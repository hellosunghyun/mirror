import Foundation
import MirrorDomain
@testable import MirrorData
import Testing

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

@Suite("실제 Core Data SQLite 저장과 복구")
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
        let settings = CommandEnvelope(requestID: "settings", idempotencyKey: "settings-key", source: .app,
            context: old, workspaceEpoch: configuration.workspaceEpoch,
            payload: .settings(policy: try PlanningPolicy(timeZoneID: "America/New_York", revision: "policy-v2"), expectedRevision: "policy-v1"))
        #expect(await store.execute(settings, at: old.capturedAt).state == .locallyCommitted)
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
    @Test("별도 OS 프로세스의 잠금 중 원본은 늘지 않고 종료 뒤 같은 요청을 한 번 저장한다")
    func separateProcessWriteGateAndTerminationRelease() async throws {
        let configuration = temporaryConfiguration()
        defer { try? FileManager.default.removeItem(at: configuration.directory) }
        let store = try await MirrorStore(configuration: configuration)
        let context = try fixedContext()
        let envelope = try capture(key: "process-boundary-decision", context: context)
        let lockURL = configuration.directory.appendingPathComponent("Writer.lock")
        let readyURL = configuration.directory.appendingPathComponent("HelperReady")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        helper.arguments = ["-u", "-c", """
        import fcntl, pathlib, signal, sys
        with open(sys.argv[1], "a+b") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            pathlib.Path(sys.argv[2]).write_text("locked", encoding="utf-8")
            signal.pause()
        """, lockURL.path, readyURL.path]
        helper.standardOutput = Pipe()
        helper.standardError = Pipe()
        try helper.run()
        defer {
            if helper.isRunning { helper.terminate() }
            helper.waitUntilExit()
        }
        let clock = ContinuousClock()
        let readyDeadline = clock.now.advanced(by: .seconds(5))
        while helper.isRunning, !FileManager.default.fileExists(atPath: readyURL.path), clock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(helper.isRunning, "잠금 helper가 실제 별도 프로세스에서 실행되어야 합니다.")
        try #require(FileManager.default.fileExists(atPath: readyURL.path), "helper의 잠금 획득을 확인해야 합니다.")
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
        helper.waitUntilExit()
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
