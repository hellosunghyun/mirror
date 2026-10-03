import XCTest
#if os(iOS)
import UIKit
import CryptoKit
#endif

/// 실제 UI 입력과 앱의 Core Data 저장 경로를 사용한다. 테스트 전용 성공 응답이나 seed는 없다.
/// 같은 소스를 iPhone, iPad, Mac UI scheme에서 실행한다.
final class MirrorUITests: XCTestCase {
    @MainActor private var lastActionDescription = "없음"
    @MainActor private var evidenceSequence = 0

    @MainActor
    func testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday() async throws {
        recordCapturePhase(.started)
        let app = try launchApp()
        recordCapturePhase(.launched)
        defer { app.terminate() }
        let title = "UI capture then today"
        try verifyPhoneNavigation(in: app, stage: .initialToday)
        recordCapturePhase(.initialNavigationVerified)
        try recordUI("initial-today", in: app, identifiers: ["today.list", "today.review", "capture.open"])
        recordCapturePhase(.initialScreenshotRecorded)
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            try await captureIPadLandscape(in: app)
        }
        #endif
        try selectDestination("calendar", title: "일정", in: app)
        _ = try requireElement("calendar.date", in: app)
        recordCapturePhase(.calendarSelected)
        try verifyPhoneNavigation(in: app, stage: .calendar)
        recordCapturePhase(.calendarNavigationVerified)
        try recordUI("calendar", in: app, identifiers: ["calendar.date", "capture.open", "settings.button"])
        recordCapturePhase(.calendarScreenshotRecorded)
        try showToday(in: app)
        try captureSettings(in: app)
        recordCapturePhase(.settingsRecorded)
        try capture(title, in: app, attachEvidence: true)
        recordCapturePhase(.captureSaved)

        try showToday(in: app)
        XCTAssertFalse(taskRow(title, in: app).exists, "Q-001: 미검토 항목은 Today에 들어가지 않는다.")
        try showLibrary(in: app)
        let unassigned = try requireRow(title, in: app)
        recordCapturePhase(.libraryOpened)
        XCTAssertTrue(value(of: unassigned).contains("아직 정하지 않음"))
        XCTAssertTrue(value(of: unassigned).contains("미완료"))
        XCTAssertEqual(displayedText(of: try requireElement("library.resultsTitle", in: app)), "정하지 않은 일")
        try verifyPhoneNavigation(in: app, stage: .library, requiresFeedback: true)
        recordCapturePhase(.libraryNavigationVerified)
        try recordUI("library", in: app, identifiers: ["library.list", "library.search", "library.batchPlan"])
        recordCapturePhase(.libraryScreenshotRecorded)

        // 검색으로 숨은 작업이 일괄 배치 대상으로 남거나 다음 선택에 되살아나면 안 된다.
        recordCapturePhase(.selectionRegressionStarted)
        try activate("library.selectToggle", in: app)
        let selection = app.buttons.matching(NSPredicate(format: "label == %@", "\(title), 배치 대상 선택")).firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 15))
        try interact(with: selection, in: app)
        try waitForLabel("선택한 1개 날짜 배치", element: requireElement("library.batchPlan", in: app, preferButtons: true), in: app)
        let search = try requireElement("library.search", in: app)
        try replaceText(in: search, with: "UI no matching task", app: app)
        let emptySelection = try requireElement("library.batchPlan", in: app, preferButtons: true)
        try waitForLabel("선택한 0개 날짜 배치", element: emptySelection, in: app)
        XCTAssertFalse(taskRow(title, in: app).exists, "검색 결과에서 사라진 작업의 선택을 제거한다.")
        XCTAssertFalse(emptySelection.isEnabled, "검색으로 숨은 작업을 일괄 배치할 수 없다.")
        try replaceText(in: search, with: title, app: app)
        search.typeText("\n")
        try waitForLabel("선택한 0개 날짜 배치", element: requireElement("library.batchPlan", in: app, preferButtons: true), in: app)
        try interact(with: selection, in: app)
        try waitForLabel("선택한 1개 날짜 배치", element: requireElement("library.batchPlan", in: app, preferButtons: true), in: app)
        try activate("library.selectToggle", in: app)
        try activate("library.selectToggle", in: app)
        let restartedSelection = try requireElement("library.batchPlan", in: app, preferButtons: true)
        try waitForLabel("선택한 0개 날짜 배치", element: restartedSelection, in: app)
        XCTAssertFalse(restartedSelection.isEnabled, "새 선택은 이전의 숨은 대상을 다시 선택하지 않는다.")
        try activate("library.selectToggle", in: app)
        recordCapturePhase(.selectionRegressionComplete)

        try showToday(in: app)
        try activate("today.review", in: app)
        let card = try requireElement("review.card", in: app)
        XCTAssertEqual(displayedText(of: card), title)
        try recordUI("review-card", in: app, identifiers: ["review.card", "review.today", "review.tomorrow", "review.thisWeek", "review.nextWeek", "review.other", "review.finish"])
        recordCapturePhase(.reviewOpened)
        try activate("review.today", in: app)
        try requireNoElement("review.card", in: app)
        try activate("review.finish", in: app)
        try requireNoElement("review.finish", in: app)
        recordCapturePhase(.todayAssigned)
        _ = try requireElement("today.list", in: app)

        let today = try requireRow(title, in: app)
        XCTAssertTrue(value(of: today).contains("9월 30일"))
        XCTAssertTrue(value(of: today).contains("미완료"), "Q-009: 오늘 배치는 완료가 아니다.")
        recordCapturePhase(.todayRowVerified)
        try verifyPhoneNavigation(in: app, stage: .todayPopulated, requiresFeedback: true)
        recordCapturePhase(.todayNavigationVerified)
        try recordUI("today-populated", in: app, identifiers: ["today.list", "today.review", "capture.open", "task.undo"])
        recordCapturePhase(.complete)
    }

    private enum CapturePhase: String {
        case started, launched, initialNavigationVerified, initialScreenshotRecorded
        case calendarSelected, calendarNavigationVerified, calendarScreenshotRecorded
        case settingsRecorded, captureSaved, libraryOpened, libraryNavigationVerified, libraryScreenshotRecorded
        case selectionRegressionStarted, selectionRegressionComplete, reviewOpened, todayAssigned
        case todayRowVerified, todayNavigationVerified, complete
    }

    private func recordCapturePhase(_ phase: CapturePhase) {
        // 도달한 고정 단계만 기록한다. 완료 단계도 사례 통과 판정으로 사용하지 않는다.
        print("UI capture phase diagnostic: {\"phase\":\"\(phase.rawValue)\"}")
    }

    private enum PhoneNavigationStage: String {
        case initialToday = "initial-today"
        case calendar, library
        case todayPopulated = "today-populated"
        case validationRecovery = "validation-recovery"
    }

    /// 탭 이동 직후의 실제 시스템 경계와 비교한다. 검색 키보드 회귀는 별도로 유지한다.
    @MainActor
    private func verifyPhoneNavigation(in app: XCUIApplication, stage: PhoneNavigationStage,
                                       requiresFeedback: Bool = false) throws {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let probes = app.descendants(matching: .any).matching(identifier: "ui.nativeStatusBar")
        let windows = app.windows.containing(NSPredicate(format: "identifier == %@", "ui.nativeStatusBar"))
            .allElementsBoundByAccessibilityElement
        guard app.state == .runningForeground, probes.count == 1, windows.count == 1 else {
            XCTFail("탭 배치 검사는 실제 전면 앱의 고유한 상태 표시줄 관측 창이 필요하다.")
            throw UIHarnessError.missingElement("nativeStatusBarWindow")
        }
        let coordinates = value(of: probes.firstMatch).split(separator: ",", omittingEmptySubsequences: false)
        guard coordinates.count == 4,
              let x = Double(coordinates[0]), let y = Double(coordinates[1]),
              let width = Double(coordinates[2]), let height = Double(coordinates[3]) else {
            XCTFail("탭 이동 후 실제 시스템 상태 표시줄의 경계를 읽지 못했다.")
            throw UIHarnessError.unexpectedValue("nativeStatusBarFrame")
        }
        let statusFrame = CGRect(x: x, y: y, width: width, height: height)
        let windowFrame = windows[0].frame
        func valid(_ frame: CGRect) -> Bool {
            [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
                && frame.width > 0 && frame.height > 0
        }
        guard valid(windowFrame), valid(statusFrame), windowFrame.contains(statusFrame) else {
            XCTFail("탭 배치 검사의 실제 창과 상태 표시줄 경계가 유효해야 한다.")
            throw UIHarnessError.unexpectedValue("nativeStatusBarFrame")
        }
        for identifier in ["capture.open", "settings.button"] {
            let buttons = app.buttons.matching(identifier: identifier)
            guard buttons.count == 1, valid(buttons.firstMatch.frame) else {
                XCTFail("탭 화면의 상단 버튼은 유효한 경계를 가진 고유한 Button이어야 한다: \(identifier)")
                throw UIHarnessError.missingElement(identifier)
            }
            let button = buttons.firstMatch
            let frame = button.frame
            recordPhoneNavigationGeometry(stage: stage, identifier: identifier,
                                          statusFrame: statusFrame, windowFrame: windowFrame, buttonFrame: frame)
            XCTAssertTrue(windowFrame.contains(frame), "탭의 상단 버튼 전체가 실제 창 안에 있어야 한다.")
            XCTAssertGreaterThanOrEqual(frame.minY, statusFrame.maxY, "탭 이동 후에도 상단 버튼은 상태 표시줄과 겹치지 않는다.")
            XCTAssertTrue(button.isHittable, "탭 이동 후에도 상단 버튼을 사용할 수 있다.")
            XCTAssertTrue(button.isEnabled, "탭 이동 후에도 상단 버튼이 활성화되어 있다.")
        }
        if requiresFeedback {
            let feedback = app.staticTexts.matching(identifier: "state.feedback")
            let undo = app.buttons.matching(identifier: "task.undo")
            let tabs = app.tabBars
            guard feedback.count == 1, undo.count == 1, tabs.count == 1,
                  valid(tabs.firstMatch.frame), windowFrame.contains(tabs.firstMatch.frame) else {
                XCTFail("저장 안내·되돌리기·시스템 탭은 실제 화면에서 각각 고유해야 한다.")
                throw UIHarnessError.missingElement("nativeTabFeedback")
            }
            let tabFrame = tabs.firstMatch.frame
            for element in [feedback.firstMatch, undo.firstMatch] {
                let frame = element.frame
                guard valid(frame) else {
                    XCTFail("저장 안내와 되돌리기의 실제 경계가 유효해야 한다.")
                    throw UIHarnessError.unexpectedValue("nativeTabFeedbackFrame")
                }
                XCTAssertTrue(windowFrame.contains(frame), "저장 안내와 되돌리기의 전체 경계가 실제 창 안에 있어야 한다.")
                XCTAssertLessThanOrEqual(frame.maxY, tabFrame.minY, "저장 안내와 되돌리기는 시스템 탭에 가려지지 않는다.")
            }
            XCTAssertTrue(undo.firstMatch.isHittable, "저장 안내의 되돌리기를 탭 위에서 사용할 수 있다.")
            XCTAssertTrue(undo.firstMatch.isEnabled, "저장 안내의 되돌리기가 활성화되어 있다.")
        }
        #endif
    }

    private func recordPhoneNavigationGeometry(stage: PhoneNavigationStage, identifier: String,
                                               statusFrame: CGRect, windowFrame: CGRect, buttonFrame: CGRect) {
        // 같은 검사에서 이미 읽은 좌표만 기록한다. 추가 AX 조회·대기·원문 출력은 없다.
        guard identifier == "capture.open" || identifier == "settings.button" else { return }
        let diagnostic: [String: Any] = [
            "stage": stage.rawValue, "identifier": identifier,
            "statusFrame": [statusFrame.minX, statusFrame.minY, statusFrame.width, statusFrame.height],
            "windowFrame": [windowFrame.minX, windowFrame.minY, windowFrame.width, windowFrame.height],
            "buttonFrame": [buttonFrame.minX, buttonFrame.minY, buttonFrame.width, buttonFrame.height],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print("UI navigation geometry diagnostic: \(json)")
        }
    }

    @MainActor
    func testTomorrowStaysOutOfTodayAndIsSearchableInLibrary() throws {
        recordTomorrowPhase(.started)
        let app = try launchApp()
        defer { app.terminate() }
        recordTomorrowPhase(.launched)
        let title = "UI tomorrow is searchable " + String(repeating: "긴 제목 ", count: 94) + "전체원문"
        try capture(title, in: app)
        recordTomorrowPhase(.captured)
        try activate("today.review", in: app)
        XCTAssertEqual(displayedText(of: try requireElement("review.card", in: app)), title)
        recordTomorrowPhase(.reviewOpened)
        try activate("review.tomorrow", in: app)
        try requireNoElement("review.card", in: app)
        recordTomorrowPhase(.tomorrowAssigned)
        try activate("review.finish", in: app)
        try requireNoElement("review.finish", in: app)
        recordTomorrowPhase(.reviewClosed)
        _ = try requireElement("today.list", in: app)
        XCTAssertFalse(taskRow(title, in: app).exists)
        recordTomorrowPhase(.todayExcluded)

        #if os(macOS)
        lastActionDescription = "Mac Cmd+F로 보관함 검색"
        app.typeKey("f", modifierFlags: .command)
        recordTomorrowPhase(.searchNavigationRequested)
        let search = try requireElement("library.search", in: app)
        recordTomorrowPhase(.searchReady)
        app.typeText("tomorrow is searchable")
        try waitForValue("tomorrow is searchable", element: search)
        XCTAssertEqual(value(of: search), "tomorrow is searchable", "Cmd+F는 검색 입력란으로 포커스를 옮긴다.")
        #else
        try showLibrary(in: app)
        recordTomorrowPhase(.searchNavigationRequested)
        let search = try requireElement("library.search", in: app)
        recordTomorrowPhase(.searchReady)
        try replaceText(in: search, with: "tomorrow is searchable", app: app)
        #endif
        recordTomorrowPhase(.searchEntered)
        let future = try requireRow(title, in: app)
        XCTAssertEqual(displayedText(of: future), title, "목록의 접근성 이름은 저장한 500자 제목 원문을 보존한다.")
        XCTAssertTrue(value(of: future).contains("10월 1일"), "Q-010: 서울 9월 30일의 내일은 10월 1일이다.")
        XCTAssertTrue(value(of: future).contains("미완료"))
        recordTomorrowPhase(.futureRowVerified)
        XCTAssertEqual(displayedText(of: try requireElement("library.resultsTitle", in: app)), "검색 결과",
                       "범위를 넓힌 검색 결과를 날짜 미정 목록으로 표시하지 않는다.")
        recordTomorrowPhase(.searchTitleVerified)
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            lastActionDescription = "iPhone 검색 중 상태 표시줄과 상단 버튼 배치"
            let probes = app.descendants(matching: .any).matching(identifier: "ui.nativeStatusBar")
            guard app.state == .runningForeground else {
                XCTFail("상태 표시줄 관측에는 실제 전면 앱이 필요하다.")
                throw UIHarnessError.missingElement("nativeStatusBarForeground")
            }
            guard probes.count == 1 else {
                XCTFail("상태 표시줄 관측 요소는 실제 앱에 정확히 하나 있어야 한다.")
                throw UIHarnessError.missingElement("nativeStatusBarProbe")
            }
            let ownerWindows = app.windows.containing(NSPredicate(format: "identifier == %@", "ui.nativeStatusBar"))
                .allElementsBoundByAccessibilityElement
            guard ownerWindows.count == 1 else {
                XCTFail("상태 표시줄 관측 요소를 소유한 실제 앱 창은 정확히 하나여야 한다.")
                throw UIHarnessError.missingElement("nativeStatusBarWindow")
            }
            let coordinates = value(of: probes.firstMatch).split(separator: ",", omittingEmptySubsequences: false)
            guard coordinates.count == 4,
                  let x = Double(coordinates[0]), let y = Double(coordinates[1]),
                  let width = Double(coordinates[2]), let height = Double(coordinates[3]) else {
                XCTFail("실제 시스템 상태 표시줄의 경계를 읽지 못했다.")
                throw UIHarnessError.unexpectedValue("nativeStatusBarFrame")
            }
            let statusFrame = CGRect(x: x, y: y, width: width, height: height)
            let windowFrame = ownerWindows[0].frame
            guard [statusFrame, windowFrame].allSatisfy({ frame in
                [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite })
                    && frame.width > 0 && frame.height > 0
            }), windowFrame.contains(statusFrame) else {
                XCTFail("상태 표시줄의 실제 경계가 유효하지 않다.")
                throw UIHarnessError.unexpectedValue("nativeStatusBarFrame")
            }
            let keyboard = app.keyboards.firstMatch
            guard keyboard.exists else {
                XCTFail("상단 배치 회귀는 검색 키보드가 열린 상태에서 검증한다.")
                throw UIHarnessError.missingElement("searchKeyboard")
            }
            for identifier in ["capture.open", "settings.button"] {
                let buttons = app.buttons.matching(identifier: identifier)
                guard buttons.count == 1 else {
                    XCTFail("검색 화면의 상단 버튼은 고유한 실제 Button이어야 한다: \(identifier)")
                    throw UIHarnessError.missingElement(identifier)
                }
                let button = buttons.firstMatch
                let frame = button.frame
                guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
                      frame.width > 0, frame.height > 0 else {
                    XCTFail("상단 버튼의 실제 경계가 유효하지 않다: \(identifier)")
                    throw UIHarnessError.unhittable(identifier)
                }
                let buttonHittable = button.isHittable
                recordSearchToolbarDiagnostic(identifier: identifier, hittable: buttonHittable,
                                              frameInsideWindow: windowFrame.contains(frame),
                                              belowStatus: frame.minY >= statusFrame.maxY)
                XCTAssertTrue(buttonHittable, "검색 중에도 상단 버튼을 사용할 수 있다.")
                XCTAssertTrue(button.isEnabled, "검색 중에도 상단 버튼이 활성화되어 있다.")
                XCTAssertGreaterThanOrEqual(frame.minY, statusFrame.maxY, "상단 버튼은 상태 표시줄과 겹치지 않는다.")
            }
        }
        #endif
        try recordUI("library-search", in: app, identifiers: ["library.list", "library.search"])
        recordTomorrowPhase(.libraryScreenshotRecorded)
        try interact(with: future, in: app)
        recordTomorrowPhase(.detailOpened)
        XCTAssertTrue(displayedText(of: try requireElement("detail.plan", in: app)).contains("10월 1일"))
        recordTomorrowPhase(.detailPlanVerified)
        XCTAssertEqual(displayedText(of: element("detail.contentTitle", in: app)), title,
                       "상세는 저장한 500자 제목 원문을 생략하지 않는다.")
        try activate("expandableText.expand", in: app)
        let collapseTitle = try requireElement("expandableText.collapse", in: app, preferButtons: true)
        XCTAssertEqual(collapseTitle.elementType, .button, "전체 제목은 별도의 실제 Button으로 접을 수 있다.")
        XCTAssertFalse(element("expandableText.expand", in: app).exists)
        XCTAssertEqual(displayedText(of: element("detail.contentTitle", in: app)), title,
                       "펼친 제목도 저장한 전체 원문을 보존한다.")
        try activate("expandableText.collapse", in: app)
        let expandTitle = try requireElement("expandableText.expand", in: app, preferButtons: true)
        XCTAssertEqual(expandTitle.elementType, .button, "접힌 제목은 별도의 실제 Button으로 다시 펼칠 수 있다.")
        XCTAssertFalse(element("expandableText.collapse", in: app).exists)
        XCTAssertEqual(displayedText(of: element("detail.contentTitle", in: app)), title,
                       "다시 접어도 전체 원문과 접근성 내용은 바뀌지 않는다.")
        try recordUI("detail", in: app, identifiers: ["detail.contentTitle", "detail.plan", "detail.edit", "task.complete", "detail.close"])
        recordTomorrowPhase(.detailScreenshotRecorded)
        try activate("detail.close", in: app)
        recordTomorrowPhase(.detailClosed)
        _ = try requireElement("library.clearSearch", in: app, preferButtons: true)
        XCTAssertEqual(app.buttons.matching(identifier: "library.clearSearch").count, 1,
                       "검색어 지우기는 고유한 실제 Button이어야 한다.")
        try activate("library.clearSearch", in: app)
        try waitForValue("", element: search)
        XCTAssertEqual(displayedText(of: try requireElement("library.resultsTitle", in: app)), "정하지 않은 일",
                       "검색어를 지우면 기존 날짜 미정 목록으로 돌아간다.")
        XCTAssertFalse(taskRow(title, in: app).exists, "검색어 지우기는 미래 계획을 날짜 미정 목록에 포함하지 않는다.")
        try showToday(in: app)
        XCTAssertFalse(taskRow(title, in: app).exists, "검색은 미래 계획을 Today로 바꾸지 않는다.")
        recordTomorrowPhase(.todayRechecked)
        recordTomorrowPhase(.complete)
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
        XCTAssertEqual(displayedText(of: problem), "제목은 500자 이하로 입력해 주세요.",
                       "제목 길이 오류에는 메모와 링크 제약을 함께 표시하지 않는다.")
        XCTAssertTrue(problem.isHittable, "저장 실패 설명은 추가 스크롤 없이 보여야 한다.")
        XCTAssertTrue(try requireElement("capture.save", in: app).isHittable,
                      "긴 입력 오류 뒤에도 저장 행동은 화면 안에 남는다.")
        #if os(iOS)
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertFalse(problem.frame.intersects(keyboard.frame), "오류 설명을 키보드가 가리지 않는다.")
        }
        #endif
        XCTAssertEqual(value(of: field), original, "Q-003: 잘라 저장하거나 입력 원문을 지우면 안 된다.")
        try recordUI("validation-error", in: app, identifiers: ["capture.title", "capture.save", "capture.close", "state.error"])

        try activate("capture.close", in: app)
        // 정상 입력과 같은 닫힘 확인을 거쳐 보관함 탐색·새 입력 복구를 시작한다.
        try requireNoElement("capture.title", in: app)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "state.error").firstMatch.exists,
                       "닫은 입력의 제목 검증 오류가 빈 목록과 새 입력에 남지 않는다.")
        try showLibrary(in: app)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "task.row.")).count, 0)

        // 오류 뒤에도 상단 행동이 실제 창과 시스템 상태 표시줄 아래에 남아야 한다.
        try verifyPhoneNavigation(in: app, stage: .validationRecovery)
        // 오류 뒤 정상 입력도 실제 원본 저장 경로로 복구되어야 한다.
        try capture("UI corrected after validation", in: app, observeValidationRecovery: true)
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
        try recordUI("week-picker", in: app, identifiers: ["plan.day.2026-10-05", "plan.day.2026-10-11", "plan.weekOnly", "plan.cancel"])
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

        // Q-021: 남은 정리 큐에 새 입력을 끼우지 않고, 원문과 기존 카드의 대상을 보존한다.
        try activate("detail.close", in: app)
        let remainingIdentifier = try requireRow(remainingTitle, in: app).identifier
        let newTitle = "UI captured during partial review"
        try capture(newTitle, in: app)
        try showLibrary(in: app)
        let inserted = try requireRow(newTitle, in: app)
        let insertedIdentifier = inserted.identifier
        XCTAssertEqual(displayedText(of: inserted), newTitle)
        XCTAssertTrue(value(of: inserted).contains("아직 정하지 않음"))
        XCTAssertTrue(value(of: inserted).contains("미완료"))
        XCTAssertEqual(try requireRow(remainingTitle, in: app).identifier, remainingIdentifier)

        try showToday(in: app)
        XCTAssertFalse(taskRow(newTitle, in: app).exists, "새 입력은 미검토 상태로 Today에 들어가지 않는다.")
        XCTAssertFalse(taskRow(remainingTitle, in: app).exists)
        try waitForLabel("이어서 정리, 남은 일 1개",
                         element: requireElement("today.review", in: app, preferButtons: true), in: app)
        try activate("today.review", in: app)
        try waitForLabel(remainingTitle, element: requireElement("review.card", in: app), in: app)
        XCTAssertEqual(displayedText(of: try requireElement("review.card", in: app)), remainingTitle,
                       "이어 정리는 새 입력 대신 기존 남은 카드를 그대로 보여 준다.")
        try activate("review.tomorrow", in: app)
        try requireNoElement("review.card", in: app)
        try activate("review.finish", in: app)
        try requireNoElement("review.finish", in: app)

        try showLibrary(in: app)
        let preserved = try requireRow(newTitle, in: app)
        XCTAssertEqual(preserved.identifier, insertedIdentifier)
        XCTAssertEqual(displayedText(of: preserved), newTitle, "새 입력의 원문을 정리 뒤에도 다시 찾을 수 있다.")
        XCTAssertTrue(value(of: preserved).contains("아직 정하지 않음"), "새 입력은 기존 큐의 결정에 함께 배치되지 않는다.")
        XCTAssertTrue(value(of: preserved).contains("미완료"))
        try replaceText(in: requireElement("library.search", in: app), with: remainingTitle, app: app)
        let postponed = try requireRow(remainingTitle, in: app)
        XCTAssertEqual(postponed.identifier, remainingIdentifier, "표시한 기존 카드의 작업만 내일로 배치한다.")
        XCTAssertTrue(value(of: postponed).contains("10월 1일"))
        XCTAssertTrue(value(of: postponed).contains("미완료"))
        // Q-021 추가 검증 끝.
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
        #if os(macOS)
        // 다른 입력창의 포커스가 닫혀도 상세의 미저장 입력은 유지해야 한다.
        try activate("capture.open", in: app)
        _ = try requireElement("capture.title", in: app)
        try activate("capture.close", in: app)
        try requireNoElement("capture.title", in: app)
        try showLibrary(in: app)
        XCTAssertEqual(value(of: try requireElement("detail.title", in: app)), edited,
                       "빠른 입력을 닫고 목록을 이동해도 미저장 상세 편집을 잃지 않는다.")
        try showToday(in: app)
        let reviewWhileEditing = try requireElement("today.review", in: app, preferButtons: true)
        XCTAssertFalse(reviewWhileEditing.isEnabled, "미저장 상세 편집 중에는 정리로 이동하지 않는다.")
        XCTAssertEqual(value(of: try requireElement("detail.title", in: app)), edited,
                       "Today로 돌아와도 미저장 상세 제목을 그대로 유지한다.")
        #endif
        try recordUI("detail-edit", in: app, identifiers: ["detail.title", "detail.save", "detail.close"])
        try activate("detail.save", in: app)
        try waitForLabel(edited, element: requireElement("detail.contentTitle", in: app), in: app)
        #if os(macOS)
        XCTAssertTrue(try requireElement("today.review", in: app, preferButtons: true).isEnabled,
                      "상세 내용을 저장한 뒤에는 다시 정리를 시작할 수 있다.")
        #endif
        XCTAssertTrue(displayedText(of: try requireElement("detail.plan", in: app)).contains("9월 30일"))

        try activate("task.complete", in: app)
        try waitForLabel("완료 취소 · 다시 열기", element: requireElement("task.complete", in: app), in: app)
        #if os(macOS)
        let completionButton = try requireElement("task.complete", in: app)
        let completionFrame = completionButton.frame
        XCTAssertLessThanOrEqual(completionFrame.width, 220,
                                 "Mac 완료 버튼이 상세 패널 전체로 늘어나지 않는다.")
        XCTAssertLessThanOrEqual(completionFrame.height, 46,
                                 "Mac 완료 버튼의 클릭 경계는 44pt와 렌더링 오차 이내다.")
        #endif
        XCTAssertTrue(displayedText(of: try requireElement("detail.plan", in: app)).contains("9월 30일"), "완료는 계획을 지우지 않는다.")
        #if os(macOS)
        let verifiesEmptyTodayBesideInspector = true
        #elseif os(iOS)
        let verifiesEmptyTodayBesideInspector = UIDevice.current.userInterfaceIdiom == .pad
        #else
        let verifiesEmptyTodayBesideInspector = false
        #endif
        if verifiesEmptyTodayBesideInspector {
            let todayFrame = try requireElement("today.list", in: app).frame
            for identifier in ["today.empty.title", "today.empty.description"] {
                let emptyText = try requireElement(identifier, in: app)
                XCTAssertTrue(emptyText.isHittable, "상세를 열어도 빈 Today 안내가 보여야 한다.")
                let frame = emptyText.frame
                XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite })
                              && frame.width > 0 && frame.height > 0,
                              "빈 Today 안내의 실제 경계는 유한하고 양수여야 한다.")
                XCTAssertTrue(todayFrame.contains(frame), "빈 Today 안내 전체가 목록 안에 보여야 한다.")
            }
        }
        try recordUI("completion", in: app, identifiers: ["detail.contentTitle", "detail.plan", "task.complete", "task.undo", "detail.close"])
        try activate("task.undo", in: app)
        try waitForLabel("완료", element: requireElement("task.complete", in: app), in: app)
        XCTAssertEqual(displayedText(of: try requireElement("detail.contentTitle", in: app)), edited)
        XCTAssertTrue(displayedText(of: try requireElement("detail.plan", in: app)).contains("9월 30일"))
        try recordUI("undo", in: app, identifiers: ["detail.contentTitle", "detail.plan", "task.complete", "detail.close"])
        try activate("detail.close", in: app)
        try showToday(in: app)
        let reopened = try requireRow(edited, in: app)
        XCTAssertTrue(value(of: reopened).contains("미완료"))
        XCTAssertFalse(taskRow(original, in: app).exists)

        // 상세의 빠른 미루기는 별도 날짜 선택 없이 내일로 옮기고 Undo로 기존 계획을 복원한다.
        try interact(with: reopened, in: app)
        // 이후 배치가 생기면 거절될 이전 계획의 실제 고유 ID를 미리 읽는다.
        let historyOpenDeadline = Date().addingTimeInterval(15)
        let historyControl = try requireElement("detail.history", in: app, timeout: max(0, historyOpenDeadline.timeIntervalSinceNow), preferButtons: true)
        XCTAssertEqual(historyControl.elementType, .button, "이력 펼치기는 내용 컨테이너와 구분된 실제 버튼이다.")
        let historyScroll = try requireHistoryScroll(containing: historyControl, in: app)
        _ = try revealHistoryTarget(historyControl, in: historyScroll, app: app, deadline: historyOpenDeadline)
        try activate("detail.history", in: app, timeout: max(0, historyOpenDeadline.timeIntervalSinceNow))
        let previousPlanUndo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.undo.setPlan."))
        let previousPlanDeadline = try revealHistoryTarget(previousPlanUndo.firstMatch, in: historyScroll, app: app)
        XCTAssertTrue(previousPlanUndo.firstMatch.waitForExistence(timeout: max(0, previousPlanDeadline.timeIntervalSinceNow)), "이전 계획의 실제 이력 버튼이 나타나야 한다.")
        XCTAssertEqual(previousPlanUndo.count, 1, "이 사례의 이전 계획 변경은 오늘 배치 하나다.")
        let previousPlanUndoID = previousPlanUndo.firstMatch.identifier
        let foldDeadline = try revealHistoryTarget(element("detail.history", in: app, preferButtons: true), in: historyScroll,
                                                  app: app, scrollUpWhenMissing: true)
        try activate("detail.history", in: app, timeout: max(0, foldDeadline.timeIntervalSinceNow))
        let postponeDeadline = try revealHistoryTarget(app.buttons.matching(identifier: "detail.postponeTomorrow").firstMatch,
                                                      in: historyScroll, app: app, scrollUpWhenMissing: true)
        XCTAssertTrue(try requireElement("detail.postponeTomorrow", in: app, timeout: max(0, postponeDeadline.timeIntervalSinceNow), preferButtons: true).isHittable,
                      "내일로 미루기는 상세에서 바로 누를 수 있어야 한다.")
        try activate("detail.postponeTomorrow", in: app, timeout: max(0, postponeDeadline.timeIntervalSinceNow))
        try waitForLabelContaining("10월 1일", element: requireElement("detail.plan", in: app))
        XCTAssertTrue(displayedText(of: try requireElement("detail.plan", in: app)).contains("10월 1일"))
        XCTAssertEqual(displayedText(of: try requireElement("detail.contentTitle", in: app)), edited)
        XCTAssertEqual(displayedText(of: try requireElement("task.complete", in: app)), "완료",
                       "내일로 미루기는 제목이나 미완료 상태를 변경하지 않는다.")
        try requireNoElement("detail.postponeTomorrow", in: app)
        let reopenDeadline = try revealHistoryTarget(element("detail.history", in: app, preferButtons: true), in: historyScroll, app: app)
        try activate("detail.history", in: app, timeout: max(0, reopenDeadline.timeIntervalSinceNow))
        let staleUndoDeadline = try revealHistoryTarget(app.buttons.matching(identifier: previousPlanUndoID).firstMatch,
                                                       in: historyScroll, app: app)
        try activate(previousPlanUndoID, in: app, timeout: max(0, staleUndoDeadline.timeIntervalSinceNow))
        let historyError = try requireElement("detail.actionError", in: app)
        try waitForLabelContaining("그 이후의 변경", element: historyError)
        XCTAssertTrue(historyError.isHittable, "이력의 변경이 거절되면 상세 안에서 이유를 볼 수 있다.")
        XCTAssertTrue(displayedText(of: try requireElement("detail.plan", in: app)).contains("10월 1일"),
                      "과거 이력의 Undo가 거절되면 최근 배치를 유지한다.")
        try activate("task.undo", in: app)
        try waitForLabelContaining("9월 30일", element: requireElement("detail.plan", in: app))
        try requireNoElement("detail.actionError", in: app)
        XCTAssertTrue(displayedText(of: try requireElement("detail.plan", in: app)).contains("9월 30일"))
        XCTAssertEqual(displayedText(of: try requireElement("detail.contentTitle", in: app)), edited)
        XCTAssertEqual(displayedText(of: try requireElement("task.complete", in: app)), "완료")
        try requireNoElement("plan.cancel", in: app)
        try activate("detail.close", in: app)
        try showToday(in: app)
        let restoredToday = try requireRow(edited, in: app)
        XCTAssertTrue(value(of: restoredToday).contains("9월 30일"))
        XCTAssertTrue(value(of: restoredToday).contains("미완료"))
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

        // 목록에서 바로 미루기: 취소는 계획을 유지하고 명시한 내일만 저장한다.
        let row = try requireRow(title, in: app)
        let taskID = try XCTUnwrap(row.identifier.components(separatedBy: "task.row.").last)
        XCTAssertNotNil(UUID(uuidString: taskID), "미루기는 화면에 보인 작업 ID를 사용한다.")
        let postponeID = "task.postpone.\(taskID)"
        try activate(postponeID, in: app)
        XCTAssertEqual(displayedText(of: try requireElement("plan.task.\(taskID)", in: app)), title)
        XCTAssertTrue(try requireElement("plan.tomorrow", in: app).isHittable)
        let todayButton = try requireElement("plan.today", in: app, preferButtons: true)
        XCTAssertTrue(todayButton.isEnabled, "일반 날짜 선택의 오늘 버튼은 활성화되어 있다.")
        XCTAssertTrue(todayButton.isHittable, "오늘과 내일은 다른 날짜를 펼치지 않고 선택할 수 있다.")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "plan.calendar").firstMatch.exists,
                       "일반 날짜 선택은 다른 날짜를 처음에 접어 둔다.")
        #if os(iOS)
        for identifier in ["plan.today", "plan.tomorrow"] {
            let buttons = app.buttons.matching(identifier: identifier)
            XCTAssertEqual(buttons.count, 1, "빠른 날짜 선택은 고유한 실제 Button이어야 한다.")
            let frame = buttons.firstMatch.frame
            XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
                          "빠른 날짜 선택 버튼의 실제 경계는 유한해야 한다.")
            XCTAssertGreaterThanOrEqual(frame.width, 44, "모바일 빠른 날짜 선택의 터치 목표 폭은 44pt 이상이다.")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "모바일 빠른 날짜 선택의 터치 목표 높이는 44pt 이상이다.")
        }
        #endif
        try recordUI("quick-plan-picker", in: app,
                     identifiers: ["plan.task.\(taskID)", "plan.today", "plan.tomorrow", "plan.cancel"])
        try activate("plan.cancel", in: app)
        try requireNoElement("plan.cancel", in: app)
        XCTAssertTrue(value(of: try requireRow(title, in: app)).contains("아직 정하지 않음"),
                      "날짜 선택 취소는 원래 계획을 변경하지 않는다.")

        try activate(postponeID, in: app)
        try activate("plan.tomorrow", in: app)
        try requireNoElement("plan.cancel", in: app)
        try showToday(in: app)
        XCTAssertFalse(taskRow(title, in: app).exists, "목록에서 내일로 미룬 일은 오늘에 들어가지 않는다.")
        try showLibrary(in: app)
        // 초기 보관함은 날짜 미정 목록이므로 전체 검색을 명시한다.
        try replaceText(in: requireElement("library.search", in: app), with: "UI undo review destination", app: app)
        let postponed = try requireRow(title, in: app)
        XCTAssertTrue(value(of: postponed).contains("10월 1일"))
        XCTAssertTrue(value(of: postponed).contains("미완료"), "미루기는 완료가 아니다.")
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
        let appearance = ProcessInfo.processInfo.environment["MIRROR_UI_APPEARANCE"] ?? "system"
        guard appearance == "system" || appearance == "dark" else {
            XCTFail("UI 모양은 기본 시스템 모양 또는 명시한 어두운 모양이어야 한다.")
            throw UIHarnessError.missingElement("uiAppearanceConfiguration")
        }
        if appearance == "dark" { app.launchEnvironment["MIRROR_UI_APPEARANCE"] = appearance }
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
    private func capture(_ title: String, in app: XCUIApplication, attachEvidence: Bool = false,
                         observeValidationRecovery: Bool = false) throws {
        try activate("capture.open", in: app, observeValidationRecovery: observeValidationRecovery)
        let field = try requireElement("capture.title", in: app)
        try replaceText(in: field, with: title, app: app, prepareKeyboardBeforeTyping: attachEvidence)
        if attachEvidence {
            #if os(iOS)
            try dismissKeyboardIntroduction(in: app)
            #endif
            try recordUI("capture-form", in: app, identifiers: ["capture.title", "capture.note", "capture.url", "capture.save", "capture.close"])
            try activate("capture.more", in: app)
            _ = try requireElement("capture.note", in: app)
        }
        try activate("capture.save", in: app)
        try waitForValue("", element: field)
        if attachEvidence {
            let confirmation = try requireElement("capture.feedback", in: app)
            XCTAssertEqual(displayedText(of: confirmation), "보관함에 넣었어요.",
                           "실제 저장을 확인한 뒤 연속 입력 화면 안에서 보관함 저장을 안내한다.")
            XCTAssertTrue(confirmation.isHittable, "저장 안내는 입력 화면에서 보여야 한다.")
            try requireNoElement("capture.note", in: app)
            #if os(iOS)
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.exists, "연속 입력을 위해 저장 후에도 키보드를 유지한다.")
            XCTAssertLessThanOrEqual(confirmation.frame.maxY, keyboard.frame.minY,
                                     "저장 안내는 키보드에 가려지지 않는다.")
            #endif
            try replaceText(in: field, with: "UI next capture draft", app: app)
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "capture.feedback").firstMatch.exists,
                           "다음 제목을 입력하면 직전 저장 안내를 접는다.")
        }
        try activate("capture.close", in: app)
        try requireNoElement("capture.title", in: app)
    }

    private enum TomorrowPhase: String {
        case started, launched, captured, reviewOpened, tomorrowAssigned, reviewClosed, todayExcluded
        case searchNavigationRequested, searchReady, searchEntered, futureRowVerified, searchTitleVerified
        case libraryScreenshotRecorded, detailOpened, detailPlanVerified, detailScreenshotRecorded
        case detailClosed, todayRechecked, complete
    }

    private func recordTomorrowPhase(_ phase: TomorrowPhase) {
        // 실제 수행한 단계만 기록한다. 검사 결과는 별도이고 제목·오류 원문·추가 AX 조회는 없다.
        print("UI test phase diagnostic: {\"method\":\"testTomorrowStaysOutOfTodayAndIsSearchableInLibrary\",\"phase\":\"\(phase.rawValue)\"}")
    }

    private func recordSearchToolbarDiagnostic(identifier: String, hittable: Bool,
                                               frameInsideWindow: Bool, belowStatus: Bool) {
        // 원래 검사에서 읽은 Bool과 경계 계산만 기록한다. 추가 AX 조회와 원문 출력은 없다.
        guard identifier == "capture.open" || identifier == "settings.button" else { return }
        let diagnostic: [String: Any] = [
            "method": "testTomorrowStaysOutOfTodayAndIsSearchableInLibrary",
            "identifier": identifier, "hittable": hittable,
            "frameInsideWindow": frameInsideWindow, "belowStatus": belowStatus,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print("UI search toolbar diagnostic: \(json)")
        }
    }

    /// 합성 작업의 실제 앱 화면만 남긴다. 추가 AX 경계는 조회하지 않는다.
    /// 화면 합격 기준은 baseline 검토 뒤 추가하며 기존 기능 assertions는 그대로 유지한다.
    @MainActor
    private func recordUI(_ stage: String, in app: XCUIApplication, identifiers _: [String]) throws {
        let clock = ContinuousClock()
        let started = clock.now
        evidenceSequence += 1
        let method = name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
        let screenshotName = "mirror-ui-\(stage)-\(method)-\(evidenceSequence)"
        let appScreenshot: XCUIScreenshot
        #if os(iOS)
        if stage == "ipad-landscape" {
            let window = app.windows.firstMatch
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(window.exists, "가로 캡처에는 실제 앱 주 창이 있어야 한다.")
            let bounds = window.frame
            XCTAssertTrue(bounds.minX.isFinite && bounds.minY.isFinite
                          && bounds.width.isFinite && bounds.height.isFinite)
            XCTAssertGreaterThan(bounds.width, bounds.height, "실제 가로 앱 창을 캡처한다.")
            XCTAssertGreaterThan(bounds.height, 0)
            XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(bounds))
            // 앱·주 창 캡처의 가로 PNG가 회전되어 별도의 native 화면 캡처를 확인한다.
            // 전면 앱의 유일한 창이 단일 화면을 채울 때만 공개 attachment를 남긴다.
            guard UIDevice.current.userInterfaceIdiom == .pad,
                  app.state == .runningForeground, app.windows.count == 1,
                  XCUIScreen.screens.count == 1 else {
                XCTFail("가로 화면 캡처는 전면 iPad 앱의 유일한 창과 화면에 한정한다.")
                throw UIHarnessError.missingElement("landscapeScreenshotScope")
            }
            let screenScreenshot = XCUIScreen.main.screenshot()
            let displaySize = screenScreenshot.image.size
            guard displaySize.width.isFinite && displaySize.height.isFinite,
                  displaySize.width > displaySize.height, displaySize.height > 0,
                  [bounds, app.frame].allSatisfy({ frame in
                      frame.minX.isFinite && frame.minY.isFinite
                          && frame.width.isFinite && frame.height.isFinite
                          && abs(frame.minX) <= 1 && abs(frame.minY) <= 1
                          && abs(frame.width - displaySize.width) <= 1
                          && abs(frame.height - displaySize.height) <= 1
                  }) else {
                XCTFail("가로 화면 캡처의 논리적 화면 범위를 앱과 주 창이 채워야 한다.")
                throw UIHarnessError.missingElement("landscapeScreenshotScope")
            }
            // 동일 native screenshot의 픽셀을 보존하고 방향만 PNG 메타데이터로 직렬화한다.
            appScreenshot = screenScreenshot
        } else { appScreenshot = app.screenshot() }
        #else
        appScreenshot = app.screenshot()
        #endif
        #if os(macOS)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "앱 화면에는 실제 주 창이 있어야 한다.")
        let frame = window.frame
        let screenSize = appScreenshot.image.size
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertGreaterThanOrEqual(frame.minX, -1, "상세를 열어도 창 왼쪽이 화면 밖으로 잘리지 않는다.")
        XCTAssertGreaterThanOrEqual(frame.minY, -1, "창 위쪽이 화면 안에 남는다.")
        XCTAssertLessThanOrEqual(frame.maxX, screenSize.width + 1, "창 오른쪽이 화면 안에 남는다.")
        XCTAssertLessThanOrEqual(frame.maxY, screenSize.height + 1, "창 아래쪽이 화면 안에 남는다.")
        #endif
        let screenshot: XCTAttachment
        #if os(iOS)
        if stage == "ipad-landscape" {
            screenshot = XCTAttachment(data: try landscapeScreenshotPNG(appScreenshot),
                                       uniformTypeIdentifier: "public.png")
        } else { screenshot = XCTAttachment(screenshot: appScreenshot) }
        #else
        screenshot = XCTAttachment(screenshot: appScreenshot)
        #endif
        screenshot.name = screenshotName
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #if os(iOS)
        if stage == "ipad-landscape" { recordNativeScreenshotDiagnostic(appScreenshot) }
        #endif

        let elapsed = started.duration(to: clock.now).components
        let milliseconds = Int(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        print("UI screenshot timing: stage=\(stage),milliseconds=\(milliseconds)")
    }

    #if os(iOS)
    @MainActor
    private func landscapeScreenshotPNG(_ screenshot: XCUIScreenshot) throws -> Data {
        // 픽셀을 회전·렌더링·재압축하지 않는다. 기존 eXIf만 실제 native 방향으로 교체한다.
        // collector의 MAX_PNG_BYTES와 한 변 크기 한도를 따른다.
        let maximumPNGBytes = 64 * 1024 * 1024
        let maximumImageExtent = 16_384
        let native = screenshot.image
        let orientation: UInt8
        switch native.imageOrientation {
        case .up: orientation = 1
        case .upMirrored: orientation = 2
        case .down: orientation = 3
        case .downMirrored: orientation = 4
        case .leftMirrored: orientation = 5
        case .right: orientation = 6
        case .rightMirrored: orientation = 7
        case .left: orientation = 8
        @unknown default: throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
        }
        guard let bitmap = native.cgImage else {
            throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
        }
        let original = screenshot.pngRepresentation
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard original.count >= signature.count, original.count <= maximumPNGBytes,
              original.starts(with: signature) else {
            throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
        }
        let bytes = [UInt8](original)
        func bigEndianUInt32(at index: Int) -> UInt32 {
            (UInt32(bytes[index]) << 24) | (UInt32(bytes[index + 1]) << 16)
                | (UInt32(bytes[index + 2]) << 8) | UInt32(bytes[index + 3])
        }
        // PNG eXIf에는 JPEG의 Exif prefix 없이 classic TIFF 하나만 저장한다.
        // II, magic 42, IFD0 offset 8, SHORT orientation 하나, next IFD 0: 정확히 26 bytes.
        let tiff: [UInt8] = [
            0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x12, 0x01, 0x03, 0x00, 0x01, 0x00,
            0x00, 0x00, orientation, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        let ihdr: [UInt8] = [0x49, 0x48, 0x44, 0x52]
        let idat: [UInt8] = [0x49, 0x44, 0x41, 0x54]
        let iend: [UInt8] = [0x49, 0x45, 0x4e, 0x44]
        let exif: [UInt8] = [0x65, 0x58, 0x49, 0x66]
        var metadataChunk: [UInt8] = [0x00, 0x00, 0x00, 0x1a] + exif + tiff
        // 새 chunk의 type과 payload만 IEEE CRC32로 계산하고 원래 chunk CRC는 그대로 복사한다.
        var crc: UInt32 = 0xffff_ffff
        for byte in metadataChunk.dropFirst(4) {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (((crc & 1) == 1) ? 0xedb8_8320 : 0)
            }
        }
        crc ^= 0xffff_ffff
        metadataChunk.append(contentsOf: [
            UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16),
            UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc),
        ])
        var output = signature
        var position = signature.count
        var sawHeader = false
        var sawImageData = false
        var imageDataEnded = false
        var sawEnd = false
        while position < bytes.count {
            guard bytes.count - position >= 12 else {
                throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
            }
            let length = Int(bigEndianUInt32(at: position))
            guard length <= maximumPNGBytes, length <= bytes.count - position - 12 else {
                throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
            }
            let end = position + length + 12
            let kind = Array(bytes[(position + 4)..<(position + 8)])
            guard kind.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  (65...90).contains(kind[2]) else {
                throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
            }
            if !sawHeader {
                guard kind == ihdr, length == 13 else {
                    throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
                }
                let width = Int(bigEndianUInt32(at: position + 8))
                let height = Int(bigEndianUInt32(at: position + 12))
                guard width > 0, height > 0,
                      width <= maximumImageExtent, height <= maximumImageExtent,
                      width == bitmap.width, height == bitmap.height else {
                    throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
                }
                sawHeader = true
            } else if kind == ihdr {
                throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
            }
            if kind == idat {
                guard !imageDataEnded else {
                    throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
                }
                sawImageData = true
            } else if sawImageData { imageDataEnded = true }
            if kind == iend {
                guard length == 0, sawImageData, end == bytes.count else {
                    throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
                }
                sawEnd = true
            }
            if kind != exif {
                output.append(contentsOf: bytes[position..<end])
                if kind == ihdr { output.append(contentsOf: metadataChunk) }
                guard output.count <= maximumPNGBytes else {
                    throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
                }
            }
            position = end
        }
        guard sawHeader, sawImageData, sawEnd else {
            throw UIHarnessError.missingElement("landscapeScreenshotMetadata")
        }
        return Data(output)
    }

    @MainActor
    private func recordNativeScreenshotDiagnostic(_ screenshot: XCUIScreenshot) {
        // 동일 native screenshot의 scalar와 원본 PNG hash만 읽는다. 픽셀을 변환하지 않는다.
        let native = screenshot.image
        guard let bitmap = native.cgImage else { return }
        let orientation: String
        switch native.imageOrientation {
        case .up: orientation = "up"
        case .down: orientation = "down"
        case .left: orientation = "left"
        case .right: orientation = "right"
        case .upMirrored: orientation = "upMirrored"
        case .downMirrored: orientation = "downMirrored"
        case .leftMirrored: orientation = "leftMirrored"
        case .rightMirrored: orientation = "rightMirrored"
        @unknown default: return
        }
        let width = Double(native.size.width), height = Double(native.size.height)
        let scale = Double(native.scale)
        guard width.isFinite, height.isFinite, scale.isFinite,
              width > 0, width <= 16_384, height > 0, height <= 16_384,
              scale > 0, scale <= 8,
              bitmap.width > 0, bitmap.width <= 16_384,
              bitmap.height > 0, bitmap.height <= 16_384 else { return }
        let diagnostic: [String: Any] = [
            "method": "testCaptureRemainsUnassignedUntilReviewExplicitlyChoosesToday",
            "stage": "ipad-landscape", "orientation": orientation,
            "imageWidth": width, "imageHeight": height, "imageScale": scale,
            "cgImageWidth": bitmap.width, "cgImageHeight": bitmap.height,
            "pngSHA256": SHA256.hash(data: screenshot.pngRepresentation)
                .map { String(format: "%02x", $0) }.joined(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print("UI native screenshot diagnostic: \(json)")
        }
    }

    @MainActor
    private func dismissKeyboardIntroduction(in app: XCUIApplication) throws {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 15), "입력 캡처에는 실제 키보드가 표시되어야 한다.")
        let introductionPredicate = NSPredicate(
            format: "label == %@",
            "Speed up your typing by sliding your finger across the letters to compose a word."
        )
        let introductionTexts = app.staticTexts.matching(introductionPredicate)
        let introduction = introductionTexts.firstMatch
        if introduction.exists {
            // Continue 준비·실제 tap·안내 닫힘은 기존 안내 대기의 15초를 공유한다.
            let introductionStarted = Date()
            let introductionDeadline = introductionStarted.addingTimeInterval(15)
            let continuePredicate = NSPredicate(format: "label == %@", "Continue")
            let continueButtons = app.buttons.matching(continuePredicate)
            // 안내는 키보드 경계 밖으로 펼쳐질 수 있다. 본문과 버튼의 실제 AX 소유를 확인한다.
            let introductionContexts = app.otherElements.containing(introductionPredicate).containing(continuePredicate)
            let introductionWindows = app.windows.containing(introductionPredicate).containing(continuePredicate)
            var candidates: [XCUIElement] = []
            var continueQueryCount = 0
            var continueExistingCount = 0
            var continueHittableCount = 0
            var continueEnabledCount = 0
            var continueInKeyboardCount = 0
            var continueInIntroductionCount = 0
            var introductionContextCount = 0
            var introductionWindowCount = 0
            var introductionTextVisible = false
            var introductionContextValid = false
            var continueFrameInsideIntroduction: Any = NSNull()
            var enabledFrameDiagnostics: [[String: Any]] = []
            var keyboardBoundsValid = false
            var continueReady = false
            func printIntroductionDiagnostic(phase: String) {
                // 이미 샘플한 값만 사용한다. 실패 진단 때문에 AX를 다시 조회하지 않는다.
                guard [candidates.count, continueQueryCount, continueExistingCount,
                       continueHittableCount, continueEnabledCount, continueInKeyboardCount,
                       continueInIntroductionCount, introductionContextCount, introductionWindowCount]
                    .allSatisfy({ (0...100).contains($0) }) else { return }
                var diagnostic: [String: Any] = [
                    "phase": phase,
                    "continueCandidateCount": candidates.count,
                    "continueQueryCount": continueQueryCount,
                    "continueExistingCount": continueExistingCount,
                    "continueHittableCount": continueHittableCount,
                    "continueEnabledCount": continueEnabledCount,
                    "continueInKeyboardCount": continueInKeyboardCount,
                    "continueInIntroductionCount": continueInIntroductionCount,
                    "introductionContextCount": introductionContextCount,
                    "introductionWindowCount": introductionWindowCount,
                    "introductionTextVisible": introductionTextVisible,
                    "introductionContextValid": introductionContextValid,
                    "continueFrameInsideIntroduction": continueFrameInsideIntroduction,
                    "keyboardBoundsValid": keyboardBoundsValid,
                    "elapsedMilliseconds": Int(min(1_200_000, max(0, Date().timeIntervalSince(introductionStarted) * 1_000))),
                ]
                // 유일한 enabled 후보의 기존 frame만 보고한다. 여러 후보의 경계를 섞지 않는다.
                let frameDiagnostic = continueEnabledCount == 1 ? enabledFrameDiagnostics.first : nil
                for key in ["continueFrameHasArea", "continueFrameInsideKeyboard",
                            "continueFrameCenterInsideKeyboard", "continueFrameIntersectsKeyboard"] {
                    diagnostic[key] = frameDiagnostic?[key] ?? NSNull()
                }
                if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    print("UI keyboard introduction diagnostic: \(json)")
                }
            }
            func usableBounds(_ frame: CGRect) -> Bool {
                !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
                    && frame.minX.isFinite && frame.minY.isFinite
                    && frame.maxX.isFinite && frame.maxY.isFinite
                    && frame.width.isFinite && frame.height.isFinite
            }
            repeat {
                guard Date() < introductionDeadline else { break }
                let keyboardBounds = keyboard.frame
                keyboardBoundsValid = keyboardBounds.width > 0 && keyboardBounds.height > 0
                    && keyboardBounds.minX.isFinite && keyboardBounds.minY.isFinite
                    && keyboardBounds.width.isFinite && keyboardBounds.height.isFinite
                continueQueryCount = 0
                continueExistingCount = 0
                continueHittableCount = 0
                continueEnabledCount = 0
                continueInKeyboardCount = 0
                continueInIntroductionCount = 0
                introductionContextCount = 0
                introductionWindowCount = 0
                introductionTextVisible = false
                introductionContextValid = false
                continueFrameInsideIntroduction = NSNull()
                candidates.removeAll(keepingCapacity: true)
                enabledFrameDiagnostics.removeAll(keepingCapacity: true)
                if keyboardBoundsValid {
                    let buttons = continueButtons.allElementsBoundByAccessibilityElement
                    continueQueryCount = buttons.count
                    var enabledButtonsWithAreaCount = 0
                    for button in buttons {
                        guard Date() < introductionDeadline else { break }
                        guard button.exists else { continue }
                        continueExistingCount += 1
                        guard button.isHittable else { continue }
                        continueHittableCount += 1
                        guard button.isEnabled else { continue }
                        continueEnabledCount += 1
                        let frame = button.frame
                        let hasArea = frame.width > 0 && frame.height > 0
                        guard hasArea else {
                            enabledFrameDiagnostics.append([
                                "continueFrameHasArea": false,
                                "continueFrameInsideKeyboard": NSNull(),
                                "continueFrameCenterInsideKeyboard": NSNull(),
                                "continueFrameIntersectsKeyboard": NSNull(),
                            ])
                            continue
                        }
                        let insideKeyboard = keyboardBounds.contains(frame)
                        enabledFrameDiagnostics.append([
                            "continueFrameHasArea": true,
                            "continueFrameInsideKeyboard": insideKeyboard,
                            "continueFrameCenterInsideKeyboard": keyboardBounds.contains(CGPoint(x: frame.midX, y: frame.midY)),
                            "continueFrameIntersectsKeyboard": keyboardBounds.intersects(frame),
                        ])
                        if insideKeyboard { continueInKeyboardCount += 1 }
                        enabledButtonsWithAreaCount += 1
                    }
                    if continueEnabledCount == 1, enabledButtonsWithAreaCount == 1,
                       Date() < introductionDeadline {
                        let textBounds = introduction.frame
                        introductionTextVisible = introductionTexts.count == 1 && introduction.isHittable
                            && usableBounds(textBounds)
                        if introductionTextVisible, Date() < introductionDeadline {
                            let windows = introductionWindows.allElementsBoundByAccessibilityElement
                            introductionWindowCount = windows.count
                            let contexts = introductionContexts.allElementsBoundByAccessibilityElement
                            var deepestContexts: [XCUIElement] = []
                            var examinedAllContexts = true
                            for context in contexts {
                                guard Date() < introductionDeadline else {
                                    examinedAllContexts = false
                                    break
                                }
                                // 임의의 첫 부모나 넓은 app wrapper를 안내 컨테이너로 쓰지 않는다.
                                let nested = context.descendants(matching: .other)
                                    .containing(introductionPredicate).containing(continuePredicate)
                                if nested.count == 0 { deepestContexts.append(context) }
                            }
                            introductionContextCount = deepestContexts.count
                            if examinedAllContexts, deepestContexts.count == 1, windows.count == 1,
                               Date() < introductionDeadline {
                                let context = deepestContexts[0]
                                let contextBounds = context.frame
                                let windowBounds = windows[0].frame
                                introductionContextValid = usableBounds(contextBounds) && usableBounds(windowBounds)
                                    && windowBounds.contains(contextBounds)
                                    && contextBounds.width * contextBounds.height < windowBounds.width * windowBounds.height
                                    && contextBounds.contains(textBounds)
                                    && contextBounds.intersects(keyboardBounds)
                                    && context.staticTexts.matching(introductionPredicate).count == 1
                                if introductionContextValid {
                                    let ownedButtons = context.buttons.matching(continuePredicate).allElementsBoundByAccessibilityElement
                                    introductionContextValid = ownedButtons.count == 1
                                    if introductionContextValid {
                                        let ownedButton = ownedButtons[0]
                                        introductionContextValid = ownedButton.exists && ownedButton.isHittable && ownedButton.isEnabled
                                        if introductionContextValid {
                                            let ownedBounds = ownedButton.frame
                                            introductionContextValid = usableBounds(ownedBounds)
                                            if introductionContextValid {
                                                let insideIntroduction = contextBounds.contains(ownedBounds)
                                                continueFrameInsideIntroduction = insideIntroduction
                                                if insideIntroduction {
                                                    candidates = [ownedButton]
                                                    continueInIntroductionCount = 1
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                continueReady = candidates.count == 1 && Date() < introductionDeadline
                if continueReady { break }
                let remaining = introductionDeadline.timeIntervalSinceNow
                if remaining > 0 { RunLoop.current.run(until: Date().addingTimeInterval(min(0.1, remaining))) }
            } while Date() < introductionDeadline
            if candidates.count != 1 || !continueReady {
                printIntroductionDiagnostic(phase: "continueReadiness")
            }
            XCTAssertEqual(candidates.count, 1, "확인된 키보드 안내 안의 유일한 Continue만 닫는다.")
            guard candidates.count == 1 else { throw UIHarnessError.missingElement("keyboardIntroduction.continue") }
            XCTAssertTrue(continueReady, "기존 안내 대기의 15초 안에 실제 Continue가 준비되어야 한다.")
            guard continueReady else { throw UIHarnessError.unhittable("keyboardIntroduction.continue") }
            let next = candidates[0]
            guard Date() < introductionDeadline else {
                printIntroductionDiagnostic(phase: "continueReadiness")
                XCTFail("실제 Continue tap도 기존 안내 대기의 15초 안에 시작해야 한다.")
                throw UIHarnessError.unhittable("keyboardIntroduction.continue")
            }
            // 준비 시 유일한 안내 소유·실제 표시 경계·enabled/hittable을 확인했다.
            next.tap()
            let remaining = introductionDeadline.timeIntervalSinceNow
            let dismissalResult: XCTWaiter.Result
            if remaining > 0 {
                let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: introduction)
                dismissalResult = XCTWaiter.wait(for: [dismissed], timeout: remaining)
            } else { dismissalResult = .timedOut }
            let dismissedBeforeDeadline = dismissalResult == .completed && Date() < introductionDeadline
            if !dismissedBeforeDeadline { printIntroductionDiagnostic(phase: "introductionDismissal") }
            XCTAssertEqual(dismissalResult, .completed)
            XCTAssertTrue(dismissedBeforeDeadline, "Continue 준비와 안내 닫힘이 기존 단일 15초 안에 완료되어야 한다.")
            guard dismissedBeforeDeadline else { throw UIHarnessError.unexpectedElement("keyboardIntroduction") }
        }
        let keyDeadline = Date().addingTimeInterval(15)
        XCTAssertTrue(keyboard.keys.firstMatch.waitForExistence(timeout: 15),
                      "시스템 안내가 아닌 실제 입력 키가 준비된 뒤 캡처한다.")
        var hasVisibleInputKey = false
        repeat {
            let bounds = keyboard.frame
            for key in keyboard.keys.allElementsBoundByIndex {
                guard Date() < keyDeadline else { break }
                if key.isHittable {
                    let frame = key.frame
                    if frame.width > 0 && frame.height > 0 && bounds.contains(frame), Date() < keyDeadline {
                        hasVisibleInputKey = true
                        break
                    }
                }
            }
            if hasVisibleInputKey { break }
            RunLoop.current.run(until: min(Date().addingTimeInterval(0.1), keyDeadline))
        } while Date() < keyDeadline
        XCTAssertTrue(hasVisibleInputKey, "실제 키보드 안의 입력 키를 시스템 안내가 가리지 않는다.")
        XCTAssertFalse(introduction.exists, "입력 화면 캡처에 시스템 키보드 안내가 남지 않는다.")
    }
    #endif

    @MainActor
    private func captureSettings(in app: XCUIApplication) throws {
        try activate("settings.button", in: app)
        let close = try settingsCloseButton(in: app)
        try recordUI("settings", in: app, identifiers: ["settings.syncState", "settings.cloudState"])
        try interact(with: close, in: app)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 15), .completed, "설정 화면을 실제로 닫은 뒤 입력한다.")
    }

    @MainActor
    private func settingsCloseButton(in app: XCUIApplication) throws -> XCUIElement {
        let label = NSPredicate(format: "label == %@", "닫기")
        let deadline = Date().addingTimeInterval(15)
        repeat {
            let sheet = app.sheets.firstMatch.buttons.matching(label).allElementsBoundByIndex
            if let close = sheet.first(where: { $0.exists && $0.isHittable }) { return close }
            // 원본의 ToolbarItem(cancellationAction)에 한정한다. Mac native window의
            // traffic-light 닫기는 toolbar/navigation bar 밖이므로 fallback에 포함하지 않는다.
            let controls = app.navigationBars.buttons.matching(label).allElementsBoundByIndex
                + app.toolbars.buttons.matching(label).allElementsBoundByIndex
            if let close = controls.first(where: { $0.exists && $0.isHittable }) { return close }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        XCTFail("실제 설정 sheet 또는 앱 toolbar의 닫기 버튼이 있어야 한다.")
        throw UIHarnessError.missingElement("settingsCloseButton")
    }

    #if os(iOS)
    @MainActor
    private func captureIPadLandscape(in app: XCUIApplication) async throws {
        lastActionDescription = "iPad 가로 화면과 인접 일정의 실제 배치 안정 대기"
        XCUIDevice.shared.orientation = .landscapeLeft
        do {
            // 기본 숨김을 확인한 뒤 실제 사용자 버튼으로 기존 가로 캡처를 준비한다.
            let defaultToggle = try requireElement("ipad.adjacentCalendar.toggle", in: app, preferButtons: true)
            let defaultToggleCount = app.buttons.matching(identifier: "ipad.adjacentCalendar.toggle").count
            XCTAssertEqual(defaultToggleCount, 1, "보조 일정 표시 버튼은 고유해야 한다.")
            guard defaultToggleCount == 1 else { throw UIHarnessError.unexpectedElement("ipad.adjacentCalendar.toggle") }
            try waitForLabel("보조 일정 표시", element: defaultToggle, in: app)
            try waitForValue("숨겨짐", element: defaultToggle)
            XCTAssertEqual(defaultToggle.label, "보조 일정 표시")
            XCTAssertEqual(value(of: defaultToggle), "숨겨짐")
            try requireNoElement("ipad.adjacentCalendar", in: app)
            try interact(with: defaultToggle, in: app)
            let shownToggle = try requireElement("ipad.adjacentCalendar.toggle", in: app, preferButtons: true)
            try waitForLabel("보조 일정 숨기기", element: shownToggle, in: app)
            try waitForValue("표시됨", element: shownToggle)
            let shownToggleCount = app.buttons.matching(identifier: "ipad.adjacentCalendar.toggle").count
            XCTAssertEqual(shownToggleCount, 1, "보조 일정 숨기기 버튼은 고유해야 한다.")
            guard shownToggleCount == 1 else { throw UIHarnessError.unexpectedElement("ipad.adjacentCalendar.toggle") }
            XCTAssertEqual(shownToggle.label, "보조 일정 숨기기")
            XCTAssertEqual(value(of: shownToggle), "표시됨")
            try await waitForViewport(in: app, landscape: true)
            try recordUI("ipad-landscape", in: app, identifiers: ["today.list", "capture.open", "settings.button", "ipad.adjacentCalendar"])
            // 캡처 이후에도 같은 버튼으로 숨김이 실제 반영되는지 확인한다.
            try interact(with: shownToggle, in: app)
            let hiddenToggle = try requireElement("ipad.adjacentCalendar.toggle", in: app, preferButtons: true)
            try waitForLabel("보조 일정 표시", element: hiddenToggle, in: app)
            try waitForValue("숨겨짐", element: hiddenToggle)
            let hiddenToggleCount = app.buttons.matching(identifier: "ipad.adjacentCalendar.toggle").count
            XCTAssertEqual(hiddenToggleCount, 1, "다시 숨긴 보조 일정 표시 버튼은 고유해야 한다.")
            guard hiddenToggleCount == 1 else { throw UIHarnessError.unexpectedElement("ipad.adjacentCalendar.toggle") }
            XCTAssertEqual(hiddenToggle.label, "보조 일정 표시")
            XCTAssertEqual(value(of: hiddenToggle), "숨겨짐")
            try requireNoElement("ipad.adjacentCalendar", in: app)
        } catch {
            XCUIDevice.shared.orientation = .portrait
            throw error
        }
        lastActionDescription = "iPad 세로 화면의 실제 배치 복귀 대기"
        XCUIDevice.shared.orientation = .portrait
        try await waitForViewport(in: app, landscape: false)
    }

    @MainActor
    private func waitForViewport(in app: XCUIApplication, landscape: Bool) async throws {
        let started = Date()
        let deadline = started.addingTimeInterval(15)
        let windowQuery = app.windows
        let todayQuery = app.descendants(matching: .any).matching(identifier: "today.list")
        let reviewQuery = app.buttons.matching(identifier: "today.review")
        let adjacentQuery = app.descendants(matching: .any).matching(identifier: "ipad.adjacentCalendar")
        let calendarDateQuery = app.descendants(matching: .any).matching(identifier: "calendar.date")
        var stableFrames: [CGRect]?
        var stableSince: Date?
        var stableSamples = 0
        var lastChecks: [String: Bool] = [:]

        // 기존 조건을 평가한 bool만 남긴다. 진단을 위해 AX를 추가 조회하지 않는다.
        // 마지막 샘플에서 아직 평가하지 않은 조건은 포함하지 않는다.
        func remember(_ name: String, _ result: Bool) -> Bool {
            lastChecks[name] = result
            return result
        }

        func isUsable(_ frame: CGRect) -> Bool {
            !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
        }
        func contains(_ viewport: CGRect, _ frame: CGRect) -> Bool {
            isUsable(frame) && viewport.insetBy(dx: -1, dy: -1).contains(frame)
        }
        func sameFrames(_ lhs: [CGRect], _ rhs: [CGRect]) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
                abs(pair.0.minX - pair.1.minX) <= 1 && abs(pair.0.minY - pair.1.minY) <= 1
                    && abs(pair.0.width - pair.1.width) <= 1 && abs(pair.0.height - pair.1.height) <= 1
            }
        }

        repeat {
            lastChecks.removeAll(keepingCapacity: true)
            let bounds = app.frame
            var frames: [CGRect] = []
            // 매 반복의 현재 query 결과에 다시 바인딩한다. AX 요소를 반복 사이에 캐시하지 않는다.
            var window: XCUIElement?
            var today: XCUIElement?
            var review: XCUIElement?
            var adjacent: XCUIElement?
            var calendarDate: XCUIElement?
            var ready = remember("foreground", app.state == .runningForeground)
                && remember("appBoundsValid", isUsable(bounds))
                && remember("appOrientationMatches", landscape ? bounds.width > bounds.height : bounds.height > bounds.width)
            if ready {
                window = windowQuery.allElementsBoundByAccessibilityElement.first
                ready = remember("windowExists", window != nil)
            }
            if ready {
                today = todayQuery.allElementsBoundByAccessibilityElement.first
                ready = remember("todayExists", today != nil)
            }
            if ready {
                review = reviewQuery.allElementsBoundByAccessibilityElement.first
                ready = remember("reviewExists", review != nil)
            }
            if ready, let window, let today, let review {
                let windowBounds = window.frame
                let todayBounds = today.frame
                let reviewBounds = review.frame
                ready = remember("windowInApp", contains(bounds, windowBounds))
                    && remember("windowOrientationMatches", landscape ? windowBounds.width > windowBounds.height : windowBounds.height > windowBounds.width)
                    && remember("todayInWindow", contains(windowBounds, todayBounds))
                    && remember("reviewInToday", contains(todayBounds, reviewBounds))
                frames = [bounds, windowBounds, todayBounds, reviewBounds]
                if landscape {
                    if ready {
                        adjacent = adjacentQuery.allElementsBoundByAccessibilityElement.first
                        ready = remember("adjacentExists", adjacent != nil)
                    }
                    if ready {
                        calendarDate = calendarDateQuery.allElementsBoundByAccessibilityElement.first
                        ready = remember("calendarDateExists", calendarDate != nil)
                    }
                    if ready, let adjacent, let calendarDate {
                        let adjacentBounds = adjacent.frame
                        let dateBounds = calendarDate.frame
                        // 기기 frame만 먼저 회전한 상태는 통과시키지 않는다. 실제 두 열과
                        // 일정 입력 제어가 같은 viewport 안에 겹치지 않고 배치되어야 한다.
                        ready = remember("adjacentInWindow", contains(windowBounds, adjacentBounds))
                            && remember("dateInAdjacent", contains(adjacentBounds, dateBounds))
                            && remember("columnsSeparate", adjacentBounds.minX >= todayBounds.maxX - 1)
                        frames += [adjacentBounds, dateBounds]
                    }
                } else if ready {
                    adjacent = adjacentQuery.allElementsBoundByAccessibilityElement.first
                    ready = remember("portraitAdjacentAbsent", adjacent == nil)
                }
            }
            let sampledAt = Date()
            if ready {
                if let stableFrames, sameFrames(stableFrames, frames) {
                    stableSamples += 1
                } else {
                    stableSamples = 1
                    stableSince = sampledAt
                    stableFrames = frames
                }
                if stableSamples >= 3, let stableSince, sampledAt.timeIntervalSince(stableSince) >= 0.5 {
                    // List/ScrollView 자체는 조작 버튼이 아니다. 안정된 실제 열의 경계와
                    // 그 안의 정리/날짜 제어가 터치 가능한지 확인한 뒤 캡처한다.
                    if remember("reviewHittable", review?.isHittable ?? false)
                        && (!landscape || remember("dateHittable", calendarDate?.isHittable ?? false))
                        && remember("insideDeadline", Date() < deadline) { return }
                }
            } else {
                stableFrames = nil
                stableSince = nil
                stableSamples = 0
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 { try await Task.sleep(for: .seconds(min(0.25, remaining))) }
        } while Date() < deadline
        let diagnostic: [String: Any] = [
            "orientation": landscape ? "landscape" : "portrait",
            "stableSamples": stableSamples,
            "elapsedMilliseconds": Int(max(0, Date().timeIntervalSince(started) * 1_000)),
            "checks": lastChecks,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print("UI viewport diagnostic: \(json)")
        }
        XCTFail(landscape
            ? "15초 안에 실제 iPad 가로 화면과 인접 일정이 표시되고 0.5초 이상 3회 연속 안정되어야 한다."
            : "15초 안에 실제 iPad 세로 화면으로 복귀하고 0.5초 이상 3회 연속 안정되어야 한다.")
        throw UIHarnessError.unexpectedValue("viewportOrientation")
    }
    #endif

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
        // 검색 입력은 클릭 가능한 래퍼가 아니라 실제 단일 줄 TextField를 찾는다.
        if identifier == "library.search" {
            return app.textFields.matching(identifier: identifier).firstMatch
        }
        // 고유한 후보는 sheet 우선·hittable 선택을 거쳐도 같은 요소다.
        // Button role을 먼저 확인하며, 중복 오류/Undo는 기존 modal 검색을 유지한다.
        if identifier != "state.error" && identifier != "task.undo" {
            let uniqueCandidates = preferButtons
                ? app.buttons.matching(identifier: identifier)
                : app.descendants(matching: .any).matching(identifier: identifier)
            if uniqueCandidates.count == 1 { return uniqueCandidates.firstMatch }
        }
        // 오류/Undo가 modal과 상태 표시줄 양쪽에 있으면 실제 활성 modal 요소를 우선한다.
        // Mac에서는 Button의 ID가 Row/Label에도 전달될 수 있으므로 실제 Button role을 우선한다.
        if preferButtons {
            let sheetButtons = app.sheets.firstMatch.buttons.matching(identifier: identifier)
            if let first = firstHittableMatch(in: sheetButtons) { return first }
            let buttons = app.buttons.matching(identifier: identifier)
            if let first = firstHittableMatch(in: buttons) { return first }
        }
        let sheetMatches = app.sheets.firstMatch.descendants(matching: .any).matching(identifier: identifier)
        if let first = firstHittableMatch(in: sheetMatches) { return first }
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        // 아직 나타나지 않은 요소는 requireElement의 기존 15초 대기에 맡긴다.
        return firstHittableMatch(in: matches) ?? matches.firstMatch
    }

    @MainActor
    private func firstHittableMatch(in query: XCUIElementQuery) -> XCUIElement? {
        let first = query.firstMatch
        guard first.exists else { return nil }
        // 보통의 고유 ID는 열거하지 않고, modal·배경 ID가 중복될 때 기존 검색을 유지한다.
        if first.isHittable { return first }
        return query.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? first
    }

    @MainActor
    private func requireElement(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 15,
                                preferButtons: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        #if os(macOS)
        if identifier == "capture.title" {
            return try requireMacCaptureTitle(in: app, timeout: timeout, file: file, line: line)
        }
        #endif
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

    #if os(macOS)
    // 실제 입력 owner의 native 역할만 받는다. snapshot 오류의 원인이나 해결을 확정하지 않는다.
    @MainActor
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
        throw UIHarnessError.missingElement("capture.title")
    }
    #endif

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
                          observeValidationRecovery: Bool = false,
                          timeout: TimeInterval = 15,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        lastActionDescription = "activate id=\(identifier)"
        let target = try requireElement(identifier, in: app, timeout: timeout, preferButtons: true, file: file, line: line)
        try interact(with: target, in: app, observeValidationRecovery: observeValidationRecovery, file: file, line: line)
    }

    @MainActor
    private func requireHistoryScroll(containing control: XCUIElement, in app: XCUIApplication,
                                      file: StaticString = #filePath, line: UInt = #line) throws -> XCUIElement {
        guard app.state == .runningForeground else {
            try failHistoryNavigation("이력 탐색 중 앱이 전경에서 실행되지 않는다", in: app, file: file, line: line)
        }
        let owners = app.scrollViews.allElementsBoundByIndex.filter { candidate in
            candidate.isHittable && candidate.descendants(matching: .any).matching(identifier: "detail.history").firstMatch.exists
        }
        // 이미 확인한 고유 owner를 사용한다. 전역 스크롤 후보를 다시 열거하지 않는다.
        // 실제 control의 소유·현재 조작 가능 여부는 기존 조건대로 확인한다.
        guard control.exists, owners.count == 1, let surface = owners.first,
              surface.isHittable,
              surface.descendants(matching: .any).matching(identifier: control.identifier).firstMatch.exists,
              surface.elementType == .scrollView else {
            try failHistoryNavigation("이력 제어의 유일한 상세 스크롤 소유자를 확인할 수 없다", in: app, file: file, line: line)
        }
        let frame = surface.frame
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
              frame.width > 0, frame.height > 0 else {
            try failHistoryNavigation("이력 제어의 유일한 상세 스크롤 소유자를 확인할 수 없다", in: app, file: file, line: line)
        }
        return surface
    }

    @MainActor
    private func revealHistoryTarget(_ target: XCUIElement, in surface: XCUIElement, app: XCUIApplication,
                                     scrollUpWhenMissing: Bool = false,
                                     deadline: Date = Date().addingTimeInterval(15),
                                     file: StaticString = #filePath, line: UInt = #line) throws -> Date {
        // 원래 존재 대기의 15초 안에서 같은 상세만 실제로 스크롤한다. 호출자의 wait도 남은 예산을 쓴다.
        var scrolls = 0
        while true {
            guard app.state == .runningForeground else {
                try failHistoryNavigation("이력 탐색 중 앱이 전경에서 실행되지 않는다", in: app, file: file, line: line)
            }
            guard Date() < deadline else {
                try failHistoryNavigation("이력 스크롤 탐색의 기존 15초 예산을 초과했다", in: app, file: file, line: line)
            }
            guard surface.exists, surface.isHittable else {
                try failHistoryNavigation("이력의 기존 상세 스크롤 소유자가 사라지거나 표시되지 않는다", in: app, file: file, line: line)
            }
            let viewport = surface.frame
            guard [viewport.minX, viewport.minY, viewport.width, viewport.height].allSatisfy({ $0.isFinite }),
                  viewport.width > 0, viewport.height > 0 else {
                try failHistoryNavigation("이력의 기존 상세 스크롤 소유자가 사라지거나 표시되지 않는다", in: app, file: file, line: line)
            }
            var scrollUp = scrollUpWhenMissing
            if target.exists {
                let frame = target.frame
                guard surface.descendants(matching: .any).matching(identifier: target.identifier).firstMatch.exists else {
                    try failHistoryNavigation("이력 대상이 기존 상세 소유자 안에 없다", in: app, file: file, line: line)
                }
                let validFrame = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite })
                    && frame.width > 0 && frame.height > 0
                // 같은 poll에서 읽은 경계로만 판정한다. 다음 poll·스크롤 뒤에는 새 경계를 읽는다.
                let rowCenterIsInside = validFrame && !frame.isEmpty && !viewport.isEmpty
                    && viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
                if validFrame, rowCenterIsInside, target.isHittable, target.isEnabled {
                    guard Date() < deadline else {
                        try failHistoryNavigation("이력 스크롤 탐색의 기존 15초 예산을 초과했다", in: app, file: file, line: line)
                    }
                    return deadline
                }
                if validFrame, rowCenterIsInside, target.isHittable {
                    RunLoop.current.run(until: min(Date().addingTimeInterval(0.1), deadline))
                    continue
                }
                if validFrame { scrollUp = frame.minY < viewport.minY }
            }
            guard scrolls < 8 else {
                try failHistoryNavigation("기존 8회 실제 스크롤 안에 이력 대상에 도달하지 못했다", in: app, file: file, line: line)
            }
            guard Date() < deadline else {
                try failHistoryNavigation("이력 스크롤 탐색의 기존 15초 예산을 초과했다", in: app, file: file, line: line)
            }
            #if os(macOS)
            surface.scroll(byDeltaX: 0, deltaY: scrollUp ? 250 : -250)
            #else
            if scrollUp { surface.swipeDown() }
            else { surface.swipeUp() }
            #endif
            scrolls += 1
        }
    }

    @MainActor
    private func failHistoryNavigation(_ reason: String, in app: XCUIApplication,
                                       file: StaticString, line: UInt) throws -> Never {
        printFailurePrefix(reason)
        XCTFail("\(reason). \(diagnostics(in: app))", file: file, line: line)
        throw UIHarnessError.unhittable("detail.history")
    }

    @MainActor
    private func interact(with element: XCUIElement, in app: XCUIApplication,
                          observeValidationRecovery: Bool = false,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        lastActionDescription = "interact"
        // 원본 저장·projection 갱신 직후에는 action의 enabled/hittable 반영도 기다린다.
        // 숨은 요소를 좌표로 누르거나 disabled 행동을 통과시키지 않는다.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true AND enabled == true"), object: element)
        _ = XCTWaiter.wait(for: [ready], timeout: 3)
        let identifier = element.identifier
        lastActionDescription = "interact id=\(identifier)"
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
                if observeValidationRecovery {
                    recordValidationRecoveryDiagnostic(for: element, identifier: identifier, in: app)
                }
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
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    @MainActor
    private func recordValidationRecoveryDiagnostic(for element: XCUIElement, identifier: String,
                                                    in app: XCUIApplication) {
        // 기존 일반 스크롤 실패가 결정된 뒤의 새 상태만 관측한다. 성공 경로의 조회·행동은 추가하지 않는다.
        // 원문 ID·제목·AX dump·기기 정보·경계 좌표는 직렬화하지 않고 고정 Bool/null만 기록한다.
        let exists = element.exists
        let frame = exists ? element.frame : .zero
        func hasArea(_ candidate: CGRect) -> Bool {
            [candidate.minX, candidate.minY, candidate.width, candidate.height].allSatisfy { $0.isFinite }
                && candidate.width > 0 && candidate.height > 0
        }
        let frameHasArea = hasArea(frame)
        let ownerWindows = exists && !identifier.isEmpty
            ? app.windows.containing(NSPredicate(format: "identifier == %@", identifier)).allElementsBoundByAccessibilityElement
            : []
        let ownedBySingleWindow = ownerWindows.count == 1
        var frameInsideWindow: Any = NSNull()
        var belowStatus: Any = NSNull()
        if app.state == .runningForeground, exists, frameHasArea, ownedBySingleWindow {
            let windowFrame = ownerWindows[0].frame
            if hasArea(windowFrame) {
                frameInsideWindow = windowFrame.contains(frame)
                let probes = app.descendants(matching: .any).matching(identifier: "ui.nativeStatusBar")
                if probes.count == 1 {
                    let probeWindows = app.windows.containing(NSPredicate(format: "identifier == %@", "ui.nativeStatusBar"))
                        .allElementsBoundByAccessibilityElement
                    let ownerProbes = ownerWindows[0].descendants(matching: .any).matching(identifier: "ui.nativeStatusBar")
                    if probeWindows.count == 1, ownerProbes.count == 1 {
                        let coordinates = value(of: probes.firstMatch).split(separator: ",", omittingEmptySubsequences: false)
                        if coordinates.count == 4,
                           let x = Double(coordinates[0]), let y = Double(coordinates[1]),
                           let width = Double(coordinates[2]), let height = Double(coordinates[3]) {
                            let statusFrame = CGRect(x: x, y: y, width: width, height: height)
                            if hasArea(statusFrame), windowFrame.contains(statusFrame) {
                                belowStatus = frame.minY >= statusFrame.maxY
                            }
                        }
                    }
                }
            }
        }
        let checks: [String: Any] = [
            "identifierMatchesCaptureOpen": identifier == "capture.open",
            "targetIsButton": exists && element.elementType == .button,
            "exists": exists,
            "enabled": exists && element.isEnabled,
            "hittable": exists && element.isHittable,
            "frameHasArea": frameHasArea,
            "ownedBySingleWindow": ownedBySingleWindow,
            "keyboardPresent": app.keyboards.firstMatch.exists,
            "alertPresent": app.alerts.firstMatch.exists,
            "sheetPresent": app.sheets.firstMatch.exists,
            "frameInsideWindow": frameInsideWindow,
            "belowStatus": belowStatus,
        ]
        let diagnostic: [String: Any] = [
            "method": "testOverlongTitleShowsErrorAndPreservesEveryCharacter",
            "action": "capture.open", "phase": "validationRecovery", "checks": checks,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print("UI validation recovery diagnostic: \(json)")
        }
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
            // 실제 소유·창·열 검증에서 이미 읽은 값만 진단한다.
            let probe = "frame=\(frame), containsTarget=\(containsTarget), inWindow=\(visible), rowCenterX=\(rowCenterX), sameColumn=\(sameColumn)"
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
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication,
                             prepareKeyboardBeforeTyping: Bool = false) throws {
        try interact(with: field, in: app)
        #if os(iOS)
        if prepareKeyboardBeforeTyping && UIDevice.current.userInterfaceIdiom == .phone {
            // 첫 증거 입력은 실제 키가 준비된 뒤 시작한다. 입력 후 기존 검사도 유지한다.
            try dismissKeyboardIntroduction(in: app)
        }
        #endif
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        #else
        let current = value(of: field)
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
        let label = element.label
        return label.isEmpty ? value(of: element) : label
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
