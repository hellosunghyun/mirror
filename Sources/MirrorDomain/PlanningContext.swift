import Foundation

/// 사용자 설정으로 고정한 계획 시간대와 화면을 만들 때의 기준이다.
public struct PlanningContext: Hashable, Sendable {
    public let planningDay: LocalDate
    public let timeZoneID: String
    public let policyRevision: String
    public let capturedAt: Date

    public init(planningDay: LocalDate, timeZoneID: String, policyRevision: String, capturedAt: Date) throws {
        guard TimeZone(identifier: timeZoneID) != nil else { throw PlanningError.invalidTimeZone }
        guard !policyRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlanningError.invalidPolicyRevision
        }
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else { throw PlanningError.invalidInstant }
        self.planningDay = planningDay
        self.timeZoneID = timeZoneID
        self.policyRevision = policyRevision
        self.capturedAt = capturedAt
    }

    /// 시스템 시계를 직접 읽지 않는다. 호출자가 주입한 시각을 계획 시간대의 날짜로 환산한다.
    public static func capture(at instant: Date, timeZoneID: String, policyRevision: String) throws -> PlanningContext {
        guard let timeZone = TimeZone(identifier: timeZoneID) else { throw PlanningError.invalidTimeZone }
        return try PlanningContext(
            planningDay: LocalDate.from(instant, timeZone: timeZone),
            timeZoneID: timeZoneID,
            policyRevision: policyRevision,
            capturedAt: instant
        )
    }

    public func destinations() throws -> DateDestinations {
        let thisWeek = try planningDay.mondayWeek()
        let nextWeek = WeekRange(
            startDate: thisWeek.endExclusiveDate,
            endExclusiveDate: try thisWeek.endExclusiveDate.addingDays(7)
        )
        return DateDestinations(
            today: planningDay,
            tomorrow: try planningDay.addingDays(1),
            thisWeek: thisWeek,
            nextWeek: nextWeek
        )
    }
}

public struct DateDestinations: Hashable, Sendable {
    public let today: LocalDate
    public let tomorrow: LocalDate
    public let thisWeek: WeekRange
    public let nextWeek: WeekRange

    public init(today: LocalDate, tomorrow: LocalDate, thisWeek: WeekRange, nextWeek: WeekRange) {
        self.today = today
        self.tomorrow = tomorrow
        self.thisWeek = thisWeek
        self.nextWeek = nextWeek
    }
}
