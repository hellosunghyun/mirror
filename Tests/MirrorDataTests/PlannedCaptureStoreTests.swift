import Foundation
import MirrorDomain
import Testing
@testable import MirrorData

@Suite("직접 날짜 입력의 실제 원본 저장·재시작·멱등성")
struct PlannedCaptureStoreTests {
    private func configuration() -> StoreConfiguration {
        StoreConfiguration(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MirrorPlannedCapture-\(UUID().uuidString)"),
            deviceID: "11111111-1111-4111-8111-111111111111")
    }
    private func context(_ day: String = "2026-09-30") throws -> PlanningContext {
        try PlanningContext(planningDay: LocalDate(day), timeZoneID: "Asia/Seoul", policyRevision: "policy-v1",
            capturedAt: ISO8601DateFormatter().date(from: "\(day)T03:00:00Z")!)
    }
    private func envelope(id: UUID, context: PlanningContext, epoch: String) throws -> CommandEnvelope {
        CommandEnvelope(requestID: "planned-capture", idempotencyKey: "same-planned-capture", source: .app,
            context: context, workspaceEpoch: epoch, payload: .captureWithPlan(taskID: id,
                content: try TaskContent(title: "내일도 남을 제목", note: "보존할 메모"),
                initialPlan: .day(try LocalDate("2026-10-01"))))
    }

    @Test("원본 저장 경계의 실패에도 제목과 날짜를 일부만 저장하지 않는다", arguments: [
        StoreFailurePoint.beforeCanonicalSave, .afterCanonicalSave, .beforeReceiptSave
    ])
    func creationIsAtomicAcrossFailure(_ point: StoreFailurePoint) async throws {
        let config = configuration()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let store = try await MirrorStore(configuration: config)
        let displayed = try context()
        let id = UUID()
        let command = try envelope(id: id, context: displayed, epoch: config.workspaceEpoch)
        let first = await store.execute(command, at: displayed.capturedAt, failurePoint: point)
        #expect(first.state == (point == .beforeCanonicalSave ? .persistenceFailed : .committedProjectionPending))
        let reopened = try await MirrorStore(configuration: config)
        let beforeRetry = try await reopened.snapshot()
        #expect(beforeRetry.tasks.count == (point == .beforeCanonicalSave ? 0 : 1))
        if let existing = beforeRetry.tasks.first {
            #expect(existing.title == "내일도 남을 제목")
            #expect(existing.plan.target == .day(try LocalDate("2026-10-01")))
            #expect(existing.status == .open)
        }
        let retry = await reopened.execute(command, at: displayed.capturedAt)
        #expect(retry.state == (point == .beforeCanonicalSave ? .locallyCommitted : .alreadyApplied))
        let restored = try await reopened.snapshot()
        #expect(restored.records.count == 1)
        #expect(restored.quarantinedCount == 0)
        let task = try #require(restored.tasks.first)
        #expect(task.taskID == id)
        #expect(task.content.note == "보존할 메모")
        #expect(task.plan.target == .day(try LocalDate("2026-10-01")))
        #expect(task.status == .open)
        #expect(task.deadline == nil)
        let nextDay = try context("2026-10-01")
        #expect(await reopened.execute(command, at: nextDay.capturedAt).state == .alreadyApplied)
        #expect(try await reopened.snapshot().records.count == 1)
    }

    @Test("새벽 날짜가 바뀐 선택은 제목만 남기지 않고 생성을 거절한다")
    func staleSelectedDateCreatesNothing() async throws {
        let config = configuration()
        defer { try? FileManager.default.removeItem(at: config.directory) }
        let store = try await MirrorStore(configuration: config)
        let old = try context()
        let next = try context("2026-10-01")
        let command = try envelope(id: UUID(), context: old, epoch: config.workspaceEpoch)
        #expect(await store.execute(command, at: next.capturedAt).state == .staleContext)
        let snapshot = try await store.snapshot()
        #expect(snapshot.tasks.isEmpty)
        #expect(snapshot.records.isEmpty)
    }
}
