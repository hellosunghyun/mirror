"""첫 captureSave 실패 PNG의 source·receipt·marker·manifest 결합. Actions에서 실행한다."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock
import zlib

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('adaptive_capture_failure_png', ROOT / 'scripts/ci-adaptive-ui-results.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
CASE = helper.CAPTURE_FAILURE_CASE
NAME = helper.CAPTURE_FAILURE_SHOT_NAME
EXPECTED = {'platform': 'iphone', 'appearance': 'system', 'commitSHA': 'a' * 40,
            'buildNumber': '23', 'runID': '34', 'runAttempt': '1'}
PRIVATE = 'SYNTHETIC_PRIVATE_ATTACHMENT_METADATA'


def source_fixture():
    return ('final class MirrorAdaptiveUITests: XCTestCase {\n'
            + ''.join('    func ' + case + '() throws {\n    }\n' for case in helper.CASES) + '}\n')


def entries():
    return helper.source_method_entries(source_fixture(), EXPECTED['platform'])


def event(state):
    return "Test Case '-[MirrorIOSAdaptiveUITests.MirrorAdaptiveUITests " + CASE + "]' " + state + '.'


def line(marker, value):
    return marker + json.dumps(value)


def observed_failure(**changes):
    return {'schemaVersion': 1, 'case': 'captureValidation', 'requestSequence': 1,
            'requestedElement': 'captureSave', 'boundary': 'assertVisible', 'exists': True,
            'enabled': True, 'hittable': False, 'windowOwnerCount': 1, 'ownerHasCaptureClose': True,
            'scrollCandidateCount': 0, 'scrollOwnerCount': 0, 'frame': [10, 20, 100, 44],
            'viewport': None, **changes}


def complete(**changes):
    return {'schemaVersion': 1, 'case': 'captureValidation', 'requestSequence': 1,
            'name': NAME, 'status': 'complete', **changes}


def log_rows(*, terminal='failed', failure=None, completion=None, through=6):
    rows = [event('started'), line(helper.CASE_DIAGNOSTIC_MARKER,
            {'schemaVersion': 1, 'case': 'captureValidation', 'requestSequence': 0, 'requestedElement': None})]
    for sequence, (phase, step) in enumerate(helper.PROGRESS_PROTOCOL[CASE][:through], 1):
        rows.append(line(helper.PROGRESS_MARKER, {'method': CASE + '()', 'phase': phase,
                                                'sequence': sequence, 'step': step}))
        if phase == 'launchComplete':
            rows.append(line(helper.CONFIG_MARKER, helper.configuration(EXPECTED, CASE)))
    rows.extend((line(helper.CASE_DIAGNOSTIC_MARKER,
                     {'schemaVersion': 1, 'case': 'captureValidation', 'requestSequence': 1, 'requestedElement': 'captureSave'}),
                 line(helper.CAPTURE_SAVE_FAILURE_MARKER, observed_failure() if failure is None else failure),
                 line(helper.CAPTURE_FAILURE_SHOT_MARKER, complete() if completion is None else completion)))
    if terminal is not None:
        rows.append(event(terminal))
    return rows


def exported(human=NAME, **changes):
    return [{'testName': PRIVATE, 'testIdentifierURL': '/private/' + PRIVATE, 'attachments': [
        {'suggestedHumanReadableName': human, 'exportedFileName': 'capture-failure.png',
         'uniformTypeIdentifier': 'public.png', **changes}]}]


def png():
    return (helper.SIGNATURE + helper.chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0))
            + helper.chunk(b'tEXt', b'Comment\0' + PRIVATE.encode()) + helper.chunk(b'eXIf', PRIVATE.encode())
            + helper.chunk(b'IDAT', zlib.compress(b'\0\xff\x00\x00\xff')) + helper.chunk(b'IEND', b''))


def evidence_fixture(directory):
    root = Path(directory).resolve()
    source = root / helper.UI_FAILURE_SOURCE_FILE
    source.parent.mkdir(parents=True)
    source.write_text(source_fixture())
    (root / 'test.log').write_text('\n'.join(log_rows()))
    outcome = {**EXPECTED, 'phase': 'test', 'status': 'failed', 'commandExitCode': 65, 'xcodebuildExitCode': 65}
    (root / 'safe-outcome.json').write_text(json.dumps(outcome))
    attachments = root / 'failure-attachments'
    attachments.mkdir()
    (attachments / 'manifest.json').write_text(json.dumps(exported()))
    (attachments / 'capture-failure.png').write_bytes(png())
    return root


class CaptureFailurePNGTests(unittest.TestCase):
    def test_only_owned_pre_record_failure_with_completed_attachment_selects_one_image(self):
        for boundary in ('assertVisible', 'reveal'):
            with self.subTest(boundary=boundary):
                log = '\n'.join(log_rows(failure=observed_failure(boundary=boundary)))
                reports = helper.xctest_case_diagnostics(log, EXPECTED, entries())
                self.assertEqual(reports[0]['captureSaveFailure']['boundary'], boundary)
                self.assertEqual(helper.failure_recorded_screenshots(log, EXPECTED, entries()), {NAME: CASE})
        self.assertIsNone(helper.SHOT_PATTERN.fullmatch(NAME))
        with self.assertRaises(helper.AdaptiveError):
            helper.attachment_name(NAME)

    def test_incomplete_duplicate_reordered_or_unowned_markers_never_select_a_png(self):
        rows = log_rows()
        marker = rows[-2]
        invalid = [rows[:-2] + rows[-1:], rows[:-3] + rows[-2:], rows[:-3] + [marker, rows[-3], rows[-1]],
                   rows[:-1] + [marker, rows[-1]], rows[:-2] + [rows[-1], marker],
                   [value for value in rows if not value.startswith(helper.CONFIG_MARKER)],
                   [value.replace('MirrorIOSAdaptiveUITests.', 'ForeignBundle.') for value in rows],
                   log_rows(through=5), log_rows(terminal='passed'), log_rows(terminal='skipped'),
                   log_rows(terminal=None)]
        for changed in ({'schemaVersion': True}, {'requestSequence': True}, {'requestSequence': 2},
                        {'case': 'plannedCapture'}, {'name': 'mirror-adaptive-max-capture-1'},
                        {'status': 'started'}, {PRIVATE: PRIVATE}):
            invalid.append(log_rows(completion=complete(**changed)))
        for changed in ({'exists': False, 'enabled': None, 'hittable': None},
                        {'windowOwnerCount': 2, 'ownerHasCaptureClose': None}, {'ownerHasCaptureClose': False},
                        {'requestedElement': 'captureTitle'}, {'requestSequence': 2}):
            invalid.append(log_rows(failure=observed_failure(**changed)))
        invalid.append([value.replace(helper.CAPTURE_FAILURE_SHOT_MARKER,
                                      'SDK prefix ' + helper.CAPTURE_FAILURE_SHOT_MARKER) for value in rows])
        for index, changed in enumerate(invalid):
            with self.subTest(index=index), self.assertRaises(helper.AdaptiveError):
                helper.failure_recorded_screenshots('\n'.join(changed), EXPECTED, entries())

    def test_exact_failure_name_and_existing_sdk_alias_keep_manifest_path_and_type_checks(self):
        alias = NAME + '_1_AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.png'
        for name in (NAME, NAME + '.png', alias):
            with self.subTest(name=name):
                self.assertEqual(helper.failure_export_entries(exported(name), {NAME: CASE}),
                                 [(CASE, NAME, 'capture-failure.png')])
        for changed in ({'exportedFileName': '../outside.png'}, {'exportedFileName': '/private/outside.png'},
                        {'uniformTypeIdentifier': 'public.jpeg'}, {'name': PRIVATE}):
            with self.subTest(changed=changed), self.assertRaises(helper.AdaptiveError):
                helper.failure_export_entries(exported(**changed), {NAME: CASE})
        for name in (NAME + '-2', NAME + '_1_bad.png', 'Screenshot'):
            with self.subTest(name=name), self.assertRaises(helper.AdaptiveError):
                helper.failure_export_entries(exported(name), {NAME: CASE})
        duplicate = exported()
        duplicate[0]['attachments'] *= 2
        for manifest in (duplicate, [{'attachments': []}]):
            with self.assertRaises(helper.AdaptiveError):
                helper.failure_export_entries(manifest, {NAME: CASE})
        with_system = exported()
        with_system[0]['attachments'].append({'name': PRIVATE, 'exportedFileName': '../' + PRIVATE,
                                            'uniformTypeIdentifier': PRIVATE})
        self.assertEqual(helper.failure_export_entries(with_system, {NAME: CASE}), [(CASE, NAME, 'capture-failure.png')])

    def test_failure_manifest_preserves_receipt_and_outcome_and_strips_private_png_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = evidence_fixture(directory)
            before = (root / 'safe-outcome.json').read_bytes()
            with mock.patch.object(helper, 'ROOT', root), \
                    mock.patch.object(helper, 'verify_receipt', return_value='b' * 64) as receipt, \
                    mock.patch('builtins.print') as printed:
                helper.failure_evidence(root, EXPECTED)
            receipt.assert_called_once_with(root, EXPECTED)
            review = root / 'failure-review'
            manifest = json.loads((review / 'manifest.json').read_text())
            shot, = manifest['screenshots']
            self.assertEqual((shot['case'], shot['stage'], shot['sequence']), (CASE, 'failure-capture-save', 1))
            self.assertEqual(manifest['buildReceiptSHA256'], 'b' * 64)
            self.assertEqual(manifest['kind'], 'adaptive-failure-diagnostic')
            self.assertEqual(manifest['semantics'], 'diagnosticOnlyNotAcceptanceOrAuditCause')
            cleaned = (review / shot['file']).read_bytes()
            self.assertEqual(cleaned, helper.clean_png(png())[0])
            self.assertEqual(shot['sha256'], helper.digest(cleaned))
            self.assertEqual(shot['exportSHA256'], helper.digest(png()))
            self.assertNotIn(PRIVATE.encode(), cleaned)
            public = json.dumps(manifest) + printed.call_args[0][0]
            for forbidden in (PRIVATE, str(root), 'testName', 'testIdentifier', 'passedTests', 'failedTests'):
                self.assertNotIn(forbidden, public)
            self.assertEqual((root / 'safe-outcome.json').read_bytes(), before)
            self.assertFalse((root / 'review').exists())
            self.assertEqual({path.name for path in review.iterdir()}, {'manifest.json', 'SHA256SUMS', 'screenshots'})
            with self.assertRaises(helper.AdaptiveError):
                helper.validate_outcome(manifest, EXPECTED)

    def test_success_build_source_receipt_and_png_failures_do_not_create_partial_review(self):
        for kind in ('success', 'build', 'source', 'receipt', 'png', 'symlink', 'missingMarker'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = evidence_fixture(directory)
                if kind in ('success', 'build'):
                    outcome = json.loads((root / 'safe-outcome.json').read_text())
                    if kind == 'build':
                        outcome['phase'] = 'build'
                    else:
                        count = len(helper.required_cases(EXPECTED['platform']))
                        outcome.update(status='passed', commandExitCode=0, xcodebuildExitCode=0,
                                       totalTestCount=count, passedTests=count, failedTests=0, skippedTests=0,
                                       screenshotCount=sum(len(helper.CASES[case]) for case in helper.required_cases(EXPECTED['platform'])))
                    (root / 'safe-outcome.json').write_text(json.dumps(outcome))
                if kind == 'source':
                    (root / helper.UI_FAILURE_SOURCE_FILE).unlink()
                if kind == 'png':
                    (root / 'failure-attachments/capture-failure.png').write_bytes(b'invalid PNG')
                if kind == 'symlink':
                    image = root / 'failure-attachments/capture-failure.png'
                    image.rename(root / 'original.png')
                    image.symlink_to(root / 'original.png')
                if kind == 'missingMarker':
                    (root / 'test.log').write_text('\n'.join(value for value in log_rows()
                        if not value.startswith(helper.CAPTURE_FAILURE_SHOT_MARKER)))
                with mock.patch.object(helper, 'ROOT', root), mock.patch.object(helper, 'verify_receipt',
                        side_effect=helper.AdaptiveError('buildReceiptMismatch') if kind == 'receipt' else None,
                        return_value='b' * 64), self.assertRaises(helper.AdaptiveError):
                    helper.failure_evidence(root, EXPECTED)
                self.assertFalse((root / 'failure-review').exists())


if __name__ == '__main__':
    unittest.main()
