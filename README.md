# 미러(Mirror)

> 잘 미루면, 지금 할 일이 남는다.

미루기와 재결정 최소화를 중심으로 하는 iPhone / iPad / Mac 앱의 제작 준비 저장소다. 개발 명세, JSON 계약, 도메인 fixture, QA 명세와 자동 검증을 포함한다. 앱 구현과 Xcode 프로젝트 생성은 다음 개발 작업이다.

## 확정된 개발 기준

- 앱 이름: **미러(Mirror)**. 한국어 표시명은 `미러`, 영문 이름은 `Mirror`.
- 이름의 의미를 설명해야 할 때만 **‘미뤄’를 표현한 이름**이라고 설명한다. 일반적인 앱 이름 표기는 `미러`를 사용한다.
- 개발 및 최소 배포 기준: **iOS 27.0 / iPadOS 27.0 / macOS 27.0**.
- GitHub 저장소: **hellosunghyun/mirror**, **private**.
- 테스트코드를 적극 활용한다. 날짜·도메인·명령 규칙은 테스트부터 작성하고, 버그 수정에는 재현 회귀 테스트를 함께 추가한다.
- 제품 요구사항 30개와 QA 명세 87개를 유지하며 단계별로 구현한다. 준비 작업에서 범위를 축소하거나 저장 구조를 새로 확정하지 않는다.

2026-09-30 로컬 환경에서 Xcode **27.0 (27A266a)**, Swift **6.4**, iPhoneOS / macOS SDK **27.0**, iOS Simulator runtime **27.0**을 확인했다. 설치된 도구 확인은 앱 빌드나 OS 호환성 검증을 의미하지 않는다. 세부 값은 [development-baseline.json](development-baseline.json)에 기록한다.

원본 문서의 제품명 미정 / `Postpone` 작업명과 iOS·iPadOS 18 / macOS 15 권고보다 **이 저장소의 확정 이름과 OS 기준이 우선한다**. 원본 문서의 기술 제안과 미결정 사항은 사용자 승인 사실로 바꾸지 않는다. Bundle ID, App Group, iCloud container, 서명 Team은 아직 미정이다.

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

Python 3.10 이상이 필요하다. 로컬 검증에는 Python 3.12를 사용했다. `jsonschema` 4 계열은 원본 문서가 이미 요구하는 검증 의존성이다. 별도의 앱 의존성을 추가하지 않았다.

```bash
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python scripts/check.py
.venv/bin/python -m unittest discover -s tests -v
```

`scripts/check.py`는 원본 파일의 무결성을 확인한 뒤 임시 복사본에서 기존 문서 검증을 실행한다. 원본 검증기는 보고서를 덮어쓰므로 보존본에서 직접 실행하지 않는다. 회귀 테스트는 정상 번들과 오류를 주입한 복사본을 검사한다. GitHub Actions도 같은 두 명령을 push / pull request마다 실행한다.

문서 검증, 준비용 회귀 테스트, Swift 앱 테스트는 각각 다른 증거다. 현재 자료의 Swift 구현 / UI / 위젯 / Siri / 실제 CloudKit 동기화 테스트는 미실행이다.

## 개발 착수

먼저 [개발 지침](AGENTS.md), 원본 문서 01·03·04·06, [테스트 전략](TESTING.md)을 읽는다. 이후 원본 D-01의 타깃·식별자 결정과 D-02의 날짜 규칙부터 진행한다. 저장 구조와 시스템 통합은 원본의 검증 게이트를 따른다.
