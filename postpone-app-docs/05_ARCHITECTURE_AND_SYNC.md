# 05. 기술 아키텍처와 동기화

버전 0.1 / 권고 구현안. 실제 Xcode 프로젝트와 빌드는 아직 없다.  
관련: [명령 계약](04_DATA_AND_COMMAND_CONTRACTS.md), [Apple 근거](10_SOURCES_AND_COMPATIBILITY.md)

## 1. 기술 선택

| 계층 | 권고 선택 | 이유 |
|---|---|---|
| UI | SwiftUI, 필요한 Mac 경계만 AppKit | Apple 기기별 네이티브 상호작용 |
| 언어 / 동시성 | Swift, 구조적 동시성, 명시적 actor 경계 | UI와 도메인 분리, 동시 접근 제어 |
| 도메인 | Foundation 기반 별도 Swift Package | 날짜와 상태를 플랫폼 UI 없이 테스트 |
| 저장 | Core Data, SQLite persistent store | 프로세스 간 저장, 이력 소비, 마이그레이션 |
| 기기 간 동기화 | NSPersistentCloudKitContainer | Apple 공식 미러링 경로 이용 |
| 원본 | immutable OperationRecord | 명령 중복, 오프라인 충돌, 되돌리기 추적 |
| 조회 | 로컬 TaskProjection / ReviewProjection | 빠른 리스트와 위젯 조회 |
| 시스템 행동 | App Intents | 앱 밖에서 같은 명령 실행 |
| 위젯 | WidgetKit / SwiftUI | 정리 카드와 오늘 목록 |
| 캘린더 | EventKit adapter | 선택한 기존 약속을 읽어 날짜 선택 보조 |
| 알림 | UserNotifications | 정리 / 실제 마감 알림 구분 |
| 로그 | OSLog, 민감 값 제외 | 외부 분석 SDK 없이 진단 |
| 테스트 | XCTest 또는 프로젝트 표준 Swift Testing + UI tests | 도메인 / 영속화 / 시스템 통합 분리 |

Core Data의 로컬 저장 / CloudKit 미러링은 A05, A06, 변경 이력은 A08에 근거한다. 특정 패턴이 가장 빠르다고 실측한 것은 아니다. SQLite를 별도로 직접 수정하지 않고 모든 Core Data 저장 접근은 공식 API를 통한다.

SwiftData와 직접 CKSyncEngine 조합을 동시에 도입하지 않는다. 기술 범위를 늘리지 않기 위해 Core Data 하나를 선택한 것이다. 자동 미러링이 제품 충돌 정책까지 알아서 제공한다고 가정하지 않는다.

## 2. 권고 타깃과 모듈

```text
Postpone.xcodeproj
  Apps/iOS/                  iPhone + iPad
  Apps/macOS/                Mac 네이티브 앱
  Extensions/iOSWidgets/
  Extensions/macOSWidgets/
  Extensions/Share/
  Packages/PostponeDomain/
  Packages/PostponeData/
  Packages/PostponeSystem/
  Packages/PostponeDesign/
  Tests/DomainTests/
  Tests/PersistenceTests/
  Tests/IntegrationTests/
  Tests/UITests/
```

| 모듈 | 책임 | 금지 의존성 |
|---|---|---|
| Domain | PlanTarget, 날짜 정책, 큐 규칙, validation, reducer | SwiftUI / WidgetKit / EventKit 직접 의존 |
| Data | Core Data, 원본 기록, 투영, 영수증, migration | 화면 탐색과 UI 정책 |
| System | 인텐트 어댑터, 위젯, 캘린더, 알림 | 도메인 규칙 복제 |
| Design | 공통 컴포넌트, 접근성, 표시 형식 | 데이터 저장의 소유권 |
| App | 화면, navigation, composition root | 별도 날짜 / 마감 규칙 구현 |

앱과 확장에 공유하는 코드는 extension-safe API만 사용한다. UI 전용 AppKit / UIKit 호출은 별도 타깃 경계에 둔다. App Group 데이터 공유와 접근 조율의 근거는 A09다.

## 3. 데이터 흐름

```text
앱 / Widget / Siri / Shortcut / Share
                ↓
        CommandAdapter
                ↓
       CommandService
     validate / idempotency
                ↓
    프로세스 간 쓰기 게이트
                ↓
  OperationRecord 로컬 원본 저장
                ↓
  Task / Review 로컬 투영 갱신
                ↓
  영수증 / Snapshot / UI 업데이트
                ↓
      필요한 위젯 재로드 요청

CloudKit 미러링 ↔ 원본 OperationRecord
새 원본 수신 → Persistent history 소비 → reducer → 투영 → UI
```

CloudKit의 성공 응답을 기다려야 카드가 넘어가는 구조가 아니다. 핵심 경로에 네트워크 요청을 넣지 않는다. EventKit이 늦거나 권한이 없어도 SetPlan은 로컬에서 끝낼 수 있다.

## 4. 영속 저장소 배치

권고는 같은 App Group 디렉터리 안의 두 Core Data 저장소다.

| 저장소 | 구성 | 클라우드 |
|---|---|---|
| Canonical.sqlite | OperationRecord, 최소 계정 / 세대 메타데이터 | 사용자가 활성화한 경우에만 CloudKit 미러링 |
| LocalProjection.sqlite | TaskProjection, Session, Receipt, WidgetPresentation, Cache | 동기화하지 않음 |

두 저장소 사이 Core Data relationship은 만들지 않고 문자열 ID로 연결한다. 두 저장소의 저장을 하나의 원자적 트랜잭션처럼 설명하지 않는다. 원본 저장 후 투영 저장 사이에 종료될 수 있으며, 재시작 시 기록을 재생해 복구한다.

원본 저장 성공 후 투영 실패는 `committedProjectionPending`이다. 원본까지 실패한 경우만 `persistenceFailed`다. 성공 기준을 단계별로 구분해야 같은 작업의 중복 생성과 저장 유실을 줄일 수 있다.

## 5. 기기 내 동시성

앱 actor는 같은 프로세스 안에서만 순서를 보장한다. 앱과 위젯 확장은 별도 프로세스이므로 actor 하나로 전역 중복 쓰기를 막았다고 판단하지 않는다.

권고 쓰기 게이트는 App Group 내 전용 lock 파일에 대한 POSIX advisory lock이다. OS가 프로세스 종료 시 해제하는 메커니즘을 사용한다. 파일 존재 여부만으로 잠금 상태를 판단하지 않는다. Core Data context는 전용 queue에서 사용한다.

게이트 안에서 하는 일은 영수증 / 원본 조회, 현재 버전 확인, 원본 저장, 영향 작업의 투영 갱신, 영수증 저장이다. 네트워크, 사용자 확인, EventKit 긴 조회, 이미지 처리, 전체 원본 재생은 넣지 않는다. 오류 / 취소 시에도 반드시 잠금을 해제한다.

잠금 대기 목표는 250ms 내외의 짧은 재시도이며 실제 수치는 기기 테스트로 정한다. 초과하면 UI를 무한 블로킹하지 않고 “다른 변경을 반영 중” 상태로 재시도한다. main thread를 동기 잠금 대기로 멈추지 않는다.

CloudKit importer는 이 앱 게이트의 참여자가 아니어도 원본의 새 행을 추가할 수 있다. importer가 UI 투영을 직접 수정하지 않게 하고, history 소비와 로컬 명령 투영은 같은 게이트로 직렬화한다. 따라서 importer와 우리 저장 경로가 같은 mutable Task 행을 덮어쓰는 구조를 피한다.

## 6. 원본과 투영 재구축

원본 기록 하나를 여러 번 받아도 operationID와 digest로 논리 중복을 제거한다. schemaVersion / payload 구조 / task 생성 기록 / 부모 참조를 검증한다. 의존 기록이 아직 도착하지 않았으면 데이터 손상으로 즉시 삭제하지 않고 pending 상태로 보존한다.

Task별 관련 기록만 읽어 재생한다. 목록을 그릴 때마다 전체 기록 100,000개를 재생하지 않는다. 이력 token과 로컬 적용 checkpoint를 보관하고, 누락 / 손상 시 해당 작업 또는 전체 캐시를 명시적으로 재구축한다.

Persistent history token은 원본 도메인 이벤트 ID와 다른 개념이다. token은 저장소 변경 소비 위치다. 캐시를 초기화해 token이 무효화되면 원본에서 다시 읽는다. 아직 소비하지 않은 이력을 임의로 제거하지 않는다.

## 7. 기기 간 동기화와 수렴

Core Data CloudKit은 별도 기기의 로컬 저장소 사이에 변경을 미러링한다. 전송 / 수신은 시스템의 비동기 작업이며 즉시 전파를 보장하지 않는다. 이것은 A06의 기술적 전제다.

제품이 추가로 책임질 것은 다음과 같다.

| 경우 | 제품 정책 |
|---|---|
| iPhone에서 제목, Mac에서 날짜 변경 | 독립 그룹을 병합하여 둘 다 보존 |
| 양쪽에서 다른 날짜 선택 | 인과 관계가 없으면 고정된 정렬로 수렴, 양쪽 이력 보존 |
| 한쪽 완료, 다른 쪽 날짜 변경 | 완료 상태 유지. 날짜 변경이 완료를 취소하지 않음 |
| 한쪽 삭제, 다른 쪽 오래된 완료 취소 | 삭제 우선. 오래된 명령으로 부활 금지 |
| 한쪽 되돌리기, 다른 쪽 후속 날짜 변경 | 이미 수신했으면 실행 거부. 오프라인 동시 변경이면 동기화 후 일반 날짜 수정을 우선하고 안내 |
| 같은 operationID 재전송 | 한 번으로 계산 |
| 부모 기록보다 후속 기록이 먼저 옴 | 의존성을 기다리고 재투영 |

Lamport 값은 `max(local, observedRemote) + 1`로 생성한다. 기기 시계가 틀려도 같은 이벤트 집합은 같은 결과를 만든다. 시스템 시간을 수정하여 과거 기록이 사라지는 방식은 쓰지 않는다.

동시 head가 생겼으면 사용자는 상세에서 “기기별로 다른 날짜가 선택됐어요”를 확인하고 원하는 날짜를 새 명령으로 확정할 수 있다. 이 새 명령은 관측한 모든 head를 부모로 연결하여 충돌을 해결한다. 조용히 승자를 정해도 사용자 의도까지 해결되었다고 주장하지 않는다.

## 8. 동기화 활성화와 계정 경계

첫 입력은 iCloud 없이 가능하다. 동기화는 “다른 기기에서도 사용”을 선택할 때 설명하고 활성화하는 것을 권고한다. 자체 이메일 계정을 요구하지 않는다.

R1은 계정별 개인 공간 하나다. 논리 workspaceKey는 `personal-v1`처럼 동일 계정의 기기에서 같아야 한다. 기기마다 무작위 기본 workspace를 만들어 서로의 작업을 숨기지 않는다. 실제 데이터 폴더는 iCloud 계정별로 구분하여 계정 A 데이터가 계정 B로 자동 업로드되지 않도록 한다.

| 상태 | 행동 |
|---|---|
| iCloud 없음 / 비활성 | 로컬 전용 저장 계속 |
| 처음 활성화 | 로컬과 기존 클라우드 자료 병합을 설명하고 확인 |
| 활성화 후 오프라인 | 로컬 성공, 동기화 대기 표시 |
| 용량 / 서비스 오류 | 원본 유지, 원인 표시, 명령을 되돌리지 않음 |
| 계정 변경 | importer와 쓰기 흐름 중지, 계정 식별 재확인, 저장소 전환 |
| 로그아웃 | 기존 원본을 다른 계정 저장소로 자동 이동하지 않음 |
| 계정 B 사용 | 별도 저장소. A 자료 이관은 명시적 export / import만 |

미러링 옵션을 켰다 껐다고 기존 store가 안전하게 다른 계정으로 이전된다고 가정하지 않는다. 활성화 / 비활성화 전환은 작업 큐를 멈추고 저장소 재구성과 migration 절차를 거친다. 작은 샘플로 검증하는 G-SYNC가 R1 출시 선행 조건이다.

## 9. 위젯 데이터

위젯 TimelineProvider는 가능한 한 로컬 투영과 작은 WidgetSnapshot만 읽는다. 원본 전체 로딩, CloudKit 동기화 완료 대기, 외부 모델 호출을 하지 않는다.

```text
WidgetSnapshot
  schemaVersion
  generatedAt
  planningDay / policyRevision
  mode
  scopeKey / sessionID / cardID
  taskID / displayedVersions / decisionToken
  minimalTitle / deadlineSummary / planSummary
  panel / dateOptions
  lastReceipt
  privacyMode
```

파일 Snapshot을 사용하면 임시 파일 작성 후 atomic replace로 교체한다. Snapshot은 source of truth가 아니고 손상되면 투영에서 재생성한다. UserDefaults에는 단순 설정만 넣고 Task 배열 전체를 주 저장소로 쓰지 않는다.

App Intent가 쓰기를 마치면 필요한 timeline 재로드를 요청한다. 예측 가능한 날짜 경계는 미래 timeline entry에 반영하되 OS 실행 시각을 보장하는 타이머처럼 사용하지 않는다. 위젯 예산과 상호작용 갱신은 A01, A02를 참고한다.

## 10. 마이그레이션과 버전 호환

Core Data 모델 버전과 명령 payload 버전은 별도로 관리한다. CloudKit production 스키마의 기존 필드를 임의로 제거 / 변경할 수 있다고 가정하지 않는다. 개발 스키마와 운영 스키마를 분리하고 A07에 따라 배포한다.

모르는 payloadVersion을 받은 구버전은 내용을 버리지 않고 해당 작업을 “새 버전 필요” 상태로 제한한다. 새로운 PlanTarget을 이해하지 못한 구버전이 그 작업을 unassigned로 바꾸어 다시 저장하면 안 된다.

마이그레이션 전 로컬 원본 백업을 만들고, 디스크 부족이나 실패 시 원본을 유지한다. 앱 삭제를 해결 방법으로 안내하기 전에 export 경로를 제공한다. 캐시 삭제는 가능하지만 원본 삭제를 자동 복구 전략으로 삼지 않는다.

## 11. 삭제와 저장소 세대

명시적 영구 삭제는 변경 이력 안에도 제목 / 메모가 남는다는 점을 고려해야 한다. 화면에서 TaskProjection만 지우는 것으로 완료했다고 처리하지 않는다.

`workspaceEpoch` 문자열만 붙인다고 삭제 후 재업로드를 막을 수 있는 것은 아니다. 동일 계정의 기기들이 현재 세대를 확인하는 경로, 세대 전환의 권위 있는 메타데이터, 구세대 importer / writer 중단 순서를 G-DELETE에서 결정해야 한다. 미러링되는 작업 기록과 삭제 후에도 유지할 제어 메타데이터의 경계를 확정하기 전에는 전체 삭제 구현을 완료 처리하지 않는다.

계정 내 전체 삭제는 CloudKit 데이터 제거와 로컬 원본 / 캐시 / 인덱스 / 알림 제거를 함께 다루는 별도 절차다. 삭제 전 offline 기기에서 생성한 구세대 데이터가 다시 올라오는 것을 막기 위해 `workspaceEpoch` 기반 차단을 설계한다. 개인 단일 기기 테스트에서 검증을 생략하고 “완전 삭제”를 보장하지 않는다. 07과 QA의 삭제 게이트를 따른다.

## 12. 개발 환경 고정

구현 시작 시 Xcode 버전, Swift compiler 버전, 배포 대상, SDK, Bundle IDs, App Group ID, CloudKit container, 개발 / 운영 환경을 README에 기록한다. 현재 문서의 가칭 식별자를 실제 서명 설정으로 오인하지 않는다.

예시:

```text
bundle: com.<owner>.<product>
widget: com.<owner>.<product>.widgets
share:  com.<owner>.<product>.share
group:  group.com.<owner>.<product>
cloud:  iCloud.com.<owner>.<product>
```

연속 통합은 도메인 테스트 → 저장소 테스트 → iOS / Mac 빌드 → UI 스모크 테스트 순서다. CloudKit과 Siri / 위젯 실기기 테스트는 별도 자격 증명과 실행 환경이 필요하다. 자동화되지 않은 테스트를 통과로 기록하지 않는다.
