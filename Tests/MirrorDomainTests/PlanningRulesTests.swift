import Foundation
import Testing
@testable import MirrorDomain

@Suite("D-02 계획·목록·검토·마감·카드 기준 불변식")
struct PlanningRulesTests {
    @Test("주 범위의 시작 포함·다음 월요일 제외", arguments: [
        ("2026-09-27", false), ("2026-09-28", true),
        ("2026-10-04", true), ("2026-10-05", false)
    ])
    func weekIsEndExclusive(_ date: String, _ expected: Bool) throws {
        let range = try LocalDate("2026-09-30").mondayWeek()
        #expect(try range.contains(LocalDate(date)) == expected)
    }

    @Test("주 계획은 다음 월요일에도 Today로 변환되지 않는다")
    func weekRemainsWeekAfterBoundary() throws {
        let plan = try PlanTarget.week(startDate: LocalDate("2026-09-28"),
                                       endExclusiveDate: LocalDate("2026-10-05"))
        let task = TaskPlanningState(status: .open, plan: plan)
        let day = try LocalDate("2026-10-05")
        #expect(!PlanningRules.isToday(task, on: day))
        #expect(PlanningRules.isReviewCandidate(task, on: day, acknowledgedCurrentPlan: false))
        #expect(task.plan == plan)
    }

    @Test("정리 이어하기는 종료만 우회하고 확인한 계획은 유지")
    func manualResume() throws {
        let day = try LocalDate("2026-09-30")
        let task = TaskPlanningState(status: .open, plan: .unassigned)
        #expect(!PlanningRules.isReviewCandidate(task, on: day, acknowledgedCurrentPlan: false,
                                                 cycleClosed: true, mode: .automatic))
        #expect(PlanningRules.isReviewCandidate(task, on: day, acknowledgedCurrentPlan: false,
                                                cycleClosed: true, mode: .manualResume))
        #expect(!PlanningRules.isReviewCandidate(task, on: day, acknowledgedCurrentPlan: true,
                                                 cycleClosed: true, mode: .manualResume))
        let deferred = TaskPlanningState(status: .open, plan: .unassigned,
                                         reviewNotBefore: try LocalDate("2026-10-01"))
        #expect(!PlanningRules.isReviewCandidate(deferred, on: day, acknowledgedCurrentPlan: false,
                                                 cycleClosed: true, mode: .manualResume))
    }

    @Test("오늘 다시 정리는 오늘로 배치한 항목의 acknowledgment만 우회")
    func manualTodayOverride() throws {
        let day = try LocalDate("2026-09-30")
        let today = TaskPlanningState(status: .open, plan: .day(day))
        #expect(PlanningRules.isReviewCandidate(today, on: day, acknowledgedCurrentPlan: true,
                                                cycleClosed: true, mode: .manualTodayOverride))
        let otherPlans: [PlanTarget] = [
            .unassigned, .parked, .day(try LocalDate("2026-09-29")), .day(try LocalDate("2026-10-01")),
            .week(startDate: try LocalDate("2026-09-28"), endExclusiveDate: try LocalDate("2026-10-05"))
        ]
        for plan in otherPlans {
            let task = TaskPlanningState(status: .open, plan: plan)
            #expect(!PlanningRules.isReviewCandidate(task, on: day, acknowledgedCurrentPlan: true,
                                                     cycleClosed: true, mode: .manualTodayOverride))
        }
        let deferred = TaskPlanningState(status: .open, plan: .day(day),
                                         reviewNotBefore: try LocalDate("2026-10-01"))
        #expect(!PlanningRules.isReviewCandidate(deferred, on: day, acknowledgedCurrentPlan: true,
                                                 cycleClosed: true, mode: .manualTodayOverride))
    }

    @Test("완료·휴지통은 모든 검토 모드와 오늘 목록에서 제외", arguments: [TaskStatus.completed, .deleted])
    func closedStatus(_ status: TaskStatus) throws {
        let day = try LocalDate("2026-09-30")
        let task = TaskPlanningState(status: status, plan: .day(day))
        #expect(!PlanningRules.isToday(task, on: day))
        for mode: ReviewMode in [.automatic, .manualResume, .manualTodayOverride] {
            #expect(!PlanningRules.isReviewCandidate(task, on: day, acknowledgedCurrentPlan: false,
                                                     cycleClosed: false, mode: mode))
        }
    }

    @Test("검토 유예는 오늘 목록 날짜를 바꾸지 않고 지정일까지 유지")
    func reviewNotBeforeInclusive() throws {
        let day = try LocalDate("2026-10-01")
        let task = TaskPlanningState(status: .open, plan: .day(day), reviewNotBefore: day)
        #expect(PlanningRules.isToday(task, on: day))
        #expect(PlanningRules.isReviewCandidate(task, on: day, acknowledgedCurrentPlan: false))
        #expect(!PlanningRules.isReviewCandidate(task, on: try LocalDate("2026-09-30"),
                                                 acknowledgedCurrentPlan: false))
    }

    @Test("과거 계획은 읽어 복원할 수 있지만 새 배치는 거부")
    func pastPlanReadAndAssignment() throws {
        let json = Data(#"{"kind":"day","date":"2026-09-29"}"#.utf8)
        let plan = try JSONDecoder().decode(PlanTarget.self, from: json)
        let day = try LocalDate("2026-09-30")
        #expect(plan == .day(try LocalDate("2026-09-29")))
        #expect(!PlanningRules.validatePlan(plan, on: day))
        let task = TaskPlanningState(status: .open, plan: plan)
        #expect(!PlanningRules.isToday(task, on: day))
        #expect(PlanningRules.isReviewCandidate(task, on: day, acknowledgedCurrentPlan: false))
    }

    @Test("주 범위 오류와 끝난 주 새 배치를 거부", arguments: [
        ("2026-09-29", "2026-10-06"), // 화요일 시작
        ("2026-09-28", "2026-10-04"), // 6일
        ("2026-09-28", "2026-10-06"), // 8일
        ("2026-09-28", "2026-09-28"), // 빈 범위
        ("2026-09-28", "2026-09-21"), // 역방향
        ("2026-09-21", "2026-09-28")  // 이미 끝남
    ])
    func invalidWeekAssignment(_ start: String, _ end: String) throws {
        let plan = try PlanTarget.week(startDate: LocalDate(start), endExclusiveDate: LocalDate(end))
        #expect(!PlanningRules.validatePlan(plan, on: try LocalDate("2026-09-30")))
    }

    @Test("잘못된 주는 raw 목적지 fixture로 읽지만 작업과 검토 후보로 허용하지 않는다", arguments: [
        ("2026-09-29", "2026-10-06"),
        ("2026-09-28", "2026-10-04"),
        ("2026-09-28", "2026-10-06"),
        ("2026-09-28", "2026-09-28"),
        ("2026-09-28", "2026-09-21")
    ])
    func malformedWeekCannotBecomeTask(_ start: String, _ end: String) throws {
        let plan = try PlanTarget.week(startDate: LocalDate(start), endExclusiveDate: LocalDate(end))
        let data = try JSONEncoder().encode(plan)
        let decodedPlan = try JSONDecoder().decode(PlanTarget.self, from: data)
        #expect(decodedPlan == plan)
        let day = try LocalDate("2026-09-30")
        #expect(!PlanningRules.validatePlan(decodedPlan, on: day))
        let planObject = try JSONSerialization.jsonObject(with: data)
        let taskData = try JSONSerialization.data(withJSONObject: [
            "status": "open", "plan": planObject, "reviewNotBefore": NSNull()
        ])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TaskPlanningState.self, from: taskData)
        }
        // 직접 구성한 잘못된 값도 자동 검토가 받아들이면 안 된다.
        let task = TaskPlanningState(status: .open, plan: decodedPlan)
        #expect(!PlanningRules.isToday(task, on: day))
        for mode: ReviewMode in [.automatic, .manualResume, .manualTodayOverride] {
            #expect(!PlanningRules.isReviewCandidate(task, on: day, acknowledgedCurrentPlan: false,
                                                     cycleClosed: false, mode: mode))
        }
    }

    @Test("구조가 유효한 과거 주는 작업 이력으로 읽고 검토한다")
    func validPastWeekIsPreserved() throws {
        let json = Data(#"{"status":"open","plan":{"kind":"week","startDate":"2026-09-21","endExclusiveDate":"2026-09-28"},"reviewNotBefore":null}"#.utf8)
        let task = try JSONDecoder().decode(TaskPlanningState.self, from: json)
        let expected = try PlanTarget.week(startDate: LocalDate("2026-09-21"),
                                           endExclusiveDate: LocalDate("2026-09-28"))
        #expect(task.plan == expected)
        let day = try LocalDate("2026-09-30")
        #expect(!PlanningRules.validatePlan(task.plan, on: day))
        #expect(!PlanningRules.isToday(task, on: day))
        #expect(PlanningRules.isReviewCandidate(task, on: day, acknowledgedCurrentPlan: false))
        #expect(try JSONDecoder().decode(TaskPlanningState.self, from: JSONEncoder().encode(task)) == task)
    }

    @Test("일요일까지 현재 주 유효, 끝 경계 월요일에는 종료")
    func assignmentAtWeekEnd() throws {
        let week = try PlanTarget.week(startDate: LocalDate("2026-09-28"),
                                       endExclusiveDate: LocalDate("2026-10-05"))
        #expect(PlanningRules.validatePlan(week, on: try LocalDate("2026-10-04")))
        #expect(!PlanningRules.validatePlan(week, on: try LocalDate("2026-10-05")))
    }

    @Test("계획 JSON에 상대 목적지와 알 수 없는 필드를 저장하지 않는다", arguments: [
        #"{"kind":"today"}"#,
        #"{"kind":"tomorrow"}"#,
        #"{"kind":"day","date":"2026-09-30","deadline":"2026-10-01"}"#,
        #"{"kind":"day","date":"2026-02-30"}"#,
        #"{"kind":"week","startDate":"2026-09-28"}"#
    ])
    func malformedStoredPlan(_ json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PlanTarget.self, from: Data(json.utf8)) }
    }

    @Test("계획 시간대 변경 후 이미 저장한 날짜와 주 문자열 유지")
    func storedDatesSurvivePolicyChange() throws {
        let plans: [PlanTarget] = [
            .day(try LocalDate("2026-10-06")),
            .week(startDate: try LocalDate("2026-10-05"), endExclusiveDate: try LocalDate("2026-10-12"))
        ]
        let seoul = try context("2026-09-30")
        let losAngeles = try context("2026-09-29", timeZoneID: "America/Los_Angeles", revision: "policy-v2")
        #expect(PlanningRules.checkContext(displayed: seoul, current: losAngeles,
                                          matchingReceiptExists: false) == .staleContext)
        for original in plans {
            let data = try JSONEncoder().encode(original)
            let restored = try JSONDecoder().decode(PlanTarget.self, from: data)
            #expect(restored == original)
            #expect(!PlanningRules.isToday(TaskPlanningState(status: .open, plan: restored),
                                           on: losAngeles.planningDay))
        }
    }

    @Test("정책 버전 변경은 같은 날도 stale, 영수증은 항상 우선")
    func changedPolicyReceiptFirst() throws {
        let displayed = try context("2026-09-30", revision: "policy-v1")
        let changed = try context("2026-09-30", revision: "policy-v2")
        #expect(PlanningRules.checkContext(displayed: displayed, current: changed,
                                          matchingReceiptExists: false) == .staleContext)
        #expect(PlanningRules.checkContext(displayed: displayed, current: changed,
                                          matchingReceiptExists: true) == .alreadyApplied)
        let tomorrow = try context("2026-10-01", timeZoneID: "America/Los_Angeles", revision: "policy-v3")
        #expect(PlanningRules.checkContext(displayed: displayed, current: tomorrow,
                                          matchingReceiptExists: true) == .alreadyApplied)
    }

    @Test("캡처 시각만 다르면 같은 날짜·정책의 카드 검증 계속")
    func capturedAtIsNotExpiry() throws {
        let first = try PlanningContext.capture(at: instant("2026-09-30T00:30:00Z"),
                                                timeZoneID: "Asia/Seoul", policyRevision: "policy-v1")
        let second = try PlanningContext.capture(at: instant("2026-09-30T14:59:59Z"),
                                                 timeZoneID: "Asia/Seoul", policyRevision: "policy-v1")
        #expect(PlanningRules.checkContext(displayed: first, current: second,
                                          matchingReceiptExists: false) == .continueValidation)
    }

    @Test("마감 없는 작업과 날짜 미정·보관에 마감 이후 확인 없음")
    func noDeadline() throws {
        let future = try PlanTarget.day(LocalDate("2026-10-20"))
        #expect(!PlanningRules.requiresAfterDeadlineConfirmation(target: future, deadlineLocalDate: nil))
        let deadline = try LocalDate("2026-10-02")
        #expect(!PlanningRules.requiresAfterDeadlineConfirmation(target: .unassigned, deadlineLocalDate: deadline))
        #expect(!PlanningRules.requiresAfterDeadlineConfirmation(target: .parked, deadlineLocalDate: deadline))
    }

    @Test("시각 마감은 UTC 보존 후 계획 시간대에 환산, 날짜 마감은 원래 날짜")
    func deadlineDateProjection() throws {
        let timestamp = try instant("2026-09-30T15:00:00Z")
        let timed = Deadline.instant(utcTimestamp: timestamp, displayTimeZoneID: "America/Los_Angeles")
        let dateOnly = try Deadline.day(localDate: LocalDate("2026-09-30"), timeZoneID: "Asia/Seoul")
        let seoul = try context("2026-09-30")
        let losAngeles = try context("2026-09-30", timeZoneID: "America/Los_Angeles")
        #expect(try timed.planningDate(in: seoul) == LocalDate("2026-10-01"))
        #expect(try timed.planningDate(in: losAngeles) == LocalDate("2026-09-30"))
        #expect(timed == .instant(utcTimestamp: timestamp, displayTimeZoneID: "America/Los_Angeles"))
        #expect(try dateOnly.planningDate(in: seoul) == LocalDate("2026-09-30"))
        #expect(try dateOnly.planningDate(in: losAngeles) == LocalDate("2026-09-30"))
        #expect(try dateOnly == .day(localDate: LocalDate("2026-09-30"), timeZoneID: "Asia/Seoul"))
    }

    @Test("마감 확인은 정확한 작업·마감 버전·목적지에만 적용")
    func deadlineAcknowledgmentBinding() throws {
        let target = try PlanTarget.day(LocalDate("2026-10-03"))
        let deadline = try LocalDate("2026-10-02")
        let ack = DeadlineAcknowledgment(taskID: "task-a", deadlineRevision: "deadline-v1", target: target)
        #expect(!PlanningRules.needsDeadlineConfirmation(taskID: "task-a", deadlineRevision: "deadline-v1",
                                                         target: target, deadlineLocalDate: deadline, acknowledgment: ack))
        #expect(PlanningRules.needsDeadlineConfirmation(taskID: "task-b", deadlineRevision: "deadline-v1",
                                                        target: target, deadlineLocalDate: deadline, acknowledgment: ack))
        #expect(PlanningRules.needsDeadlineConfirmation(taskID: "task-a", deadlineRevision: "deadline-v2",
                                                        target: target, deadlineLocalDate: deadline, acknowledgment: ack))
        #expect(PlanningRules.needsDeadlineConfirmation(taskID: "task-a", deadlineRevision: "deadline-v1",
                                                        target: .day(try LocalDate("2026-10-04")),
                                                        deadlineLocalDate: deadline, acknowledgment: ack))
        #expect(PlanningRules.needsDeadlineConfirmation(taskID: "task-a", deadlineRevision: "deadline-v1",
                                                        target: target, deadlineLocalDate: deadline, acknowledgment: nil))
    }
}
