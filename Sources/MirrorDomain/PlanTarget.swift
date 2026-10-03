import Foundation

/// 결정 당시의 절대 날짜를 보존하는 목적지다.
public enum PlanTarget: Hashable, Sendable, Codable {
    case unassigned
    case day(LocalDate)
    case week(startDate: LocalDate, endExclusiveDate: LocalDate)
    case parked

    private enum Kind: String, Codable { case unassigned, day, week, parked }

    private struct CodingKey: Swift.CodingKey, Sendable {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }

        static let kind = Self(stringValue: "kind")
        static let date = Self(stringValue: "date")
        static let startDate = Self(stringValue: "startDate")
        static let endExclusiveDate = Self(stringValue: "endExclusiveDate")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKey.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let allowedKeys: Set<String>
        switch kind {
        case .unassigned:
            allowedKeys = ["kind"]
            self = .unassigned
        case .day:
            allowedKeys = ["kind", "date"]
            self = .day(try container.decode(LocalDate.self, forKey: .date))
        case .week:
            allowedKeys = ["kind", "startDate", "endExclusiveDate"]
            // 주 범위의 의미는 새 배치 검증에서 확인한다. 과거 기록을 현재 날짜로 검증하지 않는다.
            self = .week(
                startDate: try container.decode(LocalDate.self, forKey: .startDate),
                endExclusiveDate: try container.decode(LocalDate.self, forKey: .endExclusiveDate)
            )
        case .parked:
            allowedKeys = ["kind"]
            self = .parked
        }
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowedKeys) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "PlanTarget 계약에 없는 필드는 허용하지 않습니다."))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKey.self)
        switch self {
        case .unassigned:
            try container.encode(Kind.unassigned, forKey: .kind)
        case let .day(date):
            try container.encode(Kind.day, forKey: .kind)
            try container.encode(date, forKey: .date)
        case let .week(startDate, endExclusiveDate):
            try container.encode(Kind.week, forKey: .kind)
            try container.encode(startDate, forKey: .startDate)
            try container.encode(endExclusiveDate, forKey: .endExclusiveDate)
        case .parked:
            try container.encode(Kind.parked, forKey: .kind)
        }
    }
}
