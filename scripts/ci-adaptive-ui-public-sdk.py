#!/usr/bin/env python3
"""향후 Actions 전용 공개 SDK 발췌. 위치/선언은 실제 러너 관측 전 미검증이다."""
import hashlib
import itertools
import json
import os
import re
import stat
import sys

DEVELOPER = ('Applications', 'Xcode_27.app', 'Contents', 'Developer')
LIBRARIES = (('Library', 'Frameworks'),
             ('Platforms', 'MacOSX.platform', 'Developer', 'Library', 'Frameworks'),
             ('Platforms', 'iPhoneSimulator.platform', 'Developer', 'Library', 'Frameworks'))
FRAMEWORKS = ('XCUIAutomation', 'XCTest')
SYMBOLS = ('performAccessibilityAudit', 'XCUIAccessibilityAuditIssue', 'XCUIAccessibilityAuditType')
SYMBOL_PATTERN = re.compile(r'\b(?:' + '|'.join(SYMBOLS) + r')\b')
PUBLIC_NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z')
MAX_ENTRIES, MAX_FILES, MAX_FILE_BYTES, MAX_TOTAL_BYTES = 128, 96, 2 * 1024 * 1024, 8 * 1024 * 1024
MAX_FOUND_FILES, MAX_HITS, CONTEXT, MAX_LINES = 8, 24, 12, 256
MAX_LINE_BYTES, MAX_TEXT_BYTES, MAX_OUTPUT_BYTES = 1024, 16 * 1024, 64 * 1024


def open_directory(parts):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    current = os.open('/', flags)
    try:
        for part in parts:
            child = os.open(part, flags, dir_fd=current)
            os.close(current)
            current = child
        return current
    except OSError:
        os.close(current)
        return None


def public_names(directory, kind):
    names = []
    with os.scandir(directory) as entries:
        for entry in itertools.islice(entries, MAX_ENTRIES):
            name = entry.name
            if not PUBLIC_NAME.fullmatch(name):
                continue
            lower = name.lower()
            if (kind == 'Headers' and name.endswith('.h')
                    and 'private' not in lower and 'internal' not in lower):
                names.append(name)
            elif (kind == 'Modules' and name.endswith('.swiftinterface')
                  and 'private' not in lower and 'package' not in lower):
                names.append(name)
    return sorted(names)


def read_public(directory, name, budget):
    if budget['files'] >= MAX_FILES:
        return None
    budget['files'] += 1
    before = os.stat(name, dir_fd=directory, follow_symlinks=False)
    if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
            or before.st_size > MAX_FILE_BYTES or budget['bytes'] + before.st_size > MAX_TOTAL_BYTES):
        return None
    opened = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    try:
        initial = os.fstat(opened)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size, value.st_mtime_ns)
        if not stat.S_ISREG(initial.st_mode) or identity(initial) != identity(before):
            return None
        data = bytearray()
        while len(data) < initial.st_size:
            chunk = os.read(opened, min(65536, initial.st_size - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            budget['bytes'] += len(chunk)
        if len(data) != initial.st_size or identity(os.fstat(opened)) != identity(initial):
            return None
        return bytes(data)
    finally:
        os.close(opened)


def excerpts(data):
    lines = data.decode('utf-8').splitlines()
    hits = list(itertools.islice((index for index, line in enumerate(lines)
                                 if SYMBOL_PATTERN.search(line)), MAX_HITS))
    indexes = sorted({line for hit in hits
                      for line in range(max(0, hit - CONTEXT), min(len(lines), hit + CONTEXT + 1))})[:MAX_LINES]
    groups = []
    for index in indexes:
        if groups and index == groups[-1][-1] + 1:
            groups[-1].append(index)
        else:
            groups.append([index])
    found, text_bytes = [], 0
    for group in groups:
        text = '\n'.join(lines[index] for index in group)
        symbols = [symbol for symbol in SYMBOLS if re.search(r'\b' + symbol + r'\b', text)]
        if not symbols or any(len(lines[index].encode('utf-8')) > MAX_LINE_BYTES for index in group):
            continue
        size = len(text.encode('utf-8'))
        if text_bytes + size > MAX_TEXT_BYTES:
            break
        found.append({'symbols': symbols, 'firstLine': group[0] + 1, 'text': text})
        text_bytes += size
    return found


def main():
    # SDK 탐색보다 먼저 검사한다. 로컬 실행은 아무 SDK 정보도 출력하지 않는다.
    if os.environ.get('GITHUB_ACTIONS') != 'true' or sys.platform != 'darwin':
        return 2
    records, seen, budget = [], set(), {'files': 0, 'bytes': 0}
    for library in LIBRARIES:
        for framework in FRAMEWORKS:
            # 표준 Headers/Modules alias는 따라가지 않고 고정 공개 Versions/A 경로도 시도한다.
            anchors = (('Headers',), ('Modules',), ('Modules', framework + '.swiftmodule'),
                       ('Versions', 'A', 'Headers'), ('Versions', 'A', 'Modules'),
                       ('Versions', 'A', 'Modules', framework + '.swiftmodule'))
            for anchor in anchors:
                if budget['files'] >= MAX_FILES or len(records) >= MAX_FOUND_FILES:
                    break
                directory = None
                try:
                    directory = open_directory(DEVELOPER + library + (framework + '.framework',) + anchor)
                    if directory is None:
                        continue
                    kind = 'Headers' if anchor[-1] == 'Headers' else 'Modules'
                    for name in public_names(directory, kind):
                        if budget['files'] >= MAX_FILES or len(records) >= MAX_FOUND_FILES:
                            break
                        try:
                            data = read_public(directory, name, budget)
                            if data is None:
                                continue
                            digest = hashlib.sha256(data).hexdigest()
                            if (name, digest) in seen:
                                continue
                            matches = excerpts(data)
                            if not matches:
                                continue
                            record = {'file': name, 'sha256': digest, 'excerpts': matches}
                            proposed = {'status': 'found', 'files': records + [record]}
                            if len(json.dumps(proposed, ensure_ascii=True).encode('ascii')) + 1 > MAX_OUTPUT_BYTES:
                                break
                            seen.add((name, digest))
                            records.append(record)
                        except (OSError, UnicodeError):
                            continue
                except OSError:
                    continue
                finally:
                    if directory is not None:
                        os.close(directory)
    # notFound는 이 제한된 검색의 미관측이다. SDK/API 존재 여부나 계약을 부정하지 않는다.
    report = {'status': 'found' if records else 'notFound', 'files': records}
    enabled = {**report, 'auditContractContext': True}
    # 기존 전체 발췌가 64KiB 경계에 있으면 optional 요청만 생략한다. 원 records/status는 보존한다.
    if len(json.dumps(enabled, ensure_ascii=True).encode('ascii')) + 1 <= MAX_OUTPUT_BYTES:
        report = enabled
    print(json.dumps(report, ensure_ascii=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
