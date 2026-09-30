import Foundation

/// URL은 화면 탐색만 표현한다. 이를 받는 것만으로 명령을 실행하지 않는다.
public enum MirrorRoute: Equatable, Sendable {
    case capture
    case today
    case review(weekly: Bool)
    case task(UUID)
    case schedule(taskID: UUID, sessionID: UUID?, cardID: UUID?)
}

public enum DeepLinkError: Error, Equatable, Sendable {
    case malformed, unknownRoute, foreignTask, untrustedCard
}

public enum MirrorDeepLink {
    public static let scheme = "mirror"

    public static func parse(_ url: URL) throws -> MirrorRoute {
        guard url.absoluteString.utf8.count <= 2_048,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == scheme,
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil, let host = parts.host else { throw DeepLinkError.malformed }
        let queries = parts.queryItems ?? []
        guard Set(queries.map(\.name)).count == queries.count else { throw DeepLinkError.malformed }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch host {
        case "capture":
            guard path.isEmpty, queries.isEmpty else { throw DeepLinkError.malformed }
            return .capture
        case "today":
            guard path.isEmpty, queries.isEmpty else { throw DeepLinkError.malformed }
            return .today
        case "review":
            guard path.isEmpty, queries.allSatisfy({ $0.name == "mode" }) else { throw DeepLinkError.malformed }
            let mode = queries.first?.value ?? "daily"
            guard ["daily", "weekly"].contains(mode) else { throw DeepLinkError.malformed }
            return .review(weekly: mode == "weekly")
        case "task":
            guard let first = path.first, let id = UUID(uuidString: first) else { throw DeepLinkError.malformed }
            if path.count == 1 {
                guard queries.isEmpty else { throw DeepLinkError.malformed }
                return .task(id)
            }
            guard path.count == 2, path[1] == "schedule",
                  queries.allSatisfy({ ["session", "card"].contains($0.name) }) else { throw DeepLinkError.malformed }
            func identifier(_ name: String) throws -> UUID? {
                guard let item = queries.first(where: { $0.name == name }) else { return nil }
                guard let value = item.value, let id = UUID(uuidString: value) else { throw DeepLinkError.malformed }
                return id
            }
            let session = try identifier("session"), card = try identifier("card")
            guard (session == nil) == (card == nil) else { throw DeepLinkError.malformed }
            return .schedule(taskID: id, sessionID: session, cardID: card)
        default: throw DeepLinkError.unknownRoute
        }
    }

    public static func validate(_ route: MirrorRoute, ownedTaskIDs: Set<UUID>,
                                trustedCards: [UUID: UUID] = [:]) throws -> MirrorRoute {
        switch route {
        case let .task(id):
            guard ownedTaskIDs.contains(id) else { throw DeepLinkError.foreignTask }
        case let .schedule(id, _, card):
            guard ownedTaskIDs.contains(id) else { throw DeepLinkError.foreignTask }
            // 외부 입력은 내부 카드 권한을 얻지 않는다. 가짜 참조는 안전한 상세 탐색으로 낮춘다.
            if let card, trustedCards[card] != id { return .task(id) }
        case .capture, .today, .review: break
        }
        return route
    }

    public static func url(for route: MirrorRoute) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        switch route {
        case .capture: parts.host = "capture"
        case .today: parts.host = "today"
        case let .review(weekly):
            parts.host = "review"; parts.queryItems = [.init(name: "mode", value: weekly ? "weekly" : "daily")]
        case let .task(id): parts.host = "task"; parts.path = "/\(id.uuidString)"
        case let .schedule(id, session, card):
            parts.host = "task"; parts.path = "/\(id.uuidString)/schedule"
            if let session, let card {
                parts.queryItems = [.init(name: "session", value: session.uuidString), .init(name: "card", value: card.uuidString)]
            }
        }
        // 위 구조에는 유효한 고정 스킴과 UUID만 들어간다.
        return parts.url!
    }
}
