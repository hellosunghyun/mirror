import XCTest
#if os(iOS)
import UIKit
#endif

/// 실제 연속 입력·개별 선택·날짜 명령만 사용한다. 저장소 seed나 모델 import는 없다.
@MainActor
final class MirrorBatchUITests: XCTestCase {
    private struct OriginalTask {
        let title: String
        let identifier: String
        var uuid: String { String(identifier.dropFirst("task.row.".count)) }
    }
    private enum Surface: Equatable { case library, planner, none }
    private enum HarnessFailure: Error { case missing, ambiguous, unreachable, wrongValue }
    private let unassigned = "미완료, 배치: 아직 정하지 않음"
    private let today = "미완료, 배치: 9월 30일 수요일에 하기"
    private let tomorrow = "미완료, 배치: 10월 1일 목요일에 하기"

    func testTwoTaskBatchKeepsUnselectedTaskAndOriginalContent() throws {
        let app = try launchApp()
        defer { app.terminate() }
        let titles = ["UI batch two alpha original title", "UI batch two beta original title",
                      "UI batch two control stays unassigned"]
        try captureConsecutively(titles, in: app)
        try showLibrary(search: "UI batch two", in: app)
        let originals = try originalTasks(titles, in: app)
        try verifyRows(originals, plan: unassigned, in: app)
        let selected = Array(originals.prefix(2))
        let control = originals[2]
        try beginSelection(selected, control: control, in: app)
        try verifyPicker(selected, in: app)
        try activate("plan.today", surface: .planner, in: app)
        try gone("plan.cancel", in: app)
        try verifyRows(selected, plan: today, in: app)
        try verifyRows([control], plan: unassigned, in: app)
        try verifyPicker(selected, in: app)
        try activate("plan.tomorrow", surface: .planner, in: app)
        try gone("plan.cancel", in: app)
        try verifyRows(selected, plan: tomorrow, in: app)
        try verifyRows([control], plan: unassigned, in: app)
    }

    func testTwentyTaskBatchKeepsEveryOriginalAndUsesTomorrow() throws {
        let app = try launchApp()
        defer { app.terminate() }
        let titles = (1...20).map { String(format: "UI batch twenty task %02d original title", $0) }
        try captureConsecutively(titles, in: app)
        try showLibrary(search: "UI batch twenty", in: app)
        let originals = try originalTasks(titles, in: app)
        XCTAssertEqual(originals.count, 20)
        try verifyRows(originals, plan: unassigned, in: app)
        try beginSelection(originals, control: nil, in: app)
        try verifyPicker(originals, in: app)
        try activate("plan.tomorrow", surface: .planner, in: app)
        try gone("plan.cancel", in: app)
        try verifyRows(originals, plan: tomorrow, in: app)
        XCTAssertEqual(Set(originals.map(\.identifier)).count, 20)
    }

    private func launchApp() throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MIRROR_UI_TESTING"] = "1"
        app.launchEnvironment["MIRROR_TEST_DATE"] = "2026-09-30T03:00:00Z"
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        // 앱의 기존 UI 검증 경로가 launch마다 새 실제 임시 canonical store를 연다.
        app.launch()
        _ = try unique(app.descendants(matching: .any).matching(identifier: "today.list"), timeout: 30)
        _ = try unique(app.buttons.matching(identifier: "capture.open"))
        return app
    }

    private func captureConsecutively(_ titles: [String], in app: XCUIApplication) throws {
        try activate("capture.open", in: app)
        for title in titles {
            let fields = app.textFields.matching(identifier: "capture.title")
            let field = try unique(fields.firstMatch.exists ? fields : app.textViews.matching(identifier: "capture.title"))
            try waitValue("", element: field)
            try assertReachable(field, in: app)
            performActivation(field)
            #if os(iOS)
            try dismissKeyboardIntroduction(in: app)
            #endif
            field.typeText(title)
            try waitValue(title, element: field)
            try gone("capture.feedback", in: app)
            try activate("capture.save", in: app)
            try waitValue("", element: field)
            let feedback = try unique(app.staticTexts.matching(identifier: "capture.feedback"))
            XCTAssertEqual(feedback.label, "보관함에 넣었어요.")
            XCTAssertTrue(feedback.isHittable)
        }
        try activate("capture.close", in: app)
        try gone("capture.title", in: app)
    }

    private func showLibrary(search: String, in app: XCUIApplication) throws {
        let tabs = app.tabBars.buttons.matching(NSPredicate(format: "label == %@", "보관함"))
        if tabs.firstMatch.exists {
            let tab = try unique(tabs)
            try assertReachable(tab, in: app)
            performActivation(tab)
        } else { try activate("destination.library", in: app) }
        let field = try reachable(app.textFields.matching(identifier: "library.search"), surface: .library,
                                  missingTowardTop: true, in: app)
        XCTAssertTrue(textValue(field).isEmpty)
        performActivation(field)
        #if os(iOS)
        try dismissKeyboardIntroduction(in: app)
        #endif
        field.typeText(search)
        try waitValue(search, element: field)
        field.typeText("\n")
        #if os(iOS)
        let keyboard = app.keyboards.firstMatch
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        try requireCompleted(hidden)
        #endif
    }

    private func originalTasks(_ titles: [String], in app: XCUIApplication) throws -> [OriginalTask] {
        let tasks = try titles.map { title in
            let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task.row.", title))
            let row = try reachable(query, surface: .library, in: app)
            let identifier = row.identifier
            let uuid = String(identifier.dropFirst("task.row.".count))
            XCTAssertNotNil(UUID(uuidString: uuid))
            XCTAssertEqual(row.label, title)
            return OriginalTask(title: title, identifier: identifier)
        }
        XCTAssertEqual(Set(tasks.map(\.identifier)).count, titles.count)
        return tasks
    }

    private func verifyRows(_ tasks: [OriginalTask], plan: String, in app: XCUIApplication) throws {
        for task in tasks {
            let row = try reachable(app.buttons.matching(identifier: task.identifier), surface: .library, in: app)
            XCTAssertEqual(row.identifier, task.identifier)
            XCTAssertEqual(row.label, task.title, "원문 제목을 보존한다.")
            try waitValue(plan, element: row)
            XCTAssertEqual(textValue(row), plan, "날짜 배치만 바뀌며 미완료 상태를 유지한다.")
        }
    }

    private func beginSelection(_ selected: [OriginalTask], control: OriginalTask?, in app: XCUIApplication) throws {
        try activate("library.selectToggle", surface: .library, in: app)
        for task in selected {
            let id = "task.select.\(task.uuid)"
            let choice = try reachable(app.buttons.matching(identifier: id), surface: .library, in: app)
            XCTAssertEqual(choice.label, "\(task.title), 배치 대상 선택")
            XCTAssertEqual(textValue(choice), "선택 안 됨")
            try assertMobileTarget(choice)
            performActivation(choice)
            try waitValue("선택됨", element: choice)
        }
        if let control {
            let choice = try reachable(app.buttons.matching(identifier: "task.select.\(control.uuid)"), surface: .library, in: app)
            XCTAssertEqual(choice.label, "\(control.title), 배치 대상 선택")
            XCTAssertEqual(textValue(choice), "선택 안 됨")
        }
        let batch = try reachable(app.buttons.matching(identifier: "library.batchPlan"), surface: .library,
                                  missingTowardTop: true, in: app)
        XCTAssertEqual(batch.label, "선택한 \(selected.count)개 날짜 배치")
        XCTAssertTrue(batch.isEnabled)
    }

    private func verifyPicker(_ selected: [OriginalTask], in app: XCUIApplication) throws {
        try activate("library.batchPlan", surface: .library, in: app)
        _ = try unique(app.buttons.matching(identifier: "plan.cancel"))
        let disclosure = try plannerDisclosure(in: app)
        XCTAssertEqual(disclosure.label, "선택한 작업 \(selected.count)개")
        XCTAssertEqual(textValue(disclosure), "접힘", "여러 제목을 처음에는 접어 빠른 날짜를 먼저 보여 준다.")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "plan.calendar").firstMatch.exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.task.")).count, 0)
        for id in ["plan.today", "plan.tomorrow"] {
            let quick = try reachable(app.buttons.matching(identifier: id), surface: .planner, in: app)
            try assertMobileTarget(quick)
            XCTAssertTrue(quick.isEnabled)
        }
        try assertReachable(disclosure, in: app)
        performActivation(disclosure)
        try waitValue("펼쳐짐", element: disclosure)
        for task in selected {
            let title = try reachable(app.staticTexts.matching(identifier: "plan.task.\(task.uuid)"), surface: .planner, in: app)
            XCTAssertEqual(title.label, task.title)
        }
        let folded = try plannerDisclosure(in: app)
        try assertReachable(folded, in: app)
        performActivation(folded)
        try waitValue("접힘", element: folded)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.task.")).count, 0)
    }

    private func plannerDisclosure(in app: XCUIApplication) throws -> XCUIElement {
        #if os(macOS)
        let triangles = app.descendants(matching: .disclosureTriangle).matching(identifier: "plan.tasksDisclosure")
        if triangles.firstMatch.exists {
            return try reachable(triangles, surface: .planner, missingTowardTop: true, in: app)
        }
        #endif
        return try reachable(app.buttons.matching(identifier: "plan.tasksDisclosure"), surface: .planner,
                             missingTowardTop: true, in: app)
    }

    private func activate(_ identifier: String, surface: Surface = .none, in app: XCUIApplication) throws {
        let control = try reachable(app.buttons.matching(identifier: identifier), surface: surface,
                                    missingTowardTop: identifier.hasPrefix("library."), in: app)
        try assertMobileTarget(control)
        performActivation(control)
    }

    private func performActivation(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func unique(_ query: XCUIElementQuery, timeout: TimeInterval = 15) throws -> XCUIElement {
        guard query.firstMatch.waitForExistence(timeout: timeout), query.count == 1 else {
            XCTFail("batchRequiredElementIsNotUnique")
            throw HarnessFailure.missing
        }
        return query.firstMatch
    }

    private func reachable(_ query: XCUIElementQuery, surface: Surface, missingTowardTop: Bool = false,
                           in app: XCUIApplication) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(15)
        if surface == .none {
            _ = try unique(query, timeout: max(0, deadline.timeIntervalSinceNow))
        }
        for _ in 0..<12 {
            XCTAssertEqual(app.state, .runningForeground)
            if query.firstMatch.exists {
                let element = try unique(query, timeout: 0)
                let frame = element.frame
                let windows = app.windows.containing(NSPredicate(format: "identifier == %@", element.identifier))
                    .allElementsBoundByAccessibilityElement.filter { $0.exists && hasArea($0.frame) && $0.frame.contains(frame) }
                if hasArea(frame), windows.count == 1, element.isHittable, element.isEnabled {
                    if surface == .none { return element }
                    let owner = try scrollOwner(surface, in: app)
                    if owner.frame.contains(frame) { return element }
                }
            }
            guard Date() < deadline, surface != .none else { break }
            let owner = try scrollOwner(surface, in: app)
            let towardTop: Bool
            if query.firstMatch.exists, hasArea(query.firstMatch.frame) {
                towardTop = query.firstMatch.frame.minY < owner.frame.minY
            } else { towardTop = missingTowardTop }
            #if os(macOS)
            owner.scroll(byDeltaX: 0, deltaY: towardTop ? 180 : -180)
            #else
            if towardTop { owner.swipeDown() } else { owner.swipeUp() }
            #endif
        }
        XCTFail("batchTargetIsNotReachableWithin15SecondsAnd12Scrolls")
        throw HarnessFailure.unreachable
    }

    private func scrollOwner(_ surface: Surface, in app: XCUIApplication) throws -> XCUIElement {
        let surfaces = app.scrollViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
            + app.collectionViews.allElementsBoundByIndex
        let predicate: NSPredicate
        switch surface {
        case .library:
            predicate = NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", "library.search", "task.row.")
        case .planner:
            predicate = NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", "plan.tasksDisclosure", "plan.task.")
        case .none:
            XCTFail("batchScrollOwnerRequiresActualSurface")
            throw HarnessFailure.missing
        }
        let owners = surfaces.filter { owner in
            owner.exists && owner.isHittable && hasArea(owner.frame)
                && owner.descendants(matching: .any).matching(predicate).firstMatch.exists
        }.sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let owner = owners.first else {
            XCTFail("batchActualScrollOwnerMissing")
            throw HarnessFailure.missing
        }
        if owners.count > 1 {
            let firstArea = owner.frame.width * owner.frame.height
            let secondArea = owners[1].frame.width * owners[1].frame.height
            guard firstArea < secondArea else {
                XCTFail("batchActualScrollOwnerAmbiguous")
                throw HarnessFailure.ambiguous
            }
        }
        return owner
    }

    private func assertReachable(_ element: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(element.exists && element.isEnabled && element.isHittable)
        let frame = element.frame
        XCTAssertTrue(hasArea(frame))
        let owners = app.windows.containing(NSPredicate(format: "identifier == %@", element.identifier)).allElementsBoundByAccessibilityElement
        XCTAssertEqual(owners.count, 1)
        let window = try XCTUnwrap(owners.first)
        XCTAssertTrue(window.frame.contains(frame))
    }

    private func assertMobileTarget(_ element: XCUIElement) throws {
        #if os(iOS)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44)
        #endif
    }

    private func hasArea(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
            && frame.width > 0 && frame.height > 0
    }

    private func textValue(_ element: XCUIElement) -> String {
        let value = element.value as? String ?? ""
        return value == element.placeholderValue ? "" : value
    }

    private func waitValue(_ value: String, element: XCUIElement) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            let actual = element.value as? String ?? ""
            let normalized = actual == element.placeholderValue ? "" : actual
            return normalized == value
        }, object: element)
        try requireCompleted(expectation)
    }

    private func gone(_ identifier: String, in app: XCUIApplication) throws {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        try requireCompleted(XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element))
    }

    private func requireCompleted(_ expectation: XCTestExpectation) throws {
        guard XCTWaiter.wait(for: [expectation], timeout: 15) == .completed else {
            XCTFail("batchExpectedUIStateDidNotCompleteWithin15Seconds")
            throw HarnessFailure.wrongValue
        }
    }

    #if os(iOS)
    private func dismissKeyboardIntroduction(in app: XCUIApplication) throws {
        let prompt = NSPredicate(format: "label == %@", "Speed up your typing by sliding your finger across the letters to compose a word.")
        let text = app.staticTexts.matching(prompt).firstMatch
        if text.exists {
            let next = try unique(app.buttons.matching(NSPredicate(format: "label == %@", "Continue")))
            let owners = app.windows.containing(prompt).containing(NSPredicate(format: "label == %@", "Continue"))
            XCTAssertEqual(owners.count, 1)
            XCTAssertTrue(owners.firstMatch.frame.contains(next.frame))
            XCTAssertTrue(next.isHittable && next.isEnabled)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            next.tap()
            try requireCompleted(XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: text))
        }
        XCTAssertTrue(app.keyboards.firstMatch.keys.firstMatch.waitForExistence(timeout: 15))
    }
    #endif
}
