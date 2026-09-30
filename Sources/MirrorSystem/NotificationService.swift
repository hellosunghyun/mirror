import Foundation
import UserNotifications

public enum NotificationServiceError: Error, Sendable { case permissionRequired }

public actor NotificationService {
    private let center: UNUserNotificationCenter
    public private(set) var omittedCount = 0

    public init(center: UNUserNotificationCenter = .current()) { self.center = center }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        #if os(iOS)
        case .ephemeral: return true
        #endif
        default: return false
        }
    }

    /// 이 기기의 앱 소유 예약만 조정한다. 다른 기기의 예약 취소를 보장하지 않는다.
    public func reconcile(plan: NotificationPlan) async throws {
        guard await isAuthorized() else { throw NotificationServiceError.permissionRequired }
        let pending = await center.pendingNotificationRequests()
        let desired = Set(plan.requests.map(\.identifier))
        let removed = pending.filter { isOwned($0.identifier) && !desired.contains($0.identifier) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: removed)
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { isOwned($0) && !desired.contains($0) })
        for item in plan.requests {
            let content = UNMutableNotificationContent()
            content.title = item.kind == .deadline ? "실제 마감을 확인하세요" : "잠깐 정리할까요?"
            content.body = item.kind == .weeklyReview ? "이번 주와 오늘에 남길 일을 정하세요." :
                item.kind == .dailyReview ? "오늘에 남길 일을 정하세요. 미검토는 오늘 할 일이 아니에요." : "미러에서 마감과 계획을 확인하세요."
            // 자유 입력을 알림 기본값에 넣지 않는다.
            content.sound = .default
            content.userInfo = ["route": MirrorDeepLink.url(for: item.taskID.map(MirrorRoute.task) ?? .review(weekly: item.kind == .weeklyReview)).absoluteString]
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.fireAt)
            components.timeZone = calendar.timeZone
            let request = UNNotificationRequest(identifier: item.identifier, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try await center.add(request)
        }
        omittedCount = plan.omittedCount
    }

    public func clearAll() async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter(isOwned))
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter(isOwned))
        omittedCount = 0
    }

    private func isOwned(_ identifier: String) -> Bool {
        identifier.hasPrefix("review:") || identifier.hasPrefix("deadline:")
    }
}
