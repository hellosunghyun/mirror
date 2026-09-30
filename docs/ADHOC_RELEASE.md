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

Mac에서 인코딩할 때 다음 명령의 입력 파일 경로를 실제 파일로 바꾼다. 출력은 GitHub Secret 값에만 붙여 넣는다.

```bash
base64 -i /absolute/path/adhoc.mobileprovision | pbcopy
base64 -i /absolute/path/distribution.p12 | pbcopy
```

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
