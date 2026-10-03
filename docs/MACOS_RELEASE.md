# macOS DMG와 GitHub Release

[배포 workflow](../.github/workflows/adhoc-release.yml)는 각 push에서 macOS 27 이상 Apple silicon(ARM64)용 앱을 Developer ID로 서명하고 Apple 공증을 통과한 DMG를 만든다. 같은 실행의 [iOS Ad Hoc 릴리스](ADHOC_RELEASE.md)에 Mac 자산을 추가한다. macOS 테스트 성공과 실제 배포 서명·공증 성공을 구분한다.

## 서명·공증 입력

[Actions Secrets](https://github.com/hellosunghyun/mirror/settings/secrets/actions)에 다음 네 값을 등록한다. 파일과 암호, Base64 값을 Git이나 채팅에 넣지 않는다.

| Secret | 값 |
|---|---|
| MAC_DEVELOPER_ID_P12_BASE64 | 개인 키를 포함한 Developer ID Application P12의 Base64 |
| MAC_DEVELOPER_ID_P12_PASSWORD | P12 내보내기 암호 |
| MAC_NOTARY_APPLE_ID | 인증서 Team에 속한 공증용 Apple ID |
| MAC_NOTARY_APP_PASSWORD | 해당 계정의 앱 전용 암호 |

Mac에서 파일 경로를 실제 내보낸 파일로 바꾸고 실행한다. 암호는 `gh secret set`의 입력창에 입력하며 명령줄 인자로 넣지 않는다.

```bash
base64 -i "$HOME/Downloads/인증서.p12" |
  gh secret set MAC_DEVELOPER_ID_P12_BASE64 --repo hellosunghyun/mirror
gh secret set MAC_DEVELOPER_ID_P12_PASSWORD --repo hellosunghyun/mirror
gh secret set MAC_NOTARY_APPLE_ID --repo hellosunghyun/mirror
gh secret set MAC_NOTARY_APP_PASSWORD --repo hellosunghyun/mirror
```

공증용 앱 전용 암호는 [Apple 계정](https://account.apple.com/)의 로그인 및 보안 → 앱 암호에서 생성한다. P12 내보내기 암호, Mac 로그인 암호와 각각 다르다. 공증에 사용할 Team은 검증한 인증서에서 비공개로 확인한다. Apple Development·iOS Distribution·Developer ID Installer 인증서는 이 앱 배포의 서명 인증서로 허용하지 않는다.

## 선택적 Release 게시 토큰

`MIRROR_RELEASE_TOKEN`을 등록하면 같은 Release의 IPA·DMG와 기본·다크 UI 검토 prerelease 게시 단계에서 이 값을 `GITHUB_TOKEN`으로 사용한다. 선택적 Secret이며 없으면 기존 `secrets.GITHUB_TOKEN`을 사용한다. 위 Mac 서명·공증 네 개와 iOS 서명 세 개의 입력 조건 및 모든 실제 검증 게이트를 유지한다.

GitHub의 fine-grained personal access token에서 Resource owner를 `hellosunghyun`으로 지정하고, Repository access의 **Only select repositories**에서 `hellosunghyun/mirror`만 선택한다. Repository permissions의 **Contents** 권한은 **Read and write**로 지정한다.

저장소를 관리하는 계정으로 로그인한 GitHub CLI에서 실행한 뒤 비공개 입력창에 토큰을 입력한다. 토큰 값을 채팅·Git·명령줄 인자에 넣지 않는다.

```bash
gh secret set MIRROR_RELEASE_TOKEN --repo hellosunghyun/mirror
gh secret list --repo hellosunghyun/mirror
```

등록된 이름 확인과 실제 게시 성공은 별도다. 등록 후 다음 Actions 실행에서 공개 DMG와 기존 iOS 자산의 보존을 확인한다.

## 게시 조건

1. Secret 존재와 Developer ID Application 인증서의 용도·유효기간·신뢰 및 대응 개인 키를 확인한다.
2. 동일 commit의 준비 회귀 검사와 SwiftPM·Mac·iPhone·iPad 실제 검증을 모두 통과한다.
3. 앱과 Widget·Share 확장을 ARM64 Release로 archive하고 원래 entitlements를 보존하여 내부 코드부터 서명한다. Hardened runtime, 보안 timestamp, 실제 인증서와 Team, 버전·빌드·최소 OS, 디버그 권한 부재를 검증한다.
4. 앱 ZIP 공증의 Accepted 상태와 앱 staple·Gatekeeper 검증을 확인한다. DMG를 생성·서명하고 다시 공증·staple·Gatekeeper 검증을 수행한다. DMG를 읽기 전용으로 마운트해 포함된 앱도 재검증한다.
5. 같은 실행의 공개 iOS prerelease에 아래 네 파일만 추가하고 GitHub API의 SHA-256·크기 및 태그 commit을 확인한다.

| 공개 자산 | 내용 |
|---|---|
| Mirror-macOS.dmg | 공증·staple을 완료한 설치 이미지 |
| macos-build-manifest.json | 공개 버전·빌드·commit·검증 결과·DMG 해시 |
| macos-SHA256SUMS | DMG·manifest·안내 파일의 SHA-256 |
| macos-release-notes.md | 지원 환경과 설치 안내 |

태그는 기존과 같은 `adhoc-실행ID`다. Mac 게시 후 iOS 네 파일을 포함해 총 여덟 자산이 있어야 한다. 재실행은 기존 iOS 자산을 보존하며 Mac 자산만 보완한다. iOS 게시의 재실행도 기존 Mac 자산을 보존한다. API는 파일별로 업로드하므로 Mac 게시 도중 일부 파일만 잠시 보일 수 있다.

P12·개인 키·키체인·Team·Apple ID·공증 요청 ID·원문 로그는 공개 자산에 포함하지 않는다. 비공개 임시 자료와 키체인 검색 목록·프로젝트 설정·마운트는 종료 시 정리·복원한다. 서명·공증 실패 시 Mac 자산을 게시하지 않으며 이미 성공한 iOS 배포는 유지한다.

실제 성공 여부는 해당 Actions 실행과 공개 자산으로 확인한다. App Group·iCloud 등록과 실제 기기에서의 Widget·Share·Siri·동기화 검증은 별도 작업이며 공증 성공만으로 완료를 주장하지 않는다.
