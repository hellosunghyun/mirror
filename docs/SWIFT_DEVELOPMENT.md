# Swift 개발 안내

## 앱과 모듈 구성

현재 통합 코드에는 15개 native 타깃과 4개 SwiftPM 라이브러리가 있다. 첫 전체 구현 커밋은 `67d69e952311b93c50ce874dab0aaa2347c95264`다. 이전 완료 검증 `179428d`에서 공통 명령·실제 SQLite·시스템 계약과 Mac/iPad의 여섯 UI 시나리오가 통과했다. 최신 `38d7849` Ad Hoc의 Mac UI 여섯 사례는 통과했고 iPhone 완료·Undo도 stdout Passed를 확인했다. 모바일 UI는 iPhone 5개 통과·1개 실패, iPad 4개 통과·2개 실패 뒤 모두 20분 제한으로 중단됐다. 작성 완료나 부분 UI 통과를 전체 수용 통과로 기록하지 않는다.

| 타깃 | 역할 | 지원 |
|---|---|---|
| MirrorIOS / MirrorMac | 실제 capture·Today·정리·검색/휴지통·상세·설정·내보내기 UI | iPhone·iPad·macOS 27 |
| MirrorDomain | 날짜·typed 명령·불변 OperationRecord·그룹별 reducer·조건부 Undo | 모든 표면의 공통 규칙 |
| MirrorData | 실제 Core Data 원본/로컬 투영 SQLite·process gate·복구·export/import | 앱과 공유 확장 |
| MirrorSystem | composition root·Widget 카드·App Intents·EventKit·알림·Spotlight·선택 CloudKit | 실제 시스템 adapter |
| MirrorDesign | 한국어·Mac 대응 SwiftPieces TaskRow/ExpandableText/StatusMorph | SwiftUI 앱 |
| MirrorDomainTests / MirrorDataTests / MirrorSystemTests | 같은 생산 소스의 도메인·실제 SQLite·시스템 계약 검증 | SwiftPM 및 세 native 경로 |
| MirrorIOSWidgets / MirrorMacWidgets | 위젯과 iOS Control | 플랫폼별 app에 embedding |
| MirrorIOSShare / MirrorMacShare | 원문/URL을 공통 capture로 저장 | 플랫폼별 app에 embedding |
| MirrorIOSUITests / MirrorMacUITests | seed/mock 없이 실제 화면 입력·저장·Undo 6개 시나리오 | iPhone·iPad·Mac UI scheme |

`python3 scripts/generate-xcode-project.py`로 외부 생성기·패키지 의존성 없이 소스 glob 기반 프로젝트를 재생성한다. source/test/extension 파일 추가 후 생성 파일을 함께 커밋한다. Swift compiler는 Xcode 27의 6.4, 언어 모드는 Swift 6, strict concurrency는 complete다. domain/data/system/test 기본 격리는 nonisolated, SwiftUI 앱은 명시 MainActor다.

개발 Bundle ID는 `com.baserize.mirror`와 `com.baserize.mirror.mac` 및 각 호스트의 Widget/Share suffix다. Team은 사용자가 제공한 Ad Hoc profile에서 비공개로 확인했다. Secrets API는 integration 권한 부족으로 403을 반환했고 [최초 Ad Hoc 실행 36791084786](https://github.com/hellosunghyun/mirror/actions/runs/36791084786)에는 서명용 세 Secrets가 누락됐지만, [후속 실행 36796647867](https://github.com/hellosunghyun/mirror/actions/runs/36796647867)의 입력 검사는 세 Secrets의 존재를 확인했다. 모바일 UI 게이트 실패로 archive가 실행되지 않아 실제 인증서·개인키 일치와 IPA 서명/export는 아직 미검증이다. App Group·iCloud container 권한은 제공된 profile에 없으며 Info.plist의 연결 값은 비어 있고 capability 상태는 configurationRequired다. 실제 Apple 등록·서명 IPA 배포는 미검증이다. unsigned CI embedding은 공유 컨테이너 접근 성공을 뜻하지 않는다. 확장은 App Group 없이 별도 로컬 폴더로 fallback하지 않는다. Ad Hoc 자동화의 별도 조건은 [배포 안내](ADHOC_RELEASE.md)를 따른다.

저장 선택·복원·계정/삭제 경계는 [구현 결정 기록](ARCHITECTURE_DECISIONS.md), 전체 범위는 [구현 계획](IMPLEMENTATION_PLAN.md), 부분 증거는 [추적표](REQUIREMENTS_TRACEABILITY.md)를 따른다. SwiftPieces 원본 커밋·라이선스·플랫폼 변경은 [고지](../Sources/MirrorDesign/SwiftPieces/PROVENANCE.md)에 보존한다.

## D-02 날짜와 판정

`LocalDate`는 엄격한 ASCII YYYY-MM-DD Gregorian 날짜를 보존한다. 잘못된 날짜를 정규화하지 않고 1~9999년 범위를 검사한다. Gregorian 400년 주기를 사용해 역사적 달력 전환에도 일관된 날짜 의미를 유지하며 내일과 주간 범위는 Calendar 날짜 덧셈으로 계산한다.

`PlanningContext`는 호출자가 제공한 시각, 계획 시간대, 정책 버전을 보존한다. 시스템 시계나 기기 현재 시간대로 암묵적으로 바꾸지 않는다. 저장한 날짜는 계획 시간대가 바뀌어도 이동하지 않는다.

`PlanTarget`은 unassigned/day/week/parked의 절대 목적지를 계약 JSON으로 읽고 쓴다. raw 목적지는 형식을 복원하고 주의 의미는 별도 검증한다. 작업 판정용 `TaskPlanningState` 복원은 주 시작·7일 범위의 구조를 검사하되 유효한 과거 계획은 보존한다. 새 배치는 과거 day나 끝난 week를 거부한다.

`PlanningRules`는 명시적 Today 목록, 자동/이어 정리/오늘 다시 정리 후보, 검토 유예, 마감 이후 확인과 taskID/deadlineRevision/target 바인딩, receipt를 먼저 확인하는 stale context 순서를 제공한다. 판정 함수는 순수하다. typed CommandValidator/TaskReducer와 MirrorData의 durable 조회·원본 append·projection이 이를 사용한다. CloudKit 미러링은 사용자 opt-in과 실제 등록 조건을 요구한다.

## 테스트 실행

테스트는 GitHub Actions의 `xcode-27` arm64 public preview 러너에서 실행한다. `DEVELOPER_DIR`는 `/Applications/Xcode_27.app/Contents/Developer`로 고정한다. 테스트 수행 자체는 클라우드 Linux에서 실행하지 않는다.

| CI 경로 | 실제 명령 | 결과 |
|---|---|---|
| SwiftPM | bash scripts/ci-swift-package.sh | Swift Testing 완료 결과와 실행 수 |
| Mac | bash scripts/ci-apple-platform.sh macos | MirrorMac build/test, 필수 3개 unit/integration bundle 및 MirrorMacUI test |
| iPhone | bash scripts/ci-apple-platform.sh iphone | iOS 27 iPhone Simulator의 MirrorIOS build/test 및 MirrorIOSUI test |
| iPad | bash scripts/ci-apple-platform.sh ipad | iOS 27 iPad Simulator의 MirrorIOS build/test 및 MirrorIOSUI test |

SwiftPM은 원본 fixture를 `.build/mirror-test-fixtures`에 복사하고 경로를 주입한다. Xcode는 같은 원본을 test bundle의 resource로 복사한다. 테스트는 버전·36개 ID·종류별 개수·payload를 검사하고 fixture 로딩 실패를 빈 테스트 목록으로 바꾸지 않는다.

CI는 원본 fixture 36개와 날짜/시간대/윤년/DST/자정/주 구조/검토/마감 경계 테스트를 실행한다. `scripts/ci_results.py`는 실제 테스트 수가 양수이고 XCTest 결과에 실패·skip이 없는지 확인한다. UI에서는 필수 여섯 baseline 메서드가 선언돼 있고, 현재 선언된 추가 메서드까지 실제 `Test Case`의 `Passed` 결과가 있는지 검사한다. 원래 build/test 명령의 종료 코드를 보존하고 결과 실패를 약화하지 않는다. 현재 실행의 log와 xcresult는 7일 동안 artifact로 보존한다. 최종 결과 job 이름에도 실행 수를 기록해 API로 확인할 수 있다.

단위 증거의 연결은 다음과 같다. 전체 QA 성공을 뜻하지 않는다.

| 검사 | 요구사항·QA의 관련 부분 |
|---|---|
| F-001~F-007 날짜 목적지 | FR-006/007/008/023, Q-010/014의 날짜 규칙 |
| F-008~F-020 Today/Review | FR-001/004/008/010/012/024, Q-001/013/014/017/018/024 판정 |
| F-021~F-025 마감 확인 | FR-014, Q-026/028의 조건 판정 |
| F-026~F-033 신규 배치 | FR-006/007/008/009/023의 배치 계약 |
| F-034~F-036 context | FR-023/030, Q-039/040의 validator 순서 |
| 추가 경계·수동 검토·마감 바인딩 | FR-004/008/010/012/014/023/024, Q-022/023/027/033/074의 순수 판정 |

## Mac에서 앱 실행

macOS 27과 Xcode 27 환경에서 `./script/build_and_run.sh` 또는 Codex Run 동작을 사용한다. 스크립트는 기존 Mirror 프로세스를 종료하고 MirrorMac을 빌드한 뒤 app bundle을 연다. 선택적으로 --debug, --logs, --telemetry, --verify를 지원한다. 테스트는 Actions에서 실행한다. Linux에서 Run을 누르면 요구 환경을 안내하며 종료한다.

## 이전 날짜 기반 검증 기록

커밋 `74d02286d396c59e860394cdc660d72f5ea6dfa2`의 [Actions 실행 36743523286](https://github.com/hellosunghyun/mirror/actions/runs/36743523286)은 네 경로와 최종 결과 집계 모두 성공했다. 원격 run의 headSha와 실제 build/test step 및 결과 집계의 실행 수를 확인했다.

| 경로 | 실제 결과 |
|---|---|
| SwiftPM | Swift 도메인 테스트 37개 통과 |
| macOS | MirrorMac unsigned 빌드, 도메인 테스트 37개 통과 |
| iPhone Simulator | MirrorIOS unsigned 빌드, 도메인 테스트 37개 통과 |
| iPad Simulator | MirrorIOS unsigned 빌드, 도메인 테스트 37개 통과 |

37은 각 도구가 보고한 테스트 수다. 같은 테스트 소스를 네 경로에서 실행했으며 원본 fixture 36개는 매개변수 사례로 포함된다. 이를 서로 다른 테스트 148개나 전체 앱 QA 성공으로 합산하지 않는다. 실패·skip·0-test는 CI에서 거부한다. 같은 커밋의 [준비 검사 36743523087](https://github.com/hellosunghyun/mirror/actions/runs/36743523087)도 성공했다. 원본 명세·QA 보고서는 보존한다.

위 결과는 이전 날짜 기반 코드의 근거다. 새 전체 구현의 결과는 다음 기록과 구별한다.

## 전체 통합 검증 기록

`c94a3522fef4515644a721b1fed8000dba23b5e9`의 [Actions 36763990118](https://github.com/hellosunghyun/mirror/actions/runs/36763990118)에서 SwiftPM 필수 세 target이 실패·skip 없이 통과했다. 실제 worker 완료 보고는 Domain 94, Data 24, System 33, 합계 151개다. 이전 마지막 worker만 집계하던 파서를 수정해 세 완료 보고를 모두 요구한다. 실제 SQLite 원본 변경 구독과 projection 제외·취소/종료 회귀도 포함한다.

`c94a352`에서 native 세 플랫폼의 앱·확장 빌드와 unit 명령은 성공했다. 실제 tests JSON은 `Unit test bundle` 세 개와 Mac 151 / iPhone·iPad 150개의 `Test Case` 노드를 보고했다. 단위 결과의 파서가 이 형식과 앱의 `extract.actionsdata` 파일명을 인식하지 못해 필수 검사 실패였다. App Intents metadata 파일은 실제 앱 bundle에서 확인했다.

같은 실행에서 UI 검사도 수행했지만 Mac의 필수 요소 접근·오류 문구와 iPhone·iPad의 앱 종료/연결 끊김으로 실패했다. native 전체 통과로 기록하지 않는다. 실제 관측 형식에 맞춘 파서 수정, 정리 버튼 hit 영역·오류 AX 라벨과 비동기 UI 대기/진단을 다음 검증에 포함한다.

`b0c2fa419036b9d80f5c3b4140676bf02f9910fd`의 [Actions 36769033639](https://github.com/hellosunghyun/mirror/actions/runs/36769033639)에서 앱·두 확장 빌드, 필수 세 unit bundle, 개인정보/라이선스/URL 설정, 실제 App Intents metadata 검사가 모두 통과했다. App Intents의 `extract.actionsdata`는 실제 `$.actions` 16개를 포함했다. SwiftPM 151개, Mac 151개, iPhone·iPad 각각 150개의 단위·통합 검사가 실패·skip 없이 통과했다. iOS는 Mac 전용 별도 OS 프로세스 lock 검사 한 개를 포함하지 않는다.

같은 실행의 UI 결과는 세 플랫폼 모두 6개 중 0개 통과, 6개 실패다. Mac 실제 AX에서 버튼 선택과 StaticText의 빈 label/표시 value가 관측됐다. iPhone·iPad의 현재 실행 IPS는 Mirror의 `SIGABRT`/Objective-C 예외와 UIKit 경로, UI 러너의 crash-log 대기 중 종료를 보고했다. 이 기록만으로 UIKit 예외의 원인을 특정하지 않는다. 다음 수정은 실제 버튼 역할 우선 조회, label/value 표시 문구 검증, 소유 스크롤 영역 조회 및 UI test tree·예외 세부 구조 진단을 포함한다. 실패를 제거·skip하거나 앱 재실행으로 숨기지 않는다.

이전 커밋 `542a0093fff829d93f4678206289712a6e68819c`의 [Actions 36773091969](https://github.com/hellosunghyun/mirror/actions/runs/36773091969)은 SwiftPM·Mac·iPhone·iPad 모두 실행 단계가 0개였다. GitHub annotation은 계정 결제 실패 또는 사용 한도와 `Billing & plans` 확인을 요구했고, [준비 검사 36773091846](https://github.com/hellosunghyun/mirror/actions/runs/36773091846)도 러너 시작 전에 차단됐다. 이는 당시의 `not_run` 기록이며 앱/SDK/테스트를 실행한 실패가 아니다. 최신 실행은 아래와 같이 실제 러너에서 수행됐으므로 과거 실행 0개를 현재 현황으로 쓰지 않는다.

이전 검증 커밋 `aaa901850f7581216a57358058c3fa4f0fd5b5c4`의 [Actions 36785953557](https://github.com/hellosunghyun/mirror/actions/runs/36785953557)은 앱·두 확장 빌드와 필수 세 unit/integration bundle, 개인정보/라이선스/URL 및 실제 App Intents metadata 검사를 통과했다. 실제 앱의 `extract.actionsdata`에 `$.actions` 16개가 확인됐다. 단위·통합 검사는 실패·skip 없이 통과했지만 UI 실패로 native job과 전체 실행은 실패했다.

| 경로 | 실제 단위·통합 결과 | 실제 UI 결과 |
|---|---|---|
| SwiftPM | Domain 94 + Data 24 + System 33 = 151개 통과 | 해당 없음 |
| macOS | Domain 94 + Data 24 + System 33 = 151개 통과 | 6개 중 1개 통과, 5개 실패 |
| iPhone Simulator | Domain 94 + Data 23 + System 33 = 150개 통과 | 6개 중 0개 통과, 6개 실패 |
| iPad Simulator | Domain 94 + Data 23 + System 33 = 150개 통과 | 6개 중 0개 통과, 6개 실패 |

세 native 플랫폼의 실제 UI tree는 선언된 여섯 메서드를 각각 `Test Case`로 보고했다. Mac에서는 `testOverlongTitleShowsErrorAndPreservesEveryCharacter`만 `Passed`이며 나머지는 `Failed`다. iPhone·iPad에서는 여섯 메서드가 모두 `Failed`다. 이는 [추적표의 UI 부분 매핑](REQUIREMENTS_TRACEABILITY.md#1-현재-증거와-상태)에 해당하며 QA 87개 전체 통과나 실기기 수용을 뜻하지 않는다.

그 실행의 iPhone·iPad IPS는 Mirror의 thread 0 `EXC_CRASH`/`SIGABRT`와 `NSException`/UIKitCore 경로, 36개 또는 42개 프레임의 `lastExceptionBacktrace`를 보고했다. 예외 세부 notice가 4,096바이트에서 잘려 사유가 확보되지 않았으므로 그 기록만으로 UI 원인을 특정하지 않는다. 후속 CI helper는 짧은 notice·safe `crash-summary.json`·현재 Simulator 예외 사유 수집을 추가했다. 같은 커밋의 [준비 검사 36785947353](https://github.com/hellosunghyun/mirror/actions/runs/36785947353)은 통과했다.

이전 검증 커밋 `4ef52f969059ff15c693b635bfd1596d69b42e25`의 [Actions 36791089147](https://github.com/hellosunghyun/mirror/actions/runs/36791089147)은 SwiftPM과 Mac job이 성공했다. 세 native 플랫폼의 앱·두 확장 빌드와 필수 세 unit/integration bundle, 개인정보/라이선스/URL 및 실제 App Intents actions 16개 구성 검사가 통과했다. Mac은 선언된 여섯 UI 메서드가 모두 실제 실행돼 통과했고 필수 baseline/추가 선언 메서드 실행 guard도 통과했다. iPhone UI는 여섯 메서드가 모두 실패했다. iPad UI는 앱 종료·연결 끊김을 기록한 뒤 15분 단계 제한으로 중단돼 최종 xcresult 집계를 완료하지 못했다. 모바일 UI 실패로 전체 실행은 실패다.

| 경로 | 해당 커밋의 단위·통합 결과 | 해당 커밋의 UI 결과 |
|---|---|---|
| SwiftPM | Domain 94 + Data 24 + System 33 = 151개 통과, 실패·skip 0개 | 해당 없음 |
| macOS | Domain 94 + Data 24 + System 33 = 151개 통과, 실패·skip 0개 | 6개 통과, 실패·skip 0개 |
| iPhone Simulator | Domain 94 + Data 23 + System 33 = 150개 통과, 실패·skip 0개 | 0개 통과, 6개 실패, skip 0개 |
| iPad Simulator | unit/integration/구성 검사 단계 성공, 실제 tree에 Domain 94 + Data 23 + System 33 = 150개 | 6개 시작·5개 failed 종료·긴 제목 검사 crash 로그, 15분 중단으로 최종 집계 미완료 |

그 실행의 분할 IPS 진단에는 예외 사유가 없지만 같은 실행의 현재 Simulator 로그는 양쪽 모두 `NSInvalidArgumentException`과 `Replacement elements contain duplicates`를 보고했다. 사유는 같은 Command 수정키와 입력의 keyboard shortcut 중복이다. 실제 backtrace의 `UIMenuBuilder.perform(instruction:)` → `UIKitMainMenuController.buildMenu(with:)` → `AppDelegate.buildMenu(with:)`와 메뉴 재구축/`_keyCommands` 경로도 확인됐다. Mac 명령 등록의 iOS 실행 경로를 수정하는 근거다. 그때의 iPad 다섯 `Test Case failed`와 나머지 긴 제목 검사 crash 로그를 xcresult의 확정된 6개 실패나 skip 0개로 바꾸지 않는다.

같은 커밋의 [준비 검사 36791084443](https://github.com/hellosunghyun/mirror/actions/runs/36791084443)은 원본 무결성 검사와 Python 40개 검사(기존 9개 + profile 12개 + publisher 19개)가 통과했다. 이 Python 검사는 서명 입력/프로파일과 게시 로직의 검증이며 실제 GitHub API 게시나 서명된 IPA 성공을 뜻하지 않는다. 여섯 UI 시나리오의 원본 QA 부분 범위와 남은 조건은 [추적표](REQUIREMENTS_TRACEABILITY.md#1-현재-증거와-상태)에 보존한다.

이전 검증 커밋 `1ca1d35ab1ef7fdcb45ef9a010cecdd83396feae`의 [Actions 36793734833](https://github.com/hellosunghyun/mirror/actions/runs/36793734833)은 Mac 명령 등록을 macOS로 제한한 뒤의 실제 결과다. SwiftPM과 Mac job은 성공했고, iPhone·iPad는 앱·두 확장 빌드, 필수 세 unit/integration bundle 및 구성 검사 단계가 성공했지만 UI 단계가 각각 15분 제한으로 중단돼 전체 실행은 실패했다. 세 native 플랫폼 모두 실제 App Intents actions 16개를 확인했다.

| 경로 | 실제 단위·통합 결과 | 실제 UI 결과 |
|---|---|---|
| SwiftPM | Domain 94 + Data 24 + System 33 = 151개 완료 보고 통과 | 해당 없음 |
| macOS | 151개 통과, 실패·skip 0개 | 6개 통과, 실패·skip 0개; bundle 1개/case 6개, missingMethods·nonPassedMethods 없음 |
| iPhone Simulator | unit/integration/구성 단계 성공; Domain 94 + Data 23 + System 33 = 150개 완료 보고 통과 | stdout의 여섯 메서드 모두 failed; 15분 중단으로 최종 summary/tree/실행 guard 미확보 |
| iPad Simulator | unit/integration/구성 단계 성공; Domain 94 + Data 23 + System 33 = 150개 완료 보고 통과 | stdout에서 긴 제목·내일 검색·주 패널 취소/부분 종료 3개 passed, 나머지 3개 failed; 15분 중단으로 최종 summary/tree/실행 guard 미확보 |

Mac의 실제 UI tree는 여섯 선언 메서드를 모두 `Passed`로 보고했고 strict guard의 `actualCaseCount`는 6이며 누락·비통과 메서드는 없었다. 이 시나리오에는 Mac 키보드 명령 조작이 없으므로 Q-078 완료 근거로 확장하지 않는다. 모바일의 stdout 통과/실패 기록은 최종 xcresult 집계나 skip 0개, strict guard 통과를 대신하지 않는다.

그 실행의 모바일 진단은 현재 Mirror IPS 0개·읽기 실패 0개를 보고했고, 이전 중복 단축키 예외는 해당 로그에서 관측되지 않았다. 앱 전체 안정성이나 UI 해결을 뜻하지 않는다. 당시 남은 오류는 시작 시 `today.list` 부재, `capture.save` 실제 입력 뒤 `capture.title`에 원문이 남고 disabled 상태가 지속된 입력 초기화 실패, iPhone `capture.save`의 invalid activation point 및 `library.search` 부재, iPad 정리 카드 `review.card` 미닫힘이었다.

같은 커밋의 [준비 검사 36793734834](https://github.com/hellosunghyun/mirror/actions/runs/36793734834)은 원본 무결성과 Python 40개 검사를 통과했다. 이는 실제 IPA 서명·GitHub API 게시 결과가 아니다. [추적표](REQUIREMENTS_TRACEABILITY.md#1-현재-증거와-상태)는 최신 메서드별 부분 결과와 QA의 미검증 조건을 유지한다.

이전 완료 검증 커밋 `179428d98dcbfa61470395f7acbd5653b9f25c06`의 [Swift 실행 36796650352](https://github.com/hellosunghyun/mirror/actions/runs/36796650352)은 SwiftPM·Mac·iPad job이 성공했고 iPhone UI 실패로 전체 실행은 실패했다. 세 native 플랫폼의 앱·두 확장 빌드와 필수 unit/integration bundle·구성 검사는 성공했다. 이전 저장 후처리·탭 상태 패널·입력 버튼 배치 수정의 결과와 남은 iPhone 오류를 분리한다.

| 경로 | 실제 단위·통합 결과 | 실제 UI 결과 |
|---|---|---|
| SwiftPM | Domain 94 + Data 24 + System 33 = 151개 완료 보고 통과 | 해당 없음 |
| macOS | 151개 통과, 실패·skip 0개 | 6개 통과, 실패·skip 0개; strict guard bundle 1개/case 6개, missingMethods·nonPassedMethods 없음 |
| iPhone Simulator | unit/integration/구성 단계 성공; Domain 94 + Data 23 + System 33 = 150개 완료 보고 통과 | stdout의 capture·긴 제목·정리 Undo·주 패널/부분 종료 4개 passed, 완료 Undo·내일 검색 2개 failed; 15분 중단으로 최종 summary/tree/guard 미확보 |
| iPad Simulator | 150개 통과, 실패·skip 0개 | 6개 통과, 실패·skip 0개; strict guard bundle 1개/case 6개, missingMethods·nonPassedMethods 없음 |

Mac/iPad의 실제 UI tree는 여섯 선언 메서드가 모두 `Passed`이며 strict guard의 누락·비통과 메서드가 없었다. 같은 여섯 시나리오의 플랫폼 반복 실행을 서로 다른 수용 테스트로 합산하지 않는다. iPhone의 stdout 4개 통과·2개 실패를 최종 xcresult 집계·skip 0개나 guard 통과로 바꾸지 않는다. 현재 iPhone Mirror IPS는 0개이고 읽기 실패도 0개다.

iPhone의 완료 Undo 검사는 상세 화면이 열린 동안 root의 `task.undo`가 enabled=true/hittable=false였고 이를 소유하는 scroll 컨테이너도 찾지 못했다. 내일 검색 검사는 보관함 row의 실제 tap 뒤 `detail.plan`이 나타나지 않아 실패했다. 이 두 관측이 후속 상세 화면 Undo와 검색 row 전환 수정의 근거다. Mac 키보드·실제 Widget/Siri·접근성·두 기기 동기화와 QA 87개 전체 수용은 계속 미검증이다.

같은 SHA의 [Ad Hoc 실행 36796647867](https://github.com/hellosunghyun/mirror/actions/runs/36796647867)은 세 Secret의 존재, 원본/배포 도구 회귀, SwiftPM 151개와 Mac 151개·UI 6개 검사를 통과했다. 별도로 실행한 iPhone/iPad UI는 각각 15분 제한으로 중단돼 최종 집계가 없고 archive·publish는 skipped였다. standalone의 iPad 성공을 이 배포 run의 게이트 성공으로 대체하지 않는다. 실제 인증서·개인키 일치·archive/export·IPA 서명은 미검증이며 해당 시점 Release 목록은 0개로 공개 자산 네 개도 게시되지 않았다.

같은 커밋의 [준비 검사 36796647485](https://github.com/hellosunghyun/mirror/actions/runs/36796647485)는 원본 무결성과 Python 40개 검사를 통과했다. 이 증거는 실제 API 게시나 IPA 성공을 뜻하지 않는다.

이전 커밋 `873049b2709de2a97dffbdb49a55706870f33373`의 [Ad Hoc 실행 36800189042](https://github.com/hellosunghyun/mirror/actions/runs/36800189042)은 최종 실패다. Mac job `110172582614`는 단위 151개 통과·UI 6개 중 5개 통과/1개 실패·skip 0개였다. iPhone/iPad UI는 각각 20분 제한으로 중단됐고 최종 summary/tree/guard가 없어 실제 완료 case 수를 확정하지 못했다. iPad 첫 시나리오는 `review.finish.isHittable` 조회의 invalid activation point를 보고했다. archive·publish는 skipped로 실제 인증서·개인키 일치와 IPA archive/export는 미검증이다.

같은 SHA의 [standalone 실행 36800192812](https://github.com/hellosunghyun/mirror/actions/runs/36800192812)은 새 push의 concurrency로 cancelled됐다. Mac job `110172593081`의 실제 단위 151개 통과·UI 5개 통과/1개 실패·skip 0개는 보존한다. iPad는 unit 중 operation cancelled로 UI 미실행이며 iPhone은 확보한 로그가 없어 결과를 판정하지 않는다. Ad Hoc의 모바일 시간 초과와 standalone 취소를 같은 테스트 결과로 기록하지 않는다.

Mac의 실패는 완료 Undo 시나리오에서 Undo 전 `detail.title`의 enabled=true/hittable=false, frame=(489,29,574,20), window=(-38,31,1100,674)였고 소유 scroll 컨테이너도 없었던 경우다. 이전 `179428d`의 Mac 통과를 최신 상세 화면 수정의 성공으로 대체하지 않는다. 후속 수정은 macOS 상세 Form의 grouped 배치와 사용 가능한 높이/상단 영역을 조정하고, 부모 `status.footer` ID가 `state.feedback`/`task.undo`를 덮는 접근성 식별자 문제를 제거한다. UI scroll fallback도 대상의 상단이 소유 surface 상단보다 위에 있으면 위쪽으로, 나머지는 아래쪽으로 실제 스크롤한다. 좌표 강제 tap이나 assertion/skip 변경으로 실패를 숨기지 않는다. 이 변경의 해결 여부는 다음 SHA의 Actions에서 확인해야 한다.

같은 커밋의 [준비 검사 36800188766](https://github.com/hellosunghyun/mirror/actions/runs/36800188766)은 Python 40개 검사를 통과했다. 준비 검사와 Mac의 부분 결과를 모바일 최종 수용이나 실제 IPA 배포 성공으로 기록하지 않는다.

이전 커밋 `a7ef8a2df18a92e1146fde9b1b6c0ad451cc9a41`의 [Ad Hoc 실행 36801483055](https://github.com/hellosunghyun/mirror/actions/runs/36801483055)은 최종 실패다. Mac job `110176589692`는 단위 151개 통과, UI 5개 통과·1개 실패·skip 0개였다. `detail.title` 접근 후 완료 Undo의 라벨 대기가 실패했지만 기대값·직전 입력 진단이 없어 원인을 특정하지 못했다. 모바일 UI는 두 플랫폼 모두 20분 제한으로 중단됐고 최종 summary/tree가 없어 case 수를 확정하지 못했다. iPad는 CI 로그 01:58:32.600에 suite failed를 보고했고 weekPanel case는 129.757초 뒤 `review.finish.isHittable`의 invalid activation point로 실패했다. archive·publish는 skipped로 실제 서명은 미실행이다. 같은 SHA의 standalone은 concurrency로 cancelled됐으며 Mac 단위 151개/UI 5개 통과·1개 실패와 SwiftPM 151개만 확보했다. 모바일 결과를 판정하지 않는다.

이전 커밋 `68c4c9d08d63667c4b26d4c2f52052a53fe91fdf`의 [Ad Hoc 실행 36803345968](https://github.com/hellosunghyun/mirror/actions/runs/36803345968)은 당시 중간 기록이다. Mac job `110182335962`는 단위 151개 통과·UI 5개 통과/1개 실패·skip 0개다. stdoutOnly 진단과 실제 xcresult의 5/6 결과가 일치하며 xcodeCompletion=true다. regular 화면 높이 수정 후에도 완료 Undo의 최초 `waitForLabel` 실패가 남았다. 기대 라벨은 `완료 취소` 또는 `다시 열기`, 실제 `task.complete`는 `완료`, enabled/hittable=true, frame=(463,645,47,24)다. 편집 제목과 내용 저장 피드백은 정상이며 state.error는 없고 lastAction은 task.complete였다. 클릭 미전달과 projection/receipt guard 판정은 당시 구별하지 못했다. content/edit와 status/complete는 별도 그룹이며 stale 확정 증거도 없었다. 당시 모바일 UI는 진행 중이고 실제 서명·archive/export는 미실행이었다.

후속 수정은 상세 Form 하단 상태 section의 완료 primary를 기존 Undo footer로 옮겨 44pt 라벨의 borderedProminent 고정 영역에 배치한다. 삭제된 작업에는 완료 버튼을 제공하지 않으며 기존 명령·task.complete ID·isSaving guard·receipt 조건과 휴지통 복원/이력을 보존한다. 기존 여섯 UI 사례와 모든 assertions와 통과 판정도 유지한다. 실제 해결 여부는 다음 SHA의 Actions에서 확인하며 stdout 진단을 수용 통과로 대신하지 않는다.

이전 커밋 `027a8cbce6842973ba7ad986ec411251483ce7c5`의 [Ad Hoc 실행 36805275410](https://github.com/hellosunghyun/mirror/actions/runs/36805275410)은 최종 failure다. Mac 단위 151개/UI 6개와 iPad 단위 150개/UI 6개는 실제 summary와 strict guard에서 통과했다. 두 UI guard는 bundle 1개/case 6개, missingMethods·nonPassedMethods 없음이며 실패·skip 0개다. 이전 Mac 완료 Undo 실패와 최신 Mac/iPad의 여섯 사례 통과를 구분한다.

iPhone job `110188133795`는 단위 150개를 통과했지만 UI가 20분 제한으로 중단됐다. stdoutOnly에는 여섯 case의 시작/완료, capture·긴 제목·정리 Undo·주 패널 4개 passed와 완료 Undo·내일 검색 2개 failed가 있다. suite는 6 tests/2 failures/0 unexpected, 920.990초를 보고했으며 xcodeCompletionReported=false다. 최종 UI summary/tree/strict guard는 없으므로 stdout 4/6을 최종 xcresult 통과·skip 0으로 바꾸지 않는다. assertion·selector·AX 오류 본문이 확보되지 않아 원인도 미확정이다. archive와 publish는 skipped여서 실제 인증서·개인키 일치와 IPA 서명/export·Release 게시 성공은 미검증이다.

같은 커밋의 [별도 Swift 실행 36805279997](https://github.com/hellosunghyun/mirror/actions/runs/36805279997)도 최종 failure다. SwiftPM 151개, Mac 단위 151개/UI 6개와 iPad 단위 150개/UI 6개는 통과했고 Mac/iPad strict guard의 실패·skip은 0개다. iPhone 단위 150개는 통과했지만 UI는 stdout 4개 통과·2개 실패, suite 6 tests/2 failures/0 unexpected·946.160초, xcodeCompletionReported=false를 남긴 뒤 20분 제한으로 중단됐다. 이 946.160초는 Ad Hoc 실행의 920.990초와 별도 증거이며 iPhone 최종 UI summary/tree/strict guard는 확보하지 못했다.

별도 실행의 완료 Undo 사례는 편집 제목 입력까지 정상이고 `detail.save`가 존재하지만 hittable=false였다. CollectionView frame=(0,62,402,350)에서 swipeUp 한 번 뒤 `detail.save` 버튼의 NoMatches snapshot 오류로 실패했다. 실제 저장 탭·완료·Undo 이전 실패이므로 완료 명령이나 Undo의 실패 원인으로 단정하지 않는다. 내일 검색 사례는 row를 실제 탭한 뒤 keyboard frame=(0,590,402,226)이 남고 `detail.plan`이 없었다. 자동 저장이나 overlay를 원인으로 확정하지 않으며 두 실패의 실제 동작 원인은 후속 검증이 필요하다.

최신 커밋 `38d78498ff56781b9762893c0d96b77cf253176d`의 [Ad Hoc 실행 36808965234](https://github.com/hellosunghyun/mirror/actions/runs/36808965234)은 최종 failure다. 세 서명 Secret의 존재·준비 Python 40개·SwiftPM 151개는 통과했다. Mac 단위 151개/UI 6개도 통과했고 UI strict guard는 bundle 1개/case 6개, 실패·skip 0개다. iPhone/iPad 단위는 각각 150개 통과했다.

iPhone UI stdout은 완료·Undo를 포함한 5개 통과와 내일 검색 1개 실패, suite 971.203초다. iPad UI stdout은 4개 통과와 내일 검색·주 패널 부분 종료 2개 실패, suite 1017.165초다. 두 모바일 모두 xcodeCompletionReported=false이며 UI가 20분 제한으로 중단됐다. 최종 UI summary/tree/strict gate를 확보하지 못했으므로 stdout 결과를 최종 xcresult 통과·skip 0이나 전체 UI 수용으로 기록하지 않는다. archive·publish는 skipped이고 실제 P12 암호 검증·인증서/개인키/프로파일 일치·서명된 IPA와 Release 게시는 미검증이다. 이 실행 후 확인한 Release API 목록은 0개다.

같은 커밋의 [별도 Swift 실행 36808970265](https://github.com/hellosunghyun/mirror/actions/runs/36808970265)은 최종 failure다. Mac 단위 151개/UI 6개와 SwiftPM 151개는 통과했다. iPad job `110199559968`도 단위 150개/UI 6개 통과, UI summary 실패·skip 0개와 strict guard bundle 1개/case 6개/missingMethods·nonPassedMethods 없음을 확인했다. iPhone은 stdout 5개 통과·내일 검색 1개 실패, suite 765.085초와 20분 UI 제한 중단으로 실패했다. 별도 실행의 iPad 최종 통과와 Ad Hoc iPad의 stdout 4개 통과·2개 실패/집계 중단을 구분하며 별도 결과로 배포 게이트 실패를 대신하지 않는다.

`38d7849`에는 상세 편집 저장·취소를 Form 밖 고정 footer의 우선 영역에 44pt 높이로 배치하고 compact content/statusBar에 형제 높이를 할당한 변경이 포함됐다. 기존 snapshot·접근성 ID·isSaving guard와 여섯 UI 사례의 모든 assertions·통과 판정은 유지했다. iPhone의 완료·Undo 실제 case Passed는 확인했지만 이를 전체 UI나 QA 87개 완료로 확대하지 않는다. 실제 SDK help의 -enableCodeCoverage 지원과 두 모바일 UI의 coverage NO notice도 확인했으나 결과 마감 문제 해결은 입증되지 않았다. 시간 초과나 stdout 결과를 테스트 성공으로 바꾸지 않는다.

확보한 별도 실행 전체 로그의 최초 내일 검색 실패에서 직전 검색행 frame=(16,383,370,102)의 중심 Y는 434이고, 진단 시 유일한 보관함 CollectionView frame=(0,0,402,403)의 하단보다 31pt 아래였다. 실제 행 Tap/Synthesize 뒤 키보드가 남고 `detail.plan`이 없었으며 `state.feedback`은 `완료했어요.`였다. 캐시된 행 좌표와 실패 진단 시 표시 영역의 관측은 접근 geometry 보완의 근거이며 전체 원인 확정을 뜻하지 않는다.

후속 보완은 `task.row.*`에만 적용한다. 실제 descendant ID로 소유 scroll/table/collection을 찾고 최대 8회 실제 스크롤한 뒤 행 중심이 표시 영역 안에 있고 hittable/enabled를 모두 만족해야 일반 tap을 실행한다. 고정 좌표 tap이나 행동 재시도는 추가하지 않으며 기대값·기존 여섯 사례·15초 대기·최종 xcresult/strict guard 판정은 유지한다. 제품 소스와 상태·명령은 변경하지 않는다. 이 보완의 효과는 새 SHA의 실제 Actions 검증 대기다.

native workflow는 `ci-apple-platform.sh <platform> unit`과 `ui` 두 단계로 나눴다. 실제 unit 명령과 xcresult 추출을 마친 뒤에만 UI를 실행한다. UI는 동일 run/attempt/commit·scheme·SDK·destination의 context를 확인하고 같은 DerivedData/Simulator를 사용한다. unit 단계의 필수 bundle/packaging 실패는 UI를 독립 진단하더라도 job 실패로 유지한다. 기본 `all` 호출도 지원한다. 기록한 `179428d` 실행은 단위 단계 20분·UI 15분 제한이었다. 후속 UI 20분 제한과 종료 정리 변경은 다음 Actions에서 확인하며 시간 제한과 실패 진단은 성공 판정을 대신하지 않는다.

실제 VoiceOver·홈 위젯/Siri·서명/App Group·두 기기 CloudKit·전체 삭제·사용자 검증 게이트는 별도 증거가 필요하다. 개발용 AppIcon과 unsigned CI packaging 결과도 Apple 등록·배포 준비 완료를 뜻하지 않는다.

`179428d`는 원본 저장과 실제 projection 확인 후 화면 성공을 반환하고, 알림·Spotlight 후처리를 저장소 identity에 묶인 직렬·병합 Task로 예약한다. iPhone 상태 패널은 탭 내용 안에, 입력 저장 버튼은 스크롤 본문 아래 고정 영역에 배치했다. 여섯 시나리오의 원본·계획·Undo assertions를 유지하며 각 SHA의 부분 결과를 위 기록으로 구별한다. 최신 iPhone 완료·Undo 사례는 통과했지만 모바일 전체 수용은 미완료다. 후속 행 표시 영역 확인 보완의 효과는 새 SHA의 실제 Actions 검증으로 확인한다.
