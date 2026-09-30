# 06. App Intents와 위젯 명세

버전 0.1 / 관련: [UX](02_UX_AND_SCREEN_SPEC.md), [명령 계약](04_DATA_AND_COMMAND_CONTRACTS.md), [호환성](10_SOURCES_AND_COMPATIBILITY.md)

## 1. 도입 원칙

App Intents는 단순한 앱 열기 버튼이 아니라 핵심 명령의 시스템 어댑터다. 제목 입력, 날짜 배치, 오늘 조회, 완료가 본 앱과 같은 CommandService를 사용한다. 화면 버튼이 무조건 AppIntent.perform을 직접 호출해야 한다는 의미는 아니다.

App Intent를 선언했다고 위젯, 컨트롤, Watch UI가 자동 생성되는 것은 아니다. 각 surface는 별도 타깃 / 구성 / 권한 / 가용성 검증을 필요로 한다. 기술적 기반은 Apple 공식 A01, A03, A04다.

## 2. App Entity와 Query

| 자체 타입명 | 내용 | 공개 범위 |
|---|---|---|
| TaskEntity | 안정 taskID, 제목, 계획 요약, 완료 상태, 선택 마감 | 현재 계정의 허용된 작업 |
| ReviewCycleEntity | 현재 계획 날짜와 검토 주기 | 필요할 때만 공개. 내부 card token은 제외 |
| PlanningDateEntity 또는 parameter | 선택 날짜를 명확히 표시 | 구현 SDK의 지원 형식에 맞춤 |

기본 suggestedEntities는 오늘 항목과 최근 사용 항목의 제한된 집합이다. 전체 보관함, 민감한 메모, 계정 식별자, 변경 이력 전체를 시스템에 불필요하게 내보내지 않는다. 검색 query는 제목과 ID를 구별하고 같은 제목이 여러 개면 계획 날짜 / 짧은 메모로 선택을 돕는다.

엔티티 ID는 로컬 NSManagedObjectID URI가 아니라 동기화되는 taskID다. objectID가 다른 기기에도 동일하다고 가정하지 않는다. Query 실패는 “작업이 없음”과 “잠겨 있어서 조회 불가”를 구별한다.

## 3. 인텐트 카탈로그

아래 명칭은 개발할 자체 타입의 작업명이며 Apple 내장 클래스가 아니다.

| ID | 자체 인텐트 | 입력 | 모드 / 결과 |
|---|---|---|---|
| AI-01 | AddTaskIntent | title, note?, URL? | 배경 저장, TaskEntity 반환 |
| AI-02 | GetTodayTasksIntent | 선택 계획 날짜? | 조회, 제한된 TaskEntity 배열 |
| AI-03 | FindTasksIntent | 제목 또는 상태 조건 | 조회, 동명이인 선택 가능 |
| AI-04 | ScheduleTaskIntent | TaskEntity, 절대 날짜 | 배경 변경. 모호하면 확인 / 앱 연결 |
| AI-05 | ScheduleTaskForWeekIntent | TaskEntity, 주 시작 날짜 | 주 단위 저장, 월요일 일감 아님 |
| AI-06 | SetTaskCompletedIntent | TaskEntity, completed Bool | 명시적 상태 설정 |
| AI-07 | OpenReviewIntent | daily / weekly? | 앱 정리 화면 열기 |
| AI-08 | OpenTaskIntent | TaskEntity | 해당 상세 열기 |
| AI-09 | UndoLastDecisionIntent | receipt 또는 원본 operation | 버전 조건부 되돌리기 |
| AI-10 | CommitWidgetDecisionIntent | card token, taskID, versions, target, context | 내부 위젯 쓰기용. 일반 검색 노출하지 않음 |
| AI-11 | ShowWidgetDatePanelIntent | scopeKey, cardID, expectedPanelVersion, panel | 로컬 표시만 변경 |
| AI-12 | FinishReviewIntent | cycleID, sessionID | 정리 종료, 오늘 모드 전환 |
| AI-13 | OpenDatePickerIntent / Link | taskID, session / card 참조 | 날짜 선택 전경 UI. 변경은 최종 선택 시 |

일반 사용자용 ScheduleTaskIntent와 위젯 내부 CommitWidgetDecisionIntent를 구분한다. 내부 인텐트의 카드 버전 / 토큰 같은 필드를 Siri에게 말하게 하지 않는다.

공개 배치 인텐트는 엔티티를 선택한 뒤 최신 상태를 읽고 자체 command context를 구성한다. “다음 주로 보내”는 주 계획, “다음 주 화요일”은 날짜 계획이다. SDK / Siri가 한국어 날짜를 모호하게 넘기면 확인하고 조용히 임의 해석하지 않는다.

## 4. 대표 App Shortcuts

권고 노출 목록은 “할 일 넣기”, “오늘 남긴 일”, “오늘 정리”, “이번 주 정리”, “할 일 날짜 바꾸기”, “할 일 완료” 6개다. Apple의 최대 10개는 AppShortcuts 항목 수의 제한이며 전체 App Intent 개수 제한이 아니다. 근거 A04.

한국어 발화 예시는 제품 목표 문구이지 인식 검증 결과가 아니다.

```text
“[앱 이름]에 인터뷰 질문 확인 넣어 줘.”
“[앱 이름] 오늘 할 일 보여 줘.”
“[앱 이름]에서 인터뷰 질문 확인을 내일로 옮겨 줘.”
```

날짜가 없는 입력에 마감과 프로젝트를 연속 질문하지 않는다. 작업이 확실하지 않으면 후보를 먼저 고르게 한다. 단축어의 실행 결과는 단순 문자열뿐 아니라 생성 / 변경된 엔티티도 반환하여 다음 행동과 연결할 수 있게 한다.

## 5. 배경 실행과 가용성

`AppIntent`, `AppEntity`, Query, WidgetKit 버튼을 필수 기반으로 삼는다. `supportedModes`와 `allowedExecutionTargets`는 공식 문서에 존재하지만, 사용 중 SDK와 대상 OS별 availability를 컴파일로 확인한다. 저버전 분기에는 해당 SDK가 제공하는 호환 방식만 사용한다. 이전 설명의 최신 API 이름을 검증 없이 복사하지 않는다. 근거 A03, A13.

인텐트 실행 위치가 앱인지 확장인지에 관계없이 해당 프로세스의 composition root가 Data / Domain 서비스를 초기화할 수 있어야 한다. 앱 화면을 한 번 실행한 뒤에만 준비되는 singleton에 의존하지 않는다.

잠금 상태와 authenticationPolicy를 명시한다. 시스템이 잠긴 기기에서 상호작용을 제한하는 것을 우회하지 않는다. 인증이 필요한 변경은 인증 또는 앱 열기 경로를 사용한다. 근거 A01, A14.

## 6. 위젯 종류

| 종류 | 목적 | 기본 내용 |
|---|---|---|
| 정리 / 오늘 위젯, 중형 | 일상 입력의 핵심 | 작업 1개 + 5개 목적지, 종료 뒤 Today |
| 정리 / 오늘 위젯, 대형 | 주간 날짜와 부가 정보 | 카드 + 날짜 패널 + 되돌리기 |
| 작은 위젯 | 진입과 짧은 확인 | 오늘 수 / 빠른 입력 또는 정리 진입 |
| Mac 네이티브 위젯 | Mac에서 같은 모델 조작 | 해당 기기 저장소 기준 카드 / 목록 |

중형에서 5개 버튼과 충분한 타깃 크기를 동시에 유지하는 것은 반드시 실기기로 검증한다. 큰 글자에서는 주간 날짜 패널을 앱에서 이어야 할 수 있다. 사용자가 요구한 5개 목적지는 유지하되, 읽을 수 없는 크기로 억지로 한 줄에 넣지 않는다.

iPhone 위젯을 Mac에 표시하는 원격 경로와 Mac 앱의 네이티브 위젯은 다른 테스트 대상이다. 전자는 왕복 지연이 추가될 수 있다고 Apple이 설명한다. A01.

## 7. 위젯 상태 머신

```text
loading
  → unavailable / privacyLocked / empty / reviewCard / todayList

reviewCard
  → chooseThisWeek
  → chooseNextWeek
  → appDatePicker (기타)
  → committing
  → reviewCard(next)
  → todayList (정리 종료)

chooseThisWeek / chooseNextWeek
  → reviewCard(same) (뒤로)
  → committing (날짜 또는 주만 선택)

committing
  → reviewCard(next) + receipt
  → sameCard(error)
  → staleCard(refresh)
  → committedProjectionPending
```

`@State`로 일반 앱처럼 장기적인 페이지 상태를 유지한다고 가정하지 않는다. 패널 전환은 AppIntent가 로컬 WidgetPresentation을 변경하고 timeline을 다시 만드는 방식의 권고안이다. 지원되는 Button / Toggle 동작과 reload 기반 구조는 A01에 근거한다.

WidgetPresentation은 scopeKey / cardID / panelVersion에 바인딩한다. 같은 기기의 동일 설정 위젯은 하나의 정리 scope를 공유한다. 서로 다른 위젯 인스턴스가 독립 상태라는 사실을 보장할 API를 확인하지 않고 숨은 고유 ID를 만들어 쓰지 않는다.

## 8. 카드 입력의 원자적 처리

```text
버튼에 포함할 것
  taskID
  expected content / plan / status / deadline versions
  decisionToken
  cardID / sessionID / scopeKey
  planningDay / policyRevision
  absolute destination
```

버튼 처리 시 “현재 큐 맨 앞 항목”을 새로 조회하여 수정하면 안 된다. 이미 렌더링된 taskID만 수정한다. 같은 카드의 오늘 / 내일 / 날짜 버튼 모두 동일한 decisionToken을 공유한다.

| 연속 입력 | 기대 결과 |
|---|---|
| 내일을 3회 탭 | 같은 항목 한 번만 변경 |
| 내일 직후 오늘 탭 | 먼저 저장된 하나만 적용, 뒤 입력은 이미 처리됨 |
| 패널 열기 2회 | 같은 패널. 작업 계획 변화 없음 |
| 다른 기기에서 완료 후 날짜 탭 | 로컬이 변경을 알고 있다면 stale / completed 안내 |
| 변경을 아직 못 받은 오프라인 기기에서 날짜 탭 | 로컬 기록 후 동기화. completed가 plan 변경으로 풀리지 않음 |
| 날짜 경계 후 오늘 탭 | 새 날짜로 자동 재해석하지 않고 갱신 |
| 동일 snapshot을 가진 위젯 2개에서 입력 | 공통 게이트와 토큰으로 작업 1회 변경 |

UI 변화는 로컬 원본이 저장된 뒤 진행한다. optimistic Toggle을 쓰는 경우에도 최종 표시를 실제 저장 결과와 맞춘다. A01. 오류 시 다음 카드를 성공한 것처럼 먼저 보여주지 않는다.

## 9. 갱신 정책

앱 상태 변경, 인텐트 완료, 동기화 수신 후 필요한 위젯의 timeline을 갱신 요청한다. 주기적 갱신은 날짜 경계와 계획 변경처럼 의미 있는 시점에 집중한다. 매분 또는 매초 전체 목록을 새로고침하지 않는다.

WidgetKit의 일반 갱신은 시스템 예산을 따르지만 사용자 AppIntent 상호작용에 따른 reload는 별도 취급된다. 따라서 “하루 40~70개 작업만 정리할 수 있다”고 해석하지 않는다. 반대로 누른 즉시 다음 카드가 항상 표시된다고 보장하지도 않는다. 근거 A02.

주간 날짜 패널의 반응성이 목표에 못 미치면, 오늘 / 내일은 위젯에서 유지하고 주간 / 기타는 앱의 해당 선택 화면으로 연결하는 fallback을 사용할 수 있다. 이는 무조건 동등한 UX가 아니므로 G-WIDGET 결과와 제품 범위 변경을 기록한다.

## 10. 딥링크 계약

가칭 scheme은 `postpone`이며 제품명 / Bundle 설정 확정 시 변경한다. 아래는 자체 라우팅 예시다.

```text
postpone://capture
postpone://today
postpone://review?mode=daily
postpone://task/<taskID>
postpone://task/<taskID>/schedule?session=<id>&card=<id>
```

딥링크는 화면을 여는 요청이며 URL을 받았다는 이유만으로 날짜를 변경하지 않는다. taskID, sessionID 형식과 현재 계정 소유를 검증한다. URL에 제목 / 메모 / 인증 토큰을 넣지 않는다. 외부가 만든 가짜 카드 참조는 일반 작업 상세로만 열거나 거부한다.

일반 달력 UI를 위젯 위에 arbitrary popover로 띄울 수 있다고 가정하지 않는다. 기타는 관련 앱 장면으로 연결한다. 공식 surface / deep-link 경로는 A11을 참고한다.

## 11. 정리 후 오늘 목록 전환

정리 종료 여부는 검토 주기 기록에 반영한다. 같은 날 새 작업을 입력해도 위젯이 자동으로 정리 상태를 강제하지 않는다. Today 위젯에는 명시적으로 오늘에 배치한 작업과 완료 행동, “오늘 다시 정리”를 제공한다.

날짜가 바뀌었으나 위젯 이미지가 오래됐다면 표시와 처리의 일치가 깨질 수 있다. header에 날짜를 보여주고 mutation에서 context를 검증한다. 필요한 미래 entry를 만들되, 최신성 안전은 timeline 정시 실행이 아니라 명령 검증으로 확보한다.

## 12. Mac Spotlight와 컨트롤

macOS의 일반 단축어 action 지원과 최신 Spotlight에서 action을 직접 실행하는 기능을 구분한다. WWDC25는 Mac Spotlight 실행과 필수 parameterSummary 조건을 설명한다. A12. HIG의 App Shortcuts 플랫폼 표기에는 상충하거나 좁은 의미의 표현이 있으므로 A04만으로 Mac 기능 전체를 단정하지 않는다.

최신 실행 표면은 OS별 실제 기기 / SDK에서 검증한다. 최소 macOS 15에서 최신 Spotlight 실행까지 보장하지 않는다. 미지원 환경에서는 Mac 단축어 앱과 메뉴 막대 / 앱 UI를 제공한다.

ControlWidget, 액션 버튼, Apple Watch는 지원 표면과 설정 경로가 각각 다르다. 사용자가 배치하는 것을 앱이 임의로 설치 / 매핑한다고 설명하지 않는다. R1 필수 UX가 최신 컨트롤 하나에 종속되지 않도록 한다.

## 13. Live Activity와 AI의 위치

R1에서는 하루 전체 할 일 목록을 상시 Live Activity로 유지하지 않는다. 추후 사용자가 시작한 집중 세션이나 종료가 있는 짧은 정리에만 검토한다. ActivityKit lifecycle은 위젯 timeline과 다른 개념이다. A15.

스니펫 / Siri 스키마 / AI 분해가 없어도 5개 목적지와 모든 저장 명령이 동작해야 한다. 모델이 제안한 날짜를 UI의 사용자 확인 없이 확정하지 않는다. R1의 날짜 의미를 Reminders schema에 억지로 맞춰 실제 마감과 섞지 않는다.

## 14. 구현 완료 증거

인텐트별 지원 OS, 실행 대상, 잠금 조건, 입력 / 출력, 오류, 한국어 표시를 기록한다. 실제 위젯에서 최소 30회 연속 결정, 중복 탭, 오프라인, 앱 종료, 두 인스턴스, 자정 경계를 시험한다. Siri 이름 인식 성공을 시뮬레이터 단위 테스트만으로 대체하지 않는다.
