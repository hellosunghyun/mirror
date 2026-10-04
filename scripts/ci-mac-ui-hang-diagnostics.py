#!/usr/bin/env python3
"""고정된 unsigned ECE 결과만 읽는다. 앱 실행·스택 해석·원문 공개는 하지 않는다."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.request import Request, urlopen

SOURCE = {'runID': 37193375591, 'attempt': 1, 'build': 106,
          'sha': 'ecebd93803bbf629fa19cb1eb95da739ab4b318b',
          'jobID': 111410090044, 'artifactID': 11300523993}
ARTIFACT_NAME = 'macos-37193375591-1'
ARTIFACT_DIGEST = 'sha256:ffccfeaa477e4aef7c75bab0a880e23d7694af8b83aa562cd88f19612112cbbb'
# 위 digest를 검증한 ZIP의 UI.xcresult 64개 파일로 계산했다. 원문 경로는 출력하지 않는다.
UI_TREE_DIGEST = 'e0369c34c6a14320bb8d4e060a105fb6aefe2de3d90e4d79017e99ab15b42ec8'
CATEGORIES = ('image', 'json', 'text', 'archive', 'crashOrHang', 'trace', 'other')


class DiagnosticFailure(Exception):
    def __init__(self, code, exit_code=2):
        self.code, self.exit_code = code, exit_code


def require(condition, code):
    if not condition:
        raise DiagnosticFailure(code)


def verify_owner(run, artifact, job):
    require(all(run.get(k) == v for k, v in {
        'id': SOURCE['runID'], 'run_attempt': SOURCE['attempt'], 'run_number': SOURCE['build'],
        'head_sha': SOURCE['sha']}.items()), 'runMismatch')
    require(run.get('repository', {}).get('full_name') == 'hellosunghyun/mirror', 'repositoryMismatch')
    require(all(job.get(k) == v for k, v in {
        'id': SOURCE['jobID'], 'run_id': SOURCE['runID'], 'run_attempt': SOURCE['attempt'],
        'head_sha': SOURCE['sha'], 'name': '네 경로 실제 검증 / macOS 앱 빌드와 테스트',
        'status': 'completed', 'conclusion': 'failure'}.items()), 'jobMismatch')
    require(artifact.get('id') == SOURCE['artifactID'] and artifact.get('name') == ARTIFACT_NAME
            and artifact.get('expired') is False and artifact.get('size_in_bytes') == 5027155
            and artifact.get('digest') == ARTIFACT_DIGEST, 'artifactMismatch')
    owner = artifact.get('workflow_run', {})
    require(owner.get('id') == SOURCE['runID'] and owner.get('head_sha') == SOURCE['sha'], 'artifactOwnerMismatch')


def verify_context(context):
    expected = {'platform': 'macos', 'scheme': 'MirrorMac', 'sdk': 'macosx',
                'destination': 'platform=macOS,arch=arm64', 'run_id': str(SOURCE['runID']),
                'run_attempt': str(SOURCE['attempt']), 'commit': SOURCE['sha'],
                'build_number': str(SOURCE['build'])}
    require(context == expected, 'unitContextMismatch')


def verify_tree(bundle, expected=UI_TREE_DIGEST):
    require(bundle.is_dir() and not bundle.is_symlink(), 'uiBundleMissing')
    digest, count = hashlib.sha256(), 0
    for path in sorted(bundle.rglob('*'), key=lambda path: path.relative_to(bundle).as_posix()):
        require(not path.is_symlink(), 'uiBundleSymlink')
        if path.is_file():
            body = path.read_bytes()
            digest.update(path.relative_to(bundle).as_posix().encode() + b'\0'
                          + len(body).to_bytes(8, 'big') + hashlib.sha256(body).digest())
            count += 1
    require(count == 64 and digest.hexdigest() == expected, 'uiBundleDigestMismatch')


def supports_export(help_text):
    return all(re.search(r'(?m)^\s*' + re.escape(option) + r'(?:\s|=|$)', help_text)
               for option in ('--path', '--output-path'))


def file_counts(directory):
    counts = dict.fromkeys(CATEGORIES, 0)
    require(directory.is_dir() and not directory.is_symlink(), 'exportDirectoryMissing')
    for path in directory.rglob('*'):
        require(not path.is_symlink(), 'exportSymlink')
        if not path.is_file():
            continue
        extension = path.suffix.lower()
        category = next((name for name, extensions in (
            ('image', ('.png', '.jpg', '.jpeg', '.heic')), ('json', ('.json',)),
            ('text', ('.txt', '.log')), ('archive', ('.zip', '.gz', '.tar')),
            ('crashOrHang', ('.ips', '.crash', '.hang', '.spin', '.spindump')),
            ('trace', ('.trace', '.tracev3', '.ktrace'))) if extension in extensions), 'other')
        counts[category] += 1
    return counts


def native(arguments, private, name):
    # stdout/stderr에 SDK 원문이 있어도 현재 runner의 비공개 경로에만 쓴다.
    with (private / (name + '.out')).open('wb') as out, (private / (name + '.err')).open('wb') as err:
        result = subprocess.run(arguments, stdout=out, stderr=err, check=False)
    if result.returncode:
        raise DiagnosticFailure('nativeCommandFailed', result.returncode)
    return (private / (name + '.out')).read_text(errors='replace')


def api(endpoint):
    request = Request('https://api.github.com/repos/hellosunghyun/mirror/' + endpoint,
                      headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                               'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'})
    with urlopen(request, timeout=30) as response:
        data = response.read(2 * 1024 * 1024 + 1)
    require(len(data) <= 2 * 1024 * 1024, 'apiResponseTooLarge')
    return json.loads(data)


def read_json(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 2 * 1024 * 1024,
            'metadataUnavailable')
    return json.loads(path.read_text())


def inspect(root, summary):
    private, source = root / 'private', root / 'source'
    metadata = read_json(private / 'ownership.json')
    verify_owner(metadata['run'], metadata['artifact'], metadata['job'])
    verify_context(read_json(source / 'unit-context.json'))
    verify_tree(source / 'UI.xcresult')
    summary['sourceVerified'] = True
    summary['uiBundleDigestVerified'] = True
    summary['phase'] = 'sdkVersion'
    version = native(['xcodebuild', '-version'], private, 'xcode-version')
    sdk = native(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], private, 'sdk-version').strip()
    require(re.search(r'(?m)^Xcode 27(?:\.\d+)*$', version) and re.fullmatch(r'27(?:\.\d+)*', sdk), 'sdkMismatch')
    # 현재 SDK의 공개 help에서 확인한 두 옵션만 사용한다. 알 수 없는 지원은 실패다.
    summary['phase'] = 'sdkHelp'
    for kind in ('diagnostics', 'attachments'):
        help_text = native(['xcrun', 'xcresulttool', 'export', kind, '--help'], private, kind + '-help')
        require(supports_export(help_text), 'unsupportedSDKOptions')
    summary['publicExportOptionsVerified'] = True
    first_failure = None
    for kind in ('diagnostics', 'attachments'):
        summary['phase'] = kind
        exported = private / kind
        try:
            native(['xcrun', 'xcresulttool', 'export', kind, '--path', str(source / 'UI.xcresult'),
                    '--output-path', str(exported)], private, kind + '-export')
            summary['exports'][kind] = {'status': 'exported', 'fileCategoryCounts': file_counts(exported)}
        except DiagnosticFailure as error:
            summary['exports'][kind] = {'status': error.code, 'exitCode': error.exit_code}
            first_failure = first_failure or error
    if first_failure:
        raise first_failure
    summary['phase'] = 'complete'


def main(argv=None):
    os.umask(0o077)
    arguments = sys.argv[1:] if argv is None else argv
    summary = {'schemaVersion': 1, 'scope': 'preservedUnsignedMacResult', 'source': SOURCE,
               'phase': 'context', 'status': 'started', 'sourceVerified': False, 'exports': {}}
    exit_code, root = 0, None
    try:
        require(len(arguments) == 1 and arguments[0] in ('verify', 'inspect', 'cleanup'), 'invalidCommand')
        require(os.environ.get('GITHUB_REPOSITORY') == 'hellosunghyun/mirror'
                and os.environ.get('RUNNER_OS') == 'macOS', 'runnerContextMismatch')
        runner_temp = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
        root = runner_temp / 'mirror-mac-ui-hang'
        require(not root.is_symlink(), 'privateRootSymlink')
        if arguments[0] == 'cleanup':
            shutil.rmtree(root, ignore_errors=False) if root.exists() else None
            print('Mac UI preserved diagnostics: {"status":"privateFilesRemoved"}')
            return 0
        root.mkdir(mode=0o700, exist_ok=True)
        for child in ('private', 'public'):
            require(not (root / child).is_symlink(), 'privateRootSymlink')
            (root / child).mkdir(mode=0o700, exist_ok=True)
        if arguments[0] == 'verify':
            require(not (root / 'source').exists(), 'sourceAlreadyPresent')
            summary['phase'] = 'apiOwnership'
            run = api('actions/runs/37193375591/attempts/1')
            artifact = api('actions/artifacts/11300523993')
            job = api('actions/jobs/111410090044')
            verify_owner(run, artifact, job)
            (root / 'private/ownership.json').write_text(json.dumps({'run': run, 'artifact': artifact, 'job': job}))
            summary['sourceVerified'] = True
        else:
            inspect(root, summary)
        summary['status'] = 'inspectionComplete' if arguments[0] == 'inspect' else 'ownershipVerified'
    except DiagnosticFailure as error:
        summary['status'], exit_code = error.code, error.exit_code
        summary['exitCode'] = exit_code
    except Exception:
        summary['status'], exit_code = 'diagnosticUnavailable', 2
    # 이 스키마는 고정 코드·개수·검증 출처만 포함한다. 예외 문자열/SDK 원문을 직렬화하지 않는다.
    text = json.dumps(summary, ensure_ascii=False, sort_keys=True)
    print('Mac UI preserved diagnostics: ' + text)
    try:
        if root is not None and not root.is_symlink() and (root / 'public').is_dir() and not (root / 'public').is_symlink():
            (root / 'public/summary.json').write_text(text + '\n')
    except OSError:
        print('Mac UI preserved diagnostics: {"status":"summaryWriteFailed"}')
        exit_code = exit_code or 2
    return exit_code if exit_code >= 0 else 128 - exit_code


if __name__ == '__main__':
    raise SystemExit(main())
