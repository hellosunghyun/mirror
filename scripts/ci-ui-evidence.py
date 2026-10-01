#!/usr/bin/env python3
"""실제 UI attachment에서 공개할 PNG만 정제하고 별도 검토 prerelease를 만든다.

xcresult 원본, 영상, 로그와 attachment JSON은 공개하지 않는다. export manifest의
지원 형태가 확인되지 않으면 문자열 값 대신 고정 키의 수와 JSON 타입만 출력한다.
이 도구는 화면의 디자인 승인이나 실제 기기 검증을 대신하지 않는다.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import html
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import sys
import tempfile
from urllib.parse import quote, urlencode, urlsplit
import zlib


PLATFORMS = ('iphone', 'ipad', 'mac')
STAGES = (
    'initial-today', 'calendar', 'settings', 'capture-form', 'review-card', 'week-picker', 'today-populated',
    'library', 'library-search', 'detail', 'detail-edit', 'completion', 'undo',
    'validation-error',
)
IPAD_STAGES = STAGES + ('ipad-landscape',)
ALL_STAGES = IPAD_STAGES
STAGE_PATTERN = '(?:' + '|'.join(re.escape(stage) for stage in sorted(ALL_STAGES, key=len, reverse=True)) + ')'
# XCTestCase.name의 module/class/method를 ASCII hyphen으로 치환한 명명 규칙이다.
METHOD_PATTERN = r'([a-z0-9]+(?:-[a-z0-9]+)*)'
SHOT_PATTERN = re.compile(r'mirror-ui-(' + STAGE_PATTERN + r')-' + METHOD_PATTERN + r'-([0-9]{1,6})')
# SDK27 export가 추가한 counter·대문자 UUID 형식만 제거한다.
SDK_UUID_PATTERN = r'[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}'
SDK_SHOT_PATTERN = re.compile(r'(' + SHOT_PATTERN.pattern + r')_[0-9]{1,6}_' + SDK_UUID_PATTERN)
PUBLIC_PNG_PATTERN = re.compile(r'mirror-ui-(iphone|ipad|mac)-(' + STAGE_PATTERN + r')-' + METHOD_PATTERN + r'-([0-9]{1,6})\.png')
SAFE_BASENAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,239}\.png')
IDENTITY_KEYS = {'commitSHA', 'buildNumber', 'runID', 'runAttempt'}
MANIFEST_KEYS = IDENTITY_KEYS | {'formatVersion', 'kind', 'platform', 'screenshots'}
AGGREGATE_KEYS = IDENTITY_KEYS | {'formatVersion', 'kind', 'platforms', 'screenshots'}
SHOT_KEYS = {'name', 'stage', 'file', 'sha256', 'bytes', 'width', 'height'}
PUBLIC_SHOT_KEYS = SHOT_KEYS | {'platform'}
PREPARE_STATIC = {'manifest.json', 'SHA256SUMS', 'index.html'}
PUBLIC_STATIC = {'ui-review-manifest.json', 'SHA256SUMS', 'ui-review.html'}
PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_PNG_BYTES = 64 * 1024 * 1024
MAX_PIXELS = 40_000_000
MAX_FILES = 10_000
MAX_SCREENSHOTS = 240
MAX_TOTAL_BYTES = 512 * 1024 * 1024
KNOWN_EXPORT_KEYS = (
    'tests', 'attachments', 'testName', 'testIdentifier', 'testIdentifierURL',
    'exportedFileName', 'suggestedHumanReadableName', 'name', 'uniformTypeIdentifier',
    'timestamp', 'isAssociatedWithFailure',
)


class EvidenceError(Exception):
    """고정 오류 코드만 전달하며 원본 값과 경로를 출력하지 않는다."""

    def __init__(self, code='invalidEvidence', metadata=None):
        super().__init__(code)
        self.code = code
        self.metadata = metadata


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise EvidenceError('invalidArguments') from None


def require(condition, code='invalidEvidence'):
    if not condition:
        raise EvidenceError(code)


def identity(sha, build_number, run_id, attempt):
    require(isinstance(sha, str) and re.fullmatch(r'[0-9a-f]{40}', sha), 'invalidArguments')
    for value in (build_number, run_id, attempt):
        require(isinstance(value, str) and re.fullmatch(r'[1-9][0-9]{0,19}', value), 'invalidArguments')
    return {'commitSHA': sha, 'buildNumber': build_number, 'runID': run_id, 'runAttempt': attempt}


def required_stages(platform):
    return IPAD_STAGES if platform == 'ipad' else STAGES


def read_regular(path, limit):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= limit)
        with os.fdopen(descriptor, 'rb') as stream:
            descriptor = None
            data = stream.read(limit + 1)
        require(0 < len(data) <= limit and len(data) == info.st_size)
        return data
    finally:
        if descriptor is not None:
            os.close(descriptor)


def directory_files(root):
    require(root.is_dir() and not root.is_symlink())
    files = []
    for directory, children, names in os.walk(root, followlinks=False):
        relative = Path(directory).relative_to(root)
        require(len(relative.parts) <= 10)
        for name in children + names:
            require(not (Path(directory) / name).is_symlink())
        files.extend(Path(directory) / name for name in names)
        require(len(files) <= MAX_FILES)
    return files


def strict_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result)
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique,
                      parse_constant=lambda _: (_ for _ in ()).throw(EvidenceError()))


def shape_summary(value):
    """알 수 없는 키명·문자열을 공개하지 않는 SDK 형식 확인용 요약이다."""
    types = {name: 0 for name in ('object', 'array', 'string', 'number', 'boolean', 'null')}
    keys = {name: 0 for name in KNOWN_EXPORT_KEYS}
    unknown = 0
    pending = [(value, 0)]
    visited = 0
    while pending:
        current, depth = pending.pop()
        visited += 1
        if visited > 100_000 or depth > 64:
            break
        kind = ('null' if current is None else 'boolean' if type(current) is bool else
                'object' if isinstance(current, dict) else 'array' if isinstance(current, list) else
                'string' if isinstance(current, str) else 'number')
        types[kind] += 1
        if isinstance(current, dict):
            for key, item in current.items():
                if key in keys:
                    keys[key] += 1
                else:
                    unknown += 1
                pending.append((item, depth + 1))
        elif isinstance(current, list):
            pending.extend((item, depth + 1) for item in current)
    return {'typeCounts': types, 'knownKeyCounts': keys, 'unknownKeyCount': unknown,
            'truncated': bool(pending)}


def canonical_attachment_name(value):
    require(isinstance(value, str) and len(value) <= 240, 'invalidAttachmentName')
    name = value[:-4] if value.endswith('.png') else value
    if SHOT_PATTERN.fullmatch(name):
        return name
    # .png가 있는 실제 SDK export만 지원하며 임의 suffix는 승인하지 않는다.
    match = SDK_SHOT_PATTERN.fullmatch(name) if value.endswith('.png') else None
    require(match is not None, 'invalidAttachmentName')
    return match[1]


def export_attachments(value):
    # SDK export의 명시적인 test-record 목록만 받는다. 임의 JSON을 재귀 검색하여
    # 그 안의 우연한 name/path 필드를 screenshot으로 승인하지 않는다.
    if isinstance(value, list):
        records = value
    elif isinstance(value, dict) and set(value) == {'tests'} and isinstance(value['tests'], list):
        records = value['tests']
    elif isinstance(value, dict) and isinstance(value.get('attachments'), list):
        records = [value]
    else:
        raise EvidenceError('unsupportedExport', shape_summary(value))
    require(records and len(records) <= MAX_FILES, 'emptyExport')
    attachments = []
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get('attachments'), list):
            raise EvidenceError('unsupportedExport', shape_summary(value))
        for attachment in record['attachments']:
            if not isinstance(attachment, dict):
                raise EvidenceError('unsupportedExport', shape_summary(value))
            human_name = attachment.get('suggestedHumanReadableName', attachment.get('name'))
            if not isinstance(human_name, str) or not human_name.startswith('mirror-ui-'):
                continue
            # 동봉한 geometry JSON은 내부 진단이다. 내용을 읽거나 공개하지 않는다.
            if human_name.startswith('mirror-ui-metadata-'):
                continue
            name = canonical_attachment_name(human_name)
            if 'name' in attachment and 'suggestedHumanReadableName' in attachment:
                require(attachment['name'] in (name, name + '.png', human_name), 'invalidAttachmentName')
            filename = attachment.get('exportedFileName')
            require(isinstance(filename, str) and SAFE_BASENAME.fullmatch(filename), 'invalidAttachmentPath')
            uti = attachment.get('uniformTypeIdentifier')
            require(uti is None or uti == 'public.png', 'invalidAttachmentType')
            attachments.append((name, filename))
            require(len(attachments) <= MAX_SCREENSHOTS)
    require(attachments, 'emptyEvidence')
    return attachments


def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def clean_icc(payload):
    """앱 screenshot의 ICC를 제한된 크기로 확인하고 색변환 바이트를 보존한다."""
    separator = payload.find(b'\0')
    require(1 <= separator <= 79 and payload[separator + 1:separator + 2] == b'\0', 'unsupportedICC')
    decoder = zlib.decompressobj()
    try:
        profile = decoder.decompress(payload[separator + 2:], 1024 * 1024 + 1)
    except zlib.error:
        raise EvidenceError('unsupportedICC') from None
    require(132 <= len(profile) <= 1024 * 1024 and decoder.eof and not decoder.unused_data
            and not decoder.unconsumed_tail, 'unsupportedICC')
    require(struct.unpack('>I', profile[:4])[0] == len(profile) and profile[36:40] == b'acsp', 'unsupportedICC')
    return payload


def clean_png(data):
    """Pixel과 검증한 색관리는 유지하고 텍스트/EXIF/임의 chunk를 제거한다."""
    require(data.startswith(PNG_SIGNATURE) and len(data) <= MAX_PNG_BYTES, 'invalidPNG')
    position, chunks, image_data = 8, [], []
    width = height = depth = color = None
    palette = transparency = False
    data_ended = ended = False
    color_chunks = set()
    while position < len(data):
        require(position + 12 <= len(data) and not ended, 'invalidPNG')
        length = struct.unpack('>I', data[position:position + 4])[0]
        require(length <= MAX_PNG_BYTES and position + length + 12 <= len(data), 'invalidPNG')
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        crc = struct.unpack('>I', data[position + 8 + length:position + 12 + length])[0]
        require(re.fullmatch(b'[A-Za-z]{4}', kind) and zlib.crc32(kind + payload) & 0xffffffff == crc, 'invalidPNG')
        require(kind[2:3].isupper(), 'invalidPNG')
        if width is None:
            require(kind == b'IHDR' and length == 13, 'invalidPNG')
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            allowed_depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
            require(0 < width <= 16384 and 0 < height <= 16384 and width * height <= MAX_PIXELS
                    and color in allowed_depths and depth in allowed_depths[color]
                    and compression == filtering == interlace == 0, 'unsupportedPNG')
        elif kind == b'IHDR':
            raise EvidenceError('invalidPNG')
        if kind == b'PLTE':
            require(not palette and not image_data and not transparency and color in (2, 3, 6)
                    and 0 < length <= 768 and length % 3 == 0, 'invalidPNG')
            require(color != 3 or length // 3 <= 2 ** depth, 'invalidPNG')
            palette = length // 3
        elif kind == b'tRNS':
            require(not transparency and not image_data and
                    ((color == 0 and length == 2) or (color == 2 and length == 6)
                     or (color == 3 and palette and 0 < length <= palette)), 'invalidPNG')
            transparency = True
        elif kind == b'IDAT':
            require(not data_ended and (color != 3 or palette), 'invalidPNG')
            image_data.append(payload)
        elif kind == b'IEND':
            require(length == 0 and image_data, 'invalidPNG')
            ended = True
        elif kind in (b'sRGB', b'gAMA', b'cHRM', b'iCCP'):
            require(not image_data and not palette and kind not in color_chunks, 'invalidPNG')
            if kind == b'sRGB':
                require(length == 1 and payload[0] <= 3 and b'iCCP' not in color_chunks, 'unsupportedPNG')
            elif kind == b'gAMA':
                require(length == 4 and 0 < struct.unpack('>I', payload)[0] <= 1_000_000, 'unsupportedPNG')
            elif kind == b'cHRM':
                require(length == 32, 'unsupportedPNG')
                coordinates = struct.unpack('>8I', payload)
                require(all(0 < y <= 100_000 and x <= 100_000 and x + y <= 100_000
                            for x, y in zip(coordinates[::2], coordinates[1::2])), 'unsupportedPNG')
            else:
                require(b'sRGB' not in color_chunks, 'unsupportedPNG')
                payload = clean_icc(payload)
                chunks.append(png_chunk(kind, payload))
            color_chunks.add(kind)
        elif kind not in (b'IHDR', b'PLTE', b'tRNS'):
            require(kind[:1].islower() and kind not in (b'acTL', b'fcTL', b'fdAT'), 'unsupportedPNG')
        if image_data and kind != b'IDAT':
            data_ended = True
        if kind in (b'IHDR', b'PLTE', b'tRNS', b'IDAT', b'IEND', b'sRGB', b'gAMA', b'cHRM'):
            chunks.append(data[position:position + length + 12])
        position += length + 12
    require(ended and width is not None, 'invalidPNG')
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    row_size = (width * channels * depth + 7) // 8 + 1
    expected_size = row_size * height
    decoder = zlib.decompressobj()
    try:
        raw = decoder.decompress(b''.join(image_data), expected_size + 1)
    except zlib.error:
        raise EvidenceError('invalidPNG') from None
    require(len(raw) == expected_size and decoder.eof and not decoder.unused_data
            and not decoder.unconsumed_tail and all(raw[index] <= 4 for index in range(0, len(raw), row_size)), 'invalidPNG')
    return PNG_SIGNATURE + b''.join(chunks), width, height


def exif_orientation(payload):
    """한정된 classic TIFF IFD0의 orientation 숫자만 읽고 원문은 반환하지 않는다.

    미지원·손상 구조와 중복 태그는 None이다. 이는 진단의 판독 범위이며 기존
    PNG 정제·수용 조건을 바꾸지 않는다. 다른 IFD와 태그 문자열은 따라가지 않는다.
    """
    if not 14 <= len(payload) <= 1024 * 1024:
        return None
    endian = '<' if payload[:2] == b'II' else '>' if payload[:2] == b'MM' else None
    if endian is None or struct.unpack_from(endian + 'H', payload, 2)[0] != 42:
        return None
    offset = struct.unpack_from(endian + 'I', payload, 4)[0]
    if offset < 8 or offset % 2 or offset + 2 > len(payload):
        return None
    count = struct.unpack_from(endian + 'H', payload, offset)[0]
    end = offset + 2 + count * 12
    if count > 256 or end + 4 > len(payload):
        return None
    next_ifd = struct.unpack_from(endian + 'I', payload, end)[0]
    if next_ifd and (next_ifd < 8 or next_ifd % 2 or next_ifd == offset
                     or next_ifd + 2 > len(payload)):
        return None
    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2,
             9: 4, 10: 8, 11: 4, 12: 8, 13: 4}
    orientation = None
    for index in range(count):
        entry = offset + 2 + index * 12
        tag, kind, items = struct.unpack_from(endian + 'HHI', payload, entry)
        if kind not in sizes or items == 0:
            return None
        size = sizes[kind] * items
        if size > 4:
            value_offset = struct.unpack_from(endian + 'I', payload, entry + 8)[0]
            if value_offset < 8 or value_offset + size > len(payload):
                return None
        if tag == 0x0112:
            if orientation is not None or kind != 3 or items != 1:
                return None
            value = struct.unpack_from(endian + 'H', payload, entry + 8)[0]
            if not 1 <= value <= 8:
                return None
            orientation = value
    return orientation


def png_provenance_parts(data):
    """clean_png가 이미 검증한 PNG의 원래 chunk payload만 비교용으로 읽는다."""
    position = 8
    ihdr = None
    idat = hashlib.sha256()
    exif_count = 0
    exif = None
    view = memoryview(data)
    while position < len(data):
        length = struct.unpack_from('>I', data, position)[0]
        kind = data[position + 4:position + 8]
        payload = view[position + 8:position + 8 + length]
        if kind == b'IHDR':
            ihdr = payload
        elif kind == b'IDAT':
            # 나뉜 모든 IDAT payload를 순서대로 연결한 SHA256이며 재압축하지 않는다.
            idat.update(payload)
        elif kind == b'eXIf':
            exif_count += 1
            if exif_count == 1 and length <= 1024 * 1024:
                exif = payload
        position += length + 12
    width, height = struct.unpack_from('>II', ihdr)
    return {'width': width, 'height': height, 'ihdrHash': digest(ihdr),
            'idatHash': idat.hexdigest(), 'exifPresent': exif_count > 0,
            'exifOrientation': exif_orientation(exif) if exif_count == 1 and exif is not None else None}


def png_provenance(exported, cleaned):
    """실제 iPad 가로 한 장의 고정 scalar/hash 진단이며 공개 자산은 추가하지 않는다."""
    original, public = png_provenance_parts(exported), png_provenance_parts(cleaned)
    return {'platform': 'ipad', 'stage': 'ipad-landscape',
            'exportWidth': original['width'], 'exportHeight': original['height'],
            'cleanWidth': public['width'], 'cleanHeight': public['height'],
            'exportPNGHash': digest(exported),
            'exportIHDRHash': original['ihdrHash'], 'cleanIHDRHash': public['ihdrHash'],
            'exportIDATHash': original['idatHash'], 'cleanIDATHash': public['idatHash'],
            'exportExifPresent': original['exifPresent'],
            'exportExifOrientation': original['exifOrientation'],
            'cleanExifPresent': public['exifPresent']}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode('utf-8')


def report(manifest, images):
    parts = ['<!doctype html><html lang="ko"><meta charset="utf-8">',
             '<meta name="viewport" content="width=device-width,initial-scale=1">',
             '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\'">',
             '<title>미러 UI 검토</title><style>body{font:16px system-ui;max-width:1200px;margin:2rem auto;padding:1rem}',
             'img{max-width:100%;height:auto;border:1px solid #bbb}figure{margin:2rem 0}code{overflow-wrap:anywhere}</style>',
             '<h1>미러 UI 검토</h1><p>실제 앱 UI 테스트에서 수집한 화면입니다. 디자인 승인과 실기기 검증은 별도입니다.</p>',
             '<p>Commit <code>' + html.escape(manifest['commitSHA']) + '</code> · Build ' + manifest['buildNumber'] +
             ' · Run ' + manifest['runID'] + ' · Attempt ' + manifest['runAttempt'] + '</p>']
    for shot in manifest['screenshots']:
        platform = shot.get('platform', manifest.get('platform'))
        label = platform + ' · ' + shot['stage']
        image_data = base64.b64encode(images[shot['file']]).decode('ascii')
        parts.append('<figure><figcaption>' + html.escape(label) + '</figcaption><img alt="' +
                     html.escape(label, quote=True) + '" src="data:image/png;base64,' + image_data + '"></figure>')
    parts.append('</html>\n')
    return ''.join(parts).encode('utf-8')


def payload(manifest, images, aggregate=False):
    manifest_name = 'ui-review-manifest.json' if aggregate else 'manifest.json'
    html_name = 'ui-review.html' if aggregate else 'index.html'
    files = {**images, manifest_name: json_bytes(manifest), html_name: report(manifest, images)}
    files['SHA256SUMS'] = ''.join(digest(data) + '  ' + name + '\n' for name, data in sorted(files.items())).encode('ascii')
    return files


def validate_manifest(manifest, expected, aggregate=False):
    keys = AGGREGATE_KEYS if aggregate else MANIFEST_KEYS
    require(isinstance(manifest, dict) and set(manifest) == keys)
    require(type(manifest['formatVersion']) is int and manifest['formatVersion'] == 1)
    require(manifest['kind'] == ('mirror-ui-review' if aggregate else 'mirror-ui-evidence'))
    require(all(manifest.get(key) == value for key, value in expected.items()), 'identityMismatch')
    if aggregate:
        require(manifest['platforms'] == list(PLATFORMS), 'platformMismatch')
    else:
        require(manifest['platform'] in PLATFORMS, 'platformMismatch')
    shots = manifest['screenshots']
    require(isinstance(shots, list) and 0 < len(shots) <= MAX_SCREENSHOTS * (3 if aggregate else 1), 'emptyEvidence')
    names, files = set(), set()
    coverage = {platform: set() for platform in (PLATFORMS if aggregate else (manifest['platform'],))}
    for shot in shots:
        require(isinstance(shot, dict) and set(shot) == (PUBLIC_SHOT_KEYS if aggregate else SHOT_KEYS))
        require(isinstance(shot['name'], str) and len(shot['name']) <= 240 and SHOT_PATTERN.fullmatch(shot['name']), 'invalidAttachmentName')
        match = SHOT_PATTERN.fullmatch(shot['name'])
        require(shot['stage'] == match[1])
        platform = shot.get('platform', manifest.get('platform'))
        require(platform in coverage, 'platformMismatch')
        require(shot['stage'] in required_stages(platform), 'invalidPlatformStage')
        require(shot['stage'] not in coverage[platform], 'duplicateStage')
        expected_file = (shot['name'].replace('mirror-ui-', 'mirror-ui-' + platform + '-', 1) + '.png'
                         if aggregate else 'screenshots/' + shot['name'] + '.png')
        require(shot['file'] == expected_file, 'invalidAttachmentPath')
        key = (platform, shot['name'])
        require(key not in names and shot['file'] not in files, 'duplicateScreenshot')
        names.add(key)
        files.add(shot['file'])
        require(isinstance(shot['sha256'], str) and re.fullmatch(r'[0-9a-f]{64}', shot['sha256']))
        require(type(shot['bytes']) is int and 0 < shot['bytes'] <= MAX_PNG_BYTES)
        require(all(type(shot[key]) is int and 0 < shot[key] <= 16384 for key in ('width', 'height')))
        coverage[platform].add(shot['stage'])
    require(all(stages == set(required_stages(platform)) for platform, stages in coverage.items()), 'missingCoverage')


def validate_directory(directory, expected, aggregate=False):
    manifest_name = 'ui-review-manifest.json' if aggregate else 'manifest.json'
    manifest = strict_json(read_regular(directory / manifest_name, MAX_JSON_BYTES))
    validate_manifest(manifest, expected, aggregate)
    images = {}
    for shot in manifest['screenshots']:
        data = read_regular(directory / shot['file'], MAX_PNG_BYTES)
        cleaned, width, height = clean_png(data)
        require(cleaned == data, 'unsafePNGMetadata')
        require((digest(data), len(data), width, height) ==
                (shot['sha256'], shot['bytes'], shot['width'], shot['height']), 'checksumMismatch')
        images[shot['file']] = data
    require(sum(map(len, images.values())) <= MAX_TOTAL_BYTES)
    expected_files = payload(manifest, images, aggregate)
    actual = {path.relative_to(directory).as_posix() for path in directory_files(directory)}
    require(actual == set(expected_files), 'unexpectedPublicFile')
    # 보고서와 manifest도 재생성한 고정 안전 바이트와 비교한다. PNG만 검증하고
    # 입력 HTML/JSON을 그대로 게시하는 우회 경로를 허용하지 않는다.
    for name, data in expected_files.items():
        require(read_regular(directory / name, max(len(data), MAX_JSON_BYTES)) == data, 'checksumMismatch')
    return manifest, expected_files


def write_directory(output, files, expected, aggregate=False):
    require(not output.is_symlink())
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        validate_directory(output, expected, aggregate)
    temporary = Path(tempfile.mkdtemp(prefix='.mirror-ui-stage-', dir=output.parent))
    backup = None
    try:
        for name, data in files.items():
            path = temporary / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        if output.exists():
            backup = Path(tempfile.mkdtemp(prefix='.mirror-ui-previous-', dir=output.parent))
            backup.rmdir()
            os.replace(output, backup)
        try:
            os.replace(temporary, output)
        except OSError:
            if backup is not None:
                os.replace(backup, output)
                backup = None
            raise
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
        if backup is not None and backup.exists():
            shutil.rmtree(backup)


def separate_paths(source, output):
    source_path, output_path = source.resolve(), output.resolve()
    require(source_path != output_path and source_path not in output_path.parents
            and output_path not in source_path.parents, 'overlappingDirectories')


def prepare(source, output, platform, expected):
    require(platform in PLATFORMS, 'platformMismatch')
    separate_paths(source, output)
    files = directory_files(source)
    manifests = [path for path in files if path.name == 'manifest.json']
    require(len(manifests) == 1, 'missingExportManifest')
    exported = strict_json(read_regular(manifests[0], MAX_JSON_BYTES))
    print('::notice::UI attachment export 구조: ' + json.dumps(shape_summary(exported), sort_keys=True))
    entries = export_attachments(exported)
    by_basename = {}
    for path in files:
        by_basename.setdefault(path.name, []).append(path)
    images, shots, used_names, used_exports = {}, [], set(), set()
    landscape_provenance = None
    for name, basename in entries:
        require(name not in used_names and basename not in used_exports, 'duplicateScreenshot')
        used_names.add(name)
        used_exports.add(basename)
        candidates = by_basename.get(basename, [])
        require(len(candidates) == 1, 'missingScreenshot')
        exported_data = read_regular(candidates[0], MAX_PNG_BYTES)
        data, width, height = clean_png(exported_data)
        if platform == 'ipad' and SHOT_PATTERN.fullmatch(name)[1] == 'ipad-landscape':
            landscape_provenance = png_provenance(exported_data, data)
        filename = 'screenshots/' + name + '.png'
        images[filename] = data
        shots.append({'name': name, 'stage': SHOT_PATTERN.fullmatch(name)[1], 'file': filename,
                      'sha256': digest(data), 'bytes': len(data), 'width': width, 'height': height})
    require(sum(map(len, images.values())) <= MAX_TOTAL_BYTES)
    manifest = {**expected, 'formatVersion': 1, 'kind': 'mirror-ui-evidence', 'platform': platform,
                'screenshots': sorted(shots, key=lambda shot: (ALL_STAGES.index(shot['stage']), shot['name']))}
    validate_manifest(manifest, expected)
    write_directory(output, payload(manifest, images), expected)
    if landscape_provenance is not None:
        print('::notice::UI PNG provenance diagnostic: ' + json.dumps(landscape_provenance, sort_keys=True))
    return manifest


def aggregate(source, output, expected):
    separate_paths(source, output)
    manifests = [path for path in directory_files(source) if path.name == 'manifest.json']
    require(len(manifests) == len(PLATFORMS), 'missingPlatforms')
    platforms, images, shots = set(), {}, []
    for path in sorted(manifests):
        manifest, files = validate_directory(path.parent, expected)
        platform = manifest['platform']
        require(platform not in platforms, 'duplicatePlatform')
        platforms.add(platform)
        for shot in manifest['screenshots']:
            filename = shot['name'].replace('mirror-ui-', 'mirror-ui-' + platform + '-', 1) + '.png'
            images[filename] = files[shot['file']]
            shots.append({**shot, 'platform': platform, 'file': filename})
    require(platforms == set(PLATFORMS), 'missingPlatforms')
    require(sum(map(len, images.values())) <= MAX_TOTAL_BYTES)
    manifest = {**expected, 'formatVersion': 1, 'kind': 'mirror-ui-review', 'platforms': list(PLATFORMS),
                'screenshots': sorted(shots, key=lambda shot: (PLATFORMS.index(shot['platform']),
                                                             ALL_STAGES.index(shot['stage']), shot['name']))}
    validate_manifest(manifest, expected, aggregate=True)
    write_directory(output, payload(manifest, images, aggregate=True), expected, aggregate=True)
    return manifest


def github_class():
    # 기존 배포 helper의 allowlisted GitHub 호스트·tag SHA 검증을 재사용한다.
    spec = importlib.util.spec_from_file_location('mirror_ui_github', Path(__file__).with_name('ci-publish-adhoc.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.GitHub


def release_notes(expected):
    return ('<!-- mirror-ui-review run:' + expected['runID'] + ' sha:' + expected['commitSHA'] +
            ' build:' + expected['buildNumber'] + ' -->\n'
            'iPhone · iPad · Mac 실제 UI 화면 검토 자료입니다.\n\n'
            'Build ' + expected['buildNumber'] + ' · Attempt ' + expected['runAttempt'] +
            '\n\nui-review.html을 내려받으면 PNG가 포함된 전체 보고서를 열 수 있습니다. '
            '디자인 승인과 실기기 검증은 별도입니다.\n')


def validate_remote_assets(assets, files=None):
    require(isinstance(assets, list) and len(assets) <= MAX_SCREENSHOTS * 3 + len(PUBLIC_STATIC), 'invalidRelease')
    seen = set()
    for asset in assets:
        require(isinstance(asset, dict), 'invalidRelease')
        name = asset.get('name')
        require(isinstance(name, str) and len(name) <= 255
                and (name in PUBLIC_STATIC or PUBLIC_PNG_PATTERN.fullmatch(name)), 'unexpectedReleaseAsset')
        if name not in PUBLIC_STATIC:
            match = PUBLIC_PNG_PATTERN.fullmatch(name)
            require(match[2] in required_stages(match[1]), 'unexpectedReleaseAsset')
        require(name not in seen and type(asset.get('id')) is int and asset['id'] > 0
                and type(asset.get('size')) is int and asset['size'] > 0
                and isinstance(asset.get('digest'), str) and re.fullmatch(r'sha256:[0-9a-f]{64}', asset['digest']), 'invalidReleaseAsset')
        seen.add(name)
        if files is not None:
            require(name in files and asset['size'] == len(files[name])
                    and asset['digest'] == 'sha256:' + digest(files[name]), 'uploadedAssetMismatch')
    if files is not None:
        require(seen == set(files), 'missingReleaseAsset')


def release_url(value):
    require(isinstance(value, str), 'invalidRelease')
    parsed = urlsplit(value)
    require(parsed.scheme == 'https' and parsed.netloc == 'github.com' and not parsed.query
            and not parsed.fragment and re.fullmatch(r'/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/tag/ui-review-[1-9][0-9]*', parsed.path), 'invalidRelease')
    return value


def publish(client, directory, expected):
    # 네트워크 요청 전에 모든 공개 바이트를 다시 검증하고 메모리에 고정한다.
    manifest, files = validate_directory(directory, expected, aggregate=True)
    tag = 'ui-review-' + expected['runID']
    release = client.request('GET', '/releases/tags/' + quote(tag, safe=''), missing_ok=True)
    tag_exists = client.verify_tag(tag, expected['commitSHA'])
    notes = release_notes(expected)
    attributes = {'tag_name': tag, 'target_commitish': expected['commitSHA'], 'prerelease': True,
                  'make_latest': 'false', 'name': '미러 UI 검토 ' + expected['buildNumber'], 'body': notes}
    if release is not None:
        require(isinstance(release, dict) and release.get('tag_name') == tag
                and type(release.get('id')) is int and release['id'] > 0, 'invalidRelease')
        require(tag_exists or release.get('target_commitish') == expected['commitSHA'], 'identityMismatch')
        marker = notes.split('\n', 1)[0]
        require(isinstance(release.get('body'), str) and marker in release['body']
                and (release.get('draft') is True or release.get('prerelease') is True), 'unexpectedRelease')
        validate_remote_assets(release.get('assets'))
        assets = release['assets']
        same_assets = (len(assets) == len(files) and all(asset['name'] in files and
                       asset['size'] == len(files[asset['name']]) and
                       asset['digest'] == 'sha256:' + digest(files[asset['name']]) for asset in assets))
        if same_assets and tag_exists and release.get('draft') is False:
            published = client.request('PATCH', '/releases/' + str(release['id']), value={**attributes, 'draft': False})
            require(published.get('draft') is False and published.get('prerelease') is True
                    and client.verify_tag(tag, expected['commitSHA']), 'invalidRelease')
            return release_url(published.get('html_url'))
        release = client.request('PATCH', '/releases/' + str(release['id']), value={**attributes, 'draft': True})
    else:
        release = client.request('POST', '/releases', value={**attributes, 'draft': True})
    require(isinstance(release, dict) and type(release.get('id')) is int and release['id'] > 0
            and release.get('draft') is True, 'invalidRelease')
    release_id = release['id']
    validate_remote_assets(release.get('assets', []))
    for asset in release.get('assets', []):
        client.request('DELETE', '/releases/assets/' + str(asset['id']))
    upload_url = release.get('upload_url')
    require(isinstance(upload_url, str) and urlsplit(upload_url).scheme == 'https'
            and urlsplit(upload_url).hostname == 'uploads.github.com', 'invalidRelease')
    upload_url = upload_url.split('{', 1)[0]
    for name, data in sorted(files.items()):
        content_type = 'image/png' if name.endswith('.png') else 'text/html' if name.endswith('.html') else 'application/octet-stream'
        uploaded = client.request('POST', upload_url + '?' + urlencode({'name': name}), content=data, content_type=content_type)
        validate_remote_assets([uploaded], {name: data})
    refreshed = client.request('GET', '/releases/' + str(release_id))
    require(isinstance(refreshed, dict), 'invalidRelease')
    validate_remote_assets(refreshed.get('assets'), files)
    published = client.request('PATCH', '/releases/' + str(release_id), value={**attributes, 'draft': False})
    require(published.get('draft') is False and published.get('prerelease') is True
            and client.verify_tag(tag, expected['commitSHA']), 'invalidRelease')
    return release_url(published.get('html_url'))


def main(argv=None):
    command = None
    try:
        parser = SafeArgumentParser(description=__doc__)
        commands = parser.add_subparsers(dest='command', required=True, parser_class=SafeArgumentParser)
        for name in ('prepare', 'aggregate', 'publish'):
            subparser = commands.add_parser(name)
            subparser.add_argument('--sha', required=True)
            subparser.add_argument('--build-number', required=True)
            subparser.add_argument('--run-id', required=True)
            subparser.add_argument('--attempt', required=True)
            if name == 'prepare':
                subparser.add_argument('--input', type=Path, required=True)
                subparser.add_argument('--platform', choices=PLATFORMS, required=True)
            elif name == 'aggregate':
                subparser.add_argument('--input-root', type=Path, required=True)
            else:
                subparser.add_argument('--publish-dir', type=Path, required=True)
            if name != 'publish':
                subparser.add_argument('--output', type=Path, required=True)
        args = parser.parse_args(argv)
        command = args.command
        expected = identity(args.sha, args.build_number, args.run_id, args.attempt)
        if command == 'prepare':
            manifest = prepare(args.input, args.output, args.platform, expected)
        elif command == 'aggregate':
            manifest = aggregate(args.input_root, args.output, expected)
        else:
            repository, token = os.environ.get('GITHUB_REPOSITORY'), os.environ.get('GITHUB_TOKEN')
            require(isinstance(repository, str) and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository)
                    and token, 'missingGitHubContext')
            url = publish(github_class()(repository, token), args.publish_dir, expected)
            github_output = os.environ.get('GITHUB_OUTPUT')
            if github_output:
                with open(github_output, 'a', encoding='utf-8') as destination:
                    destination.write('ui_review_url=' + url + '\n')
            print(json.dumps({'command': command, 'status': 'published', 'url': url}, sort_keys=True))
            return 0
        print(json.dumps({'command': command, 'status': 'prepared' if command == 'prepare' else 'aggregated',
                          'screenshotCount': len(manifest['screenshots'])}, sort_keys=True))
        return 0
    except EvidenceError as error:
        summary = {'command': command, 'status': error.code}
        if error.metadata is not None:
            summary['metadata'] = error.metadata
            print('::error::UI attachment export 구조 미확인: ' + json.dumps(error.metadata, sort_keys=True))
        print('::error::UI 화면 증거 검증 실패: ' + error.code)
        print(json.dumps(summary, sort_keys=True))
        return 1
    except Exception:
        # SDK JSON/IO/API 예외 메시지에는 비공개 원문·경로·토큰이 들어갈 수 있다.
        print('::error::UI 화면 증거 처리 실패: processingFailed')
        print(json.dumps({'command': command, 'status': 'processingFailed'}, sort_keys=True))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
