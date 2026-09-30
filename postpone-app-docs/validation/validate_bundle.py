#!/usr/bin/env python3
"""Validate documentation and contract examples; this does NOT test the Swift app.

Run from any directory with Python 3.10+ and jsonschema 4.x installed.
The generated report is deliberately separate from all unexecuted app QA cases.
"""
from __future__ import annotations

import json
import re
from collections import Counter
from datetime import date, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / 'validation' / 'VALIDATION_REPORT.md'
RESULT = ROOT / 'validation' / 'bundle-validation.json'
ERRORS: list[str] = []
CHECKS: Counter[str] = Counter()


def check(condition: bool, message: str, category: str) -> None:
    CHECKS[category] += 1
    if not condition:
        ERRORS.append(message)


def read_json(path: str) -> Any:
    return json.loads((ROOT / path).read_text(encoding='utf-8'))


def contract_result(case: dict[str, Any]) -> dict[str, Any]:
    """Independent specification check, not a replacement for production code tests."""
    i = case['input']
    kind = case['kind']
    if kind == 'dateDestinations':
        d = date.fromisoformat(i['planningDay'])
        start = d - timedelta(days=d.weekday())
        week = lambda offset: {
            'startDate': (start + timedelta(days=offset)).isoformat(),
            'endExclusiveDate': (start + timedelta(days=offset + 7)).isoformat(),
        }
        return {'today': d.isoformat(), 'tomorrow': (d + timedelta(days=1)).isoformat(),
                'thisWeek': week(0), 'nextWeek': week(7)}
    if kind == 'visibility':
        t, d = i['task'], i['planningDay']
        p = t['plan']
        is_open = t['status'] == 'open'
        today = is_open and p['kind'] == 'day' and p['date'] == d
        candidate = is_open and p['kind'] != 'parked'
        if t.get('reviewNotBefore') and t['reviewNotBefore'] > d:
            candidate = False
        if i['acknowledgedCurrentPlan']:
            candidate = False
        if p['kind'] == 'day' and p['date'] > d:
            candidate = False
        if p['kind'] == 'week' and p['startDate'] > d:
            candidate = False
        return {'isToday': today, 'reviewCandidate': candidate}
    if kind == 'deadlineWarning':
        p = i['target']
        day = p['date'] if p['kind'] == 'day' else p['startDate']
        return {'requiresAfterDeadlineConfirmation': day > i['deadlineLocalDate']}
    if kind == 'validatePlan':
        p, d = i['target'], date.fromisoformat(i['planningDay'])
        if p['kind'] in ('unassigned', 'parked'):
            valid = True
        elif p['kind'] == 'day':
            valid = date.fromisoformat(p['date']) >= d
        else:
            start = date.fromisoformat(p['startDate'])
            end = date.fromisoformat(p['endExclusiveDate'])
            valid = start.weekday() == 0 and end - start == timedelta(days=7) and end > d
        return {'valid': valid}
    if kind == 'contextCheck':
        value = 'alreadyApplied' if i['matchingReceiptExists'] else (
            'continueValidation' if i['displayDay'] == i['currentDay'] else 'staleContext')
        return {'result': value}
    raise ValueError(f'Unknown fixture kind: {kind}')


def main() -> int:
    # A provisional report ensures its README link can also be checked on first run.
    REPORT.write_text('# 문서 번들 검증 결과\n\n검사 중. 앱 테스트 결과가 아니다.\n', encoding='utf-8')
    md_paths = sorted(ROOT.rglob('*.md'))
    json_paths = sorted(p for p in ROOT.rglob('*.json') if p != RESULT)
    for p in md_paths:
        text = p.read_text(encoding='utf-8')
        rel = str(p.relative_to(ROOT))
        check(bool(text.strip()), f'Empty file: {rel}', 'nonempty_markdown')
        check('\ufffd' not in text, f'Unicode replacement in {rel}', 'utf8_text')
        check(len(re.findall(r'^```', text, re.M)) % 2 == 0,
              f'Unbalanced code fences: {rel}', 'balanced_code_fences')
        for match in re.finditer(r'\[[^\]\n]+\]\(([^)]+)\)', text):
            target = match.group(1).strip()
            if urlsplit(target).scheme or target.startswith('#'):
                continue
            path = (p.parent / unquote(target.split('#', 1)[0])).resolve()
            check(path.is_relative_to(ROOT) and path.exists(),
                  f'Broken internal link: {rel} -> {target}', 'internal_links')
    for p in json_paths:
        try:
            json.loads(p.read_text(encoding='utf-8'))
            check(True, '', 'json_parse')
        except (ValueError, UnicodeError) as e:
            check(False, f'{p.name}: {e}', 'json_parse')

    validators: dict[str, Draft202012Validator] = {}
    for name in ('plan-target', 'command-envelope'):
        schema = read_json(f'contracts/{name}.schema.json')
        try:
            Draft202012Validator.check_schema(schema)
            check(True, '', 'json_schema_definition')
        except Exception as e:
            check(False, f'Invalid schema {name}: {e}', 'json_schema_definition')
        validators[name] = Draft202012Validator(schema, format_checker=FormatChecker())
    # Validate the actual envelope printed in document 04.
    text = (ROOT / '04_DATA_AND_COMMAND_CONTRACTS.md').read_text(encoding='utf-8')
    examples = re.findall(r'^```json\n(.*?)^```', text, re.M | re.S)
    for example in examples:
        value = json.loads(example)
        errors = list(validators['command-envelope'].iter_errors(value))
        check(not errors, f'Envelope example: {[e.message for e in errors]}', 'command_examples')
    check(bool(examples), 'No command envelope example found', 'command_examples')

    fixtures = read_json('fixtures/domain-cases.json')['cases']
    f_ids = [f['id'] for f in fixtures]
    check(len(set(f_ids)) == len(f_ids), 'Duplicate fixture ID', 'fixture_ids')
    for f in fixtures:
        try:
            result = contract_result(f)
            check(result == f['expected'], f"{f['id']}: {result} != {f['expected']}", 'fixture_expectations')
            p = f['input'].get('target') or f['input'].get('task', {}).get('plan')
            if p:
                errors = list(validators['plan-target'].iter_errors(p))
                check(not errors, f"{f['id']} schema: {[e.message for e in errors]}", 'plan_examples')
        except Exception as e:
            check(False, f"{f['id']}: {e}", 'fixture_expectations')

    qa = read_json('validation/qa-cases.json')
    qa_ids = {q['id'] for q in qa}
    req_ids = set(re.findall(r'^\| (FR-\d{3}) \|', (ROOT / '01_PRODUCT_REQUIREMENTS.md').read_text(), re.M))
    tr = read_json('validation/traceability.json')['requirements']
    check(len(qa_ids) == len(qa), 'Duplicate QA ID', 'qa_ids')
    check({t['requirementID'] for t in tr} == req_ids, 'PRD / traceability mismatch', 'requirements_coverage')
    qa_markdown = (ROOT / '08_QA_AND_ACCEPTANCE.md').read_text()
    for q in qa:
        check(q['executionStatus'] == 'not_run', f"Misstated app test: {q['id']}", 'app_test_status')
        check(q['id'] in qa_markdown, f"Missing QA prose: {q['id']}", 'qa_documentation')
        check(bool(q['requirements']) and set(q['requirements']) <= req_ids,
              f"Unknown QA requirements: {q['id']}", 'qa_requirements')
    for t in tr:
        mapped = set(t['testIDs'])
        check(bool(mapped) and mapped <= qa_ids, f"Invalid mapping: {t['requirementID']}", 'requirements_coverage')
        check(mapped == {q['id'] for q in qa if t['requirementID'] in q['requirements']},
              f"Asymmetric mapping: {t['requirementID']}", 'requirements_coverage')
        check(all((ROOT / p).exists() for p in t['specFiles']),
              f"Missing spec file: {t['requirementID']}", 'requirements_coverage')
        check(t['implementationStatus'] == 'not_implemented' and t['appTestStatus'] == 'not_run',
              f"Misstated implementation: {t['requirementID']}", 'app_test_status')

    sources = read_json('validation/sources.json')
    s_ids = {s['id'] for s in sources}
    check(len(s_ids) == len(sources), 'Duplicate source ID', 'source_registry')
    for p in ROOT.glob('*.md'):
        cited = set(re.findall(r'\bA\d{2}\b', p.read_text()))
        check(cited <= s_ids, f"Unknown sources in {p.name}: {cited - s_ids}", 'source_registry')
    for s in sources:
        check(urlsplit(s['url']).hostname == 'developer.apple.com',
              f"Unexpected source domain: {s['id']}", 'source_registry')

    summary = {
        'reportDate': '2026-09-30',
        'scope': 'documentation_and_contract_examples_only',
        'result': 'pass' if not ERRORS else 'fail',
        'checks': dict(CHECKS), 'checkCount': sum(CHECKS.values()),
        'coreDocumentCount': len(list(ROOT.glob('*.md'))),
        'functionalRequirementCount': len(req_ids), 'qaSpecificationCount': len(qa),
        'fixtureCount': len(fixtures), 'officialSourceCount': len(sources),
        'actualAppTestsExecuted': 0, 'errors': ERRORS,
    }
    RESULT.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    report = '# 문서 번들 검증 결과\n\n검사일: 2026-09-30\n\n'
    report += f"**결과: {'통과' if not ERRORS else '수정 필요'}**. 검사 대상은 문서와 계약 예시이며 앱 구현이 아니다.\n\n"
    report += '| 항목 | 결과 |\n|---|---|\n'
    report += f'| 핵심 Markdown 문서 | {summary["coreDocumentCount"]}개 |\n'
    report += f'| 기능 요구사항 | {len(req_ids)}개, 모두 QA 명세 연결 |\n'
    report += f'| 앱 QA 명세 | {len(qa)}개, 실제 실행 0개 |\n'
    report += f'| 도메인 기대값 fixture | {len(fixtures)}개, 독립 Python 규칙과 비교 |\n'
    report += f'| 공식 자료 등록 | {len(sources)}개, 등록 ID와 문서 참조 검사 |\n'
    report += f'| 파일 / 계약 검사 | {sum(CHECKS.values())}개 검사, 오류 {len(ERRORS)}개 |\n\n'
    report += '## 수행한 검사\n\n'
    report += 'UTF-8 텍스트, 빈 파일, 코드 블록 쌍, 내부 파일 링크, JSON 파싱, JSON Schema 2020-12 정의와 예시, 날짜 / 주간 범위 / 목록 분류의 예시 기대값, PRD와 QA 연결, 공식 자료 ID를 검사했다.\n\n'
    report += '36개 fixture 검사는 문서 규칙을 독립 Python 식으로 대조한 것이다. Swift 코드, Swift Calendar의 DST 동작, Core Data 동시성, CloudKit 병합, 위젯 지연을 시험한 결과가 아니다. 외부 URL의 현재 응답 여부는 이 오프라인 검증 스크립트의 검사 범위가 아니다.\n\n'
    report += '## 아직 실행하지 않은 것\n\nXcode 빌드, App Intent metadata 추출, 앱 UI, 위젯, Siri, iCloud 실제 동기화 / 계정 전환 / 삭제, 접근성 실기기 조작, 배터리와 성능 측정은 미실행이다. 실제 제품의 완료 판정은 08 문서의 QA와 09 문서의 게이트를 따른다.\n'
    if ERRORS:
        report += '\n## 오류\n\n' + '\n'.join(f'- {e}' for e in ERRORS) + '\n'
    REPORT.write_text(report, encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 1 if ERRORS else 0


if __name__ == '__main__':
    raise SystemExit(main())
