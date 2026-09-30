# Swift 개발 안내

## D-01 타깃 구성

| 타깃 | 역할 | 지원 |
|---|---|---|
| MirrorIOS | SwiftUI 앱, 공유 scheme MirrorIOS | iPhone·iPad, iOS/iPadOS 27.0 |
| MirrorMac | 네이티브 SwiftUI 앱, 공유 scheme MirrorMac | macOS 27.0 |
| MirrorDomain | 같은 생산 소스로 빌드하는 정적 framework / SwiftPM library | 두 앱 및 테스트 |
| MirrorDomainTests | Swift Testing 단위 테스트, 원본 fixture 포함 | SwiftPM·Mac·iPhone/iPad Simulator |

외부 프로젝트 생성기나 새 패키지 의존성 없이 `Mirror.xcodeproj`를 구성했다. Swift compiler는 Xcode 27의 6.4, 언어 모드는 Swift 6이다. Xcode의 `SWIFT_VERSION=6.0`은 언어 모드이며 compiler의 6.4와 다른 설정이다. strict concurrency는 complete, 도메인·테스트 기본 격리는 nonisolated, SwiftUI 앱의 격리는 명시적인 MainActor다.

개발 빌드에서는 README의 후보 `com.baserize.mirror`와 `com.baserize.mirror.mac`을 사용한다. 위젯·Share Extension·서명 Team·App Group·iCloud container는 아직 구성하지 않았다. CI의 unsigned Simulator/Mac 빌드는 Apple Developer 등록·배포·서명 완료를 뜻하지 않는다.

앱은 이름을 표시하는 시작 골격이다. SwiftPieces는 확정된 UI 구성요소지만 아직 실제 컴포넌트를 도입하지 않았다. 원본 UX·라이선스·플랫폼 검증 기준에 따라 후속 UI 작업에서 도입한다.

## D-02 날짜와 판정

`LocalDate`는 엄격한 ASCII YYYY-MM-DD Gregorian 날짜를 보존한다. 잘못된 날짜를 정규화하지 않고 1~9999년 범위를 검사한다. Gregorian 400년 주기를 사용해 역사적 달력 전환에도 일관된 날짜 의미를 유지하며 내일과 주간 범위는 Calendar 날짜 덧셈으로 계산한다.

`PlanningContext`는 호출자가 제공한 시각, 계획 시간대, 정책 버전을 보존한다. 시스템 시계나 기기 현재 시간대로 암묵적으로 바꾸지 않는다. 저장한 날짜는 계획 시간대가 바뀌어도 이동하지 않는다.

`PlanTarget`은 unassigned/day/week/parked의 절대 목적지를 계약 JSON으로 읽고 쓴다. raw 목적지는 형식을 복원하고 주의 의미는 별도 검증한다. 작업 판정용 `TaskPlanningState` 복원은 주 시작·7일 범위의 구조를 검사하되 유효한 과거 계획은 보존한다. 새 배치는 과거 day나 끝난 week를 거부한다.

`PlanningRules`는 명시적 Today 목록, 자동/이어 정리/오늘 다시 정리 후보, 검토 유예, 마감 이후 확인과 taskID/deadlineRevision/target 바인딩, receipt를 먼저 확인하는 stale context 순서를 제공한다. 이들은 순수한 판정 함수다. durable receipt 조회·명령 append·저장·projection·CloudKit은 구현하지 않았다.

## 테스트 실행

테스트는 GitHub Actions의 `xcode-27` arm64 public preview 러너에서 실행한다. `DEVELOPER_DIR`는 `/Applications/Xcode_27.app/Contents/Developer`로 고정한다. 테스트 수행 자체는 클라우드 Linux에서 실행하지 않는다.

| CI 경로 | 실제 명령 | 결과 |
|---|---|---|
| SwiftPM | bash scripts/ci-swift-package.sh | Swift Testing 완료 결과와 실행 수 |
| Mac | bash scripts/ci-apple-platform.sh macos | MirrorMac build/test와 xcresult |
| iPhone | bash scripts/ci-apple-platform.sh iphone | iOS 27 iPhone Simulator의 MirrorIOS build/test |
| iPad | bash scripts/ci-apple-platform.sh ipad | iOS 27 iPad Simulator의 MirrorIOS build/test |

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

## 검증 기록

새 코드의 플랫폼 build/test 검증을 Actions에서 진행 중이다. 성공/실패와 실제 실행 수는 해당 commit의 run 결과가 확인된 뒤 여기에 기록한다. 원본 명세·QA 보고서는 보존한다.

실제 화면 동작·VoiceOver·SwiftPieces·위젯·Siri·실기기 서명·App Group·두 기기 동기화·저장 복구는 후속 검증 범위다.
