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

## 동기화·삭제·등록의 남은 조건

선택적 CloudKit은 원본만 미러링하며 로컬 session·presentation·캘린더 원문을 업로드하지 않는다. Apple Team·App Group·iCloud container와 개발/운영 설정은 현재 미제공이다. 후보 identifier를 실제 등록 완료로 기록하지 않는다.

이 기기에서만 지우기는 CloudKit 전체 삭제와 별도 동작이다. 삭제 후에도 자동 백업에 민감 원문을 남겨 두지 않는다. export는 사용자가 위치·내용을 알고 선택하는 평문 파일이다. 전체 CloudKit 삭제의 권위 있는 epoch·구세대 importer/writer 차단·offline 기기 재접속은 G-DELETE에서 확인해야 한다. 이 검증 전에는 완전 삭제 성공이나 공개 출시 가능을 주장하지 않는다.

서명·실제 등록·production schema·TestFlight/App Store 배포와 사용자 연구는 코드 제작의 승인 범위로 자동 실행하지 않는다. 독립 구현과 unsigned CI 검증은 계속 진행하고 필요한 실제 설정과 실행 조건을 구체화한다.
