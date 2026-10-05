#!/usr/bin/env python3
"""Actions 전용: 같은 unsigned build의 한 iPad 사례를 비교한다. 수용 gate가 아니다."""
import importlib.util
from itertools import islice
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('adaptive', ROOT / 'scripts/ci-adaptive-ui-results.py')
A = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(A)
BUILD = ROOT / '.build/ci-adaptive-ui/ipad-system'
DIRECTORY = ROOT / '.build/ci-dynamic-type-diagnostics'
CASE = 'testMaximumTypeCaptureValidationAndRecovery'
OWNER = 'MirrorIOSAdaptiveUITests.MirrorAdaptiveUITests'
MODES = ('pinned', 'system')
CATEGORIES = ('extra-small', 'small', 'medium', 'large', 'extra-large', 'extra-extra-large',
              'extra-extra-extra-large', 'accessibility-medium', 'accessibility-large',
              'accessibility-extra-large', 'accessibility-extra-extra-large',
              'accessibility-extra-extra-extra-large')
GROUPED_CATEGORY_DECLARATIONS = (
    'Standard sizes: ' + ', '.join(CATEGORIES[:7]) + '.',
    'Extended range sizes: ' + ', '.join(CATEGORIES[7:]) + '.',
    'Other values: unknown, unsupported.',
)
CATEGORY_TOKEN = re.compile(r'(?<![\w-])(?:' + '|'.join(map(re.escape, CATEGORIES)) + r')(?![\w-])')
PROBE = 'UI dynamic type fixture: '
AUDIT = 'UI dynamic type audit: '
AUDIT_ISSUE = 'UI adaptive audit issue: '
AUDIT_GEOMETRY = 'UI adaptive audit geometry: '
# MirrorAdaptiveUITests.recordAuditIssue의 고정 enum. 알 수 없는 SDK 설명·식별자는 읽지 않는다.
AUDIT_IDENTIFIERS = frozenset(('none', 'other', 'appliedDynamicType',
    'captureDynamicType', 'reviewDynamicType', 'planDynamicType', 'detailDynamicType',
    'captureOpen', 'captureClose', 'captureTitle', 'captureNote', 'captureURL', 'captureMore', 'captureSave', 'captureFeedback',
    'capturePlanChoices', 'capturePlanSummary', 'capturePlanToday', 'capturePlanTomorrow', 'capturePlanOther',
    'todayList', 'todayReview', 'destinationToday', 'destinationCalendar', 'destinationLibrary', 'settingsButton',
    'librarySearch', 'libraryList', 'libraryBatchFooter', 'libraryBatchPlan', 'reviewCard', 'reviewDetail', 'reviewToday',
    'reviewTomorrow', 'reviewThisWeek', 'reviewNextWeek', 'reviewOther', 'reviewFinish', 'planToday', 'planTomorrow',
    'planCancel', 'detailClose', 'detailContentTitle', 'detailTitle', 'detailPlan', 'detailHistory', 'detailPostponeTomorrow',
    'taskComplete', 'taskUndo', 'stateError', 'stateFeedback'))
AUDIT_ELEMENT_TYPES = frozenset(('none', 'other', 'application', 'window', 'sheet', 'button', 'textField', 'textView',
                                'staticText', 'scrollView', 'table', 'collectionView', 'image', 'disclosureTriangle'))
CHECKPOINT = '::notice::Dynamic Type checkpoint: '
CHECKPOINTS = frozenset(('checkoutStarted', 'checkoutVerified', 'contextStarted', 'contextVerified',
    'bootStatusStarted', 'bootStatusReturned', 'restoreJournalReadStarted', 'restoreJournalVerified',
    'restoreSetStarted', 'restoreSetCompleted', 'restoreReadbackStarted', 'restoreReadbackVerified',
    'restoreNotRequired'))
IDENTITY_FIELDS = ('platform', 'appearance', 'commitSHA', 'buildNumber', 'runID', 'runAttempt')


class Failure(A.AdaptiveError):
    def __init__(self, code):
        self.code = code  # 호출 지점의 고정 코드만 보존하며 SDK 예외 문자열은 사용하지 않는다.


def require(value, code):
    if not value:
        raise Failure(code)


def checkpoint(report, phase):
    require(phase in CHECKPOINTS, 'invalidCheckpoint')
    report['phase'] = phase
    # CLI가 검증한 고정 실행 정보만 내보낸다. 시작 단계는 소유 검증 완료나 성공 판정이 아니다.
    fields = (*IDENTITY_FIELDS, 'action', 'mode')
    if all(key in report for key in fields):
        value = {key: report[key] for key in fields}
        value.update(schemaVersion=1, scope='diagnosticOnly', phase=phase)
        print(CHECKPOINT + json.dumps(value, sort_keys=True), flush=True)


def verify_no_category_change(expected):
    require(not (DIRECTORY / 'public').is_symlink(), 'unsafeSetupSummary')
    setup = A.read_json(DIRECTORY / 'public/setup.json')
    fields = {*IDENTITY_FIELDS, 'schemaVersion', 'scope', 'action', 'mode', 'status', 'phase',
              'simulatorInitialState', 'bootStatusExitCode', 'bootStatusTimedOut'}
    require(isinstance(setup, dict) and set(setup) == fields
            and all(setup[key] == expected[key] for key in IDENTITY_FIELDS)
            and type(setup['schemaVersion']) is int and setup['schemaVersion'] == 1
            and setup['scope'] == 'diagnosticOnly' and setup['action'] == 'setup' and setup['mode'] is None
            and setup['status'] == 'bootFailed' and setup['phase'] == 'bootStatusReturned'
            and setup['simulatorInitialState'] in ('Booted', 'Shutdown')
            and type(setup['bootStatusTimedOut']) is bool
            and ((setup['bootStatusExitCode'] is None and setup['bootStatusTimedOut'] is True)
                 or (type(setup['bootStatusExitCode']) is int and setup['bootStatusExitCode'] != 0
                     and setup['bootStatusTimedOut'] is False)), 'unprovenCategoryChangeState')


def category_row(line):
    """설명문에서 단어를 추출하지 않고, 고정 token과 목록 구분자로만 된 한 행을 읽는다."""
    value = line.strip()
    declaration = re.match(r'^(?:Valid sizes:|Valid values:)[ \t]+', value)
    if declaration:
        if len(value) > 512:
            return None
        tokens = [part.strip() for part in value[declaration.end():].removesuffix('.').split(',')]
        if len(tokens) == len(CATEGORIES) and set(tokens) == set(CATEGORIES):
            return tokens, 'inlineDeclaration'
        return None
    if ',' in value and value.endswith('.'):
        tokens = [part.strip() for part in value.removesuffix('.').split(',')]
        if len(value) <= 512 and len(tokens) == len(CATEGORIES) and set(tokens) == set(CATEGORIES):
            return tokens, 'commaList'
        return None
    bullet = re.match(r'^[-*•][ \t]+', value)
    if bullet:
        value = value[bullet.end():]
    if ',' in value:
        tokens, kind = [part.strip() for part in value.removesuffix(',').split(',')], 'commaList'
    elif '|' in value:
        tokens, kind = [part.strip() for part in value.strip('|').split('|')], 'table'
    elif re.search(r'\t| {2,}', value):
        tokens, kind = re.split(r'(?:\t| {2,})+', value), 'table'
    else:
        tokens, kind = [value], 'standalone'
    if not tokens or any(token not in CATEGORIES for token in tokens):
        return None
    return tokens, 'bullet' if bullet else kind


def fixed_category_presence(text):
    return [value for value in CATEGORIES if re.search(r'(?<![\w-])' + re.escape(value) + r'(?![\w-])', text)]


def indentation_columns(line):
    # 들여쓰기만 8열 tab stop으로 비교한다. 목록 본문의 tab 구분자는 그대로 둔다.
    prefix = line[:len(line) - len(line.lstrip(' \t'))]
    return len(prefix.expandtabs(8))


def category_row_metadata(groups):
    """지원 판정과 별개로, 원문 없는 고정 token·형태·상한 있는 수만 관측한다."""
    rows = []
    for paragraph, group in enumerate(groups, 1):
        for line in group:
            matches = list(islice(CATEGORY_TOKEN.finditer(line), 25))
            if not matches:
                continue
            if len(rows) == 24:
                return rows, True
            value = line.strip()
            declaration = re.match(r'^(Valid sizes:|Valid values:)(?:[ \t]+|$)', value)
            prefix = line[:matches[0].start()]
            declaration_kind = ('validSizes' if declaration[1] == 'Valid sizes:' else 'validValues') if declaration else (
                'other' if re.search(r'\w', prefix) else 'none')
            body = value[declaration.end():] if declaration else value
            body = re.sub(r'^[-*•][ \t]+', '', body)
            remainder = CATEGORY_TOKEN.sub(' ', body)
            unknown = min(255, sum(1 for _ in re.finditer(r'\w+(?:-\w+)*', remainder)))
            quote_kinds = {kind for character, kind in (("'", 'single'), ('"', 'double'), ('`', 'backtick'))
                           if character in body}
            separators = {kind for character, kind in ((',', 'comma'), ('|', 'pipe')) if character in body}
            punctuation = re.sub(r'\w+(?:-\w+)*', '', remainder).strip().removesuffix('.').removesuffix(':')
            if punctuation.strip(" \t,'\"`|"):
                separator = 'other'
            elif separators:
                separator = next(iter(separators)) if len(separators) == 1 else 'mixed'
            elif '\t' in body:
                separator = 'tab'
            elif re.search(r' {2,}', body):
                separator = 'multiSpace'
            else:
                separator = 'none' if len(matches) == 1 else 'other'
            rows.append({'indentColumns': min(255, indentation_columns(line)), 'paragraphIndex': min(255, paragraph),
                         'tokens': [match[0] for match in matches[:24]], 'tokensTruncated': len(matches) > 24,
                         'quoteStyle': next(iter(quote_kinds)) if len(quote_kinds) == 1 else 'mixed' if quote_kinds else 'none',
                         'separatorShape': separator,
                         'terminal': {',': 'comma', '.': 'period', ':': 'colon'}.get(value[-1],
                             'none' if value[-1].isalnum() else 'other'),
                         'declaration': declaration_kind, 'unknownWordCount': unknown})
    return rows, False


def category_listing(text):
    # 두 option, 두 문단 또는 두 채널의 부분 목록을 합쳐 지원 계약을 만들지 않는다.
    sections = list(re.finditer(r'(?m)^([ \t]*)content_size[ \t]*$', text))
    whole_help = fixed_category_presence(text)
    result = {'knownCategories': [], 'knownCategoryCount': 0, 'categoryFormat': 'none',
              'categoryListComplete': False, 'knownTokensPresent': [], 'knownTokensPresentCount': 0,
              'sectionCount': len(sections), 'headingIndent': None, 'firstBodyIndent': None,
              'firstFollowingIndent': None, 'wholeHelpTokensPresent': whole_help,
              'wholeHelpTokensPresentCount': len(whole_help), 'categoryRows': [], 'categoryRowsTruncated': False}
    if len(sections) != 1:
        return result
    section = sections[0]
    result['headingIndent'] = indentation_columns(section[1])
    block, ambiguous_heading = [], False
    for line in text[section.end():].splitlines():
        if line.strip():
            indent = indentation_columns(line)
            if result['firstFollowingIndent'] is None:
                result['firstFollowingIndent'] = indent
            if indent <= result['headingIndent']:
                break
            # 들여쓰기 계층이 불분명한 다른 bare heading을 현재 option의 본문으로 흡수하지 않는다.
            if re.fullmatch(r'[a-z][a-z0-9_-]*', line.strip()) and line.strip() not in CATEGORIES:
                ambiguous_heading = True
                break
            if result['firstBodyIndent'] is None:
                result['firstBodyIndent'] = indent
        block.append(line)
    # 등장 여부는 안전한 고정 token만 기록하며, 목록 문법이나 지원 계약의 증거로 사용하지 않는다.
    present = fixed_category_presence('\n'.join(block))
    result.update(knownTokensPresent=present, knownTokensPresentCount=len(present))
    groups, group, indent = [], [], None
    for line in [*block, '']:
        current = indentation_columns(line)
        row = category_row(line)
        declaration = row is not None and row[1] == 'inlineDeclaration'
        if not line.strip() or declaration or indent is not None and current != indent:
            if group:
                groups.append(group)
            group, indent = [], None
        if declaration:
            groups.append([line])
        elif line.strip():
            group.append(line)
            indent = current
    result['categoryRows'], result['categoryRowsTruncated'] = category_row_metadata(groups)
    candidates, known, formats = [], set(), set()
    for group in groups:
        # 공개 Xcode 27 도움말 보존본의 세 선언을 같은 문단·들여쓰기에서 원자적으로 확인한다.
        # unknown/unsupported는 지원 category가 아니며 다른 설명이나 부분 목록과 합치지 않는다.
        if any(line.lstrip(' \t').startswith(('Standard sizes:', 'Extended range sizes:', 'Other values:'))
               for line in group):
            valid = tuple(line.strip(' \t') for line in group) == GROUPED_CATEGORY_DECLARATIONS
            candidates.append((list(CATEGORIES) if valid else [], valid))
            if valid:
                known.update(CATEGORIES)
                formats.add('standardExtendedDeclarations')
            continue
        rows, valid = [], True
        for line in group:
            row = category_row(line)
            if row is None:
                valid = False
                continue
            tokens, kind = row
            rows.extend(tokens)
            known.update(tokens)
            formats.add(kind)
        if rows:
            candidates.append((rows, valid))
    result.update(knownCategories=[value for value in CATEGORIES if value in known],
                  knownCategoryCount=len(known), categoryFormat=next(iter(formats)) if len(formats) == 1
                  else 'mixed' if formats else 'none')
    if len(candidates) == 1:
        rows, valid = candidates[0]
        result['categoryListComplete'] = (not ambiguous_heading and valid and len(rows) == len(CATEGORIES)
                                          and set(rows) == set(CATEGORIES))
    return result


def supports_ui(text):
    """공개 usage와 단일 content_size 항목의 완전한 고정 category 목록을 요구한다."""
    return (re.search(r'(?m)^Usage: simctl ui <device> <(?:option|operation)> \[<(?:arguments|value)>\]\s*$', text)
            is not None and category_listing(text)['categoryListComplete'])


def help_metadata(text):
    safe_lines = []
    for line in text.splitlines():
        line = line.strip(' \t')
        prefix = re.match(r'(?:Usage: *simctl ui|content_size)(?= |$)', line)
        if not prefix or len(line) > 100:
            continue
        tail = line[prefix.end():]
        if re.fullmatch(r'[A-Za-z <>\[\]|_]*', tail) is None:
            continue
        # 문법 placeholder와 고정 operation 단어만 허용하고 임의 설명문은 제외한다.
        placeholders = re.findall(r'<([A-Za-z_]+)>', tail)
        if any(value not in ('device', 'option', 'operation', 'arguments', 'argument', 'args',
                             'value', 'size', 'category', 'command')
               for value in placeholders):
            continue
        words = re.findall(r'[A-Za-z_]+', re.sub(r'<[A-Za-z_]+>', '', tail))
        if all(word in ('appearance', 'content_size', 'increase_contrast', 'increase', 'decrease') for word in words):
            if line not in safe_lines and len(safe_lines) < 8:
                safe_lines.append(line)
    return {'bytes': len(text.encode('utf-8')), 'supported': supports_ui(text), 'safeLines': safe_lines,
            **category_listing(text)}


def help_contract(stdout, stderr):
    streams = {'stdout': stdout, 'stderr': stderr}
    metadata = {name: help_metadata(text) for name, text in streams.items()}
    sources = [name for name in streams if metadata[name]['supported']]
    unique = sorted({streams[name] for name in sources})
    report = {'helpStreams': metadata, 'contractFrom': 'both' if len(sources) == 2 else sources[0] if sources else 'none',
              'uniqueHelpCount': len(unique), 'publicUIContractVerified': bool(sources)}
    return report, A.digest(json.dumps(unique, ensure_ascii=False).encode()) if unique else None


def category(text):
    value = text.strip()
    require(value in CATEGORIES, 'unrecognizedSystemCategory')
    return value


def native(args, name, timeout=15):
    with (DIRECTORY / (name + '.stdout')).open('xb') as out, (DIRECTORY / (name + '.stderr')).open('xb') as err:
        process = subprocess.Popen(args, cwd=ROOT, stdout=out, stderr=err, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=10)
            return None
    return code


def output(name, stream='stdout'):
    path = DIRECTORY / (name + '.' + stream)
    if path.is_file() and not path.is_symlink() and path.stat().st_size == 0:
        return ''
    return A.read_regular(path, A.MAX_LOG).decode('utf-8')


def command(args, name):
    require(native(args, name) == 0, 'nativeCommandFailed')
    return output(name)


def context(expected):
    value = A.context_for(BUILD, expected)
    return value, value['destination'].split('id=', 1)[1]


def verify_typed(summary, tree):
    require(isinstance(summary, dict) and all(type(summary.get(key)) is int for key in
            ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')), 'invalidTypedSummary')
    counts = tuple(summary[key] for key in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests'))
    require(counts in ((1, 1, 0, 0), (1, 0, 1, 0)), 'notOneCompletedCase')
    state, cases, bundles = ('Passed' if counts[1] else 'Failed'), [], []
    def visit(node, owner=None, depth=0):
        require(isinstance(node, dict) and depth < 32, 'invalidTypedTree')
        if node.get('nodeType') in ('UI test bundle', 'Unit test bundle'):
            owner = node.get('name')
            bundles.append((node.get('nodeType'), owner))
        if node.get('nodeType') == 'Test Case':
            cases.append((owner, node.get('name'), node.get('result')))
        children = node.get('children', [])
        require(isinstance(children, list) and len(children) <= 100, 'invalidTypedTree')
        for child in children:
            visit(child, owner, depth + 1)
    require(isinstance(tree, dict) and isinstance(tree.get('testNodes'), list), 'invalidTypedTree')
    for node in tree['testNodes']:
        visit(node)
    require(bundles == [('UI test bundle', 'MirrorIOSAdaptiveUITests')]
            and cases == [('MirrorIOSAdaptiveUITests', CASE + '()', state)], 'typedCaseMismatch')
    return state.lower()


def observations(log, mode, terminal):
    active, ended, probes, issues, boundary = False, False, {}, [], None
    event = re.compile(r"Test Case '-\[" + re.escape(OWNER) + ' ' + CASE
                       + r"\]' (started|passed|failed)(?: \([0-9]+(?:\.[0-9]+)? seconds\))?\.")
    for line in log.splitlines():
        if re.search(r'\bTest\s+Case\b', line):
            found = event.fullmatch(line)
            require(found is not None, 'caseOwnerMismatch')
            if found[1] == 'started':
                require(not active and not ended and line.endswith("' started."), 'duplicateCase')
                active = True
            else:
                require(active and found[1] == terminal, 'caseTerminalMismatch')
                active, ended = False, True
        if A.AUDIT_BOUNDARY_MARKER in line:
            require(active and boundary is None and line.startswith(A.AUDIT_BOUNDARY_MARKER), 'unownedAuditBoundary')
            value = A.strict_json(line[len(A.AUDIT_BOUNDARY_MARKER):])
            require(value in ({'schemaVersion': 1, 'case': 'captureValidation', 'auditSequence': 1, 'outcome': outcome}
                             for outcome in ('returned', 'threw')) and type(value['schemaVersion']) is int
                    and type(value['auditSequence']) is int and 'capture' in probes, 'invalidAuditBoundary')
            boundary = value['outcome']
        if 'UI dynamic type ' not in line:
            continue
        require(active and len(line.encode()) <= 1024 and line.startswith((PROBE, AUDIT)), 'unownedObservation')
        value = A.strict_json(line[len(PROBE if line.startswith(PROBE) else AUDIT):])
        require(isinstance(value, dict) and type(value.get('schemaVersion')) is int
                and value['schemaVersion'] == 1 and value.get('requestedMode') == mode, 'modeMismatch')
        if line.startswith(PROBE):
            require(set(value) == {'schemaVersion', 'requestedMode', 'actualMode', 'scope', 'swiftUI', 'uiKit', 'uiKitSource'}
                    and value['actualMode'] == mode and value['scope'] in ('root', 'capture')
                    and value['uiKitSource'] == 'appSystem'
                    and value['swiftUI'] == 'accessibility5' and value['uiKit'] == 'accessibilityExtraExtraExtraLarge',
                    'maximumCategoryMismatch')
            require(value['scope'] not in probes, 'duplicateProbe')
            require(value['scope'] == 'root' or 'root' in probes, 'probeOrderMismatch')
            probes[value['scope']] = value
        else:
            require(set(value) == {'schemaVersion', 'requestedMode', 'auditSequence', 'issueSequence', 'types', 'ignored'}
                    and type(value['auditSequence']) is int and value['auditSequence'] == 1
                    and type(value['issueSequence']) is int and value['issueSequence'] == len(issues) + 1
                    and value['ignored'] is False and isinstance(value['types'], list) and 0 < len(value['types']) <= 4
                    and all(item in ('dynamicType', 'contrast', 'textClipped', 'other') for item in value['types'])
                    and len(set(value['types'])) == len(value['types']) and 'capture' in probes
                    and boundary is None, 'invalidAuditObservation')
            issues.append(value['types'])
    if boundary is None and terminal == 'failed' and issues:
        boundary = 'notReturned'  # XCTest가 handler의 false 직후 사례를 끝내면 catch까지 돌아오지 않을 수 있다.
    require(ended and set(probes) == {'root', 'capture'} and boundary is not None
            and (terminal != 'passed' or boundary == 'returned' and not issues), 'incompleteObservation')
    return {'maximumProbesVerified': True, 'auditIssueTypes': issues, 'auditOutcome': boundary}


def failed_stdout_observations(log, mode):
    """미완료 stdout의 고정 관측만 읽는다. typed 완료·통과나 누락된 boundary를 추론하지 않는다."""
    require(mode in MODES and len(log.encode('utf-8')) <= A.MAX_LOG, 'invalidFailureObservation')
    started, terminal, probes, issues, boundary = False, None, {}, [], None
    pending_issue, issue_details = None, []
    event = re.compile(r"Test Case '-\[" + re.escape(OWNER) + ' ' + CASE
                       + r"\]' (started|passed|failed)(?: \([0-9]+(?:\.[0-9]+)? seconds\))?\.")
    swift_sizes = ('xSmall', 'small', 'medium', 'large', 'xLarge', 'xxLarge', 'xxxLarge',
                   'accessibility1', 'accessibility2', 'accessibility3', 'accessibility4', 'accessibility5')
    ui_sizes = ('extraSmall', 'small', 'medium', 'large', 'extraLarge', 'extraExtraLarge', 'extraExtraExtraLarge',
                'accessibilityMedium', 'accessibilityLarge', 'accessibilityExtraLarge',
                'accessibilityExtraExtraLarge', 'accessibilityExtraExtraExtraLarge', 'unspecified')
    for line in log.splitlines():
        if re.search(r'\bTest\s+Case\b', line):
            found = event.fullmatch(line)
            require(found is not None, 'invalidFailureObservation')
            if found[1] == 'started':
                require(not started and line.endswith("' started."), 'invalidFailureObservation')
                started = True
            else:
                require(started and terminal is None, 'invalidFailureObservation')
                terminal = found[1]
        is_boundary = A.AUDIT_BOUNDARY_MARKER in line
        issue_signal = re.search(r'\bUI\s+adaptive\s+audit\s+(?:issue|geometry)\b', line)
        if not is_boundary and not issue_signal and 'UI dynamic type ' not in line:
            continue
        require(started and terminal is None and len(line.encode('utf-8')) <= 1024
                and line.startswith((PROBE, AUDIT, AUDIT_ISSUE, AUDIT_GEOMETRY, A.AUDIT_BOUNDARY_MARKER)), 'invalidFailureObservation')
        marker = next(value for value in (PROBE, AUDIT, AUDIT_ISSUE, AUDIT_GEOMETRY, A.AUDIT_BOUNDARY_MARKER)
                      if line.startswith(value))
        value = A.strict_json(line[len(marker):])
        require(isinstance(value, dict) and type(value.get('schemaVersion')) is int
                and value['schemaVersion'] == 1, 'invalidFailureObservation')
        if marker in (AUDIT_ISSUE, AUDIT_GEOMETRY):
            shared = {'schemaVersion', 'case', 'auditSequence', 'issueSequence', 'elementIdentifier', 'elementType'}
            require(set(value) == shared | ({'issueKind', 'elementPresent', 'ignored'} if marker == AUDIT_ISSUE else {'frame'})
                    and value['case'] == 'captureValidation' and type(value['auditSequence']) is int
                    and value['auditSequence'] == 1 and type(value['issueSequence']) is int
                    and value['elementIdentifier'] in AUDIT_IDENTIFIERS and value['elementType'] in AUDIT_ELEMENT_TYPES
                    and 'capture' in probes and boundary is None, 'invalidFailureObservation')
            if marker == AUDIT_ISSUE:
                require(pending_issue is None and len(issues) < 64 and value['issueSequence'] == len(issues) + 1
                        and value['issueKind'] in ('parentChildMismatch', 'missingDescription', 'other')
                        and type(value['elementPresent']) is bool and value['ignored'] is False
                        and (value['elementIdentifier'] != 'none' and value['elementType'] != 'none'
                             if value['elementPresent'] else value['elementIdentifier'] == value['elementType'] == 'none'),
                        'invalidFailureObservation')
                pending_issue = {key: value[key] for key in
                                 ('issueSequence', 'issueKind', 'elementPresent', 'elementIdentifier', 'elementType')}
            else:
                require(pending_issue is None and issue_details and value['issueSequence'] == len(issues)
                        and issue_details[-1]['status'] == 'observed', 'invalidFailureObservation')
                detail = issue_details[-1]
                require(detail['geometry']['status'] == 'unobserved'
                        and all(value[key] == detail[key] for key in ('elementIdentifier', 'elementType'))
                        and (value['frame'] is None or detail['elementPresent']
                             and A.measurement_frame(value['frame'], positive=False)
                             and all(abs(number) <= 100_000 for number in value['frame'])), 'invalidFailureObservation')
                detail['geometry'] = {'status': 'observed', 'frame': value['frame']}
        elif is_boundary:
            require(value in ({'schemaVersion': 1, 'case': 'captureValidation', 'auditSequence': 1, 'outcome': outcome}
                             for outcome in ('returned', 'threw')) and type(value['auditSequence']) is int
                    and 'capture' in probes and boundary is None and pending_issue is None, 'invalidFailureObservation')
            boundary = value['outcome']
        elif marker == PROBE:
            require(set(value) == {'schemaVersion', 'requestedMode', 'actualMode', 'scope', 'swiftUI', 'uiKit', 'uiKitSource'}
                    and value['requestedMode'] in MODES and value['actualMode'] in MODES
                    and value['scope'] in ('root', 'capture') and value['uiKitSource'] == 'appSystem'
                    and value['swiftUI'] in swift_sizes and value['uiKit'] in ui_sizes
                    and value['scope'] not in probes and boundary is None and not issues and pending_issue is None
                    and (value['scope'] == 'root' or 'root' in probes), 'invalidFailureObservation')
            probes[value['scope']] = {
                'requestedMode': value['requestedMode'], 'actualMode': value['actualMode'],
                'swiftUI': value['swiftUI'], 'uiKit': value['uiKit'],
                'modeMismatch': value['requestedMode'] != mode or value['actualMode'] != mode,
                'maximumMismatch': value['swiftUI'] != 'accessibility5'
                    or value['uiKit'] != 'accessibilityExtraExtraExtraLarge',
            }
        else:
            require(set(value) == {'schemaVersion', 'requestedMode', 'auditSequence', 'issueSequence', 'types', 'ignored'}
                    and value['requestedMode'] == mode and type(value['auditSequence']) is int and value['auditSequence'] == 1
                    and type(value['issueSequence']) is int and value['issueSequence'] == len(issues) + 1
                    and value['ignored'] is False and isinstance(value['types'], list) and 0 < len(value['types']) <= 4
                    and all(item in ('dynamicType', 'contrast', 'textClipped', 'other') for item in value['types'])
                    and len(set(value['types'])) == len(value['types']) and len(issues) < 64
                    and 'capture' in probes and boundary is None, 'invalidFailureObservation')
            issues.append(value['types'])
            issue_details.append({'status': 'observed', **pending_issue, 'geometry': {'status': 'unobserved'}}
                                 if pending_issue is not None else {'status': 'unobserved'})
            pending_issue = None
    return {'caseStarted': started, 'caseTerminal': terminal,
            'probes': {scope: {'status': 'observed', **probes[scope]} if scope in probes
                       else {'status': 'unobserved'} for scope in ('root', 'capture')},
            'auditIssueTypes': issues, 'auditIssueDetails': issue_details, 'auditBoundary': boundary}


def failed_native_observations(mode, expected, receipt):
    # 이 보조 관측의 오류는 원래 nativeTestFailed/timeout을 덮지 않는다.
    result = {'scope': 'diagnosticOnly', 'evidence': 'stdoutOnly', 'status': 'unavailable',
              'stdoutBytes': None, 'stderrBytes': None}
    stage = 'receiptVerification'
    try:
        require(A.verify_receipt(BUILD, expected) == receipt, 'changedFailureReceipt')
        stage = 'streamBounds'
        for stream in ('stdout', 'stderr'):
            path = DIRECTORY / (mode + '.' + stream)
            require(path.is_file() and not path.is_symlink() and 0 <= path.stat().st_size <= A.MAX_LOG,
                    'invalidFailureStream')
            result[stream + 'Bytes'] = path.stat().st_size
        stage = 'stdoutRead'
        log = output(mode)
        stage = 'stdoutParse'
        result.update(failed_stdout_observations(log, mode), status='observed')
    except Exception:
        result.update(status='rejected' if stage == 'stdoutParse' else 'unavailable', failureStage=stage)
    return result


def failure_images(mode, expected, receipt, report):
    """이미 실패한 한 사례가 기록한 첫 앱 PNG만 보존한다. 수용 결과는 변경하지 않는다."""
    report['failureStage'] = 'ownership'
    require(mode in MODES and isinstance(receipt, str) and re.fullmatch(r'[0-9a-f]{64}', receipt)
            and A.verify_receipt(BUILD, expected) == receipt, 'invalidImageOwner')
    status = A.read_json(DIRECTORY / (mode + '-exit.json'))
    require(isinstance(status, dict) and set(status) == {'nativeExitCode', 'timedOut'}
            and ((status['nativeExitCode'] is None and status['timedOut'] is True)
                 or (type(status['nativeExitCode']) is int and 1 <= status['nativeExitCode'] <= 255
                     and status['timedOut'] is False)), 'notFailedImageOwner')
    report['failureStage'] = 'record'
    log = output(mode)
    observed = failed_stdout_observations(log, mode)
    require(observed['caseStarted'] is True and observed['caseTerminal'] == 'failed'
            and all(probe['status'] == 'observed' and not probe['modeMismatch'] and not probe['maximumMismatch']
                    for probe in observed['probes'].values()), 'unownedImageObservation')
    entries = A.source_method_entries(A.read_regular(ROOT / A.UI_FAILURE_SOURCE_FILE, A.MAX_JSON).decode('utf-8'),
                                      expected['platform'])
    selected = A.failure_recorded_screenshots(log, expected, entries, require_failure_or_interruption=True)
    require(selected == {'mirror-adaptive-max-capture-1': CASE}, 'notOneCaptureImage')
    report['failureStage'] = 'export'
    bundle, exported = DIRECTORY / (mode + '.xcresult'), DIRECTORY / (mode + '-failure-attachments')
    require(bundle.is_dir() and not bundle.is_symlink() and not exported.exists() and not exported.is_symlink(),
            'unsafeImageExport')
    code = native(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(bundle),
                   '--output-path', str(exported)], mode + '-failure-images-export', 15)
    require(code == 0, 'imageExportUnavailable')
    report['failureStage'] = 'manifest'
    files = A.directory_files(exported)
    manifests = [path for path in files if path.name == 'manifest.json']
    require(len(manifests) == 1, 'missingImageManifest')
    attachments = A.failure_export_entries(A.read_json(manifests[0]), selected)
    require(len(attachments) == 1, 'notOneExportedImage')
    candidates = [path for path in files if path.name == attachments[0][2]]
    require(len(candidates) == 1, 'missingImageFile')
    report['failureStage'] = 'png'
    original = A.read_regular(candidates[0], A.MAX_PNG)
    cleaned, width, height = A.clean_png(original)
    manifest = {**expected, 'formatVersion': 1, 'kind': 'dynamic-type-failure-images',
                'scope': 'recordedFixtureAppImagesOnly', 'semantics': 'diagnosticOnlyNotAcceptanceOrAuditCause',
                'mode': mode, 'buildReceiptSHA256': receipt, 'screenshots': [
                    {'case': CASE, 'stage': 'max-capture', 'sequence': 1, 'file': 'capture.png',
                     'sha256': A.digest(cleaned), 'exportSHA256': A.digest(original), 'bytes': len(cleaned),
                     'width': width, 'height': height}]}
    report['failureStage'] = 'receipt'
    require(A.verify_receipt(BUILD, expected) == receipt, 'changedImageReceipt')
    report['failureStage'] = 'publish'
    public = DIRECTORY / 'public'
    require(not public.is_symlink(), 'unsafeImagePublicDirectory')
    public.mkdir(mode=0o700, exist_ok=True)
    destination = public / (mode + '-failure-images')
    require(not destination.exists() and not destination.is_symlink(), 'staleImageReview')
    temporary = Path(tempfile.mkdtemp(prefix='.failure-images-', dir=DIRECTORY))
    try:
        with (temporary / 'capture.png').open('xb') as stream:
            os.chmod(temporary / 'capture.png', 0o600)
            stream.write(cleaned)
        A.write_json(temporary / 'manifest.json', manifest, exclusive=True)
        checksums = {'capture.png': A.digest(cleaned),
                     'manifest.json': A.digest(A.read_regular(temporary / 'manifest.json', A.MAX_JSON))}
        with (temporary / 'SHA256SUMS').open('x', encoding='ascii') as stream:
            os.chmod(temporary / 'SHA256SUMS', 0o600)
            stream.write(''.join(value + '  ' + name + '\n' for name, value in sorted(checksums.items())))
        require(not destination.exists() and not destination.is_symlink(), 'staleImageReview')
        temporary.rename(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    report.pop('failureStage', None)
    report.update(buildReceiptSHA256=receipt, screenshotCount=1)


def execute(action, mode, expected, report):
    if action == 'cleanup':
        for path in DIRECTORY.iterdir():
            if path.name != 'public':
                shutil.rmtree(path) if path.is_dir() and not path.is_symlink() else path.unlink()
        return
    if action == 'help':
        code = native(['xcrun', 'simctl', 'help', 'ui'], 'ui-help')
        metadata, digest = help_contract(output('ui-help'), output('ui-help', 'stderr'))
        report.update(metadata, nativeHelpExitCode=code, nativeHelpTimedOut=code is None)
        require(code == 0, 'nativeCommandFailed')
        require(metadata['publicUIContractVerified'], 'unsupportedPublicUIContract')
        A.write_json(DIRECTORY / 'contract.json', {'sha256': digest, 'supported': True,
                                                'contractFrom': metadata['contractFrom']})
        return
    require(A.read_json(DIRECTORY / 'contract.json').get('supported') is True, 'missingPublicContract')
    checkpoint(report, 'contextStarted')
    ctx, udid = context(expected)
    checkpoint(report, 'contextVerified')
    if action == 'preboot':
        require(os.environ.get('MIRROR_DYNAMIC_TYPE_PREBOOT') == '1'
                and os.environ.get('GITHUB_WORKFLOW') == 'iPad Dynamic Type 설정 원인분리 진단',
                'invalidPrebootInvocation')
        devices = A.strict_json(command(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], 'preboot-devices'))
        matches = [device for group in devices['devices'].values() for device in group if device.get('udid') == udid]
        require(len(matches) == 1 and matches[0].get('state') in ('Booted', 'Shutdown'), 'simulatorContextMismatch')
        report['simulatorInitialState'] = matches[0]['state']
        if matches[0]['state'] == 'Shutdown':
            command(['xcrun', 'simctl', 'boot', udid], 'preboot-request')
        report['prebootDisposition'] = 'bootRequested' if matches[0]['state'] == 'Shutdown' else 'alreadyBooted'
        return  # content_size와 복구 journal은 build 검증 뒤 기존 setup만 변경한다.
    if action == 'setup':
        receipt = A.verify_receipt(BUILD, expected)
        devices = A.strict_json(command(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], 'devices'))
        matches = [device for group in devices['devices'].values() for device in group if device.get('udid') == udid]
        require(len(matches) == 1 and matches[0].get('state') in ('Booted', 'Shutdown'), 'simulatorContextMismatch')
        report['simulatorInitialState'] = matches[0]['state']
        if matches[0]['state'] == 'Shutdown':
            command(['xcrun', 'simctl', 'boot', udid], 'boot')
        checkpoint(report, 'bootStatusStarted')
        boot_code = native(['xcrun', 'simctl', 'bootstatus', udid, '-b'], 'boot-status', 45)
        report.update(bootStatusExitCode=boot_code, bootStatusTimedOut=boot_code is None)
        checkpoint(report, 'bootStatusReturned')
        require(boot_code == 0, 'bootFailed')
        before = category(command(['xcrun', 'simctl', 'ui', udid, 'content_size'], 'category-before'))
        A.write_json(DIRECTORY / 'restore.json', {'context': ctx, 'before': before, 'receipt': receipt}, exclusive=True)
        command(['xcrun', 'simctl', 'ui', udid, 'content_size', CATEGORIES[-1]], 'category-set')
        after = category(command(['xcrun', 'simctl', 'ui', udid, 'content_size'], 'category-after'))
        require(after == CATEGORIES[-1], 'systemMaximumNotApplied')
        report.update(systemBefore=before, systemAfter=after, buildReceiptSHA256=receipt)
        return
    journal = DIRECTORY / 'restore.json'
    if action == 'restore':
        checkpoint(report, 'restoreJournalReadStarted')
        require(not journal.is_symlink(), 'unsafeRestoreJournal')
        if not journal.exists():
            # 부재만으로 복구를 생략하지 않는다. 같은 실행의 bootstatus 실패만 변경 전임을 증명한다.
            verify_no_category_change(expected)
            report.update(restoreDisposition='notRequiredBeforeCategoryChange', systemRestored=False)
            checkpoint(report, 'restoreNotRequired')
            return
    saved = A.read_json(journal)
    require(saved.get('context') == ctx and saved.get('before') in CATEGORIES, 'restoreContextMismatch')
    if action == 'restore':
        checkpoint(report, 'restoreJournalVerified')
        checkpoint(report, 'restoreSetStarted')
        command(['xcrun', 'simctl', 'ui', udid, 'content_size', saved['before']], 'category-restore')
        checkpoint(report, 'restoreSetCompleted')
        checkpoint(report, 'restoreReadbackStarted')
        require(category(command(['xcrun', 'simctl', 'ui', udid, 'content_size'], 'category-restored'))
                == saved['before'], 'restoreMismatch')
        checkpoint(report, 'restoreReadbackVerified')
        report['systemRestored'] = True
        return
    if action == 'failure-images':
        failure_images(mode, expected, saved.get('receipt'), report)
        return
    require(A.verify_receipt(BUILD, expected) == saved['receipt'], 'buildChanged')
    report['buildReceiptSHA256'] = saved['receipt']
    if action == 'run':
        if mode == 'system':
            require(type(A.read_json(DIRECTORY / 'pinned-exit.json').get('timedOut')) is bool, 'previousArmNotStopped')
        report['systemBeforeTest'] = category(command(['xcrun', 'simctl', 'ui', udid, 'content_size'], mode + '-category'))
        require(report['systemBeforeTest'] == CATEGORIES[-1], 'systemCategoryChanged')
        result = DIRECTORY / (mode + '.xcresult')
        require(not result.exists(), 'staleResult')
        code = native(['xcodebuild', '-project', 'Mirror.xcodeproj', '-scheme', ctx['scheme'],
                       '-configuration', 'Debug', '-sdk', ctx['sdk'], '-destination', ctx['destination'],
                       '-jobs', '2', '-derivedDataPath', str(BUILD / 'DerivedData'), '-resultBundlePath', str(result),
                       '-parallel-testing-enabled', 'NO', '-enableCodeCoverage', 'NO',
                       '-only-testing:MirrorIOSAdaptiveUITests/MirrorAdaptiveUITests/' + CASE,
                       'CURRENT_PROJECT_VERSION=' + expected['buildNumber'], 'MIRROR_UI_APPEARANCE=system',
                       'MIRROR_UI_DYNAMIC_TYPE_FIXTURE=' + mode, 'CODE_SIGNING_ALLOWED=NO', 'test-without-building'], mode, 420)
        A.write_json(DIRECTORY / (mode + '-exit.json'), {'nativeExitCode': code, 'timedOut': code is None})
        report.update(nativeExitCode=code, timedOut=code is None)
        if code != 0:
            report['failureObservation'] = failed_native_observations(mode, expected, saved['receipt'])
        require(code == 0, 'nativeTestFailed')
    else:
        status = A.read_json(DIRECTORY / (mode + '-exit.json'))
        report.update(nativeExitCode=status['nativeExitCode'], timedOut=status['timedOut'])
        require(status['timedOut'] is False and type(status['nativeExitCode']) is int, 'testDidNotFinish')
        data = [A.strict_json(command(['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path',
                                      str(DIRECTORY / (mode + '.xcresult'))], mode + '-' + kind))
                for kind in ('summary', 'tests')]
        terminal = verify_typed(*data)
        require((status['nativeExitCode'] == 0) == (terminal == 'passed'), 'nativeTypedMismatch')
        report.update(caseResult=terminal, **observations(output(mode), mode, terminal))
        require(A.verify_receipt(BUILD, expected) == saved['receipt'], 'buildChanged')


def main(argv=None):
    os.umask(0o077)
    report, code, ready = {'schemaVersion': 1, 'scope': 'diagnosticOnly'}, 0, False
    args = sys.argv[1:] if argv is None else argv
    try:
        require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_OS') == 'macOS'
                and os.environ.get('GITHUB_REPOSITORY') == 'hellosunghyun/mirror', 'runnerMismatch')
        require(len(args) in (1, 2) and args[0] in ('help', 'preboot', 'setup', 'run', 'collect', 'failure-images', 'restore', 'cleanup')
                and (len(args) == 2 and args[1] in MODES if args[0] in ('run', 'collect', 'failure-images') else len(args) == 1), 'invalidAction')
        expected = A.identity('ipad', 'system')
        mode = args[1] if len(args) == 2 else None
        report.update(expected, action=args[0], mode=mode)
        checkpoint(report, 'checkoutStarted')
        A.checkout_matches(expected)
        checkpoint(report, 'checkoutVerified')
        require(not any(path.is_symlink() for path in (DIRECTORY, *DIRECTORY.parents)), 'unsafeDirectory')
        DIRECTORY.mkdir(mode=0o700, parents=True, exist_ok=True)
        ready = True
        execute(args[0], mode, expected, report)
        report['status'] = 'observed'
    except Failure as error:
        report['status'], code = ('diagnosticUnavailable' if report.get('action') == 'failure-images' else error.code), 2
    except Exception:
        report['status'], code = 'diagnosticUnavailable', 2
    # SDK 출력을 포함한 예외 문자열과 simulator 경로/UDID는 내보내지 않는다.
    try:
        if ready:
            public = DIRECTORY / 'public'
            require(not public.is_symlink(), 'unsafePublicDirectory')
            public.mkdir(mode=0o700, exist_ok=True)
            path = public / (report['action'] + ('-' + report['mode'] if report['mode'] else '') + '.json')
            require(not path.is_symlink(), 'unsafeSummary')
            A.write_json(path, report)
    except Exception:
        report['status'], code = ('diagnosticUnavailable' if report.get('action') == 'failure-images'
                                 else 'summaryUnavailable'), 2
    print('::notice::Dynamic Type diagnostic: ' + json.dumps(report, sort_keys=True))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
