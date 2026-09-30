#!/usr/bin/env python3
"""CI의 실제 테스트 결과를 검사하고 Actions 출력과 오류 annotation을 만든다."""

import json
import os
import re
import sys
from pathlib import Path


UI_BASELINE_METHODS = {
    'testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday',
    'testTomorrowStaysOutOfTodayAndIsSearchableInLibrary',
    'testOverlongTitleShowsErrorAndPreservesEveryCharacter',
    'testWeekPanelCancellationAndPartialFinishPreserveUndecidedPlan',
    'testExplicitCompletionAndUndoPreserveEditedTitleAndPlan',
    'testReviewUndoRestoresUnassignedCardInsteadOfAddingToToday',
}


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


def diagnostics(path):
    log = Path(path).read_text(errors='replace')
    lines = log.splitlines()
    report_runs(log)
    relevant = [line for line in lines if re.search(r'error:|failed|Issue recorded|fatal:', line, re.I)
                and not re.match(r'^\s*[|`~-]', line)]
    unique = list(dict.fromkeys(relevant))
    for line in unique[:40] or lines[-8:]:
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
