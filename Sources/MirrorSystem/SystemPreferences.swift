import Foundation

public struct SystemPreferences: Equatable, Codable, Sendable {
    public var planningTimeZoneID: String
    public var policyRevision: String
    public var hideExternalTitles: Bool
    public var spotlightEnabled: Bool
    public var notificationsOnThisDevice: Bool
    public var selectedCalendarIDs: [String]
    public var reviewNotification: ReviewNotificationPreference
    public var deadlineNotifications: [DeadlineNotificationPreference]

    public init(planningTimeZoneID: String = "Asia/Seoul", policyRevision: String = "planning-v1",
                hideExternalTitles: Bool = true, spotlightEnabled: Bool = false,
                notificationsOnThisDevice: Bool = false, selectedCalendarIDs: [String] = [],
                reviewNotification: ReviewNotificationPreference = .init(),
                deadlineNotifications: [DeadlineNotificationPreference] = []) {
        self.planningTimeZoneID = planningTimeZoneID; self.policyRevision = policyRevision
        self.hideExternalTitles = hideExternalTitles; self.spotlightEnabled = spotlightEnabled
        self.notificationsOnThisDevice = notificationsOnThisDevice; self.selectedCalendarIDs = selectedCalendarIDs
        self.reviewNotification = reviewNotification; self.deadlineNotifications = deadlineNotifications
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

public enum LocalSurfaceCleanupFailure: String, Codable, Sendable { case spotlight, diagnostics }
public struct LocalSurfaceCleanupReport: Equatable, Sendable {
    public let failures: Set<LocalSurfaceCleanupFailure>
    /// 이미 그려진 OS snapshot은 reload 요청 이후 시스템이 갱신한다.
    public let widgetReloadRequested: Bool
}
