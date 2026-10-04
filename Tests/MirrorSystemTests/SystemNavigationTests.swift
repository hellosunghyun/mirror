import Foundation
import Darwin
import Testing
import UserNotifications
import CoreSpotlight
import MirrorDomain
import MirrorData
@testable import MirrorSystem

private let navigationInstant = Date(timeIntervalSince1970: 1_791_000_000)

private func navigationTask(id: UUID = UUID(), status: TaskStatus = .open, complete: Bool = true,
                            deadline: Deadline? = nil) throws -> TaskProjection {
    TaskProjection(taskID: id, workspaceKey: "personal-v1", workspaceEpoch: "local-v1",
        content: try TaskContent(title: "외부에 노출하지 않을 제목"), plan: .init(target: .day(try LocalDate("2026-10-04"))),
        lifecycle: .init(status: status, completedAt: status == .completed ? navigationInstant : nil,
                         deletedAt: status == .deleted ? navigationInstant : nil),
        deadline: deadline, createdAt: navigationInstant, versions: [:], isProjectionComplete: complete)
}

private func notificationEvent(_ route: MirrorRoute, request: String,
                               action: String = UNNotificationDefaultActionIdentifier) -> NotificationNavigationEvent {
    .init(actionIdentifier: action, requestIdentifier: request, routeURL: MirrorDeepLink.url(for: route).absoluteString)
}

@MainActor private final class NavigationCapture {
    var routes: [MirrorRoute] = []
}

@Suite("시스템 탐색과 복구 중 외부 노출")
struct SystemNavigationTests {
    @Test("상세·빠른 입력·저장 결과가 모두 끝난 경우에만 명시적 공간 변경을 허용한다")
    func workspaceChangeRequiresAllEditingAndWritesToFinish() {
        #expect(WorkspaceChangeBlocker.current(detailEditing: false, capture: false, projectionPending: false, saving: false) == nil)
        #expect(WorkspaceChangeBlocker.current(detailEditing: true, capture: false, projectionPending: false, saving: false) == .detailEditing)
        #expect(WorkspaceChangeBlocker.current(detailEditing: false, capture: true, projectionPending: false, saving: false) == .capture)
        #expect(WorkspaceChangeBlocker.current(detailEditing: false, capture: false, projectionPending: true, saving: false) == .projectionPending)
        #expect(WorkspaceChangeBlocker.current(detailEditing: false, capture: false, projectionPending: false, saving: true) == .saving)
    }

    @Test("다른 창의 입력 하나가 끝나도 남은 초안과 미확인 저장은 공간 변경을 계속 막는다")
    func workspaceChangeRemainsBlockedUntilEveryReasonClears() {
        #expect(WorkspaceChangeBlocker.current(detailEditing: true, capture: true, projectionPending: true, saving: true) == .detailEditing)
        #expect(WorkspaceChangeBlocker.current(detailEditing: false, capture: true, projectionPending: true, saving: true) == .capture)
        #expect(WorkspaceChangeBlocker.current(detailEditing: false, capture: false, projectionPending: true, saving: true) == .projectionPending)
        #expect(WorkspaceChangeBlocker.current(detailEditing: false, capture: false, projectionPending: true, saving: false) == .projectionPending)
        #expect(WorkspaceChangeBlocker.current(detailEditing: false, capture: false, projectionPending: false, saving: false) == nil)
    }

    @Test("서로 다른 일정 화면의 조회는 각 날짜의 약속을 유지한다")
    @MainActor
    func calendarDisplaysKeepIndependentRangesAndEvents() {
        let first = CalendarDisplayState(), second = CalendarDisplayState()
        let tomorrow = navigationInstant.addingTimeInterval(86_400)
        let firstEvent = CalendarEventSummary(id: "first", calendarID: "calendar", title: "첫 날짜 약속",
            start: navigationInstant, end: navigationInstant.addingTimeInterval(3_600), isAllDay: false)
        let secondEvent = CalendarEventSummary(id: "second", calendarID: "calendar", title: "다음 날짜 약속",
            start: tomorrow, end: tomorrow.addingTimeInterval(3_600), isAllDay: false)
        let firstRequest = first.begin(from: navigationInstant, to: tomorrow)
        let secondRequest = second.begin(from: tomorrow, to: tomorrow.addingTimeInterval(86_400))
        #expect(!first.complete(secondRequest, events: [secondEvent]))
        #expect(second.complete(secondRequest, events: [secondEvent]))
        #expect(first.complete(firstRequest, events: [firstEvent]))
        #expect(first.events == [firstEvent])
        #expect(second.events == [secondEvent])
        #expect(first.range?.start == navigationInstant)
        #expect(second.range?.start == tomorrow)
    }

    @Test("같은 화면의 늦은 일정 응답과 오류는 새 날짜를 덮지 않는다")
    @MainActor
    func calendarDisplayRejectsOldRangeCompletion() {
        let display = CalendarDisplayState()
        let tomorrow = navigationInstant.addingTimeInterval(86_400)
        let oldRequest = display.begin(from: navigationInstant, to: tomorrow)
        let currentRequest = display.begin(from: tomorrow, to: tomorrow.addingTimeInterval(86_400))
        let event = CalendarEventSummary(id: "current", calendarID: "calendar", title: "현재 날짜 약속",
            start: tomorrow, end: tomorrow.addingTimeInterval(3_600), isAllDay: false)
        #expect(display.complete(currentRequest, events: [event]))
        #expect(!display.complete(oldRequest, events: [], problem: "이전 조회 실패"))
        #expect(display.events == [event])
        #expect(display.problem == nil)
        #expect(display.range?.start == tomorrow)
    }

    @Test("캘린더 읽기를 중지하면 표시와 대기 응답을 폐기하고 탐색 범위는 유지한다")
    @MainActor
    func calendarDisplayInvalidationRejectsPendingRead() {
        let display = CalendarDisplayState()
        let end = navigationInstant.addingTimeInterval(86_400)
        let event = CalendarEventSummary(id: "event", calendarID: "calendar", title: "숨길 약속",
            start: navigationInstant, end: navigationInstant.addingTimeInterval(3_600), isAllDay: false)
        let completed = display.begin(from: navigationInstant, to: end)
        #expect(display.complete(completed, events: [event]))
        display.invalidate()
        #expect(display.events.isEmpty)
        #expect(!display.complete(completed, events: [event]))
        #expect(display.range == DateInterval(start: navigationInstant, end: end))
        let pending = display.begin(from: navigationInstant, to: end)
        display.invalidate()
        #expect(!display.complete(pending, events: [event]))
        #expect(display.events.isEmpty)
        let reopened = display.begin(from: navigationInstant, to: end)
        #expect(display.complete(reopened, events: [event]))
        #expect(display.events == [event])
    }

    @Test("한 입력 owner가 끝나도 다른 owner의 편집은 계속 단축키를 차단한다")
    func textEditingOneOwnerEndsWithoutClearingAnother() {
        let first = UUID(), second = UUID()
        var state = TextEditingOwnershipState()
        #expect(!state.isEditing)
        state.setEditing(true, ownerID: first)
        state.setEditing(true, ownerID: second)
        #expect(state.isEditing)
        state.setEditing(false, ownerID: first)
        #expect(state.isEditing)
        state.setEditing(false, ownerID: second)
        #expect(!state.isEditing)
    }

    @Test("등록하지 않은 다른 owner의 종료는 현재 활성 입력을 바꾸지 않는다")
    func textEditingForeignOwnerClearPreservesActiveOwner() {
        let active = UUID(), foreign = UUID()
        var state = TextEditingOwnershipState()
        state.setEditing(true, ownerID: active)
        let beforeForeignClear = state
        state.setEditing(false, ownerID: foreign)
        #expect(state == beforeForeignClear)
        state.setEditing(false, ownerID: UUID())
        #expect(state == beforeForeignClear)
        #expect(state.isEditing)
    }

    @Test("이전 owner의 늦은 종료는 새 owner의 입력을 해제하지 않는다")
    func textEditingStaleDistinctOwnerClearPreservesReplacement() {
        let previous = UUID(), current = UUID()
        var state = TextEditingOwnershipState()
        state.setEditing(true, ownerID: previous)
        state.setEditing(false, ownerID: previous)
        #expect(!state.isEditing)
        state.setEditing(true, ownerID: current)
        #expect(state.isEditing)
        let beforeStaleClear = state
        state.setEditing(false, ownerID: previous)
        #expect(state == beforeStaleClear)
    }

    @Test("동일 owner의 중복 활성·종료는 한 번의 등록과 해제와 같다")
    func textEditingSameOwnerRegistrationIsIdempotent() {
        let owner = UUID()
        var state = TextEditingOwnershipState()
        state.setEditing(true, ownerID: owner)
        let firstRegistration = state
        state.setEditing(true, ownerID: owner)
        #expect(state == firstRegistration)
        state.setEditing(false, ownerID: owner)
        #expect(!state.isEditing)
        let firstClear = state
        state.setEditing(false, ownerID: owner)
        #expect(state == firstClear)
    }

    @Test("owner 등록 순서와 무관하게 같은 활성 입력 집합이며 모두 끝나면 비어 있다")
    func textEditingOwnerOrderAndAllClearAreEquivalent() {
        let first = UUID(), second = UUID()
        var forward = TextEditingOwnershipState(), reverse = TextEditingOwnershipState()
        forward.setEditing(true, ownerID: first)
        forward.setEditing(true, ownerID: second)
        reverse.setEditing(true, ownerID: second)
        reverse.setEditing(true, ownerID: first)
        #expect(forward == reverse)
        forward.setEditing(false, ownerID: first)
        reverse.setEditing(false, ownerID: first)
        #expect(forward == reverse && forward.isEditing)
        forward.setEditing(false, ownerID: second)
        reverse.setEditing(false, ownerID: second)
        #expect(forward == reverse)
        #expect(!forward.isEditing)
        #expect(forward == TextEditingOwnershipState())
    }

    @Test("메뉴 막대 제출은 자기 토큰의 앱 제목 입력 봉투만 그대로 돌려준다")
    func menuBarCaptureOwnershipRejectsForeignCommands() throws {
        let context = try PlanningContext.capture(at: navigationInstant, timeZoneID: "Asia/Seoul", policyRevision: "policy-v1")
        let observation = UUID(), taskID = UUID()
        let owner = MenuBarCaptureSubmission(token: "menu-owned", title: "  메뉴 원문  ", observationID: observation,
            workspaceKey: "personal-v1", workspaceEpoch: "local-v1")
        let content = try TaskContent(title: owner.title)
        let envelope = CommandEnvelope(requestID: "original-request", idempotencyKey: owner.token, source: .app,
            context: context, workspaceEpoch: owner.workspaceEpoch, payload: .capture(taskID: taskID, content: content))
        #expect(owner.ownedEnvelope(envelope, token: owner.token, observationID: observation,
            workspaceKey: owner.workspaceKey, workspaceEpoch: owner.workspaceEpoch) == envelope)
        #expect(owner.ownedEnvelope(envelope, token: "other-view-token", observationID: observation,
            workspaceKey: owner.workspaceKey, workspaceEpoch: owner.workspaceEpoch) == nil)
        let candidates: [CommandEnvelope?] = [
            nil,
            CommandEnvelope(requestID: "foreign", idempotencyKey: "other-window-token", source: .app,
                context: context, workspaceEpoch: owner.workspaceEpoch, payload: envelope.payload),
            CommandEnvelope(requestID: "share", idempotencyKey: owner.token, source: .share,
                context: context, workspaceEpoch: owner.workspaceEpoch, payload: envelope.payload),
            CommandEnvelope(requestID: "planned", idempotencyKey: owner.token, source: .app,
                context: context, workspaceEpoch: owner.workspaceEpoch,
                payload: .captureWithPlan(taskID: taskID, content: content, initialPlan: .day(context.planningDay))),
            CommandEnvelope(requestID: "changed", idempotencyKey: owner.token, source: .app,
                context: context, workspaceEpoch: owner.workspaceEpoch,
                payload: .capture(taskID: taskID, content: try TaskContent(title: "다른 입력"))),
            CommandEnvelope(requestID: "note", idempotencyKey: owner.token, source: .app,
                context: context, workspaceEpoch: owner.workspaceEpoch,
                payload: .capture(taskID: taskID, content: try TaskContent(title: owner.title, note: "다른 화면의 메모")))
        ]
        for candidate in candidates {
            #expect(owner.ownedEnvelope(candidate, token: owner.token, observationID: observation,
                workspaceKey: owner.workspaceKey, workspaceEpoch: owner.workspaceEpoch) == nil)
            if let candidate {
                #expect(owner.committedReceipt(for: candidate, observationID: observation,
                    workspaceKey: owner.workspaceKey, workspaceEpoch: owner.workspaceEpoch) == nil)
            }
        }
    }

    @Test("메뉴 막대의 관측·공간·세대가 바뀌면 같은 토큰도 재시도와 성공 영수증을 거절한다")
    func menuBarCaptureOwnershipRejectsChangedWorkspace() throws {
        let context = try PlanningContext.capture(at: navigationInstant, timeZoneID: "Asia/Seoul", policyRevision: "policy-v1")
        let observation = UUID()
        let owner = MenuBarCaptureSubmission(token: "menu-owned", title: "저장 공간 원문", observationID: observation,
            workspaceKey: "personal-v1", workspaceEpoch: "local-v1")
        let envelope = CommandEnvelope(requestID: "original-request", idempotencyKey: owner.token, source: .app,
            context: context, workspaceEpoch: owner.workspaceEpoch,
            payload: .capture(taskID: UUID(), content: try TaskContent(title: owner.title)))
        for (currentObservation, currentKey, currentEpoch) in [
            (UUID(), owner.workspaceKey, owner.workspaceEpoch),
            (observation, "another-personal-space", owner.workspaceEpoch),
            (observation, owner.workspaceKey, "new-epoch")
        ] {
            #expect(owner.ownedEnvelope(envelope, token: owner.token, observationID: currentObservation,
                workspaceKey: currentKey, workspaceEpoch: currentEpoch) == nil)
            #expect(owner.committedReceipt(for: envelope, observationID: currentObservation,
                workspaceKey: currentKey, workspaceEpoch: currentEpoch) == nil)
        }
        let staleEnvelope = CommandEnvelope(requestID: envelope.requestID, idempotencyKey: owner.token, source: .app,
            context: context, workspaceEpoch: "old-epoch", payload: envelope.payload)
        #expect(owner.ownedEnvelope(staleEnvelope, token: owner.token, observationID: observation,
            workspaceKey: owner.workspaceKey, workspaceEpoch: owner.workspaceEpoch) == nil)
    }

    @Test("메뉴 성공은 정확한 토큰·제출 제목만 수용하며 실패 뒤 수정한 제목과 다른 영수증을 보존한다")
    func menuBarReceiptPreservesEditedTitleAndRejectsUnrelatedReceipt() {
        let submitted = "  메뉴 원문  "
        let receipt = CaptureCommittedReceipt(token: "menu-owned", title: "메뉴 원문")
        #expect(receipt.disposition(token: "menu-owned", submittedTitle: submitted, currentTitle: submitted) == .clearTitle)
        #expect(receipt.disposition(token: "menu-owned", submittedTitle: submitted, currentTitle: "수정한 제목") == .preserveTitle)
        #expect(receipt.disposition(token: "menu-owned", submittedTitle: submitted, currentTitle: "메뉴 원문") == .preserveTitle)
        #expect(receipt.disposition(token: "next-menu-token", submittedTitle: submitted, currentTitle: submitted) == nil)
        #expect(receipt.disposition(token: "menu-owned", submittedTitle: nil, currentTitle: submitted) == nil)
        #expect(receipt.disposition(token: "menu-owned", submittedTitle: "다른 제출", currentTitle: "다른 제출") == nil)
        let unrelated = CaptureCommittedReceipt(token: "menu-owned", title: "다른 성공 원문")
        #expect(unrelated.disposition(token: "menu-owned", submittedTitle: submitted, currentTitle: submitted) == nil)
    }

    @MainActor @Test("메뉴 pending은 다른 창 봉투를 실행하지 않고 기존 봉투 재시도로 작업 하나와 수정 제목을 보존한다")
    func menuBarPendingRetryExecutesOnlyOwnedOriginalEnvelope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorMenuRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = StoreConfiguration(directory: directory, deviceID: UUID().uuidString)
        let store = try await MirrorStore(configuration: config)
        let context = try PlanningContext.capture(at: navigationInstant, timeZoneID: "Asia/Seoul", policyRevision: "policy-v1")
        let observation = UUID(), taskID = UUID()
        let owner = MenuBarCaptureSubmission(token: "menu-original", title: "  먼저 저장한 제목  ", observationID: observation,
            workspaceKey: config.workspaceKey, workspaceEpoch: config.workspaceEpoch)
        let original = CommandEnvelope(requestID: "original-request", idempotencyKey: owner.token, source: .app,
            context: context, workspaceEpoch: config.workspaceEpoch,
            payload: .capture(taskID: taskID, content: try TaskContent(title: owner.title)))
        let pending = await store.execute(original, at: context.capturedAt, failurePoint: .afterCanonicalSave)
        #expect(pending.state == .committedProjectionPending)
        let foreign = CommandEnvelope(requestID: "other-window-request", idempotencyKey: "other-window-token", source: .app,
            context: context, workspaceEpoch: config.workspaceEpoch,
            payload: .capture(taskID: UUID(), content: try TaskContent(title: "다른 창에서 실패한 제목")))
        let rejected = owner.ownedEnvelope(foreign, token: owner.token, observationID: observation,
            workspaceKey: config.workspaceKey, workspaceEpoch: config.workspaceEpoch)
        #expect(rejected == nil)
        if let rejected { _ = await store.execute(rejected, at: context.capturedAt) }
        let retry = try #require(owner.ownedEnvelope(original, token: owner.token, observationID: observation,
            workspaceKey: config.workspaceKey, workspaceEpoch: config.workspaceEpoch))
        #expect(retry == original)
        let confirmed = await store.execute(retry, at: context.capturedAt)
        #expect(confirmed.state == .alreadyApplied)
        let receipt = try #require(owner.committedReceipt(for: retry, observationID: observation,
            workspaceKey: config.workspaceKey, workspaceEpoch: config.workspaceEpoch))
        let editedTitle = "저장 결과를 기다린 뒤 수정한 제목"
        #expect(receipt.disposition(token: owner.token, submittedTitle: owner.title, currentTitle: editedTitle) == .preserveTitle)
        #expect(owner.committedReceipt(for: retry, observationID: UUID(),
            workspaceKey: config.workspaceKey, workspaceEpoch: config.workspaceEpoch) == nil)
        let snapshot = try await store.snapshot()
        #expect(snapshot.tasks.count == 1 && snapshot.records.count == 1)
        #expect(snapshot.tasks.first?.taskID == taskID && snapshot.tasks.first?.title == "먼저 저장한 제목")
        #expect(snapshot.records.first?.idempotencyKey == owner.token)
        _ = try await store.exportAndSuspend(exportedAt: navigationInstant)
    }

    @Test("일반 저장 실패 뒤 자기 성공 receipt만 초안을 정확히 한 번 소비한다")
    func captureDraftFailureRetryConsumesOwnTokenOnce() {
        let draft = CaptureDraftSnapshot(title: "  실패 뒤 유지할 제목  ", note: "메모", sourceURL: "https://example.com/original")
        var state = CaptureDraftCommitState()
        state.register(token: "failed-capture", draft: draft)
        let matchesInitialDraft = state.matchesWholeDraft(draft)
        #expect(matchesInitialDraft)
        let missingReceipt = state.consume(token: nil, draft: draft)
        #expect(missingReceipt == nil)
        let foreignReceipt = state.consume(token: "other-window", draft: draft)
        #expect(foreignReceipt == nil)
        let foreignReceiptRetainsDraft = state.matchesWholeDraft(draft)
        #expect(foreignReceiptRetainsDraft)
        let ownRetryReceipt = state.consume(token: "failed-capture", draft: draft)
        #expect(ownRetryReceipt == .clearDraft)
        let matchesConsumedDraft = state.matchesWholeDraft(draft)
        #expect(!matchesConsumedDraft)
        let repeatedReceipt = state.consume(token: "failed-capture", draft: draft)
        #expect(repeatedReceipt == nil)
    }

    @Test("제목·메모·링크·날짜·계획 context를 바꾼 새 초안은 이전 성공이 지우지 않는다")
    func captureDraftEditsPreserveEachField() throws {
        let day = try LocalDate("2026-10-04")
        let context = try PlanningContext.capture(at: navigationInstant, timeZoneID: "Asia/Seoul", policyRevision: "policy-v1")
        let nextContext = try PlanningContext.capture(at: navigationInstant, timeZoneID: "Asia/Seoul", policyRevision: "policy-v2")
        let draft = CaptureDraftSnapshot(title: "  원문 제목  ", note: "원문 메모", sourceURL: "https://example.com/original",
                                         initialPlan: .day(day), planContext: context)
        let changed = [
            CaptureDraftSnapshot(title: "원문 제목", note: draft.note, sourceURL: draft.sourceURL, initialPlan: draft.initialPlan, planContext: context),
            CaptureDraftSnapshot(title: draft.title, note: "바꾼 메모", sourceURL: draft.sourceURL, initialPlan: draft.initialPlan, planContext: context),
            CaptureDraftSnapshot(title: draft.title, note: draft.note, sourceURL: "https://example.com/changed", initialPlan: draft.initialPlan, planContext: context),
            CaptureDraftSnapshot(title: draft.title, note: draft.note, sourceURL: draft.sourceURL, initialPlan: nil, planContext: context),
            CaptureDraftSnapshot(title: draft.title, note: draft.note, sourceURL: draft.sourceURL, initialPlan: draft.initialPlan, planContext: nextContext),
            CaptureDraftSnapshot(title: draft.title, note: draft.note, sourceURL: draft.sourceURL, initialPlan: draft.initialPlan, planContext: nil),
        ]
        for edited in changed {
            var state = CaptureDraftCommitState()
            state.register(token: "old-input", draft: draft)
            let matchesEditedDraft = state.matchesWholeDraft(edited)
            #expect(!matchesEditedDraft)
            let disposition = state.consume(token: "old-input", draft: edited)
            #expect(disposition == .preserveDraft)
            let repeatedReceipt = state.consume(token: "old-input", draft: draft)
            #expect(repeatedReceipt == nil)
        }
    }

    @Test("분할 재시도는 동일한 첫 줄·나머지 원문·메타데이터를 확인한 뒤 한 줄만 소비한다")
    func captureDraftSplitPreservesSuffixAndMetadata() throws {
        let context = try PlanningContext.capture(at: navigationInstant, timeZoneID: "Asia/Seoul", policyRevision: "policy-v1")
        let draft = CaptureDraftSnapshot(title: "첫 줄\n두 번째 줄\n마지막 줄", note: "공통 메모", sourceURL: "https://example.com/original",
                                         initialPlan: .day(try LocalDate("2026-10-04")), planContext: context)
        var state = CaptureDraftCommitState()
        state.register(token: "split-input", draft: draft, firstLine: "첫 줄")
        let splitIsWholeDraft = state.matchesWholeDraft(draft)
        #expect(!splitIsWholeDraft)
        let foreignReceipt = state.consume(token: "other-window", draft: draft)
        #expect(foreignReceipt == nil)
        let ownReceipt = state.consume(token: "split-input", draft: draft)
        #expect(ownReceipt == .removeFirstLine)
        let repeatedReceipt = state.consume(token: "split-input", draft: draft)
        #expect(repeatedReceipt == nil)
        let changed = [
            CaptureDraftSnapshot(title: "첫 줄\n바꾼 두 번째 줄\n마지막 줄", note: draft.note, sourceURL: draft.sourceURL, initialPlan: draft.initialPlan, planContext: context),
            CaptureDraftSnapshot(title: draft.title, note: "바꾼 공통 메모", sourceURL: draft.sourceURL, initialPlan: draft.initialPlan, planContext: context),
            CaptureDraftSnapshot(title: draft.title, note: draft.note, sourceURL: draft.sourceURL, initialPlan: draft.initialPlan, planContext: nil),
        ]
        for edited in changed {
            state.register(token: "split-input", draft: draft, firstLine: "첫 줄")
            let disposition = state.consume(token: "split-input", draft: edited)
            #expect(disposition == .preserveDraft)
            let alreadyConsumed = state.consume(token: "split-input", draft: draft)
            #expect(alreadyConsumed == nil)
        }
    }

    @Test("분할 첫 줄의 원문이 다르면 같은 snapshot도 지우지 않고 공백을 임의 정규화하지 않는다")
    func captureDraftSplitRequiresExactFirstLine() {
        let draft = CaptureDraftSnapshot(title: " 첫 줄 \r\n두 번째 줄", note: "", sourceURL: "")
        var state = CaptureDraftCommitState()
        state.register(token: "split-input", draft: draft, firstLine: "다른 첫 줄")
        let wrongFirstLine = state.consume(token: "split-input", draft: draft)
        #expect(wrongFirstLine == .preserveDraft)
        state.register(token: "split-input", draft: draft, firstLine: "첫 줄")
        let trimmedFirstLine = state.consume(token: "split-input", draft: draft)
        #expect(trimmedFirstLine == .preserveDraft)
        state.register(token: "split-input", draft: draft, firstLine: " 첫 줄 ")
        let exactFirstLine = state.consume(token: "split-input", draft: draft)
        #expect(exactFirstLine == .removeFirstLine)
    }

    @Test("새 실패 claim을 등록한 뒤 이전 토큰의 receipt는 새 초안을 소비하지 못한다")
    func captureDraftReplacementRejectsStaleReceipt() {
        let first = CaptureDraftSnapshot(title: "이전 제목", note: "이전 메모", sourceURL: "")
        let next = CaptureDraftSnapshot(title: "새 제목", note: "새 메모", sourceURL: "")
        var state = CaptureDraftCommitState()
        state.register(token: "old-input", draft: first)
        state.register(token: "new-input", draft: next)
        let staleReceipt = state.consume(token: "old-input", draft: first)
        #expect(staleReceipt == nil)
        let replacementRetainsCurrentDraft = state.matchesWholeDraft(next)
        #expect(replacementRetainsCurrentDraft)
        let missingReceipt = state.consume(token: nil, draft: next)
        #expect(missingReceipt == nil)
        let currentReceipt = state.consume(token: "new-input", draft: next)
        #expect(currentReceipt == .clearDraft)
        let repeatedReceipt = state.consume(token: "new-input", draft: next)
        #expect(repeatedReceipt == nil)
    }

    @Test("Task 예약 전 제출을 고정해 두 번째 입력과 pending 초기화가 원문·날짜 잠금을 바꾸지 못한다")
    func captureSubmissionFreezesDraftBeforeDispatch() throws {
        let context = try PlanningContext.capture(at: navigationInstant, timeZoneID: "Asia/Seoul", policyRevision: "policy-v1")
        let original = CaptureDraftSnapshot(title: "처음 누른 제목", note: "원래 메모", sourceURL: "https://example.com/original",
            initialPlan: .day(context.planningDay), planContext: context)
        let edited = CaptureDraftSnapshot(title: "뒤에 바꾼 제목", note: "바꾼 메모", sourceURL: "https://example.com/edited")
        var state = CaptureDraftCommitState()
        state.register(token: "old-failure", draft: original)
        let admitted = state.beginSubmission(draft: original)
        let submission = try #require(admitted)
        // 아직 비동기 작업을 예약하지 않은 같은 호출 구간이다.
        let duplicate = state.beginSubmission(draft: edited)
        #expect(duplicate == nil)
        state.clearPending()
        #expect(state.isSubmitting && state.submission == submission)
        #expect(submission.draft == original && submission.draft != edited)
        let removedOldReceipt = state.consume(token: "old-failure", draft: original)
        #expect(removedOldReceipt == nil)
        state.register(token: "current-failure", draft: submission.draft)
        let finished = state.endSubmission(submission)
        #expect(finished && !state.isSubmitting && state.matchesWholeDraft(original))
        let ownReceipt = state.consume(token: "current-failure", draft: original)
        #expect(ownReceipt == .clearDraft)
    }

    @MainActor @Test("원본 저장 뒤 지연된 pending 동안 중복 제출을 막고 같은 키로 확인해 작업 하나와 수정 초안을 보존한다")
    func captureSubmissionKeepsPendingReceiptAcrossDelayedStoreCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorCaptureAdmission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = StoreConfiguration(directory: directory, deviceID: UUID().uuidString)
        let store = try await MirrorStore(configuration: config)
        let context = try PlanningContext.capture(at: navigationInstant, timeZoneID: "Asia/Seoul", policyRevision: "policy-v1")
        let original = CaptureDraftSnapshot(title: "처음 저장한 제목", note: "원본 메모", sourceURL: "https://example.com/original",
            initialPlan: .day(context.planningDay), planContext: context)
        let edited = CaptureDraftSnapshot(title: "실패 안내 뒤 수정", note: "새 메모", sourceURL: "https://example.com/edited")
        var state = CaptureDraftCommitState()
        let admitted = state.beginSubmission(draft: original)
        let submission = try #require(admitted)
        let token = "capture-admitted-once", taskID = UUID()
        let command = CommandEnvelope(requestID: token, idempotencyKey: token, source: .app,
            context: context, workspaceEpoch: config.workspaceEpoch,
            payload: .captureWithPlan(taskID: taskID,
                content: try TaskContent(title: submission.draft.title, note: submission.draft.note, sourceURL: submission.draft.sourceURL),
                initialPlan: try #require(submission.draft.initialPlan)))
        let gate = ShareOperationGate<Void>()
        let saving = Task {
            defer { state.endSubmission(submission) }
            let result = await store.execute(command, at: context.capturedAt, failurePoint: .afterCanonicalSave)
            try await gate.suspend()
            state.register(token: token, draft: submission.draft)
            return result
        }
        await gate.waitUntilSuspended()
        let duplicate = state.beginSubmission(draft: edited)
        #expect(duplicate == nil && state.submission == submission)
        gate.resolve(.success(()))
        let failed = try await saving.value
        #expect(failed.state == .committedProjectionPending)
        #expect(!state.isSubmitting && state.matchesWholeDraft(original))
        let retryAdmission = state.beginSubmission(draft: edited)
        let retrySubmission = try #require(retryAdmission)
        let retried = await store.execute(command, at: context.capturedAt)
        #expect(retried.state == .alreadyApplied)
        let accepted = state.consume(token: token, draft: retrySubmission.draft)
        #expect(accepted == .preserveDraft)
        let finishedRetry = state.endSubmission(retrySubmission)
        #expect(finishedRetry && !state.isSubmitting)
        let snapshot = try await store.snapshot()
        #expect(snapshot.tasks.count == 1 && snapshot.records.count == 1)
        let saved = try #require(snapshot.tasks.first)
        #expect(saved.taskID == taskID && saved.title == original.title)
        #expect(saved.content.note == original.note && saved.content.sourceURL == original.sourceURL)
        #expect(saved.plan.target == original.initialPlan)
        #expect(snapshot.records.first?.idempotencyKey == token)
        _ = try await store.exportAndSuspend(exportedAt: navigationInstant)
    }

    @MainActor @Test("분할 제출은 줄 사이 잠금을 유지하고 pending 첫 줄 재시도 뒤 성공 prefix와 미저장 suffix를 보존한다")
    func captureSplitSubmissionKeepsLeaseAndRemainingReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorSplitAdmission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = StoreConfiguration(directory: directory, deviceID: UUID().uuidString)
        let store = try await MirrorStore(configuration: config)
        let context = try PlanningContext.capture(at: navigationInstant, timeZoneID: "Asia/Seoul", policyRevision: "policy-v1")
        let original = CaptureDraftSnapshot(title: "첫 줄\n둘째 줄\n셋째 줄", note: "공통 원문 메모", sourceURL: "https://example.com/split",
            initialPlan: .day(context.planningDay), planContext: context)
        var state = CaptureDraftCommitState()
        let admitted = state.beginSubmission(draft: original)
        let submission = try #require(admitted)
        let lines = submission.draft.title.components(separatedBy: .newlines)
        func command(_ line: String, token: String) throws -> CommandEnvelope {
            CommandEnvelope(requestID: token, idempotencyKey: token, source: .app,
                context: context, workspaceEpoch: config.workspaceEpoch,
                payload: .captureWithPlan(taskID: UUID(), content: try TaskContent(title: line,
                    note: submission.draft.note, sourceURL: submission.draft.sourceURL),
                    initialPlan: try #require(submission.draft.initialPlan)))
        }
        let first = try command(lines[0], token: "split-first")
        let second = try command(lines[1], token: "split-second")
        let firstResult = await store.execute(first, at: context.capturedAt)
        #expect(firstResult.state == .locallyCommitted)
        state.clearPending()
        let duplicateBetweenLines = state.beginSubmission(draft: original)
        #expect(duplicateBetweenLines == nil && state.submission == submission)
        let secondResult = await store.execute(second, at: context.capturedAt, failurePoint: .afterCanonicalSave)
        #expect(secondResult.state == .committedProjectionPending)
        let remaining = CaptureDraftSnapshot(title: lines.dropFirst().joined(separator: "\n"), note: submission.draft.note,
            sourceURL: submission.draft.sourceURL, initialPlan: submission.draft.initialPlan, planContext: submission.draft.planContext)
        state.register(token: "split-second", draft: remaining, firstLine: lines[1])
        let endedBatch = state.endSubmission(submission)
        #expect(endedBatch && !state.isSubmitting)
        let retryAdmission = state.beginSubmission(draft: remaining)
        let retry = try #require(retryAdmission)
        let retried = await store.execute(second, at: context.capturedAt)
        #expect(retried.state == .alreadyApplied)
        let accepted = state.consume(token: "split-second", draft: retry.draft)
        #expect(accepted == .removeFirstLine)
        let repeatedReceipt = state.consume(token: "split-second", draft: retry.draft)
        #expect(repeatedReceipt == nil)
        let endedRetry = state.endSubmission(retry)
        #expect(endedRetry)
        let snapshot = try await store.snapshot()
        #expect(snapshot.tasks.count == 2 && snapshot.records.count == 2)
        #expect(Set(snapshot.tasks.map(\.title)) == Set(lines.prefix(2)))
        #expect(snapshot.tasks.allSatisfy { $0.content.note == original.note && $0.content.sourceURL == original.sourceURL
            && $0.plan.target == original.initialPlan })
        #expect(remaining.title.components(separatedBy: .newlines).dropFirst().joined(separator: "\n") == lines[2])
        _ = try await store.exportAndSuspend(exportedAt: navigationInstant)
    }

    @Test("이전 제출의 늦은 해제는 새 제출의 잠금과 실패 receipt를 바꾸지 못한다")
    func staleCaptureSubmissionCannotReleaseNewDraft() throws {
        let original = CaptureDraftSnapshot(title: "첫 제출", note: "", sourceURL: "")
        let changed = CaptureDraftSnapshot(title: "다음 제출", note: "다음 메모", sourceURL: "")
        var state = CaptureDraftCommitState()
        let firstAdmission = state.beginSubmission(draft: original)
        let first = try #require(firstAdmission)
        let endedFirst = state.endSubmission(first)
        #expect(endedFirst)
        let nextAdmission = state.beginSubmission(draft: changed)
        let next = try #require(nextAdmission)
        state.register(token: "next-failure", draft: next.draft)
        let endedStale = state.endSubmission(first)
        let duplicate = state.beginSubmission(draft: original)
        #expect(!endedStale && duplicate == nil && state.submission == next)
        #expect(state.matchesWholeDraft(changed))
        let accepted = state.consume(token: "next-failure", draft: changed)
        #expect(accepted == .clearDraft && state.isSubmitting)
        let endedNext = state.endSubmission(next)
        #expect(endedNext && !state.isSubmitting)
    }

    @Test("같은 창의 입력 재호출은 생성 당시 모드와 presentation을 유지한다")
    func captureSameOwnerKeepsPresentation() throws {
        let contextID = UUID()
        let owner = UUID()
        for single in [false, true] {
            var state = CapturePresentationState()
            let openedInitialPresentation = state.open(ownerSceneID: owner, single: single, contextID: contextID)
            #expect(openedInitialPresentation)
            let first = try #require(state.presentation(for: owner))
            let reopenedSameOwner = state.open(ownerSceneID: owner, single: !single, contextID: UUID())
            #expect(reopenedSameOwner)
            #expect(state.request == first)
            #expect(state.presentation(for: owner)?.single == single)
            #expect(state.presentation(for: owner)?.contextID == contextID)
        }
    }

    @Test("다른 창의 입력과 닫기는 기존 owner의 요청을 바꾸지 못한다")
    func captureOtherOwnerCannotReplaceOrClose() throws {
        let contextID = UUID()
        let owner = UUID(), other = UUID()
        var state = CapturePresentationState()
        let openedOwnerPresentation = state.open(ownerSceneID: owner, single: false, contextID: contextID)
        #expect(openedOwnerPresentation)
        let first = try #require(state.request)
        let openedOtherOwnerPresentation = state.open(ownerSceneID: other, single: true, contextID: contextID)
        #expect(!openedOtherOwnerPresentation)
        #expect(state.request == first)
        #expect(state.presentation(for: other) == nil)
        let closedOtherOwnerPresentation = state.close(presentationID: first.id, ownerSceneID: other)
        #expect(!closedOtherOwnerPresentation)
        let closedStalePresentation = state.close(presentationID: UUID(), ownerSceneID: owner)
        #expect(!closedStalePresentation)
        #expect(state.request == first)
    }

    @Test("이전 닫기와 저장 완료는 새 presentation을 해제하지 못한다")
    func staleCaptureCannotCloseNewPresentation() throws {
        let contextID = UUID()
        let owner = UUID()
        var state = CapturePresentationState()
        let openedFirstPresentation = state.open(ownerSceneID: owner, single: true, contextID: contextID)
        #expect(openedFirstPresentation)
        let first = try #require(state.request)
        let closedFirstPresentation = state.close(presentationID: first.id, ownerSceneID: owner)
        #expect(closedFirstPresentation)
        #expect(state.request == nil)
        let openedSecondPresentation = state.open(ownerSceneID: owner, single: true, contextID: contextID)
        #expect(openedSecondPresentation)
        let second = try #require(state.request)
        #expect(second.id != first.id)
        let closedStalePresentation = state.close(presentationID: first.id, ownerSceneID: owner)
        #expect(!closedStalePresentation)
        let finishedStalePresentation = state.finish(presentationID: first.id, ownerSceneID: owner)
        #expect(!finishedStalePresentation)
        #expect(state.request == second)
        let finishedSecondPresentation = state.finish(presentationID: second.id, ownerSceneID: owner)
        #expect(finishedSecondPresentation)
        #expect(state.request == nil)
    }

    @Test("연속 입력 성공은 열어 두고 단일 입력은 자신의 일치하는 성공만 닫는다")
    func captureCompletionModeIsOwned() throws {
        let contextID = UUID()
        let owner = UUID(), other = UUID()
        for single in [false, true] {
            var state = CapturePresentationState()
            let openedPresentation = state.open(ownerSceneID: owner, single: single, contextID: contextID)
            #expect(openedPresentation)
            let request = try #require(state.request)
            let finishedOtherOwnerPresentation = state.finish(presentationID: request.id, ownerSceneID: other)
            #expect(!finishedOtherOwnerPresentation)
            #expect(state.request == request)
            let finishedOwnerPresentation = state.finish(presentationID: request.id, ownerSceneID: owner)
            #expect(finishedOwnerPresentation == single)
            if single {
                #expect(state.request == nil)
            } else {
                #expect(state.request == request)
                let closedContinuousPresentation = state.close(presentationID: request.id, ownerSceneID: owner)
                #expect(closedContinuousPresentation)
                #expect(state.request == nil)
            }
        }
    }

    @MainActor @Test("coordinator는 살아 있는 다른 owner를 거절하고 생성 당시 모드를 유지한다")
    func captureCoordinatorKeepsLiveOwner() throws {
        let contextID = UUID(), nextContextID = UUID()
        let coordinator = CapturePresentationCoordinator()
        let owner = CaptureSceneOwner(), other = CaptureSceneOwner()
        #expect(coordinator.open(owner: owner, single: false, contextID: contextID))
        let first = try #require(coordinator.request)
        #expect(!coordinator.open(owner: other, single: true, contextID: contextID))
        #expect(coordinator.request == first)
        #expect(coordinator.presentation(for: owner.id) == first)
        #expect(coordinator.presentation(for: other.id) == nil)
        #expect(coordinator.open(owner: owner, single: true, contextID: nextContextID))
        #expect(coordinator.request == first)
        #expect(coordinator.request?.single == false)
        #expect(coordinator.request?.contextID == contextID)
        #expect(coordinator.isCurrent(first, contextID: contextID))
        #expect(!coordinator.isCurrent(first, contextID: nextContextID))
        #expect(!coordinator.close(presentationID: first.id, ownerSceneID: other.id))
        #expect(!coordinator.finish(presentationID: first.id, ownerSceneID: other.id))
        #expect(coordinator.request == first)
        #expect(coordinator.close(presentationID: first.id, ownerSceneID: owner.id))
        #expect(coordinator.request == nil)
        #expect(coordinator.open(owner: owner, single: true, contextID: nextContextID))
        let reopened = try #require(coordinator.request)
        #expect(reopened.id != first.id)
        #expect(reopened.contextID == nextContextID)
        #expect(!coordinator.isCurrent(first, contextID: nextContextID))
        #expect(coordinator.isCurrent(reopened, contextID: nextContextID))
        #expect(coordinator.finish(presentationID: reopened.id, ownerSceneID: owner.id))
        #expect(coordinator.request == nil)
    }

    @MainActor @Test("coordinator와 request는 owner를 retain하지 않고 stale close가 새 owner를 해제하지 않는다")
    func captureCoordinatorReclaimsReleasedOwner() throws {
        let contextID = UUID()
        let coordinator = CapturePresentationCoordinator()
        var initialOwner: CaptureSceneOwner? = CaptureSceneOwner()
        weak var weakInitialOwner = initialOwner
        let oldRequest: CapturePresentationRequest
        do {
            let owner = try #require(initialOwner)
            #expect(coordinator.open(owner: owner, single: true, contextID: contextID))
            oldRequest = try #require(coordinator.request)
        }
        initialOwner = nil
        #expect(weakInitialOwner == nil)
        #expect(coordinator.request == nil)
        #expect(coordinator.presentation(for: oldRequest.ownerSceneID) == nil)

        let nextOwner = CaptureSceneOwner()
        #expect(coordinator.open(owner: nextOwner, single: true, contextID: contextID))
        let nextRequest = try #require(coordinator.request)
        #expect(nextRequest.id != oldRequest.id)
        #expect(nextRequest.ownerSceneID == nextOwner.id)
        #expect(!coordinator.close(presentationID: oldRequest.id, ownerSceneID: oldRequest.ownerSceneID))
        #expect(!coordinator.finish(presentationID: oldRequest.id, ownerSceneID: oldRequest.ownerSceneID))
        #expect(coordinator.request == nextRequest)
        #expect(coordinator.finish(presentationID: nextRequest.id, ownerSceneID: nextOwner.id))
        #expect(coordinator.request == nil)
    }

    @Test("설정은 한 창에서만 보이고 다른 창의 열기와 닫기는 기존 요청을 바꾸지 못한다")
    func settingsOtherOwnerCannotPresentOrDismiss() throws {
        let owner = UUID(), other = UUID()
        var state = SettingsPresentationState()
        let openedOwner = state.open(ownerSceneID: owner)
        #expect(openedOwner)
        let request = try #require(state.request)
        #expect(state.presentation(for: owner) == request)
        #expect(state.presentation(for: other) == nil)
        let openedOther = state.open(ownerSceneID: other)
        #expect(!openedOther)
        let closedOther = state.close(presentationID: request.id, ownerSceneID: other)
        #expect(!closedOther)
        let closedUnknown = state.close(presentationID: UUID(), ownerSceneID: owner)
        #expect(!closedUnknown)
        #expect(state.request == request)
        let closedOwner = state.close(presentationID: request.id, ownerSceneID: owner)
        #expect(closedOwner)
        #expect(state.request == nil)
        let openedNextOwner = state.open(ownerSceneID: other)
        #expect(openedNextOwner)
        #expect(state.presentation(for: owner) == nil)
        #expect(state.presentation(for: other)?.ownerSceneID == other)
    }

    @Test("열린 설정 재호출은 유지하고 다시 연 설정은 이전 닫기로 해제하지 못한다")
    func settingsReopeningRejectsStaleDismissal() throws {
        let owner = UUID()
        var state = SettingsPresentationState()
        let openedInitial = state.open(ownerSceneID: owner)
        #expect(openedInitial)
        let first = try #require(state.request)
        let openedSameOwner = state.open(ownerSceneID: owner)
        #expect(openedSameOwner)
        #expect(state.request == first)
        let closedInitial = state.close(presentationID: first.id, ownerSceneID: owner)
        #expect(closedInitial)
        let closedAgain = state.close(presentationID: first.id, ownerSceneID: owner)
        #expect(!closedAgain)
        let openedNext = state.open(ownerSceneID: owner)
        #expect(openedNext)
        let reopened = try #require(state.request)
        #expect(reopened.id != first.id)
        let closedStale = state.close(presentationID: first.id, ownerSceneID: owner)
        #expect(!closedStale)
        #expect(state.request == reopened)
        let closedCurrent = state.close(presentationID: reopened.id, ownerSceneID: owner)
        #expect(closedCurrent)
        #expect(state.request == nil)
    }

    @MainActor @Test("설정 coordinator는 살아 있는 owner를 유지하고 다른 객체의 같은 ID도 거절한다")
    func settingsCoordinatorKeepsLiveOwner() throws {
        let coordinator = SettingsPresentationCoordinator()
        let owner = CaptureSceneOwner(), other = CaptureSceneOwner()
        let duplicateIDOwner = CaptureSceneOwner(id: owner.id)
        #expect(coordinator.open(owner: owner))
        let request = try #require(coordinator.request)
        #expect(coordinator.open(owner: owner))
        #expect(!coordinator.open(owner: other))
        #expect(!coordinator.open(owner: duplicateIDOwner))
        #expect(coordinator.presentation(for: owner.id) == request)
        #expect(coordinator.presentation(for: other.id) == nil)
        #expect(!coordinator.close(presentationID: request.id, ownerSceneID: other.id))
        #expect(coordinator.request == request)
        #expect(coordinator.close(presentationID: request.id, ownerSceneID: owner.id))
        #expect(coordinator.request == nil)
        #expect(coordinator.open(owner: other))
        let next = try #require(coordinator.request)
        #expect(next.ownerSceneID == other.id)
        #expect(!coordinator.close(presentationID: request.id, ownerSceneID: owner.id))
        #expect(coordinator.request == next)
    }

    @MainActor @Test("설정 request는 창을 retain하지 않고 닫힌 창의 늦은 해제가 새 설정을 닫지 않는다")
    func settingsCoordinatorReclaimsReleasedOwner() throws {
        let coordinator = SettingsPresentationCoordinator()
        var initialOwner: CaptureSceneOwner? = CaptureSceneOwner()
        weak var weakInitialOwner = initialOwner
        let oldRequest: SettingsPresentationRequest
        do {
            let owner = try #require(initialOwner)
            #expect(coordinator.open(owner: owner))
            oldRequest = try #require(coordinator.request)
        }
        initialOwner = nil
        #expect(weakInitialOwner == nil)
        #expect(coordinator.request == nil)
        #expect(coordinator.presentation(for: oldRequest.ownerSceneID) == nil)

        let nextOwner = CaptureSceneOwner()
        #expect(coordinator.open(owner: nextOwner))
        let nextRequest = try #require(coordinator.request)
        #expect(nextRequest.id != oldRequest.id)
        #expect(nextRequest.ownerSceneID == nextOwner.id)
        #expect(!coordinator.close(presentationID: oldRequest.id, ownerSceneID: oldRequest.ownerSceneID))
        #expect(coordinator.request == nextRequest)
        #expect(coordinator.close(presentationID: nextRequest.id, ownerSceneID: nextOwner.id))
        #expect(coordinator.request == nil)
    }

    @Test("알림은 현재 epoch의 정리와 일치하는 실제 마감 작업만 열고 명령 경로를 받지 않는다")
    func notificationOwnership() {
        let id = UUID(), other = UUID()
        for weekly in [false, true] {
            let event = notificationEvent(.review(weekly: weekly), request: "review:local-v1:2026-10-03")
            #expect(event.route(workspaceEpoch: "local-v1") == .review(weekly: weekly))
            #expect(event.route(workspaceEpoch: "old-v1") == nil)
        }
        let task = notificationEvent(.task(id), request: "deadline:local-v1:\(id.uuidString)")
        #expect(task.route(workspaceEpoch: "local-v1") == .task(id))
        #expect(notificationEvent(.task(other), request: "deadline:local-v1:\(id.uuidString)").route(workspaceEpoch: "local-v1") == nil)
        #expect(notificationEvent(.review(weekly: false), request: "review:local-v1:2026-02-30").route(workspaceEpoch: "local-v1") == nil)
        #expect(notificationEvent(.today, request: "review:local-v1:2026-10-03").route(workspaceEpoch: "local-v1") == nil)
        #expect(notificationEvent(.capture, request: "review:local-v1:2026-10-03").route(workspaceEpoch: "local-v1") == nil)
        #expect(notificationEvent(.capture, request: "deadline:local-v1:\(id.uuidString)").route(workspaceEpoch: "local-v1") == nil)
        #expect(notificationEvent(.schedule(taskID: id, sessionID: nil, cardID: nil), request: "deadline:local-v1:\(id.uuidString)").route(workspaceEpoch: "local-v1") == nil)
        #expect(notificationEvent(.task(id), request: "foreign:\(id.uuidString)").route(workspaceEpoch: "local-v1") == nil)
        for action in [UNNotificationDismissActionIdentifier, "complete"] {
            #expect(notificationEvent(.task(id), request: "deadline:local-v1:\(id.uuidString)", action: action).route(workspaceEpoch: "local-v1") == nil)
        }
        #expect(NotificationNavigationEvent(actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "review:local-v1:2026-10-03", routeURL: "mirror://review?mode=weekly&mode=daily").route(workspaceEpoch: "local-v1") == nil)
    }

    @MainActor @Test("cold-start tap은 binding까지 보관하고 현재 workspace로 검증한 뒤 전달한다")
    func bufferedColdStartNotification() async {
        let bridge = NotificationNavigationBridge()
        let event = notificationEvent(.review(weekly: true), request: "review:local-v1:2026-10-03")
        bridge.receive(event)
        let route: MirrorRoute = await withCheckedContinuation { continuation in
            bridge.bind(workspaceEpoch: "local-v1") { route in continuation.resume(returning: route) }
        }
        #expect(route == .review(weekly: true))
        bridge.suspend()
    }

    @MainActor @Test("같은 epoch여도 교체 전 binding callback은 전달하지 않는다")
    func previousBindingIsDiscarded() {
        let bridge = NotificationNavigationBridge(), old = NavigationCapture(), current = NavigationCapture()
        let event = notificationEvent(.review(weekly: false), request: "review:local-v1:2026-10-03")
        let oldGeneration = bridge.bind(workspaceEpoch: "local-v1") { old.routes.append($0) }
        bridge.suspend()
        bridge.receive(event)
        let generation = bridge.bind(workspaceEpoch: "local-v1") { current.routes.append($0) }
        bridge.deliver(event, generation: oldGeneration)
        #expect(old.routes.isEmpty)
        #expect(current.routes.isEmpty)
        let next = notificationEvent(.review(weekly: true), request: "review:next-v1:2026-10-03")
        bridge.deliver(next, generation: generation)
        #expect(current.routes.isEmpty)
        bridge.deliver(notificationEvent(.review(weekly: true), request: "review:local-v1:2026-10-03"), generation: generation)
        #expect(current.routes == [.review(weekly: true)])
        bridge.suspend()
    }

    @MainActor @Test("늦은 설치가 current 검사에 실패하면 최신 binding을 덮어쓰지 않는다")
    func obsoleteInstallationCannotReplaceBinding() {
        let bridge = NotificationNavigationBridge(), current = NavigationCapture(), obsolete = NavigationCapture()
        let generation = bridge.bind(workspaceEpoch: "current-v1") { current.routes.append($0) }
        #expect(throws: CancellationError.self) {
            try bridge.bindIfCurrent(workspaceEpoch: "old-v1", isCurrent: { false }) { obsolete.routes.append($0) }
        }
        bridge.deliver(notificationEvent(.review(weekly: true), request: "review:current-v1:2026-10-03"), generation: generation)
        #expect(current.routes == [.review(weekly: true)])
        #expect(obsolete.routes.isEmpty)
        bridge.suspend()
    }

    @Test("Spotlight 활동은 현재 공간의 삭제되지 않은 완전한 작업과 동의가 있어야 상세로 이동한다")
    func spotlightActivation() throws {
        let task = try navigationTask(), deleted = try navigationTask(status: .deleted), incomplete = try navigationTask(complete: false)
        let tasks = [task, deleted, incomplete]
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: task.taskID.uuidString]
        #expect(SpotlightService.navigationRoute(for: activity, tasks: tasks, enabled: true, hideTitles: false) == .task(task.taskID))
        #expect(SpotlightService.navigationRoute(for: activity, tasks: tasks, enabled: false, hideTitles: false) == nil)
        #expect(SpotlightService.navigationRoute(for: activity, tasks: tasks, enabled: true, hideTitles: true) == nil)
        for identifier in [deleted.taskID.uuidString, incomplete.taskID.uuidString, UUID().uuidString, "not-an-id"] {
            #expect(SpotlightService.navigationRoute(activityType: CSSearchableItemActionType,
                itemIdentifier: identifier, tasks: tasks, enabled: true, hideTitles: false) == nil)
        }
        #expect(SpotlightService.navigationRoute(activityType: "other.activity", itemIdentifier: task.taskID.uuidString,
            tasks: tasks, enabled: true, hideTitles: false) == nil)
    }

    @Test("오늘 조회는 50개 반환 경계에서도 해당 날짜의 실제 전체 개수와 순서를 유지한다")
    func todayReplyCountBoundary() throws {
        for (total, returned) in [(0, 0), (1, 1), (50, 50), (51, 50), (100, 50)] {
            let tasks = try (0..<total).map { _ in try navigationTask() }
            let reply = MirrorTodayTaskReplyPolicy.response(tasks, hideTitle: false)
            #expect(reply.totalCount == total)
            #expect(reply.entities.count == returned)
            #expect(reply.entities.map(\.id) == Array(tasks.prefix(returned).map(\.taskID)))
            #expect(tasks.count == total)
        }
    }

    @Test("잘린 오늘 조회도 외부 제목 숨김과 실제 마감·계획을 보존한다")
    func truncatedTodayReplyPrivacy() throws {
        let day = try LocalDate("2026-10-07")
        let tasks = try (0..<51).map { _ in try navigationTask(deadline: .day(localDate: day, timeZoneID: "Asia/Seoul")) }
        let hidden = MirrorTodayTaskReplyPolicy.response(tasks, hideTitle: true)
        let visible = MirrorTodayTaskReplyPolicy.response(tasks, hideTitle: false)
        #expect(hidden.totalCount == 51 && visible.totalCount == 51)
        #expect(hidden.entities.count == 50 && visible.entities.count == 50)
        #expect(hidden.entities.map(\.id) == visible.entities.map(\.id))
        #expect(hidden.entities.allSatisfy { $0.title == "할 일" })
        #expect(visible.entities.allSatisfy { $0.title == "외부에 노출하지 않을 제목" })
        #expect(hidden.entities.allSatisfy { $0.planSummary == "계획 2026-10-04" && !$0.completed })
        #expect(hidden.entities.allSatisfy { $0.deadlineKind == .day && $0.deadlineDay == "2026-10-07" &&
            $0.deadlineInstant == nil && $0.deadlineTimeZoneID == "Asia/Seoul" })
        #expect(tasks.count == 51 && tasks.allSatisfy { $0.title == "외부에 노출하지 않을 제목" })
    }

    @Test("Shortcuts 실제 마감은 계획과 분리하고 날짜 마감을 자정 시각으로 바꾸지 않는다")
    func entityDeadlineContract() throws {
        let day = try LocalDate("2026-10-07")
        let dateEntity = MirrorTaskEntity(task: try navigationTask(deadline: .day(localDate: day, timeZoneID: "Asia/Seoul")), hideTitle: true)
        #expect(dateEntity.title == "할 일")
        #expect(dateEntity.planSummary == "계획 2026-10-04")
        #expect(dateEntity.deadlineKind == .day && dateEntity.deadlineDay == "2026-10-07")
        #expect(dateEntity.deadlineInstant == nil && dateEntity.deadlineTimeZoneID == "Asia/Seoul")
        let instantEntity = MirrorTaskEntity(task: try navigationTask(deadline: .instant(utcTimestamp: navigationInstant, displayTimeZoneID: "America/Los_Angeles")), hideTitle: false)
        #expect(instantEntity.deadlineKind == .instant && instantEntity.deadlineInstant == navigationInstant)
        #expect(instantEntity.deadlineDay == nil && instantEntity.deadlineTimeZoneID == "America/Los_Angeles")
        let unset = MirrorTaskEntity(task: try navigationTask(), hideTitle: false)
        #expect(unset.deadlineKind == .notSet && unset.deadlineDay == nil && unset.deadlineInstant == nil && unset.deadlineTimeZoneID == nil)
    }

    @Test("마감 알림을 꺼도 저장된 작업별 시각은 재시작과 재활성화 뒤 유지된다")
    func pausedDeadlinePreferencesRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorDeadlinePreference-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = StoreConfiguration(directory: directory, deviceID: UUID().uuidString)
        let store = try await MirrorStore(configuration: configuration)
        let context = try await store.currentContext(at: navigationInstant)
        let id = UUID()
        let captured = await store.execute(.init(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
            source: .app, context: context, workspaceEpoch: configuration.workspaceEpoch,
            payload: .capture(taskID: id, content: try TaskContent(title: "마감 설정 유지"))), at: navigationInstant)
        #expect(captured.state == .locallyCommitted)
        let task = try #require(try await store.taskProjection(id))
        let deadline = Deadline.day(localDate: try context.planningDay.addingDays(1), timeZoneID: context.timeZoneID)
        let saved = await store.execute(.init(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString,
            source: .app, context: context, workspaceEpoch: configuration.workspaceEpoch,
            payload: .setDeadline(taskID: id, deadline: deadline,
                expectedDeadline: try #require(task.versions[.deadline]?.headsDigest))), at: navigationInstant)
        #expect(saved.state == .locallyCommitted)
        let selected = DeadlineNotificationPreference(taskID: id, fireAt: navigationInstant.addingTimeInterval(3_600))
        let disabled = SystemPreferences(notificationsOnThisDevice: true, deadlineNotificationsEnabled: false,
                                         deadlineNotifications: [selected])
        try await store.setLocalValue(JSONEncoder().encode(disabled), forKey: "system-preferences-v1")
        try await store.suspend()
        let reopened = try await MirrorStore(configuration: configuration)
        var restored = try await SystemPreferenceRecoveryPolicy.load(store: reopened)
        #expect(!restored.deadlineNotificationsEnabled)
        #expect(restored.deadlineNotifications == [selected])
        let snapshot = try await reopened.snapshot()
        #expect(try SurfaceReconciliationPlan.notifications(snapshot: snapshot, preferences: restored, at: navigationInstant).requests.isEmpty)
        restored.deadlineNotificationsEnabled = true
        let plan = try SurfaceReconciliationPlan.notifications(snapshot: snapshot, preferences: restored, at: navigationInstant)
        #expect(plan.requests.count == 1)
        #expect(plan.requests.first?.taskID == id && plan.requests.first?.fireAt == selected.fireAt)
        try await reopened.suspend()
    }

    @Test("마감 알림 허용은 빈 목록에서도 유지하고 이전 설정 형식의 의미도 보존한다")
    func deadlinePermissionAndLegacyPreferences() throws {
        let enabled = SystemPreferences(notificationsOnThisDevice: true, deadlineNotificationsEnabled: true)
        let restored = try JSONDecoder().decode(SystemPreferences.self, from: JSONEncoder().encode(enabled))
        #expect(restored.deadlineNotificationsEnabled && restored.deadlineNotifications.isEmpty)
        for permitsNotifications in [false, true] {
            let old = SystemPreferences(notificationsOnThisDevice: permitsNotifications,
                deadlineNotifications: [.init(taskID: UUID(), fireAt: navigationInstant)])
            var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
            object.removeValue(forKey: "deadlineNotificationsEnabled")
            let decoded = try JSONDecoder().decode(SystemPreferences.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(decoded.deadlineNotificationsEnabled == permitsNotifications)
            #expect(decoded.deadlineNotifications == old.deadlineNotifications)
        }
    }

    @Test("이전 시스템 후처리가 gate를 보유하면 숨김 설정은 저장 성공으로 위장하지 않는다", .timeLimit(.minutes(1)))
    func privacyPreferenceWriteUsesReconciliationGate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorSurfaceGate-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await MirrorStore(configuration: .init(directory: directory, deviceID: UUID().uuidString))
        let services = SystemServices(store: store, directory: directory, workspaceEpoch: "local-v1")
        let publicPreferences = SystemPreferences(hideExternalTitles: false, spotlightEnabled: true, notificationsOnThisDevice: true)
        try await services.savePreferences(publicPreferences)
        let descriptor = Darwin.open(directory.appendingPathComponent("SystemSurface.lock").path,
                                     O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let hidden = SystemPreferences(hideExternalTitles: true, spotlightEnabled: false, notificationsOnThisDevice: true)
        await #expect(throws: StoreError.busy) { try await services.savePreferences(hidden) }
        #expect(try await services.preferences() == publicPreferences)
        let report = await services.reconcileExternalSurfaces(at: navigationInstant)
        #expect(report.failures == [.busy])
        let surfaces = await services.surfaces
        await #expect(throws: StoreError.busy) { _ = try await surfaces.clearExternalSurfaces() }
        try #require(flock(descriptor, LOCK_UN) == 0)
        // gate를 얻은 뒤에만 설정을 저장한다. OS API 없는 SwiftPM host의 정리 실패도 그대로 보고한다.
        if SystemAppleRuntimeHost.isApplicationOrExtension {
            try await services.savePreferences(hidden)
        } else {
            await #expect(throws: SpotlightServiceError.configurationRequired) { try await services.savePreferences(hidden) }
        }
        #expect(try await services.preferences() == hidden)
        try await store.suspend()
    }

    @Test("숨김 적용이 busy여도 재시작한 같은 공간은 미완료 선택을 복원하고 다시 적용한다", .timeLimit(.minutes(1)))
    @MainActor
    func pendingPrivacySurvivesBusyAndReopen() async throws {
        let suite = "MirrorPendingPrivacy-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = StoreConfiguration(directory: directory, deviceID: UUID().uuidString)
        let store = try await MirrorStore(configuration: config)
        let services = SystemServices(store: store, directory: directory, workspaceEpoch: config.workspaceEpoch)
        let old = SystemPreferences(hideExternalTitles: false, spotlightEnabled: true, notificationsOnThisDevice: true)
        try await services.savePreferences(old)
        let hidden = SystemPreferences(hideExternalTitles: true, spotlightEnabled: false, notificationsOnThisDevice: false)
        let journal = SystemPreferenceUpdateJournal(defaults: defaults)
        let submitted = try journal.record(hidden, for: config)
        let descriptor = Darwin.open(directory.appendingPathComponent("SystemSurface.lock").path,
                                     O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        try #require(descriptor >= 0)
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: StoreError.busy) { try await services.savePreferences(submitted.preferences) }
        #expect(try await services.preferences() == old)
        try await store.suspend()

        let reopened = try await MirrorStore(configuration: config)
        let restarted = SystemPreferenceUpdateJournal(defaults: try #require(UserDefaults(suiteName: suite)))
        let pending = try #require(try restarted.pending(for: config))
        #expect(pending.id == submitted.id && pending.preferences == hidden)
        let recoveredServices = SystemServices(store: reopened, directory: directory, workspaceEpoch: config.workspaceEpoch)
        #expect(try await recoveredServices.preferences() == old)
        try #require(flock(descriptor, LOCK_UN) == 0)
        if SystemAppleRuntimeHost.isApplicationOrExtension {
            try await recoveredServices.savePreferences(pending.preferences)
        } else {
            await #expect(throws: SpotlightServiceError.configurationRequired) {
                try await recoveredServices.savePreferences(pending.preferences)
            }
        }
        #expect(try await recoveredServices.preferences() == hidden)
        let report = await recoveredServices.reconcileExternalSurfaces(at: navigationInstant)
        try restarted.acknowledge(pending, after: report)
        #expect(try restarted.pending(for: config) == (report.failures.isEmpty ? nil : pending))
        try await reopened.suspend()
    }

    @Test("미완료 설정은 다른 공간에 적용되지 않고 오래된 완료와 후처리 실패도 최신 선택을 지우지 않는다")
    @MainActor
    func pendingPrivacyIsScopedAndAcknowledgesOnlyItsOwnSuccess() throws {
        let suite = "MirrorPendingScope-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = SystemPreferenceUpdateJournal(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let config = StoreConfiguration(directory: directory, deviceID: UUID().uuidString)
        let hidden = SystemPreferences()
        let first = try journal.record(hidden, for: config)
        let otherConfigurations = [
            StoreConfiguration(directory: directory.appendingPathComponent("other"), deviceID: config.deviceID),
            StoreConfiguration(directory: directory, workspaceKey: "other", deviceID: config.deviceID),
            StoreConfiguration(directory: directory, workspaceEpoch: "other", deviceID: config.deviceID),
            StoreConfiguration(directory: directory, deviceID: config.deviceID,
                cloudSync: .init(containerIdentifier: "test-container", accountScope: "test-account"))
        ]
        for other in otherConfigurations { #expect(try journal.pending(for: other) == nil) }
        let foreign = try journal.record(hidden, for: otherConfigurations[0])
        let cloud = otherConfigurations[3]
        try journal.record(hidden, for: cloud)
        let anotherAccount = StoreConfiguration(directory: directory, deviceID: config.deviceID,
            cloudSync: .init(containerIdentifier: "test-container", accountScope: "another-account"))
        let anotherContainer = StoreConfiguration(directory: directory, deviceID: config.deviceID,
            cloudSync: .init(containerIdentifier: "another-container", accountScope: "test-account"))
        #expect(try journal.pending(for: anotherAccount) == nil)
        #expect(try journal.pending(for: anotherContainer) == nil)
        let newest = try journal.record(SystemPreferences(reviewNotification: .init(enabled: true)), for: config)
        let success = SurfaceReconciliationReport(failures: [], omittedNotificationCount: 0)
        try journal.acknowledge(first, after: success)
        #expect(try journal.pending(for: config)?.id == newest.id)
        try journal.acknowledge(newest, after: .init(failures: [.spotlight], omittedNotificationCount: 0))
        #expect(try journal.pending(for: config)?.id == newest.id)
        try journal.acknowledge(newest, after: success)
        #expect(try journal.pending(for: config) == nil)
        #expect(try journal.pending(for: otherConfigurations[0])?.id == foreign.id)
        try journal.discard(for: config)
        #expect(try journal.pending(for: otherConfigurations[0])?.id == foreign.id)
    }

    @Test("실제 SQLite 복구 marker는 모든 외부 설정을 닫고 확인 후에도 재동의를 요구한다")
    func recoveryPrivacyAndAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorRecoveryPrivacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await MirrorStore(configuration: .init(directory: directory, deviceID: UUID().uuidString))
        let services = SystemServices(store: store, directory: directory, workspaceEpoch: "local-v1")
        let optedIn = SystemPreferences(planningTimeZoneID: "America/Los_Angeles", policyRevision: "preserved-policy",
            hideExternalTitles: false, spotlightEnabled: true, notificationsOnThisDevice: true,
            selectedCalendarIDs: ["selected-calendar"], reviewNotification: .init(enabled: true),
            deadlineNotifications: [.init(taskID: UUID(), fireAt: navigationInstant)])
        try await store.setLocalValue(JSONEncoder().encode(optedIn), forKey: "system-preferences-v1")
        let notice = ProjectionRecoveryNotice(recoveredAt: navigationInstant)
        try await store.setLocalValue(JSONEncoder().encode(notice), forKey: "projection-recovery-v1")
        #expect(try await services.projectionRecoveryNotice() == notice)
        let safe = try await services.preferences()
        #expect(safe.hideExternalTitles && !safe.spotlightEnabled && !safe.notificationsOnThisDevice)
        #expect(!safe.deadlineNotificationsEnabled)
        #expect(safe.selectedCalendarIDs.isEmpty && !safe.reviewNotification.enabled && safe.deadlineNotifications.isEmpty)
        #expect(safe.planningTimeZoneID == optedIn.planningTimeZoneID && safe.policyRevision == optedIn.policyRevision)
        #expect(try await SystemPreferenceRecoveryPolicy.load(store: store) == safe)
        if SystemAppleRuntimeHost.isApplicationOrExtension {
            try await services.savePreferences(optedIn)
        } else {
            await #expect(throws: SpotlightServiceError.configurationRequired) { try await services.savePreferences(optedIn) }
        }
        let persisted = try #require(try await store.localValue(forKey: "system-preferences-v1"))
        #expect(try JSONDecoder().decode(SystemPreferences.self, from: persisted) == safe)
        #expect(try await services.projectionRecoveryNotice() == notice)
        await #expect(throws: SystemServiceError.invalidInput) {
            try await services.acknowledgeProjectionRecovery(.init(recoveredAt: navigationInstant.addingTimeInterval(-1)))
        }
        #expect(try await services.projectionRecoveryNotice() == notice)
        try await services.acknowledgeProjectionRecovery(notice)
        #expect(try await services.projectionRecoveryNotice() == nil)
        #expect(try await services.preferences() == safe)
        _ = try await store.exportAndSuspend(exportedAt: navigationInstant)
    }

    @Test("읽을 수 없는 복구 marker도 raw opt-in과 Widget 제목을 허용하지 않는다")
    func invalidRecoveryMarkerStillHidesWidget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorRecoveryWidget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await MirrorStore(configuration: .init(directory: directory, deviceID: UUID().uuidString))
        let context = try await store.currentContext(at: navigationInstant)
        let taskID = UUID()
        let result = await store.execute(.init(requestID: UUID().uuidString, idempotencyKey: "recovery-widget", source: .app,
            context: context, workspaceEpoch: "local-v1", payload: .capture(taskID: taskID,
                content: try TaskContent(title: "복구 이전 공개 제목"))), at: navigationInstant)
        #expect(result.state == .locallyCommitted)
        try await store.setLocalValue(JSONEncoder().encode(SystemPreferences(hideExternalTitles: false, spotlightEnabled: true)), forKey: "system-preferences-v1")
        try await store.setLocalValue(Data("unsupported recovery marker".utf8), forKey: "projection-recovery-v1")
        let services = SystemServices(store: store, directory: directory, workspaceEpoch: "local-v1")
        #expect(try await services.preferences().hideExternalTitles)
        await #expect(throws: SystemServiceError.unavailable) { _ = try await services.projectionRecoveryNotice() }
        let state = try await services.widget.snapshot(at: navigationInstant)
        #expect(state.card?.taskID == taskID && state.card?.title == "할 일 1개")
        #expect(try await store.localValue(forKey: "projection-recovery-v1") != nil)
        _ = try await store.exportAndSuspend(exportedAt: navigationInstant)
    }
}

@MainActor private final class ShareOperationGate<Value: Sendable> {
    private var operation: CheckedContinuation<Value, any Error>?
    private var observer: CheckedContinuation<Void, Never>?

    func suspend() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            operation = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        guard operation == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resolve(_ result: Result<Value, any Error>) {
        operation?.resume(with: result)
        operation = nil
    }
}

@MainActor @Suite("공유 확장 지연 입력과 저장", .timeLimit(.minutes(1)))
struct ShareCaptureSessionTests {
    @Test("지연된 공유 읽기 중 편집과 저장을 막고 긴 원문과 모든 URL을 보존한다")
    func delayedLoadLocksEditingAndPreservesOriginal() async {
        let session = ShareCaptureSession()
        let gate = ShareOperationGate<(text: [String], links: [String])>()
        let loading = Task { await session.load { try await gate.suspend() } }
        await gate.waitUntilSuspended()
        #expect(session.isLoading && !session.canEdit && !session.canSave && session.canCancel)
        session.title = "읽는 중 입력"
        session.note = "읽는 중 메모"
        session.sourceURL = "https://example.com/edited"
        #expect(session.title.isEmpty && session.note.isEmpty && session.sourceURL.isEmpty)
        var captures = 0, extraReads = 0
        let saved = await session.save { _, _ in captures += 1 }
        await session.load { extraReads += 1; return (["덮어쓰면 안 되는 입력"], []) }
        #expect(!saved && captures == 0 && extraReads == 0)
        let original = String(repeating: "한👩🏽‍💻", count: 251) + "\n끝"
        let links = ["https://example.com/first", "https://example.com/second"]
        gate.resolve(.success(([original], links)))
        await loading.value
        #expect(!session.isLoading && session.canEdit && session.canSave)
        #expect(session.title.isEmpty)
        #expect(session.note == original + "\n" + links.joined(separator: "\n"))
        #expect(session.sourceURL == links[0])
        #expect(session.message == "여러 링크가 있어요. 저장할 링크 하나를 확인하세요. 원문을 자동으로 가져오지 않아요.")
        session.title = "사용자가 정한 제목"
        #expect(session.title == "사용자가 정한 제목")
    }

    @Test("읽기 중 취소한 확장은 늦은 provider 성공과 실패를 반영하거나 저장하지 않는다", arguments: [false, true])
    func cancelledLoadIgnoresLateOutcome(fails: Bool) async {
        let session = ShareCaptureSession()
        let gate = ShareOperationGate<(text: [String], links: [String])>()
        let loading = Task { await session.load { try await gate.suspend() } }
        await gate.waitUntilSuspended()
        let cancelled = session.cancel()
        let cancelledAgain = session.cancel()
        #expect(cancelled)
        #expect(!cancelledAgain)
        if fails { gate.resolve(.failure(SystemServiceError.unavailable)) }
        else { gate.resolve(.success((["늦게 읽은 원문"], ["https://example.com/source"]))) }
        await loading.value
        var captures = 0
        let saved = await session.save { _, _ in captures += 1 }
        #expect(!saved && captures == 0)
        #expect(session.title.isEmpty && session.note.isEmpty && session.sourceURL.isEmpty && session.message == nil)
        #expect(!session.isLoading && !session.canEdit && !session.canCancel && !session.didSave)
    }

    @Test("저장 결과를 기다리는 동안 세 필드와 취소를 잠그고 중복 완료를 허용하지 않는다")
    func delayedSaveKeepsSubmittedDraftAndCompletesOnce() async {
        let session = ShareCaptureSession()
        await session.load { (["공유 원문"], ["https://example.com/source"]) }
        session.title = "저장할 제목"
        session.note = "공유 원문\n추가한 메모"
        session.sourceURL = "https://example.com/selected"
        let expected = CaptureDraftSnapshot(title: "저장할 제목", note: "공유 원문\n추가한 메모",
                                            sourceURL: "https://example.com/selected")
        let gate = ShareOperationGate<Void>()
        var submitted: [CaptureDraftSnapshot] = []
        var keys: [String] = []
        let saving = Task {
            await session.save { draft, key in
                submitted.append(draft); keys.append(key)
                try await gate.suspend()
            }
        }
        await gate.waitUntilSuspended()
        #expect(session.isSaving && !session.didSave && !session.canEdit && !session.canSave && !session.canCancel)
        session.title = "저장 중 새 제목"
        session.note = "저장 중 새 메모"
        session.sourceURL = "https://example.com/new"
        #expect(session.title == expected.title && session.note == expected.note && session.sourceURL == expected.sourceURL)
        let cancelledWhileSaving = session.cancel()
        #expect(!cancelledWhileSaving)
        let duplicate = await session.save { draft, key in submitted.append(draft); keys.append(key) }
        #expect(!duplicate && submitted == [expected] && keys.count == 1)
        gate.resolve(.success(()))
        let saved = await saving.value
        #expect(saved && session.didSave && !session.isSaving && !session.canEdit && !session.canCancel)
        let repeated = await session.save { draft, key in submitted.append(draft); keys.append(key) }
        #expect(!repeated && submitted == [expected] && keys.count == 1)
    }

    @Test("지연된 저장 실패는 입력과 재시도 멱등 키를 보존하고 편집·취소를 다시 허용한다")
    func failedSaveKeepsDraftAndRetryKey() async {
        let session = ShareCaptureSession()
        await session.load { (["원문\n둘째 줄"], ["https://example.com/source"]) }
        session.title = "사용자가 수정한 제목"
        let expected = CaptureDraftSnapshot(title: session.title, note: session.note, sourceURL: session.sourceURL)
        let gate = ShareOperationGate<Void>()
        var submitted: [CaptureDraftSnapshot] = []
        var keys: [String] = []
        let saving = Task {
            await session.save { draft, key in
                submitted.append(draft); keys.append(key)
                try await gate.suspend()
            }
        }
        await gate.waitUntilSuspended()
        gate.resolve(.failure(SystemServiceError.unavailable))
        let failed = await saving.value
        #expect(!failed && !session.didSave && !session.isSaving && session.canEdit && session.canCancel)
        #expect(session.title == expected.title && session.note == expected.note && session.sourceURL == expected.sourceURL)
        #expect(session.message == SystemServiceError.unavailable.errorDescription)
        let retried = await session.save { draft, key in submitted.append(draft); keys.append(key) }
        #expect(retried && session.didSave)
        #expect(submitted == [expected, expected])
        #expect(keys.count == 2 && keys[0] == keys[1] && !keys[0].isEmpty)
    }

    @Test("실제 저장 후 응답 실패와 편집이 겹쳐도 이전 입력을 중복 저장하지 않고 수정본을 별도 명시 저장한다")
    func committedSaveRetryPreservesEditedDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MirrorShareRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await MirrorStore(configuration: .init(directory: directory, deviceID: UUID().uuidString))
        let services = SystemServices(store: store, directory: directory, workspaceEpoch: "local-v1")
        let session = ShareCaptureSession()
        await session.load { (["처음 공유한 원문"], ["https://example.com/first"]) }
        let original = CaptureDraftSnapshot(title: session.title, note: session.note, sourceURL: session.sourceURL)
        var submissions: [CaptureDraftSnapshot] = []
        var keys: [String] = []
        let first = await session.save { draft, key in
            submissions.append(draft); keys.append(key)
            _ = try await services.capture(title: draft.title, note: draft.note, sourceURL: draft.sourceURL, source: .share, key: key)
            // 원본 명령은 성공했지만 호출자는 결과를 받지 못한 경계다.
            throw SystemServiceError.unavailable
        }
        #expect(!first && session.needsSaveConfirmation && !session.didSave)
        let initiallySaved = try await services.tasks()
        #expect(initiallySaved.map(\.title) == [original.title])
        session.title = "실패 안내 뒤 편집한 제목"
        session.note = "실패 안내 뒤 편집한 메모"
        session.sourceURL = "https://example.com/edited"
        let edited = CaptureDraftSnapshot(title: session.title, note: session.note, sourceURL: session.sourceURL)
        let confirmed = await session.save { draft, key in
            submissions.append(draft); keys.append(key)
            _ = try await services.capture(title: draft.title, note: draft.note, sourceURL: draft.sourceURL, source: .share, key: key)
        }
        #expect(!confirmed && !session.didSave && session.canEdit && session.canSave && !session.needsSaveConfirmation)
        #expect(session.title == edited.title && session.note == edited.note && session.sourceURL == edited.sourceURL)
        #expect(submissions == [original, original])
        #expect(keys.count == 2 && keys[0] == keys[1])
        let confirmedTasks = try await services.tasks()
        #expect(confirmedTasks.count == 1 && confirmedTasks.first?.taskID == initiallySaved.first?.taskID)
        #expect(session.message == "이전 입력을 저장했어요. 변경한 입력은 아직 저장하지 않았어요. 확인하고 저장하세요.")
        let savedEditedDraft = await session.save { draft, key in
            submissions.append(draft); keys.append(key)
            _ = try await services.capture(title: draft.title, note: draft.note, sourceURL: draft.sourceURL, source: .share, key: key)
        }
        #expect(savedEditedDraft && session.didSave)
        #expect(submissions == [original, original, edited])
        #expect(keys.count == 3 && keys[0] == keys[1] && keys[1] != keys[2])
        let savedTasks = try await services.tasks()
        #expect(savedTasks.count == 2 && Set(savedTasks.map(\.title)) == Set([original.title, edited.title]))
        let editedTask = try #require(savedTasks.first { $0.title == edited.title })
        #expect(editedTask.content.note == edited.note && editedTask.content.sourceURL == edited.sourceURL)
        _ = try await store.exportAndSuspend(exportedAt: navigationInstant)
    }

    @Test("명령 실행 전 입력 검증 실패는 잘못된 원문 대신 사용자가 수정한 입력을 저장한다")
    func invalidInputAllowsCorrectedDraft() async {
        let session = ShareCaptureSession()
        await session.load { ([" "], []) }
        var submissions: [CaptureDraftSnapshot] = []
        let first = await session.save { draft, _ in
            submissions.append(draft)
            throw SystemServiceError.invalidInput
        }
        #expect(!first && session.canEdit && !session.needsSaveConfirmation)
        session.title = "바로잡은 제목"
        let corrected = await session.save { draft, _ in submissions.append(draft) }
        #expect(corrected && session.didSave)
        #expect(submissions.map(\.title) == [" ", "바로잡은 제목"])
    }

    @Test("공유 읽기 실패 뒤 수동 입력한 세 필드는 그대로 저장 요청에 전달한다")
    func loadFailureAllowsManualEntry() async {
        let session = ShareCaptureSession()
        await session.load { throw SystemServiceError.unavailable }
        #expect(!session.isLoading && session.canEdit && session.canSave && session.canCancel && session.message != nil)
        session.title = "수동 제목"
        session.note = "수동 메모"
        session.sourceURL = "https://example.com/manual"
        var submitted: CaptureDraftSnapshot?
        let saved = await session.save { draft, _ in submitted = draft }
        #expect(saved)
        #expect(submitted == CaptureDraftSnapshot(title: "수동 제목", note: "수동 메모", sourceURL: "https://example.com/manual"))
    }
}
