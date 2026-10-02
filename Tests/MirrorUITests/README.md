# 앱 UI 검증 범위

`MirrorUITests.swift`의 같은 XCTest 소스를 `MirrorIOSUI`(iPhone·iPad)와 `MirrorMacUI`에서 실행한다. 실행 위치는 GitHub Actions다. 로컬 클라우드에서 앱 빌드나 테스트를 실행하지 않는다.

앱에 `MIRROR_UI_TESTING=1`과 `MIRROR_TEST_DATE=2026-09-30T03:00:00Z`를 전달한다. 제목·계획 데이터는 UI 입력으로만 만든다. 앱이 자신의 임시 디렉터리에 새 UUID의 실제 Core Data 저장소를 열고 계획 시간대는 Asia/Seoul로 고정한다. 저장소 경로 주입, 작업 seed, mock 성공, skip은 사용하지 않는다.

별도 어두운 모양 검증은 같은 테스트 소스의 `MirrorIOSUIDark`·`MirrorMacUIDark` shared scheme을 사용한다. TestAction의 명시한 `MIRROR_UI_APPEARANCE=dark`를 runner에서 앱으로 전달하며, 앱은 DEBUG·UI testing일 때만 main window에 `.preferredColorScheme(.dark)`를 적용한다. 기본 scheme과 Release 앱에는 강제 모양을 적용하지 않는다. 전역 시스템 모양은 바꾸지 않으며 메뉴바·시스템 창·키보드 전체의 모양을 main window 설정만으로 보장하지 않는다. 실제 전달과 원본43장의 어두운 렌더링은 해당 Actions 실행에서 확인한다.

| 테스트 | 요구사항·QA 연결 | UI에서 확인하는 상태 |
|---|---|---|
| Capture → 오늘 명시 배치 | FR-001/006, Q-001/009 | 입력 후 unassigned·미완료이고 Today에 없음. 오늘 선택 이후 정확한 날짜·미완료 상태로 Today에 표시 |
| 내일 → 보관함 검색 | FR-003/006, Q-008/010 일부 | 서울 9/30의 내일인 10/1을 표시. Today에는 없고 검색·상세로 조회 가능. Mac은 Today에서 실제 Cmd+F로 보관함을 열고 입력란의 키보드 포커스를 확인. Q-008의 다음 달 날짜와 별개인 미래 계획 검색 사례 |
| 501자 오류와 복구 | FR-001, Q-003 | 501개 ASCII 확장 문자소를 입력. 오류 표시 후 원문 전체 유지·작업 생성 없음. 이후 정상 제목은 저장 가능 |
| 주 패널 취소·부분 종료 | FR-007/011, Q-016/019 일부 | 두 작업 중 하나만 오늘 배치. 남은 카드에서 다음 주 패널을 열고 취소해 카드 유지. 종료 후 남은 항목 unassigned·Today 제외. Q-019의 10개 중 6개와 같은 불변식을 더 작은 실제 입력으로 검사 |
| 제목 편집·완료·Undo | FR-013/015 | 실제 제목 편집 후 완료 라벨 변경, 계획 유지. 직전 status 변경 Undo 이후 편집 제목·오늘 계획·미완료 상태 유지 |
| 정리 배치 Undo | FR-015, Q-029 일부 | 내일 결정 후 Undo가 같은 제목의 카드와 이전 unassigned 계획을 복원. Today에는 없음. reviewNotBefore 내부 값과 버전 거부는 별도 저장·도메인 검증 대상 |

소스 작성은 실행 통과를 의미하지 않는다. 실제 commit·플랫폼·실행 수·xcresult·성공/실패는 Actions 결과를 확인한 뒤 파생 검증 기록에 남긴다. 원본 QA 보고서는 변경하지 않는다.

501자 제목 사례는 실제 표시 문구가 제목 길이만 안내하는지도 검사한다. 기존 `displayedText`가 비어 있지 않은 label을 우선하고 빈 label일 때만 value를 사용해 플랫폼별 접근성 표시를 읽으며, 문구 전체의 일치는 유지한다. 제목·메모·링크 오류는 기존 `TaskContent`가 거부한 원인에 맞춰 표시하며 입력 원문·검증·저장 규칙은 유지한다. 잘림 금지·오류 가시성·키보드 경계·정상 입력 복구 검사도 그대로 실행한다.

이 자동화는 기본 앱 행동의 증거다. 한국어 조합 입력·이모지 경계, VoiceOver 실제 탐색, 가장 큰 글자, Reduce Motion, iPad 좁은 창, Mac의 전체 키보드 전용 흐름(Cmd+F 일부 제외), 강제 종료·재시작, 저장 실패 주입, 오래된 버전 Undo 거부, Widget/Siri/Share·권한·실기기·두 기기 CloudKit·전체 삭제는 이 UI smoke로 검증하지 않는다.
