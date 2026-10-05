"""고정 Mac 결과 소유와 원문 비공개 경계. GitHub Actions에서만 실행한다."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    'mac_ui_hang_diagnostics', Path(__file__).resolve().parents[1] / 'scripts/ci-mac-ui-hang-diagnostics.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
PRIVATE = 'SYNTHETIC_PRIVATE_AX_TOKEN_FILENAME'


class PreservedMacDiagnosticsTests(unittest.TestCase):
    def ownership(self):
        run = {'id': helper.SOURCE['runID'], 'run_attempt': 1, 'run_number': 106,
               'head_sha': helper.SOURCE['sha'], 'status': 'in_progress', 'conclusion': None,
               'repository': {'full_name': 'hellosunghyun/mirror'}}
        artifact = {'id': helper.SOURCE['artifactID'], 'name': helper.ARTIFACT_NAME, 'expired': False,
                    'size_in_bytes': 5027155, 'digest': helper.ARTIFACT_DIGEST,
                    'workflow_run': {'id': helper.SOURCE['runID'], 'head_sha': helper.SOURCE['sha']}}
        job = {'id': helper.SOURCE['jobID'], 'run_id': helper.SOURCE['runID'], 'run_attempt': 1,
               'head_sha': helper.SOURCE['sha'], 'name': '네 경로 실제 검증 / macOS 앱 빌드와 테스트',
               'status': 'completed', 'conclusion': 'failure'}
        return run, artifact, job

    def test_completed_unsigned_mac_job_does_not_wait_for_entire_run(self):
        run, artifact, job = self.ownership()
        self.assertEqual(run['status'], 'in_progress')
        helper.verify_owner(run, artifact, job)
        for key in ('id', 'run_id', 'run_attempt', 'head_sha', 'name', 'status', 'conclusion'):
            with self.subTest(key=key), self.assertRaises(helper.DiagnosticFailure):
                helper.verify_owner(run, artifact, {**job, key: PRIVATE})

    def test_rejects_wrong_run_attempt_source_build_and_artifact(self):
        helper.verify_owner(*self.ownership())
        for key in ('id', 'run_attempt', 'run_number', 'head_sha'):
            run, artifact, job = self.ownership()
            run[key] = PRIVATE
            with self.subTest(key=key), self.assertRaises(helper.DiagnosticFailure):
                helper.verify_owner(run, artifact, job)
        for key in ('id', 'name', 'digest', 'size_in_bytes', 'expired'):
            run, artifact, job = self.ownership()
            artifact[key] = PRIVATE
            with self.subTest(key=key), self.assertRaises(helper.DiagnosticFailure):
                helper.verify_owner(run, artifact, job)

    def test_context_requires_exact_source_and_no_extra_values(self):
        context = {'platform': 'macos', 'scheme': 'MirrorMac', 'sdk': 'macosx',
                   'destination': 'platform=macOS,arch=arm64', 'run_id': '37193375591',
                   'run_attempt': '1', 'commit': helper.SOURCE['sha'], 'build_number': '106'}
        helper.verify_context(context)
        for key in context:
            with self.subTest(key=key), self.assertRaises(helper.DiagnosticFailure):
                helper.verify_context({**context, key: PRIVATE})
        with self.assertRaises(helper.DiagnosticFailure):
            helper.verify_context({**context, PRIVATE: PRIVATE})

    def test_public_help_requires_both_actual_option_entries(self):
        self.assertTrue(helper.supports_export('OPTIONS:\n  --path <path>\n  --output-path <path>'))
        for text in ('', 'USAGE: --path --output-path', '  --path <path>',
                     '  --path-extra\n  --output-path <path>'):
            with self.subTest(text=text):
                self.assertFalse(helper.supports_export(text))

    def test_tree_rejects_changed_bytes_and_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp)
            digest = hashlib.sha256()
            for number in range(64):
                name, body = f'{number:02d}', b'fixed fixture'
                (bundle / name).write_bytes(body)
                digest.update(name.encode() + b'\0' + len(body).to_bytes(8, 'big') + hashlib.sha256(body).digest())
            helper.verify_tree(bundle, expected=digest.hexdigest())
            (bundle / '00').write_text(PRIVATE)
            with self.assertRaises(helper.DiagnosticFailure):
                helper.verify_tree(bundle, expected=digest.hexdigest())
            (bundle / 'link').symlink_to(bundle / '00')
            with self.assertRaises(helper.DiagnosticFailure):
                helper.verify_tree(bundle, expected=digest.hexdigest())

    def test_native_failure_preserves_exit_without_printing_raw_output(self):
        with tempfile.TemporaryDirectory() as temp, contextlib.redirect_stdout(io.StringIO()) as output:
            def failed(arguments, stdout, stderr, check):
                stdout.write(PRIVATE.encode())
                stderr.write(PRIVATE.encode())
                return subprocess.CompletedProcess(arguments, 73)
            with mock.patch.object(helper.subprocess, 'run', side_effect=failed):
                with self.assertRaises(helper.DiagnosticFailure) as caught:
                    helper.native(['fixed-command'], Path(temp), 'private')
            self.assertEqual(caught.exception.exit_code, 73)
            self.assertEqual(output.getvalue(), '')

    def test_observation_matches_only_verified_same_command_usage_and_public_read_error_prefix(self):
        usage = 'USAGE: xcresulttool export attachments --path <path> --output-path <output-path>'
        verified = helper.public_usage_lines(usage, 'attachments')
        self.assertEqual(verified, {usage})
        self.assertEqual(helper.public_usage_lines(usage, 'diagnostics'), set())
        with tempfile.TemporaryDirectory() as temp:
            private = Path(temp)
            stdout = ('π ' + PRIVATE).encode()
            stderr = (usage + '\nError Domain=NSCocoaErrorDomain Code=259 "' + PRIVATE + '"\n'
                      'Error: Error Domain=NSCocoaErrorDomain Code=260 "' + PRIVATE + '"').encode()
            (private / 'probe.out').write_bytes(stdout)
            (private / 'probe.err').write_bytes(stderr)
            result = helper.native_observation(private, 'probe', verified)
            self.assertEqual(result['stdout']['bytes'], len(stdout))
            self.assertEqual(result['stderr']['bytes'], len(stderr))
            self.assertFalse(result['stdout']['verifiedUsageEcho'])
            self.assertTrue(result['stderr']['verifiedUsageEcho'])
            self.assertEqual(result['stderr']['fileReadErrorEnums'], ['fileReadCorruptFile', 'fileReadNoSuchFile'])
            self.assertNotIn(PRIVATE, json.dumps(result))
            self.assertNotIn(temp, json.dumps(result))
            self.assertNotIn(usage, json.dumps(result))

    def test_unknown_messages_paths_and_similar_codes_do_not_become_failure_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            private = Path(temp)
            (private / 'probe.out').write_bytes(b'')
            text = '\n'.join((
                '/private/' + PRIVATE + '/Error Domain=NSCocoaErrorDomain Code=259',
                'Description: Error Domain=NSCocoaErrorDomain Code=259',
                ' Error Domain=NSCocoaErrorDomain Code=259',
                'Error Domain=OtherDomain Code=259', 'Error Domain=NSCocoaErrorDomain Code=2590',
                'Error Domain=NSCocoaErrorDomain Code=261', PRIVATE))
            (private / 'probe.err').write_text(text)
            result = helper.native_observation(private, 'probe')
            self.assertEqual(result['stdout']['bytes'], 0)
            self.assertEqual(result['stderr']['fileReadErrorEnums'], [])
            self.assertFalse(result['stderr']['verifiedUsageEcho'])
            self.assertNotIn(PRIVATE, json.dumps(result))

    def test_unavailable_unreadable_and_oversized_observations_remain_nonfatal_and_private(self):
        with tempfile.TemporaryDirectory() as temp:
            private = Path(temp)
            self.assertFalse(helper.native_observation(private, 'missing')['stderr']['available'])
            (private / 'probe.out').write_bytes(b'\xff')
            (private / 'probe.err').symlink_to(private / 'probe.out')
            result = helper.native_observation(private, 'probe')
            self.assertEqual(result['stdout']['bytes'], 1)
            self.assertFalse(result['stdout']['textDecoded'])
            self.assertFalse(result['stderr']['available'])
            (private / 'large.out').touch()
            with (private / 'large.out').open('wb') as handle:
                handle.truncate(2 * 1024 * 1024 + 1)
            result = helper.native_observation(private, 'large')
            self.assertEqual(result['stdout']['bytes'], 2 * 1024 * 1024 + 1)
            self.assertFalse(result['stdout']['textDecoded'])

    def test_inspect_keeps_both_exports_original_exit_codes_and_first_failure(self):
        for codes in ((0, 0), (1, 64)):
            with self.subTest(codes=codes), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / 'private').mkdir()
                (root / 'source').mkdir()
                (root / 'private/ownership.json').write_text(json.dumps(dict(zip(('run', 'artifact', 'job'), self.ownership()))))
                (root / 'source/unit-context.json').write_text('{}')
                calls = []
                def run(arguments, stdout, stderr, check):
                    calls.append(arguments)
                    if arguments == ['xcodebuild', '-version']:
                        stdout.write(b'Xcode 27\n')
                    elif arguments == ['xcrun', '--sdk', 'macosx', '--show-sdk-version']:
                        stdout.write(b'27.0\n')
                    else:
                        kind = arguments[3]
                        usage = 'USAGE: xcresulttool export ' + kind + ' --path <path> --output-path <output-path>'
                        if arguments[-1] == '--help':
                            stdout.write((usage + '\nOPTIONS:\n  --path <path>\n  --output-path <output-path>').encode())
                        else:
                            expected = ['xcrun', 'xcresulttool', 'export', kind, '--path', str(root / 'source/UI.xcresult'),
                                        '--output-path', str(root / 'private' / kind)]
                            self.assertEqual(arguments, expected)
                            code = codes[0 if kind == 'diagnostics' else 1]
                            if code:
                                text = ('Error Domain=NSCocoaErrorDomain Code=259 "' + PRIVATE + '"'
                                        if kind == 'diagnostics' else usage + '\n' + PRIVATE)
                                stderr.write(text.encode())
                                return subprocess.CompletedProcess(arguments, code)
                            (root / 'private' / kind).mkdir()
                    return subprocess.CompletedProcess(arguments, 0)
                summary = {'exports': {}}
                with mock.patch.object(helper, 'verify_context') as context, mock.patch.object(helper, 'verify_tree') as tree, \
                        mock.patch.object(helper.subprocess, 'run', side_effect=run):
                    if codes[0]:
                        with self.assertRaises(helper.DiagnosticFailure) as caught:
                            helper.inspect(root, summary)
                        self.assertEqual(caught.exception.exit_code, 1)
                    else:
                        helper.inspect(root, summary)
                        self.assertEqual(summary['phase'], 'complete')
                context.assert_called_once_with({})
                tree.assert_called_once_with(root / 'source/UI.xcresult')
                self.assertEqual(len(calls), 6)
                for index, kind in enumerate(('diagnostics', 'attachments')):
                    exported = summary['exports'][kind]
                    self.assertEqual(exported['status'], 'nativeCommandFailed' if codes[index] else 'exported')
                    if codes[index]:
                        self.assertEqual(exported['exitCode'], codes[index])
                    else:
                        self.assertEqual(exported['fileCategoryCounts'], dict.fromkeys(helper.CATEGORIES, 0))
                self.assertNotIn(PRIVATE, json.dumps(summary))
                self.assertNotIn(temp, json.dumps(summary))

    def test_names_and_contents_never_enter_category_output(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for extension in ('png', 'json', 'txt', 'zip', 'ips', 'tracev3', 'unknown'):
                (directory / (PRIVATE + '.' + extension)).write_text(PRIVATE)
            counts = helper.file_counts(directory)
            self.assertEqual(counts, dict.fromkeys(helper.CATEGORIES, 1))
            self.assertNotIn(PRIVATE, json.dumps(counts))
            (directory / 'link').symlink_to(directory / (PRIVATE + '.txt'))
            with self.assertRaises(helper.DiagnosticFailure):
                helper.file_counts(directory)

    def test_exception_text_and_environment_do_not_escape_summary(self):
        with tempfile.TemporaryDirectory() as temp, contextlib.redirect_stdout(io.StringIO()) as output:
            env = {'GITHUB_REPOSITORY': 'hellosunghyun/mirror', 'RUNNER_OS': 'macOS',
                   'RUNNER_TEMP': temp, 'GH_TOKEN': PRIVATE}
            with mock.patch.dict(os.environ, env), mock.patch.object(helper, 'api', side_effect=RuntimeError(PRIVATE)):
                self.assertEqual(helper.main(['verify']), 2)
            text = (Path(temp) / 'mirror-mac-ui-hang/public/summary.json').read_text()
            self.assertNotIn(PRIVATE, output.getvalue() + text)
            self.assertNotIn(temp, output.getvalue() + text)
            self.assertEqual(json.loads(text)['status'], 'diagnosticUnavailable')


if __name__ == '__main__':
    unittest.main()
