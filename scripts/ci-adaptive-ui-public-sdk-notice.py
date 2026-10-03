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


CONTRACT_TOPICS = ('auditType', 'element', 'handler')
CONTRACT_PREFIXES = {topic: '::notice::Public SDK audit ' + topic + ' context: '
                     for topic in CONTRACT_TOPICS}
MAX_COMBINED_NOTICE = 4 * MAX_NOTICE
CONTRACT_DECLARATION_START = re.compile(
    r'^\s*(?:[-+]\s*\(|@(?:interface|protocol|property|end|class|implementation)\b|typedef\b|'
    r'(?:(?:@[A-Za-z_][A-Za-z0-9_:]*(?:\([^)]*\))?|public|open|private|fileprivate|internal|package|final|'
    r'indirect|nonisolated|static|override|required|convenience|mutating|nonmutating|class)\s+)*'
    r'(?:func|var|let|class|struct|enum|protocol|typealias|extension|init|deinit|subscript|associatedtype)\b)')


def contract_code_lines(text):
    # 문맥 내부 주석/문자열의 예시를 선언으로 분류하지 않는다. 불완전 문자열은 미관측으로 남긴다.
    first_open, first_close = text.find('/*'), text.find('*/')
    # CONTEXT 경계가 공개 block comment 중간에서 시작하면 그 닫힘 앞을 선언으로 세지 않는다.
    result, depth = [], int(first_close >= 0 and (first_open < 0 or first_close < first_open))
    for line in text.splitlines():
        code, index = '', 0
        while index < len(line):
            if line.startswith('/*', index):
                depth += 1
                index += 2
            elif line.startswith('*/', index):
                if depth == 0:
                    return None
                depth -= 1
                index += 2
            elif depth:
                index += 1
            elif line.startswith('//', index):
                break
            elif line[index] in ('"', "'"):
                quote, index = line[index], index + 1
                while index < len(line) and line[index] != quote:
                    index += 2 if line[index] == '\\' else 1
                if index >= len(line):
                    return None
                code += ' '
                index += 1
            else:
                code += line[index]
                index += 1
        result.append(code)
    return result


def contract_candidates(files, topic):
    # 같은 실제 발췌의 선언 소유 범위만 사용한다. 줄을 다시 쓰거나 떨어진 소유자를 붙이지 않는다.
    for fi, record in enumerate(files):
        for ei, excerpt in enumerate(record['excerpts']):
            lines = excerpt['text'].splitlines()
            codes = contract_code_lines(excerpt['text'])
            if codes is None:
                continue
            owner, owner_kind, depth = None, None, 0
            for index, code in enumerate(codes):
                if topic == 'handler':
                    direct = 'performAccessibilityAudit' in declared_symbols(code)
                    objc = bool(re.match(r'^\s*[-+]\s*\([^)]*\)', code))
                    if not direct and not objc:
                        continue
                    end, named, handler, signature_depth = None, direct, False, 0
                    for follow in range(index, min(len(lines), index + 13)):
                        if ('{' in codes[follow] or '}' in codes[follow]
                                or (follow > index and CONTRACT_DECLARATION_START.match(codes[follow]))):
                            break
                        signature = codes[follow]
                        if not objc and follow == index:
                            start = re.search(r'\bfunc\s+performAccessibilityAudit\b', signature)
                            signature = signature[start.end():] if start is not None else ''
                            opening = signature.find('(')
                            if opening < 0:
                                break
                            signature = signature[opening:]
                        before_depth, closed = signature_depth, False
                        if objc:
                            closed = ';' in signature
                            signature = signature.split(';', 1)[0]
                            signature_depth += signature.count('(') - signature.count(')')
                        else:
                            for offset, character in enumerate(signature):
                                signature_depth += int(character == '(') - int(character == ')')
                                if signature_depth <= 0:
                                    signature, closed = signature[:offset + 1], True
                                    break
                        named = named or bool(re.search(r'\bNS_SWIFT_NAME\s*\(\s*performAccessibilityAudit\b', signature))
                        for parameter in re.finditer(r'\b(?:issueHandler|withIssueHandler)\s*:', signature):
                            prefix = signature[:parameter.start()]
                            parameter_depth = before_depth + prefix.count('(') - prefix.count(')')
                            if parameter_depth == (0 if objc else 1):
                                handler = True
                        if named and handler:
                            end = follow
                            break
                        # 같은 행의 뒤 선언/중첩 tuple 이름도 현재 signature의 parameter로 합치지 않는다.
                        if closed:
                            break
                    if end is None:
                        continue
                    optional = []
                    for before in range(index - 1, max(-1, index - 13), -1):
                        if codes[before].strip() and not re.match(r'^\s*@(?!interface\b|protocol\b|end\b|class\b|property\b|implementation\b)[A-Za-z_]', codes[before]):
                            break
                        optional.append(before)
                    for after in range(end + 1, min(len(lines), end + 13)):
                        if CONTRACT_DECLARATION_START.match(codes[after]) or codes[after].strip() in ('}', '@end'):
                            break
                        optional.append(after)
                    yield {(fi, ei, line) for line in range(index, end + 1)}, [(fi, ei, line) for line in optional]
                    continue
                if 'XCUIAccessibilityAuditIssue' in declared_symbols(code):
                    if re.search(r'\b(?:class|struct)\s+XCUIAccessibilityAuditIssue\b', code) and '{' in code:
                        owner, owner_kind = index, 'swift'
                        depth = code.count('{') - code.count('}')
                    elif re.match(r'^\s*@interface\s+XCUIAccessibilityAuditIssue\b', code):
                        owner, owner_kind, depth = index, 'objc', 1
                    else:
                        owner, owner_kind, depth = None, None, 0
                    continue
                if owner is None:
                    continue
                if (code.strip() == '@end' or re.match(r'^\s*@(?:interface|protocol)\b', code)
                        or re.search(r'^\s*(?:(?:public|open|final)\s+)*(?:class|struct|enum|protocol|extension)\b', code)):
                    owner, owner_kind, depth = None, None, 0
                    continue
                swift_property = r'^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_:]*(?:\([^)]*\))?)\s+)*(?:public|open)\s+(?:(?:final|override|nonisolated|weak|unowned)\s+)*var\s+' + topic + r'\s*:'
                objc_property = r'^\s*@property\s*(?:\([^)]*\))?\s+[^;{}]*\b' + topic + r'\s*;'
                if depth == 1 and re.match(swift_property if owner_kind == 'swift' else objc_property, code):
                    optional = []
                    for after in range(index + 1, min(len(lines), index + 13)):
                        if re.match(r'^\s*@(?:end|interface|protocol)\b', codes[after]):
                            break
                        optional.append(after)
                        if codes[after].strip() == '}':
                            break
                    for before in range(owner - 1, max(-1, owner - 13), -1):
                        if codes[before].strip() and not re.match(r'^\s*@(?!interface\b|protocol\b|end\b|class\b|property\b|implementation\b)[A-Za-z_]', codes[before]):
                            break
                        optional.append(before)
                    yield {(fi, ei, line) for line in range(owner, index + 1)}, [(fi, ei, line) for line in optional]
                if owner_kind == 'swift':
                    depth += code.count('{') - code.count('}')
                    if depth <= 0:
                        owner, owner_kind, depth = None, None, 0


def encoded_contract_notice(report, topic):
    # outer six fields와 원래 공개 file/excerpt 스키마를 유지한다. found 계약 판정은 하지 않는다.
    if (set(report) != {'schemaVersion', 'sourceSHA', 'runID', 'attempt', 'status', 'files'}
            or report['status'] not in ('observedContext', 'unknown')
            or (report['status'] == 'observedContext') != bool(report['files'])
            or not valid_files(report['files'])):
        return None
    message = json.dumps(report, ensure_ascii=True, separators=(',', ':'))
    escaped = message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    notice = CONTRACT_PREFIXES[topic] + escaped
    return notice if len(notice.encode('ascii')) + 1 <= MAX_NOTICE else None


def contract_notices(report):
    notices = []
    for topic in CONTRACT_TOPICS:
        chosen = None
        for selected, optional in contract_candidates(report['files'], topic):
            candidate = {**report, 'status': 'observedContext',
                         'files': selected_files(report['files'], selected)}
            notice = encoded_contract_notice(candidate, topic)
            if notice is None:
                continue
            for position in optional:
                indexes = [item[2] for item in selected]
                if position[2] not in (min(indexes) - 1, max(indexes) + 1):
                    continue
                proposed = selected | {position}
                candidate = {**report, 'status': 'observedContext',
                             'files': selected_files(report['files'], proposed)}
                enriched = encoded_contract_notice(candidate, topic)
                if enriched is not None:
                    selected, notice = proposed, enriched
            rank = (-len(selected), len(notice.encode('ascii')), sorted(selected))
            if chosen is None or rank < chosen[0]:
                chosen = (rank, notice)
        if chosen is None:
            notice = encoded_contract_notice({**report, 'status': 'unknown', 'files': []}, topic)
            if notice is None:
                raise ValueError('contractNoticeBudget')
        else:
            notice = chosen[1]
        notices.append(notice)
    return notices


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
        if (not isinstance(value, dict) or set(value) not in ({'status', 'files'}, {'status', 'files', 'auditContractContext'})
                or ('auditContractContext' in value and (type(value['auditContractContext']) is not bool or value['auditContractContext'] is not True))
                or value['status'] not in ('found', 'notFound') or not valid_files(value['files'])
                or (value['status'] == 'found') != bool(value['files'])):
            return 2
        report = {'schemaVersion': 1, 'sourceSHA': source, 'runID': run, 'attempt': attempt,
                  'status': value['status'], 'files': value['files']}
        notice = compact_notice(report)
        if notice is None:
            return 2
        companions = contract_notices(report) if value.get('auditContractContext') is True else []
        if sum(len(item.encode('ascii')) + 1 for item in [notice, *companions]) > MAX_COMBINED_NOTICE:
            return 2
    except (OSError, UnicodeError, ValueError, TypeError, RecursionError):
        return 2
    # 크기 초과/잘못된 문맥에서는 부분 메시지나 대체 성공 notice를 출력하지 않는다.
    print(notice)
    for companion in companions:
        print(companion)
    return 0


if __name__ == '__main__':
    sys.exit(main())
