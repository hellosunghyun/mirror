# 미루기 중심 할 일 / 일정 앱 개발 문서

문서 버전: 0.1  
작성 및 공개 기술자료 확인 기준일: 2026-09-30  
상태: 구현을 위한 제안 명세. 사용자와 합의된 방향, 새로 제안한 정책, 기술 검증 항목을 구분한다.  
제품명: 미정. `Postpone`은 문서와 코드 예시에서만 사용하는 작업명이다.

## 제품 정의

> 잘 미루면, 지금 할 일이 남는다.
>
> 떠오르는 일을 일단 넣고, 하루 3분 동안 오늘 하지 않을 일을 다른 날로 보낸다. 일주일에 한 번은 이번 주와 이후를 나눈다. 결정한 일은 그때까지 다시 묻지 않고, 오늘 하기로 남긴 일만 보여준다.

단순한 날짜 변경 도구가 아니다. 핵심 가치는 **결정을 한 번 하고, 결정한 시점까지 기억과 재판단을 앱에 맡기는 것**이다.

## 이 문서의 기준

- **확정 방향**: 사용자가 직접 요청한 제품 방향. PRD의 `C-01`부터 `C-10`까지.
- **권고 명세**: 구현을 시작할 수 있도록 정한 기본값. 사용자 승인을 받은 확정 사실로 해석하지 않는다.
- **검증 필요**: 실제 SDK, 기기, 성능, 사용성 실험으로 확인해야 하는 사항.
- **후속 범위**: 의도적으로 첫 버전에서 제외한 기능. 이전 대화에 있었다는 이유로 자동 포함하지 않는다.

이 문서는 앱 코드나 실행 결과가 아니다. Xcode 빌드, 실제 위젯 동작, iCloud 동기화, Siri 한국어 인식은 이 환경에서 테스트하지 않았다. 번들 안의 검증 결과는 문서 내부 연결과 JSON 계약, 요구사항 추적성에 대한 검사만 의미한다.

## 문서 지도

| 문서 | 주로 읽는 사람 | 결정하는 내용 |
|---|---|---|
| [01_PRODUCT_REQUIREMENTS.md](01_PRODUCT_REQUIREMENTS.md) | 제품 담당자, 전체 개발자 | 문제, 가치, 범위, 기능 요구사항, 비기능 요구사항 |
| [02_UX_AND_SCREEN_SPEC.md](02_UX_AND_SCREEN_SPEC.md) | 디자이너, UI 개발자 | 정보구조, 화면별 상태, 버튼, 탐색, 문구, 접근성 |
| [03_DOMAIN_AND_REVIEW_RULES.md](03_DOMAIN_AND_REVIEW_RULES.md) | 도메인 / 클라이언트 개발자 | 오늘 목록, 주간 범위, 재등장, 날짜 계산, 정리 큐 |
| [04_DATA_AND_COMMAND_CONTRACTS.md](04_DATA_AND_COMMAND_CONTRACTS.md) | 데이터 / 도메인 개발자 | 엔티티, 명령, 오류, 멱등성, 되돌리기, JSON 계약 |
| [05_ARCHITECTURE_AND_SYNC.md](05_ARCHITECTURE_AND_SYNC.md) | 리드 개발자 | 네이티브 구성, 저장, 프로세스 경계, CloudKit, 충돌 복구 |
| [06_APP_INTENTS_AND_WIDGETS.md](06_APP_INTENTS_AND_WIDGETS.md) | 시스템 통합 개발자 | 인텐트 목록, 위젯 상태, 원자적 입력, 딥링크, 기기별 차이 |
| [07_CALENDAR_NOTIFICATIONS_PRIVACY.md](07_CALENDAR_NOTIFICATIONS_PRIVACY.md) | 플랫폼 / 보안 개발자 | EventKit, 알림, 권한, 잠금 상태, 내보내기, 삭제 |
| [08_QA_AND_ACCEPTANCE.md](08_QA_AND_ACCEPTANCE.md) | QA, 전체 개발자 | 시나리오, 장애 주입, 플랫폼 테스트, 출시 기준 |
| [09_DELIVERY_AND_DECISIONS.md](09_DELIVERY_AND_DECISIONS.md) | 제품 담당자, 리드 개발자 | 작업 분해, 의존성, ADR, 미결정 사항, 구현 게이트 |
| [10_SOURCES_AND_COMPATIBILITY.md](10_SOURCES_AND_COMPATIBILITY.md) | 기술 검토자 | Apple 공식 근거, 호환성, 이전 설명에서 정정할 점 |
| [11_PRODUCT_VALIDATION.md](11_PRODUCT_VALIDATION.md) | 제품 담당자 | 3분 가치 검증, 지표 정의, 개인정보 최소화, 사용자 실험 |
| [contracts/plan-target.schema.json](contracts/plan-target.schema.json) | 개발자, QA | 계획 상태의 기계 판독 계약 |
| [contracts/command-envelope.schema.json](contracts/command-envelope.schema.json) | 개발자, QA | 명령 공통 봉투 계약 |
| [fixtures/domain-cases.json](fixtures/domain-cases.json) | 개발자, QA | 고정 날짜와 상태에 대한 기대 결과 |
| [validation/traceability.json](validation/traceability.json) | 제품 담당자, QA | 요구사항과 문서 / 테스트 매핑 |

## 첫 버전의 완결된 사용 흐름

```text
한 줄 입력 또는 공유
  → 보관함
  → 하루 / 주간 정리 카드
  → 오늘 / 내일 / 이번 주 / 다음 주 / 기타
  → 정한 날까지 정리 대상에서 제외
  → 오늘 목록
  → 완료 또는 명시적인 재배치
```

주간 정리도 같은 3분 정리 시간 안에서 수행한다. 3분은 모든 항목을 반드시 처리해야 하는 제한 시간이 아니라, 계획에 쓰는 시간을 제한하려는 제품 목표다.

## 첫 구현에서 반드시 지킬 8개 규칙

1. 미검토 항목은 오늘 할 일이 아니다.
2. 오늘 버튼은 완료가 아니라 오늘에 배치하는 행동이다.
3. 날짜 배치와 실제 마감은 다른 데이터다.
4. 특정 날짜에 보낸 일은 그 전의 정리 큐에 반복해서 올리지 않는다.
5. 다음 주로만 보낸 일은 월요일의 할 일로 자동 변환하지 않는다.
6. 카드 입력은 화면에 보였던 작업 ID에만 적용한다. 전역 `현재 작업`을 다시 조회하여 수정하지 않는다.
7. 로컬 저장 성공과 클라우드 동기화 완료를 구분한다.
8. 하루가 지났다고 미완료를 다음 날의 오늘 목록으로 자동 이월하지 않는다.

## 권고 기술 기준

SwiftUI 네이티브 iPhone / iPad / Mac 앱, App Intents와 WidgetKit, Core Data와 선택적 iCloud 동기화를 기본안으로 삼는다. 상세 저장 정책은 05 문서에 정의한다. 웹 백엔드, 강제 로그인, 외부 AI 모델은 첫 버전의 필수 구성요소가 아니다.

권고 최소 배포 대상은 iOS / iPadOS 18, macOS 15다. 이는 지원 대상 제안이지 모든 최신 API가 이 버전에서 동작한다는 뜻이 아니다. 최신 Spotlight 실행, 스니펫, 스키마, 실행 대상 API는 가용성을 별도로 확인하고 제한한다. 구현 시작 시 실제 Xcode / Swift / SDK 버전을 기록한다.

## 읽는 순서

제품 범위는 01, 사용자 흐름은 02, 상태 규칙은 03을 먼저 읽는다. 개발자는 04~07을 이어 읽는다. 구현 순서는 09의 게이트를 따른다. 완료 여부는 08의 수용 기준으로 판단한다.

서로 모순되는 경우 03의 상태 규칙과 04의 명령 계약을 기술적 기준으로 사용하되, 제품 방향 자체를 바꾸려면 01과 ADR을 먼저 수정한다. 코드를 맞추기 위해 사용자 약속을 조용히 바꾸지 않는다.

## 번들 검증과 개발 착수

[문서 검증 결과](validation/VALIDATION_REPORT.md)에서 내부 연결, JSON 계약, 36개 예시 fixture, 30개 기능 요구사항의 QA 연결 상태를 확인할 수 있다. [검증 스크립트](validation/validate_bundle.py)는 문서 파일과 계약 예시만 검사한다. 실제 Swift 도메인 구현을 이 함수와 동일하다고 가정하지 않는다.

재검사에는 Python 3.10 이상과 jsonschema 4 계열이 필요하다. 프로젝트의 Swift / Xcode 의존성과는 별도인 문서 보조 도구다.

```bash
python -m pip install 'jsonschema>=4,<5'
python validation/validate_bundle.py
```

앱 테스트는 QA 명세 87개이며 아직 모두 미실행이다. 문서 검증 통과와 제품 구현 완료는 서로 다르다. 구현 첫 작업은 09 문서의 D-01 / D-02와 G-WIDGET, G-SYNC 검증 계획 수립이다.
