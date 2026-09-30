import contextlib
import hashlib
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check import main, run_document_validation, verify_source


ROOT = Path(__file__).resolve().parents[1]


class PreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mirror-preparation-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bundle = self.root / 'postpone-app-docs'
        shutil.copytree(ROOT / self.bundle.name, self.bundle)
        for name in ('development-baseline.json', 'Postpone_Development_Spec_v0.1.md'):
            shutil.copy2(ROOT / name, self.root / name)

    def snapshot(self, root):
        return {path.relative_to(root).as_posix(): path.read_bytes()
                for path in root.rglob('*') if path.is_file()}

    def write_json(self, path, value):
        path.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')

    def assert_validation_failure(self, error):
        before = self.snapshot(self.root)
        result = run_document_validation(self.bundle)
        self.assertEqual(result.returncode, 1, result.stderr)
        summary = json.loads(result.stdout)
        self.assertEqual(summary['result'], 'fail')
        self.assertTrue(any(error in message for message in summary['errors']), summary)
        self.assertEqual(self.snapshot(self.root), before)

    def test_valid_bundle_cli_and_copy_preserve_originals(self):
        before = self.snapshot(self.root)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(main(self.root), 0)
        summary = json.loads(stdout.getvalue())
        self.assertEqual(summary['result'], 'pass')
        self.assertEqual(summary['checkCount'], 564)
        self.assertEqual(summary['fixtureCount'], 36)
        self.assertEqual(summary['functionalRequirementCount'], 30)
        self.assertEqual(summary['qaSpecificationCount'], 87)
        self.assertEqual(summary['actualAppTestsExecuted'], 0)
        self.assertEqual(self.snapshot(self.root), before)
        original_before = self.snapshot(ROOT / self.bundle.name)
        specification = ROOT / 'Postpone_Development_Spec_v0.1.md'
        specification_before = specification.read_bytes()
        cli = subprocess.run([sys.executable, str(ROOT / 'scripts' / 'check.py')],
                             cwd=self.root, capture_output=True, text=True, check=False)
        self.assertEqual(cli.returncode, 0, cli.stderr)
        self.assertEqual(json.loads(cli.stdout), summary)
        self.assertEqual(self.snapshot(ROOT / self.bundle.name), original_before)
        self.assertEqual(specification.read_bytes(), specification_before)

    def test_changed_document_specification_and_manifest_are_rejected(self):
        for path in (self.bundle / 'README.md', self.root / 'Postpone_Development_Spec_v0.1.md',
                     self.bundle / 'MANIFEST.sha256'):
            with self.subTest(file=path.name):
                original = path.read_bytes()
                path.write_bytes(original + b'\nchanged\n')
                try:
                    stderr = io.StringIO()
                    with contextlib.redirect_stderr(stderr):
                        self.assertEqual(main(self.root), 1)
                    self.assertIn('SHA-256 불일치', stderr.getvalue())
                finally:
                    path.write_bytes(original)

    def test_manifest_escape_duplicate_and_entry_count_are_rejected(self):
        manifest = self.bundle / 'MANIFEST.sha256'
        baseline_path = self.root / 'development-baseline.json'
        baseline = json.loads(baseline_path.read_text())
        lines = manifest.read_text().splitlines()
        digest = lines[0].split('  ')[0]
        scenarios = (
            (lines + [f'{digest}  ../outside.md'], '허용하지 않는 원본 경로'),
            (lines + [f'{digest}  /outside.md'], '허용하지 않는 원본 경로'),
            (lines + [lines[0]], 'MANIFEST 중복 경로'),
            (lines[:-1], 'MANIFEST 항목 수 불일치'),
        )
        for changed, error in scenarios:
            with self.subTest(error=error, entry=changed[-1]):
                manifest.write_text('\n'.join(changed) + '\n', encoding='utf-8')
                baseline['source']['manifestSHA256'] = hashlib.sha256(manifest.read_bytes()).hexdigest()
                self.write_json(baseline_path, baseline)
                with self.assertRaisesRegex(ValueError, error):
                    verify_source(self.root)

    def test_hidden_extra_file_missing_file_and_symlink_are_rejected(self):
        hidden = self.bundle / '.unexpected'
        hidden.write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError, '원본 파일 목록 불일치'):
            verify_source(self.root)
        hidden.unlink()
        document = self.bundle / 'README.md'
        original = document.read_bytes()
        document.unlink()
        with self.assertRaises(FileNotFoundError):
            verify_source(self.root)
        outside = self.root / 'outside.md'
        outside.write_bytes(original)
        document.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, '심볼릭 링크'):
            verify_source(self.root)

    def test_broken_internal_link_is_rejected(self):
        document = self.bundle / 'README.md'
        document.write_text(document.read_text() + '\n[누락](missing.md)\n', encoding='utf-8')
        self.assert_validation_failure('Broken internal link')

    def test_invalid_command_envelope_is_rejected(self):
        document = self.bundle / '04_DATA_AND_COMMAND_CONTRACTS.md'
        text = document.read_text()
        example = re.search(r'^```json\n(.*?)^```', text, re.M | re.S)
        self.assertIsNotNone(example)
        value = json.loads(example.group(1))
        value['contractVersion'] = 'invalid-version'
        document.write_text(text[:example.start(1)] + json.dumps(value) + '\n' + text[example.end(1):],
                            encoding='utf-8')
        self.assert_validation_failure('Envelope example')

    def test_fixture_expectation_mismatch_is_rejected(self):
        path = self.bundle / 'fixtures' / 'domain-cases.json'
        value = json.loads(path.read_text())
        value['cases'][0]['expected']['tomorrow'] = '2000-01-01'
        self.write_json(path, value)
        self.assert_validation_failure('F-001:')

    def test_qa_and_requirement_mapping_errors_are_rejected(self):
        path = self.bundle / 'validation' / 'traceability.json'
        value = json.loads(path.read_text())
        value['requirements'][0]['testIDs'] = ['Q-999']
        self.write_json(path, value)
        self.assert_validation_failure('Invalid mapping: FR-001')
        qa_path = self.bundle / 'validation' / 'qa-cases.json'
        qa = json.loads(qa_path.read_text())
        qa[0]['requirements'] = ['FR-999']
        self.write_json(qa_path, qa)
        self.assert_validation_failure('Unknown QA requirements: Q-001')

    def test_validator_nonzero_exit_is_propagated(self):
        document = self.bundle / 'README.md'
        document.write_text(document.read_text() + '\n[누락](missing.md)\n', encoding='utf-8')
        manifest = self.bundle / 'MANIFEST.sha256'
        digest = hashlib.sha256(document.read_bytes()).hexdigest()
        manifest.write_text(re.sub(r'^[0-9a-f]{64}  README.md$', f'{digest}  README.md',
                                   manifest.read_text(), flags=re.M), encoding='utf-8')
        baseline_path = self.root / 'development-baseline.json'
        baseline = json.loads(baseline_path.read_text())
        baseline['source']['manifestSHA256'] = hashlib.sha256(manifest.read_bytes()).hexdigest()
        self.write_json(baseline_path, baseline)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(main(self.root), 1)
        self.assertEqual(json.loads(stdout.getvalue())['result'], 'fail')


if __name__ == '__main__':
    unittest.main()
