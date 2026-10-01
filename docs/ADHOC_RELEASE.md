# Ad Hoc 빌드와 GitHub Release

사용자가 제공한 Ad Hoc 프로파일 적용과 각 push의 GitHub Release 게시를 승인했다. [배포 workflow](../.github/workflows/adhoc-release.yml)는 모든 push와 수동 실행을 처리한다. 각 실행의 검증을 보존하며 새 push로 이전 배포를 취소하지 않는다.

## 서명 자료 등록

[GitHub Actions Secrets](https://github.com/hellosunghyun/mirror/settings/secrets/actions)에 다음 세 값을 등록한다. 프로파일·인증서·비밀번호를 공개 저장소나 채팅 본문에 넣지 않는다. 현재 연결 앱의 Secret 쓰기 요청은 HTTP 403으로 거부되어 저장소 관리자가 직접 등록해야 한다.

| Secret | 값 |
|---|---|
| IOS_ADHOC_PROFILE_BASE64 | 제공한 adhoc.mobileprovision의 Base64 |
| IOS_DISTRIBUTION_P12_BASE64 | 프로파일의 인증서와 일치하는 개인키 포함 Apple Distribution .p12의 Base64 |
| IOS_DISTRIBUTION_P12_PASSWORD | .p12를 내보낼 때 지정한 비밀번호 |

프로파일에는 인증서의 공개 부분만 있다. Mac의 키체인 접근에서 대응하는 Apple Distribution 인증서와 개인키를 함께 선택해 .p12로 내보낸다. 인증서만 내보내거나 다른 개인키를 사용하면 서명 검증에 실패한다. Base64는 암호화가 아니며 두 파일의 Base64도 Secret으로 취급한다.

인증서를 생성한 Mac에서 내보내는 순서는 다음과 같다.

1. Spotlight에서 **키체인 접근**을 연다. **암호** 앱과 구분한다.
2. **로그인(login)** 키체인과 **나의 인증서(My Certificates)** 항목을 선택한다.
3. 프로파일 생성 때 선택한 **Apple Distribution** 또는 **iPhone Distribution** 인증서를 찾는다. 같은 이름의 인증서가 여러 개라면 임의로 선택하지 않는다.
4. 인증서 왼쪽 삼각형을 펼쳐 아래에 **개인 키**가 있는지 확인한다.
5. 인증서와 해당 개인 키를 함께 선택하고 우클릭 또는 파일 메뉴의 **항목 내보내기…**를 선택한다.
6. 이름을 **distribution.p12**, 형식을 **개인 정보 교환(.p12)**으로 지정해 저장한다.
7. 내보내기 암호는 새로 정해 두 칸에 동일하게 입력한다. 이어지는 키체인 접근 허용 창에서 요구하는 Mac 로그인 암호와 구분한다. 내보내기 암호를 `IOS_DISTRIBUTION_P12_PASSWORD`에 등록한다.

Mac에서 인코딩할 때 다음 명령의 입력 파일 경로를 실제 파일로 바꾼다. 출력은 GitHub Secret 값에만 붙여 넣는다.

```bash
base64 -i /absolute/path/adhoc.mobileprovision | pbcopy
base64 -i /absolute/path/distribution.p12 | pbcopy
```

GitHub CLI로 등록할 때는 저장소를 관리하는 계정으로 로그인하고 두 파일이 있는 폴더에서 실행한다. `.p12` 암호는 내보내기 시 지정한 값이며 마지막 등록 명령의 입력창에 넣는다. `gh secret list`는 등록된 이름을 확인한다.

```bash
gh auth login
base64 -i adhoc.mobileprovision | tr -d '\n' |
  gh secret set IOS_ADHOC_PROFILE_BASE64 --repo hellosunghyun/mirror
base64 -i distribution.p12 | tr -d '\n' |
  gh secret set IOS_DISTRIBUTION_P12_BASE64 --repo hellosunghyun/mirror
gh secret set IOS_DISTRIBUTION_P12_PASSWORD --repo hellosunghyun/mirror
gh secret list --repo hellosunghyun/mirror
```

키체인에 인증서의 개인키가 없다면 인증서를 생성한 Mac에서 개인키 포함 `.p12`를 내보내야 한다. Apple Developer의 `.cer` 다운로드나 provisioning profile만으로 개인키를 복구할 수는 없다.

제공된 프로파일은 iOS를 포함하는 Ad Hoc 배포용, 와일드카드 Bundle ID, 등록 기기 1대, 배포 인증서 1개다. 앱·Widget·Share 세 Bundle ID의 일치를 각각 검증한다. 현재 프로파일에는 App Group과 iCloud 권한이 없다. 이 권한을 임의로 추가하지 않으며, 실제 공유 저장·CloudKit 연결에는 별도 등록과 해당 권한을 포함한 프로파일이 필요하다.

## 배포 순서와 결과

1. 서명 Secret 등록을 확인한다.
2. 동일 push의 원본 무결성·Python 배포 도구 회귀와 SwiftPM·Mac·iPhone·iPad 검증을 실행한다. 준비 검사나 실제 unit/UI·필수 bundle·metadata 검사가 실패하면 배포를 진행하지 않는다.
3. Xcode 27의 generic iOS 기기 대상으로 Release archive를 만들고 release-testing 방식으로 Ad Hoc IPA를 내보낸다.
4. 프로파일 유효기간·배포 종류·Team·인증서·entitlements, 앱 및 두 확장의 실제 서명·프로파일·build number를 확인한다.
5. IPA·공개 build manifest·SHA256SUMS·릴리즈 안내만 GitHub Release에 게시한다.

Release 태그는 adhoc-실행ID다. 실행을 재시도하면 같은 태그의 자산을 갱신한다. build number는 workflow 실행 번호다. 테스트용 Ad Hoc 배포이므로 prerelease로 게시하며, 등록된 기기와 최소 OS 27 요구를 만족해야 설치할 수 있다.

프로파일 원본, .p12, 개인키, 키체인, archive와 배포 로그는 Release와 Git에 넣지 않는다. 임시 키체인과 설치한 프로파일은 실행 종료 시 정리한다. Secret 미등록·만료·서명 불일치·검증 실패를 빈 Release 게시로 대신하지 않는다.

첫 실제 IPA 게시 전까지 자동화 코드 작성과 성공한 배포를 구별한다. 실제 UI·두 기기 동기화·전체 CloudKit 삭제·VoiceOver·사용자 검증의 남은 범위는 [요구사항 추적표](REQUIREMENTS_TRACEABILITY.md)에 유지한다.

## 원격 검증 기록

`4ef52f969059ff15c693b635bfd1596d69b42e25`의 [준비 검사 36791084443](https://github.com/hellosunghyun/mirror/actions/runs/36791084443)은 원본 무결성과 Python 회귀 40개를 통과했다. 기존 준비 9개, 합성 프로파일 검증 12개, 합성 IPA/API 게시 경계 19개다. 합성 테스트는 실제 Apple 개인키 서명이나 IPA 설치 성공을 대신하지 않는다.

같은 push의 [첫 자동 배포 36791084786](https://github.com/hellosunghyun/mirror/actions/runs/36791084786)은 세 서명 Secret이 모두 누락된 것으로 확인되어 준비 단계에서 실패했다. 배포용 검증·archive·publish는 실행되지 않았고 Release도 생성하지 않았다.

이후 사용자가 세 Secret을 등록했고, `1ca1d35ab1ef7fdcb45ef9a010cecdd83396feae`의 [자동 배포 36793731227 재시도 2](https://github.com/hellosunghyun/mirror/actions/runs/36793731227/attempts/2)에서 서명 입력 존재 확인이 실제 통과했다. 존재 확인은 인증서·개인키·프로파일 일치나 성공한 IPA 서명을 뜻하지 않는다. 실제 unit/UI 게이트를 통과한 다음 archive·export·게시 결과를 확인해야 한다.

같은 소스의 [Swift 검증 36793734833](https://github.com/hellosunghyun/mirror/actions/runs/36793734833)은 SwiftPM 151개와 Mac unit 151개·UI 6개를 통과했지만 모바일 UI 실패로 전체 실패했다. iPhone stdout는 6개 실패, iPad는 3개 통과·3개 실패였고, 양쪽 모두 결과 마감 지연과 15분 중단으로 최종 UI 결과 파일과 strict guard를 확보하지 못했다. 남은 실패를 수정한 후 새 push의 검증·서명·게시를 진행한다.
