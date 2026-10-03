import Foundation

public enum CommandSource: String, Hashable, Codable, Sendable { case app, widget, shortcut, siri, spotlight, share, `import` }
public enum CommandKind: String, Hashable, Codable, Sendable {
    case capture, setPlan, setStatus, setDeadline, editContent, park, trash, restore, undo, reviewClose, batchSetPlan, settings
}
public struct ExpectedVersions: Hashable, Codable, Sendable {
    public let content: String?; public let plan: String?; public let status: String?; public let deadline: String?
    public init(content: String? = nil, plan: String? = nil, status: String? = nil, deadline: String? = nil) {
        self.content = content; self.plan = plan; self.status = status; self.deadline = deadline
    }
    public init(_ task: TaskProjection) {
        self.init(content: task.versions[.content]?.headsDigest, plan: task.versions[.plan]?.headsDigest,
                  status: task.versions[.status]?.headsDigest, deadline: task.versions[.deadline]?.headsDigest)
    }
    public subscript(_ group: MutationGroup) -> String? {
        switch group { case .content: content; case .plan: plan; case .status: status; case .deadline: deadline }
    }
}
public struct PlanCommandItem: Hashable, Codable, Sendable {
    public let taskID: UUID; public let expected: ExpectedVersions; public let acknowledgment: DeadlineAcknowledgment?
    public init(taskID: UUID, expected: ExpectedVersions, acknowledgment: DeadlineAcknowledgment? = nil) {
        self.taskID = taskID; self.expected = expected; self.acknowledgment = acknowledgment
    }
}
public struct TaskVersionExpectation: Hashable, Codable, Sendable {
    public let taskID: UUID; public let group: MutationGroup; public let headsDigest: String
    public init(taskID: UUID, group: MutationGroup, headsDigest: String) {
        self.taskID = taskID; self.group = group; self.headsDigest = headsDigest
    }
}
public struct ReviewDecisionContext: Hashable, Codable, Sendable {
    public let cycleID: String; public let sessionID: String; public let cardID: String
    public let taskID: UUID
    public init(cycleID: String, sessionID: String, cardID: String, taskID: UUID) {
        self.cycleID = cycleID; self.sessionID = sessionID; self.cardID = cardID; self.taskID = taskID
    }
}
public struct ReviewClosure: Hashable, Codable, Sendable {
    public let cycleID: String; public let sessionID: String; public let weeklyCoverageStartDate: LocalDate?
    public init(cycleID: String, sessionID: String, weeklyCoverageStartDate: LocalDate? = nil) {
        self.cycleID = cycleID; self.sessionID = sessionID; self.weeklyCoverageStartDate = weeklyCoverageStartDate
    }
}
public struct PlanningPolicy: Hashable, Codable, Sendable {
    public let timeZoneID: String; public let revision: String
    public init(timeZoneID: String, revision: String) throws {
        guard TimeZone(identifier: timeZoneID) != nil, !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DomainContractError.invalidCommand }
        self.timeZoneID = timeZoneID; self.revision = revision
    }
}
public enum CommandPayload: Hashable, Codable, Sendable {
    case capture(taskID: UUID, content: TaskContent)
    // 기존 capture의 논리 digest를 보존하면서 명시적 날짜를 한 원본에 저장한다.
    case captureWithPlan(taskID: UUID, content: TaskContent, initialPlan: PlanTarget)
    case setPlan(item: PlanCommandItem, target: PlanTarget, review: ReviewDecisionContext?)
    case completion(taskID: UUID, desiredCompleted: Bool, expectedStatus: String)
    case setDeadline(taskID: UUID, deadline: Deadline?, expectedDeadline: String)
    case editContent(taskID: UUID, content: TaskContent, expectedContent: String)
    case park(taskID: UUID, expected: ExpectedVersions)
    case trash(taskID: UUID, expectedStatus: String)
    case restore(taskID: UUID, observedDeleteHeadIDs: [String], expectedStatus: String)
    case undo(operationID: String, expected: [TaskVersionExpectation])
    case reviewClose(ReviewClosure)
    case batchSetPlan(items: [PlanCommandItem], target: PlanTarget)
    case settings(policy: PlanningPolicy, expectedRevision: String)
    public var kind: CommandKind {
        switch self {
        case .capture, .captureWithPlan: .capture; case .setPlan: .setPlan; case .completion: .setStatus
        case .setDeadline: .setDeadline; case .editContent: .editContent; case .park: .park
        case .trash: .trash; case .restore: .restore; case .undo: .undo
        case .reviewClose: .reviewClose; case .batchSetPlan: .batchSetPlan; case .settings: .settings
        }
    }
}
public struct CommandEnvelope: Hashable, Codable, Sendable {
    public let contractVersion: Int
    public let requestID: String; public let idempotencyKey: String; public let source: CommandSource
    public let context: PlanningContext; public let workspaceEpoch: String; public let payload: CommandPayload
    public var kind: CommandKind { payload.kind }
    public init(contractVersion: Int = 1, requestID: String, idempotencyKey: String, source: CommandSource,
                context: PlanningContext, workspaceEpoch: String, payload: CommandPayload) {
        self.contractVersion = contractVersion; self.requestID = requestID; self.idempotencyKey = idempotencyKey
        self.source = source; self.context = context; self.workspaceEpoch = workspaceEpoch; self.payload = payload
    }
    public init(from decoder: any Decoder) throws { self = try CommandJSON.decode(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try CommandJSON.encode(self, to: encoder) }
    /// 재호출 ID·출처·시각·표시 기준은 사용자 결정의 내용과 구분한다.
    public func logicalDigest() throws -> String { try CanonicalDigest.hash(payload) }
}
public enum CommandResultState: String, Hashable, Codable, Sendable {
    case locallyCommitted, alreadyApplied, requiresConfirmation, staleSnapshot, staleContext, alreadyDecided
    case notFound, unavailable, persistenceFailed, committedProjectionPending
}
public struct CommandResult: Hashable, Codable, Sendable {
    public let requestID: String; public let operationID: String?; public let state: CommandResultState
    public let safeUserMessage: String; public let affectedTaskIDs: [UUID]
    public init(requestID: String, operationID: String? = nil, state: CommandResultState,
                safeUserMessage: String, affectedTaskIDs: [UUID] = []) {
        self.requestID = requestID; self.operationID = operationID; self.state = state
        self.safeUserMessage = safeUserMessage; self.affectedTaskIDs = affectedTaskIDs
    }
    public func retry(requestID: String, state: CommandResultState = .alreadyApplied) -> Self {
        Self(requestID: requestID, operationID: operationID, state: state,
             safeUserMessage: safeUserMessage, affectedTaskIDs: affectedTaskIDs)
    }
}
public struct CommandReceipt: Hashable, Codable, Sendable {
    public let workspaceEpoch: String; public let key: String; public let digest: String
    public let operationID: String; public let result: CommandResult
    public init(workspaceEpoch: String, key: String, digest: String, operationID: String, result: CommandResult) {
        self.workspaceEpoch = workspaceEpoch; self.key = key; self.digest = digest
        self.operationID = operationID; self.result = result
    }
}
public struct CommandRejection: Hashable, Sendable {
    public let state: CommandResultState; public let message: String; public let taskIDs: [UUID]
    public init(state: CommandResultState, message: String, taskIDs: [UUID] = []) {
        self.state = state; self.message = message; self.taskIDs = taskIDs
    }
}
public struct PreparedCommand: Sendable {
    public let operation: OperationRecord; public let affectedTaskIDs: [UUID]
    public let logicalDigest: String
    public init(operation: OperationRecord, affectedTaskIDs: [UUID], logicalDigest: String) {
        self.operation = operation; self.affectedTaskIDs = affectedTaskIDs; self.logicalDigest = logicalDigest
    }
}
public enum CommandPreparation: Sendable {
    case prepared(PreparedCommand)
    case alreadyApplied(CommandReceipt)
    case alreadyDecided(CommandReceipt)
    case rejected(CommandRejection)
}
public struct CommandSnapshot: Sendable {
    public let workspaceKey: String; public let workspaceEpoch: String; public let deviceID: UUID
    public let currentContext: PlanningContext; public let recordedAt: Date; public let observedLamport: Int64
    public let tasks: [UUID: TaskProjection]; public let records: [OperationRecord]; public let receipts: [CommandReceipt]
    public init(workspaceKey: String, workspaceEpoch: String, deviceID: UUID, currentContext: PlanningContext,
                recordedAt: Date, tasks: [UUID: TaskProjection], records: [OperationRecord], receipts: [CommandReceipt] = [],
                observedLamport: Int64 = 0) {
        self.workspaceKey = workspaceKey; self.workspaceEpoch = workspaceEpoch; self.deviceID = deviceID
        self.currentContext = currentContext; self.recordedAt = recordedAt; self.observedLamport = observedLamport; self.tasks = tasks
        self.records = records; self.receipts = receipts
    }
}
public enum ReviewCycle {
    public static func id(workspaceEpoch: String, context: PlanningContext) -> String {
        struct Key: Encodable { let epoch: String; let revision: String; let day: LocalDate }
        return (try? CanonicalDigest.hash(Key(epoch: workspaceEpoch, revision: context.policyRevision,
                                             day: context.planningDay))) ?? "invalid-cycle"
    }
}

/// 보존한 command-envelope v1 봉투를 사용한다. Swift enum의 합성 JSON 형식은 외부 계약에 노출하지 않는다.
private enum CommandJSON {
    private enum Key: String, CodingKey {
        case contractVersion, requestID, idempotencyKey, kind, source, context, taskID, expectedVersions, payload, workspaceEpoch
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private struct Context: Codable {
        let planningDay: LocalDate; let timeZoneID: String; let policyRevision: String
    }
    private struct Plan: Codable {
        let target: PlanTarget; let acknowledgment: DeadlineAcknowledgment?; let review: ReviewDecisionContext?
    }
    private struct PlannedCapture: Codable {
        let title: String; let note: String?; let sourceURL: String?; let initialPlan: PlanTarget?
    }
    private struct Completion: Codable { let desiredCompleted: Bool }
    private struct Restore: Codable { let observedDeleteHeadIDs: [String] }
    private struct Undo: Codable { let operationID: String; let expected: [TaskVersionExpectation] }
    private struct Batch: Codable { let items: [PlanCommandItem]; let target: PlanTarget }
    private struct Settings: Codable { let policy: PlanningPolicy; let expectedRevision: String }
    private struct Empty: Codable {}
    private struct DeadlinePayload: Codable {
        let deadline: Deadline?
        private enum CodingKeys: String, CodingKey { case deadline }
        init(deadline: Deadline?) { self.deadline = deadline }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard c.contains(.deadline) else { throw DomainContractError.invalidCommand }
            deadline = try c.decodeIfPresent(Deadline.self, forKey: .deadline)
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let deadline { try c.encode(deadline, forKey: .deadline) }
            else { try c.encodeNil(forKey: .deadline) }
        }
    }
    private static func checkKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard Set(c.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw DomainContractError.invalidCommand }
    }
    private static func payload<T: Decodable>(_ type: T.Type, _ decoder: any Decoder,
                                               allowed: Set<String>) throws -> T {
        try checkKeys(decoder, allowed: allowed)
        return try T(from: decoder)
    }
    static func decode(from decoder: any Decoder) throws -> CommandEnvelope {
        try checkKeys(decoder, allowed: ["contractVersion", "requestID", "idempotencyKey", "kind", "source", "context",
                                        "taskID", "expectedVersions", "payload", "workspaceEpoch"])
        let c = try decoder.container(keyedBy: Key.self)
        guard try c.decode(Int.self, forKey: .contractVersion) == 1 else { throw DomainContractError.invalidCommand }
        let contextDecoder = try c.superDecoder(forKey: .context)
        let context = try payload(Context.self, contextDecoder, allowed: ["planningDay", "timeZoneID", "policyRevision"])
        // 봉투의 context에는 표시 시각이 없다. 내부의 주입 시각을 시스템 현재 시각으로 대체하지 않는다.
        let planning = try PlanningContext(planningDay: context.planningDay, timeZoneID: context.timeZoneID,
                                           policyRevision: context.policyRevision, capturedAt: Date(timeIntervalSince1970: 0))
        let kind = try c.decode(CommandKind.self, forKey: .kind)
        let source = try c.decode(CommandSource.self, forKey: .source)
        let requestID = try c.decode(String.self, forKey: .requestID)
        let key = try c.decode(String.self, forKey: .idempotencyKey)
        let epoch = try c.decode(String.self, forKey: .workspaceEpoch)
        guard (1...200).contains(requestID.unicodeScalars.count), (1...200).contains(key.unicodeScalars.count), !epoch.isEmpty else {
            throw DomainContractError.invalidCommand
        }
        let p = try c.superDecoder(forKey: .payload)
        let needsVersions: Set<CommandKind> = [.setPlan, .setStatus, .setDeadline, .editContent, .park, .trash, .restore]
        if needsVersions.contains(kind), !c.contains(.expectedVersions) { throw DomainContractError.invalidCommand }
        let expected: ExpectedVersions
        if c.contains(.expectedVersions) {
            expected = try payload(ExpectedVersions.self, c.superDecoder(forKey: .expectedVersions),
                                   allowed: ["content", "plan", "status", "deadline"])
        } else { expected = ExpectedVersions() }
        guard [expected.content, expected.plan, expected.status, expected.deadline].allSatisfy({ $0?.isEmpty != true }) else {
            throw DomainContractError.invalidCommand
        }
        func taskID() throws -> UUID { try c.decode(UUID.self, forKey: .taskID) }
        func version(_ group: MutationGroup) throws -> String {
            guard let stamp = expected[group], !stamp.isEmpty else { throw DomainContractError.invalidCommand }
            return stamp
        }
        let value: CommandPayload
        switch kind {
        case .capture:
            let fields = try payload(PlannedCapture.self, p, allowed: ["title", "note", "sourceURL", "initialPlan"])
            let content = try TaskContent(title: fields.title, note: fields.note, sourceURL: fields.sourceURL)
            if let initialPlan = fields.initialPlan {
                value = .captureWithPlan(taskID: try taskID(), content: content, initialPlan: initialPlan)
            } else { value = .capture(taskID: try taskID(), content: content) }
        case .setPlan:
            let fields = try payload(Plan.self, p, allowed: ["target", "acknowledgment", "review"])
            value = .setPlan(item: PlanCommandItem(taskID: try taskID(), expected: expected, acknowledgment: fields.acknowledgment),
                             target: fields.target, review: fields.review)
        case .setStatus:
            let fields = try payload(Completion.self, p, allowed: ["desiredCompleted"])
            value = .completion(taskID: try taskID(), desiredCompleted: fields.desiredCompleted, expectedStatus: try version(.status))
        case .setDeadline:
            let fields = try payload(DeadlinePayload.self, p, allowed: ["deadline"])
            value = .setDeadline(taskID: try taskID(), deadline: fields.deadline, expectedDeadline: try version(.deadline))
        case .editContent:
            value = .editContent(taskID: try taskID(), content: try payload(TaskContent.self, p, allowed: ["title", "note", "sourceURL"]),
                                 expectedContent: try version(.content))
        case .park:
            _ = try payload(Empty.self, p, allowed: [])
            value = .park(taskID: try taskID(), expected: expected)
        case .trash:
            _ = try payload(Empty.self, p, allowed: [])
            value = .trash(taskID: try taskID(), expectedStatus: try version(.status))
        case .restore:
            let fields = try payload(Restore.self, p, allowed: ["observedDeleteHeadIDs"])
            value = .restore(taskID: try taskID(), observedDeleteHeadIDs: fields.observedDeleteHeadIDs, expectedStatus: try version(.status))
        case .undo:
            let fields = try payload(Undo.self, p, allowed: ["operationID", "expected"])
            value = .undo(operationID: fields.operationID, expected: fields.expected)
        case .reviewClose:
            value = .reviewClose(try payload(ReviewClosure.self, p, allowed: ["cycleID", "sessionID", "weeklyCoverageStartDate"]))
        case .batchSetPlan:
            let fields = try payload(Batch.self, p, allowed: ["items", "target"])
            value = .batchSetPlan(items: fields.items, target: fields.target)
        case .settings:
            let fields = try payload(Settings.self, p, allowed: ["policy", "expectedRevision"])
            value = .settings(policy: fields.policy, expectedRevision: fields.expectedRevision)
        }
        return CommandEnvelope(requestID: requestID, idempotencyKey: key, source: source,
                               context: planning, workspaceEpoch: epoch, payload: value)
    }
    static func encode(_ command: CommandEnvelope, to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(command.contractVersion, forKey: .contractVersion); try c.encode(command.requestID, forKey: .requestID)
        try c.encode(command.idempotencyKey, forKey: .idempotencyKey); try c.encode(command.kind, forKey: .kind)
        try c.encode(command.source, forKey: .source); try c.encode(command.workspaceEpoch, forKey: .workspaceEpoch)
        try c.encode(Context(planningDay: command.context.planningDay, timeZoneID: command.context.timeZoneID,
                             policyRevision: command.context.policyRevision), forKey: .context)
        switch command.payload {
        case let .capture(id, content):
            try c.encode(id, forKey: .taskID); try c.encode(content, forKey: .payload)
        case let .captureWithPlan(id, content, initialPlan):
            try c.encode(id, forKey: .taskID)
            try c.encode(PlannedCapture(title: content.title, note: content.note,
                sourceURL: content.sourceURL, initialPlan: initialPlan), forKey: .payload)
        case let .setPlan(item, target, review):
            try c.encode(item.taskID, forKey: .taskID); try c.encode(item.expected, forKey: .expectedVersions)
            try c.encode(Plan(target: target, acknowledgment: item.acknowledgment, review: review), forKey: .payload)
        case let .completion(id, completed, status):
            try c.encode(id, forKey: .taskID); try c.encode(ExpectedVersions(status: status), forKey: .expectedVersions)
            try c.encode(Completion(desiredCompleted: completed), forKey: .payload)
        case let .setDeadline(id, deadline, stamp):
            try c.encode(id, forKey: .taskID); try c.encode(ExpectedVersions(deadline: stamp), forKey: .expectedVersions)
            try c.encode(DeadlinePayload(deadline: deadline), forKey: .payload)
        case let .editContent(id, content, stamp):
            try c.encode(id, forKey: .taskID); try c.encode(ExpectedVersions(content: stamp), forKey: .expectedVersions)
            try c.encode(content, forKey: .payload)
        case let .park(id, expected):
            try c.encode(id, forKey: .taskID); try c.encode(expected, forKey: .expectedVersions)
            try c.encode(Empty(), forKey: .payload)
        case let .trash(id, stamp):
            try c.encode(id, forKey: .taskID); try c.encode(ExpectedVersions(status: stamp), forKey: .expectedVersions)
            try c.encode(Empty(), forKey: .payload)
        case let .restore(id, heads, stamp):
            try c.encode(id, forKey: .taskID); try c.encode(ExpectedVersions(status: stamp), forKey: .expectedVersions)
            try c.encode(Restore(observedDeleteHeadIDs: heads), forKey: .payload)
        case let .undo(id, expected): try c.encode(Undo(operationID: id, expected: expected), forKey: .payload)
        case let .reviewClose(value): try c.encode(value, forKey: .payload)
        case let .batchSetPlan(items, target): try c.encode(Batch(items: items, target: target), forKey: .payload)
        case let .settings(policy, revision): try c.encode(Settings(policy: policy, expectedRevision: revision), forKey: .payload)
        }
    }
}
