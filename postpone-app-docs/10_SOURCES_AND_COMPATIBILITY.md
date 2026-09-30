# 10. 공식 근거, 호환성과 검증 한계

버전 0.1 / 공개자료 확인일 2026-09-30

## 1. 근거의 구분

사용자 요구와 앞선 대화는 제품 방향의 근거다. Apple 공식 문서는 플랫폼이 제공하는 동작과 제한의 근거다. 큐 순서, 3분 목표, 되돌리기 정책, Core Data 위에 구성한 명령 기록 구조, 숫자 임계값은 이 제품을 위한 제안이며 Apple 권장사항이나 검증된 사용자 효과로 오인하면 안 된다.

이번 문서는 이전 답변의 API 주장과 소비자 앱 리서치를 그대로 사실로 복사하지 않고, 핵심 구현 경로의 공개 문서를 다시 확인해 작성했다. Xcode SDK와 실기기 결과는 아직 없으므로 컴파일 가능한 프로젝트 / 확정된 시각 시안 / 검증된 성능 문서가 아니다.

## 2. 호환성 전략

| 기능 | R1 계획 | 최소 버전과 확인 방식 |
|---|---|---|
| SwiftUI 네이티브 앱 / Core Data | 필수 | 권고 배포 대상 iOS / iPadOS 18, macOS 15에서 빌드 검증 |
| AppIntent / Entity / Query | 필수 | 각 타깃에서 실제 SDK availability 확인 |
| 인터랙티브 위젯 | 필수 | iOS 17 이후 경로를 기반으로 권고 타깃에서 실기기 검증 |
| WidgetKit 전체 날짜 패널 | 자체 UI 제안 | 임의 DatePicker가 아니라 버튼 + 저장된 presentation + reload |
| EventKit 이벤트 읽기 | 선택 필수 구현 | 권한과 usage description, sandbox entitlement 검증 |
| 최신 Mac Spotlight action | 조건부 | WWDC25 이후 지원 OS에서 확인. macOS 15 기본 약속과 분리 |
| supportedModes / allowedExecutionTargets | 조건부 사용 | 문서에 존재하지만 실제 도입 버전 / 타깃을 SDK로 기록 |
| ControlWidget / 잠금화면 컨트롤 | P1 | 사용자 배치 / 인증 / OS별 지원 별도 검증 |
| 스니펫 / Calendar·Reminders 스키마 | 후속 | 제품 의미가 맞는 경우만 채택. 실행 기반 의존성으로 삼지 않음 |
| SyncableEntity / UndoableIntent 등 최신 API | 미확정 후속 | 이번 핵심 명세는 이 API의 존재 / 지원을 전제로 하지 않음 |
| Watch 독립 앱 | 후속 | 별도 watchOS 저장 / 상호작용 / 동기화 명세 필요 |
| 집중 Live Activity | 후속 | 시작과 종료가 있는 사용자 활동에서만 검토 |

최소 버전을 최신으로 올리는 것도 가능하지만 제품 / 기술 ADR로 남긴다. 최신 API를 모두 저버전에 back-deploy할 수 있다는 가정은 하지 않는다.

## 3. 이전 설명에서 정교화한 부분

**위젯은 앱 화면과 다르다.** 패널 상태와 입력을 명시적으로 저장하고 timeline 재구축을 통해 보여주는 구현안을 사용한다. 위젯 위에 자유로운 달력 팝업이 뜬다고 가정하지 않는다.

**위젯 예산은 결정 횟수 제한이 아니다.** 사용자 AppIntent 상호작용과 일반 주기 reload를 구분한다. 성능과 정시 실행은 별도 테스트 항목이다.

**Mac은 용어와 OS 버전을 구분해야 한다.** A04의 HIG에는 App Shortcuts의 macOS 미지원 표현이 있지만 A12의 WWDC25는 Mac Spotlight에서 앱 action을 실행하는 기능을 명시한다. 이를 하나의 지원 / 미지원 체크박스로 합치지 않고, 일반 Shortcuts action과 최신 Spotlight 실행을 별도 표면으로 테스트한다.

**Calendar / Reminders schema는 데이터 저장소와 다르다.** 시스템에 행동과 데이터를 설명하는 것과 Apple 미리 알림 / 캘린더를 실제 원본 DB로 쓰는 것을 혼동하지 않는다. R1의 자체 작업 데이터는 독립적이다.

**Core Data CloudKit이 충돌 의미까지 해결하지 않는다.** 미러링은 전송 경로다. 완료와 재배치, 다른 기기의 Undo는 제품 도메인과 리듀서가 책임진다.

**3분은 측정된 효과나 모든 작업 처리 보장이 아니다.** 관리 부담을 줄이려는 가치 제안이고 11 문서에 검증 계획을 둔다.

## 4. 공식 자료 목록

아래 URL은 원문 확인용이다. Apple 문서 일부는 JavaScript 기반이며 SDK별 availability는 웹 요약만으로 확정하지 않는다. 확인된 내용만 위의 설계 전제로 사용했다.

### A01. Adding interactivity to widgets and Live Activities

Button / Toggle과 App Intents, 별도 프로세스와 timeline 기반 표시, 비동기 갱신을 확인했다. 위젯을 일반 앱의 상태 바인딩 화면으로 취급하지 않는 근거다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
```

### A02. Keeping a widget up to date

일반 위젯 갱신에는 동적인 예산이 있다. 사용자 AppIntent 상호작용의 reload는 일반 예산과 구별되며, 예산 수치를 하루 작업 처리 한도로 해석하지 않는다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/
```

### A03. AppIntent

앱 행동을 시스템에 공개하는 프로토콜이며 인증 정책과 실행 대상 등의 계약을 가진다. 플랫폼별 가용성은 실제 SDK에서 확인한다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/appintents/appintent
```

### A04. App Shortcuts / Human Interface Guidelines

설치 후 사용할 수 있는 대표 App Shortcuts, 최대 10개 항목, 짧은 발화와 사용자 설정 흐름을 확인했다. macOS 플랫폼 표기는 A12와 함께 해석해야 한다.

확인일: 2026-09-30

```text
https://developer.apple.com/design/human-interface-guidelines/app-shortcuts
```

### A05. Core Data

로컬 영속화, 변경 관리, CloudKit 미러링이 제공되는 것을 확인했다. 이 제품의 불변 명령 원본 설계 자체를 Apple이 요구한다는 뜻은 아니다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/coredata/
```

### A06. Syncing a Core Data Store with CloudKit

기기의 로컬 저장소를 CloudKit과 비동기 미러링하는 경로다. 사용자 정의 충돌 정책과 표시 갱신 책임이 사라지는 것은 아니다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/coredata/syncing-a-core-data-store-with-cloudkit
```

### A07. Creating a Core Data Model for CloudKit

unique constraint와 관계의 제약, 개발 / 운영 스키마 차이를 확인했다. 운영에 올라간 기존 record type과 field를 자유롭게 바꾸거나 제거한다고 가정하지 않는다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/CoreData/creating-a-core-data-model-for-cloudkit
```

### A08. Persistent history

저장소 변경을 token과 transaction 단위로 소비하는 근거다. 도메인의 operationID와 history token은 별개다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/coredata/persistent-history
```

### A09. App Extension Programming Guide / Handling Common Scenarios

App Group 공유 저장소와 프로세스 간 접근 조율을 확인했다. 아카이브 문서이므로 오래된 빌드 설정을 그대로 채택하지 않고 데이터 공유 원칙에만 사용했다.

확인일: 2026-09-30

```text
https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html
```

### A10. Accessing the event store

이벤트 읽기에는 full access가 필요하며 read-only 권한은 없다. R1이 읽기만 한다는 제품 정책과 OS가 부여하는 권한 범위를 구분한다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/eventkit/accessing-the-event-store
```

### A11. Developing a WidgetKit strategy

위젯, 컨트롤, Live Activity, Watch 표면의 역할을 구분하고 관련 앱 장면으로 deep link하는 경로를 확인했다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/widgetkit/developing-a-widgetkit-strategy
```

### A12. Develop for Shortcuts and Spotlight with App Intents / WWDC25

Mac Spotlight에서 App Intent action을 실행하는 경로와 필수 parameterSummary 조건을 설명한다. 최소 지원 macOS 전체에 같은 최신 표면이 있다고 가정하지 않는다.

확인일: 2026-09-30

```text
https://developer.apple.com/videos/play/wwdc2025/260/
```

### A13. AppIntent.supportedModes

전경 / 배경 모드 구분을 확인했다. allowedExecutionTargets는 A03에 있다. 실제 availability는 SDK 헤더와 컴파일 분기로 검증한다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/appintents/appintent/supportedmodes
```

### A14. IntentAuthenticationPolicy.requiresAuthentication

실행 전 인증 정책을 확인했다. 다른 기기에서 인증되어 실행되는 경우와 로컬 데이터 보호 상태는 별도로 테스트해야 한다.

확인일: 2026-09-30

```text
https://developer.apple.com/de/documentation/appintents/intentauthenticationpolicy/requiresauthentication
```

### A15. Displaying live data with Live Activities

ActivityKit은 Live Activity의 시작 / 갱신 / 종료를 관리한다. 상시 할 일 보관 화면이나 무제한 배경 프로세스로 취급하지 않는다.

확인일: 2026-09-30

```text
https://developer.apple.com/de/documentation/activitykit/displaying-live-data-with-live-activities
```

### A16. Scheduling a notification locally from your app

로컬 알림 content / trigger / request와 명시적 취소 경로를 확인했다. 본 문서의 예약 28일 / 자체 상한 48개는 제품 제안이며 OS 상한이 아니다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app
```

### A17. TN3164 / Debugging NSPersistentCloudKitContainer synchronization

동기화 문제가 표시 계층, CloudKit 설정, 시스템 제한 등에서 발생할 수 있다는 구분과 로그 기반 진단 경로를 확인했다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer
```

### A18. User Privacy and Data Use / App Privacy Details

실제 앱과 SDK의 데이터 흐름에 맞춰 개인정보 정보를 제공해야 한다. 로컬 우선 설계라는 이유만으로 수집 없음이라고 확정하지 않는다.

확인일: 2026-09-30

```text
https://developer.apple.com/app-store/app-privacy-details/
```

### A19. NSPersistentCloudKitContainer / purgeObjectsAndRecordsInZone

특정 zone의 CloudKit record와 대응 managed object를 지우는 API를 확인했다. 오프라인 기기 복귀와 전체 삭제의 의미는 제품 수준에서 별도로 검증해야 한다.

확인일: 2026-09-30

```text
https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/purgeobjectsandrecordsinzonewithid%3Ainpersistentstore%3Acompletion%3A
```

## 5. 증거 수준

문서 확인: 위 자료를 검색 또는 원문 열람으로 확인했다.

아직 미실행: Xcode 빌드, AppIntent metadata 추출, 기기 인증 경로, Siri 한국어 인식, CloudKit 실제 저장소와 계정 전환, 위젯 갱신 성능, VoiceOver 조작, 개인정보 전체 삭제.

문서 번들 검사: 내부 파일 연결, JSON 형식 / 스키마, 요구사항과 QA 매핑, 예시 날짜를 별도로 점검한다. 이 검사 결과를 앱 구현 테스트 결과로 대체하지 않는다.
