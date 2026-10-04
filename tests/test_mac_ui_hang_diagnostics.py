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
