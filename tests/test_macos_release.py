"""합성 DMG trailer와 메모리 GitHub만 사용한다. 실제 서명·공증을 대신하지 않는다."""

import ast
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import pathlib
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_macos_release', ROOT / 'scripts/ci-macos-release.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
COMMIT = 'a' * 40
OTHER_COMMIT = 'b' * 40
RUN_NUMBER = '42'
RUN_ID = '100'
RELEASE_URL = 'https://github.com/synthetic/mirror/releases/tag/adhoc-100'
PRIVATE_VALUE = 'SYNTHETIC_PRIVATE_TEAM_PROFILE_CERT_PASSWORD'


def manifest_fixture():
    return {
        'schemaVersion': 1, 'result': 'pass', 'distribution': 'developer-id', 'platform': 'macOS',
        'commitSHA': COMMIT, 'buildNumber': RUN_NUMBER, 'runID': RUN_ID,
        'version': '0.1.0', 'xcodeVersion': '27.0', 'sdkVersion': '27.0',
        'minimumOS': '27.0', 'architectures': ['arm64'], 'certificateType': 'Developer ID Application',
        'targets': [{'name': name, 'bundleIdentifier': identifier}
                    for name, identifier in helper.EXPECTED_TARGETS.items()],
        'verification': {'codesign': True, 'hardenedRuntime': True, 'notarization': True,
                         'stapled': True, 'gatekeeper': True, 'versionAndBuild': True, 'getTaskAllow': False},
    }


def existing_ios_release():
    assets = []
    for identifier, name in enumerate(sorted(helper.IOS_ASSET_NAMES), 1):
        content = ('synthetic verified iOS asset ' + name).encode()
        assets.append({'id': identifier, 'name': name, 'size': len(content), 'state': 'uploaded',
                       'digest': 'sha256:' + hashlib.sha256(content).hexdigest()})
    return {'id': 7, 'html_url': RELEASE_URL, 'tag_name': 'adhoc-100',
            'draft': False, 'prerelease': True, 'name': 'Existing iOS release', 'body': 'Existing iOS notes',
            'upload_url': 'https://uploads.github.com/repos/synthetic/mirror/releases/7/assets{?name,label}',
            'assets': assets}


class FakeClient(helper.GitHub):
    def __init__(self, release=None, *, missing_release=False, tag_commit=COMMIT, fault=None, public=True):
        super().__init__('synthetic/mirror', 'synthetic-token')
        self.release = None if missing_release else copy.deepcopy(release or existing_ios_release())
        self.tag_commit = tag_commit
        self.fault = fault
        self.public = public
        self.calls = []
        self.next_asset_id = 100
        self.tag_reads = 0
        self.upload_count = 0

    @property
    def mutations(self):
        return [call for call in self.calls if call['method'] != 'GET']

    def request(self, method, endpoint, *, value=None, content=None,
                content_type='application/json', missing_ok=False):
        self.calls.append({'method': method, 'endpoint': endpoint, 'value': copy.deepcopy(value)})
        if method == 'GET' and endpoint == '':
            return {'private': not self.public}
        if method == 'GET' and endpoint == '/releases/tags/adhoc-100':
            return copy.deepcopy(self.release)
        if method == 'GET' and endpoint == '/git/ref/tags/adhoc-100':
            self.tag_reads += 1
            commit = OTHER_COMMIT if self.fault == 'final-tag' and self.tag_reads > 1 else self.tag_commit
            return None if commit is None else {'object': {'type': 'commit', 'sha': commit}}
        if method == 'PATCH' and endpoint == '/releases/7':
            if set(value) != {'body'}:
                raise AssertionError('기존 Release의 공개 상태와 이름을 변경할 수 없습니다.')
            self.release['body'] = value['body']
            response = copy.deepcopy(self.release)
            if self.fault == 'patch-body':
                response['body'] = 'unexpected response body'
            return response
        if method == 'DELETE' and endpoint.startswith('/releases/assets/'):
            asset_id = int(endpoint.rsplit('/', 1)[1])
            victim = next(asset for asset in self.release['assets'] if asset['id'] == asset_id)
            if victim['name'] not in helper.ASSET_NAMES:
                raise AssertionError('iOS 자산을 삭제할 수 없습니다.')
            self.release['assets'] = [asset for asset in self.release['assets'] if asset['id'] != asset_id]
            return None
        if method == 'POST' and endpoint.startswith('https://uploads.github.com/'):
            name = parse_qs(urlsplit(endpoint).query)['name'][0]
            if name not in helper.ASSET_NAMES:
                raise AssertionError('Mac 자산만 업로드할 수 있습니다.')
            self.upload_count += 1
            if self.fault == 'interrupt-upload' and self.upload_count == 2:
                raise helper.PublishError('합성 업로드 중단')
            self.next_asset_id += 1
            asset = {'id': self.next_asset_id, 'name': name, 'size': len(content), 'state': 'uploaded',
                     'digest': 'sha256:' + hashlib.sha256(content).hexdigest()}
            if self.fault == 'upload-digest':
                asset['digest'] = 'sha256:' + '0' * 64
            elif self.fault == 'upload-size':
                asset['size'] += 1
            elif self.fault == 'upload-name':
                asset['name'] = 'foreign.bin'
            elif self.fault == 'upload-state':
                asset['state'] = 'starter'
            self.release['assets'].append(asset)
            return copy.deepcopy(asset)
        if method == 'GET' and endpoint == '/releases/7':
            release = copy.deepcopy(self.release)
            ios = next(asset for asset in release['assets'] if asset['name'] in helper.IOS_ASSET_NAMES)
            mac = next(asset for asset in release['assets'] if asset['name'] in helper.ASSET_NAMES)
            if self.fault == 'final-ios-id':
                ios['id'] += 1000
            elif self.fault == 'final-ios-digest':
                ios['digest'] = 'sha256:' + '0' * 64
            elif self.fault == 'final-ios-size':
                ios['size'] += 1
            elif self.fault == 'final-mac-digest':
                mac['digest'] = 'sha256:' + '0' * 64
            elif self.fault == 'final-missing':
                release['assets'].remove(mac)
            elif self.fault == 'final-foreign':
                release['assets'].append({'id': 9999, 'name': 'foreign.bin'})
            elif self.fault == 'final-draft':
                release['draft'] = True
            elif self.fault == 'final-wrong-tag':
                release['tag_name'] = 'adhoc-101'
            return release
        raise AssertionError('예상하지 않은 합성 API 요청입니다.')


class MacOSReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mirror-macos-publish-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.directory = self.root / 'public'
        self.directory.mkdir()
        # trailer/hash 검사만 위한 합성 파일이며 mount 가능한 DMG가 아니다.
        dmg = b'synthetic notarized fixture only' + b'koly' + b'\0' * 508
        (self.directory / 'Mirror-macOS.dmg').write_bytes(dmg)
        (self.directory / 'macos-release-notes.md').write_text('합성 Mac 배포 정보\n', encoding='utf-8')
        self.manifest = manifest_fixture()
        self.manifest.update(dmgSHA256=hashlib.sha256(dmg).hexdigest(), dmgBytes=len(dmg))
        self.write_manifest()

    def write_manifest(self):
        (self.directory / 'macos-build-manifest.json').write_text(json.dumps(self.manifest), encoding='utf-8')
        self.write_checksums()

    def write_checksums(self):
        (self.directory / 'macos-SHA256SUMS').write_text(''.join(
            hashlib.sha256((self.directory / name).read_bytes()).hexdigest() + '  ' + name + '\n'
            for name in sorted(helper.CHECKSUM_NAMES)), encoding='ascii')

    def validated(self):
        return helper.validate_assets(self.directory, COMMIT, RUN_NUMBER, RUN_ID)

    def publish(self, client):
        manifest, hashes = self.validated()
        return helper.publish(client, self.directory, manifest, hashes, COMMIT, RUN_ID)

    def main_rejects_before_api(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        arguments = ['--publish-dir', str(self.directory), '--commit-sha', COMMIT,
                     '--run-number', RUN_NUMBER, '--run-id', RUN_ID, '--repository', 'synthetic/mirror']
        with mock.patch.dict(os.environ, {'GITHUB_TOKEN': 'synthetic-token'}, clear=True), \
                mock.patch.object(helper, 'GitHub') as factory, \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(helper.main(arguments), 1)
            factory.assert_not_called()
        self.assertEqual(stdout.getvalue(), '')
        self.assertIn('::error::', stderr.getvalue())
        self.assertNotIn(PRIVATE_VALUE, stderr.getvalue())
        self.assertNotIn(str(self.directory), stderr.getvalue())

    def seed_mac_assets(self, client):
        _, hashes = self.validated()
        for identifier, name in enumerate(sorted(helper.ASSET_NAMES), 101):
            client.release['assets'].append({'id': identifier, 'name': name, 'state': 'uploaded',
                                            'size': (self.directory / name).stat().st_size,
                                            'digest': 'sha256:' + hashes[name]})
        client.next_asset_id = 200
        client.release['body'] += '\n\n' + helper.MAC_SECTION_MARKER + '\n합성 Mac 배포 정보\n'

    def test_validated_assets_match_all_four_hashes(self):
        manifest, hashes = self.validated()
        self.assertEqual(manifest, self.manifest)
        self.assertEqual(set(hashes), helper.ASSET_NAMES)

    def test_actual_archive_manifest_and_assets_satisfy_publisher_contract(self):
        # Bash를 실행하지 않는다. 내장 Python의 공개 산출물 생성 함수만 분리한다.
        # 모든 서명/공증 단계는 실행하지 않으며 입력 DMG도 합성 trailer fixture다.
        shell = (ROOT / 'scripts/ci-macos-archive.sh').read_text(encoding='utf-8')
        marker = 'cat > "$private_dir/helper.py" <<\'PY\'\n'
        embedded = shell.split(marker, 1)[1].split('\nPY\n', 1)[0]
        definitions = [node for node in ast.parse(embedded).body
                       if isinstance(node, ast.FunctionDef) and node.name == 'publish']
        self.assertEqual(len(definitions), 1)
        private = self.root / 'synthetic-archive'
        private.mkdir()
        produced = self.root / 'produced-public'
        produced.mkdir()
        shutil.copyfile(self.directory / 'Mirror-macOS.dmg', private / 'Mirror-macOS.dmg')
        metadata = {key: self.manifest[key] for key in
                    ('buildNumber', 'commitSHA', 'runID', 'version', 'xcodeVersion', 'sdkVersion', 'targets')}
        (private / 'build.json').write_text(json.dumps(metadata), encoding='utf-8')
        namespace = {
            'pathlib': pathlib, 'sys': SimpleNamespace(argv=['helper', 'publish', str(private), str(ROOT), str(produced)]),
            'root': private, 'hashlib': hashlib, 'shutil': shutil, 'json': json, 'require': helper.require,
            'read_json': lambda name: json.loads((private / name).read_text(encoding='utf-8')),
        }
        module = ast.fix_missing_locations(ast.Module(body=definitions, type_ignores=[]))
        exec(compile(module, 'synthetic_archive_publish_definition', 'exec'), namespace)
        namespace['publish']()
        manifest, hashes = helper.validate_assets(produced, COMMIT, RUN_NUMBER, RUN_ID)
        self.assertEqual(set(hashes), helper.ASSET_NAMES)
        self.assertEqual(manifest['verification']['getTaskAllow'], False)
        self.assertEqual({target['name']: target['bundleIdentifier'] for target in manifest['targets']},
                         helper.EXPECTED_TARGETS)
        self.assertNotIn(PRIVATE_VALUE, json.dumps(manifest))

    def test_private_manifest_keys_and_nested_values_are_rejected(self):
        cases = [('root', 'teamID'), ('root', 'profileUUID'), ('root', 'certificateSubject'),
                 ('root', 'privateKey'), ('root', 'notarizationID'), ('root', 'password'),
                 ('verification', 'keychainPath'), ('target', 'entitlementsPath')]
        for level, key in cases:
            with self.subTest(level=level, key=key):
                container = self.manifest if level == 'root' else self.manifest['targets'][0] if level == 'target' else self.manifest[level]
                container[key] = PRIVATE_VALUE
                self.write_manifest()
                self.main_rejects_before_api()
                del container[key]
        self.manifest['version'] = {'teamID': PRIVATE_VALUE}
        self.write_manifest()
        self.main_rejects_before_api()

    def test_raw_values_cannot_hide_in_public_string_metadata(self):
        for key in ('version', 'xcodeVersion', 'sdkVersion', 'certificateType'):
            with self.subTest(key=key):
                original = self.manifest[key]
                self.manifest[key] = PRIVATE_VALUE
                self.write_manifest()
                self.main_rejects_before_api()
                self.manifest[key] = original

    def test_every_required_signature_and_notarization_flag_is_strict(self):
        for key in helper.VERIFICATION_KEYS:
            for invalid in ((True, 0, 'false') if key == 'getTaskAllow' else (False, 1, 'true')):
                with self.subTest(key=key, invalid=invalid):
                    self.manifest['verification'][key] = invalid
                    self.write_manifest()
                    self.main_rejects_before_api()
                    self.manifest['verification'] = copy.deepcopy(manifest_fixture()['verification'])

    def test_current_commit_run_build_and_ipa_platform_are_required(self):
        for key, value in [('commitSHA', OTHER_COMMIT), ('runID', '101'), ('buildNumber', '43'),
                           ('platform', 'iOS'), ('distribution', 'ad-hoc'), ('minimumOS', '26.0'),
                           ('architectures', ['x86_64']), ('schemaVersion', True), ('result', 'fail')]:
            with self.subTest(key=key):
                original = self.manifest[key]
                self.manifest[key] = value
                self.write_manifest()
                self.main_rejects_before_api()
                self.manifest[key] = original

    def test_target_bundle_contract_and_duplicates_are_rejected(self):
        self.manifest['targets'][0]['bundleIdentifier'] = PRIVATE_VALUE
        self.write_manifest()
        self.main_rejects_before_api()
        self.manifest['targets'] = [copy.deepcopy(manifest_fixture()['targets'][0])] * 3
        self.write_manifest()
        self.main_rejects_before_api()

    def test_extra_private_files_and_wrong_file_names_are_rejected(self):
        for name in ('distribution.p12', 'archive.log', 'profile.mobileprovision', 'Mirror.dmg'):
            with self.subTest(name=name):
                extra = self.directory / name
                extra.write_text(PRIVATE_VALUE)
                self.main_rejects_before_api()
                extra.unlink()

    def test_symlink_empty_asset_and_invalid_dmg_fail_before_api(self):
        notes = self.directory / 'macos-release-notes.md'
        external = self.root / 'external.md'
        notes.rename(external)
        notes.symlink_to(external)
        self.main_rejects_before_api()
        notes.unlink()
        notes.write_bytes(b'')
        self.main_rejects_before_api()
        notes.write_text('synthetic restored notes')
        dmg = b'not a disk image'
        (self.directory / 'Mirror-macOS.dmg').write_bytes(dmg)
        self.manifest.update(dmgSHA256=hashlib.sha256(dmg).hexdigest(), dmgBytes=len(dmg))
        self.write_manifest()
        self.main_rejects_before_api()

    def test_modified_assets_forged_hash_size_and_bad_checksums_fail(self):
        (self.directory / 'macos-release-notes.md').write_text('changed after checksums')
        self.main_rejects_before_api()
        self.write_checksums()
        for key, value in [('dmgSHA256', '0' * 64), ('dmgBytes', self.manifest['dmgBytes'] + 1)]:
            original = self.manifest[key]
            self.manifest[key] = value
            self.write_manifest()
            self.main_rejects_before_api()
            self.manifest[key] = original
        self.write_manifest()
        valid = (self.directory / 'macos-SHA256SUMS').read_text()
        for text in ('', valid + valid.splitlines()[0] + '\n', valid.replace('  ', ' ', 1),
                     valid.replace('  Mirror-macOS.dmg', '  ../Mirror-macOS.dmg')):
            (self.directory / 'macos-SHA256SUMS').write_text(text)
            self.main_rejects_before_api()

    def test_public_ios_prerelease_and_matching_tag_are_required_without_writes(self):
        clients = [FakeClient(missing_release=True), FakeClient(tag_commit=OTHER_COMMIT),
                   FakeClient(tag_commit=None), FakeClient(public=False)]
        for field, value in (('draft', True), ('prerelease', False), ('tag_name', 'adhoc-101')):
            release = existing_ios_release()
            release[field] = value
            clients.append(FakeClient(release))
        incomplete = existing_ios_release()
        incomplete['assets'].pop()
        clients.append(FakeClient(incomplete))
        for client in clients:
            with self.assertRaises(helper.PublishError):
                self.publish(client)
            self.assertEqual(client.mutations, [])

    def test_foreign_duplicate_assets_and_bad_ios_digests_are_rejected_without_writes(self):
        releases = []
        foreign = existing_ios_release()
        foreign['assets'].append({'id': 99, 'name': 'distribution.p12'})
        releases.append(foreign)
        duplicate = existing_ios_release()
        duplicate['assets'].append(copy.deepcopy(duplicate['assets'][0]))
        releases.append(duplicate)
        duplicate_id = existing_ios_release()
        duplicate_id['assets'].append({'id': 1, 'name': 'Mirror-macOS.dmg'})
        releases.append(duplicate_id)
        for field, value in (('digest', None), ('size', 0), ('state', 'starter')):
            release = existing_ios_release()
            release['assets'][0][field] = value
            releases.append(release)
        for release in releases:
            client = FakeClient(release)
            with self.assertRaises(helper.PublishError):
                self.publish(client)
            self.assertEqual(client.mutations, [])

    def test_adds_only_mac_assets_and_preserves_ios_metadata_and_public_release(self):
        client = FakeClient()
        original = copy.deepcopy(client.release)
        self.assertEqual(self.publish(client), RELEASE_URL)
        self.assertEqual([call['method'] for call in client.mutations], ['POST'] * 4 + ['PATCH'])
        self.assertEqual(set(client.mutations[-1]['value']), {'body'})
        self.assertEqual({asset['name'] for asset in client.release['assets']}, helper.ASSET_NAMES | helper.IOS_ASSET_NAMES)
        self.assertEqual(helper.ios_snapshot(helper.release_assets(client.release, 'adhoc-100')),
                         helper.ios_snapshot(helper.release_assets(original, 'adhoc-100')))
        self.assertFalse(client.release['draft'])
        self.assertEqual(client.release['name'], original['name'])
        self.assertTrue(client.release['body'].startswith(original['body'] + '\n\n'))
        self.assertEqual(client.release['body'].count(helper.MAC_SECTION_MARKER), 1)
        self.assertTrue(client.release['body'].endswith('합성 Mac 배포 정보\n'))

    def test_complete_rerun_is_idempotent_without_api_writes(self):
        client = FakeClient()
        self.publish(client)
        client.calls.clear()
        self.assertEqual(self.publish(client), RELEASE_URL)
        self.assertEqual(client.mutations, [])

    def test_rerun_replaces_only_changed_mac_asset(self):
        client = FakeClient()
        self.seed_mac_assets(client)
        victim = next(asset for asset in client.release['assets'] if asset['name'] == 'Mirror-macOS.dmg')
        victim['digest'] = 'sha256:' + '0' * 64
        old_id = victim['id']
        original_ios = helper.ios_snapshot(helper.release_assets(client.release, 'adhoc-100'))
        self.assertEqual(self.publish(client), RELEASE_URL)
        self.assertEqual([call['method'] for call in client.mutations], ['DELETE', 'POST'])
        self.assertEqual(client.mutations[0]['endpoint'], f'/releases/assets/{old_id}')
        self.assertEqual(helper.ios_snapshot(helper.release_assets(client.release, 'adhoc-100')), original_ios)

    def test_interrupted_upload_converges_on_rerun_without_touching_ios(self):
        client = FakeClient(fault='interrupt-upload')
        original_ios = helper.ios_snapshot(helper.release_assets(client.release, 'adhoc-100'))
        with self.assertRaises(helper.PublishError):
            self.publish(client)
        self.assertEqual(len(client.release['assets']), 5)
        client.fault = None
        client.calls.clear()
        self.assertEqual(self.publish(client), RELEASE_URL)
        self.assertEqual([call['method'] for call in client.mutations], ['POST'] * 3 + ['PATCH'])
        self.assertEqual(helper.ios_snapshot(helper.release_assets(client.release, 'adhoc-100')), original_ios)

    def test_bad_upload_and_final_asset_release_or_tag_verification_fail(self):
        for fault in ('upload-digest', 'upload-size', 'upload-name', 'upload-state',
                      'final-ios-id', 'final-ios-digest', 'final-ios-size', 'final-mac-digest',
                      'final-missing', 'final-foreign', 'final-draft', 'final-wrong-tag', 'final-tag'):
            with self.subTest(fault=fault):
                client = FakeClient(fault=fault)
                with self.assertRaises(helper.PublishError):
                    self.publish(client)
                self.assertTrue(all(call['method'] != 'PATCH' for call in client.mutations))

    def test_existing_mac_body_section_is_replaced_once_and_ios_prefix_is_preserved(self):
        client = FakeClient()
        self.seed_mac_assets(client)
        client.release['body'] = 'Existing iOS notes\n\n' + helper.MAC_SECTION_MARKER + '\nOld Mac notes\n'
        self.assertEqual(self.publish(client), RELEASE_URL)
        self.assertEqual([call['method'] for call in client.mutations], ['PATCH'])
        self.assertEqual(client.release['body'], 'Existing iOS notes\n\n' + helper.MAC_SECTION_MARKER + '\n합성 Mac 배포 정보\n')
        client.calls.clear()
        self.assertEqual(self.publish(client), RELEASE_URL)
        self.assertEqual(client.mutations, [])

    def test_ambiguous_mac_body_marker_is_rejected_before_writes(self):
        client = FakeClient()
        client.release['body'] += helper.MAC_SECTION_MARKER * 2
        with self.assertRaises(helper.PublishError):
            self.publish(client)
        self.assertEqual(client.mutations, [])

    def test_body_update_response_is_checked(self):
        client = FakeClient(fault='patch-body')
        with self.assertRaises(helper.PublishError):
            self.publish(client)

    def test_wrong_upload_release_address_is_rejected_before_writes(self):
        release = existing_ios_release()
        release['upload_url'] = 'https://uploads.github.com/repos/synthetic/other/releases/7/assets{?name,label}'
        client = FakeClient(release)
        with self.assertRaises(helper.PublishError):
            self.publish(client)
        self.assertEqual(client.mutations, [])

    def test_argument_and_exception_output_never_include_private_values(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(helper.main(['--private-secret', PRIVATE_VALUE]), 1)
        self.assertEqual(stdout.getvalue(), '')
        self.assertNotIn(PRIVATE_VALUE, stderr.getvalue())
        arguments = ['--publish-dir', str(self.directory), '--commit-sha', COMMIT,
                     '--run-number', RUN_NUMBER, '--run-id', RUN_ID, '--repository', 'synthetic/mirror']
        with mock.patch.dict(os.environ, {'GITHUB_TOKEN': 'synthetic-token'}, clear=True), \
                mock.patch.object(helper, 'validate_assets', side_effect=RuntimeError(PRIVATE_VALUE)), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(helper.main(arguments), 1)
        self.assertNotIn(PRIVATE_VALUE, stderr.getvalue())


if __name__ == '__main__':
    unittest.main()
