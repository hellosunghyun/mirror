import XCTest
#if os(iOS)
import UIKit
#endif

/// 기존 여섯 기능 사례와 다른 bundle에서 실제 큰 글자·접근성·창 경계를 검사한다.
/// 매 launch는 앱의 기존 UI 테스트 모드로 새 실제 Core Data store를 연다.
final class MirrorAdaptiveUITests: XCTestCase {
    @MainActor private var screenshotSequence = 0
    @MainActor private var progressSequence = 0
    @MainActor private var diagnosticCase: DiagnosticCase?
    @MainActor private var diagnosticRequestSequence = 0
    @MainActor private var diagnosticRequestedElement: RequestedElement?
    @MainActor private var diagnosticRequestedObject: XCUIElement?
    @MainActor private var diagnosticProgressPhase: ProgressPhase?
    @MainActor private var captureFailureScreenshotRecorded = false
    @MainActor private var diagnosticAuditSequence = 0
    @MainActor private var diagnosticAuditIssueSequence = 0
    @MainActor private var dynamicTypeFixtureMode: DynamicTypeFixtureMode?
    @MainActor private var dynamicTypeFixtureScopes: Set<String> = []

    @MainActor
    func testMaximumTypeCaptureValidationAndRecovery() throws {
        beginCaseDiagnostics(.captureValidation)
        progress(.started)
        let app = try launchApp()
        progress(.launchComplete)
        defer { app.terminate() }
        progress(.captureOpenStarted)
        try tap("capture.open", requestedElement: .captureOpen, in: app)
        let title = try find("capture.title", requestedElement: .captureTitle, in: app)
        progress(.captureOpened)
        progress(.captureInputStarted)
        try replaceText(title, with: "큰 글자로 입력", in: app)
        progress(.captureInputComplete)
        try assertVisible(try button("capture.save", requestedElement: .captureSave, in: app), in: app, outsideKeyboard: true)
        progress(.recordStarted, step: 1)
        try record("max-capture", in: app)
        progress(.recordComplete, step: 1)
        progress(.auditStarted, step: 1)
        try audit(app)
        progress(.auditComplete, step: 1)

        let original = String(repeating: "x", count: 500) + "Z"
        progress(.overlongInputStarted)
        try replaceText(title, with: original, in: app)
        progress(.overlongInputComplete)
        XCTAssertEqual(title.value as? String, original)
        try tap("capture.save", requestedElement: .captureSave, in: app)
        progress(.validationSubmitted)
        let error = try find("state.error", requestedElement: .stateError, in: app)
        try waitForText("제목은 500자 이하로 입력해 주세요.", in: error)
        XCTAssertEqual(title.value as? String, original, "큰 글자에서도 501자 원문을 자르거나 지우지 않는다.")
        try assertVisible(error, in: app, outsideKeyboard: true)
        try assertVisible(try button("capture.save", requestedElement: .captureSave, in: app), in: app, outsideKeyboard: true)
        try assertVisible(try button("capture.close", requestedElement: .captureClose, in: app), in: app)
        progress(.validationVerified)
        progress(.recordStarted, step: 2)
        try record("max-validation", in: app)
        progress(.recordComplete, step: 2)

        // 정지사진의 접힌 카드 비침과 실제 접근 불가능을 구별한다.
        progress(.optionalInputsStarted)
        let more = try button("capture.more", requestedElement: .captureMoreButton, in: app)
        try reveal(more, in: app)
        try assertVisible(more, in: app, outsideKeyboard: true)
        performActivation(more)
        let note = try find("capture.note", requestedElement: .captureNote, in: app)
        try reveal(note, in: app)
        XCTAssertTrue(note.isHittable, "오류 뒤에도 선택 입력을 실제 스크롤로 열 수 있다.")
        try reveal(more, in: app)
        performActivation(more)
        try reveal(title, in: app)
        progress(.optionalInputsVerified)
        progress(.recoveryInputStarted)
        try replaceText(title, with: "오류 수정 뒤 저장", in: app)
        progress(.recoveryInputComplete)
        try tap("capture.save", requestedElement: .captureSave, in: app)
        try waitForText("보관함에 넣었어요.", in: find("capture.feedback", requestedElement: .captureFeedback, in: app))
        progress(.recoverySaved)
        try assertVisible(try find("capture.feedback", requestedElement: .captureFeedback, in: app), in: app, outsideKeyboard: true)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "state.error").firstMatch.exists)
        progress(.recordStarted, step: 3)
        try record("max-recovery", in: app)
        progress(.recordComplete, step: 3)
        try tap("capture.close", requestedElement: .captureClose, in: app)
        try gone("capture.title", in: app)
        try destination("library", requestedElement: .destinationLibrary, title: "보관함", in: app)
        let saved = try row("오류 수정 뒤 저장", in: app)
        XCTAssertTrue((saved.value as? String ?? "").contains("아직 정하지 않음"))
        progress(.storedRowVerified)
    }

    @MainActor
    func testMaximumTypeReviewAndWeekPicker() throws {
        beginCaseDiagnostics(.reviewWeek)
        progress(.started)
        let app = try launchApp()
        progress(.launchComplete)
        defer { app.terminate() }
        progress(.captureStarted)
        try capture("큰 글자 주간 선택", in: app)
        progress(.captureComplete)
        try tap("today.review", requestedElement: .todayReview, in: app)
        try waitForText("큰 글자 주간 선택", in: find("review.card", requestedElement: .reviewCard, in: app))
        progress(.reviewOpened)
        for (id, requestedElement) in [("review.today", RequestedElement.reviewToday), ("review.tomorrow", RequestedElement.reviewTomorrow), ("review.nextWeek", RequestedElement.reviewNextWeek)] {
            let choice = try button(id, requestedElement: requestedElement, in: app)
            try reveal(choice, in: app)
            try assertVisible(choice, in: app)
            try assertMobileTarget(choice)
        }
        progress(.reviewControlsVerified)
        progress(.recordStarted, step: 1)
        try record("max-review", in: app)
        progress(.recordComplete, step: 1)
        progress(.auditStarted, step: 1)
        try audit(app)
        progress(.auditComplete, step: 1)
        try tap("review.nextWeek", requestedElement: .reviewNextWeek, in: app)
        progress(.weekOpened)
        var column: (x: CGFloat, width: CGFloat)?
        for day in 5...11 {
            progress(.weekDayStarted, step: day)
            let id = String(format: "plan.day.2026-10-%02d", day)
            let date = try weekDate(id, in: app)
            try reveal(date, in: app)
            try assertVisible(date, in: app)
            try assertMobileTarget(date)
            XCTAssertTrue(date.isEnabled)
            // 각 스크롤 뒤 버튼과 실제 owner를 함께 관측한다. 이전 절대 frame은 재사용하지 않는다.
            let surface = try weekSurface(in: app)
            let bounds = surface.frame
            let frame = date.frame
            XCTAssertTrue(hasArea(bounds) && hasArea(frame) && bounds.contains(frame))
            let x = (frame.minX - bounds.minX) / bounds.width
            let width = frame.width / bounds.width
            if let column {
                XCTAssertEqual(x, column.x, accuracy: 1 / bounds.width, "7일 모두 같은 열의 왼쪽 경계를 사용한다.")
                XCTAssertEqual(width, column.width, accuracy: 1 / bounds.width, "7일 모두 같은 열의 폭을 사용한다.")
            } else { column = (x, width) }
            if day > 5 {
                let previous = app.buttons.matching(identifier: String(format: "plan.day.2026-10-%02d", day - 1))
                if previous.count == 1 {
                    let previousFrame = previous.firstMatch.frame
                    if hasArea(previousFrame) {
                        XCTAssertGreaterThanOrEqual(frame.minY, previousFrame.maxY, "같은 관측에서 연속 날짜 버튼이 수직으로 겹치지 않는다.")
                    }
                }
            }
            progress(.weekDayVerified, step: day)
        }
        progress(.recordStarted, step: 2)
        try record("max-week", in: app)
        progress(.recordComplete, step: 2)
        progress(.auditStarted, step: 2)
        try audit(app)
        progress(.auditComplete, step: 2)
        try tap("plan.day.2026-10-11", requestedElement: .planDay, in: app)
        try gone("plan.cancel", in: app)
        progress(.weekSelected)
        try tap("review.finish", requestedElement: .reviewFinish, in: app)
        try gone("review.finish", in: app)
        try destination("library", requestedElement: .destinationLibrary, title: "보관함", in: app)
        try replaceText(find("library.search", requestedElement: .librarySearch, in: app), with: "큰 글자 주간 선택", in: app)
        XCTAssertTrue((try row("큰 글자 주간 선택", in: app).value as? String ?? "").contains("10월 11일"))
        progress(.storedRowVerified)

        // 주간 배치로 정리를 닫은 뒤 들어온 항목도 화면의 주 정리 버튼으로 확인한다.
        progress(.newCaptureStarted)
        try capture("정리 완료 뒤 새 입력", in: app)
        progress(.newCaptureComplete)
        try destination("today", requestedElement: .destinationToday, title: "오늘", in: app)
        try tap("today.review", requestedElement: .todayReview, in: app)
        try waitForText("정리 완료 뒤 새 입력", in: find("review.card", requestedElement: .reviewCard, in: app))
        progress(.reviewResumeVerified)
        try tap("review.finish", requestedElement: .reviewFinish, in: app)
        try gone("review.finish", in: app)
        progress(.reviewResumeClosed)
    }

    @MainActor
    func testMaximumTypeSearchDetailCompletionAndUndo() throws {
        beginCaseDiagnostics(.searchDetailUndo)
        progress(.started)
        let app = try launchApp()
        progress(.launchComplete)
        defer { app.terminate() }
        let title = "큰 글자 검색과 내일"
        progress(.captureStarted)
        try capture(title, in: app)
        progress(.captureComplete)
        try destination("library", requestedElement: .destinationLibrary, title: "보관함", in: app)
        let saved = try row(title, in: app)
        let taskID = try XCTUnwrap(saved.identifier.components(separatedBy: "task.row.").last)
        XCTAssertNotNil(UUID(uuidString: taskID))
        progress(.postponeStarted)
        try tap("task.postpone.\(taskID)", requestedElement: .taskPostpone, in: app)
        let tomorrow = try button("plan.tomorrow", requestedElement: .planTomorrow, in: app)
        try reveal(tomorrow, in: app)
        try assertVisible(tomorrow, in: app)
        try assertMobileTarget(tomorrow)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "plan.calendar").firstMatch.exists)
        performActivation(tomorrow)
        try gone("plan.cancel", in: app)
        progress(.postponeComplete)
        try destination("today", requestedElement: .destinationToday, title: "오늘", in: app)
        XCTAssertFalse(rowQuery(title, in: app).firstMatch.exists, "내일 배치는 오늘 목록에 나타나지 않는다.")
        try destination("library", requestedElement: .destinationLibrary, title: "보관함", in: app)
        let search = try find("library.search", requestedElement: .librarySearch, in: app)
        progress(.searchInputStarted)
        try replaceText(search, with: title, in: app)
        progress(.searchInputComplete)
        let future = try row(title, in: app)
        XCTAssertTrue((future.value as? String ?? "").contains("10월 1일"))
        for (id, requestedElement) in [("capture.open", RequestedElement.captureOpen), ("settings.button", RequestedElement.settingsButton)] {
            try assertVisible(try button(id, requestedElement: requestedElement, in: app), in: app, outsideKeyboard: true)
        }
        progress(.searchVerified)
        progress(.recordStarted, step: 1)
        try record("max-search", in: app)
        progress(.recordComplete, step: 1)
        progress(.auditStarted, step: 1)
        try audit(app)
        progress(.auditComplete, step: 1)
        progress(.detailOpenStarted)
        search.typeText("\n")
        try reveal(future, in: app)
        try assertVisible(future, in: app)
        performActivation(future)
        try waitForText(title, in: find("detail.contentTitle", requestedElement: .detailContentTitle, in: app))
        XCTAssertTrue(text(try find("detail.plan", requestedElement: .detailPlan, in: app)).contains("10월 1일"))
        progress(.detailVerified)
        progress(.recordStarted, step: 2)
        try record("max-detail", in: app)
        progress(.recordComplete, step: 2)
        progress(.auditStarted, step: 2)
        try audit(app)
        progress(.auditComplete, step: 2)
        progress(.completionStarted)
        try tap("task.complete", requestedElement: .taskComplete, in: app)
        try waitForText("완료 취소 · 다시 열기", in: button("task.complete", requestedElement: .taskComplete, in: app))
        progress(.completionVerified)
        progress(.recordStarted, step: 3)
        try record("max-completion", in: app)
        progress(.recordComplete, step: 3)
        progress(.undoStarted)
        try tap("task.undo", requestedElement: .taskUndo, label: "직전 변경 되돌리기", in: app)
        try waitForText("완료", in: button("task.complete", requestedElement: .taskComplete, in: app))
        XCTAssertEqual(text(try find("detail.contentTitle", requestedElement: .detailContentTitle, in: app)), title)
        XCTAssertTrue(text(try find("detail.plan", requestedElement: .detailPlan, in: app)).contains("10월 1일"))
        progress(.undoVerified)
        progress(.recordStarted, step: 4)
        try record("max-undo", in: app)
        progress(.recordComplete, step: 4)
        progress(.auditStarted, step: 3)
        try audit(app)
        progress(.auditComplete, step: 3)
    }

    @MainActor
    func testMaximumTypePlannedCaptureKeepsUnassignedDefault() throws {
        beginCaseDiagnostics(.plannedCapture)
        progress(.started)
        let app = try launchApp()
        progress(.launchComplete)
        defer { app.terminate() }
        progress(.defaultCaptureStarted)
        let unassigned = "날짜 없는 큰 글자 입력"
        try tap("capture.open", requestedElement: .captureOpen, in: app)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "capture.planChoices").firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(identifier: "capture.planToday").firstMatch.exists)
        try replaceText(find("capture.title", requestedElement: .captureTitle, in: app), with: unassigned, in: app)
        try tap("capture.save", requestedElement: .captureSave, in: app)
        try waitForText("보관함에 넣었어요.", in: find("capture.feedback", requestedElement: .captureFeedback, in: app))
        try tap("capture.close", requestedElement: .captureClose, in: app)
        try gone("capture.title", in: app)
        try destination("library", requestedElement: .destinationLibrary, title: "보관함", in: app)
        XCTAssertTrue((try row(unassigned, in: app).value as? String ?? "").contains("아직 정하지 않음"))
        try destination("today", requestedElement: .destinationToday, title: "오늘", in: app)
        XCTAssertFalse(rowQuery(unassigned, in: app).firstMatch.exists)
        progress(.defaultCaptureComplete)

        progress(.plannedCaptureStarted)
        let planned = "오늘로 정한 큰 글자 입력"
        try tap("capture.open", requestedElement: .captureOpen, in: app)
        try replaceText(find("capture.title", requestedElement: .captureTitle, in: app), with: planned, in: app)
        try tap("capture.more", requestedElement: .captureMoreButton, in: app)
        let planChoices = try find("capture.planChoices", requestedElement: .capturePlanChoices, in: app)
        _ = try unique(planChoices.buttons.matching(identifier: "capture.planToday"), requestedElement: .capturePlanToday)
        try tap("capture.planToday", requestedElement: .capturePlanToday, in: app)
        let summary = try find("capture.planSummary", requestedElement: .capturePlanSummary, in: app)
        XCTAssertTrue(text(summary).contains("9월 30일"))
        XCTAssertEqual(text(try button("capture.save", requestedElement: .captureSave, in: app)), "날짜에 넣기")
        progress(.plannedCaptureReady)
        progress(.recordStarted, step: 1)
        try record("max-capture-plan", in: app)
        progress(.recordComplete, step: 1)
        progress(.auditStarted, step: 1)
        try audit(app)
        progress(.auditComplete, step: 1)
        try tap("capture.save", requestedElement: .captureSave, in: app)
        try waitForText("9월 30일 수요일에 넣었어요.", in: find("capture.feedback", requestedElement: .captureFeedback, in: app))
        progress(.plannedCaptureSaved)
        try assertVisible(try find("capture.feedback", requestedElement: .captureFeedback, in: app), in: app, outsideKeyboard: true)
        try tap("capture.close", requestedElement: .captureClose, in: app)
        try gone("capture.title", in: app)
        let saved = try row(planned, in: app)
        XCTAssertTrue((saved.value as? String ?? "").contains("9월 30일"))
        XCTAssertTrue((saved.value as? String ?? "").contains("미완료"), "날짜를 정한 입력은 완료가 아니다.")
        XCTAssertFalse(rowQuery(unassigned, in: app).firstMatch.exists)
        progress(.storedRowVerified)
        progress(.recordStarted, step: 2)
        try record("max-planned-today", in: app)
        progress(.recordComplete, step: 2)
    }

    #if os(macOS)
    @MainActor
    func testNarrowMacWindowCaptureAndRequestedDetail() throws {
        beginCaseDiagnostics(.narrowMac)
        progress(.started)
        let app = try launchApp(recordConfiguration: false)
        progress(.launchComplete)
        defer { app.terminate() }
        XCTAssertEqual(app.windows.count, 1)
        let window = app.windows.firstMatch
        let before = window.frame
        XCTAssertTrue(hasArea(before))
        XCTAssertGreaterThan(before.width, 800, "실제 좁히기 전의 창은 목표 폭보다 넓어야 한다.")
        // 둥근 모서리 밖을 피하고 시스템 창의 두 가장자리를 직접 drag한다.
        progress(.windowResizeStarted)
        let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -2, dy: 0))
        let widthDestination = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 780, dy: before.height / 2))
        rightEdge.click(forDuration: 0.1, thenDragTo: widthDestination)
        let widthAdjustedFrame = window.frame
        let bottomEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: -2))
        let heightDestination = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: widthAdjustedFrame.width / 2, dy: 600))
        bottomEdge.click(forDuration: 0.1, thenDragTo: heightDestination)
        let resizeObservations = ResizeObservations()
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = window.frame
            resizeObservations.record(frame)
            return Self.hasArea(frame) && frame.width >= 760 && frame.width <= 800
                && frame.height >= 520 && frame.height <= 640 && frame.width < before.width
        }, object: window)
        let resizeResult = XCTWaiter.wait(for: [resized], timeout: 15)
        let resizeSnapshot = resizeObservations.snapshot()
        resizeMeasurement(method: #function, before: before, observed: resizeSnapshot.frame,
                          samples: resizeSnapshot.samples, result: resizeResult)
        XCTAssertEqual(resizeResult, .completed,
                       "현재 화면의 실제 창이 지원하는 좁은 폭과 높이로 줄어야 한다.")
        try configuration(in: app, viewport: "narrow")
        progress(.windowResizeVerified)
        for (id, requestedElement) in [("capture.open", RequestedElement.captureOpen), ("settings.button", RequestedElement.settingsButton), ("today.review", RequestedElement.todayReview)] {
            try assertVisible(try button(id, requestedElement: requestedElement, in: app), in: app)
        }
        progress(.recordStarted, step: 1)
        try record("narrow-main", in: app)
        progress(.recordComplete, step: 1)
        progress(.auditStarted, step: 1)
        try audit(app)
        progress(.auditComplete, step: 1)
        progress(.captureStarted)
        try capture("좁은 창에서 저장", in: app)
        progress(.captureComplete)
        try destination("library", requestedElement: .destinationLibrary, title: "보관함", in: app)
        let saved = try row("좁은 창에서 저장", in: app)
        try reveal(saved, in: app)
        progress(.detailOpenStarted)
        performActivation(saved)
        try waitForText("좁은 창에서 저장", in: find("detail.contentTitle", requestedElement: .detailContentTitle, in: app))
        for (id, requestedElement) in [("detail.close", RequestedElement.detailClose), ("detail.postponeTomorrow", RequestedElement.detailPostponeTomorrow), ("task.complete", RequestedElement.taskComplete)] {
            let control = try button(id, requestedElement: requestedElement, in: app)
            try reveal(control, in: app)
            try assertVisible(control, in: app)
        }
        XCTAssertTrue(window.frame.width <= 900, "요청 상세가 좁은 창을 화면 밖으로 확장하지 않는다.")
        progress(.detailVerified)
        progress(.recordStarted, step: 2)
        try record("narrow-detail", in: app)
        progress(.recordComplete, step: 2)
        progress(.auditStarted, step: 2)
        try audit(app)
        progress(.auditComplete, step: 2)
    }
    #endif

    @MainActor
    private func launchApp(recordConfiguration: Bool = true, method: String = #function) throws -> XCUIApplication {
        continueAfterFailure = false
        screenshotSequence = 0
        dynamicTypeFixtureMode = try requestedDynamicTypeFixture()
        dynamicTypeFixtureScopes = []
        let app = XCUIApplication()
        app.launchEnvironment["MIRROR_UI_TESTING"] = "1"
        app.launchEnvironment["MIRROR_TEST_DATE"] = "2026-09-30T03:00:00Z"
        app.launchEnvironment["MIRROR_UI_DYNAMIC_TYPE"] = "accessibility5"
        app.launchEnvironment["MIRROR_UI_DYNAMIC_TYPE_FIXTURE"] = dynamicTypeFixtureMode?.rawValue ?? ""
        app.launchEnvironment["MIRROR_UI_APPEARANCE"] = try appearance()
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        do {
            _ = try find("today.list", requestedElement: .todayList, in: app, timeout: 30)
            if recordConfiguration { try configuration(in: app, viewport: "standard", method: method) }
            return app
        } catch {
            app.terminate()
            throw error
        }
    }

    private enum DynamicTypeFixtureMode: String { case pinned, system }

    @MainActor
    private func requestedDynamicTypeFixture() throws -> DynamicTypeFixtureMode? {
        let raw = ProcessInfo.processInfo.environment["MIRROR_UI_DYNAMIC_TYPE_FIXTURE"] ?? ""
        // 미설정 scheme 변수는 기존 고정 fixture다. 진단 실행은 별도 marker로 명시적 모드 전달을 검증한다.
        if raw.isEmpty || raw == "$(MIRROR_UI_DYNAMIC_TYPE_FIXTURE)" { return nil }
        guard let mode = DynamicTypeFixtureMode(rawValue: raw) else {
            XCTFail("글자 크기 진단 fixture는 pinned 또는 system이어야 한다.")
            throw HarnessFailure.configuration
        }
        #if os(iOS)
        guard diagnosticCase == .captureValidation else {
            XCTFail("글자 크기 진단 fixture는 iOS의 기존 입력 검증 사례에서만 허용한다.")
            throw HarnessFailure.configuration
        }
        return mode
        #else
        XCTFail("글자 크기 진단 fixture는 iOS에서만 허용한다.")
        throw HarnessFailure.configuration
        #endif
    }

    @MainActor
    private func appearance() throws -> String {
        let value = ProcessInfo.processInfo.environment["MIRROR_UI_APPEARANCE"] ?? "system"
        guard value == "system" || value == "dark" else {
            XCTFail("추가 UI scheme의 표시 모드는 system 또는 dark여야 한다.")
            throw HarnessFailure.configuration
        }
        return value
    }

    @MainActor
    private func configuration(in app: XCUIApplication, viewport: String, method: String = #function) throws {
        #if os(macOS)
        // 루트 AX 그룹 없이 기존 실제 버튼에서 읽은 환경값을 확인한다.
        let applied = try unique(app.buttons.matching(identifier: "capture.open"), requestedElement: .appliedDynamicType)
        XCTAssertEqual(applied.elementType, .button)
        #else
        let applied = try find("ui.appliedDynamicType", requestedElement: .appliedDynamicType, in: app)
        #endif
        try recordDynamicTypeFixture(applied, scope: "root")
        let appliedValue = applied.value
        let appliedString = appliedValue as? String
        let appliedLabel = applied.label
        configurationMeasurement(method: method, value: appliedValue, string: appliedString, label: appliedLabel)
        XCTAssertEqual(appliedString, "accessibility5", "요청값 대신 실제 SwiftUI 환경의 최대 크기를 확인한다.")
        XCTAssertEqual(app.state, .runningForeground)
        #if os(iOS)
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #else
        let platform = "macos"
        #endif
        let metadata = ["dynamicType": "accessibility5", "appearance": try appearance(),
                        "platform": platform, "viewport": viewport]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        print("UI adaptive applied configuration: \(String(decoding: data, as: UTF8.self))")
    }

    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        // 의도된 예외 목록은 비어 있다. 진단 probe·시스템 문제도 실제 근거 없이 무시하지 않는다.
        // XCTest가 보고한 모든 종류의 accessibility issue를 그대로 실패로 남긴다.
        diagnosticAuditSequence += 1
        diagnosticAuditIssueSequence = 0
        do {
            // Xcode 27 공개 SDK의 issueHandler·issue.element 계약을 사용한다.
            // Apple 설명에서 true만 무시를 뜻한다. 진단 여부와 관계없이 항상 false를 반환한다.
            // https://developer.apple.com/videos/play/wwdc2023/10035/
            try app.performAccessibilityAudit(for: .all) { issue in
                self.recordAuditIssue(issue)
                return false
            }
            recordAuditBoundary(.returned)
        } catch {
            recordAuditBoundary(.threw)
            throw error
        }
    }

    @MainActor
    private func capture(_ title: String, in app: XCUIApplication) throws {
        try tap("capture.open", requestedElement: .captureOpen, in: app)
        try replaceText(find("capture.title", requestedElement: .captureTitle, in: app), with: title, in: app)
        try tap("capture.save", requestedElement: .captureSave, in: app)
        try waitForText("보관함에 넣었어요.", in: find("capture.feedback", requestedElement: .captureFeedback, in: app))
        try tap("capture.close", requestedElement: .captureClose, in: app)
        try gone("capture.title", in: app)
    }

    @MainActor
    private func find(_ identifier: String, requestedElement: RequestedElement, in app: XCUIApplication, timeout: TimeInterval = 15) throws -> XCUIElement {
        let query: XCUIElementQuery
        switch identifier {
        case "capture.title", "capture.note", "capture.url", "library.search":
            // 입력 ID만 실제 TextField/TextView 역할을 확인한다.
            let fields = app.textFields.matching(identifier: identifier)
            if fields.firstMatch.exists { return try unique(fields, requestedElement: requestedElement, timeout: timeout) }
            let textViews = app.textViews.matching(identifier: identifier)
            if textViews.firstMatch.exists { return try unique(textViews, requestedElement: requestedElement, timeout: timeout) }
            query = identifier == "library.search" ? fields : app.descendants(matching: .any).matching(identifier: identifier)
        default:
            query = app.descendants(matching: .any).matching(identifier: identifier)
        }
        if identifier == "state.error", query.firstMatch.waitForExistence(timeout: timeout), query.count > 1 {
            // 오류가 modal과 배경에 함께 노출될 때 실제 조작 가능한 modal의 고유 후보를 사용한다.
            let visible = query.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
            XCTAssertEqual(visible.count, 1)
            return try XCTUnwrap(visible.first)
        }
        return try unique(query, requestedElement: requestedElement, timeout: timeout)
    }

    @MainActor
    private func button(_ identifier: String, requestedElement: RequestedElement, label: String? = nil, in app: XCUIApplication) throws -> XCUIElement {
        let query = label.map { app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", identifier, $0)) }
            ?? app.buttons.matching(identifier: identifier)
        #if os(macOS)
        if identifier == "capture.more", !query.firstMatch.exists {
            return try unique(app.descendants(matching: .disclosureTriangle).matching(identifier: identifier), requestedElement: .captureMoreDisclosure)
        }
        #endif
        return try unique(query, requestedElement: requestedElement)
    }

    @MainActor
    private func unique(_ query: XCUIElementQuery, requestedElement: RequestedElement, timeout: TimeInterval = 15) throws -> XCUIElement {
        recordLookupRequest(requestedElement)
        guard query.firstMatch.waitForExistence(timeout: timeout) else {
            XCTFail("Adaptive UI lookup failure: missing")
            throw HarnessFailure.missingElement
        }
        let matchingCount = query.count
        guard matchingCount == 1 else {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad,
               requestedElement == .destinationLibrary,
               let diagnosticCase,
               (diagnosticCase == .plannedCapture && diagnosticProgressPhase == .defaultCaptureStarted)
                || (diagnosticCase == .searchDetailUndo && diagnosticProgressPhase == .captureComplete),
               (0...65_535).contains(matchingCount) {
                emitMeasurement("UI adaptive lookup failure count:", fields: [
                    "schemaVersion": 1, "case": diagnosticCase.rawValue,
                    "requestSequence": diagnosticRequestSequence,
                    "requestedElement": requestedElement.rawValue, "matchingCount": matchingCount,
                ])
            }
            #endif
            XCTFail("Adaptive UI lookup failure: nonUnique")
            throw HarnessFailure.missingElement
        }
        let element = query.firstMatch
        diagnosticRequestedObject = element
        return element
    }

    @MainActor
    private func tap(_ identifier: String, requestedElement: RequestedElement, label: String? = nil, in app: XCUIApplication) throws {
        let control = try button(identifier, requestedElement: requestedElement, label: label, in: app)
        try reveal(control, in: app)
        try assertVisible(control, in: app)
        XCTAssertTrue(control.isEnabled)
        performActivation(control)
    }

    @MainActor
    private func performActivation(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    @MainActor
    private func destination(_ identifier: String, requestedElement: RequestedElement, title: String, in app: XCUIApplication) throws {
        let tabs = app.tabBars.buttons.matching(NSPredicate(format: "label == %@", title))
        if tabs.firstMatch.exists {
            let tab = try unique(tabs, requestedElement: requestedElement)
            try assertVisible(tab, in: app)
            performActivation(tab)
            return
        }
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad,
           !app.buttons.matching(identifier: "destination.\(identifier)").firstMatch.exists,
           (identifier == "library" && title == "보관함" && requestedElement == .destinationLibrary)
            || (identifier == "today" && title == "오늘" && requestedElement == .destinationToday) {
            // iPad 적응형 탭은 tabBar 밖의 실제 Button으로 노출될 수 있다.
            // 두 기존 typed 경로가 없는 경우에만 고정 label의 고유한 앱 버튼을 누른다.
            let label = NSPredicate(format: "label == %@", title)
            let tab = try unique(app.buttons.matching(label), requestedElement: requestedElement)
            XCTAssertEqual(tab.elementType, .button)
            XCTAssertEqual(app.state, .runningForeground)
            let windows = app.windows.allElementsBoundByIndex
            XCTAssertEqual(windows.count, 1)
            let window = try XCTUnwrap(windows.first)
            XCTAssertEqual(window.buttons.matching(label).count, 1, "목적지 버튼은 현재 앱의 단일 창에 속해야 한다.")
            let frame = tab.frame
            XCTAssertTrue(hasArea(frame) && hasArea(window.frame) && window.frame.contains(frame))
            try assertMobileTarget(tab)
            XCTAssertTrue(tab.exists && tab.isHittable && tab.isEnabled)
            performActivation(tab)
            return
        }
        #endif
        try tap("destination.\(identifier)", requestedElement: requestedElement, in: app)
    }

    @MainActor
    private func rowQuery(_ title: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task.row.", title))
    }

    @MainActor
    private func row(_ title: String, in app: XCUIApplication) throws -> XCUIElement {
        try unique(rowQuery(title, in: app), requestedElement: .taskRow)
    }

    @MainActor
    private func weekSurface(in app: XCUIApplication) throws -> XCUIElement {
        let dates = NSPredicate(format: "identifier BEGINSWITH %@", "plan.day.")
        let candidates = app.scrollViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
            + app.collectionViews.allElementsBoundByIndex
        var owners = candidates.filter { surface in
            hasArea(surface.frame) && surface.isHittable && surface.buttons.matching(dates).firstMatch.exists
        }
        if owners.isEmpty {
            // 첫 Section만 생성된 상태에도 같은 실제 날짜 Form에서 스크롤을 시작한다.
            let task = NSPredicate(format: "identifier BEGINSWITH %@", "plan.task.")
            owners = candidates.filter { surface in
                hasArea(surface.frame) && surface.isHittable
                    && surface.descendants(matching: .any).matching(task).firstMatch.exists
            }
        }
        guard let owner = owners.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            XCTFail("현재 주간 날짜 버튼을 실제 소유한 Form의 스크롤 경계가 있어야 한다.")
            throw HarnessFailure.missingElement
        }
        return owner
    }

    @MainActor
    private func weekDate(_ identifier: String, in app: XCUIApplication) throws -> XCUIElement {
        let query = app.buttons.matching(identifier: identifier)
        let deadline = Date().addingTimeInterval(15)
        for _ in 0..<8 {
            if query.firstMatch.exists { return try unique(query, requestedElement: .planDay, timeout: 0) }
            guard Date() < deadline else { break }
            // LazyVGrid가 아직 만들지 않은 날짜는 현재 날짜를 소유한 실제 Form에서 전진한다.
            let surface = try weekSurface(in: app)
            #if os(macOS)
            surface.scroll(byDeltaX: 0, deltaY: -180)
            #else
            surface.swipeUp()
            #endif
        }
        XCTFail("현재 주간 Form을 스크롤해 요청한 날짜 버튼을 만들어야 한다.")
        throw HarnessFailure.missingElement
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        let deadline = Date().addingTimeInterval(15)
        var firstObservation: RevealFrameObservation?
        var previousObservation: RevealFrameObservation?
        var lastObservation: RevealFrameObservation?
        var observationCount = 0
        var swipeDirections: [String] = []
        for _ in 0..<8 {
            let frame = element.frame
            let identifier = element.identifier
            let elementType = element.elementType
            let windows = app.windows.allElementsBoundByIndex.map { $0.frame }
            let ownerPredicate = NSPredicate(format: "identifier == %@", identifier)
            let surfaces = app.scrollViews.containing(ownerPredicate).allElementsBoundByIndex
                + app.tables.containing(ownerPredicate).allElementsBoundByIndex
                + app.collectionViews.containing(ownerPredicate).allElementsBoundByIndex
            // 같은 관측의 경계를 재사용하며, 다음 반복과 스크롤 뒤에는 새로 읽는다.
            var areaCount = 0, hittableCount = 0, typedTargetCount = 0, columnCount = 0
            let owners: [(surface: XCUIElement, bounds: CGRect, area: CGFloat)] = surfaces.compactMap { surface in
                let bounds = surface.frame
                guard hasArea(bounds) else { return nil }
                areaCount += 1
                // 부모의 탭 지점은 소유 조건이 아니다. 실제 자식을 소유한 viewport에서 스크롤한다.
                if surface.isHittable { hittableCount += 1 }
                guard surface.descendants(matching: elementType).matching(ownerPredicate).firstMatch.exists else { return nil }
                typedTargetCount += 1
                guard bounds.minX <= frame.midX && frame.midX <= bounds.maxX else { return nil }
                columnCount += 1
                guard windows.contains(where: { $0.intersects(bounds) }) else { return nil }
                return (surface, bounds, bounds.width * bounds.height)
            }
            let viewport = owners.min(by: { $0.area < $1.area })
            let viewportFrame = viewport?.bounds
            // 기존 조회값만 보관한다. 마지막 값은 마지막 스와이프 뒤 다음 반복의 관측이다.
            let observation = RevealFrameObservation(target: frame, owner: viewportFrame)
            if firstObservation == nil { firstObservation = observation }
            previousObservation = lastObservation
            lastObservation = observation
            observationCount += 1
            let isScrollableInput = elementType == .textField || elementType == .textView
            let oversizedInput = viewportFrame.map { isScrollableInput && frame.height > $0.height } ?? false
            // 긴 입력란은 내용 자체를 스크롤할 수 있다. 동작/오류 버튼에는 항상 전체 표시를 요구한다.
            let insideOwner = viewportFrame.map { oversizedInput ? hasArea($0.intersection(frame)) : $0.contains(frame) } ?? true
            let hittable = element.isHittable
            let insideWindow = windows.contains(where: { $0.contains(frame) })
            if hittable, hasArea(frame), insideWindow, insideOwner { return }
            guard Date() < deadline, let viewport else {
                revealFailureMeasurement(frame: frame, viewport: viewportFrame, type: elementType,
                    hittable: hittable, insideWindow: insideWindow, insideOwner: insideOwner,
                    ownerCount: owners.count, deadlineExceeded: Date() >= deadline)
                revealOwnerFailureMeasurement(element, in: app, counts: [surfaces.count, areaCount, hittableCount,
                                                               typedTargetCount, columnCount, owners.count])
                if let firstObservation, let lastObservation {
                    phoneRevealObstructionMeasurement(element, identifier: identifier, in: app,
                        first: firstObservation, previous: previousObservation, last: lastObservation,
                        observationCount: observationCount, swipeDirections: swipeDirections)
                }
                if identifier == "capture.save", elementType == .button {
                    captureSaveFailureMeasurement(element, in: app, boundary: "reveal",
                        observedHittable: hittable,
                        observedGeometry: (frame, viewportFrame, surfaces.count, owners.count))
                }
                XCTFail("현재 대상의 실제 스크롤 소유자 안에서 요소에 도달해야 한다.")
                throw HarnessFailure.unhittable
            }
            let surface = viewport.surface
            let bounds = viewport.bounds
            guard isScrollableInput || frame.height <= bounds.height else {
                XCTFail("전체 표시가 필요한 동작의 높이가 실제 스크롤 viewport보다 크다.")
                throw HarnessFailure.unhittable
            }
            let towardTop = frame.minY < bounds.minY
            #if os(macOS)
            surface.scroll(byDeltaX: 0, deltaY: towardTop ? 180 : -180)
            #else
            if towardTop { surface.swipeDown() } else { surface.swipeUp() }
            #endif
            swipeDirections.append(towardTop ? "down" : "up")
        }
        phoneRevealSwipeLimitMeasurement(element, in: app, first: firstObservation, previous: lastObservation,
                                        swipeDirections: swipeDirections, deadline: deadline)
        XCTFail("8회 이내 실제 스크롤로 추가검증 요소에 도달해야 한다.")
        throw HarnessFailure.unhittable
    }

    private struct RevealFrameObservation {
        let target: CGRect
        let owner: CGRect?
    }

    /// 8번째 gesture가 끝난 실패 경로에서만 현재 기하를 다시 읽는다. 새 값으로 성공 판정을 하지 않는다.
    @MainActor
    private func phoneRevealSwipeLimitMeasurement(_ element: XCUIElement, in app: XCUIApplication,
                                                  first: RevealFrameObservation?, previous: RevealFrameObservation?,
                                                  swipeDirections: [String], deadline: Date) {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone,
              diagnosticCase == .searchDetailUndo, diagnosticProgressPhase == .postponeStarted,
              diagnosticRequestedElement == .taskPostpone, element === diagnosticRequestedObject,
              let first, let previous, swipeDirections.count == 8,
              app.state == .runningForeground else { return }
        let frame = element.frame
        let identifier = element.identifier
        let type = element.elementType
        let windows = app.windows.allElementsBoundByIndex.map { $0.frame }
        let predicate = NSPredicate(format: "identifier == %@", identifier)
        let surfaces = app.scrollViews.containing(predicate).allElementsBoundByIndex
            + app.tables.containing(predicate).allElementsBoundByIndex
            + app.collectionViews.containing(predicate).allElementsBoundByIndex
        var areaCount = 0, hittableCount = 0, typedTargetCount = 0, columnCount = 0
        let owners: [CGRect] = surfaces.compactMap { surface in
            let bounds = surface.frame
            guard hasArea(bounds) else { return nil }
            areaCount += 1
            if surface.isHittable { hittableCount += 1 }
            guard surface.descendants(matching: type).matching(predicate).firstMatch.exists else { return nil }
            typedTargetCount += 1
            guard bounds.minX <= frame.midX && frame.midX <= bounds.maxX else { return nil }
            columnCount += 1
            guard windows.contains(where: { $0.intersects(bounds) }) else { return nil }
            return bounds
        }
        let viewport = owners.min(by: { $0.width * $0.height < $1.width * $1.height })
        let hittable = element.isHittable
        revealFailureMeasurement(frame: frame, viewport: viewport, type: type, hittable: hittable,
            insideWindow: windows.contains(where: { $0.contains(frame) }),
            insideOwner: viewport.map { $0.contains(frame) } ?? true,
            ownerCount: owners.count, deadlineExceeded: Date() >= deadline)
        revealOwnerFailureMeasurement(element, in: app, counts: [surfaces.count, areaCount, hittableCount,
                                                               typedTargetCount, columnCount, owners.count])
        phoneRevealObstructionMeasurement(element, identifier: identifier, in: app,
            first: first, previous: previous, last: RevealFrameObservation(target: frame, owner: viewport),
            observationCount: 9, swipeDirections: swipeDirections, swipeLimit: true)
        #endif
    }

    /// Phone의 알려진 실패 분기에서만 읽는다. 개별 안내 요소와의 기하 교차는 가림 원인의 확정이 아니다.
    @MainActor
    private func phoneRevealObstructionMeasurement(_ element: XCUIElement, identifier: String,
                                                   in app: XCUIApplication,
                                                   first: RevealFrameObservation, previous: RevealFrameObservation?,
                                                   last: RevealFrameObservation, observationCount: Int,
                                                   swipeDirections: [String], swipeLimit: Bool = false) {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone,
              diagnosticCase == .searchDetailUndo, diagnosticProgressPhase == .postponeStarted,
              diagnosticRequestedElement == .taskPostpone, element === diagnosticRequestedObject,
              (swipeLimit ? observationCount == 9 : (1...8).contains(observationCount)),
              swipeDirections.count == observationCount - 1 else { return }
        var counts: [String: Any] = ["appTargets": NSNull(), "ownerWindows": NSNull(), "windowTargets": NSNull()]
        func rejected(_ reason: String) {
            let fields: [String: Any] = [
                "schemaVersion": 3, "case": "searchDetailUndo", "requestSequence": diagnosticRequestSequence,
                "requestedElement": "taskPostpone", "status": "guardRejected", "reason": reason,
                "boundary": swipeLimit ? "swipeLimit" : "reveal", "observationCount": observationCount,
                "swipeDirections": swipeDirections, "counts": counts,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                  data.count <= 768 else { return }
            print("UI adaptive phone reveal obstruction diagnostic: \(String(decoding: data, as: UTF8.self))")
        }
        guard app.state == .runningForeground else { rejected("appForeground"); return }
        guard !identifier.isEmpty, element.exists, element.elementType == .button,
              element.identifier == identifier else { rejected("targetIdentity"); return }
        let appTargets = app.buttons.matching(identifier: identifier).allElementsBoundByIndex
        counts["appTargets"] = appTargets.count <= 10_000 ? appTargets.count as Any : NSNull()
        guard appTargets.count == 1, let appTarget = appTargets.first, appTarget.exists,
              appTarget.elementType == .button, appTarget.identifier == identifier else {
            rejected("targetUniqueness"); return
        }
        let windows = app.windows.containing(.button, identifier: identifier).allElementsBoundByIndex
        counts["ownerWindows"] = windows.count <= 10_000 ? windows.count as Any : NSNull()
        guard windows.count == 1, let window = windows.first else { rejected("ownerWindowCount"); return }
        let windowTargets = window.buttons.matching(identifier: identifier).allElementsBoundByIndex
        counts["windowTargets"] = windowTargets.count <= 10_000 ? windowTargets.count as Any : NSNull()
        guard window.exists, windowTargets.count == 1, let windowTarget = windowTargets.first,
              windowTarget.exists, windowTarget.elementType == .button, windowTarget.identifier == identifier else {
            rejected("anchorUniqueness"); return
        }
        func coordinates(_ frame: CGRect?) -> [Double]? {
            guard let frame else { return nil }
            let values = [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
            guard values.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }),
                  frame.width >= 0, frame.height >= 0 else { return nil }
            return values
        }
        let windowBounds = window.frame
        guard hasArea(windowBounds), let windowFrame = coordinates(windowBounds) else {
            rejected("windowGeometry"); return
        }
        func observation(_ value: RevealFrameObservation) -> [String: Any] {
            ["target": coordinates(value.target).map { $0 as Any } ?? NSNull(),
             "owner": coordinates(value.owner).map { $0 as Any } ?? NSNull()]
        }
        func measurement(_ query: XCUIElementQuery) -> [String: Any]? {
            let elements = query.allElementsBoundByIndex
            guard elements.count <= 10_000 else { return nil }
            let frame = elements.count == 1 ? elements[0].frame : nil
            let boundedFrame = coordinates(frame)
            let intersects = boundedFrame != nil && coordinates(last.target) != nil
                ? frame.map { hasArea($0.intersection(last.target)) } : nil
            return ["count": elements.count, "frame": boundedFrame.map { $0 as Any } ?? NSNull(),
                    "intersectsTarget": intersects.map { $0 as Any } ?? NSNull()]
        }
        guard let feedback = measurement(window.staticTexts.matching(identifier: "state.feedback")),
              let dismissFeedback = measurement(window.buttons.matching(identifier: "state.dismissFeedback")),
              let undo = measurement(window.buttons.matching(identifier: "task.undo")),
              let retry = measurement(window.buttons.matching(identifier: "state.retry")),
              let tabBar = measurement(window.tabBars) else { rejected("measurementBounds"); return }
        guard app.state == .runningForeground else { rejected("appForeground"); return }
        var fields: [String: Any] = [
            "schemaVersion": swipeLimit ? 2 : 1, "case": "searchDetailUndo", "requestSequence": diagnosticRequestSequence,
            "requestedElement": "taskPostpone", "observationCount": observationCount,
            "swipeDirections": swipeDirections, "first": observation(first),
            "previous": previous.map { observation($0) as Any } ?? NSNull(), "last": observation(last),
            "windowFrame": windowFrame,
            "elements": ["feedback": feedback, "dismissFeedback": dismissFeedback, "undo": undo,
                         "retry": retry, "tabBar": tabBar],
        ]
        if swipeLimit { fields["boundary"] = "swipeLimit" }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              data.count <= 1_900 else { rejected("payloadBounds"); return }
        print("UI adaptive phone reveal obstruction diagnostic: \(String(decoding: data, as: UTF8.self))")
        #endif
    }

    /// 이미 평가한 필터 개수와 실패 후 키보드 기하만 기록하며 원문 AX 값은 보존하지 않는다.
    @MainActor
    private func revealOwnerFailureMeasurement(_ element: XCUIElement, in app: XCUIApplication, counts: [Int]) {
        guard let diagnosticCase, let diagnosticRequestedElement, counts.count == 6,
              element === diagnosticRequestedObject,
              counts.allSatisfy({ (0...10_000).contains($0) }) else { return }
        var keyboardCount: Int? = nil
        var keyboardFrame: [Double]? = nil
        #if os(iOS)
        let keyboards = app.keyboards.allElementsBoundByIndex
        guard keyboards.count <= 10_000 else { return }
        keyboardCount = keyboards.count
        if keyboards.count == 1 {
            let frame = keyboards[0].frame
            let values = [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
            if values.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }), frame.width >= 0, frame.height >= 0 {
                keyboardFrame = values
            }
        }
        #endif
        emitMeasurement("UI adaptive reveal owner diagnostic:", fields: [
            "schemaVersion": 2, "case": diagnosticCase.rawValue,
            "requestSequence": diagnosticRequestSequence, "requestedElement": diagnosticRequestedElement.rawValue,
            "candidateCount": counts[0], "areaCount": counts[1], "hittableCount": counts[2],
            "typedTargetCount": counts[3], "columnCount": counts[4], "intersectCount": counts[5],
            "keyboardCount": keyboardCount.map { $0 as Any } ?? NSNull(),
            "keyboardFrame": keyboardFrame.map { $0 as Any } ?? NSNull(),
        ])
    }

    /// 실패 직전 이미 읽은 기하·조건만 기록한다. 제목·식별자·AX 원문과 추가 SDK 조회는 없다.
    @MainActor
    private func revealFailureMeasurement(frame: CGRect, viewport: CGRect?, type: XCUIElement.ElementType,
                                          hittable: Bool, insideWindow: Bool, insideOwner: Bool,
                                          ownerCount: Int, deadlineExceeded: Bool) {
        guard let diagnosticCase else { return }
        func coordinates(_ value: CGRect?) -> Any {
            guard let value else { return NSNull() }
            let numbers = [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
            guard numbers.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }) else { return NSNull() }
            return numbers
        }
        let value: [String: Any] = ["schemaVersion": 1, "case": diagnosticCase.rawValue,
            "requestSequence": diagnosticRequestSequence, "elementType": type.rawValue,
            "frame": coordinates(frame), "viewport": coordinates(viewport), "hittable": hittable,
            "insideWindow": insideWindow, "insideOwner": insideOwner, "ownerCount": ownerCount,
            "deadlineExceeded": deadlineExceeded]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count <= 1_024 else { return }
        let line = "UI adaptive reveal boundary: " + String(decoding: data, as: UTF8.self) + "\n"
        try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
    }

    @MainActor
    private func assertVisible(_ element: XCUIElement, in app: XCUIApplication, outsideKeyboard: Bool = false) throws {
        XCTAssertEqual(app.state, .runningForeground)
        let exists = element.exists
        let hittable: Bool? = exists ? element.isHittable : nil
        if !(exists && hittable == true) {
            captureSaveFailureMeasurement(element, in: app, boundary: "assertVisible",
                                          observedExists: exists, observedHittable: hittable)
        }
        XCTAssertTrue(exists && hittable == true)
        let frame = element.frame
        XCTAssertTrue(hasArea(frame))
        let owners = app.windows.containing(NSPredicate(format: "identifier == %@", element.identifier)).allElementsBoundByAccessibilityElement
        XCTAssertEqual(owners.count, 1, "실제 앱 창의 소유를 확인한다.")
        let window = try XCTUnwrap(owners.first)
        XCTAssertTrue(window.frame.contains(frame), "표시된 요소 전체가 실제 소유 창 안에 있어야 한다.")
        #if os(iOS)
        if outsideKeyboard, app.keyboards.firstMatch.exists {
            XCTAssertFalse(frame.intersects(app.keyboards.firstMatch.frame), "키보드가 현재 검증 요소를 가리지 않는다.")
        }
        if UIDevice.current.userInterfaceIdiom == .phone,
           element.identifier == "capture.open" || element.identifier == "settings.button" {
            let native = try find("ui.nativeStatusBar", requestedElement: .nativeStatusBar, in: app)
            let values = (native.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
            XCTAssertEqual(values.count, 4)
            guard values.count == 4 else { throw HarnessFailure.configuration }
            let status = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            XCTAssertTrue(hasArea(status) && window.frame.contains(status))
            XCTAssertGreaterThanOrEqual(frame.minY, status.maxY)
        }
        #endif
    }

    /// 실패 판정 뒤에만 보완 관측한다. 새 조회는 원래 assertion과 조작 조건을 바꾸지 않는다.
    @MainActor
    private func captureSaveFailureMeasurement(_ element: XCUIElement, in app: XCUIApplication,
                                               boundary: String, observedExists: Bool? = nil,
                                               observedHittable: Bool? = nil,
                                               observedGeometry: (CGRect, CGRect?, Int, Int)? = nil) {
        guard let diagnosticCase, diagnosticRequestedElement == .captureSave else { return }
        let exists = observedExists ?? element.exists
        if exists {
            guard element.elementType == .button, element.identifier == "capture.save" else { return }
        }
        let enabled: Bool? = exists ? element.isEnabled : nil
        let hittable: Bool? = observedHittable ?? (exists ? element.isHittable : nil)
        let frame: CGRect? = observedGeometry?.0 ?? (exists ? element.frame : nil)
        let windows = app.windows.containing(.button, identifier: "capture.save").allElementsBoundByIndex
        let ownerHasCaptureClose: Bool? = windows.count == 1
            ? windows[0].buttons.matching(identifier: "capture.close").firstMatch.exists : nil
        let geometry: (CGRect?, Int, Int)
        if let observedGeometry {
            geometry = (observedGeometry.1, observedGeometry.2, observedGeometry.3)
        } else {
            let predicate = NSPredicate(format: "identifier == %@", "capture.save")
            let surfaces = app.scrollViews.containing(predicate).allElementsBoundByIndex
                + app.tables.containing(predicate).allElementsBoundByIndex
                + app.collectionViews.containing(predicate).allElementsBoundByIndex
            let windowFrames = app.windows.allElementsBoundByIndex.map { $0.frame }
            let owners: [CGRect] = surfaces.compactMap { surface in
                let bounds = surface.frame
                guard let frame, hasArea(bounds) && surface.isHittable
                    && surface.descendants(matching: .button).matching(predicate).firstMatch.exists
                    && bounds.minX <= frame.midX && frame.midX <= bounds.maxX
                    && windowFrames.contains(where: { $0.intersects(bounds) }) else { return nil }
                return bounds
            }
            geometry = (owners.min(by: { $0.width * $0.height < $1.width * $1.height }), surfaces.count, owners.count)
        }
        func coordinates(_ value: CGRect?) -> Any {
            guard let value else { return NSNull() }
            let values = [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
            guard values.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }) else { return NSNull() }
            return values
        }
        emitMeasurement("UI adaptive capture save failure:", fields: [
            "schemaVersion": 1, "case": diagnosticCase.rawValue, "requestSequence": diagnosticRequestSequence,
            "requestedElement": "captureSave", "boundary": boundary, "exists": exists,
            "enabled": enabled.map { $0 as Any } ?? NSNull(),
            "hittable": hittable.map { $0 as Any } ?? NSNull(),
            "windowOwnerCount": windows.count,
            "ownerHasCaptureClose": ownerHasCaptureClose.map { $0 as Any } ?? NSNull(),
            "scrollCandidateCount": geometry.1, "scrollOwnerCount": geometry.2,
            "frame": coordinates(frame), "viewport": coordinates(geometry.0),
        ])
        // 첫 합성 입력의 실패만 보존한다. 성공 stage·촬영 순서·통과 판정으로 취급하지 않는다.
        guard diagnosticCase == .captureValidation, diagnosticProgressPhase == .captureInputComplete,
              !captureFailureScreenshotRecorded, exists, windows.count == 1, ownerHasCaptureClose == true,
              app.state == .runningForeground, app.windows.count == 1 else { return }
        let window = windows[0]
        let titleCount = window.textFields.matching(identifier: "capture.title").count
            + window.textViews.matching(identifier: "capture.title").count
        guard titleCount == 1, window.buttons.matching(identifier: "capture.close").count == 1 else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "mirror-adaptive-failure-capture-save"
        attachment.lifetime = .keepAlways
        add(attachment)
        captureFailureScreenshotRecorded = true
        emitMeasurement("UI adaptive capture save failure screenshot:", fields: [
            "schemaVersion": 1, "case": diagnosticCase.rawValue, "requestSequence": diagnosticRequestSequence,
            "name": "mirror-adaptive-failure-capture-save", "status": "complete",
        ])
        #if os(macOS)
        captureSaveCoordinateDiagnostic(element, in: app, window: window, boundary: boundary,
            observedExists: exists, observedEnabled: enabled, observedHittable: hittable, observedFrame: frame)
        #endif
    }

    #if os(macOS)
    /// 첫 실패 PNG 뒤의 단일 호출이다. 원래 captured false assertion과 성공 진행 상태를 바꾸지 않는다.
    @MainActor
    private func captureSaveCoordinateDiagnostic(_ element: XCUIElement, in app: XCUIApplication,
                                                window: XCUIElement, boundary: String,
                                                observedExists: Bool, observedEnabled: Bool?,
                                                observedHittable: Bool?, observedFrame: CGRect?) {
        guard diagnosticCase == .captureValidation, diagnosticProgressPhase == .captureInputComplete,
              diagnosticRequestedElement == .captureSave, element === diagnosticRequestedObject,
              captureFailureScreenshotRecorded, boundary == "assertVisible",
              observedExists, observedEnabled == true, observedHittable == false,
              let frame = observedFrame, hasArea(frame),
              app.state == .runningForeground, app.windows.count == 1, window.exists,
              app.windows.containing(.button, identifier: "capture.save").count == 1,
              app.buttons.matching(identifier: "capture.save").count == 1,
              window.buttons.matching(identifier: "capture.save").count == 1,
              window.buttons.matching(identifier: "capture.close").count == 1 else { return }
        let windowFrame = window.frame
        guard hasArea(windowFrame), windowFrame.contains(frame) else { return }
        let inputs = window.textFields.matching(identifier: "capture.title").allElementsBoundByIndex
            + window.textViews.matching(identifier: "capture.title").allElementsBoundByIndex
        let feedback = window.descendants(matching: .any).matching(identifier: "capture.feedback")
        guard inputs.count == 1, (inputs[0].value as? String) == "큰 글자로 입력", feedback.count == 0,
              element.exists, element.isEnabled, !element.isHittable, element.frame == frame,
              window.frame == windowFrame, app.state == .runningForeground else { return }

        let requestSequence = diagnosticRequestSequence
        func notice(_ phase: String, exists: Bool? = nil, matches: Bool? = nil) {
            let fields: [String: Any] = [
                "schemaVersion": 1, "scope": "alreadyFailedOnly", "case": "captureValidation",
                "requestSequence": requestSequence, "requestedElement": "captureSave", "phase": phase,
                "feedbackExists": exists.map { $0 as Any } ?? NSNull(),
                "feedbackMatchesExpected": matches.map { $0 as Any } ?? NSNull(),
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                  data.count <= 1_024 else { return }
            let line = "::notice::UI adaptive capture save coordinate diagnostic: "
                + String(decoding: data, as: UTF8.self) + "\n"
            try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
        }
        notice("attempted")
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - windowFrame.minX, dy: frame.midY - windowFrame.minY))
            .click()
        guard app.state == .runningForeground, app.windows.count == 1, window.exists,
              window.frame == windowFrame, window.buttons.matching(identifier: "capture.close").count == 1 else {
            notice("result")
            return
        }
        // 대기 없는 단일 관측이다. false는 비동기 저장/AX 지연도 포함하므로 클릭 차단을 확정하지 않는다.
        let feedbackExists = feedback.firstMatch.exists
        let matches = feedbackExists && feedback.count == 1 && feedback.firstMatch.label == "보관함에 넣었어요."
        notice("result", exists: feedbackExists, matches: matches)
    }
    #endif

    @MainActor
    private func assertMobileTarget(_ element: XCUIElement) throws {
        #if os(iOS)
        let frame = element.frame
        XCTAssertGreaterThanOrEqual(frame.width, 44)
        XCTAssertGreaterThanOrEqual(frame.height, 44)
        #endif
    }

    @MainActor
    private func replaceText(_ field: XCUIElement, with value: String, in app: XCUIApplication) throws {
        try reveal(field, in: app)
        performActivation(field)
        #if os(iOS)
        try dismissKeyboardIntroduction(in: app)
        let current = field.value as? String ?? ""
        if !current.isEmpty, current != field.placeholderValue {
            field.press(forDuration: 1.2)
            let selectAll = NSPredicate(format: "label == %@ OR label == %@", "전체 선택", "Select All")
            XCTAssertTrue(app.descendants(matching: .any).matching(selectAll).firstMatch.waitForExistence(timeout: 5))
            let buttons = app.buttons.matching(selectAll)
            let choice = try unique(buttons.firstMatch.exists ? buttons : app.menuItems.matching(selectAll), requestedElement: .selectAll, timeout: 0)
            XCTAssertTrue(choice.isHittable && choice.isEnabled)
            choice.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        #else
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        #endif
        field.typeText(value)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed)
    }

    #if os(iOS)
    @MainActor
    private func dismissKeyboardIntroduction(in app: XCUIApplication) throws {
        let prompt = NSPredicate(format: "label == %@", "Speed up your typing by sliding your finger across the letters to compose a word.")
        let text = app.staticTexts.matching(prompt).firstMatch
        if text.exists {
            let predicate = NSPredicate(format: "label == %@", "Continue")
            let next = try unique(app.buttons.matching(predicate), requestedElement: .keyboardContinue)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            let owners = app.windows.containing(prompt).containing(predicate)
            XCTAssertEqual(owners.count, 1)
            XCTAssertTrue(owners.firstMatch.frame.contains(next.frame) && next.isHittable && next.isEnabled)
            next.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: text)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 15), .completed)
        }
        XCTAssertTrue(app.keyboards.firstMatch.keys.firstMatch.waitForExistence(timeout: 15))
    }
    #endif

    @MainActor
    private func waitForText(_ expected: String, in element: XCUIElement) throws {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ OR (label == '' AND value == %@)", expected, expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed)
    }

    @MainActor
    private func gone(_ identifier: String, in app: XCUIApplication) throws {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 15), .completed)
    }

    @MainActor
    private func text(_ element: XCUIElement) -> String {
        element.label.isEmpty ? element.value as? String ?? "" : element.label
    }

    private static func hasArea(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
            && frame.width > 0 && frame.height > 0
    }

    private func hasArea(_ frame: CGRect) -> Bool { Self.hasArea(frame) }

    @MainActor
    private func record(_ stage: String, in app: XCUIApplication) throws {
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.windows.firstMatch.exists)
        let scope: PresentationScope?
        switch stage {
        case "max-capture", "max-validation", "max-recovery", "max-capture-plan": scope = .capture
        case "max-review": scope = .review
        case "max-week": scope = .plan
        case "max-detail", "max-completion", "max-undo", "narrow-detail": scope = .detail
        default: scope = nil
        }
        if let scope { try assertPresentationDynamicType(scope, in: app) }
        screenshotSequence += 1
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "mirror-adaptive-\(stage)-\(screenshotSequence)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertPresentationDynamicType(_ scope: PresentationScope, in app: XCUIApplication) throws {
        #if os(macOS)
        let query = scope == .capture
            ? app.buttons.matching(identifier: "capture.save")
            : app.descendants(matching: .any).matching(identifier: "ui.appliedDynamicType." + scope.rawValue)
        #else
        let query = app.descendants(matching: .any).matching(identifier: "ui.appliedDynamicType." + scope.rawValue)
        #endif
        guard query.firstMatch.waitForExistence(timeout: 15), query.count == 1 else {
            XCTFail("표시한 시트의 실제 글자 크기 환경을 고유한 요소로 확인해야 한다.")
            throw HarnessFailure.configuration
        }
        let probe = query.firstMatch
        try recordDynamicTypeFixture(probe, scope: scope.rawValue)
        #if os(macOS)
        let matches: Bool
        if scope == .capture {
            // 기존 저장 버튼 자체의 환경값을 읽고 label이나 요청값으로 대신하지 않는다.
            matches = probe.elementType == .button && (probe.value as? String) == "accessibility5"
        } else {
            matches = probe.label == "글자 크기 환경: accessibility5"
        }
        #else
        let matches = probe.value as? String == "accessibility5"
        #endif
        emitMeasurement("UI adaptive presentation configuration:", fields: [
            "scope": scope.rawValue, "maximumTypeApplied": matches,
        ])
        guard matches else {
            XCTFail("루트뿐 아니라 입력·정리·날짜·상세 시트도 최대 글자 크기를 사용해야 한다.")
            throw HarnessFailure.configuration
        }
    }

    private enum PresentationScope: String { case capture, review, plan, detail }

    @MainActor
    private func recordDynamicTypeFixture(_ probe: XCUIElement, scope: String) throws {
        guard let mode = dynamicTypeFixtureMode else { return }
        guard diagnosticCase == .captureValidation, scope == "root" || scope == "capture",
              let fields = (try? JSONSerialization.jsonObject(with: Data(probe.label.utf8))) as? [String: String],
              Set(fields.keys) == ["actualMode", "scope", "swiftUI", "uiKit", "uiKitSource"],
              let actualMode = fields["actualMode"], DynamicTypeFixtureMode(rawValue: actualMode) != nil,
              fields["scope"] == scope, fields["uiKitSource"] == "appSystem",
              let swiftUI = fields["swiftUI"], Self.fontEnvironmentNames.contains(swiftUI),
              let uiKit = fields["uiKit"], Self.applicationContentSizeNames.contains(uiKit) else {
            // 대상 앱의 원문 label은 실패 메시지나 로그에 포함하지 않는다.
            XCTFail("대상 앱의 글자 크기 진단 관측은 고정 schema와 enum을 사용해야 한다.")
            throw HarnessFailure.configuration
        }
        if dynamicTypeFixtureScopes.insert(scope).inserted {
            emitMeasurement("UI dynamic type fixture:", fields: [
                "schemaVersion": 1, "requestedMode": mode.rawValue, "actualMode": actualMode,
                "scope": scope, "swiftUI": swiftUI, "uiKit": uiKit, "uiKitSource": "appSystem",
            ])
        }
        guard actualMode == mode.rawValue, uiKit == "accessibilityExtraExtraExtraLarge" else {
            XCTFail("대상 앱에 요청한 진단 모드와 시스템 최대 글자 크기가 적용되어야 한다.")
            throw HarnessFailure.configuration
        }
    }

    @MainActor
    private func configurationMeasurement(method: String, value: Any?, string: String?, label: String) {
        let valueKind = value == nil ? "nil" : value is String ? "string" : value is NSNumber ? "number" : "other"
        let castName = string.flatMap { Self.fontEnvironmentNames.contains($0) ? $0 : nil }
        let castKind = string.map { $0.isEmpty ? "empty" : castName == nil ? "otherString" : "enum" } ?? "nil"
        let prefix = "글자 크기 환경: "
        let environmentName = label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : ""
        let environmentKind = Self.fontEnvironmentNames.contains(environmentName) ? "enum"
            : label.isEmpty ? "empty" : "unrecognized"
        emitMeasurement("UI adaptive configuration measurement:", fields: [
            "method": method, "valueKind": valueKind, "castKind": castKind,
            "castName": castName.map { $0 as Any } ?? NSNull(),
            "environmentKind": environmentKind,
            "environmentName": environmentKind == "enum" ? environmentName as Any : NSNull(),
        ])
    }

    @MainActor
    private func resizeMeasurement(method: String, before: CGRect, observed: CGRect?,
                                   samples: Int, result: XCTWaiter.Result) {
        let resultName: String
        switch result {
        case .completed: resultName = "completed"
        case .timedOut: resultName = "timedOut"
        case .incorrectOrder: resultName = "incorrectOrder"
        case .invertedFulfillment: resultName = "invertedFulfillment"
        case .interrupted: resultName = "interrupted"
        @unknown default: return
        }
        let frame = { (value: CGRect) in [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)] }
        let beforeFrame = frame(before)
        let observedFrame = observed.map(frame)
        guard beforeFrame.allSatisfy({ $0.isFinite }), observedFrame?.allSatisfy({ $0.isFinite }) ?? true,
              (0...10_000).contains(samples) else { return }
        emitMeasurement("UI adaptive resize measurement:", fields: [
            "method": method, "beforeFrame": beforeFrame,
            "observedFrame": observedFrame.map { $0 as Any } ?? NSNull(), "samples": samples,
            "waitResult": resultName, "waitCompleted": result == .completed,
        ])
    }

    @MainActor
    private func emitMeasurement(_ marker: String, fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        print("\(marker) \(String(decoding: data, as: UTF8.self))")
    }

    private static let fontEnvironmentNames: Set<String> = [
        "xSmall", "small", "medium", "large", "xLarge", "xxLarge", "xxxLarge",
        "accessibility1", "accessibility2", "accessibility3", "accessibility4", "accessibility5",
    ]

    private static let applicationContentSizeNames: Set<String> = [
        "extraSmall", "small", "medium", "large", "extraLarge", "extraExtraLarge", "extraExtraExtraLarge",
        "accessibilityMedium", "accessibilityLarge", "accessibilityExtraLarge",
        "accessibilityExtraExtraLarge", "accessibilityExtraExtraExtraLarge", "unspecified",
    ]

    /// XCTest의 predicate callback과 대기 종료 시점 사이의 관측 snapshot을 함께 보호한다.
    private final class ResizeObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var frame: CGRect?
        private var samples = 0
        func record(_ value: CGRect) {
            lock.lock()
            defer { lock.unlock() }
            frame = value
            samples += 1
        }
        func snapshot() -> (frame: CGRect?, samples: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (frame, samples)
        }
    }

    @MainActor
    private func progress(_ phase: ProgressPhase, method: String = #function, step: Int = 0) {
        diagnosticProgressPhase = phase
        if phase == .started { progressSequence = 0 }
        progressSequence += 1
        // 고정 사례명과 도달 경계만 기록하며 입력값·AX 요소·검증 결과를 포함하지 않는다.
        print("UI adaptive progress: {\"method\":\"\(method)\",\"phase\":\"\(phase.rawValue)\",\"sequence\":\(progressSequence),\"step\":\(step)}")
    }

    private enum ProgressPhase: String {
        case auditComplete
        case auditStarted
        case captureComplete
        case captureInputComplete
        case captureInputStarted
        case captureOpenStarted
        case captureOpened
        case captureStarted
        case completionStarted
        case completionVerified
        case defaultCaptureComplete
        case defaultCaptureStarted
        case detailOpenStarted
        case detailVerified
        case launchComplete
        case newCaptureComplete
        case newCaptureStarted
        case optionalInputsStarted
        case optionalInputsVerified
        case overlongInputComplete
        case overlongInputStarted
        case plannedCaptureReady
        case plannedCaptureSaved
        case plannedCaptureStarted
        case postponeComplete
        case postponeStarted
        case recordComplete
        case recordStarted
        case recoveryInputComplete
        case recoveryInputStarted
        case recoverySaved
        case reviewControlsVerified
        case reviewOpened
        case reviewResumeClosed
        case reviewResumeVerified
        case searchInputComplete
        case searchInputStarted
        case searchVerified
        case started
        case storedRowVerified
        case undoStarted
        case undoVerified
        case validationSubmitted
        case validationVerified
        case weekDayStarted
        case weekDayVerified
        case weekOpened
        case weekSelected
        case windowResizeStarted
        case windowResizeVerified
    }

    // 경계 관측은 고정 코드만 기록한다. audit 콜백도 식별자·SDK 설명을 고정 코드로 변환한다.
    @MainActor
    private func beginCaseDiagnostics(_ value: DiagnosticCase) {
        diagnosticCase = value
        diagnosticRequestSequence = 0
        diagnosticRequestedElement = nil
        diagnosticRequestedObject = nil
        diagnosticProgressPhase = nil
        captureFailureScreenshotRecorded = false
        diagnosticAuditSequence = 0
        diagnosticAuditIssueSequence = 0
        emitMeasurement("UI adaptive case diagnostic:", fields: [
            "schemaVersion": 1, "case": value.rawValue,
            "requestSequence": 0, "requestedElement": NSNull(),
        ])
    }

    @MainActor
    private func recordLookupRequest(_ element: RequestedElement) {
        guard let diagnosticCase else { return }
        diagnosticRequestSequence += 1
        diagnosticRequestedElement = element
        diagnosticRequestedObject = nil
        emitMeasurement("UI adaptive case diagnostic:", fields: [
            "schemaVersion": 1, "case": diagnosticCase.rawValue,
            "requestSequence": diagnosticRequestSequence, "requestedElement": element.rawValue,
        ])
    }

    @MainActor
    private func recordAuditBoundary(_ outcome: AuditOutcome) {
        guard let diagnosticCase else { return }
        emitMeasurement("UI adaptive audit boundary:", fields: [
            "schemaVersion": 1, "case": diagnosticCase.rawValue,
            "auditSequence": diagnosticAuditSequence, "outcome": outcome.rawValue,
        ])
    }

    @MainActor
    private func recordAuditIssue(_ issue: XCUIAccessibilityAuditIssue) {
        guard let diagnosticCase else { return }
        diagnosticAuditIssueSequence += 1
        let kind: AuditIssueKind
        switch issue.compactDescription {
        case "Parent/Child mismatch": kind = .parentChildMismatch
        case "Element has no description": kind = .missingDescription
        default: kind = .other
        }
        let element = issue.element
        let identifier: AuditElementIdentifier = element.map { auditElementIdentifier($0.identifier) } ?? .none
        let type: AuditElementType = element.map { auditElementType($0.elementType) } ?? .none
        // label/value/debugDescription/detailedDescription과 알 수 없는 식별자는 출력하지 않는다.
        emitMeasurement("UI adaptive audit issue:", fields: [
            "schemaVersion": 1, "case": diagnosticCase.rawValue,
            "auditSequence": diagnosticAuditSequence, "issueSequence": diagnosticAuditIssueSequence,
            "issueKind": kind.rawValue, "elementPresent": element != nil,
            "elementIdentifier": identifier.rawValue, "elementType": type.rawValue, "ignored": false,
        ])
        #if os(iOS)
        if let mode = dynamicTypeFixtureMode, diagnosticCase == .captureValidation {
            let knownTypes: XCUIAccessibilityAuditType = [.dynamicType, .contrast, .textClipped]
            var types: [String] = []
            if issue.auditType.contains(.dynamicType) { types.append("dynamicType") }
            if issue.auditType.contains(.contrast) { types.append("contrast") }
            if issue.auditType.contains(.textClipped) { types.append("textClipped") }
            if !issue.auditType.subtracting(knownTypes).isEmpty || types.isEmpty { types.append("other") }
            emitMeasurement("UI dynamic type audit:", fields: [
                "schemaVersion": 1, "requestedMode": mode.rawValue,
                "auditSequence": diagnosticAuditSequence, "issueSequence": diagnosticAuditIssueSequence,
                "types": types, "ignored": false,
            ])
        }
        #endif
        // 감사 issue당 frame SDK 조회 한 번만 추가한다. 원문 AX 내용 없이 유한한 좌표만 남긴다.
        let frame: [Double]? = element.flatMap {
            let value = $0.frame
            let numbers = [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
            guard numbers.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }),
                  value.width >= 0, value.height >= 0 else { return nil }
            return numbers
        }
        emitMeasurement("UI adaptive audit geometry:", fields: [
            "schemaVersion": 1, "case": diagnosticCase.rawValue,
            "auditSequence": diagnosticAuditSequence, "issueSequence": diagnosticAuditIssueSequence,
            "elementIdentifier": identifier.rawValue, "elementType": type.rawValue,
            "frame": frame.map { $0 as Any } ?? NSNull(),
        ])
    }

    @MainActor
    private func auditElementIdentifier(_ identifier: String) -> AuditElementIdentifier {
        switch identifier {
        case "ui.appliedDynamicType": .appliedDynamicType
        case "ui.appliedDynamicType.capture": .captureDynamicType
        case "ui.appliedDynamicType.review": .reviewDynamicType
        case "ui.appliedDynamicType.plan": .planDynamicType
        case "ui.appliedDynamicType.detail": .detailDynamicType
        case "capture.open": .captureOpen
        case "capture.close": .captureClose
        case "capture.title": .captureTitle
        case "capture.note": .captureNote
        case "capture.url": .captureURL
        case "capture.more": .captureMore
        case "capture.save": .captureSave
        case "capture.feedback": .captureFeedback
        case "capture.planChoices": .capturePlanChoices
        case "capture.planSummary": .capturePlanSummary
        case "capture.planToday": .capturePlanToday
        case "capture.planTomorrow": .capturePlanTomorrow
        case "capture.planOther": .capturePlanOther
        case "today.list": .todayList
        case "today.review": .todayReview
        case "destination.today": .destinationToday
        case "destination.calendar": .destinationCalendar
        case "destination.library": .destinationLibrary
        case "settings.button": .settingsButton
        case "library.search": .librarySearch
        case "library.list": .libraryList
        case "library.batchFooter": .libraryBatchFooter
        case "library.batchPlan": .libraryBatchPlan
        case "review.card": .reviewCard
        case "review.detail": .reviewDetail
        case "review.today": .reviewToday
        case "review.tomorrow": .reviewTomorrow
        case "review.thisWeek": .reviewThisWeek
        case "review.nextWeek": .reviewNextWeek
        case "review.other": .reviewOther
        case "review.finish": .reviewFinish
        case "plan.today": .planToday
        case "plan.tomorrow": .planTomorrow
        case "plan.cancel": .planCancel
        case "detail.close": .detailClose
        case "detail.contentTitle": .detailContentTitle
        case "detail.title": .detailTitle
        case "detail.plan": .detailPlan
        case "detail.history": .detailHistory
        case "detail.postponeTomorrow": .detailPostponeTomorrow
        case "task.complete": .taskComplete
        case "task.undo": .taskUndo
        case "state.error": .stateError
        case "state.feedback": .stateFeedback
        default: .other
        }
    }

    @MainActor
    private func auditElementType(_ type: XCUIElement.ElementType) -> AuditElementType {
        switch type {
        case .application: .application
        case .window: .window
        case .sheet: .sheet
        case .button: .button
        case .textField: .textField
        case .textView: .textView
        case .staticText: .staticText
        case .scrollView: .scrollView
        case .table: .table
        case .collectionView: .collectionView
        case .image: .image
        case .disclosureTriangle: .disclosureTriangle
        default: .other
        }
    }

    private enum DiagnosticCase: String {
        case captureValidation
        case reviewWeek
        case searchDetailUndo
        case plannedCapture
        case narrowMac
    }

    private enum AuditOutcome: String { case returned, threw }

    private enum AuditIssueKind: String { case parentChildMismatch, missingDescription, other }

    private enum AuditElementIdentifier: String {
        case none, other, appliedDynamicType
        case captureDynamicType, reviewDynamicType, planDynamicType, detailDynamicType
        case captureOpen, captureClose, captureTitle, captureNote, captureURL, captureMore, captureSave, captureFeedback
        case capturePlanChoices, capturePlanSummary, capturePlanToday, capturePlanTomorrow, capturePlanOther
        case todayList, todayReview, destinationToday, destinationCalendar, destinationLibrary, settingsButton
        case librarySearch, libraryList, libraryBatchFooter, libraryBatchPlan
        case reviewCard, reviewDetail, reviewToday, reviewTomorrow, reviewThisWeek, reviewNextWeek, reviewOther, reviewFinish
        case planToday, planTomorrow, planCancel
        case detailClose, detailContentTitle, detailTitle, detailPlan, detailHistory, detailPostponeTomorrow
        case taskComplete, taskUndo, stateError, stateFeedback
    }

    private enum AuditElementType: String {
        case none, other, application, window, sheet, button, textField, textView, staticText
        case scrollView, table, collectionView, image, disclosureTriangle
    }

    private enum RequestedElement: String {
        case appliedDynamicType
        case captureClose
        case captureFeedback
        case captureMoreButton
        case captureMoreDisclosure
        case captureNote
        case captureOpen
        case capturePlanChoices
        case capturePlanSummary
        case capturePlanToday
        case captureSave
        case captureTitle
        case destinationLibrary
        case destinationToday
        case detailClose
        case detailContentTitle
        case detailPlan
        case detailPostponeTomorrow
        case keyboardContinue
        case librarySearch
        case nativeStatusBar
        case planDay
        case planTomorrow
        case reviewCard
        case reviewFinish
        case reviewNextWeek
        case reviewToday
        case reviewTomorrow
        case selectAll
        case settingsButton
        case stateError
        case taskComplete
        case taskPostpone
        case taskRow
        case taskUndo
        case todayList
        case todayReview
    }

    private enum HarnessFailure: Error { case configuration, missingElement, unhittable }
}
