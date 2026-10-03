import Foundation
import MirrorDomain

// 원본 fixture는 읽기만 한다. CI는 MIRROR_FIXTURE_PATH로 별도 staging 경로를 주입한다.
enum FixtureSource {
    static let result: Result<DomainFixtureBundle, any Error> = Result { try decode(readData()) }

    static func readData() throws -> Data {
        let environment = ProcessInfo.processInfo.environment
        let url: URL
        if let path = environment["MIRROR_FIXTURE_PATH"] {
            guard !path.isEmpty else { throw FixtureError.invalid("MIRROR_FIXTURE_PATH가 비어 있습니다") }
            url = URL(fileURLWithPath: path)
        } else {
            #if !SWIFT_PACKAGE
            if let bundled = Bundle(for: FixtureBundleAnchor.self)
                .url(forResource: "domain-cases", withExtension: "json") {
                url = bundled
            } else {
                url = repositoryFixtureURL
            }
            #else
            url = repositoryFixtureURL
            #endif
        }
        return try Data(contentsOf: url)
    }

    static var arguments: [DomainFixtureCase] {
        switch result {
        case let .success(bundle): bundle.cases
        case let .failure(error):
            // 로딩 실패를 빈 arguments로 바꾸면 테스트가 0개로 성공할 수 있다.
            [DomainFixtureCase(id: "fixture-loading-failure", payload: .loadingFailure(String(describing: error)))]
        }
    }

    static func decode(_ data: Data) throws -> DomainFixtureBundle {
        let bundle = try JSONDecoder().decode(DomainFixtureBundle.self, from: data)
        try bundle.validateInventory()
        return bundle
    }

    private static var repositoryFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("postpone-app-docs/fixtures/domain-cases.json")
    }
}

#if !SWIFT_PACKAGE
private final class FixtureBundleAnchor: NSObject {}
#endif

enum FixtureError: Error {
    case invalid(String)
}

struct DomainFixtureBundle: Decodable, Sendable {
    let fixtureVersion: Int
    let cases: [DomainFixtureCase]

    func validateInventory() throws {
        guard fixtureVersion == 1 else { throw FixtureError.invalid("지원하지 않는 fixtureVersion") }
        guard cases.count == 36 else { throw FixtureError.invalid("fixture가 36개여야 합니다") }
        let ids = cases.map(\.id)
        let expectedIDs = (1...36).map { String(format: "F-%03d", $0) }
        guard Set(ids).count == ids.count, Set(ids) == Set(expectedIDs) else {
            throw FixtureError.invalid("fixture ID가 F-001...F-036과 일치해야 합니다")
        }
        let counts = Dictionary(grouping: cases, by: \.kind).mapValues(\.count)
        guard counts == ["dateDestinations": 7, "visibility": 13, "deadlineWarning": 5,
                         "validatePlan": 8, "contextCheck": 3] else {
            throw FixtureError.invalid("fixture 종류별 개수가 일치하지 않습니다")
        }
    }
}

struct DomainFixtureCase: Decodable, Sendable {
    let id: String
    let payload: Payload

    enum Payload: Sendable {
        case dateDestinations(DateInput, DateExpected)
        case visibility(VisibilityInput, VisibilityExpected)
        case deadlineWarning(DeadlineInput, DeadlineExpected)
        case validatePlan(PlanInput, PlanExpected)
        case contextCheck(ContextInput, ContextExpected)
        case loadingFailure(String)
    }

    var kind: String {
        switch payload {
        case .dateDestinations: "dateDestinations"
        case .visibility: "visibility"
        case .deadlineWarning: "deadlineWarning"
        case .validatePlan: "validatePlan"
        case .contextCheck: "contextCheck"
        case .loadingFailure: "loadingFailure"
        }
    }

    init(id: String, payload: Payload) {
        self.id = id
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case id, kind, input, expected }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        switch try container.decode(String.self, forKey: .kind) {
        case "dateDestinations":
            payload = .dateDestinations(try container.decode(DateInput.self, forKey: .input),
                                        try container.decode(DateExpected.self, forKey: .expected))
        case "visibility":
            payload = .visibility(try container.decode(VisibilityInput.self, forKey: .input),
                                  try container.decode(VisibilityExpected.self, forKey: .expected))
        case "deadlineWarning":
            payload = .deadlineWarning(try container.decode(DeadlineInput.self, forKey: .input),
                                       try container.decode(DeadlineExpected.self, forKey: .expected))
        case "validatePlan":
            payload = .validatePlan(try container.decode(PlanInput.self, forKey: .input),
                                    try container.decode(PlanExpected.self, forKey: .expected))
        case "contextCheck":
            payload = .contextCheck(try container.decode(ContextInput.self, forKey: .input),
                                    try container.decode(ContextExpected.self, forKey: .expected))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "알 수 없는 fixture kind")
        }
    }
}

struct DateInput: Decodable, Sendable {
    let planningDay: LocalDate
    let timeZoneID: String
}

struct DateExpected: Decodable, Sendable {
    let today: LocalDate
    let tomorrow: LocalDate
    let thisWeek: WeekExpected
    let nextWeek: WeekExpected
}

struct WeekExpected: Decodable, Sendable {
    let startDate: LocalDate
    let endExclusiveDate: LocalDate
}

struct VisibilityInput: Decodable, Sendable {
    let planningDay: LocalDate
    let task: TaskPlanningState
    let acknowledgedCurrentPlan: Bool
}

struct VisibilityExpected: Decodable, Sendable {
    let isToday: Bool
    let reviewCandidate: Bool
}

struct DeadlineInput: Decodable, Sendable {
    let target: PlanTarget
    let deadlineLocalDate: LocalDate
}

struct DeadlineExpected: Decodable, Sendable {
    let requiresAfterDeadlineConfirmation: Bool
}

struct PlanInput: Decodable, Sendable {
    let planningDay: LocalDate
    let target: PlanTarget
}

struct PlanExpected: Decodable, Sendable {
    let valid: Bool
}

struct ContextInput: Decodable, Sendable {
    let displayDay: LocalDate
    let currentDay: LocalDate
    let matchingReceiptExists: Bool
}

struct ContextExpected: Decodable, Sendable {
    let result: String

    private enum CodingKeys: String, CodingKey { case result }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(String.self, forKey: .result)
        guard ["continueValidation", "staleContext", "alreadyApplied"].contains(result) else {
            throw DecodingError.dataCorruptedError(forKey: .result, in: container,
                                                   debugDescription: "알 수 없는 context 기대 결과")
        }
    }
}

func instant(_ value: String) throws -> Date {
    guard let parsed = ISO8601DateFormatter().date(from: value) else {
        throw FixtureError.invalid("잘못된 테스트 UTC 시각: \(value)")
    }
    return parsed
}

func context(_ day: String, timeZoneID: String = "Asia/Seoul",
             revision: String = "policy-v1") throws -> PlanningContext {
    try PlanningContext(planningDay: LocalDate(day), timeZoneID: timeZoneID,
                        policyRevision: revision, capturedAt: instant("2026-09-30T03:00:00Z"))
}
