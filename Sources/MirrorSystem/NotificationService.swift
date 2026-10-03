import Foundation
import UserNotifications
import MirrorDomain

public enum NotificationServiceError: Error, Equatable, Sendable { case permissionRequired, configurationRequired }

public actor NotificationService {
    private var center: UNUserNotificationCenter?
    public private(set) var omittedCount = 0

    public init(center: UNUserNotificationCenter? = nil) { self.center = center }

    /// 앱 init에서 저장소를 열기 전에 호출한다. cold-start tap도 현재 공간 확인 후 전달한다.
    @MainActor public static func bootstrapNavigation() {
        guard SystemAppleRuntimeHost.isApplicationOrExtension else { return }
        UNUserNotificationCenter.current().delegate = NotificationNavigationBridge.shared
    }

    public func installNavigationHandler(workspaceEpoch: String,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        onRoute: @escaping @MainActor @Sendable (MirrorRoute) -> Void) async throws {
        guard !workspaceEpoch.isEmpty else { throw NotificationServiceError.configurationRequired }
        let center = try resolvedCenter()
        center.delegate = NotificationNavigationBridge.shared
        try await NotificationNavigationBridge.shared.bindIfCurrent(
            workspaceEpoch: workspaceEpoch, isCurrent: isCurrent, onRoute: onRoute)
    }

    /// 계정/공간 교체를 시작할 때 호출한다. 이전 callback과 아직 전달하지 않은 tap은 폐기한다.
    @MainActor public static func suspendNavigation() { NotificationNavigationBridge.shared.suspend() }

    public func requestAuthorization() async throws -> Bool {
        let center = try resolvedCenter()
        return try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func isAuthorized() async throws -> Bool {
        let center = try resolvedCenter()
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
        let center = try resolvedCenter()
        let pending = await center.pendingNotificationRequests()
        let desired = Set(plan.requests.map(\.identifier))
        let removed = pending.filter { isOwned($0.identifier) && !desired.contains($0.identifier) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: removed)
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { isOwned($0) && !desired.contains($0) })
        if plan.requests.isEmpty { omittedCount = plan.omittedCount; return }
        guard try await isAuthorized() else { throw NotificationServiceError.permissionRequired }
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

    public func clearAll() async throws {
        let center = try resolvedCenter()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter(isOwned))
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter(isOwned))
        omittedCount = 0
    }

    private func resolvedCenter() throws -> UNUserNotificationCenter {
        guard SystemAppleRuntimeHost.isApplicationOrExtension else { throw NotificationServiceError.configurationRequired }
        if let center { return center }
        let resolved = UNUserNotificationCenter.current()
        center = resolved
        return resolved
    }

    private func isOwned(_ identifier: String) -> Bool {
        identifier.hasPrefix("review:") || identifier.hasPrefix("deadline:")
    }
}

/// native response의 객체나 userInfo를 actor 경계 너머로 전달하지 않는다.
struct NotificationNavigationEvent: Sendable {
    let actionIdentifier: String
    let requestIdentifier: String
    let routeURL: String?

    func route(workspaceEpoch: String) -> MirrorRoute? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier, !workspaceEpoch.isEmpty,
              let routeURL, let url = URL(string: routeURL),
              let route = try? MirrorDeepLink.parse(url) else { return nil }
        switch route {
        case .review:
            let prefix = "review:\(workspaceEpoch):"
            guard requestIdentifier.hasPrefix(prefix),
                  (try? LocalDate(String(requestIdentifier.dropFirst(prefix.count)))) != nil else { return nil }
        case let .task(id):
            guard requestIdentifier == "deadline:\(workspaceEpoch):\(id.uuidString)" else { return nil }
        default: return nil
        }
        return route
    }
}

/// UNUserNotificationCenter.delegate는 weak이다. singleton이 수명을 유지하고 mutable 상태는 lock으로 보호한다.
final class NotificationNavigationBridge: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationNavigationBridge()
    private struct Binding {
        let generation: UUID
        let workspaceEpoch: String
        let onRoute: @MainActor @Sendable (MirrorRoute) -> Void
    }
    private let lock = NSLock()
    private var binding: Binding?
    private var pending: NotificationNavigationEvent?
    private var buffersUnboundEvents = true

    /// 앱의 공간 전환과 같은 executor에서 확인과 설치를 수행해 늦은 actor 호출의 덮어쓰기를 막는다.
    @MainActor func bindIfCurrent(workspaceEpoch: String, isCurrent: @MainActor @Sendable () -> Bool,
        onRoute: @escaping @MainActor @Sendable (MirrorRoute) -> Void) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        bind(workspaceEpoch: workspaceEpoch, onRoute: onRoute)
    }

    @discardableResult
    func bind(workspaceEpoch: String, onRoute: @escaping @MainActor @Sendable (MirrorRoute) -> Void) -> UUID {
        let current = Binding(generation: UUID(), workspaceEpoch: workspaceEpoch, onRoute: onRoute)
        lock.lock()
        binding = current
        buffersUnboundEvents = false
        let event = pending
        pending = nil
        lock.unlock()
        if let event { schedule(event, generation: current.generation) }
        return current.generation
    }

    func suspend() {
        lock.lock()
        binding = nil
        pending = nil
        buffersUnboundEvents = false
        lock.unlock()
    }

    func receive(_ event: NotificationNavigationEvent) {
        // dismiss/custom action을 cold-start 버퍼에도 넣지 않는다.
        guard event.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        lock.lock()
        let generation = binding?.generation
        if generation == nil, buffersUnboundEvents { pending = event }
        lock.unlock()
        if let generation { schedule(event, generation: generation) }
    }

    private func schedule(_ event: NotificationNavigationEvent, generation: UUID) {
        Task { @MainActor [self] in deliver(event, generation: generation) }
    }

    @MainActor func deliver(_ event: NotificationNavigationEvent, generation: UUID) {
        lock.lock()
        let current = binding
        lock.unlock()
        guard let current, current.generation == generation,
              let route = event.route(workspaceEpoch: current.workspaceEpoch) else { return }
        current.onRoute(route)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        receive(.init(actionIdentifier: response.actionIdentifier,
                      requestIdentifier: response.notification.request.identifier,
                      routeURL: response.notification.request.content.userInfo["route"] as? String))
    }
}
