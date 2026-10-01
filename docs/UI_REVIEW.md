# iPhone·iPad·Mac UI 검토

2026-10-01 사용자가 보낸 Mac 화면에서 상세가 목록보다 넓고, 완료 버튼이 패널 전체로 늘어나며, 저장·완료·Undo 안내가 사이드바 아래에서 중복되는 문제를 확인했다. 기존 여섯 UI 테스트는 기능 흐름을 검증했으나 화면의 배치와 위계를 검증하지 않았다.

## 변경한 화면

| 영역 | 변경과 유지한 행동 |
|---|---|
| 탐색과 상세 | iPhone은 네이티브 탭과 compact inspector 시트. iPad/Mac은 두 열의 사이드바·목록과 선택한 작업의 inspector. 상세 열은 280–380pt, 기본 340pt다. 넓은 iPad에서는 작업을 선택하지 않았을 때 일정이 인접한다. 화면을 옮길 때 관련 없는 상세는 닫지만 미저장 편집은 유지한다. |
| 오늘과 보관함 | 날짜·오늘 정리를 먼저 보여 주고 재정리·재개는 옵션 메뉴에 둔다. 검색·필터·여러 개 선택을 작은 영역으로 묶고 불필요한 Form 구분선을 줄인다. |
| 작업 행 | SwiftPieces의 체크를 18–20pt로 줄이며 44pt 클릭·터치 영역과 실제 완료·보관·휴지통 명령을 유지한다. 큰 검정 카드 대신 작은 여백과 선택 강조를 쓴다. |
| 상세 | 제목·상태·계획·실제 마감을 구분한다. 변경 이력과 관리는 펼침 영역에 둔다. Mac 완료·저장 버튼은 최대 200×44pt, 모바일은 터치 영역을 유지한다. |
| 상태 안내 | 목록 하단에 작은 저장·실패·Undo 안내를 둔다. 저장 성공 문구를 중복 표시하지 않으며 마지막 Undo 자체를 자동 만료시키지 않는다. |
| 일정·설정 | 폭에 맞춘 날짜 카드와 실제 마감의 별도 표시, 읽기 전용 약속의 종일·시간 구분. 설정은 관련 기능별 grouped Form과 설명 footer, 시간대 변경 펼침을 사용한다. |

데이터·명령·날짜 불변식과 SwiftPieces 저작권·MIT + Commons Clause 고지를 보존한다. 새로운 디자인 의존성이나 사용자 자료 전송을 추가하지 않는다.

## 실제 화면 증거

테스트와 앱 빌드는 GitHub Actions에서만 실행한다. [수정 전 화면 실행](https://github.com/hellosunghyun/mirror/actions/runs/36881520763)은 UI 캡처 변경 `728d682`를 사용하며 앱 화면 소스는 이전 배포와 같다. Mac·iPhone은 각각 실제 UI 6개와 guard를 통과했으나 SDK export 이름의 파싱에서 실패했다. iPad는 완료한 두 사례 통과 뒤 UI 20분 제한으로 중단되어 전체 UI 결과·필수 앱샷 완료를 확보하지 못했다. 수정 전 전체 시각 검증 통과로 기록하지 않는다.

[UI 수정본 실행](https://github.com/hellosunghyun/mirror/actions/runs/36883100875)의 Mac·iPhone은 실제 단위 및 UI 6개·guard를 통과했다. Mac의 새 버튼 크기·미저장 편집 회귀도 포함한다. iPad는 Simulator의 테스트 runner를 실행하지 못해 UI 여섯 사례가 실행되지 않았다. 이 결과를 제품 UI assertion 실패나 통과로 기록하지 않는다. 앱샷 게시의 SDK 이름 문제는 별도로 확인한다. 후속 변경은 실제 PNG와 모든 기능 assertions·실행 제한을 유지하고, 캡처마다 반복하던 추가 접근성 진단 조회를 없애 viewport만 기록한다. [후속 실행 36886881234](https://github.com/hellosunghyun/mirror/actions/runs/36886881234)에서 동일 UI 소스의 Mac·iPhone·iPad 모두 단위 검사 및 UI 6개·guard를 통과했다. iPad의 runner 기동 실패는 재현되지 않았고 기존 20분 제한 안에서 완료됐다. 이 실행은 이전 attachment parser를 사용해 PNG 준비 단계에서 실패했다. 별도 [SDK 검사 36888814412](https://github.com/hellosunghyun/mirror/actions/runs/36888814412)는 실제 SDK suffix와 Mac PNG 14개의 이름·내용·필수 화면 정규화를 확인했고, 새 parser 회귀를 포함한 준비 검사 120개가 통과했다.

새 전체 실행에서 Mac 단위 검사의 별도 Python 잠금 helper가 5초 안에 준비 신호를 보내지 못한 사례도 있었다. 원인 구분을 위해 실제 `/usr/bin/python3` 의존성 준비와 진입·잠금 직전의 고정 marker 진단을 추가했다. 원래 5초 획득·종료·회수 계약과 PID·SIGTERM·원본·멱등성 assertions는 유지한다. 모바일 UI 직전에는 단위 검사와 같은 runtime·Simulator의 준비 상태를 다시 확인하며 공유 기기를 강제로 재부팅하지 않는다.

[실행 36890839642](https://github.com/hellosunghyun/mirror/actions/runs/36890839642)의 Mac 단위159/UI6·iPad 단위156/UI6와 guard·PNG 준비는 성공했지만 iPhone은 기존 20분 제한에서 첫 다섯 사례 통과 후 마지막 주 패널 사례를 완료하지 못했다. 세 플랫폼 전체 성공·앱샷 시각 수용·새 배포로 계산하지 않는다. 실제 입력·hittable/enabled/스크롤·행 중심 경계·실패 시 상세 진단과 모든 assertions는 유지하고, 성공마다 반복하던 상세 진단 조회 및 검증에서 쓰지 않는 캡처 viewport/JSON 조회를 제거했다. 캡처는 실제 PNG와 고정 stage의 소요시간만 남긴다. iPad의 실제 회전 확인을 위한 경계 조회와 Mac 완료 버튼 크기 assertions는 그대로다.

[실행 36896318693](https://github.com/hellosunghyun/mirror/actions/runs/36896318693)의 Mac 단위159/UI6·iPhone 단위156/UI6는 실패·skip 없이 통과했다. iPad는 단위156 통과 후 UI 첫 다섯 사례가 통과했고, 마지막 주 패널 사례 시작 뒤 기존 20분 제한으로 중단됐다. 세 플랫폼 화면 자료는 게시되지 않았다. 후속 수정은 고유 ID의 첫 hittable 요소를 우선하고, 중복 modal ID에서는 기존 전체 검색을 유지한다. 행 소유·창·열의 실제 검증과 실패 진단은 유지하며 같은 label·불필요한 후보 진단 속성의 반복 조회를 줄인다. UI runner의 첫 컴파일을 별도 준비 단계에서 끝내고 현재 실행의 SHA·build·destination·빌드 산출물을 확인한 뒤 UI를 실행한다. Mac15분·모바일20분의 실제 UI 검사 제한과 전체45분·단위20분 제한, 여섯 사례·최종 guard는 유지한다. 실제 사례·캡처 시간은 범위를 제한한 진단으로 남기며 통과 판정에 사용하지 않는다.

[실행 36904124380](https://github.com/hellosunghyun/mirror/actions/runs/36904124380), `85d12c2`·build30은 세 플랫폼의 실제 UI 6개씩 모두 통과했다. UI 실행은 Mac427초·iPhone661초·iPad885초였고 같은 실행의 UI 컴파일 및 빌드 산출물 receipt 검증이 성공했다. [화면 Release](https://github.com/hellosunghyun/mirror/releases/tag/ui-review-36904124380)의 46개 자산·PNG43장과 [설치 Release](https://github.com/hellosunghyun/mirror/releases/tag/adhoc-36904124380)의 8개 자산을 공개 다운로드하여 SHA/build/run/attempt·파일 크기·SHA256을 확인했다. Mac 공증·staple·Gatekeeper와 iOS 서명·프로파일 게이트도 통과했다.

**이 실행의 실제 PNG43장을 모두 직접 열어 검토했으며 시각 수용에는 실패했다.** 기본 밝은 화면에서 Mac 상세를 열 때 1024pt 화면 밖으로 창이 커져 왼쪽이 잘렸고, plain 입력·날짜 Form의 여백이 부족했다. iPad 선택행의 흰 글씨와 옅은 배경 대비, 범위를 넓힌 검색의 잘못된 섹션 제목, iPhone 긴 입력 후 키보드 위 오류·저장 표시, 모달 파란색과 본 화면 녹색의 혼용을 확인했다. iPad 가로 캡처는 회전한 내용과 검은 띠가 있어 정상 가로 증거로 사용할 수 없었고, 첫 iPhone 입력 캡처에는 시스템 키보드 안내가 남았다. 입력 원문·완료·Undo 기능의 실패로 확대 해석하지 않는다.

후속 수정은 화면에 맞춘 Mac 새 창·Zoom과 inspector의 탐색 최소 폭, 명시적인 선택행 색, 검색 제목, grouped Form·모달 강조색, 키보드 위 고정 오류·저장 footer를 적용한다. 실제 Mac 창 경계·검색 제목·오류와 저장의 표시 회귀를 추가한다. iPad 회전은 기존15초 안에서 실제 창·열·날짜 제어의 안정된 배치를 확인하고, iPhone은 정확한 키보드 안내와 Continue가 함께 있을 때만 닫는다. 기존 여섯 사례와 모든 기능 assertions·guard·실행 제한·원본 앱샷43개를 유지하며 새 실제 PNG로 다시 확인한다.

[후속 실행36916034507](https://github.com/hellosunghyun/mirror/actions/runs/36916034507), `fae3ac0`·build31은 준비·도메인만 통과했고 세 플랫폼 앱 빌드가 `MirrorApp.swift`의 조건부 modifier와 메뉴바 Scene이 같은 블록에 있는 구문 오류로 실패했다. UI·receipt는 실행되지 않았고 새 자료·앱도 게시되지 않았다. modifier와 별도 Scene의 조건부 블록을 분리하며 이 결과를 UI assertion 실패나 시각 수용으로 계산하지 않는다.

[후속 실행36917186594](https://github.com/hellosunghyun/mirror/actions/runs/36917186594), `e39e2da`·build32는 세 플랫폼 실제 SDK 컴파일·UI 산출물 receipt를 통과했다. Mac UI6개는 모두 통과했고 새 창 경계 검사도 포함한다. iPhone은5개 통과·첫 입력 사례1개 실패이며 `keyboard.keys.firstMatch.isHittable`의 assertion을 확인했다. iPad는4개 통과·입력 및 긴 입력 사례2개 실패와 실제 UI 단계20분 중단을 확인했으나 정확한 assertion 위치는 공개 페이지에서 확인되지 않았다. 별도 SwiftPM의 `independentInstancesDeduplicate`에서 동일 요청의 `.alreadyApplied` 결과 한 개를 기대하는 회귀도 실패했다. 완료 보고의29개 run을29개 실패나 특정 target으로 추정하지 않는다. 새 화면·설치 자료는 게시되지 않았다.

후속 수정은 정확한 키보드 안내를 앱 접근성 범위에서 찾되 실제 키보드 안의 유일한 `Continue`만 닫고, 접근성 목록의 첫 키 대신 키보드 안에서 누를 수 있는 입력 키를 기존15초 안에서 확인한다. 입력 sheet를 열었을 때 배경의 오류 안내를 중복 표시하지 않는다. 독립 저장소 회귀는 기존 assertions를 유지하고 두 반환 state와 고정 busy 안내의 일치 여부만 안전하게 기록한다. 원본·식별자·오류 원문을 공개하지 않으며, 실제 반환 상태가 없는 현재 결과만으로 저장 중복이나 잠금 실패를 단정하지 않는다. 모든 시간 제한·여섯 UI 사례·43개 원본 앱샷을 유지한 새 실행으로 검증한다.

[후속 실행36923295197](https://github.com/hellosunghyun/mirror/actions/runs/36923295197), `ba2f042`·build33은 별도 SwiftPM159개·Mac UI6개·iPhone UI6개가 통과했다. Mac 실제 UI531초·iPhone957초와 각 컴파일·receipt를 확인했다. 동시 저장 진단은 locallyCommitted·alreadyApplied 각1개와 busy=false·false였지만 이전 실패 원인 해결로 단정하지 않는다. iPad는 컴파일172초와 receipt를 통과했으나 첫 입력 사례가35.848초에 실패했다. 긴 입력 오류를 포함한 나머지5개는 stdout의 통과 기록을 확인했고 UI 단계는20분 한도로 중단됐다. xcresult 완료 보고와 정확한 실패 파일·줄·assertion 종류는 없어 원인을 보류한다. 화면·설치 게시가 모두 skipped되어 새 PNG는 없다.

후속 진단은 첫 UI 실패의 고정 상대 경로·줄·baseline 메서드·검사 종류만 먼저 출력한다. iPad 회전 실패에는 기존 조건을 평가하며 읽은 bool·안정 샘플 수·경과 시간만 기록하고 추가 AX 조회는 하지 않는다. 원문 메시지·좌표·제목·절대 경로를 이 구조화 진단에 넣지 않는다. 모든6사례·43개 원본 앱샷과 기능 assertions·기존 제한을 유지한다. 진단 추가를 UI 수정 성공이나 시각 수용 완료로 계산하지 않는다.

[후속 실행36929811543](https://github.com/hellosunghyun/mirror/actions/runs/36929811543), `3c2c00e`·build34는 준비·별도 SwiftPM159개·Mac UI6개가 통과했다. iPhone과 iPad는 각각 첫 입력 사례1개 실패·나머지5개 stdout 통과와 실제 UI 단계20분 중단을 확인했다. iPhone 최초 실패는 키보드 안내의 유일한 Continue 후보 수 검사(`MirrorUITests.swift:323`, `XCTAssertEqual`)이며 실제 후보 수는 공개 결과에서 확인되지 않았다. iPad 최초 실패는 기존 회전 viewport 검사(`MirrorUITests.swift:503`, `XCTFail`)다. 실제 관측한14개 조건에서 앱·창·오늘 목록·달력의 존재·방향·포함 관계는 통과했고, 목록과 달력의 열 경계 비중첩 조건만 false였다. 나머지 단락 평가로 조회되지 않은 조건은 false로 기록하지 않는다. 이 접근성 경계 결과를 실제 PNG의 시각적 겹침으로 단정하지 않는다. 모든 화면·설치 게시가 skipped되어 새 PNG·앱은 없다.

후속 UI 수정은 넓은 iPad에서 목록과320pt 달력을 실제 나란한 열로 배치하고, 각 열의 탐색 제목을 독립적으로 유지한다. 선택 작업은 기존 native inspector를 사용한다. 키보드 안내 처리에서는 유일한 정상 Continue가 준비될 때까지 기다리는 시간과 tap·안내 닫힘이 기존 단일15초 마감 안에 들도록 한다. 후보 수1개와 hittable·enabled·키보드 포함 관계, 이후 실제 입력 키 검사 및 기존 모든 assertions는 유지한다. 사용자에게 보이는 변경 이력 버튼은 ‘이 변경 되돌리기’로 간단하게 표시하고 실제 Undo 보호 조건은 유지한다. 실패 안내는 고정 phase·후보 수·키보드 경계 유효 여부·경과 시간만 허용한다. 여섯 UI 사례·43개 원본 앱샷·모든 검사 제한을 유지하며 실제 SDK와 새 PNG에서 검증한다.

목표 화면은 아래와 같으며 최종 게시 여부는 해당 실행으로 확인한다.

| 플랫폼 | 명명된 앱 화면 |
|---|---|
| iPhone | 오늘 빈 화면, 입력, 일정, 설정, 보관함, 정리 카드, 오늘 목록, 검색, 상세, 상세 편집, 완료, Undo, 주 날짜 선택, 입력 오류: 14장 |
| iPad | 같은 14장과 실제 기기 회전 후 가로 viewport 화면: 15장 |
| Mac | 같은 14장: 14장 |

각 화면은 실제 XCUITest 입력과 Core Data 저장 경로의 `XCTAttachment(app.screenshot())`다. 성공 mock·작업 seed·이미지 생성·임의 합성 화면으로 대체하지 않는다. 고정 테스트 날짜와 합성 작업 제목을 사용한다. 실제 기기 전체 화면·영상·원본 attachment JSON·로그는 공개 검토 폴더에서 제외한다.

현재 checkout SHA, 실제 앱의 `CFBundleVersion`, Actions run·attempt를 확인한다. 실제 SDK의 `xcresulttool export attachments --help`를 먼저 확인하고 명명된 앱샷만 추출한다. 세 플랫폼·각 필수 화면·PNG 내용·checksum·manifest의 SHA/build/run/attempt가 맞지 않으면 검토 자료를 게시하지 않는다.

각 성공 실행의 별도 `ui-review-RUNID` prerelease에는 PNG 43장과 안전 manifest·`SHA256SUMS`·`ui-review.html`이 있다. HTML을 내려받으면 포함된 PNG를 브라우저에서 함께 볼 수 있다. 앱 배포의 `adhoc-RUNID`에 있는 IPA·DMG와 여덟 자산 계약은 유지한다.

## 수용 기준과 검증 한계

- 기존 여섯 UI 흐름의 실제 완료·실패 0·skip 0와 모든 필수 메서드를 확인한다. assertion·guard·실행 제한을 낮추지 않는다.
- Mac 완료 버튼의 실제 접근성 경계가 폭 220pt·높이 46pt를 넘지 않는 회귀를 추가했다. 목표 버튼 최대 200×44pt에 네이티브 렌더링 경계 오차를 허용한 검사다.
- Mac에서 미저장 상세 편집 중 빠른 입력을 열고 닫은 뒤 보관함·오늘로 이동해도 입력이 유지되는 경로를 확인한다.
- 실제 PNG를 열어 탐색·상세·버튼 위계, 겹침·잘림, 모바일 키보드·시트, iPad 가로 일정, 오류 문구를 검토한다. 테스트 통과나 앱샷 생성만으로 시각 수용을 완료 처리하지 않는다.
- 이 캡처는 각 러너가 선택한 기본 화면 크기·모양이다. 모든 창 크기·양쪽 색상 모드·가장 큰 Dynamic Type·VoiceOver·실기기 입력의 완료 증거는 별도로 남겨야 한다.

최종 실행 결과와 직접 화면 검토 결과는 [PR #2](https://github.com/hellosunghyun/mirror/pull/2)의 검증 기록 및 연결된 run·`ui-review` Release로 확인한다. QA 87개 전체 수용과 App Group·iCloud·위젯·Siri의 실기기 수용을 이 UI 검토 결과로 대신하지 않는다.
