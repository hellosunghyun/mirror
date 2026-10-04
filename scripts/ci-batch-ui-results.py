#!/usr/bin/env python3
"""실제 2/20개 batch UI의 SDK 결과를 검증한다. CLI는 GitHub Actions 전용이다.

기존 안전한 파일·빌드 제품·Simulator 검증을 재사용한다. 원본 xcresult/log/AX는
공개 artifact에 넣지 않고 고정 실행 소유·두 typed 사례의 수만 보존한다.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_batch_file_support', ROOT / 'scripts/ci-adaptive-ui-results.py')
SUPPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SUPPORT)
CLASS = 'MirrorBatchUITests'
CASES = ('testTwoTaskBatchKeepsUnselectedTaskAndOriginalContent',
         'testTwentyTaskBatchKeepsEveryOriginalAndUsesTomorrow')
SOURCE = 'Tests/MirrorBatchUITests/MirrorBatchUITests.swift'
COUNT_FIELDS = {'totalTestCount': 2, 'passedTests': 2, 'failedTests': 0, 'skippedTests': 0}
MAX_LOG = 64 * 1024 * 1024
PROGRESS_MARKER = 'Batch UI progress: '
DISCLOSURE_MARKER = 'Batch UI disclosure failure diagnostic: '


class BatchError(Exception):
    pass


def require(condition, code='invalidBatchEvidence'):
    if not condition:
        raise BatchError(code)


def identity(platform):
    require(platform in ('iphone', 'ipad', 'macos'), 'invalidPlatform')
    values = {key: os.environ.get(variable, '') for key, variable in (
        ('commitSHA', 'GITHUB_SHA'), ('buildNumber', 'GITHUB_RUN_NUMBER'),
        ('runID', 'GITHUB_RUN_ID'), ('runAttempt', 'GITHUB_RUN_ATTEMPT'))}
    require(re.fullmatch(r'[0-9a-f]{40}', values['commitSHA']) is not None, 'invalidRunIdentity')
    require(all(re.fullmatch(r'[1-9][0-9]{0,19}', values[key]) for key in
                ('buildNumber', 'runID', 'runAttempt')), 'invalidRunIdentity')
    require(os.environ.get('GITHUB_REPOSITORY') == 'hellosunghyun/mirror', 'invalidRepository')
    require(os.environ.get('GITHUB_EVENT_NAME') in ('workflow_dispatch', 'push'), 'invalidEvent')
    return {**values, 'platform': platform}


def checkout_matches(expected):
    require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, stderr=subprocess.DEVNULL,
                                    text=True).strip() == expected['commitSHA'], 'checkoutSHAMismatch')
    require(subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--'], cwd=ROOT,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0,
            'modifiedCheckout')
    require(not subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '--',
                                        'App', 'Sources', 'Extensions', 'Tests', 'scripts'], cwd=ROOT,
                                       stderr=subprocess.DEVNULL), 'untrackedSource')


def directory_for(platform):
    relative = Path('.build/ci-batch-ui') / platform
    directory = ROOT / relative
    require(not directory.is_symlink() and all(not parent.is_symlink() for parent in directory.parents),
            'unsafeDirectory')
    require(directory.resolve().is_relative_to((ROOT / '.build/ci-batch-ui').resolve()), 'unsafeDirectory')
    return directory


def base_context(expected):
    mac = expected['platform'] == 'macos'
    return {**expected, 'scheme': 'MirrorMacBatchUI' if mac else 'MirrorIOSBatchUI',
            'bundle': 'MirrorMacBatchUITests' if mac else 'MirrorIOSBatchUITests',
            'class': CLASS, 'sdk': 'macosx' if mac else 'iphonesimulator'}



def runtime_and_devices():
    """기존 SDK27 runtime 계약을 유지하며 native stderr는 공개하지 않는다."""
    version = SUPPORT.read_json(ROOT / 'development-baseline.json')['observedToolchain']['iOSSimulatorRuntime']
    runtimes = SUPPORT.strict_json(subprocess.check_output(
        ['xcrun', 'simctl', 'list', 'runtimes', '--json'], stderr=subprocess.DEVNULL))
    matches = [value for value in runtimes['runtimes'] if value.get('version') == version
               and value.get('isAvailable') is True
               and value.get('identifier', '').startswith('com.apple.CoreSimulator.SimRuntime.iOS-')]
    require(len(matches) == 1, 'missingRequiredRuntime')
    devices = SUPPORT.strict_json(subprocess.check_output(
        ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], stderr=subprocess.DEVNULL))
    return devices['devices'].get(matches[0]['identifier'], [])


def prepare(directory, expected):
    checkout_matches(expected)
    require(not directory.exists(), 'staleBatchDirectory')
    if expected['platform'] == 'macos':
        destination = 'platform=macOS'
    else:
        family = 'iPhone' if expected['platform'] == 'iphone' else 'iPad'
        devices = [device for device in runtime_and_devices()
                   if device.get('name', '').startswith(family) and device.get('state') in ('Booted', 'Shutdown')
                   and re.fullmatch(r'[0-9A-Fa-f-]{36}', device.get('udid', ''))]
        require(devices, 'missingRequiredSimulator')
        device = sorted(devices, key=lambda value: (value['state'] != 'Booted', value['name'], value['udid']))[0]
        destination = 'platform=iOS Simulator,id=' + device['udid']
    directory.mkdir(parents=True, exist_ok=False)
    SUPPORT.write_json(directory / 'context.json', {**base_context(expected), 'destination': destination}, exclusive=True)


def context_for(directory, expected):
    context = SUPPORT.read_json(directory / 'context.json')
    require(isinstance(context, dict) and set(context) == set(base_context(expected)) | {'destination'}
            and all(context[key] == value for key, value in base_context(expected).items()), 'contextMismatch')
    destination = context['destination']
    require(isinstance(destination, str) and
            (destination == 'platform=macOS' if expected['platform'] == 'macos' else
             re.fullmatch(r'platform=iOS Simulator,id=[0-9A-Fa-f-]{36}', destination) is not None), 'contextMismatch')
    checkout_matches(expected)
    return context


def build_state(directory, expected):
    context = context_for(directory, expected)
    products = directory / 'DerivedData/Build/Products'
    require(products.is_dir() and products.resolve(strict=True).is_relative_to(directory.resolve()), 'missingBuildProducts')
    runs = sorted(path for path in products.rglob('*.xctestrun') if path.is_file())
    bundles = sorted(path for path in products.rglob(context['bundle'] + '.xctest') if path.is_dir())
    require(0 < len(runs) <= 16 and 0 < len(bundles) <= 16, 'missingOrExcessiveBatchBuildProduct')
    configuration = 'Debug' if expected['platform'] == 'macos' else 'Debug-iphonesimulator'
    return {'formatVersion': 1, 'context': context, 'codeCoverage': False, 'codeSigningAllowed': False,
            'xctestruns': [SUPPORT.file_record(path, products) for path in runs],
            'app': SUPPORT.bundle_record(products / configuration / 'Mirror.app', products, expected),
            'testBundles': [SUPPORT.bundle_record(path, products, expected) for path in bundles]}


def verify_receipt(directory, expected):
    require(SUPPORT.read_json(directory / 'build-receipt.json') == build_state(directory, expected), 'buildReceiptMismatch')
    return SUPPORT.digest(SUPPORT.read_regular(directory / 'build-receipt.json', SUPPORT.MAX_JSON))


def boot(directory, expected):
    context = context_for(directory, expected)
    if expected['platform'] == 'macos':
        return
    udid = context['destination'].split('id=', 1)[1]
    matches = [device for device in runtime_and_devices() if device.get('udid') == udid]
    require(len(matches) == 1 and matches[0].get('state') in ('Booted', 'Shutdown'), 'simulatorContextMismatch')
    if matches[0]['state'] == 'Shutdown':
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def validate_summary(summary):
    require(isinstance(summary, dict) and all(type(summary.get(key)) is int and summary[key] == value
            for key, value in COUNT_FIELDS.items()), 'batchSuiteSummaryMismatch')


def validate_tree(tree, bundle):
    require(isinstance(tree, dict) and isinstance(tree.get('testNodes'), list), 'unsupportedTestTree')
    bundles, cases = [], []
    visited = 0
    def visit(node, owner=None, depth=0):
        nonlocal visited
        visited += 1
        require(visited <= 10_000 and depth <= 32 and isinstance(node, dict), 'unsupportedTestTree')
        if node.get('nodeType') in ('UI test bundle', 'Unit test bundle'):
            bundles.append((node.get('nodeType'), node.get('name'), node.get('result')))
            owner = node.get('name')
        if node.get('nodeType') == 'Test Case':
            cases.append((owner, node.get('name'), node.get('result')))
        children = node.get('children', [])
        require(isinstance(children, list), 'unsupportedTestTree')
        for child in children:
            visit(child, owner, depth + 1)
    for node in tree['testNodes']:
        visit(node)
    required = [(bundle, case + '()', 'Passed') for case in CASES]
    require(bundles == [('UI test bundle', bundle, 'Passed')] and len(cases) == len(required)
            and sorted(cases) == sorted(required), 'batchSuiteTreeMismatch')


def validate_log(log, bundle):
    require(isinstance(log, str) and len(log.encode('utf-8')) <= MAX_LOG, 'invalidLogBounds')
    active = None
    completed = []
    owner = bundle + '.' + CLASS
    for line in log.splitlines():
        if 'Test Case ' not in line:
            continue
        matches = list(SUPPORT.CASE_EVENT.finditer(line))
        require(line.count('Test Case ') == 1 and len(matches) == 1, 'unsupportedCaseEvent')
        match = matches[0]
        require(match[2] == owner and match[3] in CASES, 'caseOwnerMismatch')
        case, state = match[3], match[4]
        if state == 'started':
            require(active is None and case not in completed, 'duplicateOrParallelCase')
            active = case
        else:
            require(state == 'passed' and active == case, 'caseDidNotPass')
            completed.append(case)
            active = None
    require(active is None and len(completed) == len(CASES) and set(completed) == set(CASES), 'batchSuiteCaseCountMismatch')



def failure_locations(log, bundle, source_root=ROOT):
    """현재 두 사례의 실제 Swift 위치·assertion 종류만 반환하고 원문은 버린다."""
    require(isinstance(log, str) and len(log.encode('utf-8')) <= MAX_LOG, 'invalidLogBounds')
    reports = []
    for line in log.splitlines():
        match = SUPPORT.UI_FAILURE_SOURCE.fullmatch(line)
        if not match:
            continue
        case = SUPPORT.UI_FAILURE_CASE.match(match[4])
        if not case or case[1] != bundle + '.' + CLASS or case[2] not in CASES:
            continue
        location = SUPPORT.source_location(match[1], int(match[2]), int(match[3]) if match[3] else 1, source_root)
        if not location or location['file'] != SOURCE:
            continue
        assertion = re.match(r'^(XCT[A-Za-z]+)(?:\s|$)', case[3])
        kind = assertion[1] if assertion and assertion[1] in SUPPORT.UI_ASSERTION_KINDS else 'unclassified'
        report = {'scope': 'stdoutOnly', 'method': case[2], 'sourceFile': SOURCE,
                  'line': location['line'],
                  **({'column': location['column']} if match[3] else {}),
                  'assertionKind': kind}
        if report not in reports:
            reports.append(report)
        if len(reports) == 12:
            break
    return reports


def query_failure_locations(log, bundle, source_root=ROOT):
    """검증된 두 사례의 고정 query 종류만 반환한다. payload와 원본 경로는 버린다."""
    require(isinstance(log, str) and len(log.encode('utf-8')) <= MAX_LOG, 'invalidLogBounds')
    prefixes = (
        (r'^Failed to get matching snapshots?(?:\s|[.:]|$)', 'failedToGetMatchingSnapshot'),
        (r'^Multiple matching elements found(?:\s|[.:]|$)', 'multipleMatchingElements'),
        (r'^(?:No matching elements found|No matches found)(?:\s|[.:]|$)', 'noMatchingElements'),
        (r'^AX snapshot timed out(?:\s|[.:]|$)', 'axSnapshotTimedOut'),
        (r'^Element query evaluation failed(?:\s|[.:]|$)', 'elementQueryEvaluationFailed'),
        (r'^Application is not running(?:\s|[.:]|$)', 'applicationNotRunning'),
        (r'^Unhandled XCTest exception(?:\s|[.:]|$)', 'unhandledXCTestException'),
    )
    reports = []
    source_line_count = None
    for line in log.splitlines():
        match = SUPPORT.UI_FAILURE_SOURCE.fullmatch(line)
        if not match:
            continue
        case = SUPPORT.UI_FAILURE_CASE.match(match[4])
        if not case or case[1] != bundle + '.' + CLASS or case[2] not in CASES:
            continue
        location = SUPPORT.source_location(match[1], int(match[2]), int(match[3]) if match[3] else 1, source_root)
        if not location or location['file'] != SOURCE:
            continue
        if source_line_count is None:
            try:
                source_line_count = len(SUPPORT.read_regular(source_root / SOURCE, SUPPORT.MAX_JSON).decode('utf-8').splitlines())
            except (OSError, UnicodeError, SUPPORT.AdaptiveError):
                return []
        if location['line'] > source_line_count:
            continue
        assertion = re.match(r'^(XCT[A-Za-z]+)(?:\s|$)', case[3])
        if assertion and assertion[1] in SUPPORT.UI_ASSERTION_KINDS:
            continue
        kind = next((kind for pattern, kind in prefixes if re.match(pattern, case[3])), 'unknown')
        report = {'scope': 'stdoutOnly', 'method': case[2], 'sourceFile': SOURCE,
                  'line': location['line'],
                  **({'column': location['column']} if match[3] else {}),
                  'queryFailureKind': kind}
        if report not in reports:
            reports.append(report)
        if len(reports) == 12:
            break
    return reports


def reachable_failure_locations(log, bundle, source_root=ROOT):
    """현재 사례의 정확한 XCTFail 고정 문장만 보존한다. 원문·측정값은 버린다."""
    require(isinstance(log, str) and len(log.encode('utf-8')) <= MAX_LOG, 'invalidLogBounds')
    reasons = ('batchTargetIsNotReachableWithin15SecondsAnd12Scrolls', 'batchActualScrollOwnerMissing',
               'batchActualScrollOwnerAmbiguous', 'batchScrollOwnerRequiresActualSurface')
    targets = ('unknown', 'captureOpen', 'captureSave', 'captureClose', 'destinationToday', 'destinationLibrary',
               'librarySearch', 'librarySelectToggle', 'librarySelectAll', 'taskRow', 'taskSelection',
               'planToday', 'planTomorrow', 'planCancel', 'planDisclosure', 'planTask')
    marker = re.compile(r'failed - (' + '|'.join(reasons) + r') target=(' + '|'.join(targets) + r')')
    reports, source_line_count = [], None
    for text in log.splitlines():
        match = SUPPORT.UI_FAILURE_SOURCE.fullmatch(text)
        if not match:
            continue
        case = SUPPORT.UI_FAILURE_CASE.fullmatch(match[4])
        if not case or case[1] != bundle + '.' + CLASS or case[2] not in CASES:
            continue
        fixed = marker.fullmatch(case[3])
        if fixed is None:
            continue
        location = SUPPORT.source_location(match[1], int(match[2]), int(match[3]) if match[3] else 1, source_root)
        if not location or location['file'] != SOURCE:
            continue
        if source_line_count is None:
            try:
                source_line_count = len(SUPPORT.read_regular(source_root / SOURCE, SUPPORT.MAX_JSON).decode('utf-8').splitlines())
            except (OSError, UnicodeError, SUPPORT.AdaptiveError):
                return []
        if location['line'] > source_line_count:
            continue
        report = {'scope': 'stdoutOnly', 'method': case[2], 'sourceFile': SOURCE,
                  'line': location['line'], **({'column': location['column']} if match[3] else {}),
                  'reason': fixed[1], 'target': fixed[2]}
        if report not in reports:
            reports.append(report)
        if len(reports) == 12:
            break
    return reports


def mobile_target_failure_locations(log, bundle, source_root=ROOT):
    """실제 44pt assertion 소스와 고정 control/axis만 보존한다. 원문과 측정값은 버린다."""
    require(isinstance(log, str) and len(log.encode('utf-8')) <= MAX_LOG, 'invalidLogBounds')
    controls = ('captureOpen', 'captureSave', 'captureClose', 'librarySelectToggle', 'librarySelectAll',
                'libraryBatchPlan', 'planToday', 'planTomorrow', 'planCancel', 'destinationToday', 'destinationCalendar',
                'destinationLibrary', 'taskSelection', 'other')
    marker = re.compile(r'(?:^| - )Batch UI mobile target: (width|height) (' + '|'.join(controls) + r')$')
    reports, source_lines = [], None
    for text in log.splitlines():
        match = SUPPORT.UI_FAILURE_SOURCE.fullmatch(text)
        if not match:
            continue
        case = SUPPORT.UI_FAILURE_CASE.match(match[4])
        if not case or case[1] != bundle + '.' + CLASS or case[2] not in CASES:
            continue
        if not re.match(r'^XCTAssertGreaterThanOrEqual\s+failed(?=[:\s-]|$)', case[3]):
            continue
        fixed = marker.search(case[3])
        if fixed is None:
            continue
        location = SUPPORT.source_location(match[1], int(match[2]), int(match[3]) if match[3] else 1, source_root)
        if not location or location['file'] != SOURCE:
            continue
        if source_lines is None:
            try:
                source_lines = SUPPORT.read_regular(source_root / SOURCE, SUPPORT.MAX_JSON).decode('utf-8').splitlines()
            except (OSError, UnicodeError, SUPPORT.AdaptiveError):
                return []
        if location['line'] > len(source_lines):
            continue
        axis, control = fixed[1], fixed[2]
        required_source = ('XCTAssertGreaterThanOrEqual(element.frame.' + axis
                           + ', 44, "Batch UI mobile target: ' + axis + ' \\(target)")')
        if source_lines[location['line'] - 1].strip() != required_source:
            continue
        report = {'scope': 'stdoutOnly', 'method': case[2], 'sourceFile': SOURCE,
                  'line': location['line'], **({'column': location['column']} if match[3] else {}),
                  'axis': axis, 'targetControl': control}
        if report not in reports:
            reports.append(report)
        if len(reports) == 12:
            break
    return reports


def progress_steps(case):
    capture_count = 3 if case == CASES[0] else 20
    steps = [('started', 0), ('launched', 0)]
    steps += [(phase, ordinal) for ordinal in range(1, capture_count + 1)
              for phase in ('captureStarted', 'captureSaveRequested', 'captureSaved')]
    phases = ['captureComplete', 'libraryStarted', 'libraryVerified']
    if case == CASES[0]:
        phases += ['selectionStarted', 'selectionVerified', 'libraryReturnStarted', 'libraryReturnVerified',
                   'pickerStarted', 'pickerVerified', 'cancelStarted', 'cancelVerified',
                   'pickerStarted', 'pickerVerified', 'todayCommitStarted', 'todayCommitVerified',
                   'selectionStarted', 'selectionVerified', 'pickerStarted', 'pickerVerified']
    else:
        phases += ['bulkSelectionStarted', 'bulkSelectionVerified', 'selectionStarted', 'selectionVerified',
                   'pickerStarted', 'pickerVerified']
    phases += ['tomorrowCommitStarted', 'tomorrowCommitVerified', 'complete']
    return steps + [(phase, 0) for phase in phases]


def partial_progress(log, bundle):
    """현재 순차 사례의 완전한 marker만 관측한다. 중단된 stdout은 수용 결과가 아니다."""
    unavailable = {'status': 'diagnosticUnavailable'}
    if not isinstance(log, str) or len(log.encode('utf-8')) > MAX_LOG:
        return unavailable
    reports, active, sequence = [], None, 0
    for line in log.splitlines():
        if 'Batch UI progress' in line:
            if active is None or not line.startswith(PROGRESS_MARKER) or len(line.encode('utf-8')) + 1 > 512:
                return unavailable
            try:
                value = SUPPORT.strict_json(line[len(PROGRESS_MARKER):])
            except (SUPPORT.AdaptiveError, ValueError, TypeError, RecursionError):
                return unavailable
            if (not isinstance(value, dict) or set(value) != {'method', 'phase', 'sequence', 'captureOrdinal'}
                    or value['method'] != active['method'] or type(value['sequence']) is not int
                    or type(value['captureOrdinal']) is not int or value['sequence'] != sequence + 1):
                return unavailable
            steps = progress_steps(active['method'])
            if sequence >= len(steps) or (value['phase'], value['captureOrdinal']) != steps[sequence]:
                return unavailable
            sequence += 1
            active['lastProgress'] = {key: value[key] for key in ('phase', 'sequence', 'captureOrdinal')}
        elif re.search(r'\bTest\s+Case\b', line):
            event = re.fullmatch(
                r"Test Case '-\[([A-Za-z_][A-Za-z0-9_.]*) ([A-Za-z_][A-Za-z0-9_]*)\]' "
                r'(started|passed|failed|skipped)(?: \([0-9]{1,6}(?:\.[0-9]{1,9})? seconds\))?\.', line)
            if (event is None or event[1] != bundle + '.' + CLASS or event[2] not in CASES
                    or (event[3] == 'started' and not line.endswith("' started."))):
                return unavailable
            if event[3] == 'started':
                if active is not None or any(report['method'] == event[2] for report in reports):
                    return unavailable
                active = {'method': event[2], 'terminal': 'notObserved', 'lastProgress': None}
                reports.append(active)
                sequence = 0
            else:
                if (active is None or active['method'] != event[2]
                        or (event[3] == 'passed' and sequence != len(progress_steps(event[2])))):
                    return unavailable
                active['terminal'] = event[3]
                active = None
    return {'status': 'partial', 'cases': reports} if reports else unavailable


def disclosure_failure_diagnostics(log, bundle, source_root=ROOT):
    """실패 후 고정 관측을 같은 Mac 사례·진행·실제 접힘 assertion에만 연결한다."""
    if (bundle != 'MirrorMacBatchUITests' or not isinstance(log, str)
            or len(log.encode('utf-8')) > MAX_LOG or DISCLOSURE_MARKER.rstrip() not in log):
        return []
    if partial_progress(log, bundle).get('status') != 'partial':
        return []
    try:
        source = SUPPORT.read_regular(source_root / SOURCE, SUPPORT.MAX_JSON).decode('utf-8').splitlines()
    except (OSError, UnicodeError, SUPPORT.AdaptiveError):
        return []
    declaration = '    private func verifyPicker(_ selected: [OriginalTask], in app: XCUIApplication) throws {'
    if source.count(declaration) != 1:
        return []
    start = source.index(declaration)
    end = next((index for index in range(start + 1, len(source))
                if source[index].startswith('    private func ')), len(source))
    expected_source = [
        'let initialState = textValue(disclosure)',
        'recordPlannerDisclosureFailureIfNeeded(disclosure, initialState: initialState, callerLine: #line + 1)',
        'XCTAssertEqual(initialState, "접힘", "여러 제목을 처음에는 접어 빠른 날짜를 먼저 보여 준다.")',
    ]
    calls = [index + 1 for index in range(start + 2, end)
             if [line.strip() for line in source[index - 2:index + 1]] == expected_source]
    if len(calls) != 1 or 'progress(.pickerStarted)' not in [line.strip() for line in source[start:calls[0] - 2]]:
        return []
    caller_line = calls[0]
    if SUPPORT.source_location(SOURCE, caller_line, 1, source_root) is None:
        return []
    fields = {'schemaVersion', 'method', 'phase', 'progressSequence', 'callerLine', 'target',
              'observationTiming', 'role', 'valueKind', 'valueState'}
    states = {'nil': ('other',), 'string': ('folded', 'expanded', 'empty', 'placeholder', 'other'),
              'number': ('binaryZero', 'binaryOne', 'other'), 'other': ('other',)}
    reports, active, progress, observation, location = [], None, None, None, None
    for line in log.splitlines():
        if DISCLOSURE_MARKER.rstrip() in line:
            if (active is None or observation is not None or progress is None
                    or progress['phase'] != 'pickerStarted' or not line.startswith(DISCLOSURE_MARKER)
                    or len(line.encode('utf-8')) + 1 > 768):
                return []
            try:
                value = SUPPORT.strict_json(line[len(DISCLOSURE_MARKER):])
            except (SUPPORT.AdaptiveError, ValueError, TypeError, RecursionError):
                return []
            if (not isinstance(value, dict) or set(value) != fields
                    or type(value['schemaVersion']) is not int or value['schemaVersion'] != 1
                    or value['method'] != active or value['phase'] != 'pickerStarted'
                    or type(value['progressSequence']) is not int or not 1 <= value['progressSequence'] <= 96
                    or value['progressSequence'] != progress['sequence']
                    or type(value['callerLine']) is not int or not 1 <= value['callerLine'] <= 100_000
                    or value['callerLine'] != caller_line or value['target'] != 'planDisclosure'
                    or value['observationTiming'] != 'afterMismatch'
                    or value['role'] not in ('disclosureTriangle', 'button', 'other')
                    or not isinstance(value['valueKind'], str) or value['valueKind'] not in states
                    or value['valueState'] not in states[value['valueKind']]):
                return []
            observation = value
        elif line.startswith(PROGRESS_MARKER):
            if observation is not None:
                return []
            progress = SUPPORT.strict_json(line[len(PROGRESS_MARKER):])
        elif event := SUPPORT.UI_CASE_EVENT.match(line):
            if event[3] == 'started':
                active, progress, observation, location = event[2], None, None, None
            else:
                if observation is not None:
                    if event[3] != 'failed' or location is None:
                        return []
                    reports.append({'scope': 'partialFailureOnly', **observation, 'sourceFile': SOURCE,
                                    **location, 'terminal': 'failed'})
                active, progress, observation, location = None, None, None, None
        elif observation is not None and (failure := SUPPORT.UI_FAILURE_SOURCE.fullmatch(line)):
            case = SUPPORT.UI_FAILURE_CASE.fullmatch(failure[4])
            found = SUPPORT.source_location(failure[1], int(failure[2]),
                                            int(failure[3]) if failure[3] else 1, source_root)
            if (case is None or case[1] != bundle + '.' + CLASS or case[2] != active
                    or found is None or found['file'] != SOURCE or found['line'] != caller_line
                    or re.match(r'^XCTAssertEqual\s+failed(?=[:\s-]|$)', case[3]) is None
                    or location is not None):
                return []
            location = {'line': found['line'], **({'column': found['column']} if failure[3] else {})}
    return [] if observation is not None else reports


def diagnostics(directory, expected, phase, partial_failure=False):
    require(phase in ('build', 'test'), 'invalidArguments')
    require(not partial_failure or phase == 'test', 'invalidArguments')
    context = context_for(directory, expected)
    log = SUPPORT.read_regular(directory / (phase + '.log'), MAX_LOG).decode('utf-8', errors='replace')
    reports = SUPPORT.compiler_diagnostics(log, ROOT) if phase == 'build' else failure_locations(log, context['bundle'])
    print('::notice::Batch UI source diagnostics: ' + json.dumps(
        {**expected, 'phase': phase, 'scope': 'stdoutOnly', 'locations': reports}, sort_keys=True))
    if phase == 'test':
        query_reports = query_failure_locations(log, context['bundle'])
        print('::notice::Batch UI query failure diagnostics: ' + json.dumps(
            {**expected, 'phase': phase, 'scope': 'stdoutOnly', 'locations': query_reports,
             'locationCount': len(query_reports)}, sort_keys=True))
        reachable_reports = reachable_failure_locations(log, context['bundle'])
        if reachable_reports:
            print('::notice::Batch UI reachable failure diagnostics: ' + json.dumps(
                {**expected, 'phase': phase, 'scope': 'stdoutOnly', 'locations': reachable_reports,
                 'locationCount': len(reachable_reports)}, sort_keys=True))
        mobile_reports = mobile_target_failure_locations(log, context['bundle'])
        if mobile_reports:
            print('::notice::Batch UI mobile target diagnostics: ' + json.dumps(
                {**expected, 'phase': phase, 'scope': 'stdoutOnly', 'locations': mobile_reports,
                 'locationCount': len(mobile_reports)}, sort_keys=True))
        if partial_failure:
            validate_source(SUPPORT.read_regular(ROOT / SOURCE, SUPPORT.MAX_JSON).decode('utf-8'))
            print('::notice::Batch UI partial progress diagnostics: ' + json.dumps(
                {**expected, 'scope': 'partialFailureOnly', **partial_progress(log, context['bundle'])}, sort_keys=True))
            if expected['platform'] == 'macos':
                disclosure_reports = disclosure_failure_diagnostics(log, context['bundle'])
                if disclosure_reports:
                    print('::notice::Batch UI disclosure failure diagnostics: ' + json.dumps(
                        {**expected, 'scope': 'partialFailureOnly', 'locations': disclosure_reports,
                         'locationCount': len(disclosure_reports)}, sort_keys=True))


def validate_source(source):
    require(source.splitlines().count('final class MirrorBatchUITests: XCTestCase {') == 1, 'batchSourceClassMismatch')
    declarations = re.findall(r'^    func (test[A-Za-z0-9_]+)\(\) throws \{$', source, re.M)
    require(len(declarations) == len(CASES) and set(declarations) == set(CASES), 'batchSourceMethodMismatch')


def validate_outcome(outcome, expected):
    base = set(expected) | {'phase', 'status', 'commandExitCode', 'xcodebuildExitCode'}
    require(isinstance(outcome, dict) and all(outcome.get(key) == value for key, value in expected.items()), 'outcomeIdentityMismatch')
    command, native = outcome.get('commandExitCode'), outcome.get('xcodebuildExitCode')
    require(type(command) is int and 0 <= command <= 255 and
            (native is None or type(native) is int and 0 <= native <= 255), 'invalidOutcome')
    status, phase = outcome.get('status'), outcome.get('phase')
    if status == 'failed':
        require(set(outcome) == base and phase in ('build', 'test') and command > 0, 'invalidOutcome')
    elif status == 'buildComplete':
        require(set(outcome) == base and phase == 'build' and command == native == 0, 'invalidOutcome')
    elif status == 'passed':
        require(set(outcome) == base | set(COUNT_FIELDS) | {'methods', 'testSourceSHA256', 'buildReceiptSHA256'}
                and phase == 'test' and command == native == 0, 'invalidOutcome')
        validate_summary(outcome)
        require(outcome['methods'] == list(CASES), 'invalidOutcome')
        require(all(re.fullmatch(r'[0-9a-f]{64}', outcome.get(key, '')) for key in
                    ('testSourceSHA256', 'buildReceiptSHA256')), 'invalidOutcome')
    else:
        raise BatchError('invalidOutcome')


def guard(directory, expected):
    context = context_for(directory, expected)
    receipt_hash = verify_receipt(directory, expected)
    source = SUPPORT.read_regular(ROOT / SOURCE, SUPPORT.MAX_JSON)
    validate_source(source.decode('utf-8', errors='strict'))
    validate_summary(SUPPORT.read_json(directory / 'summary.json'))
    validate_tree(SUPPORT.read_json(directory / 'tests.json'), context['bundle'])
    validate_log(SUPPORT.read_regular(directory / 'test.log', MAX_LOG).decode('utf-8', errors='strict'), context['bundle'])
    outcome = {**expected, 'phase': 'test', 'status': 'passed', 'commandExitCode': 0, 'xcodebuildExitCode': 0,
               **COUNT_FIELDS, 'methods': list(CASES), 'testSourceSHA256': SUPPORT.digest(source),
               'buildReceiptSHA256': receipt_hash}
    validate_outcome(outcome, expected)
    SUPPORT.write_json(directory / 'safe-outcome.json', outcome)
    print('::notice::Batch UI typed result: ' + json.dumps(outcome, sort_keys=True))
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as stream:
        stream.write('batch_tests=2\nbatch_passed_tests=2\nbatch_failed_tests=0\nbatch_skipped_tests=0\n')


class StrictArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise BatchError('invalidArguments')


def main():
    require(os.environ.get('GITHUB_ACTIONS') == 'true', 'batchRemoteOnly')
    parser = StrictArgumentParser()
    parser.add_argument('command', choices=('prepare', 'context', 'receipt-record', 'receipt-verify', 'boot', 'guard', 'outcome-verify', 'diagnostics', 'failure'))
    parser.add_argument('--platform', choices=('iphone', 'ipad', 'macos'), required=True)
    parser.add_argument('--phase', choices=('build', 'test'))
    parser.add_argument('--exit-code', type=int)
    parser.add_argument('--native-exit-code', type=int, default=-1)
    parser.add_argument('--partial-failure', action='store_true')
    args = parser.parse_args()
    require(not args.partial_failure or (args.command == 'diagnostics' and args.phase == 'test'), 'invalidArguments')
    expected = identity(args.platform)
    directory = directory_for(args.platform)
    if args.command == 'prepare':
        prepare(directory, expected)
    elif args.command == 'context':
        context = context_for(directory, expected)
        print('\t'.join(context[key] for key in ('scheme', 'sdk', 'destination')))
    elif args.command == 'receipt-record':
        SUPPORT.write_json(directory / 'build-receipt.json', build_state(directory, expected), exclusive=True)
        SUPPORT.write_json(directory / 'safe-outcome.json', {**expected, 'phase': 'build', 'status': 'buildComplete',
                           'commandExitCode': 0, 'xcodebuildExitCode': 0})
    elif args.command == 'receipt-verify':
        verify_receipt(directory, expected)
    elif args.command == 'boot':
        boot(directory, expected)
    elif args.command == 'guard':
        guard(directory, expected)
    elif args.command == 'outcome-verify':
        validate_outcome(SUPPORT.read_json(directory / 'safe-outcome.json'), expected)
    elif args.command == 'diagnostics':
        diagnostics(directory, expected, args.phase, partial_failure=args.partial_failure)
    else:
        require(args.phase in ('build', 'test') and type(args.exit_code) is int and 1 <= args.exit_code <= 255
                and -1 <= args.native_exit_code <= 255, 'invalidArguments')
        directory.mkdir(parents=True, exist_ok=True)
        SUPPORT.write_json(directory / 'safe-outcome.json', {**expected, 'phase': args.phase, 'status': 'failed',
                           'commandExitCode': args.exit_code,
                           'xcodebuildExitCode': None if args.native_exit_code == -1 else args.native_exit_code})


if __name__ == '__main__':
    try:
        main()
    except BatchError as error:
        print('::error::' + str(error), file=sys.stderr)
        raise SystemExit(1) from None
    except (SUPPORT.AdaptiveError, OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError,
            subprocess.SubprocessError):
        print('::error::batchProcessingFailed', file=sys.stderr)
        raise SystemExit(1) from None
