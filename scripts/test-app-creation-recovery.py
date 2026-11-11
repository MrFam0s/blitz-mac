#!/usr/bin/env python3
"""Offline creation-journal and authentication-recovery regressions.

Every session, identity and journal is temporary. The real CLI entry point uses
only a fake urllib opener; no Apple request or user credential read is possible.
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
MODULE = Path(__file__).resolve().parents[1] / 'src/resources/skills/asc-app-create-ui/scripts/create_app.py'
spec = importlib.util.spec_from_file_location('create_app_recovery_under_test', MODULE)
create_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(create_app)


def identity(**changes):
    return dict({
        'appName': "Reader's Desk", 'bundleId': 'org.Example.ReadersDesk.Widget',
        'sku': 'ReadersDesk.Mac-v1', 'platform': 'macOS', 'primaryLocale': 'de-DE',
        'projectId': 'test-project', 'operationId': 'offline-operation-123',
        'expectedIssuerId': 'offline-issuer-123', 'expectedKeyId': 'OFFLINEKEY123',
    }, **changes)


def response(value):
    return io.BytesIO(json.dumps(value).encode('utf-8'))


def http_error(request, status, detail='Synthetic Apple rejection'):
    return create_app.urllib.error.HTTPError(request.full_url, status, 'Synthetic rejection',
        {'Set-Cookie': 'synthetic-response-cookie'}, response({'errors': [{
            'code': 'ENTITY_ERROR.ATTRIBUTE.INVALID', 'detail': detail,
        }]}))


class SimulatedCrash(BaseException):
    pass


class FakeOpener:
    """Each network-shaped request must have an explicitly planned response."""
    def __init__(self, actions):
        self.actions = list(actions)
        self.requests = []
        self.on_request = None

    def open(self, request, timeout):
        self.requests.append(request)
        if self.on_request:
            self.on_request(request)
        if not self.actions:
            raise AssertionError('Unplanned request: ' + request.method)
        action = self.actions.pop(0)
        if callable(action):
            return action(request)
        if isinstance(action, BaseException):
            raise action
        return response(action)


class CreationRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='blitz-create-recovery-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.journals = self.root / 'operations'
        self.session = self.root / 'session.json'
        self.identity_file = self.root / 'identity.json'
        self.confirmed = identity()
        self.identity_file.write_text(json.dumps(self.confirmed), encoding='utf-8')
        self.write_session('synthetic-cookie-before-auth')
        self.opener = FakeOpener([])
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(create_app, 'operation_state_directory', return_value=self.journals).start()
        mock.patch.object(create_app.os.path, 'expanduser', side_effect=self.session_path).start()
        mock.patch.object(create_app.urllib.request, 'build_opener', side_effect=lambda *a: self.opener).start()
        mock.patch.object(create_app.urllib.request, 'urlopen', side_effect=AssertionError('Real network forbidden')).start()

    def session_path(self, path):
        self.assertEqual(path, '~/.blitz/asc-agent/web-session.json')
        return str(self.session)

    def write_session(self, cookie):
        self.session.write_text(json.dumps({'last_key': 'offline', 'sessions': {
            'offline': {'cookies': {'apple': [{'name': 'session', 'value': cookie}]}}
        }}), encoding='utf-8')

    def account_response(self, **changes):
        account = {'id': self.confirmed['expectedKeyId'], 'attributes': {
            'provider': {'id': self.confirmed['expectedIssuerId']}}}
        account.update(changes)
        return {'data': account}

    def run_main(self, mode='--create', path=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = create_app.main(['--identity-file', str(path or self.identity_file), mode])
        text = out.getvalue() if status == 0 else err.getvalue()
        return status, json.loads(text)

    def journal_path(self):
        return create_app.CreationOperation(self.confirmed, directory=self.journals).path

    def journal(self):
        return json.loads(self.journal_path().read_text(encoding='utf-8'))

    def plan_http(self, status, detail='Synthetic Apple rejection'):
        def reject(request):
            raise http_error(request, status, detail)
        return reject

    def initial_account_401(self, detail='Expired synthetic session'):
        self.opener.actions = [self.plan_http(401, detail)]
        status, result = self.run_main()
        self.assertEqual(status, 1)
        self.assertEqual(result['stage'], 'account_verification')
        self.assertFalse(result['creationAttempted'])
        self.assertTrue(result['recovery']['resumeAllowed'])
        return result

    def assert_replay_blocked(self, mode, path=None):
        count = len(self.opener.requests)
        state_before = self.journal_path().read_bytes() if self.journal_path().exists() else None
        status, result = self.run_main(mode, path)
        self.assertEqual(status, 1)
        self.assertEqual(result['status'], 'error')
        self.assertEqual(len(self.opener.requests), count, 'A blocked replay reached the opener')
        if state_before is not None:
            self.assertEqual(self.journal_path().read_bytes(), state_before)
        return result

    def test_initial_401_resumes_once_with_fresh_cookies_exact_identity_and_one_post(self):
        original_identity = self.identity_file.read_bytes()
        self.initial_account_401()
        self.write_session('synthetic-cookie-after-auth')
        self.opener.actions = [self.account_response(), {'data': {'id': 'app-created-offline'}}]
        posted_journals = []
        self.opener.on_request = lambda request: posted_journals.append(self.journal()) if request.method == 'POST' else None
        status, result = self.run_main('--resume-after-auth')
        self.assertEqual(status, 0)
        self.assertEqual(result['status'], 'created_pending_verification')
        self.assertEqual([r.method for r in self.opener.requests], ['GET', 'GET', 'POST'])
        self.assertEqual([r.get_header('Cookie') for r in self.opener.requests], [
            'session=synthetic-cookie-before-auth', 'session=synthetic-cookie-after-auth',
            'session=synthetic-cookie-after-auth'])
        self.assertEqual(json.loads(self.opener.requests[-1].data), create_app.build_payload(self.confirmed))
        self.assertEqual(result['confirmationArguments'], create_app.confirmation_arguments(self.confirmed))
        self.assertEqual(self.identity_file.read_bytes(), original_identity)
        self.assertEqual(len(posted_journals), 1)
        self.assertTrue(posted_journals[0]['creationAttempted'], 'POST began before durable attempt marker')
        self.assertEqual(posted_journals[0]['phase'], 'app_creation_in_progress')
        self.assertEqual(self.journal()['authResumptions'], 1)
        self.assertEqual(self.journal()['phase'], 'created_pending_verification')
        self.assert_replay_blocked('--create')
        self.assert_replay_blocked('--resume-after-auth')

    def test_second_precreation_401_stops_instead_of_allowing_an_auth_loop(self):
        self.initial_account_401()
        self.write_session('synthetic-second-cookie')
        self.opener.actions = [self.plan_http(401)]
        status, result = self.run_main('--resume-after-auth')
        self.assertEqual(status, 1)
        self.assertFalse(result['creationAttempted'])
        self.assertFalse(result['recovery']['resumeAllowed'])
        self.assertEqual(self.journal()['phase'], 'stopped')
        self.assertEqual(self.journal()['authResumptions'], 1)
        self.assert_replay_blocked('--resume-after-auth')
        self.assert_replay_blocked('--create')
        self.assertEqual([r.method for r in self.opener.requests], ['GET', 'GET'])

    def test_create_flag_cannot_bypass_recorded_auth_continuation(self):
        self.initial_account_401()
        self.assert_replay_blocked('--create')
        self.assertEqual(len(self.opener.requests), 1)

    def test_resume_without_initial_401_never_reads_session_or_sends_request(self):
        self.session.unlink()
        self.assert_replay_blocked('--resume-after-auth')
        self.assertEqual(self.opener.requests, [])
        self.assertFalse(self.journal_path().exists())

    def test_other_precreation_http_statuses_never_authorize_resume(self):
        for code in (403, 409, 429, 500):
            with self.subTest(code=code):
                # Each subcase is a distinct user-confirmed operation.
                self.confirmed['operationId'] = 'http-before-' + str(code)
                self.identity_file.write_text(json.dumps(self.confirmed))
                self.opener.actions = [self.plan_http(code)]
                status, result = self.run_main()
                self.assertEqual(status, 1)
                self.assertEqual(result['stage'], 'account_verification')
                self.assertFalse(result['creationAttempted'])
                self.assertFalse(result['recovery']['resumeAllowed'])
                self.assert_replay_blocked('--resume-after-auth')
                self.assert_replay_blocked('--create')
        self.assertTrue(all(r.method == 'GET' for r in self.opener.requests))

    def test_post_errors_including_401_and_409_never_authorize_resume(self):
        for code in (401, 409, 500):
            with self.subTest(code=code):
                self.confirmed['operationId'] = 'http-after-' + str(code)
                self.identity_file.write_text(json.dumps(self.confirmed))
                self.opener.actions = [self.account_response(), self.plan_http(code)]
                count = len(self.opener.requests)
                status, result = self.run_main()
                self.assertEqual(status, 1)
                self.assertEqual(result['stage'], 'app_creation')
                self.assertTrue(result['creationAttempted'])
                self.assertFalse(result['recovery']['resumeAllowed'])
                self.assertTrue(self.journal()['creationAttempted'])
                self.assert_replay_blocked('--resume-after-auth')
                self.assert_replay_blocked('--create')
                self.assertEqual([r.method for r in self.opener.requests[count:]], ['GET', 'POST'])

    def test_timeouts_before_or_after_post_fail_closed(self):
        for stage in ('GET', 'POST'):
            with self.subTest(stage=stage):
                self.confirmed['operationId'] = 'timeout-' + stage
                self.identity_file.write_text(json.dumps(self.confirmed))
                self.opener.actions = ([self.account_response()] if stage == 'POST' else []) + [TimeoutError('synthetic transport timeout')]
                status, result = self.run_main()
                self.assertEqual(status, 1)
                self.assertNotIn('resumeAllowed', result.get('recovery', {}))
                self.assert_replay_blocked('--create')
                self.assert_replay_blocked('--resume-after-auth')

    def test_process_crash_before_or_after_post_cannot_replay(self):
        for stage in ('GET', 'POST'):
            with self.subTest(stage=stage):
                self.confirmed['operationId'] = 'crash-' + stage
                self.identity_file.write_text(json.dumps(self.confirmed))
                self.opener.actions = ([self.account_response()] if stage == 'POST' else []) + [SimulatedCrash()]
                with self.assertRaises(SimulatedCrash):
                    self.run_main()
                self.assertEqual(self.journal()['creationAttempted'], stage == 'POST')
                self.assert_replay_blocked('--create')
                self.assert_replay_blocked('--resume-after-auth')

    def test_response_without_app_id_keeps_post_attempt_consumed(self):
        self.opener.actions = [self.account_response(), {'data': {}}]
        status, _ = self.run_main()
        self.assertEqual(status, 1)
        self.assertTrue(self.journal()['creationAttempted'])
        self.assert_replay_blocked('--create')
        self.assert_replay_blocked('--resume-after-auth')

    def test_different_identity_or_account_cannot_resume_same_operation(self):
        self.initial_account_401()
        for field, changed in [('appName', 'Other Public Name'), ('bundleId', 'org.Other.App'),
                               ('sku', 'OtherSKU'), ('platform', 'iOS'), ('primaryLocale', 'en-US'),
                               ('projectId', 'different-project'), ('expectedIssuerId', 'other-issuer'),
                               ('expectedKeyId', 'OTHERKEY')]:
            with self.subTest(field=field):
                self.identity_file.write_text(json.dumps(dict(self.confirmed, **{field: changed})))
                self.assert_replay_blocked('--resume-after-auth')
                self.assert_replay_blocked('--create')
        self.assertEqual([r.method for r in self.opener.requests], ['GET'])

    def test_renewed_cookies_for_wrong_account_cannot_post_or_resume_again(self):
        self.initial_account_401()
        self.write_session('synthetic-other-account-cookie')
        self.opener.actions = [self.account_response(attributes={'provider': {'id': 'wrong-account'}})]
        status, result = self.run_main('--resume-after-auth')
        self.assertEqual(status, 1)
        self.assertIn('does not match', result['message'])
        self.assertEqual([r.method for r in self.opener.requests], ['GET', 'GET'])
        self.assertEqual(self.journal()['authResumptions'], 1)
        self.assert_replay_blocked('--resume-after-auth')
        self.assert_replay_blocked('--create')

    def test_copying_identity_file_does_not_create_a_fresh_operation(self):
        self.opener.actions = [self.account_response(), {'data': {'id': 'created'}}]
        self.assertEqual(self.run_main()[0], 0)
        alternate = self.root / 'different-folder' / 'copied-identity.json'
        alternate.parent.mkdir()
        alternate.write_bytes(self.identity_file.read_bytes())
        self.assert_replay_blocked('--create', alternate)
        self.assert_replay_blocked('--resume-after-auth', alternate)
        self.assertEqual(len(list(self.journals.glob('*.json'))), 1)
        self.assertEqual([r.method for r in self.opener.requests], ['GET', 'POST'])

    def test_concurrent_operation_cannot_read_credentials_or_send_request(self):
        with create_app.CreationOperation(self.confirmed, directory=self.journals):
            self.session.unlink()
            status, result = self.run_main()
            self.assertEqual(status, 1)
            self.assertIn('already running', result['message'])
            self.assertEqual(self.opener.requests, [])
        self.assert_replay_blocked('--create')

    def test_file_lock_excludes_another_process(self):
        # A child only imports the module and tries the guard; it has no session
        # and never calls create_app or main.
        code = '''import importlib.util,json,pathlib,sys
spec=importlib.util.spec_from_file_location("operation_test",sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
try:
    with m.CreationOperation(json.loads(sys.argv[2]),directory=pathlib.Path(sys.argv[3])):
        sys.exit(2)
except m.IdentityError as error:
    print(str(error))
    sys.exit(0)
'''
        with create_app.CreationOperation(self.confirmed, directory=self.journals):
            child = subprocess.run([sys.executable, '-B', '-c', code, str(MODULE),
                                    json.dumps(self.confirmed), str(self.journals)],
                                   text=True, capture_output=True, timeout=10)
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertIn('already running', child.stdout)

    def test_corrupt_or_incomplete_journal_fails_closed(self):
        self.initial_account_401()
        valid = self.journal()
        corrupt = ['{broken', 'null', '[]', json.dumps(dict(valid, schemaVersion=2)),
                   json.dumps(dict(valid, identityDigest='wrong')),
                   json.dumps(dict(valid, phase='app_creation_in_progress')),
                   json.dumps(dict(valid, authResumptions=True)),
                   json.dumps(dict(valid, creationAttempted='false')),
                   json.dumps({key: value for key, value in valid.items() if key != 'failureStage'})]
        for contents in corrupt:
            with self.subTest(contents=contents):
                self.journal_path().write_text(contents)
                self.assert_replay_blocked('--resume-after-auth')
                self.assert_replay_blocked('--create')
        self.assertEqual([r.method for r in self.opener.requests], ['GET'])

    def test_dry_run_never_consumes_operation_or_reads_session(self):
        self.session.unlink()
        status, result = self.run_main('--dry-run')
        self.assertEqual(status, 0)
        self.assertFalse(result['creationAttempted'])
        self.assertFalse(result['appleAvailabilityChecked'])
        self.assertFalse(self.journals.exists())
        self.assertEqual(self.opener.requests, [])

    def test_journal_and_error_output_exclude_cookie_values_and_apple_error_bodies(self):
        secret = 'synthetic-cookie-before-auth'
        result = self.initial_account_401('Echoed credential: ' + secret)
        journal = self.journal_path().read_text()
        self.assertNotIn(secret, journal)
        self.assertNotIn('synthetic-response-cookie', journal)
        self.assertNotIn('Echoed credential', journal)
        self.assertNotIn(secret, json.dumps(result))
        self.assertNotIn('synthetic-response-cookie', json.dumps(result))
        for value in self.confirmed.values():
            self.assertNotIn(value, journal)
        self.assertNotIn('Cookie', journal)
        self.assertEqual(os.stat(self.journal_path()).st_mode & 0o777, 0o600)

    def test_before_create_can_only_be_consumed_once(self):
        with create_app.CreationOperation(self.confirmed, directory=self.journals) as operation:
            operation.before_create()
            durable = self.journal_path().read_bytes()
            with self.assertRaises(create_app.IdentityError):
                operation.before_create()
            self.assertEqual(self.journal_path().read_bytes(), durable)
        self.assert_replay_blocked('--create')
        self.assert_replay_blocked('--resume-after-auth')


if __name__ == '__main__':
    unittest.main()
