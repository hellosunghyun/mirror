# SwiftPieces 적용 기록

- 원본: https://github.com/Saivion/SwiftPieces
- 고정 커밋: `15e4a68ce09a58f7c93a8043f88fca9ea224af75`
- 저작권: Copyright (c) 2026 Saivion Hayes
- 라이선스: MIT + Commons Clause. 원문은 `LICENSE.swiftpieces`에 보존한다. 컴포넌트 자체의 판매·재라이선스·재배포와 앱 내부 사용의 조건은 다르다.

| 도입 파일 | 원본 경로 | 변경 |
|---|---|---|
| TaskRow.swift | registry/swift/lists/TaskRow.swift | 데모 제거, MainActor 명시, UIKit 색상을 AppKit/UIKit 공통 동적 색상으로 교체, 한국어 접근성 문구, 목록 제목 3줄 미리 보기와 전체 원문·접근성 이름·상세 보존. 미러 목록에서는 투명 표면과 작은 체크 표시를 사용하고 행·스와이프 타일의 간격을 줄였다. 체크의 44pt 터치 영역과 모든 명령·접근성 행동은 유지하며 완료 배경 피드백의 강도만 낮췄다. Binding setter는 AppModel 명령 요청만 수행하고 원본 저장 성공 후 projection 값이 갱신되므로 낙관적 완료를 표시하지 않는다. 호출자가 미루기 의미에 맞는 snoozeLabel을 지정하면 타일·상태·접근성 문구에 함께 적용되며, 기본 보관 문구와 명령·제스처는 유지한다. |
| ExpandableText.swift | registry/swift/text/ExpandableText.swift | 데모 제거, MainActor 명시, Mac 동적 색상 대응, 한국어 확장·접기 문구. 레이아웃·잘림·접근성 액션을 적용한 표시 paragraph Text chain에만 선택적 paragraphAccessibilityIdentifier와 paragraphAccessibilityFocus를 제공하며 측정 복사본과 더 보기·접기 Button의 식별자는 보존한다. |
| StatusMorph.swift | registry/swift/feedback/StatusMorph.swift | 데모 제거, MainActor 명시, Mac 동적 색상 대응, 한국어 저장 문구. 원본 저장 성공과 화면 재구축 대기는 AppModel의 별도 상태로 표시한다. |

FormField와 TrackingTabs 원본도 검토했다. FormField는 UIKit 키보드·폰트 의존성과 입력 길이를 자동 자르는 동작이 있고, 미러는 긴 원문 입력을 유지하고 검증 오류를 보여야 하므로 시스템 TextField/TextEditor를 사용한다. TrackingTabs의 커스텀 페이지 이동은 iPhone 네이티브 탭 및 iPad/Mac 사이드바와 겹쳐 도입하지 않았다. 도입한 파일에는 Metal 의존성이 없다.

실제 VoiceOver, 큰 글자, Reduce Motion, Reduce Transparency 검증 결과는 플랫폼 QA에 별도로 기록한다. 원본 데모의 검증 결과를 미러의 검증 결과로 대체하지 않는다.

2026-10-04 후속 변경: ExpandableText의 기본 더 보기·접기 색상도 MirrorPalette.accent를 사용한다. 별도 스타일을 지정하지 않은 정리·상세 메모가 데모의 빨간색을 쓰던 불일치를 정리하며, 호출자의 명시적 색상·오류 표시·측정·접힘·44pt·접근성·모션은 유지한다. 실제 새 화면 확인은 다음 Actions 캡처에서 진행한다.

2026-10-03 후속 변경: TaskRow의 제목·메타 영역을 실제 plain Button으로 바꾸고 완료 체크 Button과 형제로 유지했다. 목록 제목은 3줄 미리 보기로 표시하며 원문·전체 접근성 이름·상세의 전체 제목은 유지한다. 스와이프가 열려 있을 때 첫 활성화는 닫기만 수행하는 기존 동작을 보존하며 체크의 한국어 접근성 이름을 명시했다. ExpandableText의 실제 더 보기/접기 Button을 접근성에서 숨기지 않고 한국어 이름·식별자를 제공한다. 측정용 숨김 복사본·줄 수·접힘·Reduce Motion·원저작권과 라이선스는 유지한다. 새 원격 접근성/큰 글자 검증은 실행과 원본별로 기록한다.

상세 제목도 기존 ExpandableText의 실제 폭·글자 크기 측정을 재사용해 기본 3줄 미리 보기를 제공한다. String·AttributedString 초기화의 새 식별자 기본값은 nil이며 기존 메모 호출의 기본 동작은 유지한다. 상세는 레이아웃·잘림·접근성 액션을 적용한 표시 paragraph Text chain에만 detail.contentTitle을 지정하고 제목 원문·전체 접근성 내용·선택·편집은 보존한다. 기존 더 보기·접기 Button과 접근성 동작은 별개로 유지하고, 제목 본문 탭에 의한 펼침은 끄며 새 작업 선택 때 접힘 상태를 초기화한다. 측정 복사본·임계 높이·라이선스는 변경하지 않았다. 새 원격 SDK·실제 접근성·화면 배치 검증은 아직 수행하지 않았다.

정리 카드 제목도 같은 측정 기반 3줄 미리 보기와 명시적 더 보기·접기를 사용한다. 원문·review.card 식별자를 유지하며 선택적 AccessibilityFocusState<Bool>.Binding을 레이아웃이 끝난 실제 표시 paragraph에 직접 적용한다. 접근성 포커스를 부모 Group이나 측정 복사본에 지정하지 않는다. 새 작업에서는 taskID로 접힘 상태를 초기화하고 본문 탭 펼침은 끈다. String·AttributedString 초기화의 포커스 기본값은 nil이고 기존 상세·메모 표시 체인은 유지한다. SwiftUI SDK의 해당 포커스 API와 실제 VoiceOver 이동·원문·펼침 버튼 동작은 원격 검증 대상으로 남는다.

후속 보완: 실제 상세 제목 펼침 검사에서 `expandableText.expand` 누락을 확인했다. 실제 더 보기·접기 Button을 식별자와 포커스를 가진 표시 paragraph의 아래 형제로 분리하고 label의 최소44×44pt 레이아웃과 직사각형 터치 영역을 제공한다. 문단 안의 마지막 줄 fade는 장식만 남기고 hit testing과 접근성에서 제외한다. 실제 잘림 조건·expanded/showsLess·원문 접근성·측정·링크·애니메이션·원저작권은 유지한다. 정확한 SDK 원인과 새 소스의 실제 해결 여부는 Actions 결과로 확인한다.
