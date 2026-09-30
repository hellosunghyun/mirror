# 04. 데이터 모델과 명령 계약

버전 0.1 / 권고 아키텍처 계약  
관련: [도메인 규칙](03_DOMAIN_AND_REVIEW_RULES.md), [저장과 동기화](05_ARCHITECTURE_AND_SYNC.md)

## 1. 설계 선택

작업의 현재 상태와 변경 이력을 분리한다. 기기 간에는 변경 명령의 불변 기록을 동기화하고, 화면은 그 기록에서 만든 로컬 투영을 읽는다. 이 방식은 Apple이 특정 앱에 요구하는 구조가 아니라, 이 제품에서 되돌리기, 오프라인 충돌, 위젯 중복 탭을 같은 모델로 다루기 위한 권고안이다.

범용 이벤트 소싱 플랫폼을 만들지 않는다. 하나의 `OperationRecord`, 작업별 순수 리듀서, 로컬 조회 모델로 제한한다. Kafka, 별도 이벤트 서버, CRDT 라이브러리, 자체 클라우드 API는 사용하지 않는다. 이 선택의 비용과 검증 게이트는 09 문서의 ADR-004에 있다.

## 2. 논리 모델

```text
OperationRecord (동기화되는 원본)
  ├ task mutations
  ├ review decisions / cycle closure
  └ settings mutations
            ↓ deterministic reducer
TaskProjection             ReviewAcknowledgment
  ├ content                ReviewCycleProjection
  ├ plan                   SettingsProjection
  ├ status
  ├ deadline
  └ versions / conflicts

기기 로컬만 유지
ReviewSession / ReviewCard / CommandReceipt
WidgetPresentation / CalendarCache / NotificationLedger
ProjectionCheckpoint / Diagnostics
```

실제 마감과 계획은 서로 다른 필드 묶음이다. 필드별 동시 수정의 의미를 보존하기 위해 content / plan / status / deadline을 독립적인 변경 그룹으로 취급한다.

## 3. TaskProjection

| 필드 | 형식 | 의미 / 제약 |
|---|---|---|
| taskID | UUID string | 작업 식별자. 플랫폼별로 다시 만들지 않음 |
| workspaceKey | string | R1 개인 공간 키. 계정별 물리 저장소와 함께 사용 |
| workspaceEpoch | stable string | 전체 초기화 전후 데이터를 구분하는 세대. 기기별 무작위 생성 금지 |
| title | string | 공백 제거 후 1~500 확장 문자소 |
| note | string? | 최대 20,000 확장 문자소. 별도 렌더링 실행 금지 |
| sourceURL | string? | 원문 URL. 표시와 열기에만 사용 |
| status | open / completed / deleted | 실행 / 삭제 상태. 계획과 독립 |
| plan | PlanTarget | unassigned / day / week / parked |
| reviewNotBefore | LocalDate? | 다음 자동 검토가 가능한 날짜 |
| deadline | Deadline? | 실제 마감. 별도 그룹 |
| createdAt | UTC timestamp | 최초 입력 기록 시각 |
| completedAt | UTC timestamp? | status가 completed인 경우 결과 시각 |
| deletedAt | UTC timestamp? | 삭제 이력의 표시 시각 |
| versions | map<Group, VersionStamp> | 각 필드 그룹의 현재 인과 버전 |
| conflictGroups | set<Group> | 아직 동시 변경이 남은 그룹 |
| isProjectionComplete | bool | 필요한 원본 / 부모 변경을 모두 받았는지 |

PlanTarget의 JSON 계약은 `contracts/plan-target.schema.json`에 있다. 날짜 문자열 정규식 통과가 실제 달력 날짜의 유효성을 보장하지 않는다. 2월 30일, 잘못된 주 범위는 도메인 검증에서 거부한다.

## 4. Deadline

```text
Deadline =
  day(localDate, timeZoneID)
  instant(utcTimestamp, displayTimeZoneID)
```

날짜 마감은 시간을 임의로 09:00이나 23:59로 저장하지 않는다. 지났는지 판단할 때 해당 시간대의 다음 날짜 시작을 경계로 계산한다. 알림 시각은 별도 사용자 설정이다. 시각 마감은 UTC instant가 기준이며 표시에 사용한 시간대를 보존한다.

계획 시간대를 바꾸어도 Deadline을 자동 변환하지 않는다. 선택 날짜와 시각 마감 비교 시에는 그 시각을 현재 계획 시간대의 날짜로 환산한다. 원래 시간대 표시는 상세에 남긴다.

## 5. 변경 그룹

| 그룹 | 원자적으로 변경할 값 | 분리 이유 |
|---|---|---|
| content | title / note / sourceURL | 제목 수정이 계획을 덮어쓰지 않도록 함 |
| plan | target / reviewNotBefore | 날짜와 재검토 시점의 의미를 함께 유지 |
| status | status / completedAt / deletedAt / restoreReference | 완료와 삭제의 독립적인 생명주기 |
| deadline | deadline value | 날짜 미루기로 실제 마감이 바뀌지 않도록 함 |

초기 생성은 같은 OperationRecord 안에 네 그룹의 초기값을 모두 포함한다. 다중 선택은 최대 20개 작업의 plan 변경을 한 기록에 넣는다. 이 20개 상한은 제품의 검증 / UI 상한이며 CloudKit의 공식 한도라는 뜻이 아니다.

## 6. OperationRecord

| 필드 | 형식 | 규칙 |
|---|---|---|
| operationID | stable string | 논리적 중복 제거 키 |
| schemaVersion | integer | 현재 1. 알 수 없는 버전은 원본 보존 후 격리 |
| workspaceKey | string | 개인 공간 식별 |
| workspaceEpoch | stable string | 현재 공간 세대. 구세대 기록을 조용히 재수입하지 않음 |
| deviceID | random UUID | 설치별 논리 ID. 분석 서버로 보내지 않음 |
| lamport | Int64 | 인과 순서용 증가 수. 시각의 대체값이 아님 |
| recordedAt | UTC timestamp | 이력 표시용. 충돌 승자를 정하는 유일 기준 아님 |
| commandKind | enum | capture / setPlan / setStatus / setDeadline / editContent / undo / reviewClose / settings |
| mutations | array | taskID, group, value, observedHeadIDs |
| reviewContext | object? | cycleID, sessionID, cardID, 결정 결과 |
| compensatesOperationID | string? | 되돌리기가 보상하는 원본 |
| payloadDigest | SHA-256 | 같은 ID의 서로 다른 내용 검출 |

공개 명령과 원본 commandKind는 일대일일 필요가 없다. ParkTask는 setPlan, TrashTask / RestoreTask는 setStatus, BatchSetPlan은 여러 mutation을 가진 setPlan으로 정규화한다. 원래 source command 이름은 진단용 메타데이터로 구분할 수 있지만 리듀서 의미를 중복 구현하지 않는다.

record는 저장 후 내용 수정 금지다. 잘못된 기록을 지우고 덮어쓰기보다 보상 명령을 추가한다. 명시적 개인정보 영구 삭제는 예외이며 07의 별도 워크플로를 따른다.

CloudKit 호환 원본 엔티티는 UUID / string / integer / timestamp / binary JSON 등 단순 필드만 사용하고 필드 기본값 또는 optional을 명시한다. unique constraint에 의존하지 않으며 논리 operationID로 중복 제거한다. Core Data CloudKit의 unique constraint / 관계 제약은 공식 문서 A07에 근거한다.

## 7. VersionStamp와 동시 변경

각 그룹은 하나 이상의 현재 head operation을 가질 수 있다. 새 로컬 변경은 관측한 모든 head를 `observedHeadIDs`로 기록한다. 동기화에서 서로를 보지 못한 두 변경은 동시 head로 남는다.

```text
VersionStamp:
  winningOperationID
  headsDigest = SHA256(sort(currentHeadIDs))
```

예시의 expectedVersions에 넣는 stamp 문자열은 headsDigest의 직렬화 값이다. 실제 구현에서는 taskID / group별 head 집합에 대해 digest를 만든다. winningOperationID는 표시와 리듀서의 선택 결과이며 검증값을 대신하지 않는다.

로컬 명령의 낙관적 검증은 winningOperationID만이 아니라 headsDigest로 한다. 숨은 동시 변경이 있는데 같은 승자만 보고 덮어쓰는 일을 줄인다.

인과적으로 후속인 변경은 선행 변경을 대체한다. 서로 독립적인 head는 `(lamport, deviceID, operationID)`의 사전 정의된 정렬로 같은 결과를 선택한다. 이 규칙은 모든 기기의 수렴을 위한 것이며, 현실 시간상 가장 나중의 사용자 선택을 완벽히 알아낸다는 뜻이 아니다. 패배한 변경은 이력에 남고 충돌 상태를 표시한다.

동시 head 중 보상 Undo와 일반적인 새 사용자 수정이 충돌하면 해당 그룹의 일반 수정을 우선한다. Undo가 그 새 수정까지 실제로 관측한 인과적 후속 명령인 경우에는 이 규칙의 대상이 아니다. 오프라인에서 아직 도착하지 않은 수정을 미리 검증할 수 없으므로, 로컬 Undo 결과가 동기화 뒤 바뀌면 충돌 안내와 양쪽 이력을 제공한다.

status에는 안전 우선 규칙을 더한다. 서로 인과적으로 해결되지 않은 head 중 deleted가 있으면 삭제 상태, 그다음 completed, 마지막 open을 선택한다. 명시적 복구 / 완료 취소가 관련 head 전체를 관측한 후속 명령이면 정상적으로 open이 될 수 있다. 오래된 reopen이 보지 못한 삭제를 이길 수 없다.

## 8. 명령 공통 봉투

아래는 자체 애플리케이션 명령 계약이다. REST 서버나 Apple API 형식이 아니다.

```json
{
  "contractVersion": 1,
  "requestID": "example-request-001",
  "idempotencyKey": "example-decision-001",
  "kind": "setPlan",
  "source": "widget",
  "context": {
    "planningDay": "2026-09-30",
    "timeZoneID": "Asia/Seoul",
    "policyRevision": "policy-example-v1"
  },
  "taskID": "11111111-1111-4111-8111-111111111111",
  "workspaceEpoch": "epoch-example-1",
  "expectedVersions": {
    "content": "content-stamp-1",
    "plan": "plan-stamp-1",
    "status": "status-stamp-1",
    "deadline": "deadline-stamp-1"
  },
  "payload": {
    "target": {"kind": "day", "date": "2026-10-01"}
  }
}
```

기계 검증용 파일은 `contracts/command-envelope.schema.json`이다. JSON Schema는 봉투 형식만 검증하고, 명령별 필수 payload와 VersionStamp, 마감 확인은 도메인 계층이 검증한다.

## 9. 명령별 계약

| 명령 | 입력 | 사전조건 | 결과 / 부작용 |
|---|---|---|---|
| CaptureTask | 제목, 메모?, URL?, 요청 키 | 제목 유효 | 새 ID, unassigned / open, 로컬 저장 |
| SetPlan | taskID, target, 기대 버전, 결정 키 | open, 유효 날짜, 최신 카드, 마감 확인 | plan만 변경, 검토 acknowledgment |
| SetTaskCompletion | taskID, desiredCompleted, 기대 status | deleted 아님 | 원하는 상태 설정. 단순 반전 금지 |
| SetDeadline | taskID, Deadline? | 명시적 사용자 입력 | deadline만 변경, 알림 재계산 |
| EditContent | taskID, content, 기대 버전 | 대상 존재, 크기 제한 | content만 변경 |
| ParkTask | taskID, 기대 plan/status | open | plan=parked |
| TrashTask | taskID, 기대 status | 삭제 미완료 | deleted, 알림 제거 |
| RestoreTask | taskID, delete head 목록 | 최신 삭제를 관측 | status 복구, 기존 계획 유지 |
| UndoOperation | 원본 operationID, 기대 영향 그룹 버전 | 영향 그룹이 원본 결과 그대로 | 보상 명령 생성 |
| CloseReviewCycle | cycleID, sessionID | 현재 주기 | 자동 정리 종료 상태, 미검토 유지 |
| BatchSetPlan | 최대 20개 taskID/버전, target | 전체 사전조건 성공 | 하나의 기록으로 전부 적용 |

조회 명령은 투영만 읽으며, 읽었다는 이유로 계획이나 검토 완료를 바꾸지 않는다. 위젯 패널 열기 / 뒤로 가기는 로컬 PresentationCommand이며 Task 명령이 아니다.

## 10. 결과 형식

```text
CommandResult
  requestID
  operationID?
  state:
    locallyCommitted
    alreadyApplied
    requiresConfirmation
    staleSnapshot
    staleContext
    alreadyDecided
    notFound
    unavailable
    persistenceFailed
    committedProjectionPending
  taskVersion?
  destinationSummary?
  nextNavigation?
  safeUserMessage
```

`locallyCommitted`는 클라우드까지 반영되었다는 뜻이 아니다. `committedProjectionPending`은 원본 저장은 성공했으나 화면용 데이터 반영이 아직 안 끝난 상태다. 이 경우 새로운 요청 키로 재생성하지 않는다.

## 11. 멱등성과 카드 입력

각 결정 카드는 `decisionToken` 하나를 가진다. 오늘, 내일, 주의 날짜, 기타 최종 선택은 모두 같은 토큰을 공유한다. 첫 저장이 성공한 뒤 같은 토큰의 재시도는 원래 결과를 반환한다. 다른 날짜로 다시 누르면 `alreadyDecided`를 반환하고 원래 결과를 유지한다.

의도적으로 다른 날로 바꾸려면 새 카드 / 명시적 편집 흐름과 새 토큰이 필요하다. 패널 변경이나 단순 위젯 재로드만으로 새 토큰을 발급하면 중복 방지가 깨지므로 금지한다.

`requestID`는 개별 호출 추적용이고 `idempotencyKey`는 논리적 사용자 결정의 중복 제거용이다. 의미를 합치지 않는다. 일반 CaptureTask의 새 사용자 입력은 새 키를 만든다. 단축어가 같은 텍스트를 새로 실행하는 것을 제목 일치만으로 중복 제거하면 안 된다.

원본 기록의 operationID는 결정 키와 명령 범위를 일관된 방식으로 매핑한다. 원본과 투영 사이에 앱이 종료되어도 같은 키를 원본에서 조회해 기존 결과를 복구한다. 영수증 캐시에만 의존하지 않는다.

## 12. 조건부 되돌리기

되돌리기는 데이터베이스 전체 롤백이 아니다. 원본 작업의 영향 그룹별 이전 값을 보상 명령으로 기록한다.

예: plan을 금요일로 옮긴 뒤 제목이 바뀌었다. plan이 여전히 원본 결정 결과라면 날짜만 되돌릴 수 있고 새 제목은 유지한다. 반대로 다른 기기에서 plan을 다음 주로 바꿨다면 이전 plan을 자동 복원하지 않는다.

이미 수신한 후속 변경은 Undo 실행 전에 거부한다. 아직 수신하지 못한 오프라인 변경은 즉시 알 수 없으므로 실행 시점의 전역 최신 상태를 보장하지 않는다. 이후 동기화에서는 7절의 일반 수정 우선 규칙으로 사용자의 새 결정을 보존한다.

다중 배치 되돌리기는 모든 영향 작업이 아직 같은 버전일 때만 한 번에 처리한다. 하나라도 바뀌면 전체 되돌리기를 중단하고 충돌 작업과 개별 수정 경로를 제공한다. 부분 성공을 전체 성공으로 표시하지 않는다.

## 13. 로컬 세션 모델

| 모델 | 핵심 필드 | 동기화 |
|---|---|---|
| ReviewSession | sessionID, cycleID, mode, queue taskIDs, cursor, status | 하지 않음 |
| ReviewCard | cardID, taskID, expectedVersions, decisionToken, context | 하지 않음 |
| ReviewAcknowledgment | cycleID, taskID, planVersion, decisionOperationID | 원본 operation에서 재구성 |
| ReviewCycleProjection | cycleID, closed, closeOperationID, weeklyCoverageStartDate? | 원본 operation에서 재구성 |
| WidgetPresentation | scopeKey, sessionID, cardID, panel, anchorDay, expiry | 같은 기기만 |
| CommandReceipt | key, digest, operationID, result | 로컬 캐시. 원본으로 복구 가능 |

`scopeKey`는 앱이 정의한 설정 범위다. WidgetKit이 위젯 인스턴스별 영구 UUID를 자동으로 제공한다고 가정하지 않는다. R1의 동일 설정 정리 위젯은 같은 기기의 `review-default` 흐름을 공유한다.

## 14. 내보내기 계약

권고 형식은 UTF-8 JSON이다. `formatVersion`, `exportedAt`, `workspaceKey`, `workspaceEpoch`, `planningPolicy`, `operations`, `currentTasks`를 포함한다. 복원 원본은 operations이고 currentTasks는 사람과 외부 도구를 위한 조회용 스냅샷이다. 원본이 없거나 모르는 버전이면 현재 스냅샷을 임의로 신뢰해 덮어쓰지 않는다.

동일 operationID / 같은 digest는 중복 제거한다. 동일 ID / 다른 digest는 손상 또는 계약 위반으로 격리한다. 기존 작업을 제목 일치로 합치지 않는다. 전체 교체와 병합은 별도 선택이며 병합이 기본이다.

## 15. 후속 확장용 경계

FocusSession, TimeBlock, RecurrenceTemplate은 R1 저장 테이블에 빈 필드를 대량으로 미리 추가하지 않는다. 향후 별도 엔티티를 정의한다. TimeBlock을 붙여도 PlanTarget.day가 실제 마감으로 바뀌지 않는다. 반복은 회차별 작업 ID와 템플릿을 나누는 별도 ADR이 필요하다.
