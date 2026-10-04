@preconcurrency import CoreData
import Darwin
import Foundation
import MirrorDomain
@testable import MirrorData
import SQLite3
import Testing

private struct RecoveryMarker: Codable {
    let schemaVersion: Int
    let recoveredAt: Date
}

private func recoveryConfiguration() -> StoreConfiguration {
    StoreConfiguration(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("MirrorRecoveryTests-\(UUID().uuidString)", isDirectory: true),
        deviceID: "11111111-1111-4111-8111-111111111111")
}

private func recoveryContext() throws -> PlanningContext {
    let instant = try #require(ISO8601DateFormatter().date(from: "2026-10-01T03:00:00Z"))
    return try PlanningContext(planningDay: LocalDate("2026-10-01"), timeZoneID: "Asia/Seoul", policyRevision: "policy-v1",
        capturedAt: instant)
}

private func recoveryChildren(in directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
}

private func recoveryAttribute(_ name: String, type: NSAttributeType, optional: Bool = false,
                               defaultValue: Any? = nil) -> NSAttributeDescription {
    let value = NSAttributeDescription()
    value.name = name; value.attributeType = type; value.isOptional = optional; value.defaultValue = defaultValue
    return value
}

/// 실제 SQLite의 이전 모델이다. 현재 모델과 payload 형식도 다르게 만들 수 있다.
private func legacyRecoveryModel(payloadType: NSAttributeType = .binaryDataAttributeType) -> NSManagedObjectModel {
    let entity = NSEntityDescription()
    entity.name = "Operation"; entity.managedObjectClassName = "NSManagedObject"
    entity.properties = [
        recoveryAttribute("recordID", type: .stringAttributeType, defaultValue: ""),
        recoveryAttribute("operationID", type: .stringAttributeType, defaultValue: ""),
        recoveryAttribute("payloadDigest", type: .stringAttributeType, defaultValue: ""),
        recoveryAttribute("payload", type: payloadType),
        recoveryAttribute("taskIndex", type: .stringAttributeType, defaultValue: ""),
        recoveryAttribute("workspaceKey", type: .stringAttributeType, defaultValue: ""),
        recoveryAttribute("workspaceEpoch", type: .stringAttributeType, defaultValue: ""),
        recoveryAttribute("schemaVersion", type: .integer64AttributeType, defaultValue: 1),
        recoveryAttribute("lamport", type: .integer64AttributeType, defaultValue: 0),
        recoveryAttribute("idempotencyKey", type: .stringAttributeType, optional: true),
        recoveryAttribute("insertedAt", type: .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0))
        // requestDigestを追加する以前のモデル。
    ]
    let model = NSManagedObjectModel(); model.entities = [entity]
    return model
}

/// 인덱스 도입 직전의 모델을 고정한다. requestDigest와 Data() 기본값도 실제 기존 모델과 같다.
private func preIndexRecoveryModel(canonical: Bool, unversionedIndexes: Bool = false) -> NSManagedObjectModel {
    func entity(_ name: String, _ attributes: [NSAttributeDescription]) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name; entity.managedObjectClassName = "NSManagedObject"; entity.properties = attributes
        return entity
    }
    func string(_ name: String, optional: Bool = false) -> NSAttributeDescription {
        recoveryAttribute(name, type: .stringAttributeType, optional: optional, defaultValue: optional ? nil : "")
    }
    func binary(_ name: String) -> NSAttributeDescription {
        recoveryAttribute(name, type: .binaryDataAttributeType, defaultValue: Data())
    }
    let model = NSManagedObjectModel()
    if canonical {
        model.entities = [entity("Operation", [
            string("recordID"), string("operationID"), string("payloadDigest"), binary("payload"),
            string("taskIndex"), string("workspaceKey"), string("workspaceEpoch"),
            recoveryAttribute("schemaVersion", type: .integer64AttributeType, defaultValue: Int64(1)),
            recoveryAttribute("lamport", type: .integer64AttributeType, defaultValue: Int64(0)),
            string("idempotencyKey", optional: true), string("requestDigest", optional: true),
            recoveryAttribute("insertedAt", type: .dateAttributeType, defaultValue: Date(timeIntervalSince1970: 0))
        ])]
    } else {
        model.entities = [entity("CacheValue", [string("key"), binary("value")]),
                          entity("Receipt", [string("key"), string("digest"), string("operationID"), binary("result")])]
    }
    if unversionedIndexes {
        let indexes: [String: [(String, [String])]] = [
            "Operation": [("OperationByID", ["operationID"]),
                          ("OperationByDecision", ["workspaceKey", "workspaceEpoch", "idempotencyKey"]),
                          ("OperationByLamport", ["workspaceKey", "workspaceEpoch", "lamport"])],
            "CacheValue": [("CacheValueByKey", ["key"])], "Receipt": [("ReceiptByKey", ["key"])]
        ]
        for entity in model.entities {
            entity.indexes = (indexes[entity.name ?? ""] ?? []).map { name, properties in
                let elements = properties.map { name in
                    guard let property = entity.propertiesByName[name] else { preconditionFailure("fixture index property") }
                    return NSFetchIndexElementDescription(property: property, collationType: .binary)
                }
                return NSFetchIndexDescription(name: name, elements: elements)
            }
        }
    }
    return model
}

private func openLegacyRecoveryStore(at url: URL, model: NSManagedObjectModel,
                                     readOnly: Bool = false, historyTracking: Bool = false) async throws -> NSPersistentContainer {
    let container = NSPersistentContainer(name: "RecoveryFixture", managedObjectModel: model)
    let description = NSPersistentStoreDescription(url: url)
    description.type = NSSQLiteStoreType
    description.shouldMigrateStoreAutomatically = false
    description.setOption(readOnly as NSNumber, forKey: NSReadOnlyPersistentStoreOption)
    description.setOption(["journal_mode": "WAL"] as NSDictionary, forKey: NSSQLitePragmasOption)
    if historyTracking {
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
    }
    container.persistentStoreDescriptions = [description]
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        container.loadPersistentStores { _, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
    return container
}

private func closeLegacyRecoveryStore(_ container: NSPersistentContainer) throws {
    for store in container.persistentStoreCoordinator.persistentStores {
        try container.persistentStoreCoordinator.remove(store)
    }
}

private func insertLegacyRecoveryOperation(in container: NSPersistentContainer, payload: Data) async throws {
    let context = container.newBackgroundContext()
    try await context.perform {
        let row = NSEntityDescription.insertNewObject(forEntityName: "Operation", into: context)
        row.setValue(UUID().uuidString, forKey: "recordID")
        row.setValue("original-operation", forKey: "operationID")
        row.setValue("original-digest", forKey: "payloadDigest")
        row.setValue(payload, forKey: "payload")
        row.setValue("personal-v1", forKey: "workspaceKey")
        row.setValue("local-v1", forKey: "workspaceEpoch")
        row.setValue(Date(timeIntervalSince1970: 0), forKey: "insertedAt")
        try context.save()
    }
}

private func legacyRecoveryPayload(in container: NSPersistentContainer) async throws -> Data? {
    let context = container.newBackgroundContext()
    return try await context.perform {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Operation")
        request.predicate = NSPredicate(format: "operationID == %@", "original-operation")
        return try context.fetch(request).first?.value(forKey: "payload") as? Data
    }
}

private func insertLegacyStringPayload(in container: NSPersistentContainer) async throws {
    let context = container.newBackgroundContext()
    try await context.perform {
        let row = NSEntityDescription.insertNewObject(forEntityName: "Operation", into: context)
        row.setValue("migration-original", forKey: "operationID")
        row.setValue("retain this original payload", forKey: "payload")
        row.setValue(Date(timeIntervalSince1970: 0), forKey: "insertedAt")
        try context.save()
    }
}

private func indexedRecoveryOperations(configuration: StoreConfiguration) throws -> [StoredOperation] {
    let deviceID = try #require(UUID(uuidString: configuration.deviceID))
    let taskID = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
    let otherTaskID = try #require(UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
    let instant = try recoveryContext().capturedAt
    func record(_ id: String, task: UUID? = nil, schema: Int = 1, workspace: String? = nil,
                epoch: String? = nil, lamport: Int64, decision: String? = "fixture-decision") throws -> StoredOperation {
        let operation = try OperationRecord.create(operationID: id, schemaVersion: schema,
            workspaceKey: workspace ?? configuration.workspaceKey, workspaceEpoch: epoch ?? configuration.workspaceEpoch,
            deviceID: deviceID, lamport: lamport, recordedAt: instant, commandKind: .capture,
            mutations: [TaskMutation(taskID: task ?? taskID, value: .content(try TaskContent(title: "인덱스 원본 보존 fixture")))],
            idempotencyKey: decision, logicalCommandDigest: decision.map { "request-\($0)-\(lamport)" })
        return StoredOperation(operationID: operation.operationID, payloadDigest: operation.payloadDigest,
            payload: try CanonicalDigest.data(operation), taskIDs: operation.affectedTaskIDs.map(\.uuidString),
            workspaceKey: operation.workspaceKey, workspaceEpoch: operation.workspaceEpoch, schemaVersion: operation.schemaVersion,
            idempotencyKey: operation.idempotencyKey, requestDigest: operation.logicalCommandDigest, lamport: operation.lamport)
    }
    let original = try record("fixture-collision", lamport: 10)
    return [original, original, // 같은 원문을 가진 물리 행 두 개도 유지해야 한다.
            try record("fixture-collision", task: otherTaskID, lamport: 11),
            try record("fixture-unsupported", schema: 99, lamport: 4_000, decision: nil),
            try record("fixture-foreign-workspace", workspace: "foreign-workspace", lamport: Int64.max),
            try record("fixture-foreign-epoch", epoch: "foreign-epoch", lamport: Int64.max)]
}

private func seedPreIndexRecoveryStores(configuration: StoreConfiguration, operations: [StoredOperation],
                                        preferences: Data, receipt: StoredReceipt, unversionedIndexes: Bool = false) async throws {
    let canonical = try await openLegacyRecoveryStore(at: configuration.directory.appendingPathComponent("Canonical.sqlite"),
        model: preIndexRecoveryModel(canonical: true, unversionedIndexes: unversionedIndexes), historyTracking: true)
    defer { try? closeLegacyRecoveryStore(canonical) }
    let writeCanonical = canonical.newBackgroundContext()
    try await writeCanonical.perform {
        for operation in operations {
            let row = NSEntityDescription.insertNewObject(forEntityName: "Operation", into: writeCanonical)
            row.setValue(UUID().uuidString, forKey: "recordID")
            row.setValue(operation.operationID, forKey: "operationID")
            row.setValue(operation.payloadDigest, forKey: "payloadDigest")
            row.setValue(operation.payload, forKey: "payload")
            row.setValue(operation.taskIDs.sorted().map { "|\($0)|" }.joined(), forKey: "taskIndex")
            row.setValue(operation.workspaceKey, forKey: "workspaceKey")
            row.setValue(operation.workspaceEpoch, forKey: "workspaceEpoch")
            row.setValue(Int64(operation.schemaVersion), forKey: "schemaVersion")
            row.setValue(operation.lamport, forKey: "lamport")
            row.setValue(operation.idempotencyKey, forKey: "idempotencyKey")
            row.setValue(operation.requestDigest, forKey: "requestDigest")
            row.setValue(Date(timeIntervalSince1970: 1_791_000_000), forKey: "insertedAt")
        }
        try writeCanonical.save()
    }
    let projection = try await openLegacyRecoveryStore(at: configuration.directory.appendingPathComponent("LocalProjection.sqlite"),
        model: preIndexRecoveryModel(canonical: false, unversionedIndexes: unversionedIndexes), historyTracking: true)
    defer { try? closeLegacyRecoveryStore(projection) }
    let writeProjection = projection.newBackgroundContext()
    try await writeProjection.perform {
        let preferenceRow = NSEntityDescription.insertNewObject(forEntityName: "CacheValue", into: writeProjection)
        preferenceRow.setValue("local:system-preferences-v1", forKey: "key")
        preferenceRow.setValue(preferences, forKey: "value")
        let receiptRow = NSEntityDescription.insertNewObject(forEntityName: "Receipt", into: writeProjection)
        receiptRow.setValue(receipt.key, forKey: "key")
        receiptRow.setValue(receipt.digest, forKey: "digest")
        receiptRow.setValue(receipt.operationID, forKey: "operationID")
        receiptRow.setValue(receipt.result, forKey: "result")
        try writeProjection.save()
    }
    try closeLegacyRecoveryStore(projection)
    try closeLegacyRecoveryStore(canonical)
}

private func recoveryOperationMultiset(_ operations: [StoredOperation]) throws -> [Data: Int] {
    var counts: [Data: Int] = [:]
    for operation in operations { counts[try CanonicalDigest.data(operation), default: 0] += 1 }
    return counts
}

private struct RecoverySQLiteIndex {
    let columns: [String]
    let unique: Bool
    let partial: Bool
}

private struct RecoverySQLiteTable {
    let columns: Set<String>
    let indexes: [RecoverySQLiteIndex]
}

/// 이 helper는 schema만 읽는다. 오류에도 원문 payload나 SQLite 전체 메시지를 출력하지 않는다.
private func recoverySchemaRows(_ database: OpaquePointer, sql: String) throws -> [[String]] {
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard prepared == SQLITE_OK, let statement else {
        if let statement { sqlite3_finalize(statement) }
        throw NSError(domain: "MirrorRecoverySchemaInspection", code: Int(prepared))
    }
    defer { sqlite3_finalize(statement) }
    var rows: [[String]] = []
    while true {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return rows }
        guard status == SQLITE_ROW else { throw NSError(domain: "MirrorRecoverySchemaInspection", code: Int(status)) }
        rows.append((0..<sqlite3_column_count(statement)).map { column in
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        })
    }
}

private func recoverySQLiteSchema(at url: URL) throws -> [RecoverySQLiteTable] {
    var connection: OpaquePointer?
    let opened = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil)
    guard opened == SQLITE_OK, let connection else {
        if let connection { sqlite3_close(connection) }
        throw NSError(domain: "MirrorRecoverySchemaInspection", code: Int(opened))
    }
    defer { sqlite3_close(connection) }
    func quoted(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    let tables = try recoverySchemaRows(connection, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    return try tables.map { table in
        let name = try #require(table.first)
        let columnRows = try recoverySchemaRows(connection, sql: "PRAGMA table_info(\(quoted(name)))")
        let columns = try Set(columnRows.map { row in
            try #require(row.count > 1)
            return row[1].uppercased()
        })
        let indexRows = try recoverySchemaRows(connection, sql: "PRAGMA index_list(\(quoted(name)))")
        let indexes = try indexRows.map { row in
            try #require(row.count > 4)
            let elements = try recoverySchemaRows(connection, sql: "PRAGMA index_info(\(quoted(row[1])))")
            let ordered = try elements.map { element -> (Int, String) in
                try #require(element.count > 2)
                return (try #require(Int(element[0])), element[2].uppercased())
            }.sorted { $0.0 < $1.0 }.map(\.1)
            return RecoverySQLiteIndex(columns: ordered, unique: row[2] != "0", partial: row[4] != "0")
        }
        return RecoverySQLiteTable(columns: columns, indexes: indexes)
    }
}

/// 현재 SDK가 만든 fixture의 schema를 관측한다. Core Data의 SQL 테이블명·자동 인덱스명은 고정하지 않는다.
private func expectRecoveryPhysicalIndexes(in directory: URL, installed: Bool) throws {
    let canonical = try recoverySQLiteSchema(at: directory.appendingPathComponent("Canonical.sqlite"))
    let projection = try recoverySQLiteSchema(at: directory.appendingPathComponent("LocalProjection.sqlite"))
    let operation = try #require(canonical.first { $0.columns.isSuperset(of: ["ZOPERATIONID", "ZPAYLOADDIGEST", "ZTASKINDEX"]) })
    let cache = try #require(projection.first { $0.columns.isSuperset(of: ["ZKEY", "ZVALUE"]) })
    let receipt = try #require(projection.first { $0.columns.isSuperset(of: ["ZKEY", "ZDIGEST", "ZRESULT"]) })
    let requirements: [(RecoverySQLiteTable, [String])] = [
        (operation, ["ZOPERATIONID"]),
        (operation, ["ZWORKSPACEKEY", "ZWORKSPACEEPOCH", "ZIDEMPOTENCYKEY"]),
        (operation, ["ZWORKSPACEKEY", "ZWORKSPACEEPOCH", "ZLAMPORT"]),
        (cache, ["ZKEY"]), (receipt, ["ZKEY"])
    ]
    for (table, columns) in requirements {
        let found = table.indexes.contains { $0.columns == columns && !$0.unique && !$0.partial }
        #expect(found == installed, "실제 SQLite의 비고유 전체 인덱스 및 열 순서: \(columns)")
    }
}

@Suite("손상 projection 격리와 migration 원본 보존", .serialized)
struct PersistenceRecoveryTests {
    @Test("새 저장소와 인덱스 이전 저장소는 첫 개설·재개설에 실제 인덱스와 모든 원문·로컬 값을 보존한다",
          arguments: [false, true])
    func physicalIndexesPreserveExistingRows(preExisting: Bool) async throws {
        try await checkPhysicalIndexesPreserveExistingRows(preExisting: preExisting)
    }

    @Test("버전 표식 없이 이미 인덱스를 만든 저장소도 공식 migration 이후 원문과 로컬 값을 보존한다")
    func unversionedIndexesPreserveExistingRows() async throws {
        try await checkPhysicalIndexesPreserveExistingRows(preExisting: true, unversionedIndexes: true)
    }

    private func checkPhysicalIndexesPreserveExistingRows(preExisting: Bool, unversionedIndexes: Bool = false) async throws {
        let configuration = recoveryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        let operations = try indexedRecoveryOperations(configuration: configuration)
        let expectedRows = try recoveryOperationMultiset(operations)
        let preferences = Data(#"{"planningTimeZoneID":"Asia/Seoul","hideExternalTitles":true,"selectedCalendarIDs":["fixture-calendar"]}"#.utf8)
        let receipt = StoredReceipt(key: "fixture-receipt", digest: "fixture-digest", operationID: "fixture-collision",
            result: Data(#"{"state":"locallyCommitted","requestID":"fixture-request"}"#.utf8))
        let canonicalURL = configuration.directory.appendingPathComponent("Canonical.sqlite")
        let metadataOptions: [AnyHashable: Any] = [NSReadOnlyPersistentStoreOption: true]
        var previousHashes: [String: Data]?
        if preExisting {
            try await seedPreIndexRecoveryStores(configuration: configuration, operations: operations,
                preferences: preferences, receipt: receipt, unversionedIndexes: unversionedIndexes)
            try expectRecoveryPhysicalIndexes(in: configuration.directory, installed: unversionedIndexes)
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType, at: canonicalURL, options: metadataOptions)
            previousHashes = try #require(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
        }
        for opening in 0..<2 {
            let persistence = try await CoreDataPersistence.open(configuration: configuration)
            do {
                if !preExisting && opening == 0 {
                    try await persistence.appendMany(operations)
                    try await persistence.saveProjection(["local:system-preferences-v1": preferences], receipt: receipt)
                }
                let restored = try await persistence.operations()
                // Bool만 진단하여 실패 로그에도 raw payload를 출력하지 않는다. Set 비교는 물리 중복을 놓친다.
                let originalsMatch = try recoveryOperationMultiset(restored) == expectedRows
                #expect(originalsMatch)
                #expect(restored.count == 6)
                let collisions = try await persistence.operation(operationID: "fixture-collision")
                let collisionsMatch = try recoveryOperationMultiset(collisions) == recoveryOperationMultiset(Array(operations.prefix(3)))
                #expect(collisionsMatch)
                let decisions = try await persistence.operation(idempotencyKey: "fixture-decision",
                    workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
                let decisionsMatch = try recoveryOperationMultiset(decisions) == recoveryOperationMultiset(Array(operations.prefix(3)))
                #expect(decisionsMatch)
                #expect(try await persistence.maximumLamport(workspaceKey: configuration.workspaceKey,
                    workspaceEpoch: configuration.workspaceEpoch) == 4_000)
                let restoredPreferences = try await persistence.localValue(key: "local:system-preferences-v1")
                let preferencesMatch = restoredPreferences == preferences
                #expect(preferencesMatch)
                let restoredReceipt = try #require(try await persistence.receipt(key: receipt.key))
                let receiptMatches = restoredReceipt.key == receipt.key && restoredReceipt.digest == receipt.digest
                    && restoredReceipt.operationID == receipt.operationID && restoredReceipt.result == receipt.result
                #expect(receiptMatches)
                try await persistence.close()
            } catch {
                try? await persistence.close()
                throw error
            }
            try expectRecoveryPhysicalIndexes(in: configuration.directory, installed: true)
            let backups = try recoveryChildren(in: configuration.directory.appendingPathComponent("MigrationBackups"))
            #expect(backups.count == (preExisting ? 1 : 0))
            if preExisting {
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                    ofType: NSSQLiteStoreType, at: canonicalURL, options: metadataOptions)
                let currentHashes = try #require(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
                let modelVersionChanged = currentHashes != previousHashes
                #expect(modelVersionChanged)
                let backupURL = try #require(backups.first).appendingPathComponent("Canonical.sqlite")
                let backupMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                    ofType: NSSQLiteStoreType, at: backupURL, options: metadataOptions)
                let backupVersionMatches = (backupMetadata[NSStoreModelVersionHashesKey] as? [String: Data]) == previousHashes
                #expect(backupVersionMatches)
                let backup = try await openLegacyRecoveryStore(at: backupURL,
                    model: preIndexRecoveryModel(canonical: true, unversionedIndexes: unversionedIndexes), readOnly: true)
                do {
                    let read = backup.newBackgroundContext()
                    let payloads: [Data] = try await read.perform {
                        try read.fetch(NSFetchRequest<NSManagedObject>(entityName: "Operation")).map { row in
                            let payload = row.value(forKey: "payload") as? Data
                            return try #require(payload)
                        }
                    }
                    let preserved = payloads.reduce(into: [Data: Int]()) { $0[$1, default: 0] += 1 }
                    let originals = operations.reduce(into: [Data: Int]()) { $0[$1.payload, default: 0] += 1 }
                    let backupOriginalsMatch = preserved == originals
                    #expect(backupOriginalsMatch)
                    try closeLegacyRecoveryStore(backup)
                } catch {
                    try? closeLegacyRecoveryStore(backup)
                    throw error
                }
            }
        }
        #expect(try recoveryChildren(in: configuration.directory.appendingPathComponent("ProjectionQuarantine")).isEmpty)
    }

    @Test("물리 cache 손상을 격리하고 canonical에서 재생하며 같은 결정은 중복 저장하지 않는다")
    func corruptProjectionRecovery() async throws {
        let configuration = recoveryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try recoveryContext()
        let command = CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: "recovered-decision", source: .app,
            context: context, workspaceEpoch: configuration.workspaceEpoch,
            payload: .capture(taskID: UUID(), content: try TaskContent(title: "원본에서 복구할 작업")))
        #expect(await store.execute(command, at: context.capturedAt).state == .locallyCommitted)
        let original = try await store.snapshot()
        _ = try await store.exportAndSuspend(exportedAt: context.capturedAt)
        let corrupted = Data("physically corrupt projection SQLite".utf8)
        let projectionURL = configuration.directory.appendingPathComponent("LocalProjection.sqlite")
        try corrupted.write(to: projectionURL, options: .atomic)

        let recovered = try await MirrorStore(configuration: configuration)
        let restored = try await recovered.snapshot()
        #expect(restored.tasks == original.tasks)
        #expect(restored.records == original.records)
        #expect(await recovered.execute(command, at: context.capturedAt).state == .alreadyApplied)
        #expect(try await recovered.snapshot().records.count == 1)
        let directories = try recoveryChildren(in: configuration.directory.appendingPathComponent("ProjectionQuarantine"))
        let quarantine = try #require(directories.first)
        #expect(directories.count == 1)
        #expect(try Data(contentsOf: quarantine.appendingPathComponent("LocalProjection.sqlite")) == corrupted)
        let markerData = try #require(try await recovered.localValue(forKey: "projection-recovery-v1"))
        #expect(try JSONDecoder().decode(RecoveryMarker.self, from: markerData).schemaVersion == 1)
        #expect(!FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent("ProjectionRecoveryPending.json").path))
        _ = try await recovered.exportAndSuspend(exportedAt: context.capturedAt)
    }

    @Test("canonical 물리 손상은 삭제하거나 projection 복구로 숨기지 않는다")
    func canonicalIsNeverQuarantined() async throws {
        let configuration = recoveryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        let canonical = configuration.directory.appendingPathComponent("Canonical.sqlite")
        let corrupted = Data("canonical bytes must be retained".utf8)
        try corrupted.write(to: canonical)
        await #expect(throws: StoreError.self) { _ = try await MirrorStore(configuration: configuration) }
        #expect(try Data(contentsOf: canonical) == corrupted)
        #expect(try recoveryChildren(in: configuration.directory.appendingPathComponent("ProjectionQuarantine")).isEmpty)
        #expect(try recoveryChildren(in: configuration.directory.appendingPathComponent("MigrationBackups")).isEmpty)
    }

    @Test("다른 instance가 projection을 열고 있으면 보류하고 닫힌 뒤에만 격리한다")
    func liveProjectionDefersRecovery() async throws {
        let configuration = recoveryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        let prepared = try await CoreDataPersistence.open(configuration: configuration)
        try await prepared.setLocalValue(Data("existing local cache".utf8), key: "local:fixture")
        try await prepared.close() // schema/fixture의 이전 WAL을 checkpoint하고 reader를 다시 연다.
        let live = try await CoreDataPersistence.open(configuration: configuration)
        let projection = configuration.directory.appendingPathComponent("LocalProjection.sqlite")
        let corrupted = Data("externally damaged projection".utf8)
        try corrupted.write(to: projection, options: .atomic)
        await #expect(throws: StoreError.busy) { _ = try await CoreDataPersistence.open(configuration: configuration) }
        #expect(try Data(contentsOf: projection) == corrupted)
        #expect(try recoveryChildren(in: configuration.directory.appendingPathComponent("ProjectionQuarantine")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent("ProjectionRecoveryPending.json").path))
        try await live.close()
        let recovered = try await CoreDataPersistence.open(configuration: configuration)
        #expect(try recoveryChildren(in: configuration.directory.appendingPathComponent("ProjectionQuarantine")).count == 1)
        #expect(try await recovered.localValue(key: "local:projection-recovery-v1") != nil)
        try await recovered.close()
    }

    @Test("새 cache 저장 전 종료의 pending marker를 다시 개설할 때 반영한다")
    func pendingRecoveryMarkerSurvivesRestart() async throws {
        let configuration = recoveryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        let first = try await CoreDataPersistence.open(configuration: configuration)
        try await first.close()
        let marker = RecoveryMarker(schemaVersion: 1, recoveredAt: Date(timeIntervalSince1970: 1_791_000_000))
        let data = try JSONEncoder().encode(marker)
        let pending = configuration.directory.appendingPathComponent("ProjectionRecoveryPending.json")
        try data.write(to: pending, options: .atomic)
        let reopened = try await CoreDataPersistence.open(configuration: configuration)
        let restoredData = try #require(try await reopened.localValue(key: "local:projection-recovery-v1"))
        let restored = try JSONDecoder().decode(RecoveryMarker.self, from: restoredData)
        #expect(restored.schemaVersion == marker.schemaVersion)
        #expect(restored.recoveredAt == marker.recoveredAt)
        #expect(!FileManager.default.fileExists(atPath: pending.path))
        try await reopened.close()
    }

    @Test("기존 WAL에 저장한 원본도 공식 migration backup에 포함한다")
    func coherentMigrationBackup() async throws {
        let configuration = recoveryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        let sourceURL = configuration.directory.appendingPathComponent("Canonical.sqlite")
        let oldModel = legacyRecoveryModel()
        let source = try await openLegacyRecoveryStore(at: sourceURL, model: oldModel)
        let original = Data("payload in a live WAL transaction".utf8)
        try await insertLegacyRecoveryOperation(in: source, payload: original)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path + "-wal"))
        #expect(try await CoreDataPersistence.backupCanonicalBeforeMigration(at: sourceURL, model: oldModel) == nil)
        #expect(try recoveryChildren(in: configuration.directory.appendingPathComponent("MigrationBackups")).isEmpty)
        let newModel = legacyRecoveryModel()
        let entity = try #require(newModel.entities.first)
        entity.properties.append(recoveryAttribute("requestDigest", type: .stringAttributeType, optional: true))
        let backupURL = try #require(try await CoreDataPersistence.backupCanonicalBeforeMigration(at: sourceURL, model: newModel))
        #expect(try await legacyRecoveryPayload(in: source) == original)
        let backup = try await openLegacyRecoveryStore(at: backupURL, model: oldModel, readOnly: true)
        #expect(try await legacyRecoveryPayload(in: backup) == original)
        try closeLegacyRecoveryStore(backup)
        try closeLegacyRecoveryStore(source)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test("이전 model의 비호환 migration 실패는 원본과 사전 backup을 유지한다")
    func migrationFailurePreservesOriginalAndBackup() async throws {
        let configuration = recoveryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        let sourceURL = configuration.directory.appendingPathComponent("Canonical.sqlite")
        let oldModel = legacyRecoveryModel(payloadType: .stringAttributeType)
        let source = try await openLegacyRecoveryStore(at: sourceURL, model: oldModel)
        try await insertLegacyStringPayload(in: source)
        try closeLegacyRecoveryStore(source)
        let options: [AnyHashable: Any] = [NSReadOnlyPersistentStoreOption: true]
        let before = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: sourceURL, options: options)
        await #expect(throws: StoreError.self) { _ = try await CoreDataPersistence.open(configuration: configuration) }
        let after = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: sourceURL, options: options)
        #expect((after[NSStoreModelVersionHashesKey] as? [String: Data]) == (before[NSStoreModelVersionHashesKey] as? [String: Data]))
        let backups = try recoveryChildren(in: configuration.directory.appendingPathComponent("MigrationBackups"))
        let backupURL = try #require(backups.first).appendingPathComponent("Canonical.sqlite")
        #expect(backups.count == 1)
        for url in [sourceURL, backupURL] {
            let preserved = try await openLegacyRecoveryStore(at: url, model: oldModel, readOnly: true)
            let read = preserved.newBackgroundContext()
            let payload: String? = try await read.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Operation")
                request.predicate = NSPredicate(format: "operationID == %@", "migration-original")
                return try read.fetch(request).first?.value(forKey: "payload") as? String
            }
            #expect(payload == "retain this original payload")
            try closeLegacyRecoveryStore(preserved)
        }
    }

    @Test("사전 backup을 만들 수 없으면 migration을 시작하지 않고 원본을 보존한다")
    func failedBackupPreventsMigration() async throws {
        let configuration = recoveryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        let sourceURL = configuration.directory.appendingPathComponent("Canonical.sqlite")
        let oldModel = legacyRecoveryModel(payloadType: .stringAttributeType)
        let source = try await openLegacyRecoveryStore(at: sourceURL, model: oldModel)
        try await insertLegacyStringPayload(in: source)
        try closeLegacyRecoveryStore(source)
        let options: [AnyHashable: Any] = [NSReadOnlyPersistentStoreOption: true]
        let before = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: sourceURL, options: options)
        let blocked = configuration.directory.appendingPathComponent("MigrationBackups")
        let existing = Data("existing file cannot become a backup directory".utf8)
        try existing.write(to: blocked)
        await #expect(throws: StoreError.self) { _ = try await CoreDataPersistence.open(configuration: configuration) }
        let after = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: sourceURL, options: options)
        #expect((after[NSStoreModelVersionHashesKey] as? [String: Data]) == (before[NSStoreModelVersionHashesKey] as? [String: Data]))
        #expect(try Data(contentsOf: blocked) == existing)
        #expect(!FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent("LocalProjection.sqlite").path))
    }

    @Test("잠금·디스크·권한·모호한 오류를 SQLite 손상으로 오인하지 않는다")
    func nonCorruptionIsNeverQuarantined() {
        let corrupt = NSError(domain: "NSSQLiteErrorDomain", code: 11)
        #expect(CoreDataPersistence.isProjectionCorruption(corrupt))
        #expect(CoreDataPersistence.isProjectionCorruption(NSError(domain: "NSSQLiteErrorDomain", code: 26)))
        #expect(CoreDataPersistence.isProjectionCorruption(NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreOpenError,
            userInfo: ["NSSQLiteErrorDomain": 26])))
        #expect(!CoreDataPersistence.isProjectionCorruption(NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreIncompatibleVersionHashError)))
        for code in [5, 6, 8, 10, 13, 14] {
            let resource = NSError(domain: "NSSQLiteErrorDomain", code: code)
            let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                userInfo: [NSUnderlyingErrorKey: resource])
            #expect(!CoreDataPersistence.isProjectionCorruption(wrapped))
            #expect(!CoreDataPersistence.isProjectionCorruption(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                userInfo: ["NSSQLiteErrorDomain": code])))
        }
        for code in [EACCES, EPERM, ENOSPC, EBUSY, EIO] {
            let resource = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                userInfo: [NSDetailedErrorsKey: [corrupt, resource]])
            #expect(!CoreDataPersistence.isProjectionCorruption(wrapped))
        }
    }
}
