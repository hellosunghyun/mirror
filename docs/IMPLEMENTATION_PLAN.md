# 미러 전체 구현 계획

이 계획의 목표는 원본 명세의 앱을 끝까지 제작하는 것이다. FR-001~FR-030, NFR-001~NFR-012, D-01~D-16, QA 87개와 네 검증 게이트를 모두 유지한다. P1 기능도 구현 범위에 포함한다. 단계는 의존성과 위험을 정리하기 위한 순서이며, 중간 수직 흐름을 최종 제품으로 대체하지 않는다.

이 문서와 [요구사항 추적표](REQUIREMENTS_TRACEABILITY.md)는 파생 개발 문서다. `postpone-app-docs/`와 통합 원본 명세는 수정하지 않는다. 실제 결과는 원본의 미실행 보고서를 덮어쓰지 않고 commit·run·기기별로 추가한다.

## 1. 현재 구현과 완료의 의미

확정 기준은 미러/Mirror, public 저장소, iOS·iPadOS·macOS 27.0, SwiftUI와 SwiftPieces다. 원본의 Postpone 가칭과 이전 최소 OS보다 [개발 기준](../development-baseline.json)과 [README](../README.md)가 우선한다. 식별자 접두사는 `com.baserize`이며 개발 Bundle ID 적용과 Apple 등록·서명 완료는 별개다.

최초 계획의 출발점은 이름을 표시하는 앱 골격과 날짜 도메인이었다. 이는 과거 이력이다. 코드 `74d02286d396c59e860394cdc660d72f5ea6dfa2`와 Simulator 준비를 보완한 `fa783ae`의 [Actions 36747271079](https://github.com/hellosunghyun/mirror/actions/runs/36747271079)에서 SwiftPM·Mac·iPhone·iPad 각각 도메인 테스트 37개가 통과했다. 현재 구현이나 전체 수용 결과를 이 초기 실행으로 대신하지 않는다.

현재 저장소에는 앱 기능과 공통 명령·실제 영속 저장·시스템 어댑터·확장이 있다. [Package.swift](../Package.swift)의 라이브러리는 `MirrorDomain`, `MirrorData`, `MirrorSystem`, `MirrorDesign` 4개이며 단위·통합 테스트 bundle은 `MirrorDomainTests`, `MirrorDataTests`, `MirrorSystemTests` 3개다. `MirrorIOS`와 `MirrorMac` 앱에 플랫폼별 Widget/Share 타깃이 있고, `MirrorIOSUI`와 `MirrorMacUI` scheme은 같은 UI 시나리오 6개를 실행하도록 구성되어 있다.

| 생산 코드 | 현재 구현 | 남은 수용 조건 |
|---|---|---|
| Domain | 날짜/context·Today/Review·마감 확인, 명령 봉투·그룹별 head digest, 불변 OperationRecord, 결정적 reducer·충돌·pending/격리, 최대 20개 배치와 조건부 Undo | 전체 FR/QA 시나리오와 표면별 같은 의미를 확인. 순수 테스트만으로 실기기·저장·동기화 수용을 대체하지 않음 |
| Data | 실제 Core Data Canonical/LocalProjection SQLite, 프로세스 advisory lock, 원본 우선 저장·receipt 복구, persistent history와 변경 스트림, export/import·명시적 로컬 교체·종료 경계 복구, writer 중지와 기기 로컬 삭제 | 독립 프로세스 강제 종료, protected data, 실제 계정/확장 공유, 배포용 migration과 장기 이력 안전성 검증 |
| App/Design | 입력·Today·일정·정리/주 패널·보관함 검색·상세/편집·완료/휴지통·Undo·설정, iPad/Mac 탐색·키보드/배치, SwiftPieces 3개 컴포넌트와 라이선스·출처 보존 | 6개 UI smoke의 실제 실행 결과, 접근성·가장 큰 글자·좁은 창·키보드·원문 입력·오류 상태 수용 |
| System/확장 | 공통 composition root와 App Intents/Shortcuts, Widget 카드·패널·token·snapshot, Share 텍스트/URL, EventKit 읽기·알림 계획/취소·Spotlight·동의한 로컬 진단 | 실제 App Group/서명, 앱 미실행·잠금·위젯/Siri/Share·권한 철회와 OS 실행 정책 검증 |
| Cloud opt-in | 실제 CKContainer 계정 확인·fingerprint별 공간, 최신 로컬 원본 병합 확인, 공유 active pointer와 오프라인 identity 바인딩, 계정 변경 writer/importer 중지, 원본만 NSPersistentCloudKitContainer로 미러링, 상태 스트림 | Apple container/group 설정과 2기기 G-SYNC. 전체 CloudKit 삭제는 권위 있는 epoch와 구세대 업로드 차단 미결정으로 blocked |

최근 완료된 통합 체크포인트는 `2da19a9`의 [Actions 36817569714](https://github.com/hellosunghyun/mirror/actions/runs/36817569714)다. 준비 Python 40개, SwiftPM 151개, Mac 단위 151개와 iPhone/iPad 각각 150개, 세 플랫폼 UI 각각 여섯 사례가 실제 최종 집계와 필수 bundle/method 검사에서 통과했다. UI 실패·skip은 0개다. archive는 프로파일과 개인 키가 있는 인증서의 일치 검사에서 실패했으며 IPA·Release는 없다. 후속 `f091e83`의 서명 사전 검사에서는 유효한 개인 키 identity 1개와 프로파일 인증서 1개가 서로 일치하지 않는 것을 확인했다. 현재 P12와 같은 인증서로 만든 Ad Hoc 프로파일 Secret 갱신이 필요하다. 비밀번호나 원문 서명 자료는 재요청하지 않는다.

2026-10-01 전체 명세 대조에서 위젯 단일 입력 후 Today 전환, 상태 조건을 적용하기 전 검색 결과 제한, 복원 후 투영 갱신 실패의 완료 표시, 복원 미리보기의 새 작업·격리 기록 건수, foreground 캘린더 권한 철회, Mac 검색 포커스, 명시 일간·주간 정리 딥링크의 모드, 넓은 iPad의 인접 일정 표시를 보완한다. 별도 Swift 프로세스 두 개의 동일 명령 경쟁과 원본 저장 직후 SIGKILL·재시작 회귀도 추가한다. 자체 백업의 임의 32MiB 복원 상한과 위젯 주간 패널의 절대 범위 표시도 보완하며, 1만 작업·10만 원본의 Release 성능 및 전체 백업 왕복 baseline을 별도 Actions에 연결한다. 이 변경의 통과는 새 커밋의 실제 Actions 결과가 나올 때 기록하며 이전 체크포인트로 대신하지 않는다. 최신 확정 근거는 [Swift 개발 안내](SWIFT_DEVELOPMENT.md)와 [테스트 전략](../TESTING.md)에 commit/run별로 추가한다.

fixture 36개는 매개변수 사례이며 SwiftPM 실행 수, 세 플랫폼에서 같은 테스트를 실행한 수, QA 87개 전체 시나리오를 서로 합산하지 않는다.

| 상태 | 의미 |
|---|---|
| 계획 | 산출물·수용 기준은 정해졌으나 생산 코드가 없음 |
| 부분 구현 | 일부 코드가 있으며 요구사항 전체의 완료 조건이 남음 |
| 구현·단위 검증 | 생산 코드의 단위 결과가 있지만 앱/시스템 수용 결과는 남음 |
| 통합 검증 | 실제 선택 저장소·앱·확장을 해당 실행 환경에서 검사 |
| 수용 완료 | FR·QA·NFR와 필요한 실기기/사용자 게이트의 근거가 있음 |
| blocked / not_run | 필요한 결정·환경이 없거나 실행하지 않음. 성공으로 표현하지 않음 |

D-01~D-15의 여러 생산 경로와 D-16의 로컬 계측 코드가 구현되어 있다. 단계별 전체 수용은 별개이며 현재 SwiftPM 증거만으로 QA 87개, NFR 12개 또는 네 게이트를 완료 처리하지 않는다. D-03 이후가 모두 미구현이라는 초기 상태는 더 이상 현재 상태가 아니다. 실제 등록·서명, 추가 UI·독립 프로세스 회귀, 두 기기·사용자 검증과 전체 CloudKit 삭제는 남은 조건으로 유지한다.

## 2. 명세를 구현으로 옮기는 기준

| 원본 문서 | 구현에서 유지할 내용 | 주 담당 단계 |
|---|---|---|
| 01 제품 요구사항 | FR 30개, NFR 12개, 입력/정리/실행/복귀 흐름, 비목표 | 전체, D-16 |
| 02 UX와 화면 | J-01~05, S-01~12, 5개 목적지, 저장/오류/빈 상태, 플랫폼 탐색 | D-06/08/09/11/14 |
| 03 도메인 | INV-01~20, 계획 시간대·주, Today, 일간/주간 큐·재등장 | D-02/03/05/09 |
| 04 데이터와 명령 | 엔티티, 그룹별 버전, 불변 기록, 명령 11종, 멱등성·Undo·복원 | D-03/04/05/09/10/13 |
| 05 아키텍처와 동기화 | 원본/투영 분리, process gate, history, 계정·세대, 복구 | D-04/05/10/11/13 |
| 06 인텐트와 위젯 | AI-01~13, App Shortcuts 6종, state machine·토큰·딥링크 | D-05/07/08/15 |
| 07 캘린더·알림·개인정보 | 선택 권한, 외부 일정 읽기, 예약/취소, 보호·export·삭제 | D-12/13/14 |
| 08 QA | Q-001~087, 속성 검사, 표면 행렬, 장애 주입, 출시 차단 | 전체 검증 |
| 09 구현·결정 | D-01~16, ADR, G-WIDGET/G-SYNC/G-DELETE/G-UX | 이 계획 전체 |
| 10 근거·호환성 | A01~19, 실제 SDK availability, 표면별 지원과 fallback | D-01/07/08/10/12/13/15 |
| 11 제품 검증 | H-01~07, 로컬 계측·동의, 5~8명 과제와 후속 관찰 | D-06부터 D-16 병행 |

상태 의미는 03, 명령/버전/원본 계약은 04를 기준으로 충돌을 해결한다. UI, App Intent, Widget, Share, Mac은 같은 명령 서비스를 호출한다. 상대 목적지는 표시 당시 context의 절대 목적지로 변환하며 전역 현재 작업을 다시 조회해 바꾸지 않는다. 원본 저장 전에 성공 표시나 다음 카드 진행을 하지 않는다.

## 3. 단계와 선행 조건

핵심 순서는 D-01 → D-02 → D-03 → D-04 → D-05 → D-06 → D-07 → D-08이다. D-09는 D-06 이후, D-10은 D-04/05 이후 병행하여 동기화를 늦추지 않는다. D-11은 D-06~10의 공통 규칙 위에서 완성한다. D-12/13/14는 앞선 결과를 사용하며 D-15는 D-07 후, D-16은 D-06부터 병행한다.

아래 표는 최초 계획부터 유지한 목표 산출물·의존성·최종 완료 증거다. 현재의 미구현 목록이나 통과표가 아니다. 이미 있는 생산 코드는 1절과 요구사항 추적표에서 확인하며, 각 단계의 남은 통합·실기기·사용자 조건을 계속 검사한다.

| 단계 | 생산 산출물과 남은 작업 | 선행 조건 | 완료 증거 |
|---|---|---|---|
| D-01 기준·타깃 | 현재 앱/도메인 타깃 유지; extension-safe Data/System/Design 경계, 위젯/Share/통합/UI 테스트 타깃; ID·Team·capability·개발/운영 값 기록 | 현재 골격; 등록 값은 결정 D-CAPABILITY | OS 27 세 플랫폼 빌드, 확장 metadata, 실제 공유 컨테이너·서명 확인. unsigned 결과와 분리 |
| D-02 날짜 | 기존 LocalDate/context/주 범위 보존; 작업·명령과 연결할 날짜/마감 경계 계약 보강 | D-01 | 원본 F-001~036와 윤년·연말·DST·자정·시간대 회귀가 생산 API에서 통과 |
| D-03 명령·리듀서 | 아래 명령/모델 전부; 모든 head 기반 버전·validation; 결정적 투영·충돌·pending | D-02 | INV-01~20의 자동화 가능한 부분, 그룹 독립성, 기록 순열/중복/부모 지연, Undo 충돌 단위 결과 |
| D-04 영속화·복구 | 선택 저장 기술의 canonical/projection, 실제 SQLite, checkpoint/history, receipt 재구성·migration 백업 | D-03, 저장 결정 D-STORE | 실제 영속 store의 재시작·손상·종료 경계 복구; 정상 반환 입력 유실·중복 0건 |
| D-05 프로세스 안전 | 앱/확장 공통 gate, durable receipt 조회 우선, ReviewSession/Card/Presentation, snapshot atomic replace | D-04 | 두 독립 프로세스·동일 토큰·상이 목적지·저장 실패·잠금 timeout·취소에서 대상 고정 및 한 번 적용 |
| D-06 iPhone 수직 흐름 | S-01~12 기본 탐색, 입력/Today/일정/보관함/상세/설정; 제목·메모·URL·검색; 5개 목적지·SwiftPieces | D-03~05, 실제 UI 방향 기록 | 30개 작업의 입력→정리→Today→완료→재배치; 저장 실패/원문 유지·다음 카드 고정 XCUITest |
| D-07 App Intents·Share | AI-01~13 및 Query/TaskEntity, 대표 Shortcuts 6종, 공유 텍스트/URL, 앱 최초 실행 전 composition root | D-05, 실제 SDK 서명 확인 | 인텐트 metadata 추출, 앱 미실행 쓰기/조회, 한국어·동명 작업·잠금 정책; Share 원문 오프라인 저장 |
| D-08 위젯 | iPhone/iPad 중형·대형, 작은 진입 위젯, Mac 네이티브; review/today state machine, 날짜 패널·뒤로·Undo·기타 | D-06/07, App Group·서명 | Q-035~043/047, 실제 30개 연속 결정, 두 위젯/앱 종료/자정; G-WIDGET |
| D-09 정리 완성·Undo | 일간/주간 단일 cycle, queue 안정성·새 입력 뒤 배치·close/coverage, 중간 종료/재개/오늘 override; 조건부·다중 Undo | D-06, D-03/05 | 미검토 Today 유입 0건, 같은 plan 재질문 없음, 제목 보존·후속 plan 거부; Q-019~034/080/087 관련 증거 |
| D-10 동기화 | 선택 활성화, immutable 기록 미러링, history 소비, 계정별 물리 저장소, 상태/충돌 안내·schema 호환 | D-04/05, D-SYNC·Apple capability | reducer 순열 검증 + 실제 2기기 offline matrix, 계정 전환/용량/부모 지연; G-SYNC |
| D-11 Mac·iPad | 독립 Mac 다중 열/메뉴 막대/Cmd+N/F/Z·키보드 정리; iPad 좁고 넓은 창/키보드; 최대 20개 원자 배치 | D-06~10, 공통 저장·명령 | 네이티브 기기별 입력/정리/완료·UI/키보드, 좁은 창, 드래그 대체, 원격 iPhone 위젯과 별도 검사 |
| D-12 일정·알림 | EventKit 읽기 adapter·선택 캘린더·권한/철회/cache; 일간/주간 중복 제거·28일 예약·마감 별도 설정/취소 | D-09~11 | Q-065~074, 쓰기 호출 0건, 권한 없어도 배치, 날짜·시간대·완료·offline 기기별 예약 검사 |
| D-13 데이터·개인정보 | UTF-8 export/import 미리보기·검증·중복/격리·merge/replace; 휴지통/복구, 이 기기 삭제/공간 전체 삭제·세대; 민감 로그/보호 | D-10, D-DELETE·계정/서명 | 실제 export round trip, 다른 계정·미지원 버전·악성 링크, 구세대 offline 복귀/재설치; G-DELETE |
| D-14 품질·출시 준비 | 한국어/localization, VoiceOver/VoiceControl/큰 글자·대비·Reduce Motion/Transparency; 성능·배터리·privacy manifest·license | D-08~13 | Q-075~086 + 전체 P0 및 이번 목표의 P1, NFR 실측, 공개 배포 조건·서명 archive; 승인 전 배포하지 않음 |
| D-15 최신 표면 | Mac Spotlight parameterSummary·노출 선택/인덱스 제거, ControlWidget·액션 버튼/잠금 표면, availability·앱/단축어 대체 | D-07, Xcode 27 실제 SDK | 플랫폼별 compile/metadata + 실제 실행/인증/한국어, 미지원 표면의 fallback. 스니펫은 후속 명세 |
| D-16 사용자 검증 | H-01~07, 허용 로컬 계측, 연구 요약 export·보존/삭제, 과제와 인터뷰 기록 | D-06부터 병행, 참여·공유 동의 | 실제 동의한 사용자 과제·관찰로 G-UX; 3분 강제 종료나 위젯 span을 능동 시간으로 조작하지 않음 |

### D-03의 명령·모델 체크리스트

- `TaskProjection`: workspace/epoch, content, plan, status, deadline, UTC 표시 시각, 그룹별 version/head/conflict, projection complete를 계약대로 정의한다.
- `OperationRecord`: schemaVersion, stable operationID, SHA-256 digest, device/Lamport, mutations/observedHeadIDs, reviewContext, compensation을 보존한다. 같은 ID·다른 payload와 미지원 schema는 격리한다.
- `CaptureTask`, `SetPlan`, `SetTaskCompletion`, `SetDeadline`, `EditContent`, `ParkTask`, `TrashTask`, `RestoreTask`, `UndoOperation`, `CloseReviewCycle`, `BatchSetPlan`을 구현한다. 완료는 반전이 아니라 desired Bool이고 batch 최대 20개는 전체 검증·한 기록이다.
- head 집합 digest로 낙관적 검증하고, 인과 후속/동시 head를 분리한다. 동일 집합은 `(lamport, deviceID, operationID)`로 수렴한다. 동시 status는 deleted→completed→open, 동시 일반 수정은 Undo보다 우선한다. 패배 이력과 사용자 충돌 안내를 보존한다.
- 결과는 locallyCommitted/alreadyApplied/requiresConfirmation/staleSnapshot/staleContext/alreadyDecided/notFound/unavailable/persistenceFailed/committedProjectionPending를 구별한다. 실제 저장 결과와 안전한 한국어 문구를 함께 연결한다.
- `requestID`와 논리 결정 키를 구별한다. receipt/original 재조회가 context 검사보다 먼저이고, 같은 카드의 모든 목적지는 같은 token이다. UI 상태 변경, 화면 조회, 패널 열기/닫기는 작업 mutation이 아니다.

### D-04~05의 복구·동시성 체크리스트

첫 구현은 D-STORE에 기록한 원본 권고 Core Data + SQLite를 사용한다. Canonical/LocalProjection은 실제 별도 store이고 문자열 ID로 연결한다. `MirrorStore`의 원본 우선 저장·재시도/receipt 복구·history 재생·로컬 교체/복구와 POSIX gate 코드가 있다. 새 저장 기술로 변경하거나 자동 미러링으로 충돌 계약을 낮춘 사실은 없다. 두 store를 한 원자 트랜잭션으로 표시하지 않는다. 아래 체크리스트의 독립 프로세스·강제 종료·실기기 조건은 코드와 단위 결과만으로 완료 처리하지 않는다.

원본 저장 전 / 원본 후 투영 전 / 투영 후 receipt 전 / receipt 후 snapshot 전 / snapshot 후 reload 전에 독립 프로세스를 종료한다. 재시작·같은 키 재시도에서 입력 유실·중복이 없어야 한다. 원본 성공/투영 실패는 committedProjectionPending으로 표시하며 캐시가 없어도 원본에서 receipt를 복구한다.

같은 기기의 확장과 앱은 process-safe gate에 참여한다. actor만으로 프로세스 안전을 선언하지 않는다. advisory lock, 대기 상한, 취소/종료 해제, Core Data queue 격리와 importer/history 재투영을 검사한다. gate 안에서 네트워크·사용자 확인·전체 replay·긴 EventKit 조회를 수행하지 않는다.

### D-06~15의 화면·시스템 체크리스트

첫 실행은 필수 권한 없이 입력 가능하다. 여러 줄은 한 개/줄마다 선택, title/note의 확장 문자소 상한은 안내하고 자동 잘라내지 않는다. URL은 원문 보존·명시적으로 열기만 하며 자동 수집이나 실행을 하지 않는다.

오늘·일정·보관함·전체 검색·휴지통·완료 기록·상세·설정과 모든 loading/committing/pending/error/stale/empty/permission 상태를 구현한다. 실제 마감은 계획과 별도로 표시한다. 일정의 시간 없는 할 일을 임의 시간 블록으로 바꾸지 않는다. 주만 지정은 독립 바구니이고 다음 주 월요일 자동 Today가 아니다.

SwiftPieces는 지정된 reviewed commit에서 필요한 Swift/Metal 소스만 Design 계층에 도입하고 출처·수정·MIT + Commons Clause 고지를 보존한다. UIKit/햅틱/색 의존성을 Mac에 맞추고 한국어 조합·키보드·접근성·Reduce 설정을 직접 검증한다. 내부 TaskRow 상태를 생산 모델로 쓰지 않는다.

App Intents는 앱 실행 전 초기화, 안정 taskID의 Query, 동명 작업 선택, 명시 인증, entity 반환, 한국어 표기를 포함한다. 위젯은 장기 @State가 아니라 scope/card/panelVersion 바인딩과 저장된 Presentation/timeline을 쓴다. 동일 설정은 같은 scope와 token을 공유한다. 위젯 reload 시각에 정확성을 의존하지 않고 명령에서 context를 검사한다.

## 4. 네 게이트의 실행과 출시 판단

| 게이트 | 선행·실행 | 근거와 수용 기준 | 실패·미실행일 때 |
|---|---|---|---|
| G-WIDGET | D-05~08, 서명된 실제 iPhone/iPad/Mac 표면; 중형/대형 카드 30개 연속, 오늘/내일/주 패널·날짜·뒤로·기타·Undo·두 위젯·강제 종료 | FR-007/009/016/018/030, NFR-001~004/008/009, Q-015/016/035~043/046/047/075/076. 잘못된 대상 변경 0건; local save와 새 카드 표시 p95 별도 측정 | 오류는 수정 후 재실행. 주간/기타 앱 fallback은 기대 UX 차이와 측정치를 기록하고 사용자 확인 없이 조용히 범위를 줄이지 않음 |
| G-SYNC | D-04/05/10, 실제 두 기기·개발용 계정; offline 상충 plan/content/complete/delete/Undo, 재연결·extension·종료·중복·부모 지연·계정 전환 | FR-019/020/030, NFR-001/005/006/011, Q-049~064/087. 동일 원본 집합→동일 projection; 기록 유실·계정 혼합·삭제 부활 0건 | mock/순수 reducer 결과만으로 통과 불가. 실패는 동기화 완료/공개 출시 차단이며 저장 계약을 낮추지 않음 |
| G-DELETE | D-10/13, 권위 있는 epoch 메타데이터·writer/importer 차단 설계와 두 기기; 공간 삭제 후 offline 재연결·재설치·예전 export | FR-020/024/026/030, NFR-001/007/011, Q-061/081/084/085. 구세대 재업로드·자동 부활 없음, 명시 export 복원은 별도 동의 | projection 삭제나 epoch 문자열만으로 완료 처리 불가. 실험 실패/미실행이면 완전 삭제 문구·공개 출시 차단; 대상·추가 조치를 정확히 표시 |
| G-UX | D-06/09/16, 동의받은 사용자 과제·복귀·인터뷰; H-01~07, 20~30개 중 일부 결정·3분 전 종료·다음 날·마감 확인·Undo | FR-004/005/008/011/012/014/015/016, NFR-008/012. 미검토≠Today, 주만≠월요일, 중간 종료 안전·Today 의도 일치와 재등장 신뢰 | 참여자를 만들거나 효과를 추정하지 않음. 문구→큐/Undo→주 상태→패널 순으로 수정 후 재검증. 치료·생산성 효과 주장 금지 |

## 5. 검증 실행과 증거 관리

자동 테스트와 앱 빌드는 사용자 지시대로 **GitHub Actions 러너**에서 실행한다. Linux 클라우드는 편집·자료 조사·정적 검토·CI 조정에 사용하고 로컬 테스트/앱 빌드를 실행하지 않는다. 현재 `xcode-27`, Xcode 27.0(27A266a), Swift 6.4와 SDK/runtime 27을 쓰며 workflow마다 실제 버전을 확인한다.

| 검증 계층 | 경로 | 검사할 근거 |
|---|---|---|
| 문서·보존 | 기존 validation workflow, Python check/unittest | 원본 hash·계약·FR/QA 연결. 앱 성공과 구별 |
| 날짜·명령·reducer | SwiftPM 및 Mac/iPhone/iPad 공유 Swift Testing | 고정 Clock/context, fixture 36개, 계약 실패·순열·중복·충돌·invariant |
| 영속·프로세스 통합 | Actions의 Mac/Simulator XCTest 및 독립 helper 프로세스 | 실제 SQLite, gate, 종료 fault injection, 보호 상태·migration·receipt 재구성 |
| UI·시스템 빌드 | Actions XCUITest, 앱/Widget/Share metadata·availability | S-01~12·한국어·대상 바인딩·좁은 창·저장 실패·공통 서비스 |
| 실제 시스템/성능 | 등록·서명된 별도 기기 환경, 가능한 자동화는 Actions에 연결 | Siri 한국어, 홈 위젯/timeline, 잠금·VoiceOver, CloudKit 2기기·계정·p95 |
| 사용자 | 동의한 참여자, D-16 프로토콜 | G-UX/H-01~07, 능동 시간·의도 불일치·재등장 신뢰, 로컬 요약 |

현재 명령은 `bash scripts/ci-swift-package.sh`, `bash scripts/ci-apple-platform.sh macos|iphone|ipad`다. SwiftPM은 Domain/Data/System 테스트를 실행하고 네이티브 경로는 앱·내장 확장 빌드, 3개 단위·통합 bundle, 플랫폼별 UI scheme을 차례로 검사하도록 workflow에 연결되어 있다. UI 소스는 [6개 시나리오](../Tests/MirrorUITests/README.md)이며 작성·연결과 실제 실행 통과를 구별한다. 필수 bundle 분류나 JSON 실행 수 검증이 실패하면 후속 UI를 성공으로 기록하지 않는다.

각 QA와 NFR 결과에는 아래 필드를 남긴다. 동일 테스트 소스의 네 플랫폼 실행 수를 독립 사례 수로 합산하지 않는다. 0-test·skip·실패가 있는 필수 suite는 완료로 처리하지 않는다. 장애 주입이나 양성/음성 기대값을 구현에 맞춰 약화하지 않는다.

```text
Requirement / QA / gate ID:
Production source / test name:
Full commit SHA / Actions run / attempt:
Build configuration / Device / OS / SDK:
Date / fixed clock / planning timezone / account environment:
Preconditions / steps / expected / actual:
Result: pass / fail / blocked / not_run
Artifact / measurement / related issue:
Remaining scope:
```

Actions log·xcresult는 현재 7일 artifact다. 영구적인 근거에는 민감 원문·계정 ID·서명정보를 제거한 결과 요약과 run/commit 링크를 보존한다. 실기기·사용자 결과는 승인된 저장/공유 범위를 확인하며 실제 내용 없는 가짜 증거를 만들지 않는다.

NFR 성능 데이터는 열린 작업 10,000개·기록 100,000개·조회 일정 2,000개다. 로컬 단건 p95 500ms, 일반 실기기 위젯 표시 p95 2초는 목표이며 측정된 사실이나 OS 보장이 아니다. 저장과 화면·OS reload 지연을 분리하고 장비·release/debug·표본 수·미달 사유를 기록한다.

## 6. 결정과 외부 실행 경계

현재 사용자 승인 범위인 전체 계획·코드 구현·테스트 작성·Actions 검증·의미 있는 commit/push는 계속 진행한다. 미결정 아키텍처와 실제 Apple 등록/서명·기기/계정·사용자 참여는 다음 표로 추적하며 이 작업의 코드 제작과 구분한다. 독립 날짜/명령 구현을 외부 준비 완료까지 멈추지 않는다.

| 결정 | 현재 상태·추천 검토안 | 필요한 시점과 영향 |
|---|---|---|
| D-STORE | 원본 ADR-004는 Core Data + 불변 OperationRecord + 로컬 projection 제안. 첫 구현은 원본 권고인 Core Data를 기본으로 진행. SwiftData/직접 CloudKit 대안과 영향은 [결정 기록](ARCHITECTURE_DECISIONS.md)에 남김. 별도 사용자 기술 확정으로 주장하지 않음 | D-04 전. persistence 모듈·migration·process gate·실제 통합 테스트가 달라짐 |
| D-CAPABILITY | prefix만 확정. iOS/Mac 최종 Bundle ID 공유 여부, Widget/Share ID, App Group, iCloud container, Team/배포 경로 미정 | D-01 확장·D-07/08 실제 실행·D-10 cloud 전. 실제 계정 등록/서명과 unsigned 설정을 구별 |
| D-SYNC | opt-in 계정 확인·계정별 물리 store·최신 원본 merge 동의·shared pointer·오프라인 identity 검사·실제 미러링 서비스는 구현. Apple 설정과 G-SYNC 미확인; 권위 있는 epoch 제어는 D-DELETE 미결정 | D-10 전. 계정 혼합 금지, writer/importer 중지와 실제 계정 전환 실험 |
| D-DELETE | 기기 로컬 삭제는 구현. 전체 CloudKit purge는 configurationRequired/blocked 상태만 제공하며 실행하지 않음. 자동 미러링의 구세대 업로드까지 차단할 epoch 권위·제어 경계는 [결정 기록](ARCHITECTURE_DECISIONS.md#d-delete-개인-공간-전체-삭제와-구세대-차단)의 선택·검증 필요 | D-13 전. 실제 삭제는 테스트용 데이터와 명시 실행 범위 확인; G-DELETE 없이 완전 삭제 주장 불가 |
| D-UI | SwiftUI/SwiftPieces 채택은 확정. S-01~12의 실제 시안·기기별 레이아웃/포커스·모션을 기록하고 UX 영향 선택 확인 | D-06~11. SwiftPieces 도입 고지와 플랫폼 수정, 주 위젯 fallback은 별도 제품 결정 |
| D-POLICY | 월요일 주 시작, 최초 시간대 고정, 주간 월요일·알림 09:00·28일/48개·14일 진단은 원본 권고. 사용자 선택 가능 값과 상수 구분 | 관련 D-03/09/12/16. 변경이 계획 의미를 바꾸면 ADR/회귀·세션 무효화 |
| D-DEVICE | 서명된 iPhone/iPad/Mac, 개발용 iCloud 2기기·Siri/잠금/VoiceOver 측정 환경 미제공 | D-08/10/13/14. 테스트 코드와 CI 빌드는 독립 진행; 없으면 실제 게이트는 blocked |
| D-USER | 참여자 5~8명·1~2주 관찰은 제안. 참여 모집·연구/영상/요약 export 동의는 미확보 | D-16. 로컬 계측 코드·프로토콜은 제작; 승인 없이 메시지 전송·민감 데이터 수집·연구 수행 없음 |
| D-RELEASE | 가격·상품 정책·공개 시점은 미정. 코드 제작과 별개이며 paywall을 전제로 하지 않음 | D-14 이후. 실제 TestFlight/App Store 업로드·배포/production schema는 실행 승인과 자격 필요 |

권고 기술이나 예시 Apple API를 승인 사실로 기록하지 않는다. 새 의존성·아키텍처·삭제·배포 설정의 선택은 이유/영향/대안을 구체화한 뒤 필요한 확인을 받는다. Apple API의 실제 Swift 서명·availability는 Xcode 27 컴파일/metadata로 확인한다.

## 7. 전체 완료 조건과 후속 후보 보존

전체 완료에는 FR 30개와 연결 QA 87개의 생산 구현·수용 증거, NFR 12개의 검사/실측, 모든 표면의 공통 명령 의미, 네 게이트가 필요하다. 잘못된 taskID 변경, 정상 반환 입력 유실, 자동 실제 마감 변경, 미검토 Today 유입, 삭제 부활, 계정 혼합, 민감 로그 유출, 전체 삭제 허위 표시는 빈도와 관계없이 출시를 차단한다.

현재 원본의 R1 이후 후보도 기록에서 제거하지 않는다. 아래 후보는 FR-001~030과 달리 구체 계약·QA·지원 범위가 없는 후속 설계 대상이다. 이번 전체 앱의 명세 기능을 완료한 뒤 별도 요구사항/ADR/수용 기준을 작성하고 계속 제작한다. 완성된 기능으로 주장하거나 임의 기능을 만들어 필수 계약을 바꾸지 않는다.

| 보존할 후보 | 추가 명세에서 결정할 경계 |
|---|---|
| Apple Watch 독립 앱 | watchOS 지원·로컬 저장/인텐트/동기화·인증·작은 화면 정리 |
| 집중 세션·Live Activity | 사용자가 시작/종료하는 활동, lifecycle·배터리·알림; 하루 전체 상시 표시 없음 |
| AI 작업 분해·자연어 날짜 | 전송/동의·모델·오프라인·사용자 확인, plan/deadline 분리 유지 |
| 이미지 OCR | 이미지/사진 권한·로컬/외부 처리·보존·입력 미리보기 |
| 루틴·반복 작업 | 템플릿과 회차별 taskID, 완료·마감·시간대·중복 회차 의미 |
| 자동 시간 배치 | TimeBlock 별도 의미, 사용자 승인·기존 약속 손상 방지 |
| 외부 캘린더 쓰기·미리 알림 양방향 | 원본 소유권·권한·충돌·Undo·삭제·동기화 범위 |
| 다중 프로젝트 | 개인 공간/계정 경계와 제목만 입력 유지, 조회·이동·내보내기 |
| 스니펫·Siri schema·최신 entity/Undo API | SDK·제품 의미 적합성 검증; 현재 실행 기반 필수 경로와 분리 |
| 개별 작업 이력 영구 삭제 | immutable 원본 내 개인정보·다른 기기 재업로드·복원·새 삭제 게이트 |

협업 배정, 자동 AI 우선순위 확정, ADHD 진단/치료, 강제 계정·벌점 streak는 원본의 비목표다. 새 사용자 요청 없이 전체 제작의 이름으로 추가하지 않는다.

완료 보고는 구현 파일·FR/QA 연결·실제 commit/run·검증 범위·미실행/blocked·남은 결정·미푸시 변경을 포함한다. 코드 구현 완료와 실제 서명·실기기·사용자·공개 배포 완료를 나누어 기록하며, 외부 준비가 남은 경우 해당 단계만 blocked로 남기고 독립 구현을 계속한다.
