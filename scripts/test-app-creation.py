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
    def test_existing_store_platform_intent_cannot_create_duplicate_record(self):
        with self.assertRaises(create_app.IdentityError):
            create_app.build_payload(identity(creationMode="addPlatform"))

    def test_release_target_is_preserved_in_confirmation_not_apple_payload(self):
        given = identity(creationMode="newStoreApp", releaseTargetId="mac-target")
        self.assertEqual(create_app.confirmation_arguments(given)["releaseTargetId"], "mac-target")
        self.assertNotIn("releaseTargetId", json.dumps(create_app.build_payload(given)))
        with self.assertRaises(create_app.IdentityError):
            create_app.validate_identity(identity(releaseTargetId=" "))

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
            result = json.loads(output.getvalue())
            self.assertEqual(result['status'], 'validated')
            self.assertEqual(result['validationScope'], 'local_identity_and_payload_only')
            self.assertFalse(result['appleAvailabilityChecked'])
            self.assertFalse(result['creationAttempted'])

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
            with self.assertRaises(create_app.urllib.error.HTTPError) as caught:
                create_app.create_app(identity(), session, Opener())
            caught.exception.close()

    def test_redirect_rejected(self):
        with self.assertRaises(create_app.IdentityError):
            create_app.NoRedirect().redirect_request(None,None,302,'redirect',{},'https://example.com')


def apple_http_error(body, *, status=409, stage='app_creation', secrets=()):
    if isinstance(body, dict):
        body = json.dumps(body).encode()
    error = create_app.urllib.error.HTTPError(
        create_app.BASE_URL + 'apps', status, 'Apple error',
        {'Set-Cookie': 'response-secret-must-not-appear'}, io.BytesIO(body))
    error.blitz_stage = stage
    error.blitz_sensitive_values = secrets
    return error


class CreationFailureTests(unittest.TestCase):
    def test_conflict_preserves_apple_fields_and_does_not_guess_identity(self):
        errors = [
            {'code': 'ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE',
             'title': 'An attribute is invalid', 'detail': 'The bundle ID org.amosystems.ClubBundle is unavailable.',
             'source': {'pointer': '/data/attributes/bundleId'}},
            {'code': 'ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE',
             'title': 'SKU is in use', 'detail': 'ClubBundle-iOS is already used.',
             'source': {'pointer': '/data/attributes/sku'}},
            {'code': 'ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE.DIFFERENT_ACCOUNT',
             'title': 'Name is in use', 'detail': 'The name ClubBundle is already used.',
             'source': {'pointer': '/included/2/attributes/name'}},
        ]
        result = create_app.format_http_error(apple_http_error({'errors': errors}))
        self.assertEqual(result['httpStatus'], 409)
        self.assertEqual(result['stage'], 'app_creation')
        self.assertTrue(result['creationAttempted'])
        self.assertEqual(result['appleErrors'], errors)
        self.assertEqual(result['conflictFields'], ['bundleId', 'sku', 'appName'])
        self.assertNotIn('confirmationArguments', result)
        self.assertNotIn('payload', result)

    def test_missing_pointer_does_not_assume_bundle_name_or_sku_conflict(self):
        result = create_app.format_http_error(apple_http_error({'errors': [
            {'code': 'ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE', 'detail': 'Already in use'}]}))
        self.assertEqual(result['conflictFields'], [])
        self.assertEqual(result['appleErrors'][0]['detail'], 'Already in use')

    def test_account_conflict_never_posts_and_reports_actual_stage(self):
        calls = []
        class Opener:
            def open(self, request, timeout):
                calls.append(request.method)
                raise apple_http_error({'errors': [{'code': 'ACCOUNT_CONFLICT', 'detail': 'The account cannot be verified.'}]})
        with tempfile.TemporaryDirectory() as folder:
            session = Path(folder) / 'session.json'
            session.write_text(json.dumps({'sessions': {'test': {'cookies': {'apple': [
                {'name': 'session', 'value': 'test-only-cookie'}]}}}, 'last_key': 'test'}))
            with self.assertRaises(create_app.urllib.error.HTTPError) as caught:
                create_app.create_app(identity(), session, Opener())
        result = create_app.format_http_error(caught.exception)
        self.assertEqual(calls, ['GET'])
        self.assertEqual(result['stage'], 'account_verification')
        self.assertFalse(result['creationAttempted'])
        self.assertNotIn('conflictFields', result)
        self.assertEqual(result['appleErrors'][0]['code'], 'ACCOUNT_CONFLICT')
        self.assertIn('No app creation request was sent.', result['message'])

    def test_creation_conflict_never_retries_or_changes_confirmed_identity(self):
        calls = []
        confirmed = identity(appName="Bob's Calendar", bundleId='org.AmoSystems.Calendar', sku='Calendar.Mac-v1')
        expected_payload = create_app.build_payload(confirmed)
        class Opener:
            def open(self, request, timeout):
                calls.append(request)
                if request.method == 'GET':
                    return io.BytesIO(json.dumps({'data': {'id': 'TESTKEY123', 'attributes': {
                        'provider': {'id': 'test-issuer'}}}}).encode())
                raise apple_http_error({'errors': [{'code': 'ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE',
                    'detail': 'Invalid: test-only-cookie'}]})
        with tempfile.TemporaryDirectory() as folder:
            session = Path(folder) / 'session.json'
            session.write_text(json.dumps({'sessions': {'test': {'cookies': {'apple': [
                {'name': 'session', 'value': 'test-only-cookie'}]}}}, 'last_key': 'test'}))
            with self.assertRaises(create_app.urllib.error.HTTPError) as caught:
                create_app.create_app(confirmed, session, Opener())
        result = create_app.format_http_error(caught.exception)
        self.assertEqual([call.method for call in calls], ['GET', 'POST'])
        self.assertEqual(json.loads(calls[1].data), expected_payload)
        self.assertEqual(create_app.build_payload(confirmed), expected_payload)
        self.assertEqual(result['stage'], 'app_creation')
        self.assertTrue(result['creationAttempted'])
        self.assertNotIn('test-only-cookie', json.dumps(result))

    def test_unknown_stage_is_not_claimed_as_attempted_creation(self):
        result = create_app.format_http_error(apple_http_error(b'{}', stage='unknown'))
        self.assertIsNone(result['creationAttempted'])
        self.assertNotIn('conflictFields', result)

    def test_gzip_error_body_is_decoded(self):
        body = gzip.compress(json.dumps({'errors': [{'title': 'Conflict', 'detail': 'SKU already used.'}]}).encode())
        result = create_app.format_http_error(apple_http_error(body))
        self.assertEqual(result['appleErrors'], [{'title': 'Conflict', 'detail': 'SKU already used.'}])

    def test_unstructured_oversized_and_invalid_bodies_are_not_exposed(self):
        invalid_bodies = [b'<html>SECRET</html>', b'not json SECRET', b'{"password":"SECRET"}',
                          b'[]', b'{"errors":"SECRET"}', b'\x1f\x8bcorrupt',
                          b' ' * 65537, gzip.compress(b' ' * 65537),
                          b'{"errors":[{"detail":"' + b'x' * 65536 + b'"}]}']
        for body in invalid_bodies:
            with self.subTest(length=len(body)):
                result = create_app.format_http_error(apple_http_error(body))
                self.assertNotIn('appleErrors', result)
                self.assertNotIn('SECRET', json.dumps(result))
                self.assertEqual(result['httpStatus'], 409)

    def test_only_allowlisted_fields_and_identity_pointers_are_exposed(self):
        error = apple_http_error({'errors': [{
            'code': 'INVALID CODE <html>', 'title': 'Conflict',
            'source': {'pointer': '/data/attributes/password', 'parameter': 'SECRET'},
            'meta': {'cookie': 'SECRET'}, 'links': {'about': 'https://example.invalid/SECRET'},
            'request': {'Authorization': 'SECRET'}, 'status': 'SECRET',
        }], 'headers': {'Cookie': 'SECRET'}})
        result = create_app.format_http_error(error)
        self.assertEqual(result['appleErrors'], [{'title': 'Conflict'}])
        self.assertNotIn('SECRET', json.dumps(result))
        self.assertNotIn('response-secret', json.dumps(result))

    def test_credential_markup_and_control_text_are_not_leaked(self):
        secret_texts = ['Cookie: session=SECRET', 'Authorization: Bearer SECRET',
                        'Bearer SECRET', 'Basic SECRET', '-----BEGIN PRIVATE KEY----- SECRET',
                        'eyJhbGciOiJIUzI1NiJ9.e30.c2lnbmF0dXJl', '<html>SECRET</html>',
                        'Password=SECRET', 'SessionToken: SECRET', 'Access_Token=SECRET',
                        'SCNT=SECRET', 'X-Apple-Session-Token: SECRET',
                        'https://example.invalid/?token=SECRET', 'Echo: SECRET',
                        'Auth\u200borization: SECRET']
        for text in secret_texts:
            with self.subTest(text=text):
                result = create_app.format_http_error(apple_http_error({'errors': [{'title': text, 'detail': text}]}, secrets=('SECRET',)))
                rendered = json.dumps(result)
                for forbidden in ['SECRET', 'eyJhbGciOiJIUzI1NiJ9', '<html>', 'PRIVATE KEY']:
                    self.assertNotIn(forbidden, rendered)
        result = create_app.format_http_error(apple_http_error({'errors': [{'code': 'SECRET'}]}, secrets=('SECRET',)))
        self.assertNotIn('SECRET', json.dumps(result))

    def test_marked_credentials_are_removed_even_without_known_cookie(self):
        for text in ['Cookie: unrecognized', 'Auth\u200borization: unrecognized',
                     'eyJhbGciOiJIUzI1NiJ9.e30.c2lnbmF0dXJl', '-----BEGIN PRIVATE KEY-----', '<b>bad</b>']:
            with self.subTest(text=text):
                result = create_app.format_http_error(apple_http_error({'errors': [{'detail': text}]}))
                self.assertEqual(result['appleErrors'][0]['detail'], '[Sensitive or non-text error detail omitted]')

    def test_error_counts_lengths_and_control_characters_are_bounded(self):
        result = create_app.format_http_error(apple_http_error({'errors': [
            {'title': 'A' * 600, 'detail': 'Normal\ntext\twith\u202econtrols\x00.'} for _ in range(20)]}))
        self.assertEqual(len(result['appleErrors']), 8)
        self.assertEqual(result['appleErrors'][0]['title'], 'A' * 512)
        self.assertEqual(result['appleErrors'][0]['detail'], 'Normal text withcontrols.')

    def test_main_reports_structured_failure_without_success_or_raw_headers(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'identity.json'
            path.write_text(json.dumps(identity()))
            error = apple_http_error({'errors': [{'code': 'ACCOUNT_CONFLICT', 'detail': 'Account is unavailable.'}]}, stage='account_verification')
            with mock.patch.object(create_app, 'create_app', side_effect=error), \
                    mock.patch.object(create_app, 'operation_state_directory', return_value=Path(folder) / 'operations'), \
                    contextlib.redirect_stdout(io.StringIO()) as output, \
                    contextlib.redirect_stderr(io.StringIO()) as failures:
                self.assertEqual(create_app.main(['--identity-file', str(path), '--create']), 1)
            self.assertEqual(output.getvalue(), '')
            result = json.loads(failures.getvalue())
            self.assertFalse(result['creationAttempted'])
            self.assertEqual(result['appleErrors'][0]['code'], 'ACCOUNT_CONFLICT')
            self.assertNotIn('Set-Cookie', failures.getvalue())
            self.assertNotIn('response-secret', failures.getvalue())


if __name__ == '__main__':
    unittest.main()
