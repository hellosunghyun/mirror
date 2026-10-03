#!/usr/bin/env python3
"""Actions SDK probe의 공개 JSON만 고정 문맥 notice로 전달한다. SDK를 직접 읽지 않는다."""
import json
import os
import re
import sys

PREFIX = '::notice::Public SDK audit declarations: '
SYMBOLS = ('performAccessibilityAudit', 'XCUIAccessibilityAuditIssue', 'XCUIAccessibilityAuditType')
MAX_INPUT, MAX_NOTICE = 64 * 1024, 3800
PUBLIC_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z')


def strict_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('duplicateKey')
        value[key] = item
    return value


def reject_constant(_):
    raise ValueError('nonJSONNumber')


def valid_files(value):
    if not isinstance(value, list) or len(value) > 8:
        return False
    seen = set()
    for record in value:
        if not isinstance(record, dict) or set(record) != {'file', 'sha256', 'excerpts'}:
            return False
        name, digest, excerpts = record['file'], record['sha256'], record['excerpts']
        if not isinstance(name, str) or not PUBLIC_NAME.fullmatch(name):
            return False
        lower = name.lower()
        if name.endswith('.h'):
            if 'private' in lower or 'internal' in lower:
                return False
        elif name.endswith('.swiftinterface'):
            if 'private' in lower or 'package' in lower:
                return False
        else:
            return False
        if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
            return False
        if (name, digest) in seen or not isinstance(excerpts, list) or not 1 <= len(excerpts) <= 24:
            return False
        seen.add((name, digest))
        text_bytes, line_count, previous_end = 0, 0, 0
        for excerpt in excerpts:
            if not isinstance(excerpt, dict) or set(excerpt) != {'symbols', 'firstLine', 'text'}:
                return False
            symbols, first, text = excerpt['symbols'], excerpt['firstLine'], excerpt['text']
            if not isinstance(text, str) or type(first) is not int or not 1 <= first <= 2 * 1024 * 1024:
                return False
            expected = [symbol for symbol in SYMBOLS if re.search(r'\b' + symbol + r'\b', text)]
            if not expected or symbols != expected:
                return False
            lines = text.splitlines()
            if first <= previous_end or any(len(line.encode('utf-8')) > 1024 for line in lines):
                return False
            previous_end = first + len(lines) - 1
            text_bytes += len(text.encode('utf-8'))
            line_count += len(lines)
            if text_bytes > 16 * 1024 or line_count > 256:
                return False
    return True


def encoded_notice(report):
    message = json.dumps(report, ensure_ascii=True, separators=(',', ':'))
    escaped = message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    notice = PREFIX + escaped
    return notice if len(notice.encode('ascii')) + 1 <= MAX_NOTICE else None


def selected_files(files, selected):
    records = []
    for file_index, record in enumerate(files):
        excerpts = []
        for excerpt_index, excerpt in enumerate(record['excerpts']):
            indexes = sorted(index for fi, ei, index in selected if (fi, ei) == (file_index, excerpt_index))
            if not indexes:
                continue
            groups = []
            for index in indexes:
                if groups and index == groups[-1][-1] + 1:
                    groups[-1].append(index)
                else:
                    groups.append([index])
            lines = excerpt['text'].splitlines()
            for group in groups:
                text = '\n'.join(lines[index] for index in group)
                symbols = [symbol for symbol in SYMBOLS if re.search(r'\b' + symbol + r'\b', text)]
                excerpts.append({'symbols': symbols, 'firstLine': excerpt['firstLine'] + group[0], 'text': text})
        if excerpts:
            records.append({'file': record['file'], 'sha256': record['sha256'], 'excerpts': excerpts})
    return records


def declared_symbols(line):
    # 공개 발췌의 선언 시작만 우선한다. parameter/reference/comment를 타입 정의로 세지 않는다.
    modifiers = r'^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_:]*(?:\([^)]*\))?|public|open|final|indirect|nonisolated|static|override|required|convenience|mutating|nonmutating)\s+)*'
    declared = []
    for symbol in SYMBOLS:
        if symbol == 'performAccessibilityAudit':
            patterns = (modifiers + r'func\s+' + symbol + r'\b',
                        r'^\s*[-+]\s*\([^)]*\)\s*' + symbol + r'\b')
        else:
            patterns = (modifiers + r'(?:class|struct|enum|protocol|typealias)\s+' + symbol + r'\b',
                        r'^\s*@(?:interface|protocol)\s+' + symbol + r'\b',
                        r'^\s*typedef\s+NS_(?:OPTIONS|ENUM)\s*\([^,()]+,\s*' + symbol + r'\b')
        if any(re.match(pattern, line) for pattern in patterns):
            declared.append(symbol)
    return tuple(declared)


def compact_notice(report):
    notice = encoded_notice(report)
    if notice is not None:
        return notice
    # 원래 input 전체를 검증한 뒤 실제 선언이 있는 계약은 그 정의 줄로만 coverage를 채운다.
    # 발췌에 선언이 없는 이름만 기존 reference 선택을 유지하며, API 계약 확인으로 해석하지 않는다.
    candidates = []
    for file_index, record in enumerate(report['files']):
        for excerpt_index, excerpt in enumerate(record['excerpts']):
            for index, line in enumerate(excerpt['text'].splitlines()):
                symbols = tuple(symbol for symbol in SYMBOLS if re.search(r'\b' + symbol + r'\b', line))
                if symbols:
                    candidates.append(((file_index, excerpt_index, index), symbols, declared_symbols(line)))
    declarations_available = {symbol for _, _, declarations in candidates for symbol in declarations}
    selected, covered, targets = set(), set(), []
    for _ in SYMBOLS:
        best = None
        for position, symbols, declarations in candidates:
            coverage = set(declarations) | (set(symbols) - declarations_available)
            new_symbols = coverage - covered
            if not new_symbols:
                continue
            proposed = selected | {position}
            files = selected_files(report['files'], proposed)
            if not valid_files(files):
                continue
            notice = encoded_notice({**report, 'files': files})
            if notice is None:
                continue
            rank = (-len(new_symbols), len(notice.encode('ascii')), position)
            if best is None or rank < best[0]:
                best = (rank, proposed, coverage, position)
        if best is None:
            break
        selected = best[1]
        covered.update(best[2])
        targets.append(best[3])
    if not selected:
        return None
    # 예산이 허용할 때만 같은 원발췌의 앞뒤 실제 한 줄을 더한다. gap을 합치거나 내용을 만들지 않는다.
    for file_index, excerpt_index, index in targets:
        lines = report['files'][file_index]['excerpts'][excerpt_index]['text'].splitlines()
        for adjacent in (index - 1, index + 1):
            if not 0 <= adjacent < len(lines):
                continue
            proposed = selected | {(file_index, excerpt_index, adjacent)}
            files = selected_files(report['files'], proposed)
            if valid_files(files) and encoded_notice({**report, 'files': files}) is not None:
                selected = proposed
    return encoded_notice({**report, 'files': selected_files(report['files'], selected)})


def main():
    # 허용된 공개 문맥 변수만 읽으며, SDK probe의 stdin 이외 파일/네트워크에 접근하지 않는다.
    if os.environ.get('GITHUB_ACTIONS') != 'true' or sys.platform != 'darwin':
        return 2
    source = os.environ.get('GITHUB_SHA', '')
    run = os.environ.get('GITHUB_RUN_ID', '')
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '')
    if (not re.fullmatch(r'[0-9a-f]{40}', source) or not re.fullmatch(r'[1-9][0-9]{0,19}', run)
            or not re.fullmatch(r'[1-9][0-9]{0,19}', attempt)):
        return 2
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            return 2
        value = json.loads(raw.decode('ascii'), object_pairs_hook=strict_object, parse_constant=reject_constant)
        if (not isinstance(value, dict) or set(value) != {'status', 'files'}
                or value['status'] not in ('found', 'notFound') or not valid_files(value['files'])
                or (value['status'] == 'found') != bool(value['files'])):
            return 2
        report = {'schemaVersion': 1, 'sourceSHA': source, 'runID': run, 'attempt': attempt,
                  'status': value['status'], 'files': value['files']}
        notice = compact_notice(report)
        if notice is None:
            return 2
    except (OSError, UnicodeError, ValueError, TypeError, RecursionError):
        return 2
    # 크기 초과/잘못된 문맥에서는 부분 메시지나 대체 성공 notice를 출력하지 않는다.
    print(notice)
    return 0


if __name__ == '__main__':
    sys.exit(main())
