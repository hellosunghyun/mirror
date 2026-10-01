import XCTest

/// 실제 UI 입력과 앱의 Core Data 저장 경로를 사용한다. 테스트 전용 성공 응답이나 seed는 없다.
/// 같은 소스를 iPhone, iPad, Mac UI scheme에서 실행한다.
final class MirrorUITests: XCTestCase {
    @MainActor private var lastActionDescription = "없음"

    @MainActor
    func testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday() throws {
        let app = try launchApp()
        defer { app.terminate() }
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
        XCTAssertEqual(displayedText(of: card), title)
        try activate("review.today", in: app)
        try requireNoElement("review.card", in: app)
        try activate("review.finish", in: app)
        try requireNoElement("review.finish", in: app)
        _ = try requireElement("today.list", in: app)

        let today = try requireRow(title, in: app)
        XCTAssertTrue(value(of: today).contains("9월 30일"))
        XCTAssertTrue(value(of: today).contains("미완료"), "Q-009: 오늘 배치는 완료가 아니다.")
    }

    @MainActor
    func testTomorrowStaysOutOfTodayAndIsSearchableInLibrary() throws {
        let app = try launchApp()
        defer { app.terminate() }
        let title = "UI tomorrow is searchable"
        try capture(title, in: app)
        try activate("today.review", in: app)
        XCTAssertEqual(displayedText(of: try requireElement("review.card", in: app)), title)
        try activate("review.tomorrow", in: app)
        try requireNoElement("review.card", in: app)
        try activate("review.finish", in: app)
        try requireNoElement("review.finish", in: app)
        _ = try requireElement("today.list", in: app)
        XCTAssertFalse(taskRow(title, in: app).exists)

        #if os(macOS)
        lastActionDescription = "Mac Cmd+F로 보관함 검색"
        app.typeKey("f", modifierFlags: .command)
        let search = try requireElement("library.search", in: app)
        app.typeText("tomorrow is searchable")
        try waitForValue("tomorrow is searchable", element: search)
        XCTAssertEqual(value(of: search), "tomorrow is searchable", "Cmd+F는 검색 입력란으로 포커스를 옮긴다.")
        #else
        try showLibrary(in: app)
        let search = try requireElement("library.search", in: app)
        try replaceText(in: search, with: "tomorrow is searchable", app: app)
        #endif
        let future = try requireRow(title, in: app)
        XCTAssertTrue(value(of: future).contains("10월 1일"), "Q-010: 서울 9월 30일의 내일은 10월 1일이다.")
        XCTAssertTrue(value(of: future).contains("미완료"))
        try interact(with: future, in: app)
        XCTAssertTrue(displayedText(of: try requireElement("detail.plan", in: app)).contains("10월 1일"))
        try activate("detail.close", in: app)
        try showToday(in: app)
        XCTAssertFalse(taskRow(title, in: app).exists, "검색은 미래 계획을 Today로 바꾸지 않는다.")
    }

    @MainActor
    func testOverlongTitleShowsErrorAndPreservesEveryCharacter() throws {
        let app = try launchApp()
        defer { app.terminate() }
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
        defer { app.terminate() }
        let titles = ["UI partial alpha", "UI partial beta"]
        for title in titles { try capture(title, in: app) }
        try activate("today.review", in: app)
        let decidedTitle = displayedText(of: try requireElement("review.card", in: app))
        XCTAssertTrue(titles.contains(decidedTitle))
        let remainingTitle = try XCTUnwrap(titles.first { $0 != decidedTitle })

        try activate("review.today", in: app)
        try waitForLabel(remainingTitle, element: requireElement("review.card", in: app), in: app)
        try activate("review.nextWeek", in: app)
        _ = try requireElement("plan.day.2026-10-05", in: app)
        try activate("plan.cancel", in: app)
        try waitForLabel(remainingTitle, element: requireElement("review.card", in: app), in: app)
        try activate("review.finish", in: app)
        try requireNoElement("review.finish", in: app)
        _ = try requireElement("today.list", in: app)

        _ = try requireRow(decidedTitle, in: app)
        XCTAssertFalse(taskRow(remainingTitle, in: app).exists, "Q-019: 부분 정리 종료는 미검토를 Today에 합치지 않는다.")
        try showLibrary(in: app)
        let remaining = try requireRow(remainingTitle, in: app)
        XCTAssertTrue(value(of: remaining).contains("아직 정하지 않음"), "Q-016: 주 패널 취소는 계획을 바꾸지 않는다.")
        try interact(with: remaining, in: app)
        XCTAssertEqual(displayedText(of: try requireElement("detail.plan", in: app)), "아직 정하지 않음")
    }

    @MainActor
    func testExplicitCompletionAndUndoPreserveEditedTitleAndPlan() throws {
        let app = try launchApp()
        defer { app.terminate() }
        let original = "UI edit before completion"
        let edited = "UI edited title survives undo"
        try capture(original, in: app)
        try activate("today.review", in: app)
        try activate("review.today", in: app)
        try requireNoElement("review.card", in: app)
        try activate("review.finish", in: app)
        try requireNoElement("review.finish", in: app)
        try interact(with: requireRow(original, in: app), in: app)

        try activate("detail.edit", in: app)
        let field = try requireElement("detail.title", in: app)
        try replaceText(in: field, with: edited, app: app)
        try activate("detail.save", in: app)
        try waitForLabel(edited, element: requireElement("detail.contentTitle", in: app), in: app)
        XCTAssertTrue(displayedText(of: try requireElement("detail.plan", in: app)).contains("9월 30일"))

        try activate("task.complete", in: app)
        try waitForLabel("완료 취소 · 다시 열기", element: requireElement("task.complete", in: app), in: app)
        XCTAssertTrue(displayedText(of: try requireElement("detail.plan", in: app)).contains("9월 30일"), "완료는 계획을 지우지 않는다.")
        try activate("task.undo", in: app)
        try waitForLabel("완료", element: requireElement("task.complete", in: app), in: app)
        XCTAssertEqual(displayedText(of: try requireElement("detail.contentTitle", in: app)), edited)
        XCTAssertTrue(displayedText(of: try requireElement("detail.plan", in: app)).contains("9월 30일"))
        try activate("detail.close", in: app)
        try showToday(in: app)
        let reopened = try requireRow(edited, in: app)
        XCTAssertTrue(value(of: reopened).contains("미완료"))
        XCTAssertFalse(taskRow(original, in: app).exists)
    }

    @MainActor
    func testReviewUndoRestoresUnassignedCardInsteadOfAddingToToday() throws {
        let app = try launchApp()
        defer { app.terminate() }
        let title = "UI undo review destination"
        try capture(title, in: app)
        try activate("today.review", in: app)
        try activate("review.tomorrow", in: app)
        try requireNoElement("review.card", in: app)
        try activate("task.undo", in: app)
        try waitForLabel(title, element: requireElement("review.card", in: app), in: app)
        try activate("review.finish", in: app)
        try requireNoElement("review.finish", in: app)
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
        lastActionDescription = "없음"
        let app = XCUIApplication()
        app.launchEnvironment["MIRROR_UI_TESTING"] = "1"
        app.launchEnvironment["MIRROR_TEST_DATE"] = "2026-09-30T03:00:00Z"
        app.launchArguments = ["-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        // store 경로를 주입하지 않는다. 각 launch는 앱의 temporaryDirectory에 새 실제 store를 연다.
        app.launch()
        do {
            _ = try requireElement("today.list", in: app, timeout: 30)
            _ = try requireElement("capture.open", in: app)
            return app
        } catch {
            app.terminate()
            throw error
        }
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
    private func element(_ identifier: String, in app: XCUIApplication, preferButtons: Bool = false) -> XCUIElement {
        // 오류/Undo가 modal과 상태 표시줄 양쪽에 있으면 실제 활성 modal 요소를 우선한다.
        // Mac에서는 Button의 ID가 Row/Label에도 전달될 수 있으므로 실제 Button role을 우선한다.
        if preferButtons {
            let sheetButtons = app.sheets.firstMatch.buttons.matching(identifier: identifier)
            if sheetButtons.firstMatch.exists {
                return sheetButtons.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? sheetButtons.firstMatch
            }
            let buttons = app.buttons.matching(identifier: identifier)
            if buttons.firstMatch.exists {
                return buttons.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? buttons.firstMatch
            }
        }
        let sheetMatches = app.sheets.firstMatch.descendants(matching: .any).matching(identifier: identifier)
        if sheetMatches.firstMatch.exists {
            return sheetMatches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? sheetMatches.firstMatch
        }
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        return matches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? matches.firstMatch
    }

    @MainActor
    private func requireElement(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 15,
                                preferButtons: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        guard app.state != .notRunning else {
            printFailurePrefix("앱 프로세스가 종료되어 필수 UI 요소를 조회할 수 없다: \(identifier)")
            XCTFail("앱 프로세스가 종료되어 필수 UI 요소를 조회할 수 없다: \(identifier). appState=\(app.state.rawValue)", file: file, line: line)
            throw UIHarnessError.applicationNotRunning
        }
        let found = element(identifier, in: app, preferButtons: preferButtons)
        guard found.waitForExistence(timeout: timeout) else {
            printFailurePrefix("필수 UI 요소가 없다: \(identifier)")
            XCTFail("필수 UI 요소가 없다: \(identifier). \(diagnostics(in: app))", file: file, line: line)
            throw UIHarnessError.missingElement(identifier)
        }
        return found
    }

    @MainActor
    private func requireNoElement(_ identifier: String, in app: XCUIApplication) throws {
        // 닫히는 UI의 부재는 exists만 검사한다. 사라지는 버튼의 activation point를 조회하지 않는다.
        let found = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: found)
        guard XCTWaiter.wait(for: [gone], timeout: 15) == .completed else {
            printFailurePrefix("UI 요소가 닫히거나 다음 상태로 진행하지 않았다: \(identifier)")
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
            printFailurePrefix("저장된 작업 행을 찾지 못했다: \(title)")
            XCTFail("저장된 작업 행을 찾지 못했다: \(title)")
            throw UIHarnessError.missingElement(title)
        }
        return row
    }

    @MainActor
    private func activate(_ identifier: String, in app: XCUIApplication,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let target = try requireElement(identifier, in: app, preferButtons: true, file: file, line: line)
        lastActionDescription = describe(target)
        try interact(with: target, in: app, file: file, line: line)
    }

    @MainActor
    private func interact(with element: XCUIElement, in app: XCUIApplication,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        lastActionDescription = describe(element)
        // 원본 저장·projection 갱신 직후에는 action의 enabled/hittable 반영도 기다린다.
        // 숨은 요소를 좌표로 누르거나 disabled 행동을 통과시키지 않는다.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: element)
        _ = XCTWaiter.wait(for: [ready], timeout: 3)
        let identifier = element.identifier
        // 38d7849 iPhone 실제 AX: 행 중심 y=434, 목록 하단 y=403인데 hittable=true였다.
        // 작업 행은 소유 목록의 표시 영역 안으로 실제 스크롤한 뒤 일반 tap을 수행한다.
        let rowSurface = identifier.hasPrefix("task.row.")
            ? scrollContainer(containing: element, in: app, requiringHittable: false) : nil
        if identifier.hasPrefix("task.row."), rowSurface == nil {
            printFailurePrefix("작업 행을 포함하는 스크롤 컨테이너가 없다")
            XCTFail("작업 행을 포함하는 스크롤 컨테이너가 없다: \(describe(element)). \(diagnostics(in: app))", file: file, line: line)
            throw UIHarnessError.unhittable(identifier)
        }
        // Form 아래쪽의 완료/Undo도 실제 스크롤로 도달한다. 숨겨진 요소의 좌표를 강제로 누르지 않는다.
        for _ in 0..<8 {
            let rowNeedsScroll = rowSurface.map { !rowCenterIsVisible(element, in: $0) } ?? false
            guard !element.isHittable || rowNeedsScroll else { break }
            // 다중 열에서 보관함을 스크롤하며 오른쪽 상세 버튼을 찾지 않도록 소유 컨테이너를 선택한다.
            guard let surface = rowSurface ?? scrollContainer(containing: element, in: app) else {
                printFailurePrefix("대상 UI를 포함하는 스크롤 컨테이너가 없다")
                XCTFail("대상 UI를 포함하는 스크롤 컨테이너가 없다: \(describe(element)). \(diagnostics(in: app))", file: file, line: line)
                throw UIHarnessError.unhittable(identifier)
            }
            let isAboveViewport = rowSurface == nil ? element.frame.minY < surface.frame.minY
                : element.frame.midY < surface.frame.minY
            #if os(macOS)
            surface.scroll(byDeltaX: 0, deltaY: isAboveViewport ? 250 : -250)
            #else
            if isAboveViewport { surface.swipeDown() }
            else { surface.swipeUp() }
            #endif
        }
        let rowCenterIsInside = rowSurface.map { rowCenterIsVisible(element, in: $0) } ?? true
        guard element.isHittable && element.isEnabled && rowCenterIsInside else {
            printFailurePrefix("UI 요소에 도달할 수 없다")
            XCTFail("UI 요소에 도달할 수 없다: \(describe(element)). \(diagnostics(in: app))", file: file, line: line)
            throw UIHarnessError.unhittable(element.identifier)
        }
        if rowSurface != nil { lastActionDescription = describe(element) }
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    @MainActor
    private func scrollContainer(containing element: XCUIElement, in app: XCUIApplication,
                                 requiringHittable: Bool = true) -> XCUIElement? {
        let surfaces = app.scrollViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex
        let identifier = element.identifier
        if requiringHittable {
            return surfaces.first { candidate in
                candidate.isHittable && candidate.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists
            }
        }
        // List의 AX 컨테이너와 탭할 행은 다르다. 행의 hittable/enabled는 interact에서 계속 검사한다.
        let windowFrames = app.windows.allElementsBoundByIndex.map { $0.frame }
        let rowCenterX = element.frame.midX
        var probes: [String] = []
        for candidate in surfaces {
            let frame = candidate.frame
            let containsTarget = candidate.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists
            let visible = !frame.isEmpty && windowFrames.contains { $0.intersects(frame) }
            // 다중 열의 다른 스크롤 영역을 배제한다. 세로 화면 밖 행은 계속 실제 스크롤로 찾는다.
            let sameColumn = frame.minX <= rowCenterX && rowCenterX <= frame.maxX
            let probe = "id=\(candidate.identifier), type=\(candidate.elementType.rawValue), frame=\(frame), containsTarget=\(containsTarget), inWindow=\(visible), rowCenterX=\(rowCenterX), sameColumn=\(sameColumn)"
            probes.append(probe)
            if containsTarget && visible && sameColumn {
                print("UI row scroll owner: \(probe)")
                return candidate
            }
        }
        printFailurePrefix("작업 행 스크롤 컨테이너 후보: \(probes.joined(separator: "; "))")
        return nil
    }

    @MainActor
    private func rowCenterIsVisible(_ element: XCUIElement, in surface: XCUIElement) -> Bool {
        let frame = element.frame
        let viewport = surface.frame
        return !frame.isEmpty && !viewport.isEmpty && viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
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
                printFailurePrefix("편집할 원문 전체를 선택할 수 없다")
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
    private func displayedText(of element: XCUIElement) -> String {
        // b0c2fa4 Mac 실제 AX: StaticText는 label="", value=표시 문장으로 노출됐다.
        // nonempty label을 우선하고 빈 label일 때만 실제 value를 사용한다.
        element.label.isEmpty ? value(of: element) : element.label
    }

    @MainActor
    private func waitForValue(_ expected: String, element: XCUIElement) throws {
        let predicate: NSPredicate
        if expected.isEmpty {
            predicate = NSPredicate(format: "value == %@ OR value == placeholderValue OR value == nil", expected)
        } else { predicate = NSPredicate(format: "value == %@", expected) }
        let changed = XCTNSPredicateExpectation(predicate: predicate, object: element)
        guard XCTWaiter.wait(for: [changed], timeout: 15) == .completed else {
            printFailurePrefix("입력 값이 기대 상태로 바뀌지 않았다: expected=\(expected)")
            XCTFail("입력 값이 기대 상태로 바뀌지 않았다: \(describe(element))")
            throw UIHarnessError.unexpectedValue(element.identifier)
        }
    }

    @MainActor
    private func waitForLabel(_ expected: String, element: XCUIElement, in app: XCUIApplication) throws {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ OR (label == '' AND value == %@)", expected, expected), object: element)
        guard XCTWaiter.wait(for: [changed], timeout: 15) == .completed else {
            printFailurePrefix("표시된 원본 상태가 기대값과 다르다: expected=\(expected)")
            XCTFail("표시된 원본 상태가 기대값과 다르다: expected=\(expected), \(describe(element)). \(diagnostics(in: app))")
            throw UIHarnessError.unexpectedValue(element.identifier)
        }
    }

    @MainActor
    private func waitForLabelContaining(_ expected: String, element: XCUIElement) throws {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ OR (label == '' AND value CONTAINS %@)", expected, expected), object: element)
        guard XCTWaiter.wait(for: [changed], timeout: 15) == .completed else {
            printFailurePrefix("검증 오류가 기대 내용으로 표시되지 않았다: expected=\(expected)")
            XCTFail("검증 오류가 기대 내용으로 표시되지 않았다: \(describe(element))")
            throw UIHarnessError.unexpectedValue(element.identifier)
        }
    }

    @MainActor
    private func printFailurePrefix(_ message: String) {
        let prefix = "UI error: \(message). lastAction={\(lastActionDescription)}"
        print(prefix.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r"))
    }

    @MainActor
    private func describe(_ element: XCUIElement) -> String {
        guard element.exists else { return "exists=false" }
        return "id=\(element.identifier), type=\(element.elementType.rawValue), label=\(element.label.prefix(90)), value=\(value(of: element).prefix(90)), enabled=\(element.isEnabled), selected=\(element.isSelected), frame=\(element.frame)"
    }

    @MainActor
    private func diagnostics(in app: XCUIApplication) -> String {
        let state = app.state
        guard state != .notRunning else {
            return "appState=\(state.rawValue), 앱 프로세스 종료: hierarchy 조회를 수행하지 않음"
        }
        // UI 테스트는 이 launch에서 직접 입력한 dummy만 사용한다. 앱 데이터나 로그 파일은 읽지 않는다.
        let prefixes = ["today.", "library.", "destination.", "capture.", "review.", "plan.", "detail.", "task.", "state.", "startup.", "onboarding."]
        let appIDPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: prefixes.map {
            NSPredicate(format: "identifier BEGINSWITH %@", $0)
        })
        // 테스트 러너의 query에서 ID를 먼저 필터링해 시스템 메뉴를 개별 AX IPC로 조회하지 않는다.
        let nodes = app.descendants(matching: .any).matching(appIDPredicate).allElementsBoundByIndex
        let sheetNodes = app.sheets.allElementsBoundByIndex.flatMap {
            $0.descendants(matching: .any).matching(appIDPredicate).allElementsBoundByIndex
        }
        let errors = nodes.filter { $0.identifier == "state.error" }
        let modalNodes = nodes.filter { candidate in
            candidate.identifier.hasPrefix("review.") || candidate.identifier.hasPrefix("plan.")
                || candidate.identifier.hasPrefix("detail.")
                || (candidate.identifier.hasPrefix("capture.") && candidate.identifier != "capture.open")
        }
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
                lines.append("\(node.identifier): type=\(node.elementType.rawValue), label=\(label), value=\(current), e=\(node.isEnabled)")
                added += 1
            }
        }
        // 오류와 실제 modal을 먼저 기록한다. sidebar가 annotation 길이 제한을 먼저 소진하지 않는다.
        append(errors, limit: 2)
        append(nodes.filter { $0.identifier == "state.feedback" }, limit: 1)
        append(sheetNodes + modalNodes, limit: 7)
        append(nodes, limit: 5)
        let windowFrames = app.windows.allElementsBoundByIndex.prefix(2).map { String(describing: $0.frame) }.joined(separator: ", ")
        let sheetFrames = app.sheets.allElementsBoundByIndex.prefix(2).map { String(describing: $0.frame) }.joined(separator: ", ")
        let keyboardFrames = app.keyboards.allElementsBoundByIndex.prefix(1).map { String(describing: $0.frame) }.joined(separator: ", ")
        let actionFrames = nodes.filter {
            $0.elementType == .button && ($0.identifier == "task.complete" || $0.identifier == "task.undo")
        }.prefix(4).map { "\($0.identifier): \($0.frame)" }.joined(separator: ", ")
        let scrollFrames = app.scrollViews.allElementsBoundByIndex.prefix(4).map { String(describing: $0.frame) }.joined(separator: ", ")
        let collectionFrames = app.collectionViews.allElementsBoundByIndex.prefix(3).map { String(describing: $0.frame) }.joined(separator: ", ")
        let tabs = app.tabBars.buttons.allElementsBoundByIndex.prefix(3).map {
            "\($0.label.prefix(30)): selected=\($0.isSelected), frame=\($0.frame)"
        }.joined(separator: ", ")
        let header = "appState=\(app.state.rawValue), windows=\(app.windows.count), windowFrames=[\(windowFrames)], sheets=\(app.sheets.count), sheetFrames=[\(sheetFrames)], keyboardFrames=[\(keyboardFrames)], actionFrames=[\(actionFrames)], scrollFrames=[\(scrollFrames)], collectionFrames=[\(collectionFrames)], tabs=[\(tabs)], lastAction={\(lastActionDescription)}; "
        return header + String(lines.joined(separator: "; ").prefix(1200))
    }
}

private enum UIHarnessError: Error {
    case applicationNotRunning
    case missingElement(String)
    case unexpectedElement(String)
    case unhittable(String)
    case unexpectedValue(String)
}
