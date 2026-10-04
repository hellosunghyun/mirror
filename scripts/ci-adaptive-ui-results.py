#!/usr/bin/env python3
"""적응형 UI 전체 사례의 실제 결과와 앱 PNG만 정제한다. CLI는 Actions 전용이다.

원본 로그·xcresult·export JSON·알 수 없는 문자열은 artifact에 넣지 않는다.
새 XCTest class의 SDK tree 표현은 추정하지 않고 실제 사례 이벤트로 소유를 확인한다.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
CLASS = 'MirrorAdaptiveUITests'
CASES = {
    'testMaximumTypeCaptureValidationAndRecovery': ('max-capture', 'max-validation', 'max-recovery'),
    'testMaximumTypeReviewAndWeekPicker': ('max-review', 'max-week'),
    'testMaximumTypeSearchDetailCompletionAndUndo': ('max-search', 'max-detail', 'max-completion', 'max-undo'),
    'testMaximumTypePlannedCaptureKeepsUnassignedDefault': ('max-capture-plan', 'max-planned-today'),
    'testNarrowMacWindowCaptureAndRequestedDetail': ('narrow-main', 'narrow-detail'),
}
NARROW = 'testNarrowMacWindowCaptureAndRequestedDetail'
CONFIG_MARKER = 'UI adaptive applied configuration: '
MAX_JSON = 16 * 1024 * 1024
MAX_LOG = 64 * 1024 * 1024
MAX_PNG = 64 * 1024 * 1024
MAX_PIXELS = 40_000_000
MAX_RAW = 320 * 1024 * 1024
MAX_FILES = 10_000
SIGNATURE = b'\x89PNG\r\n\x1a\n'
STAGE_PATTERN = '|'.join(re.escape(stage) for stages in CASES.values() for stage in stages)
SHOT_PATTERN = re.compile(r'mirror-adaptive-(' + STAGE_PATTERN + r')-([1-9][0-9]{0,5})')
UUID = r'[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}'
SDK_SHOT_PATTERN = re.compile(r'(' + SHOT_PATTERN.pattern + r')_[0-9]{1,6}_' + UUID)
SAFE_PNG = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,239}\.png')
CASE_EVENT = re.compile(
    r"Test Case '(-\[([A-Za-z_][A-Za-z0-9_.]*) ([A-Za-z_][A-Za-z0-9_]*)\])' "
    r'(started|passed|failed|skipped)(?=[. (]|$)')
SWIFT_SOURCE = re.compile(r'(?:App|Sources|Tests)/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.swift')
COMPILER_ERROR = re.compile(r'^(.+?\.swift):([1-9][0-9]{0,5}):([1-9][0-9]{0,5}):\s+error:\s+(.+)$')
MAX_DIAGNOSTICS = 12
UI_FAILURE_SOURCE_FILE = 'Tests/MirrorAdaptiveUITests/MirrorAdaptiveUITests.swift'
UI_ASSERTION_KINDS = frozenset({
    'XCTAssert', 'XCTAssertTrue', 'XCTAssertFalse', 'XCTAssertEqual', 'XCTAssertNotEqual',
    'XCTAssertGreaterThan', 'XCTAssertGreaterThanOrEqual', 'XCTAssertLessThan',
    'XCTAssertLessThanOrEqual', 'XCTAssertNil', 'XCTAssertNotNil', 'XCTAssertIdentical',
    'XCTAssertNotIdentical', 'XCTAssertThrowsError', 'XCTAssertNoThrow', 'XCTFail',
})
UI_LOOKUP_FAILURE_PREFIX = re.compile(r'^failed - Adaptive UI lookup failure: (missing|nonUnique)(?=$|[ \t])')
UI_CASE_EVENT = re.compile(
    r"Test Case '[-+]\[([^\s\]\r\n]+) (test[A-Za-z0-9_]+)\]' "
    r'(started|passed|failed|skipped)(?=[\s.]|$)')
UI_FAILURE_SOURCE = re.compile(
    r'^\s*(.+?\.swift):([0-9]{1,5})(?::([0-9]{1,5}))?:\s*error:\s*(.*)$')
UI_FAILURE_CASE = re.compile(r'^[-+]\[([^\s\]\r\n]+) (test[A-Za-z0-9_]+)\]\s*:\s*(.*)$')
PROGRESS_MARKER = 'UI adaptive progress: '
PROGRESS_DECLARATION = re.compile(r'^    func (' + '|'.join(re.escape(case) for case in CASES) + r')\(\) throws \{$')
PROGRESS_PROTOCOL = {
    'testMaximumTypeCaptureValidationAndRecovery': (
        ('started', 0), ('launchComplete', 0), ('captureOpenStarted', 0), ('captureOpened', 0),
        ('captureInputStarted', 0), ('captureInputComplete', 0), ('recordStarted', 1), ('recordComplete', 1),
        ('auditStarted', 1), ('auditComplete', 1), ('overlongInputStarted', 0), ('overlongInputComplete', 0),
        ('validationSubmitted', 0), ('validationVerified', 0), ('recordStarted', 2), ('recordComplete', 2),
        ('optionalInputsStarted', 0), ('optionalInputsVerified', 0), ('recoveryInputStarted', 0),
        ('recoveryInputComplete', 0), ('recoverySaved', 0), ('recordStarted', 3), ('recordComplete', 3),
        ('storedRowVerified', 0),
    ),
    'testMaximumTypeReviewAndWeekPicker': (
        ('started', 0), ('launchComplete', 0), ('captureStarted', 0), ('captureComplete', 0),
        ('reviewOpened', 0), ('reviewControlsVerified', 0), ('recordStarted', 1), ('recordComplete', 1),
        ('auditStarted', 1), ('auditComplete', 1), ('weekOpened', 0),
        *((phase, day) for day in range(5, 12) for phase in ('weekDayStarted', 'weekDayVerified')),
        ('recordStarted', 2), ('recordComplete', 2), ('auditStarted', 2), ('auditComplete', 2),
        ('weekSelected', 0), ('storedRowVerified', 0),
        ('newCaptureStarted', 0), ('newCaptureComplete', 0), ('reviewResumeVerified', 0), ('reviewResumeClosed', 0),
    ),
    'testMaximumTypeSearchDetailCompletionAndUndo': (
        ('started', 0), ('launchComplete', 0), ('captureStarted', 0), ('captureComplete', 0),
        ('postponeStarted', 0), ('postponeComplete', 0), ('searchInputStarted', 0), ('searchInputComplete', 0),
        ('searchVerified', 0), ('recordStarted', 1), ('recordComplete', 1), ('auditStarted', 1),
        ('auditComplete', 1), ('detailOpenStarted', 0), ('detailVerified', 0),
        ('recordStarted', 2), ('recordComplete', 2), ('auditStarted', 2), ('auditComplete', 2),
        ('completionStarted', 0), ('completionVerified', 0), ('recordStarted', 3), ('recordComplete', 3),
        ('undoStarted', 0), ('undoVerified', 0), ('recordStarted', 4), ('recordComplete', 4),
        ('auditStarted', 3), ('auditComplete', 3),
    ),
    'testMaximumTypePlannedCaptureKeepsUnassignedDefault': (
        ('started', 0), ('launchComplete', 0), ('defaultCaptureStarted', 0), ('defaultCaptureComplete', 0),
        ('plannedCaptureStarted', 0), ('plannedCaptureReady', 0), ('recordStarted', 1), ('recordComplete', 1),
        ('auditStarted', 1), ('auditComplete', 1), ('plannedCaptureSaved', 0), ('storedRowVerified', 0),
        ('recordStarted', 2), ('recordComplete', 2),
    ),
    'testNarrowMacWindowCaptureAndRequestedDetail': (
        ('started', 0), ('launchComplete', 0), ('windowResizeStarted', 0), ('windowResizeVerified', 0),
        ('recordStarted', 1), ('recordComplete', 1), ('auditStarted', 1), ('auditComplete', 1),
        ('captureStarted', 0), ('captureComplete', 0), ('detailOpenStarted', 0), ('detailVerified', 0),
        ('recordStarted', 2), ('recordComplete', 2), ('auditStarted', 2), ('auditComplete', 2),
    ),
}
CONFIGURATION_MEASUREMENT_MARKER = 'UI adaptive configuration measurement: '
RESIZE_MEASUREMENT_MARKER = 'UI adaptive resize measurement: '
MEASUREMENT_FONTS = frozenset(('xSmall', 'small', 'medium', 'large', 'xLarge', 'xxLarge', 'xxxLarge',
                              'accessibility1', 'accessibility2', 'accessibility3', 'accessibility4', 'accessibility5'))
MEASUREMENT_WAIT_RESULTS = frozenset(('completed', 'timedOut', 'incorrectOrder', 'invertedFulfillment', 'interrupted'))


class AdaptiveError(Exception):
    pass


def require(condition, code='invalidAdaptiveEvidence'):
    if not condition:
        raise AdaptiveError(code)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_regular(path, limit):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= limit, 'invalidFileBounds')
        with os.fdopen(descriptor, 'rb') as stream:
            descriptor = None
            data = stream.read(limit + 1)
        require(len(data) == info.st_size and len(data) <= limit, 'invalidFileBounds')
        return data
    finally:
        if descriptor is not None:
            os.close(descriptor)


def strict_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'duplicateJSONKey')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique,
                      parse_constant=lambda _: (_ for _ in ()).throw(AdaptiveError('invalidJSONNumber')))


def read_json(path):
    return strict_json(read_regular(path, MAX_JSON))


def required_cases(platform):
    require(platform in ('iphone', 'ipad', 'macos'), 'invalidMatrix')
    return tuple(case for case in CASES if case != NARROW or platform == 'macos')


def identity(platform, appearance):
    require(platform in ('iphone', 'ipad', 'macos') and appearance in ('system', 'dark'), 'invalidMatrix')
    values = {key: os.environ.get(variable, '') for key, variable in (
        ('commitSHA', 'GITHUB_SHA'), ('buildNumber', 'GITHUB_RUN_NUMBER'),
        ('runID', 'GITHUB_RUN_ID'), ('runAttempt', 'GITHUB_RUN_ATTEMPT'))}
    require(re.fullmatch(r'[0-9a-f]{40}', values['commitSHA']) is not None, 'invalidRunIdentity')
    require(all(re.fullmatch(r'[1-9][0-9]{0,19}', values[key]) for key in
                ('buildNumber', 'runID', 'runAttempt')), 'invalidRunIdentity')
    return {**values, 'platform': platform, 'appearance': appearance}


def configuration(expected, case):
    return {'dynamicType': 'accessibility5', 'appearance': expected['appearance'],
            'platform': expected['platform'], 'viewport': 'narrow' if case == NARROW else 'standard'}


def checkout_matches(expected):
    require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, stderr=subprocess.DEVNULL,
                                    text=True).strip() == expected['commitSHA'], 'checkoutSHAMismatch')
    require(subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--'], cwd=ROOT,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0,
            'modifiedCheckout')
    require(not subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '--',
                                        'App', 'Sources', 'Extensions', 'Tests'], cwd=ROOT,
                                       stderr=subprocess.DEVNULL), 'untrackedAppSource')


def safe_directory(directory):
    require(not directory.is_symlink(), 'unsafeDirectory')
    for parent in directory.parents:
        require(not parent.is_symlink(), 'unsafeDirectory')
    require(directory.resolve().is_relative_to((ROOT / '.build/ci-adaptive-ui').resolve()), 'unsafeDirectory')


def runtime_and_devices():
    version = read_json(ROOT / 'development-baseline.json')['observedToolchain']['iOSSimulatorRuntime']
    runtimes = strict_json(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))
    matches = [value for value in runtimes['runtimes'] if value.get('version') == version
               and value.get('isAvailable') is True
               and value.get('identifier', '').startswith('com.apple.CoreSimulator.SimRuntime.iOS-')]
    require(len(matches) == 1, 'missingRequiredRuntime')
    devices = strict_json(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
    return devices['devices'].get(matches[0]['identifier'], [])


def base_context(expected):
    mac = expected['platform'] == 'macos'
    return {**expected, 'scheme': 'MirrorMacAdaptiveUI' if mac else 'MirrorIOSAdaptiveUI',
            'bundle': 'MirrorMacAdaptiveUITests' if mac else 'MirrorIOSAdaptiveUITests',
            'class': CLASS, 'sdk': 'macosx' if mac else 'iphonesimulator'}


def prepare(directory, expected):
    safe_directory(directory)
    checkout_matches(expected)
    require(not directory.exists(), 'staleAdaptiveDirectory')
    context = base_context(expected)
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
    write_json(directory / 'context.json', {**context, 'destination': destination}, exclusive=True)


def context_for(directory, expected):
    safe_directory(directory)
    context = read_json(directory / 'context.json')
    require(isinstance(context, dict) and set(context) == set(base_context(expected)) | {'destination'}
            and all(context[key] == value for key, value in base_context(expected).items()), 'contextMismatch')
    destination = context['destination']
    require(isinstance(destination, str) and
            (destination == 'platform=macOS' if expected['platform'] == 'macos' else
             re.fullmatch(r'platform=iOS Simulator,id=[0-9A-Fa-f-]{36}', destination) is not None), 'contextMismatch')
    checkout_matches(expected)
    return context


def source_location(raw_path, line, column, source_root=ROOT):
    """현재 checkout 안의 실제 Swift 위치만 반환한다. 원본 경로를 출력하지 않는다."""
    if not isinstance(raw_path, str) or type(line) is not int or not 1 <= line <= 100_000:
        return None
    if type(column) is not int or not 1 <= column <= 100_000:
        return None
    prefix = str(source_root) + '/'
    relative = raw_path[len(prefix):] if raw_path.startswith(prefix) else raw_path
    if SWIFT_SOURCE.fullmatch(relative) is None:
        return None
    path = source_root / relative
    try:
        if any(candidate.is_symlink() for candidate in (path, *path.parents)):
            return None
        lines = read_regular(path, MAX_JSON).decode('utf-8').splitlines()
        if line == len(lines) + 1:
            return {'file': relative, 'line': line, 'column': column} if column == 1 else None
        if line > len(lines) or column > len(lines[line - 1].encode('utf-8')) + 1:
            return None
    except (OSError, UnicodeError, AdaptiveError):
        return None
    return {'file': relative, 'line': line, 'column': column}


def compiler_kind(message):
    if re.fullmatch(r"call can throw,? but (?:it is |is )?not marked with 'try'(?: and the error is not handled)?", message):
        return 'missingTry'
    if re.fullmatch(r"(?:variable|constant) '[^'\r\n]+' used before being initialized", message) or re.fullmatch(
            r"'?self'? used before all stored properties are initialized", message):
        return 'usedBeforeInitialization'
    if re.fullmatch(r"immutable value '[^'\r\n]+' may only be initialized once", message):
        return 'immutableInitializedTwice'
    return 'unknownCompilerError'


def compiler_diagnostics(log, source_root=ROOT):
    require(isinstance(log, str) and len(log.encode('utf-8')) <= MAX_LOG, 'invalidLogBounds')
    reports, seen = [], set()
    for text in log.splitlines():
        match = COMPILER_ERROR.fullmatch(text)
        if match is None:
            continue
        location = source_location(match[1], int(match[2]), int(match[3]), source_root)
        if location is None:
            continue
        kind = compiler_kind(match[4])
        key = (location['file'], location['line'], location['column'], kind)
        if key in seen:
            continue
        seen.add(key)
        reports.append({**location, 'kind': kind})
        if len(reports) == MAX_DIAGNOSTICS:
            break
    return reports


def diagnostics(directory, expected):
    context_for(directory, expected)
    log = read_regular(directory / 'build.log', MAX_LOG).decode('utf-8', errors='strict')
    reports = compiler_diagnostics(log)
    print('::notice::Adaptive UI compiler diagnostics: ' + json.dumps(
        {**expected, 'status': 'accepted' if reports else 'noAcceptedCompilerDiagnostics', 'diagnostics': reports},
        sort_keys=True))


def xctest_failure_diagnostics(log, expected, source_root=ROOT):
    """유일한 실제 시작·실패 instance의 명시 소유 오류만 정제한다. 결과 판정은 하지 않는다."""
    require(isinstance(log, str) and len(log.encode('utf-8')) <= MAX_LOG, 'invalidLogBounds')
    source = source_location(UI_FAILURE_SOURCE_FILE, 1, 1, source_root)
    if source is None:
        return []
    try:
        source_lines = len(read_regular(source_root / UI_FAILURE_SOURCE_FILE, MAX_JSON).decode('utf-8').splitlines())
    except (OSError, UnicodeError, AdaptiveError):
        return []
    owner = base_context(expected)['bundle'] + '.' + CLASS
    cases = required_cases(expected['platform'])
    active, started, pending, reports, seen = None, set(), [], [], set()
    for text in log.splitlines():
        if re.search(r'\bTest\s+Case\b', text):
            events = list(UI_CASE_EVENT.finditer(text))
            if len(events) != 1 or text.count('Test Case ') != 1:
                return []
            event = events[0]
            case = event[2]
            if event[1] != owner or case not in cases:
                return []
            if event[3] == 'started':
                if active is not None or case in started:
                    return []
                active = case
                started.add(case)
                pending = []
            else:
                if active != case:
                    return []
                if event[3] == 'failed':
                    for report in pending:
                        key = tuple(sorted(report.items()))
                        if key not in seen and len(reports) < MAX_DIAGNOSTICS:
                            seen.add(key)
                            reports.append(report)
                active, pending = None, []
            continue
        if len(pending) >= MAX_DIAGNOSTICS or len(reports) >= MAX_DIAGNOSTICS:
            continue
        match = UI_FAILURE_SOURCE.fullmatch(text)
        if match is None or active is None:
            continue
        explicit = UI_FAILURE_CASE.fullmatch(match[4].strip())
        if explicit is None or explicit[1] != owner or explicit[2] != active:
            # 암묵적 active case fallback을 사용하지 않는다.
            continue
        line, column = int(match[2]), int(match[3]) if match[3] is not None else None
        if line > source_lines:
            continue
        location = source_location(match[1], line, 1 if column is None else column, source_root)
        if location is None or location['file'] != UI_FAILURE_SOURCE_FILE:
            continue
        payload = explicit[3]
        assertion = re.match(r'^(XCTAssert[A-Za-z]*)\s+failed(?=[:\s-]|$)', payload)
        kind = assertion[1] if assertion else 'XCTFail' if payload.startswith('failed -') else None
        report = {'scope': 'stdoutOnly', 'method': active, 'sourceFile': UI_FAILURE_SOURCE_FILE, 'line': line}
        if column is not None:
            report['column'] = column
        report.update({'assertionKind': kind} if kind in UI_ASSERTION_KINDS else {'failureKind': 'unclassified'})
        if kind == 'XCTFail':
            # 소유가 확인된 자체 실패 문구만 분류한다. 뒤쪽 AX·입력·SDK 원문은 전달하지 않는다.
            lookup_failure = UI_LOOKUP_FAILURE_PREFIX.match(payload)
            if lookup_failure is not None:
                report['lookupFailureReason'] = lookup_failure[1]
        if report not in pending and len(pending) < MAX_DIAGNOSTICS:
            pending.append(report)
    return [] if active is not None else reports


def test_diagnostics(directory, expected):
    context_for(directory, expected)
    log = read_regular(directory / 'test.log', MAX_LOG).decode('utf-8', errors='strict')
    reports = xctest_failure_diagnostics(log, expected)
    print('::notice::Adaptive UI XCTest failure diagnostics: ' + json.dumps(
        {**expected, 'scope': 'stdoutOnly',
         'status': 'accepted' if reports else 'noAcceptedXCTestFailureDiagnostics', 'diagnostics': reports},
        sort_keys=True))


def source_method_entries(source, platform):
    require(isinstance(source, str) and len(source.encode('utf-8')) <= MAX_JSON, 'invalidSourceBounds')
    if source.splitlines().count('final class MirrorAdaptiveUITests: XCTestCase {') != 1:
        return None
    entries = {}
    for line, text in enumerate(source.splitlines(), 1):
        declaration = PROGRESS_DECLARATION.fullmatch(text)
        if declaration is not None:
            if declaration[1] in entries or line > 100_000:
                return None
            entries[declaration[1]] = line
    cases = required_cases(platform)
    return {case: entries[case] for case in cases} if all(case in entries for case in cases) else None


def xctest_progress_diagnostics(log, expected, entries):
    """관측된 method·phase만 반환한다. 선언 위치는 실행·성공·실패의 증거가 아니다."""
    require(isinstance(log, str) and len(log.encode('utf-8')) <= MAX_LOG, 'invalidLogBounds')
    cases = required_cases(expected['platform'])
    require(isinstance(entries, dict) and set(entries) == set(cases)
            and all(type(line) is int and 1 <= line <= 100_000 for line in entries.values()), 'invalidSourceEntries')
    owner = base_context(expected)['bundle'] + '.' + CLASS
    active, started, sequence, observed = None, set(), 0, None
    for text in log.splitlines():
        if re.search(r'\bTest\s+Case\b', text):
            event = UI_CASE_EVENT.match(text)
            if event is None or text.count('Test Case ') != 1 or len(list(UI_CASE_EVENT.finditer(text))) != 1:
                return None
            case = event[2]
            if event[1] != owner or case not in cases:
                return None
            if event[3] == 'started':
                if active is not None or case in started:
                    return None
                active, sequence = case, 0
                started.add(case)
                observed = {'method': case, 'sourceFile': UI_FAILURE_SOURCE_FILE, 'entryLine': entries[case]}
            else:
                if active != case:
                    return None
                active, sequence = None, 0
            continue
        if not re.search(r'\bUI\s+adaptive\s+progress\b', text):
            continue
        if active is None or not text.startswith(PROGRESS_MARKER) or text.count(PROGRESS_MARKER) != 1:
            return None
        try:
            value = strict_json(text[len(PROGRESS_MARKER):])
        except (AdaptiveError, ValueError, TypeError, RecursionError):
            return None
        if not (isinstance(value, dict) and set(value) == {'method', 'phase', 'sequence', 'step'}
                and value['method'] == active + '()' and type(value['sequence']) is int
                and type(value['step']) is int and isinstance(value['phase'], str)
                and value['sequence'] == sequence + 1 and sequence < len(PROGRESS_PROTOCOL[active])
                and (value['phase'], value['step']) == PROGRESS_PROTOCOL[active][sequence]):
            return None
        sequence += 1
        observed = {'method': active, 'sourceFile': UI_FAILURE_SOURCE_FILE, 'entryLine': entries[active],
                    'phase': value['phase'], 'sequence': sequence, 'step': value['step']}
    return observed


def progress_diagnostics(directory, expected):
    report = {**expected, 'scope': 'stdoutOnly', 'semantics': 'reachedCodeBoundaryOnly'}
    try:
        context_for(directory, expected)
    except (AdaptiveError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        report['status'] = 'contextUnavailable'
    else:
        try:
            require(source_location(UI_FAILURE_SOURCE_FILE, 1, 1, ROOT) is not None, 'invalidSourceEntries')
            entries = source_method_entries(read_regular(ROOT / UI_FAILURE_SOURCE_FILE, MAX_JSON).decode('utf-8'),
                                            expected['platform'])
            require(entries is not None, 'invalidSourceEntries')
        except (AdaptiveError, OSError, UnicodeError):
            report['status'] = 'sourceUnavailable'
        else:
            try:
                log = read_regular(directory / 'test.log', MAX_LOG).decode('utf-8')
            except (AdaptiveError, OSError, UnicodeError):
                report['status'] = 'testLogUnavailable'
            else:
                observed = xctest_progress_diagnostics(log, expected, entries)
                report.update({'status': 'observed', 'progress': observed} if observed is not None
                              else {'status': 'noAcceptedProgressDiagnostics'})
    print('::notice::Adaptive UI progress diagnostics: ' + json.dumps(report, sort_keys=True))


CASE_DIAGNOSTIC_MARKER = 'UI adaptive case diagnostic: '
AUDIT_BOUNDARY_MARKER = 'UI adaptive audit boundary: '
CASE_DIAGNOSTIC_NAMES = {
    'testMaximumTypeCaptureValidationAndRecovery': 'captureValidation',
    'testMaximumTypeReviewAndWeekPicker': 'reviewWeek',
    'testMaximumTypeSearchDetailCompletionAndUndo': 'searchDetailUndo',
    'testMaximumTypePlannedCaptureKeepsUnassignedDefault': 'plannedCapture',
    'testNarrowMacWindowCaptureAndRequestedDetail': 'narrowMac',
}
CASE_SHARED_ELEMENTS = frozenset(('todayList', 'appliedDynamicType', 'nativeStatusBar',
                                 'captureOpen', 'captureTitle', 'captureSave', 'captureFeedback',
                                 'captureClose', 'keyboardContinue', 'selectAll'))
CASE_REQUESTED_ELEMENTS = {
    'captureValidation': frozenset(('captureMoreButton', 'captureMoreDisclosure', 'captureNote',
                                   'stateError', 'destinationLibrary', 'taskRow')),
    'reviewWeek': frozenset(('destinationLibrary', 'destinationToday', 'todayReview', 'reviewCard',
                            'reviewToday', 'reviewTomorrow', 'reviewNextWeek', 'reviewFinish',
                            'librarySearch', 'planDay', 'taskRow')),
    'searchDetailUndo': frozenset(('destinationLibrary', 'destinationToday', 'taskRow', 'taskPostpone',
                                  'planTomorrow', 'librarySearch', 'settingsButton', 'detailContentTitle',
                                  'detailPlan', 'taskComplete', 'taskUndo')),
    'plannedCapture': frozenset(('destinationLibrary', 'destinationToday', 'taskRow', 'captureMoreButton',
                                 'captureMoreDisclosure', 'capturePlanToday', 'capturePlanSummary')),
    'narrowMac': frozenset(('destinationLibrary', 'todayReview', 'settingsButton', 'taskRow',
                           'detailContentTitle', 'detailClose', 'detailPostponeTomorrow', 'taskComplete')),
}
CASE_DIAGNOSTIC_SIGNAL = re.compile(r'\bUI\s+adaptive\s+(?:case\s+diagnostic|audit\s+boundary)\b')


def case_requested_elements(case, platform):
    elements = CASE_SHARED_ELEMENTS | CASE_REQUESTED_ELEMENTS[CASE_DIAGNOSTIC_NAMES[case]]
    return elements - ({'nativeStatusBar', 'keyboardContinue', 'selectAll'} if platform == 'macos'
                       else {'captureMoreDisclosure'})


def xctest_case_diagnostics(log, expected, entries):
    """고정 case별 조회 요청과 audit 반환 경계만 보관한다. 결과·오류 원인을 추론하지 않는다."""
    if xctest_progress_diagnostics(log, expected, entries) is None:
        return None
    cases = required_cases(expected['platform'])
    owner = base_context(expected)['bundle'] + '.' + CLASS
    active, sequence, reports = None, 0, {}
    for text in log.splitlines():
        if re.search(r'\bTest\s+Case\b', text):
            if CASE_DIAGNOSTIC_SIGNAL.search(text) or re.search(r'\bUI\s+adaptive\s+(?:progress|(?:configuration|resize)\s+measurement)\b', text):
                return None
            event = UI_CASE_EVENT.match(text)
            if event is None or len(list(UI_CASE_EVENT.finditer(text))) != 1 or text.count('Test Case ') != 1:
                return None
            if event[1] != owner or event[2] not in cases:
                return None
            active, sequence = (event[2], 0) if event[3] == 'started' else (None, 0)
            continue
        progress_signal = re.search(r'\bUI\s+adaptive\s+progress\b', text)
        signal = CASE_DIAGNOSTIC_SIGNAL.search(text)
        if not progress_signal and not signal:
            continue
        if len(text.encode('utf-8')) > 2048 or active is None:
            return None
        if progress_signal:
            if signal or active not in reports:
                # 새 source의 entry가 없는 legacy log에 대한 새 진단은 내보내지 않는다.
                return None
            value = strict_json(text[len(PROGRESS_MARKER):])
            sequence += 1
            report = reports[active]
            if report['auditBoundaries'] and report['auditBoundaries'][-1]['outcome'] == 'threw':
                return None
            if value['phase'] == 'auditComplete':
                if not (report['auditBoundaries'] and report['auditBoundaries'][-1]
                        == {'auditSequence': value['step'], 'outcome': 'returned'}):
                    return None
            report['lastProgress'] = {key: value[key] for key in ('phase', 'sequence', 'step')}
            continue
        marker = CASE_DIAGNOSTIC_MARKER if text.startswith(CASE_DIAGNOSTIC_MARKER) else AUDIT_BOUNDARY_MARKER
        if not text.startswith(marker) or text.count(marker) != 1:
            return None
        try:
            value = strict_json(text[len(marker):])
        except (AdaptiveError, ValueError, TypeError, RecursionError):
            return None
        if not (isinstance(value, dict) and type(value.get('schemaVersion')) is int
                and value['schemaVersion'] == 1 and value.get('case') == CASE_DIAGNOSTIC_NAMES[active]):
            return None
        if marker == CASE_DIAGNOSTIC_MARKER:
            if (set(value) != {'schemaVersion', 'case', 'requestSequence', 'requestedElement'}
                    or type(value['requestSequence']) is not int or not 0 <= value['requestSequence'] <= 10_000):
                return None
            if value['requestSequence'] == 0:
                if active in reports or sequence != 0 or value['requestedElement'] is not None:
                    return None
                reports[active] = {'case': value['case'], 'method': active,
                                   'sourceFile': UI_FAILURE_SOURCE_FILE, 'entryLine': entries[active],
                                   'lastProgress': None, 'requestSequence': 0,
                                   'requestedElement': None, 'auditBoundaries': []}
            else:
                if active not in reports:
                    return None
                report = reports[active]
                if (sequence == 0 or value['requestSequence'] != report['requestSequence'] + 1
                        or not isinstance(value['requestedElement'], str)
                        or value['requestedElement'] not in case_requested_elements(active, expected['platform'])
                        or (report['auditBoundaries'] and report['auditBoundaries'][-1]['outcome'] == 'threw')):
                    return None
                report.update({key: value[key] for key in ('requestSequence', 'requestedElement')})
        else:
            if (set(value) != {'schemaVersion', 'case', 'auditSequence', 'outcome'}
                    or type(value['auditSequence']) is not int or not isinstance(value['outcome'], str)
                    or value['outcome'] not in ('returned', 'threw') or active not in reports):
                return None
            report = reports[active]
            last = report['lastProgress']
            audits = report['auditBoundaries']
            maximum = sum(phase == 'auditStarted' for phase, _ in PROGRESS_PROTOCOL[active])
            if not (last is not None and last['phase'] == 'auditStarted'
                    and value['auditSequence'] == last['step'] == len(audits) + 1
                    and len(audits) < maximum
                    and (not audits or audits[-1]['outcome'] == 'returned')):
                return None
            audits.append({key: value[key] for key in ('auditSequence', 'outcome')})
    if len(reports) > len(cases):
        return None
    return list(reports.values())


def case_progress_diagnostics(directory, expected):
    report = {**expected, 'schemaVersion': 1, 'scope': 'stdoutOnly',
              'semantics': 'reachedCodeBoundaryAndLookupRequestOnly', 'cases': []}
    try:
        context_for(directory, expected)
    except (AdaptiveError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        report['status'] = 'contextUnavailable'
    else:
        try:
            require(source_location(UI_FAILURE_SOURCE_FILE, 1, 1, ROOT) is not None, 'invalidSourceEntries')
            entries = source_method_entries(read_regular(ROOT / UI_FAILURE_SOURCE_FILE, MAX_JSON).decode('utf-8'),
                                            expected['platform'])
            require(entries is not None, 'invalidSourceEntries')
        except (AdaptiveError, OSError, UnicodeError):
            report['status'] = 'sourceUnavailable'
        else:
            try:
                log = read_regular(directory / 'test.log', MAX_LOG).decode('utf-8')
            except (AdaptiveError, OSError, UnicodeError):
                report['status'] = 'testLogUnavailable'
            else:
                observed = xctest_case_diagnostics(log, expected, entries)
                report.update({'status': 'observedCaseBoundariesOnly', 'cases': observed} if observed
                              else {'status': 'noAcceptedCaseDiagnostics'})
    print('::notice::Adaptive UI per-case diagnostics: ' + json.dumps(report, sort_keys=True))


def configuration_measurement_fields(value):
    keys = {'method', 'valueKind', 'castKind', 'castName', 'environmentKind', 'environmentName'}
    if not (isinstance(value, dict) and set(value) == keys
            and isinstance(value['valueKind'], str) and value['valueKind'] in ('nil', 'string', 'number', 'other')
            and isinstance(value['castKind'], str) and value['castKind'] in ('nil', 'empty', 'enum', 'otherString')
            and isinstance(value['environmentKind'], str) and value['environmentKind'] in ('enum', 'empty', 'unrecognized')):
        return None
    if (value['valueKind'] == 'string') != (value['castKind'] in ('empty', 'enum', 'otherString')):
        return None
    for kind_key, name_key in (('castKind', 'castName'), ('environmentKind', 'environmentName')):
        if value[kind_key] == 'enum':
            if not isinstance(value[name_key], str) or value[name_key] not in MEASUREMENT_FONTS:
                return None
        elif value[name_key] is not None:
            return None
    return {key: value[key] for key in ('valueKind', 'castKind', 'castName', 'environmentKind', 'environmentName')}


def measurement_frame(value, *, positive):
    if not isinstance(value, list) or len(value) != 4 or any(type(number) not in (int, float) for number in value):
        return False
    try:
        return all(math.isfinite(number) for number in value) and all(
            number > 0 if positive else number >= 0 for number in value[2:])
    except (OverflowError, ValueError):
        return False


def resize_measurement_fields(value):
    keys = {'method', 'beforeFrame', 'observedFrame', 'samples', 'waitResult', 'waitCompleted'}
    if not (isinstance(value, dict) and set(value) == keys and type(value['samples']) is int
            and 0 <= value['samples'] <= 10_000 and isinstance(value['waitResult'], str)
            and value['waitResult'] in MEASUREMENT_WAIT_RESULTS and type(value['waitCompleted']) is bool
            and value['waitCompleted'] == (value['waitResult'] == 'completed')
            and measurement_frame(value['beforeFrame'], positive=True)):
        return None
    if value['samples'] == 0:
        if value['observedFrame'] is not None:
            return None
    elif not measurement_frame(value['observedFrame'], positive=False):
        return None
    return {key: value[key] for key in ('beforeFrame', 'observedFrame', 'samples', 'waitResult', 'waitCompleted')}


def xctest_measurement_diagnostics(log, expected, entries):
    """실제 소유 instance에서 관측한 고정 범주·좌표만 정제한다. 결과·원인을 추론하지 않는다."""
    if xctest_progress_diagnostics(log, expected, entries) is None:
        return None
    active, seen, reports = None, set(), []
    markers = ((CONFIGURATION_MEASUREMENT_MARKER, 'configuration', configuration_measurement_fields),
               (RESIZE_MEASUREMENT_MARKER, 'resize', resize_measurement_fields))
    for text in log.splitlines():
        event = UI_CASE_EVENT.match(text)
        if event is not None:
            if re.search(r'\bUI\s+adaptive\s+(?:progress|(?:configuration|resize)\s+measurement)\b', text):
                return None
            active = event[2] if event[3] == 'started' else None
            continue
        if not re.search(r'\bUI\s+adaptive\s+(?:configuration|resize)\s+measurement\b', text):
            continue
        marker = next((item for item in markers if text.startswith(item[0])), None)
        if marker is None or active is None or text.count(marker[0]) != 1:
            return None
        prefix, kind, sanitize = marker
        try:
            value = strict_json(text[len(prefix):])
        except (AdaptiveError, ValueError, TypeError, RecursionError):
            return None
        if not isinstance(value, dict) or value.get('method') != active + '()' or (active, kind) in seen:
            return None
        if kind == 'resize' and (active != NARROW or expected['platform'] != 'macos'):
            return None
        fields = sanitize(value)
        if fields is None:
            return None
        seen.add((active, kind))
        reports.append({'kind': kind, 'method': active, 'sourceFile': UI_FAILURE_SOURCE_FILE,
                        'entryLine': entries[active], **fields})
    return reports


def measurement_diagnostics(directory, expected):
    report = {**expected, 'scope': 'stdoutOnly', 'semantics': 'observedMeasurementsOnly'}
    try:
        context_for(directory, expected)
    except (AdaptiveError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        report['status'] = 'contextUnavailable'
    else:
        try:
            require(source_location(UI_FAILURE_SOURCE_FILE, 1, 1, ROOT) is not None, 'invalidSourceEntries')
            entries = source_method_entries(read_regular(ROOT / UI_FAILURE_SOURCE_FILE, MAX_JSON).decode('utf-8'),
                                            expected['platform'])
            require(entries is not None, 'invalidSourceEntries')
        except (AdaptiveError, OSError, UnicodeError):
            report['status'] = 'sourceUnavailable'
        else:
            try:
                log = read_regular(directory / 'test.log', MAX_LOG).decode('utf-8')
            except (AdaptiveError, OSError, UnicodeError):
                report['status'] = 'testLogUnavailable'
            else:
                observed = xctest_measurement_diagnostics(log, expected, entries)
                report.update({'status': 'observed', 'measurements': observed} if observed
                              else {'status': 'noAcceptedMeasurementDiagnostics'})
    print('::notice::Adaptive UI measurement diagnostics: ' + json.dumps(report, sort_keys=True))


def file_record(path, products):
    resolved = path.resolve(strict=True)
    require(path.is_relative_to(products) and resolved.is_relative_to(products) and resolved.is_file(), 'invalidBuildProduct')
    return {'path': path.relative_to(products).as_posix(), 'resolvedPath': resolved.relative_to(products).as_posix(),
            'sha256': digest(read_regular(resolved, 512 * 1024 * 1024))}


def bundle_record(bundle, products, expected):
    require(bundle.resolve(strict=True).is_relative_to(products) and bundle.is_dir(), 'invalidBuildProduct')
    infos = [path for path in (bundle / 'Info.plist', bundle / 'Contents/Info.plist') if path.is_file()]
    require(len(infos) == 1, 'missingBuildInfo')
    info = plistlib.loads(read_regular(infos[0].resolve(strict=True), MAX_JSON))
    executable = info.get('CFBundleExecutable')
    require(isinstance(executable, str) and re.fullmatch(r'[A-Za-z0-9_.-]+', executable)
            and executable not in ('.', '..') and str(info.get('CFBundleVersion')) == expected['buildNumber'],
            'buildVersionMismatch')
    executables = [path for path in (bundle / executable, bundle / 'Contents/MacOS' / executable) if path.is_file()]
    require(len(executables) == 1, 'missingBuildExecutable')
    return {'path': bundle.relative_to(products).as_posix(), 'info': file_record(infos[0], products),
            'executable': file_record(executables[0], products)}


def build_state(directory, expected):
    context = context_for(directory, expected)
    products = directory / 'DerivedData/Build/Products'
    require(products.is_dir() and products.resolve(strict=True).is_relative_to(directory.resolve()), 'missingBuildProducts')
    runs = sorted(path for path in products.rglob('*.xctestrun') if path.is_file())
    bundles = sorted(path for path in products.rglob(context['bundle'] + '.xctest') if path.is_dir())
    require(0 < len(runs) <= 16 and 0 < len(bundles) <= 16, 'missingAdaptiveBuildProduct')
    product_configuration = 'Debug' if expected['platform'] == 'macos' else 'Debug-iphonesimulator'
    return {'formatVersion': 1, 'context': context, 'codeCoverage': False, 'codeSigningAllowed': False,
            'xctestruns': [file_record(path, products) for path in runs],
            'app': bundle_record(products / product_configuration / 'Mirror.app', products, expected),
            'testBundles': [bundle_record(path, products, expected) for path in bundles]}


def verify_receipt(directory, expected):
    receipt = read_json(directory / 'build-receipt.json')
    require(receipt == build_state(directory, expected), 'buildReceiptMismatch')
    return digest(read_regular(directory / 'build-receipt.json', MAX_JSON))


def boot(directory, expected):
    context = context_for(directory, expected)
    if expected['platform'] == 'macos':
        return
    udid = context['destination'].split('id=', 1)[1]
    matches = [device for device in runtime_and_devices() if device.get('udid') == udid]
    require(len(matches) == 1 and matches[0].get('state') in ('Booted', 'Shutdown'), 'simulatorContextMismatch')
    if matches[0]['state'] == 'Shutdown':
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True)


def validate_summary(summary, platform):
    count = len(required_cases(platform))
    require(isinstance(summary, dict) and all(type(summary.get(key)) is int and summary[key] == value
            for key, value in (('totalTestCount', count), ('passedTests', count), ('failedTests', 0), ('skippedTests', 0))),
            'adaptiveSuiteSummaryMismatch')


def validate_tree(tree, bundle, platform):
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
    required = [(bundle, case + '()', 'Passed') for case in required_cases(platform)]
    require(bundles == [('UI test bundle', bundle, 'Passed')] and len(cases) == len(required)
            and sorted(cases) == sorted(required), 'adaptiveSuiteTreeMismatch')


def validate_log(log, bundle, expected):
    require(isinstance(log, str) and len(log.encode('utf-8')) <= MAX_LOG, 'invalidLogBounds')
    active = None
    completed, configured = [], []
    owner = bundle + '.' + CLASS
    for line in log.splitlines():
        if 'Test Case ' in line:
            matches = list(CASE_EVENT.finditer(line))
            require(line.count('Test Case ') == 1 and len(matches) == 1, 'unsupportedCaseEvent')
            match = matches[0]
            require(match[2] == owner and match[3] in required_cases(expected['platform']), 'caseOwnerMismatch')
            case, state = match[3], match[4]
            if state == 'started':
                require(active is None and case not in completed, 'duplicateOrParallelCase')
                active = case
            else:
                require(state == 'passed' and active == case and case in configured, 'caseDidNotPass')
                completed.append(case)
                active = None
        if CONFIG_MARKER in line:
            require(line.count(CONFIG_MARKER) == 1, 'invalidAppliedConfiguration')
            value = strict_json(line.split(CONFIG_MARKER, 1)[1].strip())
            require(active is not None and active not in configured and isinstance(value, dict)
                    and value == configuration(expected, active)
                    and set(value) == set(configuration(expected, active)), 'invalidAppliedConfiguration')
            configured.append(active)
    required = required_cases(expected['platform'])
    require(active is None and len(completed) == len(required) and set(completed) == set(required)
            and len(configured) == len(required) and set(configured) == set(required), 'adaptiveSuiteCaseCountMismatch')


def guard(directory, expected):
    context = context_for(directory, expected)
    receipt_hash = verify_receipt(directory, expected)
    validate_summary(read_json(directory / 'summary.json'), expected['platform'])
    validate_tree(read_json(directory / 'tests.json'), context['bundle'], expected['platform'])
    validate_log(read_regular(directory / 'test.log', MAX_LOG).decode('utf-8', errors='strict'), context['bundle'], expected)
    return receipt_hash


def directory_files(root):
    require(root.is_dir() and not root.is_symlink(), 'unsafeExportDirectory')
    files = []
    for directory, children, names in os.walk(root, followlinks=False):
        require(len(Path(directory).relative_to(root).parts) <= 10, 'invalidExportBounds')
        require(all(not (Path(directory) / name).is_symlink() for name in children + names), 'unsafeExportDirectory')
        files.extend(Path(directory) / name for name in names)
        require(len(files) <= MAX_FILES, 'invalidExportBounds')
    return files


def attachment_name(value):
    require(isinstance(value, str) and len(value) <= 240, 'invalidAttachmentName')
    name = value[:-4] if value.endswith('.png') else value
    if SHOT_PATTERN.fullmatch(name):
        return name
    match = SDK_SHOT_PATTERN.fullmatch(name) if value.endswith('.png') else None
    require(match is not None, 'invalidAttachmentName')
    return match[1]


def export_entries(value, platform):
    if isinstance(value, list):
        records = value
    elif isinstance(value, dict) and set(value) == {'tests'} and isinstance(value['tests'], list):
        records = value['tests']
    elif isinstance(value, dict) and isinstance(value.get('attachments'), list):
        records = [value]
    else:
        raise AdaptiveError('unsupportedAttachmentExport')
    required = required_cases(platform)
    require(len(records) == len(required), 'adaptiveSuiteExportMismatch')
    expected_names = {case: {'mirror-adaptive-' + stage + '-' + str(index)
                            for index, stage in enumerate(CASES[case], 1)} for case in required}
    entries, actual_cases = [], []
    for record in records:
        require(isinstance(record, dict) and isinstance(record.get('attachments'), list)
                and len(record['attachments']) <= MAX_FILES, 'unsupportedAttachmentExport')
        case_entries = []
        for attachment in record['attachments']:
            require(isinstance(attachment, dict), 'unsupportedAttachmentExport')
            human = attachment.get('suggestedHumanReadableName', attachment.get('name'))
            if not isinstance(human, str) or not human.startswith('mirror-adaptive-'):
                continue
            name = attachment_name(human)
            if 'name' in attachment and 'suggestedHumanReadableName' in attachment:
                require(attachment['name'] in (name, name + '.png', human), 'attachmentAliasMismatch')
            basename = attachment.get('exportedFileName')
            require(isinstance(basename, str) and SAFE_PNG.fullmatch(basename), 'unsafeAttachmentPath')
            require(attachment.get('uniformTypeIdentifier') in (None, 'public.png'), 'invalidAttachmentType')
            case_entries.append((name, basename))
        names = {name for name, _ in case_entries}
        owners = [case for case, expected in expected_names.items() if names == expected]
        require(len(owners) == 1 and len(case_entries) == len(names), 'screenshotStageMismatch')
        case = owners[0]
        actual_cases.append(case)
        entries.extend((case, name, basename) for name, basename in case_entries)
    require(len(actual_cases) == len(required) and set(actual_cases) == set(required)
            and len({name for _, name, _ in entries}) == len(entries)
            and len({basename for _, _, basename in entries}) == len(entries), 'screenshotCountMismatch')
    return sorted(entries, key=lambda entry: (required.index(entry[0]), int(SHOT_PATTERN.fullmatch(entry[1])[2])))


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def clean_icc(payload):
    separator = payload.find(b'\0')
    require(1 <= separator <= 79 and payload[separator + 1:separator + 2] == b'\0', 'invalidICC')
    decoder = zlib.decompressobj()
    profile = decoder.decompress(payload[separator + 2:], 1024 * 1024 + 1)
    require(132 <= len(profile) <= 1024 * 1024 and decoder.eof and not decoder.unused_data
            and not decoder.unconsumed_tail and struct.unpack('>I', profile[:4])[0] == len(profile)
            and profile[36:40] == b'acsp', 'invalidICC')
    return payload


def clean_png(data):
    require(0 < len(data) <= MAX_PNG and data.startswith(SIGNATURE), 'invalidPNG')
    position, chunks, image_data = 8, [], []
    width = height = depth = color = None
    palette = transparency = False
    data_ended = ended = False
    color_chunks = set()
    while position < len(data):
        require(position + 12 <= len(data) and not ended, 'invalidPNG')
        length = struct.unpack('>I', data[position:position + 4])[0]
        require(length <= MAX_PNG and position + length + 12 <= len(data), 'invalidPNG')
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        crc = struct.unpack('>I', data[position + 8 + length:position + 12 + length])[0]
        require(re.fullmatch(b'[A-Za-z]{4}', kind) and kind[2:3].isupper()
                and zlib.crc32(kind + payload) & 0xffffffff == crc, 'invalidPNG')
        if width is None:
            require(kind == b'IHDR' and length == 13, 'invalidPNG')
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
            require(0 < width <= 16384 and 0 < height <= 16384 and width * height <= MAX_PIXELS
                    and color in depths and depth in depths[color] and compression == filtering == interlace == 0,
                    'unsupportedPNG')
        elif kind == b'IHDR':
            raise AdaptiveError('invalidPNG')
        if kind == b'PLTE':
            require(not palette and not image_data and not transparency and color in (2, 3, 6)
                    and 0 < length <= 768 and length % 3 == 0
                    and (color != 3 or length // 3 <= 2 ** depth), 'invalidPNG')
            palette = length // 3
        elif kind == b'tRNS':
            require(not transparency and not image_data and ((color == 0 and length == 2)
                    or (color == 2 and length == 6) or (color == 3 and palette and 0 < length <= palette)), 'invalidPNG')
            transparency = True
        elif kind == b'IDAT':
            require(not data_ended and (color != 3 or palette), 'invalidPNG')
            image_data.append(payload)
        elif kind == b'IEND':
            require(length == 0 and image_data, 'invalidPNG')
            ended = True
        elif kind in (b'sRGB', b'gAMA', b'cHRM', b'iCCP'):
            require(not image_data and not palette and kind not in color_chunks, 'invalidPNG')
            if kind == b'sRGB':
                require(length == 1 and payload[0] <= 3 and b'iCCP' not in color_chunks, 'unsupportedPNG')
            elif kind == b'gAMA':
                require(length == 4 and 0 < struct.unpack('>I', payload)[0] <= 1_000_000, 'unsupportedPNG')
            elif kind == b'cHRM':
                require(length == 32, 'unsupportedPNG')
                coordinates = struct.unpack('>8I', payload)
                require(all(0 < y <= 100_000 and x <= 100_000 and x + y <= 100_000
                            for x, y in zip(coordinates[::2], coordinates[1::2])), 'unsupportedPNG')
            else:
                require(b'sRGB' not in color_chunks, 'unsupportedPNG')
                clean_icc(payload)
            color_chunks.add(kind)
        elif kind not in (b'IHDR', b'PLTE', b'tRNS'):
            require(kind[:1].islower() and kind not in (b'acTL', b'fcTL', b'fdAT'), 'unsupportedPNG')
        if image_data and kind != b'IDAT':
            data_ended = True
        if kind in (b'IHDR', b'PLTE', b'tRNS', b'IDAT', b'IEND', b'sRGB', b'gAMA', b'cHRM', b'iCCP'):
            chunks.append(data[position:position + length + 12])
        position += length + 12
    require(ended and width is not None, 'invalidPNG')
    row_size = (width * {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color] * depth + 7) // 8 + 1
    expected_size = row_size * height
    require(expected_size <= MAX_RAW, 'unsupportedPNG')
    decoder = zlib.decompressobj()
    raw = decoder.decompress(b''.join(image_data), expected_size + 1)
    require(len(raw) == expected_size and decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail
            and all(raw[index] <= 4 for index in range(0, len(raw), row_size)), 'invalidPNG')
    return SIGNATURE + b''.join(chunks), width, height


def write_json(path, value, *, exclusive=False):
    with path.open('x' if exclusive else 'w', encoding='utf-8') as stream:
        os.chmod(path, 0o600)
        stream.write(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n')


def validate_outcome(outcome, expected):
    base = set(expected) | {'phase', 'status', 'commandExitCode', 'xcodebuildExitCode'}
    require(isinstance(outcome, dict) and all(outcome.get(key) == value for key, value in expected.items()),
            'outcomeIdentityMismatch')
    status = outcome.get('status')
    require(status in ('buildComplete', 'passed', 'failed') and outcome.get('phase') in ('build', 'test'), 'invalidOutcome')
    native = outcome.get('xcodebuildExitCode')
    require(native is None or type(native) is int and 0 <= native <= 255, 'invalidOutcome')
    command = outcome.get('commandExitCode')
    require(type(command) is int and 0 <= command <= 255, 'invalidOutcome')
    if status == 'failed':
        require(set(outcome) == base and command > 0, 'invalidOutcome')
    elif status == 'buildComplete':
        require(set(outcome) == base and outcome['phase'] == 'build' and command == native == 0, 'invalidOutcome')
    else:
        require(set(outcome) == base | {'totalTestCount', 'passedTests', 'failedTests', 'skippedTests', 'screenshotCount'}
                and outcome['phase'] == 'test' and command == native == 0, 'invalidOutcome')
        validate_summary(outcome, expected['platform'])
        require(type(outcome['screenshotCount']) is int and outcome['screenshotCount'] ==
                sum(len(CASES[case]) for case in required_cases(expected['platform'])), 'invalidOutcome')


def evidence(directory, expected):
    receipt_hash = guard(directory, expected)
    files = directory_files(directory / 'attachments')
    manifests = [path for path in files if path.name == 'manifest.json']
    require(len(manifests) == 1, 'missingExportManifest')
    entries = export_entries(read_json(manifests[0]), expected['platform'])
    output = directory / 'review'
    require(not output.exists() and not output.is_symlink(), 'staleReviewDirectory')
    by_name = {}
    for path in files:
        by_name.setdefault(path.name, []).append(path)
    images, screenshots = {}, []
    for case, name, basename in entries:
        candidates = by_name.get(basename, [])
        require(len(candidates) == 1, 'missingScreenshot')
        original = read_regular(candidates[0], MAX_PNG)
        data, width, height = clean_png(original)
        match = SHOT_PATTERN.fullmatch(name)
        filename = 'screenshots/' + name + '.png'
        images[filename] = data
        screenshots.append({'case': case, 'stage': match[1], 'sequence': int(match[2]), 'file': filename,
                            'sha256': digest(data), 'exportSHA256': digest(original), 'bytes': len(data),
                            'width': width, 'height': height})
    require(sum(map(len, images.values())) <= 512 * 1024 * 1024, 'invalidEvidenceBounds')
    count = len(required_cases(expected['platform']))
    manifest = {**expected, 'formatVersion': 1, 'kind': 'mirror-adaptive-ui-evidence',
                'appliedConfigurations': {case: configuration(expected, case) for case in required_cases(expected['platform'])},
                'screenshotScope': 'XCUIApplication',
                'buildReceiptSHA256': receipt_hash,
                'testSourceSHA256': digest(read_regular(ROOT / 'Tests/MirrorAdaptiveUITests/MirrorAdaptiveUITests.swift', MAX_JSON)),
                'actualBundleCount': 1, 'actualClass': CLASS, 'totalTestCount': count,
                'passedTests': count, 'failedTests': 0, 'skippedTests': 0, 'screenshots': screenshots}
    temporary = Path(tempfile.mkdtemp(prefix='.adaptive-review-', dir=directory))
    try:
        (temporary / 'screenshots').mkdir()
        for filename, data in images.items():
            (temporary / filename).write_bytes(data)
        write_json(temporary / 'manifest.json', manifest, exclusive=True)
        summary = ('# 적응형 UI 전체 사례 결과\n\n' + expected['platform'] + ' · ' + expected['appearance'] +
                   '\n\n실제 사례 ' + str(count) + '개 통과, 실패 0개, skip 0개.\n' +
                   '적용 구성: accessibility5 · standard ' + str(count - (expected['platform'] == 'macos')) +
                   '개 · narrow ' + str(int(expected['platform'] == 'macos')) + '개\n' +
                   '앱 PNG ' + str(len(screenshots)) + '장. 시각 수용·VoiceOver·실기기 검증은 별도입니다.\n')
        (temporary / 'summary.md').write_text(summary, encoding='utf-8')
        checksums = {**{filename: digest(data) for filename, data in images.items()},
                     'manifest.json': digest(read_regular(temporary / 'manifest.json', MAX_JSON)),
                     'summary.md': digest(read_regular(temporary / 'summary.md', MAX_JSON))}
        (temporary / 'SHA256SUMS').write_text(''.join(value + '  ' + filename + '\n'
                    for filename, value in sorted(checksums.items())), encoding='utf-8')
        temporary.rename(output)
    finally:
        if temporary.exists():
            import shutil
            shutil.rmtree(temporary)
    write_json(directory / 'safe-outcome.json', {**expected, 'phase': 'test', 'status': 'passed',
               'commandExitCode': 0, 'xcodebuildExitCode': 0, 'totalTestCount': count,
               'passedTests': count, 'failedTests': 0, 'skippedTests': 0, 'screenshotCount': len(screenshots)})


def failure_recorded_screenshots(log, expected, entries):
    # 부분 실행도 원래 고정 phase protocol과 실제 bundle/method 소유를 먼저 검증한다.
    require(xctest_progress_diagnostics(log, expected, entries) is not None, 'invalidFailureScreenshotProgress')
    active, configured, selected = None, set(), {}
    for line in log.splitlines():
        event = UI_CASE_EVENT.match(line)
        if event is not None:
            active = event[2] if event[3] == 'started' else None
            continue
        if CONFIG_MARKER in line:
            require(active is not None and line.startswith(CONFIG_MARKER)
                    and line.count(CONFIG_MARKER) == 1 and active not in configured,
                    'invalidAppliedConfiguration')
            value = strict_json(line[len(CONFIG_MARKER):])
            require(isinstance(value, dict) and value == configuration(expected, active)
                    and set(value) == set(configuration(expected, active)), 'invalidAppliedConfiguration')
            configured.add(active)
        if line.startswith(PROGRESS_MARKER):
            value = strict_json(line[len(PROGRESS_MARKER):])
            if value['phase'] == 'recordComplete':
                require(active in configured and 1 <= value['step'] <= len(CASES[active]),
                        'invalidFailureScreenshotProgress')
                name = 'mirror-adaptive-' + CASES[active][value['step'] - 1] + '-' + str(value['step'])
                require(name not in selected, 'duplicateFailureScreenshot')
                selected[name] = active
    require(selected, 'noRecordedFailureScreenshots')
    return selected


def failure_evidence_context(directory, expected):
    receipt_hash = verify_receipt(directory, expected)
    outcome = read_json(directory / 'safe-outcome.json')
    validate_outcome(outcome, expected)
    require(outcome['status'] == 'failed' and outcome['phase'] == 'test'
            and type(outcome['xcodebuildExitCode']) is int and 1 <= outcome['xcodebuildExitCode'] <= 255,
            'notNativeUIFailure')
    require(source_location(UI_FAILURE_SOURCE_FILE, 1, 1, ROOT) is not None, 'invalidSourceEntries')
    entries = source_method_entries(read_regular(ROOT / UI_FAILURE_SOURCE_FILE, MAX_JSON).decode('utf-8'),
                                    expected['platform'])
    require(entries is not None, 'invalidSourceEntries')
    log = read_regular(directory / 'test.log', MAX_LOG).decode('utf-8')
    return receipt_hash, failure_recorded_screenshots(log, expected, entries)


def failure_export_entries(value, selected):
    # 성공 exporter에서 이미 사용하는 명시 test-record/attachment schema만 허용한다.
    if isinstance(value, list):
        records = value
    elif isinstance(value, dict) and set(value) == {'tests'} and isinstance(value['tests'], list):
        records = value['tests']
    elif isinstance(value, dict) and isinstance(value.get('attachments'), list):
        records = [value]
    else:
        raise AdaptiveError('unsupportedAttachmentExport')
    require(0 < len(records) <= MAX_FILES, 'invalidExportBounds')
    entries = []
    for record in records:
        require(isinstance(record, dict) and isinstance(record.get('attachments'), list)
                and len(record['attachments']) <= MAX_FILES, 'unsupportedAttachmentExport')
        for attachment in record['attachments']:
            require(isinstance(attachment, dict), 'unsupportedAttachmentExport')
            human = attachment.get('suggestedHumanReadableName', attachment.get('name'))
            if not isinstance(human, str) or not human.startswith('mirror-adaptive-'):
                continue
            name = attachment_name(human)
            if name not in selected:
                continue
            if 'name' in attachment and 'suggestedHumanReadableName' in attachment:
                require(attachment['name'] in (name, name + '.png', human), 'attachmentAliasMismatch')
            basename = attachment.get('exportedFileName')
            require(isinstance(basename, str) and SAFE_PNG.fullmatch(basename), 'unsafeAttachmentPath')
            require(attachment.get('uniformTypeIdentifier') in (None, 'public.png'), 'invalidAttachmentType')
            entries.append((selected[name], name, basename))
            require(len(entries) <= sum(map(len, CASES.values())), 'invalidEvidenceBounds')
    require({name for _, name, _ in entries} == set(selected)
            and len(entries) == len(selected) and len({basename for _, _, basename in entries}) == len(entries),
            'failureScreenshotSetMismatch')
    return sorted(entries, key=lambda item: (tuple(CASES).index(item[0]), int(SHOT_PATTERN.fullmatch(item[1])[2])))


def failure_evidence(directory, expected):
    receipt_hash, selected = failure_evidence_context(directory, expected)
    files = directory_files(directory / 'failure-attachments')
    manifests = [path for path in files if path.name == 'manifest.json']
    require(len(manifests) == 1, 'missingExportManifest')
    entries = failure_export_entries(read_json(manifests[0]), selected)
    output = directory / 'failure-review'
    require(not output.exists() and not output.is_symlink(), 'staleReviewDirectory')
    by_name = {}
    for path in files:
        by_name.setdefault(path.name, []).append(path)
    images, screenshots = {}, []
    for case, name, basename in entries:
        candidates = by_name.get(basename, [])
        require(len(candidates) == 1, 'missingScreenshot')
        original = read_regular(candidates[0], MAX_PNG)
        cleaned, width, height = clean_png(original)
        match = SHOT_PATTERN.fullmatch(name)
        filename = 'screenshots/' + name + '.png'
        images[filename] = cleaned
        screenshots.append({'case': case, 'stage': match[1], 'sequence': int(match[2]), 'file': filename,
                            'sha256': digest(cleaned), 'exportSHA256': digest(original), 'bytes': len(cleaned),
                            'width': width, 'height': height})
    require(sum(map(len, images.values())) <= 512 * 1024 * 1024, 'invalidEvidenceBounds')
    manifest = {**expected, 'formatVersion': 1, 'kind': 'adaptive-failure-diagnostic',
                'scope': 'recordedFixtureAppImagesOnly', 'semantics': 'diagnosticOnlyNotAcceptanceOrAuditCause',
                'buildReceiptSHA256': receipt_hash, 'screenshots': screenshots}
    temporary = Path(tempfile.mkdtemp(prefix='.failure-review-', dir=directory))
    try:
        os.chmod(temporary, 0o700)
        (temporary / 'screenshots').mkdir(mode=0o700)
        for filename, data in images.items():
            path = temporary / filename
            with path.open('xb') as stream:
                os.chmod(path, 0o600)
                stream.write(data)
        write_json(temporary / 'manifest.json', manifest, exclusive=True)
        checksums = {**{name: digest(data) for name, data in images.items()},
                     'manifest.json': digest(read_regular(temporary / 'manifest.json', MAX_JSON))}
        sums = temporary / 'SHA256SUMS'
        with sums.open('x', encoding='ascii') as stream:
            os.chmod(sums, 0o600)
            stream.write(''.join(value + '  ' + name + '\n' for name, value in sorted(checksums.items())))
        temporary.rename(output)
    finally:
        if temporary.exists():
            import shutil
            shutil.rmtree(temporary)
    print('::notice::Adaptive UI failure screenshot diagnostics: ' + json.dumps(
        {**expected, 'status': 'diagnosticOnly', 'screenshotCount': len(screenshots)}, sort_keys=True))


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        raise AdaptiveError('invalidArguments')


def main():
    require(os.environ.get('GITHUB_ACTIONS') == 'true', 'adaptiveRemoteOnly')
    parser = SafeParser()
    parser.add_argument('command', choices=('prepare', 'context', 'receipt-record', 'receipt-verify', 'boot', 'guard', 'evidence', 'outcome-verify', 'diagnostics', 'test-diagnostics', 'progress', 'measurements', 'failure', 'failure-evidence-prepare', 'failure-evidence'))
    parser.add_argument('--directory', required=True)
    parser.add_argument('--platform', required=True)
    parser.add_argument('--appearance', required=True)
    parser.add_argument('--phase', choices=('build', 'test'))
    parser.add_argument('--exit-code', type=int)
    parser.add_argument('--native-exit-code', type=int, default=-1)
    args = parser.parse_args()
    expected = identity(args.platform, args.appearance)
    directory = Path(args.directory)
    require(directory == Path('.build/ci-adaptive-ui') / (args.platform + '-' + args.appearance), 'unsafeDirectory')
    directory = ROOT / directory
    if args.command == 'prepare':
        prepare(directory, expected)
    elif args.command == 'context':
        context = context_for(directory, expected)
        print('\t'.join(context[key] for key in ('scheme', 'sdk', 'destination')))
    elif args.command == 'receipt-record':
        write_json(directory / 'build-receipt.json', build_state(directory, expected), exclusive=True)
        write_json(directory / 'safe-outcome.json', {**expected, 'phase': 'build', 'status': 'buildComplete',
                   'commandExitCode': 0, 'xcodebuildExitCode': 0})
    elif args.command == 'receipt-verify':
        verify_receipt(directory, expected)
    elif args.command == 'boot':
        boot(directory, expected)
    elif args.command == 'guard':
        guard(directory, expected)
    elif args.command == 'evidence':
        evidence(directory, expected)
    elif args.command == 'failure-evidence-prepare':
        failure_evidence_context(directory, expected)
    elif args.command == 'failure-evidence':
        failure_evidence(directory, expected)
    elif args.command == 'outcome-verify':
        safe_directory(directory)
        validate_outcome(read_json(directory / 'safe-outcome.json'), expected)
    elif args.command == 'diagnostics':
        require(1 <= args.native_exit_code <= 255, 'invalidArguments')
        diagnostics(directory, expected)
    elif args.command == 'test-diagnostics':
        require(1 <= args.native_exit_code <= 255, 'invalidArguments')
        test_diagnostics(directory, expected)
    elif args.command == 'progress':
        progress_diagnostics(directory, expected)
        case_progress_diagnostics(directory, expected)
    elif args.command == 'measurements':
        measurement_diagnostics(directory, expected)
    else:
        require(args.phase in ('build', 'test') and type(args.exit_code) is int and 1 <= args.exit_code <= 255
                and -1 <= args.native_exit_code <= 255, 'invalidArguments')
        safe_directory(directory)
        directory.mkdir(parents=True, exist_ok=True)
        write_json(directory / 'safe-outcome.json', {**expected, 'phase': args.phase, 'status': 'failed',
                   'commandExitCode': args.exit_code,
                   'xcodebuildExitCode': None if args.native_exit_code == -1 else args.native_exit_code})


if __name__ == '__main__':
    try:
        main()
    except AdaptiveError as error:
        print('::error::' + str(error), file=sys.stderr)
        raise SystemExit(1) from None
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError, struct.error,
            plistlib.InvalidFileException, subprocess.SubprocessError, zlib.error):
        print('::error::adaptiveProcessingFailed', file=sys.stderr)
        raise SystemExit(1) from None
