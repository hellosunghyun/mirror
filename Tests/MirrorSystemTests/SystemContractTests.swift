import Foundation
import Testing
import MirrorDomain
import MirrorData
@testable import MirrorSystem

private let fixedInstant = ISO8601DateFormatter().date(from: "2026-09-30T03:15:00Z")!

private struct WidgetHarness {
    let directory: URL
    let store: MirrorStore
    let widget: WidgetReviewService
    let context: PlanningContext
    let first: UUID
    let second: UUID
}
private func harness(twoTasks: Bool = true) async throws -> WidgetHarness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorSystemTests-\(UUID().uuidString)", isDirectory: true)
    let configuration = StoreConfiguration(directory: directory, deviceID: UUID().uuidString)
    let store = try await MirrorStore(configuration: configuration)
    let context = try await store.currentContext(at: fixedInstant)
    let first = UUID(), second = UUID()
    for (id, title) in [(first, "진료 질문 확인"), (second, "두 번째 작업")].prefix(twoTasks ? 2 : 1) {
        let envelope = CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: id.uuidString, source: .app,
                                       context: context, workspaceEpoch: configuration.workspaceEpoch,
                                       payload: .capture(taskID: id, content: try TaskContent(title: title)))
        let result = await store.execute(envelope, at: fixedInstant)
        #expect(result.state == .locallyCommitted)
    }
    var preferences = SystemPreferences(); preferences.hideExternalTitles = false
    try await store.setLocalValue(JSONEncoder().encode(preferences), forKey: "system-preferences-v1")
    return WidgetHarness(directory: directory, store: store,
                         widget: WidgetReviewService(store: store, directory: directory, workspaceEpoch: configuration.workspaceEpoch),
                         context: context, first: first, second: second)
}

@Suite("시스템 경계와 실제 SQLite 위젯 명령")
struct SystemContractTests {
    @Test("외부 딥링크는 엄격한 탐색 계약만 받는다", arguments: [
        "mirror://task/not-a-uuid", "mirror://today?mutation=complete", "mirror://review?mode=unknown",
        "mirror://today?mode=daily&mode=weekly", "mirror://user:password@today", "javascript:alert(1)",
        "mirror://task/00000000-0000-0000-0000-000000000001/schedule?card=not-a-uuid"
    ])
    func malformedLinks(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(throws: (any Error).self) { try MirrorDeepLink.parse(url) }
    }

    @Test("다른 공간의 ID는 거부하고 가짜 카드 참조는 상세 탐색으로 제한한다")
    func ownedNavigation() throws {
        let owned = UUID(), foreign = UUID(), session = UUID(), card = UUID()
        #expect(throws: DeepLinkError.foreignTask) {
            try MirrorDeepLink.validate(.task(foreign), ownedTaskIDs: [owned])
        }
        let route = MirrorRoute.schedule(taskID: owned, sessionID: session, cardID: card)
        #expect(try MirrorDeepLink.parse(MirrorDeepLink.url(for: route)) == route)
        #expect(try MirrorDeepLink.validate(route, ownedTaskIDs: [owned]) == .task(owned))
        #expect(try MirrorDeepLink.validate(route, ownedTaskIDs: [owned], trustedCards: [card: owned]) == route)
    }

    @Test("동일 설정 위젯 두 서비스는 같은 카드·토큰을 받고 서로 다른 빠른 탭도 한 작업만 바꾼다")
    func duplicateWidgetDecisions() async throws {
        let h = try await harness()
        let other = WidgetReviewService(store: h.store, directory: h.directory, workspaceEpoch: "local-v1")
        let state = try await h.widget.snapshot(at: fixedInstant), identical = try await other.snapshot(at: fixedInstant)
        let card = try #require(state.card)
        #expect(card == identical.card)
        let tomorrow = try h.context.planningDay.addingDays(1)
        async let first = h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card, target: .day(tomorrow), at: fixedInstant)
        async let second = other.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card, target: .day(h.context.planningDay), at: fixedInstant)
        let results = try await [first, second]
        #expect(results.filter { $0.state == .locallyCommitted }.count == 1)
        #expect(results.filter { $0.state == .alreadyDecided }.count == 1)
        let snapshot = try await h.store.snapshot()
        #expect(snapshot.tasks.first { $0.taskID == card.taskID }?.status == .open)
        #expect(snapshot.tasks.filter { $0.plan.target != .unassigned }.count == 1)
        #expect(snapshot.tasks.filter { $0.plan.target == .unassigned }.count == 1)
        #expect(snapshot.records.filter { $0.idempotencyKey == card.decisionToken }.count == 1)
    }

    @Test("과거 토큰을 다음 작업에 붙인 재시도도 원본 영수증의 대상만 처리한다")
    func receiptCannotAdvanceAnotherCard() async throws {
        let h = try await harness(), state = try await h.widget.snapshot(at: fixedInstant)
        let original = try #require(state.card)
        _ = try await h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: original,
                                      target: .day(try h.context.planningDay.addingDays(1)), at: fixedInstant)
        let next = try await h.widget.snapshot(at: fixedInstant), visible = try #require(next.card)
        let forged = WidgetCard(cardID: visible.cardID, taskID: visible.taskID, title: visible.title,
                                deadlineSummary: visible.deadlineSummary, expected: visible.expected,
                                decisionToken: original.decisionToken, context: original.context)
        let result = try await h.widget.commit(scopeKey: next.scopeKey, sessionID: next.sessionID,
                                               card: forged, target: .day(h.context.planningDay), at: fixedInstant)
        #expect(result.state == .alreadyDecided)
        #expect(result.affectedTaskIDs == [original.taskID])
        let after = try await h.widget.snapshot(at: fixedInstant)
        #expect(after.card == visible)
        #expect(after.queue.contains(visible.taskID))
        #expect(try await h.store.snapshot().tasks.first { $0.taskID == visible.taskID }?.plan.target == .unassigned)
    }

    @Test("패널 재로드와 같은 패널 중복 입력은 계획과 카드 토큰을 바꾸지 않는다")
    func panelReloadKeepsCard() async throws {
        let h = try await harness(), initial = try await h.widget.snapshot(at: fixedInstant)
        let card = try #require(initial.card)
        try await h.widget.showPanel(scopeKey: initial.scopeKey, cardID: card.cardID,
                                     expectedPanelVersion: initial.panelVersion, panel: .nextWeek, at: fixedInstant)
        try await h.widget.showPanel(scopeKey: initial.scopeKey, cardID: card.cardID,
                                     expectedPanelVersion: initial.panelVersion, panel: .nextWeek, at: fixedInstant)
        let reloaded = try await h.widget.snapshot(at: fixedInstant)
        #expect(reloaded.panel == .nextWeek)
        #expect(reloaded.card == card)
        #expect(try await h.store.snapshot().tasks.allSatisfy { $0.plan.target == .unassigned })
    }

    @Test("자동 큐는 중간의 새 입력을 현재 카드 앞에 넣지 않는다")
    func frozenWidgetQueue() async throws {
        let h = try await harness(), initial = try await h.widget.snapshot(at: fixedInstant)
        let id = UUID()
        let result = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
            source: .share, context: h.context, workspaceEpoch: "local-v1",
            payload: .capture(taskID: id, content: try TaskContent(title: "중간에 넣은 작업"))), at: fixedInstant)
        #expect(result.state == .locallyCommitted)
        let after = try await h.widget.snapshot(at: fixedInstant)
        #expect(after.queue == initial.queue)
        #expect(after.card == initial.card)
        #expect(!after.queue.contains(id))
    }

    @Test("자정 후 상대 버튼은 새 날짜로 다시 해석하지 않는다")
    func midnightRejectsOriginalCard() async throws {
        let h = try await harness(), state = try await h.widget.snapshot(at: fixedInstant)
        let card = try #require(state.card)
        let result = try await h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card,
                                               target: .day(h.context.planningDay), at: fixedInstant.addingTimeInterval(26 * 60 * 60))
        #expect(result.state == .staleContext)
        #expect(try await h.store.snapshot().tasks.allSatisfy { $0.plan.target == .unassigned })
    }

    @Test("부분 종료는 미검토를 보존한 채 오늘 표시로 전환한다")
    func finishDoesNotPolluteToday() async throws {
        let h = try await harness(), state = try await h.widget.snapshot(at: fixedInstant)
        let result = try await h.widget.finish(scopeKey: state.scopeKey, sessionID: state.sessionID, at: fixedInstant)
        #expect(result.state == .locallyCommitted)
        let after = try await h.widget.snapshot(at: fixedInstant)
        #expect(after.mode == .today)
        #expect(after.today.isEmpty)
        #expect(try await h.store.snapshot().tasks.allSatisfy { $0.plan.target == .unassigned })
    }

    @Test("외부 제목 숨김 변경은 기존 카드에도 반영한다")
    func privacyRefreshesExistingCard() async throws {
        let h = try await harness(), visible = try await h.widget.snapshot(at: fixedInstant)
        #expect(visible.card?.title.contains("작업") == true || visible.card?.title.contains("진료") == true)
        let hidden = SystemPreferences(hideExternalTitles: true)
        try await h.store.setLocalValue(JSONEncoder().encode(hidden), forKey: "system-preferences-v1")
        let after = try await h.widget.snapshot(at: fixedInstant)
        #expect(after.card?.title == "할 일 1개")
        #expect(after.card?.taskID == visible.card?.taskID)
        #expect(after.card?.decisionToken != visible.card?.decisionToken)
    }

    @Test("위젯 Undo는 원본 결정 버전에 고정하고 후속 제목 수정은 보존한다")
    func undoKeepsNewContent() async throws {
        let h = try await harness(), state = try await h.widget.snapshot(at: fixedInstant)
        let card = try #require(state.card)
        _ = try await h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card,
                                       target: .day(try h.context.planningDay.addingDays(1)), at: fixedInstant)
        let committed = try await h.widget.snapshot(at: fixedInstant)
        let operation = try #require(committed.lastOperationID)
        let task = try #require(try await h.store.snapshot().tasks.first { $0.taskID == card.taskID })
        let version = try #require(task.versions[.content]?.headsDigest)
        _ = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
            source: .app, context: h.context, workspaceEpoch: "local-v1",
            payload: .editContent(taskID: card.taskID, content: try TaskContent(title: "새 제목"), expectedContent: version)), at: fixedInstant)
        let result = try await h.widget.undo(scopeKey: state.scopeKey, operationID: operation,
                                            expected: committed.undoExpected, at: fixedInstant)
        #expect(result.state == .locallyCommitted)
        let restored = try #require(try await h.store.snapshot().tasks.first { $0.taskID == card.taskID })
        #expect(restored.title == "새 제목")
        #expect(restored.plan.target == .unassigned)
    }

    @Test("공개 단축어는 대표 여섯 개이며 내부 위젯 명령은 검색 노출하지 않는다")
    func shortcutCatalog() {
        #expect(MirrorAppShortcuts.appShortcuts.count == 6)
        #expect(!CommitWidgetDecisionIntent.isDiscoverable)
        #expect(!ShowWidgetDatePanelIntent.isDiscoverable)
        #expect(!FinishReviewIntent.isDiscoverable)
    }
}

@Suite("알림 예약은 데이터와 전달 정책을 분리한다")
struct NotificationContractTests {
    private func context() throws -> PlanningContext {
        try PlanningContext(planningDay: LocalDate("2026-09-30"), timeZoneID: "Asia/Seoul", policyRevision: "policy-v1", capturedAt: fixedInstant)
    }
    @Test("28일 범위에서 주간이 일간을 대체하고 정리한 날은 예약하지 않는다")
    func oneReviewPerDay() throws {
        let context = try context(), closed = try LocalDate("2026-10-02")
        let now = ISO8601DateFormatter().date(from: "2026-09-29T23:00:00Z")!
        let plan = try NotificationPlanner.plan(context: context, workspaceEpoch: "e1", now: now,
            review: .init(enabled: true), closedDays: [closed], tasks: [], deadlines: [])
        #expect(plan.requests.count == 27)
        #expect(Set(plan.requests.map(\.identifier)).count == 27)
        #expect(!plan.requests.contains { $0.identifier == "review:e1:2026-10-02" })
        #expect(plan.requests.filter { $0.kind == .weeklyReview }.count == 4)
        #expect(plan.requests.contains { $0.identifier == "review:e1:2026-10-05" && $0.kind == .weeklyReview })
    }
    @Test("정리 알림 기본값은 꺼져 있고 지난 마감 알림을 한꺼번에 발송하지 않는다")
    func optInAndPastDeadline() throws {
        let plan = try NotificationPlanner.plan(context: context(), workspaceEpoch: "e1", now: fixedInstant,
            review: .init(), closedDays: [], tasks: [], deadlines: [.init(taskID: UUID(), fireAt: fixedInstant.addingTimeInterval(-1))])
        #expect(plan.requests.isEmpty)
    }
    @Test("기본 진단은 민감 원문 없이 명시 동의된 요약만 내보낸다")
    func metricsConsent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorMetrics-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metrics = LocalMetrics(directory: directory)
        try await metrics.record(.init(kind: .decisionRejected, at: fixedInstant, surface: .widget, outcome: .stale))
        await #expect(throws: SystemServiceError.invalidInput) { try await metrics.exportSummary(consentGiven: false) }
        let bytes = try await metrics.exportSummary(consentGiven: true)
        #expect(try JSONDecoder().decode([String: Int].self, from: bytes) == ["decisionRejected": 1])
        try await metrics.erase()
        #expect(try JSONDecoder().decode([String: Int].self, from: await metrics.exportSummary(consentGiven: true)).isEmpty)
    }
}
