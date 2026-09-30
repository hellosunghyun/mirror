#!/usr/bin/env python3
"""빌드된 앱의 실제 확장·권한 설명·개인정보 고지를 검사한다."""

import json
import plistlib
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
    print(json.dumps({'app': info['CFBundleIdentifier'], 'embeddedExtensions': extensions,
                      'capabilityState': info.get('MirrorCapabilityConfigurationState'),
                      'signedSharingVerified': False}, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        escaped = str(error).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print(f'::error::{escaped}')
        raise SystemExit(1) from error
