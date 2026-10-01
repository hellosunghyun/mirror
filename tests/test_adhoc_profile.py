"""합성 프로파일 구조만 사용한다. 실제 CMS/Apple 인증서/서명 성공을 대신하지 않는다."""

import base64
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import plistlib
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('mirror_adhoc_profile', ROOT / 'scripts/ci-adhoc-profile.py')
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
NOW = datetime(2026, 9, 30, tzinfo=timezone.utc)
# SHA1/DER 외피 검증용 합성 ASN.1 데이터이며 실제 X509 인증서가 아니다.
CERTIFICATE = b'\x30\x03\x02\x01\x01'
OTHER_CERTIFICATE = b'\x30\x03\x02\x01\x02'
TEAM = 'TESTTEAM01'
PROFILE_UUID = '11111111-2222-3333-4444-555555555555'
NAMES = ['MirrorIOS', 'MirrorWidgetsIOS', 'MirrorShareIOS']


def profile_fixture():
    return {'Platform': ['iOS', 'xrOS', 'visionOS'], 'TeamIdentifier': [TEAM],
            'ApplicationIdentifierPrefix': [TEAM], 'UUID': PROFILE_UUID, 'Name': 'private synthetic profile',
            'CreationDate': datetime(2020, 1, 1), 'ExpirationDate': datetime(2099, 1, 1),
            'ProvisionedDevices': ['private synthetic device'], 'DeveloperCertificates': [CERTIFICATE],
            'Entitlements': {'application-identifier': TEAM + '.*', 'get-task-allow': False,
                             'com.apple.developer.team-identifier': TEAM, 'keychain-access-groups': [TEAM + '.*']}}


def project_fixture():
    objects = {'project': {'isa': 'PBXProject', 'targets': ['app', 'widgets', 'share', 'framework', 'mac'],
                          'attributes': {'TargetAttributes': {}}}}
    targets = [('app', NAMES[0], 'application', 'com.baserize.mirror', 'iphoneos'),
               ('widgets', NAMES[1], 'app-extension', 'com.baserize.mirror.widgets', 'iphoneos'),
               ('share', NAMES[2], 'app-extension', 'com.baserize.mirror.share', 'iphoneos'),
               ('framework', 'MirrorSystem', 'framework', 'com.baserize.mirror.system', 'auto'),
               ('mac', 'MirrorMac', 'application', 'com.baserize.mirror.mac', 'macosx')]
    for identifier, name, kind, bundle_id, sdk in targets:
        configurations = []
        for configuration in ('Debug', 'Release'):
            configuration_id = identifier + configuration
            configurations.append(configuration_id)
            objects[configuration_id] = {'isa': 'XCBuildConfiguration', 'name': configuration,
                'buildSettings': {'PRODUCT_BUNDLE_IDENTIFIER': bundle_id, 'SDKROOT': sdk,
                                  'CODE_SIGN_ENTITLEMENTS': 'Entitlements/' + identifier + '.plist'}}
        objects[identifier + 'Configurations'] = {'isa': 'XCConfigurationList', 'buildConfigurations': configurations}
        objects[identifier] = {'isa': 'PBXNativeTarget', 'name': name, 'productType': 'com.apple.product-type.' + kind,
                               'buildConfigurationList': identifier + 'Configurations'}
    return {'rootObject': 'project', 'objects': objects}


class AdHocProfileTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mirror-adhoc-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'Entitlements').mkdir()
        for name in ('app', 'widgets', 'share'):
            (self.root / 'Entitlements' / (name + '.plist')).write_bytes(plistlib.dumps({}))
        self.profile = profile_fixture()
        self.project = project_fixture()

    def prepare(self, profile=None, certificate=CERTIFICATE, project=None, names=NAMES):
        return helper.prepare(profile or self.profile, certificate, project or self.project, self.root, names,
                              {'commitSHA': 'a' * 40, 'buildNumber': '42', 'runID': '100', 'version': '0.1.0',
                               'xcodeVersion': '27.0', 'sdkVersion': '27.0'}, now=NOW)

    def test_all_three_bundle_ids_validate_and_public_manifest_contains_no_private_values(self):
        context, manifest, options = self.prepare()
        self.assertEqual(context['identitySHA1'], hashlib.sha1(CERTIFICATE).hexdigest().upper())
        self.assertEqual([value['bundleIdentifier'] for value in context['targets']],
                         ['com.baserize.mirror', 'com.baserize.mirror.widgets', 'com.baserize.mirror.share'])
        self.assertEqual(options['method'], 'release-testing')
        self.assertEqual(options['signingStyle'], 'manual')
        self.assertEqual(set(options['provisioningProfiles'].values()), {PROFILE_UUID})
        self.assertEqual(len(options['provisioningProfiles']), 3)
        self.assertEqual(manifest['deviceCount'], 1)
        self.assertEqual(manifest['capabilities'], {'appGroupsAllowed': False, 'cloudContainersAllowed': False,
                                                  'appGroupsRequested': False, 'cloudContainersRequested': False})
        public = json.dumps(manifest)
        for private in (TEAM, PROFILE_UUID, self.profile['Name'], self.profile['ProvisionedDevices'][0], context['identitySHA1']):
            self.assertNotIn(private, public)
        self.assertEqual(self.project, project_fixture())

    def test_profile_class_platform_expiry_and_malformed_identity_fail_closed(self):
        cases = [('Platform', ['macOS'], 'PROFILE_PLATFORM'), ('TeamIdentifier', [TEAM, 'OTHERTEAM1'], 'PROFILE_TEAM'),
                 ('TeamIdentifier', [1234567890], 'PROFILE_TEAM'), ('ApplicationIdentifierPrefix', [], 'PROFILE_PREFIX'),
                 ('ExpirationDate', NOW, 'PROFILE_EXPIRED'), ('ExpirationDate', '2099-01-01', 'PROFILE_EXPIRY'),
                 ('CreationDate', datetime(2100, 1, 1), 'PROFILE_EXPIRED'), ('ProvisionedDevices', [], 'PROFILE_DEVICES'),
                 ('ProvisionedDevices', ['same', 'same'], 'PROFILE_DEVICES'), ('ProvisionsAllDevices', True, 'PROFILE_ENTERPRISE'),
                 ('DeveloperCertificates', [], 'PROFILE_CERTIFICATES'), ('DeveloperCertificates', ['not DER'], 'PROFILE_CERTIFICATES'),
                 ('UUID', 'private invalid uuid', 'PROFILE_UUID'), ('Name', 'private\nname', 'PROFILE_NAME')]
        for key, value, code in cases:
            with self.subTest(key=key, code=code):
                profile = copy.deepcopy(self.profile)
                profile[key] = value
                with self.assertRaisesRegex(helper.ValidationError, '^' + code + '$'):
                    self.prepare(profile=profile)

    def test_profile_uuid_original_case_is_preserved_for_xcode_selection_and_export(self):
        for identifier in ('abcdef01-2345-6789-abcd-ef0123456789',
                           'ABCDEF01-2345-6789-ABCD-EF0123456789',
                           'AbCdEf01-2345-6789-aBcD-eF0123456789'):
            with self.subTest(identifier=identifier):
                profile = dict(self.profile, UUID=identifier)
                context, manifest, options = self.prepare(profile=profile)
                patched = helper.patch(self.project, context)
                self.assertEqual(context['profileUUID'], identifier)
                self.assertEqual(set(options['provisioningProfiles'].values()), {identifier})
                for target in ('app', 'widgets', 'share'):
                    settings = patched['objects'][target + 'Release']['buildSettings']
                    self.assertEqual(settings['PROVISIONING_PROFILE'], identifier)
                    self.assertEqual(settings['PROVISIONING_PROFILE_SPECIFIER'], profile['Name'])
                self.assertNotIn(identifier, json.dumps(manifest))
        for value in (True, 0, 'false'):
            profile = copy.deepcopy(self.profile)
            profile['Entitlements']['get-task-allow'] = value
            with self.assertRaisesRegex(helper.ValidationError, '^PROFILE_DEBUGGING$'):
                self.prepare(profile=profile)

    def test_selected_certificate_must_match_profile_der(self):
        with self.assertRaisesRegex(helper.ValidationError, '^CERTIFICATE_MISMATCH$'):
            self.prepare(certificate=OTHER_CERTIFICATE)
        profile = copy.deepcopy(self.profile)
        profile['DeveloperCertificates'].append(OTHER_CERTIFICATE)
        context, manifest, _ = self.prepare(profile=profile, certificate=OTHER_CERTIFICATE)
        self.assertEqual(context['identitySHA1'], hashlib.sha1(OTHER_CERTIFICATE).hexdigest().upper())
        self.assertEqual(manifest['certificateCount'], 2)

    def test_single_pem_and_der_match_and_malformed_or_chain_pem_is_rejected(self):
        path = self.root / 'certificate'
        pem = b'-----BEGIN CERTIFICATE-----\n' + base64.b64encode(CERTIFICATE) + b'\n-----END CERTIFICATE-----\n'
        for data in (CERTIFICATE, pem):
            path.write_bytes(data)
            self.assertEqual(helper.read_certificate(path), CERTIFICATE)
        for data in (b'not DER', CERTIFICATE[:-1], pem + pem, b'-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----'):
            path.write_bytes(data)
            with self.assertRaises(helper.ValidationError):
                helper.read_certificate(path)

    def test_wildcard_scope_exact_extensions_and_invalid_globs(self):
        for pattern, identifier, expected in [('*', 'com.baserize.mirror', True),
                ('com.baserize.*', 'com.baserize.mirror.widgets', True), ('com.*', 'com.baserize.mirror', True),
                ('com.baserize.*', 'com.baserize', False), ('com.baserize.*', 'com.baserizeevil.mirror', False),
                ('com.baserize.mirror', 'com.baserize.mirror.widgets', False),
                ('com.baserize*', 'com.baserizeevil.mirror', False), ('com.*.mirror', 'com.baserize.mirror', False)]:
            with self.subTest(pattern=pattern, identifier=identifier):
                self.assertEqual(helper.identifier_matches(pattern, identifier), expected)
        profile = copy.deepcopy(self.profile)
        profile['Entitlements']['application-identifier'] = TEAM + '.com.baserize.*'
        self.prepare(profile=profile)
        for pattern, code in [('com.baserize.mirror', 'BUNDLE_MISMATCH'), ('com.baserizeevil.*', 'BUNDLE_MISMATCH'),
                              ('com.baserize*', 'PROFILE_WILDCARD')]:
            profile['Entitlements']['application-identifier'] = TEAM + '.' + pattern
            with self.assertRaisesRegex(helper.ValidationError, '^' + code + '$'):
                self.prepare(profile=profile)

    def test_legacy_app_prefix_is_not_assumed_to_be_team_id(self):
        profile = copy.deepcopy(self.profile)
        profile['ApplicationIdentifierPrefix'] = ['LEGACY0001']
        profile['Entitlements']['application-identifier'] = 'LEGACY0001.*'
        profile['Entitlements']['keychain-access-groups'] = ['LEGACY0001.*']
        context, _, _ = self.prepare(profile=profile)
        requested = {'application-identifier': '$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)',
                     'com.apple.developer.team-identifier': TEAM,
                     'keychain-access-groups': ['$(AppIdentifierPrefix)$(CFBundleIdentifier)']}
        self.assertEqual(helper.validate_entitlements(requested, profile['Entitlements'], 'com.baserize.mirror', context)
                         ['application-identifier'], 'LEGACY0001.com.baserize.mirror')

    def test_requested_entitlements_must_be_allowed_for_the_specific_bundle(self):
        context, _, _ = self.prepare()
        invalid = [({'com.apple.security.application-groups': ['group.synthetic']}, 'ENTITLEMENT_NOT_ALLOWED'),
                   ({'com.apple.developer.icloud-container-identifiers': ['iCloud.synthetic']}, 'ENTITLEMENT_NOT_ALLOWED'),
                   ({'get-task-allow': True}, 'ENTITLEMENT_NOT_ALLOWED'),
                   ({'get-task-allow': 0}, 'ENTITLEMENT_NOT_ALLOWED'),
                   ({'application-identifier': TEAM + '.com.baserize.mirror.widgets'}, 'REQUESTED_APPLICATION_ID'),
                   ({'com.apple.developer.team-identifier': 'OTHERTEAM1'}, 'REQUESTED_TEAM'),
                   ({'keychain-access-groups': ['OTHERTEAM1.com.baserize.mirror']}, 'ENTITLEMENT_NOT_ALLOWED'),
                   ({'keychain-access-groups': ['$(UnknownPrefix)com.baserize.mirror']}, 'ENTITLEMENT_VARIABLE')]
        for requested, code in invalid:
            with self.subTest(code=code):
                with self.assertRaisesRegex(helper.ValidationError, '^' + code + '$'):
                    helper.validate_entitlements(requested, self.profile['Entitlements'], 'com.baserize.mirror', context)
        (self.root / 'Entitlements/widgets.plist').write_bytes(plistlib.dumps(invalid[0][0]))
        with self.assertRaisesRegex(helper.ValidationError, '^ENTITLEMENT_NOT_ALLOWED$'):
            self.prepare()

    def test_patch_changes_only_ios_application_configuration_settings(self):
        self.project['objects']['appRelease']['buildSettings']['PROVISIONING_PROFILE_SPECIFIER'] = 'old synthetic name'
        self.project['objects']['appRelease']['buildSettings']['PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]'] = 'old conditional name'
        self.project['objects']['appRelease']['buildSettings']['PROVISIONING_PROFILE[sdk=iphoneos*]'] = 'old conditional UUID'
        self.project['objects']['appRelease']['buildSettings']['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = 'old identity'
        context, _, _ = self.prepare()
        patched = helper.patch(self.project, context)
        for identifier in ('app', 'widgets', 'share'):
            for configuration in ('Debug', 'Release'):
                settings = patched['objects'][identifier + configuration]['buildSettings']
                self.assertEqual(settings['CODE_SIGN_STYLE'], 'Manual')
                self.assertEqual(settings['PROVISIONING_PROFILE'], PROFILE_UUID)
                self.assertEqual(settings['DEVELOPMENT_TEAM'], TEAM)
                self.assertEqual(settings['CODE_SIGN_IDENTITY'], context['identitySHA1'])
                self.assertEqual(settings['PROVISIONING_PROFILE_SPECIFIER'], context['profileName'])
                self.assertNotIn('PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]', settings)
                self.assertNotIn('PROVISIONING_PROFILE[sdk=iphoneos*]', settings)
                self.assertNotIn('CODE_SIGN_IDENTITY[sdk=iphoneos*]', settings)
        for identifier in ('project', 'framework', 'frameworkDebug', 'frameworkRelease', 'mac', 'macDebug', 'macRelease'):
            self.assertEqual(patched['objects'][identifier], self.project['objects'][identifier])
        self.assertNotIn('PROVISIONING_PROFILE', self.project['objects']['appRelease']['buildSettings'])

    def test_missing_extension_framework_selection_and_wrong_extension_id_are_rejected(self):
        for names in (NAMES[:-1], NAMES + ['MirrorSystem'], NAMES + ['MirrorMac']):
            with self.subTest(names=names), self.assertRaises(helper.ValidationError):
                self.prepare(names=names)
        project = copy.deepcopy(self.project)
        for configuration in ('Debug', 'Release'):
            project['objects']['share' + configuration]['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.other.share'
        with self.assertRaisesRegex(helper.ValidationError, '^EXTENSION_BUNDLE_ID$'):
            self.prepare(project=project)

    def test_missing_or_invalid_profile_name_cannot_select_another_profile(self):
        context, _, _ = self.prepare()
        for name in (None, '', 'synthetic\nprofile'):
            invalid = dict(context, profileName=name)
            with self.subTest(name=name), self.assertRaisesRegex(helper.ValidationError, '^CONTEXT_PROFILE_NAME$'):
                helper.patch(self.project, invalid)

    def test_context_project_and_entitlement_changes_prevent_unvalidated_patch(self):
        context, _, _ = self.prepare()
        changed = copy.deepcopy(self.project)
        changed['objects']['widgetsRelease']['buildSettings']['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.other.widgets'
        with self.assertRaisesRegex(helper.ValidationError, '^CONTEXT_PROJECT_CHANGED$'):
            helper.patch(changed, context)
        (self.root / 'Entitlements/share.plist').write_bytes(plistlib.dumps({'get-task-allow': True}))
        with self.assertRaisesRegex(helper.ValidationError, '^CONTEXT_ENTITLEMENTS_CHANGED$'):
            helper.patch(self.project, context)

    def test_cli_outputs_safe_manifest_and_writes_private_context_export_and_project(self):
        profile_path, certificate_path, project_path = [self.root / name for name in ('profile.plist', 'certificate.der', 'project.json')]
        profile_path.write_bytes(plistlib.dumps(self.profile))
        certificate_path.write_bytes(CERTIFICATE)
        project_path.write_text(json.dumps(self.project))
        context_path, manifest_path, options_path = [self.root / name for name in ('context.json', 'manifest.json', 'ExportOptions.plist')]
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = helper.main(['prepare', '--profile-plist', str(profile_path), '--certificate', str(certificate_path),
                                  '--project-json', str(project_path), '--project-root', str(self.root), '--targets', *NAMES,
                                  '--context-out', str(context_path), '--manifest-out', str(manifest_path),
                                  '--export-options-out', str(options_path)])
        self.assertEqual(status, 0, stderr.getvalue())
        self.assertEqual(json.loads(stdout.getvalue()), json.loads(manifest_path.read_text()))
        self.assertEqual(context_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(options_path.stat().st_mode & 0o777, 0o600)
        for private in (TEAM, PROFILE_UUID, self.profile['Name'], self.profile['ProvisionedDevices'][0]):
            self.assertNotIn(private, stdout.getvalue() + stderr.getvalue())
        output = self.root / 'signed-project.json'
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(helper.main(['patch', '--project-json', str(project_path), '--context', str(context_path), '--output', str(output)]), 0)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.profile['Entitlements']['get-task-allow'] = True
        profile_path.write_bytes(plistlib.dumps(self.profile))
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = helper.main(['prepare', '--profile-plist', str(profile_path), '--certificate', str(certificate_path),
                                  '--project-json', str(project_path), '--project-root', str(self.root), '--targets', *NAMES,
                                  '--context-out', str(context_path), '--manifest-out', str(manifest_path),
                                  '--export-options-out', str(options_path)])
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(stderr.getvalue()), {'result': 'fail', 'code': 'PROFILE_DEBUGGING'})
        self.assertEqual(stdout.getvalue(), '')

    def test_metadata_rejects_private_or_unstructured_fields(self):
        for value in ({'teamID': TEAM}, {'sdkVersion': TEAM}, {'commitSHA': 'not a hash'}, {'runID': 'private runner'}):
            with self.subTest(keys=list(value)), self.assertRaisesRegex(helper.ValidationError, '^BUILD_METADATA$'):
                helper.public_metadata(value)


if __name__ == '__main__':
    unittest.main()
