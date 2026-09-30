@preconcurrency import CoreData
import Foundation

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
    private let canonical: NSPersistentContainer
    private let projection: NSPersistentContainer

    private init(canonical: NSPersistentContainer, projection: NSPersistentContainer) {
        self.canonical = canonical
        self.projection = projection
    }

    static func open(configuration: StoreConfiguration) async throws -> CoreDataPersistence {
        let canonicalModel = model(canonical: true)
        let canonical: NSPersistentContainer
        if let cloud = configuration.cloudSync {
            guard !cloud.containerIdentifier.isEmpty, !cloud.accountScope.isEmpty else {
                throw StoreError.invalidConfiguration
            }
            let container = NSPersistentCloudKitContainer(name: "MirrorCanonical", managedObjectModel: canonicalModel)
            let description = storeDescription(url: configuration.directory.appendingPathComponent("Canonical.sqlite"))
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: cloud.containerIdentifier)
            container.persistentStoreDescriptions = [description]
            canonical = container
        } else {
            canonical = NSPersistentContainer(name: "MirrorCanonical", managedObjectModel: canonicalModel)
            canonical.persistentStoreDescriptions = [storeDescription(url: configuration.directory.appendingPathComponent("Canonical.sqlite"))]
        }
        let projection = NSPersistentContainer(name: "MirrorProjection", managedObjectModel: model(canonical: false))
        projection.persistentStoreDescriptions = [storeDescription(url: configuration.directory.appendingPathComponent("LocalProjection.sqlite"))]
        try await load(canonical)
        try await load(projection)
        connections.register(canonical)
        connections.register(projection)
        return CoreDataPersistence(canonical: canonical, projection: projection)
    }

    func operations(taskIDs: Set<String>? = nil) async throws -> [StoredOperation] {
        try await perform(in: canonical) { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Operation")
            if let taskIDs {
                request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: taskIDs.sorted().map {
                    NSPredicate(format: "taskIndex CONTAINS %@", "|\($0)|")
                } + [NSPredicate(format: "taskIndex == %@", "")])
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
    }

    func destroyLocalStores() async throws {
        let stores = [canonical, projection].flatMap { container in
            container.persistentStoreDescriptions.compactMap { description in
                description.url.map { ($0, container.managedObjectModel) }
            }
        }
        let openConnections = Self.connections.connections(for: Set(stores.map { $0.0 }))
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
        try await Task.detached(priority: .userInitiated) { [canonical, projection] in
            for container in [canonical, projection] {
                let coordinator = container.persistentStoreCoordinator
                for store in coordinator.persistentStores { try coordinator.remove(store) }
            }
        }.value
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

    func maximumLamport() async throws -> Int64 {
        try await perform(in: canonical) { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "Operation")
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
                if let error { continuation.resume(throwing: StoreError.classify(error)) }
                else { continuation.resume() }
            }
        }
    }

    private static func storeDescription(url: URL) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: url)
        description.type = NSSQLiteStoreType
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        #if os(iOS)
        description.setOption(FileProtectionType.complete.rawValue as NSString, forKey: NSPersistentStoreFileProtectionKey)
        #endif
        return description
    }

    private static func model(canonical: Bool) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        if canonical {
            model.entities = [entity("Operation", attributes: [
                string("recordID"), string("operationID"), string("payloadDigest"), binary("payload"),
                string("taskIndex"), string("workspaceKey"), string("workspaceEpoch"),
                integer("schemaVersion", value: 1), integer("lamport", value: 0), string("idempotencyKey", optional: true),
                string("requestDigest", optional: true), date("insertedAt")
            ])]
        } else {
            model.entities = [
                entity("CacheValue", attributes: [string("key"), binary("value")]),
                entity("Receipt", attributes: [string("key"), string("digest"), string("operationID"), binary("result")])
            ]
        }
        return model
    }

    private static func entity(_ name: String, attributes: [NSAttributeDescription]) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = "NSManagedObject"
        entity.properties = attributes
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

/// 동일 디렉터리를 여는 별도 actor의 연결도 삭제 전에 닫는다. container 수명은 소유하지 않는다.
private final class CoreDataConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [WeakCoreDataConnection] = []

    func register(_ container: NSPersistentContainer) {
        let urls = Set(container.persistentStoreDescriptions.compactMap(\.url).map(Self.key))
        lock.withLock {
            entries.removeAll { $0.container == nil }
            entries.append(WeakCoreDataConnection(container: container, urls: urls))
        }
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
    let urls: Set<URL>
    init(container: NSPersistentContainer, urls: Set<URL>) { self.container = container; self.urls = urls }
}
