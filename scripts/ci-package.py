#!/usr/bin/env python3
"""빌드된 앱의 실제 확장·권한 설명·개인정보 고지를 검사한다."""

import json
import plistlib
import re
import sys
from pathlib import Path


def bundle_info(bundle):
    candidates = [bundle / 'Info.plist', bundle / 'Contents/Info.plist']
    path = next((value for value in candidates if value.is_file()), None)
    if path is None:
        raise ValueError(f'{bundle.name}: 빌드된 Info.plist를 찾지 못했습니다.')
    return plistlib.loads(path.read_bytes())


def resource(bundle, filename):
    return (bundle / filename).is_file() or (bundle / 'Contents/Resources' / filename).is_file()


def annotation(level, message):
    escaped = str(message).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    print(f'::{level}::{escaped}')


def structure_summary(value):
    """값·번역문·parameter payload를 노출하지 않고 관측된 구조만 남긴다."""
    if isinstance(value, dict):
        return {'rootType': 'object', 'keys': [str(key)[:80] for key in list(value)[:32]]}
    if isinstance(value, list):
        return {'rootType': 'array', 'length': len(value),
                'elementTypes': sorted({type(item).__name__ for item in value})[:8]}
    return {'rootType': type(value).__name__}


def action_containers(value):
    """알 수 있는 collection만 센다. 미관측 형식은 0이라는 추측으로 바꾸지 않는다."""
    if isinstance(value, dict) and 'actions' in value:
        collection = value['actions']
        if not isinstance(collection, (dict, list)):
            raise ValueError('actions metadata의 actions가 collection이 아닙니다.')
        if collection and not all(isinstance(item, dict) and item for item in
                                  (collection.values() if isinstance(collection, dict) else collection)):
            raise ValueError('actions metadata collection의 항목 구조를 확인할 수 없습니다.')
        return [{'path': '$.actions', 'entryCount': len(collection)}]
    if isinstance(value, list):
        if value and not all(isinstance(item, dict) and item for item in value):
            raise ValueError('actions metadata 배열의 항목 구조를 확인할 수 없습니다.')
        return [{'path': '$', 'entryCount': len(value)}]
    # Xcode가 actions.data를 qualified type name -> action object map으로 쓸 때만 허용한다.
    # version/table 등의 일반 object를 action 한 개로 세지 않는다.
    if isinstance(value, dict) and value and all(
        re.fullmatch(r'[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)+', key)
        and isinstance(item, dict) and item for key, item in value.items()
    ):
        return [{'path': '$ (qualified action map)', 'entryCount': len(value)}]
    if value == {}:
        return [{'path': '$', 'entryCount': 0}]
    return []


def inspect_app_intents(app):
    # 확장의 metadata를 앱 metadata로 대신 인정하지 않는다.
    candidates = [app / 'Metadata.appintents', app / 'Contents/Resources/Metadata.appintents',
                  app / 'Contents/Metadata.appintents']
    directories = [path for path in candidates if path.is_dir()]
    if len(directories) != 1:
        raise ValueError('앱에서 고유한 Metadata.appintents directory를 찾지 못했습니다.')
    directory = directories[0]
    files = sorted(path for path in directory.rglob('*') if path.is_file())
    if not files:
        raise ValueError('앱 Metadata.appintents directory가 비어 있습니다.')
    reports = []
    action_reports = []
    problems = []
    for path in files:
        report = {'file': str(path.relative_to(directory)), 'bytes': path.stat().st_size}
        reports.append(report)
        if report['bytes'] == 0:
            report['format'] = 'empty'
            continue
        # 의도/문구 원문은 출력하지 않는다. 작은 구조 파일만 해석하고 크기를 기록한다.
        if report['bytes'] > 8 * 1024 * 1024:
            report['format'] = 'sizeLimitExceeded'
            continue
        raw = path.read_bytes()
        try:
            value = json.loads(raw)
            report['format'] = 'json'
        except (UnicodeDecodeError, json.JSONDecodeError):
            try:
                value = plistlib.loads(raw)
                report['format'] = 'plist'
            except (plistlib.InvalidFileException, ValueError, OverflowError):
                report['format'] = 'unrecognized'
                continue
        report.update(structure_summary(value))
        if path.name.lower() in ('actions.data', 'actions.json', 'actions.plist'):
            try:
                containers = action_containers(value)
                report['actionContainers'] = containers
                action_reports.extend(containers)
                if not containers:
                    problems.append('actions 파일의 관측된 구조를 아직 해석할 수 없습니다.')
            except ValueError as error:
                report['actionStructure'] = 'unrecognized'
                problems.append(str(error))
    # 이 notice는 Actions check annotations에서도 읽을 수 있다. 문자열 값은 포함하지 않는다.
    summary = {'bundle': app.name, 'directory': str(directory.relative_to(app)), 'files': reports,
               'actionContainers': action_reports}
    annotation('notice', 'App Intents metadata: ' + json.dumps(summary, ensure_ascii=False))
    if problems:
        raise ValueError(' '.join(problems))
    if not action_reports:
        raise ValueError('앱 metadata에서 해석 가능한 actions collection을 확인하지 못했습니다. 파일 구조 진단을 확인하세요.')
    if any(report['entryCount'] <= 0 for report in action_reports):
        raise ValueError('앱 metadata의 actions collection이 비어 있습니다.')
    return summary


def main():
    platform, derived_path = sys.argv[1:]
    products = 'Debug' if platform == 'macos' else 'Debug-iphonesimulator'
    app = Path(derived_path) / 'Build/Products' / products / 'Mirror.app'
    info = bundle_info(app)
    if not str(info.get('CFBundleIdentifier', '')).startswith('com.baserize.mirror'):
        raise ValueError('앱 Bundle ID가 개발 기준과 다릅니다.')
    if not info.get('NSCalendarsFullAccessUsageDescription'):
        raise ValueError('캘린더 full-access 사용 설명이 앱에 없습니다.')
    schemes = {scheme for value in info.get('CFBundleURLTypes', []) for scheme in value.get('CFBundleURLSchemes', [])}
    if 'mirror' not in schemes:
        raise ValueError('탐색용 mirror URL scheme이 앱에 없습니다.')
    for name in ['PrivacyInfo.xcprivacy', 'LICENSE.swiftpieces', 'PROVENANCE.md']:
        if not resource(app, name):
            raise ValueError(f'{name}: 앱에 실제 고지 resource가 없습니다.')
    plugins = app / ('Contents/PlugIns' if platform == 'macos' else 'PlugIns')
    extensions = {}
    for bundle in plugins.glob('*.appex'):
        extension_info = bundle_info(bundle)
        point = extension_info.get('NSExtension', {}).get('NSExtensionPointIdentifier')
        extensions[point] = bundle.name
        if not resource(bundle, 'PrivacyInfo.xcprivacy'):
            raise ValueError(f'{bundle.name}: PrivacyInfo resource가 없습니다.')
    for point in ['com.apple.widgetkit-extension', 'com.apple.share-services']:
        if point not in extensions:
            raise ValueError(f'{point}: 앱의 실제 PlugIns에 확장이 없습니다.')
    metadata = inspect_app_intents(app)
    print(json.dumps({'app': info['CFBundleIdentifier'], 'embeddedExtensions': extensions,
                      'appIntentsMetadata': metadata,
                      'capabilityState': info.get('MirrorCapabilityConfigurationState'),
                      'signedSharingVerified': False}, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        annotation('error', error)
        raise SystemExit(1) from error
