import Foundation
import Darwin
import MirrorDomain
import MirrorData

public enum SurfaceReconciliationFailure: String, Codable, Sendable {
    case busy, canonicalRead, preferences, notifications, spotlight
}

public struct SurfaceReconciliationReport: Equatable, Sendable {
    public let failures: Set<SurfaceReconciliationFailure>
    public let omittedNotificationCount: Int
    public var safeUserMessage: String? {
        failures.isEmpty ? nil : "저장은 유지했어요. 알림 또는 시스템 검색 갱신을 미러에서 다시 확인하세요."
    }
}

/// 모든 실행 표면은 저장된 기기 설정과 reducer가 적용한 원본만으로 예약을 계산한다.
enum SurfaceReconciliationPlan {
    static func notifications(snapshot: StoreSnapshot, preferences: SystemPreferences, at now: Date) throws -> NotificationPlan {
        let context = try PlanningContext.capture(at: now, timeZoneID: snapshot.policy.timeZoneID,
                                                 policyRevision: snapshot.policy.revision)
        let report = TaskReducer.reduce(snapshot.records, workspaceKey: snapshot.workspaceKey, workspaceEpoch: snapshot.workspaceEpoch)
        var closedDays: Set<LocalDate> = []
        for offset in 0..<NotificationPlanner.reviewHorizon {
            let day = try context.planningDay.addingDays(offset)
            let dayContext = try PlanningContext(planningDay: day, timeZoneID: context.timeZoneID,
                                                policyRevision: context.policyRevision, capturedAt: now)
            if report.isCycleClosed(ReviewCycle.id(workspaceEpoch: snapshot.workspaceEpoch, context: dayContext)) {
                closedDays.insert(day)
            }
        }
        return try NotificationPlanner.plan(context: context, workspaceEpoch: snapshot.workspaceEpoch, now: now,
            review: preferences.reviewNotification, closedDays: closedDays,
            tasks: snapshot.tasks,
            deadlines: preferences.deadlineNotificationsEnabled ? preferences.deadlineNotifications : [])
    }
}

/// 앱·위젯·Shortcuts의 저장 후 갱신이다. OS 후처리 실패가 canonical 저장을 되돌리지 않는다.
public actor SurfaceReconciler {
    private let store: MirrorStore
    private let directory: URL
    private let notifications: NotificationService
    private let spotlight: SpotlightService

    public init(store: MirrorStore, directory: URL,
                notifications: NotificationService = NotificationService(), spotlight: SpotlightService = SpotlightService()) {
        self.store = store; self.directory = directory
        self.notifications = notifications; self.spotlight = spotlight
    }

    public func reconcile(at now: Date = Date()) async -> SurfaceReconciliationReport {
        let descriptor: Int32
        do { descriptor = try await acquire() }
        catch { return .init(failures: [.busy], omittedNotificationCount: 0) }
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        let snapshot: StoreSnapshot
        do {
            try await SystemStoreBoundary.validate(store)
            snapshot = try await store.snapshot()
        } catch { return .init(failures: [.canonicalRead], omittedNotificationCount: 0) }
        let preferences: SystemPreferences
        do {
            preferences = try await SystemPreferenceRecoveryPolicy.load(store: store)
        } catch { return .init(failures: [.preferences], omittedNotificationCount: 0) }
        var failures: Set<SurfaceReconciliationFailure> = []
        var omitted = 0
        if preferences.notificationsOnThisDevice {
            do {
                let plan = try SurfaceReconciliationPlan.notifications(snapshot: snapshot, preferences: preferences, at: now)
                omitted = plan.omittedCount
                try await notifications.reconcile(plan: plan)
            } catch { failures.insert(.notifications) }
        } else {
            do { try await notifications.clearAll() } catch { failures.insert(.notifications) }
        }
        do {
            try await spotlight.reconcile(tasks: snapshot.tasks, enabled: preferences.spotlightEnabled,
                                          hideTitles: preferences.hideExternalTitles)
        } catch { failures.insert(.spotlight) }
        return .init(failures: failures, omittedNotificationCount: omitted)
    }

    /// 동의 철회와 이전 설정의 OS 후처리를 같은 프로세스 간 gate로 순서화한다.
    /// gate 획득 실패는 설정 저장 성공으로 처리하지 않는다.
    public func savePreferences(_ preferences: SystemPreferences) async throws {
        let descriptor = try await acquire()
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        try await SystemStoreBoundary.validate(store)
        let recoveryPending = try await store.localValue(forKey: SystemPreferenceRecoveryPolicy.markerKey) != nil
        let effective = recoveryPending ? SystemPreferenceRecoveryPolicy.failClosed(preferences) : preferences
        try await store.setLocalValue(JSONEncoder().encode(effective), forKey: "system-preferences-v1")
        var cleanupError: (any Error)?
        if !effective.spotlightEnabled || effective.hideExternalTitles {
            do { try await spotlight.removeAll() } catch { cleanupError = error }
        }
        if !effective.notificationsOnThisDevice {
            do { try await notifications.clearAll() } catch { if cleanupError == nil { cleanupError = error } }
        }
        if let cleanupError { throw cleanupError }
    }

    public func acknowledgeProjectionRecovery(_ notice: ProjectionRecoveryNotice) async throws {
        let descriptor = try await acquire()
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        guard let current = try await SystemPreferenceRecoveryPolicy.notice(store: store), current == notice else {
            throw SystemServiceError.invalidInput
        }
        let safe = SystemPreferenceRecoveryPolicy.failClosed(try await SystemPreferenceRecoveryPolicy.load(store: store))
        try await store.setLocalValue(JSONEncoder().encode(safe), forKey: "system-preferences-v1")
        try await store.setLocalValue(nil, forKey: SystemPreferenceRecoveryPolicy.markerKey)
    }

    /// 원본을 이미 닫은 뒤에도, 앞서 시작한 후처리가 끝난 다음 OS 표시를 지운다.
    public func clearExternalSurfaces() async throws -> Set<LocalSurfaceCleanupFailure> {
        let descriptor = try await acquire()
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        var failures: Set<LocalSurfaceCleanupFailure> = []
        do { try await spotlight.removeAll() } catch { failures.insert(.spotlight) }
        do { try await notifications.clearAll() } catch { failures.insert(.notifications) }
        return failures
    }

    private func acquire() async throws -> Int32 {
        let url = directory.appendingPathComponent("SystemSurface.lock")
        return try await Task.detached {
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

extension CommandResult {
    func reporting(_ report: SurfaceReconciliationReport) -> CommandResult {
        guard let message = report.safeUserMessage else { return self }
        return .init(requestID: requestID, operationID: operationID, state: state,
                     safeUserMessage: safeUserMessage + " " + message, affectedTaskIDs: affectedTaskIDs)
    }
    var requiresSurfaceReconciliation: Bool {
        [.locallyCommitted, .alreadyApplied, .alreadyDecided, .committedProjectionPending].contains(state)
    }
}
