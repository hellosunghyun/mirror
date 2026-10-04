#!/usr/bin/env python3
"""Actions 전용: 같은 unsigned build의 한 iPad 사례를 비교한다. 수용 gate가 아니다."""
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys

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
PROBE = 'UI dynamic type fixture: '
AUDIT = 'UI dynamic type audit: '


class Failure(A.AdaptiveError):
    def __init__(self, code):
        self.code = code  # 호출 지점의 고정 코드만 보존하며 SDK 예외 문자열은 사용하지 않는다.


def require(value, code):
    if not value:
        raise Failure(code)


def supports_ui(text):
    """공개 usage의 인자 순서·선택 인자와 content_size의 독립 항목을 모두 요구한다."""
    section = re.search(r'(?m)^([ \t]+)content_size[ \t]*$', text)
    if section is None:
        return False
    block = []
    for line in text[section.end():].splitlines():
        if line.strip() and len(line) - len(line.lstrip()) <= len(section[1]):
            break
        block.append(line)
    return (re.search(r'(?m)^Usage: simctl ui <device> <(?:option|operation)> \[<(?:arguments|value)>\]\s*$', text)
            is not None and all(re.search(r'(?m)^\s+' + re.escape(value) + r'\s*$', '\n'.join(block))
                                for value in CATEGORIES))


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


def output(name):
    path = DIRECTORY / (name + '.stdout')
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


def execute(action, mode, expected, report):
    if action == 'cleanup':
        for path in DIRECTORY.iterdir():
            if path.name != 'public':
                shutil.rmtree(path) if path.is_dir() and not path.is_symlink() else path.unlink()
        return
    if action == 'help':
        text = command(['xcrun', 'simctl', 'help', 'ui'], 'ui-help')
        report['listedCategories'] = [value for value in CATEGORIES
                                      if re.search(r'(?m)^\s+' + re.escape(value) + r'\s*$', text)]
        report['publicUIContractVerified'] = supports_ui(text)
        require(supports_ui(text), 'unsupportedPublicUIContract')
        A.write_json(DIRECTORY / 'contract.json', {'sha256': A.digest(text.encode()), 'supported': True})
        report['publicUIContractVerified'] = True
        return
    require(A.read_json(DIRECTORY / 'contract.json').get('supported') is True, 'missingPublicContract')
    ctx, udid = context(expected)
    if action == 'setup':
        receipt = A.verify_receipt(BUILD, expected)
        devices = A.strict_json(command(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], 'devices'))
        matches = [device for group in devices['devices'].values() for device in group if device.get('udid') == udid]
        require(len(matches) == 1 and matches[0].get('state') in ('Booted', 'Shutdown'), 'simulatorContextMismatch')
        if matches[0]['state'] == 'Shutdown':
            command(['xcrun', 'simctl', 'boot', udid], 'boot')
        require(native(['xcrun', 'simctl', 'bootstatus', udid, '-b'], 'boot-status', 45) == 0, 'bootFailed')
        before = category(command(['xcrun', 'simctl', 'ui', udid, 'content_size'], 'category-before'))
        A.write_json(DIRECTORY / 'restore.json', {'context': ctx, 'before': before, 'receipt': receipt}, exclusive=True)
        command(['xcrun', 'simctl', 'ui', udid, 'content_size', CATEGORIES[-1]], 'category-set')
        after = category(command(['xcrun', 'simctl', 'ui', udid, 'content_size'], 'category-after'))
        require(after == CATEGORIES[-1], 'systemMaximumNotApplied')
        report.update(systemBefore=before, systemAfter=after, buildReceiptSHA256=receipt)
        return
    saved = A.read_json(DIRECTORY / 'restore.json')
    require(saved.get('context') == ctx and saved.get('before') in CATEGORIES, 'restoreContextMismatch')
    if action == 'restore':
        command(['xcrun', 'simctl', 'ui', udid, 'content_size', saved['before']], 'category-restore')
        require(category(command(['xcrun', 'simctl', 'ui', udid, 'content_size'], 'category-restored'))
                == saved['before'], 'restoreMismatch')
        report['systemRestored'] = True
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
        require(len(args) in (1, 2) and args[0] in ('help', 'setup', 'run', 'collect', 'restore', 'cleanup')
                and (len(args) == 2 and args[1] in MODES if args[0] in ('run', 'collect') else len(args) == 1), 'invalidAction')
        expected = A.identity('ipad', 'system')
        A.checkout_matches(expected)
        require(not any(path.is_symlink() for path in (DIRECTORY, *DIRECTORY.parents)), 'unsafeDirectory')
        DIRECTORY.mkdir(mode=0o700, parents=True, exist_ok=True)
        ready = True
        mode = args[1] if len(args) == 2 else None
        report.update(expected, action=args[0], mode=mode)
        execute(args[0], mode, expected, report)
        report['status'] = 'observed'
    except Failure as error:
        report['status'], code = error.code, 2
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
        report['status'], code = 'summaryUnavailable', 2
    print('Dynamic Type diagnostic: ' + json.dumps(report, sort_keys=True))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
