#!/usr/bin/env python3
"""Actions SDK probe의 공개 JSON만 고정 문맥 notice로 전달한다. SDK를 직접 읽지 않는다."""
import json
import os
import re
import sys

PREFIX = '::notice title=Public SDK audit declarations::'
SYMBOLS = ('performAccessibilityAudit', 'XCUIAccessibilityAuditIssue', 'XCUIAccessibilityAuditType')
MAX_INPUT, MAX_NOTICE = 64 * 1024, 64 * 1024
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
        message = json.dumps(report, ensure_ascii=True, separators=(',', ':'))
        escaped = message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        notice = PREFIX + escaped
        if len(notice.encode('ascii')) + 1 > MAX_NOTICE:
            return 2
    except (OSError, UnicodeError, ValueError, TypeError, RecursionError):
        return 2
    # 크기 초과/잘못된 문맥에서는 부분 메시지나 대체 성공 notice를 출력하지 않는다.
    print(notice)
    return 0


if __name__ == '__main__':
    sys.exit(main())
