import Foundation

public enum TaskStatus: String, Hashable, Codable, Sendable {
    case open
    case completed
    case deleted
}

/// 목록 판정에 필요한 값만 보존한다. 저장용 TaskProjection은 별도 계층에서 구성한다.
public struct TaskPlanningState: Hashable, Codable, Sendable {
    public let status: TaskStatus
    public let plan: PlanTarget
    public let reviewNotBefore: LocalDate?

    public init(status: TaskStatus, plan: PlanTarget, reviewNotBefore: LocalDate? = nil) {
        self.status = status
        self.plan = plan
        self.reviewNotBefore = reviewNotBefore
    }

    private enum CodingKeys: String, CodingKey {
        case status, plan, reviewNotBefore
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let plan = try container.decode(PlanTarget.self, forKey: .plan)
        guard PlanningRules.validatePlanStructure(plan) else {
            throw DecodingError.dataCorruptedError(
                forKey: .plan,
                in: container,
                debugDescription: "계획 주는 월요일에 시작하는 7일 범위여야 합니다."
            )
        }
        self.init(
            status: try container.decode(TaskStatus.self, forKey: .status),
            plan: plan,
            reviewNotBefore: try container.decodeIfPresent(LocalDate.self, forKey: .reviewNotBefore)
        )
    }
}

public enum ReviewMode: String, Sendable {
    case automatic
    case manualResume
    case manualTodayOverride
}

/// 영수증의 실제 저장·조회는 호출자 책임이며 이 값은 검증 순서의 판정 결과다.
public enum ContextCheckResult: String, Sendable {
    case continueValidation
    case staleContext
    case alreadyApplied
}

public enum PlanningRules {
    public static func isToday(_ task: TaskPlanningState, on planningDay: LocalDate) -> Bool {
        task.status == .open && task.plan == .day(planningDay)
    }

    public static func isReviewCandidate(
        _ task: TaskPlanningState,
        on planningDay: LocalDate,
        acknowledgedCurrentPlan: Bool,
        cycleClosed: Bool = false,
        mode: ReviewMode = .automatic
    ) -> Bool {
        guard task.status == .open, task.plan != .parked, validatePlanStructure(task.plan) else { return false }
        if mode == .automatic && cycleClosed { return false }
        if let notBefore = task.reviewNotBefore, notBefore > planningDay { return false }
        if mode == .manualTodayOverride {
            // 명시적으로 오늘에 배치한 후보만 확인 여부를 우회한다.
            return isToday(task, on: planningDay)
        }
        if acknowledgedCurrentPlan { return false }

        switch task.plan {
        case .unassigned: return true
        case let .day(date): return date <= planningDay
        case let .week(startDate, _): return startDate <= planningDay
        case .parked: return false
        }
    }

    /// 현재 날짜에 관계없이 읽기와 복원에서도 유지해야 하는 계획 구조다.
    public static func validatePlanStructure(_ target: PlanTarget) -> Bool {
        switch target {
        case let .week(startDate, endExclusiveDate):
            return validateWeekStructure(startDate: startDate, endExclusiveDate: endExclusiveDate)
        case .unassigned, .day, .parked:
            return true
        }
    }

    public static func validateWeekStructure(startDate: LocalDate, endExclusiveDate: LocalDate) -> Bool {
        guard let expected = try? startDate.mondayWeek(), expected.startDate == startDate else { return false }
        return expected.endExclusiveDate == endExclusiveDate
    }

    /// 새 배치에만 적용하는 검증이다. 구조가 유효한 과거 이력은 읽기와 복원에서 보존한다.
    public static func validatePlan(_ target: PlanTarget, on planningDay: LocalDate) -> Bool {
        guard validatePlanStructure(target) else { return false }
        switch target {
        case .unassigned, .parked:
            return true
        case let .day(date):
            return date >= planningDay
        case let .week(_, endExclusiveDate):
            return endExclusiveDate > planningDay
        }
    }

    public static func requiresAfterDeadlineConfirmation(target: PlanTarget, deadlineLocalDate: LocalDate?) -> Bool {
        guard let deadlineLocalDate else { return false }
        switch target {
        case let .day(date): return date > deadlineLocalDate
        case let .week(startDate, _): return startDate > deadlineLocalDate
        case .unassigned, .parked: return false
        }
    }

    public static func needsDeadlineConfirmation(
        taskID: String,
        deadlineRevision: String,
        target: PlanTarget,
        deadlineLocalDate: LocalDate?,
        acknowledgment: DeadlineAcknowledgment?
    ) -> Bool {
        requiresAfterDeadlineConfirmation(target: target, deadlineLocalDate: deadlineLocalDate)
            && acknowledgment?.matches(taskID: taskID, deadlineRevision: deadlineRevision, target: target) != true
    }

    public static func checkContext(
        displayed: PlanningContext,
        current: PlanningContext,
        matchingReceiptExists: Bool
    ) -> ContextCheckResult {
        // 이미 적용된 동일 명령은 날짜와 설정이 바뀐 뒤에도 원래 결과를 반환한다.
        if matchingReceiptExists { return .alreadyApplied }
        guard displayed.planningDay == current.planningDay,
              displayed.timeZoneID == current.timeZoneID,
              displayed.policyRevision == current.policyRevision else {
            return .staleContext
        }
        return .continueValidation
    }
}

public enum Deadline: Hashable, Sendable {
    case day(localDate: LocalDate, timeZoneID: String)
    case instant(utcTimestamp: Date, displayTimeZoneID: String)

    public func planningDate(in context: PlanningContext) throws -> LocalDate {
        switch self {
        case let .day(localDate, timeZoneID):
            guard TimeZone(identifier: timeZoneID) != nil else { throw PlanningError.invalidTimeZone }
            // 날짜 마감은 시각을 임의로 만들지 않고 생성 당시의 날짜를 보존한다.
            return localDate
        case let .instant(utcTimestamp, displayTimeZoneID):
            guard TimeZone(identifier: displayTimeZoneID) != nil else { throw PlanningError.invalidTimeZone }
            return try PlanningContext.capture(
                at: utcTimestamp,
                timeZoneID: context.timeZoneID,
                policyRevision: context.policyRevision
            ).planningDay
        }
    }
}

public struct DeadlineAcknowledgment: Hashable, Sendable {
    public let taskID: String
    public let deadlineRevision: String
    public let target: PlanTarget

    public init(taskID: String, deadlineRevision: String, target: PlanTarget) {
        self.taskID = taskID
        self.deadlineRevision = deadlineRevision
        self.target = target
    }

    public func matches(taskID: String, deadlineRevision: String, target: PlanTarget) -> Bool {
        self.taskID == taskID && self.deadlineRevision == deadlineRevision && self.target == target
    }
}
