#!/usr/bin/env python3
"""Offline identity/payload regressions; never uses a real Apple session."""
import contextlib
import gzip
import importlib.util
import io
import json
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True

MODULE = Path(__file__).resolve().parents[1] / 'src/resources/skills/asc-app-create-ui/scripts/create_app.py'
spec = importlib.util.spec_from_file_location('create_app', MODULE)
create_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(create_app)


def identity(**changes):
    return dict({'appName': 'ClubBundle', 'bundleId': 'org.amosystems.ClubBundle',
                 'sku': 'ClubBundle-iOS', 'platform': 'iOS', 'primaryLocale': 'de-DE',
                 'projectId': 'clubbundle', 'operationId': 'test-operation',
                 'expectedIssuerId': 'test-issuer', 'expectedKeyId': 'TESTKEY123'}, **changes)


class CreationTests(unittest.TestCase):
    def test_public_name_is_data_not_code(self):
        for name in ["Bob's Calendar", 'Reader "Plus"', 'Cash $HOME `echo`', 'Path \\ Day', 'Mühlenstein']:
            with self.subTest(name=name):
                payload = json.loads(json.dumps(create_app.build_payload(identity(appName=name))))
                self.assertEqual(payload['included'][-1]['attributes']['name'], name)

    def test_bundle_and_sku_case_and_dots_roundtrip(self):
        given = identity(bundleId='org.AmoSystems.ClubBundle.Widget', sku='ClubBundle.Mac-2_Store')
        self.assertEqual(create_app.build_payload(given)['data']['attributes']['bundleId'], given['bundleId'])
        self.assertEqual(create_app.build_payload(given)['data']['attributes']['sku'], given['sku'])

    def test_selected_platform_maps_to_payload(self):
        for platform, value in [('iOS', 'IOS'), ('macOS', 'MAC_OS')]:
            self.assertEqual(create_app.build_payload(identity(platform=platform))['included'][0]['attributes']['platform'], value)

    def test_invalid_values_rejected_without_silent_repair(self):
        cases = [('sku', 'Meine App-iOS'), ('sku', '_App-iOS'), ('sku', 'Mühlenstein'),
                 ('bundleId', 'org..ClubBundle'), ('bundleId', 'org.amosystems.Mühlenstein'),
                 ('bundleId', '.org.ClubBundle'), ('bundleId', 'org.Club_Bundle'),
                 ('appName', 'A'), ('appName', 'A'*31), ('appName', 'Hello\nWorld'), ('appName', 'Hello\u0085World'), ('appName', 'e\u0301'*16),
                 ('platform', 'IOS'), ('primaryLocale', ''), ('primaryLocale', 'de DE'),
                 ('projectId', ''), ('operationId', ''), ('expectedIssuerId', ''), ('expectedKeyId', '')]
        for key, value in cases:
            with self.subTest(key=key, value=value), self.assertRaises(create_app.IdentityError):
                create_app.build_payload(identity(**{key: value}))

    def test_confirmation_carries_all_expected_identity(self):
        args = create_app.confirmation_arguments(identity())
        self.assertEqual(args, {'bundleId':'org.amosystems.ClubBundle','expectedName':'ClubBundle',
            'expectedSKU':'ClubBundle-iOS','expectedPlatform':'iOS','expectedLocale':'de-DE',
            'projectId':'clubbundle','operationId':'test-operation'})

    def test_dry_run_never_reads_session_or_creates(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'identity.json'; path.write_text(json.dumps(identity()))
            with mock.patch.object(create_app, 'create_app', side_effect=AssertionError('No create allowed')), contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(create_app.main(['--identity-file',str(path)]), 0)
            self.assertEqual(json.loads(output.getvalue())['status'], 'validated')

    def test_invalid_identity_does_not_read_credentials(self):
        with self.assertRaises(create_app.IdentityError):
            create_app.create_app(identity(sku='Bad SKU'), Path('/must-not-read-session'))

    def test_post_uses_json_and_requires_readback_verification(self):
        class Response(io.BytesIO):
            pass
        class Opener:
            def open(self, request, timeout):
                if request.method == 'GET':
                    self.lookup=request
                    return Response(json.dumps({'data':{'id':'TESTKEY123','relationships':{'provider':{'data':{'id':'test-issuer'}}}}}).encode())
                self.request=request
                return Response(gzip.compress(json.dumps({'data':{'id':'123'}}).encode()))
        opener=Opener()
        with tempfile.TemporaryDirectory() as folder:
            session=Path(folder)/'session.json'
            session.write_text(json.dumps({'sessions':{'test':{'cookies':{'apple':[{'name':'session','value':'test-only-cookie'}]}}},'last_key':'test'}))
            result=create_app.create_app(identity(appName="Bob's Calendar"),session,opener)
        self.assertEqual(result['status'],'created_pending_verification')
        self.assertEqual(result['appId'],'123')
        self.assertEqual(json.loads(opener.request.data)['included'][-1]['attributes']['name'],"Bob's Calendar")
        self.assertNotIn('test-only-cookie',json.dumps(result))
        self.assertEqual(opener.request.full_url,create_app.BASE_URL+'apps')
        self.assertEqual(opener.lookup.full_url,create_app.BASE_URL+'apiKeys/TESTKEY123?include=provider')
        self.assertEqual(opener.lookup.get_header('Cookie'), opener.request.get_header('Cookie'))

    def test_wrong_or_unknown_account_cannot_post(self):
        for data in [{'id':'OTHERKEY','attributes':{'provider':{'id':'test-issuer'}}},
                     {'id':'TESTKEY123','attributes':{'provider':{'id':'other-issuer'}}},
                     {'id':'TESTKEY123'}, {}]:
            with self.subTest(data=data), tempfile.TemporaryDirectory() as folder:
                class Opener:
                    def open(self, request, timeout):
                        if request.method != 'GET':
                            raise AssertionError('POST forbidden for unverified account')
                        return io.BytesIO(json.dumps({'data':data}).encode())
                session=Path(folder)/'session.json'
                session.write_text(json.dumps({'sessions':{'test':{'cookies':{'apple':[{'name':'session','value':'test-only-cookie'}]}}},'last_key':'test'}))
                with self.assertRaises(create_app.IdentityError):
                    create_app.create_app(identity(), session, Opener())

    def test_denied_account_lookup_cannot_post(self):
        class Opener:
            def open(self, request, timeout):
                if request.method != 'GET':
                    raise AssertionError('POST forbidden after denied lookup')
                raise create_app.urllib.error.HTTPError(request.full_url,403,'Forbidden',{},None)
        with tempfile.TemporaryDirectory() as folder:
            session=Path(folder)/'session.json'
            session.write_text(json.dumps({'sessions':{'test':{'cookies':{'apple':[{'name':'session','value':'test-only-cookie'}]}}},'last_key':'test'}))
            with self.assertRaises(create_app.urllib.error.HTTPError):
                create_app.create_app(identity(), session, Opener())

    def test_redirect_rejected(self):
        with self.assertRaises(create_app.IdentityError):
            create_app.NoRedirect().redirect_request(None,None,302,'redirect',{},'https://example.com')


if __name__ == '__main__':
    unittest.main()
