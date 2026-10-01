# 구현 공백과 남은 수용 조건

확인일은 **2026-10-01**, 코드 기준은 [`d7a3630121904a66546d554f2867bf00ebf8955c`](https://github.com/hellosunghyun/mirror/tree/d7a3630121904a66546d554f2867bf00ebf8955c)다. 원본 FR 30개·QA 87개·NFR 12개와 네 검증 게이트의 전체 범위를 유지하며, 생산 코드에서 확인한 공백과 외부 설정·수용 검증을 구분한다. 아래 코드 줄 번호는 이 기준 커밋에 대한 것이다.

최근 전체 GitHub Actions 검사는 통과했고, [Ad Hoc 실행 36867363304](https://github.com/hellosunghyun/mirror/actions/runs/36867363304)와 [Release `adhoc-36867363304`](https://github.com/hellosunghyun/mirror/releases/tag/adhoc-36867363304)의 iOS IPA·macOS DMG 서명·공증 배포가 성공했다. 이전 인증서 불일치·Secrets 누락·IPA 미게시 기록을 현재 차단 사유로 사용하지 않는다. 이 배포 결과와 QA 87개 전체 수용, 실제 App Group·iCloud 권한, 두 기기 동기화는 각각 별도 완료 조건이다.

## 상태의 의미

| 상태 | 판단 기준 |
|---|---|
| 미구현 | 요구한 동작을 수행하는 생산 경로가 없다. |
| 부분 구현 | 관련 동작은 있으나 요구한 세부 경로나 복구 조건이 빠져 있다. |
| 설정 막힘 | 관련 코드가 있으며 현재 identifier·entitlement·프로파일 설정으로 실제 경로를 열 수 없다. |
| 미검증 | 해당 경로의 코드가 있지만 필요한 원격·시스템·실기기·사용자 수용 증거가 없다. |

같은 기능에 코드 공백과 미검증이 함께 있을 수 있다. 미검증을 곧바로 미구현으로 계산하지 않는다.

## 확인한 코드 공백

| 항목 | 상태 | 현재 동작과 빠진 경로 | 원본 요구사항·수용 조건 |
|---|---|---|---|
| 개인 공간 전체 CloudKit 삭제 | **미구현** | 이중 확인·계정 확인 뒤에도 `CloudSyncPolicy.deletion`은 항상 `blocked`를 반환한다. CloudKit payload purge, 계정 전체의 권위 있는 epoch 전환, 오래 오프라인인 기기의 구세대 재업로드 차단은 구현되지 않았다. 기기 로컬 삭제·휴지통·export/import는 이미 있다. [CloudSyncService.swift:95–99,353–358](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Sources/MirrorSystem/CloudSyncService.swift#L95), [D-DELETE](ARCHITECTURE_DECISIONS.md#d-delete-개인-공간-전체-삭제와-구세대-차단). | FR-020/024/026/030, [원본 05 §11](../postpone-app-docs/05_ARCHITECTURE_AND_SYNC.md), Q-084, G-DELETE. 아키텍처 결정과 두 기기 삭제·재접속 증거가 필요하다. |
| 빠른 입력의 선택적 날짜 | **미구현** | 입력 화면의 부가 영역은 메모·원문 링크만 제공하고, `capture`는 계획 없는 새 작업만 저장한다. 입력하면서 사용자가 날짜를 직접 정하는 경로가 없다. 저장 뒤 기존 상세/날짜 선택을 사용하는 경로는 있다. [MirrorScreens.swift:91–118,191–199](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/App/MirrorScreens.swift#L91), [AppModel.swift:380–386](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/App/AppModel.swift#L380). | FR-001/006/009, [원본 02 S-02](../postpone-app-docs/02_UX_AND_SCREEN_SPEC.md): “메모 / 링크 / 날짜는 접힌 부가 영역”, 입력에서 직접 날짜를 정했을 때 해당 날짜 피드백. 제목만 저장하는 기본 경로를 유지한다. |
| Mac·iPad 날짜 드래그 배치 | **미구현** | 일정의 날짜별 작업과 요일 미정 바구니는 있으나 작업 drag/drop을 날짜 배치 명령에 연결하는 코드가 없다. 기존 버튼 방식의 날짜 선택은 있다. [MirrorCalendarSettings.swift:31–57](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/App/MirrorCalendarSettings.swift#L31). | FR-018/027, [원본 02 S-09](../postpone-app-docs/02_UX_AND_SCREEN_SPEC.md): Mac/iPad의 보조 드래그 경로와 같은 작업의 버튼 대체. 외부 약속은 읽기 전용으로 유지한다. |
| 마이그레이션 전 원본 백업 | **미구현** | Core Data 자동 migration·mapping 추론을 켠 뒤 store를 로드한다. 변환 전 원본을 백업하고 실패 시 그 백업을 보존하는 명시적 절차가 없다. 사용자가 선택하는 JSON 내보내기는 별도 기능이다. [CoreDataPersistence.swift:322–335](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Sources/MirrorData/CoreDataPersistence.swift#L322). | NFR-011, FR-030, [원본 05 §10](../postpone-app-docs/05_ARCHITECTURE_AND_SYNC.md), Q-064. 이전 모델·디스크 부족·변환 실패에서 원본과 백업 보존을 확인한다. |
| 알림 선택 후 대상 화면 진입 | **부분 구현** | 알림 예약·취소와 `userInfo["route"]` 생성은 있다. `UNUserNotificationCenterDelegate` 응답 처리와 이 route를 앱 탐색에 전달하는 경로가 없다. 앱의 `.onOpenURL`만으로 알림 userInfo가 전달되지는 않는다. [NotificationService.swift:47](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Sources/MirrorSystem/NotificationService.swift#L47), [MirrorRootView.swift:107](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/App/MirrorRootView.swift#L107). | FR-022/030, [원본 07 §2–4](../postpone-app-docs/07_CALENDAR_NOTIFICATIONS_PRIVACY.md)와 [원본 06 §10 딥링크](../postpone-app-docs/06_APP_INTENTS_AND_WIDGETS.md)의 정리·작업 목적지. 원본에는 알림 탭만의 독립 QA 번호가 없으므로 예약 QA 통과와 탐색 연결을 별도로 확인한다. |
| Spotlight 작업 검색 결과 선택 | **부분 구현** | 허용된 제목과 taskID 인덱싱·인덱스 제거는 있다. `CSSearchableItemActionType`/검색 항목 identifier의 activity를 받아 해당 작업 상세로 연결하는 처리와 `.onContinueUserActivity`가 없다. App Intent를 최신 Spotlight에서 실행하는 경로와 작업 검색 결과의 선택은 별도 표면이다. [SpotlightService.swift:18–24](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Sources/MirrorSystem/SpotlightService.swift#L18), [MirrorRootView.swift:96–107](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/App/MirrorRootView.swift#L96). | FR-029/030, [원본 06 §10/12](../postpone-app-docs/06_APP_INTENTS_AND_WIDGETS.md), [원본 07 §6](../postpone-app-docs/07_CALENDAR_NOTIFICATIONS_PRIVACY.md). 결과의 현재 공간·삭제 상태·노출 설정을 확인한 뒤 상세로 연결해야 한다. |
| 위젯 “기타” 배치 뒤 다음 행동 선택 | **부분 구현** | 위젯의 taskID·session/card 맥락을 유지하여 앱 달력을 열고 날짜를 저장하는 경로는 있다. 저장 성공 시 picker를 닫으며, 이 흐름의 완료 화면에서 “이어서 정리”와 “오늘 목록”을 고르는 경로는 없다. 일반 Today의 재개 버튼만으로 이 전환을 완료 처리하지 않는다. [AppModel.swift:446–449,969–975](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/App/AppModel.swift#L446), [MirrorScreens.swift:447–472](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/App/MirrorScreens.swift#L447). | FR-009/016/030, [원본 02 S-06](../postpone-app-docs/02_UX_AND_SCREEN_SPEC.md): 위젯에서 앱으로 왔을 때 “이어서 정리”와 “오늘 목록” 제공. Q-015/043, G-WIDGET. |
| 물리적으로 손상된 projection cache 복구 | **부분 구현** | 원본 재생·투영 재구축·history token 오류의 재구축과 원본 저장 직후 종료 회귀는 있다. 그러나 `LocalProjection.sqlite`의 물리 손상으로 로드가 실패하면 에러를 반환하며, 손상 캐시만 격리·재개설하고 canonical에서 복구하는 별도 경로가 없다. 파일이 없는 초기 개설과 물리 손상을 구분한다. [CoreDataPersistence.swift:54–57,322–326](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Sources/MirrorData/CoreDataPersistence.swift#L54), [MirrorStore.swift:722–754](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Sources/MirrorData/MirrorStore.swift#L722), [기존 종료 회귀:160](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Tests/MirrorDataTests/StoreIntegrationTests.swift#L160). | NFR-011, FR-030, [원본 05 §6](../postpone-app-docs/05_ARCHITECTURE_AND_SYNC.md), Q-063. 손상 파일·잠금·디스크 실패에서 canonical을 보존하고 projection만 복구하는 근거가 필요하다. |
| 큰 데이터의 페이지 조회·작은 시스템 snapshot | **부분 구현** | 영향 작업별 history 소비는 있으나 최초 개설에서 모든 Operation을 fetch·재생하고 snapshot에 전체 tasks/records를 정렬해 반환한다. 정리 진입도 메모리의 전체 tasks를 필터링하며, 페이지 단위 내용 조회 계약이 없다. 위젯 프로세스도 공통 store 개설과 snapshot 경로를 사용한다. [CoreDataPersistence.swift:68–77](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Sources/MirrorData/CoreDataPersistence.swift#L68), [MirrorStore.swift:120–135,145–150](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Sources/MirrorData/MirrorStore.swift#L120), [AppModel.swift:477–483](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/App/AppModel.swift#L477). | [원본 03 §8: 페이지 단위 읽기](../postpone-app-docs/03_DOMAIN_AND_REVIEW_RULES.md), [원본 05 §6/9](../postpone-app-docs/05_ARCHITECTURE_AND_SYNC.md), NFR-002/004, Q-086. 성능 baseline workflow는 이미 있으나 실행·실기기 수용 증거와 페이지 구현은 별도다. |
| App Entity의 실제 마감 반환 | **부분 구현** | `MirrorTaskEntity`는 id·title·planSummary·completed만 가지고 실제 마감 값/요약을 반환하지 않는다. 입력·조회·배치·완료 등 인텐트 구현은 있다. [AppIntents.swift:8–26](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Sources/MirrorSystem/AppIntents.swift#L8). | FR-014/017, [원본 06 §2](../postpone-app-docs/06_APP_INTENTS_AND_WIDGETS.md): TaskEntity의 선택 마감. 날짜 마감·시각 마감·미설정과 외부 제목 숨김 조건을 구분한 반환 계약이 필요하다. |

## 설정 때문에 열리지 않는 경로

| 기능 | 현재 설정과 결과 | 근거 |
|---|---|---|
| 앱·Widget·Share의 공유 원본 | 앱/확장 Info.plist의 `MirrorAppGroupIdentifier`가 비어 있다. 후보 `group.com.baserize.mirror`는 별도 candidate 값이며 실제 권한으로 사용하지 않는다. 본 앱은 기기 로컬 저장소를 열 수 있지만 확장은 `configurationRequired`를 반환한다. | [앱 plist:21–28](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Configuration/MirrorIOS-Info.plist#L21), [위젯 plist:21](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Configuration/Widgets-Info.plist#L21), [Share plist:21](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Configuration/Share-Info.plist#L21), [SystemCompositionRoot.swift:49–52](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Sources/MirrorSystem/SystemCompositionRoot.swift#L49). |
| iCloud 동기화 | `MirrorCloudContainerIdentifier`도 비어 있고, 저장소의 앱/확장 entitlements에는 App Group·CloudKit 권한이 없다. 제공된 iOS 프로파일에도 해당 권한이 없는 상태다. `previewEnable`은 prerequisite 검사에서 중단한다. 등록한 identifier·container·entitlement·프로파일/서명을 함께 맞춰야 실제 계정 및 미러링 경로를 검증할 수 있다. | [CloudSyncService.swift:198–204,394–399](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/Sources/MirrorSystem/CloudSyncService.swift#L198), [iOS entitlements](../Configuration/MirrorIOS.entitlements), [Mac entitlements](../Configuration/MirrorMac.entitlements), [확장 iOS](../Configuration/ExtensionIOS.entitlements), [확장 Mac](../Configuration/ExtensionMac.entitlements). |

App Intents 전체를 설정 막힘으로 분류하지 않는다. 본 앱 프로세스의 로컬 composition root로 실행 가능한 인텐트와 공유 확장 프로세스로 실행하는 위젯·Share를 구분한다. 캘린더 읽기는 iOS 사용 설명과 Mac calendar entitlement가 있고, 알림·Spotlight도 해당 사용자의 opt-in 및 OS 권한 조건에서 실행하는 코드가 있다.

## 병행 UI 변경과 남은 검증

기준 커밋의 일정 화면은 날짜별 작업을 `MirrorTaskRow`로 표시하며 실제 마감 배지/독립 영역이 빠져 있었다([기준 일정:31–57](https://github.com/hellosunghyun/mirror/blob/d7a3630121904a66546d554f2867bf00ebf8955c/App/MirrorCalendarSettings.swift#L31)). 2026-10-01 병행 UI 수정의 작업 트리에는 `dayCard`의 날짜별 “이 날의 실제 마감”과 `taskRows`의 실제 마감 배지가 추가됐다([현재 MirrorCalendarSettings.swift](../App/MirrorCalendarSettings.swift), 확인 시점 95–131·150–159행). **이 항목은 UI 수정 커밋 `6d6ef3b`에서 구현했고 세 플랫폼의 원격 앱 빌드·단위 검사와 각각 UI 6개는 통과했다.** 실제 마감이 있는 일정의 배지·별도 영역 시각 수용은 추가 증거가 필요하다. FR-014/018/021과 [원본 02 S-09](../postpone-app-docs/02_UX_AND_SCREEN_SPEC.md)의 계획·마감 분리를 확인해야 한다.

다음은 코드 작성 여부와 별도로 필요한 수용 증거다.

| 수용 범위 | 현재 남은 증거 |
|---|---|
| G-WIDGET | 실제 서명된 iPhone/iPad/Mac 위젯의 30개 연속 결정, 두 인스턴스·앱 종료·자정·주 패널·기타·Undo·잠금, 저장/새 카드 표시의 별도 p95. App Group 설정이 먼저 필요하다. |
| G-SYNC | 실제 두 기기 오프라인 변경 수렴, 계정 전환·잠금·identity token·용량 오류·importer/exporter 경계. 설정값이나 reducer 단위 결과만으로 완료 처리하지 않는다. |
| G-DELETE | 권위 있는 삭제 세대 및 전송 차단 설계가 먼저 필요하다. 구현 뒤 오래 오프라인인 기기·확장 writer·재설치·오래된 export 복원에서 재업로드/부활 여부를 검증한다. |
| 시스템 및 접근성 | 실제 Siri 한국어 발화·동명 작업 선택, Spotlight action/작업 결과, Control, Share, EventKit 거절/철회, 실제 알림 전달·선택, VoiceOver·가장 큰 글자·키보드·잠금/보호 데이터. |
| Q-063/064/086와 NFR | 물리 cache 손상 및 이전 버전 migration 실패 회귀, 1만 작업/10만 원본의 성능·메모리·페이지 조회, 실제 기기의 저장·위젯 표시 측정. [성능 workflow](../.github/workflows/performance.yml) 및 [측정 범위](../TESTING.md)는 이미 있다. |
| G-UX·사용자 수용 | 전체 QA 87개 시나리오 및 [제품 검증 프로토콜](PRODUCT_VALIDATION_PROTOCOL.md)의 사용자 과제·효과·이해도 확인. 현재 단위/통합/UI smoke 실행 수와 합산하지 않는다. |

스니펫·Watch 독립 앱·Live Activity·AI 분해·자연어 날짜 자동화·반복 작업·외부 캘린더 쓰기는 [원본의 R1 이후 범위](../postpone-app-docs/01_PRODUCT_REQUIREMENTS.md#53-r1-이후)로 유지한다. 위 표의 R1 공백에 추가하거나 이미 합의된 전체 범위를 임의로 줄이지 않는다.

이 문서는 소스·원본·결정 기록의 정적 대조 결과다. 작성 과정에서 로컬 앱 빌드·테스트나 Apple 설정·실제 자료 삭제를 실행하지 않았다.
