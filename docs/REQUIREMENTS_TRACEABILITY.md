# 미러 요구사항·QA 추적표

[전체 구현 계획](IMPLEMENTATION_PLAN.md)의 범위와 검증 책임을 추적한다. 원본 [FR/QA 연결](../postpone-app-docs/validation/traceability.json)과 [QA 87개](../postpone-app-docs/validation/qa-cases.json)의 ID·기대 결과를 유지하고 단계·검증 경로를 추가했다. 원본 보고서는 수정하지 않는다.

## 1. 현재 증거와 상태

전체 통합 코드는 `67d69e9`부터 추가했으며 모듈 접근·동시성·실제 SQLite 삭제 오류를 회귀와 함께 수정했다. `c94a3522fef4515644a721b1fed8000dba23b5e9`의 [Actions 36763990118](https://github.com/hellosunghyun/mirror/actions/runs/36763990118)에서 SwiftPM의 필수 세 target이 실제 통과했다: Domain 94, Data 24, System 33, 합계 151개다. Xcode 27의 독립 worker 완료 보고 세 개를 합산하며 매개변수 사례와 플랫폼 반복 실행을 별도 테스트로 더하지 않는다. native 앱·확장 빌드와 unit 명령은 성공했지만 bundle/metadata 결과 형식 검사와 실제 UI 오류로 전체 실행은 실패했다. 후속 수정은 다시 실제 Actions 결과를 확인해야 한다.

이전 날짜 기반 증거는 `74d02286d396c59e860394cdc660d72f5ea6dfa2` 및 Simulator 보완 `fa783ae`, [Actions 36747271079](https://github.com/hellosunghyun/mirror/actions/runs/36747271079)의 네 경로 각각 37개다. 아래 U는 이 순수 날짜 판정의 범위이며 새 저장·UI·확장·동기화나 QA 87개 전체 통과로 확장하지 않는다.

| 증거 | 실제 코드/테스트와 범위 |
|---|---|
| U1 | LocalDate/PlanningContext/PlanTarget, F-001~007/026~033, LocalDateTests: 날짜/주/윤년/DST·자정·형식·Gregorian 경계 |
| U2 | PlanningRules, F-008~020, PlanningRulesTests: Today/Review·유예·수동 모드·완료/삭제/보관 제외·과거 계획 |
| U3 | F-021~025와 deadlineDateProjection/deadlineAcknowledgmentBinding: 마감 환산/확인 조건·task/revision/target 바인딩 |
| U4 | F-034~036와 changedPolicyReceiptFirst: receipt 존재를 주입한 context 순서·같은 날짜의 정책 변경; durable 조회 아님 |
| U5 | storedDatesSurvivePolicyChange/sameInstantDifferentPlanningDay: 저장 날짜 문자열·주와 명시 계획 시간대 보존; 실제 설정·세션/알림 아님 |

| 새 부분 증거 | 실제 실행 범위와 남은 조건 |
|---|---|
| V1 명령·reducer | `CommandValidationTests`/`ReducerTests`와 기존 날짜 tests, Domain 94개. 원본 digest·그룹별 head·멱등성·충돌·pending·조건부 Undo·20개 원자 배치의 생산 API. 실제 CloudKit 전송은 검사하지 않음 |
| V2 실제 영속화 | `StoreIntegrationTests`, Data 24개. 실제 SQLite 재시작·원본 후 장애 복구·경쟁 인스턴스·export/import·로컬 삭제·복원·구독 알림. Mac 별도 OS 프로세스 lock 회귀 포함. 두 실제 Core Data writer 프로세스·물리 보호 데이터·migration/대용량 성능은 별도 검증 |
| V3 시스템 계약 | `SystemContractTests`/`CloudBoundaryTests`, System 33개. 실제 임시 SQLite의 frozen 카드·receipt/토큰·Today 순서·재정리, 알림 planner·안전 딥링크·로컬 계측·Cloud 상태 구독. unhosted OS adapter의 typed 실패를 확인하며 실제 Widget/Siri/권한/CloudKit 성공으로 대신하지 않음 |
| V4 native 빌드·구성 | `b0c2fa419036b9d80f5c3b4140676bf02f9910fd`, [Actions 36769033639](https://github.com/hellosunghyun/mirror/actions/runs/36769033639). Mac 151 / iPhone·iPad 각 150개 실제 unit 통과, 앱·두 확장/세 bundle/privacy/라이선스/URL/App Intents 실제 actions 16개 구성 검사 통과. UI는 각 6개 모두 실패하므로 앱 수용·실기기·시스템 표면 성공으로 확장하지 않음 |

최신 소스 수정 `542a0093fff829d93f4678206289712a6e68819c`의 [Actions 36773091969](https://github.com/hellosunghyun/mirror/actions/runs/36773091969)은 GitHub 계정 결제/사용 한도 때문에 모든 job의 실행 단계가 0개다. 새 UI 결과나 IPS는 생성되지 않았으며 해당 수정은 `not_run`으로 유지한다. 계정 복구 후 최신 PR HEAD를 검증하며 위 V4의 통과 근거를 최신 소스나 앱 수용 전체로 확장하지 않는다.

아래 FR 행의 `코드 추가`는 생산 경로가 작성됐다는 뜻이며 새 통합 코드의 빌드·수용 통과를 뜻하지 않는다. 이전 U 근거는 위 순수 함수에 한정한다. 모든 FR의 앱 수용은 아직 미완료이고, 모든 Q 행의 전체 시나리오는 `not_run`이다. 향후 결과는 실제 full SHA/run/OS/기기/고정 시각/expected/actual/증거/남은 범위와 함께 이 파생 추적표에 갱신한다.

## 2. FR-001~030

| FR | 우선순위·요구사항 | 단계 | 원본 QA | 현재 구현·부분 증거 | 완료에 남은 범위 |
|---|---|---|---|---|---|
| FR-001 | P0 빠른 입력 | D-03/04/06 | Q-001, Q-002, Q-003, Q-004, Q-007 | 코드 추가: TaskContent/Capture, App Capture UI·줄 분리 미리보기 | 원격 통합·UI 검증 및 작업 생성·영속/화면 |
| FR-002 | P0 공유 입력 | D-04/07/13 | Q-005 | 코드 추가: iOS/Mac Share adapter·공통 Capture | 원격 통합·UI 검증 및 Share 원문·URL·오프라인 |
| FR-003 | P0 보관함과 전체 검색 | D-04/06/11 | Q-008 | 코드 추가: 실제 저장 조회·보관함 검색/필터 | 원격 통합·UI 검증 및 전체 저장 조회·검색 UI |
| FR-004 | P0 일간 정리 | D-03/05/06/09 | Q-021, Q-022, Q-023 | 코드 추가: frozen App/Widget 큐·Review ack/close | 원격 통합·UI 검증 및 cycle/ack/session/큐·자동 전환 |
| FR-005 | P0 주간 정리 | D-03/09/12 | Q-020 | 코드 추가: 주간 cycle·알림 교체 | 원격 통합·UI 검증 및 단일 주기·중복 큐/알림 |
| FR-006 | P0 오늘 / 내일 배치 | D-02/03/06/08 | Q-009, Q-010 | 코드 추가: 공통 setPlan·오늘/내일 UI, U1 | 원격 통합·UI 검증 및 명령 저장·버튼·완료 독립 |
| FR-007 | P0 이번 주 / 다음 주 날짜 선택 | D-02/06/08/11 | Q-011, Q-012, Q-016 | 코드 추가: 이번/다음 주 7일 패널·뒤로 | 원격 통합·UI 검증 및 패널·같은 작업 저장·뒤로 |
| FR-008 | P0 주만 지정 | D-02/03/06/09 | Q-013, Q-014 | 코드 추가: week-only·검토 유예 명령, U1/U2 | 원격 통합·UI 검증 및 reviewNotBefore 저장·재등장 |
| FR-009 | P0 기타 날짜 선택 | D-05/06/08 | Q-015, Q-043 | 코드 추가: custom day/week/park·고정 widget deep link | 원격 통합·UI 검증 및 안전 라우트·달력·취소 |
| FR-010 | P0 재등장 | D-02/03/09 | Q-017 | 코드 추가: durable ack·미래/closed 후보 제외 | 원격 통합·UI 검증 및 durable ack·세션과 실제 재등장 |
| FR-011 | P0 중간 종료 | D-03/06/09 | Q-019 | 코드 추가: 부분 close 저장·요약·미검토 보존 | 원격 통합·UI 검증 및 close 저장·요약·미검토 보존 |
| FR-012 | P0 오늘 목록 | D-02/03/06/08 | Q-018 | 코드 추가: 실제 Today projection·마감 분리 | 원격 통합·UI 검증 및 영속 조회·오늘 UI |
| FR-013 | P0 완료와 다시 배치 | D-03/06/11 | Q-032, Q-033 | 코드 추가: 완료/다시 열기·명시 배치·이력 | 원격 통합·UI 검증 및 상태 명령·다시 열기/배치 |
| FR-014 | P0 실제 마감 | D-02/03/06/12 | Q-025, Q-026, Q-027, Q-028 | 코드 추가: deadline 그룹·task/head/target 확인·알림 | 원격 통합·UI 검증 및 deadline 그룹·오래된 확인 거부·알림 |
| FR-015 | P0 실행 취소 | D-03/05/09/10 | Q-029, Q-030, Q-031, Q-087 | 코드 추가: 보상 Operation·조건부/묶음 Undo | 원격 통합·UI 검증 및 보상 기록·버전·오프라인 병합 |
| FR-016 | P0 위젯 | D-05/07/08 | Q-035, Q-036, Q-037, Q-041, Q-047 | 코드 추가: WidgetTimeline·고정 card/token·5목적지 | 원격 통합·UI 검증 및 실제 timeline/token·G-WIDGET |
| FR-017 | P0 App Intents | D-03/05/07 | Q-006, Q-044 | 코드 추가: AI01~13·Entity/Query·AppShortcuts | 원격 통합·UI 검증 및 생산 서비스 adapter·Query·metadata·실제 Siri |
| FR-018 | P0 네이티브 멀티디바이스 | D-01/08/10/11/14 | Q-046, Q-079, Q-086 | 코드 추가: iPhone tabs·iPad/Mac sidebar·네이티브 확장 | 원격 통합·UI 검증 및 독립 Mac·적응형 iPad·표면별 QA |
| FR-019 | P0 로컬 우선 저장 | D-04/06/10 | Q-049, Q-050 | 코드 추가: Core Data SQLite·process gate·로컬 원본 우선 | 원격 통합·UI 검증 및 실제 저장소·네트워크 독립 |
| FR-020 | P0 iCloud 동기화 | D-03/04/05/10 | Q-053, Q-055, Q-056, Q-057, Q-058, Q-059, Q-060, Q-061, Q-062, Q-087 | 코드 추가: opt-in private CloudKit·계정별 store·merge consent | 원격 통합·UI 검증 및 실제 미러링·계정·충돌·G-SYNC |
| FR-021 | P0 캘린더 맥락 | D-12 | Q-065, Q-066, Q-067, Q-068 | 코드 추가: opt-in EventKit 읽기·권한/철회 cache | 원격 통합·UI 검증 및 실제 EventKit 권한·읽기 adapter |
| FR-022 | P0 정리 / 마감 알림 | D-09/12 | Q-069, Q-070, Q-071, Q-072, Q-073 | 코드 추가: 28일/48개 planner·실제 UN 예약/취소 | 원격 통합·UI 검증 및 실제 예약·취소·기기별 선택 |
| FR-023 | P0 날짜와 시간대 | D-02/03/05/12 | Q-039, Q-074 | 코드 추가: 저장 정책·세션 context·명시 설정 변경 | 원격 통합·UI 검증 및 설정 명령·세션 무효화·알림 재예약 |
| FR-024 | P0 휴지통 / 보관 | D-03/06/13 | Q-024, Q-034, Q-084 | 코드 추가: 휴지통/보관/restore·기기 삭제 | 원격 통합·UI 검증 및 휴지통/복구·검색·전체 삭제 게이트 |
| FR-025 | P0 접근성과 개인정보 | D-06/07/08/13/14/16 | Q-045, Q-075, Q-076, Q-077, Q-082 | 코드 추가: SwiftPieces 한국어·Reduce Motion·외부 제목 숨김·파일 보호 | 원격 통합·UI 검증 및 실제 접근성·잠금·로그/노출 |
| FR-026 | P0 내보내기 / 복원 | D-03/04/13 | Q-054, Q-081 | 코드 추가: immutable 원본 export/import·복원 확인·중단 회복 | 원격 통합·UI 검증 및 전체 원본 export/import·미리보기·격리 |
| FR-027 | P1 다중 선택 배치 | D-03/09/11 | Q-080 | 코드 추가: 20개 전체 검증·단일 Operation·batch Undo | 원격 통합·UI 검증 및 20개 전체 검증·한 기록·Undo |
| FR-028 | P1 Mac 빠른 조작 | D-09/11/14 | Q-078 | 코드 추가: Mac menu bar 입력·키보드/검색/Undo | 원격 통합·UI 검증 및 메뉴 막대·키보드/포커스·단축어 |
| FR-029 | P1 시스템 확장 표면 | D-07/15 | Q-048 | 코드 추가: iOS Control·Spotlight opt-in·parameterSummary | 원격 통합·UI 검증 및 SDK 표면·parameterSummary·인덱스·fallback |
| FR-030 | P0 오류와 오래된 화면 | D-03/04/05/06/10/13 | Q-038, Q-040, Q-042, Q-051, Q-052, Q-063, Q-064, Q-083, Q-085 | 코드 추가: original-first receipt·재구축·typed 오류·schema 격리 | 원격 통합·UI 검증 및 저장·원본 복구·오류 UI·안전 링크·schema |

## 3. NFR-001~012

단위 함수의 성질과 실제 저장/시스템 성능을 구별한다. 기준 데이터와 p95 수치는 목표이며 아직 측정되지 않았다. NFR별 근거는 아래 QA 전체와 추가 측정을 함께 포함한다.

| NFR | 요구 | 단계·관련 게이트 | QA/추가 검증 | 현재 상태 |
|---|---|---|---|---|
| NFR-001 | 데이터 안전·잘못된 작업 변경 0건 | D-03/04/05/08/10/13, 모든 안전 게이트 | Q-035~043/049/051~064/080/084/087; 원본/투영/receipt/snapshot 경계 crash | not_run |
| NFR-002 | 로컬 한 건 p95 500ms 목표 | D-04/05/14 | Q-086; 실기기 단건 표본·release/debug·store 크기·gate 대기 분리 | not_run |
| NFR-003 | 지연·두 위젯·날짜 경계에서 대상 고정 | D-05/08, G-WIDGET | Q-035~041/046; 다른 목적지 연속 탭·두 독립 프로세스 | not_run |
| NFR-004 | 일반 실기기 동작 후 표시 p95 2초 목표 | D-08/14, G-WIDGET | Q-041/046/086; 탭→save/snapshot/OS reload→새 카드 분리 | not_run |
| NFR-005 | 오프라인 핵심 흐름 | D-04/06/07/10 | Q-005/049/050/062; 네트워크 없고 iCloud 미로그인인 실제 저장·재시작 | not_run |
| NFR-006 | 동일 변경 집합의 같은 투영 | D-03/10, G-SYNC | Q-053/055~060/087; 순열·중복·기기 시계 차이·pending 부모 | not_run |
| NFR-007 | 민감 원문 분석 로그 제외 | D-07/12/13/16 | Q-045/082/083; 오류·sync·share·export·로컬 계측·제목 숨김/노출 검사 | not_run |
| NFR-008 | 큰 글자·비제스처 대체 경로 | D-06/08/11/14, G-WIDGET/G-UX | Q-075~079; VoiceOver/VoiceControl·대비·Reduce Transparency·키보드 | not_run |
| NFR-009 | 무한 폴링·초 reload·가짜 background 없음 | D-08/12/14 | 날짜 경계 timeline·예약 범위/보충·백그라운드 자원/에너지 측정 | not_run |
| NFR-010 | Foundation 순수 도메인 테스트 가능 | D-02/03 | fixture 36개·불변식·명령/reducer property; UI/Apple framework 의존 방지 | U1~U5 및 V1 Domain 94개 통과; 전체 앱 수용과 구별 |
| NFR-011 | 원본 보존·재구축·migration 복구 | D-04/10/13 | Q-051~054/060/063/064/085; backup·token 무효·손상·미지원 payload 격리 | not_run |
| NFR-012 | 권고/마감/미정 상태 구분 | D-06/09/12/16, G-UX | Q-013/014/019/025~028/068~074; week≠Monday, plan≠deadline·알림/3분 보장 문구 검사 | not_run |

## 4. Q-001~087 개별 실행 책임

Q는 원본의 ID다. `A`는 Actions 단위/실제 영속·프로세스 통합, `UI`는 Actions의 Simulator/Mac UI, `SYS`는 실제 서명 기기의 Widget/Siri/잠금/권한/CloudKit, `USER`는 동의한 사용자 검증이다. 여러 경로가 적혀 있으면 자동 근거로 실제 표면의 요구를 대신하지 않는다. 전체 기대 결과는 원본 QA의 precondition/steps를 그대로 적용한다.

Q-048의 과거 최소 OS 문구는 확정된 최소 **OS 27**의 지원/availability와 플랫폼 차이 검증으로 연결한다. 이전 OS까지 지원한다고 범위를 바꾸지 않는다.

| QA | 상황·기대 결과 | 관련 FR | 단계 | 필요한 경로 | 현재 전체 결과·부분 단위 |
|---|---|---|---|---|---|
| Q-001 | 제목만 입력 — open + unassigned. Today 미포함 | FR-001 | D-03/04/06 | A/UI | not_run; U2 Today 판정만 부분 |
| Q-002 | 공백 제목 — 저장 거부, 입력 유지 | FR-001 | D-03/06 | A/UI | not_run |
| Q-003 | 길이 초과 — 자동 잘림 없이 안내 | FR-001 | D-03/06 | A/UI | not_run |
| Q-004 | 여러 줄 붙여넣기 — 한 개 / 줄마다 선택 전 자동 3개 생성 금지 | FR-001 | D-06 | UI | not_run |
| Q-005 | 공유 텍스트와 URL — 원문 보존, 네트워크 없는 저장 | FR-002 | D-04/07/13 | A/UI/SYS | not_run |
| Q-006 | 앱 첫 실행 전 인텐트 — 로컬 저장소 초기화 후 작업 저장 | FR-017 | D-04/07 | A/SYS | not_run |
| Q-007 | 같은 제목 두 작업 — 서로 다른 작업 ID로 보존 | FR-001 | D-03/04/06 | A/UI | not_run |
| Q-008 | 미래 작업 검색 — 검색 가능하지만 정리 큐에는 미포함 | FR-003 | D-04/06/11 | A/UI | not_run |
| Q-009 | 오늘 버튼 — plan만 오늘, 완료 안 됨 | FR-006 | D-02/03/06/08 | A/UI/SYS | not_run; U1 목적지만 부분 |
| Q-010 | 내일 버튼 — 10월 1일 day 저장 | FR-006 | D-02/03/06/08 | A/UI/SYS | not_run; U1 부분 |
| Q-011 | 이번 주 날짜 — 정확 날짜 저장, 시간 블록 없음 | FR-007 | D-02/06/08 | A/UI/SYS | not_run; U1 범위만 부분 |
| Q-012 | 다음 주 날짜 — 10월 6일 day 저장 | FR-007 | D-02/06/08 | A/UI/SYS | not_run; U1 범위만 부분 |
| Q-013 | 현재 주 요일 나중 — week 상태, 같은 날 다시 질문 안 함 | FR-008 | D-02/03/06/09 | A/UI | not_run; U2 판정만 부분 |
| Q-014 | 다음 주 요일 나중 — 그 주 월요일 검토 후보, Today 아님 | FR-008 | D-02/03/06/09 | A/UI | not_run; U1/U2 부분 |
| Q-015 | 기타 날짜 — 같은 taskID에 정확 날짜 저장 | FR-009 | D-05/06/08 | A/UI/SYS | not_run |
| Q-016 | 패널 뒤로 — plan 변경 0건 | FR-007 | D-05/06/08 | A/UI/SYS | not_run |
| Q-017 | 미래 날짜 재노출 — 후보에서 제외 | FR-010 | D-02/03/09 | A/UI | not_run; U2 부분 |
| Q-018 | 과거 미완료 — 검토 후보, Today 아님 | FR-012 | D-02/03/06 | A/UI | not_run; U2 부분 |
| Q-019 | 부분 정리 종료 — 미검토 4개 보존, 자동 Today 금지 | FR-011 | D-03/06/09 | A/UI/USER | not_run |
| Q-020 | 주간 일간 중복 — 주간 하나, 일간 중복 큐 / 알림 없음 | FR-005 | D-03/09/12 | A/UI/SYS | not_run |
| Q-021 | 새 입력 중간 유입 — 현재 카드 앞에 삽입하지 않음 | FR-004 | D-05/06/09 | A/UI | not_run |
| Q-022 | 같은 날 재실행 — Today 기본, 자동 재정리 안 함 | FR-004 | D-03/06/09 | A/UI | not_run; U2 closed 판정만 부분 |
| Q-023 | 명시적 다시 정리 — 오늘 항목 재검토 가능 | FR-004 | D-02/03/06/09 | A/UI/USER | not_run; U2 부분 |
| Q-024 | 오래된 보관 항목 — 자동 큐 제외, 검색 가능 | FR-024 | D-02/03/06/13 | A/UI | not_run; U2 부분 |
| Q-025 | 계획과 마감 분리 — deadline 원본 동일 | FR-014 | D-03/06/12 | A/UI | not_run |
| Q-026 | 마감 이후 날짜 — 확인 전 변경 없음 | FR-014 | D-02/03/06/08 | A/UI/SYS | not_run; U3 부분 |
| Q-027 | 마감 확인 중 변경 — 오래된 확인 token 거부 | FR-014 | D-02/03/06/10 | A/UI/SYS | not_run; U3 바인딩만 부분 |
| Q-028 | 주 안의 마감 — 화요일 마감 표시, 월요일 자동 배치 안 함 | FR-014 | D-02/03/06/09 | A/UI/USER | not_run; U3 부분 |
| Q-029 | 단순 Undo — 이전 plan과 reviewNotBefore 복원 | FR-015 | D-03/05/09 | A/UI | not_run |
| Q-030 | 제목 수정 후 Undo — plan만 복원, 새 제목 유지 | FR-015 | D-03/09 | A/UI | not_run |
| Q-031 | 후속 plan 변경 후 Undo — 영향 plan 버전 불일치로 과거 날짜 덮어쓰기 거부 | FR-015 | D-03/09/10 | A/UI/SYS | not_run |
| Q-032 | 완료 처리 — status 완료, plan / deadline 이력 유지 | FR-013 | D-03/06/12 | A/UI | not_run |
| Q-033 | 완료 취소 — 과거 계획 유지, Today 자동 이월 안 함 | FR-013 | D-02/03/06 | A/UI | not_run; U2 판정만 부분 |
| Q-034 | 휴지통 복구 — 기존 계획 유지, stale 복구는 거부 | FR-024 | D-03/06/13 | A/UI | not_run |
| Q-035 | 반복 탭 — 한 결정, 한 작업 변경 | FR-016 | D-03/05/08 | A/SYS | not_run |
| Q-036 | 상이한 빠른 탭 — 먼저 커밋한 결과 유지, 다음 작업 안 바뀜 | FR-016 | D-03/05/08 | A/SYS | not_run |
| Q-037 | 동일 설정 위젯 2개 — 한 번 적용, 공통 receipt | FR-016 | D-04/05/08 | A/SYS | not_run |
| Q-038 | 오래된 다른 기기 완료 — stale / 완료 안내 | FR-030 | D-03/05/08/10 | A/SYS | not_run |
| Q-039 | 자정 후 상대 버튼 — staleContext, 자동 재해석 금지 | FR-023 | D-02/05/08 | A/SYS | not_run; U4 부분 |
| Q-040 | 자정 후 중복 재시도 — 기존 receipt 반환, 새 변경 없음 | FR-030 | D-02/04/05/08 | A/SYS | not_run; U4 순서만 부분 |
| Q-041 | 주 패널 재로드 — 같은 card / decisionToken 유지 | FR-016 | D-05/08 | A/SYS | not_run |
| Q-042 | 위젯 저장 실패 — 기존 카드 유지, 성공 피드백 금지 | FR-030 | D-04/05/08 | A/SYS | not_run |
| Q-043 | 기타 앱 진입 취소 — 원래 plan 유지, 원래 작업 맥락 보존 | FR-009 | D-05/06/08 | A/UI/SYS | not_run |
| Q-044 | Siri 동명 작업 — 대상 선택, 임의 첫 항목 수정 금지 | FR-017 | D-07 | A/SYS | not_run |
| Q-045 | 잠금 상태 — 인증 정책과 파일 보호 일치 | FR-025 | D-07/08/13 | SYS | not_run |
| Q-046 | Mac 원격 iPhone 위젯 — 왕복 지연 표시, 대상 고정 | FR-018 | D-08/11 | SYS | not_run |
| Q-047 | 정리 종료 모드 — Today 목록으로 전환 | FR-016 | D-03/07/08/09 | A/SYS | not_run |
| Q-048 | 구형 OS 최신 API — 비지원 기능 숨김, 핵심 동작 가능 | FR-029 | D-01/07/15 | A/UI/SYS | not_run |
| Q-049 | 오프라인 핵심 흐름 — 모두 로컬 성공 | FR-019 | D-04/06/07/10 | A/UI/SYS | not_run |
| Q-050 | iCloud 미로그인 — 로컬 전용, 강제 로그인 없음 | FR-019 | D-04/06/10 | A/UI/SYS | not_run |
| Q-051 | 원본 저장 전 crash — 성공 표시 없음, 재시도 한 번 생성 | FR-030 | D-04/05 | A | not_run |
| Q-052 | 원본 저장 후 crash — 재생으로 복구, 중복 생성 없음 | FR-030 | D-04/05 | A | not_run |
| Q-053 | 동일 event 재수신 — 논리 한 번으로 계산 | FR-020 | D-03/04/10 | A/SYS | not_run |
| Q-054 | 같은 ID 다른 payload — 격리, 조용한 덮어쓰기 금지 | FR-026 | D-03/04/10/13 | A/SYS | not_run |
| Q-055 | 제목과 날짜 동시 수정 — 둘 다 보존 | FR-020 | D-03/10 | A/SYS | not_run |
| Q-056 | 서로 다른 날짜 동시 수정 — 동일 기록 집합에서 수렴, 충돌 이력 | FR-020 | D-03/10 | A/SYS | not_run |
| Q-057 | 완료와 날짜 동시 수정 — 완료 유지 | FR-020 | D-03/10 | A/SYS | not_run |
| Q-058 | 삭제와 stale reopen — 삭제 우선, 부활 안 함 | FR-020 | D-03/10/13 | A/SYS | not_run |
| Q-059 | 기기 시계 차이 — 동일 event 집합의 결정론 유지 | FR-020 | D-03/10 | A/SYS | not_run |
| Q-060 | 부모 기록 지연 — pending 보존, 부모 도착 후 적용 | FR-020 | D-03/04/10 | A/SYS | not_run |
| Q-061 | 계정 A에서 B 변경 — A 데이터가 B로 자동 업로드 안 됨 | FR-020 | D-10/13 | A/SYS | not_run |
| Q-062 | CloudKit 용량 오류 — 로컬 유지, 동기화 대기 안내 | FR-020 | D-10 | A/SYS | not_run |
| Q-063 | 캐시 손상 — 원본 보존, 재구축 | FR-030 | D-04/05/08 | A/SYS | not_run |
| Q-064 | 마이그레이션 실패 — 원본 백업 유지, 삭제 초기화 금지 | FR-030 | D-04/10 | A | not_run |
| Q-065 | 캘린더 거절 — 핵심 날짜 배치 가능 | FR-021 | D-12 | A/UI/SYS | not_run |
| Q-066 | 캘린더 철회 — 캐시 제거, 읽기 중단 | FR-021 | D-12 | A/UI/SYS | not_run |
| Q-067 | 캘린더 쓰기 방지 — 외부 일정 수정 호출 0건 | FR-021 | D-12 | A/UI/SYS | not_run |
| Q-068 | 종일과 겹친 일정 — 단순 합산 가용시간 단정 안 함 | FR-021 | D-12 | A/UI/SYS | not_run |
| Q-069 | 정리 알림 중복 — 당일 review request 하나 | FR-022 | D-09/12 | A/SYS | not_run |
| Q-070 | 정리 먼저 완료 — 당일 pending request 취소 | FR-022 | D-09/12 | A/SYS | not_run |
| Q-071 | 마감 알림 유지 — 원래 deadline 알림 유지 | FR-022 | D-03/12 | A/SYS | not_run |
| Q-072 | 완료 후 알림 — 관련 pending / delivered 정리 | FR-022 | D-03/12 | A/SYS | not_run |
| Q-073 | 예약 범위 소진 — 무기한 알림 보장 안 함, 재진입 시 보충 | FR-022 | D-12 | A/SYS | not_run |
| Q-074 | 계획 시간대 변경 — 세션 무효화, 알림 재예약, 날짜 문자열 유지 | FR-023 | D-02/03/05/12 | A/UI/SYS | not_run; U5 부분 |
| Q-075 | VoiceOver 정리 — 요일 / 날짜 / 역할 명확, 새 카드 초점 | FR-025 | D-06/08/11/14 | SYS/USER | not_run |
| Q-076 | 가장 큰 글자 — 핵심 행동 유실 없음, 앱 대체 경로 | FR-025 | D-06/08/11/14 | UI/SYS | not_run |
| Q-077 | Reduce Motion — 상태 변화 의미 유지 | FR-025 | D-06/08/14 | UI/SYS | not_run |
| Q-078 | Mac 키보드 — 드래그 필수 아님 | FR-028 | D-09/11/14 | UI/SYS | not_run |
| Q-079 | iPad 좁은 창 — 저장과 날짜 선택 접근 가능 | FR-018 | D-11/14 | UI/SYS | not_run |
| Q-080 | 여러 개 날짜 배치 — 전체 거부, 부분 성공 위장 금지 | FR-027 | D-03/09/11 | A/UI | not_run |
| Q-081 | export / import 왕복 — 상태 같음, 중복 작업 없음 | FR-026 | D-03/04/13 | A/UI | not_run |
| Q-082 | 민감 로그 점검 — 로그에 원문 없음 | FR-025 | D-13/14/16 | A/SYS | not_run |
| Q-083 | 외부 딥링크 공격 — 변경 없이 안전 거부 | FR-030 | D-05/06/07/13 | A/UI | not_run |
| Q-084 | 전체 삭제 후 offline 복귀 — 구세대 부활 / 재업로드 여부 검증, 실패 시 출시 차단 | FR-024 | D-10/13 | SYS | not_run |
| Q-085 | 미지원 payload — 원본 보존, 덮어쓰기 제한 | FR-030 | D-03/04/10/13 | A/SYS | not_run |
| Q-086 | 성능 기준 데이터 — p95 측정과 미달 분리, 성공 조작 금지 | FR-018 | D-04/08/11/14 | A/SYS | not_run |
| Q-087 | 오프라인 Undo와 미수신 변경 — 수신 전 전역 최신 상태를 보장하지 않음. 병합 후 일반 수정 우선, 양쪽 이력과 충돌 안내 유지 | FR-015, FR-020 | D-03/09/10 | A/SYS | not_run |

## 5. 게이트·완료 추적

| 게이트 | 연결 QA와 추가 과제 | 필요 증거 | 현재 결과 |
|---|---|---|---|
| G-WIDGET | Q-015/016/035~043/046/047/075/076/086; 중형·대형 30개 연속·두 위젯·앱 종료·자정 | 실제 기기 taskID/receipt 결과·저장/표시 p95·뒤로/기타/Undo·범위 차이 기록 | not_run |
| G-SYNC | Q-049~064/087; offline 2기기·extension·Crash·계정·중복 | 실제 동일 원본 집합·투영 비교·충돌 이력·계정 분리·데이터 유실 없음 | not_run |
| G-DELETE | Q-061/081/084/085; offline 복귀·재설치·이전 export | 실제 purge/epoch authority·writer/importer 차단·자동 부활 없음·명시 복원 구분 | not_run |
| G-UX | Q-013/014/019/023/025~028/075 및 H-01~07 | 동의한 사용자 과제·인터뷰·복귀·Today 의도·주만 의미·재등장 신뢰·능동 시간 | not_run |

범위는 FR 30개, NFR 12개, Q 87개, D 16단계, 게이트 4개다. 원본 QA ID를 삭제하거나 새 테스트를 기존 수용 결과로 가장하지 않는다. D별 선행 조건·산출물·외부 결정·출시 차단 규칙은 [전체 구현 계획](IMPLEMENTATION_PLAN.md)에 있다. 다음 구현마다 해당 FR/Q의 production/test 경로와 run 증거를 추가하며, 필요 경로의 결과가 모두 있어야 전체 `pass`로 바꾼다.
