# Swift 개발 안내

## 앱과 모듈 구성

현재 통합 코드에는 15개 native 타깃과 4개 SwiftPM 라이브러리가 있다. 첫 전체 구현 커밋은 `67d69e952311b93c50ce874dab0aaa2347c95264`다. 원격 컴파일 검증 중이며 작성 완료를 수용 통과로 기록하지 않는다.

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

개발 Bundle ID는 `com.baserize.mirror`와 `com.baserize.mirror.mac` 및 각 호스트의 Widget/Share suffix다. 실제 Team·App Group·iCloud container 값은 미제공이므로 Info.plist의 연결 값은 비어 있고 capability 상태는 configurationRequired다. unsigned CI embedding은 등록·서명·공유 컨테이너 접근 성공을 뜻하지 않는다. 확장은 App Group 없이 별도 로컬 폴더로 fallback하지 않는다.

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

CI는 원본 fixture 36개와 날짜/시간대/윤년/DST/자정/주 구조/검토/마감 경계 테스트를 실행한다. `scripts/ci_results.py`는 실제 테스트 수가 양수이고 XCTest 결과에 실패·skip이 없는지 확인한다. 원래 build/test 명령의 종료 코드를 보존하고 결과 실패를 약화하지 않는다. 현재 실행의 log와 xcresult는 7일 동안 artifact로 보존한다. 최종 결과 job 이름에도 실행 수를 기록해 API로 확인할 수 있다.

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

위 결과는 이전 날짜 기반 코드의 근거다. 새 전체 구현은 현재 원격 검증 중이다. 실제 VoiceOver·홈 위젯/Siri·서명/App Group·두 기기 CloudKit·전체 삭제·사용자 검증 게이트는 별도 증거가 필요하다.
