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
    private enum ReachableTarget: String {
        case unknown, captureOpen, captureSave, captureClose, destinationToday, destinationLibrary
        case librarySearch, librarySelectToggle, librarySelectAll, taskRow, taskSelection
        case planToday, planTomorrow, planCancel, planDisclosure, planTask
    }
    private enum HarnessFailure: Error { case missing, ambiguous, unreachable, wrongValue }
    private enum ProgressCase: String {
        case two = "testTwoTaskBatchKeepsUnselectedTaskAndOriginalContent"
        case twenty = "testTwentyTaskBatchKeepsEveryOriginalAndUsesTomorrow"
        var captureCount: Int { self == .two ? 3 : 20 }
    }
    private enum ProgressPhase: String {
        case started, launched, captureStarted, captureSaveRequested, captureSaved, captureComplete
        case libraryStarted, libraryVerified, bulkSelectionStarted, bulkSelectionVerified
        case selectionStarted, selectionVerified, libraryReturnStarted, libraryReturnVerified
        case pickerStarted, pickerVerified, cancelStarted, cancelVerified
        case todayCommitStarted, todayCommitVerified, tomorrowCommitStarted, tomorrowCommitVerified, complete
    }
    private var progressCase: ProgressCase?
    private var progressSequence = 0
    private let unassigned = "미완료, 배치: 아직 정하지 않음"
    private let today = "미완료, 배치: 9월 30일 수요일에 하기"
    private let tomorrow = "미완료, 배치: 10월 1일 목요일에 하기"

    func testTwoTaskBatchKeepsUnselectedTaskAndOriginalContent() throws {
        beginProgress(.two)
        let app = try launchApp()
        defer { app.terminate() }
        progress(.launched)
        let titles = ["UI batch two alpha original title", "UI batch two beta original title",
                      "UI batch two control stays unassigned"]
        try captureConsecutively(titles, in: app)
        progress(.libraryStarted)
        try showLibrary(search: "UI batch two", in: app)
        let originals = try originalTasks(titles, in: app)
        try verifyRows(originals, plan: unassigned, in: app)
        progress(.libraryVerified)
        let selected = Array(originals.prefix(2))
        let control = originals[2]
        try beginSelection(selected, control: control, in: app)
        progress(.libraryReturnStarted)
        try selectDestination("오늘", identifier: "destination.today", in: app)
        try selectDestination("보관함", identifier: "destination.library", in: app)
        XCTAssertEqual(textValue(try unique(app.textFields.matching(identifier: "library.search"))), "UI batch two")
        try verifyRows(selected, plan: unassigned, selection: "선택됨", in: app)
        try verifyRows([control], plan: unassigned, selection: "선택 안 됨", in: app)
        XCTAssertEqual(try reachableBatchFooter(in: app).label, "선택한 2개 날짜 배치",
                       "같은 창의 화면을 다시 구성해도 일괄 대상을 유지한다.")
        progress(.libraryReturnVerified)
        try verifyPicker(selected, in: app)
        progress(.cancelStarted)
        // 취소는 iOS 고정 헤더와 Mac 툴바에 있으므로 실제 앱 창을 기준으로 도달 가능성을 확인한다.
        try activate("plan.cancel", in: app)
        try gone("plan.cancel", in: app)
        try verifyRows(selected, plan: unassigned, selection: "선택됨", in: app)
        try verifyRows([control], plan: unassigned, selection: "선택 안 됨", in: app)
        progress(.cancelVerified)
        try verifyPicker(selected, in: app)
        progress(.todayCommitStarted)
        try activate("plan.today", surface: .planner, in: app)
        try gone("plan.cancel", in: app)
        try verifyRows(selected, plan: today, in: app)
        try verifyRows([control], plan: unassigned, in: app)
        try gone("library.batchPlan", in: app)
        progress(.todayCommitVerified)
        try beginSelection(selected, control: control, in: app)
        try verifyPicker(selected, in: app)
        progress(.tomorrowCommitStarted)
        try activate("plan.tomorrow", surface: .planner, in: app)
        try gone("plan.cancel", in: app)
        try verifyRows(selected, plan: tomorrow, in: app)
        try verifyRows([control], plan: unassigned, in: app)
        try gone("library.batchPlan", in: app)
        progress(.tomorrowCommitVerified)
        progress(.complete)
    }

    func testTwentyTaskBatchKeepsEveryOriginalAndUsesTomorrow() throws {
        beginProgress(.twenty)
        let app = try launchApp()
        defer { app.terminate() }
        progress(.launched)
        let titles = (1...20).map { String(format: "UI batch twenty task %02d original title", $0) }
        try captureConsecutively(titles, in: app)
        progress(.libraryStarted)
        try showLibrary(search: "UI batch twenty", in: app)
        let originals = try originalTasks(titles, in: app)
        XCTAssertEqual(originals.count, 20)
        try verifyRows(originals, plan: unassigned, in: app)
        progress(.libraryVerified)
        try verifyBulkSelection(originals, in: app)
        try beginSelection(originals, control: nil, in: app)
        try verifyPicker(originals, in: app)
        progress(.tomorrowCommitStarted)
        try activate("plan.tomorrow", surface: .planner, in: app)
        try gone("plan.cancel", in: app)
        try verifyRows(originals, plan: tomorrow, in: app)
        try gone("library.batchPlan", in: app)
        XCTAssertEqual(Set(originals.map(\.identifier)).count, 20)
        progress(.tomorrowCommitVerified)
        progress(.complete)
    }

    private func beginProgress(_ value: ProgressCase) {
        progressCase = value; progressSequence = 0
        progress(.started)
    }

    private func progress(_ phase: ProgressPhase, ordinal: Int = 0) {
        guard let progressCase, (0...progressCase.captureCount).contains(ordinal), progressSequence < 96 else { return }
        progressSequence += 1
        // 사용자 값과 AX 조회 없이 고정 경계만 한 번 쓴다. 중단되어도 print 버퍼에 남기지 않는다.
        let line = "Batch UI progress: {\"method\":\"\(progressCase.rawValue)\",\"phase\":\"\(phase.rawValue)\",\"sequence\":\(progressSequence),\"captureOrdinal\":\(ordinal)}\n"
        let data = Data(line.utf8)
        guard data.count <= 512 else { return }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private func launchApp() throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MIRROR_UI_TESTING"] = "1"
        app.launchEnvironment["MIRROR_TEST_DATE"] = "2026-09-30T03:00:00Z"
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        // 앱의 기존 UI 검증 경로가 launch마다 새 실제 임시 canonical store를 연다.
        app.launch()
        do {
            _ = try unique(app.descendants(matching: .any).matching(identifier: "today.list"), timeout: 30)
            _ = try unique(app.buttons.matching(identifier: "capture.open"))
            return app
        } catch {
            app.terminate()
            throw error
        }
    }

    private func captureConsecutively(_ titles: [String], in app: XCUIApplication) throws {
        try activate("capture.open", in: app)
        for (index, title) in titles.enumerated() {
            progress(.captureStarted, ordinal: index + 1)
            #if os(macOS)
            let field = try requireMacCaptureTitle(in: app)
            #else
            let fields = app.textFields.matching(identifier: "capture.title")
            let textViews = app.textViews.matching(identifier: "capture.title")
            let query = fields.firstMatch.exists ? fields
                : textViews.firstMatch.exists ? textViews
                : app.descendants(matching: .any).matching(identifier: "capture.title")
            let field = try unique(query)
            #endif
            try waitValue("", element: field)
            try assertReachable(field, in: app)
            performActivation(field)
            #if os(iOS)
            try dismissKeyboardIntroduction(in: app)
            #endif
            field.typeText(title)
            try waitValue(title, element: field)
            try gone("capture.feedback", in: app)
            progress(.captureSaveRequested, ordinal: index + 1)
            try activate("capture.save", in: app)
            try waitValue("", element: field)
            let feedback = try unique(app.staticTexts.matching(identifier: "capture.feedback"))
            XCTAssertEqual(feedback.label, "보관함에 넣었어요.")
            XCTAssertTrue(feedback.isHittable)
            progress(.captureSaved, ordinal: index + 1)
        }
        try activate("capture.close", in: app)
        try gone("capture.title", in: app)
        progress(.captureComplete)
    }

    #if os(macOS)
    // 실제 입력 owner의 native 역할만 받는다. snapshot 오류의 원인이나 해결을 확정하지 않는다.
    private func requireMacCaptureTitle(in app: XCUIApplication, timeout: TimeInterval = 15,
                                        file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(min(15, max(0, timeout)))
        let closeQuery = app.buttons.matching(identifier: "capture.close")
        let saveQuery = app.buttons.matching(identifier: "capture.save")
        func hasArea(_ frame: CGRect) -> Bool {
            [frame.minX, frame.minY, frame.maxX, frame.maxY, frame.width, frame.height].allSatisfy { $0.isFinite }
                && frame.width > 0 && frame.height > 0
        }
        for attempt in 0..<12 {
            guard app.state == .runningForeground, Date() < deadline else { break }
            guard closeQuery.element(boundBy: 0).waitForExistence(timeout: max(0, deadline.timeIntervalSinceNow)),
                  app.state == .runningForeground, Date() < deadline else { break }
            guard saveQuery.element(boundBy: 0).waitForExistence(timeout: max(0, deadline.timeIntervalSinceNow)),
                  app.state == .runningForeground, Date() < deadline else { break }
            let closeCount = closeQuery.count
            let saveCount = saveQuery.count
            guard closeCount <= 1, saveCount <= 1 else { break }
            if closeCount == 1, saveCount == 1 {
                let windows = app.windows.containing(.button, identifier: "capture.close")
                    .containing(.button, identifier: "capture.save")
                let windowCount = windows.count
                guard windowCount <= 1 else { break }
                if windowCount == 1 {
                    let window = windows.element(boundBy: 0)
                    let sheets = window.sheets.containing(.button, identifier: "capture.close")
                        .containing(.button, identifier: "capture.save")
                    let sheetCount = sheets.count
                    guard sheetCount <= 1 else { break }
                    let owner = sheetCount == 1 ? sheets.element(boundBy: 0) : window
                    let ownerCloseCount = owner.buttons.matching(identifier: "capture.close").count
                    let ownerSaveCount = owner.buttons.matching(identifier: "capture.save").count
                    guard ownerCloseCount <= 1, ownerSaveCount <= 1 else { break }
                    if ownerCloseCount == 1, ownerSaveCount == 1 {
                        let fields = owner.textFields.matching(identifier: "capture.title")
                        let textViews = owner.textViews.matching(identifier: "capture.title")
                        let fieldCount = fields.count
                        let textViewCount = textViews.count
                        guard fieldCount + textViewCount <= 1 else { break }
                        if fieldCount + textViewCount == 1 {
                            let field = fieldCount == 1 ? fields.element(boundBy: 0) : textViews.element(boundBy: 0)
                            if window.exists, owner.exists, field.exists {
                                let windowFrame = window.frame
                                let ownerFrame = owner.frame
                                let fieldFrame = field.frame
                                if hasArea(windowFrame), hasArea(ownerFrame), hasArea(fieldFrame),
                                   windowFrame.contains(ownerFrame), windowFrame.contains(fieldFrame),
                                   ownerFrame.contains(fieldFrame),
                                   field.elementType == .textField || field.elementType == .textView,
                                   field.isEnabled, field.isHittable {
                                    guard app.state == .runningForeground, Date() < deadline else { break }
                                    return field
                                }
                            }
                        }
                    }
                }
            }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            guard remaining > 0 else { break }
            RunLoop.current.run(until: min(Date().addingTimeInterval(remaining / Double(12 - attempt)), deadline))
        }
        XCTFail("macCaptureTitleNativeOwnerContractFailedWithin15SecondsAnd12Checks", file: file, line: line)
        throw HarnessFailure.unreachable
    }
    #endif

    private func showLibrary(search: String, in app: XCUIApplication) throws {
        try selectDestination("보관함", identifier: "destination.library", in: app)
        let field = try reachable(app.textFields.matching(identifier: "library.search"), surface: .library,
                                  missingTowardTop: true, target: .librarySearch, in: app)
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

    private func selectDestination(_ title: String, identifier: String, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let tabs = app.tabBars.buttons.matching(NSPredicate(format: "label == %@", title))
        if tabs.firstMatch.exists {
            let tab = try unique(tabs)
            try assertReachable(tab, in: app)
            performActivation(tab)
        } else { try activate(identifier, in: app, file: file, line: line) }
    }

    private func originalTasks(_ titles: [String], in app: XCUIApplication) throws -> [OriginalTask] {
        let tasks = try titles.map { title in
            let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task.row.", title))
            let row = try reachable(query, surface: .library, target: .taskRow, in: app)
            let identifier = row.identifier
            let uuid = String(identifier.dropFirst("task.row.".count))
            XCTAssertNotNil(UUID(uuidString: uuid))
            XCTAssertEqual(row.label, title)
            return OriginalTask(title: title, identifier: identifier)
        }
        XCTAssertEqual(Set(tasks.map(\.identifier)).count, titles.count)
        return tasks
    }

    private func verifyRows(_ tasks: [OriginalTask], plan: String, selection: String? = nil,
                            in app: XCUIApplication) throws {
        let expectedValue = selection.map { plan + ", " + $0 } ?? plan
        for task in tasks {
            let row = try reachable(app.buttons.matching(identifier: task.identifier), surface: .library, target: .taskRow, in: app)
            XCTAssertEqual(row.identifier, task.identifier)
            XCTAssertEqual(row.label, task.title, "원문 제목을 보존한다.")
            try waitValue(expectedValue, element: row)
            XCTAssertEqual(textValue(row), expectedValue, "날짜 배치만 바뀌며 미완료 상태를 유지한다.")
        }
    }

    private func verifyBulkSelection(_ originals: [OriginalTask], in app: XCUIApplication) throws {
        progress(.bulkSelectionStarted)
        XCTAssertFalse(app.buttons.matching(identifier: "library.selectAll").firstMatch.exists)
        try activate("library.selectToggle", surface: .library, in: app)
        let bulk = try reachable(app.buttons.matching(identifier: "library.selectAll"), surface: .library,
                                 missingTowardTop: true, target: .librarySelectAll, in: app)
        XCTAssertEqual(bulk.label, "모두 선택, 현재 목록")
        XCTAssertEqual(textValue(bulk), "선택한 0개, 대상 20개")
        try assertMobileTarget(bulk)
        performActivation(bulk)
        try waitValue("선택한 20개, 대상 20개", element: bulk)
        XCTAssertEqual(bulk.label, "선택 해제, 현재 목록")
        let batch = try reachableBatchFooter(in: app)
        XCTAssertEqual(batch.label, "선택한 20개 날짜 배치")
        XCTAssertTrue(batch.isEnabled)
        try verifySelectionState(originals, value: "선택됨", in: app)
        try verifyRows(originals, plan: unassigned, selection: "선택됨", in: app)

        let clear = try reachable(app.buttons.matching(identifier: "library.selectAll"), surface: .library,
                                  missingTowardTop: true, target: .librarySelectAll, in: app)
        XCTAssertEqual(clear.label, "선택 해제, 현재 목록")
        try assertMobileTarget(clear)
        performActivation(clear)
        try waitValue("선택한 0개, 대상 20개", element: clear)
        XCTAssertEqual(clear.label, "모두 선택, 현재 목록")
        let clearedBatch = try unique(app.buttons.matching(identifier: "library.batchPlan"))
        XCTAssertEqual(clearedBatch.label, "선택한 0개 날짜 배치")
        XCTAssertFalse(clearedBatch.isEnabled)
        try verifySelectionState(originals, value: "선택 안 됨", in: app)
        try verifyRows(originals, plan: unassigned, selection: "선택 안 됨", in: app)
        try activate("library.selectToggle", surface: .library, in: app)
        XCTAssertFalse(app.buttons.matching(identifier: "library.selectAll").firstMatch.exists)
        progress(.bulkSelectionVerified)
    }

    private func verifySelectionState(_ originals: [OriginalTask], value: String, in app: XCUIApplication) throws {
        for task in originals {
            let identifier = "task.select.\(task.uuid)"
            let choice = try reachable(app.buttons.matching(identifier: identifier), surface: .library, target: .taskSelection, in: app)
            XCTAssertEqual(choice.identifier, identifier)
            XCTAssertEqual(choice.label, "\(task.title), 배치 대상 선택")
            try waitValue(value, element: choice)
            XCTAssertEqual(textValue(choice), value)
        }
    }

    private func beginSelection(_ selected: [OriginalTask], control: OriginalTask?, in app: XCUIApplication) throws {
        progress(.selectionStarted)
        try activate("library.selectToggle", surface: .library, in: app)
        for task in selected {
            let id = "task.select.\(task.uuid)"
            let choice = try reachable(app.buttons.matching(identifier: id), surface: .library, target: .taskSelection, in: app)
            XCTAssertEqual(choice.label, "\(task.title), 배치 대상 선택")
            XCTAssertEqual(textValue(choice), "선택 안 됨")
            try assertMobileTarget(choice)
            performActivation(choice)
            try waitValue("선택됨", element: choice)
        }
        if let control {
            let choice = try reachable(app.buttons.matching(identifier: "task.select.\(control.uuid)"), surface: .library, target: .taskSelection, in: app)
            XCTAssertEqual(choice.label, "\(control.title), 배치 대상 선택")
            XCTAssertEqual(textValue(choice), "선택 안 됨")
        }
        let batch = try reachableBatchFooter(in: app)
        XCTAssertEqual(batch.label, "선택한 \(selected.count)개 날짜 배치")
        XCTAssertTrue(batch.isEnabled)
        try assertMobileTarget(batch)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task.postpone.")).count, 0,
                       "선택 모드에는 개별 미루기 버튼을 표시하지 않는다.")
        progress(.selectionVerified)
    }

    private func verifyPicker(_ selected: [OriginalTask], in app: XCUIApplication) throws {
        progress(.pickerStarted)
        performActivation(try reachableBatchFooter(in: app))
        _ = try unique(app.buttons.matching(identifier: "plan.cancel"))
        let disclosure = try plannerDisclosure(in: app)
        XCTAssertEqual(disclosure.label, "선택한 작업 \(selected.count)개")
        XCTAssertEqual(textValue(disclosure), "접힘", "여러 제목을 처음에는 접어 빠른 날짜를 먼저 보여 준다.")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "plan.calendar").firstMatch.exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.task.")).count, 0)
        for id in ["plan.today", "plan.tomorrow"] {
            let quick = try reachable(app.buttons.matching(identifier: id), surface: .planner,
                                      target: id == "plan.today" ? .planToday : .planTomorrow, in: app)
            try assertMobileTarget(quick)
            XCTAssertTrue(quick.isEnabled)
        }
        try assertReachable(disclosure, in: app)
        performActivation(disclosure)
        try waitValue("펼쳐짐", element: disclosure)
        for task in selected {
            let title = try reachable(app.staticTexts.matching(identifier: "plan.task.\(task.uuid)"), surface: .planner, target: .planTask, in: app)
            XCTAssertEqual(title.label, task.title)
        }
        let folded = try plannerDisclosure(in: app)
        try assertReachable(folded, in: app)
        performActivation(folded)
        try waitValue("접힘", element: folded)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan.task.")).count, 0)
        progress(.pickerVerified)
    }

    private func plannerDisclosure(in app: XCUIApplication) throws -> XCUIElement {
        #if os(macOS)
        let triangles = app.descendants(matching: .disclosureTriangle).matching(identifier: "plan.tasksDisclosure")
        if triangles.firstMatch.exists {
            return try reachable(triangles, surface: .planner, missingTowardTop: true, target: .planDisclosure, in: app)
        }
        #endif
        return try reachable(app.buttons.matching(identifier: "plan.tasksDisclosure"), surface: .planner,
                             missingTowardTop: true, target: .planDisclosure, in: app)
    }

    private func reachableBatchFooter(in app: XCUIApplication) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(15)
        let footerQuery = app.descendants(matching: .any).matching(identifier: "library.batchFooter")
        let buttonQuery = app.buttons.matching(identifier: "library.batchPlan")
        for attempt in 0..<12 {
            XCTAssertEqual(app.state, .runningForeground)
            guard Date() < deadline else { break }
            _ = footerQuery.firstMatch.waitForExistence(timeout: max(0, deadline.timeIntervalSinceNow))
            _ = buttonQuery.firstMatch.waitForExistence(timeout: max(0, deadline.timeIntervalSinceNow))
            guard Date() < deadline else { break }
            if footerQuery.firstMatch.exists, buttonQuery.firstMatch.exists {
                let footer = try unique(footerQuery, timeout: 0)
                let button = try unique(buttonQuery, timeout: 0)
                _ = try unique(footer.buttons.matching(identifier: "library.batchPlan"), timeout: 0)
                let footerFrame = footer.frame
                let buttonFrame = button.frame
                let windows = app.windows.containing(NSPredicate(format: "identifier == %@", "library.batchFooter"))
                    .containing(NSPredicate(format: "identifier == %@", "library.batchPlan"))
                    .allElementsBoundByAccessibilityElement.filter {
                        $0.exists && hasArea($0.frame) && $0.frame.contains(footerFrame) && $0.frame.contains(buttonFrame)
                    }
                if Date() < deadline, hasArea(footerFrame), hasArea(buttonFrame), windows.count == 1,
                   footerFrame.contains(buttonFrame), button.isEnabled, button.isHittable {
                    try assertMobileTarget(button)
                    guard Date() < deadline else { break }
                    return button
                }
            }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            guard remaining > 0 else { break }
            RunLoop.current.run(until: min(Date().addingTimeInterval(remaining / Double(12 - attempt)), deadline))
        }
        XCTFail("batchFooterIsNotReachableWithin15SecondsAnd12Checks")
        throw HarnessFailure.unreachable
    }

    private func activate(_ identifier: String, surface: Surface = .none, in app: XCUIApplication,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let target: ReachableTarget
        switch identifier {
        case "capture.open": target = .captureOpen
        case "capture.save": target = .captureSave
        case "capture.close": target = .captureClose
        case "destination.today": target = .destinationToday
        case "destination.library": target = .destinationLibrary
        case "library.selectToggle": target = .librarySelectToggle
        case "library.selectAll": target = .librarySelectAll
        case "plan.today": target = .planToday
        case "plan.tomorrow": target = .planTomorrow
        case "plan.cancel": target = .planCancel
        default: target = .unknown
        }
        let control = try reachable(app.buttons.matching(identifier: identifier), surface: surface,
                                    missingTowardTop: identifier.hasPrefix("library."), target: target,
                                    in: app, file: file, line: line)
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
                           target: ReachableTarget = .unknown, in app: XCUIApplication,
                           file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(15)
        if surface == .none {
            _ = try unique(query, timeout: max(0, deadline.timeIntervalSinceNow))
        }
        for _ in 0..<12 {
            XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
            if query.firstMatch.exists {
                let element = try unique(query, timeout: 0)
                let frame = element.frame
                let windows = app.windows.containing(NSPredicate(format: "identifier == %@", element.identifier))
                    .allElementsBoundByAccessibilityElement.filter { $0.exists && hasArea($0.frame) && $0.frame.contains(frame) }
                if hasArea(frame), windows.count == 1, element.isHittable, element.isEnabled {
                    if surface == .none { return element }
                    let owner = try scrollOwner(surface, in: app, target: target, file: file, line: line)
                    if owner.frame.contains(frame) { return element }
                }
            }
            guard Date() < deadline, surface != .none else { break }
            let owner = try scrollOwner(surface, in: app, target: target, file: file, line: line)
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
        // 대상은 호출부의 고정 enum이다. 실제 identifier·제목·AX 값은 기록하지 않는다.
        XCTFail("batchTargetIsNotReachableWithin15SecondsAnd12Scrolls target=\(target.rawValue)", file: file, line: line)
        throw HarnessFailure.unreachable
    }

    private func scrollOwner(_ surface: Surface, in app: XCUIApplication, target: ReachableTarget,
                             file: StaticString, line: UInt) throws -> XCUIElement {
        let surfaces = app.scrollViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
            + app.collectionViews.allElementsBoundByIndex
        let predicate: NSPredicate
        switch surface {
        case .library:
            predicate = NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", "library.search", "task.row.")
        case .planner:
            predicate = NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", "plan.tasksDisclosure", "plan.task.")
        case .none:
            XCTFail("batchScrollOwnerRequiresActualSurface target=\(target.rawValue)", file: file, line: line)
            throw HarnessFailure.missing
        }
        let owners = surfaces.filter { owner in
            owner.exists && owner.isHittable && hasArea(owner.frame)
                && owner.descendants(matching: .any).matching(predicate).firstMatch.exists
        }.sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let owner = owners.first else {
            XCTFail("batchActualScrollOwnerMissing target=\(target.rawValue)", file: file, line: line)
            throw HarnessFailure.missing
        }
        if owners.count > 1 {
            let firstArea = owner.frame.width * owner.frame.height
            let secondArea = owners[1].frame.width * owners[1].frame.height
            guard firstArea < secondArea else {
                XCTFail("batchActualScrollOwnerAmbiguous target=\(target.rawValue)", file: file, line: line)
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

    private func mobileTargetCode(_ identifier: String) -> String {
        switch identifier {
        case "capture.open": return "captureOpen"
        case "capture.save": return "captureSave"
        case "capture.close": return "captureClose"
        case "library.selectToggle": return "librarySelectToggle"
        case "library.selectAll": return "librarySelectAll"
        case "library.batchPlan": return "libraryBatchPlan"
        case "plan.today": return "planToday"
        case "plan.tomorrow": return "planTomorrow"
        case "plan.cancel": return "planCancel"
        case "destination.today": return "destinationToday"
        case "destination.calendar": return "destinationCalendar"
        case "destination.library": return "destinationLibrary"
        default:
            let prefix = "task.select."
            guard identifier.hasPrefix(prefix) else { return "other" }
            let suffix = String(identifier.dropFirst(prefix.count))
            guard let uuid = UUID(uuidString: suffix), uuid.uuidString.lowercased() == suffix.lowercased() else { return "other" }
            return "taskSelection"
        }
    }

    private func assertMobileTarget(_ element: XCUIElement) throws {
        #if os(iOS)
        let target = mobileTargetCode(element.identifier)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, "Batch UI mobile target: width \(target)")
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "Batch UI mobile target: height \(target)")
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

    private func waitValue(_ value: String, element: XCUIElement,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            let actual = element.value as? String ?? ""
            let normalized = actual == element.placeholderValue ? "" : actual
            return normalized == value
        }, object: element)
        try requireCompleted(expectation, file: file, line: line)
    }

    private func gone(_ identifier: String, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        try requireCompleted(XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element),
                             file: file, line: line)
    }

    private func requireCompleted(_ expectation: XCTestExpectation,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        guard XCTWaiter.wait(for: [expectation], timeout: 15) == .completed else {
            XCTFail("batchExpectedUIStateDidNotCompleteWithin15Seconds", file: file, line: line)
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
