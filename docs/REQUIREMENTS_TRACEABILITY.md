# 미러 요구사항·QA 추적표

## 후속 구현과 검증 · 2026-10-03

간편 입력은 제목만 저장하는 기본 경로와 접힌 메모·링크·날짜를 사용한다. 사용자가 날짜를 선택하면 제목과 계획을 `captureWithPlan`으로 원자 저장하고, 취소·실패 때 입력을 보존한다. FR-001/006/009의 생성·재시도·재시작 회귀와 최대 글자 입력 사례를 작성했으며 원격 수용을 코드 작성과 구분한다. 목록의 미루기와 요청 상세, 기본 숨긴 iPad 보조 일정, 긴 제목의 명시적 펼침은 [간편 UX](SIMPLE_UX.md)와 [UI 검토](UI_REVIEW.md)에서 추적한다.

FR-027의 실제 두 개·스무 개 선택·날짜 변경은 [별도 batch UI 검증](BATCH_UI_REVIEW.md)으로 확인한다. 작성한 두 사례·결과 게이트 회귀15개는 실행 결과가 아니다. 원래 제목·UUID·미완료·선택하지 않은 작업을 실제 UI에서 검사하고, Q-080의 stale 전체 거부는 별도 조건으로 유지한다. 전체 FR30·NFR12·QA87과 물리 기기·Widget/Share·CloudKit·사용자 게이트의 미완료 상태를 유지한다.

## 이전 검증 기준 · 2026-10-01

`d7a3630`의 [Actions 실행 36867363304](https://github.com/hellosunghyun/mirror/actions/runs/36867363304)은 준비 회귀 85개·SwiftPM 159개·Mac 단위 159개/UI 6개·iPhone/iPad 각각 단위 156개/UI 6개를 통과했다. 실패·skip은 0개이며 [동일 실행의 Release](https://github.com/hellosunghyun/mirror/releases/tag/adhoc-36867363304)에 iOS IPA와 Developer ID 서명·공증·staple·Gatekeeper를 확인한 macOS DMG가 게시됐다. 이전 인증서 불일치·IPA 미게시 기록은 아래의 과거 증거다.

전체 요구사항 완료를 선언하지 않는다. 현재 코드 공백·설정 막힘·미검증은 [구현 공백](IMPLEMENTATION_GAPS.md)에 구분하며, UI 기능 테스트 통과만으로 시각 품질을 승인하지 않는다. [UI 검토](UI_REVIEW.md)는 실제 앱샷 43장과 기존 6개 UI 흐름을 Actions에서 확인한다. 수정 전 캡처 변경 `728d682`의 준비 회귀 116개는 실제 통과했으며 앱 UI 수정의 전체 결과는 해당 새 실행과 별도 `ui-review` prerelease로 확인한다.

## 이전 검증 기록

`f091e83`의 [별도 Swift 실행 36820276082](https://github.com/hellosunghyun/mirror/actions/runs/36820276082)은 실제 최종 결과에서 SwiftPM 151개, Mac 단위 151개·UI 6개, iPhone/iPad 각각 단위 150개·UI 6개를 통과했다. 각 summary의 실패·skip은 0개이며 세 UI strict guard는 필수 bundle 1개/case 6개와 missingMethods·nonPassedMethods 없음이다. 같은 SHA의 Ad Hoc 사전 검사는 유효한 개인 키 identity 1개와 프로파일 인증서 1개를 확인했으나 일치 수는 0개여서 실패했다. P12 가져오기는 성공했으며 현재 P12와 같은 인증서로 생성한 프로파일 Secret 갱신이 필요하다. IPA·Release는 아직 생성되지 않았다.

같은 `f091e83`의 [Ad Hoc 실행 36820272558](https://github.com/hellosunghyun/mirror/actions/runs/36820272558)은 Mac/iPhone 최종 UI 통과와 iPad 단위 150개 통과를 확인했으나 iPad UI는 20분 제한으로 중단됐다. stdout의 앞 네 사례 통과·내일 검색 시작은 부분 진단이며 최종 UI summary/strict guard 통과가 아니다. 별도 Swift 실행의 성공과 이 배포 게이트 실패를 구분한다. 수정분은 새 실행에서 확인하며 제한이나 assertion을 낮추지 않는다.

이번 후속 구현은 위젯 단일 입력의 저장 후 Today 전환, 상태/제목 필터 후 검색 결과 50개 제한, 복원 pending 완료 표시와 새 작업·격리 기록 미리보기, foreground 캘린더 권한 갱신, Mac Cmd+F 초기 포커스, 명시 일간·주간 정리 모드, 넓은 iPad의 인접 일정을 보완한다. 실제 두 Swift 프로세스 동일 명령 경쟁과 canonical 저장 후 SIGKILL·재시작 회귀도 추가한다. 자체 export를 거부하던 임의 32MiB 복원 상한을 제거하고 위젯 주간 패널에 선택 주와 시작·종료 월일을 표시한다. 1만 작업·10만 유효 원본의 Release baseline은 실제 저장·조회·명령·export 크기와 전체 파일 두 번 복원을 별도 Actions에서 검사한다. 작성한 소스와 새 SHA의 실제 Actions 통과를 구별한다. 외부 위젯·Siri·CloudKit·접근성·성능·사용자 게이트는 계속 not_run/blocked다.

[전체 구현 계획](IMPLEMENTATION_PLAN.md)의 범위와 검증 책임을 추적한다. 원본 [FR/QA 연결](../postpone-app-docs/validation/traceability.json)과 [QA 87개](../postpone-app-docs/validation/qa-cases.json)의 ID·기대 결과를 유지하고 단계·검증 경로를 추가했다. 원본 보고서는 수정하지 않는다.

## 1. 이전 증거와 상태

최신 커밋 `2da19a9`의 [Ad Hoc 실행 36817569714](https://github.com/hellosunghyun/mirror/actions/runs/36817569714)은 서명 입력 존재·준비 Python 40개·SwiftPM 151개를 통과했다. Mac 단위 151개/UI 6개, iPhone 단위 150개/UI 6개, iPad 단위 150개/UI 6개도 모두 실제 최종 summary에서 통과했다. 세 플랫폼의 UI 실패·skip은 0개이며 strict guard는 각각 bundle 1개/case 6개/missingMethods·nonPassedMethods 없음이다. 여섯 UI 부분 시나리오 통과는 QA 87개 전체나 실기기·시스템 표면 수용 완료를 뜻하지 않는다.

archive job `110231668813`은 `프로파일과 일치하며 개인 키가 있는 서명 인증서가 정확히 하나여야 합니다.`라는 match guard 메시지로 실패했고 publish는 skipped였다. 서명 IPA와 Release는 생성하지 못했다. 현재 -v codesigning 조회는 유효한 identity만 확인하므로 이 메시지만으로 P12 암호 오류·다른 인증서·개인키 부재·신뢰 체인 문제를 구분할 수 없다. 테스트 통과와 실제 서명·게시 성공을 구분한다.

이전 커밋 `25515ee`의 [Ad Hoc 실행 36815613352](https://github.com/hellosunghyun/mirror/actions/runs/36815613352)은 Mac 단위 151/151개 통과·UI 3/6개 통과/3개 실패·skip 0개, xcodeCompletionReported=true였다. 실패는 완료·Undo/내일 검색/주 패널 사례다. 이후 iPhone은 단위 150개/UI 6개를 통과했지만 iPad UI는 stdout 3개 passed·1개 failed, 내일 검색 started·주 패널 미보고 상태에서 20분 제한으로 중단됐다. iPad 최종 UI summary/tree/strict guard는 없으며 archive·publish는 실행하지 못했다.

이전 커밋 `32b61596a9a6d18d31232cf9b83a640e6320050f`의 [Ad Hoc 실행 36812798695](https://github.com/hellosunghyun/mirror/actions/runs/36812798695)은 최종 failure다. 세 서명 입력 존재·준비 Python 40개·SwiftPM 151개와 Mac 단위 151개/UI 6개는 통과했다. Mac UI strict guard는 bundle 1개/case 6개, 실패·skip 0개다. 모바일 단위는 iPhone/iPad 각각 150개 통과했다. iPhone UI stdout은 3개 통과와 완료·Undo/내일 검색/주 패널 부분 종료 3개 실패, iPad는 2개 통과와 capture/완료·Undo/내일 검색/주 패널 부분 종료 4개 실패였다. 두 모바일은 xcodeCompletionReported=false로 각각 20분 제한 중단됐고 최종 UI summary/tree/strict guard는 확보하지 못했다. archive·publish는 skipped이며 Release 목록은 0개다. 실제 P12 암호·인증서/개인키/프로파일 일치와 서명 IPA·Release 게시는 미검증이다.

같은 커밋의 [별도 Swift 실행 36812801840](https://github.com/hellosunghyun/mirror/actions/runs/36812801840)은 이 기록 시점 Mac 단위 151개/UI 6개와 SwiftPM 151개를 통과했다. iPhone 단위 150개는 통과했고 UI stdout 3개 통과·3개 실패, suite 747.419초 뒤 20분 제한으로 중단됐다. iPad UI는 진행 중으로 최종 결과가 미확정이다. 별도 실행의 부분 결과나 과거 iPad 통과를 이번 배포 게이트 통과로 대신하지 않는다.

이전 커밋 `38d78498ff56781b9762893c0d96b77cf253176d`의 [Ad Hoc 실행 36808965234](https://github.com/hellosunghyun/mirror/actions/runs/36808965234)은 최종 failure다. 세 서명 Secret의 존재·준비 Python 40개·SwiftPM 151개는 통과했다. Mac 단위 151개/UI 6개도 통과했고 UI strict guard는 bundle 1개/case 6개, 실패·skip 0개다. iPhone/iPad 단위는 각각 150개 통과했다.

iPhone UI stdout은 완료·Undo를 포함한 5개 통과와 내일 검색 1개 실패, suite 971.203초다. iPad UI stdout은 4개 통과와 내일 검색·주 패널 부분 종료 2개 실패, suite 1017.165초다. 두 모바일 모두 xcodeCompletionReported=false이며 UI가 20분 제한으로 중단됐다. 최종 UI summary/tree/strict gate를 확보하지 못했으므로 stdout 결과를 최종 xcresult 통과·skip 0이나 전체 UI 수용으로 기록하지 않는다. archive·publish는 skipped이고 실제 P12 암호 검증·인증서/개인키/프로파일 일치·서명된 IPA와 Release 게시는 미검증이다. 이 실행 후 확인한 Release API 목록은 0개다.

같은 커밋의 [별도 Swift 실행 36808970265](https://github.com/hellosunghyun/mirror/actions/runs/36808970265)은 최종 failure다. Mac 단위 151개/UI 6개와 SwiftPM 151개는 통과했다. iPad job `110199559968`도 단위 150개/UI 6개 통과, UI summary 실패·skip 0개와 strict guard bundle 1개/case 6개/missingMethods·nonPassedMethods 없음을 확인했다. iPhone은 stdout 5개 통과·내일 검색 1개 실패, suite 765.085초와 20분 UI 제한 중단으로 실패했다. 별도 실행의 iPad 최종 통과와 Ad Hoc iPad의 stdout 4개 통과·2개 실패/집계 중단을 구분하며 별도 결과로 배포 게이트 실패를 대신하지 않는다.

이전 커밋 `027a8cbce6842973ba7ad986ec411251483ce7c5`의 [Ad Hoc 실행 36805275410](https://github.com/hellosunghyun/mirror/actions/runs/36805275410)은 최종 failure다. Mac 단위 151개/UI 6개, iPad 단위 150개/UI 6개는 실제 summary와 strict guard에서 통과했다. 두 UI guard는 bundle 1개/case 6개/missingMethods·nonPassedMethods 없음이며 실패·skip 0개다. iPhone 단위 150개는 통과했지만 UI job `110188133795`는 20분 제한으로 중단됐다. stdoutOnly에는 여섯 case 시작/완료와 capture·긴 제목·정리 Undo·주 패널 4개 passed, 완료 Undo·내일 검색 2개 failed가 있다. suite는 6 tests/2 failures/0 unexpected, 920.990초였고 xcodeCompletionReported=false다. 최종 UI summary/tree/strict guard와 실제 assertion·selector·AX 오류 본문이 없어 iPhone 최종 수용·skip 0개나 실패 원인을 확정하지 않는다. archive `110194664010`와 publish `110194664167`는 skipped로 실제 키 일치·IPA 서명/export·Release 게시 성공도 미검증이다.

같은 커밋의 [별도 Swift 실행 36805279997](https://github.com/hellosunghyun/mirror/actions/runs/36805279997)도 최종 failure다. SwiftPM 151개, Mac 단위 151개/UI 6개와 iPad 단위 150개/UI 6개는 통과했고 Mac/iPad strict guard의 실패·skip은 0개다. iPhone 단위 150개는 통과했지만 UI는 stdout 4개 통과·2개 실패, suite 6 tests/2 failures/0 unexpected·946.160초, xcodeCompletionReported=false를 남긴 뒤 20분 제한으로 중단됐다. 이 946.160초는 Ad Hoc 실행의 920.990초와 별도 증거이며 iPhone 최종 UI summary/tree/strict guard는 확보하지 못했다.

별도 실행의 완료 Undo 사례는 편집 제목 입력까지 정상이고 `detail.save`가 존재하지만 hittable=false였다. CollectionView frame=(0,62,402,350)에서 swipeUp 한 번 뒤 `detail.save` 버튼의 NoMatches snapshot 오류로 실패했다. 실제 저장 탭·완료·Undo 이전 실패이므로 완료 명령이나 Undo의 실패 원인으로 단정하지 않는다. 내일 검색 사례는 row를 실제 탭한 뒤 keyboard frame=(0,590,402,226)이 남고 `detail.plan`이 없었다. 자동 저장이나 overlay를 원인으로 확정하지 않으며 두 실패의 실제 동작 원인은 후속 검증이 필요하다.

이전 `68c4c9d08d63667c4b26d4c2f52052a53fe91fdf`의 [Ad Hoc 실행 36803345968](https://github.com/hellosunghyun/mirror/actions/runs/36803345968)은 당시 중간 기록이다. Mac 단위 151개 통과·UI 5개 통과/1개 실패·skip 0개였고 stdoutOnly와 xcresult가 일치했다. 완료 Undo는 기대 라벨과 다른 task.complete=완료, enabled/hittable=true에서 실패했지만 정상 편집 제목/피드백과 state.error 없음만으로 클릭 전달·projection guard·stale 여부를 확정하지 못했다. 당시 모바일 UI와 서명은 미완료였다. 최신 Mac/iPad 여섯 사례 통과를 당시 실패의 원인 확정이나 전체 QA 수용으로 확대하지 않는다.

이전 `a7ef8a2df18a92e1146fde9b1b6c0ad451cc9a41`의 [Ad Hoc 실행 36801483055](https://github.com/hellosunghyun/mirror/actions/runs/36801483055)은 두 모바일 UI의 20분 제한 중단으로 최종 failure이며 archive/publish는 skipped다. Mac 단위 151개·UI 5개 통과/1개 실패는 보존한다. iPad는 CI 로그 01:58:32.600의 suite failed와 weekPanel case 129.757초 뒤 review.finish.isHittable invalid activation point를 보고했지만 최종 summary/tree가 없어 case 수를 확정하지 못한다. 같은 SHA의 standalone은 concurrency cancelled였고 Mac 단위 151개/UI 5/6과 SwiftPM 151개만 확보했다. 모바일은 판정하지 않는다.

이전 `873049b2709de2a97dffbdb49a55706870f33373`의 [Ad Hoc 실행 36800189042](https://github.com/hellosunghyun/mirror/actions/runs/36800189042)은 최종 failure다. Mac job `110172582614`의 단위 151개 통과·UI 5개 통과/1개 실패·skip 0개, 완료 Undo 전 `detail.title` enabled=true/hittable=false·소유 scroll 부재가 확인됐다. iPhone/iPad UI는 각각 20분 제한 중단으로 최종 summary/tree/guard가 없으며 완료 case 수를 확정하지 못한다. iPad 첫 시나리오는 `review.finish.isHittable` 조회의 invalid activation point였다. archive/publish는 skipped로 인증서·개인키 일치는 미실행이다. 같은 SHA의 [standalone 실행 36800192812](https://github.com/hellosunghyun/mirror/actions/runs/36800192812)은 새 push concurrency로 cancelled됐다. Mac `110172593081`의 5/6 UI 결과만 보존하고 iPad는 unit 취소/UI 미실행, iPhone은 로그 미확보로 판정하지 않는다. [준비 검사 36800188766](https://github.com/hellosunghyun/mirror/actions/runs/36800188766)의 Python 40개 통과는 서명·전체 앱 수용 증거가 아니다.

`38d7849`에는 상세 편집 저장·취소를 Form 밖 고정 footer의 우선 영역에 44pt 높이로 배치하고 compact content/statusBar에 형제 높이를 할당한 변경이 포함됐다. 기존 snapshot·접근성 ID·isSaving guard와 여섯 UI 사례의 모든 assertions·통과 판정은 유지했다. iPhone의 완료·Undo 실제 case Passed는 확인했지만 이를 전체 UI나 QA 87개 완료로 확대하지 않는다. 실제 SDK help의 -enableCodeCoverage 지원과 두 모바일 UI의 coverage NO notice도 확인했으나 결과 마감 문제 해결은 입증되지 않았다. 시간 초과나 stdout 결과를 테스트 성공으로 바꾸지 않는다.

이전 `38d7849`의 별도 실행 전체 로그에서 최초 내일 검색 실패 시 직전 검색행 frame=(16,383,370,102)의 중심 Y는 434이고, 진단 시 유일한 보관함 CollectionView frame=(0,0,402,403)의 하단보다 31pt 아래였다. 실제 행 Tap/Synthesize 뒤 키보드가 남고 `detail.plan`이 없었으며 `state.feedback`은 `완료했어요.`였다. 캐시된 행 좌표와 실패 진단 시 표시 영역의 관측은 접근 geometry 보완의 근거이며 전체 원인 확정을 뜻하지 않는다.

이전 `32b6159` Ad Hoc iPad의 최초 실패는 `review.finish`의 hittability 조회에서 invalid activation point가 발생한 것으로 MirrorUITests.swift:247에 기록됐다. 구체적인 소유 영역·geometry 증거는 별도 실행 iPhone annotation에서 확인했다. 완료·Undo 사례의 행 중심 Y 약 333은 CollectionView의 하단 648 안에 있었지만 소유 컨테이너 guard에서 실패했고, today.list는 존재하며 키보드는 없었다. 내일 검색 사례도 같은 소유 영역 guard에서 실패했다. 이 결과만으로 컨테이너 hittability=false를 단독 원인으로 확정하지 않는다.

이전 소유 컨테이너·부재 검사 보완은 `task.row.*`의 소유 컨테이너 탐색에서 컨테이너 hittability 필터 대신 실제 descendant ID·양수 frame·실제 window와의 교집합을 확인한다. 후보의 id/type/frame/containsTarget/window 진단을 남겨 소유 관계와 표시 영역을 확인한다. 행 자체의 hittable/enabled·중심의 표시 영역 포함 조건, 최대 8회 실제 scroll·일반 native tap은 유지한다. 닫힌 버튼의 부재 검사는 hittability를 조회하지 않고 전체 matching ID의 firstMatch.exists=false를 기존 15초 동안 확인한다. 제품 소스·상태·명령과 기대값·여섯 사례의 28개 assertions·15초 대기·최종 xcresult/strict guard 판정은 유지한다. 고정 좌표 tap이나 행동 재시도는 추가하지 않는다. 이 보완만으로 성공을 확정하지 않으며 후속 실행의 실제 결과와 구분한다.

같은 `25515ee`의 [별도 Swift 실행 36815617243](https://github.com/hellosunghyun/mirror/actions/runs/36815617243)은 최종 cancelled였다. 완료한 iPhone job `110221075621`의 단위 150/150개/UI 6/6개 통과·실패/skip 0개와 strict guard bundle 1개/case 6개/missing·nonPassed 없음은 부분 증거로 보존한다. 취소된 별도 실행이나 그 부분 성공으로 당시 Ad Hoc의 실패를 대신하지 않는다.

이후 확보한 `25515ee` 전체 로그는 content 열 X=152..432의 행에 대해 sidebar X=-38..152를 소유 영역으로 선택하고 실제 스크롤 8회 뒤 세 사례가 실패한 경로를 확인했다. sameColumn·선택 owner 진단 변경을 포함한 `2da19a9`에서 Mac 여섯 UI 사례가 최종 통과했다. 기존 여섯 사례 본문·28개 assertions·최대 8회 실제 스크롤·행 hittable/enabled 확인·실제 tap·최종 xcresult/strict guard 판정은 유지했다.

후속 서명 검사 보완은 --preflight 모드에서 프로파일 준비 단계까지 검증한 뒤 임시 자료를 정리한다. 전체 identity·valid identity와 각각의 profile 일치 수, 가져온 인증서의 matchingImportedCertificateCount만 안전 진단으로 남긴다. 프로파일 준비 출력은 비공개 파일에 보관하고 고정 signing_stage 오류 notice를 사용하며 구체 도구 출력·해시·DN·서명 자료는 출력하지 않는다. 인증서 부재·인증서는 있지만 개인키 identity를 조회하지 못한 상태·전체 identity는 일치하지만 valid identity가 없는 상태를 정적 메시지로 구분하되 valid identity가 정확히 하나여야 하는 기존 선택 gate는 유지한다. workflow는 presence 뒤 별도 signing-materials job을 병렬로 실행하고 archive에 기존 네 검증 gate와 새 서명 preflight 성공을 함께 요구한다. 실제 서명 원인 판별과 이 변경의 효과는 새 SHA의 Actions 검증 대기다. 제품 상태·명령·테스트 기대값과 QA 87개 원본은 유지하며 서명 IPA·Release·실기기 수용은 미완료다. 아래 V1~V4는 이전 완료 검증 `179428d`의 증거를 보존하며 V5와 UI 메서드 표는 최신 `2da19a9`의 실제 최종 결과다. V6도 최신 준비·서명 실패 범위를 기록하며 이전 실패·취소 기록과 구별한다.

전체 통합 코드는 `67d69e9`부터 추가했으며 모듈 접근·동시성·실제 SQLite 삭제 오류를 회귀와 함께 수정했다. 아래 V1~V4의 이전 완료 검증은 `179428d98dcbfa61470395f7acbd5653b9f25c06`의 [Swift 실행 36796650352](https://github.com/hellosunghyun/mirror/actions/runs/36796650352)이다. SwiftPM과 Mac의 단위·통합 151개(Domain 94, Data 24, System 33), iPhone·iPad 각각 150개(Domain 94, Data 23, System 33)가 완료 보고에서 통과했고 앱·두 확장과 필수 bundle/구성 검사 단계도 성공했다. Mac/iPad는 UI 여섯 Test Case가 모두 Passed, 실패·skip 0개이며 strict guard bundle 1개/case 6개/missingMethods·nonPassedMethods 없음이다. iPhone stdout은 capture·긴 제목·정리 Undo·주 패널/부분 종료 4개 passed, 완료 Undo·내일 검색 2개 failed였다. iPhone UI는 15분 제한으로 중단돼 최종 summary/tree/guard를 확보하지 못했고 전체 실행은 실패했다. Xcode 27의 독립 worker 완료 보고를 합산하며 매개변수 사례와 플랫폼 반복 실행을 별도 테스트로 더하지 않는다.

이전 `1ca1d35ab1ef7fdcb45ef9a010cecdd83396feae`의 [Actions 36793734833](https://github.com/hellosunghyun/mirror/actions/runs/36793734833)은 Mac UI 6개 통과, 모바일 두 플랫폼은 각각 15분 중단이었다. stdout은 iPhone 여섯 메서드 failed, iPad 3개 passed·3개 failed였지만 최종 모바일 집계를 확보하지 못했다. 최신 standalone의 iPad 6개 및 strict guard 통과와 당시 부분 기록을 구분한다.

이전 `179428d`의 [Ad Hoc 실행 36796647867](https://github.com/hellosunghyun/mirror/actions/runs/36796647867)은 Secret 존재·원본/배포 회귀·SwiftPM·Mac 검사가 성공했다. 별도로 실행한 모바일 두 UI job은 각각 15분 제한으로 중단돼 archive·publish는 skipped였고 실제 인증서·개인키 일치·IPA 서명/export는 미검증이다. Release 목록은 해당 시점 0개로 공개 자산 네 개도 없다. standalone의 iPad 성공으로 이 배포 run의 게이트 실패를 대체하지 않는다.

이전 `4ef52f969059ff15c693b635bfd1596d69b42e25`의 [Actions 36791089147](https://github.com/hellosunghyun/mirror/actions/runs/36791089147)은 Mac UI 6개 통과, iPhone UI 6개 실패, iPad 5개 failed 종료·긴 제목 검사 crash 후 집계 미완료였다. 당시 현재 Simulator 로그에서 중복 Command 단축키 예외가 확인돼 Mac 명령 등록을 macOS로 제한했다. 최신 실행은 현재 Mirror IPS 0개·읽기 실패 0개이며 해당 중복 예외가 관측되지 않았지만 화면 전환·입력과 UI 집계 실패가 남았다. 과거 crash 결과를 현재 UI 실패 원인이나 해결 완료로 쓰지 않는다.

이전 `aaa901850f7581216a57358058c3fa4f0fd5b5c4`의 [Actions 36785953557](https://github.com/hellosunghyun/mirror/actions/runs/36785953557)은 SwiftPM/Mac 단위·통합 151개와 iPhone·iPad 각각 150개, 앱·확장 및 actions 16개 구성 검사가 통과했지만 UI는 Mac 1/6, iPhone·iPad 각각 0/6으로 전체 실패였다. 최신 Mac의 6/6 통과와 당시의 UI 실패를 구별한다.

이전 `c94a3522fef4515644a721b1fed8000dba23b5e9`의 [Actions 36763990118](https://github.com/hellosunghyun/mirror/actions/runs/36763990118)은 SwiftPM 151개 통과, native bundle/metadata 형식 검사와 UI 실패의 기록이다. 이때의 파서 문제와 최신 실행의 UI 실패를 구별한다.

이전 날짜 기반 증거는 `74d02286d396c59e860394cdc660d72f5ea6dfa2` 및 Simulator 보완 `fa783ae`, [Actions 36747271079](https://github.com/hellosunghyun/mirror/actions/runs/36747271079)의 네 경로 각각 37개다. 아래 U는 이 순수 날짜 판정의 범위이며 새 저장·UI·확장·동기화나 QA 87개 전체 통과로 확장하지 않는다.

| 증거 | 실제 코드/테스트와 범위 |
|---|---|
| U1 | LocalDate/PlanningContext/PlanTarget, F-001~007/026~033, LocalDateTests: 날짜/주/윤년/DST·자정·형식·Gregorian 경계 |
| U2 | PlanningRules, F-008~020, PlanningRulesTests: Today/Review·유예·수동 모드·완료/삭제/보관 제외·과거 계획 |
| U3 | F-021~025와 deadlineDateProjection/deadlineAcknowledgmentBinding: 마감 환산/확인 조건·task/revision/target 바인딩 |
| U4 | F-034~036와 changedPolicyReceiptFirst: receipt 존재를 주입한 context 순서·같은 날짜의 정책 변경; durable 조회 아님 |
| U5 | storedDatesSurvivePolicyChange/sameInstantDifferentPlanningDay: 저장 날짜 문자열·주와 명시 계획 시간대 보존; 실제 설정·세션/알림 아님 |

| 새 부분 증거 | 실제 실행 범위와 남은 조건 |
|---|---|
| V1 명령·reducer | `CommandValidationTests`/`ReducerTests`와 기존 날짜 tests, Domain 94개. 원본 digest·그룹별 head·멱등성·충돌·pending·조건부 Undo·20개 원자 배치의 생산 API. 실제 CloudKit 전송은 검사하지 않음 |
| V2 실제 영속화 | `StoreIntegrationTests`, SwiftPM/Mac Data 24개, iPhone·iPad Data 23개. 실제 SQLite 재시작·원본 후 장애 복구·경쟁 인스턴스·export/import·로컬 삭제·복원·구독 알림. Mac 별도 OS 프로세스 lock 회귀 포함. 두 실제 Core Data writer 프로세스·물리 보호 데이터·migration/대용량 성능은 별도 검증 |
| V3 시스템 계약 | `SystemContractTests`/`CloudBoundaryTests`, System 33개. 실제 임시 SQLite의 frozen 카드·receipt/토큰·Today 순서·재정리, 알림 planner·안전 딥링크·로컬 계측·Cloud 상태 구독. unhosted OS adapter의 typed 실패를 확인하며 실제 Widget/Siri/권한/CloudKit 성공으로 대신하지 않음 |
| V4 native 빌드·구성 | `179428d98dcbfa61470395f7acbd5653b9f25c06`, [Swift 실행 36796650352](https://github.com/hellosunghyun/mirror/actions/runs/36796650352). SwiftPM/Mac 각각 151개, iPhone·iPad 각각 150개 완료 보고 통과와 필수 세 unit bundle 확인. 세 native 플랫폼의 앱·두 확장 및 privacy/라이선스/URL/App Intents 구성 검사 단계 성공. 앱 수용·실기기·시스템 표면 성공으로 확장하지 않음 |
| V5 UI 부분 시나리오 | 최신 `2da19a9`의 [Ad Hoc 실행 36817569714](https://github.com/hellosunghyun/mirror/actions/runs/36817569714)에서 Mac/iPhone/iPad 각각 최종 UI summary 6개 통과·실패/skip 0개. 세 strict guard 각각 bundle 1개/case 6개/missingMethods·nonPassedMethods 없음. 아래 QA 부분 매핑만 검증한 결과이며 QA 87개 전체·실기기 수용을 뜻하지 않음 |
| V6 준비·배포 로직 | 최신 `2da19a9`의 Ad Hoc 실행에서 서명 입력 존재·준비 Python 40개 통과. unit/UI gate 통과 후 archive 110231668813의 프로파일/개인키 포함 인증서 match guard 실패, publish skipped. `f091e83` 사전 진단에서 P12와 프로파일 인증서 불일치를 확인했으며 서명 IPA·GitHub Release 게시 성공은 미검증 |

| UI 메서드 | 원본 QA의 관련 부분 | Mac | iPhone / iPad |
|---|---|---|---|
| `testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday` | Q-001/Q-009 부분: 미검토 항목의 Today 제외·명시 오늘 배치와 미완료 유지 | 통과 | 통과 / 통과 |
| `testTomorrowStaysOutOfTodayAndIsSearchableInLibrary` | Q-008/Q-010 부분: 내일 항목 검색·날짜 보존·Today 제외. Q-008의 다음 달 항목·정리 큐 제외는 미검사 | 통과 | 통과 / 통과 |
| `testOverlongTitleShowsErrorAndPreservesEveryCharacter` | Q-003 부분: ASCII 501자 입력의 오류 안내·원문 보존·정상 입력 복구. Unicode grapheme/500자 허용 경계는 미검사 | 통과 | 통과 / 통과 |
| `testWeekPanelCancellationAndPartialFinishPreserveUndecidedPlan` | Q-016/Q-019 부분: 취소 뒤 계획 표시 보존·2개 중 1개 결정. plan 변경 0건의 mutation 기록은 미검사이며 원본 10개/6개 결정/4개 미검토와 구별 | 통과 | 통과 / 통과 |
| `testExplicitCompletionAndUndoPreserveEditedTitleAndPlan` | Q-032 부분: 완료·Undo의 상태/제목/기존 계획 표시. deadline/history는 미검사. Q-030의 plan Undo와 Q-033의 과거 날짜 완료 취소는 미검사 | 통과 | 통과 / 통과 |
| `testReviewUndoRestoresUnassignedCardInsteadOfAddingToToday` | Q-029 부분: 직전 배치 Undo의 unassigned 복원·Today 제외. reviewNotBefore는 미검사 | 통과 | 통과 / 통과 |

UI 부분 시나리오는 실제 임시 Core Data 저장소와 고정 시각 `2026-09-30T03:00:00Z`, 한국어 UI에서 실행한다. 원본 QA의 모든 precondition/steps·기기 표면이나 앱 재실행 후 영속 보존까지 완료한 결과가 아니므로 Q 행 전체 상태를 `pass`로 바꾸지 않는다. Mac UI 시나리오에는 키보드 명령 조작이 없으므로 Q-078 검증 완료를 뜻하지 않는다. 최신 표는 세 플랫폼의 최종 summary/strict guard 증거이며 이전 iPhone stdout의 passed/failed 부분 기록과 구분한다. 같은 여섯 시나리오의 플랫폼 반복을 서로 다른 수용 테스트로 합산하지 않는다.

완료 검증 `179428d`의 standalone iPhone 실패는 상세 화면이 열린 동안 root의 `task.undo`가 enabled=true/hittable=false이고 소유 scroll 컨테이너가 없었던 완료 Undo, 보관함 row의 실제 tap 뒤 `detail.plan`이 나타나지 않았던 내일 검색이다. 현재 iPhone Mirror IPS는 0개·읽기 실패 0개다. 이전 `4ef52f9`의 중복 Command 단축키 예외와 `1ca1d35`의 입력 초기화/화면 전환 오류, 당시 두 실패를 최신 `2da19a9`의 세 플랫폼 UI 통과와 구분한다.

이전 소스 `542a0093fff829d93f4678206289712a6e68819c`의 [Actions 36773091969](https://github.com/hellosunghyun/mirror/actions/runs/36773091969)은 GitHub 계정 결제/사용 한도 때문에 모든 job의 실행 단계가 0개였다. 그 실행은 UI/IPS가 생성되지 않은 당시의 `not_run` 기록이며, 현재는 위 최신 실행의 실제 결과로 구분한다. 과거 실행 차단을 현재 UI 실패의 원인으로 쓰지 않는다.

아래 FR 행의 `코드 추가`는 생산 경로가 작성됐다는 뜻이며 새 통합 코드의 빌드·수용 통과를 뜻하지 않는다. 이전 U 근거는 위 순수 함수에 한정한다. 모든 FR의 앱 수용은 아직 미완료이고, 모든 Q 행의 전체 시나리오는 `not_run`이다. 부분 UI 결과는 V5와 해당 Q 행에 별도로 남긴다. Team은 제공된 Ad Hoc profile에서 비공개로 확인했다. Secrets API의 권한 부족 403과 [최초 Ad Hoc 실행 36791084786](https://github.com/hellosunghyun/mirror/actions/runs/36791084786)의 세 Secrets 누락은 과거 기록이며 최신 Ad Hoc 입력 검사는 세 Secrets의 존재를 확인했다. 실제 인증서·개인키 일치는 최신 archive의 match guard 실패로 미검증이며 원인은 추가 진단이 필요하다. profile에는 App Group·iCloud container 권한이 없으며 실제 Apple 등록·서명 IPA 배포·공유 컨테이너와 두 기기 검증은 미완료다. 향후 결과는 실제 full SHA/run/OS/기기/고정 시각/expected/actual/증거/남은 범위와 함께 이 파생 추적표에 갱신한다.

## 2. FR-001~030

| FR | 우선순위·요구사항 | 단계 | 원본 QA | 현재 구현·부분 증거 | 완료에 남은 범위 |
|---|---|---|---|---|---|
| FR-001 | P0 빠른 입력 | D-03/04/06 | Q-001, Q-002, Q-003, Q-004, Q-007 | 코드 추가: TaskContent/Capture, App Capture UI·줄 분리 미리보기 | 원격 통합·UI 검증 및 작업 생성·영속/화면 |
| FR-002 | P0 공유 입력 | D-04/07/13 | Q-005 | 코드 추가: iOS/Mac Share adapter·공통 Capture | 원격 통합·UI 검증 및 Share 원문·URL·오프라인 |
| FR-003 | P0 보관함과 전체 검색 | D-04/06/11 | Q-008 | 코드 추가: 실제 저장 조회·보관함 검색/필터 | 원격 통합·UI 검증 및 전체 저장 조회·검색 UI |
| FR-004 | P0 일간 정리 | D-03/05/06/09 | Q-021, Q-022, Q-023 | 코드 추가: frozen App/Widget 큐·Review ack/close | 원격 통합·UI 검증 및 cycle/ack/session/큐·자동 전환 |
| FR-005 | P0 주간 정리 | D-03/09/12 | Q-020 | 코드 추가: 주간 cycle·알림 교체 | 원격 통합·UI 검증 및 단일 주기·중복 큐/알림 |
| FR-006 | P0 오늘 / 내일 배치 | D-02/03/06/08 | Q-009, Q-010 | 코드 추가: 공통 setPlan·오늘/내일 UI, U1 | 원격 통합·UI 검증 및 명령 저장·버튼·완료 독립 |
| FR-007 | P0 이번 주 / 다음 주 날짜 선택 | D-02/06/08/11 | Q-011, Q-012, Q-016 | 코드 추가: 이번/다음 주 7일 패널·뒤로 | 원격 통합·UI 검증 및 패널·같은 작업 저장·뒤로 |
| FR-008 | P0 주만 지정 | D-02/03/06/09 | Q-013, Q-014 | 코드 추가: week-only·검토 유예 명령, U1/U2 | 원격 통합·UI 검증 및 reviewNotBefore 저장·재등장 |
| FR-009 | P0 기타 날짜 선택 | D-05/06/08 | Q-015, Q-043 | 코드 추가: custom day/week/park·고정 widget deep link | 원격 통합·UI 검증 및 안전 라우트·달력·취소 |
| FR-010 | P0 재등장 | D-02/03/09 | Q-017 | 코드 추가: durable ack·미래/closed 후보 제외 | 원격 통합·UI 검증 및 durable ack·세션과 실제 재등장 |
| FR-011 | P0 중간 종료 | D-03/06/09 | Q-019 | 코드 추가: 부분 close 저장·요약·미검토 보존 | 원격 통합·UI 검증 및 close 저장·요약·미검토 보존 |
| FR-012 | P0 오늘 목록 | D-02/03/06/08 | Q-018 | 코드 추가: 실제 Today projection·마감 분리 | 원격 통합·UI 검증 및 영속 조회·오늘 UI |
| FR-013 | P0 완료와 다시 배치 | D-03/06/11 | Q-032, Q-033 | 코드 추가: 완료/다시 열기·명시 배치·이력 | 원격 통합·UI 검증 및 상태 명령·다시 열기/배치 |
| FR-014 | P0 실제 마감 | D-02/03/06/12 | Q-025, Q-026, Q-027, Q-028 | 코드 추가: deadline 그룹·task/head/target 확인·알림 | 원격 통합·UI 검증 및 deadline 그룹·오래된 확인 거부·알림 |
| FR-015 | P0 실행 취소 | D-03/05/09/10 | Q-029, Q-030, Q-031, Q-087 | 코드 추가: 보상 Operation·조건부/묶음 Undo | 원격 통합·UI 검증 및 보상 기록·버전·오프라인 병합 |
| FR-016 | P0 위젯 | D-05/07/08 | Q-035, Q-036, Q-037, Q-041, Q-047 | 코드 추가: WidgetTimeline·고정 card/token·5목적지 | 원격 통합·UI 검증 및 실제 timeline/token·G-WIDGET |
| FR-017 | P0 App Intents | D-03/05/07 | Q-006, Q-044 | 코드 추가: AI01~13·Entity/Query·AppShortcuts | 원격 통합·UI 검증 및 생산 서비스 adapter·Query·metadata·실제 Siri |
| FR-018 | P0 네이티브 멀티디바이스 | D-01/08/10/11/14 | Q-046, Q-079, Q-086 | 코드 추가: iPhone tabs·iPad/Mac sidebar·네이티브 확장 | 원격 통합·UI 검증 및 독립 Mac·적응형 iPad·표면별 QA |
| FR-019 | P0 로컬 우선 저장 | D-04/06/10 | Q-049, Q-050 | 코드 추가: Core Data SQLite·process gate·로컬 원본 우선 | 원격 통합·UI 검증 및 실제 저장소·네트워크 독립 |
| FR-020 | P0 iCloud 동기화 | D-03/04/05/10 | Q-053, Q-055, Q-056, Q-057, Q-058, Q-059, Q-060, Q-061, Q-062, Q-087 | 코드 추가: opt-in private CloudKit·계정별 store·merge consent | 원격 통합·UI 검증 및 실제 미러링·계정·충돌·G-SYNC |
| FR-021 | P0 캘린더 맥락 | D-12 | Q-065, Q-066, Q-067, Q-068 | 코드 추가: opt-in EventKit 읽기·권한/철회 cache | 원격 통합·UI 검증 및 실제 EventKit 권한·읽기 adapter |
| FR-022 | P0 정리 / 마감 알림 | D-09/12 | Q-069, Q-070, Q-071, Q-072, Q-073 | 코드 추가: 28일/48개 planner·실제 UN 예약/취소 | 원격 통합·UI 검증 및 실제 예약·취소·기기별 선택 |
| FR-023 | P0 날짜와 시간대 | D-02/03/05/12 | Q-039, Q-074 | 코드 추가: 저장 정책·세션 context·명시 설정 변경 | 원격 통합·UI 검증 및 설정 명령·세션 무효화·알림 재예약 |
| FR-024 | P0 휴지통 / 보관 | D-03/06/13 | Q-024, Q-034, Q-084 | 코드 추가: 휴지통/보관/restore·기기 삭제 | 원격 통합·UI 검증 및 휴지통/복구·검색·전체 삭제 게이트 |
| FR-025 | P0 접근성과 개인정보 | D-06/07/08/13/14/16 | Q-045, Q-075, Q-076, Q-077, Q-082 | 코드 추가: SwiftPieces 한국어·Reduce Motion·외부 제목 숨김·파일 보호 | 원격 통합·UI 검증 및 실제 접근성·잠금·로그/노출 |
| FR-026 | P0 내보내기 / 복원 | D-03/04/13 | Q-054, Q-081 | 코드 추가: immutable 원본 export/import·복원 확인·중단 회복 | 원격 통합·UI 검증 및 전체 원본 export/import·미리보기·격리 |
| FR-027 | P1 다중 선택 배치 | D-03/09/11 | Q-080 | 코드 추가: 20개 전체 검증·단일 Operation·batch Undo | 원격 통합·UI 검증 및 20개 전체 검증·한 기록·Undo |
| FR-028 | P1 Mac 빠른 조작 | D-09/11/14 | Q-078 | 코드 추가: Mac menu bar 입력·키보드/검색/Undo | 원격 통합·UI 검증 및 메뉴 막대·키보드/포커스·단축어 |
| FR-029 | P1 시스템 확장 표면 | D-07/15 | Q-048 | 코드 추가: iOS Control·Spotlight opt-in·parameterSummary | 원격 통합·UI 검증 및 SDK 표면·parameterSummary·인덱스·fallback |
| FR-030 | P0 오류와 오래된 화면 | D-03/04/05/06/10/13 | Q-038, Q-040, Q-042, Q-051, Q-052, Q-063, Q-064, Q-083, Q-085 | 코드 추가: original-first receipt·재구축·typed 오류·schema 격리 | 원격 통합·UI 검증 및 저장·원본 복구·오류 UI·안전 링크·schema |

## 3. NFR-001~012

단위 함수의 성질과 실제 저장/시스템 성능을 구별한다. 기준 데이터와 p95 수치는 목표이며 아직 측정되지 않았다. NFR별 근거는 아래 QA 전체와 추가 측정을 함께 포함한다.

| NFR | 요구 | 단계·관련 게이트 | QA/추가 검증 | 현재 상태 |
|---|---|---|---|---|
| NFR-001 | 데이터 안전·잘못된 작업 변경 0건 | D-03/04/05/08/10/13, 모든 안전 게이트 | Q-035~043/049/051~064/080/084/087; 원본/투영/receipt/snapshot 경계 crash | not_run |
| NFR-002 | 로컬 한 건 p95 500ms 목표 | D-04/05/14 | Q-086; 실기기 단건 표본·release/debug·store 크기·gate 대기 분리 | not_run |
| NFR-003 | 지연·두 위젯·날짜 경계에서 대상 고정 | D-05/08, G-WIDGET | Q-035~041/046; 다른 목적지 연속 탭·두 독립 프로세스 | not_run |
| NFR-004 | 일반 실기기 동작 후 표시 p95 2초 목표 | D-08/14, G-WIDGET | Q-041/046/086; 탭→save/snapshot/OS reload→새 카드 분리 | not_run |
| NFR-005 | 오프라인 핵심 흐름 | D-04/06/07/10 | Q-005/049/050/062; 네트워크 없고 iCloud 미로그인인 실제 저장·재시작 | not_run |
| NFR-006 | 동일 변경 집합의 같은 투영 | D-03/10, G-SYNC | Q-053/055~060/087; 순열·중복·기기 시계 차이·pending 부모 | not_run |
| NFR-007 | 민감 원문 분석 로그 제외 | D-07/12/13/16 | Q-045/082/083; 오류·sync·share·export·로컬 계측·제목 숨김/노출 검사 | not_run |
| NFR-008 | 큰 글자·비제스처 대체 경로 | D-06/08/11/14, G-WIDGET/G-UX | Q-075~079; VoiceOver/VoiceControl·대비·Reduce Transparency·키보드 | not_run |
| NFR-009 | 무한 폴링·초 reload·가짜 background 없음 | D-08/12/14 | 날짜 경계 timeline·예약 범위/보충·백그라운드 자원/에너지 측정 | not_run |
| NFR-010 | Foundation 순수 도메인 테스트 가능 | D-02/03 | fixture 36개·불변식·명령/reducer property; UI/Apple framework 의존 방지 | U1~U5 및 V1 Domain 94개 통과; 전체 앱 수용과 구별 |
| NFR-011 | 원본 보존·재구축·migration 복구 | D-04/10/13 | Q-051~054/060/063/064/085; backup·token 무효·손상·미지원 payload 격리 | not_run |
| NFR-012 | 권고/마감/미정 상태 구분 | D-06/09/12/16, G-UX | Q-013/014/019/025~028/068~074; week≠Monday, plan≠deadline·알림/3분 보장 문구 검사 | not_run |

## 4. Q-001~087 개별 실행 책임

Q는 원본의 ID다. `A`는 Actions 단위/실제 영속·프로세스 통합, `UI`는 Actions의 Simulator/Mac UI, `SYS`는 실제 서명 기기의 Widget/Siri/잠금/권한/CloudKit, `USER`는 동의한 사용자 검증이다. 여러 경로가 적혀 있으면 자동 근거로 실제 표면의 요구를 대신하지 않는다. 전체 기대 결과는 원본 QA의 precondition/steps를 그대로 적용한다.

Q-048의 과거 최소 OS 문구는 확정된 최소 **OS 27**의 지원/availability와 플랫폼 차이 검증으로 연결한다. 이전 OS까지 지원한다고 범위를 바꾸지 않는다.

| QA | 상황·기대 결과 | 관련 FR | 단계 | 필요한 경로 | 현재 전체 결과·부분 단위 |
|---|---|---|---|---|---|
| Q-001 | 제목만 입력 — open + unassigned. Today 미포함 | FR-001 | D-03/04/06 | A/UI | not_run; U2 Today 판정만 부분, V5 Mac/iPad 부분 통과·iPhone passed 로그/집계 미완료 |
| Q-002 | 공백 제목 — 저장 거부, 입력 유지 | FR-001 | D-03/06 | A/UI | not_run |
| Q-003 | 길이 초과 — 자동 잘림 없이 안내 | FR-001 | D-03/06 | A/UI | not_run; V5 Mac/iPad ASCII 501자 부분 통과·iPhone passed 로그/집계 미완료, Unicode/500자 경계 미검사 |
| Q-004 | 여러 줄 붙여넣기 — 한 개 / 줄마다 선택 전 자동 3개 생성 금지 | FR-001 | D-06 | UI | not_run |
| Q-005 | 공유 텍스트와 URL — 원문 보존, 네트워크 없는 저장 | FR-002 | D-04/07/13 | A/UI/SYS | not_run |
| Q-006 | 앱 첫 실행 전 인텐트 — 로컬 저장소 초기화 후 작업 저장 | FR-017 | D-04/07 | A/SYS | not_run |
| Q-007 | 같은 제목 두 작업 — 서로 다른 작업 ID로 보존 | FR-001 | D-03/04/06 | A/UI | not_run |
| Q-008 | 미래 작업 검색 — 검색 가능하지만 정리 큐에는 미포함 | FR-003 | D-04/06/11 | A/UI | not_run; V5 Mac/iPad 내일 검색·Today 제외 부분 통과·iPhone failed 로그/집계 미완료, 다음 달/정리 큐 미검사 |
| Q-009 | 오늘 버튼 — plan만 오늘, 완료 안 됨 | FR-006 | D-02/03/06/08 | A/UI/SYS | not_run; U1 목적지만 부분, V5 Mac/iPad 부분 통과·iPhone passed 로그/집계 미완료 |
| Q-010 | 내일 버튼 — 10월 1일 day 저장 | FR-006 | D-02/03/06/08 | A/UI/SYS | not_run; U1 부분, V5 Mac/iPad 부분 통과·iPhone failed 로그/집계 미완료 |
| Q-011 | 이번 주 날짜 — 정확 날짜 저장, 시간 블록 없음 | FR-007 | D-02/06/08 | A/UI/SYS | not_run; U1 범위만 부분 |
| Q-012 | 다음 주 날짜 — 10월 6일 day 저장 | FR-007 | D-02/06/08 | A/UI/SYS | not_run; U1 범위만 부분 |
| Q-013 | 현재 주 요일 나중 — week 상태, 같은 날 다시 질문 안 함 | FR-008 | D-02/03/06/09 | A/UI | not_run; U2 판정만 부분 |
| Q-014 | 다음 주 요일 나중 — 그 주 월요일 검토 후보, Today 아님 | FR-008 | D-02/03/06/09 | A/UI | not_run; U1/U2 부분 |
| Q-015 | 기타 날짜 — 같은 taskID에 정확 날짜 저장 | FR-009 | D-05/06/08 | A/UI/SYS | not_run |
| Q-016 | 패널 뒤로 — plan 변경 0건 | FR-007 | D-05/06/08 | A/UI/SYS | not_run; V5 Mac/iPad 취소 뒤 plan 표시 부분 통과·iPhone passed 로그/집계 미완료, mutation 0건 미검사 |
| Q-017 | 미래 날짜 재노출 — 후보에서 제외 | FR-010 | D-02/03/09 | A/UI | not_run; U2 부분 |
| Q-018 | 과거 미완료 — 검토 후보, Today 아님 | FR-012 | D-02/03/06 | A/UI | not_run; U2 부분 |
| Q-019 | 부분 정리 종료 — 미검토 4개 보존, 자동 Today 금지 | FR-011 | D-03/06/09 | A/UI/USER | not_run; V5 Mac/iPad 2개 중 1개 결정 부분 통과·iPhone passed 로그/집계 미완료, 원본 10개/6개/4개 미검사 |
| Q-020 | 주간 일간 중복 — 주간 하나, 일간 중복 큐 / 알림 없음 | FR-005 | D-03/09/12 | A/UI/SYS | not_run |
| Q-021 | 새 입력 중간 유입 — 현재 카드 앞에 삽입하지 않음 | FR-004 | D-05/06/09 | A/UI | not_run |
| Q-022 | 같은 날 재실행 — Today 기본, 자동 재정리 안 함 | FR-004 | D-03/06/09 | A/UI | not_run; U2 closed 판정만 부분 |
| Q-023 | 명시적 다시 정리 — 오늘 항목 재검토 가능 | FR-004 | D-02/03/06/09 | A/UI/USER | not_run; U2 부분 |
| Q-024 | 오래된 보관 항목 — 자동 큐 제외, 검색 가능 | FR-024 | D-02/03/06/13 | A/UI | not_run; U2 부분 |
| Q-025 | 계획과 마감 분리 — deadline 원본 동일 | FR-014 | D-03/06/12 | A/UI | not_run |
| Q-026 | 마감 이후 날짜 — 확인 전 변경 없음 | FR-014 | D-02/03/06/08 | A/UI/SYS | not_run; U3 부분 |
| Q-027 | 마감 확인 중 변경 — 오래된 확인 token 거부 | FR-014 | D-02/03/06/10 | A/UI/SYS | not_run; U3 바인딩만 부분 |
| Q-028 | 주 안의 마감 — 화요일 마감 표시, 월요일 자동 배치 안 함 | FR-014 | D-02/03/06/09 | A/UI/USER | not_run; U3 부분 |
| Q-029 | 단순 Undo — 이전 plan과 reviewNotBefore 복원 | FR-015 | D-03/05/09 | A/UI | not_run; V5와 f091e83에서 Mac/iPhone/iPad unassigned 복원 부분 통과, reviewNotBefore 미검사 |
| Q-030 | 제목 수정 후 Undo — plan만 복원, 새 제목 유지 | FR-015 | D-03/09 | A/UI | not_run |
| Q-031 | 후속 plan 변경 후 Undo — 영향 plan 버전 불일치로 과거 날짜 덮어쓰기 거부 | FR-015 | D-03/09/10 | A/UI/SYS | not_run |
| Q-032 | 완료 처리 — status 완료, plan / deadline 이력 유지 | FR-013 | D-03/06/12 | A/UI | not_run; V5 Mac/iPad 상태·plan 표시 부분 통과·iPhone failed 로그/집계 미완료, deadline/history 미검사 |
| Q-033 | 완료 취소 — 과거 계획 유지, Today 자동 이월 안 함 | FR-013 | D-02/03/06 | A/UI | not_run; U2 판정만 부분 |
| Q-034 | 휴지통 복구 — 기존 계획 유지, stale 복구는 거부 | FR-024 | D-03/06/13 | A/UI | not_run |
| Q-035 | 반복 탭 — 한 결정, 한 작업 변경 | FR-016 | D-03/05/08 | A/SYS | not_run |
| Q-036 | 상이한 빠른 탭 — 먼저 커밋한 결과 유지, 다음 작업 안 바뀜 | FR-016 | D-03/05/08 | A/SYS | not_run |
| Q-037 | 동일 설정 위젯 2개 — 한 번 적용, 공통 receipt | FR-016 | D-04/05/08 | A/SYS | not_run |
| Q-038 | 오래된 다른 기기 완료 — stale / 완료 안내 | FR-030 | D-03/05/08/10 | A/SYS | not_run |
| Q-039 | 자정 후 상대 버튼 — staleContext, 자동 재해석 금지 | FR-023 | D-02/05/08 | A/SYS | not_run; U4 부분 |
| Q-040 | 자정 후 중복 재시도 — 기존 receipt 반환, 새 변경 없음 | FR-030 | D-02/04/05/08 | A/SYS | not_run; U4 순서만 부분 |
| Q-041 | 주 패널 재로드 — 같은 card / decisionToken 유지 | FR-016 | D-05/08 | A/SYS | not_run |
| Q-042 | 위젯 저장 실패 — 기존 카드 유지, 성공 피드백 금지 | FR-030 | D-04/05/08 | A/SYS | not_run |
| Q-043 | 기타 앱 진입 취소 — 원래 plan 유지, 원래 작업 맥락 보존 | FR-009 | D-05/06/08 | A/UI/SYS | not_run |
| Q-044 | Siri 동명 작업 — 대상 선택, 임의 첫 항목 수정 금지 | FR-017 | D-07 | A/SYS | not_run |
| Q-045 | 잠금 상태 — 인증 정책과 파일 보호 일치 | FR-025 | D-07/08/13 | SYS | not_run |
| Q-046 | Mac 원격 iPhone 위젯 — 왕복 지연 표시, 대상 고정 | FR-018 | D-08/11 | SYS | not_run |
| Q-047 | 정리 종료 모드 — Today 목록으로 전환 | FR-016 | D-03/07/08/09 | A/SYS | not_run |
| Q-048 | 구형 OS 최신 API — 비지원 기능 숨김, 핵심 동작 가능 | FR-029 | D-01/07/15 | A/UI/SYS | not_run |
| Q-049 | 오프라인 핵심 흐름 — 모두 로컬 성공 | FR-019 | D-04/06/07/10 | A/UI/SYS | not_run |
| Q-050 | iCloud 미로그인 — 로컬 전용, 강제 로그인 없음 | FR-019 | D-04/06/10 | A/UI/SYS | not_run |
| Q-051 | 원본 저장 전 crash — 성공 표시 없음, 재시도 한 번 생성 | FR-030 | D-04/05 | A | not_run |
| Q-052 | 원본 저장 후 crash — 재생으로 복구, 중복 생성 없음 | FR-030 | D-04/05 | A | not_run |
| Q-053 | 동일 event 재수신 — 논리 한 번으로 계산 | FR-020 | D-03/04/10 | A/SYS | not_run |
| Q-054 | 같은 ID 다른 payload — 격리, 조용한 덮어쓰기 금지 | FR-026 | D-03/04/10/13 | A/SYS | not_run |
| Q-055 | 제목과 날짜 동시 수정 — 둘 다 보존 | FR-020 | D-03/10 | A/SYS | not_run |
| Q-056 | 서로 다른 날짜 동시 수정 — 동일 기록 집합에서 수렴, 충돌 이력 | FR-020 | D-03/10 | A/SYS | not_run |
| Q-057 | 완료와 날짜 동시 수정 — 완료 유지 | FR-020 | D-03/10 | A/SYS | not_run |
| Q-058 | 삭제와 stale reopen — 삭제 우선, 부활 안 함 | FR-020 | D-03/10/13 | A/SYS | not_run |
| Q-059 | 기기 시계 차이 — 동일 event 집합의 결정론 유지 | FR-020 | D-03/10 | A/SYS | not_run |
| Q-060 | 부모 기록 지연 — pending 보존, 부모 도착 후 적용 | FR-020 | D-03/04/10 | A/SYS | not_run |
| Q-061 | 계정 A에서 B 변경 — A 데이터가 B로 자동 업로드 안 됨 | FR-020 | D-10/13 | A/SYS | not_run |
| Q-062 | CloudKit 용량 오류 — 로컬 유지, 동기화 대기 안내 | FR-020 | D-10 | A/SYS | not_run |
| Q-063 | 캐시 손상 — 원본 보존, 재구축 | FR-030 | D-04/05/08 | A/SYS | not_run |
| Q-064 | 마이그레이션 실패 — 원본 백업 유지, 삭제 초기화 금지 | FR-030 | D-04/10 | A | not_run |
| Q-065 | 캘린더 거절 — 핵심 날짜 배치 가능 | FR-021 | D-12 | A/UI/SYS | not_run |
| Q-066 | 캘린더 철회 — 캐시 제거, 읽기 중단 | FR-021 | D-12 | A/UI/SYS | not_run |
| Q-067 | 캘린더 쓰기 방지 — 외부 일정 수정 호출 0건 | FR-021 | D-12 | A/UI/SYS | not_run |
| Q-068 | 종일과 겹친 일정 — 단순 합산 가용시간 단정 안 함 | FR-021 | D-12 | A/UI/SYS | not_run |
| Q-069 | 정리 알림 중복 — 당일 review request 하나 | FR-022 | D-09/12 | A/SYS | not_run |
| Q-070 | 정리 먼저 완료 — 당일 pending request 취소 | FR-022 | D-09/12 | A/SYS | not_run |
| Q-071 | 마감 알림 유지 — 원래 deadline 알림 유지 | FR-022 | D-03/12 | A/SYS | not_run |
| Q-072 | 완료 후 알림 — 관련 pending / delivered 정리 | FR-022 | D-03/12 | A/SYS | not_run |
| Q-073 | 예약 범위 소진 — 무기한 알림 보장 안 함, 재진입 시 보충 | FR-022 | D-12 | A/SYS | not_run |
| Q-074 | 계획 시간대 변경 — 세션 무효화, 알림 재예약, 날짜 문자열 유지 | FR-023 | D-02/03/05/12 | A/UI/SYS | not_run; U5 부분 |
| Q-075 | VoiceOver 정리 — 요일 / 날짜 / 역할 명확, 새 카드 초점 | FR-025 | D-06/08/11/14 | SYS/USER | not_run |
| Q-076 | 가장 큰 글자 — 핵심 행동 유실 없음, 앱 대체 경로 | FR-025 | D-06/08/11/14 | UI/SYS | not_run |
| Q-077 | Reduce Motion — 상태 변화 의미 유지 | FR-025 | D-06/08/14 | UI/SYS | not_run |
| Q-078 | Mac 키보드 — 드래그 필수 아님 | FR-028 | D-09/11/14 | UI/SYS | not_run |
| Q-079 | iPad 좁은 창 — 저장과 날짜 선택 접근 가능 | FR-018 | D-11/14 | UI/SYS | not_run |
| Q-080 | 여러 개 날짜 배치 — 전체 거부, 부분 성공 위장 금지 | FR-027 | D-03/09/11 | A/UI | not_run |
| Q-081 | export / import 왕복 — 상태 같음, 중복 작업 없음 | FR-026 | D-03/04/13 | A/UI | not_run |
| Q-082 | 민감 로그 점검 — 로그에 원문 없음 | FR-025 | D-13/14/16 | A/SYS | not_run |
| Q-083 | 외부 딥링크 공격 — 변경 없이 안전 거부 | FR-030 | D-05/06/07/13 | A/UI | not_run |
| Q-084 | 전체 삭제 후 offline 복귀 — 구세대 부활 / 재업로드 여부 검증, 실패 시 출시 차단 | FR-024 | D-10/13 | SYS | not_run |
| Q-085 | 미지원 payload — 원본 보존, 덮어쓰기 제한 | FR-030 | D-03/04/10/13 | A/SYS | not_run |
| Q-086 | 성능 기준 데이터 — p95 측정과 미달 분리, 성공 조작 금지 | FR-018 | D-04/08/11/14 | A/SYS | not_run |
| Q-087 | 오프라인 Undo와 미수신 변경 — 수신 전 전역 최신 상태를 보장하지 않음. 병합 후 일반 수정 우선, 양쪽 이력과 충돌 안내 유지 | FR-015, FR-020 | D-03/09/10 | A/SYS | not_run |

## 5. 게이트·완료 추적

| 게이트 | 연결 QA와 추가 과제 | 필요 증거 | 현재 결과 |
|---|---|---|---|
| G-WIDGET | Q-015/016/035~043/046/047/075/076/086; 중형·대형 30개 연속·두 위젯·앱 종료·자정 | 실제 기기 taskID/receipt 결과·저장/표시 p95·뒤로/기타/Undo·범위 차이 기록 | not_run |
| G-SYNC | Q-049~064/087; offline 2기기·extension·Crash·계정·중복 | 실제 동일 원본 집합·투영 비교·충돌 이력·계정 분리·데이터 유실 없음 | not_run |
| G-DELETE | Q-061/081/084/085; offline 복귀·재설치·이전 export | 실제 purge/epoch authority·writer/importer 차단·자동 부활 없음·명시 복원 구분 | not_run |
| G-UX | Q-013/014/019/023/025~028/075 및 H-01~07 | 동의한 사용자 과제·인터뷰·복귀·Today 의도·주만 의미·재등장 신뢰·능동 시간 | not_run |

범위는 FR 30개, NFR 12개, Q 87개, D 16단계, 게이트 4개다. 원본 QA ID를 삭제하거나 새 테스트를 기존 수용 결과로 가장하지 않는다. D별 선행 조건·산출물·외부 결정·출시 차단 규칙은 [전체 구현 계획](IMPLEMENTATION_PLAN.md)에 있다. 다음 구현마다 해당 FR/Q의 production/test 경로와 run 증거를 추가하며, 필요 경로의 결과가 모두 있어야 전체 `pass`로 바꾼다.
