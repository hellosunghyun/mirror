import Foundation
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
