import XCTest

/// 실제 UI 입력과 앱의 Core Data 저장 경로를 사용한다. 테스트 전용 성공 응답이나 seed는 없다.
/// 같은 소스를 iPhone, iPad, Mac UI scheme에서 실행한다.
final class MirrorUITests: XCTestCase {
    @MainActor
    func testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday() throws {
        let app = try launchApp()
        let title = "UI capture then today"
        try capture(title, in: app)

        try showToday(in: app)
        XCTAssertFalse(taskRow(title, in: app).exists, "Q-001: 미검토 항목은 Today에 들어가지 않는다.")
        try showLibrary(in: app)
        let unassigned = try requireRow(title, in: app)
        XCTAssertTrue(value(of: unassigned).contains("아직 정하지 않음"))
        XCTAssertTrue(value(of: unassigned).contains("미완료"))

        try showToday(in: app)
        try activate("today.review", in: app)
        let card = try requireElement("review.card", in: app)
        XCTAssertEqual(card.label, title)
        try activate("review.today", in: app)
        try requireNoElement("review.card", in: app)
        try activate("review.finish", in: app)
        _ = try requireElement("today.list", in: app)

        let today = try requireRow(title, in: app)
        XCTAssertTrue(value(of: today).contains("9월 30일"))
        XCTAssertTrue(value(of: today).contains("미완료"), "Q-009: 오늘 배치는 완료가 아니다.")
    }

    @MainActor
    func testTomorrowStaysOutOfTodayAndIsSearchableInLibrary() throws {
        let app = try launchApp()
        let title = "UI tomorrow is searchable"
        try capture(title, in: app)
        try activate("today.review", in: app)
        XCTAssertEqual(try requireElement("review.card", in: app).label, title)
        try activate("review.tomorrow", in: app)
        try requireNoElement("review.card", in: app)
        try activate("review.finish", in: app)
        _ = try requireElement("today.list", in: app)
        XCTAssertFalse(taskRow(title, in: app).exists)

        try showLibrary(in: app)
        let search = try requireElement("library.search", in: app)
        try replaceText(in: search, with: "tomorrow is searchable", app: app)
        let future = try requireRow(title, in: app)
        XCTAssertTrue(value(of: future).contains("10월 1일"), "Q-010: 서울 9월 30일의 내일은 10월 1일이다.")
        XCTAssertTrue(value(of: future).contains("미완료"))
        try interact(with: future, in: app)
        XCTAssertTrue(try requireElement("detail.plan", in: app).label.contains("10월 1일"))
        try activate("detail.close", in: app)
        try showToday(in: app)
        XCTAssertFalse(taskRow(title, in: app).exists, "검색은 미래 계획을 Today로 바꾸지 않는다.")
    }

    @MainActor
    func testOverlongTitleShowsErrorAndPreservesEveryCharacter() throws {
        let app = try launchApp()
        try activate("capture.open", in: app)
        let field = try requireElement("capture.title", in: app)
        // ASCII도 확장 문자소 하나당 하나다. 501자를 실제 키보드 입력으로 제출한다.
        let original = String(repeating: "x", count: 500) + "Z"
        try replaceText(in: field, with: original, app: app)
        XCTAssertEqual(value(of: field), original)
        try activate("capture.save", in: app)
        let problem = try requireElement("state.error", in: app)
        try waitForLabelContaining("500", element: problem)
        XCTAssertEqual(value(of: field), original, "Q-003: 잘라 저장하거나 입력 원문을 지우면 안 된다.")

        try activate("capture.close", in: app)
        try showLibrary(in: app)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "task.row.")).count, 0)

        // 오류 뒤 정상 입력도 실제 원본 저장 경로로 복구되어야 한다.
        try capture("UI corrected after validation", in: app)
        try showLibrary(in: app)
        XCTAssertTrue(value(of: try requireRow("UI corrected after validation", in: app)).contains("아직 정하지 않음"))
    }

    @MainActor
    func testWeekPanelCancellationAndPartialFinishPreserveUndecidedPlan() throws {
        let app = try launchApp()
        let titles = ["UI partial alpha", "UI partial beta"]
        for title in titles { try capture(title, in: app) }
        try activate("today.review", in: app)
        let decidedTitle = try requireElement("review.card", in: app).label
        XCTAssertTrue(titles.contains(decidedTitle))
        let remainingTitle = try XCTUnwrap(titles.first { $0 != decidedTitle })

        try activate("review.today", in: app)
        try waitForLabel(remainingTitle, element: requireElement("review.card", in: app))
        try activate("review.nextWeek", in: app)
        _ = try requireElement("plan.day.2026-10-05", in: app)
        try activate("plan.cancel", in: app)
        try waitForLabel(remainingTitle, element: requireElement("review.card", in: app))
        try activate("review.finish", in: app)
        _ = try requireElement("today.list", in: app)

        _ = try requireRow(decidedTitle, in: app)
        XCTAssertFalse(taskRow(remainingTitle, in: app).exists, "Q-019: 부분 정리 종료는 미검토를 Today에 합치지 않는다.")
        try showLibrary(in: app)
        let remaining = try requireRow(remainingTitle, in: app)
        XCTAssertTrue(value(of: remaining).contains("아직 정하지 않음"), "Q-016: 주 패널 취소는 계획을 바꾸지 않는다.")
        try interact(with: remaining, in: app)
        XCTAssertEqual(try requireElement("detail.plan", in: app).label, "아직 정하지 않음")
    }

    @MainActor
    func testExplicitCompletionAndUndoPreserveEditedTitleAndPlan() throws {
        let app = try launchApp()
        let original = "UI edit before completion"
        let edited = "UI edited title survives undo"
        try capture(original, in: app)
        try activate("today.review", in: app)
        try activate("review.today", in: app)
        try requireNoElement("review.card", in: app)
        try activate("review.finish", in: app)
        try interact(with: requireRow(original, in: app), in: app)

        try activate("detail.edit", in: app)
        let field = try requireElement("detail.title", in: app)
        try replaceText(in: field, with: edited, app: app)
        try activate("detail.save", in: app)
        try waitForLabel(edited, element: requireElement("detail.contentTitle", in: app))
        XCTAssertTrue(try requireElement("detail.plan", in: app).label.contains("9월 30일"))

        try activate("task.complete", in: app)
        try waitForLabel("완료 취소 · 다시 열기", element: requireElement("task.complete", in: app))
        XCTAssertTrue(try requireElement("detail.plan", in: app).label.contains("9월 30일"), "완료는 계획을 지우지 않는다.")
        try activate("task.undo", in: app)
        try waitForLabel("완료", element: requireElement("task.complete", in: app))
        XCTAssertEqual(try requireElement("detail.contentTitle", in: app).label, edited)
        XCTAssertTrue(try requireElement("detail.plan", in: app).label.contains("9월 30일"))
        try activate("detail.close", in: app)
        try showToday(in: app)
        let reopened = try requireRow(edited, in: app)
        XCTAssertTrue(value(of: reopened).contains("미완료"))
        XCTAssertFalse(taskRow(original, in: app).exists)
    }

    @MainActor
    func testReviewUndoRestoresUnassignedCardInsteadOfAddingToToday() throws {
        let app = try launchApp()
        let title = "UI undo review destination"
        try capture(title, in: app)
        try activate("today.review", in: app)
        try activate("review.tomorrow", in: app)
        try requireNoElement("review.card", in: app)
        try activate("task.undo", in: app)
        try waitForLabel(title, element: requireElement("review.card", in: app))
        try activate("review.finish", in: app)
        _ = try requireElement("today.list", in: app)
        XCTAssertFalse(taskRow(title, in: app).exists)
        try showLibrary(in: app)
        XCTAssertTrue(value(of: try requireRow(title, in: app)).contains("아직 정하지 않음"), "Q-029: 직전 배치 Undo는 이전 계획을 복원한다.")
    }

    // XCTestCase 자체의 actor 격리를 바꾸거나 setUp override를 격리하지 않는다.
    // UI API를 사용하는 test/helper 메서드만 MainActor로 지정한다.
    @MainActor
    private func launchApp() throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MIRROR_UI_TESTING"] = "1"
        app.launchEnvironment["MIRROR_TEST_DATE"] = "2026-09-30T03:00:00Z"
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        // store 경로를 주입하지 않는다. 각 launch는 앱의 temporaryDirectory에 새 실제 store를 연다.
        app.launch()
        _ = try requireElement("today.list", in: app, timeout: 30)
        _ = try requireElement("capture.open", in: app)
        return app
    }

    @MainActor
    private func capture(_ title: String, in app: XCUIApplication) throws {
        try activate("capture.open", in: app)
        let field = try requireElement("capture.title", in: app)
        try replaceText(in: field, with: title, app: app)
        try activate("capture.save", in: app)
        try waitForValue("", element: field)
        try activate("capture.close", in: app)
        try requireNoElement("capture.title", in: app)
    }

    @MainActor
    private func showToday(in app: XCUIApplication) throws {
        try selectDestination("today", title: "오늘", in: app)
        _ = try requireElement("today.list", in: app)
    }

    @MainActor
    private func showLibrary(in app: XCUIApplication) throws {
        try selectDestination("library", title: "보관함", in: app)
        _ = try requireElement("library.search", in: app)
    }

    @MainActor
    private func selectDestination(_ id: String, title: String, in app: XCUIApplication) throws {
        // iPhone의 실제 탭 버튼과 iPad/Mac의 실제 사이드바 버튼을 각각 선택한다.
        // NavigationStack에 붙은 ID를 비활성 탭 버튼의 ID로 오인하지 않는다.
        let tab = app.tabBars.buttons[title]
        if tab.exists { try interact(with: tab, in: app) }
        else { try activate("destination.\(id)", in: app) }
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        // 오류/Undo가 modal과 상태 표시줄 양쪽에 있으면 실제 활성 modal 요소를 우선한다.
        let sheetMatches = app.sheets.firstMatch.descendants(matching: .any).matching(identifier: identifier)
        if sheetMatches.firstMatch.exists {
            return sheetMatches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? sheetMatches.firstMatch
        }
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        return matches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? matches.firstMatch
    }

    @MainActor
    private func requireElement(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 15,
                                file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        guard app.state != .notRunning else {
            XCTFail("앱 프로세스가 종료되어 필수 UI 요소를 조회할 수 없다: \(identifier). appState=\(app.state.rawValue)", file: file, line: line)
            throw UIHarnessError.applicationNotRunning
        }
        let found = element(identifier, in: app)
        guard found.waitForExistence(timeout: timeout) else {
            XCTFail("필수 UI 요소가 없다: \(identifier). \(diagnostics(in: app))", file: file, line: line)
            throw UIHarnessError.missingElement(identifier)
        }
        return found
    }

    @MainActor
    private func requireNoElement(_ identifier: String, in app: XCUIApplication) throws {
        let found = element(identifier, in: app)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: found)
        guard XCTWaiter.wait(for: [gone], timeout: 15) == .completed else {
            XCTFail("UI 요소가 닫히거나 다음 상태로 진행하지 않았다: \(identifier)")
            throw UIHarnessError.unexpectedElement(identifier)
        }
    }

    @MainActor
    private func taskRow(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "task.row.", title)).firstMatch
    }

    @MainActor
    private func requireRow(_ title: String, in app: XCUIApplication) throws -> XCUIElement {
        let row = taskRow(title, in: app)
        guard row.waitForExistence(timeout: 15) else {
            XCTFail("저장된 작업 행을 찾지 못했다: \(title)")
            throw UIHarnessError.missingElement(title)
        }
        return row
    }

    @MainActor
    private func activate(_ identifier: String, in app: XCUIApplication,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        try interact(with: requireElement(identifier, in: app, file: file, line: line), in: app, file: file, line: line)
    }

    @MainActor
    private func interact(with element: XCUIElement, in app: XCUIApplication,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        // 원본 저장·projection 갱신 직후에는 action의 enabled/hittable 반영도 기다린다.
        // 숨은 요소를 좌표로 누르거나 disabled 행동을 통과시키지 않는다.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: element)
        _ = XCTWaiter.wait(for: [ready], timeout: 3)
        // Form 아래쪽의 완료/Undo도 실제 스크롤로 도달한다. 숨겨진 요소의 좌표를 강제로 누르지 않는다.
        for _ in 0..<8 where !element.isHittable {
            let surfaces = app.scrollViews.allElementsBoundByIndex
                + app.tables.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex
            let identifier = element.identifier
            // 다중 열에서 보관함을 스크롤하며 오른쪽 상세 버튼을 찾지 않도록 소유 컨테이너를 선택한다.
            let surface = surfaces.first { candidate in
                candidate.isHittable && candidate.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists
            } ?? app
            #if os(macOS)
            surface.scroll(byDeltaX: 0, deltaY: -250)
            #else
            surface.swipeUp()
            #endif
        }
        guard element.isHittable && element.isEnabled else {
            XCTFail("UI 요소에 도달할 수 없다: \(describe(element)). \(diagnostics(in: app))", file: file, line: line)
            throw UIHarnessError.unhittable(element.identifier)
        }
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) throws {
        try interact(with: field, in: app)
        let current = value(of: field)
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        #else
        // TextField의 placeholder는 value로 보고될 수 있다. 실제 입력 값만 지운다.
        if !current.isEmpty, current != field.placeholderValue {
            field.press(forDuration: 1.2)
            let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label == %@", "전체 선택", "Select All")).firstMatch
            guard selectAll.waitForExistence(timeout: 5) else {
                XCTFail("편집할 원문 전체를 선택할 수 없다.")
                throw UIHarnessError.missingElement("Select All")
            }
            try interact(with: selectAll, in: app)
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        #endif
        field.typeText(text)
        try waitForValue(text, element: field)
    }

    @MainActor
    private func value(of element: XCUIElement) -> String { element.value as? String ?? "" }

    @MainActor
    private func waitForValue(_ expected: String, element: XCUIElement) throws {
        let predicate: NSPredicate
        if expected.isEmpty {
            predicate = NSPredicate(format: "value == %@ OR value == placeholderValue OR value == nil", expected)
        } else { predicate = NSPredicate(format: "value == %@", expected) }
        let changed = XCTNSPredicateExpectation(predicate: predicate, object: element)
        guard XCTWaiter.wait(for: [changed], timeout: 15) == .completed else {
            XCTFail("입력 값이 기대 상태로 바뀌지 않았다: \(describe(element))")
            throw UIHarnessError.unexpectedValue(element.identifier)
        }
    }

    @MainActor
    private func waitForLabel(_ expected: String, element: XCUIElement) throws {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)
        guard XCTWaiter.wait(for: [changed], timeout: 15) == .completed else {
            XCTFail("표시된 원본 상태가 기대값과 다르다: \(describe(element))")
            throw UIHarnessError.unexpectedValue(element.identifier)
        }
    }

    @MainActor
    private func waitForLabelContaining(_ expected: String, element: XCUIElement) throws {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", expected), object: element)
        guard XCTWaiter.wait(for: [changed], timeout: 15) == .completed else {
            XCTFail("검증 오류가 기대 내용으로 표시되지 않았다: \(describe(element))")
            throw UIHarnessError.unexpectedValue(element.identifier)
        }
    }

    @MainActor
    private func describe(_ element: XCUIElement) -> String {
        guard element.exists else { return "exists=false" }
        return "id=\(element.identifier), label=\(element.label.prefix(90)), value=\(value(of: element).prefix(90)), enabled=\(element.isEnabled), hittable=\(element.isHittable), frame=\(element.frame)"
    }

    @MainActor
    private func diagnostics(in app: XCUIApplication) -> String {
        let state = app.state
        guard state != .notRunning else {
            return "appState=\(state.rawValue), 앱 프로세스 종료: hierarchy 조회를 수행하지 않음"
        }
        // UI 테스트는 이 launch에서 직접 입력한 dummy만 사용한다. 앱 데이터나 로그 파일은 읽지 않는다.
        let prefixes = ["today.", "library.", "destination.", "capture.", "review.", "plan.", "detail.", "task.", "state."]
        let nodes = app.descendants(matching: .any).allElementsBoundByIndex.filter { candidate in
            prefixes.contains { candidate.identifier.hasPrefix($0) }
        }
        let sheetNodes = app.sheets.allElementsBoundByIndex.flatMap {
            $0.descendants(matching: .any).allElementsBoundByIndex
        }.filter { candidate in prefixes.contains { candidate.identifier.hasPrefix($0) } }
        let errors = nodes.filter { $0.identifier == "state.error" }.sorted { $0.isHittable && !$1.isHittable }
        let modalNodes = nodes.filter { candidate in
            candidate.identifier.hasPrefix("review.") || candidate.identifier.hasPrefix("plan.")
                || candidate.identifier.hasPrefix("detail.")
                || (candidate.identifier.hasPrefix("capture.") && candidate.identifier != "capture.open")
        }.sorted { $0.isHittable && !$1.isHittable }
        var seen: Set<String> = []
        var lines: [String] = []
        @MainActor
        func append(_ candidates: [XCUIElement], limit: Int) {
            var added = 0
            for node in candidates where node.exists && added < limit {
                let key = node.identifier + "|" + node.label
                guard seen.insert(key).inserted else { continue }
                let label = node.label.replacingOccurrences(of: "\n", with: " ").prefix(50)
                let current = value(of: node).replacingOccurrences(of: "\n", with: " ").prefix(35)
                lines.append("\(node.identifier): label=\(label), value=\(current), e=\(node.isEnabled), h=\(node.isHittable)")
                added += 1
            }
        }
        // 오류와 실제 modal을 먼저 기록한다. sidebar가 annotation 길이 제한을 먼저 소진하지 않는다.
        append(errors, limit: 2)
        append(sheetNodes + modalNodes, limit: 7)
        append(nodes, limit: 5)
        let header = "appState=\(app.state.rawValue), windows=\(app.windows.count), sheets=\(app.sheets.count); "
        return header + String(lines.joined(separator: "; ").prefix(1400))
    }
}

private enum UIHarnessError: Error {
    case applicationNotRunning
    case missingElement(String)
    case unexpectedElement(String)
    case unhittable(String)
    case unexpectedValue(String)
}
