"""UI·저장 결과 진단의 비공개 값 제외·기존 통과 게이트 회귀. Actions에서 실행한다."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_ci_results_diagnostics', ROOT / 'scripts/ci_results.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
PRIVATE = 'SYNTHETIC_PRIVATE_TIMING_INPUT'
METHODS = (
    'testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday',
    'testExplicitCompletionAndUndoPreserveEditedTitleAndPlan',
    'testOverlongTitleShowsErrorAndPreservesEveryCharacter',
    'testReviewUndoRestoresUnassignedCardInsteadOfAddingToToday',
    'testTomorrowStaysOutOfTodayAndIsSearchableInLibrary',
    'testWeekPanelCancellationAndPartialFinishPreserveUndecidedPlan',
)
STAGES = (
    'initial-today', 'calendar', 'settings', 'capture-form', 'review-card', 'week-picker', 'today-populated',
    'library', 'library-search', 'detail', 'detail-edit', 'completion', 'undo', 'validation-error', 'ipad-landscape',
)
CASE_NOTICE = '::notice::UI case timing: '
SCREENSHOT_NOTICE = '::notice::UI screenshot timing: '
STORE_DEDUP_NOTICE = '::notice::Store dedup result diagnostic: '
STORE_DEDUP_REJECTED_NOTICE = '::notice::Store dedup result diagnostic rejected: '
UI_FIRST_FAILURE_NOTICE = '::notice::UI first failure: '
UI_FIRST_FAILURE_REJECTED_NOTICE = '::notice::UI first failure rejected: '
UI_VIEWPORT_NOTICE = '::notice::UI viewport diagnostic: '
UI_VIEWPORT_REJECTED_NOTICE = '::notice::UI viewport diagnostic rejected: '
UI_KEYBOARD_NOTICE = '::notice::UI keyboard introduction diagnostic: '
UI_KEYBOARD_REJECTED_NOTICE = '::notice::UI keyboard introduction diagnostic rejected: '
UI_PHASE_NOTICE = '::notice::UI test phase diagnostic: '
UI_PHASE_REJECTED_NOTICE = '::notice::UI test phase diagnostic rejected: '
UI_NATIVE_SCREENSHOT_NOTICE = '::notice::UI native screenshot diagnostic: '
UI_NATIVE_SCREENSHOT_REJECTED_NOTICE = '::notice::UI native screenshot diagnostic rejected: '
PHASE_METHOD = METHODS[4]
NATIVE_SCREENSHOT_METHOD = METHODS[0]
PHASES = (
    'started', 'launched', 'captured', 'reviewOpened', 'tomorrowAssigned', 'reviewClosed',
    'todayExcluded', 'searchNavigationRequested', 'searchReady', 'searchEntered',
    'futureRowVerified', 'searchTitleVerified', 'libraryScreenshotRecorded', 'detailOpened',
    'detailPlanVerified', 'detailScreenshotRecorded', 'detailClosed', 'todayRechecked', 'complete',
)


def case_line(method=METHODS[0], event='passed', seconds='12.345', module='MirrorIOSUITests'):
    # 실제 iPad Actions 로그의 XCTest 완료 줄에는 마지막 마침표가 있다.
    return f"Test Case '-[{module}.MirrorUITests {method}]' {event} ({seconds} seconds)."


def screenshot_line(stage='week-picker', milliseconds='123'):
    return f'UI screenshot timing: stage={stage},milliseconds={milliseconds}'


def store_dedup_line(payload=None):
    if payload is None:
        payload = {'states': ['locallyCommitted', 'unavailable'], 'busyResults': [False, True]}
    return 'Store dedup result diagnostic: ' + json.dumps(payload)


def ui_failure_line(method=METHODS[0], source='Tests/MirrorUITests/MirrorUITests.swift',
                    line='475', kind='XCTAssertTrue', explicit=True):
    assertion = 'failed -' if kind == 'XCTFail' else kind + ' failed -'
    owner = f'-[MirrorIOSUITests.MirrorUITests {method}] : ' if explicit else ''
    return f'{source}:{line}: error: {owner}{assertion} expected/actual=/private/{PRIVATE}'


def viewport_line(payload):
    return 'UI viewport diagnostic: ' + json.dumps(payload)


def keyboard_line(payload):
    return 'UI keyboard introduction diagnostic: ' + json.dumps(payload)


def phase_line(payload):
    return 'UI test phase diagnostic: ' + json.dumps(payload)


def native_screenshot_line(payload):
    return 'UI native screenshot diagnostic: ' + json.dumps(payload)


def started_line(method, owner='MirrorIOSUITests.MirrorUITests'):
    return f"Test Case '-[{owner} {method}]' started."


def native_screenshot_payload():
    return {'method': NATIVE_SCREENSHOT_METHOD, 'stage': 'ipad-landscape', 'orientation': 'left',
            'imageWidth': 1376.0, 'imageHeight': 1032.0, 'imageScale': 2.0,
            'cgImageWidth': 2752, 'cgImageHeight': 2064, 'pngSHA256': 'a' * 64}


class CIResultsDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def capture(self, operation, *arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            operation(*arguments)
        self.assertEqual(stderr.getvalue(), '')
        output = stdout.getvalue()
        self.assertNotIn(PRIVATE, output)
        return output

    def notices(self, output, prefix):
        return [json.loads(line[len(prefix):]) for line in output.splitlines() if line.startswith(prefix)]

    def test_phase_diagnostic_accepts_actual_unique_case_and_only_ordered_prefixes(self):
        log = self.root / 'phase-prefix.log'
        self.assertEqual(helper.UI_PHASE_NAMES, PHASES)
        for owner in ('MirrorUITests', 'MirrorIOSUITests.MirrorUITests', 'MirrorMacUITests.MirrorUITests'):
            for length in range(1, len(PHASES) + 1):
                with self.subTest(owner=owner, length=length):
                    payloads = [{'method': PHASE_METHOD, 'phase': phase} for phase in PHASES[:length]]
                    log.write_text('\n'.join([started_line(PHASE_METHOD, owner)]
                                             + ['fatal: /private/' + PRIVATE + ' ' + phase_line(payload)
                                                for payload in payloads]
                                             + [case_line(PHASE_METHOD, event='failed')]) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    self.assertEqual(self.notices(output, UI_PHASE_NOTICE),
                                     [{'scope': 'stdoutOnly', **payload} for payload in payloads])
                    self.assertEqual(self.notices(output, UI_PHASE_REJECTED_NOTICE), [])
                    self.assertNotIn('/private/', output)
                    self.assertNotIn('::error::', output)

    def test_phase_diagnostic_rejects_ambiguous_finished_foreign_and_forged_active_cases(self):
        valid = {'method': PHASE_METHOD, 'phase': 'started'}
        prefixes = [[], [started_line(METHODS[0])], [started_line(PHASE_METHOD, 'OtherTests')],
                    [started_line(PHASE_METHOD), started_line(METHODS[0])],
                    [started_line(PHASE_METHOD), case_line(PHASE_METHOD)],
                    [started_line(PHASE_METHOD), "Test Case '-[broken]' started."],
                    [phase_line({**valid, 'private': started_line(PHASE_METHOD) + PRIVATE})]]
        log = self.root / 'phase-active.log'
        for prefix in prefixes:
            with self.subTest(prefix=prefix):
                log.write_text('\n'.join(prefix + [phase_line(valid)]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_PHASE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_PHASE_REJECTED_NOTICE),
                                 [{'invalidCount': 2 if len(prefix) == 1 and prefix[0].startswith('UI test') else 1}])
        # 다른 실제 사례가 끝난 뒤 유일한 대상 사례의 prefix는 계속 진단할 수 있다.
        log.write_text('\n'.join([started_line(PHASE_METHOD), started_line(METHODS[0]),
                                  case_line(METHODS[0]), phase_line(valid)]) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_PHASE_NOTICE), [{'scope': 'stdoutOnly', **valid}])

    def test_phase_diagnostic_rejects_wrong_order_duplicate_schema_and_byte_limit_as_whole_transcript(self):
        valid = {'method': PHASE_METHOD, 'phase': 'started'}
        invalid_payloads = [{**valid, 'phase': value} for value in (PRIVATE, 'complete', None, True, 1, [], {})]
        invalid_payloads += [{**valid, 'method': value} for value in (METHODS[0], PRIVATE, None, True, [], {})]
        invalid_payloads += [{**valid, 'private': PRIVATE}, {'phase': 'started'},
                             {'method': PHASE_METHOD}, [], None]
        log = self.root / 'phase-invalid.log'
        for payload in invalid_payloads:
            with self.subTest(payload=payload):
                log.write_text('\n'.join([started_line(PHASE_METHOD), phase_line(payload)]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_PHASE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_PHASE_REJECTED_NOTICE), [{'invalidCount': 1}])
        bad_lines = [phase_line(valid), phase_line({**valid, 'phase': 'captured'}),
                     phase_line({'method': PHASE_METHOD, 'phase': 'launched', 'private': PRIVATE}),
                     phase_line(valid) + ' error: ' + PRIVATE,
                     phase_line(valid) + ' UI test phase diagnostic: ' + PRIVATE,
                     'UI test phase diagnostic: {' + PRIVATE,
                     'UI test phase diagnostic: ' + '[' * 1500 + '0' + ']' * 1500,
                     'UI test phase diagnostic: {"method":"' + PHASE_METHOD + '","phase":"'
                     + PRIVATE + '","phase":"launched"}']
        for bad in bad_lines:
            with self.subTest(bad=bad):
                log.write_text('\n'.join([started_line(PHASE_METHOD), phase_line(valid), bad]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_PHASE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_PHASE_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertNotIn('::error::', output)
        over_limit = json.dumps({**valid, 'private': PRIVATE + '한' * 1400}, ensure_ascii=False)
        self.assertLess(len(over_limit), 4096)
        self.assertGreater(len(over_limit.encode('utf-8')), 4096)
        with mock.patch.object(helper.json, 'loads', side_effect=AssertionError('over-limit payload parsed')):
            output = self.capture(helper.report_ui_phase_diagnostics,
                                  [started_line(PHASE_METHOD), 'UI test phase diagnostic: ' + over_limit])
        self.assertEqual(self.notices(output, UI_PHASE_REJECTED_NOTICE), [{'invalidCount': 1}])

    def test_native_screenshot_diagnostic_accepts_fixed_orientation_and_actual_numeric_boundaries(self):
        log = self.root / 'native-valid.log'
        orientations = {'up', 'down', 'left', 'right', 'upMirrored', 'downMirrored', 'leftMirrored', 'rightMirrored'}
        self.assertEqual(helper.UI_IMAGE_ORIENTATIONS, orientations)
        for orientation in orientations:
            for size, scale, pixel in ((0.01, 0.01, 1), (1, 1, 1), (16384.0, 8.0, 16384)):
                with self.subTest(orientation=orientation, size=size, scale=scale):
                    payload = {**native_screenshot_payload(), 'orientation': orientation,
                               'imageWidth': size, 'imageHeight': size, 'imageScale': scale,
                               'cgImageWidth': pixel, 'cgImageHeight': pixel}
                    log.write_text('\n'.join([started_line(NATIVE_SCREENSHOT_METHOD),
                                              'fatal: /private/' + PRIVATE + ' ' + native_screenshot_line(payload),
                                              case_line(NATIVE_SCREENSHOT_METHOD)]) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_NOTICE),
                                     [{'scope': 'stdoutOnly', **payload}])
                    self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_REJECTED_NOTICE), [])
                    self.assertNotIn('/private/', output)
                    self.assertNotIn('::error::', output)

    def test_native_screenshot_diagnostic_rejects_unknown_schema_nonfinite_bool_and_private_hash(self):
        valid = native_screenshot_payload()
        invalid = []
        for key, upper in (('imageWidth', 16384), ('imageHeight', 16384), ('imageScale', 8)):
            invalid += [{**valid, key: value} for value in
                        (0, -1, upper + 0.001, True, False, '1', None, [], {},
                         float('nan'), float('inf'), float('-inf'), 10 ** 400)]
        for key in ('cgImageWidth', 'cgImageHeight'):
            invalid += [{**valid, key: value} for value in (0, -1, 16385, True, False, 1.0, '1', None, [], {})]
        invalid += [{**valid, 'orientation': value} for value in (PRIVATE, 'unknown', None, True, [], {})]
        invalid += [{**valid, 'pngSHA256': value} for value in
                    ('A' * 64, 'a' * 63, 'a' * 65, 'g' * 64, PRIVATE, 'a' * 64 + '\n', None, True, [], {})]
        invalid += [{**valid, 'method': PHASE_METHOD}, {**valid, 'stage': 'calendar'},
                    {**valid, 'private': PRIVATE}, {key: value for key, value in valid.items() if key != 'imageScale'},
                    [], None]
        log = self.root / 'native-invalid.log'
        for payload in invalid:
            with self.subTest(payload=payload):
                log.write_text('\n'.join([started_line(NATIVE_SCREENSHOT_METHOD), native_screenshot_line(payload)]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_NOTICE), [])
                self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertNotIn('::error::', output)

    def test_native_screenshot_diagnostic_requires_unique_active_case_and_rejects_duplicate_or_malformed_transcript(self):
        valid = native_screenshot_payload()
        log = self.root / 'native-transcript.log'
        prefixes = [[], [started_line(PHASE_METHOD)], [started_line(NATIVE_SCREENSHOT_METHOD, 'OtherTests')],
                    [started_line(NATIVE_SCREENSHOT_METHOD), started_line(PHASE_METHOD)],
                    [started_line(NATIVE_SCREENSHOT_METHOD), case_line(NATIVE_SCREENSHOT_METHOD)],
                    [started_line(NATIVE_SCREENSHOT_METHOD), "Test Case '-[broken]' started."]]
        for prefix in prefixes:
            with self.subTest(prefix=prefix):
                log.write_text('\n'.join(prefix + [native_screenshot_line(valid)]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_NOTICE), [])
                self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_REJECTED_NOTICE), [{'invalidCount': 1}])
        malformed = [native_screenshot_line(valid), native_screenshot_line(valid) + ' error: ' + PRIVATE,
                     native_screenshot_line(valid) + ' UI native screenshot diagnostic: ' + PRIVATE,
                     'UI native screenshot diagnostic: {' + PRIVATE,
                     'UI native screenshot diagnostic: ' + '[' * 1500 + '0' + ']' * 1500,
                     native_screenshot_line(valid).replace('"orientation": "left"',
                                                           '"orientation":"' + PRIVATE + '","orientation":"left"')]
        for bad in malformed:
            with self.subTest(bad=bad):
                log.write_text('\n'.join([started_line(NATIVE_SCREENSHOT_METHOD), native_screenshot_line(valid), bad]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_NOTICE), [])
                self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_REJECTED_NOTICE), [{'invalidCount': 1}])
        over_limit = json.dumps({**valid, 'private': PRIVATE + '한' * 1400}, ensure_ascii=False)
        self.assertLess(len(over_limit), 4096)
        self.assertGreater(len(over_limit.encode('utf-8')), 4096)
        with mock.patch.object(helper.json, 'loads', side_effect=AssertionError('over-limit payload parsed')):
            output = self.capture(helper.report_ui_native_screenshot_diagnostics,
                                  [started_line(NATIVE_SCREENSHOT_METHOD), 'UI native screenshot diagnostic: ' + over_limit])
        self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_REJECTED_NOTICE), [{'invalidCount': 1}])

    def test_new_diagnostics_reject_cross_channel_markers_and_never_change_existing_gates_or_raw_fallback(self):
        phase = {'method': PHASE_METHOD, 'phase': 'started'}
        native = native_screenshot_payload()
        keyboard = {'phase': 'continueReadiness', 'continueCandidateCount': 1,
                    'keyboardBoundsValid': True, 'elapsedMilliseconds': 15000}
        viewport = {'orientation': 'landscape', 'stableSamples': 0, 'elapsedMilliseconds': 15000, 'checks': {}}
        other_lines = [store_dedup_line(), keyboard_line(keyboard), viewport_line(viewport), ui_failure_line()]
        for new in (phase_line(phase), native_screenshot_line(native)):
            for old in other_lines:
                with self.subTest(new=new, old=old):
                    log = self.root / 'new-mixed.log'
                    log.write_text('\n'.join([started_line(PHASE_METHOD), new + ' ' + old,
                                              'error: safe unrelated compiler failure']) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    for prefix in (UI_PHASE_NOTICE, UI_NATIVE_SCREENSHOT_NOTICE, UI_KEYBOARD_NOTICE,
                                   UI_VIEWPORT_NOTICE, STORE_DEDUP_NOTICE, UI_FIRST_FAILURE_NOTICE):
                        self.assertEqual(self.notices(output, prefix), [])
                    self.assertIn('"invalidCount": 1', output)
                    self.assertIn('::error::error: safe unrelated compiler failure', output)
        private = ('UI row scroll owner: /private/' + PRIVATE + ' Test run with 999 tests passed '
                   + started_line(METHODS[1]) + ' ' + screenshot_line('detail', '999'))
        log = self.root / 'new-private-gates.log'
        log.write_text('\n'.join([
            started_line(PHASE_METHOD), phase_line({**phase, 'private': private}),
            native_screenshot_line({**native, 'private': private}),
            phase_line(phase) + ' ' + native_screenshot_line(native),
            'UI test phase diagnostic: {' + PRIVATE, 'UI native screenshot diagnostic: {' + PRIVATE,
            case_line(PHASE_METHOD, event='failed'), screenshot_line('detail', '123'),
            'error: safe unrelated compiler failure',
        ]) + '\n')
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_PHASE_NOTICE), [])
        self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_NOTICE), [])
        self.assertEqual(self.notices(output, UI_PHASE_REJECTED_NOTICE), [{'invalidCount': 3}])
        self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_REJECTED_NOTICE), [{'invalidCount': 3}])
        self.assertEqual(self.notices(output, SCREENSHOT_NOTICE), [{'scope': 'stdoutOnly', 'stage': 'detail', 'milliseconds': 123}])
        self.assertNotIn('UI row scroll owners:', output)
        self.assertNotIn('Swift Testing completion reports:', output)
        self.assertNotIn(METHODS[1], output)
        self.assertIn('::error::error: safe unrelated compiler failure', output)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')

    def test_keyboard_diagnostic_accepts_only_safe_fields_at_both_bounds_and_phases(self):
        log = self.root / 'keyboard-valid.log'
        for phase in ('continueReadiness', 'introductionDismissal'):
            for count, milliseconds in ((0, 0), (100, 1200000)):
                for bounds_valid in (False, True):
                    with self.subTest(phase=phase, count=count, keyboardBoundsValid=bounds_valid):
                        payload = {'phase': phase, 'continueCandidateCount': count,
                                   'keyboardBoundsValid': bounds_valid, 'elapsedMilliseconds': milliseconds}
                        log.write_text('fatal: /private/' + PRIVATE + ' ' + keyboard_line(payload) + '\n')
                        output = self.capture(helper.diagnostics, log)
                        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [{'scope': 'stdoutOnly', **payload}])
                        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [])
                        self.assertNotIn('/private/', output)
                        self.assertNotIn('::error::', output)

    def test_extended_keyboard_diagnostic_preserves_actual_decreasing_counts_and_old_schema(self):
        log = self.root / 'keyboard-extended-valid.log'
        count_fields = ('continueQueryCount', 'continueExistingCount', 'continueHittableCount',
                        'continueEnabledCount', 'continueInKeyboardCount')
        self.assertEqual(helper.UI_KEYBOARD_COUNT_FIELDS, count_fields)
        for phase in ('continueReadiness', 'introductionDismissal'):
            for counts in ((0, 0, 0, 0, 0), (100, 100, 100, 100, 100), (5, 4, 3, 2, 1), (1, 1, 0, 0, 0)):
                with self.subTest(phase=phase, counts=counts):
                    basic = {'phase': phase, 'continueCandidateCount': counts[-1],
                             'keyboardBoundsValid': True, 'elapsedMilliseconds': 15097}
                    extended = {**basic, **dict(zip(count_fields, counts))}
                    log.write_text('\n'.join([keyboard_line(basic), keyboard_line(extended)]) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE),
                                     [{'scope': 'stdoutOnly', **basic}, {'scope': 'stdoutOnly', **extended}])
                    self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [])
                    self.assertNotIn('::error::', output)

    def test_extended_keyboard_diagnostic_rejects_noninteger_nonmonotonic_mismatch_and_partial_fields(self):
        fields = ('continueQueryCount', 'continueExistingCount', 'continueHittableCount',
                  'continueEnabledCount', 'continueInKeyboardCount')
        valid = {'phase': 'continueReadiness', 'continueCandidateCount': 1,
                 'keyboardBoundsValid': True, 'elapsedMilliseconds': 15097,
                 **dict(zip(fields, (5, 4, 3, 2, 1)))}
        invalid = []
        for key in fields:
            invalid += [{**valid, key: value} for value in (-1, 101, True, False, 1.0, '1', None, [], {})]
            invalid.append({name: value for name, value in valid.items() if name != key})
        for counts in ((1, 2, 1, 1, 1), (3, 2, 3, 1, 1), (4, 3, 2, 3, 1), (5, 4, 3, 2, 3)):
            invalid.append({**valid, **dict(zip(fields, counts))})
        invalid += [{**valid, 'continueCandidateCount': 0}, {**valid, 'continueCandidateCount': 2},
                    {**valid, 'private': PRIVATE}]
        log = self.root / 'keyboard-extended-invalid.log'
        log.write_text('\n'.join(keyboard_line(payload) for payload in invalid) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': len(invalid)}])
        self.assertNotIn('::error::', output)

    def test_extended_keyboard_diagnostic_rejects_duplicate_counts_and_private_mixed_markers(self):
        valid = {'phase': 'continueReadiness', 'continueCandidateCount': 0,
                 'keyboardBoundsValid': True, 'elapsedMilliseconds': 15097,
                 'continueQueryCount': 1, 'continueExistingCount': 1, 'continueHittableCount': 0,
                 'continueEnabledCount': 0, 'continueInKeyboardCount': 0}
        private = ('UI row scroll owner: /private/' + PRIVATE + ' Test run with 999 tests passed '
                   + started_line(METHODS[1]) + ' ' + screenshot_line('detail', '999'))
        lines = [keyboard_line({**valid, 'private': private}),
                 keyboard_line(valid).replace('"continueQueryCount": 1',
                                              '"continueQueryCount":"' + PRIVATE + '","continueQueryCount":1'),
                 keyboard_line(valid) + ' ' + phase_line({'method': PHASE_METHOD, 'phase': 'started'}),
                 keyboard_line(valid) + ' ' + native_screenshot_line(native_screenshot_payload())]
        log = self.root / 'keyboard-extended-private.log'
        log.write_text('\n'.join(lines) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': len(lines)}])
        self.assertEqual(self.notices(output, UI_PHASE_REJECTED_NOTICE), [{'invalidCount': 1}])
        self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_REJECTED_NOTICE), [{'invalidCount': 1}])
        self.assertNotIn('::error::', output)
        self.assertNotIn('UI row scroll owners:', output)
        self.assertNotIn('Swift Testing completion reports:', output)
        self.assertNotIn(METHODS[1], output)

    def test_keyboard_diagnostic_rejects_unknown_phase_wrong_types_and_nonexact_fields(self):
        valid = {'phase': 'continueReadiness', 'continueCandidateCount': 1,
                 'keyboardBoundsValid': True, 'elapsedMilliseconds': 15000}
        invalid = [{**valid, 'phase': value} for value in (PRIVATE, 'unknown', None, True, [])]
        for key, upper in (('continueCandidateCount', 100), ('elapsedMilliseconds', 1200000)):
            invalid += [{**valid, key: value} for value in (-1, upper + 1, True, False, 1.0, '1', None)]
        invalid += [{**valid, 'keyboardBoundsValid': value} for value in (0, 1, 0.0, 'true', None, [], {})]
        invalid += [{**valid, 'private': PRIVATE},
                    {key: value for key, value in valid.items() if key != 'keyboardBoundsValid'}, [], None]
        log = self.root / 'keyboard-invalid.log'
        log.write_text('\n'.join(keyboard_line(payload) for payload in invalid) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': len(invalid)}])
        self.assertNotIn('::error::', output)

    def test_keyboard_diagnostic_rejects_duplicate_malformed_and_over_byte_limit_json(self):
        valid = {'phase': 'introductionDismissal', 'continueCandidateCount': 1,
                 'keyboardBoundsValid': True, 'elapsedMilliseconds': 15000}
        lines = [keyboard_line(valid) + ' error: ' + PRIVATE,
                 keyboard_line(valid) + ' UI keyboard introduction diagnostic: ' + PRIVATE,
                 'UI keyboard introduction diagnostic: {' + PRIVATE,
                 'UI keyboard introduction diagnostic: ' + '[' * 1500 + '0' + ']' * 1500,
                 'UI keyboard introduction diagnostic: {"phase":"' + PRIVATE + '","phase":"continueReadiness",'
                 '"continueCandidateCount":1,"keyboardBoundsValid":true,"elapsedMilliseconds":15000}']
        log = self.root / 'keyboard-malformed.log'
        log.write_text('\n'.join(lines) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': len(lines)}])
        self.assertNotIn('::error::', output)
        over_limit = json.dumps({**valid, 'private': PRIVATE + '한' * 1400}, ensure_ascii=False)
        self.assertLess(len(over_limit), 4096)
        self.assertGreater(len(over_limit.encode('utf-8')), 4096)
        with mock.patch.object(helper.json, 'loads', side_effect=AssertionError('over-limit payload parsed')):
            output = self.capture(helper.report_ui_keyboard_diagnostics,
                                  ['UI keyboard introduction diagnostic: ' + over_limit])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': 1}])

    def test_keyboard_diagnostic_order_mixed_marker_privacy_and_unchanged_gates(self):
        keyboard = {'phase': 'continueReadiness', 'continueCandidateCount': 2,
                    'keyboardBoundsValid': True, 'elapsedMilliseconds': 15000}
        viewport = {'orientation': 'landscape', 'stableSamples': 0, 'elapsedMilliseconds': 16098,
                    'checks': {'columnsSeparate': False}}
        private = ("error: UI row scroll owner: /private/" + PRIVATE
                   + " Test run with 999 tests passed Test Case '-[MirrorIOSUITests.MirrorUITests "
                   + METHODS[1] + "]' started. UI screenshot timing: stage=detail,milliseconds=999")
        log = self.root / 'keyboard-mixed.log'
        log.write_text('\n'.join([
            f"Test Case '-[MirrorIOSUITests.MirrorUITests {METHODS[0]}]' started.",
            ui_failure_line(line='323', kind='XCTAssertEqual'), keyboard_line(keyboard),
            viewport_line(viewport), store_dedup_line(), keyboard_line({**keyboard, 'private': private}),
            keyboard_line(keyboard) + ' ' + store_dedup_line(),
            viewport_line(viewport) + ' ' + keyboard_line(keyboard),
            ui_failure_line(line='324') + ' ' + keyboard_line(keyboard),
            case_line(event='failed'), screenshot_line('detail', '123'), 'error: safe unrelated compiler failure',
        ]) + '\n')
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [{'scope': 'stdoutOnly', **keyboard}])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': 4}])
        self.assertEqual(self.notices(output, UI_VIEWPORT_NOTICE), [{'scope': 'stdoutOnly', **viewport}])
        self.assertEqual(self.notices(output, UI_VIEWPORT_REJECTED_NOTICE), [{'invalidCount': 1}])
        self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [{'invalidCount': 1}])
        self.assertEqual(len(self.notices(output, STORE_DEDUP_NOTICE)), 1)
        self.assertLess(output.index(UI_FIRST_FAILURE_NOTICE), output.index(UI_KEYBOARD_NOTICE))
        self.assertLess(output.index(UI_KEYBOARD_NOTICE), output.index(UI_VIEWPORT_NOTICE))
        self.assertLess(output.index(UI_VIEWPORT_NOTICE), output.index('::notice::UI stdout diagnostics: '))
        self.assertNotIn('UI row scroll owners:', output)
        self.assertNotIn('Swift Testing completion reports:', output)
        self.assertNotIn(METHODS[1], output)
        self.assertIn('::error::error: safe unrelated compiler failure', output)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')

    def test_first_ui_failure_is_safe_first_and_precedes_viewport_events_and_timings(self):
        viewport = {'orientation': 'landscape', 'stableSamples': 2, 'elapsedMilliseconds': 15000,
                    'checks': {'foreground': True, 'windowOrientationMatches': False}}
        log = self.root / 'ui-first.log'
        log.write_text('\n'.join([
            f"Test Case '-[MirrorIOSUITests.MirrorUITests {METHODS[0]}]' started.",
            ui_failure_line(source='/private/' + PRIVATE + '/Tests/MirrorUITests/MirrorUITests.swift', kind='XCTFail'),
            'fatal: /private/' + PRIVATE + ' ' + viewport_line(viewport),
            ui_failure_line(method=METHODS[1], line='110'),
            case_line(event='failed', seconds='35.848'), screenshot_line('calendar', '123'),
        ]) + '\n')
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
            'scope': 'stdoutOnly', 'method': METHODS[0],
            'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 475, 'assertionKind': 'XCTFail',
        }])
        self.assertEqual(self.notices(output, UI_VIEWPORT_NOTICE), [{'scope': 'stdoutOnly', **viewport}])
        self.assertLess(output.index(UI_FIRST_FAILURE_NOTICE), output.index(UI_VIEWPORT_NOTICE))
        self.assertLess(output.index(UI_VIEWPORT_NOTICE), output.index('::notice::UI stdout diagnostics: '))
        self.assertLess(output.index(UI_VIEWPORT_NOTICE), output.index(CASE_NOTICE))
        self.assertNotIn('/private/', output)
        self.assertNotIn('expected/actual', output)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')

    def test_first_ui_failure_uses_only_a_unique_active_case_and_never_a_finished_one(self):
        start = lambda method, owner='MirrorIOSUITests.MirrorUITests': f"Test Case '-[{owner} {method}]' started."
        log = self.root / 'ui-active.log'
        log.write_text('\n'.join([
            start(METHODS[0]), start(METHODS[1]), ui_failure_line(explicit=False, line='100'),
            case_line(METHODS[1]), ui_failure_line(explicit=False, line='101'),
            case_line(METHODS[0], event='failed'), ui_failure_line(explicit=False, line='102'),
        ]) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
            'scope': 'stdoutOnly', 'method': METHODS[0],
            'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 101, 'assertionKind': 'XCTAssertTrue',
        }])
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 2}])
        for prefix in ([], [start('test' + PRIVATE)], [start(METHODS[0], 'OtherTests')],
                       [start(METHODS[0]), case_line(METHODS[0])],
                       [start(METHODS[0]), "Test Case '-[broken]' started."]):
            with self.subTest(prefix=prefix):
                log.write_text('\n'.join(prefix + [ui_failure_line(explicit=False)]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 1}])

    def test_first_ui_failure_accepts_only_source_line_and_assertion_contract(self):
        log = self.root / 'ui-contract.log'
        for source, line in (('MirrorUITests.swift', '1'), ('Tests/MirrorUITests/MirrorUITests.swift', '10000')):
            for kind in helper.UI_ASSERTION_KINDS:
                with self.subTest(source=source, line=line, kind=kind):
                    log.write_text(ui_failure_line(source=source, line=line, kind=kind) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
                        'scope': 'stdoutOnly', 'method': METHODS[0],
                        'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift',
                        'line': int(line), 'assertionKind': kind,
                    }])
        invalid_lines = [ui_failure_line(line=value) for value in ('0', '10001', '-1', '\u0661', '1.5', '1e2', '123456')]
        invalid_lines += [ui_failure_line(source=value) for value in (
            '/private/' + PRIVATE + '/OtherTests.swift', '/private/' + PRIVATE + '/MirrorUITests.swift',
            'Tests/OtherTests/MirrorUITests.swift', 'Tests/MirrorUITests/MirrorUITests.swift.backup')]
        invalid_lines += [ui_failure_line(kind='XCTAssert' + PRIVATE), ui_failure_line(method='test' + PRIVATE),
                          ui_failure_line().replace('.MirrorUITests ', '.OtherTests ')]
        log.write_text('\n'.join(invalid_lines) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [])
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': len(invalid_lines)}])
        self.assertNotIn('::error::', output)

    def test_ui_assertion_filter_preserves_real_swift_compiler_error_in_the_same_source(self):
        line = "Tests/MirrorUITests/MirrorUITests.swift:12:5: error: cannot find 'SyntheticCompilerAPI' in scope"
        log = self.root / 'ui-compile.log'
        log.write_text(line + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertIn('::error::' + line, output)
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [])
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [])

    def test_viewport_preserves_sparse_checks_and_exact_numeric_boundaries(self):
        log = self.root / 'viewport-valid.log'
        for orientation in ('portrait', 'landscape'):
            for samples, milliseconds in ((0, 0), (10000, 1200000)):
                for checks in ({}, {'foreground': True, 'insideDeadline': False},
                               {name: True for name in helper.UI_VIEWPORT_CHECK_NAMES}):
                    with self.subTest(orientation=orientation, checks=checks):
                        payload = {'orientation': orientation, 'stableSamples': samples,
                                   'elapsedMilliseconds': milliseconds, 'checks': checks}
                        log.write_text(viewport_line(payload) + '\n')
                        output = self.capture(helper.diagnostics, log)
                        self.assertEqual(self.notices(output, UI_VIEWPORT_NOTICE), [{'scope': 'stdoutOnly', **payload}])
                        self.assertEqual(self.notices(output, UI_VIEWPORT_REJECTED_NOTICE), [])

    def test_viewport_rejects_wrong_types_unknown_checks_and_nonexact_json(self):
        valid = {'orientation': 'landscape', 'stableSamples': 3, 'elapsedMilliseconds': 15000,
                 'checks': {'foreground': True}}
        invalid = [{**valid, 'orientation': value} for value in ('unknown', PRIVATE, None, True, [])]
        for key, upper in (('stableSamples', 10000), ('elapsedMilliseconds', 1200000)):
            invalid += [{**valid, key: value} for value in (-1, upper + 1, True, False, 1.0, '1', None)]
        invalid += [{**valid, 'checks': {PRIVATE: True}}, {**valid, 'checks': {'foreground': 1}},
                    {**valid, 'checks': {'foreground': 'true'}}, {**valid, 'checks': []},
                    {**valid, 'private': PRIVATE}, {key: value for key, value in valid.items() if key != 'checks'},
                    [], None]
        lines = [viewport_line(payload) for payload in invalid]
        lines += [viewport_line(valid) + ' error: ' + PRIVATE,
                  viewport_line(valid) + ' UI viewport diagnostic: ' + PRIVATE,
                  'UI viewport diagnostic: {' + PRIVATE,
                  'UI viewport diagnostic: ' + json.dumps({**valid, 'private': PRIVATE * 4096}),
                  'UI viewport diagnostic: ' + '[' * 1500 + '0' + ']' * 1500,
                  'UI viewport diagnostic: {"orientation":"' + PRIVATE + '","orientation":"landscape",'
                  '"stableSamples":3,"elapsedMilliseconds":15000,"checks":{}}',
                  'UI viewport diagnostic: {"orientation":"landscape","stableSamples":3,'
                  '"elapsedMilliseconds":15000,"checks":{"foreground":true,"foreground":false}}']
        log = self.root / 'viewport-invalid.log'
        log.write_text('\n'.join(lines) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_VIEWPORT_NOTICE), [])
        self.assertEqual(self.notices(output, UI_VIEWPORT_REJECTED_NOTICE), [{'invalidCount': len(lines)}])
        self.assertNotIn('::error::', output)

    def test_ui_failure_and_viewport_payloads_never_enter_other_diagnostic_channels(self):
        private = ("error: UI row scroll owner: /private/" + PRIVATE
                   + " Test run with 999 tests passed Test Case '-[MirrorIOSUITests.MirrorUITests "
                   + METHODS[1] + "]' started. UI screenshot timing: stage=detail,milliseconds=999")
        viewport = {'orientation': 'landscape', 'stableSamples': 0, 'elapsedMilliseconds': 15000,
                    'checks': {}, 'private': private}
        failure = ui_failure_line(line='111') + ' ' + private
        log = self.root / 'ui-mixed.log'
        log.write_text('\n'.join([
            f"Test Case '-[MirrorIOSUITests.MirrorUITests {METHODS[0]}]' started.",
            viewport_line(viewport), failure, store_dedup_line(),
            ui_failure_line(line='112') + ' ' + store_dedup_line(),
            store_dedup_line() + ' ' + viewport_line({
                'orientation': 'portrait', 'stableSamples': 0, 'elapsedMilliseconds': 15000, 'checks': {},
            }),
            case_line(event='failed'), screenshot_line('detail', '123'),
            'error: safe unrelated compiler failure',
        ]) + '\n')
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
            'scope': 'stdoutOnly', 'method': METHODS[0],
            'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 111, 'assertionKind': 'XCTAssertTrue',
        }])
        self.assertEqual(self.notices(output, UI_VIEWPORT_REJECTED_NOTICE), [{'invalidCount': 2}])
        self.assertEqual(len(self.notices(output, STORE_DEDUP_NOTICE)), 1)
        self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [{'invalidCount': 2}])
        self.assertEqual(self.notices(output, SCREENSHOT_NOTICE), [
            {'scope': 'stdoutOnly', 'stage': 'detail', 'milliseconds': 123},
        ])
        self.assertNotIn('UI row scroll owners:', output)
        self.assertNotIn('Swift Testing completion reports:', output)
        self.assertNotIn(METHODS[1], output)
        self.assertIn('::error::error: safe unrelated compiler failure', output)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')

    def test_store_dedup_valid_report_has_only_fixed_method_scope_states_and_bools(self):
        log = self.root / 'store-valid.log'
        log.write_text('fatal: /private/' + PRIVATE + ' ' + store_dedup_line() + '\n')
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [{
            'method': 'independentInstancesDeduplicate', 'scope': 'stdoutOnly',
            'states': ['locallyCommitted', 'unavailable'], 'busyResults': [False, True],
        }])
        self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [])
        self.assertNotIn('/private/', output)
        self.assertNotIn('::error::', output)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')

    def test_store_dedup_accepts_each_current_command_result_state(self):
        expected_states = {
            'locallyCommitted', 'alreadyApplied', 'requiresConfirmation', 'staleSnapshot',
            'staleContext', 'alreadyDecided', 'notFound', 'unavailable', 'persistenceFailed',
            'committedProjectionPending',
        }
        self.assertEqual(helper.COMMAND_RESULT_STATES, expected_states)
        for state in sorted(expected_states):
            with self.subTest(state=state):
                payload = {'states': [state, 'alreadyApplied'],
                           'busyResults': [state == 'unavailable', False]}
                log = self.root / 'store-state.log'
                log.write_text(store_dedup_line(payload) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [{
                    'method': 'independentInstancesDeduplicate', 'scope': 'stdoutOnly', **payload,
                }])
                self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [])

    def test_store_dedup_rejects_unknown_state_and_wrong_payload_shapes(self):
        invalid_payloads = (
            {'states': ['locallyCommitted', PRIVATE], 'busyResults': [False, False]},
            {'states': [PRIVATE, 'alreadyApplied'], 'busyResults': [False, False]},
            {'states': [], 'busyResults': [False, False]},
            {'states': ['locallyCommitted'], 'busyResults': [False, False]},
            {'states': ['locallyCommitted', 'alreadyApplied', 'unavailable'], 'busyResults': [False, False]},
            {'states': 'locallyCommitted', 'busyResults': [False, False]},
            {'states': [None, 'alreadyApplied'], 'busyResults': [False, False]},
            {'states': [True, 'alreadyApplied'], 'busyResults': [False, False]},
            {'states': [{}, 'alreadyApplied'], 'busyResults': [False, False]},
            {'busyResults': [False, False]},
            {'states': ['locallyCommitted', 'alreadyApplied']},
            [], None, True,
        )
        for payload in invalid_payloads:
            with self.subTest(payload=payload):
                log = self.root / 'store-shape.log'
                # None도 기본 정상 payload가 아니라 실제 JSON null로 입력한다.
                log.write_text('Store dedup result diagnostic: ' + json.dumps(payload) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [])
                self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertNotIn('::error::', output)

    def test_store_dedup_requires_exactly_two_actual_bool_values(self):
        invalid_values = (0, 1, 0.0, 1.0, 'true', 'false', None, [], {})
        invalid_arrays = ([], [False], [False, True, False], 'false,true', None)
        for value in invalid_values:
            for index in (0, 1):
                values = [False, True]
                values[index] = value
                invalid_arrays += (values,)
        for values in invalid_arrays:
            with self.subTest(busyResults=values):
                payload = {'states': ['locallyCommitted', 'unavailable'], 'busyResults': values}
                log = self.root / 'store-bool.log'
                log.write_text(store_dedup_line(payload) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [])
                self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertNotIn('::error::', output)

    def test_store_dedup_rejects_private_extra_fields_duplicates_and_malformed_json(self):
        valid = {'states': ['locallyCommitted', 'alreadyApplied'], 'busyResults': [False, False]}
        private_payload = {**valid, 'private': 'UI row scroll owner: error: /private/' + PRIVATE}
        duplicate = ('{"states":["' + PRIVATE + '","alreadyApplied"],'
                     '"states":["locallyCommitted","alreadyApplied"],"busyResults":[false,false]}')
        lines = [store_dedup_line(private_payload),
                 'Store dedup result diagnostic: ' + duplicate,
                 store_dedup_line(valid) + ' error: ' + PRIVATE,
                 'Store dedup result diagnostic: {' + PRIVATE,
                 store_dedup_line(valid) + ' Store dedup result diagnostic: ' + PRIVATE,
                 'Store dedup result diagnostic: ' + json.dumps({**valid, 'private': PRIVATE * 4096}),
                 'Store dedup result diagnostic: ' + '[' * 1500 + '0' + ']' * 1500]
        log = self.root / 'store-private.log'
        log.write_text('\n'.join(lines) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [])
        self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [{'invalidCount': len(lines)}])
        self.assertNotIn('/private/', output)
        self.assertNotIn('UI row scroll owners:', output)
        self.assertNotIn('::error::', output)

    def test_store_dedup_interleaved_logs_keep_other_diagnostics_and_swift_target_gates(self):
        log = self.root / 'store-parallel.log'
        lines = [
            'Test run with 36 tests passed after 0.2 seconds.',
            store_dedup_line(),
            screenshot_line('detail', '123'),
            'Test run with 94 tests failed after 0.3 seconds.',
            store_dedup_line({'states': ['locallyCommitted', PRIVATE], 'busyResults': [False, False]}),
            'error: safe unrelated compiler failure',
            'Test run with 29 tests passed after 0.1 seconds.',
        ]
        log.write_text('\n'.join(lines) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [{
            'method': 'independentInstancesDeduplicate', 'scope': 'stdoutOnly',
            'states': ['locallyCommitted', 'unavailable'], 'busyResults': [False, True],
        }])
        self.assertEqual(self.notices(output, STORE_DEDUP_REJECTED_NOTICE), [{'invalidCount': 1}])
        self.assertEqual(self.notices(output, SCREENSHOT_NOTICE), [
            {'scope': 'stdoutOnly', 'stage': 'detail', 'milliseconds': 123},
        ])
        self.assertEqual(self.notices(output, '::notice::Swift Testing completion reports: '), [[
            {'tests': 36, 'result': 'passed'}, {'tests': 94, 'result': 'failed'},
            {'tests': 29, 'result': 'passed'},
        ]])
        self.assertIn('::error::error: safe unrelated compiler failure', output)
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        with mock.patch.object(helper.sys, 'argv', ['ci_results.py', 'swift', str(log)]), \
                mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                mock.patch.object(helper, 'record') as record:
            with self.assertRaises(ValueError):
                self.capture(helper.main)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')

        valid = {'states': ['locallyCommitted', 'alreadyApplied'], 'busyResults': [False, False]}
        log.write_text('\n'.join([
            'Test run with 36 tests passed after 0.2 seconds.', store_dedup_line(valid),
            'Test run with 94 tests passed after 0.3 seconds.',
            'Test run with 29 tests passed after 0.1 seconds.',
        ]) + '\n')
        with mock.patch.object(helper.sys, 'argv', ['ci_results.py', 'swift', str(log)]), \
                mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}):
            output = self.capture(helper.main)
        self.assertEqual(self.notices(output, STORE_DEDUP_NOTICE), [{
            'method': 'independentInstancesDeduplicate', 'scope': 'stdoutOnly', **valid,
        }])
        self.assertIn('"executedTests": 159, "result": "pass"', output)
        self.assertEqual(output_path.read_text(), 'previous=value\ntests=159\n')

    def test_duration_accepts_native_numbers_at_both_inclusive_bounds(self):
        for value in (0, 0.0, 0.001, 1199.999, 1200, 1200.0):
            with self.subTest(value=value):
                self.assertIs(helper.valid_ui_duration(value), True)
        for value in (True, False, None, '1', [], {}, -1, -0.001, 1200.001, 1201,
                      float('nan'), float('inf'), float('-inf'), 10 ** 400, complex(1, 0)):
            with self.subTest(value=value):
                self.assertIs(helper.valid_ui_duration(value), False)

    def test_case_timings_include_only_completed_baseline_cases_and_safe_fields(self):
        lines = [case_line(event='started'), case_line(seconds='0')[:-1],
                 case_line(METHODS[1], 'failed', '1200', 'MirrorMacUITests')]
        output = self.capture(helper.report_ui_timing_diagnostics, lines)
        self.assertEqual(self.notices(output, CASE_NOTICE), [
            {'scope': 'stdoutOnly', 'method': METHODS[0], 'event': 'passed', 'seconds': 0.0},
            {'scope': 'stdoutOnly', 'method': METHODS[1], 'event': 'failed', 'seconds': 1200.0},
        ])
        self.assertNotIn('MirrorIOSUITests', output)
        self.assertNotIn('MirrorMacUITests', output)

    def test_case_timings_keep_latest_valid_event_for_each_of_six_baselines(self):
        lines = [case_line(method, seconds='1') for method in METHODS]
        lines += [case_line(method, 'failed', '2.5') for method in METHODS]
        lines += [case_line(METHODS[0], seconds='1200.001'), case_line('test' + PRIVATE)]
        output = self.capture(helper.report_ui_timing_diagnostics, lines)
        cases = self.notices(output, CASE_NOTICE)
        self.assertEqual(len(cases), 6)
        self.assertEqual({case['method'] for case in cases}, set(METHODS))
        self.assertTrue(all(case['event'] == 'failed' and case['seconds'] == 2.5 for case in cases))

    def test_case_timing_rejects_malformed_or_out_of_range_decimal_text(self):
        for seconds in ('true', 'NaN', 'inf', '-1', '+1', '.5', '1.', '1e2', '1200.001',
                        '999999999999999999999', '\u0661', PRIVATE + '/private/path'):
            with self.subTest(seconds=seconds):
                self.assertEqual(self.capture(helper.report_ui_timing_diagnostics,
                                              [case_line(seconds=seconds)]), '')
        for line in (case_line('test' + PRIVATE), case_line(event='skipped'),
                     case_line() + ' error: /private/' + PRIVATE):
            with self.subTest(line=line):
                self.assertEqual(self.capture(helper.report_ui_timing_diagnostics, [line]), '')

    def test_screenshot_timing_accepts_fixed_stages_and_exact_millisecond_bounds(self):
        lines = [screenshot_line(stage, '0' if index == 0 else '1200000')
                 for index, stage in enumerate(STAGES)]
        output = self.capture(helper.report_ui_timing_diagnostics, lines)
        shots = self.notices(output, SCREENSHOT_NOTICE)
        self.assertEqual(len(shots), 15)
        self.assertEqual({shot['stage'] for shot in shots}, set(STAGES))
        self.assertEqual(shots[0], {'scope': 'stdoutOnly', 'stage': STAGES[0], 'milliseconds': 0})
        self.assertTrue(all(type(shot['milliseconds']) is int for shot in shots))
        self.assertEqual(shots[-1]['milliseconds'], 1200000)

    def test_screenshot_timing_retains_only_last_fifteen_valid_events(self):
        lines = [screenshot_line(milliseconds=str(value)) for value in range(20)]
        lines += [screenshot_line(PRIVATE), screenshot_line(milliseconds='1200001')]
        output = self.capture(helper.report_ui_timing_diagnostics, lines)
        self.assertEqual([shot['milliseconds'] for shot in self.notices(output, SCREENSHOT_NOTICE)],
                         list(range(5, 20)))

    def test_screenshot_timing_rejects_bad_tokens_and_trailing_payloads(self):
        lines = [screenshot_line(milliseconds=value) for value in
                 ('true', 'NaN', '-1', '+1', '1.0', '1e3', '1200001', '999999999999', '\u0661', PRIVATE)]
        lines += [screenshot_line('/private/' + PRIVATE), screenshot_line('week-picker/' + PRIVATE),
                  screenshot_line() + ' error: /private/' + PRIVATE,
                  'UI screenshot timing: stage=week-picker, milliseconds=123']
        self.assertEqual(self.capture(helper.report_ui_timing_diagnostics, lines), '')

    def test_log_prefixes_are_not_copied_into_timing_notices(self):
        prefix = '2026-10-01T00:00:00.000Z fatal: /private/' + PRIVATE + ' '
        output = self.capture(helper.report_ui_timing_diagnostics,
                              [prefix + case_line(), prefix + screenshot_line()])
        self.assertEqual(len(self.notices(output, CASE_NOTICE)), 1)
        self.assertEqual(len(self.notices(output, SCREENSHOT_NOTICE)), 1)
        self.assertNotIn('2026-10-01', output)
        self.assertNotIn('/private/', output)

    def test_diagnostics_filters_invalid_structured_payloads_from_raw_error_and_fallback(self):
        for lines in ([case_line('test' + PRIVATE, 'failed')],
                      [case_line(seconds=PRIVATE + '/private/path')],
                      [screenshot_line() + ' error: /private/' + PRIVATE],
                      [screenshot_line(PRIVATE, 'true')],
                      [case_line('test' + PRIVATE, 'failed').replace('Test Case', 'Test\tCase')],
                      [case_line('test' + PRIVATE, 'failed').replace('Test Case', 'Test  Case')],
                      [case_line(seconds='/private/' + PRIVATE).replace("Case '", 'Case ')],
                      [case_line(seconds='/private/' + PRIVATE).replace('.MirrorUITests ', '.MirrorUITests\t')]):
            with self.subTest(lines=lines):
                log = self.root / 'invalid.log'
                log.write_text('\n'.join(lines) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, CASE_NOTICE), [])
                self.assertEqual(self.notices(output, SCREENSHOT_NOTICE), [])
                self.assertNotIn('/private/', output)

    def test_timing_diagnostics_never_record_success_or_write_actions_outputs(self):
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        samples = ['', screenshot_line(),
                   '\n'.join([case_line(method) for method in METHODS[:-1]] +
                             [f"Test Case '-[MirrorIOSUITests.MirrorUITests {METHODS[-1]}]' started."])]
        for text in samples:
            with self.subTest(text=text):
                log = self.root / 'incomplete.log'
                log.write_text(text)
                with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                        mock.patch.object(helper, 'record') as record:
                    output = self.capture(helper.diagnostics, log)
                record.assert_not_called()
                self.assertEqual(output_path.read_text(), 'previous=value\n')
                self.assertNotIn('executedTests', output)
                self.assertNotIn('"result": "pass"', output)
                if text:
                    self.assertNotIn('"xcodeCompletionReported": true', output)

    def test_actual_xctest_started_line_survives_without_a_completion_result(self):
        log = self.root / 'started.log'
        log.write_text(f"Test Case '-[MirrorIOSUITests.MirrorUITests {METHODS[-1]}]' started.\n")
        output = self.capture(helper.diagnostics, log)
        summaries = self.notices(output, '::notice::UI stdout diagnostics: ')
        self.assertEqual(len(summaries), 1)
        self.assertEqual(summaries[0]['events'], [{'method': METHODS[-1], 'event': 'started'}])
        self.assertIs(summaries[0]['xcodeCompletionReported'], False)
        self.assertEqual(self.notices(output, CASE_NOTICE), [])

    def test_zero_test_record_still_fails_without_writing_outputs(self):
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}):
            with self.assertRaises(ValueError):
                helper.record(0)
        self.assertEqual(output_path.read_text(), 'previous=value\n')

    def test_ui_guard_still_requires_every_case_and_rejects_failed_or_skipped_results(self):
        source = self.root / 'sources'
        source.mkdir()
        (source / 'MirrorUITests.swift').write_text('\n'.join(f'func {method}() {{}}' for method in METHODS))
        tree_path = self.root / 'ui-tests.json'
        for missing, bad_result in ((True, None), (False, 'Failed'), (False, 'Skipped')):
            with self.subTest(missing=missing, bad_result=bad_result):
                children = [{'nodeType': 'Test Case', 'name': method + '()', 'result': 'Passed',
                             'durationInSeconds': 1.0} for method in (METHODS[:-1] if missing else METHODS)]
                if bad_result is not None:
                    children[-1]['result'] = bad_result
                tree_path.write_text(json.dumps({'testNodes': [{'nodeType': 'UI test bundle',
                    'name': 'MirrorIOSUITests', 'result': 'Passed', 'children': children}]}))
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ValueError):
                    helper.ui_guard(tree_path, 'MirrorIOSUITests', source)

    def test_tree_timings_use_only_baseline_case_result_and_numeric_duration(self):
        nodes = {'testNodes': [
            {'nodeType': 'Test Case', 'name': METHODS[0] + '()', 'result': 'Passed',
             'durationInSeconds': 0, 'duration': PRIVATE, 'nodeIdentifierURL': '/private/' + PRIVATE},
            {'nodeType': 'Test Case', 'name': METHODS[1] + '()', 'result': 'Failed',
             'durationInSeconds': 1200.0},
            {'nodeType': 'Failure Message', 'name': METHODS[2] + '()', 'result': 'Passed',
             'durationInSeconds': 1.0},
            {'nodeType': 'Test Case', 'name': 'test' + PRIVATE, 'result': 'Passed', 'durationInSeconds': 1.0},
        ]}
        output = self.capture(helper.report_ui_tree_timings, nodes)
        self.assertEqual(self.notices(output, CASE_NOTICE), [
            {'scope': 'xcresult', 'method': METHODS[0], 'event': 'passed', 'seconds': 0.0},
            {'scope': 'xcresult', 'method': METHODS[1], 'event': 'failed', 'seconds': 1200.0},
        ])
        self.assertNotIn('nodeIdentifierURL', output)
        self.assertNotIn('/private/', output)

    def test_tree_timing_rejects_invalid_numeric_values_and_nonfinal_results(self):
        invalid = (True, False, None, '12.3', -0.001, 1200.001, float('nan'), float('inf'), 10 ** 400)
        nodes = [{'nodeType': 'Test Case', 'name': METHODS[0] + '()', 'result': 'Passed',
                  'durationInSeconds': value} for value in invalid]
        nodes += [{'nodeType': 'Test Case', 'name': METHODS[0] + '()', 'result': result,
                   'durationInSeconds': 1.0} for result in ('Skipped', 'started', PRIVATE)]
        self.assertEqual(self.capture(helper.report_ui_tree_timings, nodes), '')

    def test_tree_timings_keep_latest_valid_result_per_baseline_without_declaring_success(self):
        nodes = [{'nodeType': 'Test Case', 'name': method + '()', 'result': result,
                  'durationInSeconds': seconds} for result, seconds in (('Passed', 1), ('Failed', 2))
                 for method in METHODS]
        with mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.report_ui_tree_timings, {'testNodes': nodes})
        record.assert_not_called()
        cases = self.notices(output, CASE_NOTICE)
        self.assertEqual(len(cases), 6)
        self.assertEqual({case['method'] for case in cases}, set(METHODS))
        self.assertTrue(all(case['event'] == 'failed' and case['seconds'] == 2.0 for case in cases))
        self.assertNotIn('executedTests', output)


if __name__ == '__main__':
    unittest.main()
