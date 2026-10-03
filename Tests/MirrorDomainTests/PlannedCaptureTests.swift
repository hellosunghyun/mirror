import Foundation
import Testing
@testable import MirrorDomain

@Suite("선택적 날짜 입력의 원자적 생성·구버전 보존")
struct PlannedCaptureTests {
    private func command(_ target: PlanTarget) throws -> CommandEnvelope {
        try CommandTestData.command(.captureWithPlan(taskID: CommandTestData.taskID,
            content: TaskContent(title: "직접 정한 일", note: "원문 메모"), initialPlan: target))
    }

    @Test("직접 정한 내일은 한 생성 기록이고 오늘·미검토 큐에 섞이지 않는다")
    func plannedDayIsOneOpenCreation() throws {
        let target = PlanTarget.day(try LocalDate("2026-10-01"))
        let prepared = try CommandTestData.prepared(command(target))
        let record = prepared.operation
        #expect(record.schemaVersion == 2)
        #expect(record.commandKind == .capture)
        #expect(record.mutations.count == 4)
        #expect(record.mutations.allSatisfy { $0.observedHeadIDs.isEmpty })
        let report = CommandTestData.reduce([record])
        #expect(report.quarantined.isEmpty)
        #expect(report.pending.isEmpty)
        let task = try CommandTestData.task(in: [record])
        #expect(task.title == "직접 정한 일")
        #expect(task.content.note == "원문 메모")
        #expect(task.plan.target == target)
        #expect(task.status == .open)
        #expect(task.deadline == nil)
        #expect(!PlanningRules.isToday(task.planningState, on: try LocalDate("2026-09-30")))
    }

    @Test("주만 정한 생성은 월요일 작업이 되지 않고 reviewNotBefore를 보존한다")
    func plannedWeekRetainsUndecidedDay() throws {
        let target = PlanTarget.week(startDate: try LocalDate("2026-09-28"), endExclusiveDate: try LocalDate("2026-10-05"))
        let record = try CommandTestData.prepared(command(target)).operation
        let task = try CommandTestData.task(in: [record])
        #expect(task.plan.target == target)
        #expect(task.plan.reviewNotBefore == (try LocalDate("2026-10-01")))
        #expect(!PlanningRules.isToday(task.planningState, on: try LocalDate("2026-09-30")))
    }

    @Test("과거 날짜·주·미지정·보관은 명시적 날짜 생성으로 저장하지 않는다", arguments: [
        PlanTarget.day(try! LocalDate("2026-09-29")),
        PlanTarget.week(startDate: try! LocalDate("2026-09-21"), endExclusiveDate: try! LocalDate("2026-09-28")),
        .unassigned, .parked
    ])
    func rejectsInvalidInitialPlan(_ target: PlanTarget) throws {
        guard case let .rejected(error) = CommandValidator.prepare(try command(target), snapshot: CommandTestData.snapshot()) else {
            Issue.record("잘못된 첫 날짜는 생성 기록을 만들면 안 된다.")
            return
        }
        #expect(error.state == .unavailable)
    }

    @Test("기존 날짜 없는 capture는 v1 원본과 기존 wire·digest를 그대로 쓴다")
    func defaultCaptureRemainsVersionOne() throws {
        let content = try TaskContent(title: "기존 입력")
        let old = try CommandTestData.command(.capture(taskID: CommandTestData.taskID, content: content))
        let prepared = try CommandTestData.prepared(old)
        #expect(prepared.operation.schemaVersion == 1)
        #expect(try CommandTestData.task(in: [prepared.operation]).plan.target == .unassigned)
        let object = try CommandTestData.jsonObject(CanonicalDigest.data(old))
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(payload["initialPlan"] == nil)
        #expect(Set(payload.keys).isSubset(of: ["title", "note", "sourceURL"]))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let restored = try decoder.decode(CommandEnvelope.self, from: CanonicalDigest.data(old))
        #expect(restored.payload == old.payload)
        #expect(try restored.logicalDigest() == old.logicalDigest())
    }

    @Test("선택한 날짜는 wire 왕복과 논리 결정 키에 바인딩한다")
    func selectedDateSurvivesWireAndChangesDigest() throws {
        let first = try command(.day(LocalDate("2026-09-30")))
        let second = try command(.day(LocalDate("2026-10-01")))
        let bytes = try CanonicalDigest.data(first)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let restored = try decoder.decode(CommandEnvelope.self, from: bytes)
        #expect(restored.payload == first.payload)
        #expect(try restored.logicalDigest() == first.logicalDigest())
        #expect(try first.logicalDigest() != second.logicalDigest())
    }

    @Test("계획한 생성도 Undo로 복구 가능한 휴지통 이동을 한다")
    func plannedCaptureUndoKeepsContentAndDate() throws {
        let creation = try CommandTestData.prepared(command(.day(LocalDate("2026-10-01")))).operation
        let undo = try CommandTestData.command(.undo(operationID: creation.operationID, expected: creation.undoExpectations()), key: "undo-planned")
        let compensating = try CommandTestData.prepared(undo, records: [creation]).operation
        let task = try CommandTestData.task(in: [creation, compensating])
        #expect(task.status == .deleted)
        #expect(task.title == "직접 정한 일")
        #expect(task.plan.target == .day(try LocalDate("2026-10-01")))
    }

    @Test("v2의 다른 명령은 지원한 것처럼 재생하지 않는다")
    func onlyPlannedCreationSupportsVersionTwo() throws {
        let creation = try CommandTestData.capture()
        let task = try CommandTestData.task(in: [creation])
        let envelope = try CommandTestData.command(.completion(taskID: task.taskID, desiredCompleted: true,
            expectedStatus: task.versions[.status]!.headsDigest), key: "complete-v2")
        let original = try CommandTestData.prepared(envelope, records: [creation]).operation
        let unsupported = try OperationRecord.create(operationID: original.operationID, schemaVersion: 2,
            workspaceKey: original.workspaceKey, workspaceEpoch: original.workspaceEpoch, deviceID: original.deviceID,
            lamport: original.lamport, recordedAt: original.recordedAt, commandKind: original.commandKind,
            mutations: original.mutations, idempotencyKey: original.idempotencyKey,
            logicalCommandDigest: original.logicalCommandDigest, undoValues: original.undoValues)
        #expect(CommandTestData.reduce([creation, unsupported]).quarantined[unsupported.operationID] == .unsupportedSchema)
    }
}
