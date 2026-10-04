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
    'library', 'library-search', 'detail', 'detail-edit', 'completion', 'undo', 'validation-error',
    'quick-plan-picker', 'ipad-landscape',
)
CASE_NOTICE = '::notice::UI case timing: '
TREE_CASE_NOTICE = '::notice::UI xcresult case timings: '
SCREENSHOT_NOTICE = '::notice::UI screenshot timing: '
STORE_DEDUP_NOTICE = '::notice::Store dedup result diagnostic: '
STORE_DEDUP_REJECTED_NOTICE = '::notice::Store dedup result diagnostic rejected: '
UI_FIRST_FAILURE_NOTICE = '::notice::UI first failure: '
UI_FIRST_FAILURE_REJECTED_NOTICE = '::notice::UI first failure rejected: '
UI_FIRST_FAILURE_REJECTION_REASONS_NOTICE = '::notice::UI first failure rejection reasons: '
UI_UNCLASSIFIED_FAILURE_NOTICE = '::notice::UI unclassified failure: '
UI_VIEWPORT_NOTICE = '::notice::UI viewport diagnostic: '
UI_VIEWPORT_REJECTED_NOTICE = '::notice::UI viewport diagnostic rejected: '
UI_KEYBOARD_NOTICE = '::notice::UI keyboard introduction diagnostic: '
UI_KEYBOARD_REJECTED_NOTICE = '::notice::UI keyboard introduction diagnostic rejected: '
UI_PHASE_NOTICE = '::notice::UI test phase diagnostic: '
UI_PHASE_REJECTED_NOTICE = '::notice::UI test phase diagnostic rejected: '
UI_NATIVE_SCREENSHOT_NOTICE = '::notice::UI native screenshot diagnostic: '
UI_NATIVE_SCREENSHOT_REJECTED_NOTICE = '::notice::UI native screenshot diagnostic rejected: '
UI_TOOLBAR_NOTICE = '::notice::UI search toolbar diagnostic: '
UI_TOOLBAR_REJECTED_NOTICE = '::notice::UI search toolbar diagnostic rejected: '
PHASE_METHOD = METHODS[4]
NATIVE_SCREENSHOT_METHOD = METHODS[0]
PHASES = (
    'started', 'launched', 'captured', 'reviewOpened', 'tomorrowAssigned', 'reviewClosed',
    'todayExcluded', 'searchNavigationRequested', 'searchReady', 'searchEntered',
    'futureRowVerified', 'searchTitleVerified', 'libraryScreenshotRecorded', 'detailOpened',
    'detailPlanVerified', 'detailTitleVerified', 'detailTitleExpanded', 'detailTitleCollapsed',
    'detailScreenshotRecorded', 'detailClosed', 'todayRechecked', 'complete',
)
KEYBOARD_FRAME_FIELDS = (
    'continueFrameHasArea', 'continueFrameInsideKeyboard',
    'continueFrameCenterInsideKeyboard', 'continueFrameIntersectsKeyboard',
)
KEYBOARD_INTRODUCTION_FIELDS = (
    'continueInIntroductionCount', 'introductionContextCount', 'introductionWindowCount',
    'introductionTextVisible', 'introductionContextValid', 'continueFrameInsideIntroduction',
)
UI_CAPTURE_PHASE_NOTICE = '::notice::UI capture phase diagnostic: '
UI_CAPTURE_PHASE_REJECTED_NOTICE = '::notice::UI capture phase diagnostic rejected: '
UI_VALUE_WAIT_NOTICE = '::notice::UI value wait failure diagnostic: '
UI_VALUE_WAIT_REJECTED_NOTICE = '::notice::UI value wait failure diagnostic rejected: '
CAPTURE_PHASES = (
    'started', 'launched', 'initialNavigationVerified', 'initialScreenshotRecorded', 'calendarSelected',
    'calendarNavigationVerified', 'calendarScreenshotRecorded', 'settingsRecorded', 'captureSaved',
    'libraryOpened', 'libraryNavigationVerified', 'libraryScreenshotRecorded', 'selectionRegressionStarted',
    'selectionRegressionComplete', 'reviewOpened', 'todayAssigned', 'todayRowVerified',
    'todayNavigationVerified', 'complete',
)
UI_NAVIGATION_GEOMETRY_NOTICE = '::notice::UI navigation geometry diagnostic: '
UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE = '::notice::UI navigation geometry diagnostic rejected: '
NAVIGATION_GEOMETRY_FIELDS = ('stage', 'identifier', 'statusFrame', 'windowFrame', 'buttonFrame')
NAVIGATION_GEOMETRY_PREFIXES = {
    METHODS[0]: tuple((stage, identifier)
                      for stage in ('initial-today', 'calendar', 'library', 'today-populated')
                      for identifier in ('capture.open', 'settings.button')),
    METHODS[2]: (('validation-recovery', 'capture.open'),
                 ('validation-recovery', 'settings.button')),
}
UI_VALIDATION_RECOVERY_NOTICE = '::notice::UI validation recovery diagnostic: '
UI_VALIDATION_RECOVERY_REJECTED_NOTICE = '::notice::UI validation recovery diagnostic rejected: '
VALIDATION_RECOVERY_METHOD = METHODS[2]
VALIDATION_RECOVERY_BOOL_FIELDS = (
    'identifierMatchesCaptureOpen', 'targetIsButton', 'exists', 'enabled', 'hittable',
    'frameHasArea', 'ownedBySingleWindow', 'keyboardPresent', 'alertPresent', 'sheetPresent',
)
VALIDATION_RECOVERY_NULLABLE_FIELDS = ('frameInsideWindow', 'belowStatus')
QUERY_FAILURE_SAMPLES = (
    ('Failed to get matching snapshot', 'failedToGetMatchingSnapshot'),
    ('Failed to get matching snapshots', 'failedToGetMatchingSnapshot'),
    ('Multiple matching elements found', 'multipleMatchingElements'),
    ('No matching elements found', 'noMatchingElements'),
    ('No matches found', 'noMatchingElements'),
    ('AX snapshot timed out', 'axSnapshotTimedOut'),
    ('Element query evaluation failed', 'elementQueryEvaluationFailed'),
    ('Application is not running', 'applicationNotRunning'),
    ('Unhandled XCTest exception', 'unhandledXCTestException'),
)
HISTORY_FAILURE_SAMPLES = (
    ('이력 탐색 중 앱이 전경에서 실행되지 않는다', 'historyApplicationNotForeground'),
    ('이력 제어의 유일한 상세 스크롤 소유자를 확인할 수 없다', 'historyScrollOwnerNotUnique'),
    ('이력 스크롤 탐색의 기존 15초 예산을 초과했다', 'historyScrollDeadlineExceeded'),
    ('이력의 기존 상세 스크롤 소유자가 사라지거나 표시되지 않는다', 'historyScrollOwnerUnavailable'),
    ('이력 대상이 기존 상세 소유자 안에 없다', 'historyTargetOutsideOwner'),
    ('기존 8회 실제 스크롤 안에 이력 대상에 도달하지 못했다', 'historyScrollLimitReached'),
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


def ui_failure_message_line(message, **arguments):
    return ui_failure_line(**arguments).replace('expected/actual=/private/' + PRIVATE, message)


def ui_query_failure_line(message, **arguments):
    return ui_failure_message_line(message, **arguments).replace('XCTAssertTrue failed - ', '', 1)


def viewport_line(payload):
    return 'UI viewport diagnostic: ' + json.dumps(payload)


def keyboard_line(payload):
    return 'UI keyboard introduction diagnostic: ' + json.dumps(payload)


def phase_line(payload):
    return 'UI test phase diagnostic: ' + json.dumps(payload)


def native_screenshot_line(payload):
    return 'UI native screenshot diagnostic: ' + json.dumps(payload)


def toolbar_line(payload):
    return 'UI search toolbar diagnostic: ' + json.dumps(payload)


def toolbar_payload(identifier='capture.open', **observations):
    return {'method': PHASE_METHOD, 'identifier': identifier,
            'hittable': True, 'belowStatus': True, 'frameInsideWindow': True, **observations}


def started_line(method, owner='MirrorIOSUITests.MirrorUITests'):
    return f"Test Case '-[{owner} {method}]' started."


def native_screenshot_payload():
    return {'method': NATIVE_SCREENSHOT_METHOD, 'stage': 'ipad-landscape', 'orientation': 'left',
            'imageWidth': 1376.0, 'imageHeight': 1032.0, 'imageScale': 2.0,
            'cgImageWidth': 2752, 'cgImageHeight': 2064, 'pngSHA256': 'a' * 64}


def keyboard_frame_payload():
    return {'phase': 'continueReadiness', 'continueCandidateCount': 0,
            'keyboardBoundsValid': True, 'elapsedMilliseconds': 15901,
            'continueQueryCount': 1, 'continueExistingCount': 1, 'continueHittableCount': 1,
            'continueEnabledCount': 1, 'continueInKeyboardCount': 0,
            'continueFrameHasArea': True, 'continueFrameInsideKeyboard': False,
            'continueFrameCenterInsideKeyboard': True, 'continueFrameIntersectsKeyboard': True}


def keyboard_introduction_payload():
    return {**keyboard_frame_payload(), 'continueCandidateCount': 1,
            'continueFrameCenterInsideKeyboard': False, 'continueInIntroductionCount': 1,
            'introductionContextCount': 1, 'introductionWindowCount': 1,
            'introductionTextVisible': True, 'introductionContextValid': True,
            'continueFrameInsideIntroduction': True}


def validation_recovery_payload(**checks):
    return {'method': VALIDATION_RECOVERY_METHOD, 'action': 'capture.open', 'phase': 'validationRecovery',
            'checks': {**{key: True for key in VALIDATION_RECOVERY_BOOL_FIELDS},
                       'frameInsideWindow': None, 'belowStatus': None, **checks}}


def validation_recovery_line(payload):
    return 'UI validation recovery diagnostic: ' + json.dumps(payload)


def capture_phase_line(phase='started'):
    return 'UI capture phase diagnostic: ' + json.dumps({'phase': phase})


def value_wait_payload(method=METHODS[0], **overrides):
    source = (ROOT / helper.UI_FAILURE_SOURCE_FILE).read_text().splitlines()
    # Shared capture() is exercised by every baseline case; direct empty waits are case-owned.
    call = ('try waitForValue("", element: continuousTitle)' if method == METHODS[0]
            else 'try replaceText(in: field, with: title, app: app, prepareKeyboardBeforeTyping: attachEvidence)')
    caller = next(index for index, line in enumerate(source, 1)
                  if call in line)
    return {'target': 'captureTitle', 'callerLine': caller, 'expectedEmpty': True,
            'actualStringPresent': True, 'actualMatchesExpected': False, 'actualMatchesPlaceholder': False,
            'expectedLineCount': 0, 'actualLineCount': 2, **overrides}


def value_wait_line(payload):
    return 'UI value wait failure diagnostic: ' + json.dumps(payload)


def value_wait_transcript(payload=None, method=METHODS[0], module='MirrorIOSUITests', terminal='failed'):
    payload = value_wait_payload() if payload is None else payload
    failure = ui_failure_message_line('입력 값이 기대 상태로 바뀌지 않았다.', method=method,
                                      line=str(payload['callerLine']), kind='XCTFail').replace('MirrorIOSUITests', module)
    return [started_line(method, owner=module + '.MirrorUITests'), value_wait_line(payload), failure,
            case_line(method, event=terminal, module=module)]


def navigation_geometry_payload(stage='initial-today', identifier='capture.open', **observations):
    # 실패한 경계에서도 수치 자체는 관측이다. 아래 버튼은 status 영역 아래가 아니다.
    return {'stage': stage, 'identifier': identifier, 'statusFrame': [0, 0, 390, 59],
            'windowFrame': [0.0, 0.0, 390.0, 844.0], 'buttonFrame': [294, 12.5, 40, 40.0],
            **observations}


def navigation_geometry_line(payload):
    return 'UI navigation geometry diagnostic: ' + json.dumps(payload)


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

    def test_value_wait_reports_only_matching_failed_case_and_current_source_callsite(self):
        for module in ('MirrorIOSUITests', 'MirrorMacUITests'):
            for method in METHODS:
                with self.subTest(module=module, method=method):
                    payload = value_wait_payload(method=method)
                    output = self.capture(helper.report_ui_value_wait_diagnostics,
                                          value_wait_transcript(payload, method, module))
                    self.assertEqual(self.notices(output, UI_VALUE_WAIT_NOTICE),
                                     [{'scope': 'stdoutOnly', 'method': method,
                                       'sourceFile': helper.UI_FAILURE_SOURCE_FILE, **payload}])
                    self.assertNotIn(str(ROOT), output)
        # A late update after the timeout is an observation, not a passing assertion.
        payload = value_wait_payload(actualLineCount=0, actualMatchesExpected=True)
        output = self.capture(helper.report_ui_value_wait_diagnostics, value_wait_transcript(payload))
        self.assertEqual(self.notices(output, UI_VALUE_WAIT_NOTICE)[0]['actualMatchesExpected'], True)

    def test_value_wait_rejects_foreign_parallel_restarted_duplicate_and_nonfailed_cases(self):
        valid = value_wait_transcript()
        invalid = [valid[1:], valid[:-1], value_wait_transcript(terminal='passed'),
                   value_wait_transcript(terminal='skipped'), value_wait_transcript(module='OtherUITests'),
                   value_wait_transcript(method='testUnexpected'),
                   [valid[0], valid[0], *valid[1:]],
                   [valid[0], started_line(METHODS[1]), *valid[1:]],
                   [*valid[:2], case_line(event='failed'), valid[0], *valid[2:]],
                   [valid[0], valid[1], valid[1], *valid[2:]], valid + valid,
                   [*valid[:3], valid[3] + ' ' + started_line(METHODS[1])]]
        for transcript in invalid:
            with self.subTest(transcript=transcript):
                output = self.capture(helper.report_ui_value_wait_diagnostics, transcript)
                self.assertEqual(self.notices(output, UI_VALUE_WAIT_NOTICE), [])
                self.assertTrue(self.notices(output, UI_VALUE_WAIT_REJECTED_NOTICE))

    def test_value_wait_requires_exact_owned_failure_and_matching_caller_line(self):
        valid = value_wait_transcript()
        wrong_failures = [valid[2].replace(helper.UI_FAILURE_SOURCE_FILE, 'Tests/Other.swift'),
                          valid[2].replace(METHODS[0], METHODS[1]),
                          valid[2].replace(':' + str(value_wait_payload()['callerLine']) + ':', ':1:'),
                          valid[2] + PRIVATE, valid[2].replace('failed - ', 'XCTAssertTrue failed - ')]
        for failure in wrong_failures:
            output = self.capture(helper.report_ui_value_wait_diagnostics, [*valid[:2], failure, valid[3]])
            self.assertEqual(self.notices(output, UI_VALUE_WAIT_NOTICE), [])
            self.assertTrue(self.notices(output, UI_VALUE_WAIT_REJECTED_NOTICE))
        outside_call = value_wait_payload(callerLine=1)
        output = self.capture(helper.report_ui_value_wait_diagnostics, value_wait_transcript(outside_call))
        self.assertEqual(self.notices(output, UI_VALUE_WAIT_NOTICE), [])
        # An authentic callsite from another baseline test does not belong to this failure.
        output = self.capture(helper.report_ui_value_wait_diagnostics,
                              value_wait_transcript(value_wait_payload(), method=METHODS[1]))
        self.assertEqual(self.notices(output, UI_VALUE_WAIT_NOTICE), [])
        self.assertTrue(self.notices(output, UI_VALUE_WAIT_REJECTED_NOTICE))

    def test_value_wait_rejects_private_fields_invalid_types_and_inconsistent_bounded_counts(self):
        bad = [{'private': PRIVATE}, {'target': PRIVATE}, {'target': []}, {'callerLine': True},
               {'callerLine': 0}, {'callerLine': 100000}, {'callerLine': '1'},
               {'expectedEmpty': 1}, {'actualStringPresent': None}, {'actualMatchesExpected': 'false'},
               {'actualMatchesPlaceholder': 0}, {'expectedLineCount': True}, {'actualLineCount': -1},
               {'actualLineCount': 17}, {'actualLineCount': '2'}, {'expectedEmpty': False},
               {'actualStringPresent': False}, {'actualMatchesExpected': True}]
        for change in bad:
            with self.subTest(change=change):
                output = self.capture(helper.report_ui_value_wait_diagnostics,
                                      value_wait_transcript(value_wait_payload(**change)))
                self.assertEqual(self.notices(output, UI_VALUE_WAIT_NOTICE), [])
                self.assertTrue(self.notices(output, UI_VALUE_WAIT_REJECTED_NOTICE))
        for observations in ({'actualLineCount': 16}, {'actualStringPresent': False, 'actualLineCount': 0}):
            output = self.capture(helper.report_ui_value_wait_diagnostics,
                                  value_wait_transcript(value_wait_payload(**observations)))
            self.assertEqual(len(self.notices(output, UI_VALUE_WAIT_NOTICE)), 1)

    def test_value_wait_rejects_malformed_duplicate_oversize_and_mixed_payloads_without_fallback_leaks(self):
        valid = value_wait_transcript()
        encoded = json.dumps(value_wait_payload())
        marker = 'UI value wait failure diagnostic: '
        invalid = [marker + '{', marker + '[]', marker + encoded + PRIVATE,
                   marker + encoded[:-1] + ', "target":"' + PRIVATE + '"}',
                   marker + encoded[:-1] + ', "private":"' + PRIVATE + '한' * 1500 + '"}',
                   valid[1] + ' ' + valid[1], valid[1] + ' ' + started_line(METHODS[1]),
                   valid[1] + ' ' + capture_phase_line(), valid[1] + ' ' + ui_failure_line(),
                   valid[1] + ' ' + store_dedup_line()]
        for bad in invalid:
            output = self.capture(helper.report_ui_value_wait_diagnostics, [valid[0], bad, *valid[2:]])
            self.assertEqual(self.notices(output, UI_VALUE_WAIT_NOTICE), [])
            self.assertTrue(self.notices(output, UI_VALUE_WAIT_REJECTED_NOTICE))
        log = self.root / 'value-wait-private.log'
        log.write_text('\n'.join([valid[0], marker + json.dumps({'private': PRIVATE + ' fatal error'}), *valid[2:]]))
        output = self.capture(helper.diagnostics, log)
        self.assertNotIn(PRIVATE, output)
        self.assertEqual(self.notices(output, UI_VALUE_WAIT_NOTICE), [])
        self.assertTrue(self.notices(output, UI_FIRST_FAILURE_NOTICE))

    def test_capture_phase_preserves_every_actual_prefix_and_complete_without_success_inference(self):
        for owner in ('MirrorUITests', 'MirrorIOSUITests.MirrorUITests', 'MirrorMacUITests.MirrorUITests'):
            for length in range(1, len(CAPTURE_PHASES) + 1):
                with self.subTest(owner=owner, prefix_length=length):
                    lines = [started_line(METHODS[0], owner)] + [
                        'fatal: /private/' + PRIVATE + ' ' + capture_phase_line(phase)
                        for phase in CAPTURE_PHASES[:length]]
                    lines += [case_line(METHODS[0], event='failed').replace(
                        'MirrorIOSUITests.MirrorUITests', owner)]
                    output = self.capture(helper.report_ui_capture_phase_diagnostics, lines)
                    self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_NOTICE), [{
                        'scope': 'stdoutOnly', 'method': METHODS[0], 'phases': list(CAPTURE_PHASES[:length]),
                    }])
                    self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_REJECTED_NOTICE), [])
                    self.assertEqual(len(output.splitlines()), 1)
                    for inferred in ('event', 'success', 'executedTests', '"result"'):
                        self.assertNotIn(inferred, output)
        self.assertEqual(self.capture(helper.report_ui_capture_phase_diagnostics, []), '')

    def test_capture_phase_requires_fixed_order_unique_active_case_and_same_execution(self):
        valid = capture_phase_line()
        start = started_line(METHODS[0])
        prefixes = [[], [started_line(METHODS[2])], [started_line(METHODS[0], 'OtherTests')],
                    [start, started_line(METHODS[1])], [start, start],
                    [start, start, case_line(METHODS[0]), start],
                    [start, started_line(METHODS[0], 'MirrorMacUITests.MirrorUITests')],
                    [start, "Test Case '-[broken]' started."],
                    [start + ' ' + started_line(METHODS[2])]]
        prefixes += [[start, case_line(METHODS[0], event=event)]
                     for event in ('passed', 'failed', 'skipped')]
        for prefix in prefixes:
            output = self.capture(helper.report_ui_capture_phase_diagnostics, prefix + [valid])
            self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_NOTICE), [])
            self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_REJECTED_NOTICE), [{'invalidCount': 1}])
        entries = [capture_phase_line(phase) for phase in CAPTURE_PHASES]
        sequences = [([start, entries[1]], 1), ([start, entries[0], entries[2]], 1),
                     ([start, valid, valid], 1), ([start] + entries + [entries[-1]], 1),
                     ([start, entries[0], case_line(METHODS[0]), start, entries[1]], 1),
                     ([valid, start, valid, case_line(METHODS[0]), entries[1]], 2)]
        for lines, count in sequences:
            with self.subTest(lines=lines):
                output = self.capture(helper.report_ui_capture_phase_diagnostics, lines)
                self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_REJECTED_NOTICE), [{'invalidCount': count}])
                self.assertEqual(len(output.splitlines()), 1)
        for prefix in ([start, started_line(METHODS[1]), case_line(METHODS[1])],
                       [start, start, case_line(METHODS[0]), case_line(METHODS[0]), start]):
            output = self.capture(helper.report_ui_capture_phase_diagnostics, prefix + [valid])
            self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_NOTICE),
                             [{'scope': 'stdoutOnly', 'method': METHODS[0], 'phases': ['started']}])

    def test_capture_phase_rejects_nonexact_private_malformed_duplicate_and_oversize_payloads(self):
        marker = 'UI capture phase diagnostic: '
        encoded = json.dumps({'phase': 'started'})
        invalid_payloads = [{'phase': value} for value in
                            (PRIVATE, True, 1, None, [], {}, 'captureSaved', 'testCapture')]
        invalid_payloads += [{'method': METHODS[0], 'phase': 'started'}, {'phase': 'started', 'private': PRIVATE},
                             {}, [], None, True]
        bad_lines = [marker + json.dumps(payload) for payload in invalid_payloads]
        bad_lines += [marker + encoded + ' error: /private/' + PRIVATE,
                      marker + encoded + ' ' + marker + PRIVATE,
                      marker + '{"phase":"' + PRIVATE + '","phase":"started"}',
                      marker + '{' + PRIVATE, marker + '[' * 1500 + '0' + ']' * 1500]
        start = started_line(METHODS[0])
        for bad in bad_lines:
            for lines in ([start, bad], [start, capture_phase_line(), bad], [start, bad, capture_phase_line()]):
                output = self.capture(helper.report_ui_capture_phase_diagnostics, lines)
                self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertEqual(len(output.splitlines()), 1)
        at_limit = encoded[:-1] + ' ' * (4096 - len(encoded.encode('utf-8'))) + '}'
        self.assertEqual(len(at_limit.encode('utf-8')), 4096)
        output = self.capture(helper.report_ui_capture_phase_diagnostics, [start, marker + at_limit])
        self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_NOTICE),
                         [{'scope': 'stdoutOnly', 'method': METHODS[0], 'phases': ['started']}])
        over_limit = json.dumps({'phase': 'started', 'private': PRIVATE + '한' * 1400}, ensure_ascii=False)
        self.assertLess(len(over_limit), 4096)
        self.assertGreater(len(over_limit.encode('utf-8')), 4096)
        for payload in (at_limit[:-1] + ' }', over_limit):
            with mock.patch.object(helper.json, 'loads', side_effect=AssertionError('over-limit payload parsed')):
                output = self.capture(helper.report_ui_capture_phase_diagnostics, [start, marker + payload])
            self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_NOTICE), [])
            self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_REJECTED_NOTICE), [{'invalidCount': 1}])

    def test_capture_phase_rejects_mixed_channels_and_geometry_without_reinterpreting_private_events(self):
        valid = capture_phase_line()
        others = [store_dedup_line(), keyboard_line(keyboard_frame_payload()), viewport_line({}),
                  phase_line({'method': PHASE_METHOD, 'phase': 'started'}),
                  native_screenshot_line(native_screenshot_payload()), toolbar_line(toolbar_payload()),
                  validation_recovery_line(validation_recovery_payload()),
                  navigation_geometry_line(navigation_geometry_payload()), ui_failure_line(),
                  screenshot_line('detail', '999'), started_line(METHODS[2])]
        others += [case_line(event=event) for event in ('passed', 'failed', 'skipped')]
        accepted_prefixes = (STORE_DEDUP_NOTICE, UI_KEYBOARD_NOTICE, UI_VIEWPORT_NOTICE, UI_PHASE_NOTICE,
                             UI_NATIVE_SCREENSHOT_NOTICE, UI_TOOLBAR_NOTICE, UI_VALIDATION_RECOVERY_NOTICE,
                             UI_NAVIGATION_GEOMETRY_NOTICE, UI_FIRST_FAILURE_NOTICE, SCREENSHOT_NOTICE, CASE_NOTICE)
        log = self.root / 'capture-phase-mixed.log'
        for other in others:
            for combined in (valid + ' ' + other, other + ' ' + valid):
                log.write_text('\n'.join([started_line(METHODS[0]), combined,
                                          'error: safe unrelated compiler failure']) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_REJECTED_NOTICE), [{'invalidCount': 1}])
                for prefix in accepted_prefixes:
                    self.assertEqual(self.notices(output, prefix), [])
                self.assertIn('::error::error: safe unrelated compiler failure', output)
        forged = started_line(METHODS[0]) + ' ' + case_line(METHODS[0]) + ' /private/' + PRIVATE
        for foreign in (store_dedup_line({'private': forged}), keyboard_line({'private': forged}),
                        viewport_line({'private': forged}), phase_line({'private': forged}),
                        native_screenshot_line({'private': forged}), toolbar_line({'private': forged}),
                        validation_recovery_line({'private': forged}),
                        navigation_geometry_line({'private': forged}), ui_failure_message_line(forged)):
            for actual_start in (False, True):
                prefix = [started_line(METHODS[0])] if actual_start else []
                output = self.capture(helper.report_ui_capture_phase_diagnostics, prefix + [foreign, valid])
                self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_NOTICE),
                                 [{'scope': 'stdoutOnly', 'method': METHODS[0], 'phases': ['started']}]
                                 if actual_start else [])
                self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_REJECTED_NOTICE),
                                 [] if actual_start else [{'invalidCount': 1}])

    def test_capture_phase_and_geometry_preserve_first_failure_and_actions_gate_files_together(self):
        output_path = self.root / 'github-output'
        summary_path = self.root / 'github-step-summary'
        output_path.write_text('previous=value\n')
        summary_path.write_text('previous summary\n')
        log = self.root / 'capture-phase-private-gates.log'
        private = ('UI row scroll owner: /private/' + PRIVATE + ' Test run with 999 tests passed '
                   + started_line(METHODS[1]) + ' ' + screenshot_line('detail', '999')
                   + ' savedReceiptVerified=true ** TEST SUCCEEDED **')
        for invalid in (False, True):
            phase = {'phase': 'started'}
            if invalid:
                phase['private'] = private
            payload = navigation_geometry_payload()
            log.write_text('\n'.join([
                started_line(METHODS[0]), 'UI capture phase diagnostic: ' + json.dumps(phase),
                navigation_geometry_line(payload), ui_failure_line(method=METHODS[0], line='599'),
                case_line(METHODS[0], event='failed'), screenshot_line('detail', '123'),
                'error: safe unrelated compiler failure',
            ]) + '\n')
            with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                    'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                    mock.patch.object(helper, 'record') as record:
                output = self.capture(helper.diagnostics, log)
            self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_NOTICE),
                             [] if invalid else [{'scope': 'stdoutOnly', 'method': METHODS[0], 'phases': ['started']}])
            self.assertEqual(self.notices(output, UI_CAPTURE_PHASE_REJECTED_NOTICE),
                             [{'invalidCount': 1}] if invalid else [])
            self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE),
                             [{'scope': 'stdoutOnly', 'method': METHODS[0], 'samples': [payload]}])
            self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
                'scope': 'stdoutOnly', 'method': METHODS[0], 'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift',
                'line': 599, 'assertionKind': 'XCTAssertTrue',
            }])
            self.assertLess(output.index(UI_FIRST_FAILURE_NOTICE), output.index(UI_NAVIGATION_GEOMETRY_NOTICE))
            for forbidden in ('/private/', 'savedReceiptVerified', 'UI row scroll owners:',
                              'Swift Testing completion reports:', METHODS[1], 'executedTests', '"result": "pass"'):
                self.assertNotIn(forbidden, output)
            self.assertFalse(self.notices(output, '::notice::UI stdout diagnostics: ')[0]['xcodeCompletionReported'])
            record.assert_not_called()
            self.assertEqual(output_path.read_text(), 'previous=value\n')
            self.assertEqual(summary_path.read_text(), 'previous summary\n')
        log.write_text('UI capture phase diagnostic: ' + json.dumps({'private': private}) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(output.splitlines(), [UI_CAPTURE_PHASE_REJECTED_NOTICE + '{"invalidCount": 1}'])

    def test_navigation_geometry_preserves_actual_failure_frames_and_every_observed_prefix(self):
        for method, prefix in NAVIGATION_GEOMETRY_PREFIXES.items():
            for owner in ('MirrorUITests', 'MirrorIOSUITests.MirrorUITests', 'MirrorMacUITests.MirrorUITests'):
                for length in range(1, len(prefix) + 1):
                    with self.subTest(method=method, owner=owner, prefix_length=length):
                        payloads = [navigation_geometry_payload(stage, identifier)
                                    for stage, identifier in prefix[:length]]
                        # 객체 키 순서와 수치 int/float를 바꾸어도 값은 그대로 보존한다.
                        lines = [started_line(method, owner)] + [
                            'fatal: /private/' + PRIVATE + ' ' + navigation_geometry_line(
                                dict(reversed(list(payload.items())))) for payload in payloads]
                        lines += [case_line(method, event='failed', module=owner.rsplit('.', 1)[0])
                                  if '.' in owner else case_line(method, event='failed').replace(
                                      'MirrorIOSUITests.MirrorUITests', owner)]
                        output = self.capture(helper.report_ui_navigation_geometry_diagnostics, lines)
                        self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE),
                                         [{'scope': 'stdoutOnly', 'method': method, 'samples': payloads}])
                        self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE), [])
                        self.assertEqual(len(output.splitlines()), 1)
                        for inferred in ('belowStatus', 'frameInsideWindow', 'completed', 'success', 'event',
                                         'executedTests', '"result"'):
                            self.assertNotIn(inferred, output)
        self.assertEqual(self.capture(helper.report_ui_navigation_geometry_diagnostics, []), '')
        payload = navigation_geometry_payload(statusFrame=[-100000, 100000.0, 100000, 100000.0],
                                              windowFrame=[0, -0.0, 0.5, 1],
                                              buttonFrame=[1, -1, 1, 0.5])
        output = self.capture(helper.report_ui_navigation_geometry_diagnostics,
                              [started_line(METHODS[0]), navigation_geometry_line(payload)])
        self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE),
                         [{'scope': 'stdoutOnly', 'method': METHODS[0], 'samples': [payload]}])

        for width, height in ((0, 40), (40, 0), (0, 0)):
            with self.subTest(actual_zero_button=(width, height)):
                payload = navigation_geometry_payload(buttonFrame=[-10, -20.5, width, height])
                output = self.capture(helper.report_ui_navigation_geometry_diagnostics,
                                      [started_line(METHODS[0]), navigation_geometry_line(payload)])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE),
                                 [{'scope': 'stdoutOnly', 'method': METHODS[0], 'samples': [payload]}])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE), [])
                self.assertNotIn('belowStatus', output)
                self.assertNotIn('frameHasArea', output)

    def test_navigation_geometry_requires_unique_actual_case_and_fixed_stage_owner(self):
        valid = navigation_geometry_line(navigation_geometry_payload())
        start = started_line(METHODS[0])
        prefixes = [[], [started_line(METHODS[2])], [started_line(METHODS[0], 'OtherTests')],
                    [start, started_line(METHODS[1])], [start, start],
                    [start, start, case_line(METHODS[0]), start],
                    [start, started_line(METHODS[0], 'MirrorMacUITests.MirrorUITests')],
                    [start, "Test Case '-[broken]' started."],
                    [start + ' ' + started_line(METHODS[2])]]
        prefixes += [[start, case_line(METHODS[0], event=event)]
                     for event in ('passed', 'failed', 'skipped')]
        for prefix in prefixes:
            with self.subTest(prefix=prefix):
                output = self.capture(helper.report_ui_navigation_geometry_diagnostics, prefix + [valid])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE), [])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE), [{'invalidCount': 1}])
        recovery = navigation_geometry_line(navigation_geometry_payload('validation-recovery'))
        for method, line in ((METHODS[0], recovery), (METHODS[2], valid), (METHODS[1], recovery)):
            with self.subTest(wrong_stage_method=method):
                output = self.capture(helper.report_ui_navigation_geometry_diagnostics, [started_line(method), line])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE), [])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE), [{'invalidCount': 1}])
        for prefix in ([start, started_line(METHODS[1]), case_line(METHODS[1])],
                       [start, start, case_line(METHODS[0]), case_line(METHODS[0]), start]):
            output = self.capture(helper.report_ui_navigation_geometry_diagnostics, prefix + [valid])
            self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE),
                             [{'scope': 'stdoutOnly', 'method': METHODS[0],
                               'samples': [navigation_geometry_payload()]}])

    def test_navigation_geometry_rejects_duplicate_out_of_order_overcount_and_cross_execution_prefixes(self):
        start = started_line(METHODS[0])
        entries = [navigation_geometry_line(navigation_geometry_payload(stage, identifier))
                   for stage, identifier in NAVIGATION_GEOMETRY_PREFIXES[METHODS[0]]]
        invalid = navigation_geometry_line({**navigation_geometry_payload(), 'private': PRIVATE})
        samples = [([start, entries[1]], 1), ([start, entries[0], entries[2]], 1),
                   ([start, entries[0], entries[0]], 1), ([start] + entries + [entries[-1]], 1),
                   ([start, entries[0], case_line(METHODS[0]), start, entries[1]], 1),
                   ([start, entries[0], invalid], 1), ([start, invalid, entries[0]], 1),
                   ([entries[0], start, entries[0], case_line(METHODS[0]), entries[1]], 2)]
        recovery = [navigation_geometry_line(navigation_geometry_payload(stage, identifier))
                    for stage, identifier in NAVIGATION_GEOMETRY_PREFIXES[METHODS[2]]]
        samples += [([started_line(METHODS[2])] + recovery + [recovery[-1]], 1),
                    ([start, entries[0], case_line(METHODS[0]), started_line(METHODS[2]),
                      recovery[0], invalid], 1)]
        for lines, invalid_count in samples:
            with self.subTest(lines=lines):
                output = self.capture(helper.report_ui_navigation_geometry_diagnostics, lines)
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE), [])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE),
                                 [{'invalidCount': invalid_count}])
                self.assertEqual(len(output.splitlines()), 1)
        output = self.capture(helper.report_ui_navigation_geometry_diagnostics,
                              [start] + entries + [case_line(METHODS[0], event='failed'),
                                                    started_line(METHODS[2])] + recovery)
        self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE), [
            {'scope': 'stdoutOnly', 'method': method,
             'samples': [navigation_geometry_payload(stage, identifier) for stage, identifier in prefix]}
            for method, prefix in NAVIGATION_GEOMETRY_PREFIXES.items()])
        self.assertEqual(len(output.splitlines()), 2)

    def test_navigation_geometry_rejects_nonexact_schema_and_invalid_frame_numbers_without_leak(self):
        valid = navigation_geometry_payload()
        invalid = [{key: value for key, value in valid.items() if key != missing} for missing in valid]
        invalid += [{**valid, 'method': METHODS[0]}, {**valid, 'private': PRIVATE}, [], None, True]
        for key, bad in (('stage', 'detail'), ('identifier', 'capture.submit')):
            invalid += [{**valid, key: value} for value in (bad, PRIVATE, True, 1, None, [], {})]
        for key in ('statusFrame', 'windowFrame', 'buttonFrame'):
            invalid += [{**valid, key: value} for value in
                        (None, True, PRIVATE, {}, [], [0, 0, 1], [0, 0, 1, 1, 1],
                         {'minX': 0, 'minY': 0, 'width': 1, 'height': 1, 'private': PRIVATE})]
            for index in range(4):
                wrong_values = (True, False, None, PRIVATE, [], {}, float('nan'), float('inf'),
                                float('-inf'), 100001, -100001, 10 ** 400)
                if index >= 2:
                    wrong_values += (-1,) if key == 'buttonFrame' else (0, -1)
                for value in wrong_values:
                    frame = list(valid[key])
                    frame[index] = value
                    invalid.append({**valid, key: frame})
        for payload in invalid:
            with self.subTest(payload=payload):
                output = self.capture(helper.report_ui_navigation_geometry_diagnostics,
                                      [started_line(METHODS[0]), navigation_geometry_line(payload)])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE), [])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertEqual(len(output.splitlines()), 1)

    def test_navigation_geometry_rejects_duplicate_keys_trailing_raw_and_bounded_payload_before_parse(self):
        marker = 'UI navigation geometry diagnostic: '
        valid = navigation_geometry_payload()
        encoded = json.dumps(valid)
        bad_lines = [marker + encoded + ' error: /private/' + PRIVATE,
                     marker + encoded + ' ' + marker + PRIVATE,
                     marker + '{' + PRIVATE, marker + '[' * 1500 + '0' + ']' * 1500]
        for key in valid:
            duplicate = encoded.replace('"' + key + '":',
                                        '"' + key + '": "' + PRIVATE + '", "' + key + '":', 1)
            bad_lines.append(marker + duplicate)
        for line in bad_lines:
            output = self.capture(helper.report_ui_navigation_geometry_diagnostics,
                                  [started_line(METHODS[0]), line])
            self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE), [])
            self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE), [{'invalidCount': 1}])
        at_limit = encoded[:-1] + ' ' * (4096 - len(encoded.encode('utf-8'))) + '}'
        self.assertEqual(len(at_limit.encode('utf-8')), 4096)
        output = self.capture(helper.report_ui_navigation_geometry_diagnostics,
                              [started_line(METHODS[0]), marker + at_limit])
        self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE),
                         [{'scope': 'stdoutOnly', 'method': METHODS[0], 'samples': [valid]}])
        over_limit = json.dumps({**valid, 'private': PRIVATE + '한' * 1400}, ensure_ascii=False)
        self.assertLess(len(over_limit), 4096)
        self.assertGreater(len(over_limit.encode('utf-8')), 4096)
        for payload in (at_limit[:-1] + ' }', over_limit):
            with mock.patch.object(helper.json, 'loads', side_effect=AssertionError('over-limit payload parsed')):
                output = self.capture(helper.report_ui_navigation_geometry_diagnostics,
                                      [started_line(METHODS[0]), marker + payload])
            self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE), [])
            self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE), [{'invalidCount': 1}])

    def test_navigation_geometry_rejects_mixed_channels_and_registers_marker_against_reinterpretation(self):
        valid = navigation_geometry_line(navigation_geometry_payload())
        other_lines = [store_dedup_line(), keyboard_line(keyboard_frame_payload()), viewport_line({}),
                       phase_line({'method': PHASE_METHOD, 'phase': 'started'}),
                       native_screenshot_line(native_screenshot_payload()), toolbar_line(toolbar_payload()),
                       validation_recovery_line(validation_recovery_payload()), capture_phase_line(), ui_failure_line(),
                       screenshot_line('detail', '999'), started_line(METHODS[2])]
        other_lines += [case_line(event=event) for event in ('passed', 'failed', 'skipped')]
        accepted_prefixes = (STORE_DEDUP_NOTICE, UI_KEYBOARD_NOTICE, UI_VIEWPORT_NOTICE, UI_PHASE_NOTICE,
                             UI_NATIVE_SCREENSHOT_NOTICE, UI_TOOLBAR_NOTICE, UI_VALIDATION_RECOVERY_NOTICE,
                             UI_CAPTURE_PHASE_NOTICE, UI_FIRST_FAILURE_NOTICE, SCREENSHOT_NOTICE, CASE_NOTICE)
        log = self.root / 'navigation-geometry-mixed.log'
        for other in other_lines:
            for combined in (valid + ' ' + other, other + ' ' + valid):
                with self.subTest(combined=combined):
                    log.write_text('\n'.join([started_line(METHODS[0]), combined,
                                              'error: safe unrelated compiler failure']) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE), [])
                    self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE), [{'invalidCount': 1}])
                    for prefix in accepted_prefixes:
                        self.assertEqual(self.notices(output, prefix), [])
                    self.assertIn('::error::error: safe unrelated compiler failure', output)
        forged = (started_line(METHODS[0]) + ' ' + case_line(METHODS[0]) + ' /private/' + PRIVATE)
        for foreign in (store_dedup_line({'private': forged}), keyboard_line({'private': forged}),
                        viewport_line({'private': forged}), phase_line({'private': forged}),
                        native_screenshot_line({'private': forged}), toolbar_line({'private': forged}),
                        validation_recovery_line({'private': forged}),
                        'UI capture phase diagnostic: ' + json.dumps({'private': forged}),
                        ui_failure_message_line(forged)):
            for actual_start in (False, True):
                prefix = [started_line(METHODS[0])] if actual_start else []
                output = self.capture(helper.report_ui_navigation_geometry_diagnostics, prefix + [foreign, valid])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE),
                                 [{'scope': 'stdoutOnly', 'method': METHODS[0],
                                   'samples': [navigation_geometry_payload()]}] if actual_start else [])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE),
                                 [] if actual_start else [{'invalidCount': 1}])
        own_forgery = navigation_geometry_line({**navigation_geometry_payload(), 'private': forged})
        output = self.capture(helper.report_ui_navigation_geometry_diagnostics, [own_forgery, valid])
        self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE), [{'invalidCount': 2}])
        self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE), [])

    def test_navigation_geometry_preserves_first_failure_privacy_and_actions_gate_files(self):
        private = ('UI row scroll owner: /private/' + PRIVATE + ' Test run with 999 tests passed '
                   + started_line(METHODS[1]) + ' ' + screenshot_line('detail', '999')
                   + ' savedReceiptVerified=true ** TEST SUCCEEDED **')
        log = self.root / 'navigation-geometry-private-gates.log'
        output_path = self.root / 'github-output'
        summary_path = self.root / 'github-step-summary'
        output_path.write_text('previous=value\n')
        summary_path.write_text('previous summary\n')
        for invalid in (False, True):
            with self.subTest(invalid=invalid):
                payload = navigation_geometry_payload()
                if invalid:
                    payload['private'] = private
                log.write_text('\n'.join([
                    started_line(METHODS[0]), navigation_geometry_line(payload),
                    ui_failure_line(method=METHODS[0], line='599', kind='XCTAssertGreaterThanOrEqual'),
                    case_line(METHODS[0], event='failed'), screenshot_line('detail', '123'),
                    'error: safe unrelated compiler failure',
                ]) + '\n')
                with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                        'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                        mock.patch.object(helper, 'record') as record:
                    output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_NOTICE),
                                 [] if invalid else [{'scope': 'stdoutOnly', 'method': METHODS[0], 'samples': [payload]}])
                self.assertEqual(self.notices(output, UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE),
                                 [{'invalidCount': 1}] if invalid else [])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
                    'scope': 'stdoutOnly', 'method': METHODS[0], 'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift',
                    'line': 599, 'assertionKind': 'XCTAssertGreaterThanOrEqual',
                }])
                self.assertLess(output.index(UI_FIRST_FAILURE_NOTICE),
                                output.index(UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE if invalid
                                             else UI_NAVIGATION_GEOMETRY_NOTICE))
                self.assertEqual(self.notices(output, SCREENSHOT_NOTICE),
                                 [{'scope': 'stdoutOnly', 'stage': 'detail', 'milliseconds': 123}])
                for forbidden in ('/private/', 'savedReceiptVerified', 'UI row scroll owners:',
                                  'Swift Testing completion reports:', METHODS[1], 'executedTests', '"result": "pass"'):
                    self.assertNotIn(forbidden, output)
                self.assertFalse(self.notices(output, '::notice::UI stdout diagnostics: ')[0]['xcodeCompletionReported'])
                self.assertIn('::error::error: safe unrelated compiler failure', output)
                record.assert_not_called()
                self.assertEqual(output_path.read_text(), 'previous=value\n')
                self.assertEqual(summary_path.read_text(), 'previous summary\n')
        log.write_text(navigation_geometry_line({'private': private}) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(output.splitlines(), [UI_NAVIGATION_GEOMETRY_REJECTED_NOTICE + '{"invalidCount": 1}'])

    def test_validation_recovery_preserves_false_null_and_exact_safe_wrapper(self):
        log = self.root / 'validation-recovery-valid.log'
        for owner in ('MirrorUITests', 'MirrorIOSUITests.MirrorUITests', 'MirrorMacUITests.MirrorUITests'):
            for observed in (False, True):
                for inside in (False, True, None):
                    for below in (False, True, None):
                        with self.subTest(owner=owner, observed=observed, inside=inside, below=below):
                            payload = validation_recovery_payload(
                                **{key: observed for key in VALIDATION_RECOVERY_BOOL_FIELDS},
                                frameInsideWindow=inside, belowStatus=below)
                            reversed_payload = dict(reversed(list(payload.items())))
                            reversed_payload['checks'] = dict(reversed(list(payload['checks'].items())))
                            log.write_text('\n'.join([
                                started_line(VALIDATION_RECOVERY_METHOD, owner),
                                'fatal: /private/' + PRIVATE + ' ' + validation_recovery_line(reversed_payload),
                                case_line(VALIDATION_RECOVERY_METHOD, event='failed').replace(
                                    'MirrorIOSUITests.MirrorUITests', owner),
                            ]) + '\n')
                            output = self.capture(helper.diagnostics, log)
                            self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE),
                                             [{'scope': 'stdoutOnly', **payload}])
                            self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_REJECTED_NOTICE), [])
                            self.assertNotIn('::error::', output)
        self.assertEqual(self.capture(helper.report_ui_validation_recovery_diagnostics, []), '')

    def test_validation_recovery_requires_unique_active_case_and_rejects_before_after_probes(self):
        valid = validation_recovery_line(validation_recovery_payload())
        start = started_line(VALIDATION_RECOVERY_METHOD)
        prefixes = [[], [started_line(METHODS[0])], [started_line(VALIDATION_RECOVERY_METHOD, 'OtherTests')],
                    [start, started_line(METHODS[0])], [start, start],
                    [start, start, case_line(VALIDATION_RECOVERY_METHOD), start],
                    [start, started_line(VALIDATION_RECOVERY_METHOD, 'MirrorMacUITests.MirrorUITests')],
                    [start, "Test Case '-[broken]' started."]]
        prefixes += [[start, case_line(VALIDATION_RECOVERY_METHOD, event=event)]
                     for event in ('passed', 'failed', 'skipped')]
        for prefix in prefixes:
            with self.subTest(prefix=prefix):
                output = self.capture(helper.report_ui_validation_recovery_diagnostics, prefix + [valid])
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE), [])
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_REJECTED_NOTICE), [{'invalidCount': 1}])
        for prefix in ([start, started_line(METHODS[0]), case_line(METHODS[0])],
                       [start, start, case_line(VALIDATION_RECOVERY_METHOD),
                        case_line(VALIDATION_RECOVERY_METHOD), start]):
            with self.subTest(recovered_prefix=prefix):
                output = self.capture(helper.report_ui_validation_recovery_diagnostics, prefix + [valid])
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE),
                                 [{'scope': 'stdoutOnly', **validation_recovery_payload()}])
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_REJECTED_NOTICE), [])

    def test_validation_recovery_is_once_per_transcript_and_any_invalid_suppresses_acceptance(self):
        valid = validation_recovery_line(validation_recovery_payload())
        invalid = validation_recovery_line({**validation_recovery_payload(), 'private': PRIVATE})
        start = started_line(VALIDATION_RECOVERY_METHOD)
        samples = [([start, valid, valid], 1), ([start, valid, invalid], 1),
                   ([start, invalid, valid], 1),
                   ([start, valid, case_line(VALIDATION_RECOVERY_METHOD), start, valid], 1),
                   ([valid, start, valid, case_line(VALIDATION_RECOVERY_METHOD), valid], 2)]
        for lines, invalid_count in samples:
            with self.subTest(lines=lines):
                output = self.capture(helper.report_ui_validation_recovery_diagnostics, lines)
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE), [])
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_REJECTED_NOTICE),
                                 [{'invalidCount': invalid_count}])
                self.assertEqual(len(output.splitlines()), 1)

    def test_validation_recovery_rejects_wrong_identity_nonexact_schema_and_nonbool_flags(self):
        valid = validation_recovery_payload()
        invalid = []
        for key, wrong in (('method', METHODS[0]), ('action', 'settings.button'), ('phase', 'started')):
            invalid += [{**valid, key: value} for value in (wrong, PRIVATE, True, 1, None, [], {})]
        invalid += [{key: value for key, value in valid.items() if key != missing} for missing in valid]
        invalid += [{**valid, 'private': PRIVATE}, {**valid, 'savedReceiptVerified': True},
                    {**valid, 'checks': {}}, {**valid, 'checks': None},
                    {**valid, 'checks': []}, {**valid, 'checks': True}, [], None, True]
        for key in VALIDATION_RECOVERY_BOOL_FIELDS:
            invalid += [{**valid, 'checks': {**valid['checks'], key: value}}
                        for value in (0, 1, 0.0, 1.0, 'true', 'false', None, [], {}, PRIVATE)]
        for key in VALIDATION_RECOVERY_NULLABLE_FIELDS:
            invalid += [{**valid, 'checks': {**valid['checks'], key: value}}
                        for value in (0, 1, 0.0, 'true', 'null', [], {}, PRIVATE)]
        for key in (*VALIDATION_RECOVERY_BOOL_FIELDS, *VALIDATION_RECOVERY_NULLABLE_FIELDS):
            invalid.append({**valid, 'checks': {name: value for name, value in valid['checks'].items()
                                              if name != key}})
        invalid += [{**valid, 'checks': {**valid['checks'], key: value}} for key, value in
                    (('frameX', 1), ('title', PRIVATE), ('identifier', 'capture.open'),
                     ('savedReceiptVerified', True), (PRIVATE, False))]
        for payload in invalid:
            with self.subTest(payload=payload):
                output = self.capture(helper.report_ui_validation_recovery_diagnostics,
                                      [started_line(VALIDATION_RECOVERY_METHOD), validation_recovery_line(payload)])
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE), [])
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertEqual(len(output.splitlines()), 1)

    def test_validation_recovery_rejects_duplicate_keys_malformed_and_utf8_byte_limits(self):
        valid = validation_recovery_payload()
        encoded = json.dumps(valid)
        bad_lines = [validation_recovery_line(valid) + ' error: /private/' + PRIVATE,
                     validation_recovery_line(valid) + ' UI validation recovery diagnostic: ' + PRIVATE,
                     'UI validation recovery diagnostic: {' + PRIVATE,
                     'UI validation recovery diagnostic: ' + '[' * 1500 + '0' + ']' * 1500]
        for key in valid:
            duplicate = encoded.replace('"' + key + '":',
                                        '"' + key + '": "' + PRIVATE + '", "' + key + '":', 1)
            bad_lines.append('UI validation recovery diagnostic: ' + duplicate)
        for key in valid['checks']:
            duplicate = encoded.replace('"' + key + '":',
                                        '"' + key + '": "' + PRIVATE + '", "' + key + '":', 1)
            bad_lines.append('UI validation recovery diagnostic: ' + duplicate)
        log = self.root / 'validation-recovery-malformed.log'
        for bad in bad_lines:
            with self.subTest(bad=bad):
                log.write_text('\n'.join([started_line(VALIDATION_RECOVERY_METHOD), bad]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE), [])
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertNotIn('::error::', output)
        at_limit = encoded[:-1] + ' ' * (4096 - len(encoded.encode('utf-8'))) + '}'
        self.assertEqual(len(at_limit.encode('utf-8')), 4096)
        output = self.capture(helper.report_ui_validation_recovery_diagnostics,
                              [started_line(VALIDATION_RECOVERY_METHOD),
                               'UI validation recovery diagnostic: ' + at_limit])
        self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE), [{'scope': 'stdoutOnly', **valid}])
        over_limit = json.dumps({**valid, 'private': PRIVATE + '한' * 1400}, ensure_ascii=False)
        self.assertLess(len(over_limit), 4096)
        self.assertGreater(len(over_limit.encode('utf-8')), 4096)
        for payload in (at_limit[:-1] + ' }', over_limit):
            with self.subTest(payload_bytes=len(payload.encode('utf-8'))), \
                    mock.patch.object(helper.json, 'loads', side_effect=AssertionError('over-limit payload parsed')):
                output = self.capture(helper.report_ui_validation_recovery_diagnostics,
                                      [started_line(VALIDATION_RECOVERY_METHOD),
                                       'UI validation recovery diagnostic: ' + payload])
            self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE), [])
            self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_REJECTED_NOTICE), [{'invalidCount': 1}])

    def test_validation_recovery_rejects_all_mixed_channels_and_case_events_in_both_orders(self):
        keyboard = {'phase': 'continueReadiness', 'continueCandidateCount': 1,
                    'keyboardBoundsValid': True, 'elapsedMilliseconds': 15000}
        others = [store_dedup_line(), keyboard_line(keyboard), viewport_line({}),
                  phase_line({'method': PHASE_METHOD, 'phase': 'started'}),
                  native_screenshot_line(native_screenshot_payload()), toolbar_line(toolbar_payload()),
                  ui_failure_line(method=VALIDATION_RECOVERY_METHOD), screenshot_line('detail', '999'),
                  started_line(METHODS[0])]
        others += [case_line(VALIDATION_RECOVERY_METHOD, event=event)
                   for event in ('passed', 'failed', 'skipped')]
        prefixes = (STORE_DEDUP_NOTICE, UI_KEYBOARD_NOTICE, UI_VIEWPORT_NOTICE, UI_PHASE_NOTICE,
                    UI_NATIVE_SCREENSHOT_NOTICE, UI_TOOLBAR_NOTICE, UI_FIRST_FAILURE_NOTICE,
                    SCREENSHOT_NOTICE, CASE_NOTICE)
        log = self.root / 'validation-recovery-mixed.log'
        for other in others:
            recovery = validation_recovery_line(validation_recovery_payload())
            for combined in (recovery + ' ' + other, other + ' ' + recovery):
                with self.subTest(combined=combined):
                    log.write_text('\n'.join([started_line(VALIDATION_RECOVERY_METHOD), combined,
                                              'error: safe unrelated compiler failure']) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE), [])
                    self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_REJECTED_NOTICE), [{'invalidCount': 1}])
                    for prefix in prefixes:
                        self.assertEqual(self.notices(output, prefix), [])
                    self.assertIn('::error::error: safe unrelated compiler failure', output)

    def test_validation_recovery_ignores_forged_active_events_in_existing_structured_channels(self):
        forged = (started_line(VALIDATION_RECOVERY_METHOD) + ' ' + case_line(VALIDATION_RECOVERY_METHOD)
                  + ' ' + started_line(METHODS[1]) + ' /private/' + PRIVATE)
        lines = [store_dedup_line({'states': [], 'busyResults': [], 'private': forged}),
                 keyboard_line({'private': forged}), viewport_line({'private': forged}),
                 phase_line({'method': PHASE_METHOD, 'phase': 'started', 'private': forged}),
                 native_screenshot_line({**native_screenshot_payload(), 'private': forged}),
                 toolbar_line({**toolbar_payload(), 'private': forged}),
                 ui_failure_message_line(forged)]
        log = self.root / 'validation-recovery-forged-events.log'
        for forged_line in lines:
            for actual_start in (False, True):
                with self.subTest(forged_line=forged_line, actual_start=actual_start):
                    prefix = [started_line(VALIDATION_RECOVERY_METHOD)] if actual_start else []
                    log.write_text('\n'.join(prefix + [forged_line,
                                                      validation_recovery_line(validation_recovery_payload())]) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    expected = [{'scope': 'stdoutOnly', **validation_recovery_payload()}] if actual_start else []
                    self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE), expected)
                    self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_REJECTED_NOTICE),
                                     [] if actual_start else [{'invalidCount': 1}])
                    self.assertNotIn(METHODS[1], output)
        own_forgery = validation_recovery_line({**validation_recovery_payload(), 'private': forged})
        output = self.capture(helper.report_ui_validation_recovery_diagnostics,
                              [own_forgery, validation_recovery_line(validation_recovery_payload())])
        self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE), [])
        self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_REJECTED_NOTICE), [{'invalidCount': 2}])

    def test_validation_recovery_preserves_first_failure_privacy_and_actions_outputs(self):
        private = ('UI row scroll owner: /private/' + PRIVATE + ' Test run with 999 tests passed '
                   + started_line(METHODS[1]) + ' ' + screenshot_line('detail', '999')
                   + ' savedReceiptVerified=true frame=(1,2,3,4) ** TEST SUCCEEDED **')
        log = self.root / 'validation-recovery-private-gates.log'
        output_path = self.root / 'github-output'
        summary_path = self.root / 'github-step-summary'
        output_path.write_text('previous=value\n')
        summary_path.write_text('previous summary\n')
        for invalid in (False, True):
            with self.subTest(invalid=invalid):
                payload = validation_recovery_payload(hittable=False, belowStatus=None)
                if invalid:
                    payload['private'] = private
                log.write_text('\n'.join([
                    started_line(VALIDATION_RECOVERY_METHOD), validation_recovery_line(payload),
                    ui_failure_message_line('UI 요소에 도달할 수 없다: capture.open. ' + private,
                                            method=VALIDATION_RECOVERY_METHOD, line='284', kind='XCTFail'),
                    case_line(VALIDATION_RECOVERY_METHOD, event='failed'), screenshot_line('detail', '123'),
                    'error: safe unrelated compiler failure',
                ]) + '\n')
                with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                        'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                        mock.patch.object(helper, 'record') as record:
                    output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_NOTICE),
                                 [] if invalid else [{'scope': 'stdoutOnly', **payload}])
                self.assertEqual(self.notices(output, UI_VALIDATION_RECOVERY_REJECTED_NOTICE),
                                 [{'invalidCount': 1}] if invalid else [])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
                    'scope': 'stdoutOnly', 'method': VALIDATION_RECOVERY_METHOD,
                    'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 284,
                    'assertionKind': 'XCTFail', 'failureReason': 'unhittableOrDisabled',
                }])
                self.assertLess(output.index(UI_FIRST_FAILURE_NOTICE),
                                output.index(UI_VALIDATION_RECOVERY_REJECTED_NOTICE if invalid
                                             else UI_VALIDATION_RECOVERY_NOTICE))
                self.assertEqual(self.notices(output, SCREENSHOT_NOTICE),
                                 [{'scope': 'stdoutOnly', 'stage': 'detail', 'milliseconds': 123}])
                for forbidden in ('/private/', 'frame=', 'savedReceiptVerified', 'UI row scroll owners:',
                                  'Swift Testing completion reports:', METHODS[1], 'executedTests', '"result": "pass"'):
                    self.assertNotIn(forbidden, output)
                self.assertFalse(self.notices(output, '::notice::UI stdout diagnostics: ')[0]['xcodeCompletionReported'])
                self.assertIn('::error::error: safe unrelated compiler failure', output)
                record.assert_not_called()
                self.assertEqual(output_path.read_text(), 'previous=value\n')
                self.assertEqual(summary_path.read_text(), 'previous summary\n')
        log.write_text(validation_recovery_line({'private': private}) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(output.splitlines(), [UI_VALIDATION_RECOVERY_REJECTED_NOTICE + '{"invalidCount": 1}'])

    def test_validation_recovery_cannot_replace_real_success_failure_skip_or_execution_gates(self):
        output_path = self.root / 'github-output'
        output_path.write_text('previous=value\n')
        log = self.root / 'validation-recovery-swift-gates.log'
        recovery = [started_line(VALIDATION_RECOVERY_METHOD),
                    validation_recovery_line(validation_recovery_payload())]
        for reports in ([], ['Test run with 159 tests passed after 0.1 seconds.'],
                        ['Test run with 36 tests passed after 0.1 seconds.',
                         'Test run with 94 tests failed after 0.1 seconds.',
                         'Test run with 29 tests passed after 0.1 seconds.'],
                        ['Test run with 36 tests passed after 0.1 seconds.',
                         'Test run with 94 tests passed after 0.1 seconds.',
                         'Test run with 29 tests passed after 0.1 seconds.', '1 test skipped']):
            with self.subTest(reports=reports):
                log.write_text('\n'.join(recovery + reports) + '\n')
                with mock.patch.object(helper.sys, 'argv', ['ci_results.py', 'swift', str(log)]), \
                        mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                        mock.patch.object(helper, 'record') as record, self.assertRaises(ValueError):
                    self.capture(helper.main)
                record.assert_not_called()
                self.assertEqual(output_path.read_text(), 'previous=value\n')
        summary = self.root / 'validation-recovery-xcode-summary.json'
        for total, passed, failed, skipped in ((0, 0, 0, 0), (6, 5, 1, 0), (6, 5, 0, 1), (6, 5, 0, 0)):
            with self.subTest(total=total, passed=passed, failed=failed, skipped=skipped):
                summary.write_text(json.dumps({'totalTestCount': total, 'passedTests': passed,
                                               'failedTests': failed, 'skippedTests': skipped}))
                with mock.patch.object(helper.sys, 'argv', ['ci_results.py', 'xcode', str(summary)]), \
                        mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}), \
                        mock.patch.object(helper, 'record') as record, self.assertRaises(ValueError):
                    self.capture(helper.main)
                record.assert_not_called()
                self.assertEqual(output_path.read_text(), 'previous=value\n')
        source = self.root / 'validation-recovery-ui-source'
        source.mkdir()
        (source / 'MirrorUITests.swift').write_text('\n'.join('func ' + method + '() {}' for method in METHODS))
        tree_path = self.root / 'validation-recovery-ui-tree.json'
        for results in ([('Passed', method) for method in METHODS[:-1]],
                        [('Failed' if method == VALIDATION_RECOVERY_METHOD else 'Passed', method) for method in METHODS],
                        [('Skipped' if method == VALIDATION_RECOVERY_METHOD else 'Passed', method) for method in METHODS]):
            with self.subTest(results=results):
                tree_path.write_text(json.dumps({'testNodes': [{'nodeType': 'UI test bundle', 'name': 'MirrorIOSUITests',
                    'result': 'Passed', 'children': [{'nodeType': 'Test Case', 'name': method + '()', 'result': result}
                                                   for result, method in results]}]}))
                with self.assertRaises(ValueError):
                    self.capture(helper.ui_guard, tree_path, 'MirrorIOSUITests', source)
        summary.write_text(json.dumps({'totalTestCount': 6, 'passedTests': 6, 'failedTests': 0, 'skippedTests': 0}))
        with mock.patch.object(helper.sys, 'argv', ['ci_results.py', 'xcode', str(summary)]), \
                mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path)}):
            output = self.capture(helper.main)
        self.assertIn('"executedTests": 6, "result": "pass"', output)
        self.assertEqual(output_path.read_text(), 'previous=value\ntests=6\n')

    def test_toolbar_diagnostic_preserves_false_observations_and_incomplete_ordered_prefixes(self):
        log = self.root / 'toolbar-prefix.log'
        for owner in ('MirrorUITests', 'MirrorIOSUITests.MirrorUITests'):
            for hittable in (False, True):
                for below_status in (False, True):
                    for inside_window in (False, True):
                        for length in (1, 2):
                            with self.subTest(owner=owner, hittable=hittable, below=below_status,
                                              inside=inside_window, length=length):
                                payloads = [toolbar_payload(identifier, hittable=hittable,
                                                            belowStatus=below_status,
                                                            frameInsideWindow=inside_window)
                                            for identifier in ('capture.open', 'settings.button')[:length]]
                                log.write_text('\n'.join([started_line(PHASE_METHOD, owner)]
                                                         + ['fatal: /private/' + PRIVATE + ' ' + toolbar_line(payload)
                                                            for payload in payloads]
                                                         + [case_line(PHASE_METHOD, event='failed')]) + '\n')
                                output = self.capture(helper.diagnostics, log)
                                self.assertEqual(self.notices(output, UI_TOOLBAR_NOTICE), [{
                                    'scope': 'stdoutOnly', 'method': PHASE_METHOD,
                                    'buttons': [{key: payload[key] for key in
                                                 ('identifier', 'hittable', 'belowStatus', 'frameInsideWindow')}
                                                for payload in payloads],
                                }])
                                self.assertEqual(self.notices(output, UI_TOOLBAR_REJECTED_NOTICE), [])
                                self.assertNotIn('::error::', output)
        self.assertEqual(self.capture(helper.report_ui_toolbar_diagnostics, []), '')

    def test_toolbar_diagnostic_requires_unique_active_tomorrow_case_and_ignores_forged_events(self):
        log = self.root / 'toolbar-active.log'
        prefixes = [[], [started_line(METHODS[0])], [started_line(PHASE_METHOD, 'OtherTests')],
                    [started_line(PHASE_METHOD), started_line(METHODS[0])],
                    [started_line(PHASE_METHOD), case_line(PHASE_METHOD)],
                    [started_line(PHASE_METHOD), "Test Case '-[broken]' started."],
                    [phase_line({'method': PHASE_METHOD, 'phase': 'started',
                                 'private': started_line(PHASE_METHOD) + PRIVATE})]]
        for prefix in prefixes:
            with self.subTest(prefix=prefix):
                log.write_text('\n'.join(prefix + [toolbar_line(toolbar_payload())]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_TOOLBAR_NOTICE), [])
                self.assertEqual(self.notices(output, UI_TOOLBAR_REJECTED_NOTICE), [{'invalidCount': 1}])
        log.write_text('\n'.join([started_line(PHASE_METHOD), started_line(METHODS[0]),
                                  case_line(METHODS[0]), toolbar_line(toolbar_payload(hittable=False))]) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(len(self.notices(output, UI_TOOLBAR_NOTICE)), 1)
        self.assertFalse(self.notices(output, UI_TOOLBAR_NOTICE)[0]['buttons'][0]['hittable'])

    def test_toolbar_diagnostic_rejects_wrong_order_duplicates_and_extra_records_as_whole_transcript(self):
        capture, settings = toolbar_payload(), toolbar_payload('settings.button')
        sequences = ([settings], [capture, capture], [capture, settings, capture],
                     [capture, settings, settings])
        log = self.root / 'toolbar-order.log'
        for sequence in sequences:
            with self.subTest(sequence=sequence):
                log.write_text('\n'.join([started_line(PHASE_METHOD)]
                                         + [toolbar_line(payload) for payload in sequence]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_TOOLBAR_NOTICE), [])
                self.assertEqual(self.notices(output, UI_TOOLBAR_REJECTED_NOTICE), [{'invalidCount': 1}])

    def test_toolbar_diagnostic_rejects_bool_as_int_private_values_and_nonexact_schema(self):
        valid = toolbar_payload('settings.button')
        invalid = []
        for key in ('hittable', 'belowStatus', 'frameInsideWindow'):
            invalid += [{**valid, key: value} for value in (0, 1, 0.0, 'true', None, [], {}, PRIVATE)]
        for key in ('method', 'identifier'):
            invalid += [{**valid, key: value} for value in (PRIVATE, True, None, [], {})]
        invalid += [{**valid, 'method': METHODS[0]}, {**valid, 'identifier': 'task.complete'},
                    {**valid, 'private': PRIVATE}, {**valid, 'frame': '/private/' + PRIVATE},
                    {key: value for key, value in valid.items() if key != 'belowStatus'}, [], None]
        log = self.root / 'toolbar-schema.log'
        for payload in invalid:
            with self.subTest(payload=payload):
                log.write_text('\n'.join([started_line(PHASE_METHOD), toolbar_line(toolbar_payload()),
                                          toolbar_line(payload)]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_TOOLBAR_NOTICE), [])
                self.assertEqual(self.notices(output, UI_TOOLBAR_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertNotIn('::error::', output)

    def test_toolbar_diagnostic_rejects_malformed_duplicate_keys_and_utf8_byte_limit_without_raw_fallback(self):
        valid = toolbar_payload('settings.button')
        bad_lines = [toolbar_line(valid) + ' error: /private/' + PRIVATE,
                     toolbar_line(valid) + ' UI search toolbar diagnostic: ' + PRIVATE,
                     'UI search toolbar diagnostic: {' + PRIVATE,
                     'UI search toolbar diagnostic: ' + '[' * 1500 + '0' + ']' * 1500,
                     toolbar_line(valid).replace('"hittable": true', '"hittable":"' + PRIVATE + '","hittable":true')]
        log = self.root / 'toolbar-malformed.log'
        for bad in bad_lines:
            with self.subTest(bad=bad):
                log.write_text('\n'.join([started_line(PHASE_METHOD), toolbar_line(toolbar_payload()), bad]) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_TOOLBAR_NOTICE), [])
                self.assertEqual(self.notices(output, UI_TOOLBAR_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertNotIn('::error::', output)
        over_limit = json.dumps({**valid, 'private': PRIVATE + '한' * 1400}, ensure_ascii=False)
        self.assertLess(len(over_limit), 4096)
        self.assertGreater(len(over_limit.encode('utf-8')), 4096)
        with mock.patch.object(helper.json, 'loads', side_effect=AssertionError('over-limit payload parsed')):
            output = self.capture(helper.report_ui_toolbar_diagnostics,
                                  [started_line(PHASE_METHOD), 'UI search toolbar diagnostic: ' + over_limit])
        self.assertEqual(self.notices(output, UI_TOOLBAR_REJECTED_NOTICE), [{'invalidCount': 1}])

    def test_toolbar_diagnostic_rejects_cross_channel_markers_and_mixed_case_event_in_both_orders(self):
        keyboard = {'phase': 'continueReadiness', 'continueCandidateCount': 1,
                    'keyboardBoundsValid': True, 'elapsedMilliseconds': 15000}
        old_lines = [store_dedup_line(), keyboard_line(keyboard), viewport_line({}),
                     native_screenshot_line(native_screenshot_payload()),
                     phase_line({'method': PHASE_METHOD, 'phase': 'started'}), ui_failure_line(),
                     started_line(METHODS[0])]
        log = self.root / 'toolbar-mixed.log'
        for other in old_lines:
            for combined in (toolbar_line(toolbar_payload()) + ' ' + other,
                             other + ' ' + toolbar_line(toolbar_payload())):
                with self.subTest(combined=combined):
                    log.write_text('\n'.join([started_line(PHASE_METHOD), combined,
                                              'error: safe unrelated compiler failure']) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    self.assertEqual(self.notices(output, UI_TOOLBAR_NOTICE), [])
                    self.assertEqual(self.notices(output, UI_TOOLBAR_REJECTED_NOTICE), [{'invalidCount': 1}])
                    for prefix in (STORE_DEDUP_NOTICE, UI_KEYBOARD_NOTICE, UI_VIEWPORT_NOTICE,
                                   UI_NATIVE_SCREENSHOT_NOTICE, UI_PHASE_NOTICE, UI_FIRST_FAILURE_NOTICE):
                        self.assertEqual(self.notices(output, prefix), [])
                    self.assertIn('::error::error: safe unrelated compiler failure', output)

    def test_toolbar_diagnostic_keeps_failure_priority_and_never_writes_success_or_actions_outputs(self):
        private = ('UI row scroll owner: /private/' + PRIVATE + ' Test run with 999 tests passed '
                   + started_line(METHODS[1]) + ' ' + screenshot_line('detail', '999'))
        log = self.root / 'toolbar-private-gates.log'
        output_path = self.root / 'github-output'
        summary_path = self.root / 'github-step-summary'
        output_path.write_text('previous=value\n')
        summary_path.write_text('previous summary\n')
        log.write_text('\n'.join([started_line(PHASE_METHOD),
                                  toolbar_line(toolbar_payload()),
                                  toolbar_line({**toolbar_payload('settings.button'), 'private': private}),
                                  case_line(PHASE_METHOD, event='failed'),
                                  screenshot_line('detail', '123'), 'error: safe unrelated compiler failure']) + '\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_TOOLBAR_NOTICE), [])
        self.assertEqual(self.notices(output, UI_TOOLBAR_REJECTED_NOTICE), [{'invalidCount': 1}])
        self.assertEqual(self.notices(output, SCREENSHOT_NOTICE),
                         [{'scope': 'stdoutOnly', 'stage': 'detail', 'milliseconds': 123}])
        self.assertNotIn('UI row scroll owners:', output)
        self.assertNotIn('Swift Testing completion reports:', output)
        self.assertNotIn(METHODS[1], output)
        self.assertNotIn('executedTests', output)
        self.assertNotIn('"result": "pass"', output)
        self.assertIn('::error::error: safe unrelated compiler failure', output)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')
        self.assertEqual(summary_path.read_text(), 'previous summary\n')
        log.write_text('\n'.join([started_line(PHASE_METHOD), toolbar_line(toolbar_payload(hittable=False)),
                                  ui_failure_line(method=PHASE_METHOD, line='155'),
                                  case_line(PHASE_METHOD, event='failed')]) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(len(self.notices(output, UI_FIRST_FAILURE_NOTICE)), 1)
        self.assertEqual(len(self.notices(output, UI_TOOLBAR_NOTICE)), 1)
        self.assertLess(output.index(UI_FIRST_FAILURE_NOTICE), output.index(UI_TOOLBAR_NOTICE))

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
                                     [{'scope': 'stdoutOnly', 'method': PHASE_METHOD,
                                       'phases': list(PHASES[:length])}])
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
        self.assertEqual(self.notices(output, UI_PHASE_NOTICE),
                         [{'scope': 'stdoutOnly', 'method': PHASE_METHOD, 'phases': ['started']}])

    def test_full_phase_prefix_is_one_notice_after_failure_keyboard_viewport_and_native_diagnostics(self):
        keyboard = {'phase': 'continueReadiness', 'continueCandidateCount': 0,
                    'keyboardBoundsValid': True, 'elapsedMilliseconds': 15000,
                    'continueQueryCount': 1, 'continueExistingCount': 1,
                    'continueHittableCount': 0, 'continueEnabledCount': 0,
                    'continueInKeyboardCount': 0}
        viewport = {'orientation': 'landscape', 'stableSamples': 0, 'elapsedMilliseconds': 15000,
                    'checks': {'columnsSeparate': False}}
        native = native_screenshot_payload()
        log = self.root / 'phase-notice-priority.log'
        log.write_text('\n'.join(
            [started_line(PHASE_METHOD)]
            + [phase_line({'method': PHASE_METHOD, 'phase': phase}) for phase in PHASES]
            + [case_line(PHASE_METHOD, event='failed'), started_line(NATIVE_SCREENSHOT_METHOD),
               native_screenshot_line(native), viewport_line(viewport), keyboard_line(keyboard),
               ui_failure_line(line='481', kind='XCTAssertEqual'), case_line(event='failed'),
               screenshot_line('detail', '123')]
        ) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_PHASE_NOTICE),
                         [{'scope': 'stdoutOnly', 'method': PHASE_METHOD, 'phases': list(PHASES)}])
        self.assertEqual(self.notices(output, UI_PHASE_REJECTED_NOTICE), [])
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [{'scope': 'stdoutOnly', **keyboard}])
        self.assertEqual(self.notices(output, UI_VIEWPORT_NOTICE), [{'scope': 'stdoutOnly', **viewport}])
        self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_NOTICE), [{'scope': 'stdoutOnly', **native}])
        priority = (UI_FIRST_FAILURE_NOTICE, UI_KEYBOARD_NOTICE, UI_VIEWPORT_NOTICE,
                    UI_NATIVE_SCREENSHOT_NOTICE, UI_PHASE_NOTICE, '::notice::UI stdout diagnostics: ')
        for earlier, later in zip(priority, priority[1:]):
            self.assertLess(output.index(earlier), output.index(later))

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

    def test_native_screenshot_cli_only_reports_strict_metadata_without_success_or_actions_writes(self):
        valid = native_screenshot_payload()
        samples = (
            ('', [], []),
            ('\n'.join([started_line(NATIVE_SCREENSHOT_METHOD),
                        'fatal: /private/' + PRIVATE + ' ' + native_screenshot_line(valid),
                        ui_failure_line(), case_line(event='failed'),
                        'Test run with 999 tests passed after 0.2 seconds.']),
             [{'scope': 'stdoutOnly', **valid}], []),
            ('\n'.join([started_line(NATIVE_SCREENSHOT_METHOD),
                        native_screenshot_line({**valid, 'private': PRIVATE}), case_line()]),
             [], [{'invalidCount': 1}]),
        )
        log = self.root / 'native-cli.log'
        output_path = self.root / 'github-output'
        summary_path = self.root / 'github-step-summary'
        output_path.write_text('previous=value\n')
        summary_path.write_text('previous summary\n')
        for text, expected, rejected in samples:
            with self.subTest(text=text):
                log.write_text(text)
                with mock.patch.object(helper.sys, 'argv',
                                       ['ci_results.py', 'native-screenshot-diagnostics', str(log)]), \
                        mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                            'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                        mock.patch.object(helper, 'record') as record, \
                        mock.patch.object(helper, 'diagnostics') as diagnostics:
                    output = self.capture(helper.main)
                self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_NOTICE), expected)
                self.assertEqual(self.notices(output, UI_NATIVE_SCREENSHOT_REJECTED_NOTICE), rejected)
                self.assertEqual(len(output.splitlines()), len(expected) + len(rejected))
                record.assert_not_called()
                diagnostics.assert_not_called()
                self.assertEqual(output_path.read_text(), 'previous=value\n')
                self.assertEqual(summary_path.read_text(), 'previous summary\n')
                self.assertNotIn('executedTests', output)
                self.assertNotIn('"result": "pass"', output)

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

    def test_keyboard_frame_diagnostic_preserves_legacy_schemas_and_nullable_singleton_contexts(self):
        self.assertEqual(helper.UI_KEYBOARD_FRAME_FIELDS, KEYBOARD_FRAME_FIELDS)
        valid = keyboard_frame_payload()
        basic = {key: valid[key] for key in
                 ('phase', 'continueCandidateCount', 'keyboardBoundsValid', 'elapsedMilliseconds')}
        extended = {key: value for key, value in valid.items() if key not in KEYBOARD_FRAME_FIELDS}
        samples = [basic, extended, valid]
        for counts in ((0, 0, 0, 0, 0), (5, 4, 3, 2, 1), (100, 100, 100, 100, 100)):
            samples.append({**valid, **dict(zip(helper.UI_KEYBOARD_COUNT_FIELDS, counts)),
                            'continueCandidateCount': counts[-1],
                            **dict.fromkeys(KEYBOARD_FRAME_FIELDS)})
        samples.append({**valid, 'continueFrameHasArea': False,
                        **dict.fromkeys(KEYBOARD_FRAME_FIELDS[1:])})
        for inside, center, intersects in ((False, False, False), (False, False, True),
                                          (False, True, True), (True, True, True)):
            samples.append({**valid, 'continueCandidateCount': int(inside),
                            'continueInKeyboardCount': int(inside),
                            'continueFrameInsideKeyboard': inside,
                            'continueFrameCenterInsideKeyboard': center,
                            'continueFrameIntersectsKeyboard': intersects})
        log = self.root / 'keyboard-frame-contexts.log'
        for phase in ('continueReadiness', 'introductionDismissal'):
            for milliseconds in (0, 1200000):
                for sample in samples:
                    with self.subTest(phase=phase, milliseconds=milliseconds, sample=sample):
                        payload = {**sample, 'phase': phase, 'elapsedMilliseconds': milliseconds}
                        log.write_text(keyboard_line(payload) + '\n')
                        output = self.capture(helper.diagnostics, log)
                        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE),
                                         [{'scope': 'stdoutOnly', **payload}])
                        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [])
                        self.assertNotIn('::error::', output)

    def test_keyboard_frame_diagnostic_rejects_wrong_null_context_types_and_geometry_contradictions(self):
        valid = keyboard_frame_payload()
        invalid = []
        for key in KEYBOARD_FRAME_FIELDS:
            invalid.append({name: value for name, value in valid.items() if name != key})
            invalid += [{**valid, key: value} for value in (0, 1, 'true', [], {}, PRIVATE)]
        invalid.append({**valid, 'continueFrameHasArea': None})
        for key in KEYBOARD_FRAME_FIELDS[1:]:
            invalid.append({**valid, key: None})
        for key in helper.UI_KEYBOARD_COUNT_FIELDS:
            invalid.append({name: value for name, value in valid.items() if name != key})
            invalid += [{**valid, key: value} for value in (True, -1, 101, 1.0, None)]
        invalid += [{**valid, 'continueExistingCount': 2},
                    {**valid, 'continueCandidateCount': 1}]
        for counts in ((0, 0, 0, 0, 0), (5, 4, 3, 2, 1), (100, 100, 100, 100, 100)):
            missing_singleton = {**valid, **dict(zip(helper.UI_KEYBOARD_COUNT_FIELDS, counts)),
                                 'continueCandidateCount': counts[-1],
                                 **dict.fromkeys(KEYBOARD_FRAME_FIELDS)}
            for key in KEYBOARD_FRAME_FIELDS:
                invalid += [{**missing_singleton, key: value} for value in (False, True)]
        no_area = {**valid, 'continueFrameHasArea': False, **dict.fromkeys(KEYBOARD_FRAME_FIELDS[1:])}
        for key in KEYBOARD_FRAME_FIELDS[1:]:
            invalid += [{**no_area, key: value} for value in (False, True)]
        contained = {**valid, 'continueCandidateCount': 1, 'continueInKeyboardCount': 1,
                     'continueFrameInsideKeyboard': True}
        invalid += [
            {**no_area, 'continueCandidateCount': 1, 'continueInKeyboardCount': 1},
            {**valid, 'continueFrameInsideKeyboard': True},
            {**contained, 'continueFrameInsideKeyboard': False},
            {**contained, 'continueFrameCenterInsideKeyboard': False},
            {**contained, 'continueFrameIntersectsKeyboard': False},
            {**valid, 'frameX': 123}, {**valid, 'title': PRIVATE},
        ]
        log = self.root / 'keyboard-frame-invalid.log'
        log.write_text('\n'.join(keyboard_line(payload) for payload in invalid) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': len(invalid)}])
        self.assertNotIn('::error::', output)

    def test_keyboard_frame_diagnostic_keeps_duplicate_byte_limit_mixed_privacy_and_no_success_guards(self):
        valid = keyboard_frame_payload()
        private = ('UI row scroll owner: /private/' + PRIVATE + ' Test run with 999 tests passed '
                   + started_line(METHODS[1]) + ' ' + screenshot_line('detail', '999'))
        bad_lines = [keyboard_line({**valid, 'private': private}),
                     keyboard_line(valid) + ' error: ' + PRIVATE,
                     keyboard_line(valid) + ' ' + keyboard_line(valid),
                     'UI keyboard introduction diagnostic: {' + PRIVATE,
                     'UI keyboard introduction diagnostic: ' + '[' * 1500 + '0' + ']' * 1500]
        for key in KEYBOARD_FRAME_FIELDS:
            text = 'true' if valid[key] else 'false'
            bad_lines.append(keyboard_line(valid).replace(
                '"' + key + '": ' + text,
                '"' + key + '": "' + PRIVATE + '", "' + key + '": ' + text))
        bad_lines += [keyboard_line(valid) + ' ' + other for other in
                      (phase_line({'method': PHASE_METHOD, 'phase': 'started'}),
                       native_screenshot_line(native_screenshot_payload()), viewport_line({}),
                       store_dedup_line(), ui_failure_line())]
        log = self.root / 'keyboard-frame-private.log'
        log.write_text('\n'.join([keyboard_line(valid)] + bad_lines + [
            screenshot_line('detail', '123'), 'error: safe unrelated compiler failure',
        ]) + '\n')
        output_path = self.root / 'github-output'
        summary_path = self.root / 'github-step-summary'
        output_path.write_text('previous=value\n')
        summary_path.write_text('previous summary\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [{'scope': 'stdoutOnly', **valid}])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': len(bad_lines)}])
        self.assertNotIn('UI row scroll owners:', output)
        self.assertNotIn('Swift Testing completion reports:', output)
        self.assertNotIn(METHODS[1], output)
        self.assertNotIn('executedTests', output)
        self.assertIn('::error::error: safe unrelated compiler failure', output)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')
        self.assertEqual(summary_path.read_text(), 'previous summary\n')
        over_limit = json.dumps({**valid, 'private': PRIVATE + '한' * 1400}, ensure_ascii=False)
        self.assertLess(len(over_limit), 4096)
        self.assertGreater(len(over_limit.encode('utf-8')), 4096)
        with mock.patch.object(helper.json, 'loads', side_effect=AssertionError('over-limit payload parsed')):
            output = self.capture(helper.report_ui_keyboard_diagnostics,
                                  ['UI keyboard introduction diagnostic: ' + over_limit])
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': 1}])

    def test_introduction_context_preserves_39_keyboard_geometry_and_legacy_schemas(self):
        self.assertEqual(helper.UI_KEYBOARD_INTRODUCTION_FIELDS, KEYBOARD_INTRODUCTION_FIELDS)
        legacy = {**keyboard_frame_payload(), 'continueFrameCenterInsideKeyboard': False}
        basic = {key: legacy[key] for key in
                 ('phase', 'continueCandidateCount', 'keyboardBoundsValid', 'elapsedMilliseconds')}
        extended = {key: value for key, value in legacy.items() if key not in KEYBOARD_FRAME_FIELDS}
        introduction = keyboard_introduction_payload()
        self.assertEqual(len(legacy), 13)
        self.assertEqual(len(introduction), 19)
        log = self.root / 'keyboard-introduction-compatible.log'
        for phase in ('continueReadiness', 'introductionDismissal'):
            with self.subTest(phase=phase):
                samples = [{**sample, 'phase': phase} for sample in (basic, extended, legacy, introduction)]
                log.write_text('\n'.join(keyboard_line(sample) for sample in samples) + '\n')
                output = self.capture(helper.diagnostics, log)
                notices = self.notices(output, UI_KEYBOARD_NOTICE)
                self.assertEqual(notices, [{'scope': 'stdoutOnly', **sample} for sample in samples])
                self.assertEqual(len(notices[-1]), 20)
                self.assertEqual(notices[-1]['continueCandidateCount'], 1)
                self.assertEqual(notices[-1]['continueInKeyboardCount'], 0)
                self.assertIs(notices[-1]['continueFrameInsideKeyboard'], False)
                self.assertIs(notices[-1]['continueFrameCenterInsideKeyboard'], False)
                self.assertIs(notices[-1]['continueFrameIntersectsKeyboard'], True)
                self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [])

    def test_introduction_context_nullability_distinguishes_missing_ambiguous_and_outside_guides(self):
        valid = keyboard_introduction_payload()
        unavailable = {**valid, 'continueCandidateCount': 0, 'continueInIntroductionCount': 0,
                       'introductionContextValid': False, 'continueFrameInsideIntroduction': None}
        samples = [
            {**valid, 'continueCandidateCount': 0, 'continueInIntroductionCount': 0,
             'continueFrameInsideIntroduction': False},
            unavailable,
            {**unavailable, 'introductionContextCount': 0},
            {**unavailable, 'introductionContextCount': 2},
            {**unavailable, 'introductionWindowCount': 0},
            {**unavailable, 'introductionWindowCount': 2},
            {**unavailable, 'introductionTextVisible': False},
            {**unavailable, 'continueEnabledCount': 0, **dict.fromkeys(KEYBOARD_FRAME_FIELDS)},
            {**unavailable, **dict.fromkeys(helper.UI_KEYBOARD_COUNT_FIELDS[:-1], 2),
             **dict.fromkeys(KEYBOARD_FRAME_FIELDS)},
            {**unavailable, 'continueFrameHasArea': False,
             **dict.fromkeys(KEYBOARD_FRAME_FIELDS[1:])},
        ]
        log = self.root / 'keyboard-introduction-nullability.log'
        for sample in samples:
            with self.subTest(sample=sample):
                log.write_text(keyboard_line(sample) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [{'scope': 'stdoutOnly', **sample}])
                self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [])

    def test_introduction_context_rejects_partial_schema_wrong_types_and_unproven_or_conflicting_candidates(self):
        valid = keyboard_introduction_payload()
        invalid = []
        for key in KEYBOARD_INTRODUCTION_FIELDS:
            invalid.append({name: value for name, value in valid.items() if name != key})
        for key, upper in (('continueInIntroductionCount', 1), ('introductionContextCount', 100),
                           ('introductionWindowCount', 100)):
            invalid += [{**valid, key: value} for value in (-1, upper + 1, True, 1.0, None, PRIVATE)]
        for key in ('introductionTextVisible', 'introductionContextValid', 'continueFrameInsideIntroduction'):
            invalid += [{**valid, key: value} for value in (0, 1, 'true', None, [], {})]
        unavailable = {**valid, 'continueCandidateCount': 0, 'continueInIntroductionCount': 0,
                       'introductionContextValid': False, 'continueFrameInsideIntroduction': None}
        invalid += [
            {**valid, 'continueCandidateCount': 0},
            {**valid, 'continueInIntroductionCount': 0},
            {**valid, 'continueFrameInsideIntroduction': False},
            {**valid, 'introductionContextValid': False},
            {**unavailable, 'continueFrameInsideIntroduction': False},
            {**unavailable, 'continueFrameInsideIntroduction': True},
            {**valid, 'introductionContextCount': 0}, {**valid, 'introductionContextCount': 2},
            {**valid, 'introductionWindowCount': 0}, {**valid, 'introductionWindowCount': 2},
            {**valid, 'introductionTextVisible': False},
            {**valid, 'keyboardBoundsValid': False},
            {**valid, 'continueFrameInsideKeyboard': True},
            {**valid, 'continueFrameCenterInsideKeyboard': True, 'continueFrameIntersectsKeyboard': False},
            {**unavailable, 'continueEnabledCount': 0, **dict.fromkeys(KEYBOARD_FRAME_FIELDS),
             'introductionContextValid': True, 'continueFrameInsideIntroduction': False},
            {**unavailable, **dict.fromkeys(helper.UI_KEYBOARD_COUNT_FIELDS[:-1], 2),
             **dict.fromkeys(KEYBOARD_FRAME_FIELDS), 'introductionContextValid': True,
             'continueFrameInsideIntroduction': False},
            {**unavailable, 'continueFrameHasArea': False, **dict.fromkeys(KEYBOARD_FRAME_FIELDS[1:]),
             'introductionContextValid': True, 'continueFrameInsideIntroduction': False},
            {**valid, 'windowTitle': PRIVATE},
            {**keyboard_frame_payload(), 'continueCandidateCount': 1,
             'continueFrameCenterInsideKeyboard': False},
        ]
        log = self.root / 'keyboard-introduction-invalid.log'
        log.write_text('\n'.join(keyboard_line(sample) for sample in invalid) + '\n')
        output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': len(invalid)}])
        self.assertNotIn('::error::', output)

    def test_introduction_context_keeps_duplicate_byte_limit_private_fallback_and_actions_output_guards(self):
        valid = keyboard_introduction_payload()
        private = ('UI row scroll owner: /private/' + PRIVATE + ' Test run with 999 tests passed '
                   + started_line(METHODS[1]) + ' ' + screenshot_line('detail', '999'))
        bad_lines = [keyboard_line({**valid, 'private': private}),
                     keyboard_line(valid) + ' error: ' + PRIVATE]
        for key in KEYBOARD_INTRODUCTION_FIELDS:
            encoded = json.dumps(valid[key])
            bad_lines.append(keyboard_line(valid).replace(
                '"' + key + '": ' + encoded,
                '"' + key + '": "' + PRIVATE + '", "' + key + '": ' + encoded))
        bad_lines += [keyboard_line(valid) + ' ' + other for other in
                      (keyboard_line(valid), phase_line({'method': PHASE_METHOD, 'phase': 'started'}),
                       native_screenshot_line(native_screenshot_payload()), viewport_line({}),
                       store_dedup_line(), ui_failure_line())]
        log = self.root / 'keyboard-introduction-private.log'
        log.write_text('\n'.join([keyboard_line(valid)] + bad_lines + [
            'error: safe unrelated compiler failure',
        ]) + '\n')
        output_path = self.root / 'github-output'
        summary_path = self.root / 'github-step-summary'
        output_path.write_text('previous=value\n')
        summary_path.write_text('previous summary\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [{'scope': 'stdoutOnly', **valid}])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': len(bad_lines)}])
        self.assertNotIn('UI row scroll owners:', output)
        self.assertNotIn('Swift Testing completion reports:', output)
        self.assertNotIn(METHODS[1], output)
        self.assertNotIn('executedTests', output)
        self.assertIn('::error::error: safe unrelated compiler failure', output)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')
        self.assertEqual(summary_path.read_text(), 'previous summary\n')
        over_limit = json.dumps({**valid, 'private': PRIVATE + '한' * 1400}, ensure_ascii=False)
        self.assertLess(len(over_limit), 4096)
        self.assertGreater(len(over_limit.encode('utf-8')), 4096)
        with mock.patch.object(helper.json, 'loads', side_effect=AssertionError('over-limit payload parsed')):
            output = self.capture(helper.report_ui_keyboard_diagnostics,
                                  ['UI keyboard introduction diagnostic: ' + over_limit])
        self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [])
        self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': 1}])

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
                    self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [])
                    self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTION_REASONS_NOTICE), [])
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

    def test_first_ui_failure_rejection_reasons_count_each_existing_branch_once(self):
        reason_counts = {'sourceFormat': 0, 'sourceOwnership': 0, 'lineRange': 0, 'caseFormat': 0,
                         'caseUnavailable': 0, 'caseOwnership': 0, 'assertionKind': 0}
        native_error = ui_failure_line().replace('XCTAssertTrue failed -', 'Native UI error:')
        samples = (
            (ui_failure_line(line='-1'), 'sourceFormat'),
            (ui_failure_line(source='/private/' + PRIVATE + '/OtherTests.swift'), 'sourceOwnership'),
            (ui_failure_line(line='0'), 'lineRange'),
            (ui_failure_line().replace(METHODS[0] + ']', 'test' + PRIVATE + '-broken]'), 'caseFormat'),
            (ui_failure_line(explicit=False), 'caseUnavailable'),
            (ui_failure_line(method='test' + PRIVATE), 'caseOwnership'),
            (ui_failure_line().replace('.MirrorUITests ', '.OtherTests '), 'caseOwnership'),
            (ui_failure_line(kind='XCTAssertNativeFailure'), 'assertionKind'),
            (native_error, 'assertionKind'),
        )
        for failure, reason in samples:
            with self.subTest(reason=reason, failure=failure):
                output = self.capture(helper.report_ui_first_failure, [failure])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTION_REASONS_NOTICE), [{
                    'rejectedTotal': 1, 'reasonCounts': {**dict.fromkeys(reason_counts, 0), reason: 1},
                }])
                self.assertEqual(len(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE)),
                                 int(reason == 'assertionKind'))
                reason_counts[reason] += 1
        output = self.capture(helper.report_ui_first_failure, [failure for failure, _ in samples])
        rejected = self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE)
        reasons = self.notices(output, UI_FIRST_FAILURE_REJECTION_REASONS_NOTICE)
        self.assertEqual(rejected, [{'invalidCount': 9}])
        self.assertEqual(reasons, [{'rejectedTotal': 9, 'reasonCounts': reason_counts}])
        self.assertEqual(sum(reasons[0]['reasonCounts'].values()), rejected[0]['invalidCount'])
        self.assertEqual(len(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE)), 1)
        self.assertNotIn('Native UI error', output)
        self.assertNotIn('XCTAssertNativeFailure', output)
        self.assertNotIn('/private/', output)
        self.assertEqual(self.capture(helper.report_ui_first_failure, ['error: safe compiler error']), '')

    def test_unclassified_ui_failure_requires_valid_source_line_and_owned_case(self):
        unsupported = lambda **arguments: ui_failure_line(kind='XCTAssertNativeFailure', **arguments)
        samples = (
            [unsupported(source='/private/' + PRIVATE + '/OtherTests.swift')],
            [unsupported(source='Tests/MirrorUITests/MirrorUITests.swift.backup')],
            [unsupported(line='0')], [unsupported(line='10001')], [unsupported(line='-1')],
            [unsupported().replace(METHODS[0] + ']', 'test' + PRIVATE + '-broken]')],
            [unsupported(method='test' + PRIVATE)],
            [unsupported().replace('.MirrorUITests ', '.OtherTests ')],
            [unsupported(explicit=False)],
            [started_line(METHODS[0]), started_line(METHODS[1]), unsupported(explicit=False)],
            [started_line(METHODS[0]), case_line(METHODS[0]), unsupported(explicit=False)],
            [started_line(METHODS[0], 'OtherTests'), unsupported(explicit=False)],
        )
        for lines in samples:
            with self.subTest(lines=lines):
                output = self.capture(helper.report_ui_first_failure, lines)
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 1}])
                reasons = self.notices(output, UI_FIRST_FAILURE_REJECTION_REASONS_NOTICE)
                self.assertEqual(len(reasons), 1)
                self.assertEqual(reasons[0]['rejectedTotal'], 1)
                self.assertEqual(sum(reasons[0]['reasonCounts'].values()), 1)
                self.assertEqual(reasons[0]['reasonCounts']['assertionKind'], 0)
        for explicit, source, line in ((True, '/private/' + PRIVATE + '/Tests/MirrorUITests/MirrorUITests.swift', '1'),
                                      (False, 'MirrorUITests.swift', '10000')):
            with self.subTest(explicit=explicit, line=line):
                output = self.capture(helper.report_ui_first_failure, [
                    started_line(METHODS[2]), unsupported(method=METHODS[2], source=source, line=line,
                                                         explicit=explicit),
                    unsupported(method=METHODS[0], line='939'), ui_failure_line(method=METHODS[1], line='475'),
                ])
                self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [{
                    'scope': 'stdoutOnly', 'method': METHODS[2],
                    'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': int(line),
                    'failureKind': 'unclassified',
                }])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
                    'scope': 'stdoutOnly', 'method': METHODS[1],
                    'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 475,
                    'assertionKind': 'XCTAssertTrue',
                }])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 2}])

    def test_unclassified_ui_failure_never_replaces_an_earlier_supported_failure(self):
        output = self.capture(helper.report_ui_first_failure, [
            ui_failure_line(method=METHODS[1], line='475'),
            ui_failure_line(method=METHODS[2], line='284', kind='XCTAssertNativeFailure'),
            ui_failure_line(method=METHODS[0], line='939', kind='XCTAssertNativeFailure'),
        ])
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
            'scope': 'stdoutOnly', 'method': METHODS[1],
            'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 475,
            'assertionKind': 'XCTAssertTrue',
        }])
        self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [{
            'scope': 'stdoutOnly', 'method': METHODS[2],
            'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 284,
            'failureKind': 'unclassified',
        }])
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 2}])

    def test_unclassified_failure_and_reasons_preserve_private_filter_and_actions_outputs(self):
        private = ('/private/' + PRIVATE + ' Test run with 999 tests passed '
                   + started_line(METHODS[1]) + ' ' + screenshot_line('detail', '999'))
        unsupported = ui_failure_message_line(private, method=METHODS[2], line='284').replace(
            'XCTAssertTrue failed -', 'Native UI error:')
        log = self.root / 'ui-unclassified-private.log'
        log.write_text('\n'.join([
            ui_failure_line(source='OtherTests.swift'), unsupported,
            ui_failure_line(method=METHODS[0], line='599'),
            unsupported + ' ' + viewport_line({'private': private}),
            'error: safe unrelated compiler failure',
        ]) + '\n')
        output_path = self.root / 'github-output'
        summary_path = self.root / 'github-step-summary'
        output_path.write_text('previous=value\n')
        summary_path.write_text('previous summary\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.diagnostics, log)
        self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [{
            'scope': 'stdoutOnly', 'method': METHODS[2],
            'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 284,
            'failureKind': 'unclassified',
        }])
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
            'scope': 'stdoutOnly', 'method': METHODS[0],
            'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 599,
            'assertionKind': 'XCTAssertTrue',
        }])
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 2}])
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTION_REASONS_NOTICE), [{
            'rejectedTotal': 2, 'reasonCounts': {
                'sourceFormat': 0, 'sourceOwnership': 1, 'lineRange': 0, 'caseFormat': 0,
                'caseUnavailable': 0, 'caseOwnership': 0, 'assertionKind': 1,
            },
        }])
        self.assertEqual(self.notices(output, UI_VIEWPORT_NOTICE), [])
        self.assertEqual(self.notices(output, UI_VIEWPORT_REJECTED_NOTICE), [{'invalidCount': 1}])
        for raw in ('Native UI error', '/private/', 'expected/actual', 'Swift Testing completion reports:',
                    METHODS[1], 'UI screenshot timing:', 'UI stdout diagnostics:', 'executedTests'):
            self.assertNotIn(raw, output)
        self.assertIn('::error::error: safe unrelated compiler failure', output)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')
        self.assertEqual(summary_path.read_text(), 'previous summary\n')

    def test_native_query_reason_uses_only_known_prefix_after_owned_source_and_case(self):
        log = self.root / 'ui-query-reasons.log'
        private = '/private/' + PRIVATE + ' identifier=private AX frame=(1,2,3,4)'
        for owner in ('MirrorUITests', 'MirrorIOSUITests.MirrorUITests', 'MirrorMacUITests.MirrorUITests'):
            for index, (prefix, reason) in enumerate(QUERY_FAILURE_SAMPLES):
                method = METHODS[index % len(METHODS)]
                with self.subTest(owner=owner, prefix=prefix):
                    failure = ui_query_failure_line(prefix + ': ' + private, method=method, line='475',
                        source='/private/' + PRIVATE + '/Tests/MirrorUITests/MirrorUITests.swift')
                    log.write_text(failure.replace('MirrorIOSUITests.MirrorUITests', owner) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [{
                        'scope': 'stdoutOnly', 'method': method,
                        'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 475,
                        'failureKind': 'unclassified', 'queryFailureReason': reason,
                    }])
                    self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [])
                    self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 1}])
                    counts = self.notices(output, UI_FIRST_FAILURE_REJECTION_REASONS_NOTICE)[0]['reasonCounts']
                    self.assertEqual(counts['assertionKind'], 1)
                    self.assertEqual(sum(counts.values()), 1)
                    for raw in (prefix, '/private/', 'identifier=', 'AX frame=', '::error::'):
                        self.assertNotIn(raw, output)

    def test_native_query_detail_matches_only_complete_sdk_messages_without_private_values(self):
        prefix = 'Failed to get matching snapshots: '
        samples = (
            ('Timed out while evaluating UI query.', 'uiQueryEvaluationTimeout'),
            ('Unable to perform work on main run loop, process main thread busy for 123.456s',
             'processMainThreadBusy'),
        )
        for tail, detail in samples:
            with self.subTest(detail=detail):
                failure = ui_query_failure_line(prefix + tail).replace('MirrorIOSUITests', 'MirrorMacUITests')
                output = self.capture(helper.report_ui_first_failure, [
                    started_line(METHODS[0], owner='MirrorMacUITests.MirrorUITests'), failure,
                    case_line(METHODS[0], event='failed', module='MirrorMacUITests')])
                self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [{
                    'scope': 'stdoutOnly', 'method': METHODS[0],
                    'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 475,
                    'failureKind': 'unclassified', 'queryFailureReason': 'failedToGetMatchingSnapshot',
                    'queryFailureDetail': detail,
                }])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 1}])
                for raw in (prefix, tail, '123.456', '::error::'):
                    self.assertNotIn(raw, output)

    def test_native_query_detail_rejects_outer_prefix_mismatch_and_quoted_payloads(self):
        prefix = 'Failed to get matching snapshots: '
        tails = ('Timed out while evaluating UI query.',
                 'Unable to perform work on main run loop, process main thread busy for 123.456s')
        for tail in tails:
            for message in (
                'AX snapshot timed out: ' + tail, 'Failed to get matching snapshot: ' + tail,
                prefix + 'title="' + tail + '"', prefix + '"' + tail + '"',
                prefix + 'Other SDK error: ' + tail, prefix + tail + ' ' + PRIVATE,
                prefix + tail + '.', prefix + tail.replace(' ', '\t', 1), tail,
                (prefix + tail).lower(),
            ):
                with self.subTest(message=message):
                    output = self.capture(helper.report_ui_first_failure, [ui_query_failure_line(message)])
                    self.assertNotIn('queryFailureDetail', output)
                    self.assertEqual(len(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE)), 1)
            for arguments in ({'source': 'OtherTests.swift'}, {'method': 'test' + PRIVATE}):
                output = self.capture(helper.report_ui_first_failure,
                                      [ui_query_failure_line(prefix + tail, **arguments)])
                self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [])
            output = self.capture(helper.report_ui_first_failure,
                                  [ui_failure_message_line(prefix + tail, kind='XCTFail')])
            self.assertNotIn('queryFailureDetail', output)
        for tail in (tails[0][:-1], tails[1].replace('123.456', '123')):
            output = self.capture(helper.report_ui_first_failure, [ui_query_failure_line(prefix + tail)])
            self.assertNotIn('queryFailureDetail', output)

    def test_native_query_reason_requires_prefix_boundary_and_does_not_reclassify_assertions(self):
        for prefix, reason in QUERY_FAILURE_SAMPLES:
            for suffix in ('', '.', ':', ' ', ': ' + PRIVATE):
                with self.subTest(prefix=prefix, suffix=suffix):
                    output = self.capture(helper.report_ui_first_failure, [ui_query_failure_line(prefix + suffix)])
                    self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE)[0]['queryFailureReason'], reason)
            messages = (prefix + 'Unexpected: ' + PRIVATE, 'prefix ' + prefix + ': ' + PRIVATE,
                        prefix.lower() + ': ' + PRIVATE, 'Native UI error: ' + prefix + ': ' + PRIVATE)
            for message in messages:
                with self.subTest(message=message):
                    output = self.capture(helper.report_ui_first_failure, [ui_query_failure_line(message)])
                    self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [{
                        'scope': 'stdoutOnly', 'method': METHODS[0],
                        'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 475,
                        'failureKind': 'unclassified',
                    }])
            for kind in ('XCTAssertTrue', 'XCTAssertEqual', 'XCTFail'):
                with self.subTest(prefix=prefix, kind=kind):
                    output = self.capture(helper.report_ui_first_failure, [
                        ui_failure_message_line(prefix + ': ' + PRIVATE, kind=kind)])
                    self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [])
                    self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
                        'scope': 'stdoutOnly', 'method': METHODS[0],
                        'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 475,
                        'assertionKind': kind,
                    }])

    def test_native_query_reason_preserves_source_and_case_rejection_and_headerless_boundary(self):
        payload = 'Failed to get matching snapshots: /private/' + PRIVATE
        samples = (
            (ui_query_failure_line(payload, source='OtherTests.swift'), 'sourceOwnership'),
            (ui_query_failure_line(payload, source='/private/' + PRIVATE + '/MirrorUITests.swift'), 'sourceOwnership'),
            (ui_query_failure_line(payload, line='-1'), 'sourceFormat'),
            (ui_query_failure_line(payload, line='0'), 'lineRange'),
            (ui_query_failure_line(payload, line='10001'), 'lineRange'),
            (ui_query_failure_line(payload, method='test' + PRIVATE), 'caseOwnership'),
            (ui_query_failure_line(payload).replace(METHODS[0] + ']', METHODS[0] + '-broken]'), 'caseFormat'),
        )
        log = self.root / 'ui-query-ownership.log'
        for failure, reason in samples:
            with self.subTest(reason=reason, failure=failure):
                log.write_text(failure + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 1}])
                counts = self.notices(output, UI_FIRST_FAILURE_REJECTION_REASONS_NOTICE)[0]['reasonCounts']
                self.assertEqual(counts[reason], 1)
                self.assertEqual(sum(counts.values()), 1)
                self.assertNotIn('queryFailureReason', output)
                self.assertNotIn('::error::', output)
        for before in ([], [started_line(METHODS[0])],
                       [started_line(METHODS[0]), started_line(METHODS[1])],
                       [started_line(METHODS[0]), case_line(METHODS[0])]):
            output = self.capture(helper.report_ui_first_failure,
                                  before + [ui_query_failure_line(payload, explicit=False)])
            self.assertEqual(output, '')
        output = self.capture(helper.report_ui_first_failure, [
            ui_query_failure_line(payload).replace('.MirrorUITests ', '.OtherTests ')])
        self.assertEqual(output, '')

    def test_native_query_reason_keeps_first_unclassified_location_without_promoting_later_causes(self):
        unknown = ui_query_failure_line('Native UI error: ' + PRIVATE, method=METHODS[2], line='284')
        snapshot = ui_query_failure_line('Failed to get matching snapshots: ' + PRIVATE, method=METHODS[0], line='475')
        multiple = ui_query_failure_line('Multiple matching elements found: ' + PRIVATE, method=METHODS[1], line='939')
        for lines, expected_method, expected_line, expected_reason in (
            ([unknown, snapshot, multiple], METHODS[2], 284, None),
            ([snapshot, unknown, multiple], METHODS[0], 475, 'failedToGetMatchingSnapshot'),
            ([multiple, snapshot, unknown], METHODS[1], 939, 'multipleMatchingElements'),
        ):
            with self.subTest(expected_reason=expected_reason):
                output = self.capture(helper.report_ui_first_failure, lines)
                expected = {'scope': 'stdoutOnly', 'method': expected_method,
                            'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': expected_line,
                            'failureKind': 'unclassified'}
                if expected_reason is not None:
                    expected['queryFailureReason'] = expected_reason
                self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE), [expected])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 3}])

    def test_history_xctfail_reason_maps_fixed_sentences_and_keeps_payload_private(self):
        log = self.root / 'ui-history-reasons.log'
        for explicit in (True, False):
            for sentence, reason in HISTORY_FAILURE_SAMPLES:
                with self.subTest(explicit=explicit, reason=reason):
                    message = sentence + '. /private/' + PRIVATE + ' AX frame=(1,2,3,4) title=private'
                    log.write_text('\n'.join([started_line(METHODS[1]),
                        ui_failure_message_line(message, method=METHODS[1], kind='XCTFail', explicit=explicit),
                        case_line(METHODS[1], event='failed')]) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
                        'scope': 'stdoutOnly', 'method': METHODS[1],
                        'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 475,
                        'assertionKind': 'XCTFail', 'failureReason': reason,
                    }])
                    self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [])
                    for raw in (sentence, '/private/', 'AX frame=', 'title=', '::error::'):
                        self.assertNotIn(raw, output)

    def test_history_xctfail_reason_requires_exact_sentence_boundary_and_approved_ownership(self):
        for sentence, _ in HISTORY_FAILURE_SAMPLES:
            for message in (sentence, sentence + ': ' + PRIVATE, sentence + '.' + PRIVATE,
                            sentence + '가. ' + PRIVATE, '다른 실패. ' + sentence + '. ' + PRIVATE):
                output = self.capture(helper.report_ui_first_failure, [ui_failure_message_line(message, kind='XCTFail')])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
                    'scope': 'stdoutOnly', 'method': METHODS[0],
                    'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 475,
                    'assertionKind': 'XCTFail',
                }])
            known = sentence + '. ' + PRIVATE
            for kind in ('XCTAssertTrue', 'XCTAssertEqual'):
                output = self.capture(helper.report_ui_first_failure, [ui_failure_message_line(known, kind=kind)])
                self.assertNotIn('failureReason', output)
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE)[0]['assertionKind'], kind)
            invalid = [ui_failure_message_line(known, source='OtherTests.swift', kind='XCTFail'),
                       ui_failure_message_line(known, method='test' + PRIVATE, kind='XCTFail'),
                       ui_failure_message_line(known, kind='XCTFail').replace('.MirrorUITests ', '.OtherTests ')]
            output = self.capture(helper.report_ui_first_failure, invalid)
            self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [])
            self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 3}])
            for before in ([], [started_line(METHODS[0]), started_line(METHODS[1])],
                           [started_line(METHODS[0]), case_line(METHODS[0])]):
                output = self.capture(helper.report_ui_first_failure,
                    before + [ui_failure_message_line(known, kind='XCTFail', explicit=False)])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 1}])

    def test_query_and_history_reasons_do_not_emit_payload_events_or_write_actions_outputs(self):
        private = ('/private/' + PRIVATE + ' AX frame=(1,2,3,4) UI row scroll owner: private '
                   'Test run with 999 tests passed ' + started_line(METHODS[4])
                   + ' ' + screenshot_line('detail', '999') + ' ::error::' + PRIVATE)
        query = ui_query_failure_line('Failed to get matching snapshots: ' + private, method=METHODS[1])
        history = ui_failure_message_line(HISTORY_FAILURE_SAMPLES[0][0] + '. ' + private,
                                          method=METHODS[1], kind='XCTFail')
        mixed = query + ' ' + viewport_line({'private': private})
        log = self.root / 'ui-query-history-private.log'
        log.write_text('\n'.join([mixed, query, history, 'error: safe unrelated compiler failure']) + '\n')
        output_path = self.root / 'github-output'
        summary_path = self.root / 'github-step-summary'
        output_path.write_text('previous=value\n')
        summary_path.write_text('previous summary\n')
        with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                mock.patch.object(helper.sys, 'argv', ['ci_results.py', 'diagnostics', str(log)]), \
                mock.patch.object(helper, 'record') as record:
            output = self.capture(helper.main)
        self.assertEqual(self.notices(output, UI_UNCLASSIFIED_FAILURE_NOTICE)[0]['queryFailureReason'],
                         'failedToGetMatchingSnapshot')
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE)[0]['failureReason'],
                         'historyApplicationNotForeground')
        self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 1}])
        self.assertEqual(self.notices(output, UI_VIEWPORT_REJECTED_NOTICE), [{'invalidCount': 1}])
        for raw in ('/private/', 'AX frame=', 'UI row scroll owners:', 'UI stdout diagnostics:',
                    'Swift Testing completion reports:', 'UI screenshot timing:', METHODS[4], 'executedTests',
                    '"result": "pass"'):
            self.assertNotIn(raw, output)
        self.assertIn('::error::error: safe unrelated compiler failure', output)
        record.assert_not_called()
        self.assertEqual(output_path.read_text(), 'previous=value\n')
        self.assertEqual(summary_path.read_text(), 'previous summary\n')

    def test_xctfail_reason_identifies_fixed_helper_branches_at_forwarded_caller_284(self):
        branches = (
            ('앱 프로세스가 종료되어 필수 UI 요소를 조회할 수 없다', 'applicationNotRunning'),
            ('필수 UI 요소가 없다', 'missingElement'),
            ('작업 행을 포함하는 스크롤 컨테이너가 없다', 'rowScrollContainerMissing'),
            ('대상 UI를 포함하는 스크롤 컨테이너가 없다', 'scrollContainerMissing'),
            ('UI 요소에 도달할 수 없다', 'unhittableOrDisabled'),
        )
        log = self.root / 'ui-caller-reasons.log'
        for explicit in (True, False):
            for prefix, reason in branches:
                with self.subTest(explicit=explicit, reason=reason):
                    message = prefix + ': capture.open. identifier=/private/' + PRIVATE + ' AX frame=(1,2,3,4)'
                    log.write_text('\n'.join([
                        started_line(METHODS[2]),
                        ui_failure_message_line(message, method=METHODS[2], line='284', kind='XCTFail',
                                                explicit=explicit),
                        case_line(METHODS[2], event='failed'),
                    ]) + '\n')
                    output = self.capture(helper.diagnostics, log)
                    self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
                        'scope': 'stdoutOnly', 'method': METHODS[2],
                        'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 284,
                        'assertionKind': 'XCTFail', 'failureReason': reason,
                    }])
                    self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [])
                    self.assertNotIn('capture.open', output)
                    self.assertNotIn('AX frame=', output)
                    self.assertNotIn(prefix, output)

    def test_xctfail_reason_requires_exact_message_prefix_boundary_and_preserves_legacy_assertions(self):
        prefix = 'UI 요소에 도달할 수 없다'
        messages = (
            prefix, prefix + '가: ' + PRIVATE, prefix + ':capture.open ' + PRIVATE,
            prefix + '. capture.open ' + PRIVATE, '다른 실패: ' + prefix + ': ' + PRIVATE,
            '알 수 없는 실패: ' + PRIVATE,
        )
        log = self.root / 'ui-reason-boundaries.log'
        samples = [(message, 'XCTFail') for message in messages]
        samples += [(prefix + ': capture.open ' + PRIVATE, 'XCTAssertTrue'),
                    (prefix + ': capture.open ' + PRIVATE, 'XCTAssertEqual')]
        for message, kind in samples:
            with self.subTest(message=message, kind=kind):
                log.write_text(ui_failure_message_line(message, method=METHODS[2], line='284', kind=kind) + '\n')
                output = self.capture(helper.diagnostics, log)
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [{
                    'scope': 'stdoutOnly', 'method': METHODS[2],
                    'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 284,
                    'assertionKind': kind,
                }])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [])

    def test_xctfail_reason_keeps_first_failure_validation_private_filter_and_actions_outputs(self):
        known = 'UI 요소에 도달할 수 없다: capture.open. '
        private = ('/private/' + PRIVATE + ' UI row scroll owner: frame=(1,2,3,4) '
                   + 'Test run with 999 tests passed ' + started_line(METHODS[1])
                   + ' ' + screenshot_line('detail', '999'))
        recognized = ui_failure_message_line(known + private, method=METHODS[2], line='284', kind='XCTFail')
        unknown = ui_failure_message_line('알 수 없는 실패: ' + private,
                                          method=METHODS[2], line='284', kind='XCTFail')
        mixed = recognized + ' ' + keyboard_line({
            'phase': 'continueReadiness', 'continueCandidateCount': 0,
            'keyboardBoundsValid': False, 'elapsedMilliseconds': 0,
        })
        invalid = [ui_failure_message_line(known + private, source='OtherTests.swift', kind='XCTFail'),
                   ui_failure_message_line(known + private, method='test' + PRIVATE, kind='XCTFail')]
        log = self.root / 'ui-reason-first-and-private.log'
        output_path = self.root / 'github-output'
        summary_path = self.root / 'github-step-summary'
        output_path.write_text('previous=value\n')
        summary_path.write_text('previous summary\n')
        for first, expected_reason in ((unknown, None), (recognized, 'unhittableOrDisabled')):
            with self.subTest(expected_reason=expected_reason):
                log.write_text('\n'.join([started_line(METHODS[2])] + invalid + [
                    mixed, first, recognized.replace(':284:', ':939:'),
                    'error: safe unrelated compiler failure',
                ]) + '\n')
                with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                        'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                        mock.patch.object(helper, 'record') as record:
                    output = self.capture(helper.diagnostics, log)
                expected = {'scope': 'stdoutOnly', 'method': METHODS[2],
                            'sourceFile': 'Tests/MirrorUITests/MirrorUITests.swift', 'line': 284,
                            'assertionKind': 'XCTFail'}
                if expected_reason is not None:
                    expected['failureReason'] = expected_reason
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_NOTICE), [expected])
                self.assertEqual(self.notices(output, UI_FIRST_FAILURE_REJECTED_NOTICE), [{'invalidCount': 2}])
                self.assertEqual(self.notices(output, UI_KEYBOARD_NOTICE), [])
                self.assertEqual(self.notices(output, UI_KEYBOARD_REJECTED_NOTICE), [{'invalidCount': 1}])
                self.assertNotIn('capture.open', output)
                self.assertNotIn('UI row scroll owners:', output)
                self.assertNotIn('Swift Testing completion reports:', output)
                self.assertNotIn(METHODS[1], output)
                self.assertNotIn('executedTests', output)
                self.assertIn('::error::error: safe unrelated compiler failure', output)
                record.assert_not_called()
                self.assertEqual(output_path.read_text(), 'previous=value\n')
                self.assertEqual(summary_path.read_text(), 'previous summary\n')

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
        self.assertEqual(len(shots), 16)
        self.assertEqual({shot['stage'] for shot in shots}, set(STAGES))
        self.assertEqual(shots[0], {'scope': 'stdoutOnly', 'stage': STAGES[0], 'milliseconds': 0})
        self.assertTrue(all(type(shot['milliseconds']) is int for shot in shots))
        self.assertEqual(shots[-1]['milliseconds'], 1200000)

    def test_screenshot_timing_retains_only_last_sixteen_valid_events(self):
        lines = [screenshot_line(milliseconds=str(value)) for value in range(20)]
        lines += [screenshot_line(PRIVATE), screenshot_line(milliseconds='1200001')]
        output = self.capture(helper.report_ui_timing_diagnostics, lines)
        self.assertEqual([shot['milliseconds'] for shot in self.notices(output, SCREENSHOT_NOTICE)],
                         list(range(4, 20)))

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
        self.assertEqual(self.notices(output, TREE_CASE_NOTICE), [{
            'scope': 'xcresult', 'cases': [
                {'method': METHODS[0], 'event': 'passed', 'seconds': 0.0},
                {'method': METHODS[1], 'event': 'failed', 'seconds': 1200.0},
            ],
        }])
        self.assertEqual(self.notices(output, CASE_NOTICE), [])
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
        batches = self.notices(output, TREE_CASE_NOTICE)
        self.assertEqual(len(batches), 1)
        self.assertEqual(set(batches[0]), {'scope', 'cases'})
        self.assertEqual(batches[0]['scope'], 'xcresult')
        cases = batches[0]['cases']
        self.assertEqual(len(cases), 6)
        self.assertEqual({case['method'] for case in cases}, set(METHODS))
        self.assertTrue(all(case['event'] == 'failed' and case['seconds'] == 2.0 for case in cases))
        self.assertTrue(all(set(case) == {'method', 'event', 'seconds'} for case in cases))
        self.assertEqual(self.notices(output, CASE_NOTICE), [])
        self.assertNotIn('executedTests', output)

    def test_tree_timing_batch_preserves_zero_partial_and_all_six_cases_without_actions_writes(self):
        output_path = self.root / 'github-output'
        summary_path = self.root / 'github-step-summary'
        output_path.write_text('previous=value\n')
        summary_path.write_text('previous summary\n')
        for length in range(7):
            with self.subTest(length=length):
                nodes = {'testNodes': [{'nodeType': 'Test Case', 'name': method + '()',
                                       'result': 'Passed', 'durationInSeconds': index,
                                       'nodeIdentifierURL': '/private/' + PRIVATE}
                                      for index, method in enumerate(METHODS[:length])]}
                expected = [{'method': method, 'event': 'passed', 'seconds': index}
                            for index, method in enumerate(METHODS[:length])]
                with mock.patch.dict(helper.os.environ, {'GITHUB_OUTPUT': str(output_path),
                                                        'GITHUB_STEP_SUMMARY': str(summary_path)}), \
                        mock.patch.object(helper, 'record') as record:
                    output = self.capture(helper.report_ui_tree_timings, nodes)
                self.assertEqual(self.notices(output, TREE_CASE_NOTICE),
                                 [{'scope': 'xcresult', 'cases': expected}] if length else [])
                self.assertEqual(len(output.splitlines()), int(length > 0))
                self.assertEqual(self.notices(output, CASE_NOTICE), [])
                self.assertNotIn('executedTests', output)
                self.assertNotIn('"result": "pass"', output)
                record.assert_not_called()
                self.assertEqual(output_path.read_text(), 'previous=value\n')
                self.assertEqual(summary_path.read_text(), 'previous summary\n')


if __name__ == '__main__':
    unittest.main()
