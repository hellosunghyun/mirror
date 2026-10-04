"""native 시작 경계 영수증과 timeout 뒤 부분 PNG 진단의 결합. Actions에서 실행한다."""
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('adaptive_native_start', ROOT / 'scripts/ci-adaptive-ui-results.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
EXPECTED = {'platform': 'iphone', 'appearance': 'system', 'commitSHA': 'a' * 40,
            'buildNumber': '23', 'runID': '34', 'runAttempt': '1'}
RECEIPT_HASH = 'b' * 64
CASE = helper.CAPTURE_FAILURE_CASE
ERRORS = (helper.AdaptiveError, OSError, ValueError)


def start_value(**changes):
    return {**EXPECTED, 'formatVersion': 1, 'kind': 'adaptive-native-test-start',
            'buildReceiptSHA256': RECEIPT_HASH, **changes}


def fixture(directory):
    root = Path(directory).resolve()
    work = root / '.build/ci-adaptive-ui/iphone-system'
    work.mkdir(parents=True)
    source = root / helper.UI_FAILURE_SOURCE_FILE
    source.parent.mkdir(parents=True)
    source.write_text('final class MirrorAdaptiveUITests: XCTestCase {\n'
        + ''.join('    func ' + case + '() throws {\n    }\n' for case in helper.CASES) + '}\n')
    outcome = {**EXPECTED, 'phase': 'build', 'status': 'buildComplete',
               'commandExitCode': 0, 'xcodebuildExitCode': 0}
    (work / 'safe-outcome.json').write_text(json.dumps(outcome))
    return root, work


def marker(prefix, value):
    return prefix + json.dumps(value)


def event(state):
    return "Test Case '-[MirrorIOSAdaptiveUITests.MirrorAdaptiveUITests " + CASE + "]' " + state + '.'


def log_rows(terminal='failed', *, capture_failure=False):
    rows = [event('started')]
    if capture_failure:
        rows.append(marker(helper.CASE_DIAGNOSTIC_MARKER,
            {'schemaVersion': 1, 'case': 'captureValidation', 'requestSequence': 0, 'requestedElement': None}))
    for sequence, (phase, step) in enumerate(helper.PROGRESS_PROTOCOL[CASE], 1):
        rows.append(marker(helper.PROGRESS_MARKER,
            {'method': CASE + '()', 'phase': phase, 'sequence': sequence, 'step': step}))
        if phase == 'launchComplete':
            rows.append(marker(helper.CONFIG_MARKER, helper.configuration(EXPECTED, CASE)))
        if phase == ('captureInputComplete' if capture_failure else 'recordComplete'):
            break
    if capture_failure:
        rows.append(marker(helper.CASE_DIAGNOSTIC_MARKER,
            {'schemaVersion': 1, 'case': 'captureValidation', 'requestSequence': 1, 'requestedElement': 'captureSave'}))
        rows.append(marker(helper.CAPTURE_SAVE_FAILURE_MARKER,
            {'schemaVersion': 1, 'case': 'captureValidation', 'requestSequence': 1, 'requestedElement': 'captureSave',
             'boundary': 'assertVisible', 'exists': True, 'enabled': True, 'hittable': False,
             'windowOwnerCount': 1, 'ownerHasCaptureClose': True, 'scrollCandidateCount': 0,
             'scrollOwnerCount': 0, 'frame': [10, 20, 100, 44], 'viewport': None}))
        rows.append(marker(helper.CAPTURE_FAILURE_SHOT_MARKER,
            {'schemaVersion': 1, 'case': 'captureValidation', 'requestSequence': 1,
             'name': helper.CAPTURE_FAILURE_SHOT_NAME, 'status': 'complete'}))
    if terminal is not None:
        rows.append(event(terminal))
    return rows


class NativeTestStartTests(unittest.TestCase):
    def test_start_record_verifies_build_and_is_private_exclusive_without_changing_outcome(self):
        with tempfile.TemporaryDirectory() as directory:
            root, work = fixture(directory)
            original = (work / 'safe-outcome.json').read_bytes()
            with mock.patch.object(helper, 'ROOT', root), \
                    mock.patch.object(helper, 'verify_receipt', return_value=RECEIPT_HASH) as receipt:
                helper.native_test_start_record(work, EXPECTED)
                receipt.assert_called_once_with(work, EXPECTED)
                path = work / 'native-test-start.json'
                self.assertEqual(json.loads(path.read_text()), start_value())
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                helper.verify_native_test_start(work, EXPECTED, RECEIPT_HASH)
                with self.assertRaises(ERRORS):
                    helper.native_test_start_record(work, EXPECTED)
            self.assertEqual((work / 'safe-outcome.json').read_bytes(), original)
            self.assertFalse((work / 'test.log').exists())
            self.assertFalse((work / 'UI.xcresult').exists())
            self.assertFalse((work / 'review').exists())

    def test_start_record_rejects_existing_artifacts_including_dangling_symlinks(self):
        for name in ('test.log', 'UI.xcresult', 'native-test-start.json'):
            for kind in ('file', 'directory', 'symlink', 'dangling'):
                with self.subTest(name=name, kind=kind), tempfile.TemporaryDirectory() as directory:
                    root, work = fixture(directory)
                    stale = work / name
                    if kind == 'file':
                        stale.write_bytes(b'existing')
                    elif kind == 'directory':
                        stale.mkdir()
                    else:
                        target = root / 'target'
                        if kind == 'symlink':
                            target.write_bytes(b'existing')
                        stale.symlink_to(target)
                    with mock.patch.object(helper, 'ROOT', root), \
                            mock.patch.object(helper, 'verify_receipt', return_value=RECEIPT_HASH), \
                            self.assertRaises(ERRORS):
                        helper.native_test_start_record(work, EXPECTED)
                    if name != 'native-test-start.json':
                        self.assertFalse((work / 'native-test-start.json').exists())
                    if kind in ('symlink', 'dangling'):
                        self.assertTrue(stale.is_symlink())

    def test_start_record_requires_valid_current_build_outcome_and_verified_receipt(self):
        variants = ({'phase': 'test'}, {'status': 'failed', 'commandExitCode': 65, 'xcodebuildExitCode': 65},
                    {'status': 'passed'}, {'runAttempt': '2'}, {'extra': 'untrusted'})
        for changes in variants:
            with self.subTest(fields=tuple(changes)), tempfile.TemporaryDirectory() as directory:
                root, work = fixture(directory)
                path = work / 'safe-outcome.json'
                path.write_text(json.dumps({**json.loads(path.read_text()), **changes}))
                original = path.read_bytes()
                with mock.patch.object(helper, 'ROOT', root), \
                        mock.patch.object(helper, 'verify_receipt', return_value=RECEIPT_HASH), self.assertRaises(ERRORS):
                    helper.native_test_start_record(work, EXPECTED)
                self.assertFalse((work / 'native-test-start.json').exists())
                self.assertEqual(path.read_bytes(), original)
        with tempfile.TemporaryDirectory() as directory:
            root, work = fixture(directory)
            with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'verify_receipt',
                    side_effect=helper.AdaptiveError('buildReceiptMismatch')), self.assertRaises(helper.AdaptiveError):
                helper.native_test_start_record(work, EXPECTED)
            self.assertFalse((work / 'native-test-start.json').exists())

    def test_start_receipt_requires_exact_typed_identity_hash_and_complete_unique_json(self):
        changes = [{'formatVersion': True}, {'formatVersion': 2}, {'kind': 'another-kind'},
                   {'buildReceiptSHA256': 'c' * 64}, {'buildReceiptSHA256': 'B' * 64},
                   {'buildReceiptSHA256': True}, {'buildReceiptSHA256': 'b' * 63}, {'extra': 'untrusted'}]
        changes += [{key: 'foreign'} for key in EXPECTED]
        changes += [{key: int(EXPECTED[key])} for key in ('buildNumber', 'runID', 'runAttempt')]
        malformed = [json.dumps(start_value(**change)) for change in changes]
        malformed += ['{', json.dumps(start_value())[:-1],
                      json.dumps(start_value()).replace('"formatVersion": 1', '"formatVersion": 1, "formatVersion": 1'),
                      json.dumps({key: value for key, value in start_value().items() if key != 'kind'})]
        with tempfile.TemporaryDirectory() as directory:
            root, work = fixture(directory)
            path = work / 'native-test-start.json'
            for index, value in enumerate(malformed):
                path.write_text(value)
                with self.subTest(index=index), mock.patch.object(helper, 'ROOT', root), self.assertRaises(ERRORS):
                    helper.verify_native_test_start(work, EXPECTED, RECEIPT_HASH)
            path.unlink()
            path.symlink_to(root / 'missing')
            with mock.patch.object(helper, 'ROOT', root), self.assertRaises(ERRORS):
                helper.verify_native_test_start(work, EXPECTED, RECEIPT_HASH)

    def test_build_complete_fallback_requires_start_and_owned_completed_capture_without_rewriting_outcome(self):
        for terminal, capture_failure in (('failed', False), (None, False), ('failed', True)):
            with self.subTest(terminal=terminal, failureShot=capture_failure), tempfile.TemporaryDirectory() as directory:
                root, work = fixture(directory)
                original = (work / 'safe-outcome.json').read_bytes()
                with mock.patch.object(helper, 'ROOT', root), \
                        mock.patch.object(helper, 'verify_receipt', return_value=RECEIPT_HASH):
                    helper.native_test_start_record(work, EXPECTED)
                    (work / 'test.log').write_text('\n'.join(log_rows(terminal, capture_failure=capture_failure)))
                    receipt_hash, selected = helper.failure_evidence_context(work, EXPECTED)
                expected_name = helper.CAPTURE_FAILURE_SHOT_NAME if capture_failure else 'mirror-adaptive-max-capture-1'
                self.assertEqual((receipt_hash, selected), (RECEIPT_HASH, {expected_name: CASE}))
                self.assertEqual((work / 'safe-outcome.json').read_bytes(), original)
                self.assertFalse((work / 'review').exists())

    def test_fallback_rejects_unowned_incomplete_or_successful_logs_and_unconfirmed_start(self):
        kinds = ('missingStart', 'wrongHash', 'wrongAttempt', 'partialStart', 'symlinkStart', 'passed', 'skipped',
                 'noCase', 'foreignOwner', 'missingConfig', 'incompleteRecord', 'missingSource', 'captureInterrupted')
        for kind in kinds:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root, work = fixture(directory)
                start = work / 'native-test-start.json'
                start.write_text(json.dumps(start_value()))
                rows = log_rows(kind if kind in ('passed', 'skipped') else 'failed')
                if kind == 'missingStart':
                    start.unlink()
                elif kind in ('wrongHash', 'wrongAttempt'):
                    changes = {'buildReceiptSHA256': 'c' * 64} if kind == 'wrongHash' else {'runAttempt': '2'}
                    start.write_text(json.dumps(start_value(**changes)))
                elif kind == 'partialStart':
                    start.write_text('{')
                elif kind == 'symlinkStart':
                    start.rename(root / 'copied-start.json')
                    start.symlink_to(root / 'copied-start.json')
                elif kind == 'noCase':
                    rows = ['no owned native case']
                elif kind == 'foreignOwner':
                    rows = [row.replace('MirrorIOSAdaptiveUITests.', 'ForeignBundle.') for row in rows]
                elif kind == 'missingConfig':
                    rows = [row for row in rows if not row.startswith(helper.CONFIG_MARKER)]
                elif kind == 'incompleteRecord':
                    rows = rows[:-2] + rows[-1:]
                elif kind == 'missingSource':
                    (root / helper.UI_FAILURE_SOURCE_FILE).unlink()
                elif kind == 'captureInterrupted':
                    rows = log_rows(None, capture_failure=True)
                (work / 'test.log').write_text('\n'.join(rows))
                original = (work / 'safe-outcome.json').read_bytes()
                with mock.patch.object(helper, 'ROOT', root), \
                        mock.patch.object(helper, 'verify_receipt', return_value=RECEIPT_HASH), self.assertRaises(ERRORS):
                    helper.failure_evidence_context(work, EXPECTED)
                self.assertEqual((work / 'safe-outcome.json').read_bytes(), original)
                self.assertFalse((work / 'failure-review').exists())

    def test_summary_verifies_optional_start_before_publication_and_keeps_legacy_outcome(self):
        with tempfile.TemporaryDirectory() as directory:
            root, work = fixture(directory)
            original = (work / 'safe-outcome.json').read_bytes()
            with mock.patch.object(helper, 'ROOT', root), \
                    mock.patch.object(helper, 'verify_receipt', return_value=RECEIPT_HASH) as receipt:
                helper.outcome_verify(work, EXPECTED)
                receipt.assert_not_called()
                (work / 'native-test-start.json').write_text(json.dumps(start_value()))
                helper.outcome_verify(work, EXPECTED)
                receipt.assert_called_once_with(work, EXPECTED)
                # 시작 직전 경계만 뜻하므로 log/result 부재는 요약 영수증 검증을 바꾸지 않는다.
                self.assertFalse((work / 'test.log').exists())
                self.assertFalse((work / 'UI.xcresult').exists())
            self.assertEqual((work / 'safe-outcome.json').read_bytes(), original)
        for kind in ('extra', 'wrongHash', 'wrongAttempt', 'partial', 'symlink', 'dangling', 'changedBuild'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root, work = fixture(directory)
                path = work / 'native-test-start.json'
                changes = {'extra': 'untrusted'} if kind == 'extra' else (
                    {'buildReceiptSHA256': 'c' * 64} if kind == 'wrongHash' else
                    {'runAttempt': '2'} if kind == 'wrongAttempt' else {})
                path.write_text('{' if kind == 'partial' else json.dumps(start_value(**changes)))
                if kind in ('symlink', 'dangling'):
                    target = root / 'start-copy.json'
                    path.rename(target)
                    if kind == 'dangling':
                        target.unlink()
                    path.symlink_to(target)
                with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'verify_receipt',
                        return_value=RECEIPT_HASH, side_effect=helper.AdaptiveError('buildReceiptMismatch')
                        if kind == 'changedBuild' else None), self.assertRaises(ERRORS):
                    helper.outcome_verify(work, EXPECTED)


if __name__ == '__main__':
    unittest.main()
