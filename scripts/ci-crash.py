#!/usr/bin/env python3
"""현재 CI의 미러 UI 실패에서 구조화한 crash 원인만 남긴다.

앱 데이터·계정·환경·전체 crash body·경로는 출력하지 않는다. 진단은 원래 UI
실패 상태를 바꾸지 않으며, ui-start.marker보다 오래된 보고서는 읽지 않는다.
"""

import copy
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path


ANNOTATION_LIMIT = 2000
SAFE_SUMMARY_NAME = 'crash-summary.json'


def annotation(value):
    message = 'Mirror crash diagnostics: ' + json.dumps(value, ensure_ascii=False, separators=(',', ':'))
    escaped = message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    return f'::notice::{escaped}'


def annotation_size(value):
    return len(annotation(value).encode('utf-8')) + 1  # print의 줄바꿈도 한도에 포함한다.


def notice(value):
    # 전체 JSON을 자르지 않는다. 극단적으로 긴 단일 필드는 안전한 요약 파일에 남긴다.
    value = copy.deepcopy(value)
    while annotation_size(value) > ANNOTATION_LIMIT:
        fields = []

        def visit(container):
            for key, child in (container.items() if isinstance(container, dict) else enumerate(container)):
                if isinstance(child, (dict, list)):
                    visit(child)
                elif isinstance(child, str) and len(child) > 64:
                    fields.append((len(annotation(child).encode('utf-8')), container, key, child))
                elif isinstance(child, (int, float)) and not isinstance(child, bool):
                    if len(json.dumps(child)) > 64:
                        fields.append((len(json.dumps(child)), container, key, child))

        visit(value)
        if not fields:
            value = {'status': 'annotationFieldsExcluded', 'safeSummary': SAFE_SUMMARY_NAME}
            break
        _, container, key, original = max(fields, key=lambda field: field[0])
        if not isinstance(original, str):
            container[key] = {'excluded': 'fieldExceedsAnnotationLimit', 'valueType': type(original).__name__}
            continue
        suffix = ' [truncated: crash-summary.json]'
        low, high = 0, len(original)
        container[key] = suffix
        if annotation_size(value) <= ANNOTATION_LIMIT:
            while low < high:
                middle = (low + high + 1) // 2
                container[key] = original[:middle] + suffix
                if annotation_size(value) <= ANNOTATION_LIMIT:
                    low = middle
                else:
                    high = middle - 1
            container[key] = original[:low] + suffix
    print(annotation(value))


def notice_chunks(identity, section, items):
    """구조 항목과 frame은 독립 JSON annotation으로 나누고 순서를 보존한다."""
    chunk = 1
    pending = []

    def payload(values):
        return {'status': 'reportDetails', **identity, 'section': section,
                'chunk': chunk, 'items': values}

    for item in items:
        if pending and annotation_size(payload(pending + [item])) > ANNOTATION_LIMIT:
            notice(payload(pending))
            chunk += 1
            pending = []
        pending.append(item)
        if annotation_size(payload(pending)) > ANNOTATION_LIMIT:
            notice(payload(pending))
            chunk += 1
            pending = []
    if pending or chunk == 1:
        notice(payload(pending))


def report_notices(report, ordinal):
    identity = {key: report[key] for key in ('file', 'process')}
    identity['ordinal'] = ordinal
    reason = {key: value for key, value in report['exceptionReason'].items() if key != 'sourceStructures'}
    first = {'status': 'reportFound', **identity, 'exceptionReason': reason}
    remaining = []
    for key in ('exception', 'termination', 'faultingThread'):
        candidate = {**first, key: report[key]}
        if annotation_size(candidate) <= ANNOTATION_LIMIT:
            first = candidate
        else:
            remaining.append({'field': key, 'value': report[key]})
    notice(first)
    if remaining:
        notice_chunks(identity, 'exceptionAndTermination', remaining)
    notice_chunks(identity, 'bodyStructure', [
        {'key': key, 'valueType': value} for key, value in report['bodyStructure'].items()])
    sources = report['exceptionReason'].get('sourceStructures', {})
    if sources:
        source_items = []
        for source, structure in sources.items():
            source_items.append({'source': source, 'valueType': structure['valueType']})
            source_items.extend({'source': source, 'key': key} for key in structure['keys'])
        notice_chunks(identity, 'exceptionReasonSourceStructures', source_items)
    last = report['lastExceptionBacktrace']
    notice_chunks(identity, 'lastExceptionBacktraceStructure', [
        {key: last[key] for key in ('status', 'valueType', 'totalFrameCount')},
        *({'key': key} for key in last['keys'])])
    for section, frames in (('faultingFrames', report['frames']),
                            ('additionalAppFrames', report['additionalAppFrames']),
                            ('lastExceptionBacktraceFrames', last['frames'])):
        notice_chunks(identity, section, frames)


def safe_label(value, limit=400):
    """symbol·system indicator만 허용한다. 경로·URL·제어문자가 섞이면 숨긴다."""
    if value is None:
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value
    if not isinstance(value, str) or '/' in value or '\\' in value or '://' in value:
        return '<redacted>'
    if not re.fullmatch(r"[A-Za-z0-9_$.:@<>\[\](), +*?!&=~|#'\-]+", value):
        return '<redacted>'
    return value[:limit] + (' [truncated]' if len(value) > limit else '')


def report_body(text):
    # 현대 ips는 header JSON 뒤에 별도의 body JSON이 올 수 있다.
    decoder = json.JSONDecoder()
    cursor = 0
    documents = []
    while cursor < len(text):
        while cursor < len(text) and text[cursor].isspace():
            cursor += 1
        if cursor == len(text):
            break
        value, cursor = decoder.raw_decode(text, cursor)
        if isinstance(value, dict):
            documents.append(value)
        if len(documents) > 4:
            raise ValueError('unexpectedDocumentCount')
    body = next((value for value in reversed(documents)
                 if any(key in value for key in ('exception', 'termination', 'threads'))), None)
    if body is None:
        raise ValueError('bodyNotRecognized')
    return body


def frame_summary(frame, images, position):
    image_index = frame.get('imageIndex')
    binary = None
    if isinstance(image_index, int) and not isinstance(image_index, bool) and 0 <= image_index < len(images):
        image = images[image_index]
        if isinstance(image, dict):
            name = image.get('name')
            if not isinstance(name, str) and isinstance(image.get('path'), str):
                name = Path(image['path']).name
            binary = safe_label(name, limit=120)
    offset = frame.get('imageOffset')
    return {'frameIndex': position,
            'imageIndex': image_index if isinstance(image_index, int) and not isinstance(image_index, bool) else None,
            'imageOffset': offset if isinstance(offset, int) and not isinstance(offset, bool) else None,
            'binary': binary, 'symbol': safe_label(frame.get('symbol'))}


def sanitized_reason(value):
    # SDK 문구 중 object description/따옴표 내용/입력값은 제거한다. 원문은 보존·출력하지 않는다.
    value = re.sub(r'<[^>]*>', '<object>', value)
    value = re.sub(r'[A-Za-z][A-Za-z0-9+.-]*://[^\s]+|\bwww\.[^\s]+', '<url>', value)
    value = re.sub(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b', '<account>', value)
    value = re.sub(r'(?:[A-Za-z]:\\|/)[^\s,;)]*', '<path>', value)
    value = re.sub(r'\b[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\b|\b0x[0-9A-Fa-f]+\b', '<identifier>', value)
    value = re.sub(r"(['\"])(.*?)(?<!\\)\1", '<quoted-text>', value)
    value = re.sub(r'(?i)\b(title|text|input|query|account|username|userInfo|email|name|value|task)\s*[:=]\s*[^,;\n]*', r'\1=<input>', value)
    value = re.sub(r'[^\x20-\x7E]+', '<text>', value)
    value = re.sub(r'\b\d{7,}\b', '<number>', value)
    value = ' '.join(value.split())
    return value[:1000] + (' [truncated]' if len(value) > 1000 else '')


def exception_reason(body, exception):
    sources = {key: body[key] for key in ('applicationSpecificInformation', 'asi') if key in body}
    candidates = []
    for container, name in ((body, '$'), (exception, '$.exception')):
        for key in ('reason', 'exceptionReason'):
            if isinstance(container.get(key), str):
                candidates.append((name + '.' + key, container[key]))
    strings = []

    def visit(value, source, depth=0):
        if depth > 8 or len(strings) >= 32:
            return
        if isinstance(value, str):
            strings.append((source, value[:16000]))
        elif isinstance(value, dict):
            for child in value.values():
                visit(child, source, depth + 1)
        elif isinstance(value, list):
            for child in value:
                visit(child, source, depth + 1)

    for key, value in sources.items():
        visit(value, key)
    name = None
    for source, text in strings:
        match = re.search(r"uncaught exception\s+['\"]([A-Za-z0-9_]+Exception)['\"]", text, re.I)
        if match and name is None:
            name = safe_label(match.group(1), limit=120)
        match = re.search(r'\breason\s*:\s*(.+)', text, re.I | re.S)
        if match:
            reason = match.group(1).strip()
            if len(reason) >= 2 and reason[0] in ('\"', "'") and reason[-1] == reason[0]:
                reason = reason[1:-1]
            candidates.append((source, reason))
    if not candidates:
        return {'status': 'absent', 'name': name, 'reason': None,
                'sourceStructures': {key: {'valueType': type(value).__name__,
                    'keys': [safe_label(key, limit=120) for key in list(value)[:16]] if isinstance(value, dict) else []} for key, value in sources.items()}}
    source, reason = candidates[0]
    return {'status': 'present', 'name': name, 'source': source, 'reason': sanitized_reason(reason)}


def structural_report(path, body):
    exception = body.get('exception')
    termination = body.get('termination')
    exception = exception if isinstance(exception, dict) else {}
    termination = termination if isinstance(termination, dict) else {}
    threads = body.get('threads')
    threads = threads if isinstance(threads, list) else []
    index = body.get('faultingThread')
    if not isinstance(index, int) or isinstance(index, bool) or not 0 <= index < len(threads):
        index = next((number for number, thread in enumerate(threads)
                      if isinstance(thread, dict) and thread.get('triggered') is True), None)
    thread = threads[index] if index is not None else {}
    frames = thread.get('frames', []) if isinstance(thread, dict) else []
    images = body.get('usedImages', [])
    images = images if isinstance(images, list) else []
    result_frames = []
    additional_app_frames = []
    for position, frame in enumerate(frames if isinstance(frames, list) else []):
        if not isinstance(frame, dict):
            continue
        details = frame_summary(frame, images, position)
        binary = details['binary']
        if position < 15:
            result_frames.append(details)
        elif binary in ('Mirror', 'Mirror.debug.dylib') and len(additional_app_frames) < 8:
            additional_app_frames.append(details)
    last = body.get('lastExceptionBacktrace')
    if isinstance(last, list):
        last_frames = last
    elif isinstance(last, dict) and isinstance(last.get('frames'), list):
        last_frames = last['frames']
    else:
        last_frames = []
    last_summary = {'status': 'absent' if last is None else 'present',
                    'valueType': type(last).__name__, 'totalFrameCount': len(last_frames),
                    'keys': [safe_label(key, limit=120) for key in list(last)[:16]] if isinstance(last, dict) else [],
                    'frames': [frame_summary(frame, images, position) for position, frame in enumerate(last_frames[:24])
                               if isinstance(frame, dict)]}
    return {'file': safe_label(path.name, limit=160), 'process': safe_label(body.get('procName'), limit=120),
            'exception': {'type': safe_label(exception.get('type')), 'signal': safe_label(exception.get('signal'))},
            'termination': {key: safe_label(termination.get(key)) for key in ('namespace', 'code', 'indicator')},
            'faultingThread': index, 'frames': result_frames,
            'additionalAppFrames': additional_app_frames,
            'bodyStructure': {safe_label(key, limit=120): type(value).__name__ for key, value in list(body.items())[:48]},
            'lastExceptionBacktrace': last_summary, 'exceptionReason': exception_reason(body, exception)}


def simulator_exception_reasons(platform, identifier, started):
    if platform == 'macos':
        return {'status': 'notApplicable', 'reasons': []}
    predicate = ('process == "Mirror" AND (eventMessage CONTAINS "uncaught exception" '
                 'OR eventMessage CONTAINS "Terminating app" OR eventMessage CONTAINS "reason:" '
                 'OR eventMessage CONTAINS "assertion failure")')
    try:
        result = subprocess.run(
            ['xcrun', 'simctl', 'spawn', identifier, 'log', 'show', '--style', 'json',
             '--last', '20m', '--predicate', predicate],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            encoding='utf-8', errors='replace', timeout=20, check=False)
        if result.returncode != 0:
            return {'status': 'unavailable', 'returnCode': result.returncode, 'reasons': []}
        entries = json.loads(result.stdout)
        if not isinstance(entries, list):
            return {'status': 'unavailable', 'errorType': 'unexpectedLogStructure', 'reasons': []}
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return {'status': 'unavailable', 'errorType': type(error).__name__, 'reasons': []}
    recent = []
    unknown_timestamps = 0
    for entry in entries:
        message = entry.get('eventMessage') if isinstance(entry, dict) else None
        if not isinstance(message, str):
            continue
        timestamp = entry.get('timestamp')
        try:
            if not isinstance(timestamp, str):
                raise ValueError('logTimestampMissing')
            recorded = datetime.fromisoformat(timestamp.replace('Z', '+00:00')).timestamp()
        except (OSError, ValueError):
            unknown_timestamps += 1
            continue
        if recorded >= started:
            recent.append((recorded, entry))
    reasons = []
    seen = set()
    for _, entry in sorted(recent, key=lambda item: item[0], reverse=True):
        message = entry['eventMessage']
        reason = exception_reason({'asi': [message]}, {})
        if reason['status'] != 'present':
            assertion = re.search(r'\bassertion failure\s*:\s*(.+)', message, re.I | re.S)
            if not assertion:
                continue
            reason = {'status': 'present', 'name': None, 'source': 'assertionFailure',
                      'reason': sanitized_reason(assertion.group(1))}
        if not reason['reason']:
            continue
        signature = (reason['name'], reason['reason'])
        if signature in seen:
            continue
        seen.add(signature)
        reasons.append(reason)
        if len(reasons) == 4:
            break
    if not reasons and unknown_timestamps:
        return {'status': 'unavailable', 'errorType': 'currentLogTimestampUnavailable', 'reasons': []}
    return {'status': 'present' if reasons else 'absent', 'reasons': reasons}


def save_summary(directory, summary):
    # structural_report와 sanitized_reason을 거친 값만 저장한다. IPS/body/log 원문은 저장하지 않는다.
    (directory / SAFE_SUMMARY_NAME).write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main():
    platform, result_path = sys.argv[1:]
    if platform not in ('macos', 'iphone', 'ipad'):
        raise ValueError('unsupportedPlatform')
    directory = Path(result_path)
    marker = directory / 'ui-start.marker'
    if not marker.is_file():
        summary = {'status': 'uiStartMarkerMissing', 'reports': []}
        save_summary(directory, summary)
        notice(summary)
        return
    started = marker.stat().st_mtime
    home = Path.home()
    locations = [home / 'Library/Logs/DiagnosticReports', Path('/Library/Logs/DiagnosticReports')]
    simulator_identifier = None
    if platform != 'macos':
        context = json.loads((directory / 'unit-context.json').read_text())
        match = re.search(r'(?:^|,)id=([A-Fa-f0-9-]{36})(?:,|$)', context.get('destination', ''))
        if match is None:
            raise ValueError('currentSimulatorNotIdentified')
        simulator_identifier = match.group(1)
        device = home / 'Library/Developer/CoreSimulator/Devices' / simulator_identifier / 'data/Library/Logs'
        locations.extend([device / 'DiagnosticReports', device / 'CrashReporter'])
    candidates = {}
    for location in locations:
        try:
            for path in location.rglob('Mirror*.ips'):
                if path.is_file() and not path.is_symlink():
                    modified = path.stat().st_mtime
                    if modified >= started:
                        candidates[path] = modified
        except OSError:
            continue
    reports = []
    unreadable = 0
    other_bundle = 0
    selected = sorted(candidates, key=candidates.get, reverse=True)[:6]
    for path in selected:
        try:
            if path.stat().st_size > 8 * 1024 * 1024:
                unreadable += 1
                continue
            body = report_body(path.read_text(encoding='utf-8-sig'))
            bundle_info = body.get('bundleInfo', {})
            bundle = bundle_info.get('CFBundleIdentifier') if isinstance(bundle_info, dict) else None
            if isinstance(bundle, str) and not (bundle == 'com.baserize.mirror' or bundle.startswith('com.baserize.mirror.')):
                other_bundle += 1
                continue
            reports.append(structural_report(path, body))
        except (OSError, UnicodeError, ValueError):
            unreadable += 1
    status = 'reportsFound' if reports else 'noCurrentMirrorReports'
    log_reasons = simulator_exception_reasons(platform, simulator_identifier, started)
    summary = {'status': status, 'reportCount': len(reports), 'unreadableReports': unreadable,
               'otherBundleReportsExcluded': other_bundle,
               'reportLimitExcluded': len(candidates) - len(selected)}
    save_summary(directory, {**summary, 'reports': reports, 'simulatorExceptionReasons': log_reasons})
    for ordinal, report in enumerate(reports, start=1):
        report_notices(report, ordinal)
    for ordinal, reason in enumerate(log_reasons['reasons'], start=1):
        notice({'status': 'simulatorExceptionReason', 'ordinal': ordinal, 'exceptionReason': reason})
    notice({'status': 'simulatorExceptionReasonCollection',
            'collection': {key: value for key, value in log_reasons.items() if key != 'reasons'},
            'reasonCount': len(log_reasons['reasons'])})
    notice({**summary, 'safeSummary': SAFE_SUMMARY_NAME})


if __name__ == '__main__':
    try:
        main()
    except (OSError, UnicodeError, ValueError) as error:
        # 예외의 원문에는 private 경로나 입력이 포함될 수 있으므로 출력하지 않는다.
        notice({'status': 'diagnosticUnavailable', 'errorType': type(error).__name__, 'reports': []})
        raise SystemExit(1) from None
