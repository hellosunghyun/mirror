import Foundation
import Darwin
import Testing
import MirrorDomain
import MirrorData
@testable import MirrorSystem

private let fixedInstant = ISO8601DateFormatter().date(from: "2026-09-30T03:15:00Z")!

/// 경로·식별자·테스트 데이터 대신 공개 host 구조의 존재 여부만 한 번 기록한다.
private let systemHostStructureNotice: Void = {
    let bundle = Bundle.main
    let info = bundle.infoDictionary ?? [:]
    let pathExtension = bundle.bundleURL.pathExtension.lowercased()
    let publicExtension = ["app", "appex", "xctest"].contains(pathExtension) ? pathExtension : "other"
    let hasGroupMarker = info["MirrorAppGroupIdentifier"] != nil
    let hasCloudMarker = info["MirrorCloudContainerIdentifier"] != nil
    let hasExtensionMarker = info["NSExtension"] != nil
    let hasRunnerMarker = bundle.bundleIdentifier?.hasSuffix(".xctrunner") == true
    let types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
    let hasProductURLScheme = types.contains { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains("mirror") }
    print("[MirrorSystemHost] bundleExtension=\(publicExtension) runtimeAllowsOS=\(SystemAppleRuntimeHost.isApplicationOrExtension) groupMarker=\(hasGroupMarker) cloudMarker=\(hasCloudMarker) extensionMarker=\(hasExtensionMarker) runnerMarker=\(hasRunnerMarker) productURLScheme=\(hasProductURLScheme)")
}()

private struct WidgetHarness {
    let directory: URL
    let store: MirrorStore
    let widget: WidgetReviewService
    let context: PlanningContext
    let first: UUID
    let second: UUID
}
private func harness(twoTasks: Bool = true) async throws -> WidgetHarness {
    _ = systemHostStructureNotice
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

private func widgetDecisionEnvelope(_ state: WidgetReviewState, card: WidgetCard, target: PlanTarget,
                                    acknowledgment: DeadlineAcknowledgment? = nil) -> CommandEnvelope {
    CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: card.decisionToken, source: .widget,
        context: card.context, workspaceEpoch: "local-v1",
        payload: .setPlan(item: .init(taskID: card.taskID, expected: card.expected, acknowledgment: acknowledgment),
            target: target, review: .init(cycleID: state.cycleID, sessionID: state.sessionID.uuidString,
                                        cardID: card.cardID.uuidString, taskID: card.taskID)))
}

private func setWidgetHarnessDeadlines(_ h: WidgetHarness) async throws {
    for task in try await h.store.snapshot().tasks {
        let saved = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
            source: .app, context: h.context, workspaceEpoch: "local-v1",
            payload: .setDeadline(taskID: task.taskID,
                deadline: .day(localDate: h.context.planningDay, timeZoneID: h.context.timeZoneID),
                expectedDeadline: try #require(task.versions[.deadline]?.headsDigest))), at: fixedInstant)
        #expect(saved.state == .locallyCommitted)
    }
}

/// sleep으로 순서를 추측하지 않고 실제 gate 등록·진입·해제를 연결한다.
private final class WidgetGateSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var isSignalled: Bool { lock.withLock { signalled } }
    func signal() {
        let continuations = lock.withLock {
            signalled = true
            let continuations = waiting
            waiting.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock {
                    if signalled { return true }
                    waiting.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            // 테스트 취소가 barrier 자체에 갇히지 않고 defer cleanup까지 도달한다.
            self.signal()
        }
    }
}

private actor WidgetGateProbe {
    let gate: WidgetPresentationGate
    init(gate: WidgetPresentationGate) { self.gate = gate }
    func enter(_ entered: WidgetGateSignal, until release: WidgetGateSignal? = nil) async throws {
        try await gate.withLock {
            entered.signal()
            if let release { await release.wait() }
            try Task.checkCancellation()
        }
    }
}

private func widgetGateDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorWidgetGate-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("시스템 경계와 실제 SQLite 위젯 명령")
struct SystemContractTests {
    private func searchTask(title: String, status: TaskStatus, complete: Bool = true) throws -> TaskProjection {
        TaskProjection(taskID: UUID(), workspaceKey: "personal-v1", workspaceEpoch: "local-v1",
                       content: try TaskContent(title: title), plan: .init(target: .unassigned),
                       lifecycle: .init(status: status, completedAt: status == .completed ? fixedInstant : nil,
                                        deletedAt: status == .deleted ? fixedInstant : nil),
                       deadline: nil, createdAt: fixedInstant, versions: [:], isProjectionComplete: complete)
    }

    @Test("제목 검색의 첫 50개가 다른 상태여도 뒤의 일치 상태를 찾고 결과만 50개로 제한한다")
    func searchFiltersStatusBeforeLimit() throws {
        for status in [MirrorTaskStatusFilter.open, .completed] {
            let desired: TaskStatus = status == .completed ? .completed : .open
            let other: TaskStatus = desired == .open ? .completed : .open
            let leading = try (0..<60).map { try searchTask(title: "검색 대상 \($0)", status: other) }
            let matching = try (0..<55).map { try searchTask(title: "검색 대상 뒤 \($0)", status: desired) }
            let result = MirrorTaskSearchPolicy.matches(leading + matching, query: "검색 대상", status: status)
            #expect(result.count == 50)
            #expect(result.map(\.taskID) == matching.prefix(50).map(\.taskID))
        }
    }

    @Test("제목과 명시 ID 검색은 삭제·불완전 작업을 제외하고 상태 조건을 함께 적용한다")
    func searchKeepsIDAndEligibility() throws {
        let open = try searchTask(title: "검색 대상 미완료", status: .open)
        let completed = try searchTask(title: "검색 대상 완료", status: .completed)
        let deleted = try searchTask(title: "검색 대상 삭제", status: .deleted)
        let incomplete = try searchTask(title: "검색 대상 불완전", status: .open, complete: false)
        let unrelated = try searchTask(title: "다른 제목", status: .open)
        let tasks = [deleted, incomplete, unrelated, open, completed]
        #expect(MirrorTaskSearchPolicy.matches(tasks, query: "검색 대상", status: nil).map(\.taskID) == [open.taskID, completed.taskID])
        #expect(MirrorTaskSearchPolicy.matches(tasks, query: completed.taskID.uuidString, status: .completed).map(\.taskID) == [completed.taskID])
        #expect(MirrorTaskSearchPolicy.matches(tasks, query: completed.taskID.uuidString, status: .open).isEmpty)
        #expect(MirrorTaskSearchPolicy.matches(tasks, query: deleted.taskID.uuidString, status: nil).isEmpty)
        #expect(MirrorTaskSearchPolicy.matches(tasks, query: incomplete.taskID.uuidString, status: nil).isEmpty)
    }

    @Test("제목 없이 상태만 찾을 때도 앞의 다른 상태를 건너뛰고 일치 결과를 제한한다")
    func searchStatusOnlyLimitsMatches() throws {
        let completed = try (0..<60).map { try searchTask(title: "완료 \($0)", status: .completed) }
        let open = try (0..<55).map { try searchTask(title: "미완료 \($0)", status: .open) }
        let result = MirrorTaskSearchPolicy.matches(completed + open, query: nil, status: .open)
        #expect(result.map(\.taskID) == open.prefix(50).map(\.taskID))
    }

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

    @Test("동일 설정 위젯 두 서비스는 같은 카드·토큰을 받고 서로 다른 빠른 탭도 한 작업만 바꾼다", .timeLimit(.minutes(1)))
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

    @Test("presentation 대기는 같은 actor 재진입과 경로 별칭을 직렬화하고 다른 저장소는 막지 않는다", .timeLimit(.minutes(1)))
    func presentationQueueSeparatesDirectories() async throws {
        let directory = try widgetGateDirectory(), otherDirectory = try widgetGateDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        let queued = WidgetGateSignal(), entered = WidgetGateSignal(), release = WidgetGateSignal()
        let nextEntered = WidgetGateSignal(), aliasQueued = WidgetGateSignal(), aliasEntered = WidgetGateSignal()
        let probe = WidgetGateProbe(gate: .init(directory: directory, onQueued: { queued.signal() }))
        let first = Task { try await probe.enter(entered, until: release) }
        defer { release.signal(); first.cancel() }
        await entered.wait()
        let second = Task { try await probe.enter(nextEntered) }
        defer { second.cancel() }
        await queued.wait()
        let alias = WidgetPresentationGate(directory: URL(fileURLWithPath: directory.path + "/./"),
            onQueued: { aliasQueued.signal() })
        let third = Task {
            try await alias.withLock {
                #expect(nextEntered.isSignalled)
                aliasEntered.signal()
            }
        }
        defer { third.cancel() }
        await aliasQueued.wait()
        let independent = try await WidgetPresentationGate(directory: otherDirectory).withLock { true }
        #expect(independent)
        #expect(!nextEntered.isSignalled)
        #expect(!aliasEntered.isSignalled)
        release.signal()
        try await first.value
        try await second.value
        try await third.value
        #expect(nextEntered.isSignalled)
        #expect(aliasEntered.isSignalled)
    }

    @Test("presentation 등록 전·대기 중·선택 뒤 취소와 작업 오류는 다음 요청을 막지 않는다", .timeLimit(.minutes(1)))
    func presentationCancellationReleasesTurn() async throws {
        let directory = try widgetGateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = WidgetPresentationGate(directory: directory)
        let start = WidgetGateSignal(), cancelledEntry = WidgetGateSignal()
        let cancelledBeforeRegistration = Task {
            await start.wait()
            try await gate.withLock { cancelledEntry.signal() }
        }
        cancelledBeforeRegistration.cancel()
        start.signal()
        await #expect(throws: CancellationError.self) { try await cancelledBeforeRegistration.value }
        #expect(!cancelledEntry.isSignalled)

        let entered = WidgetGateSignal(), release = WidgetGateSignal(), queued = WidgetGateSignal()
        let first = Task { try await gate.withLock { entered.signal(); await release.wait() } }
        defer { release.signal(); first.cancel() }
        await entered.wait()
        let waitingGate = WidgetPresentationGate(directory: directory, onQueued: { queued.signal() })
        let waiting = Task { try await waitingGate.withLock { cancelledEntry.signal() } }
        defer { waiting.cancel() }
        await queued.wait()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(!cancelledEntry.isSignalled)
        release.signal()
        try await first.value

        let selected = WidgetGateSignal(), finish = WidgetGateSignal()
        let active = Task {
            try await gate.withLock {
                selected.signal()
                await finish.wait()
                try Task.checkCancellation()
            }
        }
        defer { finish.signal(); active.cancel() }
        await selected.wait()
        active.cancel()
        finish.signal()
        await #expect(throws: CancellationError.self) { try await active.value }
        await #expect(throws: SystemServiceError.invalidInput) {
            try await gate.withLock { () async throws -> Void in throw SystemServiceError.invalidInput }
        }
        #expect(try await gate.withLock { true })
    }

    @Test("외부 presentation flock은 기존 busy 제한을 유지하고 해제 뒤 다시 진입한다", .timeLimit(.minutes(1)))
    func presentationFileLockRemainsBounded() async throws {
        let directory = try widgetGateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = Darwin.open(directory.appendingPathComponent("WidgetPresentation.lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        try #require(descriptor >= 0)
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let gate = WidgetPresentationGate(directory: directory)
        let start = ContinuousClock.now
        await #expect(throws: StoreError.busy) { try await gate.withLock { } }
        #expect(start.duration(to: .now) >= .milliseconds(250))
        try #require(flock(descriptor, LOCK_UN) == 0)
        #expect(try await gate.withLock { true })
    }

    @Test("과거 토큰을 다음 작업에 붙인 재시도도 원본 영수증의 대상만 처리한다", .timeLimit(.minutes(1)))
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

    @Test("자정 후 상대 버튼은 새 날짜로 다시 해석하지 않는다", .timeLimit(.minutes(1)))
    func midnightRejectsOriginalCard() async throws {
        let h = try await harness(), state = try await h.widget.snapshot(at: fixedInstant)
        let card = try #require(state.card)
        let result = try await h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card,
                                               target: .day(h.context.planningDay), at: fixedInstant.addingTimeInterval(26 * 60 * 60))
        #expect(result.state == .staleContext)
        #expect(try await h.store.snapshot().tasks.allSatisfy { $0.plan.target == .unassigned })
        let observationID = UUID()
        let owner = WidgetDecisionOwnership(requestID: UUID(), observationID: observationID, workspaceKey: "personal-v1",
            envelope: widgetDecisionEnvelope(state, card: card, target: .day(h.context.planningDay)))
        #expect(!owner.retainsDecision(after: result, displayUpdated: false))
        #expect(WorkspaceChangeBlocker.current(detailEditing: false, capture: false, projectionPending: false,
            saving: false, pendingCommand: owner.retainsDecision(after: result, displayUpdated: false)) == nil)
        #expect(owner.isCurrent(owner, observationID: observationID, workspaceKey: "personal-v1", workspaceEpoch: "local-v1"))
        let replacement = WidgetDecisionOwnership(requestID: UUID(), observationID: observationID,
            workspaceKey: "personal-v1", envelope: owner.envelope)
        #expect(!owner.isCurrent(replacement, observationID: observationID, workspaceKey: "personal-v1", workspaceEpoch: "local-v1"))
        #expect(!owner.isCurrent(owner, observationID: UUID(), workspaceKey: "personal-v1", workspaceEpoch: "local-v1"))
        #expect(!owner.isCurrent(owner, observationID: observationID, workspaceKey: "other", workspaceEpoch: "local-v1"))
        #expect(!owner.isCurrent(owner, observationID: observationID, workspaceKey: "personal-v1", workspaceEpoch: "reset"))
    }

    @Test("외부 계획 변경과 이미 결정된 위젯 카드는 재시도 소유를 해제한다", .timeLimit(.minutes(1)))
    func widgetDefinitiveRejectionsReleaseRetryOwnership() async throws {
        let h = try await harness(), state = try await h.widget.snapshot(at: fixedInstant)
        let card = try #require(state.card), target = PlanTarget.day(h.context.planningDay)
        let envelope = widgetDecisionEnvelope(state, card: card, target: target)
        let owner = WidgetDecisionOwnership(requestID: UUID(), observationID: UUID(), workspaceKey: "personal-v1", envelope: envelope)
        let external = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
            source: .app, context: h.context, workspaceEpoch: "local-v1",
            payload: .setPlan(item: .init(taskID: card.taskID, expected: card.expected), target: target, review: nil)), at: fixedInstant)
        #expect(external.state == .locallyCommitted)
        let stale = try await h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card,
            target: .day(try h.context.planningDay.addingDays(1)), at: fixedInstant)
        #expect(stale.state == .staleSnapshot)
        #expect(!owner.retainsDecision(after: stale, displayUpdated: false))
        #expect(try await h.store.taskProjection(card.taskID)?.plan.target == target)

        let fresh = try await h.widget.snapshot(at: fixedInstant), next = try #require(fresh.card)
        let nextOwner = WidgetDecisionOwnership(requestID: UUID(), observationID: UUID(), workspaceKey: "personal-v1",
            envelope: widgetDecisionEnvelope(fresh, card: next, target: target))
        let committed = try await h.widget.commit(scopeKey: fresh.scopeKey, sessionID: fresh.sessionID, card: next,
            target: target, at: fixedInstant)
        #expect(committed.state == .locallyCommitted)
        let decided = try await h.widget.commit(scopeKey: fresh.scopeKey, sessionID: fresh.sessionID, card: next,
            target: .day(try h.context.planningDay.addingDays(2)), at: fixedInstant)
        #expect(decided.state == .alreadyDecided)
        #expect(!nextOwner.retainsDecision(after: decided, displayUpdated: false))
        #expect(try await h.store.snapshot().records.filter { $0.idempotencyKey == next.decisionToken }.count == 1)

        // notFound도 원본 생성 전의 확정 거절이다. 존재하지 않는 task ID를 새 대상으로 바꾸지 않는다.
        let missingEnvelope = CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
            source: .widget, context: h.context, workspaceEpoch: "local-v1",
            payload: .setPlan(item: .init(taskID: UUID(), expected: card.expected), target: target, review: nil))
        let missingOwner = WidgetDecisionOwnership(requestID: UUID(), observationID: UUID(), workspaceKey: "personal-v1",
                                                  envelope: missingEnvelope)
        let missing = await h.store.execute(missingEnvelope, at: fixedInstant)
        #expect(missing.state == .notFound)
        #expect(!missingOwner.retainsDecision(after: missing, displayUpdated: false))
        #expect(!((try await h.store.snapshot()).records.contains { $0.idempotencyKey == missingEnvelope.idempotencyKey }))
    }

    @Test("마감 승인된 위젯 저장 장애는 같은 승인·토큰으로 재시도하고 원본 하나만 남긴다", .timeLimit(.minutes(1)))
    func acknowledgedWidgetRetryPreservesOriginalCommand() async throws {
        for failurePoint in [StoreFailurePoint.beforeCanonicalSave, .afterCanonicalSave] {
            let h = try await harness(twoTasks: false)
            try await setWidgetHarnessDeadlines(h)
            let state = try await h.widget.snapshot(at: fixedInstant), card = try #require(state.card)
            let target = PlanTarget.day(try h.context.planningDay.addingDays(1))
            let acknowledgment = DeadlineAcknowledgment(taskID: card.taskID.uuidString,
                deadlineRevision: try #require(card.expected.deadline), target: target)
            let envelope = widgetDecisionEnvelope(state, card: card, target: target, acknowledgment: acknowledgment)
            let owner = WidgetDecisionOwnership(requestID: UUID(), observationID: UUID(), workspaceKey: "personal-v1", envelope: envelope)
            let failed = await h.store.execute(envelope, at: fixedInstant, failurePoint: failurePoint)
            #expect(failed.state == (failurePoint == .beforeCanonicalSave ? .persistenceFailed : .committedProjectionPending))
            #expect(owner.retainsDecision(after: failed, displayUpdated: false))
            #expect(WorkspaceChangeBlocker.current(detailEditing: false, capture: false, projectionPending: false,
                saving: false, pendingCommand: owner.retainsDecision(after: failed, displayUpdated: false)) == .pendingCommand)
            guard case let .setPlan(item, retainedTarget, _) = owner.envelope.payload else {
                Issue.record("위젯 명령을 유지해야 한다"); continue
            }
            #expect(item.acknowledgment == acknowledgment)
            let retried = try await h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card,
                target: retainedTarget, acknowledgment: item.acknowledgment, at: fixedInstant)
            #expect(retried.state == (failurePoint == .beforeCanonicalSave ? .locallyCommitted : .alreadyApplied))
            #expect(owner.retainsDecision(after: retried, displayUpdated: false))
            #expect(!owner.retainsDecision(after: retried, displayUpdated: true))
            #expect(WorkspaceChangeBlocker.current(detailEditing: false, capture: false, projectionPending: false,
                saving: false, pendingCommand: owner.retainsDecision(after: retried, displayUpdated: true)) == nil)
            let repeated = try await h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card,
                target: retainedTarget, acknowledgment: item.acknowledgment, at: fixedInstant.addingTimeInterval(26 * 60 * 60))
            #expect(repeated.state == .alreadyApplied)
            let snapshot = try await h.store.snapshot()
            #expect(snapshot.records.filter { $0.idempotencyKey == owner.envelope.idempotencyKey }.count == 1)
            #expect(snapshot.tasks.first { $0.taskID == card.taskID }?.plan.target == target)
        }
    }

    @Test("명시적 위젯 재시도는 같은 저장소 actor 재관측만 연결하고 재개설·다른 공간은 거절한다", .timeLimit(.minutes(1)))
    func widgetRetryRebindsOnlySameLiveStore() async throws {
        let h = try await harness(), state = try await h.widget.snapshot(at: fixedInstant)
        let card = try #require(state.card), target = PlanTarget.day(h.context.planningDay)
        let configuration = await h.store.configuration
        let original = WidgetDecisionOwnership(requestID: UUID(), observationID: UUID(), workspaceKey: configuration.workspaceKey,
            envelope: widgetDecisionEnvelope(state, card: card, target: target))
        let failed = await h.store.execute(original.envelope, at: fixedInstant, failurePoint: .beforeCanonicalSave)
        #expect(failed.state == .persistenceFailed)
        #expect(original.retainsDecision(after: failed, displayUpdated: false))
        let nextObservation = UUID()
        let rebound = try #require(original.rebindingForRetry(observationID: nextObservation,
            originalStore: h.store, currentStore: h.store, originalConfiguration: configuration, currentConfiguration: configuration))
        #expect(rebound.envelope == original.envelope)
        #expect(rebound.requestID == original.requestID)
        #expect(rebound.isCurrent(rebound, observationID: nextObservation, workspaceKey: configuration.workspaceKey,
                                  workspaceEpoch: configuration.workspaceEpoch))
        #expect(!original.isCurrent(rebound, observationID: nextObservation, workspaceKey: configuration.workspaceKey,
                                    workspaceEpoch: configuration.workspaceEpoch))
        let reopened = try await MirrorStore(configuration: configuration)
        #expect(original.rebindingForRetry(observationID: nextObservation, originalStore: h.store,
            currentStore: reopened, originalConfiguration: configuration, currentConfiguration: configuration) == nil)
        for changed in [
            StoreConfiguration(directory: configuration.directory.appendingPathComponent("other"), deviceID: configuration.deviceID),
            StoreConfiguration(directory: configuration.directory, workspaceKey: "other", deviceID: configuration.deviceID),
            StoreConfiguration(directory: configuration.directory, workspaceEpoch: "reset", deviceID: configuration.deviceID),
            StoreConfiguration(directory: configuration.directory, deviceID: configuration.deviceID,
                cloudSync: .init(containerIdentifier: "test-container", accountScope: "test-account"))
        ] {
            #expect(original.rebindingForRetry(observationID: nextObservation, originalStore: h.store,
                currentStore: h.store, originalConfiguration: configuration, currentConfiguration: changed) == nil)
        }
        let retried = try await h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card,
                                                target: target, at: fixedInstant)
        #expect(retried.state == .locallyCommitted)
        #expect(!rebound.retainsDecision(after: retried, displayUpdated: true))
        #expect(try await h.store.snapshot().records.filter { $0.idempotencyKey == original.envelope.idempotencyKey }.count == 1)
    }

    @Test("취소한 위젯 A의 확인은 앱 B의 마감 확인·자동 해제를 소비하거나 A를 변경하지 않는다", .timeLimit(.minutes(1)))
    func deadlineConfirmationOwnsDisplayedTaskAndRequest() async throws {
        let h = try await harness()
        try await setWidgetHarnessDeadlines(h)
        let state = try await h.widget.snapshot(at: fixedInstant), card = try #require(state.card)
        let target = PlanTarget.day(try h.context.planningDay.addingDays(1))
        let widgetEnvelope = widgetDecisionEnvelope(state, card: card, target: target)
        let observationID = UUID()
        let owner = WidgetDecisionOwnership(requestID: UUID(), observationID: observationID,
                                            workspaceKey: "personal-v1", envelope: widgetEnvelope)
        let widgetResult = try await h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card,
                                                     target: target, at: fixedInstant)
        #expect(widgetResult.state == .requiresConfirmation)
        #expect(owner.retainsDecision(after: widgetResult, displayUpdated: false))
        let other = try #require(try await h.store.snapshot().tasks.first { $0.taskID != card.taskID })
        let appEnvelope = CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString, source: .app,
            context: h.context, workspaceEpoch: "local-v1",
            payload: .setPlan(item: .init(taskID: other.taskID, expected: ExpectedVersions(other)), target: target, review: nil))
        let appResult = await h.store.execute(appEnvelope, at: fixedInstant)
        #expect(appResult.state == .requiresConfirmation)
        #expect(owner.ownsConfirmation(widgetEnvelope, observationID: observationID, workspaceKey: "personal-v1", workspaceEpoch: "local-v1"))
        #expect(!owner.ownsConfirmation(appEnvelope, observationID: observationID, workspaceKey: "personal-v1", workspaceEpoch: "local-v1"))
        #expect(!owner.ownsConfirmation(widgetEnvelope, observationID: UUID(), workspaceKey: "personal-v1", workspaceEpoch: "local-v1"))
        let targetPayload = widgetDecisionEnvelope(state, card: card, target: .day(try h.context.planningDay.addingDays(2))).payload
        let differentTarget = CommandEnvelope(requestID: widgetEnvelope.requestID, idempotencyKey: widgetEnvelope.idempotencyKey,
            source: .widget, context: widgetEnvelope.context, workspaceEpoch: "local-v1", payload: targetPayload)
        #expect(!owner.ownsConfirmation(differentTarget, observationID: observationID, workspaceKey: "personal-v1", workspaceEpoch: "local-v1"))
        let differentToken = CommandEnvelope(requestID: widgetEnvelope.requestID, idempotencyKey: UUID().uuidString,
            source: .widget, context: widgetEnvelope.context, workspaceEpoch: "local-v1", payload: widgetEnvelope.payload)
        #expect(!owner.ownsConfirmation(differentToken, observationID: observationID, workspaceKey: "personal-v1", workspaceEpoch: "local-v1"))

        var confirmation = DeadlineConfirmationState()
        confirmation.replace(with: widgetEnvelope)
        confirmation.dismiss(widgetEnvelope)
        let canceled = confirmation.take(widgetEnvelope)
        #expect(canceled == widgetEnvelope)
        confirmation.replace(with: appEnvelope)
        confirmation.dismiss(widgetEnvelope)
        let lateWidget = confirmation.take(widgetEnvelope)
        #expect(lateWidget == nil)
        #expect(confirmation.presented == appEnvelope)
        confirmation.dismiss(appEnvelope)
        let consumed = confirmation.take(appEnvelope)
        let displayed = try #require(consumed)
        let duplicate = confirmation.take(appEnvelope)
        #expect(duplicate == nil)
        #expect(displayed == appEnvelope)
        confirmation.replace(with: appEnvelope)
        let beforeDismiss = confirmation.take(appEnvelope)
        confirmation.dismiss(appEnvelope)
        #expect(beforeDismiss == appEnvelope)
        #expect(confirmation.presented == nil)
        confirmation.replace(with: widgetEnvelope)
        confirmation.replace(with: nil)
        let previousWorkspace = confirmation.take(widgetEnvelope)
        #expect(previousWorkspace == nil)

        let acknowledgment = DeadlineAcknowledgment(taskID: other.taskID.uuidString,
            deadlineRevision: try #require(other.versions[.deadline]?.headsDigest), target: target)
        let confirmed = CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: displayed.idempotencyKey,
            source: displayed.source, context: displayed.context, workspaceEpoch: displayed.workspaceEpoch,
            payload: .setPlan(item: .init(taskID: other.taskID, expected: ExpectedVersions(other), acknowledgment: acknowledgment),
                              target: target, review: nil))
        let committed = await h.store.execute(confirmed, at: fixedInstant)
        #expect(committed.state == .locallyCommitted)
        let snapshot = try await h.store.snapshot()
        #expect(snapshot.tasks.first { $0.taskID == card.taskID }?.plan.target == .unassigned)
        #expect(snapshot.tasks.first { $0.taskID == other.taskID }?.plan.target == target)
        #expect(!snapshot.records.contains { $0.idempotencyKey == widgetEnvelope.idempotencyKey })
    }

    @Test("부분 종료는 미검토를 보존한 채 오늘 표시로 전환한다", .timeLimit(.minutes(1)))
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

    @Test("위젯 오늘 다시 정리는 종료한 주기에서 Today만 다시 카드로 만든다", .timeLimit(.minutes(1)))
    func reopenOnlyExplicitToday() async throws {
        let h = try await harness(), initial = try await h.widget.snapshot(at: fixedInstant)
        let card = try #require(initial.card)
        _ = try await h.widget.commit(scopeKey: initial.scopeKey, sessionID: initial.sessionID, card: card,
                                      target: .day(h.context.planningDay), at: fixedInstant)
        _ = try await h.widget.finish(scopeKey: initial.scopeKey, sessionID: initial.sessionID, at: fixedInstant)
        let before = try await h.store.snapshot()
        let reopened = try await h.widget.startReview(scopeKey: initial.scopeKey, todayOnly: true, at: fixedInstant)
        #expect(reopened.mode == .review)
        #expect(reopened.manualTodayOverride)
        #expect(reopened.queue == [card.taskID])
        #expect(reopened.card?.taskID == card.taskID)
        #expect(reopened.card?.decisionToken != card.decisionToken)
        #expect(reopened.sessionID != initial.sessionID)
        #expect(try await h.store.snapshot().records == before.records)
        #expect(try await h.widget.snapshot(at: fixedInstant).card == reopened.card)
    }

    @Test("오늘 목록은 operation ID의 사전 순서 대신 배치한 결정 순서를 유지한다")
    func todayUsesDecisionOrder() async throws {
        let h = try await harness()
        let keys = try ["today-first", "today-second"].map { key in
            (key, try OperationRecord.logicalID(workspaceKey: "personal-v1", workspaceEpoch: "local-v1", idempotencyKey: key))
        }.sorted { $0.1 > $1.1 }
        for (id, key) in zip([h.first, h.second], keys.map { $0.0 }) {
            let task = try #require(try await h.store.snapshot().tasks.first { $0.taskID == id })
            let result = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: key,
                source: .app, context: h.context, workspaceEpoch: "local-v1",
                payload: .setPlan(item: .init(taskID: id, expected: .init(task)), target: .day(h.context.planningDay), review: nil)), at: fixedInstant)
            #expect(result.state == .locallyCommitted)
        }
        let first = try await h.widget.snapshot(at: fixedInstant)
        let reopened = WidgetReviewService(store: h.store, directory: h.directory, workspaceEpoch: "local-v1")
        let second = try await reopened.snapshot(at: fixedInstant)
        #expect(first.today.map(\.taskID) == [h.first, h.second])
        #expect(second.today == first.today)
        let services = SystemServices(store: h.store, directory: h.directory, workspaceEpoch: "local-v1")
        #expect(try await services.todayTasks(on: h.context.planningDay, at: fixedInstant).map(\.taskID) == [h.first, h.second])
    }

    @Test("위젯 Undo는 원본 결정 버전에 고정하고 후속 제목 수정은 보존한다", .timeLimit(.minutes(1)))
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
        let visible = try await h.widget.snapshot(at: fixedInstant), restoredCard = try #require(visible.card)
        #expect(restoredCard.taskID == card.taskID)
        #expect(restoredCard.title == "새 제목")
        #expect(restoredCard.expected == ExpectedVersions(restored))
        #expect(restoredCard.cardID != card.cardID)
        #expect(restoredCard.decisionToken != card.decisionToken)
        #expect(visible.sessionID != state.sessionID)
        #expect(visible.queue == [card.taskID] + committed.queue)
        #expect(visible.queuePlanVersions[card.taskID.uuidString] == restored.versions[.plan]?.headsDigest)

        // Undo 전 카드의 지연 재시도는 원래 영수증만 반환하고 복원한 카드를 넘기지 않는다.
        let oldDecision = try await h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card,
                                                    target: .day(try h.context.planningDay.addingDays(1)), at: fixedInstant)
        #expect(oldDecision.state == .alreadyApplied)
        let afterOldDecision = try await h.widget.snapshot(at: fixedInstant)
        #expect(afterOldDecision.card == restoredCard)
        #expect(afterOldDecision.queue == visible.queue)

        _ = try await h.widget.commit(scopeKey: visible.scopeKey, sessionID: visible.sessionID, card: restoredCard,
                                      target: .day(try h.context.planningDay.addingDays(2)), at: fixedInstant)
        let newer = try await h.widget.snapshot(at: fixedInstant)
        let beforeRetry = try await h.store.snapshot().records
        let repeated = try await h.widget.undo(scopeKey: state.scopeKey, operationID: operation,
                                               expected: committed.undoExpected, at: fixedInstant)
        #expect(repeated.state == .alreadyApplied)
        let afterRetry = try await h.widget.snapshot(at: fixedInstant)
        #expect(afterRetry.card == newer.card)
        #expect(afterRetry.sessionID == newer.sessionID)
        #expect(afterRetry.lastOperationID == newer.lastOperationID)
        #expect(afterRetry.undoExpected == newer.undoExpected)
        #expect(try await h.store.snapshot().records == beforeRetry)
    }

    @Test("같은 위젯 세션의 이전 결정 영수증은 최신 Undo와 현재 카드를 되감지 않는다",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func oldDecisionReceiptPreservesLatestUndo(changeTarget: Bool) async throws {
        let h = try await harness(), thirdID = UUID()
        let captured = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: thirdID.uuidString,
            source: .app, context: h.context, workspaceEpoch: "local-v1",
            payload: .capture(taskID: thirdID, content: try TaskContent(title: "세 번째 작업"))), at: fixedInstant)
        #expect(captured.state == .locallyCommitted)
        let initial = try await h.widget.snapshot(at: fixedInstant), first = try #require(initial.card)
        let target = PlanTarget.day(try h.context.planningDay.addingDays(1))
        let firstResult = try await h.widget.commit(scopeKey: initial.scopeKey, sessionID: initial.sessionID,
            card: first, target: target, at: fixedInstant)
        #expect(firstResult.state == .locallyCommitted)
        let advanced = try await h.widget.snapshot(at: fixedInstant), second = try #require(advanced.card)
        let secondResult = try await h.widget.commit(scopeKey: advanced.scopeKey, sessionID: advanced.sessionID,
            card: second, target: target, at: fixedInstant)
        #expect(secondResult.state == .locallyCommitted)
        let latest = try await h.widget.snapshot(at: fixedInstant), current = try #require(latest.card)
        let latestOperation = try #require(latest.lastOperationID)
        #expect(latest.sessionID == initial.sessionID)
        #expect(latestOperation == secondResult.operationID)
        #expect(current.taskID != first.taskID && current.taskID != second.taskID)
        let records = try await h.store.snapshot().records

        let reopened = WidgetReviewService(store: h.store, directory: h.directory, workspaceEpoch: "local-v1")
        let repeated = try await reopened.commit(scopeKey: initial.scopeKey, sessionID: initial.sessionID,
            card: first, target: changeTarget ? .day(h.context.planningDay) : target, at: fixedInstant)
        #expect(repeated.state == (changeTarget ? .alreadyDecided : .alreadyApplied))
        #expect(repeated.operationID == firstResult.operationID)
        #expect(repeated.affectedTaskIDs == [first.taskID])
        let afterRetry = try await h.widget.snapshot(at: fixedInstant)
        #expect(afterRetry.sessionID == latest.sessionID)
        #expect(afterRetry.card == current)
        #expect(afterRetry.queue == latest.queue)
        #expect(afterRetry.lastOperationID == latestOperation)
        #expect(afterRetry.undoExpected == latest.undoExpected)
        #expect(try await h.store.snapshot().records == records)

        let undone = try await reopened.undo(scopeKey: afterRetry.scopeKey,
            operationID: try #require(afterRetry.lastOperationID), expected: afterRetry.undoExpected, at: fixedInstant)
        #expect(undone.state == .locallyCommitted)
        #expect(undone.affectedTaskIDs == [second.taskID])
        #expect(try await h.store.taskProjection(first.taskID)?.plan.target == target)
        #expect(try await h.store.taskProjection(second.taskID)?.plan.target == .unassigned)
        let afterUndo = try await h.widget.snapshot(at: fixedInstant)
        #expect(afterUndo.card?.taskID == second.taskID)
        #expect(afterUndo.queue == [second.taskID] + latest.queue)
    }

    @Test("최신 위젯 결정 영수증은 화면 저장이 중단된 뒤에도 Undo를 복구한다", .timeLimit(.minutes(1)))
    func latestDecisionReceiptRecoversUndoAfterPresentationInterruption() async throws {
        let h = try await harness(), thirdID = UUID()
        let captured = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: thirdID.uuidString,
            source: .app, context: h.context, workspaceEpoch: "local-v1",
            payload: .capture(taskID: thirdID, content: try TaskContent(title: "세 번째 작업"))), at: fixedInstant)
        #expect(captured.state == .locallyCommitted)
        let initial = try await h.widget.snapshot(at: fixedInstant)
        let first = try #require(initial.card)
        let target = PlanTarget.day(try h.context.planningDay.addingDays(1))
        let firstResult = try await h.widget.commit(scopeKey: initial.scopeKey, sessionID: initial.sessionID,
            card: first, target: target, at: fixedInstant)
        #expect(firstResult.state == .locallyCommitted)
        let previous = try await h.widget.snapshot(at: fixedInstant), second = try #require(previous.card)
        let secondResult = try await h.widget.commit(scopeKey: previous.scopeKey, sessionID: previous.sessionID,
            card: second, target: target, at: fixedInstant)
        #expect(secondResult.state == .locallyCommitted)
        let operation = try #require(secondResult.operationID)
        // 원본은 완료됐지만 presentation 저장 직전에 종료된 상태를 디스크에 재현한다.
        try await h.store.setLocalValue(JSONEncoder().encode(previous), forKey: "widget-presentation-v1:\(previous.scopeKey)")
        let reopened = WidgetReviewService(store: h.store, directory: h.directory, workspaceEpoch: "local-v1")
        let refreshed = try await reopened.snapshot(at: fixedInstant)
        #expect(refreshed.lastOperationID == firstResult.operationID)
        #expect(!refreshed.queue.contains(second.taskID))
        let records = try await h.store.snapshot().records
        let repeated = try await reopened.commit(scopeKey: previous.scopeKey, sessionID: previous.sessionID,
            card: second, target: target, at: fixedInstant)
        #expect(repeated.state == .alreadyApplied)
        let recovered = try await reopened.snapshot(at: fixedInstant)
        let expectedUndo = try #require(records.first { $0.operationID == operation }).undoExpectations()
        #expect(recovered.lastOperationID == operation)
        #expect(recovered.undoExpected == expectedUndo)
        #expect(recovered.card == refreshed.card)
        #expect(try await h.store.snapshot().records == records)
        let undone = try await reopened.undo(scopeKey: recovered.scopeKey, operationID: operation,
            expected: recovered.undoExpected, at: fixedInstant)
        #expect(undone.state == .locallyCommitted)
        #expect(undone.affectedTaskIDs == [second.taskID])
        #expect(try await h.store.taskProjection(first.taskID)?.plan.target == target)
        #expect(try await h.store.taskProjection(second.taskID)?.plan.target == .unassigned)
    }

    @Test("마지막 카드 Undo는 닫힌 주기를 이 세션에서만 다시 열고 새 입력을 자동으로 끼워 넣지 않는다", .timeLimit(.minutes(1)))
    func undoLastWidgetCardResumesFrozenQueue() async throws {
        let h = try await harness(twoTasks: false), initial = try await h.widget.snapshot(at: fixedInstant)
        let card = try #require(initial.card)
        _ = try await h.widget.commit(scopeKey: initial.scopeKey, sessionID: initial.sessionID, card: card,
                                      target: .day(try h.context.planningDay.addingDays(1)), at: fixedInstant)
        let closed = try await h.widget.snapshot(at: fixedInstant)
        #expect(closed.mode == .today)
        let operation = try #require(closed.lastOperationID)
        let added = UUID()
        let captured = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: added.uuidString,
            source: .share, context: h.context, workspaceEpoch: "local-v1",
            payload: .capture(taskID: added, content: try TaskContent(title: "정리 뒤 새 입력"))), at: fixedInstant)
        #expect(captured.state == .locallyCommitted)
        let undone = try await h.widget.undo(scopeKey: closed.scopeKey, operationID: operation,
                                            expected: closed.undoExpected, at: fixedInstant)
        #expect(undone.state == .locallyCommitted)
        let resumed = try await h.widget.snapshot(at: fixedInstant), restoredCard = try #require(resumed.card)
        #expect(resumed.mode == .review)
        #expect(resumed.manualResumeOverride == true)
        #expect(!resumed.manualTodayOverride)
        #expect(resumed.queue == [card.taskID])
        #expect(restoredCard.taskID == card.taskID)
        #expect(restoredCard.decisionToken != card.decisionToken)
        let snapshot = try await h.store.snapshot()
        #expect(TaskReducer.reduce(snapshot.records, workspaceKey: snapshot.workspaceKey,
                                   workspaceEpoch: snapshot.workspaceEpoch).isCycleClosed(initial.cycleID))
        let reopened = WidgetReviewService(store: h.store, directory: h.directory, workspaceEpoch: "local-v1")
        #expect(try await reopened.snapshot(at: fixedInstant).card == restoredCard)
        let otherScope = try await reopened.snapshot(scopeKey: "other", at: fixedInstant)
        #expect(otherScope.mode == .today)
        _ = try await reopened.finish(scopeKey: resumed.scopeKey, sessionID: resumed.sessionID, at: fixedInstant)
        let finished = try await h.widget.snapshot(at: fixedInstant)
        #expect(finished.mode == .today)
        #expect(finished.manualResumeOverride != true)
        #expect(finished.card == nil)
    }

    @Test("위젯 Undo는 이미 받은 후속 계획을 덮거나 정리 큐에 복원하지 않는다", .timeLimit(.minutes(1)))
    func staleWidgetUndoKeepsCurrentCard() async throws {
        let h = try await harness(), initial = try await h.widget.snapshot(at: fixedInstant)
        let card = try #require(initial.card)
        _ = try await h.widget.commit(scopeKey: initial.scopeKey, sessionID: initial.sessionID, card: card,
                                      target: .day(try h.context.planningDay.addingDays(1)), at: fixedInstant)
        let committed = try await h.widget.snapshot(at: fixedInstant), operation = try #require(committed.lastOperationID)
        let task = try #require(try await h.store.taskProjection(card.taskID))
        let target = PlanTarget.day(try h.context.planningDay.addingDays(2))
        let newer = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
            source: .app, context: h.context, workspaceEpoch: "local-v1",
            payload: .setPlan(item: .init(taskID: card.taskID, expected: .init(task)), target: target, review: nil)), at: fixedInstant)
        #expect(newer.state == .locallyCommitted)
        let undone = try await h.widget.undo(scopeKey: committed.scopeKey, operationID: operation,
                                            expected: committed.undoExpected, at: fixedInstant)
        #expect(undone.state == .staleSnapshot)
        let after = try await h.widget.snapshot(at: fixedInstant)
        #expect(after.card == committed.card)
        #expect(after.queue == committed.queue)
        #expect(after.sessionID == committed.sessionID)
        #expect(try await h.store.taskProjection(card.taskID)?.plan.target == target)
    }

    @Test("오늘 다시 정리의 Undo는 Today 범위와 남은 카드를 유지한다", .timeLimit(.minutes(1)))
    func undoWithinManualTodayKeepsTodayScope() async throws {
        let h = try await harness()
        for id in [h.first, h.second] {
            let task = try #require(try await h.store.taskProjection(id))
            let result = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
                source: .app, context: h.context, workspaceEpoch: "local-v1",
                payload: .setPlan(item: .init(taskID: id, expected: .init(task)), target: .day(h.context.planningDay), review: nil)), at: fixedInstant)
            #expect(result.state == .locallyCommitted)
        }
        let initial = try await h.widget.snapshot(at: fixedInstant)
        _ = try await h.widget.finish(scopeKey: initial.scopeKey, sessionID: initial.sessionID, at: fixedInstant)
        let resumed = try await h.widget.startReview(todayOnly: true, at: fixedInstant), card = try #require(resumed.card)
        _ = try await h.widget.commit(scopeKey: resumed.scopeKey, sessionID: resumed.sessionID, card: card,
                                      target: .day(try h.context.planningDay.addingDays(1)), at: fixedInstant)
        let committed = try await h.widget.snapshot(at: fixedInstant), operation = try #require(committed.lastOperationID)
        _ = try await h.widget.undo(scopeKey: committed.scopeKey, operationID: operation,
                                    expected: committed.undoExpected, at: fixedInstant)
        let after = try await h.widget.snapshot(at: fixedInstant)
        #expect(after.mode == .review)
        #expect(after.manualTodayOverride)
        #expect(after.manualResumeOverride != true)
        #expect(after.card?.taskID == card.taskID)
        #expect(after.queue == resumed.queue)
    }

    @Test("재개 상태가 없는 기존 위젯 저장값도 카드와 토큰을 유지하여 읽는다")
    func legacyWidgetPresentationDecodesWithoutResumeFlag() async throws {
        let h = try await harness(), initial = try await h.widget.snapshot(at: fixedInstant)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        object.removeValue(forKey: "manualResumeOverride")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WidgetReviewState.self, from: data)
        #expect(decoded.manualResumeOverride == nil)
        try await h.store.setLocalValue(data, forKey: "widget-presentation-v1:\(initial.scopeKey)")
        let reloaded = try await h.widget.snapshot(at: fixedInstant)
        #expect(reloaded.card == initial.card)
        #expect(reloaded.sessionID == initial.sessionID)
        #expect(reloaded.queue == initial.queue)
    }

    @Test("공개 단축어는 대표 여섯 개이며 내부 위젯 명령은 검색 노출하지 않는다")
    func shortcutCatalog() {
        #expect(MirrorAppShortcuts.appShortcuts.count == 6)
        #expect(!CommitWidgetDecisionIntent.isDiscoverable)
        #expect(!ShowWidgetDatePanelIntent.isDiscoverable)
        #expect(!FinishReviewIntent.isDiscoverable)
    }

    @Test("OS host가 없는 실행도 실제 저장 성공과 시스템 후처리 실패를 분리한다", .timeLimit(.minutes(1)))
    func canonicalCommitWithRuntimeBoundary() async throws {
        let h = try await harness(twoTasks: false), state = try await h.widget.snapshot(at: fixedInstant)
        let card = try #require(state.card)
        let result = try await h.widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card,
                                              target: .day(h.context.planningDay), at: fixedInstant)
        #expect(result.state == .locallyCommitted)
        #expect(try await h.store.snapshot().tasks.first { $0.taskID == card.taskID }?.plan.target == .day(h.context.planningDay))
        let report = try #require(await h.widget.lastSurfaceReport)
        if !SystemAppleRuntimeHost.isApplicationOrExtension {
            #expect(report.failures.contains(.notifications))
            #expect(report.failures.contains(.spotlight))
            #expect(result.safeUserMessage.contains("저장은 유지"))
            await #expect(throws: NotificationServiceError.configurationRequired) {
                try await NotificationService().clearAll()
            }
            await #expect(throws: SpotlightServiceError.configurationRequired) {
                try await SpotlightService().removeAll()
            }
        }
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

    @Test("위젯에서 실제 정리를 닫은 뒤 공통 예약 계획은 당일 알림만 제거한다", .timeLimit(.minutes(1)))
    func widgetClosureCancelsTodayReminder() async throws {
        let h = try await harness()
        var preferences = SystemPreferences()
        preferences.reviewNotification = .init(enabled: true, hour: 15)
        let before = try SurfaceReconciliationPlan.notifications(snapshot: try await h.store.snapshot(), preferences: preferences, at: fixedInstant)
        let todayID = "review:local-v1:\(h.context.planningDay)"
        #expect(before.requests.count == 28)
        #expect(before.requests.contains { $0.identifier == todayID })
        let state = try await h.widget.snapshot(at: fixedInstant)
        let closed = try await h.widget.finish(scopeKey: state.scopeKey, sessionID: state.sessionID, at: fixedInstant)
        #expect(closed.state == .locallyCommitted)
        let after = try SurfaceReconciliationPlan.notifications(snapshot: try await h.store.snapshot(), preferences: preferences, at: fixedInstant)
        #expect(after.requests.count == 27)
        #expect(!after.requests.contains { $0.identifier == todayID })
        #expect(Set(before.requests.map(\.identifier)).subtracting([todayID]) == Set(after.requests.map(\.identifier)))
    }

    @Test("실제 마감 알림은 계획 변경에 유지되고 완료 후 예약에서 빠진다")
    func deadlineNotificationSurvivesPlanChange() async throws {
        let h = try await harness()
        let original = try #require(try await h.store.snapshot().tasks.first { $0.taskID == h.first })
        let deadlineVersion = try #require(original.versions[.deadline]?.headsDigest)
        let deadline = Deadline.day(localDate: try LocalDate("2026-10-01"), timeZoneID: "Asia/Seoul")
        let saved = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
            source: .app, context: h.context, workspaceEpoch: "local-v1",
            payload: .setDeadline(taskID: h.first, deadline: deadline, expectedDeadline: deadlineVersion)), at: fixedInstant)
        #expect(saved.state == .locallyCommitted)
        let snapshot = try await h.store.snapshot(), task = try #require(snapshot.tasks.first { $0.taskID == h.first })
        let fireAt = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!
        let preferences: [DeadlineNotificationPreference] = [.init(taskID: h.first, fireAt: fireAt)]
        let before = try NotificationPlanner.plan(context: h.context, workspaceEpoch: "local-v1", now: fixedInstant,
            review: .init(), closedDays: [], tasks: snapshot.tasks, deadlines: preferences)
        #expect(before.requests.count == 1)
        let target = PlanTarget.day(try LocalDate("2026-10-05"))
        let acknowledgment = DeadlineAcknowledgment(taskID: h.first.uuidString,
            deadlineRevision: try #require(task.versions[.deadline]?.headsDigest), target: target)
        let moved = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
            source: .app, context: h.context, workspaceEpoch: "local-v1",
            payload: .setPlan(item: .init(taskID: h.first, expected: .init(task), acknowledgment: acknowledgment),
                              target: target, review: nil)), at: fixedInstant)
        #expect(moved.state == .locallyCommitted)
        let afterMove = try await h.store.snapshot()
        let after = try NotificationPlanner.plan(context: h.context, workspaceEpoch: "local-v1", now: fixedInstant,
            review: .init(), closedDays: [], tasks: afterMove.tasks, deadlines: preferences)
        #expect(after.requests == before.requests)
        let movedTask = try #require(afterMove.tasks.first { $0.taskID == h.first })
        let completed = await h.store.execute(.init(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
            source: .app, context: h.context, workspaceEpoch: "local-v1",
            payload: .completion(taskID: h.first, desiredCompleted: true,
                                  expectedStatus: try #require(movedTask.versions[.status]?.headsDigest))), at: fixedInstant)
        #expect(completed.state == .locallyCommitted)
        let removed = try NotificationPlanner.plan(context: h.context, workspaceEpoch: "local-v1", now: fixedInstant,
            review: .init(), closedDays: [], tasks: await h.store.snapshot().tasks, deadlines: preferences)
        #expect(removed.requests.isEmpty)
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
