import Foundation

public enum OperationKind: String, Hashable, Codable, Sendable {
    case capture, setPlan, setStatus, setDeadline, editContent, undo, reviewClose, settings
}
public enum MutationValue: Hashable, Codable, Sendable {
    case content(TaskContent), plan(PlanValue), status(StatusValue), deadline(Deadline?)
    public var group: MutationGroup {
        switch self { case .content: .content; case .plan: .plan; case .status: .status; case .deadline: .deadline }
    }
    public var isStructurallyValid: Bool {
        switch self {
        case .content: return true // TaskContent의 생성·decode에서 검증한다.
        case let .plan(value): return PlanningRules.validatePlanStructure(value.target)
        case let .status(value): return value.isStructurallyValid
        case let .deadline(value): return value?.isStructurallyValid != false
        }
    }
}
public struct TaskMutation: Hashable, Codable, Sendable {
    public let taskID: UUID; public let value: MutationValue; public let observedHeadIDs: [String]
    public var group: MutationGroup { value.group }
    public init(taskID: UUID, value: MutationValue, observedHeadIDs: [String] = []) {
        self.taskID = taskID; self.value = value; self.observedHeadIDs = observedHeadIDs.sorted()
    }
}

/// 불변 원본. payloadDigest는 저장된 모든 의미 필드에 바인딩되며 자신은 해시 대상에서 제외한다.
public struct OperationRecord: Hashable, Codable, Sendable {
    public let operationID: String; public let schemaVersion: Int
    public let workspaceKey: String; public let workspaceEpoch: String; public let deviceID: UUID
    public let lamport: Int64; public let recordedAt: Date; public let commandKind: OperationKind
    public let mutations: [TaskMutation]; public let idempotencyKey: String?; public let logicalCommandDigest: String?
    public let undoValues: [TaskMutation]; public let compensatesOperationID: String?
    public let reviewDecision: ReviewDecisionContext?; public let reviewClosure: ReviewClosure?
    public let settings: PlanningPolicy?; public let payloadDigest: String

    /// v2는 명시적으로 계획한 생성만 추가한다. 다른 미지원 기록은 격리·보존한다.
    public var isSupportedSchemaVersion: Bool {
        schemaVersion == 1 || (schemaVersion == 2 && commandKind == .capture)
    }

    public init(operationID: String, schemaVersion: Int = 1, workspaceKey: String, workspaceEpoch: String,
                deviceID: UUID, lamport: Int64, recordedAt: Date, commandKind: OperationKind,
                mutations: [TaskMutation], idempotencyKey: String? = nil, logicalCommandDigest: String? = nil,
                undoValues: [TaskMutation] = [], compensatesOperationID: String? = nil,
                reviewDecision: ReviewDecisionContext? = nil, reviewClosure: ReviewClosure? = nil,
                settings: PlanningPolicy? = nil, payloadDigest: String) {
        self.operationID = operationID; self.schemaVersion = schemaVersion; self.workspaceKey = workspaceKey
        self.workspaceEpoch = workspaceEpoch; self.deviceID = deviceID; self.lamport = lamport
        self.recordedAt = recordedAt; self.commandKind = commandKind; self.mutations = mutations
        self.idempotencyKey = idempotencyKey; self.logicalCommandDigest = logicalCommandDigest
        self.undoValues = undoValues; self.compensatesOperationID = compensatesOperationID
        self.reviewDecision = reviewDecision; self.reviewClosure = reviewClosure; self.settings = settings
        self.payloadDigest = payloadDigest
    }
    public static func create(operationID: String, schemaVersion: Int = 1, workspaceKey: String,
                              workspaceEpoch: String, deviceID: UUID, lamport: Int64, recordedAt: Date,
                              commandKind: OperationKind, mutations: [TaskMutation], idempotencyKey: String? = nil,
                              logicalCommandDigest: String? = nil, undoValues: [TaskMutation] = [],
                              compensatesOperationID: String? = nil, reviewDecision: ReviewDecisionContext? = nil,
                              reviewClosure: ReviewClosure? = nil, settings: PlanningPolicy? = nil) throws -> Self {
        let unhashed = Self(operationID: operationID, schemaVersion: schemaVersion, workspaceKey: workspaceKey,
                            workspaceEpoch: workspaceEpoch, deviceID: deviceID, lamport: lamport,
                            recordedAt: recordedAt, commandKind: commandKind, mutations: mutations,
                            idempotencyKey: idempotencyKey, logicalCommandDigest: logicalCommandDigest,
                            undoValues: undoValues, compensatesOperationID: compensatesOperationID,
                            reviewDecision: reviewDecision, reviewClosure: reviewClosure, settings: settings,
                            payloadDigest: "")
        return Self(operationID: operationID, schemaVersion: schemaVersion, workspaceKey: workspaceKey,
                    workspaceEpoch: workspaceEpoch, deviceID: deviceID, lamport: lamport, recordedAt: recordedAt,
                    commandKind: commandKind, mutations: mutations, idempotencyKey: idempotencyKey,
                    logicalCommandDigest: logicalCommandDigest, undoValues: undoValues,
                    compensatesOperationID: compensatesOperationID, reviewDecision: reviewDecision,
                    reviewClosure: reviewClosure, settings: settings, payloadDigest: try unhashed.computedDigest())
    }
    public func computedDigest() throws -> String {
        struct Payload: Encodable {
            let operationID: String; let schemaVersion: Int; let workspaceKey: String; let workspaceEpoch: String
            let deviceID: UUID; let lamport: Int64; let recordedAt: Date; let commandKind: OperationKind
            let mutations: [TaskMutation]; let idempotencyKey: String?; let logicalCommandDigest: String?
            let undoValues: [TaskMutation]; let compensatesOperationID: String?
            let reviewDecision: ReviewDecisionContext?; let reviewClosure: ReviewClosure?; let settings: PlanningPolicy?
        }
        return try CanonicalDigest.hash(Payload(operationID: operationID, schemaVersion: schemaVersion,
            workspaceKey: workspaceKey, workspaceEpoch: workspaceEpoch, deviceID: deviceID, lamport: lamport,
            recordedAt: recordedAt, commandKind: commandKind, mutations: mutations, idempotencyKey: idempotencyKey,
            logicalCommandDigest: logicalCommandDigest, undoValues: undoValues,
            compensatesOperationID: compensatesOperationID, reviewDecision: reviewDecision,
            reviewClosure: reviewClosure, settings: settings))
    }
    public var affectedTaskIDs: [UUID] { Set(mutations.map(\.taskID)).sorted { $0.uuidString < $1.uuidString } }
    public static func logicalID(workspaceKey: String, workspaceEpoch: String, idempotencyKey: String) throws -> String {
        struct Identity: Encodable { let workspace: String; let epoch: String; let key: String }
        return try CanonicalDigest.hash(Identity(workspace: workspaceKey, epoch: workspaceEpoch, key: idempotencyKey))
    }
    /// 원본을 적용한 직후의 버전에 고정한다. 이후 snapshot의 버전을 Undo 입력으로 바꾸지 않는다.
    public func undoExpectations() -> [TaskVersionExpectation] {
        let affected = undoValues.isEmpty ? mutations : undoValues
        return affected.map { mutation in
            TaskVersionExpectation(taskID: mutation.taskID, group: mutation.group,
                headsDigest: CanonicalDigest.heads(taskID: mutation.taskID, group: mutation.group, ids: [operationID]))
        }
    }
    public func undoExpectations(in tasks: [UUID: TaskProjection]) -> [TaskVersionExpectation] {
        undoExpectations()
    }
    public func recoveredReceipt(requestID: String) -> CommandReceipt? {
        guard let key = idempotencyKey, let digest = logicalCommandDigest else { return nil }
        return CommandReceipt(workspaceEpoch: workspaceEpoch, key: key, digest: digest, operationID: operationID,
                              result: CommandResult(requestID: requestID, operationID: operationID,
                                state: .committedProjectionPending, safeUserMessage: "저장한 변경을 화면에 반영 중이에요.",
                                affectedTaskIDs: affectedTaskIDs))
    }
}

public enum ReductionIssue: String, Codable, Sendable {
    case conflictingDuplicate, invalidDigest, malformedRecord, invalidParent, missingParent, missingCreation
    case unsupportedSchema, wrongWorkspace, cyclicDependency
}
public struct ReviewAcknowledgment: Hashable, Codable, Sendable {
    public let cycleID: String; public let taskID: UUID; public let planVersion: String
    public let decisionOperationID: String
    public init(cycleID: String, taskID: UUID, planVersion: String, decisionOperationID: String) {
        self.cycleID = cycleID; self.taskID = taskID; self.planVersion = planVersion
        self.decisionOperationID = decisionOperationID
    }
}
public struct ReviewCycleProjection: Hashable, Codable, Sendable {
    public let cycleID: String; public let closed: Bool; public let closeOperationID: String
    public let weeklyCoverageStartDate: LocalDate?
}
public struct ReductionReport: Sendable {
    public let tasks: [UUID: TaskProjection]
    public let pending: [String: ReductionIssue]; public let quarantined: [String: ReductionIssue]
    public let appliedOperationIDs: Set<String>
    public let acknowledgments: [ReviewAcknowledgment]; public let cycles: [String: ReviewCycleProjection]
    public let settings: PlanningPolicy?
    public func acknowledges(task: TaskProjection, cycleID: String) -> Bool {
        acknowledgments.contains { $0.cycleID == cycleID && $0.taskID == task.taskID
            && $0.planVersion == task.versions[.plan]?.headsDigest }
    }
    public func isCycleClosed(_ cycleID: String) -> Bool { cycles[cycleID]?.closed == true }
}
