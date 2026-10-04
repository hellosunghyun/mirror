"""합성 프로파일 구조만 사용한다. 실제 CMS/Apple 인증서/서명 성공을 대신하지 않는다."""

import base64
import contextlib
import copy
import hashlib
import importlib.util
import io
import itertools
import json
import plistlib
import tempfile
import unittest
from unittest import mock
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


def explicit_profile_fixtures():
    profiles = {}
    for index, (name, suffix) in enumerate(zip(NAMES, ('', '.widgets', '.share')), start=1):
        profile = profile_fixture()
        profile.update(UUID=f'abcdef0{index}-2345-6789-abcd-ef0123456789', Name=f'private synthetic profile {index}')
        profile['Entitlements']['application-identifier'] = TEAM + '.com.baserize.mirror' + suffix
        profiles[name] = profile
    return profiles


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

    def prepare_explicit(self, profiles=None):
        return helper.prepare(None, CERTIFICATE, self.project, self.root, NAMES, now=NOW,
                              target_profiles=profiles if profiles is not None else explicit_profile_fixtures())

    def test_profile_input_selection_rejects_partial_even_with_legacy_and_prefers_complete_explicit(self):
        for legacy, present in itertools.product((False, True), itertools.product((False, True), repeat=3)):
            environment = {'IOS_ADHOC_PROFILE_BASE64': 'legacy-private'} if legacy else {}
            environment.update({secret: 'explicit-private' for (_, _, secret), enabled in zip(helper.PROFILE_INPUTS, present) if enabled})
            with self.subTest(legacy=legacy, present=present):
                if any(present) and not all(present):
                    with self.assertRaisesRegex(helper.ValidationError, '^PROFILE_INPUTS_PARTIAL$'):
                        helper.profile_inputs(environment)
                elif not any(present) and not legacy:
                    with self.assertRaisesRegex(helper.ValidationError, '^PROFILE_INPUT_MISSING$'):
                        helper.profile_inputs(environment)
                else:
                    selected = helper.profile_inputs(environment)
                    self.assertEqual(len(selected), 3 if all(present) else 1)
                    if all(present):
                        self.assertEqual([value[0] for value in selected], NAMES)
                        self.assertNotIn('IOS_ADHOC_PROFILE_BASE64', [value[2] for value in selected])

    def test_input_cli_and_decode_keep_values_private_and_validate_before_writing(self):
        environment = {'IOS_DISTRIBUTION_P12_BASE64': base64.b64encode(b'private synthetic p12').decode(),
                       'IOS_DISTRIBUTION_P12_PASSWORD': 'private synthetic password',
                       'IOS_ADHOC_PROFILE_BASE64': 'ignored invalid legacy value'}
        environment.update({secret: base64.b64encode(('private synthetic ' + name).encode()).decode()
                            for name, _, secret in helper.PROFILE_INPUTS})
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict('os.environ', environment, clear=True), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(helper.main(['check-inputs']), 0)
        self.assertEqual(json.loads(stdout.getvalue()), {'result': 'pass', 'profileMode': 'explicit'})
        self.assertEqual(stderr.getvalue(), '')
        directory = self.root / 'decoded'
        inputs = helper.decode_inputs(environment, directory)
        self.assertEqual(inputs['mode'], 'explicit')
        for path in directory.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual({path.name for path in directory.iterdir()},
                         {'distribution.p12', 'app.mobileprovision', 'widgets.mobileprovision', 'share.mobileprovision', 'profile-inputs.json'})
        for secret in ('IOS_ADHOC_WIDGET_PROFILE_BASE64', 'IOS_DISTRIBUTION_P12_BASE64'):
            invalid = dict(environment, **{secret: '!invalid-private-value!'})
            with self.assertRaisesRegex(helper.ValidationError, '^SIGNING_BASE64$'):
                helper.decode_inputs(invalid, self.root / 'invalid')
            self.assertFalse((self.root / 'invalid').exists())
        for secret, code in (('IOS_DISTRIBUTION_P12_BASE64', 'P12_INPUT_MISSING'),
                             ('IOS_DISTRIBUTION_P12_PASSWORD', 'P12_PASSWORD_MISSING')):
            with self.assertRaisesRegex(helper.ValidationError, '^' + code + '$'):
                helper.check_inputs(dict(environment, **{secret: ''}))

    def test_explicit_profiles_map_each_target_and_preserve_legacy_context(self):
        profiles = explicit_profile_fixtures()
        profiles[NAMES[1]]['UUID'] = profiles[NAMES[1]]['UUID'].upper()
        profiles[NAMES[1]]['ApplicationIdentifierPrefix'] = ['LEGACY0001']
        profiles[NAMES[1]]['Entitlements']['application-identifier'] = 'LEGACY0001.com.baserize.mirror.widgets'
        profiles[NAMES[1]]['Entitlements']['keychain-access-groups'] = ['LEGACY0001.*']
        profiles[NAMES[1]]['ProvisionedDevices'].append('extra extension device')
        profiles[NAMES[2]]['ExpirationDate'] = datetime(2098, 1, 1)
        context, manifest, options = self.prepare_explicit(profiles)
        patched = helper.patch(self.project, context)
        self.assertEqual(context['schemaVersion'], 2)
        self.assertEqual(manifest['expiresAtUTC'], '2098-01-01T00:00:00Z')
        self.assertEqual(manifest['deviceCount'], 1)
        self.assertEqual(manifest['certificateCount'], 1)
        for identifier, name in zip(('app', 'widgets', 'share'), NAMES):
            for configuration in ('Debug', 'Release'):
                settings = patched['objects'][identifier + configuration]['buildSettings']
                self.assertEqual(settings['PROVISIONING_PROFILE'], profiles[name]['UUID'])
                self.assertEqual(settings['PROVISIONING_PROFILE_SPECIFIER'], profiles[name]['Name'])
                self.assertEqual(options['provisioningProfiles'][settings['PRODUCT_BUNDLE_IDENTIFIER']], profiles[name]['UUID'])
            identity = helper.target_identity(context, name)
            self.assertEqual(identity['applicationIdentifierPrefix'], profiles[name]['ApplicationIdentifierPrefix'][0])
        for identifier in ('frameworkDebug', 'frameworkRelease', 'macDebug', 'macRelease'):
            self.assertEqual(patched['objects'][identifier], self.project['objects'][identifier])
        public = json.dumps(manifest)
        for profile in profiles.values():
            for value in (profile['UUID'], profile['Name'], *profile['ProvisionedDevices']):
                self.assertNotIn(value, public)
        legacy, _, _ = self.prepare()
        self.assertEqual(legacy['schemaVersion'], 1)
        self.assertNotIn('targetProfiles', legacy)

    def test_explicit_profile_set_rejects_missing_swapped_wildcard_and_conflicting_identity(self):
        cases = []
        profiles = explicit_profile_fixtures(); profiles.pop(NAMES[2])
        cases.append((profiles, 'PROFILE_TARGETS'))
        profiles = explicit_profile_fixtures(); profiles[NAMES[1]], profiles[NAMES[2]] = profiles[NAMES[2]], profiles[NAMES[1]]
        cases.append((profiles, 'BUNDLE_MISMATCH'))
        profiles = explicit_profile_fixtures(); profiles[NAMES[1]]['Entitlements']['application-identifier'] = TEAM + '.*'
        cases.append((profiles, 'PROFILE_EXPLICIT_REQUIRED'))
        profiles = explicit_profile_fixtures(); profiles[NAMES[1]]['TeamIdentifier'] = ['OTHERTEAM1']
        profiles[NAMES[1]]['Entitlements']['com.apple.developer.team-identifier'] = 'OTHERTEAM1'
        cases.append((profiles, 'PROFILE_TEAM_MISMATCH'))
        for key, value, code in [('UUID', explicit_profile_fixtures()[NAMES[0]]['UUID'].upper(), 'PROFILE_UUID_COLLISION'),
                                  ('Name', explicit_profile_fixtures()[NAMES[0]]['Name'].upper(), 'PROFILE_NAME_COLLISION'),
                                  ('DeveloperCertificates', [OTHER_CERTIFICATE], 'CERTIFICATE_MISMATCH'),
                                  ('ProvisionedDevices', ['different device'], 'PROFILE_DEVICE_COVERAGE'),
                                  ('ExpirationDate', NOW, 'PROFILE_EXPIRED'),
                                  ('Platform', ['macOS'], 'PROFILE_PLATFORM')]:
            profiles = explicit_profile_fixtures(); profiles[NAMES[2]][key] = value
            cases.append((profiles, code))
        for profiles, code in cases:
            with self.subTest(code=code), self.assertRaisesRegex(helper.ValidationError, '^' + code + '$'):
                self.prepare_explicit(profiles)

    def test_each_requested_capability_uses_its_target_profile(self):
        profiles = explicit_profile_fixtures()
        requested = {'com.apple.security.application-groups': ['group.synthetic'],
                     'com.apple.developer.icloud-container-identifiers': ['iCloud.synthetic']}
        for profile in profiles.values():
            profile['Entitlements'].update(copy.deepcopy(requested))
        (self.root / 'Entitlements/widgets.plist').write_bytes(plistlib.dumps(requested))
        _, manifest, _ = self.prepare_explicit(profiles)
        self.assertTrue(all(manifest['capabilities'].values()))
        del profiles[NAMES[0]]['Entitlements']['com.apple.developer.icloud-container-identifiers']
        _, manifest, _ = self.prepare_explicit(profiles)
        self.assertFalse(manifest['capabilities']['cloudContainersAllowed'])
        del profiles[NAMES[1]]['Entitlements']['com.apple.security.application-groups']
        with self.assertRaisesRegex(helper.ValidationError, '^ENTITLEMENT_NOT_ALLOWED$'):
            self.prepare_explicit(profiles)

    def test_certificate_selection_requires_one_common_valid_private_key_identity(self):
        profiles = explicit_profile_fixtures()
        fingerprint = hashlib.sha1(CERTIFICATE).hexdigest().upper()
        other = hashlib.sha1(OTHER_CERTIFICATE).hexdigest().upper()
        profiles[NAMES[0]]['DeveloperCertificates'].append(OTHER_CERTIFICATE)
        self.assertEqual(helper.common_certificates(list(profiles.values()), {fingerprint, other}), [CERTIFICATE])
        profiles[NAMES[2]]['DeveloperCertificates'] = [OTHER_CERTIFICATE]
        self.assertEqual(helper.common_certificates(list(profiles.values()), {fingerprint, other}), [])
        for profile in profiles.values():
            profile['DeveloperCertificates'] = [CERTIFICATE, OTHER_CERTIFICATE]
        directory = self.root / 'identity-selection'; directory.mkdir()
        helper.decode_inputs({'IOS_DISTRIBUTION_P12_BASE64': 'YQ==',
                              **{secret: 'YQ==' for _, _, secret in helper.PROFILE_INPUTS}}, directory)
        for name, stem, _ in helper.PROFILE_INPUTS:
            (directory / (stem + '.plist')).write_bytes(plistlib.dumps(profiles[name]))
        (directory / 'all-identities.txt').write_text(f'  1) {fingerprint} private\n  2) {other} private\n')
        (directory / 'identities.txt').write_text(f'  1) {fingerprint} private\n  2) {other} private\n')
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(helper.ValidationError, '^COMMON_SIGNING_IDENTITY$'):
            helper.select_certificate(directory, False)
        (directory / 'identities.txt').write_text(f'  1) {fingerprint} private\n')
        with contextlib.redirect_stdout(io.StringIO()):
            helper.select_certificate(directory, False)
        self.assertEqual((directory / 'certificate.der').read_bytes(), CERTIFICATE)
        self.assertEqual((directory / 'certificate.der').stat().st_mode & 0o777, 0o600)

    def test_exported_profiles_and_signed_entitlements_match_each_target(self):
        profiles = explicit_profile_fixtures()
        context, _, _ = self.prepare_explicit(profiles)
        for target in context['targets']:
            profile = profiles[target['name']]
            actual = {key: profile['Entitlements'][key] for key in
                      ('application-identifier', 'com.apple.developer.team-identifier', 'get-task-allow')}
            helper.verify_embedded(context, target['bundleIdentifier'], profile, actual, CERTIFICATE, now=NOW)
            wrong = copy.deepcopy(profile); wrong['UUID'] = PROFILE_UUID
            with self.assertRaisesRegex(helper.ValidationError, '^EXPORTED_PROFILE$'):
                helper.verify_embedded(context, target['bundleIdentifier'], wrong, actual, CERTIFICATE, now=NOW)
            wrong = copy.deepcopy(profile); wrong['ProvisionedDevices'].append('extra unpublished device')
            with self.assertRaisesRegex(helper.ValidationError, '^EXPORTED_PROFILE_CONTENT$'):
                helper.verify_embedded(context, target['bundleIdentifier'], wrong, actual, CERTIFICATE, now=NOW)
            with self.assertRaisesRegex(helper.ValidationError, '^EXPORTED_CERTIFICATE$'):
                helper.verify_embedded(context, target['bundleIdentifier'], profile, actual, OTHER_CERTIFICATE, now=NOW)
            for key, value, code in [('get-task-allow', True, 'EXPORTED_DEBUGGING'),
                                     ('application-identifier', 'LEGACY0001.' + target['bundleIdentifier'], 'EXPORTED_IDENTITY'),
                                     ('com.apple.security.application-groups', ['group.unpermitted'], 'ENTITLEMENT_NOT_ALLOWED')]:
                with self.subTest(target=target['name'], key=key), self.assertRaisesRegex(helper.ValidationError, '^' + code + '$'):
                    helper.verify_embedded(context, target['bundleIdentifier'], profile, dict(actual, **{key: value}), CERTIFICATE, now=NOW)

    def test_legacy_export_accepts_same_wildcard_profile_with_per_bundle_signed_identity(self):
        context, _, _ = self.prepare()
        for target in context['targets']:
            actual = {'application-identifier': TEAM + '.' + target['bundleIdentifier'],
                      'com.apple.developer.team-identifier': TEAM, 'get-task-allow': False,
                      'keychain-access-groups': [TEAM + '.' + target['bundleIdentifier']]}
            helper.verify_embedded(context, target['bundleIdentifier'], self.profile, actual, CERTIFICATE, now=NOW)

    def test_explicit_private_context_cannot_swap_identity_or_profile_selection(self):
        context, _, _ = self.prepare_explicit()
        for key, value, code in [('teamID', 'OTHERTEAM1', 'CONTEXT_PROFILE_IDENTITY'),
                                 ('identitySHA1', 'F' * 40, 'CONTEXT_PROFILE_IDENTITY'),
                                 ('profileUUID', context['targetProfiles'][NAMES[0]]['profileUUID'], 'CONTEXT_PROFILE_COLLISION'),
                                 ('profileName', context['targetProfiles'][NAMES[0]]['profileName'], 'CONTEXT_PROFILE_COLLISION'),
                                 ('profileSHA256', '', 'CONTEXT_PROFILE_DIGEST'),
                                 ('applicationIdentifierPrefix', 'malformed', 'CONTEXT_PREFIX')]:
            changed = copy.deepcopy(context)
            changed['targetProfiles'][NAMES[1]][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(helper.ValidationError, '^' + code + '$'):
                helper.patch(self.project, changed)

    def test_exported_requested_capability_cannot_be_omitted_or_source_changed(self):
        profiles = explicit_profile_fixtures()
        key = 'com.apple.security.application-groups'
        profiles[NAMES[1]]['Entitlements'][key] = ['group.synthetic']
        path = self.root / 'Entitlements/widgets.plist'
        path.write_bytes(plistlib.dumps({key: ['group.synthetic']}))
        context, _, _ = self.prepare_explicit(profiles)
        profile = profiles[NAMES[1]]
        actual = {name: profile['Entitlements'][name] for name in
                  ('application-identifier', 'com.apple.developer.team-identifier', 'get-task-allow')}
        with self.assertRaisesRegex(helper.ValidationError, '^EXPORTED_ENTITLEMENTS_MISSING$'):
            helper.verify_embedded(context, 'com.baserize.mirror.widgets', profile, actual, CERTIFICATE, now=NOW)
        actual[key] = ['group.synthetic']
        helper.verify_embedded(context, 'com.baserize.mirror.widgets', profile, actual, CERTIFICATE, now=NOW)
        path.write_bytes(plistlib.dumps({}))
        with self.assertRaisesRegex(helper.ValidationError, '^CONTEXT_ENTITLEMENTS_CHANGED$'):
            helper.verify_embedded(context, 'com.baserize.mirror.widgets', profile, actual, CERTIFICATE, now=NOW)

    def test_explicit_cli_uses_private_context_and_export_with_safe_errors(self):
        directory = self.root / 'explicit-cli'; directory.mkdir()
        profiles = explicit_profile_fixtures()
        for name, stem, _ in helper.PROFILE_INPUTS:
            (directory / (stem + '.plist')).write_bytes(plistlib.dumps(profiles[name]))
        (directory / 'certificate.der').write_bytes(CERTIFICATE)
        (directory / 'project.json').write_text(json.dumps(self.project))
        arguments = ['prepare', '--target-profiles-dir', str(directory), '--certificate', str(directory / 'certificate.der'),
                     '--project-json', str(directory / 'project.json'), '--project-root', str(self.root), '--targets', *NAMES,
                     '--context-out', str(directory / 'context.json'), '--manifest-out', str(directory / 'manifest.json'),
                     '--export-options-out', str(directory / 'ExportOptions.plist')]
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(helper.main(arguments), 0)
        self.assertEqual(stderr.getvalue(), '')
        for filename in ('context.json', 'ExportOptions.plist'):
            self.assertEqual((directory / filename).stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads((directory / 'context.json').read_text())['schemaVersion'], 2)
        for profile in profiles.values():
            for value in (TEAM, profile['UUID'], profile['Name'], *profile['ProvisionedDevices']):
                self.assertNotIn(value, stdout.getvalue() + stderr.getvalue())
        profiles[NAMES[2]]['Entitlements']['get-task-allow'] = True
        (directory / 'share.plist').write_bytes(plistlib.dumps(profiles[NAMES[2]]))
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(helper.main(arguments), 1)
        self.assertEqual(stdout.getvalue(), '')
        self.assertEqual(json.loads(stderr.getvalue()), {'result': 'fail', 'code': 'PROFILE_DEBUGGING'})


if __name__ == '__main__':
    unittest.main()
