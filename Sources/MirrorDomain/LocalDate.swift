import Foundation

/// 시각이나 기기 시간대 없이 보존하는 그레고리력 날짜다.
public struct LocalDate: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            throw PlanningError.invalidLocalDate
        }

        let calendar = Self.civilCalendar
        let calendarYear = Self.cycleYear(for: year)
        let components = DateComponents(era: 1, year: calendarYear, month: month, day: day, hour: 12)
        guard let instant = calendar.date(from: components) else {
            throw PlanningError.invalidLocalDate
        }
        let actual = calendar.dateComponents([.era, .year, .month, .day], from: instant)
        guard actual.era == 1, actual.year == calendarYear, actual.month == month, actual.day == day else {
            throw PlanningError.invalidLocalDate
        }

        self.year = year
        self.month = month
        self.day = day
    }

    /// ASCII `YYYY-MM-DD`만 허용하며 잘못된 달력 날짜를 정규화하지 않는다.
    public init(_ iso8601: String) throws {
        let bytes = Array(iso8601.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48...57).contains(byte)
              }),
              let year = Int(String(iso8601.prefix(4))),
              let month = Int(String(iso8601.dropFirst(5).prefix(2))),
              let day = Int(String(iso8601.suffix(2))) else {
            throw PlanningError.invalidLocalDate
        }
        try self.init(year: year, month: month, day: day)
    }

    public var iso8601: String {
        "\(Self.padded(year, width: 4))-\(Self.padded(month, width: 2))-\(Self.padded(day, width: 2))"
    }

    public var description: String { iso8601 }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    /// 400년마다 반복하는 UTC 그레고리력 축에서 Calendar의 날짜 단위 덧셈을 사용한다.
    /// 계획 시간대의 DST, 건너뛴 날짜와 역사적 달력 전환은 저장한 날짜에 영향을 주지 않는다.
    public func addingDays(_ count: Int) throws -> LocalDate {
        let index = civilDayIndex
        let upperBound = Self.lastCivilDayIndex
        guard count >= -index, count <= upperBound - index else {
            throw PlanningError.dateArithmeticOutOfRange
        }
        return try Self.from(civilDayIndex: index + count)
    }

    public func mondayWeek() throws -> WeekRange {
        let calendar = Self.civilCalendar
        let components = DateComponents(era: 1, year: Self.cycleYear(for: year), month: month, day: day, hour: 12)
        guard let instant = calendar.date(from: components) else {
            throw PlanningError.invalidLocalDate
        }
        let weekday = calendar.component(.weekday, from: instant)
        let daysSinceMonday = (weekday + 5) % 7
        let start = try addingDays(-daysSinceMonday)
        return WeekRange(startDate: start, endExclusiveDate: try start.addingDays(7))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "유효한 YYYY-MM-DD 그레고리력 날짜가 필요합니다.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso8601)
    }

    /// 시각을 UTC 오프셋으로 달력 날짜축에 투영한다. 역사적 달력 전환은 적용하지 않는다.
    static func from(_ instant: Date, timeZone: TimeZone) throws -> LocalDate {
        let unixSeconds = instant.timeIntervalSince1970
        guard unixSeconds.isFinite else {
            throw PlanningError.invalidInstant
        }
        // 지원 연도 밖의 극단적인 시각을 시간대 라이브러리에 넘기지 않는다.
        let minimumUnixSeconds = Double(-Self.unixEpochCivilDayIndex) * Self.secondsPerCivilDay
        let maximumUnixSecondsExclusive = Double(Self.lastCivilDayIndex - Self.unixEpochCivilDayIndex + 1)
            * Self.secondsPerCivilDay
        guard unixSeconds >= minimumUnixSeconds - Self.secondsPerCivilDay,
              unixSeconds < maximumUnixSecondsExclusive + Self.secondsPerCivilDay else {
            throw PlanningError.invalidLocalDate
        }
        let localSeconds = unixSeconds + Double(timeZone.secondsFromGMT(for: instant))
        let unixDay = (localSeconds / Self.secondsPerCivilDay).rounded(.down)
        guard unixDay >= Double(-Self.unixEpochCivilDayIndex),
              unixDay <= Double(Self.lastCivilDayIndex - Self.unixEpochCivilDayIndex) else {
            throw PlanningError.invalidLocalDate
        }
        return try Self.from(civilDayIndex: Self.unixEpochCivilDayIndex + Int(unixDay))
    }

    static var civilCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    // 날짜 위치는 그레고리력의 윤년 규칙과 400년 주기로 계산한다.
    private static let daysInGregorianCycle = 146_097
    private static let daysBeforeMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    private static let lastCivilDayIndex = 9999 * 365 + 9999 / 4 - 9999 / 100 + 9999 / 400 - 1
    private static let unixEpochCivilDayIndex = 1969 * 365 + 1969 / 4 - 1969 / 100 + 1969 / 400
    // 시각→날짜 변환에만 사용한다. 내일과 주 범위는 Calendar의 날짜 단위 연산을 사용한다.
    private static let secondsPerCivilDay: Double = 24 * 60 * 60

    private var civilDayIndex: Int {
        let previousYear = year - 1
        let leapDay = month > 2 && Self.isLeapYear(year) ? 1 : 0
        return previousYear * 365 + previousYear / 4 - previousYear / 100 + previousYear / 400
            + Self.daysBeforeMonth[month - 1] + leapDay + day - 1
    }

    private static func cycleYear(for year: Int) -> Int {
        2001 + (year - 1) % 400
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }

    private static func from(civilDayIndex index: Int) throws -> LocalDate {
        guard (0...lastCivilDayIndex).contains(index) else {
            throw PlanningError.dateArithmeticOutOfRange
        }
        let completeCycles = index / daysInGregorianCycle
        let daysInCycle = index % daysInGregorianCycle
        let calendar = civilCalendar
        let cycleStart = DateComponents(era: 1, year: 2001, month: 1, day: 1, hour: 12)
        guard let instant = calendar.date(from: cycleStart),
              let date = calendar.date(byAdding: .day, value: daysInCycle, to: instant) else {
            throw PlanningError.dateArithmeticOutOfRange
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let cycleYear = components.year, let month = components.month, let day = components.day else {
            throw PlanningError.dateArithmeticOutOfRange
        }
        return try Self(year: completeCycles * 400 + cycleYear - 2000, month: month, day: day)
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: width - digits.count) + digits
    }
}

public struct WeekRange: Hashable, Codable, Sendable {
    public let startDate: LocalDate
    public let endExclusiveDate: LocalDate

    public init(startDate: LocalDate, endExclusiveDate: LocalDate) {
        self.startDate = startDate
        self.endExclusiveDate = endExclusiveDate
    }

    public func contains(_ date: LocalDate) -> Bool {
        startDate <= date && date < endExclusiveDate
    }
}

public enum PlanningError: Error, Equatable, Sendable {
    case invalidLocalDate
    case dateArithmeticOutOfRange
    case invalidTimeZone
    case invalidPolicyRevision
    case invalidInstant
}
