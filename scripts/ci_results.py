#!/usr/bin/env python3
"""CI의 실제 테스트 결과를 검사하고 Actions 출력과 오류 annotation을 만든다."""

import json
import math
import os
import re
import sys
from collections import deque
from pathlib import Path


UI_BASELINE_METHODS = {
    'testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday',
    'testTomorrowStaysOutOfTodayAndIsSearchableInLibrary',
    'testOverlongTitleShowsErrorAndPreservesEveryCharacter',
    'testWeekPanelCancellationAndPartialFinishPreserveUndecidedPlan',
    'testExplicitCompletionAndUndoPreserveEditedTitleAndPlan',
    'testReviewUndoRestoresUnassignedCardInsteadOfAddingToToday',
}
UI_SCREENSHOT_STAGES = frozenset({
    'initial-today', 'calendar', 'settings', 'capture-form', 'review-card', 'week-picker',
    'today-populated', 'library', 'library-search', 'detail', 'detail-edit', 'completion',
    'undo', 'validation-error', 'quick-plan-picker', 'ipad-landscape',
})
UI_CASE_EVENT_PATTERN = re.compile(
    r"Test Case '[-+]\[[^\s\]\r\n]+\.MirrorUITests (test[A-Za-z0-9_]+)\]' (started|passed|failed)(?=[\s.]|$)")
UI_CASE_TIMING_PATTERN = re.compile(
    r"Test Case '[-+]\[[^\s\]\r\n]+\.MirrorUITests (test[A-Za-z0-9_]+)\]' "
    r'(passed|failed) \(([0-9]{1,6}(?:\.[0-9]{1,9})?) seconds\)\.?\s*$')
UI_SCREENSHOT_TIMING_PATTERN = re.compile(
    r'UI screenshot timing: stage=([a-z-]{1,32}),milliseconds=([0-9]{1,7})\s*$')
STORE_DEDUP_DIAGNOSTIC_MARKER = 'Store dedup result diagnostic:'
COMMAND_RESULT_STATES = frozenset({
    'locallyCommitted', 'alreadyApplied', 'requiresConfirmation', 'staleSnapshot',
    'staleContext', 'alreadyDecided', 'notFound', 'unavailable', 'persistenceFailed',
    'committedProjectionPending',
})
UI_FAILURE_SOURCE_FILE = 'Tests/MirrorUITests/MirrorUITests.swift'
UI_ASSERTION_KINDS = frozenset({
    'XCTAssert', 'XCTAssertTrue', 'XCTAssertFalse', 'XCTAssertEqual', 'XCTAssertNotEqual',
    'XCTAssertGreaterThan', 'XCTAssertGreaterThanOrEqual', 'XCTAssertLessThan',
    'XCTAssertLessThanOrEqual', 'XCTAssertNil', 'XCTAssertNotNil', 'XCTAssertIdentical',
    'XCTAssertNotIdentical', 'XCTAssertThrowsError', 'XCTAssertNoThrow', 'XCTFail',
})
UI_XCTFAIL_REASON_PREFIXES = (
    ('앱 프로세스가 종료되어 필수 UI 요소를 조회할 수 없다', 'applicationNotRunning'),
    ('필수 UI 요소가 없다', 'missingElement'),
    ('작업 행을 포함하는 스크롤 컨테이너가 없다', 'rowScrollContainerMissing'),
    ('대상 UI를 포함하는 스크롤 컨테이너가 없다', 'scrollContainerMissing'),
    ('UI 요소에 도달할 수 없다', 'unhittableOrDisabled'),
)
UI_ANY_CASE_EVENT_PATTERN = re.compile(
    r"Test Case '[-+]\[([^\s\]\r\n]+) (test[A-Za-z0-9_]+)\]' "
    r'(started|passed|failed|skipped)(?=[\s.]|$)')
UI_FAILURE_SOURCE_PATTERN = re.compile(
    r'^\s*(.+?\.swift):([0-9]{1,5})(?::[0-9]{1,5})?:\s*error:\s*(.*)$')
UI_FAILURE_CASE_PATTERN = re.compile(
    r'^[-+]\[([^\s\]\r\n]+) (test[A-Za-z0-9_]+)\]\s*:\s*(.*)$')
UI_VIEWPORT_DIAGNOSTIC_MARKER = 'UI viewport diagnostic:'
UI_KEYBOARD_DIAGNOSTIC_MARKER = 'UI keyboard introduction diagnostic:'
UI_PHASE_DIAGNOSTIC_MARKER = 'UI test phase diagnostic:'
UI_NATIVE_SCREENSHOT_DIAGNOSTIC_MARKER = 'UI native screenshot diagnostic:'
UI_TOOLBAR_DIAGNOSTIC_MARKER = 'UI search toolbar diagnostic:'
UI_VALIDATION_RECOVERY_DIAGNOSTIC_MARKER = 'UI validation recovery diagnostic:'
UI_NAVIGATION_GEOMETRY_DIAGNOSTIC_MARKER = 'UI navigation geometry diagnostic:'
UI_CAPTURE_PHASE_DIAGNOSTIC_MARKER = 'UI capture phase diagnostic:'
STRUCTURED_DIAGNOSTIC_MARKERS = frozenset({
    STORE_DEDUP_DIAGNOSTIC_MARKER, UI_VIEWPORT_DIAGNOSTIC_MARKER,
    UI_KEYBOARD_DIAGNOSTIC_MARKER, UI_PHASE_DIAGNOSTIC_MARKER,
    UI_NATIVE_SCREENSHOT_DIAGNOSTIC_MARKER, UI_TOOLBAR_DIAGNOSTIC_MARKER,
    UI_VALIDATION_RECOVERY_DIAGNOSTIC_MARKER, UI_NAVIGATION_GEOMETRY_DIAGNOSTIC_MARKER,
    UI_CAPTURE_PHASE_DIAGNOSTIC_MARKER,
})
UI_PHASE_METHOD = 'testTomorrowStaysOutOfTodayAndIsSearchableInLibrary'
UI_TOOLBAR_IDENTIFIERS = ('capture.open', 'settings.button')
UI_VALIDATION_RECOVERY_METHOD = 'testOverlongTitleShowsErrorAndPreservesEveryCharacter'
UI_CAPTURE_PHASE_METHOD = 'testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday'
UI_CAPTURE_PHASE_NAMES = (
    'started', 'launched', 'initialNavigationVerified', 'initialScreenshotRecorded', 'calendarSelected',
    'calendarNavigationVerified', 'calendarScreenshotRecorded', 'settingsRecorded', 'captureSaved',
    'libraryOpened', 'libraryNavigationVerified', 'libraryScreenshotRecorded', 'selectionRegressionStarted',
    'selectionRegressionComplete', 'reviewOpened', 'todayAssigned', 'todayRowVerified',
    'todayNavigationVerified', 'complete',
)
UI_NAVIGATION_GEOMETRY_FIELDS = ('stage', 'identifier', 'statusFrame', 'windowFrame', 'buttonFrame')
UI_NAVIGATION_GEOMETRY_PREFIXES = {
    UI_CAPTURE_PHASE_METHOD: tuple(
        (stage, identifier) for stage in ('initial-today', 'calendar', 'library', 'today-populated')
        for identifier in UI_TOOLBAR_IDENTIFIERS),
    UI_VALIDATION_RECOVERY_METHOD: tuple(
        ('validation-recovery', identifier) for identifier in UI_TOOLBAR_IDENTIFIERS),
}
UI_VALIDATION_RECOVERY_BOOL_FIELDS = (
    'identifierMatchesCaptureOpen', 'targetIsButton', 'exists', 'enabled', 'hittable',
    'frameHasArea', 'ownedBySingleWindow', 'keyboardPresent', 'alertPresent', 'sheetPresent',
)
UI_VALIDATION_RECOVERY_NULLABLE_FIELDS = ('frameInsideWindow', 'belowStatus')
UI_PHASE_NAMES = (
    'started', 'launched', 'captured', 'reviewOpened', 'tomorrowAssigned', 'reviewClosed',
    'todayExcluded', 'searchNavigationRequested', 'searchReady', 'searchEntered',
    'futureRowVerified', 'searchTitleVerified', 'libraryScreenshotRecorded', 'detailOpened',
    'detailPlanVerified', 'detailScreenshotRecorded', 'detailClosed', 'todayRechecked', 'complete',
)
UI_NATIVE_SCREENSHOT_METHOD = 'testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday'
UI_IMAGE_ORIENTATIONS = frozenset({
    'up', 'down', 'left', 'right', 'upMirrored', 'downMirrored', 'leftMirrored', 'rightMirrored',
})
UI_KEYBOARD_COUNT_FIELDS = (
    'continueQueryCount', 'continueExistingCount', 'continueHittableCount',
    'continueEnabledCount', 'continueInKeyboardCount',
)
UI_KEYBOARD_FRAME_FIELDS = (
    'continueFrameHasArea', 'continueFrameInsideKeyboard',
    'continueFrameCenterInsideKeyboard', 'continueFrameIntersectsKeyboard',
)
UI_KEYBOARD_INTRODUCTION_FIELDS = (
    'continueInIntroductionCount', 'introductionContextCount', 'introductionWindowCount',
    'introductionTextVisible', 'introductionContextValid', 'continueFrameInsideIntroduction',
)
UI_VIEWPORT_CHECK_NAMES = frozenset({
    'foreground', 'appBoundsValid', 'appOrientationMatches', 'windowExists', 'todayExists',
    'reviewExists', 'windowInApp', 'windowOrientationMatches', 'todayInWindow', 'reviewInToday',
    'adjacentExists', 'calendarDateExists', 'adjacentInWindow', 'dateInAdjacent',
    'columnsSeparate', 'portraitAdjacentAbsent', 'reviewHittable', 'dateHittable', 'insideDeadline',
})


def annotation(message):
    escaped = message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    print(f'::error::{escaped}')


def reported_runs(log):
    return [{'tests': int(count), 'result': state}
            for count, state in re.findall(r'Test run with (\d+) tests? (?:in \d+ suites? )?(passed|failed)', log)]


def report_runs(log):
    reports = reported_runs(log)
    if reports:
        print('::notice::Swift Testing completion reports: ' + json.dumps(reports))


def mixed_structured_diagnostic(line, marker):
    return (any(other in line for other in STRUCTURED_DIAGNOSTIC_MARKERS if other != marker)
            or is_ui_failure_candidate(line))


def fixed_diagnostic_json(line, marker):
    # 고정 계약의 모든 JSON 객체에서 중복 키를 거절한다. 원문은 출력하지 않는다.
    def unique_fields(pairs):
        fields = {}
        for key, value in pairs:
            if key in fields:
                raise ValueError('중복된 진단 필드입니다.')
            fields[key] = value
        return fields

    if mixed_structured_diagnostic(line, marker) or UI_ANY_CASE_EVENT_PATTERN.search(line):
        raise ValueError('서로 다른 진단이나 테스트 event를 한 줄에서 연결하지 않습니다.')
    if line.count(marker) != 1:
        raise ValueError('진단 marker가 하나여야 합니다.')
    payload = line.partition(marker)[2].strip()
    if len(payload.encode('utf-8')) > 4096:
        raise ValueError('진단 payload가 너무 깁니다.')
    return json.loads(payload, object_pairs_hook=unique_fields)


def track_active_ui_cases(line, active_cases):
    # 구조화 원문 속에 삽입한 가짜 event로 활성 테스트를 바꾸지 않는다.
    if any(marker in line for marker in STRUCTURED_DIAGNOSTIC_MARKERS) or is_ui_failure_candidate(line):
        return
    event = UI_ANY_CASE_EVENT_PATTERN.search(line)
    if event:
        case = (event[1], event[2])
        if event[3] == 'started':
            active_cases.add(case)
        else:
            active_cases.discard(case)
    elif re.search(r'\bTest\s+Case\b', line):
        active_cases.clear()


def unique_active_ui_method(active_cases, method):
    if len(active_cases) != 1:
        return False
    owner, actual_method = next(iter(active_cases))
    return ((owner == 'MirrorUITests' or owner.endswith('.MirrorUITests'))
            and actual_method == method)


def report_ui_validation_recovery_diagnostics(lines):
    active_cases = set()
    active_case_depths = {}
    ambiguous_active = False
    report = None
    invalid_count = 0
    for line in lines:
        if UI_VALIDATION_RECOVERY_DIAGNOSTIC_MARKER not in line:
            if (not any(marker in line for marker in STRUCTURED_DIAGNOSTIC_MARKERS)
                    and not is_ui_failure_candidate(line)):
                event = UI_ANY_CASE_EVENT_PATTERN.search(line)
                if event:
                    case = (event[1], event[2])
                    if event[3] == 'started':
                        if active_case_depths.get(case, 0):
                            # 동일 이름의 겹친 시작은 모두 닫힐 때까지 유일 실행으로 추정하지 않는다.
                            ambiguous_active = True
                        active_case_depths[case] = active_case_depths.get(case, 0) + 1
                    elif active_case_depths.get(case, 0) > 1:
                        active_case_depths[case] -= 1
                    else:
                        active_case_depths.pop(case, None)
                elif re.search(r'\bTest\s+Case\b', line):
                    active_case_depths.clear()
            track_active_ui_cases(line, active_cases)
            if not active_case_depths:
                ambiguous_active = False
            continue
        try:
            if 'UI screenshot timing:' in line:
                raise ValueError('입력 오류 복구 진단에 screenshot timing을 연결하지 않습니다.')
            candidate = fixed_diagnostic_json(line, UI_VALIDATION_RECOVERY_DIAGNOSTIC_MARKER)
            if (not isinstance(candidate, dict)
                    or set(candidate) != {'method', 'action', 'phase', 'checks'}
                    or candidate['method'] != UI_VALIDATION_RECOVERY_METHOD
                    or candidate['action'] != 'capture.open'
                    or candidate['phase'] != 'validationRecovery'
                    or not isinstance(candidate['checks'], dict)
                    or set(candidate['checks']) != set(UI_VALIDATION_RECOVERY_BOOL_FIELDS
                                                      + UI_VALIDATION_RECOVERY_NULLABLE_FIELDS)
                    or any(type(candidate['checks'][key]) is not bool
                           for key in UI_VALIDATION_RECOVERY_BOOL_FIELDS)
                    or any(candidate['checks'][key] is not None
                           and type(candidate['checks'][key]) is not bool
                           for key in UI_VALIDATION_RECOVERY_NULLABLE_FIELDS)
                    or not unique_active_ui_method(active_cases, UI_VALIDATION_RECOVERY_METHOD)
                    or ambiguous_active or report is not None):
                raise ValueError('입력 오류 복구 진단은 유일한 baseline 사례의 고정 일회성 판정이어야 합니다.')
            report = {
                'scope': 'stdoutOnly', 'method': UI_VALIDATION_RECOVERY_METHOD,
                'action': 'capture.open', 'phase': 'validationRecovery',
                'checks': {key: candidate['checks'][key] for key in
                           UI_VALIDATION_RECOVERY_BOOL_FIELDS + UI_VALIDATION_RECOVERY_NULLABLE_FIELDS},
            }
        except (ValueError, TypeError, RecursionError):
            invalid_count += 1
    # false/null을 보존한다. 무효 전사가 섞이면 일부 관측도 추정하거나 원문을 공개하지 않는다.
    if invalid_count:
        print('::notice::UI validation recovery diagnostic rejected: '
              + json.dumps({'invalidCount': invalid_count}))
    elif report is not None:
        print('::notice::UI validation recovery diagnostic: ' + json.dumps(report))


def track_fixed_ui_case_instances(line, active_cases, depths, epochs, next_epoch, ambiguous):
    # 다른 구조화 원문이나 assertion 안의 가짜 event는 소유자를 바꾸지 않는다.
    if (any(marker in line for marker in STRUCTURED_DIAGNOSTIC_MARKERS)
            or is_ui_failure_candidate(line)):
        return next_epoch, ambiguous
    events = list(UI_ANY_CASE_EVENT_PATTERN.finditer(line))
    if len(events) > 1:
        active_cases.clear()
        depths.clear()
        epochs.clear()
        return next_epoch, True
    if events:
        event = events[0]
        case = (event[1], event[2])
        if event[3] == 'started':
            if depths.get(case, 0):
                ambiguous = True
            else:
                if not depths:
                    ambiguous = False
                next_epoch += 1
                epochs[case] = next_epoch
            depths[case] = depths.get(case, 0) + 1
        elif depths.get(case, 0) > 1:
            depths[case] -= 1
        else:
            depths.pop(case, None)
            epochs.pop(case, None)
    elif re.search(r'\bTest\s+Case\b', line):
        depths.clear()
        epochs.clear()
    track_active_ui_cases(line, active_cases)
    return next_epoch, ambiguous if depths else False


def report_ui_capture_phase_diagnostics(lines):
    active_cases = set()
    active_case_depths = {}
    active_case_epochs = {}
    next_epoch = 0
    ambiguous_active = False
    phases = []
    sample_epoch = None
    invalid_count = 0
    for line in lines:
        if UI_CAPTURE_PHASE_DIAGNOSTIC_MARKER not in line:
            next_epoch, ambiguous_active = track_fixed_ui_case_instances(
                line, active_cases, active_case_depths, active_case_epochs, next_epoch, ambiguous_active)
            continue
        try:
            if 'UI screenshot timing:' in line:
                raise ValueError('입력 사례 단계 진단과 screenshot timing을 연결하지 않습니다.')
            candidate = fixed_diagnostic_json(line, UI_CAPTURE_PHASE_DIAGNOSTIC_MARKER)
            if (not isinstance(candidate, dict) or set(candidate) != {'phase'}
                    or not isinstance(candidate['phase'], str)
                    or ambiguous_active or not unique_active_ui_method(active_cases, UI_CAPTURE_PHASE_METHOD)
                    or len(phases) >= len(UI_CAPTURE_PHASE_NAMES)
                    or candidate['phase'] != UI_CAPTURE_PHASE_NAMES[len(phases)]):
                raise ValueError('입력 사례 단계는 실제 유일한 baseline 사례의 고정 순서 prefix여야 합니다.')
            epoch = active_case_epochs.get(next(iter(active_cases)))
            if epoch is None or (sample_epoch is not None and sample_epoch != epoch):
                raise ValueError('서로 다른 입력 사례 실행의 단계 prefix를 합치지 않습니다.')
            sample_epoch = epoch
            phases.append(candidate['phase'])
        except (ValueError, TypeError, RecursionError):
            invalid_count += 1
    # complete는 실제 도달한 단계 이름이다. 사례 성공이나 뒤쪽 단계는 추정하지 않는다.
    if invalid_count:
        print('::notice::UI capture phase diagnostic rejected: ' + json.dumps({'invalidCount': invalid_count}))
    elif phases:
        print('::notice::UI capture phase diagnostic: ' + json.dumps({
            'scope': 'stdoutOnly', 'method': UI_CAPTURE_PHASE_METHOD, 'phases': phases,
        }))


def report_ui_navigation_geometry_diagnostics(lines):
    active_cases = set()
    active_case_depths = {}
    active_case_epochs = {}
    next_epoch = 0
    ambiguous_active = False
    samples = {method: [] for method in UI_NAVIGATION_GEOMETRY_PREFIXES}
    sample_epochs = {}
    invalid_count = 0

    def fixed_frame(value, allow_zero=False):
        return (isinstance(value, list) and len(value) == 4
                and all(type(number) in (int, float) for number in value)
                and all(abs(number) <= 100000 for number in value[:2])
                and all(0 <= number <= 100000 and (allow_zero or number > 0)
                        for number in value[2:])
                and all(math.isfinite(number) for number in value))

    for line in lines:
        if UI_NAVIGATION_GEOMETRY_DIAGNOSTIC_MARKER not in line:
            next_epoch, ambiguous_active = track_fixed_ui_case_instances(
                line, active_cases, active_case_depths, active_case_epochs, next_epoch, ambiguous_active)
            continue
        try:
            if 'UI screenshot timing:' in line:
                raise ValueError('화면 경계 진단과 screenshot timing을 연결하지 않습니다.')
            candidate = fixed_diagnostic_json(line, UI_NAVIGATION_GEOMETRY_DIAGNOSTIC_MARKER)
            if (not isinstance(candidate, dict) or set(candidate) != set(UI_NAVIGATION_GEOMETRY_FIELDS)
                    or not isinstance(candidate['stage'], str)
                    or not isinstance(candidate['identifier'], str)
                    or any(not fixed_frame(candidate[key], allow_zero=(key == 'buttonFrame')) for key in
                           ('statusFrame', 'windowFrame', 'buttonFrame'))):
                raise ValueError('화면 경계 진단은 고정 stage·identifier와 유한한 frame 배열이어야 합니다.')
            methods = [method for method, prefix in UI_NAVIGATION_GEOMETRY_PREFIXES.items()
                       if any(stage == candidate['stage'] for stage, _ in prefix)]
            if (len(methods) != 1 or ambiguous_active
                    or not unique_active_ui_method(active_cases, methods[0])):
                raise ValueError('화면 경계 진단은 실제 유일한 baseline 사례 소유여야 합니다.')
            method = methods[0]
            prefix = UI_NAVIGATION_GEOMETRY_PREFIXES[method]
            case = next(iter(active_cases))
            epoch = active_case_epochs.get(case)
            if (epoch is None or len(samples[method]) >= len(prefix)
                    or (candidate['stage'], candidate['identifier']) != prefix[len(samples[method])]
                    or (method in sample_epochs and sample_epochs[method] != epoch)):
                raise ValueError('화면 경계 진단은 동일한 실제 실행의 고정 순서 prefix여야 합니다.')
            sample_epochs[method] = epoch
            samples[method].append({key: candidate[key] for key in UI_NAVIGATION_GEOMETRY_FIELDS})
        except (ValueError, TypeError, RecursionError):
            invalid_count += 1
    # 관측한 prefix만 보존한다. 사례 성공·실패 원인이나 누락된 뒤쪽 단계를 추정하지 않는다.
    # 무효 원문이 섞이면 어떤 부분 관측도 공개하지 않는다.
    if invalid_count:
        print('::notice::UI navigation geometry diagnostic rejected: '
              + json.dumps({'invalidCount': invalid_count}))
    else:
        for method, observed in samples.items():
            if observed:
                print('::notice::UI navigation geometry diagnostic: ' + json.dumps({
                    'scope': 'stdoutOnly', 'method': method, 'samples': observed,
                }))


def report_ui_toolbar_diagnostics(lines):
    active_cases = set()
    buttons = []
    invalid_count = 0
    for line in lines:
        if UI_TOOLBAR_DIAGNOSTIC_MARKER not in line:
            track_active_ui_cases(line, active_cases)
            continue
        try:
            candidate = fixed_diagnostic_json(line, UI_TOOLBAR_DIAGNOSTIC_MARKER)
            if (not isinstance(candidate, dict) or set(candidate) != {
                    'method', 'identifier', 'hittable', 'belowStatus', 'frameInsideWindow'}
                    or candidate['method'] != UI_PHASE_METHOD
                    or not isinstance(candidate['identifier'], str)
                    or any(type(candidate[key]) is not bool
                           for key in ('hittable', 'belowStatus', 'frameInsideWindow'))
                    or not unique_active_ui_method(active_cases, UI_PHASE_METHOD)
                    or len(buttons) >= len(UI_TOOLBAR_IDENTIFIERS)
                    or candidate['identifier'] != UI_TOOLBAR_IDENTIFIERS[len(buttons)]):
                raise ValueError('검색 상단 버튼은 실제 유일한 baseline 사례의 고정 순서 prefix여야 합니다.')
            buttons.append({key: candidate[key] for key in
                            ('identifier', 'hittable', 'belowStatus', 'frameInsideWindow')})
        except (ValueError, TypeError, RecursionError):
            invalid_count += 1
    # 실제 false 판정도 보존한다. 무효 원문이 섞이면 부분 관측을 추정하지 않는다.
    if invalid_count:
        print('::notice::UI search toolbar diagnostic rejected: ' + json.dumps({'invalidCount': invalid_count}))
    elif buttons:
        print('::notice::UI search toolbar diagnostic: ' + json.dumps({
            'scope': 'stdoutOnly', 'method': UI_PHASE_METHOD, 'buttons': buttons,
        }))


def report_ui_phase_diagnostics(lines):
    active_cases = set()
    reports = []
    invalid_count = 0
    for line in lines:
        if UI_PHASE_DIAGNOSTIC_MARKER not in line:
            track_active_ui_cases(line, active_cases)
            continue
        try:
            report = fixed_diagnostic_json(line, UI_PHASE_DIAGNOSTIC_MARKER)
            if (not isinstance(report, dict) or set(report) != {'method', 'phase'}
                    or report['method'] != UI_PHASE_METHOD
                    or not isinstance(report['phase'], str)
                    or not unique_active_ui_method(active_cases, UI_PHASE_METHOD)
                    or len(reports) >= len(UI_PHASE_NAMES)
                    or report['phase'] != UI_PHASE_NAMES[len(reports)]):
                raise ValueError('UI phase는 실제 유일한 baseline 사례의 순서 있는 prefix여야 합니다.')
            reports.append({'scope': 'stdoutOnly', **report})
        except (ValueError, TypeError, RecursionError):
            invalid_count += 1
    # malformed·중복·순서 오류가 하나라도 있으면 그 transcript의 prefix도 추정하지 않는다.
    if invalid_count:
        print('::notice::UI test phase diagnostic rejected: ' + json.dumps({'invalidCount': invalid_count}))
    elif reports:
        # 단계마다 주석을 만들지 않고 검증한 prefix 전체를 한 번에 보존한다.
        print('::notice::UI test phase diagnostic: ' + json.dumps({
            'scope': 'stdoutOnly', 'method': UI_PHASE_METHOD,
            'phases': [report['phase'] for report in reports],
        }))


def report_ui_native_screenshot_diagnostics(lines):
    active_cases = set()
    report = None
    invalid_count = 0
    def positive_number(value, upper):
        return (type(value) in (int, float) and 0 < value <= upper and math.isfinite(value))

    for line in lines:
        if UI_NATIVE_SCREENSHOT_DIAGNOSTIC_MARKER not in line:
            track_active_ui_cases(line, active_cases)
            continue
        try:
            candidate = fixed_diagnostic_json(line, UI_NATIVE_SCREENSHOT_DIAGNOSTIC_MARKER)
            if (not isinstance(candidate, dict) or set(candidate) != {
                    'method', 'stage', 'orientation', 'imageWidth', 'imageHeight', 'imageScale',
                    'cgImageWidth', 'cgImageHeight', 'pngSHA256'}
                    or candidate['method'] != UI_NATIVE_SCREENSHOT_METHOD
                    or candidate['stage'] != 'ipad-landscape'
                    or not isinstance(candidate['orientation'], str)
                    or candidate['orientation'] not in UI_IMAGE_ORIENTATIONS
                    or not positive_number(candidate['imageWidth'], 16384)
                    or not positive_number(candidate['imageHeight'], 16384)
                    or not positive_number(candidate['imageScale'], 8)
                    or any(type(candidate[key]) is not int or not 1 <= candidate[key] <= 16384
                           for key in ('cgImageWidth', 'cgImageHeight'))
                    or not isinstance(candidate['pngSHA256'], str)
                    or re.fullmatch(r'[0-9a-f]{64}', candidate['pngSHA256']) is None
                    or not unique_active_ui_method(active_cases, UI_NATIVE_SCREENSHOT_METHOD)
                    or report is not None):
                raise ValueError('native screenshot은 실제 baseline 사례의 고정 일회성 metadata여야 합니다.')
            report = {'scope': 'stdoutOnly', **candidate}
        except (ValueError, TypeError, RecursionError):
            invalid_count += 1
    if invalid_count:
        print('::notice::UI native screenshot diagnostic rejected: ' + json.dumps({'invalidCount': invalid_count}))
    elif report is not None:
        print('::notice::UI native screenshot diagnostic: ' + json.dumps(report))


def report_store_dedup_diagnostics(lines):
    # 원본 값·경로·메시지 대신 현재 enum 두 상태와 고정 busy 판정 두 개만 공개한다.
    reports = deque(maxlen=8)
    invalid_count = 0

    def unique_fields(pairs):
        fields = {}
        for key, value in pairs:
            if key in fields:
                raise ValueError('중복된 진단 필드입니다.')
            fields[key] = value
        return fields

    for line in lines:
        if STORE_DEDUP_DIAGNOSTIC_MARKER not in line:
            continue
        try:
            if mixed_structured_diagnostic(line, STORE_DEDUP_DIAGNOSTIC_MARKER):
                raise ValueError('서로 다른 진단을 한 줄에서 연결하지 않습니다.')
            if line.count(STORE_DEDUP_DIAGNOSTIC_MARKER) != 1:
                raise ValueError('진단 marker가 하나여야 합니다.')
            payload = line.partition(STORE_DEDUP_DIAGNOSTIC_MARKER)[2].strip()
            if len(payload) > 4096:
                raise ValueError('진단 payload가 너무 깁니다.')
            report = json.loads(payload, object_pairs_hook=unique_fields)
            if not isinstance(report, dict) or set(report) != {'states', 'busyResults'}:
                raise ValueError('진단 필드는 states와 busyResults여야 합니다.')
            states, busy_results = report['states'], report['busyResults']
            if (not isinstance(states, list) or len(states) != 2
                    or any(not isinstance(state, str) or state not in COMMAND_RESULT_STATES
                           for state in states)
                    or not isinstance(busy_results, list) or len(busy_results) != 2
                    or any(type(value) is not bool for value in busy_results)):
                raise ValueError('진단은 enum 상태 두 개와 bool 두 개여야 합니다.')
            reports.append({'method': 'independentInstancesDeduplicate', 'scope': 'stdoutOnly',
                            'states': states, 'busyResults': busy_results})
        except (ValueError, TypeError, RecursionError):
            invalid_count += 1
    for report in reports:
        print('::notice::Store dedup result diagnostic: ' + json.dumps(report))
    if invalid_count:
        print('::notice::Store dedup result diagnostic rejected: '
              + json.dumps({'invalidCount': invalid_count}))


def valid_ui_duration(value):
    # bool과 범위 밖 정수는 float 변환 전에 제외한다. 진단 수치를 통과 게이트로 쓰지 않는다.
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and 0 <= value <= 1200 and math.isfinite(value))


def is_ui_failure_candidate(line):
    # 미지의 source·assertion도 원문 fallback에 넘기지 않는다. 일반 컴파일 오류는 유지한다.
    return bool(re.search(r':\s*error:', line)
                and (re.search(r'[-+]\[(?:[^\s\]\r\n]+\.)?MirrorUITests\s', line)
                     or re.search(r'\bXCTAssert[A-Za-z_]*\s+failed(?=[:\s-]|$)', line)
                     or 'failed -' in line))


def report_ui_first_failure(lines):
    active_cases = set()
    first_failure = None
    invalid_count = 0

    def own_case(case):
        return ((case[0] == 'MirrorUITests' or case[0].endswith('.MirrorUITests'))
                and case[1] in UI_BASELINE_METHODS)

    for line in lines:
        if not is_ui_failure_candidate(line):
            event = UI_ANY_CASE_EVENT_PATTERN.search(line)
            if event:
                case = (event[1], event[2])
                if event[3] == 'started':
                    active_cases.add(case)
                else:
                    active_cases.discard(case)
            elif re.search(r'\bTest\s+Case\b', line):
                # 파손된 이름·event 이후에는 앞 테스트를 활성 상태로 추정하지 않는다.
                active_cases.clear()
            continue
        source = UI_FAILURE_SOURCE_PATTERN.match(line)
        if not source or not (source[1] in ('MirrorUITests.swift', UI_FAILURE_SOURCE_FILE)
                              or source[1].endswith('/' + UI_FAILURE_SOURCE_FILE)):
            invalid_count += 1
            continue
        line_number = int(source[2])
        if not 1 <= line_number <= 10000:
            invalid_count += 1
            continue
        payload = source[3].strip()
        explicit = UI_FAILURE_CASE_PATTERN.match(payload)
        if explicit:
            case = (explicit[1], explicit[2])
            payload = explicit[3]
        elif payload.startswith(('-[', '+[')):
            invalid_count += 1
            continue
        else:
            case = next(iter(active_cases)) if len(active_cases) == 1 else None
        assertion = re.match(r'^(XCTAssert[A-Za-z]*)\s+failed(?=[:\s-]|$)', payload)
        kind = assertion[1] if assertion else 'XCTFail' if payload.startswith('failed -') else None
        if case is None or not own_case(case) or kind not in UI_ASSERTION_KINDS:
            invalid_count += 1
            continue
        if first_failure is None:
            first_failure = {'scope': 'stdoutOnly', 'method': case[1],
                             'sourceFile': UI_FAILURE_SOURCE_FILE, 'line': line_number,
                             'assertionKind': kind}
            if kind == 'XCTFail':
                # 승인한 source·case의 고정 접두사만 enum으로 바꾼다. 뒤쪽 원문은 출력하지 않는다.
                reason = next((reason for prefix, reason in UI_XCTFAIL_REASON_PREFIXES
                               if payload.startswith('failed - ' + prefix + ': ')), None)
                if reason is not None:
                    first_failure['failureReason'] = reason
    if first_failure is not None:
        print('::notice::UI first failure: ' + json.dumps(first_failure))
    if invalid_count:
        print('::notice::UI first failure rejected: ' + json.dumps({'invalidCount': invalid_count}))


def report_ui_keyboard_diagnostics(lines):
    reports = deque(maxlen=8)
    invalid_count = 0

    def unique_fields(pairs):
        fields = {}
        for key, value in pairs:
            if key in fields:
                raise ValueError('중복된 keyboard 필드입니다.')
            fields[key] = value
        return fields

    for line in lines:
        if UI_KEYBOARD_DIAGNOSTIC_MARKER not in line:
            continue
        try:
            if mixed_structured_diagnostic(line, UI_KEYBOARD_DIAGNOSTIC_MARKER):
                raise ValueError('서로 다른 진단을 한 줄에서 연결하지 않습니다.')
            if line.count(UI_KEYBOARD_DIAGNOSTIC_MARKER) != 1:
                raise ValueError('keyboard marker가 하나여야 합니다.')
            payload = line.partition(UI_KEYBOARD_DIAGNOSTIC_MARKER)[2].strip()
            if len(payload.encode('utf-8')) > 4096:
                raise ValueError('keyboard payload가 너무 깁니다.')
            report = json.loads(payload, object_pairs_hook=unique_fields)
            basic_fields = {'phase', 'continueCandidateCount', 'keyboardBoundsValid', 'elapsedMilliseconds'}
            count_fields = basic_fields | set(UI_KEYBOARD_COUNT_FIELDS)
            frame_fields = count_fields | set(UI_KEYBOARD_FRAME_FIELDS)
            introduction_fields = frame_fields | set(UI_KEYBOARD_INTRODUCTION_FIELDS)
            if (not isinstance(report, dict)
                    or set(report) not in (basic_fields, count_fields, frame_fields, introduction_fields)):
                raise ValueError('keyboard 필드가 고정 계약과 다릅니다.')
            has_introduction_context = set(report) == introduction_fields
            count, milliseconds = report['continueCandidateCount'], report['elapsedMilliseconds']
            if (report['phase'] not in ('continueReadiness', 'introductionDismissal')
                    or type(count) is not int or not 0 <= count <= 100
                    or type(report['keyboardBoundsValid']) is not bool
                    or type(milliseconds) is not int or not 0 <= milliseconds <= 1200000):
                raise ValueError('keyboard 수치·phase가 고정 계약과 다릅니다.')
            if set(report) != basic_fields:
                counts = [report[key] for key in UI_KEYBOARD_COUNT_FIELDS]
                if (any(type(value) is not int or not 0 <= value <= 100 for value in counts)
                        or any(previous < current for previous, current in zip(counts, counts[1:]))
                        or (not has_introduction_context and counts[-1] != count)):
                    raise ValueError('keyboard count는 기존 AX 조회 순서의 단조 감소이며 legacy 최종 후보 수와 같아야 합니다.')
            if set(report) in (frame_fields, introduction_fields):
                has_area, inside, center_inside, intersects = [report[key] for key in UI_KEYBOARD_FRAME_FIELDS]
                if report['continueEnabledCount'] != 1:
                    if any(value is not None for value in (has_area, inside, center_inside, intersects)):
                        raise ValueError('유일한 enabled 후보가 없으면 frame 진단은 모두 null이어야 합니다.')
                elif type(has_area) is not bool:
                    raise ValueError('유일한 enabled 후보의 면적 판정은 bool이어야 합니다.')
                elif not has_area:
                    if (count != 0 or report['continueInKeyboardCount'] != 0
                            or any(value is not None for value in (inside, center_inside, intersects))):
                        raise ValueError('면적이 없는 frame은 최종 후보가 아니며 나머지 판정은 null이어야 합니다.')
                elif (any(type(value) is not bool for value in (inside, center_inside, intersects))
                        or inside != (report['continueInKeyboardCount'] == 1)
                        or (inside and not (center_inside and intersects))
                        or (has_introduction_context and center_inside and not intersects)):
                    raise ValueError('frame 포함 판정은 keyboard 관측 수·중심·교차 판정과 일치해야 합니다.')
            if has_introduction_context:
                guide_count = report['continueInIntroductionCount']
                context_count = report['introductionContextCount']
                window_count = report['introductionWindowCount']
                text_visible = report['introductionTextVisible']
                context_valid = report['introductionContextValid']
                inside_guide = report['continueFrameInsideIntroduction']
                if (type(guide_count) is not int or not 0 <= guide_count <= 1
                        or any(type(value) is not int or not 0 <= value <= 100
                               for value in (context_count, window_count))
                        or type(text_visible) is not bool or type(context_valid) is not bool
                        or count != guide_count or guide_count > report['continueEnabledCount']):
                    raise ValueError('안내 context의 고정 count·bool과 최종 후보 수가 일치해야 합니다.')
                can_evaluate_guide = (report['keyboardBoundsValid'] is True
                                      and report['continueEnabledCount'] == 1
                                      and report['continueFrameHasArea'] is True
                                      and context_count == 1 and window_count == 1 and text_visible)
                if context_valid:
                    if (not can_evaluate_guide or type(inside_guide) is not bool
                            or guide_count != int(inside_guide)):
                        raise ValueError('유효한 유일 안내 context 안의 frame 포함 판정이 후보 수와 같아야 합니다.')
                elif inside_guide is not None or guide_count != 0:
                    raise ValueError('유효한 안내 context가 없으면 frame 판정은 null이고 안내 후보 수는 0이어야 합니다.')
            reports.append({'scope': 'stdoutOnly', **report})
        except (ValueError, TypeError, RecursionError):
            invalid_count += 1
    for report in reports:
        print('::notice::UI keyboard introduction diagnostic: ' + json.dumps(report))
    if invalid_count:
        print('::notice::UI keyboard introduction diagnostic rejected: '
              + json.dumps({'invalidCount': invalid_count}))


def report_ui_viewport_diagnostics(lines):
    reports = deque(maxlen=8)
    invalid_count = 0

    def unique_fields(pairs):
        fields = {}
        for key, value in pairs:
            if key in fields:
                raise ValueError('중복된 viewport 필드입니다.')
            fields[key] = value
        return fields

    for line in lines:
        if UI_VIEWPORT_DIAGNOSTIC_MARKER not in line:
            continue
        try:
            if mixed_structured_diagnostic(line, UI_VIEWPORT_DIAGNOSTIC_MARKER):
                raise ValueError('서로 다른 진단을 한 줄에서 연결하지 않습니다.')
            if line.count(UI_VIEWPORT_DIAGNOSTIC_MARKER) != 1:
                raise ValueError('viewport marker가 하나여야 합니다.')
            payload = line.partition(UI_VIEWPORT_DIAGNOSTIC_MARKER)[2].strip()
            if len(payload) > 4096:
                raise ValueError('viewport payload가 너무 깁니다.')
            report = json.loads(payload, object_pairs_hook=unique_fields)
            if not isinstance(report, dict) or set(report) != {
                    'orientation', 'stableSamples', 'elapsedMilliseconds', 'checks'}:
                raise ValueError('viewport 필드가 고정 계약과 다릅니다.')
            samples, milliseconds, checks = report['stableSamples'], report['elapsedMilliseconds'], report['checks']
            if (report['orientation'] not in ('landscape', 'portrait')
                    or type(samples) is not int or not 0 <= samples <= 10000
                    or type(milliseconds) is not int or not 0 <= milliseconds <= 1200000
                    or not isinstance(checks, dict) or not set(checks).issubset(UI_VIEWPORT_CHECK_NAMES)
                    or any(type(value) is not bool for value in checks.values())):
                raise ValueError('viewport 수치·check가 고정 계약과 다릅니다.')
            reports.append({'scope': 'stdoutOnly', **report})
        except (ValueError, TypeError, RecursionError):
            invalid_count += 1
    for report in reports:
        print('::notice::UI viewport diagnostic: ' + json.dumps(report))
    if invalid_count:
        print('::notice::UI viewport diagnostic rejected: ' + json.dumps({'invalidCount': invalid_count}))


def report_ui_timing_diagnostics(lines):
    cases = {}
    captures = deque(maxlen=16)
    for line in lines:
        case = UI_CASE_TIMING_PATTERN.search(line)
        if case and case[1] in UI_BASELINE_METHODS:
            seconds = float(case[3])
            if valid_ui_duration(seconds):
                cases.pop(case[1], None)
                cases[case[1]] = {'scope': 'stdoutOnly', 'method': case[1],
                                  'event': case[2], 'seconds': seconds}
        capture = UI_SCREENSHOT_TIMING_PATTERN.search(line)
        if capture and capture[1] in UI_SCREENSHOT_STAGES:
            milliseconds = int(capture[2])
            if milliseconds <= 1_200_000:
                captures.append({'scope': 'stdoutOnly', 'stage': capture[1],
                                 'milliseconds': milliseconds})
    # 사례마다 별도 notice로 남겨 긴 이름 때문에 뒤쪽 사례가 잘리지 않게 한다.
    for case in cases.values():
        print('::notice::UI case timing: ' + json.dumps(case))
    for capture in captures:
        print('::notice::UI screenshot timing: ' + json.dumps(capture))


def report_ui_tree_timings(nodes):
    cases = {}

    def visit(node):
        if isinstance(node, dict):
            name = node.get('name')
            method = re.search(r'\b(test[A-Za-z0-9_]+)\b', name) if isinstance(name, str) else None
            duration = node.get('durationInSeconds')
            if (node.get('nodeType') == 'Test Case' and method
                    and method[1] in UI_BASELINE_METHODS
                    and node.get('result') in ('Passed', 'Failed') and valid_ui_duration(duration)):
                cases.pop(method[1], None)
                cases[method[1]] = {'scope': 'xcresult', 'method': method[1],
                                    'event': node['result'].lower(), 'seconds': duration}
            for value in node.values():
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)

    visit(nodes)
    if cases:
        print('::notice::UI xcresult case timings: ' + json.dumps({
            'scope': 'xcresult', 'cases': [
                {'method': case['method'], 'event': case['event'], 'seconds': case['seconds']}
                for case in cases.values()
            ],
        }))


def diagnostics(path):
    log = Path(path).read_text(errors='replace')
    raw_lines = log.splitlines()
    lines = [line for line in raw_lines
             if not any(marker in line for marker in STRUCTURED_DIAGNOSTIC_MARKERS)]
    report_ui_first_failure(lines)
    report_ui_validation_recovery_diagnostics(raw_lines)
    report_ui_navigation_geometry_diagnostics(raw_lines)
    report_ui_capture_phase_diagnostics(raw_lines)
    report_ui_toolbar_diagnostics(raw_lines)
    report_ui_keyboard_diagnostics(raw_lines)
    report_ui_viewport_diagnostics(raw_lines)
    report_ui_native_screenshot_diagnostics(raw_lines)
    report_ui_phase_diagnostics(raw_lines)
    report_store_dedup_diagnostics(raw_lines)
    # 유효·무효 구조화 원문은 다른 진단·오류 fallback에도 섞지 않는다.
    lines = [line for line in lines if not is_ui_failure_candidate(line)]
    log = '\n'.join(lines)
    report_runs(log)
    # 중단된 xcresult와 stdout의 사례 진행을 구별한다. 게이트 통과 판정에는 사용하지 않는다.
    case_events = []
    for line in lines:
        match = UI_CASE_EVENT_PATTERN.search(line)
        if match and match[1] in UI_BASELINE_METHODS:
            case_events.append({'method': match[1], 'event': match[2]})
    if case_events:
        summaries = list(dict.fromkeys(line.strip() for line in lines
                        if re.match(r'\s*Executed \d+ tests?, with \d+ failures?', line)))
        print('::notice::UI stdout diagnostics: ' + json.dumps({
            'scope': 'stdoutOnly', 'events': case_events[-18:],
            'suiteSummaries': summaries[-3:],
            'xcodeCompletionReported': bool(re.search(r'\*\* TEST(?: EXECUTE)? (?:SUCCEEDED|FAILED) \*\*', log)),
        }, ensure_ascii=False))
    report_ui_timing_diagnostics(lines)
    owners = list(dict.fromkeys(line.strip() for line in lines if 'UI row scroll owner:' in line))
    if owners:
        print('::notice::UI row scroll owners: ' + json.dumps(owners[-8:], ensure_ascii=False))
    # UI 구조화 원문은 안전한 이름·수치만 위에서 출력한다. 알 수 없는 이름이나
    # 잘못된 timing payload를 일반 오류/마지막 줄 fallback에서 다시 공개하지 않는다.
    error_lines = [line for line in lines if 'UI screenshot timing:' not in line
                   and not (re.search(r'\bTest\s+Case\b', line) and 'MirrorUITests' in line)]
    relevant = [line for line in error_lines if re.search(r'error:|failed|Issue recorded|fatal:', line, re.I)
                and not re.match(r'^\s*[|`~-]', line)]
    unique = list(dict.fromkeys(relevant))
    for line in unique[:40] or error_lines[-8:]:
        annotation(line[:1800])


def record(count, unit_count=None, ui_count=None):
    if not isinstance(count, int) or isinstance(count, bool) or count <= 0:
        raise ValueError('실제 실행한 테스트가 1개 이상이어야 합니다.')
    result = {'executedTests': count, 'result': 'pass'}
    if unit_count is not None:
        result.update(unitTests=unit_count, uiTests=ui_count)
    print(json.dumps(result))
    output = os.environ.get('GITHUB_OUTPUT')
    if output:
        with Path(output).open('a') as stream:
            stream.write(f'tests={count}\n')
            if unit_count is not None:
                stream.write(f'unit_tests={unit_count}\nui_tests={ui_count}\n')


def xcode_count(path):
    summary = json.loads(Path(path).read_text())
    print('::notice::Xcode test summary: ' + json.dumps({
        'file': Path(path).name,
        'totalTestCount': summary.get('totalTestCount'),
        'passedTests': summary.get('passedTests'),
        'failedTests': summary.get('failedTests'),
        'skippedTests': summary.get('skippedTests'),
    }))
    total = summary['totalTestCount']
    if not isinstance(total, int) or isinstance(total, bool) or total <= 0:
        raise ValueError(f'{path}: 실제 테스트 수가 양수여야 합니다.')
    if summary['failedTests'] != 0 or summary['skippedTests'] != 0 or summary['passedTests'] != total:
        raise ValueError(f'{path}: 실패·skip 없이 모든 테스트가 통과해야 합니다.')
    return total


def ui_guard(path, required_bundle, source_root):
    """실제 UI bundle/case와 baseline 및 현재 선언을 함께 확인한다."""
    source_root = Path(source_root)
    declarations = set()
    for source in source_root.rglob('*.swift'):
        declarations.update(re.findall(
            r'^\s*(?:(?:public|open|internal|fileprivate|private|final|override|nonisolated|static|class)\s+)*'
            r'func\s+(test[A-Za-z0-9_]+)\s*\(', source.read_text(), re.M))
    if not UI_BASELINE_METHODS.issubset(declarations):
        raise ValueError('UI 소스에 필수 baseline 6개 메서드 선언이 모두 있어야 합니다.')
    nodes = json.loads(Path(path).read_text())
    bundles = []
    cases = []

    def visit(node, in_required_bundle=False):
        if isinstance(node, dict):
            # run 36785953557의 실제 UI tree: UI test bundle / Test Case / Passed 또는 Failed.
            if node.get('nodeType') == 'UI test bundle':
                in_required_bundle = node.get('name') == required_bundle
                if in_required_bundle:
                    bundles.append(node.get('result'))
            if in_required_bundle and node.get('nodeType') == 'Test Case':
                name = node.get('name')
                match = re.search(r'\b(test[A-Za-z0-9_]+)\b', name) if isinstance(name, str) else None
                cases.append({'method': match.group(1) if match else None, 'result': node.get('result')})
            for value in node.values():
                visit(value, in_required_bundle)
        elif isinstance(node, list):
            for value in node:
                visit(value, in_required_bundle)

    visit(nodes)
    executed = {case['method'] for case in cases if case['method'] is not None}
    missing = sorted(declarations - executed)
    failed = [case['method'] for case in cases if case['result'] != 'Passed' or case['method'] is None]
    print('::notice::UI execution guard: ' + json.dumps({
        'requiredBundle': required_bundle, 'actualBundleCount': len(bundles),
        'actualCaseCount': len(cases), 'declaredMethods': sorted(declarations),
        'missingMethods': missing, 'nonPassedMethods': failed,
    }, ensure_ascii=False))
    if not bundles:
        raise ValueError(f'{required_bundle}: 실제 필수 UI bundle이 있어야 합니다.')
    if not cases or missing or failed:
        raise ValueError('UI baseline과 현재 선언된 모든 테스트가 실제 Test Case로 실행되어 Passed여야 합니다.')


def main():
    mode, path, *additional_paths = sys.argv[1:]
    if mode == 'diagnostics':
        diagnostics(path)
        return
    if mode == 'native-screenshot-diagnostics':
        report_ui_native_screenshot_diagnostics(Path(path).read_text(errors='replace').splitlines())
        return
    if mode == 'swift':
        log = Path(path).read_text(errors='replace')
        report_runs(log)
        reports = reported_runs(log)
        # Xcode 27 SwiftPM은 세 test target을 독립 worker에서 실행한다.
        # 실제 관측: 3ac7f99 run 36760077361의 25/94/21 완료 보고. 마지막 worker만 세지 않는다.
        if len(reports) != 3 or any(r['result'] != 'passed' or r['tests'] <= 0 for r in reports):
            raise ValueError('필수 세 SwiftPM 테스트 target의 양수 통과 완료 보고가 있어야 합니다.')
        if re.search(r'\btest(?:s)?\b.*\bskipped\b', log, re.I):
            raise ValueError('Swift 테스트에 skipped 결과가 있습니다.')
        report_store_dedup_diagnostics(log.splitlines())
        record(sum(report['tests'] for report in reports))
    elif mode == 'xcode':
        unit = xcode_count(path)
        if additional_paths:
            if len(additional_paths) != 1:
                raise ValueError('UI 결과 요약은 한 파일이어야 합니다.')
            ui = xcode_count(additional_paths[0])
            record(unit + ui, unit, ui)
        else:
            record(unit)
    elif mode == 'ui-tree':
        # 실패/timeout에서도 실제 SDK test tree 구조를 진단한다.
        nodes = json.loads(Path(path).read_text())
        node_types = {}
        methods = []

        def result_structure(value):
            if isinstance(value, str):
                return value if re.fullmatch(r'[A-Za-z _-]{1,64}', value) else {'valueType': 'string'}
            if value is None or isinstance(value, (bool, int, float)):
                return value
            return {'valueType': type(value).__name__, 'keys': list(value)[:16] if isinstance(value, dict) else []}

        def visit_ui(node):
            if isinstance(node, dict):
                node_type = node.get('nodeType')
                if isinstance(node_type, str):
                    node_types[node_type] = node_types.get(node_type, 0) + 1
                name = node.get('name')
                match = re.search(r'\b(test[A-Za-z0-9_]+)\b', name) if isinstance(name, str) else None
                if match and len(methods) < 64:
                    methods.append({'method': match.group(1), 'nodeType': node_type,
                                    'result': result_structure(node.get('result')),
                                    'keys': list(node)[:16]})
                for value in node.values():
                    visit_ui(value)
            elif isinstance(node, list):
                for value in node:
                    visit_ui(value)

        visit_ui(nodes)
        report_ui_tree_timings(nodes)
        print('::notice::UI test structure: ' + json.dumps({
            'rootKeys': list(nodes)[:16] if isinstance(nodes, dict) else [],
            'nodeTypes': node_types, 'methods': methods,
        }, ensure_ascii=False))
    elif mode == 'ui-guard':
        if len(additional_paths) != 2:
            raise ValueError('필수 UI bundle과 현재 UI 테스트 소스 디렉터리를 지정해야 합니다.')
        ui_guard(path, additional_paths[0], additional_paths[1])
    elif mode == 'bundles':
        if not additional_paths:
            raise ValueError('필수 테스트 bundle 목록이 있어야 합니다.')
        nodes = json.loads(Path(path).read_text())
        bundles = {}
        node_types = {}
        named_nodes = []

        def cases(node):
            if isinstance(node, dict):
                return int(node.get('nodeType') == 'Test Case') + sum(cases(v) for v in node.values())
            if isinstance(node, list):
                return sum(cases(v) for v in node)
            return 0

        def visit(node):
            if isinstance(node, dict):
                node_type = node.get('nodeType')
                if isinstance(node_type, str):
                    node_types[node_type] = node_types.get(node_type, 0) + 1
                name = node.get('name')
                if isinstance(name, str) and name in additional_paths and len(named_nodes) < 12:
                    named_nodes.append({'name': name[:120], 'nodeType': node_type, 'keys': list(node)[:12]})
                # Xcode 27 run 36763990118의 실제 tests.json에서 관측한 형식.
                if node.get('nodeType') in ('Test Bundle', 'Unit test bundle'):
                    bundles[node.get('name')] = cases(node)
                for value in node.values():
                    visit(value)
            elif isinstance(node, list):
                for value in node:
                    visit(value)

        visit(nodes)
        print('::notice::Xcode test structure: ' + json.dumps({'rootKeys': list(nodes)[:16] if isinstance(nodes, dict) else [], 'nodeTypes': node_types, 'bundles': bundles, 'namedNodes': named_nodes}, ensure_ascii=False))
        for bundle in additional_paths:
            if bundles.get(bundle, 0) <= 0:
                raise ValueError(f'{bundle}: 실제 테스트 bundle/case를 찾지 못했습니다. 확인한 bundle: {bundles}')
        print(json.dumps({'requiredTestBundles': {b: bundles[b] for b in additional_paths}}))
    else:
        raise ValueError(f'알 수 없는 결과 형식: {mode}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        annotation(str(error))
        raise SystemExit(1) from error
