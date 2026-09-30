# 미러(Mirror)

> 잘 미루면, 지금 할 일이 남는다.

미루기와 재결정 최소화를 중심으로 하는 iPhone / iPad / Mac 앱이다. SwiftUI의 실제 입력·정리·Today·검색·상세·설정 화면, 불변 원본 기반 Core Data 저장, Widget/Share/App Intents 및 선택 CloudKit 코드를 통합했다. 전체 구현의 Actions 컴파일·통합/UI 검증을 진행 중이며 실제 서명·두 기기 동기화·사용자 검증은 남아 있다.

## 이름 설명

이름의 의미를 소개할 때만 사용하는 짧은 설명 초안:

> 미러(Mirror)는 ‘미뤄’를 표현한 이름입니다. 할 일을 알맞은 때로 미루고, 지금 할 일에 집중하도록 돕습니다.

## 확정된 개발 기준

- 앱 이름: **미러(Mirror)**. 한국어 표시명은 `미러`, 영문 이름은 `Mirror`.
- 이름의 의미를 설명해야 할 때만 **‘미뤄’를 표현한 이름**이라고 설명한다. 일반적인 앱 이름 표기는 `미러`를 사용한다.
- 개발 및 최소 배포 기준: **iOS 27.0 / iPadOS 27.0 / macOS 27.0**.
- UI 구성요소: 사용자 지정 **[SwiftPieces](https://github.com/Saivion/SwiftPieces)**를 사용한다. 적용 방식과 검증 기준은 아래 UI 항목을 따른다.
- GitHub 저장소: **hellosunghyun/mirror**, **public**. 사용자 승인에 따른 공개 전환을 GitHub에서 확인했다. 실제 공개 범위와 전환 상태는 [development-baseline.json](development-baseline.json)에 기록한다.
- 테스트코드를 적극 활용한다. 날짜·도메인·명령 규칙은 테스트부터 작성하고, 버그 수정에는 재현 회귀 테스트를 함께 추가한다.
- 제품 요구사항 30개와 QA 명세 87개를 유지하며 단계별로 구현한다. 준비 작업에서 범위를 축소하거나 저장 구조를 새로 확정하지 않는다.

2026-09-30 로컬 환경에서 Xcode **27.0 (27A266a)**, Swift **6.4**, iPhoneOS / macOS SDK **27.0**, iOS Simulator runtime **27.0**을 확인했다. 설치된 도구 확인은 앱 빌드나 OS 호환성 검증을 의미하지 않는다. 세부 값은 [development-baseline.json](development-baseline.json)에 기록한다.

원본 문서의 제품명 미정 / `Postpone` 작업명과 iOS·iPadOS 18 / macOS 15 권고보다 **이 저장소의 확정 이름과 OS 기준이 우선한다**. 원본 문서의 기술 제안과 미결정 사항은 사용자 승인 사실로 바꾸지 않는다. 식별자 접두사 `com.baserize`는 사용자 지정값이며, 전체 Bundle ID·App Group과 플랫폼별 구성은 아래 후보를 기준으로 결정한다. iCloud container는 아직 미정이다. Ad Hoc 서명 Team은 제공된 프로파일에서 비공개로 확인하며 실제 배포 인증서와의 일치를 검증한다.

## UI 구성요소

미러 UI는 **SwiftUI + SwiftPieces**를 기준으로 제작한다. SwiftPieces 채택은 사용자 지정 결정이다. TaskRow·ExpandableText·StatusMorph 소스를 한국어·MainActor·Mac 대응과 함께 실제 화면에 도입했다. 고정 출처·변경·라이선스는 [도입 기록](Sources/MirrorDesign/SwiftPieces/PROVENANCE.md)을 따른다.

- 초기 확인 기준: [`15e4a68ce09a58f7c93a8043f88fca9ea224af75`](https://github.com/Saivion/SwiftPieces/tree/15e4a68ce09a58f7c93a8043f88fca9ea224af75).
- [공식 사용 방식](https://github.com/Saivion/SwiftPieces/blob/15e4a68ce09a58f7c93a8043f88fca9ea224af75/README.md): 필요한 `registry/swift/` 소스를 UI / Design 계층에 가져와 사용한다. 셰이더를 쓰는 구성요소는 필요한 `.metal` 파일도 포함한다. 각 도입 파일의 원본 경로·커밋·수정 내역을 기록한다.
- [라이선스](https://github.com/Saivion/SwiftPieces/blob/15e4a68ce09a58f7c93a8043f88fca9ea224af75/LICENSE): **MIT + Commons Clause License Condition v1.0**. 앱의 일부로 사용·수정·배포할 때 저작권·허가문을 보존한다. 컴포넌트 자체의 판매·재허가·재배포는 제한된다. 일반 MIT로 표기하지 않는다.
- 초기 검토 대상은 아래 후보에서 실제 화면 요구에 맞춰 선택한다. 화면 구조와 컴포넌트 배치는 시안과 검증으로 결정한다.

| 미러 화면의 역할 | SwiftPieces 검토 후보 |
|---|---|
| 한 줄 입력·수정 | [FormField](https://github.com/Saivion/SwiftPieces/blob/15e4a68ce09a58f7c93a8043f88fca9ea224af75/registry/swift/inputs/FormField.swift) |
| 오늘 목록의 작업 행 | [TaskRow](https://github.com/Saivion/SwiftPieces/blob/15e4a68ce09a58f7c93a8043f88fca9ea224af75/registry/swift/lists/TaskRow.swift) |
| 정리 카드의 긴 내용 펼치기 | [ExpandableText](https://github.com/Saivion/SwiftPieces/blob/15e4a68ce09a58f7c93a8043f88fca9ea224af75/registry/swift/text/ExpandableText.swift) |
| 화면 내부의 분류 선택 | [TrackingTabs](https://github.com/Saivion/SwiftPieces/blob/15e4a68ce09a58f7c93a8043f88fca9ea224af75/registry/swift/navigation/TrackingTabs.swift) |
| 저장·처리 상태 피드백 | [StatusMorph](https://github.com/Saivion/SwiftPieces/blob/15e4a68ce09a58f7c93a8043f88fca9ea224af75/registry/swift/feedback/StatusMorph.swift) |

확인한 후보에는 UIKit 타입·색상 의존성이 있다. 상위 저장소의 [검증 워크플로](https://github.com/Saivion/SwiftPieces/blob/15e4a68ce09a58f7c93a8043f88fca9ea224af75/.github/workflows/swift.yml)는 iOS 26 Simulator 기준이므로 미러의 OS 27·Mac 지원을 증명하지 않는다. 필요한 플랫폼별 수정을 수행하고 iOS / iPadOS / macOS 27에서 각각 빌드와 실제 사용을 검증한다.

컴포넌트 내부 상태는 미러의 날짜·계획·완료 데이터와 분리한다. 입력은 공통 명령 경로로 전달하고 저장 성공 이후 성공 상태를 표시한다. 접근성·한국어 문구·큰 글자·Reduce Motion·Reduce Transparency·실패 복구는 [테스트 전략](TESTING.md)에 따라 확인한다.

## 식별자 후보

사용자 지정 접두사는 **`com.baserize`**다. 아래 값은 이름과 원본의 타깃 제안으로 구성한 **후보**다. 앱의 unsigned 개발 빌드에는 `com.baserize.mirror`와 `com.baserize.mirror.mac`을 적용했지만 Apple Developer 등록·사용 가능 여부·최종 플랫폼 공유 구성은 아직 확인하지 않았다.

| 대상 | 후보 | 결정할 사항 |
|---|---|---|
| iPhone / iPad 메인 앱 | `com.baserize.mirror` | 메인 Bundle ID 추천 후보 |
| Mac 메인 앱 | `com.baserize.mirror` 또는 `com.baserize.mirror.mac` | 플랫폼 간 Bundle ID 공유 여부 |
| iOS 위젯 | `com.baserize.mirror.widgets` | 실제 위젯 타깃 구성 |
| Mac 위젯 | `com.baserize.mirror.widgets` 또는 `com.baserize.mirror.mac.widgets` | Mac 호스트 앱의 Bundle ID에 맞춰 결정 |
| 공유 확장 | `com.baserize.mirror.share` | 지원 플랫폼·호스트 타깃; Mac 별도 ID 사용 시 호스트 접두사에 맞춰 조정 |
| App Group | `group.com.baserize.mirror` | 실제 앱·확장의 그룹 연결과 서명 검증 |

App Group은 같은 개발팀의 앱·확장이 같은 기기의 저장 공간을 공유하기 위한 식별자다. 기기 간 동기화는 별도이며, `com.baserize`는 Apple의 서명 Team ID가 아니다. Mac의 App Group 적용 방식은 서명 Team과 배포 구성이 정해진 후 공유 컨테이너 접근으로 확인한다. iCloud container와 URL scheme은 이 후보 작업에서 확정하지 않는다.

표기와 공유 범위는 Apple의 [App Group 구성](https://developer.apple.com/documentation/xcode/configuring-app-groups) 및 [App Groups entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups) 문서로 확인했다. 원본 05 문서의 가칭 식별자 예시를 덮어쓰지 않는다.

## 압축에서 가져온 자료

`Postpone_Development_Docs_v0.1.zip`의 파일 24개를 원래 이름과 내용 그대로 풀었다.

| 자료 | 용도 |
|---|---|
| [postpone-app-docs/README.md](postpone-app-docs/README.md) | 개발 문서 11개, 계약과 검증 자료의 지도 |
| [Postpone_Development_Spec_v0.1.md](Postpone_Development_Spec_v0.1.md) | 통합 명세 원문 |
| [도메인 fixture](postpone-app-docs/fixtures/domain-cases.json) | 36개 고정 입력과 기대 결과 |
| [QA 명세](postpone-app-docs/validation/qa-cases.json) | 87개 수용 시나리오, 앱 테스트는 모두 미실행 |
| [원본 MANIFEST](postpone-app-docs/MANIFEST.sha256) | 원본 문서·계약 파일 22개의 SHA-256 |
| [구현 순서와 미결정 사항](postpone-app-docs/09_DELIVERY_AND_DECISIONS.md) | D-01부터 D-16까지의 개발 작업과 게이트 |

압축 SHA-256은 `1a1c04c47e408b28bd0120babd4befa31841df9b6238c6211f6ebda79b9f5058`이다. 원본 ZIP은 다운로드 폴더에 보존한다. 원본 자료를 수정해야 한다면 변경된 개발 문서를 별도로 만들고 요구사항 연결을 유지한다.

## 검증 실행

각 push의 Ad Hoc IPA·GitHub Release 자동화와 필요한 서명 Secret 등록은 [Ad Hoc 배포 안내](docs/ADHOC_RELEASE.md)를 따른다. 사용자 승인에 따른 배포 자동화이며 실제 서명·게시 성공은 Actions 결과로 확인한다.

테스트는 **GitHub Actions 러너에서 실행**한다. [Swift workflow](.github/workflows/swift.yml)는 Xcode 27에서 SwiftPM 도메인·SQLite·시스템 테스트와 macOS·iPhone·iPad 앱/확장 빌드 및 실제 UI 테스트를 실행하고 실제 테스트 수와 현재 실행의 로그·xcresult를 보존한다. 기존 [문서 workflow](.github/workflows/validation.yml)는 Python 준비 검증을 계속 수행한다.

`Mirror.xcodeproj`의 공유 scheme은 `MirrorIOS`와 `MirrorMac`이다. iPhone·iPad는 하나의 iOS 앱 타깃을 사용하고 Mac은 네이티브 타깃을 사용한다. 두 앱·확장은 `MirrorDomain`/`MirrorData`/`MirrorSystem`의 공통 경로를 사용하며 `MirrorIOSUI`/`MirrorMacUI` scheme에서 실제 입력·저장·Undo UI를 검사한다. 개발 빌드의 Bundle ID는 후보 `com.baserize.mirror`, `com.baserize.mirror.mac`이며 Apple 등록·서명·App Group·iCloud 설정 완료를 뜻하지 않는다.

타깃 구성, 날짜 규칙, CI 명령과 검증 범위는 [Swift 개발 안내](docs/SWIFT_DEVELOPMENT.md)를 따른다. macOS 27/Xcode 27에서 앱을 실행하려면 `./script/build_and_run.sh` 또는 Codex의 Run 동작을 사용할 수 있다. 테스트 실행은 Actions를 사용한다.

아래 Python 명령은 기존 준비 도구의 설치와 검사 절차를 설명한다. 검사는 Actions에서 실행한다.

Python 3.10 이상이 필요하다. 로컬 검증에는 Python 3.12를 사용했다. `jsonschema` 4 계열은 원본 문서가 이미 요구하는 검증 의존성이다. 별도의 앱 의존성을 추가하지 않았다.

```bash
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python scripts/check.py
.venv/bin/python -m unittest discover -s tests -v
```

`scripts/check.py`는 원본 파일의 무결성을 확인한 뒤 임시 복사본에서 기존 문서 검증을 실행한다. 원본 검증기는 보고서를 덮어쓰므로 보존본에서 직접 실행하지 않는다. 회귀 테스트는 정상 번들과 오류를 주입한 복사본을 검사한다. GitHub Actions도 같은 두 명령을 push / pull request마다 실행한다.

문서 검증, Swift 날짜 도메인 테스트, 앱 빌드, 실제 UI·위젯·Siri·CloudKit 동기화 검증은 각각 다른 증거다. 원본 QA 명세의 미실행 상태는 보존하며 실제 코드의 실행 결과는 [요구사항별 검증 기록](docs/REQUIREMENTS_TRACEABILITY.md)에 별도로 남긴다.

## 개발 착수

최종 목표는 전체 명세의 앱 제작이다. [전체 구현 계획](docs/IMPLEMENTATION_PLAN.md)은 D-01~D-16의 산출물·선행 조건·검증 게이트·외부 준비를, [요구사항 추적표](docs/REQUIREMENTS_TRACEABILITY.md)는 FR 30개·NFR 12개·QA 87개의 구현과 증거를 관리한다. 중간 단계의 골격이나 단위 테스트 통과를 전체 제품 완성으로 기록하지 않는다.

먼저 [개발 지침](AGENTS.md), 원본 문서 01·03·04·06, [테스트 전략](TESTING.md)을 읽는다. 타깃 골격과 날짜 판정은 [Swift 개발 안내](docs/SWIFT_DEVELOPMENT.md)에 기록한다. 타깃·도메인·저장·명령·시스템 통합의 실제 코드와 원격 실행을 확인한 뒤, 서명·등록·실기기·사용자 검증 게이트를 충족한다.
