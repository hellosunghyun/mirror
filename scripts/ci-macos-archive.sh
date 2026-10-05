#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

# 인증서, 공증 계정과 원문 로그는 임시 비공개 영역에서만 사용한다.
phase=arguments
fail() { printf '::error::macOS archive phase=%s code=%s\n' "$phase" "$1" >&2; exit 1; }
[[ $# -eq 3 || ( $# -eq 4 && ${4:-} == --preflight ) ]] || fail invalid_arguments
build_number="$1"
commit_sha="$2"
run_id="$3"
preflight=0
[[ ${4:-} != --preflight ]] || preflight=1
[[ "$build_number" =~ ^[1-9][0-9]*$ && "$run_id" =~ ^[1-9][0-9]*$ && "$commit_sha" =~ ^[0-9a-f]{40}$ ]] || fail invalid_metadata
[[ "$(uname -s)" == Darwin && ${GITHUB_ACTIONS:-} == true ]] || fail macos_actions_required
[[ -n ${RUNNER_TEMP:-} && -n ${GITHUB_OUTPUT:-} ]] || fail runner_environment_missing
[[ -n ${MAC_DEVELOPER_ID_P12_BASE64:-} && ${MAC_DEVELOPER_ID_P12_PASSWORD+x} ]] || fail p12_secret_missing
if [[ "$preflight" != 1 ]]; then
  [[ -n ${MAC_NOTARY_APPLE_ID:-} && -n ${MAC_NOTARY_APP_PASSWORD:-} ]] || fail notary_secret_missing
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="$repo_root/Mirror.xcodeproj/project.pbxproj"
private_dir=""
publish_dir=""
keychain_path=""
keychain_created=0
search_changed=0
project_changed=0
completed=0
previous_keychain_count=0
previous_keychains=()
cleanup() {
  local original_status=$?
  local cleanup_failed=0
  set +e
  set +u
  if [[ -n "$private_dir" && -f "$private_dir/dmg-mounted.flag" ]]; then
    hdiutil detach "$private_dir/dmg-mounted" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ "$search_changed" == 1 ]]; then
    security list-keychains -d user -s "${previous_keychains[@]}" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ "$keychain_created" == 1 ]]; then
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ "$project_changed" == 1 ]]; then
    cp -p "$private_dir/original-project.pbxproj" "$project_path" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ -n "$private_dir" ]]; then rm -rf "$private_dir" >/dev/null 2>&1 || cleanup_failed=1; fi
  if [[ "$cleanup_failed" == 1 ]]; then
    printf '%s\n' '::error::macOS archive phase=cleanup code=restore_failed' >&2
    [[ "$original_status" != 0 ]] || original_status=1
  fi
  if [[ "$completed" != 1 || "$original_status" != 0 ]]; then
    if [[ -n "$publish_dir" ]]; then rm -rf "$publish_dir" >/dev/null 2>&1; fi
  fi
  exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "::error::macOS archive phase=%s code=command_failed\n" "$phase" >&2' ERR

phase=private_workspace
private_dir="$(mktemp -d "$RUNNER_TEMP/mirror-macos-private.XXXXXX")"
chmod 700 "$private_dir"
keychain_path="$private_dir/developer-id.keychain-db"
cp -p "$project_path" "$private_dir/original-project.pbxproj"

# 모든 외부 명령의 출력은 비공개 파일로 보낸다. 오류에는 고정된 단계와 코드만 쓴다.
cat > "$private_dir/helper.py" <<'PY'
import base64
import datetime
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys

root = pathlib.Path(sys.argv[2])
repo = pathlib.Path(sys.argv[3])
log_path = root / 'commands.log'
phase = sys.argv[1]

class CheckFailed(Exception):
    pass

def require(condition, code):
    if not condition:
        raise CheckFailed(code)

def command(arguments, code, **kwargs):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)
    with log_path.open('ab') as log:
        log.write(result.stdout)
        log.write(result.stderr)
    require(result.returncode == 0, code)
    return result.stdout, result.stderr

def read_json(name):
    return json.loads((root / name).read_text())

def write_json(name, value):
    (root / name).write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')

def tlv(data, offset=0):
    require(offset + 2 <= len(data), 'certificate_der_invalid')
    tag, length = data[offset], data[offset + 1]
    start = offset + 2
    if length & 128:
        count = length & 127
        require(1 <= count <= 4 and start + count <= len(data), 'certificate_der_invalid')
        length = int.from_bytes(data[start:start + count], 'big')
        start += count
    end = start + length
    require(end <= len(data), 'certificate_der_invalid')
    return tag, data[start:end], end

def children(data):
    result, offset = [], 0
    while offset < len(data):
        tag, value, offset = tlv(data, offset)
        result.append((tag, value))
    require(offset == len(data), 'certificate_der_invalid')
    return result

def oid(data):
    require(bool(data), 'certificate_der_invalid')
    values, value = [], 0
    for byte in data:
        value = (value << 7) | (byte & 127)
        if not byte & 128:
            values.append(value)
            value = 0
    require(not data[-1] & 128 and bool(values), 'certificate_der_invalid')
    first = values.pop(0)
    return '.'.join(map(str, [min(first // 40, 2), first - min(first // 40, 2) * 40] + values))

def certificate_details(data):
    tag, outer, end = tlv(data)
    require(tag == 48 and end == len(data), 'certificate_der_invalid')
    body = children(children(outer)[0][1])
    start = 1 if body[0][0] == 160 else 0
    validity, subject = body[start + 3], body[start + 4]
    require(validity[0] == subject[0] == 48, 'certificate_der_invalid')
    dates = []
    for tag, value in children(validity[1]):
        require(tag in (23, 24), 'certificate_dates_invalid')
        text = value.decode('ascii')
        dates.append(datetime.datetime.strptime(text, '%y%m%d%H%M%SZ' if tag == 23 else '%Y%m%d%H%M%SZ').replace(tzinfo=datetime.timezone.utc))
    require(len(dates) == 2 and dates[0] <= datetime.datetime.now(datetime.timezone.utc) < dates[1], 'certificate_expired_or_not_yet_valid')
    attributes = {}
    for tag, rdn in children(subject[1]):
        require(tag == 49, 'certificate_subject_invalid')
        for tag, attribute in children(rdn):
            require(tag == 48, 'certificate_subject_invalid')
            pair = children(attribute)
            require(len(pair) == 2 and pair[0][0] == 6, 'certificate_subject_invalid')
            encoding = 'utf-16-be' if pair[1][0] == 30 else 'utf-8'
            attributes.setdefault(oid(pair[0][1]), []).append(pair[1][1].decode(encoding))
    common_names, teams = attributes.get('2.5.4.3', []), attributes.get('2.5.4.11', [])
    require(len(common_names) == len(teams) == 1 and re.fullmatch(r'[A-Z0-9]{10}', teams[0]), 'certificate_subject_invalid')
    match = re.fullmatch(r'Developer ID Application: .+ \(([A-Z0-9]{10})\)', common_names[0])
    require(match is not None and match[1] == teams[0], 'developer_id_application_required')
    extensions = {}
    for tag, value in body[start + 6:]:
        if tag != 163:
            continue
        extension_sequence = children(value)
        require(len(extension_sequence) == 1 and extension_sequence[0][0] == 48, 'certificate_extensions_invalid')
        for tag, extension in children(extension_sequence[0][1]):
            require(tag == 48, 'certificate_extensions_invalid')
            fields = children(extension)
            require(fields[0][0] == 6 and fields[-1][0] == 4, 'certificate_extensions_invalid')
            key = oid(fields[0][1])
            require(key not in extensions, 'certificate_extensions_invalid')
            extensions[key] = fields[-1][1]
    require('1.2.840.113635.100.6.1.13' in extensions, 'developer_id_application_oid_required')
    require('1.2.840.113635.100.6.1.2' not in extensions and '1.2.840.113635.100.6.1.4' not in extensions, 'distribution_or_development_certificate_rejected')
    eku = extensions.get('2.5.29.37', b'')
    tag, sequence, end = tlv(eku)
    require(tag == 48 and end == len(eku) and '1.3.6.1.5.5.7.3.3' in [oid(value) for tag, value in children(sequence) if tag == 6], 'codesigning_eku_required')
    return teams[0]

def identity():
    raw = base64.b64decode(''.join(os.environ['MAC_DEVELOPER_ID_P12_BASE64'].split()), validate=True)
    require(bool(raw), 'p12_base64_empty')
    (root / 'developer-id.p12').write_bytes(raw)

def validate_identity():
    def identities(name):
        # -v 없는 security 출력은 동일 identity를 Matching/Valid 두 번에 걸쳐 보여 준다.
        return {value.upper() for value in re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\b', (root / name).read_text(), re.MULTILINE)}
    all_identities, valid_identities = identities('all-identities.txt'), identities('valid-identities.txt')
    require(len(all_identities) == len(valid_identities) == 1, 'exactly_one_valid_private_key_identity_required')
    fingerprint = next(iter(valid_identities))
    require(all_identities == valid_identities, 'private_key_identity_mismatch')
    certificates = []
    for pem in re.findall(r'-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----', (root / 'certificates.pem').read_text(), re.DOTALL):
        der = base64.b64decode(''.join(pem.split()), validate=True)
        if hashlib.sha1(der).hexdigest().upper() == fingerprint:
            certificates.append(der)
    require(len(certificates) == 1, 'identity_leaf_certificate_mismatch')
    team = certificate_details(certificates[0])
    # security의 유효 codesigning identity는 이 leaf와 접근 가능한 개인 키의 쌍이다.
    (root / 'certificate.der').write_bytes(certificates[0])
    write_json('identity.json', {'sha1': fingerprint, 'team': team})

def prepare_project():
    stdout, _ = command(['xcodebuild', '-version'], 'xcode_version_unavailable')
    match = re.search(r'^Xcode ([0-9.]+)$', stdout.decode(), re.MULTILINE)
    stdout, _ = command(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], 'macos_sdk_unavailable')
    sdk = stdout.decode().strip()
    require(match is not None and match[1].split('.')[0] == sdk.split('.')[0] == '27', 'xcode_27_macos_sdk_27_required')
    project = read_json('project.json')
    objects = project['objects']
    targets = []
    signing_identity = read_json('identity.json')
    for name in ('MirrorMac', 'MirrorWidgetsMac', 'MirrorShareMac'):
        matches = [value for value in objects.values() if value.get('isa') == 'PBXNativeTarget' and value.get('name') == name]
        require(len(matches) == 1, 'mac_target_missing_or_ambiguous')
        configs = objects[matches[0]['buildConfigurationList']]['buildConfigurations']
        release = [objects[key] for key in configs if objects[key].get('name') == 'Release']
        require(len(release) == 1, 'release_configuration_missing')
        settings = release[0]['buildSettings']
        bundle_id = settings['PRODUCT_BUNDLE_IDENTIFIER']
        require(isinstance(bundle_id, str) and re.fullmatch(r'[A-Za-z0-9.-]+', bundle_id), 'bundle_identifier_invalid')
        entitlement_path = (repo / settings['CODE_SIGN_ENTITLEMENTS']).resolve()
        require(entitlement_path.is_relative_to(repo.resolve()) and entitlement_path.is_file(), 'source_entitlements_missing')
        entitlements = plistlib.loads(entitlement_path.read_bytes())
        require(entitlements.get('com.apple.security.app-sandbox') is True and 'com.apple.security.get-task-allow' not in entitlements and 'get-task-allow' not in entitlements, 'source_sandbox_or_debug_entitlements_invalid')
        # profile가 필요한 권한을 몰래 삭제하거나 예외 권한을 추가하지 않는다.
        require(not any(key.startswith('com.apple.developer.') or key in ('application-identifier', 'keychain-access-groups') for key in entitlements), 'developer_id_profile_required_by_source_entitlements')
        targets.append({'name': name, 'bundleIdentifier': bundle_id, 'entitlements': str(entitlement_path)})
        settings.update({'CURRENT_PROJECT_VERSION': sys.argv[4], 'ENABLE_HARDENED_RUNTIME': 'YES', 'CODE_SIGN_STYLE': 'Manual', 'DEVELOPMENT_TEAM': signing_identity['team'], 'CODE_SIGN_IDENTITY': 'Developer ID Application'})
        for key in list(settings):
            if key.startswith('PROVISIONING_PROFILE'):
                settings.pop(key)
    require(len({value['bundleIdentifier'] for value in targets}) == 3, 'bundle_identifier_duplicate')
    mac_target = next(value for value in objects.values() if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'MirrorMac')
    version = next(objects[key]['buildSettings']['MARKETING_VERSION'] for key in objects[mac_target['buildConfigurationList']]['buildConfigurations'] if objects[key].get('name') == 'Release')
    require(isinstance(version, str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', version), 'marketing_version_invalid')
    write_json('project-patched.json', project)
    write_json('build.json', {'buildNumber': sys.argv[4], 'commitSHA': sys.argv[5], 'runID': sys.argv[6], 'version': version, 'xcodeVersion': match[1], 'sdkVersion': sdk, 'targets': targets})

def info(bundle):
    candidates = [bundle / 'Contents/Info.plist', bundle / 'Info.plist']
    paths = [value for value in candidates if value.is_file()]
    require(len(paths) == 1, 'bundle_info_missing_or_ambiguous')
    return plistlib.loads(paths[0].read_bytes())

def executable(bundle, values):
    name = values.get('CFBundleExecutable')
    require(isinstance(name, str) and bool(name) and pathlib.Path(name).name == name, 'bundle_executable_invalid')
    paths = [bundle / 'Contents/MacOS' / name, bundle / name]
    found = [value for value in paths if value.is_file()]
    require(len(found) == 1, 'bundle_executable_missing_or_ambiguous')
    return found[0]

def macho(path):
    with path.open('rb') as source:
        return source.read(4) in (b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca')

def inventory(app):
    require(app.is_dir() and not app.is_symlink(), 'archive_app_missing')
    root_resolved = app.resolve()
    for path in app.rglob('*'):
        require(path.resolve().is_relative_to(root_resolved), 'bundle_path_escapes_app')
        require(not path.name.endswith(('.mobileprovision', '.provisionprofile', '.p12', '.keychain', '.keychain-db')), 'unexpected_private_material_in_app')
    bundles = [app] + sorted(app.rglob('*.appex'))
    require(len(bundles) == 3, 'exactly_two_embedded_extensions_required')
    metadata = read_json('build.json')
    expected = {target['bundleIdentifier']: target for target in metadata['targets']}
    entries, represented, seen = [], set(), set()
    for bundle in bundles:
        values = info(bundle)
        bundle_id = values.get('CFBundleIdentifier')
        require(bundle_id in expected and bundle_id not in seen, 'embedded_bundle_identifier_mismatch')
        seen.add(bundle_id)
        target = expected[bundle_id]
        require((bundle == app) == (target['name'] == 'MirrorMac'), 'app_extension_target_mismatch')
        require(str(values.get('CFBundleShortVersionString')) == metadata['version'] and str(values.get('CFBundleVersion')) == metadata['buildNumber'], 'bundle_version_or_build_mismatch')
        require(str(values.get('LSMinimumSystemVersion')) in ('27', '27.0', '27.0.0'), 'minimum_macos_27_required')
        binary = executable(bundle, values)
        require(macho(binary), 'bundle_macho_executable_required')
        stdout, _ = command(['lipo', '-archs', str(binary)], 'architecture_inspection_failed')
        require(stdout.decode().split() == ['arm64'], 'arm64_only_executable_required')
        entries.append({'path': str(bundle), 'binary': str(binary), 'entitlements': target['entitlements']})
        represented.add(binary.resolve())
    require(seen == set(expected), 'embedded_targets_missing')
    widget = next(path for path in bundles if info(path).get('NSExtension', {}).get('NSExtensionPointIdentifier') == 'com.apple.widgetkit-extension')
    share = next(path for path in bundles if info(path).get('NSExtension', {}).get('NSExtensionPointIdentifier') == 'com.apple.share-services')
    require(widget != share, 'extension_points_invalid')
    app_info = info(app)
    require(bool(app_info.get('NSCalendarsFullAccessUsageDescription')), 'calendar_usage_description_missing')
    require('mirror' in {scheme for value in app_info.get('CFBundleURLTypes', []) for scheme in value.get('CFBundleURLSchemes', [])}, 'mirror_url_scheme_missing')
    for name in ('PrivacyInfo.xcprivacy', 'LICENSE.swiftpieces', 'PROVENANCE.md'):
        require((app / 'Contents/Resources' / name).is_file(), 'app_disclosure_resource_missing')
    for bundle in bundles[1:]:
        require((bundle / 'Contents/Resources/PrivacyInfo.xcprivacy').is_file(), 'extension_privacy_resource_missing')
    package_spec = importlib.util.spec_from_file_location('ci_package', repo / 'scripts/ci-package.py')
    package = importlib.util.module_from_spec(package_spec)
    package_spec.loader.exec_module(package)
    # 기존 App Intents 판정도 원문 출력 없이 비공개 로그에만 담는다.
    import contextlib
    with log_path.open('a') as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
        package.inspect_app_intents(app)
    nested_bundles = []
    for suffix in ('*.framework', '*.xpc', '*.app', '*.bundle'):
        for bundle in app.rglob(suffix):
            if bundle in bundles or bundle.is_symlink():
                continue
            candidates = [bundle / 'Contents/Info.plist', bundle / 'Info.plist', bundle / 'Resources/Info.plist']
            plist_paths = [path for path in candidates if path.is_file()]
            if not plist_paths:
                continue
            values = plistlib.loads(plist_paths[0].read_bytes())
            name = values.get('CFBundleExecutable')
            if not isinstance(name, str) or pathlib.Path(name).name != name:
                continue
            candidates = [bundle / 'Contents/MacOS' / name, bundle / name]
            binaries = [value for value in candidates if value.is_file() and macho(value)]
            require(len(binaries) <= 1, 'nested_bundle_executable_ambiguous')
            if binaries:
                represented.add(binaries[0].resolve())
                nested_bundles.append({'path': str(bundle), 'binary': str(binaries[0]), 'entitlements': None})
    entries.extend(nested_bundles)
    for path in sorted(app.rglob('*')):
        if path.is_file() and not path.is_symlink() and path.resolve() not in represented and macho(path):
            entries.append({'path': str(path), 'binary': str(path), 'entitlements': None})
            represented.add(path.resolve())
    # 코드가 있는 번들은 가장 깊은 경로부터 서명하고 최상위 앱은 마지막에 서명한다.
    entries.sort(key=lambda value: len(pathlib.Path(value['path']).parts), reverse=True)
    require(entries[-1]['path'] == str(app), 'nested_signing_order_invalid')
    for entry in entries:
        stdout, _ = command(['lipo', '-archs', entry['binary']], 'nested_architecture_inspection_failed')
        require('arm64' in stdout.decode().split(), 'nested_arm64_architecture_missing')
    return entries

def decoded_entitlements(stdout, stderr):
    if stdout.strip().startswith((b'<?xml', b'<plist', b'bplist')):
        raw = stdout
    else:
        locations = [position for marker in (b'<?xml', b'<plist') if (position := stderr.find(marker)) >= 0]
        raw = stderr[min(locations):] if locations else b''
        require(not stdout.strip(), 'signed_entitlements_unrecognized')
    return plistlib.loads(raw) if raw.strip() else {}

def inspect_signature(path, expected_entitlements=None, runtime=True):
    command(['codesign', '--verify', '--strict', '--verbose=2', str(path)], 'strict_signature_verification_failed')
    _, stderr = command(['codesign', '-d', '--verbose=4', str(path)], 'signature_metadata_unavailable')
    text = stderr.decode(errors='replace')
    signing_identity = read_json('identity.json')
    require(re.search(r'^TeamIdentifier=' + re.escape(signing_identity['team']) + r'$', text, re.MULTILINE) is not None, 'signature_team_mismatch')
    require(re.search(r'^Timestamp=', text, re.MULTILINE) is not None, 'secure_timestamp_missing')
    if runtime:
        match = re.search(r'^CodeDirectory .*?flags=(0x[0-9a-fA-F]+)', text, re.MULTILINE)
        require(match is not None and int(match[1], 16) & 0x10000, 'hardened_runtime_flag_missing')
        stdout, stderr = command(['codesign', '-d', '--entitlements', ':-', str(path)], 'signed_entitlements_unavailable')
        actual = decoded_entitlements(stdout, stderr)
        require('com.apple.security.get-task-allow' not in actual and 'get-task-allow' not in actual, 'debug_entitlement_present')
        if expected_entitlements is not None:
            expected = plistlib.loads(pathlib.Path(expected_entitlements).read_bytes())
            require(actual == expected, 'source_entitlements_not_preserved')
    prefix = root / 'extracted-leaf-'
    for certificate in root.glob('extracted-leaf-*'):
        certificate.unlink()
    command(['codesign', '-d', '--extract-certificates=' + str(prefix), str(path)], 'signature_certificate_extraction_failed')
    leaf = pathlib.Path(str(prefix) + '0')
    require(leaf.is_file() and leaf.read_bytes() == (root / 'certificate.der').read_bytes(), 'signature_leaf_certificate_mismatch')

def sign_app():
    app = root / 'Mirror.xcarchive/Products/Applications/Mirror.app'
    entries = inventory(app)
    identity_data = read_json('identity.json')
    keychain = root / 'developer-id.keychain-db'
    for entry in entries:
        arguments = ['codesign', '--force', '--sign', identity_data['sha1'], '--keychain', str(keychain), '--options', 'runtime', '--timestamp']
        if entry['entitlements'] is not None:
            arguments += ['--entitlements', entry['entitlements']]
        else:
            # 예상하지 못한 기존 권한을 묵시적으로 버리지 않는다.
            probe = subprocess.run(['codesign', '-d', '--entitlements', ':-', entry['path']], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            with log_path.open('ab') as log:
                log.write(probe.stdout)
                log.write(probe.stderr)
            if probe.returncode == 0:
                require(not decoded_entitlements(probe.stdout, probe.stderr), 'unexpected_nested_entitlements_require_review')
            else:
                require(b'code object is not signed at all' in probe.stderr, 'nested_signature_inspection_failed')
        command(arguments + [entry['path']], 'nested_codesign_failed')
        inspect_signature(pathlib.Path(entry['path']), entry['entitlements'])
    command(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], 'app_deep_strict_verification_failed')
    write_json('signed-entries.json', entries)

def notarize(path, label):
    identity_data = read_json('identity.json')
    stdout, _ = command(['xcrun', 'notarytool', 'submit', str(path), '--apple-id', os.environ['MAC_NOTARY_APPLE_ID'], '--password', os.environ['MAC_NOTARY_APP_PASSWORD'], '--team-id', identity_data['team'], '--wait', '--output-format', 'json'], 'notary_submit_failed')
    (root / (label + '-notary.json')).write_bytes(stdout)
    response = json.loads(stdout)
    require(isinstance(response, dict) and response.get('status') == 'Accepted', 'notarization_not_accepted')

def notarize_app():
    app = root / 'Mirror.xcarchive/Products/Applications/Mirror.app'
    archive = root / 'Mirror-notary.zip'
    command(['ditto', '-c', '-k', '--keepParent', str(app), str(archive)], 'notary_app_archive_failed')
    notarize(archive, 'app')
    command(['xcrun', 'stapler', 'staple', str(app)], 'app_staple_failed')
    command(['xcrun', 'stapler', 'validate', str(app)], 'app_staple_validation_failed')
    command(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)], 'app_gatekeeper_rejected')
    for entry in read_json('signed-entries.json'):
        inspect_signature(pathlib.Path(entry['path']), entry['entitlements'])
    command(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], 'stapled_app_signature_invalid')

def make_dmg():
    app = root / 'Mirror.xcarchive/Products/Applications/Mirror.app'
    stage = root / 'dmg-stage'
    stage.mkdir()
    command(['ditto', str(app), str(stage / 'Mirror.app')], 'dmg_app_copy_failed')
    (stage / 'Applications').symlink_to('/Applications')
    dmg = root / 'Mirror-macOS.dmg'
    command(['hdiutil', 'create', '-volname', 'Mirror', '-srcfolder', str(stage), '-ov', '-format', 'UDZO', str(dmg)], 'dmg_creation_failed')
    identity_data = read_json('identity.json')
    command(['codesign', '--force', '--sign', identity_data['sha1'], '--keychain', str(root / 'developer-id.keychain-db'), '--timestamp', str(dmg)], 'dmg_codesign_failed')
    inspect_signature(dmg, runtime=False)
    notarize(dmg, 'dmg')
    command(['xcrun', 'stapler', 'staple', str(dmg)], 'dmg_staple_failed')
    command(['xcrun', 'stapler', 'validate', str(dmg)], 'dmg_staple_validation_failed')
    command(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', str(dmg)], 'dmg_gatekeeper_rejected')
    inspect_signature(dmg, runtime=False)
    mount = root / 'dmg-mounted'
    mount.mkdir()
    mounted = False
    try:
        command(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg)], 'dmg_mount_failed')
        mounted = True
        (root / 'dmg-mounted.flag').touch()
        mounted_app = mount / 'Mirror.app'
        entries = inventory(mounted_app)
        for entry in entries:
            inspect_signature(pathlib.Path(entry['path']), entry['entitlements'])
        command(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(mounted_app)], 'dmg_embedded_app_signature_invalid')
        command(['xcrun', 'stapler', 'validate', str(mounted_app)], 'dmg_embedded_app_staple_invalid')
        command(['spctl', '--assess', '--type', 'execute', '--verbose=2', str(mounted_app)], 'dmg_embedded_app_gatekeeper_rejected')
    finally:
        if mounted:
            command(['hdiutil', 'detach', str(mount)], 'dmg_unmount_failed')
            (root / 'dmg-mounted.flag').unlink()

def publish():
    destination = pathlib.Path(sys.argv[4])
    metadata = read_json('build.json')
    dmg = root / 'Mirror-macOS.dmg'
    require(dmg.is_file() and dmg.stat().st_size > 0, 'dmg_missing_or_empty')
    dmg_hash = hashlib.sha256(dmg.read_bytes()).hexdigest()
    shutil.copyfile(dmg, destination / dmg.name)
    manifest = {key: metadata[key] for key in ('buildNumber', 'commitSHA', 'runID', 'version', 'xcodeVersion', 'sdkVersion')}
    verification = {key: True for key in ('codesign', 'hardenedRuntime', 'notarization', 'stapled', 'gatekeeper', 'versionAndBuild')}
    verification['getTaskAllow'] = False
    manifest.update({'schemaVersion': 1, 'result': 'pass', 'distribution': 'developer-id', 'platform': 'macOS', 'minimumOS': '27.0', 'architectures': ['arm64'], 'certificateType': 'Developer ID Application', 'dmgSHA256': dmg_hash, 'dmgBytes': dmg.stat().st_size, 'targets': [{key: target[key] for key in ('name', 'bundleIdentifier')} for target in metadata['targets']], 'verification': verification})
    (destination / 'macos-build-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    notes = ('# Mirror macOS ' + metadata['version'] + '\n\n' +
             '- 빌드: ' + metadata['buildNumber'] + '\n' +
             '- Commit: `' + metadata['commitSHA'] + '`\n' +
             '- macOS 27 이상, Apple silicon (ARM64)\n' +
             '- Developer ID 서명, hardened runtime, Apple 공증·staple 및 Gatekeeper 검증 통과\n\n' +
             '`Mirror-macOS.dmg`를 열고 Mirror를 Applications로 복사하세요.\n')
    (destination / 'macos-release-notes.md').write_text(notes, encoding='utf-8')
    assets = sorted(path for path in destination.iterdir() if path.is_file())
    require({path.name for path in assets} == {'Mirror-macOS.dmg', 'macos-build-manifest.json', 'macos-release-notes.md'}, 'public_asset_set_invalid')
    (destination / 'macos-SHA256SUMS').write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n' for path in assets), encoding='utf-8')

try:
    {'decode': identity, 'identity': validate_identity, 'project': prepare_project, 'sign': sign_app, 'app_notary': notarize_app, 'dmg_notary': make_dmg, 'publish': publish}[phase]()
except CheckFailed as error:
    print('::error::macOS archive phase=' + phase + ' code=' + str(error), file=sys.stderr)
    raise SystemExit(1) from None
except Exception:
    print('::error::macOS archive phase=' + phase + ' code=private_processing_failed', file=sys.stderr)
    raise SystemExit(1) from None
PY

phase=p12_decode
python3 "$private_dir/helper.py" decode "$private_dir" "$repo_root"
phase=keychain
security list-keychains -d user > "$private_dir/original-keychains.txt" 2> "$private_dir/security.log"
python3 - "$private_dir/original-keychains.txt" > "$private_dir/original-keychains.nul" 2>> "$private_dir/security.log" <<'PY'
import pathlib, shlex, sys
for value in shlex.split(pathlib.Path(sys.argv[1]).read_text()):
    sys.stdout.buffer.write(value.encode() + b'\0')
PY
while IFS= read -r -d '' entry; do
  previous_keychains+=("$entry")
  previous_keychain_count=$((previous_keychain_count + 1))
done < "$private_dir/original-keychains.nul"
keychain_password="$(openssl rand -hex 32 2>> "$private_dir/security.log")"
search_changed=1
keychain_created=1
security create-keychain -p "$keychain_password" "$keychain_path" >> "$private_dir/security.log" 2>&1
security set-keychain-settings -lut 21600 "$keychain_path" >> "$private_dir/security.log" 2>&1
security unlock-keychain -p "$keychain_password" "$keychain_path" >> "$private_dir/security.log" 2>&1
if (( previous_keychain_count > 0 )); then
  security list-keychains -d user -s "$keychain_path" "${previous_keychains[@]}" >> "$private_dir/security.log" 2>&1
else
  security list-keychains -d user -s "$keychain_path" >> "$private_dir/security.log" 2>&1
fi
phase=p12_import
security import "$private_dir/developer-id.p12" -k "$keychain_path" -P "$MAC_DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >> "$private_dir/security.log" 2>&1
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path" >> "$private_dir/security.log" 2>&1
phase=identity
security find-identity -p codesigning "$keychain_path" > "$private_dir/all-identities.txt" 2>> "$private_dir/security.log"
security find-identity -v -p codesigning "$keychain_path" > "$private_dir/valid-identities.txt" 2>> "$private_dir/security.log"
security find-certificate -a -p "$keychain_path" > "$private_dir/certificates.pem" 2>> "$private_dir/security.log"
python3 "$private_dir/helper.py" identity "$private_dir" "$repo_root"
if [[ "$preflight" == 1 ]]; then
  printf '%s\n' '::notice::macOS archive phase=preflight code=developer_id_identity_verified'
  completed=1
  exit 0
fi

phase=project
plutil -convert json -o "$private_dir/project.json" "$project_path" >> "$private_dir/commands.log" 2>&1
python3 "$private_dir/helper.py" project "$private_dir" "$repo_root" "$build_number" "$commit_sha" "$run_id"
project_changed=1
plutil -convert xml1 -o "$project_path" "$private_dir/project-patched.json" >> "$private_dir/commands.log" 2>&1
phase=archive
# Xcode가 보존한 원래 권한으로 이후 각 코드 객체를 직접 서명한다. --deep 서명은 사용하지 않는다.
xcodebuild -project "$repo_root/Mirror.xcodeproj" -scheme MirrorMac -configuration Release \
  -sdk macosx -destination 'generic/platform=macOS' -archivePath "$private_dir/Mirror.xcarchive" \
  -derivedDataPath "$private_dir/DerivedData" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=27.0 CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=YES archive > "$private_dir/archive.log" 2>&1
phase=sign
python3 "$private_dir/helper.py" sign "$private_dir" "$repo_root"
phase=app_notary
python3 "$private_dir/helper.py" app_notary "$private_dir" "$repo_root"
phase=dmg_notary
python3 "$private_dir/helper.py" dmg_notary "$private_dir" "$repo_root"
phase=publish
publish_dir="$(mktemp -d "$RUNNER_TEMP/mirror-macos-publish.XXXXXX")"
python3 "$private_dir/helper.py" publish "$private_dir" "$repo_root" "$publish_dir"
chmod 755 "$publish_dir"
chmod 644 "$publish_dir"/*
printf 'publish_dir=%s\n' "$publish_dir" >> "$GITHUB_OUTPUT"
printf '%s\n' '::notice::macOS archive phase=complete code=notarized_dmg_verified'
completed=1
