# Ad Hoc 빌드와 GitHub Release

사용자가 제공한 Ad Hoc 프로파일 적용과 각 push의 GitHub Release 게시를 승인했다. [배포 workflow](../.github/workflows/adhoc-release.yml)는 모든 push와 수동 실행을 처리한다. 각 실행의 검증을 보존하며 새 push로 이전 배포를 취소하지 않는다.

## 서명 자료 등록

[GitHub Actions Secrets](https://github.com/hellosunghyun/mirror/settings/secrets/actions)에 다음 세 값을 등록한다. 프로파일·인증서·비밀번호를 공개 저장소나 채팅 본문에 넣지 않는다. 연결 앱의 Secret 쓰기 HTTP 403은 과거 기록이며 이후 사용자가 등록한 세 Secret의 존재는 최신 배포 실행에서 확인했다. 실제 서명 자료의 일치와 P12 암호는 별도 archive 검증이 필요하다.

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

[서명 빌드 진단 workflow](../.github/workflows/adhoc-diagnostics.yml)는 서명 빌드 도구가 변경된 push에서 별도로 실행한다. archive·export와 실제 IPA 서명을 검사하되 산출물과 비공개 로그는 정리하고, 실패 시 알려진 오류 종류의 고정 이름·개수만 출력한다. 원문 오류·서명 식별자는 출력하지 않는다. 이 진단의 성공은 전체 배포 검증 게이트를 대체하지 않으며 Release 게시 권한도 없다. 각 push의 실제 게시에는 기존 준비 검사와 네 Swift 검증 경로가 모두 필요하다.

러너에서만 앱·두 확장의 수동 서명 설정을 갱신한다. `PROVISIONING_PROFILE_SPECIFIER`에는 검증한 실제 프로파일 이름을, 기존 `PROVISIONING_PROFILE`에는 동일 프로파일의 UUID를 지정한다. 기존 이름이나 SDK별 선택 override를 제거하고 원본 프로젝트는 작업 종료 시 복원한다.

첫 실제 IPA 게시 전까지 자동화 코드 작성과 성공한 배포를 구별한다. 실제 UI·두 기기 동기화·전체 CloudKit 삭제·VoiceOver·사용자 검증의 남은 범위는 [요구사항 추적표](REQUIREMENTS_TRACEABILITY.md)에 유지한다.

## 원격 검증 기록

`4ef52f969059ff15c693b635bfd1596d69b42e25`의 [준비 검사 36791084443](https://github.com/hellosunghyun/mirror/actions/runs/36791084443)은 원본 무결성과 Python 회귀 40개를 통과했다. 기존 준비 9개, 합성 프로파일 검증 12개, 합성 IPA/API 게시 경계 19개다. 합성 테스트는 실제 Apple 개인키 서명이나 IPA 설치 성공을 대신하지 않는다.

같은 push의 [첫 자동 배포 36791084786](https://github.com/hellosunghyun/mirror/actions/runs/36791084786)은 세 서명 Secret이 모두 누락된 것으로 확인되어 준비 단계에서 실패했다. 배포용 검증·archive·publish는 실행되지 않았고 Release도 생성하지 않았다.

이후 사용자가 세 Secret을 등록했고, `1ca1d35ab1ef7fdcb45ef9a010cecdd83396feae`의 [자동 배포 36793731227 재시도 2](https://github.com/hellosunghyun/mirror/actions/runs/36793731227/attempts/2)에서 서명 입력 존재 확인이 실제 통과했다. 존재 확인은 인증서·개인키·프로파일 일치나 성공한 IPA 서명을 뜻하지 않는다. 실제 unit/UI 게이트를 통과한 다음 archive·export·게시 결과를 확인해야 한다.

같은 소스의 [Swift 검증 36793734833](https://github.com/hellosunghyun/mirror/actions/runs/36793734833)은 SwiftPM 151개와 Mac unit 151개·UI 6개를 통과했지만 모바일 UI 실패로 전체 실패했다. iPhone stdout는 6개 실패, iPad는 3개 통과·3개 실패였고, 양쪽 모두 결과 마감 지연과 15분 중단으로 최종 UI 결과 파일과 strict guard를 확보하지 못했다. 남은 실패를 수정한 후 새 push의 검증·서명·게시를 진행한다.

`179428d98dcbfa61470395f7acbd5653b9f25c06`의 [준비 검사 36796647485](https://github.com/hellosunghyun/mirror/actions/runs/36796647485)는 Python 40개를 통과했다. [Swift 검증 36796650352](https://github.com/hellosunghyun/mirror/actions/runs/36796650352)에서 SwiftPM 151개, Mac unit 151개·UI 6개, iPad unit 150개·UI 6개가 통과했고 Mac/iPad UI는 최종 결과와 strict guard에서 실패·skip 0을 확인했다. iPhone unit 150개는 통과했지만 UI stdout는 4개 통과·2개 실패였고 15분 제한으로 최종 결과를 마감하지 못했다. 남은 실패는 상세 화면에서 가려진 Undo와 검색 결과의 상세 전환이다.

동일 push의 [자동 배포 36796647867](https://github.com/hellosunghyun/mirror/actions/runs/36796647867)은 세 Secret 존재 확인·준비 검사·SwiftPM·Mac을 통과했다. 이 실행의 iPhone/iPad UI는 각각 15분 시간 초과여서 위 별도 Swift 실행의 iPad 통과를 배포 게이트 통과로 대신하지 않는다. Archive와 publish는 건너뛰었고 인증서·개인키·프로파일 일치, 실제 IPA와 GitHub Release는 아직 미검증이다.

후속 변경은 상세 화면 안에 직전 Undo를 고정 배치하고, 검색 결과를 열기 전에 검색 포커스를 해제하며, 활성 화면만 상세 선택을 해제하도록 한다. UI 사례마다 앱을 종료하고 모바일 UI 제한은 20분으로 조정한다. 기존 여섯 사례와 최종 결과 검증은 유지하며 다음 push에서 실제 결과를 확인한다.

이 변경을 포함한 `873049b2709de2a97dffbdb49a55706870f33373`의 [준비 검사 36800188766](https://github.com/hellosunghyun/mirror/actions/runs/36800188766)는 Python 40개를 통과했다. [자동 배포 36800189042](https://github.com/hellosunghyun/mirror/actions/runs/36800189042)는 세 Secret·준비·SwiftPM을 통과했지만 Mac UI에서 5개 통과·1개 실패·skip 0이었다. 실패는 Undo 실행 전 상세 제목 입력란이 창 위쪽에 가려지고 접근 가능한 스크롤 컨테이너가 없었던 편집 단계다. iPhone/iPad UI는 이 기록 시점 진행 중이며 archive·publish는 아직 실행되지 않았다.

후속 수정은 Mac 상세 Form을 grouped 스타일과 가용 높이에 맞춰 스크롤할 수 있게 하고, UI 테스트도 대상이 뷰포트 위에 있으면 위로 스크롤해 실제 접근성을 확인한다. 상태 패널 부모의 진단용 ID가 자식의 오류·Undo ID를 덮는 문제를 제거한다. 숨은 요소의 강제 탭이나 assertion 생략은 추가하지 않으며 새 push의 검증·실제 서명 결과를 확인한다.

`873049b` 자동 배포의 모바일 두 UI는 최종적으로 각각 20분 제한으로 중단됐다. iPad 첫 사례에서 `review.finish`의 접근성 hit point 계산 오류가 기록됐지만 최종 UI summary/tree가 없어 전체 여섯 사례의 결과수는 미확정이다. Archive와 publish는 skipped였다. 같은 SHA의 별도 Swift 실행은 새 push에 의해 자동 취소됐으며 Mac의 완료 결과만 확보했고 모바일 결과를 완료로 기록하지 않는다.

`a7ef8a2df18a92e1146fde9b1b6c0ad451cc9a41`의 [자동 배포 36801483055](https://github.com/hellosunghyun/mirror/actions/runs/36801483055)는 Mac 단위 151개와 UI 5개를 통과했지만 완료·Undo 사례 하나가 실패했다. 제목 입력란에는 접근한 뒤 `task.complete`의 기대 상태가 표시되지 않았고 실제 버튼은 label=완료, enabled/hittable=true였다. 기존 진단에는 기대값·직전 입력·현재 오류가 없어 클릭 미실행과 명령 거절을 구분할 수 없다. 모바일 UI는 이 기록 시점 진행 중이며 archive 게이트는 차단됐다.

후속 수정은 regular 화면의 상태 패널을 화면 내용과 VStack 형제로 배치해 높이를 나누고, 시작·온보딩 오류와 compact 탭 배치를 유지한다. UI 상태 대기 실패에는 기대값·직전 입력·현재 오류를 기록하며 중단 진단에는 stdout의 사례 진행과 suite 요약을 별도로 남긴다. stdout 진단을 최종 결과 파일·strict guard 통과로 대신하지 않으며 실제 서명·IPA·Release 성공은 계속 미검증이다.

`a7ef8a2`의 모바일 두 UI도 각각 20분 제한으로 중단돼 최종 UI 결과를 확보하지 못했고 archive·publish는 skipped였다. `68c4c9d08d63667c4b26d4c2f52052a53fe91fdf`의 [자동 배포 36803345968](https://github.com/hellosunghyun/mirror/actions/runs/36803345968)는 준비·SwiftPM과 Mac 단위 151개를 통과했지만 Mac UI는 5개 통과·1개 실패·skip 0이었다. 추가 진단에서 최초 완료 상태 대기 실패, 직전 입력 `task.complete`, 편집 제목 정상 반영, 피드백 `내용을 저장했어요.`, 오류 메시지 없음이 확인됐다. stdoutOnly와 실제 xcresult의 5/6 결과가 일치했다. 해당 시점 모바일 UI는 진행 중이며 서명은 실행되지 않았다.

후속 수정은 상세 완료 버튼을 Form의 상태 행에서 Undo와 같은 고정 하단 영역으로 옮기고 실제 버튼 라벨에 44pt 높이를 확보한다. 기존 완료 명령·ID·저장 중 비활성화와 삭제 작업/Undo receipt 조건, 휴지통·복구·이력은 유지한다. 클릭 미전달과 모델 guard 거절의 원인을 확정하지 않으며 기존 여섯 실제 UI 사례로 새 배치를 검증한다.

이 변경을 포함한 `027a8cbce6842973ba7ad986ec411251483ce7c5`의 [자동 배포 36805275410](https://github.com/hellosunghyun/mirror/actions/runs/36805275410)은 최종 failure다. 서명 입력 존재·준비·SwiftPM job은 성공했고 Mac은 단위 151개/UI 6개, iPad는 단위 150개/UI 6개가 실제 최종 결과에서 모두 통과했다. Mac/iPad strict guard는 bundle 1개/case 6개이며 missingMethods·nonPassedMethods가 없고 실패·skip도 0개다.

iPhone 단위 150개는 통과했지만 UI는 20분 제한으로 중단됐다. stdoutOnly에는 여섯 case의 시작/완료와 capture·긴 제목·정리 Undo·주 패널의 4개 passed, 완료 Undo·내일 검색의 2개 failed가 있다. suite 요약은 6 tests/2 failures/0 unexpected, 920.990초였고 xcodeCompletionReported=false다. 최종 UI summary/tree/strict guard가 없으므로 stdout 4/6을 최종 xcresult 통과·skip 0으로 기록하지 않는다. 실제 assertion·selector·AX 오류 본문이 확보되지 않아 두 실패의 원인은 미확정이다. Archive `110194664010`와 publish `110194664167`는 skipped였고 실제 인증서·개인키·프로파일 일치, IPA 서명/export와 Release 게시도 미검증이다.

같은 커밋의 [별도 Swift 실행 36805279997](https://github.com/hellosunghyun/mirror/actions/runs/36805279997)도 최종 failure다. SwiftPM 151개, Mac 단위 151개/UI 6개와 iPad 단위 150개/UI 6개는 통과했고 Mac/iPad strict guard의 실패·skip은 0개다. iPhone 단위 150개는 통과했지만 UI는 stdout 4개 통과·2개 실패, suite 6 tests/2 failures/0 unexpected·946.160초, xcodeCompletionReported=false를 남긴 뒤 20분 제한으로 중단됐다. 이 946.160초는 Ad Hoc 실행의 920.990초와 별도 증거이며 iPhone 최종 UI summary/tree/strict guard는 확보하지 못했다.

별도 실행의 완료 Undo 사례는 편집 제목 입력까지 정상이고 `detail.save`가 존재하지만 hittable=false였다. CollectionView frame=(0,62,402,350)에서 swipeUp 한 번 뒤 `detail.save` 버튼의 NoMatches snapshot 오류로 실패했다. 실제 저장 탭·완료·Undo 이전 실패이므로 완료 명령이나 Undo의 실패 원인으로 단정하지 않는다. 내일 검색 사례는 row를 실제 탭한 뒤 keyboard frame=(0,590,402,226)이 남고 `detail.plan`이 없었다. 자동 저장이나 overlay를 원인으로 확정하지 않으며 두 실패의 실제 동작 원인은 후속 검증이 필요하다.

이전 커밋 `38d78498ff56781b9762893c0d96b77cf253176d`의 [Ad Hoc 실행 36808965234](https://github.com/hellosunghyun/mirror/actions/runs/36808965234)은 최종 failure다. 세 서명 Secret의 존재·준비 Python 40개·SwiftPM 151개는 통과했다. Mac 단위 151개/UI 6개도 통과했고 UI strict guard는 bundle 1개/case 6개, 실패·skip 0개다. iPhone/iPad 단위는 각각 150개 통과했다.

iPhone UI stdout은 완료·Undo를 포함한 5개 통과와 내일 검색 1개 실패, suite 971.203초다. iPad UI stdout은 4개 통과와 내일 검색·주 패널 부분 종료 2개 실패, suite 1017.165초다. 두 모바일 모두 xcodeCompletionReported=false이며 UI가 20분 제한으로 중단됐다. 최종 UI summary/tree/strict gate를 확보하지 못했으므로 stdout 결과를 최종 xcresult 통과·skip 0이나 전체 UI 수용으로 기록하지 않는다. archive·publish는 skipped이고 실제 P12 암호 검증·인증서/개인키/프로파일 일치·서명된 IPA와 Release 게시는 미검증이다. 이 실행 후 확인한 Release API 목록은 0개다.

같은 커밋의 [별도 Swift 실행 36808970265](https://github.com/hellosunghyun/mirror/actions/runs/36808970265)은 최종 failure다. Mac 단위 151개/UI 6개와 SwiftPM 151개는 통과했다. iPad job `110199559968`도 단위 150개/UI 6개 통과, UI summary 실패·skip 0개와 strict guard bundle 1개/case 6개/missingMethods·nonPassedMethods 없음을 확인했다. iPhone은 stdout 5개 통과·내일 검색 1개 실패, suite 765.085초와 20분 UI 제한 중단으로 실패했다. 별도 실행의 iPad 최종 통과와 Ad Hoc iPad의 stdout 4개 통과·2개 실패/집계 중단을 구분하며 별도 결과로 배포 게이트 실패를 대신하지 않는다.

`38d7849`에는 상세 편집 저장·취소를 Form 밖 고정 footer의 우선 영역에 44pt 높이로 배치하고 compact content/statusBar에 형제 높이를 할당한 변경이 포함됐다. 기존 snapshot·접근성 ID·isSaving guard와 여섯 UI 사례의 모든 assertions·통과 판정은 유지했다. iPhone의 완료·Undo 실제 case Passed는 확인했지만 이를 전체 UI나 QA 87개 완료로 확대하지 않는다. 실제 SDK help의 -enableCodeCoverage 지원과 두 모바일 UI의 coverage NO notice도 확인했으나 결과 마감 문제 해결은 입증되지 않았다. 시간 초과나 stdout 결과를 테스트 성공으로 바꾸지 않는다.

이전 `38d7849`의 별도 실행 전체 로그에서 최초 내일 검색 실패 시 직전 검색행 frame=(16,383,370,102)의 중심 Y는 434이고, 진단 시 유일한 보관함 CollectionView frame=(0,0,402,403)의 하단보다 31pt 아래였다. 실제 행 Tap/Synthesize 뒤 키보드가 남고 `detail.plan`이 없었으며 `state.feedback`은 `완료했어요.`였다. 캐시된 행 좌표와 실패 진단 시 표시 영역의 관측은 접근 geometry 보완의 근거이며 전체 원인 확정을 뜻하지 않는다.

이전 커밋 `32b61596a9a6d18d31232cf9b83a640e6320050f`의 [Ad Hoc 실행 36812798695](https://github.com/hellosunghyun/mirror/actions/runs/36812798695)은 최종 failure다. 세 서명 입력 존재·준비 Python 40개·SwiftPM 151개와 Mac 단위 151개/UI 6개는 통과했다. Mac UI strict guard는 bundle 1개/case 6개, 실패·skip 0개다. 모바일 단위는 iPhone/iPad 각각 150개 통과했다. iPhone UI stdout은 3개 통과와 완료·Undo/내일 검색/주 패널 부분 종료 3개 실패, iPad는 2개 통과와 capture/완료·Undo/내일 검색/주 패널 부분 종료 4개 실패였다. 두 모바일은 xcodeCompletionReported=false로 각각 20분 제한 중단됐고 최종 UI summary/tree/strict guard는 확보하지 못했다. archive·publish는 skipped이며 Release 목록은 0개다. 실제 P12 암호·인증서/개인키/프로파일 일치와 서명 IPA·Release 게시는 미검증이다.

같은 커밋의 [별도 Swift 실행 36812801840](https://github.com/hellosunghyun/mirror/actions/runs/36812801840)은 이 기록 시점 Mac 단위 151개/UI 6개와 SwiftPM 151개를 통과했다. iPhone 단위 150개는 통과했고 UI stdout 3개 통과·3개 실패, suite 747.419초 뒤 20분 제한으로 중단됐다. iPad UI는 진행 중으로 최종 결과가 미확정이다. 별도 실행의 부분 결과나 과거 iPad 통과를 이번 배포 게이트 통과로 대신하지 않는다.

이전 `32b6159` Ad Hoc iPad의 최초 실패는 `review.finish`의 hittability 조회에서 invalid activation point가 발생한 것으로 MirrorUITests.swift:247에 기록됐다. 구체적인 소유 영역·geometry 증거는 별도 실행 iPhone annotation에서 확인했다. 완료·Undo 사례의 행 중심 Y 약 333은 CollectionView의 하단 648 안에 있었지만 소유 컨테이너 guard에서 실패했고, today.list는 존재하며 키보드는 없었다. 내일 검색 사례도 같은 소유 영역 guard에서 실패했다. 이 결과만으로 컨테이너 hittability=false를 단독 원인으로 확정하지 않는다.

이전 소유 컨테이너·부재 검사 보완은 `task.row.*`의 소유 컨테이너 탐색에서 컨테이너 hittability 필터 대신 실제 descendant ID·양수 frame·실제 window와의 교집합을 확인한다. 후보의 id/type/frame/containsTarget/window 진단을 남겨 소유 관계와 표시 영역을 확인한다. 행 자체의 hittable/enabled·중심의 표시 영역 포함 조건, 최대 8회 실제 scroll·일반 native tap은 유지한다. 닫힌 버튼의 부재 검사는 hittability를 조회하지 않고 전체 matching ID의 firstMatch.exists=false를 기존 15초 동안 확인한다. 제품 소스·상태·명령과 기대값·여섯 사례의 28개 assertions·15초 대기·최종 xcresult/strict guard 판정은 유지한다. 고정 좌표 tap이나 행동 재시도는 추가하지 않는다. 이 보완만으로 성공을 확정하지 않으며 후속 실행의 실제 결과와 구분한다.

이전 커밋 `25515ee`의 [Ad Hoc 실행 36815613352](https://github.com/hellosunghyun/mirror/actions/runs/36815613352)은 Mac 단위 151/151개 통과·UI 3/6개 통과/3개 실패·skip 0개, xcodeCompletionReported=true였다. 실패는 완료·Undo/내일 검색/주 패널 사례다. 이후 iPhone은 단위 150개/UI 6개를 통과했지만 iPad UI는 stdout 3개 passed·1개 failed, 내일 검색 started·주 패널 미보고 상태에서 20분 제한으로 중단됐다. iPad 최종 UI summary/tree/strict guard는 없으며 archive·publish는 실행하지 못했다.

같은 `25515ee`의 [별도 Swift 실행 36815617243](https://github.com/hellosunghyun/mirror/actions/runs/36815617243)은 최종 cancelled였다. 완료한 iPhone job `110221075621`의 단위 150/150개/UI 6/6개 통과·실패/skip 0개와 strict guard bundle 1개/case 6개/missing·nonPassed 없음은 부분 증거로 보존한다. 취소된 별도 실행이나 그 부분 성공으로 당시 Ad Hoc의 실패를 대신하지 않는다.

이후 확보한 `25515ee` 전체 로그는 content 열 X=152..432의 행에 대해 sidebar X=-38..152를 소유 영역으로 선택하고 실제 스크롤 8회 뒤 세 사례가 실패한 경로를 확인했다. sameColumn·선택 owner 진단 변경을 포함한 `2da19a9`에서 Mac 여섯 UI 사례가 최종 통과했다. 기존 여섯 사례 본문·28개 assertions·최대 8회 실제 스크롤·행 hittable/enabled 확인·실제 tap·최종 xcresult/strict guard 판정은 유지했다.

최신 커밋 `2da19a9`의 [Ad Hoc 실행 36817569714](https://github.com/hellosunghyun/mirror/actions/runs/36817569714)은 서명 입력 존재·준비 Python 40개·SwiftPM 151개를 통과했다. Mac 단위 151개/UI 6개, iPhone 단위 150개/UI 6개, iPad 단위 150개/UI 6개도 모두 실제 최종 summary에서 통과했다. 세 플랫폼의 UI 실패·skip은 0개이며 strict guard는 각각 bundle 1개/case 6개/missingMethods·nonPassedMethods 없음이다. 여섯 UI 부분 시나리오 통과는 QA 87개 전체나 실기기·시스템 표면 수용 완료를 뜻하지 않는다.

archive job `110231668813`은 `프로파일과 일치하며 개인 키가 있는 서명 인증서가 정확히 하나여야 합니다.`라는 match guard 메시지로 실패했고 publish는 skipped였다. 서명 IPA와 Release는 생성하지 못했다. 현재 -v codesigning 조회는 유효한 identity만 확인하므로 이 메시지만으로 P12 암호 오류·다른 인증서·개인키 부재·신뢰 체인 문제를 구분할 수 없다. 테스트 통과와 실제 서명·게시 성공을 구분한다.

후속 서명 검사 보완은 --preflight 모드에서 프로파일 준비 단계까지 검증한 뒤 임시 자료를 정리한다. 전체 identity·valid identity와 각각의 profile 일치 수, 가져온 인증서의 matchingImportedCertificateCount만 안전 진단으로 남긴다. 프로파일 준비 출력은 비공개 파일에 보관하고 고정 signing_stage 오류 notice를 사용하며 구체 도구 출력·해시·DN·서명 자료는 출력하지 않는다. 인증서 부재·인증서는 있지만 개인키 identity를 조회하지 못한 상태·전체 identity는 일치하지만 valid identity가 없는 상태를 정적 메시지로 구분하되 valid identity가 정확히 하나여야 하는 기존 선택 gate는 유지한다. workflow는 presence 뒤 별도 signing-materials job을 병렬로 실행하고 archive에 기존 네 검증 gate와 새 서명 preflight 성공을 함께 요구한다. 실제 서명 원인 판별과 이 변경의 효과는 새 SHA의 Actions 검증 대기다. 제품 상태·명령·테스트 기대값과 QA 87개 원본은 유지하며 서명 IPA·Release·실기기 수용은 미완료다.
