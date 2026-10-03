import Foundation
import Observation

/// 입력 presentation의 origin과 저장 뒤 동작은 생성 당시 값으로 고정한다.
public struct CapturePresentationRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ownerSceneID: UUID
    public let single: Bool
    public let contextID: UUID

    public init(ownerSceneID: UUID, single: Bool, contextID: UUID, id: UUID = UUID()) {
        self.id = id
        self.ownerSceneID = ownerSceneID
        self.single = single
        self.contextID = contextID
    }
}

/// 활성 입력은 하나만 유지하며, 다른 창과 오래된 닫기가 현재 요청을 바꾸지 못한다.
public struct CapturePresentationState: Equatable, Sendable {
    public private(set) var request: CapturePresentationRequest?

    public init() {}

    public func presentation(for ownerSceneID: UUID) -> CapturePresentationRequest? {
        guard request?.ownerSceneID == ownerSceneID else { return nil }
        return request
    }

    @discardableResult
    public mutating func open(ownerSceneID: UUID, single: Bool, contextID: UUID) -> Bool {
        if let request { return request.ownerSceneID == ownerSceneID }
        request = CapturePresentationRequest(ownerSceneID: ownerSceneID, single: single, contextID: contextID)
        return true
    }

    @discardableResult
    public mutating func close(presentationID: UUID, ownerSceneID: UUID) -> Bool {
        guard request?.id == presentationID, request?.ownerSceneID == ownerSceneID else { return false }
        request = nil
        return true
    }

    @discardableResult
    public mutating func finish(presentationID: UUID, ownerSceneID: UUID) -> Bool {
        guard request?.single == true else { return false }
        return close(presentationID: presentationID, ownerSceneID: ownerSceneID)
    }
}

/// scene가 직접 보유하는 수명이다. 요청과 coordinator는 이 객체를 retain하지 않는다.
@MainActor
public final class CaptureSceneOwner {
    public let id: UUID

    public init(id: UUID = UUID()) { self.id = id }
}

/// 원본 상태의 관측은 유지하고, 실제 owner가 해제된 요청만 다음 open에서 정리한다.
@Observable
@MainActor
public final class CapturePresentationCoordinator {
    private var state = CapturePresentationState()
    @ObservationIgnored private weak var owner: CaptureSceneOwner?

    public init() {}

    public var request: CapturePresentationRequest? {
        // owner가 nil이어도 state 읽기를 먼저 수행하여 nested Observation 경계를 유지한다.
        let request = state.request
        guard let owner, request?.ownerSceneID == owner.id else { return nil }
        return request
    }

    public func presentation(for ownerSceneID: UUID) -> CapturePresentationRequest? {
        let request = request
        guard request?.ownerSceneID == ownerSceneID else { return nil }
        return request
    }

    public func isCurrent(_ request: CapturePresentationRequest, contextID: UUID) -> Bool {
        guard let current = self.request else { return false }
        return current == request && request.contextID == contextID
    }

    @discardableResult
    public func open(owner newOwner: CaptureSceneOwner, single: Bool, contextID: UUID) -> Bool {
        if let stale = state.request, owner == nil {
            state.close(presentationID: stale.id, ownerSceneID: stale.ownerSceneID)
        }
        if let owner, owner !== newOwner { return false }
        guard state.open(ownerSceneID: newOwner.id, single: single, contextID: contextID) else { return false }
        owner = newOwner
        return true
    }

    @discardableResult
    public func close(presentationID: UUID, ownerSceneID: UUID) -> Bool {
        guard state.close(presentationID: presentationID, ownerSceneID: ownerSceneID) else { return false }
        owner = nil
        return true
    }

    @discardableResult
    public func finish(presentationID: UUID, ownerSceneID: UUID) -> Bool {
        guard state.finish(presentationID: presentationID, ownerSceneID: ownerSceneID) else { return false }
        owner = nil
        return true
    }
}

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
