import Foundation
import MirrorDomain
@testable import MirrorData
import Testing

private let previewDeviceID = "22222222-2222-4222-8222-222222222222"

private func previewConfiguration() -> StoreConfiguration {
    StoreConfiguration(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MirrorArchivePreview-\(UUID().uuidString)", isDirectory: true),
                       deviceID: previewDeviceID)
}

private func previewContext() throws -> PlanningContext {
    try PlanningContext(planningDay: LocalDate("2026-09-30"), timeZoneID: "Asia/Seoul", policyRevision: "policy-v1",
                        capturedAt: ISO8601DateFormatter().date(from: "2026-09-30T03:00:00Z")!)
}

private func previewCapture(id: UUID, title: String, context: PlanningContext) throws -> CommandEnvelope {
    CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString, source: .app,
                    context: context, workspaceEpoch: "local-v1", payload: .capture(taskID: id, content: try TaskContent(title: title)))
}

private func previewRawRow(_ record: OperationRecord) throws -> [String: Any] {
    ["operationID": record.operationID, "payloadDigest": record.payloadDigest,
     "payloadBase64": try CanonicalDigest.data(record).base64EncodedString(), "taskIDs": record.affectedTaskIDs.map(\.uuidString),
     "workspaceKey": record.workspaceKey, "workspaceEpoch": record.workspaceEpoch,
     "schemaVersion": record.schemaVersion, "lamport": record.lamport,
     "idempotencyKey": record.idempotencyKey as Any? ?? NSNull(),
     "requestDigest": record.logicalCommandDigest as Any? ?? NSNull()]
}

@Suite("실제 원본 재생의 복원 미리보기 건수")
struct ArchivePreviewTests {
    @Test("새 작업은 새 기록과 구분하며 같은 원본 중복은 작업을 늘리지 않는다")
    func newTasksUseCurrentCanonicalProjection() async throws {
        let sourceConfiguration = previewConfiguration(), targetConfiguration = previewConfiguration()
        defer {
            try? FileManager.default.removeItem(at: sourceConfiguration.directory)
            try? FileManager.default.removeItem(at: targetConfiguration.directory)
        }
        let source = try await MirrorStore(configuration: sourceConfiguration)
        let target = try await MirrorStore(configuration: targetConfiguration)
        let context = try previewContext(), firstID = UUID()
        #expect(await source.execute(try previewCapture(id: firstID, title: "첫 작업", context: context), at: context.capturedAt).state == .locallyCommitted)
        let firstArchive = try await source.exportArchive(exportedAt: context.capturedAt)
        let initial = try await target.previewArchive(firstArchive)
        #expect(initial.taskCount == 1)
        #expect(initial.newTaskCount == 1)
        #expect(initial.duplicateCount == 0)
        #expect(initial.quarantinedRecordCount == 0)
        #expect(try await target.importArchive(firstArchive).inserted == 1)

        let duplicate = try await target.previewArchive(firstArchive)
        #expect(duplicate.taskCount == 1)
        #expect(duplicate.newTaskCount == 0)
        #expect(duplicate.duplicateCount == 1)
        let first = try #require(try await source.snapshot().tasks.first)
        let edit = CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: UUID().uuidString, source: .app,
            context: context, workspaceEpoch: sourceConfiguration.workspaceEpoch,
            payload: .editContent(taskID: firstID, content: try TaskContent(title: "제목을 고친 첫 작업"),
                                  expectedContent: try #require(first.versions[.content]?.headsDigest)))
        #expect(await source.execute(edit, at: context.capturedAt).state == .locallyCommitted)
        let editedArchive = try await source.exportArchive(exportedAt: context.capturedAt)
        let edited = try await target.previewArchive(editedArchive)
        #expect(edited.operationCount == 2)
        #expect(edited.taskCount == 1)
        #expect(edited.newTaskCount == 0)
        #expect(edited.duplicateCount == 1)

        #expect(await source.execute(try previewCapture(id: UUID(), title: "둘째 작업", context: context), at: context.capturedAt).state == .locallyCommitted)
        let latestArchive = try await source.exportArchive(exportedAt: context.capturedAt)
        var latest = try #require(try JSONSerialization.jsonObject(with: latestArchive) as? [String: Any])
        latest["currentTasks"] = [Any]() // 조회용 snapshot이 아닌 원본으로 건수를 판단해야 한다.
        let previewBytes = try JSONSerialization.data(withJSONObject: latest)
        let preview = try await target.previewArchive(previewBytes)
        #expect(preview.operationCount == 3)
        #expect(preview.taskCount == 2)
        #expect(preview.newTaskCount == 1)
        #expect(preview.duplicateCount == 1)
        #expect(preview.quarantinedRecordCount == 0)
        #expect(try await target.snapshot().tasks.count == 1)
        #expect(try await target.snapshot().tasks.first?.title == "첫 작업")
    }

    @Test("일반·중단 복구 미리보기는 미해석 schema와 payload 및 재생에서 거부된 원본을 함께 센다")
    func recoveryPreviewCountsQuarantinedOriginals() async throws {
        let sourceConfiguration = previewConfiguration(), targetConfiguration = previewConfiguration()
        defer {
            try? FileManager.default.removeItem(at: sourceConfiguration.directory)
            try? FileManager.default.removeItem(at: targetConfiguration.directory)
        }
        let source = try await MirrorStore(configuration: sourceConfiguration)
        let target = try await MirrorStore(configuration: targetConfiguration)
        let context = try previewContext()
        #expect(await source.execute(try previewCapture(id: UUID(), title: "복원할 정상 작업", context: context), at: context.capturedAt).state == .locallyCommitted)
        let archive = try await source.exportArchive(exportedAt: context.capturedAt)
        var root = try #require(try JSONSerialization.jsonObject(with: archive) as? [String: Any])
        var rows = try #require(root["rawOperations"] as? [[String: Any]])
        let future = try OperationRecord.create(operationID: "preview-future", schemaVersion: 99,
            workspaceKey: sourceConfiguration.workspaceKey, workspaceEpoch: sourceConfiguration.workspaceEpoch,
            deviceID: UUID(uuidString: previewDeviceID)!, lamport: 2, recordedAt: context.capturedAt,
            commandKind: .settings, mutations: [], settings: PlanningPolicy(timeZoneID: "UTC", revision: "future-policy"))
        let malformed = try OperationRecord.create(operationID: "preview-malformed", workspaceKey: sourceConfiguration.workspaceKey,
            workspaceEpoch: sourceConfiguration.workspaceEpoch, deviceID: UUID(uuidString: previewDeviceID)!,
            lamport: 3, recordedAt: context.capturedAt, commandKind: .settings, mutations: [])
        let futureRow = try previewRawRow(future)
        rows += [futureRow, futureRow, try previewRawRow(malformed)]
        rows.append(["operationID": "preview-unreadable", "payloadDigest": "unreadable-digest",
            "payloadBase64": Data("unrecognized original bytes".utf8).base64EncodedString(), "taskIDs": [String](),
            "workspaceKey": sourceConfiguration.workspaceKey, "workspaceEpoch": sourceConfiguration.workspaceEpoch,
            "schemaVersion": 1, "lamport": Int64(4)])
        root["rawOperations"] = rows
        root["currentTasks"] = [Any]()
        let damagedArchive = try JSONSerialization.data(withJSONObject: root)
        let normal = try await target.previewArchive(damagedArchive)
        let recovery = try MirrorStore.previewArchiveForRecovery(damagedArchive, configuration: targetConfiguration)
        for preview in [normal, recovery] {
            #expect(preview.operationCount == 5)
            #expect(preview.taskCount == 1)
            #expect(preview.newTaskCount == 1)
            #expect(preview.duplicateCount == 1)
            #expect(preview.quarantinedRecordCount == 3)
            #expect(preview.warnings.contains { $0.contains("격리") && $0.contains("3개") })
        }
        #expect(recovery.requiresWorkspaceConfirmation)
        #expect(try await target.snapshot().tasks.isEmpty)
    }

    @Test("현재 원본과 충돌하는 변형 및 복구 파일의 양쪽 변형은 실제 재생 판정으로 격리한다")
    func conflictingVariantsUseMergedReduction() async throws {
        let configuration = previewConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try previewContext()
        #expect(await store.execute(try previewCapture(id: UUID(), title: "현재 원본", context: context), at: context.capturedAt).state == .locallyCommitted)
        let original = try #require(try await store.snapshot().records.first)
        let content = try TaskContent(title: "다른 변형")
        let variant = try OperationRecord.create(operationID: original.operationID, workspaceKey: original.workspaceKey,
            workspaceEpoch: original.workspaceEpoch, deviceID: original.deviceID, lamport: original.lamport,
            recordedAt: original.recordedAt, commandKind: original.commandKind,
            mutations: original.mutations.map { mutation in
                mutation.group == .content ? TaskMutation(taskID: mutation.taskID, value: .content(content)) : mutation
            }, idempotencyKey: original.idempotencyKey, logicalCommandDigest: original.logicalCommandDigest)
        let variantObject = try JSONSerialization.jsonObject(with: CanonicalDigest.data(variant))
        var root: [String: Any] = ["formatVersion": 1, "workspaceKey": configuration.workspaceKey,
            "workspaceEpoch": configuration.workspaceEpoch, "sourceAccountScope": "local-only", "operations": [variantObject]]
        let normalBytes = try JSONSerialization.data(withJSONObject: root)
        let normal = try await store.previewArchive(normalBytes)
        #expect(normal.newTaskCount == 0)
        #expect(normal.quarantinedRecordCount == 1)
        #expect(normal.duplicateCount == 0)
        #expect(try await store.snapshot().tasks.first?.title == "현재 원본")

        root["operations"] = [try JSONSerialization.jsonObject(with: CanonicalDigest.data(original)), variantObject]
        let recoveryBytes = try JSONSerialization.data(withJSONObject: root)
        let recovery = try MirrorStore.previewArchiveForRecovery(recoveryBytes, configuration: configuration)
        #expect(recovery.taskCount == 0)
        #expect(recovery.newTaskCount == 0)
        #expect(recovery.quarantinedRecordCount == 2)
        #expect(recovery.warnings.contains { $0.contains("격리") && $0.contains("2개") })
    }
}
