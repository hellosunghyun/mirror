#!/usr/bin/env python3
"""검증한 Mac 공개 자산만 같은 run의 기존 iOS prerelease에 추가한다.

서명·공증·staple·Gatekeeper 실제 검사는 macOS 생산 단계에서 수행한다.
이 게시 단계는 그 검증 결과, 현재 실행 식별자와 파일/API 해시를 확인한다.
iOS 공개 Release가 없으면 API 쓰기 없이 실패하며 iOS 자산은 삭제하지 않는다.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import quote, urlencode, urlsplit


# iOS 게시와 같은 인증·허용 호스트·timeout·고정 오류 메시지를 사용한다.
_SPEC = importlib.util.spec_from_file_location('mirror_macos_github_transport',
                                              Path(__file__).with_name('ci-publish-adhoc.py'))
_transport = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_transport)
GitHub = _transport.GitHub
PublishError = _transport.PublishError

ASSET_NAMES = {'Mirror-macOS.dmg', 'macos-build-manifest.json',
               'macos-SHA256SUMS', 'macos-release-notes.md'}
IOS_ASSET_NAMES = {'Mirror.ipa', 'build-manifest.json', 'SHA256SUMS', 'release-notes.md'}
CHECKSUM_NAMES = ASSET_NAMES - {'macos-SHA256SUMS'}
MAC_SECTION_MARKER = '<!-- mirror-macos-release -->'
REQUIRED_MANIFEST_KEYS = {
    'result', 'distribution', 'platform', 'commitSHA', 'buildNumber', 'runID',
    'version', 'xcodeVersion', 'sdkVersion', 'minimumOS', 'architectures',
    'dmgSHA256', 'dmgBytes', 'targets', 'verification',
}
PUBLIC_MANIFEST_KEYS = REQUIRED_MANIFEST_KEYS | {'schemaVersion', 'certificateType'}
VERIFICATION_KEYS = {'codesign', 'hardenedRuntime', 'notarization', 'stapled',
                     'gatekeeper', 'versionAndBuild', 'getTaskAllow'}
EXPECTED_TARGETS = {
    'MirrorMac': 'com.baserize.mirror.mac',
    'MirrorWidgetsMac': 'com.baserize.mirror.mac.widgets',
    'MirrorShareMac': 'com.baserize.mirror.mac.share',
}


def require(condition, message):
    if not condition:
        raise PublishError(message)


def validate_manifest_keys(manifest):
    require(isinstance(manifest, dict) and REQUIRED_MANIFEST_KEYS <= set(manifest)
            and set(manifest) <= PUBLIC_MANIFEST_KEYS,
            'Mac manifest의 공개 필드가 유효하지 않습니다.')
    verification = manifest.get('verification')
    require(isinstance(verification, dict) and set(verification) == VERIFICATION_KEYS
            and all(type(value) is bool for value in verification.values()),
            'Mac manifest의 공개 검증 필드가 유효하지 않습니다.')
    require(all(verification[key] is True for key in VERIFICATION_KEYS - {'getTaskAllow'})
            and verification['getTaskAllow'] is False,
            '실제 서명·공증·staple·Gatekeeper 검사를 완료한 Mac 산출물만 게시할 수 있습니다.')
    require(manifest['result'] == 'pass' and manifest['distribution'] == 'developer-id'
            and manifest['platform'] == 'macOS', 'Developer ID Mac 배포 결과만 게시할 수 있습니다.')
    require(manifest['minimumOS'] == '27.0' and manifest['architectures'] == ['arm64'],
            'Mac 배포의 OS 또는 아키텍처가 확정 기준과 다릅니다.')
    for key in ('version', 'xcodeVersion', 'sdkVersion'):
        require(isinstance(manifest[key], str)
                and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', manifest[key]) is not None,
                'Mac manifest의 공개 버전 값이 유효하지 않습니다.')
    require(isinstance(manifest['commitSHA'], str)
            and re.fullmatch(r'[0-9a-f]{40}', manifest['commitSHA']) is not None,
            'Mac manifest의 commit 형식이 유효하지 않습니다.')
    for key in ('buildNumber', 'runID'):
        require(type(manifest[key]) in (str, int)
                and re.fullmatch(r'[1-9][0-9]*', str(manifest[key])) is not None,
                'Mac manifest의 실행 번호가 유효하지 않습니다.')
    require(isinstance(manifest['dmgSHA256'], str)
            and re.fullmatch(r'[0-9a-f]{64}', manifest['dmgSHA256']) is not None
            and type(manifest['dmgBytes']) is int and manifest['dmgBytes'] > 0,
            'Mac manifest의 DMG 해시 또는 크기가 유효하지 않습니다.')
    require('schemaVersion' not in manifest
            or (type(manifest['schemaVersion']) is int and manifest['schemaVersion'] == 1),
            'Mac manifest의 schema가 유효하지 않습니다.')
    require('certificateType' not in manifest or manifest['certificateType'] == 'Developer ID Application',
            'Mac manifest의 인증서 용도 분류가 유효하지 않습니다.')
    targets = manifest['targets']
    require(isinstance(targets, list) and len(targets) == len(EXPECTED_TARGETS),
            'Mac manifest의 공개 target 필드가 유효하지 않습니다.')
    found = {}
    for target in targets:
        require(isinstance(target, dict) and set(target) == {'name', 'bundleIdentifier'}
                and isinstance(target.get('name'), str) and isinstance(target.get('bundleIdentifier'), str)
                and target['name'] not in found, 'Mac manifest의 공개 target 필드가 유효하지 않습니다.')
        found[target['name']] = target['bundleIdentifier']
    require(found == EXPECTED_TARGETS, 'Mac manifest의 앱·확장 대상이 확정 기준과 다릅니다.')


def validate_assets(directory, commit, run_number, run_id):
    require(directory.is_dir() and {path.name for path in directory.iterdir()} == ASSET_NAMES,
            'Mac 게시 폴더에는 허용한 공개 산출물 네 개만 있어야 합니다.')
    for name in ASSET_NAMES:
        path = directory / name
        require(not path.is_symlink() and path.is_file() and path.stat().st_size > 0,
                'Mac 게시 산출물이 없거나 일반 파일이 아닙니다.')
    try:
        manifest = json.loads((directory / 'macos-build-manifest.json').read_text(encoding='utf-8'))
        (directory / 'macos-release-notes.md').read_text(encoding='utf-8')
        checksums = {}
        for line in (directory / 'macos-SHA256SUMS').read_text(encoding='ascii').splitlines():
            match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_.-]+)', line)
            require(match is not None and match[2] in CHECKSUM_NAMES and match[2] not in checksums,
                    'macos-SHA256SUMS 형식이 유효하지 않습니다.')
            checksums[match[2]] = match[1]
        require(set(checksums) == CHECKSUM_NAMES, 'Mac 체크섬이 모든 공개 파일을 포함해야 합니다.')
    except (OSError, UnicodeError, ValueError):
        raise PublishError('Mac manifest와 체크섬을 읽을 수 없습니다.') from None
    validate_manifest_keys(manifest)
    hashes = {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in ASSET_NAMES}
    require(all(hashes[name] == value for name, value in checksums.items()),
            'Mac 게시 산출물의 SHA-256이 일치하지 않습니다.')
    require(manifest['commitSHA'] == commit and str(manifest['buildNumber']) == run_number
            and str(manifest['runID']) == run_id, 'Mac manifest의 commit/run/build가 현재 실행과 다릅니다.')
    dmg = directory / 'Mirror-macOS.dmg'
    require(manifest['dmgSHA256'] == hashes[dmg.name] and manifest['dmgBytes'] == dmg.stat().st_size,
            'Mac manifest의 DMG SHA-256 또는 크기가 다릅니다.')
    # hdiutil이 만든 UDIF의 고정 trailer만 확인한다. 실제 이미지/서명 검사를 대체하지 않는다.
    require(dmg.stat().st_size >= 512, 'Mac 산출물의 DMG 형식이 유효하지 않습니다.')
    with dmg.open('rb') as stream:
        stream.seek(-512, os.SEEK_END)
        require(stream.read(4) == b'koly', 'Mac 산출물의 DMG 형식이 유효하지 않습니다.')
    return manifest, hashes


def release_assets(release, tag):
    require(isinstance(release, dict) and release.get('tag_name') == tag
            and release.get('draft') is False and release.get('prerelease') is True
            and type(release.get('id')) is int and release['id'] > 0,
            '같은 실행의 기존 공개 iOS prerelease가 필요합니다.')
    assets = release.get('assets')
    require(isinstance(assets, list), 'Release 자산 정보를 확인할 수 없습니다.')
    found = {}
    asset_ids = set()
    for asset in assets:
        require(isinstance(asset, dict) and asset.get('name') in IOS_ASSET_NAMES | ASSET_NAMES
                and asset['name'] not in found and type(asset.get('id')) is int and asset['id'] > 0
                and asset['id'] not in asset_ids,
                'Release에 예상하지 않은 자산 또는 중복 자산이 있습니다.')
        found[asset['name']] = asset
        asset_ids.add(asset['id'])
    require(IOS_ASSET_NAMES <= set(found), '기존 공개 iOS 자산 네 개가 있어야 Mac 자산을 추가할 수 있습니다.')
    for name in IOS_ASSET_NAMES:
        asset = found[name]
        require(type(asset.get('size')) is int and asset['size'] > 0
                and isinstance(asset.get('digest'), str)
                and re.fullmatch(r'sha256:[0-9a-f]{64}', asset['digest']) is not None
                and asset.get('state') == 'uploaded', '기존 iOS 자산의 해시·크기·업로드 상태를 확인할 수 없습니다.')
    return found


def ios_snapshot(assets):
    return {name: (assets[name]['id'], assets[name]['size'], assets[name]['digest'], assets[name]['state'])
            for name in IOS_ASSET_NAMES}


def asset_matches(asset, name, directory, hashes):
    return (isinstance(asset, dict) and asset.get('name') == name and asset.get('state') == 'uploaded'
            and type(asset.get('size')) is int and asset['size'] == (directory / name).stat().st_size
            and asset.get('digest') == 'sha256:' + hashes[name])


def macos_release_body(body, notes):
    require(isinstance(body, str) and body.count(MAC_SECTION_MARKER) <= 1
            and MAC_SECTION_MARKER not in notes, 'Release 본문의 Mac 섹션 형식이 유효하지 않습니다.')
    ios_body = body.partition(MAC_SECTION_MARKER)[0].rstrip()
    return ios_body + '\n\n' + MAC_SECTION_MARKER + '\n' + notes.rstrip() + '\n'


def verify_final_assets(release, tag, release_id, preserved_ios, directory, hashes):
    assets = release_assets(release, tag)
    require(release['id'] == release_id and set(assets) == IOS_ASSET_NAMES | ASSET_NAMES,
            '최종 Release에 iOS·Mac 공개 자산 여덟 개가 모두 있어야 합니다.')
    require(ios_snapshot(assets) == preserved_ios, '기존 iOS 자산이 Mac 게시 중 변경되었습니다.')
    require(all(asset_matches(assets[name], name, directory, hashes) for name in ASSET_NAMES),
            '게시한 Mac 자산의 최종 SHA-256 검증에 실패했습니다.')


def publish(client, directory, manifest, hashes, commit, run_id):
    tag = 'adhoc-' + run_id
    repository = client.request('GET', '')
    require(isinstance(repository, dict) and repository.get('private') is False,
            '공개 저장소의 iOS prerelease에만 Mac 자산을 추가합니다.')
    release = client.request('GET', '/releases/tags/' + quote(tag, safe=''), missing_ok=True)
    assets = release_assets(release, tag)
    require(client.verify_tag(tag, commit), '기존 iOS release 태그의 commit을 확인할 수 없습니다.')
    notes = (directory / 'macos-release-notes.md').read_text(encoding='utf-8')
    macos_release_body(release.get('body'), notes)
    preserved_ios = ios_snapshot(assets)
    release_id = release['id']
    upload_url = release.get('upload_url')
    require(isinstance(upload_url, str) and urlsplit(upload_url).hostname == 'uploads.github.com',
            'Mac 자산 업로드 주소를 확인할 수 없습니다.')
    upload_url = upload_url.split('{', 1)[0]
    expected_upload_url = client.base.replace('https://api.github.com/', 'https://uploads.github.com/') + f'/releases/{release_id}/assets'
    require(upload_url == expected_upload_url, 'Mac 자산 업로드 대상이 현재 Release와 다릅니다.')
    # 이미 공개된 iOS release를 숨기거나 iOS 자산을 교체하지 않는다.
    # Release API는 자산별 쓰기이므로 업로드 도중에는 일부 Mac 자산만 보일 수 있다.
    for name in sorted(ASSET_NAMES):
        existing = assets.get(name)
        if asset_matches(existing, name, directory, hashes):
            continue
        if existing is not None:
            client.request('DELETE', f"/releases/assets/{existing['id']}")
        uploaded = client.request('POST', upload_url + '?' + urlencode({'name': name}),
                                  content=(directory / name).read_bytes(),
                                  content_type='application/octet-stream')
        require(asset_matches(uploaded, name, directory, hashes),
                '업로드한 Mac 자산의 이름·크기·SHA-256·상태가 다릅니다.')
    refreshed = client.request('GET', f'/releases/{release_id}')
    verify_final_assets(refreshed, tag, release_id, preserved_ios, directory, hashes)
    require(client.verify_tag(tag, commit), '게시 후 Release 태그의 commit을 확인할 수 없습니다.')
    desired_body = macos_release_body(refreshed.get('body'), notes)
    if refreshed['body'] != desired_body:
        refreshed = client.request('PATCH', f'/releases/{release_id}', value={'body': desired_body})
        verify_final_assets(refreshed, tag, release_id, preserved_ios, directory, hashes)
        require(refreshed.get('body') == desired_body, 'Release의 Mac 배포 안내를 확인할 수 없습니다.')
        require(client.verify_tag(tag, commit), '본문 갱신 후 Release 태그의 commit을 확인할 수 없습니다.')
    url = refreshed.get('html_url')
    expected_url = client.base.replace('https://api.github.com/repos/', 'https://github.com/') + '/releases/tag/' + tag
    require(url == expected_url, '공개 Release 주소를 확인할 수 없습니다.')
    return url


class PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise PublishError('Mac 게시 인자 형식이 유효하지 않습니다.') from None


def main(argv=None):
    try:
        parser = PrivateArgumentParser(prog='ci-macos-release', add_help=False)
        parser.add_argument('--publish-dir', type=Path, required=True)
        parser.add_argument('--commit-sha', required=True)
        parser.add_argument('--run-number', required=True)
        parser.add_argument('--run-id', required=True)
        parser.add_argument('--repository', default=os.environ.get('GITHUB_REPOSITORY'))
        args = parser.parse_args(argv)
        require(re.fullmatch(r'[0-9a-f]{40}', args.commit_sha) is not None
                and re.fullmatch(r'[1-9][0-9]*', args.run_number) is not None
                and re.fullmatch(r'[1-9][0-9]*', args.run_id) is not None
                and isinstance(args.repository, str)
                and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository) is not None,
                'Mac repository, commit, run 번호 형식이 유효하지 않습니다.')
        token = os.environ.get('GITHUB_TOKEN')
        require(bool(token), 'Actions GITHUB_TOKEN이 필요합니다.')
        manifest, hashes = validate_assets(args.publish_dir, args.commit_sha, args.run_number, args.run_id)
        url = publish(GitHub(args.repository, token), args.publish_dir, manifest, hashes, args.commit_sha, args.run_id)
        output = os.environ.get('GITHUB_OUTPUT')
        if output:
            with open(output, 'a', encoding='utf-8') as destination:
                destination.write(f'macos_release_url={url}\n')
        print('검증한 Mac 자산 네 개를 기존 prerelease에 게시했습니다: ' + url)
        return 0
    except Exception as error:
        message = str(error) if isinstance(error, PublishError) else 'Mac 배포 게시를 완료할 수 없습니다.'
        print('::error::' + message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A'), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
