import Foundation
import MirrorData

public struct SystemPreferences: Equatable, Codable, Sendable {
    public var planningTimeZoneID: String
    public var policyRevision: String
    public var hideExternalTitles: Bool
    public var spotlightEnabled: Bool
    public var notificationsOnThisDevice: Bool
    public var selectedCalendarIDs: [String]
    public var reviewNotification: ReviewNotificationPreference
    public var deadlineNotificationsEnabled: Bool
    public var deadlineNotifications: [DeadlineNotificationPreference]

    public init(planningTimeZoneID: String = "Asia/Seoul", policyRevision: String = "planning-v1",
                hideExternalTitles: Bool = true, spotlightEnabled: Bool = false,
                notificationsOnThisDevice: Bool = false, selectedCalendarIDs: [String] = [],
                reviewNotification: ReviewNotificationPreference = .init(),
                deadlineNotificationsEnabled: Bool? = nil,
                deadlineNotifications: [DeadlineNotificationPreference] = []) {
        self.planningTimeZoneID = planningTimeZoneID; self.policyRevision = policyRevision
        self.hideExternalTitles = hideExternalTitles; self.spotlightEnabled = spotlightEnabled
        self.notificationsOnThisDevice = notificationsOnThisDevice; self.selectedCalendarIDs = selectedCalendarIDs
        self.reviewNotification = reviewNotification; self.deadlineNotifications = deadlineNotifications
        self.deadlineNotificationsEnabled = deadlineNotificationsEnabled ?? (notificationsOnThisDevice && !deadlineNotifications.isEmpty)
    }

    private enum CodingKeys: String, CodingKey {
        case planningTimeZoneID, policyRevision, hideExternalTitles, spotlightEnabled, notificationsOnThisDevice
        case selectedCalendarIDs, reviewNotification, deadlineNotificationsEnabled, deadlineNotifications
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        planningTimeZoneID = try values.decode(String.self, forKey: .planningTimeZoneID)
        policyRevision = try values.decode(String.self, forKey: .policyRevision)
        hideExternalTitles = try values.decode(Bool.self, forKey: .hideExternalTitles)
        spotlightEnabled = try values.decode(Bool.self, forKey: .spotlightEnabled)
        notificationsOnThisDevice = try values.decode(Bool.self, forKey: .notificationsOnThisDevice)
        selectedCalendarIDs = try values.decode([String].self, forKey: .selectedCalendarIDs)
        reviewNotification = try values.decode(ReviewNotificationPreference.self, forKey: .reviewNotification)
        deadlineNotifications = try values.decode([DeadlineNotificationPreference].self, forKey: .deadlineNotifications)
        // 이전 형식은 실행할 알림만 저장했다. 기존 동작을 유지하며 새 형식부터 선택과 허용을 분리한다.
        deadlineNotificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .deadlineNotificationsEnabled)
            ?? (notificationsOnThisDevice && !deadlineNotifications.isEmpty)
    }
}

/// OS 갱신을 마치지 못한 사용자 선택은 해당 저장소에만 다시 적용한다.
public struct PendingSystemPreferenceUpdate: Equatable, Codable, Sendable {
    public let id: UUID
    public let preferences: SystemPreferences
    private let directoryPath: String
    private let workspaceKey: String
    private let workspaceEpoch: String
    private let cloudContainer: String?
    private let cloudAccount: String?

    init(preferences: SystemPreferences, configuration: StoreConfiguration) {
        id = UUID(); self.preferences = preferences
        directoryPath = configuration.directory.standardizedFileURL.path
        workspaceKey = configuration.workspaceKey; workspaceEpoch = configuration.workspaceEpoch
        cloudContainer = configuration.cloudSync?.containerIdentifier
        cloudAccount = configuration.cloudSync?.accountScope
    }

    public func belongs(to configuration: StoreConfiguration) -> Bool {
        directoryPath == configuration.directory.standardizedFileURL.path && workspaceKey == configuration.workspaceKey
            && workspaceEpoch == configuration.workspaceEpoch && cloudContainer == configuration.cloudSync?.containerIdentifier
            && cloudAccount == configuration.cloudSync?.accountScope
    }
}

/// canonical gate가 busy여도 앱 재시작 뒤 동의 철회가 사라지지 않도록 기기 설정에 먼저 남긴다.
@MainActor
public final class SystemPreferenceUpdateJournal {
    private let defaults: UserDefaults
    private let key = "Mirror.system-preferences.pending.v1"

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func pending(for configuration: StoreConfiguration) throws -> PendingSystemPreferenceUpdate? {
        try updates().last { $0.belongs(to: configuration) }
    }

    @discardableResult
    public func record(_ preferences: SystemPreferences, for configuration: StoreConfiguration) throws -> PendingSystemPreferenceUpdate {
        var pending = try updates().filter { !$0.belongs(to: configuration) }
        let update = PendingSystemPreferenceUpdate(preferences: preferences, configuration: configuration)
        pending.append(update)
        try write(pending)
        return update
    }

    /// 이전 적용이 끝나는 동안 사용자가 다시 변경한 선택은 지우지 않는다.
    public func acknowledge(_ update: PendingSystemPreferenceUpdate, after report: SurfaceReconciliationReport) throws {
        guard report.failures.isEmpty else { return }
        try write(updates().filter { $0.id != update.id })
    }

    /// 실제 기기 원본 삭제가 성공한 공간에만 사용한다.
    public func discard(for configuration: StoreConfiguration) throws {
        try write(updates().filter { !$0.belongs(to: configuration) })
    }

    private func updates() throws -> [PendingSystemPreferenceUpdate] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([PendingSystemPreferenceUpdate].self, from: data)
    }

    private func write(_ updates: [PendingSystemPreferenceUpdate]) throws {
        if updates.isEmpty { defaults.removeObject(forKey: key) }
        else { defaults.set(try JSONEncoder().encode(updates), forKey: key) }
    }
}

public enum SystemServiceError: Error, Equatable, Sendable, LocalizedError {
    case configurationRequired, privacyLocked, externalSearchDisabled, accountTransitionRequired
    case unavailable, missingTask, staleCard, invalidInput, commandRejected(String)
    public var errorDescription: String? {
        switch self {
        case .configurationRequired: "앱과 확장의 공유 저장소 설정이 필요해요."
        case .privacyLocked: "보호된 데이터를 읽으려면 기기의 잠금을 해제하고 미러를 여세요."
        case .externalSearchDisabled: "외부 제목 검색이 꺼져 있어요. 미러에서 검색하거나 기존 작업을 선택하세요."
        case .accountTransitionRequired: "iCloud 계정과 개인 공간을 확인해야 해요. 이전 공간의 쓰기를 멈추고 미러에서 확인하세요."
        case .unavailable: "지금 데이터를 읽을 수 없어요. 잠시 뒤 다시 시도하세요."
        case .missingTask: "이 공간에서 작업을 찾을 수 없어요."
        case .staleCard: "작업이나 날짜가 바뀌었어요. 새 카드를 확인하세요."
        case .invalidInput: "입력 형식이나 날짜를 확인하세요."
        case let .commandRejected(message): message
        }
    }
}

public enum LocalSurfaceCleanupFailure: String, Codable, Sendable { case spotlight, notifications, diagnostics }
public struct LocalSurfaceCleanupReport: Equatable, Sendable {
    public let failures: Set<LocalSurfaceCleanupFailure>
    /// 이미 그려진 OS snapshot은 reload 요청 이후 시스템이 갱신한다.
    public let widgetReloadRequested: Bool
}
