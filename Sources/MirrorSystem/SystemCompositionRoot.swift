import Foundation
import MirrorDomain
import MirrorData

public enum SystemProcessRole: Sendable { case automatic, application, sharedExtension }

/// 각 프로세스에서 직접 초기화한다. 앱 화면의 실행이나 온보딩 singleton에 의존하지 않는다.
public enum SystemCompositionRoot {
    public static func open(role: SystemProcessRole = .automatic) async throws -> SystemServices {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "MirrorAppGroupIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let groupID = configured.flatMap { $0.isEmpty ? nil : $0 }
        let isExtension: Bool
        switch role {
        case .automatic: isExtension = Bundle.main.bundleURL.pathExtension == "appex"
        case .application: isExtension = false
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
            do { configuration = try .appGroup(identifier: groupID, deviceID: deviceID) }
            catch { throw SystemServiceError.configurationRequired }
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
            return SystemServices(store: store, directory: configuration.directory, workspaceEpoch: configuration.workspaceEpoch)
        }
        roots[key] = task
        do { return try await task.value }
        catch { roots[key] = nil; throw error }
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

    public init(store: MirrorStore, directory: URL, workspaceEpoch: String) {
        self.store = store; self.directory = directory; self.workspaceEpoch = workspaceEpoch
        calendar = CalendarService(); notifications = NotificationService(); spotlight = SpotlightService()
        metrics = LocalMetrics(directory: directory)
        widget = WidgetReviewService(store: store, directory: directory, workspaceEpoch: workspaceEpoch)
    }

    public func preferences() async throws -> SystemPreferences {
        guard let data = try await store.localValue(forKey: "system-preferences-v1") else { return .init() }
        return try JSONDecoder().decode(SystemPreferences.self, from: data)
    }

    public func savePreferences(_ preferences: SystemPreferences) async throws {
        guard TimeZone(identifier: preferences.planningTimeZoneID) != nil, !preferences.policyRevision.isEmpty else {
            throw SystemServiceError.invalidInput
        }
        try await store.setLocalValue(JSONEncoder().encode(preferences), forKey: "system-preferences-v1")
        if !preferences.spotlightEnabled || preferences.hideExternalTitles { try await spotlight.removeAll() }
        if !preferences.notificationsOnThisDevice { await notifications.clearAll() }
        await calendar.clearCache()
        WidgetReload.request()
    }

    public func currentContext(at date: Date = Date()) async throws -> PlanningContext {
        let snapshot = try await store.snapshot()
        return try .capture(at: date, timeZoneID: snapshot.policy.timeZoneID,
                            policyRevision: snapshot.policy.revision)
    }

    public func tasks() async throws -> [TaskProjection] { try await store.snapshot().tasks }

    public func task(_ id: UUID) async throws -> TaskProjection {
        guard let task = try await tasks().first(where: { $0.taskID == id }), task.status != .deleted,
              task.isProjectionComplete else { throw SystemServiceError.missingTask }
        return task
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
        let kind: LocalMetricKind = payload.kind == .capture ? .captureSaved : payload.kind == .undo ? .undoResult :
            [.locallyCommitted, .alreadyApplied, .committedProjectionPending].contains(result.state) ? .decisionCommitted : .decisionRejected
        // 진단 저장 실패가 이미 저장한 원본 명령의 성공을 실패로 바꾸지 않는다.
        try? await metrics.record(.init(kind: kind, at: current.capturedAt, surface: surface,
                                        outcome: outcome, processingMilliseconds: Int(milliseconds)))
        WidgetReload.request()
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
        let digest = try CanonicalDigest.hash([workspaceEpoch, key])
        let hex = Array(digest.prefix(32))
        let uuid = [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]), String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-")
        guard let id = UUID(uuidString: uuid) else { throw SystemServiceError.invalidInput }
        let result = try await execute(.capture(taskID: id, content: TaskContent(title: title, note: note, sourceURL: sourceURL)),
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
}
