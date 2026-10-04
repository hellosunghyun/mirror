import Foundation
import MirrorDomain
@testable import MirrorData
import Testing

#if os(macOS)
import Darwin
#endif

private let testDeviceID = "11111111-1111-4111-8111-111111111111"

private func fixedContext(day: String = "2026-09-30") throws -> PlanningContext {
    let date = try LocalDate(day)
    let instant = ISO8601DateFormatter().date(from: "\(day)T03:00:00Z")!
    return try PlanningContext(planningDay: date, timeZoneID: "Asia/Seoul", policyRevision: "policy-v1", capturedAt: instant)
}

private func temporaryConfiguration() -> StoreConfiguration {
    StoreConfiguration(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MirrorStoreTests-\(UUID().uuidString)", isDirectory: true),
                       deviceID: testDeviceID)
}

private func capture(id: UUID = UUID(), key: String = UUID().uuidString, title: String = "밀리지 않을 기록",
                     context: PlanningContext, epoch: String = "local-v1") throws -> CommandEnvelope {
    CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: key, source: .app,
                    context: context, workspaceEpoch: epoch,
                    payload: .capture(taskID: id, content: try TaskContent(title: title)))
}

private enum ObservationTestError: Error { case timeout }

private func nextChange(in stream: AsyncStream<StoreChangeEvent>, timeout: Duration = .seconds(5)) async throws -> StoreChangeEvent? {
    try await withThrowingTaskGroup(of: StoreChangeEvent?.self) { group in
        group.addTask {
            for await event in stream { return event }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ObservationTestError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next() ?? nil
    }
}

#if os(macOS)
private struct StoreProbeReport: Decodable {
    let state: CommandResultState
    let operationID: String?
    let taskCount: Int?
    let recordCount: Int?
}

private final class StoreProbeChild: @unchecked Sendable {
    let process = Process()
    private let exitSignal = DispatchSemaphore(value: 0)
    private let reportURL: URL

    init(mode: String, directory: URL, envelope: URL, ready: URL, start: URL, report: URL,
         serviceInstant: Date) throws {
        reportURL = report
        // SwiftPM의 공식 --show-bin-path 결과를 사용해 native XCTest의 환경 변수 전달에 의존하지 않는다.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let scratch = root.appendingPathComponent(".build/process-probe", isDirectory: true)
        let manifest = scratch.appendingPathComponent("bin-path.txt")
        try #require(FileManager.default.fileExists(atPath: manifest.path),
                     "CI는 프로세스 helper를 명시적으로 build하고 bin-path.txt를 준비해야 합니다.")
        let binPath = try String(contentsOf: manifest, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let binary = URL(fileURLWithPath: binPath, isDirectory: true).appendingPathComponent("MirrorStoreProbe")
        try #require(binary.standardizedFileURL.path.hasPrefix(scratch.standardizedFileURL.path + "/"),
                     "helper 실행 파일은 현재 저장소의 process-probe scratch 안에 있어야 합니다.")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path),
                     "실제 MirrorStoreProbe 실행 파일이 없으면 프로세스 회귀를 완료할 수 없습니다.")
        process.executableURL = binary
        process.arguments = [mode, directory.path, envelope.path, ready.path, start.path, report.path,
                             String(serviceInstant.timeIntervalSince1970)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let signal = exitSignal
        process.terminationHandler = { _ in signal.signal() }
    }

    func run() throws { try process.run() }
    func cleanup() { killAndReap(process, exitSignal: exitSignal) }

    var hasReapedExit: Bool {
        hasReapedExitSignal(exitSignal)
    }

    var diagnostic: String {
        let lifecycle = process.isRunning ? "running" :
            "exitReason=\(process.terminationReason.rawValue) status=\(process.terminationStatus)"
        let report = try? JSONDecoder().decode(StoreProbeReport.self, from: Data(contentsOf: reportURL))
        // 원본 내용, 경로, operationID는 진단에 노출하지 않는다.
        return "\(lifecycle) state=\(report?.state.rawValue ?? "no-report")"
    }
}

private func hasReapedExitSignal(_ signal: DispatchSemaphore) -> Bool {
    guard signal.wait(timeout: .now()) == .success else { return false }
    signal.signal() // cleanup도 같은 종료 완료 신호를 확인한다.
    return true
}

private func killAndReap(_ process: Process, exitSignal: DispatchSemaphore) {
    guard process.processIdentifier > 0 else { return }
    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    // 종료 handler는 Foundation이 자식을 회수한 뒤 호출된다. timeout이면 검증 실패를 남긴다.
    guard exitSignal.wait(timeout: .now() + 5) == .success else {
        Issue.record("SIGKILL 이후 5초 안에 helper 종료·회수를 확인하지 못했습니다.")
        return
    }
    if process.isRunning { Issue.record("종료 handler 이후에도 helper가 실행 중입니다.") }
}

private func waitForProbeReady(_ children: [StoreProbeChild], files: [URL]) async throws {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(15))
    while !files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
        try #require(children.allSatisfy { $0.process.isRunning },
                     "ready 이전에 helper가 종료됐습니다: \(children.map(\.diagnostic))")
        try #require(clock.now < deadline, "helper ready 대기는 15초 이내여야 합니다.")
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(children.allSatisfy { $0.process.isRunning },
                 "ready는 실행 중인 실제 helper가 보내야 합니다: \(children.map(\.diagnostic))")
}

private func waitForProbeExit(_ children: [StoreProbeChild]) async throws {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(15))
    while children.contains(where: { !$0.hasReapedExit }) {
        try #require(clock.now < deadline, "helper 종료 대기는 15초 이내여야 합니다.")
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(children.allSatisfy { !$0.process.isRunning }, "종료 handler는 자식 종료를 확인해야 합니다.")
}
#endif

@Suite("실제 Core Data SQLite 저장과 복구", .serialized)
struct StoreIntegrationTests {
    @Test("원본 저장 전 실패는 원본과 작업을 남기지 않는다")
    func failureBeforeCanonical() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let envelope = try capture(context: context)
        let failure = await store.execute(envelope, at: context.capturedAt, failurePoint: .beforeCanonicalSave)
        #expect(failure.state == .persistenceFailed)
        let reopened = try await MirrorStore(configuration: configuration)
        let empty = try await reopened.snapshot()
        #expect(empty.tasks.isEmpty)
        #expect(empty.records.isEmpty)
        let retry = await reopened.execute(envelope, at: context.capturedAt)
        #expect(retry.state == .locallyCommitted)
        #expect(try await reopened.snapshot().tasks.count == 1)
    }

    @Test("원본과 투영 사이 종료는 원본의 같은 결정 키로 복구한다", arguments: [StoreFailurePoint.afterCanonicalSave, .beforeReceiptSave])
    func canonicalRecovery(point: StoreFailurePoint) async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let envelope = try capture(context: context)
        let failure = await store.execute(envelope, at: context.capturedAt, failurePoint: point)
        #expect(failure.state == .committedProjectionPending)
        #expect(failure.operationID != nil)
        let reopened = try await MirrorStore(configuration: configuration)
        let recovered = try await reopened.snapshot()
        #expect(recovered.tasks.count == 1)
        #expect(recovered.records.count == 1)
        // 다음 날의 오래된 봉투여도 원본 멱등성 조회가 context 검증보다 먼저다.
        let tomorrow = try fixedContext(day: "2026-10-01")
        let retry = await reopened.execute(envelope, at: tomorrow.capturedAt)
        #expect(retry.state == .alreadyApplied)
        #expect(retry.operationID == failure.operationID)
        #expect(try await reopened.snapshot().records.count == 1)
    }

    @Test("다른 payload를 같은 키로 보내면 원래 작업을 유지한다")
    func conflictingDecision() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let id = UUID(), key = "same-user-decision"
        let first = try capture(id: id, key: key, title: "첫 제목", context: context)
        let changed = try capture(id: id, key: key, title: "바뀐 제목", context: context)
        #expect(await store.execute(first, at: context.capturedAt).state == .locallyCommitted)
        #expect(await store.execute(changed, at: context.capturedAt).state == .alreadyDecided)
        let snapshot = try await store.snapshot()
        #expect(snapshot.tasks.map(\.title) == ["첫 제목"])
        #expect(snapshot.records.count == 1)
    }

    @Test("독립 store 인스턴스의 동시 재시도는 원본 한 개를 만든다")
    func independentInstancesDeduplicate() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let first = try await MirrorStore(configuration: configuration)
        let second = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let envelope = try capture(context: context)
        async let a = first.execute(envelope, at: context.capturedAt)
        async let b = second.execute(envelope, at: context.capturedAt)
        let results = await [a, b]
        let diagnostic: [String: Any] = [
            "states": results.map { $0.state.rawValue },
            "busyResults": results.map {
                $0.state == .unavailable && $0.safeUserMessage == "다른 변경을 반영 중입니다. 같은 작업을 재시도해 주세요."
            }
        ]
        let diagnosticJSON = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
        print("Store dedup result diagnostic: \(String(decoding: diagnosticJSON, as: UTF8.self))")
        #expect(results.filter { $0.state == .locallyCommitted }.count == 1)
        #expect(results.filter { $0.state == .alreadyApplied }.count == 1)
        let left = try await first.snapshot(), right = try await second.snapshot()
        #expect(left.tasks == right.tasks)
        #expect(left.records.count == 1)
        #expect(right.records.count == 1)
    }

    @Test("다른 store에서 성공한 수정은 오래된 snapshot과 재구축이 덮지 않는다")
    func historyRefreshAfterAnotherWriter() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let reader = try await MirrorStore(configuration: configuration)
        let writer = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let id = UUID()
        #expect(await writer.execute(try capture(id: id, context: context), at: context.capturedAt).state == .locallyCommitted)
        let initial = try await reader.snapshot()
        let task = try #require(initial.tasks.first)
        let edit = CommandEnvelope(requestID: "edit-request", idempotencyKey: "edit-key", source: .app,
            context: context, workspaceEpoch: configuration.workspaceEpoch,
            payload: .editContent(taskID: id, content: try TaskContent(title: "다른 프로세스의 수정"),
                                  expectedContent: try #require(task.versions[.content]?.headsDigest)))
        #expect(await writer.execute(edit, at: context.capturedAt).state == .locallyCommitted)
        try await reader.rebuild()
        #expect(try await reader.snapshot().tasks.first?.title == "다른 프로세스의 수정")
        #expect(try await writer.snapshot().tasks.first?.title == "다른 프로세스의 수정")
    }

    @Test("작업 전용 읽기는 다른 SQLite writer의 변경과 원래 목록 순서를 유지한다")
    func taskProjectionReadsRefreshAndPreserveOrdering() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let reader = try await MirrorStore(configuration: configuration)
        let writer = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let earlierID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let laterID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        #expect(try await reader.taskProjections().isEmpty)
        #expect(try await reader.taskProjection(earlierID) == nil)
        // 같은 생성 시각의 반대 삽입 순서도 기존 UUID 정렬과 같아야 한다.
        #expect(await writer.execute(try capture(id: laterID, title: "뒤 ID", context: context), at: context.capturedAt).state == .locallyCommitted)
        #expect(await writer.execute(try capture(id: earlierID, title: "앞 ID", context: context), at: context.capturedAt).state == .locallyCommitted)
        let initialTasks = try await reader.taskProjections()
        #expect(initialTasks.map(\.taskID) == [earlierID, laterID])
        #expect(initialTasks.first?.createdAt == initialTasks.last?.createdAt)
        #expect(initialTasks == (try await reader.snapshot()).tasks)
        let original = try #require(try await reader.taskProjection(earlierID))
        #expect(original == initialTasks.first)
        let edit = CommandEnvelope(requestID: "projection-read-edit", idempotencyKey: "projection-read-edit", source: .app,
            context: context, workspaceEpoch: configuration.workspaceEpoch,
            payload: .editContent(taskID: earlierID, content: try TaskContent(title: "다른 writer의 최신 제목"),
                                  expectedContent: try #require(original.versions[.content]?.headsDigest)))
        #expect(await writer.execute(edit, at: context.capturedAt).state == .locallyCommitted)
        let edited = try #require(try await reader.taskProjection(earlierID))
        #expect(edited.title == "다른 writer의 최신 제목")
        #expect(edited == (try await writer.snapshot()).tasks.first)
        let trash = CommandEnvelope(requestID: "projection-read-trash", idempotencyKey: "projection-read-trash", source: .app,
            context: context, workspaceEpoch: configuration.workspaceEpoch,
            payload: .trash(taskID: earlierID, expectedStatus: try #require(edited.versions[.status]?.headsDigest)))
        #expect(await writer.execute(trash, at: context.capturedAt).state == .locallyCommitted)
        #expect(try await reader.taskProjection(earlierID)?.status == .deleted)
        // Store는 삭제 작업도 반환하고 SystemServices.task의 기존 노출 필터가 제외한다.
        #expect(try await reader.taskProjections() == (try await writer.snapshot()).tasks)
        #expect(try await reader.taskProjection(UUID()) == nil)
    }

    @Test("따뜻한 snapshot의 원본 정렬은 같은 writer·다른 연결·import·삭제 후에도 최신이다")
    func sortedRecordCacheFollowsCanonicalChanges() async throws {
        let configuration = temporaryConfiguration()
        let importDirectory = temporaryConfiguration().directory
        let importConfiguration = StoreConfiguration(directory: importDirectory,
            deviceID: "22222222-2222-4222-8222-222222222222")
        defer {
            try? FileManager.default.removeItem(at: configuration.directory)
            try? FileManager.default.removeItem(at: importDirectory)
        }
        let reader = try await MirrorStore(configuration: configuration)
        let writer = try await MirrorStore(configuration: configuration)
        let source = try await MirrorStore(configuration: importConfiguration)
        let context = try fixedContext()
        // 빈 정렬 cache부터 실제 변경까지 같은 actor에서 재사용한다.
        #expect(try await reader.snapshot().records.isEmpty)
        let local = await reader.execute(try capture(key: "sorted-cache-local", title: "같은 writer", context: context), at: context.capturedAt)
        #expect(local.state == .locallyCommitted)
        let localOperationID = try #require(local.operationID)
        let afterLocal = try await reader.snapshot()
        #expect(afterLocal.records.map(\.operationID) == [localOperationID])
        #expect(try await reader.snapshot().records == afterLocal.records)
        let remote = await writer.execute(try capture(key: "sorted-cache-remote", title: "다른 연결", context: context), at: context.capturedAt)
        #expect(remote.state == .locallyCommitted)
        let remoteOperationID = try #require(remote.operationID)
        let afterRemote = try await reader.snapshot()
        #expect(afterRemote.records.map(\.operationID) == [localOperationID, remoteOperationID])
        #expect(afterRemote.records.map(\.lamport) == [1, 2])
        #expect(try await reader.snapshot().records == afterRemote.records)
        let imported = await source.execute(try capture(key: "sorted-cache-import", title: "가져온 원본", context: context), at: context.capturedAt)
        #expect(imported.state == .locallyCommitted)
        let importedOperationID = try #require(imported.operationID)
        let archive = try await source.exportArchive(exportedAt: context.capturedAt)
        let report = try await reader.importArchive(archive)
        #expect(report.inserted == 1)
        #expect(!report.projectionPending)
        let afterImport = try await reader.snapshot()
        // 마지막에 추가한 Lamport 1 원본은 같은 Lamport의 device ID 순서로 앞에 들어간다.
        #expect(afterImport.records.map(\.operationID) == [localOperationID, importedOperationID, remoteOperationID])
        #expect(afterImport.records.map(\.lamport) == [1, 1, 2])
        #expect(afterImport.records.map(\.deviceID) == [UUID(uuidString: testDeviceID)!, UUID(uuidString: importConfiguration.deviceID)!, UUID(uuidString: testDeviceID)!])
        #expect(try await reader.snapshot().records == afterImport.records)
        // 같은 원본을 새 actor에서 읽어 전체 payload/digest/부모/순서까지 비교한다.
        let reopened = try await MirrorStore(configuration: configuration)
        #expect(try await reopened.snapshot().records == afterImport.records)
        let duplicate = try await reader.importArchive(archive)
        #expect(duplicate.inserted == 0)
        #expect(duplicate.duplicates == 1)
        #expect(try await reader.snapshot().records == afterImport.records)
        let deletion = try await reader.deleteLocalData()
        #expect(deletion.deleted)
        await #expect(throws: StoreError.obsoleteEpoch) { try await reader.snapshot() }
        await #expect(throws: StoreError.obsoleteEpoch) { try await writer.snapshot() }
        let replacement = try await MirrorStore(configuration: try #require(deletion.newConfiguration))
        #expect(try await replacement.snapshot().records.isEmpty)
    }

    @Test("저장한 계획 정책과 실제 현재 시각은 카드 context보다 우선한다")
    func staleClockAndPersistedPolicy() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let old = try fixedContext()
        let captureEnvelope = try capture(context: old)
        let tomorrow = try fixedContext(day: "2026-10-01")
        // capture는 명시 날짜 변경이 없어 stale day를 요구하지 않을 수 있다.
        #expect(await store.execute(captureEnvelope, at: old.capturedAt).state == .locallyCommitted)
        let task = try #require(try await store.snapshot().tasks.first)
        let plan = CommandEnvelope(requestID: "stale-plan", idempotencyKey: "stale-plan-key", source: .widget,
            context: old, workspaceEpoch: configuration.workspaceEpoch,
            payload: .setPlan(item: PlanCommandItem(taskID: task.taskID, expected: ExpectedVersions(task)), target: .day(old.planningDay), review: nil))
        #expect(await store.execute(plan, at: tomorrow.capturedAt).state == .staleContext)
        let reader = try await MirrorStore(configuration: configuration)
        let initialContext = try await reader.currentContext(at: old.capturedAt)
        #expect(initialContext == old)
        let settings = CommandEnvelope(requestID: "settings", idempotencyKey: "settings-key", source: .app,
            context: old, workspaceEpoch: configuration.workspaceEpoch,
            payload: .settings(policy: try PlanningPolicy(timeZoneID: "America/New_York", revision: "policy-v2"), expectedRevision: "policy-v1"))
        #expect(await store.execute(settings, at: old.capturedAt).state == .locallyCommitted)
        let refreshedContext = try await reader.currentContext(at: old.capturedAt)
        #expect(refreshedContext.timeZoneID == "America/New_York")
        #expect(refreshedContext.policyRevision == "policy-v2")
        #expect(refreshedContext.planningDay == (try LocalDate("2026-09-29")))
        #expect(refreshedContext.capturedAt == old.capturedAt)
        let reopened = try await MirrorStore(configuration: configuration)
        #expect(try await reopened.snapshot().policy.timeZoneID == "America/New_York")
        #expect(try await reopened.currentContext(at: old.capturedAt).policyRevision == "policy-v2")
    }

    @Test("원본 export/import는 상태와 이력을 왕복하고 두 번 import해도 중복이 없다")
    func exportImportRoundTrip() async throws {
        let firstConfiguration = temporaryConfiguration(), secondConfiguration = temporaryConfiguration()
        defer {
            try? FileManager.default.removeItem(at: firstConfiguration.directory)
            try? FileManager.default.removeItem(at: secondConfiguration.directory)
        }
        let first = try await MirrorStore(configuration: firstConfiguration)
        let second = try await MirrorStore(configuration: secondConfiguration)
        let context = try fixedContext()
        #expect(await first.execute(try capture(title: "메모와 이력의 왕복", context: context), at: context.capturedAt).state == .locallyCommitted)
        let archive = try await first.exportArchive(exportedAt: context.capturedAt)
        let preview = try await second.previewArchive(archive)
        #expect(preview.operationCount == 1)
        #expect(preview.taskCount == 1)
        let imported = try await second.importArchive(archive)
        #expect(imported.inserted == 1)
        #expect(!imported.projectionPending)
        let duplicate = try await second.importArchive(archive)
        #expect(duplicate.inserted == 0)
        #expect(duplicate.duplicates == 1)
        let left = try await first.snapshot(), right = try await second.snapshot()
        #expect(left.tasks == right.tasks)
        #expect(left.records == right.records)
    }

    @Test("모르는 schema 원본은 격리하지만 내보내기에서 유실하지 않는다")
    func unknownSchemaPreservation() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let unknown = try OperationRecord.create(operationID: "future-record", schemaVersion: 99,
            workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch,
            deviceID: UUID(uuidString: testDeviceID)!, lamport: 1, recordedAt: context.capturedAt,
            commandKind: .settings, mutations: [], settings: PlanningPolicy(timeZoneID: "UTC", revision: "future-policy"))
        let archive = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "workspaceKey": configuration.workspaceKey,
            "workspaceEpoch": configuration.workspaceEpoch, "sourceAccountScope": "local-only",
            "operations": [try JSONSerialization.jsonObject(with: CanonicalDigest.data(unknown))]])
        let imported = try await store.importArchive(archive)
        #expect(imported.quarantined == 1)
        let snapshot = try await store.snapshot()
        #expect(snapshot.tasks.isEmpty)
        #expect(snapshot.policy.revision == "policy-v1")
        #expect(snapshot.pendingOperationIDs.contains("future-record"))
        let output = try await store.exportArchive(exportedAt: context.capturedAt)
        let json = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        let originals = try #require(json["operations"] as? [[String: Any]])
        #expect(originals.first?["schemaVersion"] as? Int == 99)
        #expect(originals.first?["operationID"] as? String == "future-record")
    }

    @Test("다른 공간의 격리된 최대 Lamport는 명령을 막지 않고 같은 공간의 미지원 시계는 보존한다",
          arguments: ["workspaceKey", "workspaceEpoch"])
    func quarantinedForeignLamportDoesNotBlockCurrentWorkspace(differentField: String) async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let initial = await store.execute(try capture(title: "유지할 기존 작업", context: context), at: context.capturedAt)
        #expect(initial.state == .locallyCommitted)
        let foreign = try OperationRecord.create(operationID: "quarantined-foreign-lamport",
            workspaceKey: differentField == "workspaceKey" ? "foreign-space" : configuration.workspaceKey,
            workspaceEpoch: differentField == "workspaceEpoch" ? "foreign-generation" : configuration.workspaceEpoch,
            deviceID: UUID(uuidString: testDeviceID)!, lamport: Int64.max, recordedAt: context.capturedAt,
            commandKind: .settings, mutations: [], settings: PlanningPolicy(timeZoneID: "UTC", revision: "foreign-policy"))
        let future = try OperationRecord.create(operationID: "current-workspace-future-schema", schemaVersion: 99,
            workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch,
            deviceID: UUID(uuidString: testDeviceID)!, lamport: 4_000, recordedAt: context.capturedAt,
            commandKind: .settings, mutations: [], settings: PlanningPolicy(timeZoneID: "UTC", revision: "future-policy"))
        let rawRows: [[String: Any]] = try [foreign, future].map { record in
            ["operationID": record.operationID, "payloadDigest": record.payloadDigest,
             "payloadBase64": try CanonicalDigest.data(record).base64EncodedString(),
             "taskIDs": record.affectedTaskIDs.map(\.uuidString), "workspaceKey": record.workspaceKey,
             "workspaceEpoch": record.workspaceEpoch, "schemaVersion": record.schemaVersion,
             "lamport": record.lamport, "quarantined": record.operationID == foreign.operationID]
        }
        let archive = try JSONSerialization.data(withJSONObject: ["formatVersion": 1,
            "workspaceKey": configuration.workspaceKey, "workspaceEpoch": configuration.workspaceEpoch,
            "sourceAccountScope": "local-only", "rawOperations": rawRows])
        let imported = try await store.importArchive(archive)
        #expect(imported.inserted == 2)
        #expect(!imported.projectionPending)
        let beforeCapture = try await store.snapshot()
        #expect(beforeCapture.tasks.map(\.title) == ["유지할 기존 작업"])
        #expect(beforeCapture.quarantinedCount == 2)
        #expect(beforeCapture.policy.revision == "policy-v1")
        let command = try capture(key: "after-foreign-lamport", title: "격리 뒤 새 작업", context: context)
        let result = await store.execute(command, at: context.capturedAt)
        #expect(result.state == .locallyCommitted)
        let final = try await store.snapshot()
        let newRecord = try #require(final.records.first { $0.operationID == result.operationID })
        #expect(newRecord.lamport == 4_001)
        #expect(Set(final.tasks.map(\.title)) == ["유지할 기존 작업", "격리 뒤 새 작업"])
        #expect(final.records.contains(future))
        #expect(final.quarantinedCount == 2)
        let output = try await store.exportArchive(exportedAt: context.capturedAt)
        let exported = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        let exportedRows = try #require(exported["rawOperations"] as? [[String: Any]])
        #expect(exportedRows.count == 4)
        for record in [foreign, future] {
            let row = try #require(exportedRows.first { $0["operationID"] as? String == record.operationID })
            let expectedPayload = try CanonicalDigest.data(record).base64EncodedString()
            #expect(row["payloadBase64"] as? String == expectedPayload)
            #expect(row["payloadDigest"] as? String == record.payloadDigest)
            #expect(row["workspaceKey"] as? String == record.workspaceKey)
            #expect(row["workspaceEpoch"] as? String == record.workspaceEpoch)
        }
        try await store.suspend()
        let reopened = try await MirrorStore(configuration: configuration)
        let restarted = try await reopened.snapshot()
        #expect(restarted.tasks == final.tasks)
        #expect(Set(restarted.records) == Set(final.records))
        #expect(restarted.quarantinedCount == 2)
        let retry = await reopened.execute(command, at: context.capturedAt)
        #expect(retry.state == .alreadyApplied)
        #expect(retry.operationID == result.operationID)
    }

    @Test("프로세스의 다른 초기 시간대는 저장한 최초 정책을 덮지 않는다")
    func bootstrapPolicySharedAcrossInstances() async throws {
        let firstConfiguration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: firstConfiguration.directory) }
        let first = try await MirrorStore(configuration: firstConfiguration)
        let secondConfiguration = StoreConfiguration(directory: firstConfiguration.directory, deviceID: testDeviceID,
            initialTimeZoneID: "America/New_York", initialPolicyRevision: "another-default")
        let second = try await MirrorStore(configuration: secondConfiguration)
        let left = try await first.snapshot(), right = try await second.snapshot()
        #expect(left.policy == right.policy)
        try await second.rebuild()
        #expect(try await second.snapshot().policy.timeZoneID == "Asia/Seoul")
        #expect(try await second.snapshot().policy.revision == "policy-v1")
    }

    @Test("같은 ID와 주장 digest의 다른 내용도 중복으로 버리지 않고 격리한다")
    func dishonestDigestIsNotDeduplicated() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        #expect(await store.execute(try capture(title: "원본 제목", context: context), at: context.capturedAt).state == .locallyCommitted)
        let original = try #require(try await store.snapshot().records.first)
        let different = try OperationRecord.create(operationID: original.operationID, workspaceKey: original.workspaceKey,
            workspaceEpoch: original.workspaceEpoch, deviceID: original.deviceID, lamport: original.lamport,
            recordedAt: original.recordedAt, commandKind: original.commandKind,
            mutations: original.mutations.map { mutation in
                mutation.group == .content ? TaskMutation(taskID: mutation.taskID, value: .content(try! TaskContent(title: "위조 제목"))) : mutation
            }, idempotencyKey: original.idempotencyKey, logicalCommandDigest: original.logicalCommandDigest)
        var json = try #require(try JSONSerialization.jsonObject(with: CanonicalDigest.data(different)) as? [String: Any])
        json["payloadDigest"] = original.payloadDigest // 실제 의미 내용의 SHA-256과 다르다.
        let archive = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "workspaceKey": configuration.workspaceKey,
            "workspaceEpoch": configuration.workspaceEpoch, "sourceAccountScope": "local-only", "operations": [json]])
        let report = try await store.importArchive(archive)
        #expect(report.inserted == 1)
        #expect(report.duplicates == 0)
        #expect(report.quarantined == 1)
        let snapshot = try await store.snapshot()
        #expect(snapshot.tasks.isEmpty)
        #expect(snapshot.quarantinedCount == 1)
        let output = try await store.exportArchive(exportedAt: context.capturedAt)
        let exported = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect((exported["rawOperations"] as? [Any])?.count == 2)
    }

    @Test("같은 ID의 다른 작업 변형은 증분 조회·명령·재시작에서도 함께 격리한다")
    func crossTaskDuplicateRemainsQuarantinedAcrossCommandAndRestart() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let first = try capture(key: "cross-task-decision", context: context)
        let committed = await store.execute(first, at: context.capturedAt)
        #expect(committed.state == .locallyCommitted)
        let before = try await store.snapshot()
        let task = try #require(before.tasks.first)
        let original = try #require(before.records.first)
        let reader = try await MirrorStore(configuration: configuration)
        let displayed = try await reader.snapshot()
        #expect(displayed.tasks == before.tasks)

        let otherID = UUID()
        let otherCapture = try capture(id: otherID, key: first.idempotencyKey, context: context)
        let variant = try OperationRecord.create(operationID: original.operationID,
            workspaceKey: original.workspaceKey, workspaceEpoch: original.workspaceEpoch,
            deviceID: original.deviceID, lamport: original.lamport, recordedAt: original.recordedAt,
            commandKind: .capture,
            mutations: original.mutations.map { TaskMutation(taskID: otherID, value: $0.value) },
            idempotencyKey: original.idempotencyKey, logicalCommandDigest: otherCapture.logicalDigest(),
            undoValues: original.undoValues.map { TaskMutation(taskID: otherID, value: $0.value) })
        let archive = try JSONSerialization.data(withJSONObject: ["formatVersion": 1,
            "workspaceKey": configuration.workspaceKey, "workspaceEpoch": configuration.workspaceEpoch,
            "sourceAccountScope": "local-only",
            "operations": [try JSONSerialization.jsonObject(with: CanonicalDigest.data(variant))]])
        let imported = try await store.importArchive(archive)
        #expect(imported.inserted == 1)
        #expect(imported.quarantined == 1)
        let quarantined = try await store.snapshot()
        let refreshed = try await reader.snapshot()
        #expect(quarantined.tasks.isEmpty)
        #expect(refreshed.tasks.isEmpty)
        #expect(quarantined.quarantinedCount == 1)
        #expect(refreshed.quarantinedCount == 1)
        #expect(Set(quarantined.records) == [original, variant])
        #expect(Set(refreshed.records) == [original, variant])

        let edit = CommandEnvelope(requestID: "quarantined-edit-request", idempotencyKey: "quarantined-edit",
            source: .app, context: context, workspaceEpoch: configuration.workspaceEpoch,
            payload: .editContent(taskID: task.taskID, content: try TaskContent(title: "격리 후 저장하면 안 되는 수정"),
                expectedContent: try #require(task.versions[.content]?.headsDigest)))
        let rejected = await store.execute(edit, at: context.capturedAt)
        #expect(rejected.state == .notFound)
        #expect(rejected.operationID == nil)
        let afterCommand = try await store.snapshot()
        #expect(afterCommand.tasks.isEmpty)
        #expect(Set(afterCommand.records) == [original, variant])
        try await store.rebuild()
        let rebuilt = try await store.snapshot()
        #expect(rebuilt.tasks == afterCommand.tasks)
        #expect(Set(rebuilt.records) == [original, variant])
        try await reader.suspend()
        try await store.suspend()
        let reopened = try await MirrorStore(configuration: configuration)
        let restarted = try await reopened.snapshot()
        #expect(restarted.tasks.isEmpty)
        #expect(restarted.quarantinedCount == 1)
        #expect(Set(restarted.records) == [original, variant])
        let output = try await reopened.exportArchive(exportedAt: context.capturedAt)
        let exported = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        let rows = try #require(exported["rawOperations"] as? [[String: Any]])
        #expect(rows.count == 2)
        let expectedPayloads = try Set([original, variant].map { try CanonicalDigest.data($0).base64EncodedString() })
        #expect(Set(rows.compactMap { $0["payloadBase64"] as? String }) == expectedPayloads)
    }

    @Test("raw archive의 task index와 요청 키 위조는 저장 전에 거부한다")
    func rejectPoisonedRawMetadata() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        #expect(await store.execute(try capture(context: context), at: context.capturedAt).state == .locallyCommitted)
        let data = try await store.exportArchive(exportedAt: context.capturedAt)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var raw = try #require(json["rawOperations"] as? [[String: Any]])
        raw[0]["taskIDs"] = [UUID().uuidString]
        raw[0]["idempotencyKey"] = "another-decision"
        json["rawOperations"] = raw
        let poisoned = try JSONSerialization.data(withJSONObject: json)
        await #expect(throws: StoreError.incompatibleArchive) { try await store.importArchive(poisoned) }
        #expect(try await store.snapshot().records.count == 1)
    }

    @Test("동시 재구축 뒤 다른 writer의 모든 성공한 입력을 읽는다")
    func concurrentRebuildKeepsSuccessfulWrites() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let reader = try await MirrorStore(configuration: configuration)
        let writer = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let writing = Task {
            for index in 0..<8 {
                let envelope = try capture(key: "concurrent-\(index)", title: "입력 \(index)", context: context)
                var result = await writer.execute(envelope, at: context.capturedAt)
                if result.state == .unavailable { result = await writer.execute(envelope, at: context.capturedAt) }
                #expect(result.state == .locallyCommitted || result.state == .alreadyApplied)
                await Task.yield()
            }
        }
        for _ in 0..<8 {
            do { try await reader.rebuild() }
            catch StoreError.busy { /* 변경이 연속되면 오래된 성공 대신 재시도 상태를 반환한다. */ }
            await Task.yield()
        }
        try await writing.value
        let current = try await reader.snapshot()
        #expect(current.tasks.count == 8)
        #expect(current.records.count == 8)
        #expect(Set(current.tasks.map(\.title)) == Set((0..<8).map { "입력 \($0)" }))
    }

    @Test("다른 epoch의 import는 저장 전에 거부한다")
    func rejectOtherEpoch() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let data = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "workspaceKey": configuration.workspaceKey,
                                                               "workspaceEpoch": "old-generation", "operations": []])
        await #expect(throws: StoreError.obsoleteEpoch) { try await store.importArchive(data) }
        #expect(try await store.snapshot().records.isEmpty)
    }

    @Test("250ms gate timeout과 취소 뒤 다음 writer는 들어올 수 있다")
    func gateTimeoutAndCancellationRelease() async throws {
        let directory = temporaryConfiguration().directory
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Test.lock")
        let holder = ProcessWriteGate(url: url, timeout: .milliseconds(250))
        let first = try await holder.acquire()
        let waiting = Task { try await holder.acquire() }
        waiting.cancel()
        await #expect(throws: StoreError.cancelled) { try await waiting.value }
        let clock = ContinuousClock(), start = clock.now
        await #expect(throws: StoreError.busy) { try await holder.acquire() }
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(2))
        first.release()
        let after = try await holder.acquire()
        after.release()
    }

    @Test("기기 내 삭제는 앱 소유 복구 자료만 지우고 다른 파일을 보존한다")
    func localDeleteRemovesOwnedRecoveryArtifacts() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        #expect(await store.execute(try capture(context: context), at: context.capturedAt).state == .locallyCommitted)
        for (directory, filename) in [("MigrationBackups", "Canonical.sqlite"), ("ProjectionQuarantine", "LocalProjection.sqlite")] {
            let nested = configuration.directory.appendingPathComponent(directory).appendingPathComponent("owned-fixture")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("owned recovery content".utf8).write(to: nested.appendingPathComponent(filename))
        }
        let unrelated = configuration.directory.appendingPathComponent("UserExports", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let retained = unrelated.appendingPathComponent("keep.json")
        let retainedBytes = Data("unrelated user export".utf8)
        try retainedBytes.write(to: retained)
        let sibling = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: sibling.directory) }
        try FileManager.default.createDirectory(at: sibling.directory, withIntermediateDirectories: true)
        let siblingFile = sibling.directory.appendingPathComponent("Canonical.sqlite")
        try retainedBytes.write(to: siblingFile)
        let deletion = try await store.deleteLocalData()
        #expect(deletion.deleted)
        for directory in ["MigrationBackups", "ProjectionQuarantine"] {
            #expect(!FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent(directory).path))
        }
        #expect(try Data(contentsOf: retained) == retainedBytes)
        #expect(try Data(contentsOf: siblingFile) == retainedBytes)
        let replacement = try await MirrorStore(configuration: #require(deletion.newConfiguration))
        #expect(try await replacement.snapshot().tasks.isEmpty)
        #expect(try await replacement.snapshot().records.isEmpty)
    }

    @Test("복구 자료 이름이 symlink여도 기기 내 삭제는 다른 공간의 대상 파일을 지우지 않는다")
    func localDeleteDoesNotFollowRecoveryArtifactSymlinks() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let other = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: other.directory) }
        try FileManager.default.createDirectory(at: other.directory, withIntermediateDirectories: true)
        let retained = other.directory.appendingPathComponent("keep.sqlite")
        let retainedBytes = Data("other space data".utf8)
        try retainedBytes.write(to: retained)
        for name in ["MigrationBackups", "ProjectionQuarantine"] {
            try FileManager.default.createSymbolicLink(at: configuration.directory.appendingPathComponent(name),
                                                      withDestinationURL: other.directory)
        }
        #expect(try await store.deleteLocalData().deleted)
        #expect(try Data(contentsOf: retained) == retainedBytes)
        for name in ["MigrationBackups", "ProjectionQuarantine"] {
            #expect(!FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent(name).path))
        }
    }

    @Test("기기 내 삭제는 원본과 캐시를 지우고 구 writer를 차단한다", arguments: [false, true])
    func localDeleteBlocksOldWriter(secondConnection: Bool) async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let first = try await MirrorStore(configuration: configuration)
        let oldWriter: MirrorStore?
        if secondConnection { oldWriter = try await MirrorStore(configuration: configuration) }
        else { oldWriter = nil }
        let context = try fixedContext()
        #expect(await first.execute(try capture(context: context), at: context.capturedAt).state == .locallyCommitted)
        try await first.setLocalValue(Data("private widget title".utf8), forKey: "widget")
        for name in ["WidgetSnapshot.json", "NotificationLedger.json"] {
            try Data("private local presentation".utf8).write(to: configuration.directory.appendingPathComponent(name))
        }
        let deletion = try await first.deleteLocalData()
        #expect(deletion.deleted)
        #expect(!FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent("Canonical.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent("LocalProjection.sqlite").path))
        for name in ["Canonical.sqlite", "LocalProjection.sqlite"] {
            for suffix in ["-wal", "-shm", "-journal"] {
                #expect(!FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent(name + suffix).path))
            }
        }
        for name in ["WidgetSnapshot.json", "NotificationLedger.json"] {
            #expect(!FileManager.default.fileExists(atPath: configuration.directory.appendingPathComponent(name).path))
        }
        await #expect(throws: StoreError.obsoleteEpoch) { try await first.taskProjections() }
        await #expect(throws: StoreError.obsoleteEpoch) { try await first.taskProjection(UUID()) }
        await #expect(throws: StoreError.obsoleteEpoch) { try await first.currentContext(at: context.capturedAt) }
        if let oldWriter {
            await #expect(throws: StoreError.obsoleteEpoch) { try await oldWriter.taskProjections() }
            await #expect(throws: StoreError.obsoleteEpoch) { try await oldWriter.taskProjection(UUID()) }
            await #expect(throws: StoreError.obsoleteEpoch) { try await oldWriter.currentContext(at: context.capturedAt) }
        }
        if let oldWriter { await #expect(throws: StoreError.obsoleteEpoch) { try await oldWriter.snapshot() } }
        let replacementConfiguration = try #require(deletion.newConfiguration)
        let replacement = try await MirrorStore(configuration: replacementConfiguration)
        #expect(try await replacement.snapshot().tasks.isEmpty)
        #expect(try await replacement.localValue(forKey: "widget") == nil)
        if let oldWriter {
            let stale = await oldWriter.execute(try capture(context: context), at: context.capturedAt)
            #expect(stale.state == .persistenceFailed)
        }
        let fresh = try capture(context: context, epoch: replacementConfiguration.workspaceEpoch)
        #expect(await replacement.execute(fresh, at: context.capturedAt).state == .locallyCommitted)
    }

    @Test("삭제한 뒤 export를 명시 복원해도 구 writer를 부활시키지 않는다")
    func restoreOriginalGraphAfterLocalDelete() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let first = try await MirrorStore(configuration: configuration)
        let oldWriter = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let original = try capture(context: context)
        #expect(await first.execute(original, at: context.capturedAt).state == .locallyCommitted)
        let before = try await first.snapshot()
        let archive = try await first.exportArchive(exportedAt: context.capturedAt)
        let deleted = try await first.deleteLocalData()
        let empty = try await MirrorStore(configuration: #require(deleted.newConfiguration))
        let preview = try await empty.previewArchive(archive)
        #expect(preview.requiresWorkspaceConfirmation)
        #expect(preview.taskCount == 1)
        await #expect(throws: StoreError.obsoleteEpoch) { try await empty.importArchive(archive) }
        await #expect(throws: StoreError.confirmationRequired) { try await empty.restoreArchiveAsLocalWorkspace(archive, confirmed: false) }
        let restored = try await empty.restoreArchiveAsLocalWorkspace(archive, confirmed: true)
        let final = try await MirrorStore(configuration: restored.newConfiguration)
        let after = try await final.snapshot()
        #expect(after.tasks == before.tasks)
        #expect(after.records == before.records)
        // domain epoch가 원래와 같아져도 별도 physical writer generation이 구 actor를 막는다.
        await #expect(throws: StoreError.obsoleteEpoch) { try await oldWriter.snapshot() }
        #expect(await final.execute(original, at: context.capturedAt).state == .alreadyApplied)
    }

    @Test("다른 공간을 복원한 뒤 공식 로컬 factory가 원래 공간과 명령을 다시 연다")
    func restoredWorkspaceReopensThroughLocalFactory() async throws {
        let sourceDirectory = temporaryConfiguration().directory
        let localDirectory = temporaryConfiguration().directory
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: localDirectory)
        }
        let sourceConfiguration = StoreConfiguration(directory: sourceDirectory, workspaceKey: "restored-personal-space",
            workspaceEpoch: "restored-generation", deviceID: testDeviceID)
        let localConfiguration = try StoreConfiguration.localConfiguration(in: localDirectory, deviceID: testDeviceID)
        let source = try await MirrorStore(configuration: sourceConfiguration)
        let local = try await MirrorStore(configuration: localConfiguration)
        let context = try fixedContext()
        let original = try capture(key: "restored-source", title: "원본 공간의 작업", context: context,
                                   epoch: sourceConfiguration.workspaceEpoch)
        let captured = await source.execute(original, at: context.capturedAt)
        #expect(captured.state == .locallyCommitted)
        let replaced = await local.execute(try capture(title: "교체할 기기 작업", context: context), at: context.capturedAt)
        #expect(replaced.state == .locallyCommitted)
        let expected = try await source.snapshot()
        let expectedRecord = try #require(expected.records.first)
        let archive = try await source.exportArchive(exportedAt: context.capturedAt)
        let preview = try await local.previewArchive(archive)
        #expect(preview.requiresWorkspaceConfirmation)
        let restoration = try await local.restoreArchiveAsLocalWorkspace(archive, confirmed: true)
        let restored = try await MirrorStore(configuration: restoration.newConfiguration)
        let immediate = try await restored.snapshot()
        #expect(immediate.tasks == expected.tasks)
        #expect(immediate.records == expected.records)
        try await restored.suspend()

        // 앱과 App Group의 공식 진입점이 실제로 공유하는 factory에 저장 디렉터리만 주입한다.
        let restartedConfiguration = try StoreConfiguration.localConfiguration(in: localDirectory, deviceID: testDeviceID)
        #expect(restartedConfiguration.workspaceKey == sourceConfiguration.workspaceKey)
        #expect(restartedConfiguration.workspaceEpoch == sourceConfiguration.workspaceEpoch)
        #expect(restartedConfiguration.directory == localDirectory)
        let reopened = try await MirrorStore(configuration: restartedConfiguration)
        let restarted = try await reopened.snapshot()
        #expect(restarted.tasks == expected.tasks)
        #expect(restarted.records == expected.records)
        let retry = await reopened.execute(original, at: context.capturedAt)
        #expect(retry.state == .alreadyApplied)
        #expect(retry.operationID == captured.operationID)
        let newCommand = try capture(key: "after-restored-restart", title: "재시작 뒤 새 작업", context: context,
                                     epoch: restartedConfiguration.workspaceEpoch)
        let newResult = await reopened.execute(newCommand, at: context.capturedAt)
        #expect(newResult.state == .locallyCommitted)
        let final = try await reopened.snapshot()
        #expect(Set(final.tasks.map(\.title)) == ["원본 공간의 작업", "재시작 뒤 새 작업"])
        #expect(final.records.count == 2)
        #expect(final.records.contains(expectedRecord))
        #expect(final.records.allSatisfy { $0.workspaceKey == sourceConfiguration.workspaceKey
            && $0.workspaceEpoch == sourceConfiguration.workspaceEpoch })
    }

    @Test("로컬 factory는 저장된 공간 키나 세대가 없으면 기본 공간으로 덮지 않는다",
          arguments: ["workspaceKey", "workspaceEpoch"])
    func localFactoryRejectsIncompleteStoredIdentity(missingField: String) throws {
        let directory = temporaryConfiguration().directory
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var identity = ["workspaceKey": "restored-personal-space", "workspaceEpoch": "restored-generation"]
        identity.removeValue(forKey: missingField)
        let bytes = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
        let identityURL = directory.appendingPathComponent("StorageIdentity.json")
        try bytes.write(to: identityURL, options: .atomic)
        #expect(throws: StoreError.invalidConfiguration) {
            try StoreConfiguration.localConfiguration(in: directory, deviceID: testDeviceID)
        }
        #expect(try Data(contentsOf: identityURL) == bytes)
    }

    @Test("복원 교체 중 종료는 같은 export로 재시도해 복구한다")
    func interruptedRestoreRecovery() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let source = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        #expect(await source.execute(try capture(context: context), at: context.capturedAt).state == .locallyCommitted)
        let original = try await source.snapshot()
        let archive = try await source.exportArchive(exportedAt: context.capturedAt)
        do {
            _ = try await source.restoreArchiveAsLocalWorkspace(archive, confirmed: true, failurePoint: .afterCanonicalSave)
            Issue.record("복원 경계 장애가 적용되어야 합니다.")
        } catch StoreError.persistence { }
        await #expect(throws: StoreError.busy) { try await MirrorStore(configuration: configuration) }
        let report = try await MirrorStore.recoverInterruptedLocalRestoration(from: archive,
            directory: configuration.directory, deviceID: testDeviceID, confirmed: true)
        let recovered = try await MirrorStore(configuration: report.newConfiguration)
        let snapshot = try await recovered.snapshot()
        #expect(snapshot.records == original.records)
        #expect(snapshot.tasks == original.tasks)
    }

    @Test("계정 출처가 다른 export는 같은 세대라도 명시 동의가 필요하다")
    func importAccountScopeConsent() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        #expect(await store.execute(try capture(context: context), at: context.capturedAt).state == .locallyCommitted)
        let data = try await store.exportArchive(exportedAt: context.capturedAt)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["sourceAccountScope"] = "account-another-nonsensitive-fingerprint"
        object["originAccountScopes"] = ["account-another-nonsensitive-fingerprint"]
        let otherAccount = try JSONSerialization.data(withJSONObject: object)
        #expect(try await store.previewArchive(otherAccount).requiresAccountConfirmation)
        await #expect(throws: StoreError.confirmationRequired) { try await store.importArchive(otherAccount) }
        let confirmed = try await store.importArchive(otherAccount, consent: ArchiveImportConsent(accountChangeConfirmed: true))
        #expect(confirmed.inserted == 0)
        #expect(confirmed.duplicates == 1)
        let preserved = try await store.exportArchive(exportedAt: context.capturedAt)
        let metadata = try #require(try JSONSerialization.jsonObject(with: preserved) as? [String: Any])
        #expect((metadata["originAccountScopes"] as? [String])?.contains("account-another-nonsensitive-fingerprint") == true)
    }

    @Test("계정 경계 suspend는 원본을 유지하고 구 writer를 차단한다")
    func suspendKeepsOriginalRecords() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let first = try await MirrorStore(configuration: configuration)
        let oldWriter = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        #expect(await first.execute(try capture(context: context), at: context.capturedAt).state == .locallyCommitted)
        try await first.suspend()
        await #expect(throws: StoreError.obsoleteEpoch) { try await oldWriter.snapshot() }
        try await oldWriter.suspend() // 다른 인스턴스가 revoke해도 자신의 store를 닫는다.
        try await oldWriter.suspend() // 종료 호출은 멱등적이다.
        let reopened = try await MirrorStore(configuration: configuration)
        #expect(try await reopened.snapshot().tasks.count == 1)
        #expect(try await reopened.snapshot().records.count == 1)
        #expect(await reopened.cloudStoreIdentifiers().isEmpty)
    }

    @Test("초기 원본 재생 뒤 세대 중지·전환은 낡은 initializer의 projection 저장을 막는다", arguments: [false, true])
    func initializationRechecksIdentityBeforeProjection(transitioning: Bool) async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let owner = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let envelope = try capture(key: "initialization-boundary", context: context)
        let committed = await owner.execute(envelope, at: context.capturedAt)
        #expect(committed.state == .locallyCommitted)
        let original = try await owner.snapshot()
        let observer = try await CoreDataPersistence.open(configuration: configuration)
        let projectionMarker = Data("new-owner-projection".utf8)
        let gate = ProcessWriteGate(url: configuration.directory.appendingPathComponent("Writer.lock"), timeout: configuration.lockTimeout)

        await #expect(throws: StoreError.obsoleteEpoch) {
            _ = try await MirrorStore(configuration: configuration, beforeInitialProjection: {
                if transitioning {
                    let lease = try await gate.acquire()
                    defer { lease.release() }
                    let url = configuration.directory.appendingPathComponent("StorageIdentity.json")
                    var identity = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                    identity["isTransitioning"] = true
                    try JSONSerialization.data(withJSONObject: identity).write(to: url, options: .atomic)
                } else {
                    // 실제 생산 suspend가 generation을 회전시킨다. canonical history는 바뀌지 않는다.
                    try await owner.suspend()
                }
                // 옛 initializer가 기존 history 분기의 saveProjection을 실행하면 이 값이 덮인다.
                try await observer.saveProjection(["policy": projectionMarker])
            })
        }
        #expect(try await observer.localValue(key: "policy") == projectionMarker)
        #expect(try await observer.operations().count == original.records.count)

        // 실패한 initializer는 최종 Writer.lock을 놓아야 하며 원본도 재진입·동일 키 재시도 가능해야 한다.
        let afterFailure = try await gate.acquire()
        defer { afterFailure.release() }
        if transitioning {
            let url = configuration.directory.appendingPathComponent("StorageIdentity.json")
            var identity = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            identity["isTransitioning"] = false
            try JSONSerialization.data(withJSONObject: identity).write(to: url, options: .atomic)
        }
        afterFailure.release()
        try await observer.close()
        let reopened = try await MirrorStore(configuration: configuration)
        let restored = try await reopened.snapshot()
        #expect(restored.tasks == original.tasks)
        #expect(restored.records == original.records)
        let retried = await reopened.execute(envelope, at: context.capturedAt)
        #expect(retried.state == .alreadyApplied)
        #expect(retried.operationID == committed.operationID)
        try await reopened.suspend()
        try await owner.suspend()
    }

    @Test("다른 SQLite store의 원본 알림 뒤 snapshot에 저장한 작업이 나타난다", .timeLimit(.minutes(1)))
    func canonicalChangeObservationAcrossInstances() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let reader = try await MirrorStore(configuration: configuration)
        let writer = try await MirrorStore(configuration: configuration)
        let stream = try await reader.changes(includeInitial: false)
        let context = try fixedContext()
        #expect(await writer.execute(try capture(title: "실제 저장소 알림", context: context), at: context.capturedAt).state == .locallyCommitted)
        #expect(try await nextChange(in: stream) == .canonicalChanged)
        let changed = try await reader.snapshot()
        #expect(changed.tasks.map(\.title) == ["실제 저장소 알림"])
        #expect(changed.records.count == 1)
    }

    @Test("투영과 영수증 저장은 원본 변경 stream의 refresh 반복을 만들지 않는다", .timeLimit(.minutes(1)))
    func localProjectionDoesNotPublishCanonicalChange() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let reader = try await MirrorStore(configuration: configuration)
        let writer = try await MirrorStore(configuration: configuration)
        let stream = try await reader.changes(includeInitial: false)
        try await writer.setLocalValue(Data("local presentation".utf8), forKey: "widget")
        await #expect(throws: ObservationTestError.timeout) { try await nextChange(in: stream, timeout: .milliseconds(350)) }
        #expect(try await reader.snapshot().records.isEmpty)
        #expect(try await reader.snapshot().tasks.isEmpty)
    }

    @Test("소비자 취소와 suspend는 변경 구독을 종료하며 원본을 남긴다", .timeLimit(.minutes(1)))
    func canonicalObservationTermination() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let cancelledStream = try await store.changes(includeInitial: false)
        let cancelled = Task {
            for await _ in cancelledStream { }
            return true
        }
        cancelled.cancel()
        #expect(await cancelled.value)
        let closingStream = try await store.changes(includeInitial: false)
        try await store.suspend()
        #expect(try await nextChange(in: closingStream) == nil)
        await #expect(throws: StoreError.obsoleteEpoch) { try await store.changes() }
        let reopened = try await MirrorStore(configuration: configuration)
        #expect(try await reopened.snapshot().records.isEmpty)
    }

    @Test("활성화 확인 시 export는 preview 이후 성공한 입력도 포함한다")
    func exportAndSuspendIncludesLatestInputs() async throws {
        let configuration = temporaryConfiguration(), targetConfiguration = temporaryConfiguration()
        defer {
            try? FileManager.default.removeItem(at: configuration.directory)
            try? FileManager.default.removeItem(at: targetConfiguration.directory)
        }
        let source = try await MirrorStore(configuration: configuration)
        let anotherWriter = try await MirrorStore(configuration: configuration)
        let target = try await MirrorStore(configuration: targetConfiguration)
        let context = try fixedContext()
        #expect(await source.execute(try capture(title: "미리보기 이전", context: context), at: context.capturedAt).state == .locallyCommitted)
        let oldPreview = try await source.exportArchive(exportedAt: context.capturedAt)
        #expect(try await target.previewArchive(oldPreview).operationCount == 1)
        #expect(await anotherWriter.execute(try capture(title: "미리보기 이후", context: context), at: context.capturedAt).state == .locallyCommitted)
        let latest = try await source.exportAndSuspend(exportedAt: context.capturedAt)
        #expect(try await target.previewArchive(latest).operationCount == 2)
        #expect(try await target.importArchive(latest).inserted == 2)
        #expect(try await target.snapshot().tasks.count == 2)
        await #expect(throws: StoreError.obsoleteEpoch) { try await anotherWriter.snapshot() }
    }

    #if os(macOS)
    @Test("두 실제 Swift writer 프로세스의 같은 봉투·토큰은 작업과 원본을 한 번만 저장한다", .timeLimit(.minutes(2)))
    func separateSwiftProcessesDeduplicateSameEnvelope() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let taskID = UUID()
        let envelope = try capture(id: taskID, key: "swift-process-shared-decision", title: "프로세스 경합 회귀", context: context)
        let envelopeURL = configuration.directory.appendingPathComponent("ProbeEnvelope.json")
        try CanonicalDigest.data(envelope).write(to: envelopeURL, options: .atomic)
        let start = configuration.directory.appendingPathComponent("ProbeStart")
        let readyFiles = (0..<2).map { configuration.directory.appendingPathComponent("ProbeReady-\($0)") }
        let reportFiles = (0..<2).map { configuration.directory.appendingPathComponent("ProbeReport-\($0).json") }
        let first = try StoreProbeChild(mode: "race", directory: configuration.directory, envelope: envelopeURL,
                                        ready: readyFiles[0], start: start, report: reportFiles[0], serviceInstant: context.capturedAt)
        defer { first.cleanup() }
        let second = try StoreProbeChild(mode: "race", directory: configuration.directory, envelope: envelopeURL,
                                         ready: readyFiles[1], start: start, report: reportFiles[1], serviceInstant: context.capturedAt)
        defer { second.cleanup() }
        try first.run()
        try second.run()
        try await waitForProbeReady([first, second], files: readyFiles)
        #expect(first.process.processIdentifier != second.process.processIdentifier)
        #expect(first.process.processIdentifier != ProcessInfo.processInfo.processIdentifier)
        #expect(second.process.processIdentifier != ProcessInfo.processInfo.processIdentifier)
        try Data("start".utf8).write(to: start, options: .atomic)
        try await waitForProbeExit([first, second])
        try #require(first.process.terminationReason == .exit && first.process.terminationStatus == 0,
                     "first helper: \(first.diagnostic)")
        try #require(second.process.terminationReason == .exit && second.process.terminationStatus == 0,
                     "second helper: \(second.diagnostic)")
        let reports = try reportFiles.map { try JSONDecoder().decode(StoreProbeReport.self, from: Data(contentsOf: $0)) }
        #expect(reports.filter { $0.state == .locallyCommitted }.count == 1)
        #expect(reports.filter { $0.state == .alreadyApplied }.count == 1)
        let operationID = try #require(reports[0].operationID)
        #expect(reports[1].operationID == operationID)
        #expect(reports.allSatisfy { $0.taskCount == 1 && $0.recordCount == 1 })
        let snapshot = try await store.snapshot()
        #expect(snapshot.tasks.count == 1)
        #expect(snapshot.tasks.first?.taskID == taskID)
        #expect(snapshot.records.count == 1)
        #expect(snapshot.records.first?.operationID == operationID)
        let retry = await store.execute(envelope, at: context.capturedAt)
        #expect(retry.state == .alreadyApplied)
        #expect(retry.operationID == operationID)
    }

    @Test("실제 Swift writer의 원본 저장 뒤 SIGKILL은 같은 요청으로 한 번 복구된다", .timeLimit(.minutes(2)))
    func separateSwiftProcessCanonicalCommitSurvivesSIGKILL() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        let context = try fixedContext()
        let taskID = UUID()
        let envelope = try capture(id: taskID, key: "swift-process-canonical-kill", title: "원본 종료 복구 회귀", context: context)
        let envelopeURL = configuration.directory.appendingPathComponent("ProbeEnvelope.json")
        try CanonicalDigest.data(envelope).write(to: envelopeURL, options: .atomic)
        let ready = configuration.directory.appendingPathComponent("ProbeCanonicalReady")
        let reportURL = configuration.directory.appendingPathComponent("ProbeCanonicalReport.json")
        let child = try StoreProbeChild(mode: "after-canonical", directory: configuration.directory, envelope: envelopeURL,
            ready: ready, start: configuration.directory.appendingPathComponent("UnusedStart"), report: reportURL,
            serviceInstant: context.capturedAt)
        defer { child.cleanup() }
        try child.run()
        try await waitForProbeReady([child], files: [ready])
        let report = try JSONDecoder().decode(StoreProbeReport.self, from: Data(contentsOf: reportURL))
        try #require(report.state == .committedProjectionPending)
        let committedOperationID = try #require(report.operationID)
        #expect(report.taskCount == nil && report.recordCount == nil)
        #expect(child.process.processIdentifier != ProcessInfo.processInfo.processIdentifier)
        try #require(Darwin.kill(child.process.processIdentifier, SIGKILL) == 0)
        try await waitForProbeExit([child])
        #expect(child.process.terminationReason == .uncaughtSignal)
        #expect(child.process.terminationStatus == SIGKILL)

        let reopened = try await MirrorStore(configuration: configuration)
        let recovered = try await reopened.snapshot()
        #expect(recovered.tasks.count == 1)
        #expect(recovered.tasks.first?.taskID == taskID)
        #expect(recovered.records.count == 1)
        #expect(recovered.records.first?.operationID == committedOperationID)
        let tomorrow = try fixedContext(day: "2026-10-01")
        let retry = await reopened.execute(envelope, at: tomorrow.capturedAt)
        #expect(retry.state == .alreadyApplied)
        #expect(retry.operationID == committedOperationID)
        let final = try await reopened.snapshot()
        #expect(final.tasks.count == 1)
        #expect(final.tasks.first?.taskID == taskID)
        #expect(final.records.count == 1)
    }

    @Test("별도 OS 프로세스의 잠금 중 원본은 늘지 않고 종료 뒤 같은 요청을 한 번 저장한다")
    func separateProcessWriteGateAndTerminationRelease() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let envelope = try capture(key: "process-boundary-decision", context: context)
        let lockURL = configuration.directory.appendingPathComponent("Writer.lock")
        let readyURL = configuration.directory.appendingPathComponent("HelperReady")
        let entryURL = configuration.directory.appendingPathComponent("HelperEntry")
        let beforeLockURL = configuration.directory.appendingPathComponent("HelperBeforeLock")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        helper.arguments = ["-u", "-c", """
        import sys
        with open(sys.argv[3], "w") as marker:
            marker.write("entry")
        import fcntl, pathlib, signal
        with open(sys.argv[1], "a+b") as handle:
            with open(sys.argv[4], "w") as marker:
                marker.write("before-lock")
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            pathlib.Path(sys.argv[2]).write_text("locked", encoding="utf-8")
            signal.pause()
        """, lockURL.path, readyURL.path, entryURL.path, beforeLockURL.path]
        helper.standardOutput = Pipe()
        helper.standardError = Pipe()
        let exitSignal = DispatchSemaphore(value: 0)
        helper.terminationHandler = { _ in exitSignal.signal() }
        try helper.run()
        defer { killAndReap(helper, exitSignal: exitSignal) }
        let clock = ContinuousClock()
        let readyDeadline = clock.now.advanced(by: .seconds(5))
        while helper.isRunning, !FileManager.default.fileExists(atPath: readyURL.path), clock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let lifecycle = helper.isRunning ? "running" :
            "reason=\(helper.terminationReason.rawValue),status=\(helper.terminationStatus)"
        let stage = "entry=\(FileManager.default.fileExists(atPath: entryURL.path)),beforeLock=\(FileManager.default.fileExists(atPath: beforeLockURL.path)),\(lifecycle)"
        try #require(helper.isRunning, "잠금 helper가 실제 별도 프로세스에서 실행되어야 합니다. \(stage)")
        try #require(FileManager.default.fileExists(atPath: readyURL.path), "helper의 잠금 획득을 확인해야 합니다. \(stage)")
        #expect(helper.processIdentifier != ProcessInfo.processInfo.processIdentifier)

        let blocked = await store.execute(envelope, at: context.capturedAt)
        #expect(blocked.state == .unavailable)
        #expect(blocked.operationID == nil)
        let beforeExit = try await store.snapshot()
        #expect(beforeExit.tasks.isEmpty)
        #expect(beforeExit.records.isEmpty)

        helper.terminate() // 명시 flock 해제 없이 프로세스 종료 시 OS가 잠금을 해제한다.
        let exitDeadline = clock.now.advanced(by: .seconds(5))
        while helper.isRunning, clock.now < exitDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!helper.isRunning, "helper 종료 후에만 생산 명령을 재시도합니다.")
        let reapDeadline = clock.now.advanced(by: .seconds(5))
        while !hasReapedExitSignal(exitSignal), clock.now < reapDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(hasReapedExitSignal(exitSignal),
                     "Python helper의 종료·회수 완료 신호는 5초 이내여야 합니다.")
        #expect(helper.terminationReason == .uncaughtSignal)

        let committed = await store.execute(envelope, at: context.capturedAt)
        #expect(committed.state == .locallyCommitted)
        let retry = await store.execute(envelope, at: context.capturedAt)
        #expect(retry.state == .alreadyApplied)
        #expect(retry.operationID == committed.operationID)
        let final = try await store.snapshot()
        #expect(final.tasks.count == 1)
        #expect(final.records.count == 1)
    }
    #endif
}
