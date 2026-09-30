import Foundation
import Darwin
import MirrorDomain
import MirrorData

public enum WidgetDisplayMode: String, Codable, Sendable {
    case loading, configurationRequired, unavailable, privacyLocked, empty, review, today
}
public enum WidgetDatePanel: String, Codable, Sendable { case card, thisWeek, nextWeek }
public struct WidgetCard: Hashable, Codable, Sendable {
    public let cardID: UUID
    public let taskID: UUID
    public let title: String
    public let deadlineSummary: String?
    public let expected: ExpectedVersions
    public let decisionToken: String
    public let context: PlanningContext
}
public struct WidgetTodayItem: Hashable, Codable, Sendable {
    public let taskID: UUID
    public let title: String
    public let expectedStatus: String
}
public struct WidgetReviewState: Hashable, Codable, Sendable {
    public var scopeKey: String
    public var mode: WidgetDisplayMode
    public var panel: WidgetDatePanel
    public var panelVersion: Int
    public var sessionID: UUID
    public var cycleID: String
    public var context: PlanningContext?
    public var queue: [UUID]
    public var queuePlanVersions: [String: String]
    public var card: WidgetCard?
    public var today: [WidgetTodayItem]
    public var lastOperationID: String?
    public var undoExpected: [TaskVersionExpectation]
    public var message: String?
    public var manualTodayOverride: Bool

    public init(scopeKey: String = "default", mode: WidgetDisplayMode, context: PlanningContext? = nil) {
        self.scopeKey = scopeKey; self.mode = mode; self.context = context
        panel = .card; panelVersion = 0; sessionID = UUID(); cycleID = ""
        queue = []; queuePlanVersions = [:]; card = nil; today = []
        lastOperationID = nil; undoExpected = []; message = nil; manualTodayOverride = false
    }
}

/// 동일 설정 위젯은 같은 scope의 세션과 카드를 공유한다. 인스턴스 고유 ID를 가정하지 않는다.
public actor WidgetReviewService {
    private let store: MirrorStore
    private let directory: URL
    private let workspaceEpoch: String
    private let metrics: LocalMetrics
    public init(store: MirrorStore, directory: URL, workspaceEpoch: String) {
        self.store = store; self.directory = directory; self.workspaceEpoch = workspaceEpoch
        metrics = LocalMetrics(directory: directory)
    }

    public func snapshot(scopeKey: String = "default", at now: Date = Date()) async throws -> WidgetReviewState {
        try await SystemStoreBoundary.validate(store)
        try validateScope(scopeKey)
        return try await locked(scopeKey) { [self] in try await loadAndRefresh(scopeKey: scopeKey, now: now) }
    }

    public func startReview(scopeKey: String = "default", todayOnly: Bool = false, at now: Date = Date()) async throws -> WidgetReviewState {
        try await SystemStoreBoundary.validate(store)
        try validateScope(scopeKey)
        return try await locked(scopeKey) { [self] in
            try await store.setLocalValue(nil, forKey: localKey(scopeKey))
            return try await loadAndRefresh(scopeKey: scopeKey, now: now, todayOnly: todayOnly, manuallyStarted: true)
        }
    }

    public func showPanel(scopeKey: String, cardID: UUID, expectedPanelVersion: Int,
                          panel: WidgetDatePanel, at now: Date = Date()) async throws {
        try await SystemStoreBoundary.validate(store)
        try validateScope(scopeKey)
        try await locked(scopeKey) { [self] in
            var state = try await loadAndRefresh(scopeKey: scopeKey, now: now)
            guard state.mode == .review, state.card?.cardID == cardID else { throw SystemServiceError.staleCard }
            if state.panel == panel { return }
            guard state.panelVersion == expectedPanelVersion else { throw SystemServiceError.staleCard }
            if state.panel != panel { state.panel = panel; state.panelVersion += 1 }
            try await save(state)
        }
        WidgetReload.request()
    }

    /// 보였던 카드 전체를 넘긴다. 현재 맨 앞의 작업을 다시 찾아 다른 작업에 적용하지 않는다.
    public func commit(scopeKey: String, sessionID: UUID, card: WidgetCard,
                       target: PlanTarget, acknowledgment: DeadlineAcknowledgment? = nil,
                       at now: Date = Date()) async throws -> CommandResult {
        try await SystemStoreBoundary.validate(store)
        try validateScope(scopeKey)
        let start = ContinuousClock.now
        let result = try await locked(scopeKey) { [self] in
            let currentSnapshot = try await store.snapshot()
            let current = try PlanningContext.capture(at: now, timeZoneID: currentSnapshot.policy.timeZoneID,
                                                     policyRevision: currentSnapshot.policy.revision)
            let decision = ReviewDecisionContext(cycleID: ReviewCycle.id(workspaceEpoch: workspaceEpoch, context: card.context),
                                                 sessionID: sessionID.uuidString, cardID: card.cardID.uuidString, taskID: card.taskID)
            let envelope = CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: card.decisionToken, source: .widget,
                                           context: card.context, workspaceEpoch: workspaceEpoch,
                                           payload: .setPlan(item: .init(taskID: card.taskID, expected: card.expected, acknowledgment: acknowledgment), target: target, review: decision))
            let hasReceipt = currentSnapshot.records.contains { $0.idempotencyKey == card.decisionToken }
            if !hasReceipt, PlanningRules.checkContext(displayed: card.context, current: current, matchingReceiptExists: false) != .staleContext {
                guard let data = try await store.localValue(forKey: localKey(scopeKey)),
                      let visible = try? JSONDecoder().decode(WidgetReviewState.self, from: data),
                      visible.sessionID == sessionID, visible.card == card else {
                    return CommandResult(requestID: envelope.requestID, state: .staleSnapshot,
                                         safeUserMessage: "카드가 바뀌었어요. 새 카드를 확인하세요.", affectedTaskIDs: [card.taskID])
                }
            }
            // receipt 우선 검사는 canonical store 안에서 실행한다. 날짜/세션이 바뀐 재시도도 원래 결과를 얻는다.
            let result = await store.execute(envelope, context: current)
            var state: WidgetReviewState
            if let data = try await store.localValue(forKey: localKey(scopeKey)) {
                state = try JSONDecoder().decode(WidgetReviewState.self, from: data)
            } else { state = try await loadAndRefresh(scopeKey: scopeKey, now: now) }
            if [.locallyCommitted, .alreadyApplied, .alreadyDecided].contains(result.state) {
                if state.sessionID == sessionID {
                    // 재시도는 원본 영수증의 대상으로 제한한다. 변조된 payload로 다음 카드를 진행시키지 않는다.
                    let affected = Set(result.affectedTaskIDs)
                    state.queue.removeAll { affected.contains($0) }
                    if let visible = state.card, affected.contains(visible.taskID) {
                        state.card = nil; state.panel = .card; state.panelVersion += 1
                    }
                    if let operationID = result.operationID,
                       let operation = try await store.snapshot().records.first(where: { $0.operationID == operationID }) {
                        state.lastOperationID = operationID
                        state.undoExpected = operation.undoExpectations()
                    }
                    state.message = result.safeUserMessage
                    try await save(state)
                    state = try await loadAndRefresh(scopeKey: scopeKey, now: now)
                    if state.queue.isEmpty { _ = try await close(state: state, now: now) }
                }
            } else {
                state.message = result.safeUserMessage
                // 저장 실패는 패널/카드를 진행시키지 않는다. stale 결과만 최신 snapshot을 다시 받는다.
                try await save(state)
            }
            return result
        }
        let elapsed = start.duration(to: .now).components
        let milliseconds = max(0, elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        let outcome: MetricOutcome = [.locallyCommitted, .alreadyApplied].contains(result.state) ? .success :
            result.state == .committedProjectionPending ? .projectionPending : result.state == .requiresConfirmation ? .confirmation :
            [.staleContext, .staleSnapshot, .alreadyDecided].contains(result.state) ? .stale : .failure
        try? await metrics.record(.init(kind: .widgetInteractionFinished, at: now, surface: .widget, outcome: outcome,
                                       processingMilliseconds: Int(milliseconds)))
        WidgetReload.request()
        return result
    }

    public func finish(scopeKey: String, sessionID: UUID, at now: Date = Date()) async throws -> CommandResult {
        try await SystemStoreBoundary.validate(store)
        try validateScope(scopeKey)
        let result = try await locked(scopeKey) { [self] in
            let state = try await loadAndRefresh(scopeKey: scopeKey, now: now)
            guard state.sessionID == sessionID else { throw SystemServiceError.staleCard }
            return try await close(state: state, now: now)
        }
        WidgetReload.request()
        return result
    }

    public func undo(scopeKey: String, operationID: String, expected: [TaskVersionExpectation],
                     at now: Date = Date()) async throws -> CommandResult {
        try await SystemStoreBoundary.validate(store)
        try validateScope(scopeKey)
        let result = try await locked(scopeKey) { [self] in
            let snapshot = try await store.snapshot()
            let context = try PlanningContext.capture(at: now, timeZoneID: snapshot.policy.timeZoneID, policyRevision: snapshot.policy.revision)
            let envelope = CommandEnvelope(requestID: UUID().uuidString,
                                           idempotencyKey: "undo:\(operationID):\(try CanonicalDigest.hash(expected))", source: .widget,
                                           context: context, workspaceEpoch: workspaceEpoch,
                                           payload: .undo(operationID: operationID, expected: expected))
            let result = await store.execute(envelope, context: context)
            var state = try await loadAndRefresh(scopeKey: scopeKey, now: now)
            state.message = result.safeUserMessage
            if [.locallyCommitted, .alreadyApplied].contains(result.state) {
                state.lastOperationID = nil; state.undoExpected = []
            }
            try await save(state)
            return result
        }
        WidgetReload.request()
        return result
    }

    private func close(state: WidgetReviewState, now: Date) async throws -> CommandResult {
        guard let displayed = state.context else { throw SystemServiceError.unavailable }
        let snapshot = try await store.snapshot()
        let current = try PlanningContext.capture(at: now, timeZoneID: snapshot.policy.timeZoneID, policyRevision: snapshot.policy.revision)
        let envelope = CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: "finish:\(state.sessionID.uuidString)",
                                       source: .widget, context: displayed, workspaceEpoch: workspaceEpoch,
                                       payload: .reviewClose(.init(cycleID: state.cycleID, sessionID: state.sessionID.uuidString)))
        let result = await store.execute(envelope, context: current)
        var updated = state
        updated.message = result.safeUserMessage
        if [.locallyCommitted, .alreadyApplied].contains(result.state) {
            updated.mode = .today; updated.card = nil; updated.panel = .card; updated.manualTodayOverride = false
        }
        try await save(updated)
        return result
    }

    private func loadAndRefresh(scopeKey: String, now: Date, todayOnly: Bool = false,
                                 manuallyStarted: Bool = false) async throws -> WidgetReviewState {
        let snapshot = try await store.snapshot()
        let context = try PlanningContext.capture(at: now, timeZoneID: snapshot.policy.timeZoneID, policyRevision: snapshot.policy.revision)
        let preferences: SystemPreferences
        if let value = try await store.localValue(forKey: "system-preferences-v1") {
            preferences = try JSONDecoder().decode(SystemPreferences.self, from: value)
        } else { preferences = .init() }
        let report = TaskReducer.reduce(snapshot.records, workspaceKey: snapshot.workspaceKey, workspaceEpoch: snapshot.workspaceEpoch)
        let cycle = ReviewCycle.id(workspaceEpoch: workspaceEpoch, context: context)
        var state: WidgetReviewState
        if let data = try await store.localValue(forKey: localKey(scopeKey)),
           let existing = try? JSONDecoder().decode(WidgetReviewState.self, from: data),
           existing.cycleID == cycle, existing.context?.timeZoneID == context.timeZoneID { state = existing }
        else {
            state = .init(scopeKey: scopeKey, mode: .review, context: context)
            state.cycleID = cycle; state.manualTodayOverride = todayOnly
            let mode: ReviewMode = todayOnly ? .manualTodayOverride : manuallyStarted ? .manualResume : .automatic
            let candidates = snapshot.tasks.filter {
                $0.isProjectionComplete && PlanningRules.isReviewCandidate($0.planningState, on: context.planningDay,
                    acknowledgedCurrentPlan: report.acknowledges(task: $0, cycleID: cycle),
                    cycleClosed: report.isCycleClosed(cycle), mode: mode)
            }.sorted { reviewOrder($0, context: context) < reviewOrder($1, context: context) }
            state.queue = candidates.map(\.taskID)
            state.queuePlanVersions = Dictionary(uniqueKeysWithValues: candidates.compactMap { task in
                task.versions[.plan].map { (task.taskID.uuidString, $0.headsDigest) }
            })
            if report.isCycleClosed(cycle), !manuallyStarted { state.mode = .today }
        }
        let decisionOrder = Dictionary(snapshot.records.filter { report.appliedOperationIDs.contains($0.operationID) }
            .map { ($0.operationID, $0.lamport) }, uniquingKeysWith: { first, _ in first })
        state.today = snapshot.tasks.filter { PlanningRules.isToday($0.planningState, on: context.planningDay) && $0.isProjectionComplete }
            .sorted {
                let left = $0.versions[.plan].flatMap { decisionOrder[$0.winningOperationID] } ?? 0
                let right = $1.versions[.plan].flatMap { decisionOrder[$0.winningOperationID] } ?? 0
                return left == right ? $0.taskID.uuidString < $1.taskID.uuidString : left < right
            }
            .prefix(5).compactMap { task in
                task.versions[.status].map { .init(taskID: task.taskID, title: preferences.hideExternalTitles ? "할 일" : task.title, expectedStatus: $0.headsDigest) }
            }
        if report.isCycleClosed(cycle), !state.manualTodayOverride { state.mode = .today; state.card = nil }
        if state.mode == .review || state.mode == .empty {
            let indexed = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.taskID, $0) })
            state.queue.removeAll { id in
                guard let task = indexed[id], task.isProjectionComplete else { return true }
                return !PlanningRules.isReviewCandidate(task.planningState, on: context.planningDay,
                    acknowledgedCurrentPlan: report.acknowledges(task: task, cycleID: cycle), cycleClosed: false,
                    mode: state.manualTodayOverride ? .manualTodayOverride : .manualResume)
            }
            if let id = state.queue.first, let task = indexed[id] {
                let expected = ExpectedVersions(task)
                let title = preferences.hideExternalTitles ? "할 일 1개" : task.title
                if state.card?.taskID != id || state.card?.expected != expected || state.card?.title != title {
                    state.card = WidgetCard(cardID: UUID(), taskID: id, title: title,
                                            deadlineSummary: try task.deadline?.planningDate(in: context).description,
                                            expected: expected, decisionToken: UUID().uuidString, context: context)
                    state.panel = .card; state.panelVersion += 1
                }
                state.mode = .review
            } else { state.card = nil; state.mode = .empty }
        }
        try await save(state)
        return state
    }

    private func reviewOrder(_ task: TaskProjection, context: PlanningContext) -> (Int, Date, String) {
        let deadline = try? task.deadline?.planningDate(in: context)
        let rank: Int
        if let deadline, deadline < context.planningDay { rank = 0 }
        else if let deadline, deadline <= ((try? context.planningDay.addingDays(1)) ?? context.planningDay) { rank = 1 }
        else {
            switch task.plan.target {
            case let .day(day): rank = day < context.planningDay ? 2 : 3
            case .week: rank = 4
            case .unassigned: rank = 5
            case .parked: rank = 6
            }
        }
        return (rank, task.createdAt, task.taskID.uuidString)
    }

    private func save(_ state: WidgetReviewState) async throws {
        try await store.setLocalValue(JSONEncoder().encode(state), forKey: localKey(state.scopeKey))
    }
    private func localKey(_ scope: String) -> String { "widget-presentation-v1:\(scope)" }
    private func validateScope(_ scope: String) throws {
        guard (1...128).contains(scope.utf8.count), scope.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:")).contains($0) }) else {
            throw SystemServiceError.invalidInput
        }
    }
    private func locked<T: Sendable>(_ scope: String, operation: @Sendable () async throws -> T) async throws -> T {
        let gate = WidgetPresentationGate(url: directory.appendingPathComponent("WidgetPresentation.lock"))
        let descriptor = try await gate.acquire()
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        return try await operation()
    }
}

/// actor 한 개가 아니라 프로세스 간 잠금으로 presentation의 read/modify/write를 묶는다.
private struct WidgetPresentationGate: Sendable {
    let url: URL
    func acquire() async throws -> Int32 {
        try await Task.detached {
            let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw SystemServiceError.unavailable }
            let start = ContinuousClock.now
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                if Task.isCancelled { Darwin.close(descriptor); throw CancellationError() }
                if start.duration(to: .now) > .milliseconds(250) { Darwin.close(descriptor); throw StoreError.busy }
                usleep(10_000)
            }
            return descriptor
        }.value
    }
}
