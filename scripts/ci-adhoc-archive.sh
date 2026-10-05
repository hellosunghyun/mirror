#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

# 서명 자료와 로그는 runner의 임시 영역에만 둔다. 공개 산출물은 성공 뒤 별도 폴더로 내보낸다.
if [[ $# -ne 3 && ( $# -ne 4 || ( ${4:-} != --preflight && ${4:-} != --diagnostic ) ) ]]; then
  printf '%s\n' '사용법: ci-adhoc-archive.sh BUILD_NUMBER COMMIT_SHA RUN_ID [--preflight|--diagnostic]' >&2
  exit 2
fi
build_number="$1"
commit_sha="$2"
run_id="$3"
preflight=0
if [[ ${4:-} == --preflight ]]; then preflight=1; fi
diagnostic=0
if [[ ${4:-} == --diagnostic ]]; then diagnostic=1; fi
[[ "$build_number" =~ ^[1-9][0-9]*$ && "$run_id" =~ ^[1-9][0-9]*$ && "$commit_sha" =~ ^[0-9a-f]{40}$ ]] || {
  printf '%s\n' '::error::빌드 번호, commit SHA, run ID가 유효하지 않습니다.' >&2
  exit 2
}
[[ "$(uname -s)" == Darwin ]] || { printf '%s\n' '::error::Ad Hoc archive는 macOS Actions 러너에서 실행합니다.' >&2; exit 2; }
: "${RUNNER_TEMP:?RUNNER_TEMP이 필요합니다.}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT이 필요합니다.}"
: "${IOS_DISTRIBUTION_P12_BASE64:?배포 P12 Secret이 필요합니다.}"
: "${IOS_DISTRIBUTION_P12_PASSWORD?P12 비밀번호 Secret이 필요합니다.}"

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
profile_count=0
previous_keychains=()
installed_profiles=()
profile_backups=()

cleanup() {
  local original_status=$?
  local cleanup_failed=0
  set +e
  set +u
  if [[ "$search_changed" == 1 ]]; then
    security list-keychains -d user -s "${previous_keychains[@]}" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ "$keychain_created" == 1 ]]; then
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || cleanup_failed=1
  fi
  if [[ "$project_changed" == 1 ]]; then
    cp -p "$private_dir/original-project.pbxproj" "$project_path" >/dev/null 2>&1 || cleanup_failed=1
  fi
  local index
  for ((index=0; index<${#installed_profiles[@]}; index++)); do
    if [[ -n "${profile_backups[$index]}" ]]; then
      cp -p "${profile_backups[$index]}" "${installed_profiles[$index]}" >/dev/null 2>&1 || cleanup_failed=1
    else
      rm -f "${installed_profiles[$index]}" >/dev/null 2>&1 || cleanup_failed=1
    fi
  done
  if [[ -n "$private_dir" ]]; then rm -rf "$private_dir" || cleanup_failed=1; fi
  if [[ "$cleanup_failed" == 1 ]]; then
    printf '%s\n' '::error::임시 서명 설정을 완전히 정리하지 못했습니다. 게시를 중지합니다.' >&2
    if [[ "$original_status" == 0 ]]; then original_status=1; fi
  fi
  if [[ "$completed" != 1 || "$original_status" != 0 ]]; then
    if [[ -n "$publish_dir" ]]; then rm -rf "$publish_dir"; fi
  fi
  exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
signing_stage="서명 환경 준비"
trap 'printf "%s\n" "::error::Ad Hoc 처리 단계에 실패했습니다: $signing_stage" >&2' ERR

private_dir="$(mktemp -d "$RUNNER_TEMP/mirror-adhoc-private.XXXXXX")"
publish_dir="$(mktemp -d "$RUNNER_TEMP/mirror-adhoc-publish.XXXXXX")"
chmod 700 "$private_dir"
keychain_path="$private_dir/distribution.keychain-db"
cp -p "$project_path" "$private_dir/original-project.pbxproj"

python3 "$repo_root/scripts/ci-adhoc-profile.py" decode-inputs --output-directory "$private_dir"
python3 - "$private_dir/profile-inputs.json" > "$private_dir/profile-stems.txt" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1], encoding='utf-8'))['profiles']:
    print(item['stem'])
PY
profile_stems=()
while IFS= read -r stem; do profile_stems+=("$stem"); done < "$private_dir/profile-stems.txt"

xcodebuild -version > "$private_dir/toolchain.txt"
xcrun --sdk iphoneos --show-sdk-version > "$private_dir/sdk.txt"
plutil -convert json -o "$private_dir/project.json" "$project_path"
python3 - "$private_dir" "$build_number" "$commit_sha" "$run_id" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
toolchain = (root / 'toolchain.txt').read_text()
match = re.search(r'^Xcode ([0-9.]+)$', toolchain, re.MULTILINE)
sdk = (root / 'sdk.txt').read_text().strip()
if not match or match[1].split('.')[0] != '27' or sdk.split('.')[0] != '27':
    raise SystemExit('Xcode 27와 iPhoneOS SDK 27이 필요합니다.')
project = json.loads((root / 'project.json').read_text())
objects = project['objects']
target = next(value for value in objects.values() if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'MirrorIOS')
configurations = objects[target['buildConfigurationList']]['buildConfigurations']
release = next(objects[key] for key in configurations if objects[key].get('name') == 'Release')
version = str(release['buildSettings']['MARKETING_VERSION'])
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', version):
    raise SystemExit('앱 버전 형식이 유효하지 않습니다.')
metadata = {'buildNumber': sys.argv[2], 'commitSHA': sys.argv[3], 'runID': sys.argv[4],
            'version': version, 'xcodeVersion': match[1], 'sdkVersion': sdk}
(root / 'build.json').write_text(json.dumps(metadata, ensure_ascii=False), encoding='utf-8')
PY

security list-keychains -d user > "$private_dir/original-keychains.txt"
python3 - "$private_dir/original-keychains.txt" > "$private_dir/original-keychains.nul" <<'PY'
import pathlib, shlex, sys
for entry in shlex.split(pathlib.Path(sys.argv[1]).read_text()):
    sys.stdout.buffer.write(entry.encode() + b'\0')
PY
while IFS= read -r -d '' entry; do
  previous_keychains+=("$entry")
  previous_keychain_count=$((previous_keychain_count + 1))
done < "$private_dir/original-keychains.nul"
keychain_password="$(openssl rand -hex 32)"
# create-keychain도 검색 목록을 바꿀 수 있으므로 생성 이전부터 복구를 보장한다.
search_changed=1
keychain_created=1
security create-keychain -p "$keychain_password" "$keychain_path" > "$private_dir/security.log" 2>&1
security set-keychain-settings -lut 21600 "$keychain_path" >> "$private_dir/security.log" 2>&1
security unlock-keychain -p "$keychain_password" "$keychain_path" >> "$private_dir/security.log" 2>&1
if (( previous_keychain_count > 0 )); then
  security list-keychains -d user -s "$keychain_path" "${previous_keychains[@]}" >> "$private_dir/security.log" 2>&1
else
  security list-keychains -d user -s "$keychain_path" >> "$private_dir/security.log" 2>&1
fi
signing_stage="P12 인증서와 개인 키 가져오기"
security import "$private_dir/distribution.p12" -k "$keychain_path" -P "$IOS_DISTRIBUTION_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >> "$private_dir/security.log" 2>&1
signing_stage="개인 키 접근 설정"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain_path" >> "$private_dir/security.log" 2>&1
signing_stage="서명 identity 조회"
security find-identity -p codesigning "$keychain_path" > "$private_dir/all-identities.txt" 2>> "$private_dir/security.log"
security find-identity -v -p codesigning "$keychain_path" > "$private_dir/identities.txt" 2>> "$private_dir/security.log"
certificate_query_succeeded=0
if security find-certificate -a -p "$keychain_path" > "$private_dir/imported-certificates.pem" 2>> "$private_dir/security.log"; then
  certificate_query_succeeded=1
fi
signing_stage="프로파일 해석"
for stem in "${profile_stems[@]}"; do
  security cms -D -i "$private_dir/$stem.mobileprovision" > "$private_dir/$stem.plist" 2>> "$private_dir/security.log"
done
signing_stage="인증서·개인 키·프로파일 일치 검사"
python3 "$repo_root/scripts/ci-adhoc-profile.py" select-certificate --directory "$private_dir" \
  --certificate-query-succeeded "$certificate_query_succeeded"

signing_stage="프로파일과 배포 권한 검사"
profile_arguments=(--profile-plist "$private_dir/profile.plist")
if [[ ${#profile_stems[@]} -eq 3 ]]; then profile_arguments=(--target-profiles-dir "$private_dir"); fi
python3 "$repo_root/scripts/ci-adhoc-profile.py" prepare \
  "${profile_arguments[@]}" --certificate "$private_dir/certificate.der" \
  --project-json "$private_dir/project.json" --project-root "$repo_root" \
  --targets MirrorIOS MirrorWidgetsIOS MirrorShareIOS \
  --context-out "$private_dir/context.json" --manifest-out "$private_dir/build-manifest.json" \
  --export-options-out "$private_dir/ExportOptions.plist" --metadata "$private_dir/build.json" \
  > "$private_dir/prepare.log"
if [[ "$preflight" == 1 ]]; then
  printf '%s\n' '서명 자료 사전 검사 통과: 유효한 인증서·개인 키·프로파일 및 세 배포 대상의 권한을 확인했습니다. 실제 IPA 서명은 archive 단계에서 별도로 검증합니다.'
  exit 0
fi
signing_stage="프로젝트 수동 서명 설정"
python3 - "$private_dir/context.json" <<'PY'
import json, sys
context = json.load(open(sys.argv[1], encoding='utf-8'))
for identity in [context, *context.get('targetProfiles', {}).values()]:
    for key in ['teamID', 'profileUUID', 'profileName', 'identitySHA1', 'applicationIdentifierPrefix']:
        value = str(identity[key]).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print('::add-mask::' + value)
PY
python3 "$repo_root/scripts/ci-adhoc-profile.py" patch \
  --project-json "$private_dir/project.json" --context "$private_dir/context.json" \
  --output "$private_dir/signed-project.json"
project_changed=1
plutil -convert xml1 -o "$project_path" "$private_dir/signed-project.json"
team_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["teamID"])' "$private_dir/context.json")"
identity_sha1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["identitySHA1"])' "$private_dir/context.json")"
profile_directories=("$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles")
for stem in "${profile_stems[@]}"; do
  profile_uuid="$(python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1], "rb"))["UUID"])' "$private_dir/$stem.plist")"
  for directory in "${profile_directories[@]}"; do
    mkdir -p "$directory"
    installed="$directory/$profile_uuid.mobileprovision"
    backup=""
    if [[ -e "$installed" ]]; then
      backup="$private_dir/profile-backup-$profile_count.mobileprovision"
      cp -p "$installed" "$backup"
    fi
    installed_profiles+=("$installed")
    profile_backups+=("$backup")
    profile_count=$((profile_count + 1))
    cp "$private_dir/$stem.mobileprovision" "$installed"
  done
done

signing_stage="Xcode 유효 서명 설정 진단"
if xcodebuild -project "$repo_root/Mirror.xcodeproj" -scheme MirrorIOS -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' -showBuildSettings -json \
    DEVELOPMENT_TEAM="$team_id" CODE_SIGN_IDENTITY="$identity_sha1" CODE_SIGNING_ALLOWED=YES \
    CURRENT_PROJECT_VERSION="$build_number" > "$private_dir/resolved-settings.json" 2> "$private_dir/settings.log"; then
  python3 - "$private_dir" <<'PY'
import json, pathlib, plistlib, sys
summary = {'status': 'unavailable'}
try:
    private = pathlib.Path(sys.argv[1])
    context = json.loads((private / 'context.json').read_text())
    resolved = json.loads((private / 'resolved-settings.json').read_text())
    known_names = ('MirrorIOS', 'MirrorWidgetsIOS', 'MirrorShareIOS')
    expected = {item['name']: item for item in context['targets'] if item['name'] in known_names}
    actual = {item['target']: item['buildSettings'] for item in resolved if item.get('target') in known_names}
    inputs = json.loads((private / 'profile-inputs.json').read_text())['profiles']
    sources = {item['target']: item['stem'] for item in inputs}
    home = pathlib.Path.home()
    directories = (home / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
                   home / 'Library/MobileDevice/Provisioning Profiles')
    installed_count = 0
    checked = set()
    source_matches = True
    targets = {}
    for name in known_names:
        identity = context.get('targetProfiles', {}).get(name, context)
        stem = sources.get(name, sources.get(None))
        profile = (private / (stem + '.mobileprovision')).read_bytes()
        source_profile = plistlib.loads((private / (stem + '.plist')).read_bytes())
        source_matches = source_matches and source_profile.get('UUID') == identity['profileUUID']
        for directory in directories:
            candidate = directory / (identity['profileUUID'] + '.mobileprovision')
            if candidate not in checked and candidate.is_file() and candidate.read_bytes() == profile:
                checked.add(candidate)
                installed_count += 1
        settings = actual.get(name, {})
        targets[name] = {
            'present': name in actual,
            'manual': settings.get('CODE_SIGN_STYLE') == 'Manual',
            'signingAllowed': settings.get('CODE_SIGNING_ALLOWED') == 'YES',
            'teamMatches': settings.get('DEVELOPMENT_TEAM') == context['teamID'],
            'identityMatches': str(settings.get('CODE_SIGN_IDENTITY', '')).upper() == context['identitySHA1'],
            'legacyProfileMatches': settings.get('PROVISIONING_PROFILE') == identity['profileUUID'],
            'specifierMatches': settings.get('PROVISIONING_PROFILE_SPECIFIER') in (identity['profileUUID'], identity['profileName']),
            'specifierUsesName': settings.get('PROVISIONING_PROFILE_SPECIFIER') == identity['profileName'],
            'bundleMatches': settings.get('PRODUCT_BUNDLE_IDENTIFIER') == expected.get(name, {}).get('bundleIdentifier'),
        }
    summary = {'status': 'resolved', 'matchingProfileLocations': installed_count, 'targets': targets,
               'profileUUIDMatchesSource': source_matches}
except Exception:
    pass
print('::notice::Effective signing settings diagnostics: ' + json.dumps(summary, sort_keys=True))
PY
else
  printf '%s\n' '::notice::Xcode 유효 서명 설정을 조회하지 못했습니다. 실제 archive로 결과를 확인합니다.'
fi

signing_stage="서명된 iOS archive 생성"
if ! xcodebuild -project "$repo_root/Mirror.xcodeproj" -scheme MirrorIOS -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' -archivePath "$private_dir/Mirror.xcarchive" \
    -derivedDataPath "$private_dir/DerivedData" -jobs 2 \
    DEVELOPMENT_TEAM="$team_id" CODE_SIGN_IDENTITY="$identity_sha1" CODE_SIGNING_ALLOWED=YES \
    CURRENT_PROJECT_VERSION="$build_number" archive > "$private_dir/archive.log" 2>&1; then
  python3 "$repo_root/scripts/ci-adhoc-diagnostics.py" --phase archive --log-file "$private_dir/archive.log" || \
    printf '%s\n' '::notice::비공개 archive 로그의 오류 분류를 완료하지 못했습니다.'
  printf '%s\n' '::error::서명된 iOS archive 생성에 실패했습니다. 서명 자료와 비공개 로그는 정리합니다.' >&2
  exit 1
fi
signing_stage="Ad Hoc IPA export"
if ! xcodebuild -exportArchive -archivePath "$private_dir/Mirror.xcarchive" \
    -exportOptionsPlist "$private_dir/ExportOptions.plist" -exportPath "$private_dir/export" \
    > "$private_dir/export.log" 2>&1; then
  python3 "$repo_root/scripts/ci-adhoc-diagnostics.py" --phase export --log-file "$private_dir/export.log" || \
    printf '%s\n' '::notice::비공개 export 로그의 오류 분류를 완료하지 못했습니다.'
  printf '%s\n' '::error::Ad Hoc IPA export에 실패했습니다. 서명 자료와 비공개 로그는 정리합니다.' >&2
  exit 1
fi

signing_stage="IPA 서명과 공개 자산 검사"
python3 - "$private_dir" "$publish_dir" "$repo_root/scripts/ci-adhoc-profile.py" <<'PY'
import hashlib, json, pathlib, plistlib, shutil, subprocess, sys, zipfile
private, public = map(pathlib.Path, sys.argv[1:3])
profile_helper = sys.argv[3]
context = json.loads((private / 'context.json').read_text())
metadata = json.loads((private / 'build.json').read_text())
manifest = json.loads((private / 'build-manifest.json').read_text())
ipas = list((private / 'export').glob('*.ipa'))
if len(ipas) != 1:
    raise SystemExit('export된 IPA가 정확히 하나여야 합니다.')
extracted = private / 'verified-export'
extracted.mkdir()
with zipfile.ZipFile(ipas[0]) as archive:
    for member in archive.infolist():
        path = pathlib.PurePosixPath(member.filename)
        if path.is_absolute() or '..' in path.parts or ((member.external_attr >> 16) & 0o170000) == 0o120000:
            raise SystemExit('IPA 경로 형식이 유효하지 않습니다.')
    archive.extractall(extracted)
apps = list((extracted / 'Payload').glob('*.app'))
if len(apps) != 1:
    raise SystemExit('IPA에는 메인 앱이 정확히 하나 있어야 합니다.')
bundles = apps + list(apps[0].rglob('*.appex'))
expected = {target['bundleIdentifier'] for target in context['targets']}
seen = set()
for index, bundle in enumerate(bundles):
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    identifier = info.get('CFBundleIdentifier')
    if identifier not in expected or identifier in seen:
        raise SystemExit('export된 앱과 확장 식별자가 계약과 다릅니다.')
    seen.add(identifier)
    if str(info.get('CFBundleVersion')) != metadata['buildNumber'] or str(info.get('CFBundleShortVersionString')) != metadata['version']:
        raise SystemExit('export된 앱 또는 확장의 버전/빌드 번호가 다릅니다.')
    if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []):
        raise SystemExit('실제 iPhoneOS 앱만 게시할 수 있습니다.')
    if str(info.get('MinimumOSVersion', '')).split('.')[0] != '27':
        raise SystemExit('최소 iOS 버전은 27이어야 합니다.')
    log = private / f'codesign-{index}.log'
    with log.open('wb') as diagnostics:
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle)], check=True,
                       stdout=diagnostics, stderr=diagnostics)
        entitlements = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(bundle)],
                                      check=True, stdout=subprocess.PIPE, stderr=diagnostics).stdout
        certificate_prefix = str(private / f'signed-certificate-{index}-')
        subprocess.run(['/usr/bin/codesign', '-d', '--extract-certificates=' + certificate_prefix, str(bundle)],
                       check=True, stdout=diagnostics, stderr=diagnostics)
        embedded = subprocess.run(['/usr/bin/security', 'cms', '-D', '-i', str(bundle / 'embedded.mobileprovision')],
                                  check=True, stdout=subprocess.PIPE, stderr=diagnostics).stdout
    leaf = pathlib.Path(certificate_prefix + '0').read_bytes()
    if hashlib.sha1(leaf).hexdigest().upper() != context['identitySHA1'].upper():
        raise SystemExit('export된 코드의 서명 인증서가 선택한 인증서와 다릅니다.')
    embedded_path = private / f'export-profile-{index}.plist'
    entitlement_path = private / f'export-entitlements-{index}.plist'
    embedded_path.write_bytes(embedded)
    entitlement_path.write_bytes(entitlements)
    verified = subprocess.run([sys.executable, profile_helper, 'verify-embedded',
        '--context', str(private / 'context.json'), '--bundle-id', identifier,
        '--profile-plist', str(embedded_path), '--entitlements', str(entitlement_path),
        '--certificate', certificate_prefix + '0'])
    if verified.returncode != 0:
        raise SystemExit('export된 앱 또는 확장의 프로파일·실제 권한 검증에 실패했습니다.')
if seen != expected:
    raise SystemExit('메인 앱과 위젯·Share 확장 세 개가 모두 필요합니다.')
shutil.copyfile(ipas[0], public / 'Mirror.ipa')
manifest['ipaSHA256'] = hashlib.sha256((public / 'Mirror.ipa').read_bytes()).hexdigest()
manifest['ipaBytes'] = (public / 'Mirror.ipa').stat().st_size
manifest['verification'] = {'codesign': True, 'embeddedProfile': True, 'getTaskAllow': False, 'versionAndBuild': True}
(public / 'build-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding='utf-8')
notes = (f"미러 Ad Hoc {metadata['version']} ({metadata['buildNumber']})\n\n"
         f"- Commit: `{metadata['commitSHA']}`\n"
         f"- GitHub Actions run: {metadata['runID']}\n"
         "- 대상: iOS / iPadOS 27 이상, provisioning profile에 등록한 기기\n"
         "- 메인 앱과 위젯·Share 확장의 실제 서명, 프로파일, 버전과 빌드 번호를 확인했습니다.\n\n"
         "Mirror.ipa와 SHA256SUMS를 내려받아 무결성을 확인한 뒤 등록한 기기에 설치하세요.\n")
(public / 'release-notes.md').write_text(notes, encoding='utf-8')
checksums = []
for name in ['Mirror.ipa', 'build-manifest.json', 'release-notes.md']:
    checksums.append(f"{hashlib.sha256((public / name).read_bytes()).hexdigest()}  {name}\n")
(public / 'SHA256SUMS').write_text(''.join(checksums), encoding='ascii')
PY
if [[ "$diagnostic" == 1 ]]; then
  printf '%s\n' 'Ad Hoc 빌드 진단 통과: archive·export·실제 IPA 서명 검증을 완료했으며 임시 산출물을 정리합니다.'
  exit 0
fi
chmod 755 "$publish_dir"
chmod 644 "$publish_dir/Mirror.ipa" "$publish_dir/build-manifest.json" "$publish_dir/SHA256SUMS" "$publish_dir/release-notes.md"
printf 'publish_dir=%s\n' "$publish_dir" >> "$GITHUB_OUTPUT"
completed=1
printf '%s\n' '서명과 export 검증을 완료했습니다. 공개 산출물 네 개만 게시 단계로 전달합니다.'
