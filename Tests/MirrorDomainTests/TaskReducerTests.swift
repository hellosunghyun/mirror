import Foundation
import Testing
@testable import MirrorDomain

@Suite("D-03 인과적 리듀서·충돌·조건부 Undo")
struct TaskReducerTests {
    @Test("동일 원본을 세 번 수신해도 하나의 논리 기록과 작업만 남는다")
    func repeatedRecordIsAppliedOnce() throws {
        let capture = try CommandTestData.capture()
        let once = CommandTestData.reduce([capture])
        let repeated = CommandTestData.reduce([capture, capture, capture])
        #expect(repeated.tasks == once.tasks)
        #expect(repeated.appliedOperationIDs == [capture.operationID])
        #expect(repeated.pending.isEmpty)
        #expect(repeated.quarantined.isEmpty)
    }

    @Test("같은 ID의 서로 다른 원본은 도착 순서와 무관하게 격리한다")
    func conflictingIDNeverSilentlyOverwrites() throws {
        let capture = try CommandTestData.capture()
        let alternateContent = try TaskContent(title: "다른 원문")
        let otherMutations = capture.mutations.map { mutation in
            mutation.group == .content
                ? TaskMutation(taskID: mutation.taskID, value: .content(alternateContent))
                : mutation
        }
        let conflicting = try ReducerTestData.copy(capture, mutations: otherMutations)
        #expect(capture.payloadDigest != conflicting.payloadDigest)
        for records in [[capture, conflicting], [conflicting, capture], [capture, conflicting, capture]] {
            let result = CommandTestData.reduce(records)
            #expect(result.quarantined[capture.operationID] == .conflictingDuplicate)
            #expect(!result.appliedOperationIDs.contains(capture.operationID))
            #expect(result.tasks[CommandTestData.taskID] == nil)
        }
    }

    @Test("digest가 다른 손상 원본과 알 수 없는 schema는 보존 목록으로 격리한다")
    func invalidDigestAndUnknownSchema() throws {
        let capture = try CommandTestData.capture()
        let badDigest = try ReducerTestData.decodedCopy(capture, replacing: "payloadDigest", with: String(repeating: "0", count: 64))
        let invalid = CommandTestData.reduce([badDigest])
        #expect(invalid.quarantined[capture.operationID] == .invalidDigest)
        #expect(invalid.tasks.isEmpty)
        let unknown = try ReducerTestData.copy(capture, schemaVersion: 99)
        let future = CommandTestData.reduce([unknown])
        #expect(future.quarantined[capture.operationID] == .unsupportedSchema)
        #expect(future.tasks.isEmpty)
        #expect(future.appliedOperationIDs.isEmpty)
    }

    @Test("다른 공간·구세대 기록은 현재 작업을 부활시키지 않는다")
    func workspaceAndEpochIsolation() throws {
        let capture = try CommandTestData.capture()
        for other in [
            try ReducerTestData.copy(capture, workspaceKey: "other-account"),
            try ReducerTestData.copy(capture, workspaceEpoch: "epoch-before-delete")
        ] {
            let report = CommandTestData.reduce([other])
            #expect(report.tasks.isEmpty)
            #expect(report.quarantined[other.operationID] == .wrongWorkspace)
        }
    }

    @Test("제목과 계획의 동시 수정은 각 그룹을 독립적으로 보존한다")
    func independentContentAndPlanSurvive() throws {
        let capture = try CommandTestData.capture()
        let target = try PlanTarget.day(LocalDate("2026-10-02"))
        let plan = try ReducerTestData.operation("plan-a", kind: .setPlan, value: .plan(PlanValue(target: target)),
                                                parents: [capture.operationID])
        let content = try ReducerTestData.operation("content-b", kind: .editContent,
                                                   value: .content(TaskContent(title: "새 제목", note: "메모")),
                                                   parents: [capture.operationID], deviceID: CommandTestData.otherDeviceID)
        for records in ReducerTestData.permutations([capture, plan, content]) {
            let task = try CommandTestData.task(in: records)
            #expect(task.title == "새 제목")
            #expect(task.content.note == "메모")
            #expect(task.plan.target == target)
            #expect(task.status == .open)
            #expect(task.deadline == nil)
            #expect(task.conflictGroups.isEmpty)
        }
    }

    @Test("동시 계획은 시계가 뒤바뀌어도 같은 승자·head 집합·충돌로 수렴한다")
    func concurrentPlansConvergeAcrossEveryArrivalOrder() throws {
        let capture = try CommandTestData.capture()
        let earlyClock = try ReducerTestData.operation("plan-device-b", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-02")))), parents: [capture.operationID],
            lamport: 2, recordedAt: "2026-09-29T01:00:00Z", deviceID: CommandTestData.otherDeviceID)
        let fastClock = try ReducerTestData.operation("plan-device-a", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-01")))), parents: [capture.operationID],
            lamport: 2, recordedAt: "2026-10-01T01:00:00Z")
        let expectedTarget = try PlanTarget.day(LocalDate("2026-10-02"))
        var reference: TaskProjection?
        for records in ReducerTestData.permutations([capture, earlyClock, fastClock]) {
            let task = try CommandTestData.task(in: records + records + records)
            #expect(task.plan.target == expectedTarget)
            #expect(task.versions[.plan]?.winningOperationID == earlyClock.operationID)
            #expect(task.versions[.plan]?.headIDs == [fastClock.operationID, earlyClock.operationID].sorted())
            #expect(task.conflictGroups == [.plan])
            #expect(task.isProjectionComplete)
            if let reference { #expect(task == reference) } else { reference = task }
        }
    }

    @Test("후속 계획은 관측한 head 모두를 대체하며 충돌을 해소한다")
    func causalSuccessorResolvesConcurrentHeads() throws {
        let capture = try CommandTestData.capture()
        let a = try ReducerTestData.operation("plan-a", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-01")))), parents: [capture.operationID])
        let b = try ReducerTestData.operation("plan-b", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-02")))), parents: [capture.operationID],
            deviceID: CommandTestData.otherDeviceID)
        let resolved = try ReducerTestData.operation("resolved", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-05")))), parents: [a.operationID, b.operationID],
            lamport: 3, recordedAt: "2026-09-20T00:00:00Z")
        for records in ReducerTestData.permutations([capture, a, b, resolved]) {
            let task = try CommandTestData.task(in: records)
            #expect(task.plan.target == .day(try LocalDate("2026-10-05")))
            #expect(task.versions[.plan]?.headIDs == [resolved.operationID])
            #expect(task.conflictGroups.isEmpty)
        }
    }

    @Test("부모 미도착 원본은 pending으로 남고 부모 도착 후 같은 결과로 복구한다")
    func childWaitsForParent() throws {
        let capture = try CommandTestData.capture()
        let parent = try ReducerTestData.operation("parent-plan", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-01")))), parents: [capture.operationID])
        let child = try ReducerTestData.operation("child-plan", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-02")))), parents: [parent.operationID], lamport: 3)
        let incomplete = CommandTestData.reduce([capture, child])
        #expect(incomplete.pending[child.operationID] == .missingParent)
        #expect(incomplete.tasks[CommandTestData.taskID]?.plan.target == .unassigned)
        #expect(incomplete.tasks[CommandTestData.taskID]?.isProjectionComplete == false)
        #expect(!incomplete.appliedOperationIDs.contains(child.operationID))
        let recovered = CommandTestData.reduce([capture, child, parent])
        #expect(recovered.pending.isEmpty)
        #expect(recovered.tasks[CommandTestData.taskID]?.plan.target == .day(try LocalDate("2026-10-02")))
        #expect(recovered.tasks[CommandTestData.taskID]?.isProjectionComplete == true)
        #expect(recovered.tasks == CommandTestData.reduce([capture, parent, child]).tasks)
    }

    @Test("생성 원본보다 먼저 받은 변경은 생성 후 재생하며 임의 작업을 만들지 않는다")
    func mutationBeforeCaptureWaits() throws {
        let capture = try CommandTestData.capture()
        let plan = try ReducerTestData.operation("plan-before-create", kind: .setPlan,
            value: .plan(PlanValue(target: .parked)), parents: [capture.operationID])
        let pending = CommandTestData.reduce([plan])
        #expect(pending.tasks.isEmpty)
        #expect(pending.pending[plan.operationID] != nil)
        let recovered = CommandTestData.reduce([plan, capture])
        #expect(recovered.pending.isEmpty)
        #expect(recovered.tasks[CommandTestData.taskID]?.plan.target == .parked)
    }

    @Test("다른 작업·그룹의 head를 부모라고 제시하면 격리한다")
    func foreignParentsAreRejected() throws {
        let capture = try CommandTestData.capture()
        let other = try CommandTestData.capture(taskID: CommandTestData.otherTaskID, key: "other")
        let foreignTask = try ReducerTestData.operation("foreign-task-parent", kind: .setPlan,
                                                       value: .plan(PlanValue(target: .parked)), parents: [other.operationID])
        let content = try ReducerTestData.operation("content-parent", kind: .editContent,
                                                   value: .content(TaskContent(title: "새 제목")), parents: [capture.operationID])
        let foreignGroup = try ReducerTestData.operation("foreign-group-parent", kind: .setPlan,
                                                        value: .plan(PlanValue(target: .parked)), parents: [content.operationID], lamport: 3)
        let report = CommandTestData.reduce([capture, other, foreignTask, content, foreignGroup])
        #expect(report.quarantined[foreignTask.operationID] == .invalidParent)
        #expect(report.quarantined[foreignGroup.operationID] == .invalidParent)
        #expect(report.tasks[CommandTestData.taskID]?.plan.target == .unassigned)
    }

    @Test("완료와 계획 동시 수정은 완료를 유지하고 계획 이력을 보존한다")
    func completionIsNotReopenedByPlan() throws {
        let capture = try CommandTestData.capture()
        let completion = try ReducerTestData.operation("complete", kind: .setStatus,
            value: .status(StatusValue(status: .completed, completedAt: instant("2026-09-30T03:00:00Z"))),
            parents: [capture.operationID])
        let plan = try ReducerTestData.operation("future-plan", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-05")))), parents: [capture.operationID],
            lamport: 100, deviceID: CommandTestData.otherDeviceID)
        for records in ReducerTestData.permutations([capture, completion, plan]) {
            let task = try CommandTestData.task(in: records)
            #expect(task.status == .completed)
            #expect(task.plan.target == .day(try LocalDate("2026-10-05")))
            #expect(task.lifecycle.completedAt == (try instant("2026-09-30T03:00:00Z")))
        }
    }

    @Test("인과적으로 미해결인 상태는 삭제·완료·열림 순으로 안전 우선", arguments: [false, true])
    func statusSafetyPrecedesLamport(_ includeDeletion: Bool) throws {
        let capture = try CommandTestData.capture()
        let completion = try ReducerTestData.operation("complete-low-clock", kind: .setStatus,
            value: .status(StatusValue(status: .completed, completedAt: instant("2026-09-30T03:00:00Z"))),
            parents: [capture.operationID], lamport: 2)
        let staleReopen = try ReducerTestData.operation("reopen-high-clock", kind: .setStatus,
            value: .status(StatusValue(status: .open)), parents: [capture.operationID], lamport: 100,
            deviceID: CommandTestData.otherDeviceID)
        let deletion = try ReducerTestData.operation("delete-low-clock", kind: .setStatus,
            value: .status(StatusValue(status: .deleted, deletedAt: instant("2026-09-30T02:00:00Z"))),
            parents: [capture.operationID], lamport: 2)
        let records = [capture, completion, staleReopen] + (includeDeletion ? [deletion] : [])
        for order in ReducerTestData.permutations(records) {
            let task = try CommandTestData.task(in: order)
            #expect(task.status == (includeDeletion ? .deleted : .completed))
            #expect(task.conflictGroups == [.status])
            #expect(task.plan.target == .unassigned)
        }
    }

    @Test("완료 취소는 상태만 열고 과거 날짜를 오늘로 자동 이동하지 않는다")
    func explicitReopenPreservesPreviousPlan() throws {
        let capture = try CommandTestData.capture()
        let plan = try ReducerTestData.operation("past-plan", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-09-29")))), parents: [capture.operationID])
        let completion = try ReducerTestData.operation("complete", kind: .setStatus,
            value: .status(StatusValue(status: .completed, completedAt: instant("2026-09-29T03:00:00Z"))),
            parents: [capture.operationID])
        let current = try CommandTestData.task(in: [capture, plan, completion])
        let reopen = try CommandTestData.prepared(CommandTestData.command(.completion(
            taskID: current.taskID, desiredCompleted: false, expectedStatus: current.versions[.status]!.headsDigest)),
            records: [capture, plan, completion])
        let task = try CommandTestData.task(in: [capture, plan, completion, reopen.operation])
        #expect(task.status == .open)
        #expect(task.plan.target == .day(try LocalDate("2026-09-29")))
        #expect(!PlanningRules.isToday(task.planningState, on: try LocalDate("2026-09-30")))
    }

    @Test("휴지통 복구는 최신 삭제 head 전체를 명시적으로 참조한다")
    func restoreRequiresEveryDeleteHead() throws {
        let capture = try CommandTestData.capture()
        let a = try ReducerTestData.operation("delete-a", kind: .setStatus,
            value: .status(StatusValue(status: .deleted, deletedAt: instant("2026-09-30T02:00:00Z"))),
            parents: [capture.operationID])
        let b = try ReducerTestData.operation("delete-b", kind: .setStatus,
            value: .status(StatusValue(status: .deleted, deletedAt: instant("2026-09-30T03:00:00Z"))),
            parents: [capture.operationID], deviceID: CommandTestData.otherDeviceID)
        let records = [capture, a, b]
        let task = try CommandTestData.task(in: records)
        let incomplete = try CommandTestData.command(.restore(taskID: task.taskID, observedDeleteHeadIDs: [a.operationID],
                                                             expectedStatus: task.versions[.status]!.headsDigest))
        _ = try CommandTestData.rejection(CommandValidator.prepare(incomplete, snapshot: CommandTestData.snapshot(records: records)))
        let complete = try CommandTestData.command(.restore(taskID: task.taskID,
            observedDeleteHeadIDs: [a.operationID, b.operationID], expectedStatus: task.versions[.status]!.headsDigest))
        let restore = try CommandTestData.prepared(complete, records: records)
        let restored = try CommandTestData.task(in: records + [restore.operation])
        #expect(restored.status == .open)
        #expect(restored.plan == task.plan)
        #expect(restored.deadline == task.deadline)
        #expect(restored.conflictGroups.isEmpty)
    }

    @Test("plan Undo 후에도 새 content와 실제 마감은 유지한다")
    func undoOnlyAffectedGroup() throws {
        let capture = try CommandTestData.capture()
        let initial = try CommandTestData.task(in: [capture])
        let move = try CommandTestData.prepared(CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: initial.taskID, expected: ExpectedVersions(initial)),
            target: .day(LocalDate("2026-10-02")), review: nil), key: "move"), records: [capture])
        let afterMove = try CommandTestData.task(in: [capture, move.operation])
        let edit = try CommandTestData.prepared(CommandTestData.command(.editContent(
            taskID: initial.taskID, content: TaskContent(title: "바뀐 제목"),
            expectedContent: afterMove.versions[.content]!.headsDigest), key: "edit"), records: [capture, move.operation])
        let beforeUndo = CommandTestData.reduce([capture, move.operation, edit.operation])
        let undo = try CommandTestData.prepared(CommandTestData.command(.undo(operationID: move.operation.operationID,
            expected: move.operation.undoExpectations(in: beforeUndo.tasks)), key: "undo"),
            records: [capture, move.operation, edit.operation])
        let restored = try CommandTestData.task(in: [capture, move.operation, edit.operation, undo.operation])
        #expect(restored.plan == initial.plan)
        #expect(restored.title == "바뀐 제목")
        #expect(restored.deadline == initial.deadline)
        #expect(undo.operation.compensatesOperationID == move.operation.operationID)
        #expect(undo.operation.mutations.count == 1)
    }

    @Test("이미 받은 후속 계획을 Undo로 덮어쓰지 않는다")
    func undoRejectsReceivedFollowUp() throws {
        let capture = try CommandTestData.capture()
        let initial = try CommandTestData.task(in: [capture])
        let move = try CommandTestData.prepared(CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: initial.taskID, expected: ExpectedVersions(initial)),
            target: .day(LocalDate("2026-10-02")), review: nil), key: "move"), records: [capture])
        let afterMove = CommandTestData.reduce([capture, move.operation])
        let staleExpectation = move.operation.undoExpectations(in: afterMove.tasks)
        let later = try ReducerTestData.operation("later-plan", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-05")))), parents: [move.operation.operationID], lamport: 3)
        let undo = try CommandTestData.command(.undo(operationID: move.operation.operationID, expected: staleExpectation), key: "undo")
        let result = CommandValidator.prepare(undo, snapshot: try CommandTestData.snapshot(records: [capture, move.operation, later]))
        #expect(try CommandTestData.rejection(result).state == .staleSnapshot)
        // 바뀐 현재 stamp를 새로 넣어도 원본 결과가 아닌 후속 변경은 되돌리면 안 된다.
        let current = try CommandTestData.task(in: [capture, move.operation, later])
        let freshButWrong = try CommandTestData.command(.undo(operationID: move.operation.operationID,
            expected: [TaskVersionExpectation(taskID: current.taskID, group: .plan,
                                               headsDigest: current.versions[.plan]!.headsDigest)]), key: "undo-new")
        _ = try CommandTestData.rejection(CommandValidator.prepare(freshButWrong,
            snapshot: CommandTestData.snapshot(records: [capture, move.operation, later])))
        #expect(try CommandTestData.task(in: [capture, move.operation, later]).plan.target == .day(LocalDate("2026-10-05")))
    }

    @Test("오프라인 Undo와 새 계획이 동시면 lamport와 무관하게 일반 수정이 우선한다")
    func concurrentUserEditWinsOverUndo() throws {
        let capture = try CommandTestData.capture()
        let initial = try CommandTestData.task(in: [capture])
        let move = try CommandTestData.prepared(CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: initial.taskID, expected: ExpectedVersions(initial)),
            target: .day(LocalDate("2026-10-02")), review: nil), key: "move"), records: [capture])
        let afterMove = CommandTestData.reduce([capture, move.operation])
        let localUndo = try CommandTestData.prepared(CommandTestData.command(.undo(operationID: move.operation.operationID,
            expected: move.operation.undoExpectations(in: afterMove.tasks)), key: "undo"), records: [capture, move.operation])
        // 리듀서의 안전 규칙을 검사하려고 Undo만 큰 논리 시계로 다시 직렬화한다.
        let undo = try ReducerTestData.copy(localUndo.operation, lamport: 100)
        let edit = try ReducerTestData.operation("offline-user-edit", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-05")))), parents: [move.operation.operationID],
            lamport: 3, deviceID: CommandTestData.otherDeviceID)
        for records in ReducerTestData.permutations([capture, move.operation, undo, edit]) {
            let task = try CommandTestData.task(in: records)
            #expect(task.plan.target == .day(try LocalDate("2026-10-05")))
            #expect(task.versions[.plan]?.winningOperationID == edit.operationID)
            #expect(task.versions[.plan]?.headIDs == [undo.operationID, edit.operationID].sorted())
            #expect(task.conflictGroups.contains(.plan))
        }
    }

    @Test("삭제를 관측한 일반 reopen은 복구 reference 없이 작업을 부활시키지 못한다")
    func receivedRestoreMustReferenceDeletion() throws {
        let capture = try CommandTestData.capture()
        let deletion = try ReducerTestData.operation("delete", kind: .setStatus,
            value: .status(StatusValue(status: .deleted, deletedAt: instant("2026-09-30T03:00:00Z"))),
            parents: [capture.operationID])
        let invalid = try ReducerTestData.operation("restore-without-reference", kind: .setStatus,
            value: .status(StatusValue(status: .open)), parents: [deletion.operationID], lamport: 3)
        let result = CommandTestData.reduce([capture, deletion, invalid])
        #expect(result.quarantined[invalid.operationID] != nil)
        #expect(!result.appliedOperationIDs.contains(invalid.operationID))
        #expect(result.tasks[CommandTestData.taskID]?.status == .deleted)
        let valid = try ReducerTestData.operation("explicit-restore", kind: .setStatus,
            value: .status(StatusValue(status: .open, restoreReference: [deletion.operationID])),
            parents: [deletion.operationID], lamport: 3)
        #expect(try CommandTestData.task(in: [capture, deletion, valid]).status == .open)
    }

    @Test("부모보다 증가하지 않는 논리 시계는 유효한 후속 변경으로 적용하지 않는다")
    func nonIncreasingCausalLamportIsRejected() throws {
        let capture = try CommandTestData.capture()
        let parent = try ReducerTestData.operation("plan-parent", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-01")))), parents: [capture.operationID], lamport: 5)
        let child = try ReducerTestData.operation("invalid-child", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-02")))), parents: [parent.operationID], lamport: 5)
        let report = CommandTestData.reduce([capture, parent, child])
        #expect(report.quarantined[child.operationID] != nil)
        #expect(!report.appliedOperationIDs.contains(child.operationID))
        #expect(report.tasks[CommandTestData.taskID]?.plan.target == .day(try LocalDate("2026-10-01")))
    }

    @Test("배치 원본의 부모 하나가 없으면 나머지 작업에도 부분 반영하지 않는다")
    func receivedBatchIsAtomicWhenParentMissing() throws {
        let captures = try CommandTestData.batchCaptures(count: 20)
        let tasks = CommandTestData.reduce(captures).tasks.values.sorted { $0.taskID.uuidString < $1.taskID.uuidString }
        let items = tasks.map { PlanCommandItem(taskID: $0.taskID, expected: ExpectedVersions($0)) }
        let batch = try CommandTestData.prepared(CommandTestData.command(.batchSetPlan(
            items: items, target: .day(LocalDate("2026-10-01"))), key: "batch"), records: captures)
        let delayedCapture = captures[19]
        let incomplete = CommandTestData.reduce(Array(captures.prefix(19)) + [batch.operation])
        #expect(incomplete.tasks.count == 19)
        #expect(incomplete.pending[batch.operation.operationID] != nil)
        #expect(!incomplete.appliedOperationIDs.contains(batch.operation.operationID))
        #expect(incomplete.tasks.values.allSatisfy { $0.plan.target == .unassigned && !$0.isProjectionComplete })
        let recovered = CommandTestData.reduce(Array(captures.prefix(19)) + [batch.operation, delayedCapture])
        let target = try PlanTarget.day(LocalDate("2026-10-01"))
        #expect(recovered.tasks.count == 20)
        #expect(recovered.pending.isEmpty)
        #expect(recovered.tasks.values.allSatisfy { $0.plan.target == target && $0.isProjectionComplete })
    }

    @Test("다중 Undo 대상 하나에 후속 변경이 있으면 전체 보상 기록을 만들지 않는다")
    func batchUndoRejectsWholeGroup() throws {
        let captures = try CommandTestData.batchCaptures(count: 20)
        let tasks = CommandTestData.reduce(captures).tasks.values.sorted { $0.taskID.uuidString < $1.taskID.uuidString }
        let batch = try CommandTestData.prepared(CommandTestData.command(.batchSetPlan(
            items: tasks.map { PlanCommandItem(taskID: $0.taskID, expected: ExpectedVersions($0)) },
            target: .day(LocalDate("2026-10-01"))), key: "batch"), records: captures)
        let all = captures + [batch.operation]
        let unchangedExpectations = batch.operation.undoExpectations(in: CommandTestData.reduce(all).tasks)
        #expect(unchangedExpectations.count == 20)
        let later = try OperationRecord.create(operationID: "one-new-plan", workspaceKey: CommandTestData.workspaceKey,
            workspaceEpoch: CommandTestData.workspaceEpoch, deviceID: CommandTestData.otherDeviceID, lamport: 3,
            recordedAt: instant("2026-09-30T04:00:00Z"), commandKind: .setPlan,
            mutations: [TaskMutation(taskID: tasks[19].taskID, value: .plan(PlanValue(target: .parked)),
                                     observedHeadIDs: [batch.operation.operationID])])
        let command = try CommandTestData.command(.undo(operationID: batch.operation.operationID,
                                                       expected: unchangedExpectations), key: "batch-undo")
        let snapshot = try CommandTestData.snapshot(records: all + [later])
        #expect(try CommandTestData.rejection(CommandValidator.prepare(command, snapshot: snapshot)).state == .staleSnapshot)
        let target = try PlanTarget.day(LocalDate("2026-10-01"))
        #expect(snapshot.tasks.values.filter { $0.plan.target == target }.count == 19)
        #expect(snapshot.tasks[tasks[19].taskID]?.plan.target == .parked)
    }

    @Test("정리 확인은 해당 계획 버전에만 유효하고 종료는 미검토 작업을 바꾸지 않는다")
    func reviewAcknowledgmentAndClosurePreserveUnreviewedTasks() throws {
        let first = try CommandTestData.capture()
        let other = try CommandTestData.capture(taskID: CommandTestData.otherTaskID, key: "other")
        let original = try CommandTestData.task(in: [first, other])
        let cycle = try ReviewCycle.id(workspaceEpoch: CommandTestData.workspaceEpoch, context: context("2026-09-30"))
        let decision = ReviewDecisionContext(cycleID: cycle, sessionID: "session", cardID: "card", taskID: original.taskID)
        let move = try CommandTestData.prepared(CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: original.taskID, expected: ExpectedVersions(original)),
            target: .day(LocalDate("2026-09-30")), review: decision), key: "review-decision"), records: [first, other])
        let decided = CommandTestData.reduce([first, other, move.operation])
        #expect(decided.acknowledgments.count == 1)
        #expect(decided.acknowledges(task: decided.tasks[original.taskID]!, cycleID: cycle))
        #expect(!decided.acknowledges(task: decided.tasks[CommandTestData.otherTaskID]!, cycleID: cycle))
        let close = try CommandTestData.prepared(CommandTestData.command(.reviewClose(
            ReviewClosure(cycleID: cycle, sessionID: "session")), key: "close"), records: [first, other, move.operation])
        let closed = CommandTestData.reduce([first, other, move.operation, close.operation])
        #expect(closed.isCycleClosed(cycle))
        #expect(closed.tasks == decided.tasks)
        #expect(closed.tasks[CommandTestData.otherTaskID]?.plan.target == .unassigned)
        let newPlan = try ReducerTestData.operation("later-review-plan", kind: .setPlan,
            value: .plan(PlanValue(target: .parked)), parents: [move.operation.operationID], lamport: 4)
        let changed = CommandTestData.reduce([first, other, move.operation, close.operation, newPlan])
        #expect(!changed.acknowledges(task: changed.tasks[original.taskID]!, cycleID: cycle))
        #expect(changed.acknowledgments.count == 1)
    }

    @Test("분수 시각 원본은 정수 밀리초 저장·재생 뒤에도 같은 digest를 유지한다", arguments: [
        (1_790_000_000.123456, Int64(1_790_000_000_123)),
        (1_790_000_000.123001, Int64(1_790_000_000_123)),
        (1_790_000_000.123999, Int64(1_790_000_000_124)),
        (1_790_000_000.122999, Int64(1_790_000_000_123)),
        (1_790_000_000.124001, Int64(1_790_000_000_124))
    ])
    func fractionalTimestampDigestSurvivesCanonicalRoundTrip(_ seconds: Double, _ expectedMilliseconds: Int64) throws {
        let capture = try CommandTestData.capture()
        let timestamp = Date(timeIntervalSince1970: seconds)
        let record = try OperationRecord.create(operationID: "fractional-completion", workspaceKey: CommandTestData.workspaceKey,
            workspaceEpoch: CommandTestData.workspaceEpoch, deviceID: CommandTestData.deviceID, lamport: 2,
            recordedAt: timestamp, commandKind: .setStatus,
            mutations: [TaskMutation(taskID: CommandTestData.taskID,
                                     value: .status(StatusValue(status: .completed, completedAt: timestamp)),
                                     observedHeadIDs: [capture.operationID])])
        let bytes = try CanonicalDigest.data(record)
        let object = try CommandTestData.jsonObject(bytes)
        #expect((object["recordedAt"] as? NSNumber)?.int64Value == expectedMilliseconds)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let restored = try decoder.decode(OperationRecord.self, from: bytes)
        #expect(try restored.computedDigest() == record.payloadDigest)
        #expect(restored.payloadDigest == record.payloadDigest)
        #expect(try CanonicalDigest.data(restored) == bytes)
        #expect(restored.recordedAt == Date(timeIntervalSince1970: Double(expectedMilliseconds) / 1_000))
        let replay = CommandTestData.reduce([capture, restored])
        #expect(replay.quarantined.isEmpty)
        #expect(replay.tasks[CommandTestData.taskID]?.status == .completed)
    }

    @Test("알려진 순환 부모는 미도착 부모의 pending과 구분하여 격리한다")
    func knownParentCycleIsQuarantined() throws {
        let capture = try CommandTestData.capture()
        let a = try ReducerTestData.operation("cycle-a", kind: .setPlan, value: .plan(PlanValue(target: .parked)),
                                             parents: ["cycle-b"], lamport: 3)
        let b = try ReducerTestData.operation("cycle-b", kind: .setPlan, value: .plan(PlanValue(target: .parked)),
                                             parents: ["cycle-a"], lamport: 2)
        let selfCycle = try ReducerTestData.operation("cycle-self", kind: .setPlan, value: .plan(PlanValue(target: .parked)),
                                                     parents: ["cycle-self"], lamport: 2)
        let missing = try ReducerTestData.operation("absent-parent", kind: .setPlan, value: .plan(PlanValue(target: .parked)),
                                                   parents: ["not-received"], lamport: 2)
        let result = CommandTestData.reduce([capture, a, b, selfCycle, missing])
        for id in [a.operationID, b.operationID, selfCycle.operationID] {
            #expect(result.quarantined[id] == .cyclicDependency)
            #expect(result.pending[id] == nil)
        }
        #expect(result.pending[missing.operationID] == .missingParent)
        #expect(result.quarantined[missing.operationID] == nil)
        #expect(result.tasks[CommandTestData.taskID]?.plan.target == .unassigned)
    }

    @Test("수신 Undo는 원본의 이전 값과 다른 복원 값을 위조할 수 없다")
    func importedUndoCannotForgePreviousValue() throws {
        let capture = try CommandTestData.capture()
        let initial = try CommandTestData.task(in: [capture])
        let move = try CommandTestData.prepared(CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: initial.taskID, expected: ExpectedVersions(initial)),
            target: .day(LocalDate("2026-10-02")), review: nil), key: "move"), records: [capture])
        let undo = try CommandTestData.prepared(CommandTestData.command(.undo(operationID: move.operation.operationID,
            expected: move.operation.undoExpectations()), key: "undo"), records: [capture, move.operation])
        let forged = try ReducerTestData.copy(undo.operation, mutations: [
            TaskMutation(taskID: initial.taskID, value: .plan(PlanValue(target: .day(LocalDate("2026-10-05")))),
                         observedHeadIDs: [move.operation.operationID])
        ])
        let result = CommandTestData.reduce([capture, move.operation, forged])
        #expect(result.quarantined[forged.operationID] != nil)
        #expect(!result.appliedOperationIDs.contains(forged.operationID))
        #expect(result.tasks[initial.taskID]?.plan.target == .day(try LocalDate("2026-10-02")))
    }
}

enum ReducerTestData {
    static func operation(_ id: String, kind: OperationKind, value: MutationValue, parents: [String],
                          lamport: Int64 = 2, recordedAt: String = "2026-09-30T03:00:00Z",
                          deviceID: UUID = CommandTestData.deviceID) throws -> OperationRecord {
        try OperationRecord.create(operationID: id, workspaceKey: CommandTestData.workspaceKey,
                                   workspaceEpoch: CommandTestData.workspaceEpoch, deviceID: deviceID,
                                   lamport: lamport, recordedAt: instant(recordedAt), commandKind: kind,
                                   mutations: [TaskMutation(taskID: CommandTestData.taskID, value: value, observedHeadIDs: parents)])
    }

    static func copy(_ record: OperationRecord, mutations: [TaskMutation]? = nil, schemaVersion: Int? = nil,
                     workspaceKey: String? = nil, workspaceEpoch: String? = nil, lamport: Int64? = nil) throws -> OperationRecord {
        try OperationRecord.create(operationID: record.operationID, schemaVersion: schemaVersion ?? record.schemaVersion,
                                   workspaceKey: workspaceKey ?? record.workspaceKey, workspaceEpoch: workspaceEpoch ?? record.workspaceEpoch,
                                   deviceID: record.deviceID, lamport: lamport ?? record.lamport,
                                   recordedAt: record.recordedAt, commandKind: record.commandKind,
                                   mutations: mutations ?? record.mutations, idempotencyKey: record.idempotencyKey,
                                   logicalCommandDigest: record.logicalCommandDigest, undoValues: record.undoValues,
                                   compensatesOperationID: record.compensatesOperationID, reviewDecision: record.reviewDecision,
                                   reviewClosure: record.reviewClosure, settings: record.settings)
    }

    static func decodedCopy(_ record: OperationRecord, replacing field: String, with value: Any) throws -> OperationRecord {
        let data = try CanonicalDigest.data(record)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandTestFailure.expected("테스트 원본은 JSON 객체여야 합니다")
        }
        object[field] = value
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(OperationRecord.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    static func permutations<T>(_ values: [T]) -> [[T]] {
        guard !values.isEmpty else { return [[]] }
        return values.indices.flatMap { index -> [[T]] in
            var rest = values
            let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }
}
