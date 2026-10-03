@preconcurrency import CoreData
import Darwin
import Foundation
import MirrorDomain
@testable import MirrorData
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

private func openLegacyRecoveryStore(at url: URL, model: NSManagedObjectModel,
                                     readOnly: Bool = false) async throws -> NSPersistentContainer {
    let container = NSPersistentContainer(name: "RecoveryFixture", managedObjectModel: model)
    let description = NSPersistentStoreDescription(url: url)
    description.type = NSSQLiteStoreType
    description.shouldMigrateStoreAutomatically = false
    description.setOption(readOnly as NSNumber, forKey: NSReadOnlyPersistentStoreOption)
    description.setOption(["journal_mode": "WAL"] as NSDictionary, forKey: NSSQLitePragmasOption)
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

@Suite("손상 projection 격리와 migration 원본 보존", .serialized)
struct PersistenceRecoveryTests {
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
