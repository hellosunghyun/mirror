import Foundation
import Observation
import MirrorDomain

/// 명시적 공간 변경만 제한한다. 저장 결과 재확인과 자동 계정 격리는 별도 경로다.
public enum WorkspaceChangeBlocker: Equatable, Sendable {
    case detailEditing, capture, projectionPending, saving

    public static func current(detailEditing: Bool, capture: Bool, projectionPending: Bool, saving: Bool) -> Self? {
        if detailEditing { return .detailEditing }
        if capture { return .capture }
        if projectionPending { return .projectionPending }
        if saving { return .saving }
        return nil
    }
}

/// 공유 단축키 차단은 활성 입력 owner들의 합집합으로 유지한다.
public struct TextEditingOwnershipState: Equatable, Sendable {
    private var activeOwnerIDs: Set<UUID> = []

    public init() {}

    public var isEditing: Bool { !activeOwnerIDs.isEmpty }

    public mutating func setEditing(_ active: Bool, ownerID: UUID) {
        if active { activeOwnerIDs.insert(ownerID) }
        else { activeOwnerIDs.remove(ownerID) }
    }
}

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

///  실패한 입력의 원문과 선택 날짜를 receipt 소비까지 그대로 비교한다.
public struct CaptureDraftSnapshot: Equatable, Sendable {
    public let title: String
    public let note: String
    public let sourceURL: String
    public let initialPlan: PlanTarget?
    public let planContext: PlanningContext?

    public init(title: String, note: String, sourceURL: String,
                initialPlan: PlanTarget? = nil, planContext: PlanningContext? = nil) {
        self.title = title
        self.note = note
        self.sourceURL = sourceURL
        self.initialPlan = initialPlan
        self.planContext = planContext
    }
}

public enum CaptureDraftCommitDisposition: Equatable, Sendable {
    case clearDraft, removeFirstLine, preserveDraft
}

/// 한 실패 입력만 보유한다. 자기 receipt는 초안 변경 여부와 관계없이 정확히 한 번 소비한다.
public struct CaptureDraftCommitState: Sendable {
    private var pending: (token: String, draft: CaptureDraftSnapshot, firstLine: String?)?

    public init() {}

    public mutating func register(token: String, draft: CaptureDraftSnapshot, firstLine: String? = nil) {
        pending = (token, draft, firstLine)
    }

    public func matchesWholeDraft(_ draft: CaptureDraftSnapshot) -> Bool {
        guard let pending else { return false }
        return pending.firstLine == nil && pending.draft == draft
    }

    public mutating func consume(token: String?, draft: CaptureDraftSnapshot) -> CaptureDraftCommitDisposition? {
        guard let token, let pending, pending.token == token else { return nil }
        self.pending = nil
        guard pending.draft == draft else { return .preserveDraft }
        if let firstLine = pending.firstLine {
            return draft.title.components(separatedBy: .newlines).first == firstLine
                ? .removeFirstLine : .preserveDraft
        }
        return .clearDraft
    }
}

/// 공유 확장의 비동기 읽기·저장 동안 입력과 종료를 같은 상태로 제한한다.
@MainActor @Observable
public final class ShareCaptureSession {
    private enum Phase { case loading, ready, saving, saved, cancelled }
    private var phase = Phase.loading
    private var loadStarted = false
    private var titleValue = ""
    private var noteValue = ""
    private var sourceURLValue = ""
    private var decisionKey = UUID().uuidString
    private var pendingDraft: CaptureDraftSnapshot?
    public private(set) var message: String?

    public init() {}

    public var isLoading: Bool { phase == .loading }
    public var isSaving: Bool { phase == .saving }
    public var didSave: Bool { phase == .saved }
    public var canEdit: Bool { phase == .ready }
    public var canSave: Bool { phase == .ready }
    public var canCancel: Bool { phase == .loading || phase == .ready }
    public var needsSaveConfirmation: Bool { pendingDraft != nil }

    public var title: String {
        get { titleValue }
        set { if canEdit { titleValue = newValue } }
    }
    public var note: String {
        get { noteValue }
        set { if canEdit { noteValue = newValue } }
    }
    public var sourceURL: String {
        get { sourceURLValue }
        set { if canEdit { sourceURLValue = newValue } }
    }

    public func load(using read: @MainActor () async throws -> (text: [String], links: [String])) async {
        guard phase == .loading, !loadStarted else { return }
        loadStarted = true
        do {
            let (text, links) = try await read()
            guard phase == .loading else { return }
            let raw = text.joined(separator: "\n")
            noteValue = ([raw] + links).filter { !$0.isEmpty }.joined(separator: "\n")
            // 긴 원문을 자동으로 잘라내지 않는다. 메모에 보존하고 제목을 사용자에게 받는다.
            titleValue = raw.count <= 500 ? raw : ""
            sourceURLValue = links.first ?? ""
            if raw.isEmpty { titleValue = sourceURLValue.count <= 500 ? sourceURLValue : "" }
            if text.isEmpty && links.isEmpty { message = "공유된 텍스트나 URL을 읽을 수 없어요." }
            if links.count > 1 { message = "여러 링크가 있어요. 저장할 링크 하나를 확인하세요. 원문을 자동으로 가져오지 않아요." }
        } catch {
            guard phase == .loading else { return }
            message = "공유한 텍스트나 URL을 읽을 수 없어요. 입력을 확인하세요."
        }
        phase = .ready
    }

    /// 실패한 제출부터 같은 키로 확인한다. 실패 뒤 수정한 초안은 다음 명시적 저장까지 유지한다.
    /// 반환값이 true일 때만 현재 초안까지 저장되었으므로 확장 요청을 완료한다.
    public func save(using capture: @MainActor (CaptureDraftSnapshot, String) async throws -> Void) async -> Bool {
        guard canSave else { return false }
        let draft = CaptureDraftSnapshot(title: title, note: note, sourceURL: sourceURL)
        let submission = pendingDraft ?? draft
        pendingDraft = submission
        phase = .saving
        message = nil
        do {
            try await capture(submission, decisionKey)
            pendingDraft = nil
            if submission != draft {
                decisionKey = UUID().uuidString
                phase = .ready
                message = "이전 입력을 저장했어요. 변경한 입력은 아직 저장하지 않았어요. 확인하고 저장하세요."
                return false
            }
            phase = .saved
            message = "저장했어요. 날짜는 아직 정하지 않았어요."
            return true
        } catch {
            // capture의 입력 검증은 명령 실행 전이다. 이 경우에는 잘못된 입력을 수정할 수 있다.
            if (error as? SystemServiceError) == .invalidInput { pendingDraft = nil }
            phase = .ready
            message = (error as? SystemServiceError)?.errorDescription ?? "저장하지 못했어요. 입력을 유지했으니 확인하고 다시 시도하세요."
            return false
        }
    }

    /// 원본 저장을 시작한 뒤에는 결과를 기다린다. 읽기 중 취소하면 늦은 결과를 버린다.
    public func cancel() -> Bool {
        guard canCancel else { return false }
        phase = .cancelled
        return true
    }
}
