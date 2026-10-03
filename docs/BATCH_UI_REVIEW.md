# 두 개·스무 개 작업의 실제 일괄 배치 수용

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
