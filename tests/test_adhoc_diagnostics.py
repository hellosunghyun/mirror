"""합성 Xcode 오류만 분류하며 실제 서명 자료·비공개 로그를 사용하지 않는다."""

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_adhoc_diagnostics', ROOT / 'scripts/ci-adhoc-diagnostics.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
PRIVATE_VALUES = ('SYNTHETIC_TEAM_123', 'SYNTHETIC_PROFILE_456', 'SYNTHETIC_CERT_789',
                  'SYNTHETIC_SECRET_PASSWORD', '/private/synthetic/source.swift',
                  'CN=Synthetic Private Person', 'SYNTHETIC_UNKNOWN_ERROR')


class AdHocDiagnosticsTests(unittest.TestCase):
    def invoke(self, arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = helper.main(arguments)
        output = stdout.getvalue()
        self.assertEqual(stderr.getvalue(), '')
        self.assertEqual(len(output.splitlines()), 1)
        self.assertTrue(output.startswith(helper.NOTICE_PREFIX))
        for value in PRIVATE_VALUES:
            self.assertNotIn(value, output)
        summary = json.loads(output[len(helper.NOTICE_PREFIX):])
        self.assertEqual(set(summary), {'phase', 'status', 'counts'})
        self.assertTrue(all(type(value) is int and value >= 0 for value in summary['counts'].values()))
        return code, summary

    def log_summary(self, text, phase='archive'):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'SYNTHETIC_SECRET_PASSWORD-private.log'
            path.write_text(text, encoding='utf-8')
            code, summary = self.invoke(['--phase', phase, '--log-file', str(path)])
            self.assertEqual(code, 0)
            self.assertEqual(summary['status'], 'classified')
            self.assertEqual(summary['phase'], phase)
            return summary['counts']

    def test_typical_errors_have_one_specific_category(self):
        examples = {
            'frameworkUnsupportedProvisioning': 'error: SyntheticFramework does not support provisioning profiles, but profile SYNTHETIC_PROFILE_456 has been manually specified.',
            'manualAutomaticConflict': 'error: SyntheticApp has conflicting provisioning settings. It is automatically signed, but a provisioning profile has been manually specified.',
            'signingMismatch': 'error: Provisioning profile "SYNTHETIC_PROFILE_456" doesn\'t include signing certificate "SYNTHETIC_CERT_789".',
            'missingTeam': 'error: Signing for SyntheticApp requires a development team. SYNTHETIC_TEAM_123',
            'missingProfile': 'error: No profiles for com.synthetic.private were found: Xcode could not find a provisioning profile.',
            'keychainInteraction': '/private/synthetic/source.swift: User interaction is not allowed. SYNTHETIC_SECRET_PASSWORD',
            'certificate': 'error: No signing certificate "SYNTHETIC_CERT_789" found for team SYNTHETIC_TEAM_123 with a private key.',
            'provisioning': 'error: Provisioning profile "SYNTHETIC_PROFILE_456" doesn\'t include the application-groups entitlement.',
            'destination': 'xcodebuild: error: Unable to find a destination matching the provided destination specifier.',
            'sdk': 'xcodebuild: error: SDK "iphoneos99.0" cannot be located.',
            'project': 'xcodebuild: error: The workspace does not contain a scheme named SYNTHETIC_SECRET_PASSWORD.',
            'link': 'clang: error: linker command failed with exit code 1 (use -v to see invocation)',
            'compile': '/private/synthetic/source.swift:10:2: error: cannot find SYNTHETIC_SECRET_PASSWORD in scope',
            'codeSigning': '/private/synthetic/source.swift: errSecInternalComponent',
        }
        for expected, line in examples.items():
            with self.subTest(category=expected):
                counts = self.log_summary(line + '\nCN=Synthetic Private Person\n')
                self.assertEqual(counts['errorLineCount'], 1)
                self.assertEqual(counts[expected], 1)
                self.assertEqual(sum(value for key, value in counts.items() if key != 'errorLineCount'), 1)

    def test_unknown_error_only_increases_error_line_count(self):
        counts = self.log_summary('error: SYNTHETIC_UNKNOWN_ERROR SYNTHETIC_SECRET_PASSWORD\n')
        self.assertEqual(counts['errorLineCount'], 1)
        self.assertEqual(sum(value for key, value in counts.items() if key != 'errorLineCount'), 0)

    def test_link_errors_are_not_compile_errors(self):
        counts = self.log_summary('/private/synthetic/source.swift:10:2: error: linker command failed\n'
                                  'Undefined symbols for architecture arm64:\n'
                                  'ld: framework not found SYNTHETIC_SECRET_PASSWORD\n')
        self.assertEqual(counts['errorLineCount'], 3)
        self.assertEqual(counts['link'], 3)
        self.assertEqual(counts['compile'], 0)

    def test_warnings_commands_and_failure_summaries_are_not_error_lines(self):
        counts = self.log_summary('warning: Provisioning profile SYNTHETIC_PROFILE_456 is unused.\n'
                                  'note: No signing certificate has been selected.\n'
                                  'CompileSwift /private/synthetic/source.swift\n'
                                  'Command CodeSign failed with a nonzero exit code\n'
                                  '** ARCHIVE FAILED **\n** EXPORT FAILED **\n')
        self.assertEqual(sum(counts.values()), 0)

    def test_ansi_colors_and_export_phase(self):
        counts = self.log_summary('\x1b[31merror:\x1b[0m No Team ID found in archive. SYNTHETIC_TEAM_123\n', phase='export')
        self.assertEqual(counts['missingTeam'], 1)
        self.assertEqual(counts['errorLineCount'], 1)

    def test_raw_actions_commands_cannot_escape_summary(self):
        counts = self.log_summary('error: SYNTHETIC_UNKNOWN_ERROR\n'
                                  '::notice::SYNTHETIC_SECRET_PASSWORD\n'
                                  '::error::CN=Synthetic Private Person\n')
        self.assertEqual(counts['errorLineCount'], 1)

    def test_invalid_phase_is_fixed_status_without_argument_value(self):
        code, summary = self.invoke(['--phase', 'SYNTHETIC_SECRET_PASSWORD', '--log-file', '/private/synthetic/source.swift'])
        self.assertEqual(code, 2)
        self.assertIsNone(summary['phase'])
        self.assertEqual(summary['status'], 'invalidArguments')
        self.assertEqual(sum(summary['counts'].values()), 0)

    def test_missing_argument_does_not_print_usage_or_path(self):
        code, summary = self.invoke(['--phase', 'archive', 'SYNTHETIC_SECRET_PASSWORD'])
        self.assertEqual(code, 2)
        self.assertEqual(summary['status'], 'invalidArguments')

    def test_missing_file_has_fixed_status(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'SYNTHETIC_SECRET_PASSWORD-missing.log'
            code, summary = self.invoke(['--phase', 'archive', '--log-file', str(path)])
        self.assertEqual(code, 1)
        self.assertEqual(summary['phase'], 'archive')
        self.assertEqual(summary['status'], 'inputUnavailable')
        self.assertEqual(sum(summary['counts'].values()), 0)

    def test_symlink_is_not_read(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'private.log'
            path.write_text('error: SYNTHETIC_UNKNOWN_ERROR', encoding='utf-8')
            link = Path(directory) / 'link.log'
            link.symlink_to(path)
            code, summary = self.invoke(['--phase', 'export', '--log-file', str(link)])
        self.assertEqual(code, 1)
        self.assertEqual(summary['status'], 'inputUnavailable')
        self.assertEqual(sum(summary['counts'].values()), 0)

    def test_exception_details_are_never_printed(self):
        with mock.patch.object(helper, 'summarize_file', side_effect=RuntimeError('SYNTHETIC_SECRET_PASSWORD CN=Synthetic Private Person')):
            code, summary = self.invoke(['--phase', 'archive', '--log-file', '/private/synthetic/source.swift'])
        self.assertEqual(code, 1)
        self.assertEqual(summary['status'], 'processingFailed')
        self.assertEqual(sum(summary['counts'].values()), 0)


if __name__ == '__main__':
    unittest.main()
