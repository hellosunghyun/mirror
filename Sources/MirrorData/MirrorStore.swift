import Foundation
import MirrorDomain

public struct StoreSnapshot: Sendable {
    public let tasks: [TaskProjection]
    public let records: [OperationRecord]
    public let policy: PlanningPolicy
    public let workspaceKey: String
    public let workspaceEpoch: String
    public let syncState: StoreSyncState
    public let quarantinedCount: Int
    public let pendingOperationIDs: [String]
}

public struct ImportPreview: Sendable {
    public let operationCount: Int
    public let taskCount: Int
    public let duplicateCount: Int
    public let warnings: [String]
    public let requiresWorkspaceConfirmation: Bool
    public let requiresAccountConfirmation: Bool
    public let sourceWorkspaceEpoch: String
}

public struct ArchiveImportConsent: Sendable {
    public let accountChangeConfirmed: Bool
    public init(accountChangeConfirmed: Bool = false) { self.accountChangeConfirmed = accountChangeConfirmed }
}

public struct ArchiveRestorationReport: Sendable {
    public let newConfiguration: StoreConfiguration
    public let importReport: ImportReport
}

public struct LocalDeletionReport: Sendable {
    public let deleted: Bool
    public let newConfiguration: StoreConfiguration?
    public let safeUserMessage: String
}

private struct StorageIdentity: Codable, Equatable, Sendable {
    let workspaceKey: String
    let workspaceEpoch: String
    let accountScope: String?
    let bootstrapPolicy: PlanningPolicy?
    let writerGeneration: String?
    let isTransitioning: Bool?
    let originAccountScopeFingerprints: [String]?

    init(workspaceKey: String, workspaceEpoch: String, accountScope: String?, bootstrapPolicy: PlanningPolicy?,
         writerGeneration: String? = nil, isTransitioning: Bool? = nil, originAccountScopeFingerprints: [String]? = nil) {
        self.workspaceKey = workspaceKey; self.workspaceEpoch = workspaceEpoch; self.accountScope = accountScope
        self.bootstrapPolicy = bootstrapPolicy; self.writerGeneration = writerGeneration
        self.isTransitioning = isTransitioning; self.originAccountScopeFingerprints = originAccountScopeFingerprints
    }
}

/// 두 SQLite 저장소를 원자적이라고 가정하지 않는다. 성공 기준은 원본의 save다.
/// actor는 한 프로세스의 순서만 맡고 실제 쓰기는 advisory lock으로 조율한다.
public actor MirrorStore {
    public let configuration: StoreConfiguration
    private let persistence: CoreDataPersistence
    private let gate: ProcessWriteGate
    private let identity: StorageIdentity
    private var records: [OperationRecord] = []
    private var tasks: [UUID: TaskProjection] = [:]
    private var policy: PlanningPolicy
    private var historyCursor: Data?
    private var unknownIDs: Set<String> = []
    private var pending: [String: ReductionIssue] = [:]
    private var quarantined: [String: ReductionIssue] = [:]
    private var deleted = false

    public init(configuration: StoreConfiguration) async throws {
        guard !configuration.workspaceKey.isEmpty, !configuration.workspaceEpoch.isEmpty,
              UUID(uuidString: configuration.deviceID) != nil,
              configuration.lockTimeout > .zero else { throw StoreError.invalidConfiguration }
        self.configuration = configuration
        self.policy = try PlanningPolicy(timeZoneID: configuration.initialTimeZoneID, revision: configuration.initialPolicyRevision)
        try Self.prepareDirectory(configuration.directory)
        let gate = ProcessWriteGate(url: configuration.directory.appendingPathComponent("Writer.lock"), timeout: configuration.lockTimeout)
        self.gate = gate
        var identity = StorageIdentity(workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch,
                                       accountScope: configuration.cloudSync?.accountScope, bootstrapPolicy: self.policy,
                                       writerGeneration: UUID().uuidString,
                                       originAccountScopeFingerprints: [Self.scopeFingerprint(configuration)])
        let lease = try await gate.acquire()
        defer { lease.release() }
        let identityURL = configuration.directory.appendingPathComponent("StorageIdentity.json")
        if FileManager.default.fileExists(atPath: identityURL.path) {
            let old = try JSONDecoder().decode(StorageIdentity.self, from: Data(contentsOf: identityURL))
            guard old.isTransitioning != true else { throw StoreError.busy }
            guard old.workspaceKey == identity.workspaceKey else { throw StoreError.workspaceMismatch }
            guard old.workspaceEpoch == identity.workspaceEpoch else { throw StoreError.obsoleteEpoch }
            guard old.accountScope == identity.accountScope else { throw StoreError.accountScopeMismatch }
            let bootstrap = old.bootstrapPolicy ?? self.policy
            identity = StorageIdentity(workspaceKey: identity.workspaceKey, workspaceEpoch: identity.workspaceEpoch,
                                       accountScope: identity.accountScope, bootstrapPolicy: bootstrap,
                                       writerGeneration: old.writerGeneration ?? identity.writerGeneration,
                                       originAccountScopeFingerprints: old.originAccountScopeFingerprints ?? identity.originAccountScopeFingerprints)
            self.policy = bootstrap
            if old.bootstrapPolicy == nil || old.writerGeneration == nil { try CanonicalDigest.data(identity).write(to: identityURL, options: .atomic) }
        } else {
            try CanonicalDigest.data(identity).write(to: identityURL, options: .atomic)
        }
        self.identity = identity
        self.persistence = try await CoreDataPersistence.open(configuration: configuration)
        // 재생 중 새 import가 와도 읽기 전의 cursor부터 다음에 소비할 수 있다.
        self.historyCursor = try await persistence.historyCursor()
        lease.release()
        let raw = try await persistence.operations()
        let decoded = Self.decode(raw, configuration: configuration)
        self.records = decoded.records
        self.unknownIDs = decoded.unknownIDs
        let report = TaskReducer.reduce(decoded.records, workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
        self.tasks = Self.restrictUnsupportedTasks(report.tasks, unknownTaskIDs: decoded.unknownTaskIDs)
        self.pending = report.pending
        self.quarantined = report.quarantined
        if let setting = report.settings { self.policy = setting }
        let projectionLease = try await gate.acquire()
        if try await persistence.historyChanges(after: historyCursor).changed {
            projectionLease.release()
            try await rebuild()
        } else {
            defer { projectionLease.release() }
            try await persistence.saveProjection(try Self.projectionValues(tasks: self.tasks, policy: self.policy), replacingTasks: true)
        }
    }

    public func snapshot() async throws -> StoreSnapshot {
        try assertIdentity()
        try await refresh()
        return StoreSnapshot(
            tasks: tasks.values.sorted { $0.createdAt == $1.createdAt ? $0.taskID.uuidString < $1.taskID.uuidString : $0.createdAt < $1.createdAt },
            records: records.sorted(by: Self.precedes), policy: policy,
            workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch,
            syncState: configuration.cloudSync == nil ? .localOnly : .awaitingCloudSynchronization,
            quarantinedCount: Set(quarantined.keys).union(unknownIDs).count,
            pendingOperationIDs: Array(Set(pending.keys).union(unknownIDs)).sorted()
        )
    }

    public func currentContext(at instant: Date) async throws -> PlanningContext {
        let current = try await snapshot()
        return try PlanningContext.capture(at: instant, timeZoneID: current.policy.timeZoneID, policyRevision: current.policy.revision)
    }

    /// 카드의 frozen context와 구분한 서비스의 현재 시각을 주입한다.
    public func execute(_ envelope: CommandEnvelope, at instant: Date,
                        failurePoint: StoreFailurePoint = .none) async -> CommandResult {
        do {
            let context = try PlanningContext.capture(at: instant, timeZoneID: policy.timeZoneID, policyRevision: policy.revision)
            return await execute(envelope, context: context, failurePoint: failurePoint)
        } catch {
            return Self.failure(envelope, state: .unavailable, message: "현재 날짜를 확인할 수 없습니다.")
        }
    }

    /// context.capturedAt은 서비스가 주입한 현재 시각이다. 봉투의 context는 검증에만 쓴다.
    public func execute(_ envelope: CommandEnvelope, context: PlanningContext,
                        failurePoint: StoreFailurePoint = .none) async -> CommandResult {
        var committed: OperationRecord?
        do {
            try Task.checkCancellation()
            let lease = try await gate.acquire()
            defer { lease.release() }
            try Task.checkCancellation()
            try assertIdentity()
            guard envelope.workspaceEpoch == configuration.workspaceEpoch else {
                return Self.failure(envelope, state: .staleSnapshot, message: "저장소가 갱신되었습니다. 화면을 다시 열어 주세요.")
            }
            // receipt에만 의존하지 않는다. 원본의 키를 시각·카드 검증보다 먼저 읽는다.
            let previousRaw = try await persistence.operation(idempotencyKey: envelope.idempotencyKey,
                workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
            let previous = Self.decode(previousRaw, configuration: configuration).records
            let digest = try envelope.logicalDigest()
            if !previousRaw.isEmpty && previous.isEmpty {
                return Self.failure(envelope, state: .unavailable, message: "이 결정의 원본을 해석할 수 없습니다. 새 버전으로 이력을 확인해 주세요.")
            }
            if let previousOperation = previous.first {
                guard previousRaw.count == previous.count, previousOperation.schemaVersion == 1,
                      previous.allSatisfy({ $0.schemaVersion == 1 }),
                      previous.allSatisfy({ $0.payloadDigest == previousOperation.payloadDigest &&
                          (try? $0.computedDigest()) == $0.payloadDigest }) else {
                    return Self.failure(envelope, state: .unavailable, message: "같은 변경의 서로 다른 원본이 있습니다. 이력을 확인해 주세요.")
                }
                committed = previousOperation
                let repeatedState: CommandResultState = previousOperation.logicalCommandDigest == digest ? .alreadyApplied : .alreadyDecided
                let projected = try await projectAffected(by: previousOperation)
                let result = CommandResult(requestID: envelope.requestID, operationID: previousOperation.operationID,
                                           state: projected ? repeatedState : .committedProjectionPending,
                                           safeUserMessage: projected ? (repeatedState == .alreadyApplied ? "이미 저장한 변경입니다." : "이 카드는 이미 결정되었습니다.") : "변경은 저장했습니다. 원본 이력을 반영 중입니다.",
                                           affectedTaskIDs: previousOperation.affectedTaskIDs)
                try await persistence.saveProjection([:], receipt: StoredReceipt(key: envelope.idempotencyKey,
                    digest: previousOperation.logicalCommandDigest ?? digest, operationID: previousOperation.operationID,
                    result: try CanonicalDigest.data(result)))
                return result
            }
            // 카드의 작업 ID만 가져온다. 화면을 그릴 때마다 전체 작업을 재생하지 않는다.
            let affectedIDs = try await affectedTaskIDs(envelope.payload)
            let relevantRaw = try await relatedOperations(taskIDs: affectedIDs)
            let decoded = Self.decode(relevantRaw, configuration: configuration)
            let report = TaskReducer.reduce(decoded.records, workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
            let currentPolicy = report.settings ?? policy
            let currentContext = try PlanningContext.capture(at: context.capturedAt, timeZoneID: currentPolicy.timeZoneID,
                                                              policyRevision: currentPolicy.revision)
            let commandSnapshot = CommandSnapshot(
                workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch,
                deviceID: UUID(uuidString: configuration.deviceID)!, currentContext: currentContext,
                recordedAt: context.capturedAt,
                tasks: Self.restrictUnsupportedTasks(report.tasks, unknownTaskIDs: decoded.unknownTaskIDs),
                records: decoded.records, observedLamport: try await persistence.maximumLamport()
            )
            switch CommandValidator.prepare(envelope, snapshot: commandSnapshot) {
            case let .rejected(rejection):
                return CommandResult(requestID: envelope.requestID, state: rejection.state,
                                     safeUserMessage: rejection.message, affectedTaskIDs: rejection.taskIDs)
            case let .alreadyApplied(receipt): return receipt.result.retry(requestID: envelope.requestID)
            case let .alreadyDecided(receipt): return receipt.result.retry(requestID: envelope.requestID, state: .alreadyDecided)
            case let .prepared(prepared):
                guard try await persistence.operation(operationID: prepared.operation.operationID).isEmpty else {
                    return Self.failure(envelope, state: .unavailable, message: "이 변경 ID의 기존 원본이 있습니다. 이력을 확인해 주세요.")
                }
                if failurePoint == .beforeCanonicalSave { throw StoreError.persistence("원본 저장 전 장애입니다.") }
                try await persistence.append(try Self.stored(prepared.operation))
                committed = prepared.operation
                if failurePoint == .afterCanonicalSave { throw StoreError.persistence("원본 저장 후 장애입니다.") }
                let combined = decoded.records + [prepared.operation]
                let updated = TaskReducer.reduce(combined, workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
                let result = CommandResult(requestID: envelope.requestID, operationID: prepared.operation.operationID,
                                           state: .locallyCommitted, safeUserMessage: "이 기기에 저장했습니다.",
                                           affectedTaskIDs: prepared.affectedTaskIDs)
                if failurePoint == .beforeReceiptSave { throw StoreError.persistence("화면용 저장 전 장애입니다.") }
                try await persistence.saveProjection(try Self.projectionValues(tasks: updated.tasks, policy: updated.settings ?? currentPolicy),
                    receipt: StoredReceipt(key: envelope.idempotencyKey, digest: prepared.logicalDigest,
                        operationID: prepared.operation.operationID, result: try CanonicalDigest.data(result)))
                for (id, task) in updated.tasks { tasks[id] = task }
                policy = updated.settings ?? currentPolicy
                mergeRecords(combined)
                return result
            }
        } catch {
            if let committed {
                return CommandResult(requestID: envelope.requestID, operationID: committed.operationID,
                    state: .committedProjectionPending, safeUserMessage: "변경은 저장했습니다. 화면 반영을 재시도해 주세요.",
                    affectedTaskIDs: committed.affectedTaskIDs)
            }
            if error is CancellationError || error as? StoreError == .cancelled {
                return Self.failure(envelope, state: .unavailable, message: "변경을 중단했습니다. 필요하면 재시도해 주세요.")
            }
            if error as? StoreError == .busy {
                return Self.failure(envelope, state: .unavailable, message: "다른 변경을 반영 중입니다. 같은 작업을 재시도해 주세요.")
            }
            if StoreError.classify(error) == .protectedDataUnavailable {
                return Self.failure(envelope, state: .unavailable, message: "기기 잠금을 해제한 뒤 같은 작업을 재시도해 주세요.")
            }
            return Self.failure(envelope, state: .persistenceFailed, message: "저장할 수 없습니다. 같은 작업을 재시도해 주세요.")
        }
    }

    public func localValue(forKey key: String) async throws -> Data? {
        try assertIdentity()
        return try await persistence.localValue(key: "local:\(key)")
    }

    public func setLocalValue(_ value: Data?, forKey key: String) async throws {
        let lease = try await gate.acquire()
        defer { lease.release() }
        try assertIdentity()
        try await persistence.setLocalValue(value, key: "local:\(key)")
    }

    /// UTF-8 JSON의 operations가 복원 원본이고 currentTasks는 조회용이다.
    /// 모르는 payload도 rawOperations에서 원본 bytes 그대로 보존한다.
    public func exportArchive(exportedAt: Date) async throws -> Data {
        try assertIdentity()
        let raw = try await persistence.operations()
        let decoded = Self.decode(raw, configuration: configuration)
        let report = TaskReducer.reduce(decoded.records, workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
        return try Self.makeArchive(raw: raw,
            currentTasks: Array(Self.restrictUnsupportedTasks(report.tasks, unknownTaskIDs: decoded.unknownTaskIDs).values),
            planningPolicy: report.settings ?? identity.bootstrapPolicy ?? policy,
            configuration: configuration, originScopes: storedIdentity().originAccountScopeFingerprints,
            exportedAt: exportedAt)
    }

    /// 동기화 활성화 확인 뒤 최신 원본을 확보하고 writer/importer를 detach한다.
    /// 원본 재생과 JSON 작성은 gate를 해제한 뒤 수행한다.
    public func exportAndSuspend(exportedAt: Date) async throws -> Data {
        guard exportedAt.timeIntervalSince1970.isFinite else { throw StoreError.invalidConfiguration }
        let lease = try await gate.acquire()
        let raw: [StoredOperation]
        let before: StorageIdentity
        do {
            try assertIdentity()
            raw = try await persistence.operations()
            before = try storedIdentity()
            let rotated = StorageIdentity(workspaceKey: before.workspaceKey, workspaceEpoch: before.workspaceEpoch,
                accountScope: before.accountScope, bootstrapPolicy: before.bootstrapPolicy,
                writerGeneration: UUID().uuidString, originAccountScopeFingerprints: before.originAccountScopeFingerprints)
            try CanonicalDigest.data(rotated).write(to: configuration.directory.appendingPathComponent("StorageIdentity.json"), options: .atomic)
            deleted = true
            try await persistence.close()
            lease.release()
        } catch { lease.release(); throw error }
        let decoded = Self.decode(raw, configuration: configuration)
        let report = TaskReducer.reduce(decoded.records, workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
        return try Self.makeArchive(raw: raw,
            currentTasks: Array(Self.restrictUnsupportedTasks(report.tasks, unknownTaskIDs: decoded.unknownTaskIDs).values),
            planningPolicy: report.settings ?? before.bootstrapPolicy ?? policy,
            configuration: configuration, originScopes: before.originAccountScopeFingerprints,
            exportedAt: exportedAt)
    }

    private static func makeArchive(raw: [StoredOperation], currentTasks: [TaskProjection], planningPolicy: PlanningPolicy,
                                    configuration: StoreConfiguration, originScopes: [String]?, exportedAt: Date) throws -> Data {
        guard exportedAt.timeIntervalSince1970.isFinite else { throw StoreError.invalidConfiguration }
        var operationObjects: [Any] = []
        var rawObjects: [[String: Any]] = []
        for row in raw.sorted(by: { $0.operationID < $1.operationID }) {
            if let object = try? JSONSerialization.jsonObject(with: row.payload) { operationObjects.append(object) }
            rawObjects.append(["operationID": row.operationID, "payloadDigest": row.payloadDigest,
                               "payloadBase64": row.payload.base64EncodedString(), "taskIDs": row.taskIDs,
                               "workspaceKey": row.workspaceKey, "workspaceEpoch": row.workspaceEpoch,
                               "quarantined": row.workspaceKey != configuration.workspaceKey || row.workspaceEpoch != configuration.workspaceEpoch,
                               "schemaVersion": row.schemaVersion, "lamport": row.lamport,
                               "idempotencyKey": row.idempotencyKey as Any? ?? NSNull(),
                               "requestDigest": row.requestDigest as Any? ?? NSNull()])
        }
        let json: [String: Any] = [
            "formatVersion": 1, "exportedAt": exportedAt.timeIntervalSince1970 * 1_000,
            "workspaceKey": configuration.workspaceKey, "workspaceEpoch": configuration.workspaceEpoch,
            "sourceAccountScope": Self.scopeFingerprint(configuration),
            "originAccountScopes": originScopes ?? [Self.scopeFingerprint(configuration)],
            "planningPolicy": try JSONSerialization.jsonObject(with: CanonicalDigest.data(planningPolicy)),
            "operations": operationObjects, "rawOperations": rawObjects,
            "currentTasks": try JSONSerialization.jsonObject(with: CanonicalDigest.data(currentTasks.sorted { $0.taskID.uuidString < $1.taskID.uuidString }))
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public func previewArchive(_ data: Data) async throws -> ImportPreview {
        try assertIdentity()
        let parsed = try Self.parseArchive(data, configuration: configuration, allowForeignWorkspace: true)
        let metadata = try Self.archiveMetadata(data)
        let existing = try await persistence.operations()
        let preview = Self.importCounts(parsed, existing: existing)
        let previewConfiguration = StoreConfiguration(directory: configuration.directory, workspaceKey: metadata.workspace,
            workspaceEpoch: metadata.epoch, deviceID: configuration.deviceID,
            initialTimeZoneID: policy.timeZoneID, initialPolicyRevision: policy.revision)
        let decoded = Self.decode(parsed, configuration: previewConfiguration)
        let report = TaskReducer.reduce(decoded.records, workspaceKey: metadata.workspace, workspaceEpoch: metadata.epoch)
        var warnings: [String] = []
        if preview.quarantined > 0 { warnings.append("같은 ID의 다른 내용이나 해석할 수 없는 원본은 보존하고 격리합니다.") }
        if !report.pending.isEmpty { warnings.append("아직 부모 기록이 없는 변경은 대기 상태로 보존합니다.") }
        warnings.append("현재 작업 스냅샷이 아닌 원본 변경 기록을 병합합니다.")
        let otherEpoch = metadata.epoch != configuration.workspaceEpoch || metadata.workspace != configuration.workspaceKey
        let otherAccount = Self.requiresAccountConfirmation(metadata.scopes, configuration: configuration)
        if otherEpoch { warnings.append("다른 세대의 자료입니다. 기기 내 작업을 교체하고 원본 공간을 명시적으로 복원해야 합니다.") }
        if otherAccount { warnings.append("다른 계정 또는 확인할 수 없는 출처의 자료입니다. 계정 간 이관을 명시적으로 확인해야 합니다.") }
        return ImportPreview(operationCount: parsed.count, taskCount: report.tasks.count,
                             duplicateCount: preview.duplicates, warnings: warnings,
                             requiresWorkspaceConfirmation: otherEpoch, requiresAccountConfirmation: otherAccount,
                             sourceWorkspaceEpoch: metadata.epoch)
    }

    public static func previewArchiveForRecovery(_ data: Data, configuration: StoreConfiguration) throws -> ImportPreview {
        let parsed = try parseArchive(data, configuration: configuration, allowForeignWorkspace: true)
        let metadata = try archiveMetadata(data)
        let previewConfiguration = StoreConfiguration(directory: configuration.directory, workspaceKey: metadata.workspace,
            workspaceEpoch: metadata.epoch, deviceID: configuration.deviceID)
        let decoded = decode(parsed, configuration: previewConfiguration)
        let report = TaskReducer.reduce(decoded.records, workspaceKey: metadata.workspace, workspaceEpoch: metadata.epoch)
        return ImportPreview(operationCount: parsed.count, taskCount: report.tasks.count,
            duplicateCount: importCounts(parsed, existing: []).duplicates,
            warnings: ["중단된 기기 내 복원을 선택한 원본 export로 다시 진행합니다. 현재 저장소는 전체 교체됩니다.",
                       "다른 계정과 세대의 자료가 포함되면 이관을 명시적으로 확인해야 합니다."],
            requiresWorkspaceConfirmation: true,
            requiresAccountConfirmation: requiresAccountConfirmation(metadata.scopes, configuration: configuration),
            sourceWorkspaceEpoch: metadata.epoch)
    }

    public func importArchive(_ data: Data, consent: ArchiveImportConsent = .init()) async throws -> ImportReport {
        try assertIdentity()
        let parsed = try Self.parseArchive(data, configuration: configuration) // 모든 행의 형식을 저장 전에 검증한다.
        let metadata = try Self.archiveMetadata(data)
        if Self.requiresAccountConfirmation(metadata.scopes, configuration: configuration), !consent.accountChangeConfirmed {
            throw StoreError.confirmationRequired
        }
        let lease = try await gate.acquire()
        let counts: ImportReport
        do {
            try assertIdentity()
            let existing = try await persistence.operations()
            counts = Self.importCounts(parsed, existing: existing)
            var seen = Set(existing.map(Self.rowFingerprint))
            let additions = parsed.filter { seen.insert(Self.rowFingerprint($0)).inserted }
            try await persistence.appendMany(additions)
            try preserveOriginScopes(metadata.scopes)
            lease.release()
        } catch { lease.release(); throw error }
        do { try await rebuild(); return counts }
        catch {
            return ImportReport(inserted: counts.inserted, duplicates: counts.duplicates,
                                quarantined: counts.quarantined, projectionPending: true)
        }
    }

    /// UI에서 기기 내 삭제를 명시적으로 확인한 뒤 호출한다. 숨겨진 자동 백업을 남기지 않는다.
    public func deleteLocalData() async throws -> LocalDeletionReport {
        guard configuration.cloudSync == nil else {
            return LocalDeletionReport(deleted: false, newConfiguration: nil,
                safeUserMessage: "클라우드 연결 중단과 계정 확인이 필요합니다. iCloud 전체 삭제는 별도 절차입니다.")
        }
        let lease = try await gate.acquire()
        defer { lease.release() }
        try assertIdentity()
        let epoch = "local-\(UUID().uuidString.lowercased())"
        let rotated = StorageIdentity(workspaceKey: configuration.workspaceKey, workspaceEpoch: epoch,
                                      accountScope: nil, bootstrapPolicy: identity.bootstrapPolicy,
                                      writerGeneration: UUID().uuidString,
                                      originAccountScopeFingerprints: [Self.scopeFingerprint(configuration)])
        // 구 actor와 다른 프로세스 writer를 먼저 차단한 뒤 원본·투영을 파괴한다.
        try CanonicalDigest.data(rotated).write(to: configuration.directory.appendingPathComponent("StorageIdentity.json"), options: .atomic)
        deleted = true
        try await persistence.destroyLocalStores()
        for name in ["WidgetSnapshot.json", "NotificationLedger.json"] {
            let url = configuration.directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        records = []; tasks = [:]; unknownIDs = []; pending = [:]; quarantined = [:]
        let next = StoreConfiguration(directory: configuration.directory, workspaceKey: configuration.workspaceKey,
            workspaceEpoch: epoch, deviceID: configuration.deviceID, lockTimeout: configuration.lockTimeout,
            initialTimeZoneID: configuration.initialTimeZoneID, initialPolicyRevision: configuration.initialPolicyRevision)
        return LocalDeletionReport(deleted: true, newConfiguration: next,
                                   safeUserMessage: "이 기기의 원본과 캐시를 지웠습니다. 다른 기기와 iCloud 데이터는 삭제하지 않았습니다.")
    }

    /// 계정 전환 전에 이 container를 detach한다. 다른 프로세스도 자신의 계정 경계를 확인해야 한다.
    public func suspend() async throws {
        if deleted {
            try await persistence.close()
            return
        }
        let lease: ProcessWriteLease
        do { lease = try await gate.acquire() }
        catch {
            deleted = true
            try await persistence.close()
            throw error
        }
        defer { lease.release() }
        var boundaryError: StoreError?
        do {
            let previous = try storedIdentity()
            // 다른 프로세스가 이미 revoke했다면 그 세대를 다시 회전시키지 않는다.
            if previous.workspaceKey == identity.workspaceKey, previous.workspaceEpoch == identity.workspaceEpoch,
               previous.accountScope == identity.accountScope, previous.writerGeneration == identity.writerGeneration,
               previous.isTransitioning != true {
                let rotated = StorageIdentity(workspaceKey: previous.workspaceKey, workspaceEpoch: previous.workspaceEpoch,
                    accountScope: previous.accountScope, bootstrapPolicy: previous.bootstrapPolicy,
                    writerGeneration: UUID().uuidString, originAccountScopeFingerprints: previous.originAccountScopeFingerprints)
                try CanonicalDigest.data(rotated).write(to: configuration.directory.appendingPathComponent("StorageIdentity.json"), options: .atomic)
            }
        } catch { boundaryError = StoreError.classify(error) }
        // identity가 달라지거나 접근이 막혀도 자신의 importer/context는 반드시 detach한다.
        deleted = true
        try await persistence.close()
        if let boundaryError { throw boundaryError }
    }

    public func cloudStoreIdentifiers() -> Set<String> {
        guard configuration.cloudSync != nil, !deleted else { return [] }
        return persistence.canonicalStoreIdentifiers()
    }

    /// 별도 확인한 로컬 전체 교체다. 원본의 ID/digest/부모를 수정하지 않고 원래 공간을 복원한다.
    public func restoreArchiveAsLocalWorkspace(_ data: Data, confirmed: Bool,
                                               failurePoint: StoreFailurePoint = .none) async throws -> ArchiveRestorationReport {
        guard confirmed else { throw StoreError.confirmationRequired }
        guard configuration.cloudSync == nil else { throw StoreError.cloudConnectionRequiresTransition }
        let incoming = try Self.parseArchive(data, configuration: configuration, allowForeignWorkspace: true)
        let metadata = try Self.archiveMetadata(data)
        let restoredPolicy = metadata.policy ?? identity.bootstrapPolicy ?? policy
        let next = StoreConfiguration(directory: configuration.directory, workspaceKey: metadata.workspace,
            workspaceEpoch: metadata.epoch, deviceID: configuration.deviceID,
            lockTimeout: configuration.lockTimeout, initialTimeZoneID: restoredPolicy.timeZoneID,
            initialPolicyRevision: restoredPolicy.revision)
        let lease = try await gate.acquire()
        defer { lease.release() }
        try assertIdentity()
        let transition = StorageIdentity(workspaceKey: metadata.workspace, workspaceEpoch: metadata.epoch,
            accountScope: nil, bootstrapPolicy: restoredPolicy, writerGeneration: UUID().uuidString,
            isTransitioning: true, originAccountScopeFingerprints: metadata.scopes)
        let identityURL = configuration.directory.appendingPathComponent("StorageIdentity.json")
        try CanonicalDigest.data(transition).write(to: identityURL, options: .atomic)
        deleted = true
        try await persistence.destroyLocalStores()
        let restored = try await CoreDataPersistence.open(configuration: next)
        var seen: Set<String> = []
        let unique = incoming.filter { seen.insert(Self.rowFingerprint($0)).inserted }
        do {
            try await restored.appendMany(unique)
            if failurePoint == .afterCanonicalSave { throw StoreError.persistence("복원 원본 저장 뒤 장애입니다.") }
            try await restored.close()
        } catch {
            try? await restored.close()
            // 전환 상태를 유지한다. 빈 저장소에 새 명령을 저장했다고 성공을 반환하지 않는다.
            throw error
        }
        let ready = StorageIdentity(workspaceKey: transition.workspaceKey, workspaceEpoch: transition.workspaceEpoch,
            accountScope: nil, bootstrapPolicy: restoredPolicy, writerGeneration: transition.writerGeneration,
            isTransitioning: false, originAccountScopeFingerprints: metadata.scopes)
        try CanonicalDigest.data(ready).write(to: identityURL, options: .atomic)
        return ArchiveRestorationReport(newConfiguration: next, importReport: Self.importCounts(incoming, existing: []))
    }

    /// 교체 중 종료된 저장소는 원본 export를 다시 선택하고 확인하여 복구한다.
    /// 자동으로 다른 계정 자료나 currentTasks 스냅샷을 복원하지 않는다.
    public static func recoverInterruptedLocalRestoration(from data: Data, directory: URL, deviceID: String,
                                                         confirmed: Bool) async throws -> ArchiveRestorationReport {
        guard confirmed else { throw StoreError.confirmationRequired }
        let metadata = try archiveMetadata(data)
        let temporary = StoreConfiguration(directory: directory, workspaceKey: metadata.workspace,
            workspaceEpoch: metadata.epoch, deviceID: deviceID)
        let incoming = try parseArchive(data, configuration: temporary, allowForeignWorkspace: true)
        let gate = ProcessWriteGate(url: directory.appendingPathComponent("Writer.lock"), timeout: temporary.lockTimeout)
        let lease = try await gate.acquire()
        defer { lease.release() }
        let identityURL = directory.appendingPathComponent("StorageIdentity.json")
        let interrupted = try JSONDecoder().decode(StorageIdentity.self, from: Data(contentsOf: identityURL))
        guard interrupted.isTransitioning == true, interrupted.accountScope == nil,
              interrupted.workspaceKey == metadata.workspace, interrupted.workspaceEpoch == metadata.epoch else {
            throw StoreError.invalidConfiguration
        }
        let initial: PlanningPolicy
        if let archivePolicy = metadata.policy { initial = archivePolicy }
        else if let bootstrap = interrupted.bootstrapPolicy { initial = bootstrap }
        else { initial = try PlanningPolicy(timeZoneID: "Asia/Seoul", revision: "policy-v1") }
        let next = StoreConfiguration(directory: directory, workspaceKey: metadata.workspace,
            workspaceEpoch: metadata.epoch, deviceID: deviceID,
            initialTimeZoneID: initial.timeZoneID, initialPolicyRevision: initial.revision)
        let damaged = try await CoreDataPersistence.open(configuration: next)
        try await damaged.destroyLocalStores()
        let restored = try await CoreDataPersistence.open(configuration: next)
        var seen: Set<String> = []
        do {
            try await restored.appendMany(incoming.filter { seen.insert(rowFingerprint($0)).inserted })
            try await restored.close()
        } catch { try? await restored.close(); throw error }
        let ready = StorageIdentity(workspaceKey: metadata.workspace, workspaceEpoch: metadata.epoch,
            accountScope: nil, bootstrapPolicy: initial, writerGeneration: UUID().uuidString,
            isTransitioning: false, originAccountScopeFingerprints: metadata.scopes)
        try CanonicalDigest.data(ready).write(to: identityURL, options: .atomic)
        return ArchiveRestorationReport(newConfiguration: next, importReport: importCounts(incoming, existing: []))
    }

    private static func archiveMetadata(_ data: Data) throws -> ArchiveMetadata {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspace = object["workspaceKey"] as? String, let epoch = object["workspaceEpoch"] as? String else {
            throw StoreError.incompatibleArchive
        }
        let scopes = object["originAccountScopes"] as? [String] ?? [object["sourceAccountScope"] as? String ?? "unverified"]
        let source = object["sourceAccountScope"] as? String ?? "unverified"
        let allScopes = Array(Set(scopes + [source])).sorted()
        let initialPolicy: PlanningPolicy?
        if let value = object["planningPolicy"] {
            let decoded = try JSONDecoder().decode(PlanningPolicy.self, from: JSONSerialization.data(withJSONObject: value))
            initialPolicy = try PlanningPolicy(timeZoneID: decoded.timeZoneID, revision: decoded.revision)
        } else { initialPolicy = nil }
        return ArchiveMetadata(workspace: workspace, epoch: epoch, scopes: allScopes, policy: initialPolicy)
    }

    private static func scopeFingerprint(_ configuration: StoreConfiguration) -> String {
        guard let scope = configuration.cloudSync?.accountScope else { return "local-only" }
        return "account-\((try? CanonicalDigest.hash(scope)) ?? "unverified")"
    }

    private static func requiresAccountConfirmation(_ scopes: [String], configuration: StoreConfiguration) -> Bool {
        let own = scopeFingerprint(configuration)
        return scopes.contains { $0 != own }
    }

    private func storedIdentity() throws -> StorageIdentity {
        do {
            return try JSONDecoder().decode(StorageIdentity.self, from: Data(contentsOf: configuration.directory.appendingPathComponent("StorageIdentity.json")))
        } catch { throw StoreError.classify(error) }
    }

    private func preserveOriginScopes(_ scopes: [String]) throws {
        let old = try storedIdentity()
        let updated = StorageIdentity(workspaceKey: old.workspaceKey, workspaceEpoch: old.workspaceEpoch,
            accountScope: old.accountScope, bootstrapPolicy: old.bootstrapPolicy, writerGeneration: old.writerGeneration,
            isTransitioning: old.isTransitioning,
            originAccountScopeFingerprints: Array(Set((old.originAccountScopeFingerprints ?? []) + scopes)).sorted())
        try CanonicalDigest.data(updated).write(to: configuration.directory.appendingPathComponent("StorageIdentity.json"), options: .atomic)
    }

    private static func parseArchive(_ data: Data, configuration: StoreConfiguration, allowForeignWorkspace: Bool = false) throws -> [StoredOperation] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["formatVersion"] as? Int == 1 else { throw StoreError.incompatibleArchive }
        guard let workspace = root["workspaceKey"] as? String, !workspace.isEmpty,
              let epoch = root["workspaceEpoch"] as? String, !epoch.isEmpty else { throw StoreError.incompatibleArchive }
        if !allowForeignWorkspace {
            guard workspace == configuration.workspaceKey else { throw StoreError.workspaceMismatch }
            guard epoch == configuration.workspaceEpoch else { throw StoreError.obsoleteEpoch }
        }
        if let raw = root["rawOperations"] as? [[String: Any]] {
            return try raw.map { entry in
                guard let id = entry["operationID"] as? String, !id.isEmpty,
                      let digest = entry["payloadDigest"] as? String, !digest.isEmpty,
                      let base64 = entry["payloadBase64"] as? String, let payload = Data(base64Encoded: base64),
                      let schema = entry["schemaVersion"] as? Int,
                      let lamport = entry["lamport"] as? Int64,
                      let key = entry["workspaceKey"] as? String, !key.isEmpty,
                      let rowEpoch = entry["workspaceEpoch"] as? String, !rowEpoch.isEmpty,
                      let ids = entry["taskIDs"] as? [String] else { throw StoreError.incompatibleArchive }
                guard (key == workspace && rowEpoch == epoch) || entry["quarantined"] as? Bool == true else {
                    throw StoreError.incompatibleArchive
                }
                return try Self.validateArchiveRow(StoredOperation(operationID: id, payloadDigest: digest, payload: payload,
                    taskIDs: ids, workspaceKey: key, workspaceEpoch: rowEpoch, schemaVersion: schema,
                    idempotencyKey: entry["idempotencyKey"] as? String,
                    requestDigest: entry["requestDigest"] as? String, lamport: lamport))
            }
        }
        guard let operations = root["operations"] as? [[String: Any]] else { throw StoreError.incompatibleArchive }
        return try operations.map { entry in
            guard let id = entry["operationID"] as? String, !id.isEmpty,
                  let digest = entry["payloadDigest"] as? String, !digest.isEmpty,
                  let schema = entry["schemaVersion"] as? Int,
                  let lamport = entry["lamport"] as? Int64,
                  entry["workspaceKey"] as? String == workspace,
                  entry["workspaceEpoch"] as? String == epoch else { throw StoreError.incompatibleArchive }
            let ids = (entry["mutations"] as? [[String: Any]] ?? []).compactMap { $0["taskID"] as? String }
            return try Self.validateArchiveRow(StoredOperation(operationID: id, payloadDigest: digest,
                payload: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]),
                taskIDs: ids, workspaceKey: workspace, workspaceEpoch: epoch,
                schemaVersion: schema, idempotencyKey: entry["idempotencyKey"] as? String,
                requestDigest: entry["logicalCommandDigest"] as? String, lamport: lamport))
        }
    }

    private static func importCounts(_ incoming: [StoredOperation], existing: [StoredOperation]) -> ImportReport {
        var contents = Dictionary(grouping: existing, by: \.operationID).mapValues { Set($0.map(Self.rowFingerprint)) }
        var inserted = 0, duplicates = 0, quarantined = 0
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        for row in incoming {
            let fingerprint = rowFingerprint(row)
            if contents[row.operationID]?.contains(fingerprint) == true { duplicates += 1; continue }
            var isQuarantined = contents[row.operationID] != nil
            if let record = try? decoder.decode(OperationRecord.self, from: row.payload) {
                if record.schemaVersion != 1 || (try? record.computedDigest()) != record.payloadDigest { isQuarantined = true }
            } else { isQuarantined = true }
            if isQuarantined { quarantined += 1 }
            inserted += 1
            contents[row.operationID, default: []].insert(fingerprint)
        }
        return ImportReport(inserted: inserted, duplicates: duplicates, quarantined: quarantined)
    }

    private static func validateArchiveRow(_ row: StoredOperation) throws -> StoredOperation {
        guard row.taskIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw StoreError.incompatibleArchive }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        if let operation = try? decoder.decode(OperationRecord.self, from: row.payload),
           !matchesMetadata(row, operation: operation) { throw StoreError.incompatibleArchive }
        return row
    }

    private static func rowFingerprint(_ row: StoredOperation) -> String {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let content: String
        if let operation = try? decoder.decode(OperationRecord.self, from: row.payload), let calculated = try? operation.computedDigest() {
            content = calculated
        } else { content = (try? CanonicalDigest.hash(row.payload)) ?? "invalid-payload" }
        return "\(row.operationID):\(row.payloadDigest):\(content)"
    }

    /// 원본 전체 재생은 쓰기 게이트 밖에서 수행한다. importer와 동시에 들어온 원본은 다음 history 소비로 반영한다.
    public func rebuild() async throws {
        for _ in 0..<4 {
        try assertIdentity()
        let cursor = try await persistence.historyCursor()
        let raw = try await persistence.operations()
        let decoded = Self.decode(raw, configuration: configuration)
        let report = TaskReducer.reduce(decoded.records, workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
        let projected = Self.restrictUnsupportedTasks(report.tasks, unknownTaskIDs: decoded.unknownTaskIDs)
        let lease = try await gate.acquire()
        defer { lease.release() }
        try assertIdentity()
        if try await persistence.historyChanges(after: cursor).changed {
            lease.release()
            continue // 게이트를 기다리는 사이 저장된 최신 원본으로 다시 계산한다.
        }
        let restoredPolicy: PlanningPolicy
        if let setting = report.settings { restoredPolicy = setting }
        else if let bootstrap = identity.bootstrapPolicy { restoredPolicy = bootstrap }
        else { restoredPolicy = try PlanningPolicy(timeZoneID: configuration.initialTimeZoneID, revision: configuration.initialPolicyRevision) }
        try await persistence.saveProjection(try Self.projectionValues(tasks: projected, policy: restoredPolicy), replacingTasks: true)
        tasks = projected; records = decoded.records; policy = restoredPolicy
        unknownIDs = decoded.unknownIDs; pending = report.pending; quarantined = report.quarantined
        historyCursor = cursor
        return
        }
        throw StoreError.busy
    }

    private func refresh() async throws {
        for _ in 0..<4 {
        let changes: HistoryBatch
        do { changes = try await persistence.historyChanges(after: historyCursor) }
        catch { try await rebuild(); return } // 캐시 token 손상은 원본에서 복원한다.
        guard changes.changed else { return }
        let raw = try await relatedOperations(taskIDs: changes.taskIDs)
        let decoded = Self.decode(raw, configuration: configuration)
        let report = TaskReducer.reduce(decoded.records, workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
        let lease = try await gate.acquire()
        defer { lease.release() }
        try assertIdentity()
        if try await persistence.historyChanges(after: changes.cursor).changed {
            lease.release()
            continue // 오래된 투영으로 최신 명령 결과를 덮어쓰지 않는다.
        }
        let changedTasks = Self.restrictUnsupportedTasks(report.tasks, unknownTaskIDs: decoded.unknownTaskIDs)
        let affectedIDs = changes.taskIDs.union(raw.flatMap(\.taskIDs))
        for id in affectedIDs.compactMap(UUID.init(uuidString:)) { tasks.removeValue(forKey: id) }
        for (id, task) in changedTasks { tasks[id] = task }
        policy = report.settings ?? policy
        mergeRecords(decoded.records)
        unknownIDs.formUnion(decoded.unknownIDs)
        let replayedIDs = Set(raw.map(\.operationID))
        for id in replayedIDs { pending.removeValue(forKey: id); quarantined.removeValue(forKey: id) }
        pending.merge(report.pending) { _, new in new }
        quarantined.merge(report.quarantined) { _, new in new }
        try await persistence.saveProjection(try Self.projectionValues(tasks: changedTasks, policy: policy), removingTaskIDs: affectedIDs)
        historyCursor = changes.cursor
        if let cursor = changes.cursor { try await persistence.setLocalValue(cursor, key: "checkpoint:history") }
        return
        }
        throw StoreError.busy
    }

    private func projectAffected(by operation: OperationRecord) async throws -> Bool {
        let raw = try await relatedOperations(taskIDs: Set(operation.affectedTaskIDs.map(\.uuidString)))
        let decoded = Self.decode(raw, configuration: configuration)
        let report = TaskReducer.reduce(decoded.records, workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
        let updated = Self.restrictUnsupportedTasks(report.tasks, unknownTaskIDs: decoded.unknownTaskIDs)
        try await persistence.saveProjection(try Self.projectionValues(tasks: updated, policy: report.settings ?? policy))
        for (id, task) in updated { tasks[id] = task }
        policy = report.settings ?? policy
        mergeRecords(decoded.records)
        return report.appliedOperationIDs.contains(operation.operationID) &&
            operation.affectedTaskIDs.allSatisfy { updated[$0]?.isProjectionComplete == true }
    }

    private func affectedTaskIDs(_ payload: CommandPayload) async throws -> Set<String> {
        switch payload {
        case let .capture(id, _), let .completion(id, _, _), let .setDeadline(id, _, _),
             let .editContent(id, _, _), let .park(id, _), let .trash(id, _), let .restore(id, _, _):
            return [id.uuidString]
        case let .setPlan(item, _, _): return [item.taskID.uuidString]
        case let .batchSetPlan(items, _): return Set(items.map { $0.taskID.uuidString })
        case let .undo(id, _): return Set(try await persistence.operation(operationID: id).flatMap(\.taskIDs))
        case .reviewClose, .settings: return []
        }
    }

    private func relatedOperations(taskIDs: Set<String>) async throws -> [StoredOperation] {
        var related = taskIDs
        while true {
            let raw = try await persistence.operations(taskIDs: related)
            let expanded = related.union(raw.flatMap(\.taskIDs))
            if expanded == related { return raw }
            related = expanded // batch 원본의 일부만 재생하지 않는다.
        }
    }

    private func mergeRecords(_ new: [OperationRecord]) {
        let ids = Set(new.map(\.operationID))
        records.removeAll { ids.contains($0.operationID) }
        records.append(contentsOf: new)
    }

    private func assertIdentity() throws {
        guard !deleted else { throw StoreError.obsoleteEpoch }
        let current = try storedIdentity()
        guard current.workspaceKey == identity.workspaceKey else { throw StoreError.workspaceMismatch }
        guard current.workspaceEpoch == identity.workspaceEpoch else { throw StoreError.obsoleteEpoch }
        guard current.accountScope == identity.accountScope else { throw StoreError.accountScopeMismatch }
        guard current.writerGeneration == identity.writerGeneration, current.isTransitioning != true else { throw StoreError.obsoleteEpoch }
    }

    private static func prepareDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            #endif
        } catch { throw StoreError.classify(error) }
    }

    private static func stored(_ operation: OperationRecord) throws -> StoredOperation {
        StoredOperation(operationID: operation.operationID, payloadDigest: operation.payloadDigest,
                        payload: try CanonicalDigest.data(operation), taskIDs: operation.affectedTaskIDs.map(\.uuidString),
                        workspaceKey: operation.workspaceKey, workspaceEpoch: operation.workspaceEpoch,
                        schemaVersion: operation.schemaVersion, idempotencyKey: operation.idempotencyKey,
                        requestDigest: operation.logicalCommandDigest, lamport: operation.lamport)
    }

    private static func decode(_ raw: [StoredOperation], configuration: StoreConfiguration) -> DecodedOperations {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var records: [OperationRecord] = []
        var unknown: Set<String> = []
        var unknownTasks: Set<UUID> = []
        for row in raw {
            guard row.workspaceKey == configuration.workspaceKey, row.workspaceEpoch == configuration.workspaceEpoch else {
                unknown.insert(row.operationID); continue // 구세대 원본은 새 작업의 활성 상태를 오염시키지 않는다.
            }
            guard
                  let operation = try? decoder.decode(OperationRecord.self, from: row.payload),
                  Self.matchesMetadata(row, operation: operation) else {
                unknown.insert(row.operationID); unknownTasks.formUnion(row.taskIDs.compactMap(UUID.init(uuidString:))); continue
            }
            records.append(operation)
            if operation.schemaVersion != 1 {
                unknown.insert(row.operationID); unknownTasks.formUnion(operation.affectedTaskIDs)
            }
        }
        return DecodedOperations(records: records, unknownIDs: unknown, unknownTaskIDs: unknownTasks)
    }

    private static func matchesMetadata(_ row: StoredOperation, operation: OperationRecord) -> Bool {
        row.operationID == operation.operationID && row.payloadDigest == operation.payloadDigest &&
        row.workspaceKey == operation.workspaceKey && row.workspaceEpoch == operation.workspaceEpoch &&
        row.schemaVersion == operation.schemaVersion && row.lamport == operation.lamport &&
        row.idempotencyKey == operation.idempotencyKey && row.requestDigest == operation.logicalCommandDigest &&
        Set(row.taskIDs) == Set(operation.affectedTaskIDs.map(\.uuidString))
    }

    private static func restrictUnsupportedTasks(_ tasks: [UUID: TaskProjection], unknownTaskIDs: Set<UUID>) -> [UUID: TaskProjection] {
        tasks.mapValues { task in
            guard unknownTaskIDs.contains(task.taskID) else { return task }
            return TaskProjection(taskID: task.taskID, workspaceKey: task.workspaceKey, workspaceEpoch: task.workspaceEpoch,
                content: task.content, plan: task.plan, lifecycle: task.lifecycle, deadline: task.deadline, createdAt: task.createdAt,
                versions: task.versions, conflictGroups: task.conflictGroups, isProjectionComplete: false)
        }
    }

    private static func projectionValues(tasks: [UUID: TaskProjection], policy: PlanningPolicy) throws -> [String: Data] {
        var values = try Dictionary(uniqueKeysWithValues: tasks.values.map { ("task:\($0.taskID.uuidString)", try CanonicalDigest.data($0)) })
        values["policy"] = try CanonicalDigest.data(policy)
        return values
    }

    private static func precedes(_ lhs: OperationRecord, _ rhs: OperationRecord) -> Bool {
        if lhs.lamport != rhs.lamport { return lhs.lamport < rhs.lamport }
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID.uuidString < rhs.deviceID.uuidString }
        return lhs.operationID < rhs.operationID
    }

    private static func failure(_ envelope: CommandEnvelope, state: CommandResultState, message: String) -> CommandResult {
        CommandResult(requestID: envelope.requestID, state: state, safeUserMessage: message)
    }
}

private struct DecodedOperations: Sendable {
    let records: [OperationRecord]
    let unknownIDs: Set<String>
    let unknownTaskIDs: Set<UUID>
}

private struct ArchiveMetadata: Sendable {
    let workspace: String
    let epoch: String
    let scopes: [String]
    let policy: PlanningPolicy?
}
