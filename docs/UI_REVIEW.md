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

`2b05387839e09aaf56ff484672f123e6e79ee80b`의 [다크 원본 실행](https://github.com/hellosunghyun/mirror/actions/runs/36994469590)은 준비·도메인159개, Mac 단위159개, 모바일 단위156개씩과 세 UI6개씩·guard·최종xcresult·원본 게시가 실제 통과했다. 실제 attempt1의49자산·46PNG를 다운로드해 해시·크기·모든 단계와 PNG CRC697개를 검증했고, iPhone 설정 원본을 직접 열어 계획 시간대·알림 설명이 어두운 것을 확인했다. 주요 동작의 통과를 보조 설명의 시각 수용으로 대신하지 않는다.

설정 설명은 명시적인 밝은/다크 보조 문구 색을 사용하도록 바꾼다. 기존 편집 placeholder와 같은 두 색을 재사용하며 입력 안내 색의 실제 값·문구·caption 크기·행동·저장·레이아웃은 유지한다. native Form의 색 계층을 원인으로 확정하지 않는다. 색 변경만을 복제하는 테스트는 추가하지 않고 기존46장과 기능 검사를 후속 Actions에서 다시 확인한다. 위 이전2b 화면은 연속 입력의 새 저장 완료 안내와 이 대비 수정의 검증을 대신하지 않는다.

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

[후속 실행36934719595](https://github.com/hellosunghyun/mirror/actions/runs/36934719595), `fc53163`·build35는 준비·SwiftPM159개와 Mac/iPhone/iPad 실제 UI6개씩 모두 통과했다. 각 SDK 컴파일·receipt도 성공했고 실제 UI 실행은 Mac515초·iPhone879초·iPad759초였다. [화면46자산](https://github.com/hellosunghyun/mirror/releases/tag/ui-review-36934719595)과 [설치8자산](https://github.com/hellosunghyun/mirror/releases/tag/adhoc-36934719595)을 공개 다운로드하여 source/build/run/attempt·파일 크기·SHA256·43단계·실제PNG dimensions를 확인했다. iOS 서명·프로파일·앱/확장3개 버전·최소OS27.0, Mac 공증·staple·Gatekeeper 게이트도 성공했다.

**새 원본43장도 모두 직접 열었지만 iPad 가로1장의 시각 검증은 다시 실패했다.** Mac14장과 iPhone14장, iPad 세로14장에서는 이전 창 잘림·plain Form 여백·선택행 대비·검색 제목·키보드 안내·오류/저장 가시성이 보완됐다. 가로 PNG는 여전히90도 회전한 내용과 오른쪽 약25% 검은 띠가 있어 인접 달력의 실제 시각 증거로 인정하지 않는다. viewport assertions 통과를 정상 pixels로 대체하지 않으며 HStack·대기 실패나 EXIF 제거를 원인으로 단정하지 않는다. 설정 캘린더 버튼의 파란 강조색도 비차단 잔여 항목으로 확인했다.

후속 보완은 `ipad-landscape` 단계만 실제 foreground 앱 주 창의 native screenshot을 직접 첨부하고 기존42장의 캡처 경로를 유지한다. 창 존재·유효한 경계·앱 포함·가로 방향을 검사한다. 이미지 회전·crop·렌더링·후처리로 증거를 고치지 않으며 같은 SDK 내부 캡처 경로일 가능성이 있어 새 원본에서 다시 판정한다. 설정 NavigationStack에도 동일한 강조색을 적용한다. 기존6사례·43장·모든 기능 assertions와 시간 제한은 유지한다.

[후속 실행36938485106](https://github.com/hellosunghyun/mirror/actions/runs/36938485106), `fe3dee3`·build36은 준비·도메인159개·Mac 실제 UI6개가 통과했다. Mac SDK 컴파일28초·receipt·UI실행450초를 확인했다. iPhone은 SDK 컴파일125초·receipt 뒤 UI exit65/1192초로 실패했다. 최초 capture 실패는378행의 Continue 후보 수 `XCTAssertEqual`이며, 실제 후보0개·키보드 경계 유효·대기15097ms를 확인했다. overlong 실패와 다른 메서드의 stdout 통과도 관측했으나 최종 xcresult 사례 수로 계산하지 않는다. iPad는 SDK 컴파일102초·receipt와 가로 창 캡처를 포함한 capture 통과를 확인했지만 tomorrow/보관함 검색 사례가40.228초에 실패했다. 다른5개 stdout 통과 뒤 UI20분 제한으로 중단됐으며 최초 위치 진단은 rejected1이라 정확한 줄·종류는 미확정이다. 화면·설치 게시가 모두 skipped되어 새 원본은 없다.

다음 진단은 동작·assertions·시간 제한을 유지한다. 내일 작업 사례에 수행 단계의 고정 enum만 기록하며 각 검사 결과는 별도로 확인한다. Continue 후보는 기존 exists→hittable→enabled→키보드 포함 조회의 단조 감소 수만 집계해 추가 AX 조회 없이 제외 지점을 좁힌다. 가로 한 장에서는 동일 native screenshot의 UIImage 방향 enum·크기·scale·CGImage 크기·정식 PNG hash를 읽고, SDK export 원본과 정제본의 IHDR/IDAT hash 및 제한된 EXIF orientation 숫자만 비교한다. UIImage enum과 EXIF 숫자는 다른 체계이며 직접 등치하지 않는다. 원문 metadata·좌표·제목·추가 자산·이미지 보정은 없다. strict schema·활성 사례 귀속·중복/혼합/손상/개인정보 차단 회귀를 추가하고 테스트 실행은 새 Actions에 남긴다.

[후속 실행36942414309](https://github.com/hellosunghyun/mirror/actions/runs/36942414309), `f043b03`·build37은 준비·도메인159개와 Mac·iPad의 실제 UI6개씩을 통과했다. Mac 컴파일25초·UI481초, iPad 컴파일186초·UI909초와 각 receipt를 확인했다. iPhone은 컴파일157초·receipt 뒤 최초 capture의 Continue 후보 수 검사481행에서 실패했다. 공개 결과에 실제 후보 수·제외 지점·최종 xcresult 수는 없어 미확정이다. 내일 작업의 수행 단계도 started부터 todayExcluded까지7개만 관측했다. aggregate 실패로 화면·설치 게시가 모두 skipped되어 새37 원본·앱 자산은 없다.

후속 진단은 첫 실패·keyboard·viewport를 먼저 표시하고, 검증된 내일 작업 수행 단계 prefix를 하나의 배열 주석으로 집약한다. 원본 로그의19단계·활성 사례 귀속·순서·중복·잘못된 값 거절 계약은 유지한다. 성공한 UI 실행에서도 동일 native screenshot의 허용 metadata만 별도로 보고한다. 이 보고는 테스트·게시 성공 판정이나 Actions 출력값을 만들지 않는다. 공개 HTML의 주석 총수·페이지네이션 경로는 확인하지 못해 이전 진단 누락의 원인으로 단정하지 않는다. 테스트·빌드는 GitHub Actions에서만 다시 확인하며 기존 모든 assertions·6사례·43장·시간 제한은 유지한다.

[후속 실행36945881039](https://github.com/hellosunghyun/mirror/actions/runs/36945881039), `80112be`·build38은 준비·도메인159개·Mac 검증을 통과했다. Mac 실제 xcresult6개 passed와 컴파일48초·receipt·UI501초를 확인했다. iPad도 검증 success·컴파일164초·receipt·UI739초이며 공개 xcresult에서는5개 사례 passed만 관측했다. 가로 native 캡처는 UIImage 방향 left·표시1376×1032/scale2·CGImage2064×2752다. 방향 표현만으로 정상 픽셀이나 원인을 판정하지 않는다. iPhone은 컴파일238초·receipt 뒤 최초 capture481행에서 실패했다. Continue의 조회·존재·hittable·enabled 수는 각각1개이나 마지막 면적·키보드 포함 조건을 통과한 것은0개였고 대기는15901ms였다. 내일 작업의19개 수행 단계는 complete까지 공개됐지만 각 assertion 결과와 별개로 본다. capture/긴 입력의 실패 및 일부 stdout 통과가 관측됐으나 최종 xcresult 수는 미확정이다. 전체 화면·설치 게시가 skipped되어 새38 자산은 없다.

후속 보완은 첫 iPhone 증거 입력의 실제 field tap 뒤 키보드 안내·입력 키 준비를 확인하고 텍스트를 입력한다. 기존 입력 후 준비 검사도 유지한다. 다른 다섯 사례와 iPad·Mac의 입력 동작은 유지하며 모든 기존 assertions·각15초 예산·전체 실행 제한을 줄이거나 늘리지 않는다. 첫 Phone 사례에는 준비 조회 비용이 추가되므로 실제 런타임은 후속 Actions에서 확인한다. 유일한 enabled 후보의 이미 읽은 frame에서는 면적·전체 포함·중심 포함·교차 여부 네 값만 보고한다. 미평가·복수 후보는 null로 구분하며 좌표·추가 AX 조회는 없다. 기존 후보 선택 조건은 그대로다. 실제 xcresult 사례 시간도 수집한 전부를 한 주석 배열로 보존한다. 이 진단 집약은 테스트·게시 성공 판정을 바꾸지 않는다.

목표 화면은 아래와 같으며 최종 게시 여부는 해당 실행으로 확인한다.

| 플랫폼 | 명명된 앱 화면 |
|---|---|
| iPhone | 오늘 빈 화면, 입력, 일정, 설정, 보관함, 정리 카드, 오늘 목록, 검색, 상세, 상세 편집, 완료, Undo, 주 날짜 선택, 입력 오류, 일반 빠른 날짜 선택: 15장 |
| iPad | 같은 15장과 실제 기기 회전 후 가로 viewport 화면: 16장 |
| Mac | 같은 15장: 15장 |

각 화면은 실제 XCUITest 입력과 Core Data 저장 경로의 native XCUIScreenshot을 첨부한다. iPad 가로 한 장은 `XCUIScreen.main.screenshot()`을 사용하며 전면 iPad 앱의 유일한 주 창·단일 화면과 동일 캡처의 논리적 화면 크기를 검사한다. 앱과 창이 화면 전체를1pt 오차 안에서 채우지 않으면 attachment를 남기지 않고 실패한다. 현재 계약의 나머지45장은 `app.screenshot()`이다. 화면 캡처에는 시스템 chrome이 포함될 수 있으며, 앱·창 경계 검사가 알림 배너 부재까지 증명하지는 않는다. 합성 작업만 입력하는 CI Simulator 원본에서 다른 앱·개인 내용·시스템 overlay 노출을 직접 확인한다. 성공 mock·작업 seed·이미지 생성·임의 합성 화면으로 대체하지 않는다. 고정 테스트 날짜와 합성 작업 제목을 사용한다. 실제 개인 기기 화면·영상·원본 attachment JSON·로그는 공개 검토 폴더에서 제외한다.

현재 checkout SHA, 실제 앱의 `CFBundleVersion`, Actions run·attempt를 확인한다. 실제 SDK의 `xcresulttool export attachments --help`를 먼저 확인하고 명명된 앱샷만 추출한다. 세 플랫폼·각 필수 화면·PNG 내용·checksum·manifest의 SHA/build/run/attempt가 맞지 않으면 검토 자료를 게시하지 않는다.

현재46-stage 계약을 따르는 성공 실행의 별도 `ui-review-RUNID` prerelease는 PNG46장과 안전 manifest·`SHA256SUMS`·`ui-review.html`의49자산을 요구한다. HTML을 내려받으면 포함된 PNG를 브라우저에서 함께 볼 수 있다. 과거43-stage 실행의 실제 자료 수는 해당 검증 기록을 따른다. 앱 배포의 `adhoc-RUNID`에 있는 IPA·DMG와 여덟 자산 계약은 유지한다.


[후속 실행36949485800](https://github.com/hellosunghyun/mirror/actions/runs/36949485800), `634e208`·build39는 준비·도메인159개·Mac 단위159/UI6·iPad 단위156/UI6가 통과했다. Mac 컴파일28초·receipt·UI450초와 iPad 컴파일208초·receipt·UI919초, 실제 xcresult의 각6개와 실행 guard를 확인했다. Phone은 컴파일162초·receipt 뒤 최초 capture의506행 유일 후보 검사에서 실패했다. 실제 Continue는 query/existing/hittable/enabled 각1개이고 면적이 있으며 키보드와 교차하지만 중심·전체 포함은 false였다. 후보0개·경계유효·15443ms를 확인했다. 나머지5개는 stdout 통과이며 최종 xcresult 수로 합산하지 않는다. 모든 화면·설치 게시가 skipped되어39 새 원본은 없다.

이 관측은 안내 버튼이 키보드의 직사각형 경계 밖으로 펼쳐질 수 있음을 보여 준다. 후속 수정은 정확한 안내 본문과 Continue의 공통 접근성 컨테이너를 찾고, 가장 깊은 컨테이너와 소유 창이 각각 유일한지 확인한다. 본문·버튼의 정확한 label과 유일성, enabled/hittable, 유한한 양의 경계, 컨테이너 전체의 창 포함, 본문·버튼 전체의 컨테이너 포함을 요구한다. 창 전체를 덮는 wrapper는 배제하고 실제 키보드와의 교차를 보조 연결 조건으로 쓴다. 임의의 첫 부모나 교차만으로 버튼을 선택하지 않는다. 기존 tap 뒤 안내 소멸·실제 입력 키 준비·모든 assertions·단일15초·6사례·43장·실행 제한과 성공 게이트를 유지한다. 실제 공통 컨테이너의 존재와 조회 비용, 해결 여부는 후속 Actions에서 검증해야 한다.

기존 키보드 면적·전체/중심 포함·교차 진단은 원래 사실로 보존한다. 새 raw19키 계약에만 안내 후보 수·컨테이너/창 수·본문 표시·컨텍스트 유효 여부·버튼의 컨텍스트 포함 bool/null을 추가한다. 최종 후보는 새 안내 후보와 연결하고 기존 키보드 포함 수와 혼동하지 않는다. 이전4/9/13키 계약과 strict 개인정보·중복·혼합·범위·nullable 검증을 유지한다.

[후속 실행36952646432](https://github.com/hellosunghyun/mirror/actions/runs/36952646432), `9c446cf`·build40는 준비·도메인159개·Mac 단위159/UI6·iPad 단위156/UI6가 통과했다. 실제 xcresult 각6개와 실행 guard, Mac 컴파일22초·UI426초와 iPad 컴파일176초·UI732초를 확인했다. Phone은 컴파일105초·receipt 검증 후 긴 입력 오류 뒤 보관함에서 정상 입력을 다시 여는 capture helper284행에서 XCTFail로 실패했다. 최초 입력·촬영 사례의 stdout passed196.443초를 관측했으나 새 키보드20키 진단과 최종 Phone xcresult 수는 미관측이다. 해당 호출 위치만으로 앱 종료·필수 요소 부재·소유 스크롤 부재·hittable/enabled 실패를 구별할 수 없다. 모든 화면·설치 게시가 skipped되어40 새 원본은 없다.

오류 경로도 정상 입력과 같이 닫기 뒤 `capture.title`의 실제 소멸을 기존 helper로 확인한 후 보관함 탐색·새 입력 복구를 시작한다. 이는 닫힘 상태의 검증을 추가하는 동기화 수정이며, 이번 실패가 시트 전환 때문이었다고 단정하지 않는다. 새로운 고정 sleep·좌표 탭이나 기존 assertions·시간 제한의 변경은 없다. 추가 대기 비용은 기존 전체 제한 안에서 확인한다.

후속 진단은 승인된 첫 XCTFail 본문의 정확한 고정 한국어 접두사와 경계만 고정 enum으로 공개한다. 앱 종료·필수 요소 부재·행/일반 소유 스크롤 부재·hittable/enabled 실패를 구별하고 불명 분기와 다른 assertion은 기존 다섯 필드를 유지한다. 원문·작업 제목·AX·좌표를 출력하거나 진단 조회를 추가하지 않는다. 세 회귀는 전달된284행·고정 분기·정확한 경계·첫 실패 선택·혼합/비공개 원문 제외·Actions 출력 불변을 검사한다. 실패 분기 재현과 해결은 후속 Actions에서 확인한다.

[후속 실행36955448753](https://github.com/hellosunghyun/mirror/actions/runs/36955448753), `c380125`·build41은 준비·도메인159개·Mac 단위159개·iPhone/iPad 단위156개와 실제 UI6개씩/guard를 모두 통과했다. UI46자산·설치8자산을 다운로드하여 source/build/run/attempt·bytes·SHA256·PNG IHDR·43단계와 IPA본체/확장3개의 버전·최소OS27.0, Mac arm64 및 서명·공증 게이트를 확인했다. 원본43장도 모두 직접 열었다. iPhone14장·Mac14장·iPad세로14장에서는 확정 잘림·겹침을 발견하지 못했지만, iPad가로1장은2064×2752 PNG에 전체 내용이90도 돌아가 시각 검증에 실패했다. 이전 검은 띠는 없으며 목록과 독립 일정의 두 열은 보인다. native UIImage left·표시1376×1032/scale2·CG2064×2752만으로 정상 가로 pixels를 판정하지 않는다.

후속 변경은 가로 한 장의 producer만 실제 main-screen native 캡처로 바꾸고 앱·주 창·화면 범위 검사를 강화한다. 동일 native 객체·기존 attachment·정제 경로와 모든 기존 기능 assertions·6사례·43장·시간 제한은 유지한다. 수동 회전·crop·렌더링으로 원본을 고치지 않는다. 실제 SDK 선언과 새 원본의 정방향·검은 띠·두 열·시스템 노출은 다음 Actions에서 확인하며, producer 변경만으로 해결했다고 기록하지 않는다.

## iPad 대기 조회와 입력 오류 안내

[build42](https://github.com/hellosunghyun/mirror/actions/runs/36959011411)는 가로 캡처 전 안정 대기에서 3회 샘플과 평가한 17개 배치·조작 가능 조건을 충족했지만 16,792ms에 최종 15초 제한을 넘겼다. [Dark1](https://github.com/hellosunghyun/mirror/actions/runs/36960263697)도 같은 단계에서 15,218ms·안정 샘플 2회로 실패했다. Dark1의 기록된 배치 조건 15개는 모두 true이며, 미평가 조작 가능·최종 제한 조건을 false로 채우지 않는다. 두 실행에서 main-screen 캡처 호출과 정상 가로 PNG를 확인하지 못했고, 어두운 원본은 게시되지 않았다.

후속 harness는 각 반복에서 원래 window·today·review·adjacent·date query를 새 접근성 요소에 바인딩하고, 결과 유무로 존재 여부를 확인한 뒤 같은 요소의 경계와 조작 가능 여부를 읽는다. 반복 사이에 요소를 캐시하지 않는다. 전체 query 열거 비용과 한 반복 안의 AX 교체는 실제 Actions에서 확인해야 하며 비용 절감을 미리 보장하지 않는다. 기존 전면 앱·경계·방향·포함·두 열 분리·세로 복귀 조건, 3회/0.5초 안정, 15초와 마지막 시간 검사는 유지한다.

입력 오류는 기존 `TaskContent`가 거부한 제목·메모·링크 원인만 안내한다. 입력 원문·검증·저장·실패 metric은 유지한다. 기존 501자 UI 사례에 제목 길이만 안내하는 정확한 표시 문구 검사를 추가하고, 원문 보존·무작업 생성·가시성·키보드 경계·정상 복구 검사는 모두 유지한다. 새 실제 원본에서 오류 문구와 가로 캡처를 다시 확인한다.

[Dark2](https://github.com/hellosunghyun/mirror/actions/runs/36963542367)의 Mac은 새 501자 문구 검사132행에서 실패했다. 공개 자료로 actual label/value를 확정하지 못했으므로 빈 label이 원인이라고 단정하지 않는다. 후속 검사는 이미 쓰던 `displayedText`로 비어 있지 않은 label을 우선하고 빈 label일 때만 value를 읽어 문구 전체를 정확히 비교한다. 500자 포함 대기와 모든 기존 assertions는 유지한다. 기존 접근성 표시 읽기 방식과 새 문구 검사의 일관성을 맞춘 변경이며, 실제 해결 여부는 다음 Actions에서 확인한다.

## 다크 원본의 실제 대비와 후속 수정

`825e35e`의 [Dark3](https://github.com/hellosunghyun/mirror/actions/runs/36965028958)는 도메인159개·Mac 단위159개·Phone/Pad 단위156개와 UI6개씩·각 guard·aggregate·앱샷 게시를 모두 통과했다. 공개46자산·43PNG의 exact SHA/build3/run/attempt1·bytes·SHA256·raw dimensions·43stage·전체CRC를 확인하고, Phone14·Pad15·Mac14 원본을 모두 개별 직접 열었다. 가로1장은 orientation8 전용26-byte eXIf가 native UIImage.left와 일치하며 실제 정방향 글자·목록/일정 인접2열·검은띠없음을 확인했다. 다른42장의 EXIF는 없다. 공개 provenance14는 미관측이어서 native/export/public IHDR·IDAT 실측대조는 미확정으로 보존한다.

Mac14에서는 확정 창잘림·빈상세·과도한완료버튼 blocker/P2가 없었다. Phone/Pad도 확정 잘림·겹침은 없고 오류/저장/편집취소가 키보드 위에 보였지만, 밝은 민트 주요 버튼의 흰 글자 대비가 낮다. Phone의 상세 편집 메모·원문링크 placeholder도 검은 입력 표면에서 매우 어둡다. 이 두 P2 때문에 전체 시각 수용은 보류했다. 작은 설정 footnote·검색 placeholder·보조라벨과 정리 마지막 선택의 첫 화면 발견성은 P3후보이며 정지 이미지로 도달불가를 확정하지 않는다.

후속 수정은 기존 accent를 유지하고 주요 버튼6개의 Text 라벨에만 adaptive `onAccent`(light 흰색, dark `#16301E`)를 명시한다. 상세 편집3개 입력란은 같은 제목·binding·axis·lineLimit·style·ID를 유지하면서 adaptive `inputPrompt`(light `#526155`, dark `#AEBCAF`)의 명시적 Text prompt를 사용한다. prompt는 Text? 인수의 반환형을 분명히 하는 Text의 foregroundColor를 사용하고, 버튼 라벨은 foregroundStyle을 사용한다. native 버튼 style·프레임·disabled·focus·동작·명령·metric·기존 UI6개/43장/모든 assertions·시간 제한을 바꾸지 않는다.

불투명한 색상 선언값의 독립 sRGB 상대휘도 계산은 accent/label light6.87:1, dark의 기존 흰색1.54:1에서 후보9.22:1, prompt/기존 표면 light5.86~6.56:1·dark7.46~10.61:1이다. 실제 렌더링 픽셀 계측이나 disabled/pressed/inactive 상태·VoiceOver·전체 접근성 수용 결과가 아니다. 실제27 SDK 컴파일과 밝은/어두운 원본의 가독성은 다음 Actions에서 검증한다. 이번 대비 후보에서 capture의 선택 입력 prompt·검색·설정 secondary 색상으로 범위를 확대하지 않는다.

## 쉽게 입력하고 미루는 화면 분배

사용자가 입력과 미루기가 복잡하고 한 화면의 정보가 많다고 지적하여 흐름을 다시 정리한다. 빠른 입력은 제목과 키보드 위 저장을 먼저 보여 주며, 메모·링크는 접힌 영역에 둔다. 반복 안내·상시 글자 수를 숨기고 저장 시 제목 제한 오류는 고정 저장 영역 한 곳에서 안내한다. 여러 줄 입력은 하단의 한 개 저장과 본문의 나누기 미리 보기로 구분하며 원문·분할 확인·저장 receipt·취소·연속 입력 포커스를 유지한다. 연속 입력에서는 실제 저장과 projection 갱신을 확인한 뒤 입력 화면 안에 “보관함에 넣었어요.”를 한 줄로 표시한다. 다음 제목·메모·링크 입력이나 저장 시도에서 이전 안내를 지우고 오류·저장 중·projection 확인 중에는 성공 안내를 숨긴다. 단일 입력의 닫힘과 재확인 token의 귀속은 유지한다.

목록의 미완료 작업에는 `미루기`를 표시하여 상세나 길게 누르기 없이 같은 화면의 작업 ID로 날짜 선택을 연다. 일반 날짜 선택은 오늘·내일을 즉시 선택하고 다른 날짜를 펼칠 수 있다. 정리/위젯에서 전체 달력을 요청한 경로는 처음부터 펼친다. 열기·취소·펼치기는 저장하지 않으며 모든 선택은 기존 고정 request의 context·expected versions·token과 공통 명령을 사용한다. 기존 Undo UI 사례 끝에 직접 미루기의 대상 ID·취소 후 미정 유지·내일 저장·Today 제외·미완료 상태 검사를 추가한다. 기존 여섯 사례·43앱샷·모든 기존 assertions·시간 제한·guard는 유지한다.

정리 화면은 한 작업 카드, 오늘·내일의 큰 두 행동, 이번 주·다음 주·다른 날의 보조 세 행동으로 나눈다. 큰 글자와 좁은 폭에는 세로 배치를 사용하고 44pt 목표를 유지한다. 세션·card 고정, 키보드1~5·편집 중 비활성·포커스/공지·마감 확인·부분 종료·Undo는 그대로다. 오늘 화면의 날짜·반복 정보를 줄이고 날짜 미정 수는 정리 버튼에 짧게 표시한다. 종료의 세 수치 요약은 목록 아래에 기본적으로 접어서 두며 사용자가 필요할 때 펼칠 수 있다. 상세 편집은 내용에 집중하고 지정된 실제 마감과 충돌 안내는 계속 보인다. 일반 상세의 미설정 마감은 추가 행동 하나로 줄이며 이력/관리 기능은 접힌 영역에서 제공한다.

넓은 iPad의 옆 일정은 날짜·해당 일의 작업/마감/약속과 값이 있는 요일 미정 바구니에 집중한다. 일간/주간 전체 탐색과 캘린더 선택·권한은 별도 일정/설정 화면에서 제공하며, 캘린더 오류는 참고 열에도 남긴다. 기존 인접2열·320pt 폭·선택 시 상세로 전환·세로에서 참고 열 부재·viewport의19조건/3회/0.5초/15초는 보존한다. Mac은 목록과 선택한 작업의 좁은 상세를 유지한다.

이 변경의 근거는 이전Dark3 실제 원본과 최신 사용자 지적 및 원본 S-02~S-11이다. 정적 검토만으로 새 UI 수용을 완료하지 않는다. 새 통합 SHA의 실제27 SDK·세 플랫폼 UI·밝은/어두운 원본, 특히 직접 미루기 취소/저장·모든 선택 가시성·키보드 위 오류/저장·iPad 가로를 GitHub Actions에서 확인한다. 최대 글자·VoiceOver·다양한 창·실기기와 전체QA87의 미검증 범위는 유지한다.

## 검색 키보드와 안내 중복의 실제 원본 검토

`f031d2a`의 [Dark5](https://github.com/hellosunghyun/mirror/actions/runs/36970192204)는 준비·도메인159개·Mac 단위159개·Phone/Pad 단위156개와 실제 UI6개씩·guard·aggregate·앱샷 게시를 통과했다. 공개 manifest의 attempt1과 46자산/43PNG 총19,969,387bytes의 source/build5/run·bytes·SHA256·stage 및 전체667chunk CRC를 확인했다. Phone14·Pad15·Mac14 원본을 개별 직접 열었고 가로 한 장은 native.left와 일치하는 orientation8 전용26byte eXIf로 정방향이다. 다른42장 EXIF는 없으며 공개 provenance14의 native/export/public 실측 대조는 미확정이다.

정리의 다섯 선택과 고정 종료 영역, 축소한 입력·오늘 요약·상세 편집, iPad 참고 일정은 기본 캡처에서 확인했다. 그러나 iPhone 검색 원본에서는 키보드가 열린 동안 상단 추가/설정 버튼이 상태 표시줄과 겹쳐 전체 시각 수용은 실패다. 같은 source의 상세 원본에도 배경 겹침이 남는다. 긴 제목의 선택 count 행은 고정 오류 영역 경계에 일부만 보였으며, 주 오류와 저장은 키보드 위에 온전히 보인다. 이 부분 노출을 영구적인 스크롤 불가로 판정하지 않는다. Mac 정리 modal에서는 뒤 화면의 같은 성공/Undo 안내가 반복된다. UI 테스트 통과와 시각 수용 실패를 구분한다.

후속 Root 변경은 compact 탐색을 전체 화면 GeometryReader 밖에 두고 regular 탐색에서만 기존 폭을 읽는다. GeometryReader가 실제 겹침의 원인이라는 결론은 새 원본까지 보류한다. 상세 inspector는 compact/regular 분기 바깥의 같은 호스트에 유지하여 미저장 로컬 편집 상태의 소유 경로를 바꾸지 않는다. iPad의1050pt/320pt, Mac의520/760pt 및 inspector280/340/380pt 계약은 유지한다. 전역 키보드 safe-area 무시나 수동 상단 inset은 추가하지 않는다. 정리 modal의 오류·저장·Undo는 기존 modal에 남기고 뒤 화면의 반복 안내를 숨긴다. modal에 없는 별도 시스템·정리 오류가 있으면 뒤 화면의 기존 안내 영역도 유지하며 모델값은 지우지 않는다.

S-02/S-03은 숫자 count를 요구하지 않는다. Form의 선택 count만 제거하고 Q-003의 500 확장 문자소 제한·정확한 고정 오류·자동 잘림 금지·실패 후 원문·복구 동작은 유지한다. 기존 501자 UI 사례는 그대로다. 기존 내일/검색 사례의 Phone 분기에는 실제 상태 표시줄·검색 키보드와 고유 상단 Button의 경계·조작 가능·활성 상태를 요구하고 Button.minY ≥ StatusBar.maxY를 비교하는 회귀를 추가한다. AX 경계는 화면 point이며 PNG pixel과 섞지 않는다. 상태 표시줄의 runtime AX 노출과 수정 후 실제 통과는 GitHub Actions에서 확인한다. 누락을 skip하거나 임의 inset·첫 hittable 후보로 대체하지 않는다. 기존 여섯 사례·43장·모든 이전 assertions·대기/시간 제한·guard는 보존한다.

## 시스템 상태 표시줄의 테스트 관측 범위

`bd6899b`의 [Dark6](https://github.com/hellosunghyun/mirror/actions/runs/36974546315)는 준비·도메인159개·Mac 단위159개/UI6개·iPad 단위156개/UI6개 및 두 플랫폼의 guard·최종 xcresult6passed를 통과했다. iPhone은 컴파일201초·receipt verified 후 새 검색 회귀의108행에서 `app.statusBars.firstMatch.exists`가 false여서 실패했다. 이 결과는 시스템 상태 표시줄의 앱 AX 노출 전제가 충족되지 않았다는 증거이며, 실제 상단 버튼의 겹침 재발을 뜻하지 않는다. Phone 전체 실행 수·최종 guard/xcresult는 미관측이다. aggregate 실패·UI 증거 게시 skipped로 새43장 원본은 없고 HTTP 감시는 종료했다. 별도 직접 Swift #124는 취소됐으며 네 경로의 개별 결과나 실행 수를 추론하지 않는다.

후속 검사는 DEBUG·iOS·UI 테스트·iPhone에서만 투명1pt UIKit 관측 뷰를 사용한다. 자체 host 창의 단일 foreground scene·단일 정상 key window와 실제 `statusBarManager`를 요구하고, 시스템 CGRect를 화면 point로 변환해 접근성 value의 기하 숫자4개로 전달한다. 모의 경계·고정 inset·이전 값 캐시는 없으며 UI 화면이나 Release에 표시하지 않는다. 관측 뷰의 정상 AX frame은 바꾸지 않는다. UIKit getter 측정과 AX snapshot의 갱신 시점·실제 OS27 API 컴파일/노출은 후속 Actions에서 확인한다.

테스트는 전면 앱의 유일한 창·관측 ID의 유일성·숫자4개의 정확한 형식·유한한 양의 경계·실제 앱 창 포함을 요구한다. 검색 키보드와 두 실제 Button의 유일성·유효 경계·활성·조작 가능·Button.minY ≥ StatusBar.maxY 비교를 유지한다. 누락·unavailable·중복·잘못된 값은 실패하며 skip·fallback·추가 timeout은 없다. 기존6사례·43stage·모든 이전 assertions·시간 제한·guard를 보존한다. 기하 관측과 원본 PNG의 직접 시각 검토는 별개이며 최신 화면 수용은 대기 중이다.

같은 source의 [AdHoc48](https://github.com/hellosunghyun/mirror/actions/runs/36974546392)은 준비·도메인159개·Mac 단위159개/UI6개·iPad 단위156개/UI6개 및 두 플랫폼의 guard·최종xcresult6passed를 통과했다. Phone의 최초 실패는817행의 키보드 안내 준비 `XCTAssertTrue`다. 안내 본문·고유 컨테이너/창·소유 Continue의 기존 조건이 확인됐지만 continueReadiness는19,225ms로 기존15초를 넘겼다. stdout의 capture/검색2failed·다른4passed는 최종xcresult/guard 수와 구별한다. 검색의 실제 실패 위치는 미관측으로 Dark6의108행을 대입하지 않는다. aggregate 실패·UI 증거/양archive/양publish skipped로 새 화면·설치 자산은 없고 HTTP 감시는 종료했다.

키보드 안내 검사에서 같은 query의 결과를 매 반복 새 AX identity로 바인딩하고, 유효한 컨테이너/본문 검사를 통과한 뒤 소유 버튼 배열을 한 번 읽는다. 인덱스 재조회 비용을 줄일 후보이며19,225ms의 특정 호출 원인이나 실제 시간 개선을 확정한 것은 아니다. 선택 범위·모든 exists/hittable/enabled/기하/가장 깊은 컨테이너/소유 창 조건과 단일15초의 준비·tap·닫힘 예산, 이후 입력 키 검사는 보존한다. 반복 밖 캐시나 성공값 재사용은 없다. 실제 비용과 안정성은 다음 Actions에서 확인한다.

`ed4ea9a`의 [Dark7](https://github.com/hellosunghyun/mirror/actions/runs/36978047439)는 준비·도메인159개·Mac 단위159개/UI6개·iPad 단위156개/UI6개 및 두 native의 guard·최종xcresult6passed를 통과했다. Phone 컴파일177초·receipt는 실제 검증됐지만 검색의108행에서 전면 상태·app 창1개·probe1개의 복합 scope guard가 실패했다. 어느 항목이 실패했는지는 미관측이며, native value 파싱이나 실제 버튼 경계 비교에는 도달하지 못했다. D6의 상태 표시줄 AX 부재를 이 source의 원인으로 대입하지 않는다. aggregate 실패·UI 증거 skipped로 새 다크43장은 없고 HTTP 감시를 종료했다.

후속 DEBUG/iOS modifier는 UI 테스트 iPhone에서만 기존 root 콘텐츠를 첫 child로 유지한 ZStack에 투명1pt native 관측 뷰를 명시적 sibling으로 둔다. 배경 장식의 AX 노출 여부를 제어할 후보이며 이전 실패의 원인이나 실제 해결을 확정하지 않는다. Release/Mac에는 modifier가 컴파일되지 않고 iPad/일반 DEBUG 실행은 기존 content를 그대로 반환한다. 공통 inspector는 바깥의 같은 호스트, native getter·상태창·좌표·Button 조건과 모델·명령·저장·화면 상수는 보존한다. 세 기존 scope 조건은 순서대로 별도의 고정 실패행으로 나누어 원인을 구분하며 조건을 없애거나 fallback·skip·새 timeout을 추가하지 않는다. SDK·AX 노출과 새 UI6/43원본 수용은 후속 Actions에서 확인한다.

`3aed351`의 [AdHoc50](https://github.com/hellosunghyun/mirror/actions/runs/36981434872)과 [Dark8](https://github.com/hellosunghyun/mirror/actions/runs/36981434927)은 양 준비·도메인159개와 양 Mac 단위159개/UI6개·guard·최종xcresult6passed를 통과했다. 기본50 iPad도 단위156개/UI6개·guard·최종xcresult6passed를 통과했다. 두 Phone의 최초 유효 실패는 검색112행의 `app.windows.count == 1` 검사다. 전면 상태 뒤에 도달했지만 실제 창 수는 미관측이며 probe 유일성·좌표 파싱에는 도달하지 않았다. 기본50의 다른5개 stdout 사례는 통과했고, Dark8에는 추가 capture 실패와 거부 진단1건이 있으나 위치와 둘의 관계는 미확정이다. Dark8 iPad는 첫 앱·확장/단위·통합·구성 단계에서 실패하고 UI 빌드·실행이 skipped됐다. 공개 페이지에는 timed-out 표시가 있지만 어느 내부 명령에서 중단됐는지는 미관측이다. 두 aggregate 실패로 새43장과 기본50 설치 자산은 게시되지 않았다.

후속 검색 검사는 관측 요소를 소유한 실제 창의 유일성을 확인한다. 앱 AX 트리의 모든 Window 개수와 native getter가 속한 scene의 key UIWindow 개수는 다른 범위다. 전면 앱·global probe1개를 확인한 뒤 probe ID를 포함하는 창을 현재 AX identity로 열거하고 owner1개 및 그 창의 실제 frame을 사용한다. 상태 표시줄의 정확한4개 숫자·유한 양의 경계·소유 창 포함, 실제 검색 키보드와 두 global Button의 고유성·유효 경계·hittable/enabled·상태 표시줄 비중첩 검사를 유지한다. 임의의 첫 창이나 고정 inset을 사용하지 않으며 기존6사례·43stage·모든 제품 assertions와 시간 제한을 보존한다. 이 소유 범위 교정의 실제 SDK/runtime 결과는 새 Actions에서 확인한다.

Simulator unit 경로에는 고정 `scope/platform/phase/state` notice만 추가한다. 선택·컴파일·boot·준비 대기·단위 실행·요약·bundle·packaging 명령의 시작과 반환을 구분하며 경로·UDID·원문 로그·계정·서명 정보를 넣지 않는다. 기존 명령·인수·jobs2·trap·실패 코드·GITHUB_OUTPUT·gate·runner·SDK·시간 제한은 유지한다. 출력은 best-effort이고 마지막 미완료 marker는 마지막으로 관측된 구간만 뜻하며 시간 초과 원인을 증명하지 않는다. 로컬에서는 구문·diff만 확인하고 실제 검사는 Actions에서 수행한다.

`be2fdf9`의 [Dark9](https://github.com/hellosunghyun/mirror/actions/runs/36985572406)는 도메인159개·Mac 단위159개/UI6개·iPad 단위156개/UI6개와 각 guard·최종 xcresult6passed를 통과했다. Phone은 컴파일146초·receipt 확인 뒤 검색155행 `button.isHittable`에서 처음 실패했다. 전면 앱·유일 probe 소유 창·실제 상태 표시줄 경계·키보드 존재·고유 Button 및 양의 경계 검사 뒤에 도달했다. 실패 버튼은 추가·설정 중 어느 것인지 미확정이며, `continueAfterFailure=false` 때문에 그 버튼의 enabled·상태 표시줄 비교는 미도달이다. 이 결과만으로 실제 겹침이나 원인을 확정하지 않는다. aggregate 실패로 새로운43장 원본은 게시되지 않았다.

후속 관측은 기존 각 버튼의 frame과 한 번의 `isHittable` 조회만 재사용한다. 고정 두 identifier·메서드와 hittable·창 안 경계·상태 표시줄 아래 배치의 Bool을 원래 assertion 직전에 기록한다. 좌표·제목·AX 원문·추가 조회는 없다. 공개 parser는 실제 유일한 활성 사례, exact5키, 진짜 Bool, 추가→설정의 길이1–2 prefix만 허용하며 무효 transcript는 전체를 거부한다. 원래 enabled 조회와 모든 assertions·여섯 사례·43단계·시간 제한·성공 게이트는 유지한다. 이 관측 추가는 UI 수정이나 전체 통과를 의미하지 않으며, 원인은 새 Actions 결과와 실제 원본에서 확인한다.

## 빠른 날짜 선택의 터치 영역과 추가 원본

일반 날짜 선택의 오늘·내일은 Button 바깥의 여백 대신 실제 Text label 안에 최소44pt 높이를 둔다. 표시된 작업 ID·expected versions·context·token과 기존 날짜 명령은 그대로 사용한다. 오늘 화면의 “이번 정리 결과”는 처음과 정리 종료 뒤에 접어 두며 필요할 때 펼칠 수 있다. 종료 수치·Undo와 오류 경로는 유지하고 목록이 먼저 보이게 한다.

첫 실제 입력 흐름에서는 저장 뒤 빈 입력칸·고정 성공 문구·입력 화면에서의 가시성, 모바일 키보드 유지·키보드 위 안내와 다음 제목에서 안내가 사라지는 동작을 검사한다. 기존 여섯 사례·모든 기존 assertions·46장 계약을 유지하며, 저장 성공 안내의 별도 원본 사진은 이 캡처 계약에 포함하지 않는다. 실제 검사의 통과와 VoiceOver 공지·실기기 수용은 구분한다.

iOS의 compact 탐색 스택에는 `.toolbarMinimizationBehavior(.never, for: .navigationBar)`를 적용해 스크롤 중에도 상단 추가·설정 버튼을 유지하도록 한다. 직전 `3c1c164`의 [Dark10](https://github.com/hellosunghyun/mirror/actions/runs/36989502805)과 [일반52](https://github.com/hellosunghyun/mirror/actions/runs/36989502843) Phone은 각각 단위156개/UI6개·guard·최종xcresult6passed를 통과했고 양 모드 원본43장씩을 직접 검토했다. 이 결과는 새 toolbar 정책·44pt·46장 계약의 수용을 대신하지 않는다. 공개된 고정 toolbar aggregate는 미관측이고 toolbar 최소화가 이전 hittable 실패의 원인인지는 미확정이다. 이 API의 실제27 SDK/runtime 동작과 검색 키보드 중 버튼 사용성은 새 Actions의 기존 assertions·고정 관측·원본 화면으로 확인한다.

기존 ReviewUndo 사례의 첫 일반 picker 열기에서 대상 제목·내일 hittable 검사를 유지하고 오늘 enabled/hittable 및 접힌 `plan.calendar` 부재를 추가로 확인한다. iPhone·iPad에서 두 고유한 실제 Button의 유한한 경계와 폭·높이44pt 이상을 검사하며 Mac에는 모바일 터치 크기를 강제하지 않는다. 첫 picker를 취소하기 직전에 `quick-plan-picker` 원본을 한 장 남긴 뒤 기존 취소 후 미정 유지·다시 내일 선택·Today 제외·10월1일·미완료 회귀를 끝까지 실행한다.

원래43장을 제거하거나 대체하지 않고 세 플랫폼의 새 원본3장을 추가한다. 각 모양은 iPhone15·iPad16·Mac15의46 PNG와 static3개를 포함한49공개 자산을 요구한다. iPad16개 timing이 모두 남도록 고정 진단 tail도16개로 보존한다. stage 누락·중복 대체와 새 stage의 비공개 이름·영상 타입은 합성 fixture에서 거절하며 기존 exact coverage·identity·hash/bytes·정제·게시 게이트를 유지한다. 기존6메서드·모든 assertions·시간 제한·UI guard와 가로 PNG의 방향/원본 보존 계약은 낮추지 않는다.

이 변경은 준비된 구현이며 실제44pt·접힘·새46원본 시각 수용은 후속 Actions 결과로 확인한다. 현재와 역사적43-stage run/자료를 새46-stage 결과로 계산하지 않는다. 현재 helper는 그대로 보존하고 새 실제 SHA/run/build/attempt 확인 뒤 별도46-stage 검토 helper를 준비한다. 과거14-stage baseline을 사용하는 SDK 진단 workflow는 변경하지 않으며 새46 collector를 그 과거 결과에 적용하면 새 stage 부재를 정상적으로 거절한다. 일반 picker 한 장은 다른 날짜를 펼친 모습·VoiceOver·최대 글자·실기기와 전체QA87 수용을 대신하지 않는다.

## 입력 오류 뒤 재입력 실패의 제한된 관측

`ac76af8`의 [Dark14](https://github.com/hellosunghyun/mirror/actions/runs/37001269475)는 도메인159개와 Mac 단위159개·UI6개·guard·최종xcresult6passed를 통과했지만 모바일 검증이 실패하여 앱샷 게시가 생략됐다. Phone의 첫 정제 실패는 긴 제목 사례의 원래399행 `capture.open` 활성화에서 `scrollContainerMissing`이다. 직전 일반55도 같은 사례·위치·분류였으며 실제 버튼 경계·키보드·modal 상태와 원인은 아직 확인하지 못했다. Pad는 첫 입력 사례의 원래1359행 `waitForValue`에서 실패했다. 어느 호출·기대값에서 멈췄는지는 미확정이며 Phone 실패와 같은 원인으로 취급하지 않는다. 이전 일반54·Dark12의 원본92장 검토와 서명 일반54 배포는 이 최신 실행의 통과를 대신하지 않는다.

긴 제목 사례의 정상 재입력 호출에만 관측 flag를 전달한다. 기존 일반 스크롤 컨테이너 부재가 이미 결정된 뒤에 고정 메서드·`capture.open`·`validationRecovery`와 12개의 Bool/null 판정을 한 번 출력한다. 존재·활성·조작 가능·양의 경계·단일 소유 창·키보드/alert/sheet 존재와 창 안 배치·상태 표시줄 아래 배치 등을 구분한다. 실제 식별자·입력·AX dump·기기 정보·좌표는 직렬화하지 않는다. 창 안 배치는 유효한 단일 소유 창을 요구하고, 상태 표시줄 아래 배치는 같은 창의 고유한 native probe와 유효한 경계를 추가로 요구한다. 필요한 근거가 없으면 두 nullable 판정은 추정하지 않는다. 실패 결정 이후의 새 조회이므로 원래 실패 순간과 원자적으로 같은 상태를 보장하지 않는다.

공개 parser는 실제 유일한 활성 baseline 사례에서 exact4키와 exact12판정, 진짜 Bool 및 지정된 두 nullable 필드만 허용한다. 전사에 후보가 반복되거나 무효 후보가 하나라도 섞이면 부분 승인도 출력하지 않고 거절 수만 남긴다. 중복 JSON 키·추가 필드·4096byte 초과·혼합 진단/실패/event·위조 활성 사례와 겹친 동일 사례의 불완전 종료를 거절한다. 정상 출력은 `stdoutOnly`이며 Actions 성공 출력·실행 수·UI guard를 대체하지 않는다. 이 개인정보·문맥·게이트 회귀9개는 GitHub Actions에서 실행한다.

원래 여섯 UI 메서드·82개 assertion 호출·25개 XCTFail 호출의 순서와 문구, timeout·tap·swipe 및46원본/49자산 계약을 정적으로 대조해 보존했다. assertion 호출 수는 실제 러너의 테스트 완료 수가 아니다. 성공 경로에는 추가 AX 조회나 행동을 넣지 않고 실패·throw·스크롤 횟수·기다림·skip·게시 조건도 바꾸지 않는다. 이번 변경은 원인 관측 준비이며 제품 수정이나 모바일 통과를 의미하지 않는다.

## 저장소 통합 검사의 실행 순서

`90f9c22`의 [일반57](https://github.com/hellosunghyun/mirror/actions/runs/37008995469) 도메인은36개·94개 그룹을 통과했지만29개 그룹이 실패했다. 고정 독립 인스턴스 진단은 `locallyCommitted`/`unavailable`, busy `false`/`true`다. 같은 소스의 [Dark15](https://github.com/hellosunghyun/mirror/actions/runs/37008995501) 도메인은159개를 통과했다. 일반57의 공개 source218행은 보였으나 실제 case event와 결합되지 않았으므로 추가 실패의 범위를 추정하지 않는다.

실제 Core Data 저장소를 각각 만드는 `StoreIntegrationTests` suite의 검사들만 순서대로 실행한다. suite 내부의 독립 store 두 개는 기존 `async let`으로 동시에 실행하고, 실제 두 프로세스의 동일 token 경쟁과 잠금 timeout·취소·회수도 그대로 검증한다. 기존26개 Test 선언·158개 expect·32개 require·두 async let·다섯 timeLimit과 원래 실패 조건·설정·저장소 구현은 유지한다. 전체 Data29 완료 집계와 이 suite의 소스 선언26개를 구분한다.

원본05 §5는250ms 내외의 짧은 재시도 목표와 초과 시 “다른 변경을 반영 중” 상태의 재시도를 요구한다. 이 변경은 서로 다른 테스트 저장소의 동시 디스크 부하를 제한하며 기존250ms를 늘리지 않는다. 다른 suite의 부하는 남으므로 잠금 실패의 원인 해결이나 실제 기기 성능 수용을 의미하지 않는다. 실제 실행과 기존159개·각 플랫폼 단위/UI·46원본·서명/게시 게이트는 후속 Actions에서 확인한다.

## 수용 기준과 검증 한계

[build43](https://github.com/hellosunghyun/mirror/actions/runs/36960263569)은 세 플랫폼의 단위 검사·실제 UI 6개씩·guard와 앱샷 게시를 통과했다. 공개 46자산의 identity·bytes·SHA256을 확인하고 가로 원본 한 장을 직접 열었지만, main-screen 캡처도 내용이 90도 돌아가 시각 검증에 실패했다. native UIImage는 left, logical 1376×1032, CGImage와 공개 PNG는 2064×2752다. 공개 PNG에는 EXIF가 없지만 export 단계의 방향 정보는 확보하지 못했으므로 손실 단계를 확정하지 않는다. 이 실행의 나머지 42장을 새로 직접 검토했다고 기록하지 않는다.

후속 수정은 가로 한 장만 같은 native screenshot의 `imageOrientation`을 PNG eXIf의 26-byte orientation 전용 TIFF로 직렬화하여 data attachment로 첨부한다. 원본 IHDR·모든 IDAT와 기존 chunk CRC는 그대로 복사하며 픽셀 회전·crop·렌더링·재압축을 하지 않는다. 파일 전체의 bytes·hash는 메타데이터 때문에 달라질 수 있다. collector는 정확한 iPad 가로 stage에서 유효하고 단일한 방향값만 재구성하며 다른 EXIF 태그·IFD·text를 제거한다. 다른 42장의 기본 정제 정책과 manifest의 raw width·height, schema·14키 provenance 계약은 유지한다. prepare·단일/집계 재검증과 게시 전에 EXIF 적용 후 가로 크기를 요구하지만, 이 검사는 CW/CCW 방향이나 시각 수용을 판정하지 않는다.

회귀 6개는 양 byte order·방향값 1–8·다른 IFD/개인 metadata 제거·멱등성, 가로 stage만 보존 및 다른 42장 기존 결과 유지, prepare의 표시 크기, 손상·중복 방향 추론 금지, 정합한 hash/dimensions를 가진 잘못된 가로 증거의 단일/집계 거절과 게시 요청 0회, 다른 stage의 EXIF 게시 거절을 검사한다. SDK attachment export가 eXIf를 보존하는지, 원본/export/public IHDR·IDAT가 같은지, 새 가로 PNG의 글자가 정방향이고 두 열·시스템 노출이 정상인지는 새 Actions와 실제 원본에서 확인한다.

밝은 모양의 기본 검증·서명 배포와 별개로 어두운 모양 검증 workflow를 각 관련 push에 실행한다. 현재 계약은 같은6사례·46장과 각 플랫폼 시간 제한을 독립 run/SHA/build/attempt·receipt·Release로 유지한다. 두 Dark shared scheme의 TestAction에만 고정 dark 값을 전달하고 CI는 UI build/test만 해당 scheme으로 선택한다. receipt의 기존 ui_scheme 필드를 실제 선택값과 대조해 밝은/어두운 산출물 교환을 거부한다. 앱은 DEBUG·MIRROR_UI_TESTING=1인 main window에만 강제 모양을 적용하고 Release·기본 scheme은 기존 시스템 모양을 유지한다. 전역 host/Simulator 모양은 바꾸지 않는다. 실제 SDK 환경 전달과 현재 계약의 어두운 원본46장을 확인하기 전에는 새 다크 검증 완료로 기록하지 않는다.

- 기존 여섯 UI 흐름의 실제 완료·실패 0·skip 0와 모든 필수 메서드를 확인한다. assertion·guard·실행 제한을 낮추지 않는다.
- Mac 완료 버튼의 실제 접근성 경계가 폭 220pt·높이 46pt를 넘지 않는 회귀를 추가했다. 목표 버튼 최대 200×44pt에 네이티브 렌더링 경계 오차를 허용한 검사다.
- Mac에서 미저장 상세 편집 중 빠른 입력을 열고 닫은 뒤 보관함·오늘로 이동해도 입력이 유지되는 경로를 확인한다.
- 실제 PNG를 열어 탐색·상세·버튼 위계, 겹침·잘림, 모바일 키보드·시트, iPad 가로 일정, 오류 문구를 검토한다. 테스트 통과나 앱샷 생성만으로 시각 수용을 완료 처리하지 않는다.
- 이 캡처는 각 러너가 선택한 기본 화면 크기·모양이다. 모든 창 크기·양쪽 색상 모드·가장 큰 Dynamic Type·VoiceOver·실기기 입력의 완료 증거는 별도로 남겨야 한다.

최종 실행 결과와 직접 화면 검토 결과는 [PR #2](https://github.com/hellosunghyun/mirror/pull/2)의 검증 기록 및 연결된 run·`ui-review` Release로 확인한다. QA 87개 전체 수용과 App Group·iCloud·위젯·Siri의 실기기 수용을 이 UI 검토 결과로 대신하지 않는다.
