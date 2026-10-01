# SwiftPieces 적용 기록

- 원본: https://github.com/Saivion/SwiftPieces
- 고정 커밋: `15e4a68ce09a58f7c93a8043f88fca9ea224af75`
- 저작권: Copyright (c) 2026 Saivion Hayes
- 라이선스: MIT + Commons Clause. 원문은 `LICENSE.swiftpieces`에 보존한다. 컴포넌트 자체의 판매·재라이선스·재배포와 앱 내부 사용의 조건은 다르다.

| 도입 파일 | 원본 경로 | 변경 |
|---|---|---|
| TaskRow.swift | registry/swift/lists/TaskRow.swift | 데모 제거, MainActor 명시, UIKit 색상을 AppKit/UIKit 공통 동적 색상으로 교체, 한국어 접근성 문구, 제목 줄 수 제한 제거. 미러 목록에서는 투명 표면과 작은 체크 표시를 사용하고 행·스와이프 타일의 간격을 줄였다. 체크의 44pt 터치 영역과 모든 명령·접근성 행동은 유지하며 완료 배경 피드백의 강도만 낮췄다. Binding setter는 AppModel 명령 요청만 수행하고 원본 저장 성공 후 projection 값이 갱신되므로 낙관적 완료를 표시하지 않는다. |
| ExpandableText.swift | registry/swift/text/ExpandableText.swift | 데모 제거, MainActor 명시, Mac 동적 색상 대응, 한국어 확장·접기 문구. |
| StatusMorph.swift | registry/swift/feedback/StatusMorph.swift | 데모 제거, MainActor 명시, Mac 동적 색상 대응, 한국어 저장 문구. 원본 저장 성공과 화면 재구축 대기는 AppModel의 별도 상태로 표시한다. |

FormField와 TrackingTabs 원본도 검토했다. FormField는 UIKit 키보드·폰트 의존성과 입력 길이를 자동 자르는 동작이 있고, 미러는 긴 원문 입력을 유지하고 검증 오류를 보여야 하므로 시스템 TextField/TextEditor를 사용한다. TrackingTabs의 커스텀 페이지 이동은 iPhone 네이티브 탭 및 iPad/Mac 사이드바와 겹쳐 도입하지 않았다. 도입한 파일에는 Metal 의존성이 없다.

실제 VoiceOver, 큰 글자, Reduce Motion, Reduce Transparency 검증 결과는 플랫폼 QA에 별도로 기록한다. 원본 데모의 검증 결과를 미러의 검증 결과로 대체하지 않는다.
