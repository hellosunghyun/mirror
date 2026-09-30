#!/usr/bin/env python3
"""private 프로파일/인증서 파일을 검증하고 iOS 앱 타깃의 수동 서명을 준비한다.

CMS 검증·X509 검증·키체인 import는 호출하는 archive shell이 수행한다.
이 도구는 프로파일의 허용 범위와 선택한 인증서 DER의 SHA1 일치를 검증한다.
"""

import argparse
import base64
import copy
import hashlib
import json
import os
import plistlib
import re
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path


class ValidationError(ValueError):
    """private 입력값을 포함하지 않는 고정 오류 코드만 외부로 전달한다."""


def require(condition, code):
    if not condition:
        raise ValidationError(code)


def read_file(path, limit=4 * 1024 * 1024):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= limit, 'INPUT_FILE')
    return path.read_bytes()


def load_json(path):
    value = json.loads(read_file(path))
    require(isinstance(value, dict), 'JSON_ROOT')
    return value


def load_plist(path):
    value = plistlib.loads(read_file(path))
    require(isinstance(value, dict), 'PLIST_ROOT')
    return value


def read_certificate(path):
    raw = read_file(path, 256 * 1024)
    if raw.lstrip().startswith(b'-----BEGIN'):
        match = re.fullmatch(rb'\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----\s*', raw)
        require(match is not None, 'CERTIFICATE_PEM')
        raw = base64.b64decode(re.sub(rb'\s+', b'', match.group(1)), validate=True)
    require(isinstance(raw, bytes) and len(raw) > 2 and raw[0] == 0x30, 'CERTIFICATE_DER')
    length = raw[1]
    offset = 2
    if length & 0x80:
        width = length & 0x7f
        require(1 <= width <= 4 and len(raw) >= 2 + width, 'CERTIFICATE_DER')
        length = int.from_bytes(raw[2:2 + width], 'big')
        offset += width
    require(length > 0 and offset + length == len(raw), 'CERTIFICATE_DER')
    return raw


def valid_bundle_id(value):
    return isinstance(value, str) and len(value) <= 255 and re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', value) is not None


def identifier_matches(pattern, identifier):
    """별표는 전체 또는 마지막 dot component만 허용해 범위가 넓어지는 오타를 거부한다."""
    if not isinstance(pattern, str) or not isinstance(identifier, str) or '*' in identifier:
        return False
    if '*' not in pattern:
        return pattern == identifier
    if pattern == '*':
        return bool(identifier)
    if pattern.endswith('.*') and pattern.count('*') == 1:
        return identifier.startswith(pattern[:-1]) and len(identifier) > len(pattern) - 1
    return False


def utc(value, code):
    require(isinstance(value, datetime), code)
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def profile_identity(profile, certificate, bundle_ids, now=None):
    now = utc(now or datetime.now(timezone.utc), 'CURRENT_TIME')
    require(isinstance(profile.get('Platform'), list) and 'iOS' in profile['Platform'], 'PROFILE_PLATFORM')
    teams = profile.get('TeamIdentifier')
    prefixes = profile.get('ApplicationIdentifierPrefix')
    require(isinstance(teams, list) and len(teams) == 1 and isinstance(teams[0], str) and re.fullmatch(r'[A-Z0-9]{10}', teams[0]) is not None, 'PROFILE_TEAM')
    require(isinstance(prefixes, list) and len(prefixes) == 1 and isinstance(prefixes[0], str) and re.fullmatch(r'[A-Z0-9]{10}', prefixes[0]) is not None, 'PROFILE_PREFIX')
    expiry = utc(profile.get('ExpirationDate'), 'PROFILE_EXPIRY')
    creation = utc(profile.get('CreationDate'), 'PROFILE_CREATION')
    require(creation <= now < expiry and creation < expiry, 'PROFILE_EXPIRED')
    entitlements = profile.get('Entitlements')
    require(isinstance(entitlements, dict), 'PROFILE_ENTITLEMENTS')
    require(entitlements.get('get-task-allow') is False, 'PROFILE_DEBUGGING')
    require(profile.get('ProvisionsAllDevices', False) is False, 'PROFILE_ENTERPRISE')
    devices = profile.get('ProvisionedDevices')
    require(isinstance(devices, list) and bool(devices) and all(isinstance(device, str) and device for device in devices), 'PROFILE_DEVICES')
    require(len(set(devices)) == len(devices), 'PROFILE_DEVICES')
    certificates = profile.get('DeveloperCertificates')
    require(isinstance(certificates, list) and bool(certificates) and all(isinstance(value, bytes) and value for value in certificates), 'PROFILE_CERTIFICATES')
    fingerprint = hashlib.sha1(certificate).hexdigest().upper()
    require(any(hashlib.sha1(value).hexdigest().upper() == fingerprint for value in certificates), 'CERTIFICATE_MISMATCH')
    require(entitlements.get('com.apple.developer.team-identifier') == teams[0], 'ENTITLEMENT_TEAM')
    application_id = entitlements.get('application-identifier')
    require(isinstance(application_id, str) and application_id.startswith(prefixes[0] + '.'), 'PROFILE_APPLICATION_ID')
    pattern = application_id[len(prefixes[0]) + 1:]
    require(pattern == '*' or valid_bundle_id(pattern) or (pattern.endswith('.*') and re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*', pattern[:-2]) is not None), 'PROFILE_WILDCARD')
    require(all(valid_bundle_id(value) and identifier_matches(pattern, value) for value in bundle_ids), 'BUNDLE_MISMATCH')
    profile_uuid = profile.get('UUID')
    require(isinstance(profile_uuid, str) and re.fullmatch(r'[A-Fa-f0-9-]{36}', profile_uuid) is not None, 'PROFILE_UUID')
    try:
        profile_uuid = str(uuid.UUID(profile_uuid)).upper()
    except (ValueError, AttributeError):
        raise ValidationError('PROFILE_UUID') from None
    name = profile.get('Name')
    require(isinstance(name, str) and 0 < len(name) <= 256 and name.isprintable(), 'PROFILE_NAME')
    return {'teamID': teams[0], 'profileUUID': profile_uuid, 'profileName': name,
            'identitySHA1': fingerprint, 'applicationIdentifierPrefix': prefixes[0],
            'profileExpiresAtUTC': expiry.isoformat().replace('+00:00', 'Z')}


def expand_entitlement(value, team, prefix, bundle_id):
    if isinstance(value, str):
        replacements = {'AppIdentifierPrefix': prefix + '.', 'TeamIdentifierPrefix': team + '.',
                        'CFBundleIdentifier': bundle_id, 'PRODUCT_BUNDLE_IDENTIFIER': bundle_id}
        for key, replacement in replacements.items():
            value = value.replace('$(' + key + ')', replacement).replace('${' + key + '}', replacement)
        require('$(' not in value and '${' not in value, 'ENTITLEMENT_VARIABLE')
        return value
    if isinstance(value, list):
        return [expand_entitlement(item, team, prefix, bundle_id) for item in value]
    if isinstance(value, dict):
        return {key: expand_entitlement(item, team, prefix, bundle_id) for key, item in value.items()}
    return value


def allowed_value(requested, permitted):
    if type(requested) is not type(permitted):
        return False
    if isinstance(requested, str):
        return identifier_matches(permitted, requested)
    if isinstance(requested, dict):
        return all(key in permitted and allowed_value(value, permitted[key]) for key, value in requested.items())
    if isinstance(requested, list):
        return all(any(allowed_value(value, candidate) for candidate in permitted) for value in requested)
    return isinstance(requested, (bool, int)) and requested == permitted


def validate_entitlements(requested, permitted, bundle_id, identity):
    require(isinstance(requested, dict), 'REQUESTED_ENTITLEMENTS')
    requested = expand_entitlement(requested, identity['teamID'], identity['applicationIdentifierPrefix'], bundle_id)
    if 'application-identifier' in requested:
        require(requested['application-identifier'] == identity['applicationIdentifierPrefix'] + '.' + bundle_id, 'REQUESTED_APPLICATION_ID')
    if 'com.apple.developer.team-identifier' in requested:
        require(requested['com.apple.developer.team-identifier'] == identity['teamID'], 'REQUESTED_TEAM')
    require(all(key in permitted and allowed_value(value, permitted[key]) for key, value in requested.items()), 'ENTITLEMENT_NOT_ALLOWED')
    return requested


def target_configurations(project, names):
    objects = project.get('objects')
    require(isinstance(objects, dict) and isinstance(project.get('rootObject'), str), 'PROJECT_STRUCTURE')
    root = objects.get(project['rootObject'], {})
    require(root.get('isa') == 'PBXProject' and isinstance(root.get('targets'), list), 'PROJECT_STRUCTURE')
    require(bool(names) and len(set(names)) == len(names), 'TARGET_NAMES')
    selected = []
    ios_app_names = []
    for target_id in root['targets']:
        target = objects.get(target_id, {})
        if target.get('isa') != 'PBXNativeTarget' or target.get('productType') not in (
                'com.apple.product-type.application', 'com.apple.product-type.app-extension'):
            continue
        configuration_list = objects.get(target.get('buildConfigurationList'), {})
        require(configuration_list.get('isa') == 'XCConfigurationList' and isinstance(configuration_list.get('buildConfigurations'), list), 'TARGET_CONFIGURATIONS')
        configurations = []
        for configuration_id in configuration_list['buildConfigurations']:
            configuration = objects.get(configuration_id, {})
            settings = configuration.get('buildSettings')
            require(configuration.get('isa') == 'XCBuildConfiguration' and isinstance(settings, dict), 'TARGET_CONFIGURATIONS')
            configurations.append((configuration_id, configuration, settings))
        if not configurations or not all(settings.get('SDKROOT') == 'iphoneos' for _, _, settings in configurations):
            require(target.get('name') not in names, 'TARGET_PLATFORM')
            continue
        ios_app_names.append(target.get('name'))
        if target.get('name') in names:
            bundle_ids = {settings.get('PRODUCT_BUNDLE_IDENTIFIER') for _, _, settings in configurations}
            require(len(bundle_ids) == 1 and valid_bundle_id(next(iter(bundle_ids))), 'TARGET_BUNDLE_ID')
            require(any(configuration.get('name') == 'Release' for _, configuration, _ in configurations), 'TARGET_RELEASE')
            selected.append({'id': target_id, 'name': target['name'], 'productType': target['productType'],
                             'bundleIdentifier': next(iter(bundle_ids)), 'configurations': configurations})
    require(set(ios_app_names) == set(names) and len(selected) == len(names), 'TARGET_SELECTION')
    apps = [target for target in selected if target['productType'] == 'com.apple.product-type.application']
    require(len(apps) == 1, 'TARGET_MAIN_APPLICATION')
    require(all(target is apps[0] or target['bundleIdentifier'].startswith(apps[0]['bundleIdentifier'] + '.') for target in selected), 'EXTENSION_BUNDLE_ID')
    require(len({target['bundleIdentifier'] for target in selected}) == len(selected), 'TARGET_BUNDLE_DUPLICATE')
    return selected


def entitlement_path(root, settings):
    value = settings.get('CODE_SIGN_ENTITLEMENTS')
    if not value:
        return None
    require(isinstance(value, str), 'ENTITLEMENT_PATH')
    for variable in ('SRCROOT', 'PROJECT_DIR'):
        value = value.replace('$(' + variable + ')', str(root)).replace('${' + variable + '}', str(root))
    require('$(' not in value and '${' not in value, 'ENTITLEMENT_PATH')
    path = (root / value).resolve()
    require(path.is_relative_to(root), 'ENTITLEMENT_PATH')
    return path


def public_metadata(value):
    require(isinstance(value, dict) and set(value) <= {'commitSHA', 'buildNumber', 'runID', 'version', 'xcodeVersion', 'sdkVersion'}, 'BUILD_METADATA')
    patterns = {'commitSHA': r'[a-fA-F0-9]{40}|[a-fA-F0-9]{64}', 'buildNumber': r'[0-9]+(?:\.[0-9]+){0,2}',
                'runID': r'[0-9]+', 'version': r'[0-9]+(?:\.[0-9]+){0,2}',
                'xcodeVersion': r'[0-9]+(?:\.[0-9]+){0,3}', 'sdkVersion': r'[0-9]+(?:\.[0-9]+){0,3}'}
    require(all(isinstance(item, str) and len(item) <= 128 and re.fullmatch(patterns[key], item) is not None for key, item in value.items()), 'BUILD_METADATA')
    return value


def project_digest(project):
    return hashlib.sha256(json.dumps(project, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def prepare(profile, certificate, project, root, names, metadata=None, now=None):
    root = Path(root).resolve()
    targets = target_configurations(project, names)
    identity = profile_identity(profile, certificate, [target['bundleIdentifier'] for target in targets], now)
    requested = []
    stored_targets = []
    for target in targets:
        configurations = []
        for configuration_id, configuration, settings in target['configurations']:
            path = entitlement_path(root, settings)
            entitlements = load_plist(path) if path else {}
            requested.append(validate_entitlements(entitlements, profile['Entitlements'], target['bundleIdentifier'], identity))
            configurations.append({'id': configuration_id, 'name': configuration['name'],
                                   'entitlementsPath': str(path) if path else None,
                                   'entitlementsSHA256': hashlib.sha256(read_file(path)).hexdigest() if path else None})
        stored_targets.append({key: target[key] for key in ('id', 'name', 'productType', 'bundleIdentifier')} | {'configurations': configurations})
    context = {'schemaVersion': 1, 'distribution': 'ad-hoc', **identity, 'sourceProjectSHA256': project_digest(project),
               'projectRoot': str(root), 'targets': stored_targets}
    permitted = profile['Entitlements']
    group_keys = ('com.apple.security.application-groups',)
    cloud_keys = ('com.apple.developer.icloud-container-identifiers', 'com.apple.developer.ubiquity-container-identifiers')
    manifest = {'result': 'pass', 'distribution': 'ad-hoc', 'exportMethod': 'release-testing', 'platform': 'iOS',
                'expiresAtUTC': identity['profileExpiresAtUTC'], 'deviceCount': len(profile['ProvisionedDevices']),
                'certificateCount': len(profile['DeveloperCertificates']), 'certificateMatchesProfile': True,
                'requestedEntitlementsValidated': True,
                'targets': [{key: target[key] for key in ('name', 'bundleIdentifier')} for target in targets],
                'capabilities': {'appGroupsAllowed': any(permitted.get(key) for key in group_keys),
                                 'cloudContainersAllowed': any(permitted.get(key) for key in cloud_keys),
                                 'appGroupsRequested': any(value.get(key) for value in requested for key in group_keys),
                                 'cloudContainersRequested': any(value.get(key) for value in requested for key in cloud_keys)},
                **public_metadata(metadata or {})}
    export_options = {'method': 'release-testing', 'signingStyle': 'manual', 'teamID': identity['teamID'],
                      'signingCertificate': identity['identitySHA1'], 'stripSwiftSymbols': True,
                      'provisioningProfiles': {target['bundleIdentifier']: identity['profileUUID'] for target in targets}}
    return context, manifest, export_options


def patch(project, context):
    require(type(context.get('schemaVersion')) is int and context['schemaVersion'] == 1 and context.get('distribution') == 'ad-hoc', 'CONTEXT_SCHEMA')
    require(re.fullmatch(r'[A-Z0-9]{10}', str(context.get('teamID', ''))) is not None, 'CONTEXT_TEAM')
    require(re.fullmatch(r'[A-F0-9]{40}', str(context.get('identitySHA1', ''))) is not None, 'CONTEXT_IDENTITY')
    require(isinstance(context.get('profileUUID'), str) and re.fullmatch(r'[A-F0-9-]{36}', context['profileUUID']) is not None, 'CONTEXT_PROFILE')
    require(context.get('sourceProjectSHA256') == project_digest(project), 'CONTEXT_PROJECT_CHANGED')
    stored = context.get('targets')
    require(isinstance(stored, list) and all(isinstance(target, dict) and isinstance(target.get('name'), str) for target in stored), 'CONTEXT_TARGETS')
    actual = target_configurations(project, [target['name'] for target in stored])
    require({target['id'] for target in actual} == {target.get('id') for target in stored}, 'CONTEXT_TARGETS')
    result = copy.deepcopy(project)
    for target in actual:
        expected = next(item for item in stored if item['id'] == target['id'])
        require(expected.get('bundleIdentifier') == target['bundleIdentifier'] and expected.get('productType') == target['productType'], 'CONTEXT_TARGETS')
        configuration_ids = {identifier for identifier, _, _ in target['configurations']}
        require(isinstance(expected.get('configurations'), list) and {item.get('id') for item in expected['configurations']} == configuration_ids, 'CONTEXT_CONFIGURATIONS')
        for identifier, _, settings in target['configurations']:
            configuration = next(item for item in expected['configurations'] if item['id'] == identifier)
            path = entitlement_path(Path(context['projectRoot']), settings)
            require(configuration.get('entitlementsPath') == (str(path) if path else None), 'CONTEXT_ENTITLEMENTS_CHANGED')
            require(configuration.get('entitlementsSHA256') == (hashlib.sha256(read_file(path)).hexdigest() if path else None), 'CONTEXT_ENTITLEMENTS_CHANGED')
            settings = result['objects'][identifier]['buildSettings']
            settings.update(CODE_SIGN_STYLE='Manual', PROVISIONING_PROFILE=context['profileUUID'],
                            DEVELOPMENT_TEAM=context['teamID'], CODE_SIGN_IDENTITY=context['identitySHA1'])
            for key in list(settings):
                if key.startswith('PROVISIONING_PROFILE_SPECIFIER') or key.startswith('PROVISIONING_PROFILE[') or key.startswith('CODE_SIGN_IDENTITY['):
                    settings.pop(key)
    return result


def atomic_write(path, raw, private):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(not path.is_symlink(), 'OUTPUT_FILE')
    descriptor, temporary = tempfile.mkstemp(prefix='.mirror-adhoc-', dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600 if private else 0o644)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(raw)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prepare_parser = commands.add_parser('prepare')
    for name in ('profile-plist', 'certificate', 'project-json', 'project-root', 'context-out', 'manifest-out', 'export-options-out'):
        prepare_parser.add_argument('--' + name, required=True, type=Path)
    prepare_parser.add_argument('--targets', nargs='+', required=True)
    prepare_parser.add_argument('--metadata', type=Path)
    patch_parser = commands.add_parser('patch')
    for name in ('project-json', 'context', 'output'):
        patch_parser.add_argument('--' + name, required=True, type=Path)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == 'prepare':
            context, manifest, export_options = prepare(load_plist(arguments.profile_plist), read_certificate(arguments.certificate),
                load_json(arguments.project_json), arguments.project_root, arguments.targets,
                load_json(arguments.metadata) if arguments.metadata else {})
            atomic_write(arguments.context_out, json.dumps(context).encode(), private=True)
            atomic_write(arguments.export_options_out, plistlib.dumps(export_options), private=True)
            atomic_write(arguments.manifest_out, json.dumps(manifest, ensure_ascii=False).encode(), private=False)
            print(json.dumps(manifest, ensure_ascii=False))
        else:
            context = load_json(arguments.context)
            patched = patch(load_json(arguments.project_json), context)
            atomic_write(arguments.output, json.dumps(patched).encode(), private=True)
            print(json.dumps({'result': 'pass', 'patchedApplicationTargets': len(context['targets'])}))
        return 0
    except ValidationError as error:
        print(json.dumps({'result': 'fail', 'code': str(error)}), file=sys.stderr)
    except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException):
        print(json.dumps({'result': 'fail', 'code': 'INPUT_FORMAT'}), file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
