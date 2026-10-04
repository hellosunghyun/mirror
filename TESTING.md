# 테스트 전략

## 간편 일괄 미루기

[전용 batch UI 검증](docs/BATCH_UI_REVIEW.md)은 iPhone·iPad·Mac에서 두 개와 스무 개 작업을 실제 입력·개별 선택하고 날짜를 바꾼다. 원래 UUID·전체 제목·미완료 상태, 선택하지 않은 작업의 날짜, 기본 접힌 제목과 달력을 확인한다. 앱 소스가 바뀐 push의 [batch workflow](.github/workflows/batch-ui.yml)에서 실행하며, 각 플랫폼의 현재 SHA·실행·attempt와 실제 typed 두 사례의 통과·실패0·skip0을 확인해야 한다.

새 UI 두 사례와 결과 게이트 회귀15개는 작성된 검사이며 실제 통과 수와 구분한다. 기존 여섯 native UI 사례·143개 assertion·32개 XCTFail·원본46장과 기존 시간 제한·서명 및 게시 게이트는 유지한다. 일반 일괄 배치 성공은 Q-080의 stale 전체 거부·실기기·두 기기 수용을 대신하지 않는다. 로컬 클라우드에서 테스트나 앱 빌드를 실행하지 않는다.

사용자 지시: **테스트코드를 적극적으로 활용한다.**

## 현재 실행 가능한 검사

사용자 지정 실행 위치는 **GitHub Actions 러너**다. [Swift workflow](.github/workflows/swift.yml)는 SwiftPM 및 Xcode의 macOS·iPhone·iPad 환경에서 같은 생산 도메인·Core Data 저장·시스템 서비스 소스를 검사하고 iPhone·iPad·Mac에서 실제 XCUITest를 실행한다. 결과 파서는 실제 실행 수가 양수인지, 실패·skip이 없는지 확인하며 현재 실행의 로그·xcresult를 보존한다. 자세한 실행과 결과는 [Swift 개발 안내](docs/SWIFT_DEVELOPMENT.md)를 따른다.

별도 [Adaptive workflow](.github/workflows/adaptive-ui.yml)의 iPhone·iPad 검사는 실제 Simulator의 시스템 글자 크기를 최대로 설정한다. 같은 빌드 context의 Simulator와 원래 category를 확인·기록한 뒤 설정값을 다시 읽고, 앱의 UIKit 값과 루트·표시한 각 화면의 실제 SwiftUI 최대 크기를 검증한다. 설정이 없거나 값이 다르면 고정 크기로 대체하지 않고 실패한다. 시스템 크기를 바꾸는 접근성 감사가 단일 SwiftUI override에 막히지 않도록 하는 검사 환경 변경이며, 기존 감사 실패의 원인을 확정하거나 통과로 바꾸는 조치가 아니다.

설정 시작을 기록한 iOS 실행은 성공·실패·검사 단계 중단 뒤 별도 `always()` 단계에서 원래 시스템 크기를 복원하고 readback을 확인한다. journal이나 context가 없거나 맞지 않으면 복구 성공으로 기록하지 않는다. iOS 4개·Mac 5개 실제 사례, 전체 `.all` 감사, 모든 issue를 실패로 남기는 처리, 원래 크기·동작 assertion과 시간 제한·typed 결과·PNG 게이트를 유지한다. Mac 경로와 기존 pinned/system 단일 사례 진단은 별도로 유지하며, 새 환경의 실제 수용 결과는 해당 SHA의 Actions 완료로 확인한다.

Swift 테스트는 원본 fixture 36개를 그대로 읽어 날짜 목적지, Today/Review 판정, 마감 확인, 신규 배치, receipt 우선 stale context 판정을 검사한다. 추가 사례는 윤년·연말·Gregorian 역사적 경계·DST·자정·잘못된 입력·주 구조·수동 검토와 마감 확인 바인딩을 검증한다. 원본 파일을 수정하거나 기대값을 생산 구현에서 계산하지 않는다.

준비 검사와 회귀 테스트는 원본 문서의 무결성, 문서 연결, JSON 계약, fixture 기대값, FR / QA 매핑을 검증한다. 기존 검증기는 임시 복사본에서 실행한다. 준비 검사가 통과해도 실제 앱의 QA 상태 87개는 미실행으로 유지한다.

현재 전체 구현에는 명령/reducer·실제 SQLite·Widget/알림/링크 계약과 UI 시나리오가 추가됐다. `2da19a9`의 Actions 36817569714에서 SwiftPM 151개, Mac 단위 151개·iPhone/iPad 단위 각각 150개와 세 플랫폼 UI 각각 6개를 최종 집계에서 통과했다. 서명은 별도 인증서 일치 검사에서 실패했다. 후속 검색·복원·프로세스·화면 보완은 새 SHA의 Actions에서 다시 검증한다. 이전 37개 날짜 테스트의 통과를 새 저장·UI·동기화의 성공으로 확장하지 않는다. 최종 집계는 필수 세 unit/integration bundle 및 UI의 양수 실행 수와 실패·skip 없음까지 요구한다. 원본 보고서의 상태를 덮어쓰지 않고 파생 검증 기록에 실행 범위를 남긴다.

## 별도 프로세스 회귀

`MirrorStoreProbe`는 테스트용 SwiftPM 실행 파일이며 앱에 포함하지 않는다. CI는 `.build/process-probe`에서 현재 소스를 빌드하고 공식 `--show-bin-path` 결과를 기록한다. Mac 저장 통합 테스트는 실제 생산 `MirrorStore`를 열어 두 프로세스의 동일 명령 경쟁과 원본 저장 후 SIGKILL·재시작을 검사한다. helper가 없으면 실패하며 skip하지 않는다. Python lock 경계 회귀도 유지한다. 이 결과로 실제 CloudKit 두 기기·OS 보호 데이터·실기기 위젯 검증을 대체하지 않는다.

## 대용량 성능과 자체 백업 왕복

Actions의 별도 Release 검사에서 합성 열린 작업 10,000개·유효 원본 기록 100,000개를 실제 저장소에 가져오고 조회·단건 명령·내보내기의 표본과 p50/p95를 기록한다. 내보낸 파일의 UTF-8 크기와 빈 저장소로의 전체 복원·동일 파일 재복원도 확인한다. 준비 시간은 명령 표본에서 제외하고 commit·러너·OS/SDK/Swift·빌드 종류를 함께 보존한다. 목표 초과는 실제 숫자와 함께 기록하며 실기기 저장 500ms·위젯 표시 2초나 전체 Q-086 통과로 바꾸지 않는다. EventKit 권한과 실제 캘린더가 없는 합성 일정은 실제 2,000개 조회 검증으로 간주하지 않는다.

복원 UI의 임의 32MiB 상한은 제거했다. 허용된 20,000자 ASCII 메모 1,700개만으로도 그 상한을 넘으며 자체 내보내기에는 같은 제한이 없었기 때문이다. 파일은 기존 mapped read·형식 검증·미리보기·명시적 복원 동의를 계속 거친다. 대용량 데이터의 실제 메모리·시간과 복원 성공은 새 Actions baseline에서 확인한다.

## 앱 구현에 연결할 테스트

| 순서 | 대상 | 기존 근거 | 필요한 증거 |
|---|---|---|---|
| D-02 / D-03 | 날짜·주간 범위·Today / review 분류 | fixture F-001~F-036, 문서 03·04 | 실제 Swift 구현을 고정 시간·시간대로 실행; 월말·윤년·자정·DST와 미래 항목 제외 |
| D-03 / D-05 | 명령 멱등성·오래된 카드 | Q-035~Q-040, Q-053~Q-054 | 재시도 한 번 적용, 같은 ID·다른 payload 거부, receipt / staleContext 순서 |
| D-04 / D-10 | 저장 중 종료·복구·충돌 | Q-051~Q-060, Q-087 | 원본 / projection / receipt 경계 장애 주입, 입력 유실·중복 방지, operation 순서별 수렴 |
| D-09 | 조건부 Undo·완료·삭제 상태 | Q-029~Q-031, 문서 03·04 | 후속 변경 이후 Undo 거부와 삭제 / 완료 불변식 |
| D-10 / D-13 | 계정 분리·전체 삭제·export / import | Q-061, Q-081, Q-084~Q-085, G-SYNC / G-DELETE | 계약 왕복 테스트와 실제 두 기기 계정 전환·오프라인 재연결 |
| D-06~D-08 / D-11~D-14 | UI·App Intents·위젯·플랫폼 | 문서 06·08, G-WIDGET | 실제 SDK 빌드·metadata 추출, 앱 미실행 인텐트, 위젯 카드 30개, 접근성·실기기 성능 |

범위 전체와 세부 수용 기준은 [원본 QA 명세](postpone-app-docs/08_QA_AND_ACCEPTANCE.md)를 따른다. 위 표는 먼저 자동화할 위험 영역이며 다른 QA를 제외하지 않는다.

## SwiftPieces UI 검증

UI는 사용자 지정 SwiftPieces를 사용한다. TaskRow/ExpandableText/StatusMorph를 실제 화면에 도입했고 한국어·MainActor·Mac 색상 대응을 적용했다. 아래 실제 접근성 검증은 아직 미실행이다. 실제 소스 도입 후 컴포넌트별 검증 결과를 FR / QA와 연결한다.

| 검증 대상 | 필요한 시나리오 |
|---|---|
| 플랫폼 빌드 | iOS / iPadOS / macOS 27 타깃 각각 빌드; UIKit 타입·색상·햅틱 의존성과 필요한 Metal 파일 확인 |
| 입력·한국어 | FormField의 한국어 조합 입력·붙여넣기·제출·빈 입력·검증 오류·큰 글자·키보드 포커스 |
| 명령과 저장 | TaskRow 등의 이벤트가 화면의 작업 ID를 유지; 저장 실패 시 성공 표시 없음; 연속 입력·중복 명령·Undo 후 상태 일치 |
| 접근성 | VoiceOver 라벨·값·선택 상태와 제스처를 대신할 액션; Dynamic Type·긴 한국어·대비·Reduce Transparency |
| 모션과 자원 | Reduce Motion의 실행 중 변경; 애니메이션·햅틱·센서 중단과 백그라운드 전환; 카드 반복 조작 성능 |
| 상태 피드백 | StatusMorph 등의 로딩·성공·오류 캡션 한국어화; 로컬 저장과 동기화 상태 구분; 실패 후 재시도 |
| 출처와 고지 | 도입 파일의 원본 경로·커밋·변경 내역·저작권·허가문과 앱 배포 고지 확인 |

상위 SwiftPieces의 iOS 26 Simulator typecheck는 미러의 OS 27·Mac 빌드나 런타임 접근성을 검증하지 않는다. 준비용 Python 검사 결과와 이 UI 검증 결과를 별도로 기록한다.

## 구현 시 원칙

1. 사용자 행동이나 계약에 따른 기대 결과를 먼저 작성한다.
2. 공통 fixture를 Swift 테스트 입력으로 활용하되 Python 참조 함수를 생산 구현으로 복사하지 않는다.
3. 시계와 시간대를 고정해 테스트가 날짜나 실행 기기에 따라 달라지지 않게 한다.
4. 저장·동시성은 실제 선택된 저장소를 대상으로 통합 검증한다. mock 성공만으로 복구·동기화 완료를 판정하지 않는다.
5. 수용 시나리오별 실행 대상, OS / SDK, 명령, 통과·실패·미실행 상태를 기록한다.

Swift Testing, XCTest / XCUITest는 Apple 제공 테스트 도구를 사용한다. 현재 Xcode 프로젝트·공유 scheme과 실행 명령은 [Swift 개발 안내](docs/SWIFT_DEVELOPMENT.md)에 기록했다. 후속 저장·명령·UI 검증은 실제 타깃 구성에 맞춰 확장한다.
