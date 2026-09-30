import Foundation
import MirrorDomain

public enum NotificationKind: String, Codable, Sendable { case dailyReview, weeklyReview, deadline }

public struct PlannedNotification: Equatable, Codable, Sendable {
    public let identifier: String
    public let kind: NotificationKind
    public let fireAt: Date
    public let taskID: UUID?
    public init(identifier: String, kind: NotificationKind, fireAt: Date, taskID: UUID? = nil) {
        self.identifier = identifier; self.kind = kind; self.fireAt = fireAt; self.taskID = taskID
    }
}

public struct ReviewNotificationPreference: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var hour: Int
    public var minute: Int
    public var weeklyWeekday: Int
    public init(enabled: Bool = false, hour: Int = 9, minute: Int = 0, weeklyWeekday: Int = 2) {
        self.enabled = enabled; self.hour = hour; self.minute = minute; self.weeklyWeekday = weeklyWeekday
    }
}

public struct DeadlineNotificationPreference: Equatable, Codable, Sendable {
    public let taskID: UUID
    public let fireAt: Date
    public init(taskID: UUID, fireAt: Date) { self.taskID = taskID; self.fireAt = fireAt }
}

public struct NotificationPlan: Equatable, Sendable {
    public let requests: [PlannedNotification]
    public let omittedCount: Int
}

public enum NotificationPlanner {
    public static let reviewHorizon = 28
    public static let productLimit = 48

    public static func plan(context: PlanningContext, workspaceEpoch: String, now: Date,
                            review: ReviewNotificationPreference, closedDays: Set<LocalDate>,
                            tasks: [TaskProjection], deadlines: [DeadlineNotificationPreference]) throws -> NotificationPlan {
        guard (0...23).contains(review.hour), (0...59).contains(review.minute),
              (1...7).contains(review.weeklyWeekday), now.timeIntervalSinceReferenceDate.isFinite,
              let zone = TimeZone(identifier: context.timeZoneID),
              Set(tasks.map(\.taskID)).count == tasks.count,
              Set(deadlines.map(\.taskID)).count == deadlines.count else { throw PlanningError.invalidInstant }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone; calendar.locale = Locale(identifier: "en_US_POSIX")
        var planned: [PlannedNotification] = []
        if review.enabled {
            for offset in 0..<reviewHorizon {
                let day = try context.planningDay.addingDays(offset)
                if closedDays.contains(day) { continue }
                var components = DateComponents()
                components.calendar = calendar; components.timeZone = zone
                components.year = day.year; components.month = day.month; components.day = day.day
                components.hour = review.hour; components.minute = review.minute
                // 존재하지 않는 DST 시각은 Calendar의 다음 유효 시각으로 해석하되 날짜가 바뀌면 예약하지 않는다.
                guard let midnight = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
                      let fire = calendar.nextDate(after: midnight.addingTimeInterval(-1), matching: components,
                                                   matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
                      try PlanningContext.capture(at: fire, timeZoneID: context.timeZoneID,
                                                  policyRevision: context.policyRevision).planningDay == day, fire > now else { continue }
                let weekly = calendar.component(.weekday, from: fire) == review.weeklyWeekday
                planned.append(.init(identifier: "review:\(workspaceEpoch):\(day)",
                                     kind: weekly ? .weeklyReview : .dailyReview, fireAt: fire))
            }
        }
        let taskIndex = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        for preference in deadlines {
            guard preference.fireAt.timeIntervalSinceReferenceDate.isFinite, preference.fireAt > now,
                  let task = taskIndex[preference.taskID], task.status == .open,
                  task.isProjectionComplete, task.deadline != nil else { continue }
            planned.append(.init(identifier: "deadline:\(workspaceEpoch):\(task.taskID.uuidString)",
                                 kind: .deadline, fireAt: preference.fireAt, taskID: task.taskID))
        }
        // 가까운 시각을 우선하며 같은 시각에는 명시 마감이 먼저다. 먼 마감 원본을 삭제하지 않는다.
        planned.sort {
            if $0.fireAt != $1.fireAt { return $0.fireAt < $1.fireAt }
            if ($0.kind == .deadline) != ($1.kind == .deadline) { return $0.kind == .deadline }
            return $0.identifier < $1.identifier
        }
        return NotificationPlan(requests: Array(planned.prefix(productLimit)),
                                omittedCount: max(0, planned.count - productLimit))
    }
}
