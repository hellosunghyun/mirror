# 두 개·스무 개 작업의 실제 일괄 배치 수용

후속 선택 화면에서는 일반 작업의 완료·개별 미루기·상세 제어를 숨기고 선택 체크와 제목·계획만 표시한다. 제목도 같은 로컬 선택을 바꾸며 전체 title/상태/계획 접근성 값은 유지한다. 날짜 배치 버튼은 선택 모드의 하단 안전 영역에 한 번만 표시하고 선택 ID는 현재 목록 순서로 전달한다. 기존 선택 수·최대20개·날짜 context·원자 명령·Undo는 유지한다. 기존 두 UI 사례에 개별 미루기 버튼 부재 assertion 하나와 기존44pt 검사 호출을 추가해 authored52개이며 원51 assertions·모든 기존 동작/대기·typed2/실패0/skip0·receipt gates를 보존한다. Native scroll owner의 실제 frame에 footer가 포함되는지와 탭·키보드 수용은 새 Actions 전까지 미검증이다.

`d7e23ef`의 일괄3은 세 플랫폼 SDK build가 실제 성공했다. Mac의 두 사례는 작성 칸 query의 `firstMatch.exists` 위치L80에서 unclassified 실패가 관측됐으며 typed 결과는 수용하지 못했다. TextField/TextView/기타 요소 중 실제 역할이나 누락·중복·SDK 원인은 미확정이다. 이 실패를 선택 화면이나 저장 명령의 실패로 단정하지 않는다.

사용자가 요청한 쉬운 입력·미루기와 화면 밀도를 검증하기 위해 기존 여섯 native UI 사례와 별도인 `MirrorIOSBatchUI` / `MirrorMacBatchUI` scheme을 사용한다. 기존 native assertion·실패 조건·46장 PNG와 15/20분 예산, push마다 서명·Release 게시하는 게이트는 바꾸지 않는다.

`batch-ui.yml`은 앱·공통 소스·새 batch 사례·생성 프로젝트·batch CI 게이트가 바뀐 push에서 iPhone/iPad/Mac 세 job을 실행한다. `workflow_dispatch`도 제공한다. 새 workflow 파일이 default branch에 없으면 GitHub가 수동 dispatch를 허용하지 않을 수 있으므로, 첫 검증은 새 소스를 포함한 정상 push의 실제 SHA·run ID·attempt로 확인한다.

## 실제 사용자 조작

- 두 작업: 입력 sheet를 한 번 열어 세 제목을 실제 연속 저장한다. 두 작업만 개별 선택하고 나머지 하나는 대조 작업으로 남긴다. 선택 수2·기본 접힌 제목과 달력·빠른 Today/Tomorrow 버튼, 제목 펼치기/접기를 확인한다. Today 뒤 다시 Tomorrow로 보내도 두 원래 UUID·전체 제목·미완료를 보존하고 대조 작업은 날짜 미정으로 남아야 한다.
- 스무 작업: 한 입력 sheet에서 스무 제목을 실제 저장하고 UI에서 원래 UUID·전체 제목·날짜 미정·미완료를 읽는다. 스무 선택 버튼을 각각 조작해 선택 수20을 확인한다. 기본 접힌 제목을 펼쳐 모든 선택 제목을 확인하고 다시 접은 뒤 Tomorrow를 누른다. 스무 원래 UUID·전체 제목·미완료가 유지되고 모두 10월1일이어야 한다.

합성 제목만 사용하며 생산 모델을 import하거나 저장소에 seed를 주입하지 않는다. 기존 `MIRROR_UI_TESTING` launch가 앱의 임시 실제 canonical store를 열고 시계만2026-09-30T03:00:00Z로 고정한다. Mac은 click, iOS는 tap이며 고유한 역할·실제 앱 창과 scroll owner·enabled/hittable·유한한15초/12회 스크롤을 확인한다. iOS의 빠른 명령·선택 버튼은44pt 경계를 검사한다.

## 결과와 한계

빌드10분과 새 batch UI20분은 별도 전용 예산이다. 실행 전 동일 run/source·앱과 test runner 제품의 해시 receipt를 확인한다. 실제 `xcresulttool` summary와 test tree에 정확한 두 사례가 각각 Passed이며 실패·skip0이어야 한다. 다른 bundle·누락·중복·0-test·불완전 stdout는 거부한다. 실제 소유 class의 시작/종료 로그는 typed 결과에 더하는 검사이고 typed 결과를 대체하지 않는다.

공개 artifact는 현재 SHA·run·attempt·플랫폼·typed 수·고정 method IDs·해시로 제한한다. 원본 xcresult·로그·AX tree·제목·UUID를 업로드하지 않는다. 이 전용 사례는 FR-027의 일반 일괄 조작과 화면 분배를 검증한다. Q-080의 stale20개 전체 거부·물리 VoiceOver·실기기와 두 기기 동기화는 별도 검증이며 이 사례의 성공으로 완료 처리하지 않는다. 새 스크린샷은 만들지 않아 기존46장 계약을 유지한다.

실행 준비와 실제 SDK 실행 통과는 구별한다. 세 플랫폼의 동일 새 SHA에 대한 typed 사례 수2·실패0·skip0과 실제 UI 내용을 확인하기 전에는 수용 완료로 기록하지 않는다.

소스 `6dd7327`의 Mac은 회귀 명령과 앱·runner SDK 빌드를 통과했지만 두 UI 사례가 작성 칸 조회의 같은79행에서 실패했다. 실제 접근성 역할과 존재·중복 중 어느 조건인지는 미확인이다. 작성 칸은 기존 적응형 UI 검사와 같이 TextField, TextView, 고유한 작성 칸 ID 순서로 찾는다. 어느 경로도 고유 후보1개·15초와 이후 실제 앱 창 소유·전체 표시·enabled/hittable·정확한 빈 값과 제목·실제 입력·저장·원본 receipt 검사를 우회하지 않는다. 기존51 assertions·6 XCTFail·두 사례·PNG0·시간 제한을 유지하며 조회 보완의 실제 성공은 새 소스에서 확인한다.

## 현재 목록을 한 번에 선택하기

선택 모드에만 ‘모두 선택’과 ‘선택 해제’를 제공한다. 대상은 현재 검색·목록 필터가 보여 주는 미완료 작업의 표시 순서이며 완료·휴지통 작업과 다른 필터의 작업은 포함하지 않는다. 대상이 20개보다 많으면 ‘앞 20개 선택’이라고 표시하고 표시 순서의 앞 20개로 로컬 선택 집합을 교체한다. 대상이 없으면 추가 선택 버튼은 숨긴다. 개별 선택과 기존 최대20개·날짜 고정·stale 전체 거부 명령 게이트를 유지한다.

이 버튼은 로컬 선택 집합만 변경한다. 작업 생성·날짜 배치·완료·저장 명령을 실행하지 않으며 날짜 배치는 기존의 별도 버튼으로 확정한다. ‘현재 목록’ 접근성 라벨·선택 수와 최대 대상 수의 접근성 값으로 범위를 알린다. 기본 화면에는 버튼을 추가하지 않고 기존 적응형 액션 그룹을 사용해 선택 모드의 버튼만 화면 폭과 큰 글자 크기에 맞춘다.

스무 작업 사례에는 기존 개별 선택 전에 실제 ‘모두 선택’ 조작을 추가한다. UI에서 읽은 같은20개 원래 ID·전체 제목·선택 상태와 선택 수20, 날짜 미정·미완료를 확인하고 ‘선택 해제’ 뒤 선택 수0·비활성 날짜 버튼과 같은20개 선택 해제·원문·날짜 미정을 확인한다. 선택 모드를 마친 뒤 기존 스무 개별 선택·접힌 제목·Tomorrow·원래 ID/제목/미완료 검증을 그대로 실행한다. 두 작업 사례의 대조 작업과 기존 두 method IDs, typed2·실패0·skip0 게이트,15개 결과 회귀·기존 timeout·46장 PNG 계약을 유지한다.

이는 작성한 실제 UI 수용 경로이며 실행 결과가 아니다. 앞20개 선택의 >20개 경계와 빈 목록 버튼 숨김은 현재 후보의 정적 소스로 확인했으며 이 두 경계의 실제 native UI 사례를 추가하지 않았다. 추가 조작의 실제 시간·SDK 접근성 역할·범위·선택 상태는 새 소스를 포함한 동일 SHA의 iPhone/iPad/Mac Actions에서 확인해야 한다.

Batch query 실패 진단은 기존 source notice와 별도의 `Batch UI query failure diagnostics: ` notice로 남긴다. 동일 run 문맥과 정확한 batch bundle·class·두 method, 현재 Swift 소스의 실제 행·열을 먼저 검증한 뒤, 기존 assertion 분류가 `unclassified`인 payload의 고정된 시작 문구만 일곱 query 종류 또는 `unknown`으로 정제한다. 중복을 제거한 최대12개 위치와 수만 출력하며 제목·UUID·원문·비공개 경로는 출력하지 않는다. 시작 문구 지원은 합성 회귀로 작성한 진단 계약이고 실제 실패 원인을 확정하지 않는다. 기존15개 회귀와 typed2·실패0·skip0, outcome·receipt·수용 게이트를 보존하며 추가 회귀와 실제 SDK 분류 결과는 Actions에서 검증한다.

## 하단 날짜 버튼과 Mac 입력의 후속 검증

하단 날짜 버튼은 목록의 스크롤 내용과 별도인 안전 영역에 있다. 따라서 활성 날짜 버튼의 기존 세 조작 경로는 실제 `library.batchFooter` 그룹 안의 고유 native Button, 두 요소를 함께 소유하는 실제 창, 유한한 양수 frame·전체 포함·enabled/hittable·iOS44pt를 검사한다. 고정 footer를 목록 스크롤 viewport 안에 포함시키는 조건은 사용하지 않는다. 원래 선택 수·명령·비활성 상태·receipt와 모든 기존 assertion·대기를 보존하며, 최대15초/12회 확인과 전면 앱 assertion 하나를 더해 authored53개다. source 계약 보완이며 실제 AX 그룹과 footer geometry의 수용은 미검증이다.

`831df7c` 일괄4의 Mac 두 사례는 작성 칸의 `firstMatch.exists` 위치L80에서 `failedToGetMatchingSnapshot`으로 실패했다. iPad 두 사례는 L362의 기존 너비44pt 검사에서 실패했다. 실제 native 입력 역할, iPad 실패 버튼·측정 너비·실패 원인은 미확정이며 typed 실행 수는 수용하지 못했다. 후속 Mac 작성 칸 helper는 고유 닫기·저장 Button을 함께 포함하는 창을 찾고, 그 창의 실제 입력 시트가 있으면 같은 시트 안에서 TextField/TextView 합계1개를 요구한다. 실제 frame·창과 owner 포함·전면·enabled/hittable·15초/12회 확인을 유지하고 다른 요소의 조회와 iOS 기존 입력 경로는 보존한다. footer와 Mac 종료 실패 조건을 합쳐 authored53 assertions·8 XCTFail·두 사례·PNG0이며 실제 통과 수를 뜻하지 않는다.

같은 일괄4의 iPhone도 SDK 빌드 성공 뒤 UI 단계 실패로 종료했고 세 플랫폼 전체 run은 자연 실패로 종료했다. iPhone에서 알려진 source/query 진단과 typed 수는 수용하지 못했다. UI 단계의 약20분 실행 시간만으로 timeout 원인을 확정하지 않는다. 종료된 실행의 추가 진단 읽기와 재시작은 하지 않으며 후속 소스는 별도 실행에서 검증한다.


44pt 모바일 target 진단은 기존 width·height ≥44 assertion의 조건·호출 수를 그대로 두고 고정 axis와 control code만 메시지에 붙인다. capture·목록 선택·footer batch·계획 날짜·화면 이동은 고정 code, 정확한 UUID 형식의 task.select 대상은 taskSelection, 나머지는 other로 축약한다. 원 identifier·UUID·제목·측정값을 공개 notice에 넣지 않는다.

별도 Batch UI mobile target diagnostics notice는 현재 실행의 다섯 문맥, 정확한 두 method·bundle/class·canonical Swift 파일·실제 행/열, 그리고 해당 행이 메시지의 axis와 일치하는 실제 ≥44 source assertion인지 확인한 뒤 고정 axis/control와 최대12개 중복 제거 위치·수만 남긴다. 기존 source/query notices·typed2·실패0·skip0·outcome·receipt·시간 제한과 원21 결과 회귀를 보존하고 privacy·소유/소스/실제 bounds·행 조건·notice·dedup 회귀3개를 작성했다. 이는 authored 계약이며 실제 target·크기·실패 원인이나 native 통과를 확인했다는 뜻이 아니다. 추가 identifier 조회의 실제 시간과 SDK 동작은 새 동일 SHA의 GitHub Actions에서 확인해야 한다.

모바일 notice는 승인된 실제 source-bound 위치가 있을 때만 추가하여 기존 query/빈 진단 notice 수와 원21 회귀를 그대로 유지한다. assertMobileTarget 함수와 모든 호출을 유지하며 iOS에서 element.identifier property를 정확 한 번 읽는다. matching/count/snapshot API를 추가하지 않지만 이 property의 native AX 비용과 실제 시간은 미검증이다.

선택 모드의 큰 제목 Button에도 현재 선택됨·선택 안 됨을 알린다. 기존 미완료·계획 값 전체를 앞에 유지하고 완료·휴지통 작업은 기존 상태와 계획을 표시한다. 검증의 초기 일반 행 두 경로는 원래 값을 유지하며, 날짜 배치 뒤 대상·대조 작업과 전체 선택·해제의 일곱 경로는 fixture에서 아는 선택 기대값을 명시한다. 전체 문자열의 정확한 비교·제목·ID·현재 날짜 명령·도달 조건·기존53개 assertion·8개 실패 조건·두 사례를 유지하며 앱의 실제 선택값으로 기대값을 만들지 않는다. 실제 VoiceOver 안내와 새 소스의 Actions 통과는 별도로 확인한다.
