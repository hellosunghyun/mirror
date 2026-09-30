"""합성 IPA와 메모리 GitHub 응답으로 게시 경계를 검증한다. 실제 서명을 대신하지 않는다."""

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_adhoc_publish', ROOT / 'scripts/ci-publish-adhoc.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
COMMIT = 'a' * 40
OTHER_COMMIT = 'b' * 40
RUN_NUMBER = '42'
RUN_ID = '100'
RELEASE_URL = 'https://github.com/synthetic/mirror/releases/tag/adhoc-100'
ASSETS = {'Mirror.ipa', 'build-manifest.json', 'SHA256SUMS', 'release-notes.md'}


def manifest_fixture():
    return {'result': 'pass', 'distribution': 'ad-hoc', 'exportMethod': 'release-testing', 'platform': 'iOS',
            'expiresAtUTC': '2099-01-01T00:00:00Z', 'deviceCount': 1, 'certificateCount': 1,
            'certificateMatchesProfile': True, 'requestedEntitlementsValidated': True,
            'targets': [{'name': 'MirrorIOS', 'bundleIdentifier': 'com.baserize.mirror'},
                        {'name': 'MirrorWidgetsIOS', 'bundleIdentifier': 'com.baserize.mirror.widgets'},
                        {'name': 'MirrorShareIOS', 'bundleIdentifier': 'com.baserize.mirror.share'}],
            'capabilities': {'appGroupsAllowed': False, 'cloudContainersAllowed': False,
                             'appGroupsRequested': False, 'cloudContainersRequested': False},
            'commitSHA': COMMIT, 'buildNumber': RUN_NUMBER, 'runID': RUN_ID,
            'version': '0.1.0', 'xcodeVersion': '27.0', 'sdkVersion': '27.0',
            'verification': {'codesign': True, 'embeddedProfile': True,
                             'getTaskAllow': False, 'versionAndBuild': True}}


class FakeClient(helper.GitHub):
    """API 쓰기를 기록하고 draft 상태에서만 업로드하는 메모리 서버."""

    def __init__(self, release=None, tag_commit=None, fault=None):
        super().__init__('synthetic/mirror', 'synthetic-test-token')
        self.release = copy.deepcopy(release)
        self.tag_commit = tag_commit
        self.fault = fault
        self.calls = []
        self.uploads = []
        self.asset_id = 100

    @property
    def mutations(self):
        return [call for call in self.calls if call['method'] != 'GET']

    def request(self, method, endpoint, *, value=None, content=None,
                content_type='application/json', missing_ok=False):
        self.calls.append({'method': method, 'endpoint': endpoint, 'value': copy.deepcopy(value)})
        if method == 'GET' and endpoint == '/releases/tags/adhoc-100':
            return copy.deepcopy(self.release)
        if method == 'GET' and endpoint == '/git/ref/tags/adhoc-100':
            return None if self.tag_commit is None else {'object': {'type': 'commit', 'sha': self.tag_commit}}
        if method == 'POST' and endpoint == '/releases':
            self.release = {'id': 7, 'html_url': RELEASE_URL,
                            'upload_url': 'https://uploads.github.com/repos/synthetic/mirror/releases/7/assets{?name,label}',
                            'assets': [], **copy.deepcopy(value)}
            return copy.deepcopy(self.release)
        if method == 'PATCH' and endpoint == '/releases/7':
            self.release.update(copy.deepcopy(value))
            if value.get('draft') is False and self.tag_commit is None and self.fault != 'missing-final-tag':
                self.tag_commit = self.release['target_commitish']
            return copy.deepcopy(self.release)
        if method == 'DELETE' and endpoint.startswith('/releases/assets/'):
            asset_id = int(endpoint.rsplit('/', 1)[1])
            self.release['assets'] = [asset for asset in self.release['assets'] if asset['id'] != asset_id]
            return None
        if method == 'POST' and endpoint.startswith('https://uploads.github.com/'):
            name = parse_qs(urlsplit(endpoint).query)['name'][0]
            self.uploads.append({'name': name, 'draft': self.release['draft'], 'content': content})
            self.asset_id += 1
            asset = {'id': self.asset_id, 'name': name, 'size': len(content),
                     'digest': 'sha256:' + hashlib.sha256(content).hexdigest()}
            if self.fault == 'upload-digest' and name == 'Mirror.ipa':
                asset['digest'] = 'sha256:' + '0' * 64
            if self.fault == 'upload-size' and name == 'Mirror.ipa':
                asset['size'] += 1
            if self.fault == 'upload-name' and name == 'Mirror.ipa':
                asset['name'] = 'unexpected.ipa'
            self.release['assets'].append(asset)
            return copy.deepcopy(asset)
        if method == 'GET' and endpoint == '/releases/7':
            response = copy.deepcopy(self.release)
            if self.fault == 'refreshed-digest':
                response['assets'][0]['digest'] = 'sha256:' + '0' * 64
            elif self.fault == 'refreshed-size':
                response['assets'][0]['size'] += 1
            elif self.fault == 'refreshed-missing':
                response['assets'].pop()
            return response
        raise AssertionError(f'예상하지 않은 합성 API 호출: {method} {endpoint}')


class TagClient(helper.GitHub):
    def __init__(self, responses):
        super().__init__('synthetic/mirror', 'synthetic-test-token')
        self.responses = responses
        self.calls = []

    def request(self, method, endpoint, **kwargs):
        self.calls.append((method, endpoint))
        return copy.deepcopy(self.responses[endpoint])


class AdHocPublishTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mirror-publish-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.directory = self.root / 'public'
        self.directory.mkdir()
        self.write_fixture()

    def write_fixture(self):
        with zipfile.ZipFile(self.directory / 'Mirror.ipa', 'w') as archive:
            for bundle, identifier in [('Payload/Mirror.app', 'com.baserize.mirror'),
                    ('Payload/Mirror.app/PlugIns/Widgets.appex', 'com.baserize.mirror.widgets'),
                    ('Payload/Mirror.app/PlugIns/Share.appex', 'com.baserize.mirror.share')]:
                archive.writestr(bundle + '/Info.plist', plistlib.dumps({
                    'CFBundleIdentifier': identifier, 'CFBundleVersion': RUN_NUMBER,
                    'CFBundleShortVersionString': '0.1.0', 'CFBundleSupportedPlatforms': ['iPhoneOS']}))
                archive.writestr(bundle + '/synthetic-binary', b'synthetic unsigned fixture only')
        self.manifest = manifest_fixture()
        ipa = (self.directory / 'Mirror.ipa').read_bytes()
        self.manifest.update(ipaSHA256=hashlib.sha256(ipa).hexdigest(), ipaBytes=len(ipa))
        (self.directory / 'release-notes.md').write_text('합성 테스트 배포\n', encoding='utf-8')
        self.write_manifest()

    def write_manifest(self):
        (self.directory / 'build-manifest.json').write_text(json.dumps(self.manifest, sort_keys=True), encoding='utf-8')
        self.write_checksums()

    def write_checksums(self):
        (self.directory / 'SHA256SUMS').write_text(''.join(
            hashlib.sha256((self.directory / name).read_bytes()).hexdigest() + '  ' + name + '\n'
            for name in sorted(ASSETS - {'SHA256SUMS'})), encoding='ascii')

    def validated(self):
        return helper.validate_assets(self.directory, COMMIT, RUN_NUMBER, RUN_ID)

    def publish(self, client):
        manifest, hashes = self.validated()
        return helper.publish(client, self.directory, manifest, hashes, COMMIT, RUN_ID)

    def main_rejects_before_api(self):
        argv = ['ci-publish-adhoc.py', '--publish-dir', str(self.directory), '--commit-sha', COMMIT,
                '--run-number', RUN_NUMBER, '--run-id', RUN_ID, '--repository', 'synthetic/mirror']
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys, 'argv', argv), patch.dict(os.environ, {'GITHUB_TOKEN': 'synthetic-test-token'}, clear=True), \
                patch.object(helper, 'GitHub') as client_factory, \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(helper.main(), 1)
            client_factory.assert_not_called()
        self.assertEqual(stdout.getvalue(), '')
        self.assertIn('::error::', stderr.getvalue())

    def existing_release(self, *, draft=False):
        _, hashes = self.validated()
        return {'id': 7, 'html_url': RELEASE_URL, 'draft': draft, 'prerelease': True,
                'tag_name': 'adhoc-' + RUN_ID, 'target_commitish': COMMIT,
                'upload_url': 'https://uploads.github.com/repos/synthetic/mirror/releases/7/assets{?name,label}',
                'assets': [{'id': index, 'name': name, 'size': (self.directory / name).stat().st_size,
                            'digest': 'sha256:' + hashes[name]} for index, name in enumerate(sorted(ASSETS), 1)]}

    def test_valid_public_assets_return_all_four_hashes(self):
        manifest, hashes = self.validated()
        self.assertEqual(manifest, self.manifest)
        self.assertEqual(set(hashes), ASSETS)
        for name, digest in hashes.items():
            self.assertEqual(digest, hashlib.sha256((self.directory / name).read_bytes()).hexdigest())

    def test_commit_run_and_build_mismatch_are_rejected_before_api(self):
        for key, value in [('commitSHA', OTHER_COMMIT), ('runID', '101'), ('buildNumber', '43')]:
            with self.subTest(key=key):
                self.manifest[key] = value
                self.write_manifest()
                self.main_rejects_before_api()
                self.manifest[key] = manifest_fixture()[key]

    def test_changed_asset_or_forged_ipa_hash_and_size_are_rejected_before_api(self):
        (self.directory / 'release-notes.md').write_text('체크섬 이후 변경\n')
        self.main_rejects_before_api()
        self.write_checksums()
        for key, value in [('ipaSHA256', '0' * 64), ('ipaBytes', self.manifest['ipaBytes'] + 1)]:
            with self.subTest(key=key):
                original = self.manifest[key]
                self.manifest[key] = value
                self.write_manifest()
                self.main_rejects_before_api()
                self.manifest[key] = original

    def test_unsigned_debuggable_or_unverified_manifest_is_rejected_before_api(self):
        for key, invalid in [('codesign', False), ('embeddedProfile', False), ('getTaskAllow', True),
                             ('versionAndBuild', False), ('codesign', 1), ('getTaskAllow', 0)]:
            with self.subTest(key=key, invalid=invalid):
                self.manifest['verification'][key] = invalid
                self.write_manifest()
                self.main_rejects_before_api()
                self.manifest['verification'] = copy.deepcopy(manifest_fixture()['verification'])

    def test_non_ipa_and_non_ad_hoc_distribution_are_rejected_before_api(self):
        for key, value in [('distribution', 'app-store'), ('exportMethod', 'debugging')]:
            with self.subTest(key=key):
                original = self.manifest[key]
                self.manifest[key] = value
                self.write_manifest()
                self.main_rejects_before_api()
                self.manifest[key] = original
        (self.directory / 'Mirror.ipa').write_bytes(b'not a ZIP archive')
        ipa = (self.directory / 'Mirror.ipa').read_bytes()
        self.manifest.update(ipaSHA256=hashlib.sha256(ipa).hexdigest(), ipaBytes=len(ipa))
        self.write_manifest()
        self.main_rejects_before_api()

    def test_raw_profile_p12_log_or_extra_directory_are_rejected_before_api(self):
        for name in ['adhoc.mobileprovision', 'distribution.p12', 'archive.log']:
            with self.subTest(name=name):
                extra = self.directory / name
                extra.write_bytes(b'synthetic private source')
                self.main_rejects_before_api()
                extra.unlink()
        (self.directory / 'Mirror.xcarchive').mkdir()
        self.main_rejects_before_api()

    def test_private_manifest_fields_at_each_public_level_are_rejected_before_api(self):
        for level, key, value in [('root', 'teamID', 'SYNTHETIC1'), ('root', 'profileUUID', 'synthetic-private-uuid'),
                ('root', 'provisionedDevices', ['synthetic-private-device']),
                ('capabilities', 'cloudContainerID', 'iCloud.private.synthetic'),
                ('verification', 'identitySHA1', 'c' * 40), ('target', 'entitlementsPath', '/private/synthetic')]:
            with self.subTest(level=level, key=key):
                container = (self.manifest if level == 'root' else self.manifest['targets'][0]
                             if level == 'target' else self.manifest[level])
                container[key] = value
                self.write_manifest()
                self.main_rejects_before_api()
                container.pop(key)

    def test_missing_duplicate_or_malformed_checksums_are_rejected_before_api(self):
        valid = (self.directory / 'SHA256SUMS').read_text()
        for text in ['', valid.splitlines()[0] + '\n', valid + valid.splitlines()[0] + '\n',
                     valid.replace('  Mirror.ipa', '  ../Mirror.ipa'), valid.replace('  ', ' ', 1)]:
            with self.subTest(text=text):
                (self.directory / 'SHA256SUMS').write_text(text)
                self.main_rejects_before_api()

    def test_symbolic_link_or_empty_asset_is_rejected_before_api(self):
        notes = self.directory / 'release-notes.md'
        external = self.root / 'external-notes.md'
        notes.rename(external)
        notes.symlink_to(external)
        self.main_rejects_before_api()
        notes.unlink()
        notes.write_bytes(b'')
        self.main_rejects_before_api()

    def test_publish_keeps_all_uploads_draft_and_rechecks_four_hashes_before_publication(self):
        client = FakeClient()
        self.assertEqual(self.publish(client), RELEASE_URL)
        self.assertEqual({upload['name'] for upload in client.uploads}, ASSETS)
        self.assertTrue(all(upload['draft'] is True for upload in client.uploads))
        publish_index = next(index for index, call in enumerate(client.calls)
                             if call['method'] == 'PATCH' and call['value'].get('draft') is False)
        refreshed_index = next(index for index, call in enumerate(client.calls)
                               if call['method'] == 'GET' and call['endpoint'] == '/releases/7')
        self.assertLess(refreshed_index, publish_index)
        self.assertFalse(client.release['draft'])
        self.assertTrue(client.release['prerelease'])
        self.assertEqual(client.tag_commit, COMMIT)
        _, hashes = self.validated()
        self.assertEqual({asset['name']: asset['digest'] for asset in client.release['assets']},
                         {name: 'sha256:' + digest for name, digest in hashes.items()})

    def test_upload_or_refreshed_asset_failure_leaves_release_draft(self):
        for fault in ['upload-digest', 'upload-size', 'upload-name', 'refreshed-digest',
                      'refreshed-size', 'refreshed-missing']:
            with self.subTest(fault=fault):
                client = FakeClient(fault=fault)
                with self.assertRaises(helper.PublishError):
                    self.publish(client)
                self.assertTrue(client.release['draft'])
                self.assertFalse(any(call['method'] == 'PATCH' and call['value'].get('draft') is False
                                     for call in client.calls))

    def test_existing_tag_on_other_commit_is_rejected_without_mutation(self):
        client = FakeClient(release=self.existing_release(), tag_commit=OTHER_COMMIT)
        with self.assertRaisesRegex(helper.PublishError, '다른 commit'):
            self.publish(client)
        self.assertEqual(client.mutations, [])

    def test_existing_draft_without_tag_cannot_be_reused_for_other_commit(self):
        release = self.existing_release(draft=True)
        release['target_commitish'] = OTHER_COMMIT
        client = FakeClient(release=release)
        with self.assertRaisesRegex(helper.PublishError, 'commit'):
            self.publish(client)
        self.assertEqual(client.mutations, [])

    def test_unexpected_existing_asset_is_rejected_without_deleting_it(self):
        release = self.existing_release(draft=True)
        release['assets'].append({'id': 50, 'name': 'adhoc.mobileprovision', 'size': 10, 'digest': None})
        client = FakeClient(release=release, tag_commit=COMMIT)
        with self.assertRaises(helper.PublishError):
            self.publish(client)
        self.assertEqual(client.mutations, [])
        self.assertEqual(client.release, release)

    def test_same_run_retry_returns_existing_verified_release_without_mutation(self):
        client = FakeClient()
        self.assertEqual(self.publish(client), RELEASE_URL)
        client.calls.clear()
        client.uploads.clear()
        self.assertEqual(self.publish(client), RELEASE_URL)
        self.assertEqual(client.mutations, [])
        self.assertEqual(client.uploads, [])
        self.assertIn({'method': 'GET', 'endpoint': '/git/ref/tags/adhoc-100', 'value': None}, client.calls)

    def test_incomplete_retry_replaces_assets_while_draft_before_republication(self):
        release = self.existing_release()
        release['assets'].pop()
        client = FakeClient(release=release, tag_commit=COMMIT)
        self.assertEqual(self.publish(client), RELEASE_URL)
        first_mutation = client.mutations[0]
        self.assertEqual(first_mutation['method'], 'PATCH')
        self.assertIs(first_mutation['value']['draft'], True)
        self.assertEqual(len([call for call in client.mutations if call['method'] == 'DELETE']), 3)
        self.assertTrue(all(upload['draft'] for upload in client.uploads))
        self.assertEqual({asset['name'] for asset in client.release['assets']}, ASSETS)

    def test_duplicate_existing_names_cannot_take_idempotent_fast_path(self):
        release = self.existing_release()
        repeated = next(asset for asset in release['assets'] if asset['name'] == 'Mirror.ipa')
        release['assets'] = [{**repeated, 'id': index} for index in range(1, 5)]
        client = FakeClient(release=release, tag_commit=COMMIT)
        self.assertEqual(self.publish(client), RELEASE_URL)
        self.assertEqual(len(client.uploads), 4)
        self.assertEqual({asset['name'] for asset in client.release['assets']}, ASSETS)

    def test_missing_final_tag_is_not_reported_as_success(self):
        client = FakeClient(fault='missing-final-tag')
        with self.assertRaises(helper.PublishError):
            self.publish(client)

    def test_tag_verification_resolves_annotated_tags_and_rejects_wrong_commit_or_cycle(self):
        ref = '/git/ref/tags/adhoc-100'
        absent = TagClient({ref: None})
        self.assertFalse(absent.verify_tag('adhoc-100', COMMIT))
        annotated = TagClient({ref: {'object': {'type': 'tag', 'sha': 'c' * 40}},
                              '/git/tags/' + 'c' * 40: {'object': {'type': 'commit', 'sha': COMMIT}}})
        self.assertTrue(annotated.verify_tag('adhoc-100', COMMIT))
        self.assertEqual(len(annotated.calls), 2)
        for target in [{'type': 'commit', 'sha': OTHER_COMMIT}, {'type': 'tree', 'sha': COMMIT}]:
            with self.subTest(target=target):
                client = TagClient({ref: {'object': target}})
                with self.assertRaises(helper.PublishError):
                    client.verify_tag('adhoc-100', COMMIT)
        cycle = TagClient({ref: {'object': {'type': 'tag', 'sha': 'c' * 40}},
                          '/git/tags/' + 'c' * 40: {'object': {'type': 'tag', 'sha': 'c' * 40}}})
        with self.assertRaises(helper.PublishError):
            cycle.verify_tag('adhoc-100', COMMIT)
        self.assertLessEqual(len(cycle.calls), 6)


if __name__ == '__main__':
    unittest.main()
