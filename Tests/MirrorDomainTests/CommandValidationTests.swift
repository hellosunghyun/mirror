import Foundation
import Testing
@testable import MirrorDomain

@Suite("D-03 공개 명령의 입력·버전·멱등성 계약")
struct CommandValidationTests {
    @Test("제목 공백을 정리하되 원문 메모·URL·여러 줄을 보존한다")
    func captureContentPreservesMeaning() throws {
        let note = "첫 줄\n둘째 줄\n한 👨‍👩‍👧‍👦"
        let source = "https://example.com/path?q=%ED%95%9C%EA%B8%80#original"
        let content = try TaskContent(title: "  첫째\n둘째  \n", note: note, sourceURL: source)
        #expect(content.title == "첫째\n둘째")
        #expect(content.note == note)
        #expect(content.sourceURL == source)
        #expect(try JSONDecoder().decode(TaskContent.self, from: JSONEncoder().encode(content)) == content)
    }

    @Test("빈 제목은 입력을 잘라 새 작업으로 만들지 않는다", arguments: ["", " ", "\n\t\r", "　 \n"])
    func rejectsWhitespaceTitle(_ title: String) {
        #expect(throws: DomainContractError.invalidContent) { try TaskContent(title: title) }
    }

    @Test("제목 상한은 UTF-8 바이트가 아닌 확장 문자소 500개", arguments: ["한", "한", "👨‍👩‍👧‍👦", "🇰🇷", "e\u{301}"])
    func extendedGraphemeTitleLimit(_ grapheme: String) throws {
        let allowed = String(repeating: grapheme, count: 500)
        let excessive = String(repeating: grapheme, count: 501)
        #expect(allowed.count == 500)
        let content = try TaskContent(title: allowed)
        #expect(content.title == allowed)
        #expect(throws: DomainContractError.invalidContent) { try TaskContent(title: excessive) }
    }

    @Test("메모 상한도 확장 문자소 20,000개이며 자동으로 자르지 않는다")
    func noteLimit() throws {
        let allowed = String(repeating: "👨‍👩‍👧‍👦", count: 20_000)
        let content = try TaskContent(title: "메모", note: allowed)
        #expect(content.note == allowed)
        #expect(throws: DomainContractError.invalidContent) {
            try TaskContent(title: "메모", note: allowed + "한")
        }
    }

    @Test("출처는 외부 실행 코드나 로컬 파일·인증정보 URL을 받지 않는다", arguments: [
        "javascript:alert(1)", "file:///private/note", "https://user:password@example.com/",
        "https:///missing-host", " https://example.com", "https://example.com\n"
    ])
    func rejectsUnsafeSourceURL(_ source: String) {
        #expect(throws: DomainContractError.invalidSourceURL) {
            try TaskContent(title: "원문", sourceURL: source)
        }
    }

    @Test("직렬화된 내용도 길이·제목·URL 검증을 우회하지 못한다", arguments: [
        #"{"title":" \n\t","note":null,"sourceURL":null}"#,
        #"{"title":"입력","note":null,"sourceURL":"javascript:alert(1)"}"#
    ])
    func decodedContentIsValidated(_ json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TaskContent.self, from: Data(json.utf8))
        }
    }

    @Test("head digest는 순서와 무관하고 작업·그룹·경계를 구분한다")
    func versionDigestScopeAndOrdering() {
        let taskID = CommandTestData.taskID
        let first = VersionStamp(taskID: taskID, group: .plan, winningOperationID: "c", headIDs: ["ab", "c"])
        let reordered = VersionStamp(taskID: taskID, group: .plan, winningOperationID: "c", headIDs: ["c", "ab"])
        let sameConcatenation = VersionStamp(taskID: taskID, group: .plan, winningOperationID: "bc", headIDs: ["a", "bc"])
        let otherGroup = VersionStamp(taskID: taskID, group: .content, winningOperationID: "c", headIDs: ["ab", "c"])
        let otherTask = VersionStamp(taskID: CommandTestData.otherTaskID, group: .plan,
                                     winningOperationID: "c", headIDs: ["ab", "c"])
        #expect(first == reordered)
        #expect(first.headsDigest.count == 64)
        #expect(first.headsDigest != sameConcatenation.headsDigest)
        #expect(first.headsDigest != otherGroup.headsDigest)
        #expect(first.headsDigest != otherTask.headsDigest)
    }

    @Test("제목이 같아도 새 요청은 서로 다른 작업이며 처음에는 미배치·미완료다")
    func captureCreatesIndependentUnassignedTasks() throws {
        let first = try CommandTestData.capture(taskID: CommandTestData.taskID, key: "capture-a", title: "같은 제목")
        let second = try CommandTestData.capture(taskID: CommandTestData.otherTaskID, key: "capture-b", title: "같은 제목")
        let report = CommandTestData.reduce([first, second])
        #expect(report.tasks.count == 2)
        for task in report.tasks.values {
            #expect(task.title == "같은 제목")
            #expect(task.status == .open)
            #expect(task.plan.target == .unassigned)
            #expect(task.deadline == nil)
            #expect(!PlanningRules.isToday(task.planningState, on: try LocalDate("2026-09-30")))
        }
    }

    @Test("오늘 배치는 plan만 바꾸며 완료·제목·실제 마감을 변경하지 않는다")
    func setPlanDoesNotCompleteTask() throws {
        let capture = try CommandTestData.capture()
        let base = try CommandTestData.task(in: [capture])
        let target = try PlanTarget.day(LocalDate("2026-09-30"))
        let command = try CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: base.taskID, expected: ExpectedVersions(base)), target: target, review: nil))
        let prepared = try CommandTestData.prepared(command, records: [capture])
        #expect(prepared.operation.mutations.count == 1)
        #expect(prepared.operation.mutations.first?.value == .plan(PlanValue(target: target)))
        let changed = try CommandTestData.task(in: [capture, prepared.operation])
        #expect(changed.plan.target == target)
        #expect(changed.status == .open)
        #expect(changed.content == base.content)
        #expect(changed.deadline == base.deadline)
        #expect(changed.versions[.status] == base.versions[.status])
    }

    @Test("같은 결정의 영수증은 자정·시간대·정책 변경보다 먼저 반환된다")
    func durableReceiptPrecedesStaleContext() throws {
        let capture = try CommandTestData.capture()
        let task = try CommandTestData.task(in: [capture])
        let command = try CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: task.taskID, expected: ExpectedVersions(task)),
            target: .day(LocalDate("2026-10-01")), review: nil), key: "same-card")
        let prepared = try CommandTestData.prepared(command, records: [capture])
        let receipt = CommandTestData.receipt(for: command, prepared: prepared)
        let changedContext = try context("2026-10-01", timeZoneID: "America/Los_Angeles", revision: "policy-v2")
        let snapshot = try CommandTestData.snapshot(records: [capture, prepared.operation],
                                                    receipts: [receipt], currentContext: changedContext)
        guard case let .alreadyApplied(returned) = CommandValidator.prepare(command, snapshot: snapshot) else {
            throw CommandTestFailure.expected("저장된 영수증이 staleContext보다 먼저 반환되어야 합니다")
        }
        #expect(returned.operationID == prepared.operation.operationID)
        #expect(returned.key == "same-card")
        #expect(returned.digest == prepared.logicalDigest)
    }

    @Test("영수증 캐시가 없어도 동일 결정 원본에서 결과를 복구한다")
    func originalRecordRecoversReceipt() throws {
        let capture = try CommandTestData.capture()
        let task = try CommandTestData.task(in: [capture])
        let command = try CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: task.taskID, expected: ExpectedVersions(task)),
            target: .day(LocalDate("2026-10-01")), review: nil), key: "recover-key")
        let prepared = try CommandTestData.prepared(command, records: [capture])
        let later = try CommandTestData.snapshot(records: [capture, prepared.operation],
                                                 currentContext: context("2026-10-02"))
        guard case let .alreadyApplied(receipt) = CommandValidator.prepare(command, snapshot: later) else {
            throw CommandTestFailure.expected("영수증 캐시 없이 원본 기록으로 재시도를 복구해야 합니다")
        }
        #expect(receipt.operationID == prepared.operation.operationID)
        #expect(CommandTestData.reduce([capture, prepared.operation]).appliedOperationIDs.count == 2)
    }

    @Test("같은 카드에서 다른 목적지를 눌러도 먼저 저장한 결정을 보존한다")
    func differentPayloadForSameKeyIsAlreadyDecided() throws {
        let capture = try CommandTestData.capture()
        let task = try CommandTestData.task(in: [capture])
        let item = PlanCommandItem(taskID: task.taskID, expected: ExpectedVersions(task))
        let first = try CommandTestData.command(.setPlan(item: item, target: .day(LocalDate("2026-10-01")), review: nil),
                                                key: "one-card")
        let committed = try CommandTestData.prepared(first, records: [capture])
        let other = try CommandTestData.command(.setPlan(item: item, target: .day(LocalDate("2026-09-30")), review: nil),
                                                key: "one-card", requestID: "second-call")
        let snapshot = try CommandTestData.snapshot(records: [capture, committed.operation],
                                                    receipts: [CommandTestData.receipt(for: first, prepared: committed)])
        guard case let .alreadyDecided(receipt) = CommandValidator.prepare(other, snapshot: snapshot) else {
            throw CommandTestFailure.expected("같은 결정 키의 다른 payload는 alreadyDecided여야 합니다")
        }
        #expect(receipt.operationID == committed.operation.operationID)
        #expect(try CommandTestData.task(in: snapshot.records).plan.target == .day(LocalDate("2026-10-01")))
    }

    @Test("requestID·출처·표시 시각은 동일 사용자 결정의 payload digest를 바꾸지 않는다")
    func retryMetadataDoesNotChangeLogicalDigest() throws {
        let payload = CommandPayload.capture(taskID: CommandTestData.taskID, content: try TaskContent(title: "제목"))
        let first = try CommandTestData.command(payload, key: "capture-key", requestID: "call-a")
        let second = CommandEnvelope(requestID: "call-b", idempotencyKey: "capture-key", source: .widget,
                                     context: try context("2026-10-01"), workspaceEpoch: CommandTestData.workspaceEpoch,
                                     payload: payload)
        #expect(try first.logicalDigest() == second.logicalDigest())
    }

    @Test("아직 처리하지 않은 자정 전 카드는 새로운 오늘 날짜로 재해석하지 않는다")
    func uncommittedOldCardIsStale() throws {
        let capture = try CommandTestData.capture()
        let task = try CommandTestData.task(in: [capture])
        let command = try CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: task.taskID, expected: ExpectedVersions(task)),
            target: .day(LocalDate("2026-09-30")), review: nil))
        let snapshot = try CommandTestData.snapshot(records: [capture], currentContext: context("2026-10-01"))
        #expect(try CommandTestData.rejection(CommandValidator.prepare(command, snapshot: snapshot)).state == .staleContext)
        #expect(try CommandTestData.task(in: snapshot.records).plan.target == .unassigned)
    }

    @Test("완료된 카드의 오래된 날짜 입력은 상태 버전 검증에서 거부한다")
    func completedTaskRejectsOldPlanCard() throws {
        let capture = try CommandTestData.capture()
        let original = try CommandTestData.task(in: [capture])
        let completion = try CommandTestData.prepared(
            CommandTestData.command(.completion(taskID: original.taskID, desiredCompleted: true,
                                                expectedStatus: original.versions[.status]!.headsDigest), key: "complete"),
            records: [capture])
        let oldCard = try CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: original.taskID, expected: ExpectedVersions(original)),
            target: .day(LocalDate("2026-10-01")), review: nil), key: "old-card")
        let snapshot = try CommandTestData.snapshot(records: [capture, completion.operation])
        #expect(try CommandTestData.rejection(CommandValidator.prepare(oldCard, snapshot: snapshot)).state == .staleSnapshot)
        #expect(snapshot.tasks[original.taskID]?.status == .completed)
        #expect(snapshot.tasks[original.taskID]?.plan.target == .unassigned)
    }

    @Test("20개 배치는 하나의 원본에 모두 기록한다")
    func twentyTaskBatchIsOneOperation() throws {
        let records = try CommandTestData.batchCaptures(count: 20)
        let tasks = CommandTestData.reduce(records).tasks
        let items = tasks.values.sorted { $0.taskID.uuidString < $1.taskID.uuidString }
            .map { PlanCommandItem(taskID: $0.taskID, expected: ExpectedVersions($0)) }
        let command = try CommandTestData.command(.batchSetPlan(items: items, target: .day(LocalDate("2026-10-01"))))
        let prepared = try CommandTestData.prepared(command, records: records)
        #expect(prepared.operation.mutations.count == 20)
        #expect(Set(prepared.operation.mutations.map(\.taskID)).count == 20)
        let report = CommandTestData.reduce(records + [prepared.operation])
        #expect(report.appliedOperationIDs.count == 21)
        let target = try PlanTarget.day(LocalDate("2026-10-01"))
        #expect(report.tasks.values.allSatisfy { $0.plan.target == target })
    }

    @Test("배치 대상 하나가 stale이면 준비된 원본과 부분 성공이 없다")
    func staleBatchMemberRejectsWholeBatch() throws {
        let records = try CommandTestData.batchCaptures(count: 20)
        let before = CommandTestData.reduce(records)
        let tasks = before.tasks.values.sorted { $0.taskID.uuidString < $1.taskID.uuidString }
        let items = tasks.enumerated().map { index, task in
            PlanCommandItem(taskID: task.taskID, expected: index == 19
                            ? ExpectedVersions(content: task.versions[.content]!.headsDigest,
                                               plan: "stale-plan", status: task.versions[.status]!.headsDigest,
                                               deadline: task.versions[.deadline]!.headsDigest)
                            : ExpectedVersions(task))
        }
        let command = try CommandTestData.command(.batchSetPlan(items: items, target: .day(LocalDate("2026-10-01"))))
        let result = CommandValidator.prepare(command, snapshot: try CommandTestData.snapshot(records: records))
        #expect(try CommandTestData.rejection(result).state == .staleSnapshot)
        #expect(before.tasks.values.allSatisfy { $0.plan.target == .unassigned })
    }

    @Test("21개 또는 중복 작업 배치는 상한·원자성을 우회하지 못한다")
    func invalidBatchSizesAndDuplicates() throws {
        let records = try CommandTestData.batchCaptures(count: 21)
        let tasks = CommandTestData.reduce(records).tasks.values.sorted { $0.taskID.uuidString < $1.taskID.uuidString }
        let all = tasks.map { PlanCommandItem(taskID: $0.taskID, expected: ExpectedVersions($0)) }
        for items in [all, [all[0], all[0]], []] {
            let command = try CommandTestData.command(.batchSetPlan(items: items, target: .day(LocalDate("2026-10-01"))))
            _ = try CommandTestData.rejection(CommandValidator.prepare(command,
                                                                        snapshot: CommandTestData.snapshot(records: records)))
        }
    }

    @Test("승자 ID가 그대로여도 숨은 동시 head가 생기면 오래된 카드를 거부한다")
    func sameWinnerDifferentHeadsIsStale() throws {
        let capture = try CommandTestData.capture()
        let winner = try ReducerTestData.operation("winning-plan", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-02")))), parents: [capture.operationID], lamport: 3)
        let displayed = try CommandTestData.task(in: [capture, winner])
        let losing = try ReducerTestData.operation("hidden-plan", kind: .setPlan,
            value: .plan(PlanValue(target: .day(LocalDate("2026-10-01")))), parents: [capture.operationID], lamport: 2)
        let current = try CommandTestData.task(in: [capture, winner, losing])
        #expect(current.versions[.plan]?.winningOperationID == displayed.versions[.plan]?.winningOperationID)
        #expect(current.versions[.plan]?.headsDigest != displayed.versions[.plan]?.headsDigest)
        let oldCard = try CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: displayed.taskID, expected: ExpectedVersions(displayed)),
            target: .day(LocalDate("2026-10-05")), review: nil))
        let rejected = CommandValidator.prepare(oldCard, snapshot: try CommandTestData.snapshot(records: [capture, winner, losing]))
        #expect(try CommandTestData.rejection(rejected).state == .staleSnapshot)
    }

    @Test("마감 이후 배치는 정확한 마감 버전·작업·목적지 확인에만 허용한다")
    func afterDeadlineRequiresBoundAcknowledgment() throws {
        let capture = try CommandTestData.capture()
        let actualDeadline = try Deadline.day(localDate: LocalDate("2026-10-02"), timeZoneID: "Asia/Seoul")
        let deadline = try ReducerTestData.operation("deadline", kind: .setDeadline, value: .deadline(actualDeadline),
                                                    parents: [capture.operationID])
        let records = [capture, deadline]
        let task = try CommandTestData.task(in: records)
        let target = try PlanTarget.day(LocalDate("2026-10-03"))
        let version = task.versions[.deadline]!.headsDigest
        let acknowledgments: [DeadlineAcknowledgment?] = [
            nil,
            DeadlineAcknowledgment(taskID: task.taskID.uuidString, deadlineRevision: "old-deadline", target: target),
            DeadlineAcknowledgment(taskID: CommandTestData.otherTaskID.uuidString, deadlineRevision: version, target: target),
            DeadlineAcknowledgment(taskID: task.taskID.uuidString, deadlineRevision: version, target: .parked)
        ]
        for acknowledgment in acknowledgments {
            let command = try CommandTestData.command(.setPlan(
                item: PlanCommandItem(taskID: task.taskID, expected: ExpectedVersions(task), acknowledgment: acknowledgment),
                target: target, review: nil))
            #expect(try CommandTestData.rejection(CommandValidator.prepare(command,
                snapshot: CommandTestData.snapshot(records: records))).state == .requiresConfirmation)
        }
        let valid = DeadlineAcknowledgment(taskID: task.taskID.uuidString, deadlineRevision: version, target: target)
        let accepted = try CommandTestData.prepared(CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: task.taskID, expected: ExpectedVersions(task), acknowledgment: valid),
            target: target, review: nil)), records: records)
        let updated = try CommandTestData.task(in: records + [accepted.operation])
        #expect(updated.plan.target == target)
        #expect(updated.deadline == actualDeadline)
        #expect(updated.versions[.deadline] == task.versions[.deadline])
    }

    @Test("완료 입력은 원하는 상태 설정이며 새 호출로 반복해도 반전하지 않는다")
    func repeatedDesiredCompletionDoesNotToggle() throws {
        let capture = try CommandTestData.capture()
        let initial = try CommandTestData.task(in: [capture])
        let first = try CommandTestData.prepared(CommandTestData.command(.completion(
            taskID: initial.taskID, desiredCompleted: true, expectedStatus: initial.versions[.status]!.headsDigest), key: "done-1"),
            records: [capture])
        let completed = try CommandTestData.task(in: [capture, first.operation])
        let second = try CommandTestData.prepared(CommandTestData.command(.completion(
            taskID: initial.taskID, desiredCompleted: true, expectedStatus: completed.versions[.status]!.headsDigest), key: "done-2"),
            records: [capture, first.operation])
        let result = try CommandTestData.task(in: [capture, first.operation, second.operation])
        #expect(result.status == .completed)
        #expect(result.lifecycle.completedAt == completed.lifecycle.completedAt)
        #expect(result.plan == initial.plan)
    }

    @Test("주의 요일 미정은 주간 계획과 재검토 유예를 한 그룹으로 기록한다")
    func currentAndNextWeekDeferral() throws {
        let capture = try CommandTestData.capture()
        let task = try CommandTestData.task(in: [capture])
        let cases = [("2026-09-28", "2026-10-05", "2026-10-01"),
                     ("2026-10-05", "2026-10-12", "2026-10-05")]
        for (start, end, reviewDate) in cases {
            let target = try PlanTarget.week(startDate: LocalDate(start), endExclusiveDate: LocalDate(end))
            let prepared = try CommandTestData.prepared(CommandTestData.command(.setPlan(
                item: PlanCommandItem(taskID: task.taskID, expected: ExpectedVersions(task)), target: target, review: nil)),
                records: [capture])
            let projected = try CommandTestData.task(in: [capture, prepared.operation])
            #expect(projected.plan.target == target)
            #expect(projected.plan.reviewNotBefore == (try LocalDate(reviewDate)))
            #expect(projected.status == .open)
            #expect(!PlanningRules.isToday(projected.planningState, on: try LocalDate("2026-09-30")))
        }
    }

    @Test("정리 입력은 화면에 표시한 작업 ID와 주기에만 적용한다")
    func reviewCardCannotTargetDifferentTask() throws {
        let capture = try CommandTestData.capture()
        let task = try CommandTestData.task(in: [capture])
        let cycle = try ReviewCycle.id(workspaceEpoch: CommandTestData.workspaceEpoch, context: context("2026-09-30"))
        let review = ReviewDecisionContext(cycleID: cycle, sessionID: "session", cardID: "card",
                                          taskID: CommandTestData.otherTaskID)
        let command = try CommandTestData.command(.setPlan(
            item: PlanCommandItem(taskID: task.taskID, expected: ExpectedVersions(task)),
            target: .day(LocalDate("2026-10-01")), review: review))
        #expect(try CommandTestData.rejection(CommandValidator.prepare(command,
            snapshot: CommandTestData.snapshot(records: [capture]))).state == .staleSnapshot)
    }

    @Test("미지원 봉투·빈 요청 키·상한 초과 요청은 원본을 만들지 않는다")
    func malformedEnvelopeIsRejected() throws {
        let payload = CommandPayload.capture(taskID: CommandTestData.taskID, content: try TaskContent(title: "유효한 제목"))
        let values = [
            (2, "request", "key"), (1, " ", "key"), (1, "request", "\n"),
            (1, String(repeating: "r", count: 201), "key"), (1, "request", String(repeating: "k", count: 201))
        ]
        for (version, request, key) in values {
            let envelope = CommandEnvelope(contractVersion: version, requestID: request, idempotencyKey: key,
                                           source: .app, context: try context("2026-09-30"),
                                           workspaceEpoch: CommandTestData.workspaceEpoch, payload: payload)
            #expect(try CommandTestData.rejection(CommandValidator.prepare(envelope,
                snapshot: CommandTestData.snapshot())).state == .unavailable)
        }
    }

    @Test("다른 세대의 같은 키 영수증은 현재 공간의 새 결정을 막지 않는다")
    func receiptIsScopedToWorkspaceEpoch() throws {
        let command = try CommandTestData.command(.capture(taskID: CommandTestData.taskID, content: TaskContent(title: "새 작업")))
        let receipt = CommandReceipt(workspaceEpoch: "old-epoch", key: command.idempotencyKey,
                                     digest: try command.logicalDigest(), operationID: "old-operation",
                                     result: CommandResult(requestID: "old", operationID: "old-operation",
                                                           state: .locallyCommitted, safeUserMessage: "이전 공간"))
        let result = CommandValidator.prepare(command, snapshot: try CommandTestData.snapshot(receipts: [receipt]))
        guard case let .prepared(new) = result else {
            throw CommandTestFailure.expected("다른 세대 영수증을 현재 결과로 재사용하면 안 됩니다")
        }
        #expect(new.operation.workspaceEpoch == CommandTestData.workspaceEpoch)
        #expect(new.operation.operationID != receipt.operationID)
    }

    @Test("원본 v1 setPlan JSON을 taskID·expectedVersions·payload 계약으로 읽는다")
    func decodesOriginalCommandEnvelopeShape() throws {
        let decoded = try CommandTestData.decodeWireObject(CommandTestData.setPlanWireObject())
        #expect(decoded.contractVersion == 1)
        #expect(decoded.kind == .setPlan)
        #expect(decoded.requestID == "wire-request")
        #expect(decoded.idempotencyKey == "wire-card")
        #expect(decoded.source == .widget)
        #expect(decoded.context.planningDay == (try LocalDate("2026-09-30")))
        #expect(decoded.context.timeZoneID == "Asia/Seoul")
        #expect(decoded.context.policyRevision == "policy-v1")
        // wire context에는 capturedAt이 없으므로 시스템 현재 시각을 가져오지 않는다.
        #expect(decoded.context.capturedAt == Date(timeIntervalSince1970: 0))
        guard case let .setPlan(item, target, review) = decoded.payload else {
            throw CommandTestFailure.expected("setPlan은 해당 명령 payload로 읽어야 합니다")
        }
        #expect(item.taskID == CommandTestData.taskID)
        #expect(item.expected == ExpectedVersions(content: "content-v1", plan: "plan-v1", status: "status-v1", deadline: "deadline-v1"))
        #expect(target == .day(try LocalDate("2026-10-01")))
        #expect(review == nil)
        #expect(item.acknowledgment == nil)
    }

    @Test("v1 봉투 인코딩은 Swift enum 내부 모양과 capturedAt을 wire에 노출하지 않는다")
    func encodedEnvelopeUsesDocumentedKeys() throws {
        let command = try CommandTestData.decodeWireObject(CommandTestData.setPlanWireObject())
        let data = try CanonicalDigest.data(command)
        let object = try CommandTestData.jsonObject(data)
        #expect(Set(object.keys) == ["contractVersion", "requestID", "idempotencyKey", "kind", "source", "context",
                                      "taskID", "expectedVersions", "payload", "workspaceEpoch"])
        #expect(object["kind"] as? String == "setPlan")
        #expect(object["taskID"] as? String == CommandTestData.taskID.uuidString)
        let wireContext = try #require(object["context"] as? [String: Any])
        #expect(Set(wireContext.keys) == ["planningDay", "timeZoneID", "policyRevision"])
        #expect(wireContext["capturedAt"] == nil)
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(Set(payload.keys) == ["target"])
        #expect(payload["setPlan"] == nil)
        let target = try #require(payload["target"] as? [String: Any])
        #expect(target["kind"] as? String == "day")
        #expect(target["date"] as? String == "2026-10-01")
    }

    @Test("12개 공개 명령의 wire 왕복은 payload·논리 digest·정책을 보존한다")
    func everyPublicCommandRoundTrips() throws {
        let id = CommandTestData.taskID
        let expected = ExpectedVersions(content: "content-v1", plan: "plan-v1", status: "status-v1", deadline: "deadline-v1")
        let target = try PlanTarget.day(LocalDate("2026-10-03"))
        let acknowledgment = DeadlineAcknowledgment(taskID: id.uuidString, deadlineRevision: "deadline-v1", target: target)
        let review = ReviewDecisionContext(cycleID: "cycle", sessionID: "session", cardID: "card", taskID: id)
        let item = PlanCommandItem(taskID: id, expected: expected, acknowledgment: acknowledgment)
        let content = try TaskContent(title: "한 👨‍👩‍👧‍👦", note: "첫째\n둘째", sourceURL: "https://example.com/source")
        let deadline = try Deadline.day(localDate: LocalDate("2026-10-02"), timeZoneID: "Asia/Seoul")
        let payloads: [CommandPayload] = [
            .capture(taskID: id, content: content),
            .setPlan(item: item, target: target, review: review),
            .completion(taskID: id, desiredCompleted: true, expectedStatus: "status-v1"),
            .setDeadline(taskID: id, deadline: deadline, expectedDeadline: "deadline-v1"),
            .editContent(taskID: id, content: content, expectedContent: "content-v1"),
            .park(taskID: id, expected: expected),
            .trash(taskID: id, expectedStatus: "status-v1"),
            .restore(taskID: id, observedDeleteHeadIDs: ["delete-a", "delete-b"], expectedStatus: "status-v1"),
            .undo(operationID: "original", expected: [TaskVersionExpectation(taskID: id, group: .plan, headsDigest: "plan-v1")]),
            .reviewClose(ReviewClosure(cycleID: "cycle", sessionID: "session", weeklyCoverageStartDate: try LocalDate("2026-09-28"))),
            .batchSetPlan(items: [item], target: target),
            .settings(policy: try PlanningPolicy(timeZoneID: "America/Los_Angeles", revision: "policy-v2"), expectedRevision: "policy-v1")
        ]
        // setDeadline의 nil은 payload 누락이 아닌 명시적인 마감 삭제다.
        let timed = Deadline.instant(utcTimestamp: try instant("2026-10-02T06:30:00Z"), displayTimeZoneID: "Asia/Seoul")
        let all = payloads + [.setDeadline(taskID: id, deadline: nil, expectedDeadline: "deadline-v1"),
                              .setDeadline(taskID: id, deadline: timed, expectedDeadline: "deadline-v1")]
        #expect(Set(payloads.map(\.kind)).count == 12)
        for payload in all {
            let command = try CommandTestData.command(payload, key: "round-trip-\(payload.kind.rawValue)")
            let data = try CanonicalDigest.data(command)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let restored = try decoder.decode(CommandEnvelope.self, from: data)
            #expect(restored.payload == command.payload)
            #expect(restored.kind == command.kind)
            #expect(restored.source == command.source)
            #expect(restored.requestID == command.requestID)
            #expect(restored.idempotencyKey == command.idempotencyKey)
            #expect(restored.workspaceEpoch == command.workspaceEpoch)
            #expect(restored.context.planningDay == command.context.planningDay)
            #expect(restored.context.timeZoneID == command.context.timeZoneID)
            #expect(restored.context.policyRevision == command.context.policyRevision)
            #expect(restored.context.capturedAt == Date(timeIntervalSince1970: 0))
            #expect(try restored.logicalDigest() == command.logicalDigest())
        }
    }

    @Test("봉투·context·payload·expectedVersions의 알 수 없는 키는 거부한다", arguments: [
        "envelope", "context", "payload", "expectedVersions"
    ])
    func rejectsUnknownWireKeys(_ section: String) throws {
        var object = CommandTestData.setPlanWireObject()
        if section == "envelope" { object["unrecognized"] = "ignored-value" }
        else {
            var nested = try #require(object[section] as? [String: Any])
            nested["unrecognized"] = "ignored-value"
            object[section] = nested
        }
        #expect(throws: (any Error).self) { try CommandTestData.decodeWireObject(object) }
    }

    @Test("명령 kind와 payload 조합·필수 taskID·버전 봉투가 맞지 않으면 거부한다")
    func rejectsMismatchedOrIncompleteWirePayloads() throws {
        let base = CommandTestData.setPlanWireObject()
        var cases: [[String: Any]] = []
        var captureWithPlan = base
        captureWithPlan["kind"] = "capture"
        cases.append(captureWithPlan)
        var planWithCompletion = base
        planWithCompletion["payload"] = ["desiredCompleted": true]
        cases.append(planWithCompletion)
        var ambiguousPlan = base
        ambiguousPlan["payload"] = ["target": ["kind": "day", "date": "2026-10-01"], "desiredCompleted": true]
        cases.append(ambiguousPlan)
        var relativeTarget = base
        relativeTarget["payload"] = ["target": ["kind": "tomorrow"]]
        cases.append(relativeTarget)
        var noTaskID = base
        noTaskID.removeValue(forKey: "taskID")
        cases.append(noTaskID)
        var noExpectedVersions = base
        noExpectedVersions.removeValue(forKey: "expectedVersions")
        cases.append(noExpectedVersions)
        var emptyVersion = base
        emptyVersion["expectedVersions"] = ["content": "content-v1", "plan": "", "status": "status-v1", "deadline": "deadline-v1"]
        cases.append(emptyVersion)
        var numericVersion = base
        numericVersion["expectedVersions"] = ["plan": 7]
        cases.append(numericVersion)
        var invalidDate = base
        invalidDate["context"] = ["planningDay": "2026-02-30", "timeZoneID": "Asia/Seoul", "policyRevision": "policy-v1"]
        cases.append(invalidDate)
        var invalidZone = base
        invalidZone["context"] = ["planningDay": "2026-09-30", "timeZoneID": "invalid/Zone", "policyRevision": "policy-v1"]
        cases.append(invalidZone)
        var unknownSource = base
        unknownSource["source"] = "publicWebServer"
        cases.append(unknownSource)
        var invalidID = base
        invalidID["taskID"] = "the-current-task"
        cases.append(invalidID)
        var unknownKind = base
        unknownKind["kind"] = "toggleCompletion"
        cases.append(unknownKind)
        var unsupported = base
        unsupported["contractVersion"] = 2
        cases.append(unsupported)
        for object in cases {
            #expect(throws: (any Error).self) { try CommandTestData.decodeWireObject(object) }
        }
    }

    @Test("명시적 null deadline은 삭제로 왕복하지만 누락 payload는 삭제로 해석하지 않는다")
    func deadlineClearRequiresExplicitNull() throws {
        let command = try CommandTestData.command(.setDeadline(taskID: CommandTestData.taskID, deadline: nil,
                                                             expectedDeadline: "deadline-v1"))
        var object = try CommandTestData.jsonObject(CanonicalDigest.data(command))
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(Set(payload.keys) == ["deadline"])
        #expect(payload["deadline"] is NSNull)
        let restored = try CommandTestData.decodeWireObject(object)
        #expect(restored.payload == command.payload)
        object["payload"] = [String: Any]()
        #expect(throws: (any Error).self) { try CommandTestData.decodeWireObject(object) }
    }

    @Test("분수 시각 마감도 wire 왕복 후 같은 논리 결정 digest를 유지한다", arguments: [
        (1_790_000_000.123456, Int64(1_790_000_000_123)),
        (1_790_000_000.123001, Int64(1_790_000_000_123)),
        (1_790_000_000.123999, Int64(1_790_000_000_124)),
        (1_790_000_000.122999, Int64(1_790_000_000_123)),
        (1_790_000_000.124001, Int64(1_790_000_000_124))
    ])
    func fractionalDeadlineLogicalDigestSurvivesWireRoundTrip(_ seconds: Double, _ expectedMilliseconds: Int64) throws {
        let deadline = Deadline.instant(utcTimestamp: Date(timeIntervalSince1970: seconds), displayTimeZoneID: "Asia/Seoul")
        let command = try CommandTestData.command(.setDeadline(taskID: CommandTestData.taskID, deadline: deadline,
                                                             expectedDeadline: "deadline-v1"))
        let bytes = try CanonicalDigest.data(command)
        let restored = try CommandTestData.decodeWireObject(CommandTestData.jsonObject(bytes))
        #expect(try restored.logicalDigest() == command.logicalDigest())
        #expect(try CanonicalDigest.data(restored) == bytes)
        guard case let .setDeadline(id, .instant(timestamp, zone)?, stamp) = restored.payload else {
            throw CommandTestFailure.expected("시각 마감의 UTC timestamp와 표시 시간대가 보존되어야 합니다")
        }
        #expect(id == CommandTestData.taskID)
        #expect(stamp == "deadline-v1")
        #expect(zone == "Asia/Seoul")
        #expect(timestamp == Date(timeIntervalSince1970: Double(expectedMilliseconds) / 1_000))
    }
}

enum CommandTestData {
    static let taskID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let otherTaskID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let deviceID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    static let otherDeviceID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    static let workspaceKey = "personal-test"
    static let workspaceEpoch = "epoch-test-1"

    static func command(_ payload: CommandPayload, key: String = "new-decision", requestID: String = "request-test",
                        displayedContext: PlanningContext? = nil) throws -> CommandEnvelope {
        CommandEnvelope(requestID: requestID, idempotencyKey: key, source: .app,
                        context: try displayedContext ?? context("2026-09-30"),
                        workspaceEpoch: workspaceEpoch, payload: payload)
    }

    static func snapshot(records: [OperationRecord] = [], receipts: [CommandReceipt] = [],
                         currentContext: PlanningContext? = nil) throws -> CommandSnapshot {
        CommandSnapshot(workspaceKey: workspaceKey, workspaceEpoch: workspaceEpoch, deviceID: deviceID,
                        currentContext: try currentContext ?? context("2026-09-30"),
                        recordedAt: try instant("2026-09-30T03:00:00Z"), tasks: reduce(records).tasks,
                        records: records, receipts: receipts)
    }

    static func reduce(_ records: [OperationRecord]) -> ReductionReport {
        TaskReducer.reduce(records, workspaceKey: workspaceKey, workspaceEpoch: workspaceEpoch)
    }

    static func task(in records: [OperationRecord], taskID: UUID = CommandTestData.taskID) throws -> TaskProjection {
        guard let task = reduce(records).tasks[taskID] else {
            throw CommandTestFailure.expected("작업 투영이 존재해야 합니다")
        }
        return task
    }

    static func prepared(_ command: CommandEnvelope, records: [OperationRecord] = []) throws -> PreparedCommand {
        guard case let .prepared(prepared) = CommandValidator.prepare(command, snapshot: try snapshot(records: records)) else {
            throw CommandTestFailure.expected("명령이 정상적으로 준비되어야 합니다")
        }
        return prepared
    }

    static func capture(taskID: UUID = CommandTestData.taskID, key: String = "capture-default", title: String = "작업") throws -> OperationRecord {
        try prepared(command(.capture(taskID: taskID, content: TaskContent(title: title)), key: key)).operation
    }

    static func batchCaptures(count: Int) throws -> [OperationRecord] {
        try (1...count).map { index in
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
            return try capture(taskID: id, key: "capture-\(index)", title: "작업 \(index)")
        }
    }

    static func receipt(for command: CommandEnvelope, prepared: PreparedCommand) -> CommandReceipt {
        CommandReceipt(workspaceEpoch: workspaceEpoch, key: command.idempotencyKey, digest: prepared.logicalDigest,
                       operationID: prepared.operation.operationID,
                       result: CommandResult(requestID: command.requestID, operationID: prepared.operation.operationID,
                                             state: .locallyCommitted, safeUserMessage: "이 기기에 저장했습니다",
                                             affectedTaskIDs: prepared.affectedTaskIDs))
    }

    static func rejection(_ result: CommandPreparation) throws -> CommandRejection {
        guard case let .rejected(rejection) = result else {
            throw CommandTestFailure.expected("명령은 변경 원본을 만들지 않고 거부되어야 합니다")
        }
        return rejection
    }

    static func setPlanWireObject() -> [String: Any] {
        [
            "contractVersion": 1, "requestID": "wire-request", "idempotencyKey": "wire-card",
            "kind": "setPlan", "source": "widget", "workspaceEpoch": workspaceEpoch,
            "context": ["planningDay": "2026-09-30", "timeZoneID": "Asia/Seoul", "policyRevision": "policy-v1"],
            "taskID": taskID.uuidString,
            "expectedVersions": ["content": "content-v1", "plan": "plan-v1", "status": "status-v1", "deadline": "deadline-v1"],
            "payload": ["target": ["kind": "day", "date": "2026-10-01"]]
        ]
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CommandTestFailure.expected("wire 봉투는 JSON 객체여야 합니다")
        }
        return object
    }

    static func decodeWireObject(_ object: [String: Any]) throws -> CommandEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(CommandEnvelope.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}

enum CommandTestFailure: Error {
    case expected(String)
}
