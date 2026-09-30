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


def diagnostics(path):
    lines = Path(path).read_text(errors='replace').splitlines()
    relevant = [line for line in lines if re.search(r'error:|failed|Issue recorded|fatal:', line, re.I)]
    for line in relevant[:20] or lines[-8:]:
        annotation(line[:1800])


def record(count):
    if not isinstance(count, int) or isinstance(count, bool) or count <= 0:
        raise ValueError('실제 실행한 테스트가 1개 이상이어야 합니다.')
    print(json.dumps({'executedTests': count, 'result': 'pass'}))
    output = os.environ.get('GITHUB_OUTPUT')
    if output:
        with Path(output).open('a') as stream:
            stream.write(f'tests={count}\n')


def main():
    mode, path = sys.argv[1:]
    if mode == 'diagnostics':
        diagnostics(path)
        return
    if mode == 'swift':
        log = Path(path).read_text(errors='replace')
        matches = re.findall(r'Test run with (\d+) tests? (?:in \d+ suites? )?passed', log)
        if not matches:
            raise ValueError('Swift Testing의 실제 완료 결과를 찾지 못했습니다.')
        if re.search(r'\btest(?:s)?\b.*\bskipped\b', log, re.I):
            raise ValueError('Swift 테스트에 skipped 결과가 있습니다.')
        record(int(matches[-1]))
    elif mode == 'xcode':
        summary = json.loads(Path(path).read_text())
        passed = summary['passedTests']
        total = summary['totalTestCount']
        if summary['failedTests'] != 0 or summary['skippedTests'] != 0 or passed != total:
            raise ValueError(f'모든 테스트가 실행되어 통과해야 합니다: {summary}')
        record(total)
    else:
        raise ValueError(f'알 수 없는 결과 형식: {mode}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        annotation(str(error))
        raise SystemExit(1) from error
