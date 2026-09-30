# 구현 결정 기록

이 문서는 원본 권고를 실제 코드로 옮길 때의 선택과 검증 조건을 기록한다. 사용자 확정값, 현재 구현 선택, 아직 필요한 외부 설정을 구분한다. 원본 명세와 보존 보고서는 변경하지 않는다.

## D-STORE: Core Data 원본과 로컬 투영

전체 제작 지시에 따라 원본 ADR-004의 Core Data 구성을 첫 구현의 기본으로 사용한다. 별도 저장 기술 선호를 확인하는 질문은 제시했으며, 사용자가 다른 기술을 확정한 사실로 기록하지 않는다. 새 외부 의존성을 추가하거나 기존 사용자 데이터를 마이그레이션하지 않는다.

| 선택 | 이유와 영향 |
|---|---|
| Core Data + SQLite | Apple 공식 queue·persistent history·CloudKit 경계를 사용한다. 기존 명세의 권고를 유지하며 직접 SQLite 파일을 수정하지 않는다. |
| Canonical / LocalProjection 분리 | 불변 OperationRecord가 복원 원본이다. Task·receipt·session·widget presentation은 로컬 투영이며 두 저장을 하나의 트랜잭션으로 주장하지 않는다. |
| 원본 먼저 저장 | 원본 저장 뒤 투영 실패는 committedProjectionPending이다. 원본에서도 결정 키를 조회해 재시작·재시도 시 중복을 방지한다. |
| 그룹별 head·digest | content·plan·status·deadline은 독립 그룹이다. winner ID만 검사하지 않고 전체 관측 head를 검증한다. |
| POSIX advisory lock | actor는 한 프로세스만 직렬화한다. 앱/확장의 공통 디렉터리에서 실제 파일 lock을 사용하고 timeout·오류·취소 해제를 검증한다. |

SwiftData 자동 미러링은 코드가 짧아질 수 있지만 명세의 프로세스 gate·원본/투영 복구·오프라인 충돌 계약을 대체하지 않는다. 직접 CKSyncEngine 또는 별도 SQLite 구현은 전송·migration·queue 책임이 늘어나므로 첫 구현에서 동시에 도입하지 않는다. 향후 변경은 같은 데이터 안전성과 실제 게이트를 유지하는 별도 변경이다.

실제 SQLite 재시작·원본/투영 경계 장애 주입·다른 store 인스턴스 경쟁·export/import 왕복은 Actions에서 실행한다. 두 독립 프로세스, 실기기 protected data와 CloudKit 계정/오프라인 검증은 별도 증거가 필요하다. 구현 코드가 생겼다는 이유로 게이트를 통과 처리하지 않는다.

## 앱과 확장 저장소 경계

App Group이 아직 등록되지 않은 개발 앱은 명시적인 앱 전용 로컬 저장소로 핵심 기능을 사용할 수 있다. Widget/Share/시스템 확장은 실제 공유 컨테이너를 얻지 못하면 configurationRequired/unavailable을 반환한다. 각 확장이 임의 앱 전용 폴더를 만드는 fallback으로 데이터가 공유되는 것처럼 표시하지 않는다.

CI 테스트는 실제 SQLite를 주입된 임시 공통 경로에서 사용한다. 이 결과는 실제 entitlement·서명·확장 프로세스 공유 검증과 다르다. 앱 최초 실행 전 시스템 행동은 별도 프로세스 composition root로 서비스를 초기화한다.

## 시간대와 성공 표시

기기 현재 시간대는 최초 정책을 고르는 입력으로만 사용할 수 있다. 저장한 계획 시간대·정책 버전은 사용자의 명시 변경 전까지 유지한다. 화면에 표시한 frozen context와 서비스가 현재 시각/저장 정책으로 계산한 context를 비교한다. 카드가 넘긴 context를 서비스의 현재 context로 신뢰하지 않는다.

UI·Widget·Intent는 같은 명령 서비스를 사용하며 원본 저장 후에 성공을 표시한다. 로컬 성공은 CloudKit 완료가 아니다. committedProjectionPending은 새 결정 키로 재생성하지 않고 복구·재조회한다. 같은 카드의 다섯 목적지는 같은 결정 토큰을 사용한다.

## D-SYNC: 선택 활성화와 계정 공간

`CloudSyncService`는 사용자 opt-in 뒤 실제 `CKContainer.accountStatus`와 사용자 record ID를 확인한다. 원문 계정 ID를 로그나 UI에 내보내지 않고 fingerprint별 App Group 하위 디렉터리에 CloudKit 원본 저장소를 연다. 기존 로컬 자료와 클라우드 자료의 미리 보기를 제공하고 별도 병합 확인 뒤 `exportAndSuspend`가 잡은 최신 원본을 가져온다. 미리 보기 이후 입력을 오래된 export로 누락시키지 않는다.

확정한 active pointer를 같은 기기의 App Intent·Widget·Share가 읽는다. 계정이 확인된 시점의 opaque OS identity token을 기기 로컬로 바인딩하며 핵심 쓰기 경로는 이 token과 전환 latch를 검사한다. 오프라인 명령에 계정 네트워크 조회를 강제하지 않는다. token 확인 불가·계정 변경·전환 중이면 기존 공간을 추측해 열지 않는다. `suspend`와 writer generation은 기존 프로세스의 새 쓰기를 차단하고 Core Data store를 detach한다.

원본만 `NSPersistentCloudKitContainer`에 연결한다. 로컬 projection·receipt·session·widget presentation·캘린더 원문·알림 설정은 미러링하지 않는다. 실제 미러링 이벤트의 진행·오류·종료 상태는 앱에 별도 상태 스트림으로 전달하고 원본 변경 스트림과 구분한다. 한 이벤트 종료나 로컬 저장 성공을 모든 기기의 동기화 완료로 표시하지 않는다.

이 구현은 Apple container/App Group/서명 설정이나 G-SYNC 통과를 뜻하지 않는다. iCloud-only entitlement 구성의 identity token 제공·secure coding, 잠금 상태, 계정 전환 중 importer/exporter 중지, 용량 오류, 실제 두 기기의 offline 수렴은 실기기 근거가 필요하다. 특히 기기 로컬 writer generation은 다음 절의 계정 전체 epoch 권위를 대신하지 않는다.

## D-DELETE: 개인 공간 전체 삭제와 구세대 차단

현재 **개인 공간 전체 CloudKit purge는 configurationRequired/blocked**다. Apple container/group 값이 없으면 `cloudDeletionStatus`는 configurationRequired를 반환한다. 설정이 있더라도 이중 확인과 계정 확인 뒤 권위 있는 epoch 미구성과 오프라인 재업로드 미검증을 차단 사유로 반환한다. CloudKit zone purge나 “모든 기기에서 완전히 삭제됨” 성공은 실행·보고하지 않는다. `deleteLocalData`의 기기 로컬 원본·캐시 삭제, 휴지통 이동, 명시적 평문 export와 이 전체 삭제를 구분한다.

현재 불변 기록에는 workspaceEpoch가 있고 로컬 저장소 identity에는 writer generation·전환 상태가 있다. 이 값으로 해당 기기의 오래된 actor를 막고 구세대 원본을 읽기에서 격리할 수 있다. 그러나 다른 오프라인 기기가 권위 있는 새 세대를 아직 받지 못했을 때의 전송까지 자동으로 막지는 못한다. `NSPersistentCloudKitContainer` importer/exporter는 앱의 advisory lock에 참여하지 않으며 자동 미러링이 매 전송 직전 앱의 epoch 검사를 실행한다는 보장도 없다. zone purge 뒤 오래된 미러링 store가 재접속하면 payload를 다시 올리거나 zone을 재생성하는지를 검증해야 한다. 화면에서 구세대를 숨기는 것과 클라우드에 민감 원본이 다시 저장되지 않는 것은 별도의 조건이다.

결정해야 할 핵심은 삭제 후에도 남는 최소 제어 메타데이터의 소유권, 현재 epoch를 누가 변경하는지, 각 업로드가 그 권위를 어떻게 강제하는지다. 계정 전환 시 확인하는 로컬 identity token이나 `epoch` 문자열 하나를 추가하는 것으로 이 문제를 완료 처리하지 않는다.

| 검토안 | 효과와 필요한 검증 | 영향·현재 판단 |
|---|---|---|
| 자동 미러링 유지 + 별도 계정 epoch 제어 기록 | 삭제 후에도 title/note 없이 세대·삭제 사건을 남기고 앱 writer를 중지하는 설계. 모든 기기가 제어를 받기 전 기존 자동 exporter가 payload를 재업로드하지 못한다는 실제 메커니즘을 추가로 증명해야 함 | 기존 Core Data 경로를 유지할 수 있으나 제어 기록을 조회한 뒤 store를 바꾸는 것만으로 전송 경쟁을 해결했다고 주장할 수 없음. zone/store 세대 분리와 재생성 차단은 실제 SDK·두 기기 실험이 필요하며 아직 채택·검증하지 않음 |
| Core Data 로컬 원본 + 명시적 CloudKit 전송 제어 | Apple `CKSyncEngine` 등으로 OperationRecord 전송을 직접 소유하고 세대 검증과 업로드의 경쟁을 설계. 예를 들어 같은 custom zone의 최소 제어 record와 payload batch를 조건부·원자 저장해 오래된 제어 revision의 쓰기를 거부하는 경로를 검토 | 자동 미러링을 대체하므로 전송·재시도·history·계정 전환·zone 관리·migration 책임이 늘어남. 원자성이 zone 경계를 넘는다고 가정하지 않으며 제어 기록 보존과 payload 삭제 방식·실제 SDK 제약을 검증해야 함. 현재 코드에 도입하지 않음 |
| 현재 전송 구현 유지, 전체 purge 차단과 공개 출시 보류 | 로컬 기능과 실제 opt-in 서비스 제작·unsigned CI는 계속하고 D-DELETE 설계·G-DELETE를 끝낸 뒤 전체 삭제를 연결 | 현재 선택. FR-020/024/026/030과 G-DELETE 범위를 제거하거나 로컬 삭제를 전체 삭제로 바꾸지 않음. 미결정 상태를 사용자에게 정확히 표시 |

명시적 전송 대안도 서버에서 구세대 쓰기를 거부하는 조건이 실제로 성립해야 한다. 앱이 새 epoch를 먼저 읽고 나중에 독립 payload 쓰기를 실행하는 두 단계만으로는 그 사이의 삭제 경쟁을 차단할 수 없다. 제어 record를 별도 zone에 두고 같은 batch가 원자적으로 검사된다고 가정해서도 안 된다. zone 전체 purge가 제어 기록까지 지운다면 삭제 후 남는 권위를 다른 검증된 경로로 보존해야 한다. 별도 서버는 현재 제품 범위와 개인정보 전송 경계를 바꾸므로 이 기록에서 채택하지 않는다.

다음 변경에는 구체 설계와 사용자 확인이 필요하다.

- 자동 미러링을 직접 전송 엔진으로 바꾸거나 새 제어 store/zone·payload 계약을 도입하는 아키텍처 변경.
- 이미 동기화된 원본을 새 zone/store/세대로 이전하는 migration과 기존 zone 정리. 평문 export·복구 경로와 실패 시 원본 보존을 먼저 준비한다.
- 실제 CloudKit purge·계정 자료 삭제 실행. 계정·삭제 범위·테스트용 자료·이중 확인·offline 기기 조치와 실패 후 복구를 검토할 수 있는 상태로 만든 뒤 승인된 범위에서 실행한다.
- production schema 변경, 등록·서명·배포 설정과 공개 출시. 코드 제작 승인을 실제 사용자 자료 삭제나 배포 승인으로 확대하지 않는다.

G-DELETE는 오래 오프라인인 두 번째 기기를 삭제 뒤 다시 연결하고 기존 앱·확장 writer, importer/exporter, 재설치, 오래된 export 복원을 검사해야 한다. 정상 완료 조건은 삭제 이후 구세대 payload 재업로드·자동 부활이 없고 명시적 복원은 별도 동의를 거치는 것이다. 최소 제어 메타데이터의 보존 목적·내용은 개인정보 문서에 설명하며 사용자 원문을 제어 메타데이터로 남기지 않는다. 이 조건이 미실행이거나 실패하면 완전 삭제 문구와 공개 출시를 차단한다.

## 동기화·삭제·등록의 남은 조건

선택적 CloudKit은 원본만 미러링하며 로컬 session·presentation·캘린더 원문을 업로드하지 않는다. Apple Team·App Group·iCloud container와 개발/운영 설정은 현재 미제공이다. 후보 identifier를 실제 등록 완료로 기록하지 않는다.

이 기기에서만 지우기는 CloudKit 전체 삭제와 별도 동작이다. 삭제 후에도 자동 백업에 민감 원문을 남겨 두지 않는다. export는 사용자가 위치·내용을 알고 선택하는 평문 파일이다. 전체 CloudKit 삭제의 권위 있는 epoch·구세대 importer/writer 차단·offline 기기 재접속은 G-DELETE에서 확인해야 한다. 이 검증 전에는 완전 삭제 성공이나 공개 출시 가능을 주장하지 않는다.

서명·실제 등록·production schema·TestFlight/App Store 배포와 사용자 연구는 코드 제작의 승인 범위로 자동 실행하지 않는다. 독립 구현과 unsigned CI 검증은 계속 진행하고 필요한 실제 설정과 실행 조건을 구체화한다.
