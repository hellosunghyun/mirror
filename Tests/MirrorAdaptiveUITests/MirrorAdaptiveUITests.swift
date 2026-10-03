import XCTest
#if os(iOS)
import UIKit
#endif

/// 기존 여섯 기능 사례와 다른 bundle에서 실제 큰 글자·접근성·창 경계를 검사한다.
/// 매 launch는 앱의 기존 UI 테스트 모드로 새 실제 Core Data store를 연다.
final class MirrorAdaptiveUITests: XCTestCase {
    @MainActor private var screenshotSequence = 0

    @MainActor
    func testMaximumTypeCaptureValidationAndRecovery() throws {
        let app = try launchApp()
        defer { app.terminate() }
        try tap("capture.open", in: app)
        let title = try find("capture.title", in: app)
        try replaceText(title, with: "큰 글자로 입력", in: app)
        try assertVisible(try button("capture.save", in: app), in: app, outsideKeyboard: true)
        try record("max-capture", in: app)
        try audit(app)

        let original = String(repeating: "x", count: 500) + "Z"
        try replaceText(title, with: original, in: app)
        XCTAssertEqual(title.value as? String, original)
        try tap("capture.save", in: app)
        let error = try find("state.error", in: app)
        try waitForText("제목은 500자 이하로 입력해 주세요.", in: error)
        XCTAssertEqual(title.value as? String, original, "큰 글자에서도 501자 원문을 자르거나 지우지 않는다.")
        try assertVisible(error, in: app, outsideKeyboard: true)
        try assertVisible(try button("capture.save", in: app), in: app, outsideKeyboard: true)
        try assertVisible(try button("capture.close", in: app), in: app)
        try record("max-validation", in: app)

        // 정지사진의 접힌 카드 비침과 실제 접근 불가능을 구별한다.
        let more = try button("capture.more", in: app)
        try reveal(more, in: app)
        try assertVisible(more, in: app, outsideKeyboard: true)
        more.tap()
        let note = try find("capture.note", in: app)
        try reveal(note, in: app)
        XCTAssertTrue(note.isHittable, "오류 뒤에도 선택 입력을 실제 스크롤로 열 수 있다.")
        try reveal(more, in: app)
        more.tap()
        try reveal(title, in: app)
        try replaceText(title, with: "오류 수정 뒤 저장", in: app)
        try tap("capture.save", in: app)
        try waitForText("보관함에 넣었어요.", in: find("capture.feedback", in: app))
        try assertVisible(try find("capture.feedback", in: app), in: app, outsideKeyboard: true)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "state.error").firstMatch.exists)
        try record("max-recovery", in: app)
        try tap("capture.close", in: app)
        try gone("capture.title", in: app)
        try destination("library", title: "보관함", in: app)
        let saved = try row("오류 수정 뒤 저장", in: app)
        XCTAssertTrue((saved.value as? String ?? "").contains("아직 정하지 않음"))
    }

    @MainActor
    func testMaximumTypeReviewAndWeekPicker() throws {
        let app = try launchApp()
        defer { app.terminate() }
        try capture("큰 글자 주간 선택", in: app)
        try tap("today.review", in: app)
        try waitForText("큰 글자 주간 선택", in: find("review.card", in: app))
        for id in ["review.today", "review.tomorrow", "review.nextWeek"] {
            let choice = try button(id, in: app)
            try reveal(choice, in: app)
            try assertVisible(choice, in: app)
            try assertMobileTarget(choice)
        }
        try record("max-review", in: app)
        try audit(app)
        try tap("review.nextWeek", in: app)
        var column: (x: CGFloat, width: CGFloat)?
        for day in 5...11 {
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
        }
        try record("max-week", in: app)
        try audit(app)
        try tap("plan.day.2026-10-11", in: app)
        try gone("plan.cancel", in: app)
        try tap("review.finish", in: app)
        try gone("review.finish", in: app)
        try destination("library", title: "보관함", in: app)
        try replaceText(find("library.search", in: app), with: "큰 글자 주간 선택", in: app)
        XCTAssertTrue((try row("큰 글자 주간 선택", in: app).value as? String ?? "").contains("10월 11일"))
    }

    @MainActor
    func testMaximumTypeSearchDetailCompletionAndUndo() throws {
        let app = try launchApp()
        defer { app.terminate() }
        let title = "큰 글자 검색과 내일"
        try capture(title, in: app)
        try destination("library", title: "보관함", in: app)
        let saved = try row(title, in: app)
        let taskID = try XCTUnwrap(saved.identifier.components(separatedBy: "task.row.").last)
        XCTAssertNotNil(UUID(uuidString: taskID))
        try tap("task.postpone.\(taskID)", in: app)
        let tomorrow = try button("plan.tomorrow", in: app)
        try reveal(tomorrow, in: app)
        try assertVisible(tomorrow, in: app)
        try assertMobileTarget(tomorrow)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "plan.calendar").firstMatch.exists)
        tomorrow.tap()
        try gone("plan.cancel", in: app)
        try destination("today", title: "오늘", in: app)
        XCTAssertFalse(rowQuery(title, in: app).firstMatch.exists, "내일 배치는 오늘 목록에 나타나지 않는다.")
        try destination("library", title: "보관함", in: app)
        let search = try find("library.search", in: app)
        try replaceText(search, with: title, in: app)
        let future = try row(title, in: app)
        XCTAssertTrue((future.value as? String ?? "").contains("10월 1일"))
        for id in ["capture.open", "settings.button"] {
            try assertVisible(try button(id, in: app), in: app, outsideKeyboard: true)
        }
        try record("max-search", in: app)
        try audit(app)
        search.typeText("\n")
        try reveal(future, in: app)
        try assertVisible(future, in: app)
        future.tap()
        try waitForText(title, in: find("detail.contentTitle", in: app))
        XCTAssertTrue(text(try find("detail.plan", in: app)).contains("10월 1일"))
        try record("max-detail", in: app)
        try audit(app)
        try tap("task.complete", in: app)
        try waitForText("완료 취소 · 다시 열기", in: button("task.complete", in: app))
        try record("max-completion", in: app)
        try tap("task.undo", label: "직전 변경 되돌리기", in: app)
        try waitForText("완료", in: button("task.complete", in: app))
        XCTAssertEqual(text(try find("detail.contentTitle", in: app)), title)
        XCTAssertTrue(text(try find("detail.plan", in: app)).contains("10월 1일"))
        try record("max-undo", in: app)
        try audit(app)
    }

    @MainActor
    func testMaximumTypePlannedCaptureKeepsUnassignedDefault() throws {
        let app = try launchApp()
        defer { app.terminate() }
        let unassigned = "날짜 없는 큰 글자 입력"
        try tap("capture.open", in: app)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "capture.planChoices").firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(identifier: "capture.planToday").firstMatch.exists)
        try replaceText(find("capture.title", in: app), with: unassigned, in: app)
        try tap("capture.save", in: app)
        try waitForText("보관함에 넣었어요.", in: find("capture.feedback", in: app))
        try tap("capture.close", in: app)
        try gone("capture.title", in: app)
        try destination("library", title: "보관함", in: app)
        XCTAssertTrue((try row(unassigned, in: app).value as? String ?? "").contains("아직 정하지 않음"))
        try destination("today", title: "오늘", in: app)
        XCTAssertFalse(rowQuery(unassigned, in: app).firstMatch.exists)

        let planned = "오늘로 정한 큰 글자 입력"
        try tap("capture.open", in: app)
        try replaceText(find("capture.title", in: app), with: planned, in: app)
        try tap("capture.more", in: app)
        try tap("capture.planToday", in: app)
        let summary = try find("capture.planSummary", in: app)
        XCTAssertTrue(text(summary).contains("9월 30일"))
        XCTAssertEqual(text(try button("capture.save", in: app)), "날짜에 넣기")
        try record("max-capture-plan", in: app)
        try audit(app)
        try tap("capture.save", in: app)
        try waitForText("9월 30일 수요일에 넣었어요.", in: find("capture.feedback", in: app))
        try assertVisible(try find("capture.feedback", in: app), in: app, outsideKeyboard: true)
        try tap("capture.close", in: app)
        try gone("capture.title", in: app)
        let saved = try row(planned, in: app)
        XCTAssertTrue((saved.value as? String ?? "").contains("9월 30일"))
        XCTAssertTrue((saved.value as? String ?? "").contains("미완료"), "날짜를 정한 입력은 완료가 아니다.")
        XCTAssertFalse(rowQuery(unassigned, in: app).firstMatch.exists)
        try record("max-planned-today", in: app)
    }

    #if os(macOS)
    @MainActor
    func testNarrowMacWindowCaptureAndRequestedDetail() throws {
        let app = try launchApp(recordConfiguration: false)
        defer { app.terminate() }
        XCTAssertEqual(app.windows.count, 1)
        let window = app.windows.firstMatch
        let before = window.frame
        XCTAssertTrue(hasArea(before))
        XCTAssertGreaterThan(before.width, 800, "실제 좁히기 전의 창은 목표 폭보다 넓어야 한다.")
        // 시스템 창의 실제 오른쪽 아래 모서리를 drag한다. 앱의 sizeClass를 위조하지 않는다.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let destination = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 780, dy: 600))
        corner.press(forDuration: 0.1, thenDragTo: destination)
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = window.frame
            return Self.hasArea(frame) && frame.width >= 760 && frame.width <= 800
                && frame.height >= 520 && frame.height <= 640 && frame.width < before.width
        }, object: window)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 15), .completed,
                       "현재 화면의 실제 창이 지원하는 좁은 폭과 높이로 줄어야 한다.")
        try configuration(in: app, viewport: "narrow")
        for id in ["capture.open", "settings.button", "today.review"] {
            try assertVisible(try button(id, in: app), in: app)
        }
        try record("narrow-main", in: app)
        try audit(app)
        try capture("좁은 창에서 저장", in: app)
        try destination("library", title: "보관함", in: app)
        let saved = try row("좁은 창에서 저장", in: app)
        try reveal(saved, in: app)
        saved.tap()
        try waitForText("좁은 창에서 저장", in: find("detail.contentTitle", in: app))
        for id in ["detail.close", "detail.postponeTomorrow", "task.complete"] {
            let control = try button(id, in: app)
            try reveal(control, in: app)
            try assertVisible(control, in: app)
        }
        XCTAssertTrue(window.frame.width <= 900, "요청 상세가 좁은 창을 화면 밖으로 확장하지 않는다.")
        try record("narrow-detail", in: app)
        try audit(app)
    }
    #endif

    @MainActor
    private func launchApp(recordConfiguration: Bool = true) throws -> XCUIApplication {
        continueAfterFailure = false
        screenshotSequence = 0
        let app = XCUIApplication()
        app.launchEnvironment["MIRROR_UI_TESTING"] = "1"
        app.launchEnvironment["MIRROR_TEST_DATE"] = "2026-09-30T03:00:00Z"
        app.launchEnvironment["MIRROR_UI_DYNAMIC_TYPE"] = "accessibility5"
        app.launchEnvironment["MIRROR_UI_APPEARANCE"] = try appearance()
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        do {
            _ = try find("today.list", in: app, timeout: 30)
            if recordConfiguration { try configuration(in: app, viewport: "standard") }
            return app
        } catch {
            app.terminate()
            throw error
        }
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
    private func configuration(in app: XCUIApplication, viewport: String) throws {
        let applied = try find("ui.appliedDynamicType", in: app)
        XCTAssertEqual(applied.value as? String, "accessibility5", "요청값 대신 실제 SwiftUI 환경의 최대 크기를 확인한다.")
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
        try app.performAccessibilityAudit(for: .all)
    }

    @MainActor
    private func capture(_ title: String, in app: XCUIApplication) throws {
        try tap("capture.open", in: app)
        try replaceText(find("capture.title", in: app), with: title, in: app)
        try tap("capture.save", in: app)
        try waitForText("보관함에 넣었어요.", in: find("capture.feedback", in: app))
        try tap("capture.close", in: app)
        try gone("capture.title", in: app)
    }

    @MainActor
    private func find(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 15) throws -> XCUIElement {
        let fields = app.textFields.matching(identifier: identifier)
        if fields.firstMatch.exists { return try unique(fields, timeout: timeout) }
        let textViews = app.textViews.matching(identifier: identifier)
        if textViews.firstMatch.exists { return try unique(textViews, timeout: timeout) }
        let query = identifier == "library.search" ? fields : app.descendants(matching: .any).matching(identifier: identifier)
        if identifier == "state.error", query.firstMatch.waitForExistence(timeout: timeout), query.count > 1 {
            // 오류가 modal과 배경에 함께 노출될 때 실제 조작 가능한 modal의 고유 후보를 사용한다.
            let visible = query.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
            XCTAssertEqual(visible.count, 1)
            return try XCTUnwrap(visible.first)
        }
        return try unique(query, timeout: timeout)
    }

    @MainActor
    private func button(_ identifier: String, label: String? = nil, in app: XCUIApplication) throws -> XCUIElement {
        let query = label.map { app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", identifier, $0)) }
            ?? app.buttons.matching(identifier: identifier)
        #if os(macOS)
        if identifier == "capture.more", !query.firstMatch.exists {
            return try unique(app.descendants(matching: .disclosureTriangle).matching(identifier: identifier))
        }
        #endif
        return try unique(query)
    }

    @MainActor
    private func unique(_ query: XCUIElementQuery, timeout: TimeInterval = 15) throws -> XCUIElement {
        guard query.firstMatch.waitForExistence(timeout: timeout), query.count == 1 else {
            XCTFail("필수 추가검증 요소는 실제 역할의 고유한 후보여야 한다.")
            throw HarnessFailure.missingElement
        }
        return query.firstMatch
    }

    @MainActor
    private func tap(_ identifier: String, label: String? = nil, in app: XCUIApplication) throws {
        let control = try button(identifier, label: label, in: app)
        try reveal(control, in: app)
        try assertVisible(control, in: app)
        XCTAssertTrue(control.isEnabled)
        control.tap()
    }

    @MainActor
    private func destination(_ identifier: String, title: String, in app: XCUIApplication) throws {
        let tabs = app.tabBars.buttons.matching(NSPredicate(format: "label == %@", title))
        if tabs.firstMatch.exists {
            let tab = try unique(tabs)
            try assertVisible(tab, in: app)
            tab.tap()
        } else { try tap("destination.\(identifier)", in: app) }
    }

    @MainActor
    private func rowQuery(_ title: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task.row.", title))
    }

    @MainActor
    private func row(_ title: String, in app: XCUIApplication) throws -> XCUIElement {
        try unique(rowQuery(title, in: app))
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
            if query.firstMatch.exists { return try unique(query, timeout: 0) }
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
        for _ in 0..<8 {
            let frame = element.frame
            let windows = app.windows.allElementsBoundByIndex.map { $0.frame }
            let ownerPredicate = NSPredicate(format: "identifier == %@", element.identifier)
            let surfaces = app.scrollViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
                + app.collectionViews.allElementsBoundByIndex
            let owners = surfaces.filter { surface in
                let bounds = surface.frame
                return hasArea(bounds) && surface.isHittable
                    && surface.descendants(matching: element.elementType).matching(ownerPredicate).firstMatch.exists
                    && bounds.minX <= frame.midX && frame.midX <= bounds.maxX
                    && windows.contains { $0.intersects(bounds) }
            }
            let viewport = owners.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            let viewportFrame = viewport?.frame
            let isScrollableInput = element.elementType == .textField || element.elementType == .textView
            let oversizedInput = viewportFrame.map { isScrollableInput && frame.height > $0.height } ?? false
            // 긴 입력란은 내용 자체를 스크롤할 수 있다. 동작/오류 버튼에는 항상 전체 표시를 요구한다.
            let insideOwner = viewportFrame.map { oversizedInput ? hasArea($0.intersection(frame)) : $0.contains(frame) } ?? true
            if element.isHittable, hasArea(frame), windows.contains(where: { $0.contains(frame) }), insideOwner { return }
            guard Date() < deadline, let surface = viewport else {
                XCTFail("현재 대상의 실제 스크롤 소유자 안에서 요소에 도달해야 한다.")
                throw HarnessFailure.unhittable
            }
            let bounds = surface.frame
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
        }
        XCTFail("8회 이내 실제 스크롤로 추가검증 요소에 도달해야 한다.")
        throw HarnessFailure.unhittable
    }

    @MainActor
    private func assertVisible(_ element: XCUIElement, in app: XCUIApplication, outsideKeyboard: Bool = false) throws {
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(element.exists && element.isHittable)
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
            let native = try find("ui.nativeStatusBar", in: app)
            let values = (native.value as? String ?? "").split(separator: ",").compactMap { Double($0) }
            XCTAssertEqual(values.count, 4)
            guard values.count == 4 else { throw HarnessFailure.configuration }
            let status = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            XCTAssertTrue(hasArea(status) && window.frame.contains(status))
            XCTAssertGreaterThanOrEqual(frame.minY, status.maxY)
        }
        #endif
    }

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
        field.tap()
        #if os(iOS)
        try dismissKeyboardIntroduction(in: app)
        let current = field.value as? String ?? ""
        if !current.isEmpty, current != field.placeholderValue {
            field.press(forDuration: 1.2)
            let selectAll = NSPredicate(format: "label == %@ OR label == %@", "전체 선택", "Select All")
            XCTAssertTrue(app.descendants(matching: .any).matching(selectAll).firstMatch.waitForExistence(timeout: 5))
            let buttons = app.buttons.matching(selectAll)
            let choice = try unique(buttons.firstMatch.exists ? buttons : app.menuItems.matching(selectAll), timeout: 0)
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
            let next = try unique(app.buttons.matching(predicate))
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
        screenshotSequence += 1
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "mirror-adaptive-\(stage)-\(screenshotSequence)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum HarnessFailure: Error { case configuration, missingElement, unhittable }
}
