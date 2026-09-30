#!/usr/bin/env python3
"""CI의 실제 테스트 결과를 검사하고 Actions 출력과 오류 annotation을 만든다."""

import json
import os
import re
import sys
from pathlib import Path


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
    total = summary['totalTestCount']
    if not isinstance(total, int) or isinstance(total, bool) or total <= 0:
        raise ValueError(f'{path}: 실제 테스트 수가 양수여야 합니다.')
    if summary['failedTests'] != 0 or summary['skippedTests'] != 0 or summary['passedTests'] != total:
        raise ValueError(f'{path}: 실패·skip 없이 모든 테스트가 통과해야 합니다.')
    return total


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
    elif mode == 'bundles':
        if not additional_paths:
            raise ValueError('필수 테스트 bundle 목록이 있어야 합니다.')
        nodes = json.loads(Path(path).read_text())
        bundles = {}

        def cases(node):
            if isinstance(node, dict):
                return int(node.get('nodeType') == 'Test Case') + sum(cases(v) for v in node.values())
            if isinstance(node, list):
                return sum(cases(v) for v in node)
            return 0

        def visit(node):
            if isinstance(node, dict):
                if node.get('nodeType') == 'Test Bundle':
                    bundles[node.get('name')] = cases(node)
                for value in node.values():
                    visit(value)
            elif isinstance(node, list):
                for value in node:
                    visit(value)

        visit(nodes)
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
