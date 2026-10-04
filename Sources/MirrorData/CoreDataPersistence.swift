@preconcurrency import CoreData
import Foundation
import Darwin

struct StoredOperation: Codable, Sendable {
    let operationID: String
    let payloadDigest: String
    let payload: Data
    let taskIDs: [String]
    let workspaceKey: String
    let workspaceEpoch: String
    let schemaVersion: Int
    let idempotencyKey: String?
    let requestDigest: String?
    let lamport: Int64
}

struct StoredReceipt: Sendable {
    let key: String
    let digest: String
    let operationID: String
    let result: Data
}

/// 컨테이너는 내부에서만 사용한다. NSManagedObject는 각 perform 밖으로 내보내지 않는다.
/// unchecked는 Core Data queue 제약에 한정하며 공개 경계는 Sendable DTO다.
final class CoreDataPersistence: @unchecked Sendable {
    private static let connections = CoreDataConnectionRegistry()
    private static let retainedProjectionLifetimes = RetainedProjectionLifetimes()
    private let canonical: NSPersistentContainer
    private let projection: NSPersistentContainer
    private let changeHub: CanonicalStoreChangeHub
    private let projectionLifetime: ProjectionLifetimeLease

    private init(canonical: NSPersistentContainer, projection: NSPersistentContainer,
                 projectionLifetime: ProjectionLifetimeLease) {
        self.canonical = canonical
        self.projection = projection
        self.projectionLifetime = projectionLifetime
        self.changeHub = CanonicalStoreChangeHub(coordinator: canonical.persistentStoreCoordinator)
    }

    deinit {
        changeHub.finish()
        // container의 지연 정리보다 먼저 lease를 해제하지 않는다.
        for store in projection.persistentStoreCoordinator.persistentStores {
            try? projection.persistentStoreCoordinator.remove(store)
        }
        Self.releaseProjectionLifetime(projectionLifetime, projection: projection)
    }

    static func open(configuration: StoreConfiguration) async throws -> CoreDataPersistence {
        let canonicalModel = model(canonical: true)
        let canonical: NSPersistentContainer
        if let cloud = configuration.cloudSync {
            guard !cloud.containerIdentifier.isEmpty, !cloud.accountScope.isEmpty else {
                throw StoreError.invalidConfiguration
            }
            let container = NSPersistentCloudKitContainer(name: "MirrorCanonical", managedObjectModel: canonicalModel)
            let description = storeDescription(url: configuration.directory.appendingPathComponent("Canonical.sqlite"),
                canonical: true, model: canonicalModel)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: cloud.containerIdentifier)
            container.persistentStoreDescriptions = [description]
            canonical = container
        } else {
            canonical = NSPersistentContainer(name: "MirrorCanonical", managedObjectModel: canonicalModel)
            canonical.persistentStoreDescriptions = [storeDescription(url: configuration.directory.appendingPathComponent("Canonical.sqlite"),
                canonical: true, model: canonicalModel)]
        }
        let projectionModel = model(canonical: false)
        let projection = NSPersistentContainer(name: "MirrorProjection", managedObjectModel: projectionModel)
        let projectionURL = configuration.directory.appendingPathComponent("LocalProjection.sqlite")
        projection.persistentStoreDescriptions = [storeDescription(url: projectionURL, canonical: false, model: projectionModel)]
        // MirrorStore의 Writer.lock 안에서 호출된다. 열린 다른 프로세스의 SQLite도 이동하지 않는다.
        let lifetime: ProjectionLifetimeLease
        do { lifetime = try ProjectionLifetimeLease.acquire(in: configuration.directory) }
        catch { throw StoreError.classify(error) }
        do {
            _ = try await backupCanonicalBeforeMigration(
                at: configuration.directory.appendingPathComponent("Canonical.sqlite"), model: canonicalModel)
            try await load(canonical)
            do { try await load(projection) }
            catch {
                guard isProjectionCorruption(error), FileManager.default.fileExists(atPath: projectionURL.path) else {
                    throw error
                }
                try await unload([projection])
                try lifetime.useExclusive()
                try await quarantineProjection(at: projectionURL)
                try await load(projection)
            }
            let persistence = CoreDataPersistence(canonical: canonical, projection: projection, projectionLifetime: lifetime)
            // pending 파일은 새 cache save 전의 종료에도 재동의 신호를 유지한다.
            let pendingURL = configuration.directory.appendingPathComponent("ProjectionRecoveryPending.json")
            if FileManager.default.fileExists(atPath: pendingURL.path) {
                let marker = try JSONDecoder().decode(ProjectionRecoveryMarker.self, from: Data(contentsOf: pendingURL))
                guard marker.schemaVersion == 1, marker.recoveredAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw StoreError.invalidConfiguration
                }
                try await persistence.saveProjection(["local:projection-recovery-v1": try JSONEncoder().encode(marker)])
                try FileManager.default.removeItem(at: pendingURL)
            }
            try lifetime.useShared()
            connections.register(canonical, changes: persistence.changeHub)
            connections.register(projection)
            return persistence
        } catch {
            try? await unload([canonical, projection])
            releaseProjectionLifetime(lifetime, projection: projection)
            throw StoreError.classify(error)
        }
    }

    func canonicalChanges(includeInitial: Bool) -> AsyncStream<StoreChangeEvent> {
        changeHub.stream(includeInitial: includeInitial)
    }

    func operations(taskIDs: Set<String>? = nil, operationIDs: Set<String> = []) async throws -> [StoredOperation] {
        try await perform(in: canonical) { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Operation")
            if let taskIDs {
                var predicates = taskIDs.sorted().map {
                    NSPredicate(format: "taskIndex CONTAINS %@", "|\($0)|")
                } + [NSPredicate(format: "taskIndex == %@", "")]
                if !operationIDs.isEmpty {
                    predicates.append(NSPredicate(format: "operationID IN %@", operationIDs.sorted()))
                }
                request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
            }
            return try context.fetch(request).map(Self.operationDTO)
        }
    }

    func operation(operationID: String) async throws -> [StoredOperation] {
        try await perform(in: canonical) { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Operation")
            request.predicate = NSPredicate(format: "operationID == %@", operationID)
            return try context.fetch(request).map(Self.operationDTO)
        }
    }

    func operation(idempotencyKey: String, workspaceKey: String, workspaceEpoch: String) async throws -> [StoredOperation] {
        try await perform(in: canonical) { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Operation")
            request.predicate = NSPredicate(format: "idempotencyKey == %@ AND workspaceKey == %@ AND workspaceEpoch == %@",
                                            idempotencyKey, workspaceKey, workspaceEpoch)
            return try context.fetch(request).map(Self.operationDTO)
        }
    }

    func append(_ operation: StoredOperation) async throws {
        try await appendMany([operation])
    }

    func appendMany(_ operations: [StoredOperation]) async throws {
        try await perform(in: canonical) { context in
            for operation in operations {
            let row = NSEntityDescription.insertNewObject(forEntityName: "Operation", into: context)
            row.setValue(UUID().uuidString, forKey: "recordID")
            row.setValue(operation.operationID, forKey: "operationID")
            row.setValue(operation.payloadDigest, forKey: "payloadDigest")
            row.setValue(operation.payload, forKey: "payload")
            row.setValue(operation.taskIDs.sorted().map { "|\($0)|" }.joined(), forKey: "taskIndex")
            row.setValue(operation.workspaceKey, forKey: "workspaceKey")
            row.setValue(operation.workspaceEpoch, forKey: "workspaceEpoch")
            row.setValue(Int64(operation.schemaVersion), forKey: "schemaVersion")
            row.setValue(operation.idempotencyKey, forKey: "idempotencyKey")
            row.setValue(operation.requestDigest, forKey: "requestDigest")
            row.setValue(operation.lamport, forKey: "lamport")
            row.setValue(Date(), forKey: "insertedAt")
            }
            try context.save()
        }
        if !operations.isEmpty { changeHub.publish() }
    }

    func destroyLocalStores() async throws {
        let stores = [canonical, projection].flatMap { container in
            container.persistentStoreDescriptions.compactMap { description in
                description.url.map { ($0, container.managedObjectModel) }
            }
        }
        let openConnections = Self.connections.connections(for: Set(stores.map { $0.0 }))
        Self.connections.finishObservers(for: Set(stores.map { $0.0 }))
        try await Task.detached(priority: .userInitiated) {
            // 같은 프로세스의 별도 인스턴스도 먼저 닫아 지연 checkpoint의 재생성을 막는다.
            try autoreleasepool {
            for container in openConnections {
                let coordinator = container.persistentStoreCoordinator
                for store in coordinator.persistentStores { try coordinator.remove(store) }
            }
            for (url, model) in stores {
                let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
                if FileManager.default.fileExists(atPath: url.path) {
                    try coordinator.destroyPersistentStore(at: url, ofType: NSSQLiteStoreType, options: nil)
                }
                for store in coordinator.persistentStores { try coordinator.remove(store) }
            }
            }
            // 공식 API의 임시 store와 autoreleased 연결도 해제한 뒤 물리 파일을 확인한다.
            for (url, _) in stores {
                // detach/destroy를 파일 소멸과 같은 것으로 취급하지 않는다.
                for suffix in ["", "-wal", "-shm", "-journal"] {
                    let file = URL(fileURLWithPath: url.path + suffix)
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                    guard !FileManager.default.fileExists(atPath: file.path) else {
                        throw StoreError.persistence("삭제할 저장소 파일이 남아 있습니다.")
                    }
                }
            }
        }.value
    }

    func close() async throws {
        changeHub.finish()
        try await Self.unload([canonical, projection])
        projectionLifetime.release()
    }

    func canonicalStoreIdentifiers() -> Set<String> {
        Set(canonical.persistentStoreCoordinator.persistentStores.compactMap { $0.identifier })
    }

    func receipt(key: String) async throws -> StoredReceipt? {
        try await perform(in: projection) { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Receipt")
            request.predicate = NSPredicate(format: "key == %@", key)
            request.fetchLimit = 1
            guard let row = try context.fetch(request).first else { return nil }
            return StoredReceipt(
                key: row.value(forKey: "key") as? String ?? "",
                digest: row.value(forKey: "digest") as? String ?? "",
                operationID: row.value(forKey: "operationID") as? String ?? "",
                result: row.value(forKey: "result") as? Data ?? Data()
            )
        }
    }

    /// task projection과 receipt는 같은 로컬 SQLite의 한 save에서 확정할 수 있다.
    func saveProjection(_ values: [String: Data], receipt: StoredReceipt? = nil, replacingTasks: Bool = false,
                        removingTaskIDs: Set<String> = []) async throws {
        try await perform(in: projection) { context in
            if replacingTasks {
                let request = NSFetchRequest<NSManagedObject>(entityName: "CacheValue")
                request.predicate = NSPredicate(format: "key BEGINSWITH %@", "task:")
                for row in try context.fetch(request) { context.delete(row) }
            }
            if !removingTaskIDs.isEmpty {
                let request = NSFetchRequest<NSManagedObject>(entityName: "CacheValue")
                request.predicate = NSPredicate(format: "key IN %@", removingTaskIDs.map { "task:\($0)" })
                for row in try context.fetch(request) { context.delete(row) }
            }
            for (key, value) in values {
                let row = try Self.findOrCreate(entity: "CacheValue", key: key, context: context)
                row.setValue(value, forKey: "value")
            }
            if let receipt {
                let row = try Self.findOrCreate(entity: "Receipt", key: receipt.key, context: context)
                row.setValue(receipt.digest, forKey: "digest")
                row.setValue(receipt.operationID, forKey: "operationID")
                row.setValue(receipt.result, forKey: "result")
            }
            if context.hasChanges { try context.save() }
        }
    }

    func cacheValues(prefix: String) async throws -> [String: Data] {
        try await perform(in: projection) { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "CacheValue")
            request.predicate = NSPredicate(format: "key BEGINSWITH %@", prefix)
            var values: [String: Data] = [:]
            for row in try context.fetch(request) {
                if let key = row.value(forKey: "key") as? String, let value = row.value(forKey: "value") as? Data { values[key] = value }
            }
            return values
        }
    }

    func localValue(key: String) async throws -> Data? {
        try await cacheValues(prefix: key)[key]
    }

    func setLocalValue(_ value: Data?, key: String) async throws {
        try await perform(in: projection) { context in
            let row = try Self.findOrCreate(entity: "CacheValue", key: key, context: context)
            if let value { row.setValue(value, forKey: "value") } else { context.delete(row) }
            if context.hasChanges { try context.save() }
        }
    }

    /// history token은 도메인 operationID와 다르다. 아직 소비하지 않은 이력은 삭제하지 않는다.
    func historyCursor() async throws -> Data? {
        try await perform(in: canonical) { context in
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
            guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction],
                  let token = transactions.last?.token else { return nil }
            return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        }
    }

    func maximumLamport(workspaceKey: String, workspaceEpoch: String) async throws -> Int64 {
        try await perform(in: canonical) { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Operation")
            // 격리 보존한 다른 공간/세대의 원본은 현재 공간의 논리 시계를 올리지 않는다.
            // 같은 공간의 미지원 schema는 계속 관측하여 새 버전 기록과의 인과 순서를 보존한다.
            request.predicate = NSPredicate(format: "workspaceKey == %@ AND workspaceEpoch == %@", workspaceKey, workspaceEpoch)
            request.sortDescriptors = [NSSortDescriptor(key: "lamport", ascending: false)]
            request.fetchLimit = 1
            return (try context.fetch(request).first?.value(forKey: "lamport") as? NSNumber)?.int64Value ?? 0
        }
    }

    func historyChanges(after cursor: Data?) async throws -> HistoryBatch {
        try await perform(in: canonical) { context in
            let token: NSPersistentHistoryToken?
            if let cursor {
                token = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: cursor)
            } else { token = nil }
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
            guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction] else {
                return HistoryBatch(taskIDs: [], containsGlobalChanges: false, cursor: cursor, changed: false)
            }
            var ids: Set<String> = []
            var global = false
            for transaction in transactions {
                for change in transaction.changes ?? [] {
                    if change.changeType == .delete { global = true; continue }
                    guard let row = try? context.existingObject(with: change.changedObjectID) else { global = true; continue }
                    let index = row.value(forKey: "taskIndex") as? String ?? ""
                    if index.isEmpty { global = true }
                    ids.formUnion(index.split(separator: "|").map(String.init))
                }
            }
            let data = try transactions.last.map { try NSKeyedArchiver.archivedData(withRootObject: $0.token, requiringSecureCoding: true) } ?? cursor
            return HistoryBatch(taskIDs: ids, containsGlobalChanges: global, cursor: data, changed: !transactions.isEmpty)
        }
    }

    private static func operationDTO(_ row: NSManagedObject) -> StoredOperation {
        let index = row.value(forKey: "taskIndex") as? String ?? ""
        return StoredOperation(
            operationID: row.value(forKey: "operationID") as? String ?? "",
            payloadDigest: row.value(forKey: "payloadDigest") as? String ?? "",
            payload: row.value(forKey: "payload") as? Data ?? Data(),
            taskIDs: index.split(separator: "|").map(String.init),
            workspaceKey: row.value(forKey: "workspaceKey") as? String ?? "",
            workspaceEpoch: row.value(forKey: "workspaceEpoch") as? String ?? "",
            schemaVersion: (row.value(forKey: "schemaVersion") as? NSNumber)?.intValue ?? 0,
            idempotencyKey: row.value(forKey: "idempotencyKey") as? String,
            requestDigest: row.value(forKey: "requestDigest") as? String,
            lamport: (row.value(forKey: "lamport") as? NSNumber)?.int64Value ?? 0
        )
    }

    private static func findOrCreate(entity: String, key: String, context: NSManagedObjectContext) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "key == %@", key)
        request.fetchLimit = 1
        if let existing = try context.fetch(request).first { return existing }
        let row = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        row.setValue(key, forKey: "key")
        return row
    }

    private func perform<T: Sendable>(in container: NSPersistentContainer, _ body: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        context.transactionAuthor = "Mirror.local"
        do { return try await context.perform { try body(context) } }
        catch { throw StoreError.classify(error) }
    }

    private static func load(_ container: NSPersistentContainer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            container.loadPersistentStores { _, error in
                // 판정 전 underlying SQLite/POSIX 오류를 보존한다.
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private static func unload(_ containers: [NSPersistentContainer]) async throws {
        try await Task.detached(priority: .userInitiated) {
            var firstError: (any Error)?
            for container in containers {
                let coordinator = container.persistentStoreCoordinator
                for store in coordinator.persistentStores {
                    do { try coordinator.remove(store) }
                    catch { if firstError == nil { firstError = error } }
                }
            }
            if let firstError { throw firstError }
        }.value
    }

    private static func releaseProjectionLifetime(_ lifetime: ProjectionLifetimeLease, projection: NSPersistentContainer) {
        if projection.persistentStoreCoordinator.persistentStores.isEmpty { lifetime.release() }
        else {
            // detach 실패는 복구를 허용하는 근거가 아니다. 프로세스 재시작 전까지 connection과 lease를 보존한다.
            retainedProjectionLifetimes.retain(lifetime, projection: projection)
        }
    }

    /// 공식 저장소 복제 API가 WAL을 포함한 일관된 backup을 만든다. 실패하면 migration을 시작하지 않는다.
    /// 이전 모델의 metadata와 원본을 보존하며 성공/실패 어느 쪽에서도 backup을 자동 삭제하지 않는다.
    static func backupCanonicalBeforeMigration(at url: URL, model: NSManagedObjectModel) async throws -> URL? {
        try await Task.detached(priority: .utility) { () throws -> URL? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let options: [AnyHashable: Any] = [NSReadOnlyPersistentStoreOption: true]
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType, at: url, options: options)
            guard !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else { return nil }
            let directory = url.deletingLastPathComponent().appendingPathComponent("MigrationBackups", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            #endif
            let backupURL = directory.appendingPathComponent("Canonical.sqlite")
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            var destinationOptions: [AnyHashable: Any] = [:]
            #if os(iOS)
            destinationOptions[NSPersistentStoreFileProtectionKey] = FileProtectionType.complete.rawValue
            #endif
            try coordinator.replacePersistentStore(at: backupURL, destinationOptions: destinationOptions,
                withPersistentStoreFrom: url, sourceOptions: options, ofType: NSSQLiteStoreType)
            let backupMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType, at: backupURL, options: options)
            guard let originalHashes = metadata[NSStoreModelVersionHashesKey] as? [String: Data],
                  let copiedHashes = backupMetadata[NSStoreModelVersionHashesKey] as? [String: Data],
                  originalHashes == copiedHashes else { throw StoreError.persistence("원본 백업을 확인할 수 없습니다.") }
            return backupURL
        }.value
    }

    /// 모호한 load 실패는 손상으로 간주하지 않는다. 자원/보호 데이터 오류가 있으면 복구를 보류한다.
    static func isProjectionCorruption(_ error: any Error) -> Bool {
        var errors = [error as NSError]
        var corruption = false
        var visited: Set<ObjectIdentifier> = []
        while let current = errors.popLast() {
            guard visited.insert(ObjectIdentifier(current)).inserted, visited.count <= 32 else { return false }
            if current.domain == NSCocoaErrorDomain {
                if current.code == NSFileReadCorruptFileError { corruption = true }
                else if [NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteOutOfSpaceError,
                         NSFileReadNoSuchFileError, NSFileWriteVolumeReadOnlyError].contains(current.code) { return false }
            }
            if current.domain == NSPOSIXErrorDomain { return false }
            let sqliteCode = current.domain == "NSSQLiteErrorDomain" ? current.code :
                (current.userInfo["NSSQLiteErrorDomain"] as? NSNumber)?.intValue
            if let sqliteCode {
                // SQLite extended codes keep the primary result in the low byte.
                let primary = sqliteCode & 0xff
                if primary == 11 || primary == 26 { corruption = true }
                else { return false }
            }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError { errors.append(underlying) }
            if let detailed = current.userInfo[NSDetailedErrorsKey] as? [NSError] { errors.append(contentsOf: detailed) }
        }
        return corruption
    }

    private static func quarantineProjection(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            let parent = url.deletingLastPathComponent()
            let pendingURL = parent.appendingPathComponent("ProjectionRecoveryPending.json")
            if !FileManager.default.fileExists(atPath: pendingURL.path) {
                try JSONEncoder().encode(ProjectionRecoveryMarker(schemaVersion: 1, recoveredAt: Date()))
                    .write(to: pendingURL, options: .atomic)
            }
            let quarantine = parent.appendingPathComponent("ProjectionQuarantine", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: quarantine.path)
            #endif
            var moved: [(URL, URL)] = []
            do {
                // 원본은 대상에 포함하지 않는다. main file을 마지막으로 이동해 중간 종료에서도 오래된 cache를 식별한다.
                for suffix in ["-journal", "-shm", "-wal", ""] {
                    let source = URL(fileURLWithPath: url.path + suffix)
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    let destination = quarantine.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.moveItem(at: source, to: destination)
                    moved.append((source, destination))
                }
            } catch {
                // rollback도 실패하면 격리물을 남겨 반환한다. 삭제나 새 개설을 계속하지 않는다.
                for (source, destination) in moved.reversed() { try? FileManager.default.moveItem(at: destination, to: source) }
                throw error
            }
        }.value
    }

    private static func storeDescription(url: URL, canonical: Bool, model: NSManagedObjectModel) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.type = NSSQLiteStoreType
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        // programmatic 모델은 Bundle 검색으로 이전 버전을 찾을 수 없다. 이전 모델을 명시해
        // Core Data가 데이터 변환 없이 인덱스 차이를 추론하도록 한다.
        let previousModel = Self.model(canonical: canonical, queryIndexes: false)
        let stage = NSCustomMigrationStage(
            migratingFrom: NSManagedObjectModelReference(model: previousModel, versionChecksum: previousModel.versionChecksum),
            to: NSManagedObjectModelReference(model: model, versionChecksum: model.versionChecksum))
        description.setOption(NSStagedMigrationManager([stage]), forKey: NSPersistentStoreStagedMigrationManagerOptionKey)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        #if os(iOS)
        description.setOption(FileProtectionType.complete.rawValue as NSString, forKey: NSPersistentStoreFileProtectionKey)
        #endif
        return description
    }

    private static func model(canonical: Bool, queryIndexes: Bool = true) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        if canonical {
            model.entities = [entity("Operation", attributes: [
                string("recordID"), string("operationID"), string("payloadDigest"), binary("payload"),
                string("taskIndex"), string("workspaceKey"), string("workspaceEpoch"),
                integer("schemaVersion", value: 1), integer("lamport", value: 0), string("idempotencyKey", optional: true),
                string("requestDigest", optional: true), date("insertedAt")
            ], indexes: [
                ("OperationByID", ["operationID"]),
                ("OperationByDecision", ["workspaceKey", "workspaceEpoch", "idempotencyKey"]),
                ("OperationByLamport", ["workspaceKey", "workspaceEpoch", "lamport"])
            ])]
        } else {
            model.entities = [
                entity("CacheValue", attributes: [string("key"), binary("value")],
                       indexes: [("CacheValueByKey", ["key"])]),
                entity("Receipt", attributes: [string("key"), string("digest"), string("operationID"), binary("result")],
                       indexes: [("ReceiptByKey", ["key"])])
            ]
        }
        for entity in model.entities {
            if queryIndexes {
                // fetch index만 추가하면 기존 SQLite와 호환된다고 판정되어 실제 생성이 생략된다.
                // 명시적인 버전 차이로 공식 migration과 원본 사전 backup을 함께 활성화한다.
                entity.versionHashModifier = "Mirror.query-indexes.v1"
            } else {
                entity.indexes = []
            }
        }
        return model
    }

    private static func entity(_ name: String, attributes: [NSAttributeDescription],
                               indexes: [(String, [String])] = []) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = "NSManagedObject"
        entity.properties = attributes
        // 조회만 보조한다. 같은 operationID의 물리 중복과 서로 다른 원문은 모두 보존한다.
        entity.indexes = indexes.map { indexName, propertyNames in
            let elements = propertyNames.map { propertyName in
                guard let property = entity.propertiesByName[propertyName] else {
                    preconditionFailure("조회 인덱스의 속성이 모델에 없습니다: \(propertyName)")
                }
                return NSFetchIndexElementDescription(property: property, collationType: .binary)
            }
            return NSFetchIndexDescription(name: indexName, elements: elements)
        }
        // CloudKit 원본은 unique constraint에 의존하지 않는다.
        return entity
    }

    private static func attribute(_ name: String, type: NSAttributeType, value: Any? = nil, optional: Bool = false) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        attribute.defaultValue = value
        return attribute
    }
    private static func string(_ name: String, optional: Bool = false) -> NSAttributeDescription {
        attribute(name, type: .stringAttributeType, value: optional ? nil : "", optional: optional)
    }
    private static func binary(_ name: String) -> NSAttributeDescription { attribute(name, type: .binaryDataAttributeType, value: Data()) }
    private static func integer(_ name: String, value: Int64) -> NSAttributeDescription { attribute(name, type: .integer64AttributeType, value: value) }
    private static func date(_ name: String) -> NSAttributeDescription { attribute(name, type: .dateAttributeType, value: Date(timeIntervalSince1970: 0)) }
}

struct HistoryBatch: Sendable {
    let taskIDs: Set<String>
    let containsGlobalChanges: Bool
    let cursor: Data?
    let changed: Bool
}

private struct ProjectionRecoveryMarker: Codable, Sendable {
    let schemaVersion: Int
    let recoveredAt: Date
}

/// Writer.lock은 쓰기 순서, 이 lease는 열린 projection 연결의 수명만 보호한다.
/// 다른 프로세스가 읽는 SQLite를 옮기지 않도록 복구 때만 exclusive NONBLOCK을 사용한다.
private final class ProjectionLifetimeLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(in directory: URL) throws -> ProjectionLifetimeLease {
        let url = directory.appendingPathComponent("ProjectionLifetime.lock")
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { throw StoreError.busy }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return ProjectionLifetimeLease(descriptor: descriptor)
    }

    func useExclusive() throws {
        try lock.withLock {
            guard let descriptor else { throw StoreError.busy }
            // 자신의 shared lease를 해제한 뒤 타 인스턴스가 없을 때만 교체한다.
            guard flock(descriptor, LOCK_UN) == 0 else { throw StoreError.busy }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN { throw StoreError.busy }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }
    }

    func useShared() throws {
        try lock.withLock {
            guard let descriptor else { throw StoreError.busy }
            guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { throw StoreError.busy }
        }
    }

    func release() {
        lock.withLock {
            guard let descriptor else { return }
            self.descriptor = nil
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }

    deinit { release() }
}

private final class RetainedProjectionLifetimes: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(ProjectionLifetimeLease, NSPersistentContainer)] = []

    func retain(_ lifetime: ProjectionLifetimeLease, projection: NSPersistentContainer) {
        lock.withLock {
            if !entries.contains(where: { $0.0 === lifetime }) { entries.append((lifetime, projection)) }
        }
    }
}

/// 동일 디렉터리를 여는 별도 actor의 연결도 삭제 전에 닫는다. container 수명은 소유하지 않는다.
private final class CoreDataConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [WeakCoreDataConnection] = []

    func register(_ container: NSPersistentContainer, changes: CanonicalStoreChangeHub? = nil) {
        let urls = Set(container.persistentStoreDescriptions.compactMap(\.url).map(Self.key))
        lock.withLock {
            entries.removeAll { $0.container == nil }
            entries.append(WeakCoreDataConnection(container: container, urls: urls, changes: changes))
        }
    }

    func finishObservers(for urls: Set<URL>) {
        let keys = Set(urls.map(Self.key))
        let observers = lock.withLock {
            entries.compactMap { entry -> CanonicalStoreChangeHub? in
                entry.urls.isDisjoint(with: keys) ? nil : entry.changes
            }
        }
        for observer in observers { observer.finish() }
    }

    func connections(for urls: Set<URL>) -> [NSPersistentContainer] {
        let keys = Set(urls.map(Self.key))
        return lock.withLock {
            entries.removeAll { $0.container == nil }
            return entries.compactMap { entry in
                entry.urls.isDisjoint(with: keys) ? nil : entry.container
            }
        }
    }

    private static func key(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
}

private final class WeakCoreDataConnection {
    weak var container: NSPersistentContainer?
    weak var changes: CanonicalStoreChangeHub?
    let urls: Set<URL>
    init(container: NSPersistentContainer, urls: Set<URL>, changes: CanonicalStoreChangeHub?) {
        self.container = container; self.urls = urls; self.changes = changes
    }
}

/// Notification은 callback 내부에서 식별하고 Sendable 변경 신호만 소비자에게 보낸다.
private final class CanonicalStoreChangeHub: @unchecked Sendable {
    private let lock = NSLock()
    private weak var coordinator: NSPersistentStoreCoordinator?
    private let storeURLs: Set<URL>
    private let storeUUIDs: Set<String>
    private var observer: (any NSObjectProtocol)?
    private var subscribers: [UUID: AsyncStream<StoreChangeEvent>.Continuation] = [:]
    private var closed = false

    init(coordinator: NSPersistentStoreCoordinator) {
        self.coordinator = coordinator
        self.storeURLs = Set(coordinator.persistentStores.compactMap(\.url).map(Self.key))
        self.storeUUIDs = Set(coordinator.persistentStores.compactMap {
            coordinator.metadata(for: $0)[NSStoreUUIDKey] as? String
        })
        observer = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) {
            [weak self] notification in
            guard let self, self.belongsToCanonical(notification) else { return }
            self.publish()
        }
    }

    func stream(includeInitial: Bool) -> AsyncStream<StoreChangeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<StoreChangeEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in self?.removeSubscriber(id) }
        let active = lock.withLock {
            guard !closed else { return false }
            subscribers[id] = continuation
            return true
        }
        if !active { continuation.finish() }
        else if includeInitial { continuation.yield(.canonicalChanged) }
        return stream
    }

    func publish() {
        let targets = lock.withLock { closed ? [] : Array(subscribers.values) }
        for subscriber in targets { subscriber.yield(.canonicalChanged) }
    }

    func finish() {
        let resources: ((any NSObjectProtocol)?, [AsyncStream<StoreChangeEvent>.Continuation]) = lock.withLock {
            guard !closed else { return (nil, []) }
            closed = true
            let resources = (observer, Array(subscribers.values))
            observer = nil
            subscribers = [:]
            return resources
        }
        if let observer = resources.0 { NotificationCenter.default.removeObserver(observer) }
        for subscriber in resources.1 { subscriber.finish() }
    }

    private func removeSubscriber(_ id: UUID) { _ = lock.withLock { subscribers.removeValue(forKey: id) } }

    private func belongsToCanonical(_ notification: Notification) -> Bool {
        if let uuid = notification.userInfo?[NSStoreUUIDKey] as? String { return storeUUIDs.contains(uuid) }
        guard let own = coordinator, let notifying = notification.object as? NSPersistentStoreCoordinator else { return false }
        if notifying === own { return true }
        // 공개 UUID가 없는 알림은 실제 coordinator의 등록 URL로만 식별한다.
        // userInfo의 문서화되지 않은 URL 키를 가정하지 않는다.
        let notifyingURLs = Set(notifying.persistentStores.compactMap(\.url).map(Self.key))
        return !storeURLs.isDisjoint(with: notifyingURLs)
    }

    private static func key(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    deinit { finish() }
}
