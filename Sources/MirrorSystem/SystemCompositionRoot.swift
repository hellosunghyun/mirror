import Foundation
import MirrorDomain
import MirrorData

public enum SystemProcessRole: Sendable { case automatic, application, sharedExtension }

enum SystemAppleRuntimeHost {
    static var isApplicationOrExtension: Bool {
        ["app", "appex"].contains(Bundle.main.bundleURL.pathExtension.lowercased())
    }
}

/// 각 프로세스에서 직접 초기화한다. 앱 화면의 실행이나 온보딩 singleton에 의존하지 않는다.
public enum SystemCompositionRoot {
    public static func open(role: SystemProcessRole = .automatic) async throws -> SystemServices {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "MirrorAppGroupIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = configured.flatMap { $0.isEmpty ? nil : $0 }
        let bundleIsExtension = Bundle.main.bundleURL.pathExtension == "appex"
        let isExtension: Bool
        switch role {
        case .automatic: isExtension = bundleIsExtension
        case .application: isExtension = bundleIsExtension
        case .sharedExtension: isExtension = true
        }
        let defaults: UserDefaults
        if let groupID {
            guard let shared = UserDefaults(suiteName: groupID) else { throw SystemServiceError.configurationRequired }
            defaults = shared
        } else { defaults = .standard }
        let key = "mirror.device-id.v1"
        let deviceID: String
        if let existing = defaults.string(forKey: key), UUID(uuidString: existing) != nil { deviceID = existing }
        else { deviceID = UUID().uuidString; defaults.set(deviceID, forKey: key) }
        let configuration: StoreConfiguration
        if let groupID {
            do {
                let identifier = (Bundle.main.object(forInfoDictionaryKey: "MirrorCloudContainerIdentifier") as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                configuration = try await CloudSyncService.resolveActiveConfiguration(appGroupIdentifier: groupID, deviceID: deviceID,
                    expectedContainerIdentifier: identifier.flatMap { $0.isEmpty ? nil : $0 }) ?? .appGroup(identifier: groupID, deviceID: deviceID)
            }
            catch CloudSyncServiceError.accountTransitionRequired { throw SystemServiceError.accountTransitionRequired }
            catch CloudSyncServiceError.accountUnavailable { throw SystemServiceError.accountTransitionRequired }
            catch {
                if StoreError.classify(error) == .protectedDataUnavailable { throw SystemServiceError.privacyLocked }
                throw SystemServiceError.configurationRequired
            }
        } else {
            guard !isExtension else { throw SystemServiceError.configurationRequired }
            // 공유 설정이 없는 본 앱만 사용하는 명시적 로컬 전용 경로다.
            configuration = try .localApplicationSupport(deviceID: deviceID)
        }
        return try await ProcessServicesRegistry.shared.open(configuration: configuration)
    }

    public static func open(configuration: StoreConfiguration) async throws -> SystemServices {
        try await ProcessServicesRegistry.shared.open(configuration: configuration)
    }

    /// 저장소 전환 후 이전 프로세스 composition root를 다시 제공하지 않는다.
    public static func invalidate(directory: URL? = nil) async {
        await ProcessServicesRegistry.shared.invalidate(directory: directory)
    }
}

private actor ProcessServicesRegistry {
    static let shared = ProcessServicesRegistry()
    private var roots: [String: Task<SystemServices, any Error>] = [:]
    func invalidate(directory: URL?) {
        if let directory { roots = roots.filter { !$0.key.hasPrefix(directory.path + ":") } }
        else { roots.removeAll() }
    }
    func open(configuration: StoreConfiguration) async throws -> SystemServices {
        let key = configuration.directory.path + ":" + configuration.workspaceEpoch + ":" +
            (configuration.cloudSync?.accountScope ?? "local") + ":" + (configuration.cloudSync?.containerIdentifier ?? "")
        if let task = roots[key] { return try await task.value }
        let task = Task {
            let store = try await MirrorStore(configuration: configuration)
            let services = SystemServices(store: store, directory: configuration.directory, workspaceEpoch: configuration.workspaceEpoch)
            if let sync = configuration.cloudSync {
                let group = (Bundle.main.object(forInfoDictionaryKey: "MirrorAppGroupIdentifier") as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let group, !group.isEmpty else { throw SystemServiceError.configurationRequired }
                let monitor = CloudSyncService(localConfiguration: configuration,
                    setup: .init(containerIdentifier: sync.containerIdentifier, appGroupIdentifier: group,
                                 workspaceEpoch: configuration.workspaceEpoch))
                try await monitor.resumeActiveStore(active: store)
                await services.attachCloudMonitor(monitor)
            }
            return services
        }
        roots[key] = task
        do { return try await task.value }
        catch {
            roots[key] = nil
            if StoreError.classify(error) == .protectedDataUnavailable { throw SystemServiceError.privacyLocked }
            throw error
        }
    }
}

/// projection만 복구한 사실은 사용자가 확인할 때까지 기기 설정과 함께 남긴다.
public struct ProjectionRecoveryNotice: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let recoveredAt: Date
    public init(recoveredAt: Date) { schemaVersion = 1; self.recoveredAt = recoveredAt }
}

/// Widget/Shortcuts/저장 후 갱신도 앱과 같은 복구 중 privacy 정책을 적용한다.
enum SystemPreferenceRecoveryPolicy {
    static let markerKey = "projection-recovery-v1"

    static func notice(store: MirrorStore) async throws -> ProjectionRecoveryNotice? {
        guard let data = try await store.localValue(forKey: markerKey) else { return nil }
        let notice = try JSONDecoder().decode(ProjectionRecoveryNotice.self, from: data)
        guard notice.schemaVersion == 1, notice.recoveredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SystemServiceError.unavailable
        }
        return notice
    }

    static func failClosed(_ preferences: SystemPreferences) -> SystemPreferences {
        var safe = preferences
        safe.hideExternalTitles = true; safe.spotlightEnabled = false; safe.notificationsOnThisDevice = false
        safe.selectedCalendarIDs = []; safe.reviewNotification.enabled = false; safe.deadlineNotifications = []
        return safe
    }

    static func load(store: MirrorStore) async throws -> SystemPreferences {
        let recoveryPending = try await store.localValue(forKey: markerKey) != nil
        let preferences: SystemPreferences
        if let data = try await store.localValue(forKey: "system-preferences-v1") {
            preferences = try JSONDecoder().decode(SystemPreferences.self, from: data)
        } else { preferences = .init() }
        // 손상/미지원 marker도 외부 노출을 허용하지 않는다.
        return recoveryPending ? failClosed(preferences) : preferences
    }
}

public actor SystemServices {
    public let store: MirrorStore
    public let directory: URL
    public let workspaceEpoch: String
    public let calendar: CalendarService
    public let notifications: NotificationService
    public let spotlight: SpotlightService
    public let metrics: LocalMetrics
    public let widget: WidgetReviewService
    public let surfaces: SurfaceReconciler
    public private(set) var lastSurfaceReport: SurfaceReconciliationReport?
    private var cloudMonitor: CloudSyncService?

    public init(store: MirrorStore, directory: URL, workspaceEpoch: String) {
        self.store = store; self.directory = directory; self.workspaceEpoch = workspaceEpoch
        calendar = CalendarService()
        let notificationService = NotificationService(), spotlightService = SpotlightService()
        notifications = notificationService; spotlight = spotlightService
        metrics = LocalMetrics(directory: directory)
        let reconciler = SurfaceReconciler(store: store, directory: directory,
                                          notifications: notificationService, spotlight: spotlightService)
        surfaces = reconciler
        widget = WidgetReviewService(store: store, directory: directory, workspaceEpoch: workspaceEpoch, surfaces: reconciler)
    }

    public func attachCloudMonitor(_ monitor: CloudSyncService) { cloudMonitor = monitor }

    @discardableResult
    public func reconcileExternalSurfaces(at now: Date = Date()) async -> SurfaceReconciliationReport {
        let report = await surfaces.reconcile(at: now)
        lastSurfaceReport = report
        return report
    }

    public func preferences() async throws -> SystemPreferences {
        do {
            return try await SystemPreferenceRecoveryPolicy.load(store: store)
        } catch {
            if StoreError.classify(error) == .protectedDataUnavailable { throw SystemServiceError.privacyLocked }
            throw SystemServiceError.unavailable
        }
    }

    public func projectionRecoveryNotice() async throws -> ProjectionRecoveryNotice? {
        do { return try await SystemPreferenceRecoveryPolicy.notice(store: store) }
        catch {
            if StoreError.classify(error) == .protectedDataUnavailable { throw SystemServiceError.privacyLocked }
            throw SystemServiceError.unavailable
        }
    }

    /// 복구 안내를 확인한 명시 동작에만 연결한다. 기본 설정 저장으로 marker를 지우지 않는다.
    /// 외부 노출은 여기서 켜지지 않으며 이후 설정 화면에서 각각 다시 동의해야 한다.
    public func acknowledgeProjectionRecovery(_ notice: ProjectionRecoveryNotice) async throws {
        guard let current = try await projectionRecoveryNotice(), current == notice else { throw SystemServiceError.invalidInput }
        let safe = SystemPreferenceRecoveryPolicy.failClosed(try await preferences())
        try await store.setLocalValue(JSONEncoder().encode(safe), forKey: "system-preferences-v1")
        try await store.setLocalValue(nil, forKey: SystemPreferenceRecoveryPolicy.markerKey)
        WidgetReload.request()
    }

    public func savePreferences(_ preferences: SystemPreferences) async throws {
        guard TimeZone(identifier: preferences.planningTimeZoneID) != nil, !preferences.policyRevision.isEmpty else {
            throw SystemServiceError.invalidInput
        }
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
        await calendar.clearCache()
        WidgetReload.request()
        if let cleanupError { throw cleanupError }
    }

    /// 로컬 원본 삭제/공간 교체 후 호출한다. 실패한 후처리를 숨기지 않으며 모든 표면에 시도한다.
    public func eraseLocalSurfaceData() async -> LocalSurfaceCleanupReport {
        var failures: Set<LocalSurfaceCleanupFailure> = []
        do { try await spotlight.removeAll() } catch { failures.insert(.spotlight) }
        do { try await notifications.clearAll() } catch { failures.insert(.notifications) }
        await calendar.clearCache()
        do { try await metrics.erase() } catch { failures.insert(.diagnostics) }
        await SystemCompositionRoot.invalidate(directory: directory)
        WidgetReload.request()
        return .init(failures: failures, widgetReloadRequested: true)
    }

    public func currentContext(at date: Date = Date()) async throws -> PlanningContext {
        do {
            try await validateBoundary()
            return try await store.currentContext(at: date)
        }
        catch {
            if StoreError.classify(error) == .protectedDataUnavailable { throw SystemServiceError.privacyLocked }
            throw error
        }
    }

    public func tasks() async throws -> [TaskProjection] {
        do {
            try await validateBoundary()
            return try await store.snapshot().tasks
        }
        catch {
            if StoreError.classify(error) == .protectedDataUnavailable { throw SystemServiceError.privacyLocked }
            throw error
        }
    }

    public func task(_ id: UUID) async throws -> TaskProjection {
        guard let task = try await tasks().first(where: { $0.taskID == id }), task.status != .deleted,
              task.isProjectionComplete else { throw SystemServiceError.missingTask }
        return task
    }

    public func todayTasks(on date: LocalDate? = nil, at now: Date = Date()) async throws -> [TaskProjection] {
        do {
            try await validateBoundary()
            let snapshot = try await store.snapshot()
            let context = try PlanningContext.capture(at: now, timeZoneID: snapshot.policy.timeZoneID,
                                                     policyRevision: snapshot.policy.revision)
            let report = TaskReducer.reduce(snapshot.records, workspaceKey: snapshot.workspaceKey, workspaceEpoch: snapshot.workspaceEpoch)
            return TodayTaskOrdering.sorted(snapshot.tasks.filter {
                $0.isProjectionComplete && PlanningRules.isToday($0.planningState, on: date ?? context.planningDay)
            }, records: snapshot.records, appliedIDs: report.appliedOperationIDs)
        } catch {
            if StoreError.classify(error) == .protectedDataUnavailable { throw SystemServiceError.privacyLocked }
            throw error
        }
    }

    public func execute(_ payload: CommandPayload, source: CommandSource, key: String = UUID().uuidString,
                        displayedContext: PlanningContext? = nil) async throws -> CommandResult {
        let current = try await currentContext()
        let envelope = CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: key, source: source,
                                       context: displayedContext ?? current, workspaceEpoch: workspaceEpoch, payload: payload)
        let start = ContinuousClock.now
        let result = await store.execute(envelope, context: current)
        let elapsed = start.duration(to: .now).components
        let milliseconds = min(Int64(Int.max), max(0, elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000))
        let outcome: MetricOutcome
        switch result.state {
        case .locallyCommitted, .alreadyApplied: outcome = .success
        case .committedProjectionPending: outcome = .projectionPending
        case .staleSnapshot, .staleContext, .alreadyDecided: outcome = .stale
        case .requiresConfirmation: outcome = .confirmation
        case .unavailable, .notFound: outcome = .unavailable
        case .persistenceFailed: outcome = .failure
        }
        let surface = MetricSurface(rawValue: source.rawValue) ?? .app
        let committed = [.locallyCommitted, .alreadyApplied, .committedProjectionPending].contains(result.state)
        let kind: LocalMetricKind = payload.kind == .capture ? (committed ? .captureSaved : .captureRejected) : payload.kind == .undo ? .undoResult :
            [.locallyCommitted, .alreadyApplied, .committedProjectionPending].contains(result.state) ? .decisionCommitted : .decisionRejected
        // 진단 저장 실패가 이미 저장한 원본 명령의 성공을 실패로 바꾸지 않는다.
        if payload.kind != .capture || ![.alreadyApplied, .alreadyDecided].contains(result.state) {
            try? await metrics.record(.init(kind: kind, at: current.capturedAt, surface: surface,
                                            outcome: outcome, processingMilliseconds: Int(milliseconds)))
        }
        WidgetReload.request()
        if result.requiresSurfaceReconciliation {
            return result.reporting(await reconcileExternalSurfaces(at: current.capturedAt))
        }
        return result
    }

    public func requireCommitted(_ result: CommandResult) throws {
        guard [.locallyCommitted, .alreadyApplied].contains(result.state) else {
            // 원본 저장 후 projection 대기는 저장 성공과 화면 성공을 분리해서 호출자에게 전달한다.
            throw SystemServiceError.commandRejected(result.safeUserMessage)
        }
    }

    public func capture(title: String, note: String? = nil, sourceURL: String? = nil,
                        source: CommandSource, key: String = UUID().uuidString) async throws -> TaskProjection {
        let surface = MetricSurface(rawValue: source.rawValue) ?? .app
        try? await metrics.record(.init(kind: .captureAttempt, at: Date(), surface: surface))
        let content: TaskContent
        do { content = try TaskContent(title: title, note: note, sourceURL: sourceURL) }
        catch {
            try? await metrics.record(.init(kind: .captureRejected, at: Date(), surface: surface, outcome: .failure))
            throw SystemServiceError.invalidInput
        }
        let digest = try CanonicalDigest.hash([workspaceEpoch, key])
        let hex = Array(digest.prefix(32))
        let uuid = [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]), String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-")
        guard let id = UUID(uuidString: uuid) else { throw SystemServiceError.invalidInput }
        let result = try await execute(.capture(taskID: id, content: content),
                                       source: source, key: key)
        try requireCommitted(result)
        guard let actualID = result.affectedTaskIDs.first else { throw SystemServiceError.unavailable }
        return try await task(actualID)
    }

    public func schedule(id: UUID, target: PlanTarget, source: CommandSource) async throws -> CommandResult {
        let task = try await task(id)
        return try await execute(.setPlan(item: .init(taskID: id, expected: .init(task)), target: target, review: nil), source: source)
    }

    public func setCompleted(id: UUID, completed: Bool, source: CommandSource) async throws -> CommandResult {
        let task = try await task(id)
        guard let status = task.versions[.status]?.headsDigest else { throw SystemServiceError.unavailable }
        return try await execute(.completion(taskID: id, desiredCompleted: completed, expectedStatus: status), source: source)
    }

    private func validateBoundary() async throws {
        if let cloudMonitor {
            guard await cloudMonitor.validateLocalIdentity() else { throw SystemServiceError.accountTransitionRequired }
        } else { try await SystemStoreBoundary.validate(store) }
    }
}

enum SystemStoreBoundary {
    static func validate(_ store: MirrorStore) async throws {
        let configuration = await store.configuration
        guard let sync = configuration.cloudSync else { return }
        let group = (Bundle.main.object(forInfoDictionaryKey: "MirrorAppGroupIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let group, !group.isEmpty else { throw SystemServiceError.configurationRequired }
        do {
            guard let current = try await CloudSyncService.resolveActiveConfiguration(appGroupIdentifier: group,
                deviceID: configuration.deviceID, expectedContainerIdentifier: sync.containerIdentifier),
                  current.cloudSync?.accountScope == sync.accountScope,
                  current.workspaceEpoch == configuration.workspaceEpoch,
                  current.directory.standardizedFileURL == configuration.directory.standardizedFileURL else {
                throw SystemServiceError.accountTransitionRequired
            }
        } catch {
            try? await store.suspend()
            if StoreError.classify(error) == .protectedDataUnavailable { throw SystemServiceError.privacyLocked }
            throw SystemServiceError.accountTransitionRequired
        }
    }
}
