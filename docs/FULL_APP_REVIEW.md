# 전체 앱 재검토 · 2026-10-03

사용자 목표는 쉽게 넣고 쉽게 미루는 앱, 적절한 화면 분배와 iPhone·iPad·Mac의 실제 수용이다. [원본 24개](../postpone-app-docs/), FR30·NFR12·QA87·D-01~D-16와 G-WIDGET/G-SYNC/G-DELETE/G-UX를 유지한다. 자동화 통과와 실제 기기·계정·사용자 수용을 구분한다. 검증 위치는 GitHub Actions이며 로컬 클라우드에서는 앱 빌드·테스트를 실행하지 않는다.

## 반영한 제품 방향과 구체적인 수정

- 기본 입력은 제목과 저장을 우선한다. 메모·링크·날짜는 접고, 선택한 날짜는 제목과 원자 저장한다. 여러 줄을 모두 저장한 뒤 숨은 메모·링크가 다음 작업에 붙던 경로는 실제 성공 처리에서만 비우도록 수정했다. 실패·pending과 남은 줄은 보존한다.
- 목록에서 내일·날짜를 선택하고, 상세는 요청할 때 연다. 선택하지 않은 상세와 기본 숨긴 iPad 보조 일정이 화면을 차지하지 않는다. iPhone/좁은 iPad는 세 탭, 넓은 iPad/Mac은 탐색·목록·선택 상세를 분배한다. 고급 설정·변경 이력은 별도 진입과 펼침 영역을 사용한다.
- iOS 입력은 시스템 기본 sheet 크기를 사용하고, Mac은 기존 최소·이상 크기를 유지한다. 키보드 위 저장·오류 영역, 44pt 입력 제어, 큰 글자의 재배치를 유지한다. 실제 크기·접근성 수용은 아래 실패와 미검증 항목을 해소해야 한다.
- 입력 presentation은 시작한 scene와 불변 mode/context에 연결한다. 다른 창의 입력이나 오래된 닫기·완료가 현재 요청을 바꾸지 못한다. Cmd-N은 focused scene의 명시적 action을 사용한다. loading 중에는 시작 완료 뒤 요청을 만들며, 공간/관측 세대가 바뀐 기존 입력은 저장 전에 거절하고 원문을 보존한다.
- owner 수명 token은 scene가 보유하고 coordinator는 weak reference만 가진다. 실제 owner가 해제되면 다음 명시적 open에서 오래된 요청을 회수한다. onDisappear·focus·scenePhase만으로 미저장 입력을 종료하지 않는다. SwiftUI State/FocusedValue/대기 Task의 실제 창 종료 후 해제 시점은 native 미검증이다.
- 메뉴 막대는 제출 토큰과 원문 snapshot을 보유하고, canonical 저장·projection 갱신이 확인된 제목 receipt만 처리한다. 모델은 등록된 메뉴 막대 token 하나의 성공 결과를 보관하므로 다른 창의 성공이 이를 덮지 않는다. 자기 성공일 때만 token을 교체하며, 이전 제목 재시도가 성공해도 새로 편집한 제목은 비우지 않는다. 다른 입력의 receipt·실패·pending은 원문을 지우지 않고, 로컬 진행 중 guard로 연속 클릭을 막는다. 실제 메뉴 막대 재시도·키보드 수용은 별도 native 검증 대상이다.
- 반복 snapshot의 원본 정렬은 actor 내부에서 재사용하고 모든 원본 쓰기에 무효화한다. Lamport/deviceUUID/operationID 순서, refresh 뒤 identity 확인, history·Undo·Cloud 계약을 유지한다. 실제 별도 연결·import·중복·삭제 뒤 캐시 무효화 회귀를 작성했다. cold/변경 뒤 첫 조회는 전체 정렬하고 메모리 buffer 하나를 더 보유한다.

입력 소유권 suite에 pure state4개와 MainActor coordinator2개를 작성했다. 같은 owner의 id/mode/context 불변, 다른 owner 거부, stale close/finish 거부, single/continuous, 실제 weak 해제와 다음 owner 수용을 확인한다. 알림은 기존 review/task allowlist를 유지하고 capture 거부 assertion2개를 추가했다. 이는 작성한 회귀이며 실행 결과가 아니다. 상세의 기존 task ID·claim·관측 세대 보호를 뚫는 잘못된 작업 저장 반례는 이번 정적 검토에서 확인하지 못했다.

## 확인한 Actions 증거

이 표는 입력 owner 보완 이전 소스 `10d2495dd2b9ce4e1d4ba0c7615712d40bf639fc`에 귀속된다. 후속 수정의 성공으로 옮기지 않는다.

| 경로 | 실제 관측과 한계 |
|---|---|
| 문서·준비233/234 | push/PR 성공. Swift/native UI 수용을 대신하지 않는다. |
| [Adaptive21](https://github.com/hellosunghyun/mirror/actions/runs/37139729038) | iPhone/iPad/Mac system SDK·앱/runner 빌드 성공 뒤 UI 실패. 고정 사례·조회·audit 경계와 실제 큰 글자 환경을 확인했으나 공식 case counts·AX issue·실패 원인은 미확정이다. |
| [Batch10](https://github.com/hellosunghyun/mirror/actions/runs/37139729014) | iPhone/iPad/Mac SDK 빌드 성공 뒤 UI 실패. Mac 두 method는 close query matching snapshot 경계, iPad 진단은 빈 배열이다. typed2·실패0·skip0 수용은 확보하지 못했다. |
| [Dark55](https://github.com/hellosunghyun/mirror/actions/runs/37139729237) | Domain과 세 플랫폼 native 빌드/단위·통합·구성 단계 성공 뒤 세 UI 모두 실패했다. 게시 단계는 skipped이며 공식 UI 수·사진·접근성 원인은 미확정이다. |
| [Basic98](https://github.com/hellosunghyun/mirror/actions/runs/37139729196) | 준비·Secret presence와 iOS/Developer ID 사전검사 성공. 도메인/Mac190개와 iPhone/iPad187개 단위·통합 통과 뒤 세 UI 모두 실패했다. iPhone/iPad에는 명시적20분 timeout이 있었고 Mac은 timeout 원인을 확인하지 못했다. 전체 실행은 실패, IPA·공증 DMG·Release 게시는 skipped다. |
| [성능6](https://github.com/hellosunghyun/mirror/actions/runs/37139859105) | 동일 소스의 실제 SQLite baseline 완료·PASS. 명령20회 모두 locallyCommitted/500ms 미만, command p95 392.144084ms·snapshot p95 77.794667ms·export p95 21142.986916ms와232052338byte. 원본·상태 왕복과 중복 import를 확인했으나 앱 UI·실기기·Widget·EventKit·Q086 수용은 별도다. |

후속 입력 owner·메뉴 소스 `414f7b5695d9958fd094cd21d7032a78b479c965`에서는 Adaptive22 세 플랫폼 앱과 UI 러너 빌드가 실제 성공했지만 system UI는 모두 실패했다. 입력 제목/목록 미루기의 스크롤 접근, capturePlanToday 고유 조회, 전체 audit 경계를 관측했으며 실제 AX 값·audit 종류·원인은 미확정이다. Batch11도 세 SDK 빌드 성공 뒤 세 UI가 실패했고 Mac 두 사례는 닫기 조회의 matching snapshot 실패였다. Dark56와 Basic99의 네 native 경로는 `cannot use mutating member on immutable value` compiler 오류로 실패하고 UI는 skipped다. Dark56의 고정 operand는 `$0`였으며 annotations 행 번호는 로그 위치이므로 Swift source 행으로 쓰지 않는다.

새 pure state 회귀의16개 mutating 호출을 별도 Bool로 계산한 뒤 동일한 기대값을 검사하도록 분리해 호출 순서·인자·횟수·테스트16개와 기존 테스트를 유지했다. 이 보완 소스 `68e2c73110a1f6510cf3c6d958f1e9b21ae06396`의 [Swift224](https://github.com/hellosunghyun/mirror/actions/runs/37146464759)는 실제 SwiftPM 성공과 iPhone/iPad 앱·확장 빌드/단위·통합·구성 단계 성공을 확인했다. 같은 소스의 [Dark57](https://github.com/hellosunghyun/mirror/actions/runs/37146461576) Mac/iPad native 단계도 성공했다. 개별 테스트16개 실행 기록과 숫자는 로그 조회 실패로 미확인이며, UI 최종 수용·사진·배포를 대신하지 않는다. [Basic100](https://github.com/hellosunghyun/mirror/actions/runs/37146461553)의 iOS 인증서/프로파일과 Developer ID 사전 검사는 성공했고 native/UI·현재 자산 수용은 별도다.

추가 정적 검토에서 Batch의 초기 launch 확인이 Swift error를 던지면 호출자 defer가 등록되지 않아 자기 앱 종료를 건너뛰는 경계를 찾았다. 기존 초기 조회 두 개와 반환을 do/catch로 감싸 같은 XCUIApplication을 종료한 뒤 원래 오류를 다시 던진다. 성공 경로와 기존2사례·53assertion·8XCTFail·기대값·시간·typed gate는 유지한다. 실제 잔류 프로세스나 기존 UI 실패 원인의 해결은 확인하지 못했으며, 이 마지막 보완의 SDK/UI 수용은 새 소스의 Actions에서 확인해야 한다. Simulator 재사용·Mac GUI session·고정 checkout 경로는 외부 runner 격리를 전제로 하지만 실제 host 공유/충돌은 미관측이므로 이를 원인으로 단정하지 않는다.

불투명 sRGB 팔레트의 기본 전경/배경10조합은 정적 계산에서 모두 대비4.5 이상이었다. 실제 투명도·시스템 제어·렌더링 배경과 native audit 통과를 대신하지 않는다.

Native6사례·46장과 기존 assertion/실패 조건, Batch2사례의 typed gate, Adaptive의 전체 접근성 audit와 시간 제한을 유지한다. 테스트를 skip하거나 실패 조건을 약화하지 않는다. 공개 SDK에서 auditType 및 nullable element 선언, optional throwing Issue→Bool signature는 관측했으나 true/false의 의미는 확인하지 못했다. handler 추정이나 사전 issue 무시를 추가하지 않는다.

## 출시 전에 남은 조건

| 영역 | 남은 일과 선행 조건 |
|---|---|
| UI·접근성 | 현재 소스의 밝은/어두운 원본, 큰 글자·좁은 창·일괄 선택 실패 원인과 수정 검증. 실제 VoiceOver·키보드·Reduce 설정·iPad Split View는 별도 기기 수용이다. |
| 다중 창 | Mac/iPad에서 dirty 입력 A와 B의 open/close/URL·Cmd-N, owner 창 종료, 다른 창의 Settings 공간 교체, stale 저장 원문 보존과 명시 재열기를 확인해야 한다. 창별 독립 선택/포커스와 네이티브 종료 시 초안 보호도 남아 있다. |
| 메뉴 막대 | 자기 token·실제 성공 제목과 원문 snapshot으로 pending 재시도 성공·새 편집 보존을 보완했다. 실제 native 실패 주입·재시도·다른 창 receipt·빠른 클릭·포커스 전달의 수용은 아직 미관측이다. |
| 시스템 표면 | 실제 등록된 App Group·iCloud Container와 entitlement/프로파일 연결이 필요하다. 빈 값·후보 ID·임시 저장 경로를 Widget/Share/두 기기 성공으로 기록하지 않는다. 알림·Siri·Spotlight는 실제 OS 진입과 현재 공간/노출 정책을 확인한다. |
| 전체 Cloud 삭제 | 서버의 권위 있는 삭제 세대, 소유 zone 삭제와 구세대 offline exporter 차단이 미구현이다. 상태 안내만 지원하며 blocked를 유지한다. 실제 사용자 데이터를 임의 삭제하지 않는다. |
| 대용량·배포 | cold open/paging·Spotlight 증분·실기기 메모리와 큰 백업 UI를 측정해야 한다. 새 소스의 UI gate·서명·공증·게시 성공과 공개 자산의 source/checksum을 확인해야 한다. |

이전 성능5의 실제 SQLite1만작업·10만원본 측정은 command p95 249.236375ms, 첫 command 1455.864959ms, snapshot p95 708.51775ms, export p95 14246.83775ms와232052338byte였다. 전체100020기록 복원과 두 번째 import0inserted는 확인했으나 실제 앱 UI/메모리 수용으로 대신하지 않는다. 성능6의 반복 snapshot 측정은 낮았지만 command/export p95는 이전 run보다 높았으며, 서로 다른 runner 실행만으로 모든 동작의 개선이나 원인을 확정하지 않는다. 현재 앱에는 예전32MiB 복원 상한이 없다.

[전체 제작 계획](COMPLETION_PLAN.md), [요구사항 추적표](REQUIREMENTS_TRACEABILITY.md), [간편 UX](SIMPLE_UX.md), [UI 검토](UI_REVIEW.md), [일괄 배치](BATCH_UI_REVIEW.md)를 함께 따른다. 코드 수정·부분 Actions 성공·과거 자산을 전체 제품 또는 QA87개 수용 완료로 표현하지 않는다.
