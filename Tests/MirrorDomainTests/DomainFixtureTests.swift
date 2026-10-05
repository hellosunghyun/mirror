import Foundation
import Testing
@testable import MirrorDomain

@Suite("D-02 원본 도메인 fixture 36개")
struct DomainFixtureTests {
    @Test("fixture 버전·36개 ID·종류별 개수 확인")
    func inventory() throws {
        let bundle = try FixtureSource.result.get()
        #expect(bundle.fixtureVersion == 1)
        #expect(bundle.cases.count == 36)
        try bundle.validateInventory()
    }

    @Test("원본 입력을 실제 Swift 생산 API로 판정", arguments: FixtureSource.arguments)
    func fixture(_ vector: DomainFixtureCase) throws {
        switch vector.payload {
        case let .dateDestinations(input, expected):
            let ctx = try PlanningContext(planningDay: input.planningDay, timeZoneID: input.timeZoneID,
                                          policyRevision: "fixture-v1",
                                          capturedAt: instant("2026-09-30T03:00:00Z"))
            let actual = try ctx.destinations()
            #expect(actual.today == expected.today, "\(vector.id): 오늘")
            #expect(actual.tomorrow == expected.tomorrow, "\(vector.id): 내일")
            #expect(actual.thisWeek.startDate == expected.thisWeek.startDate, "\(vector.id): 이번 주 시작")
            #expect(actual.thisWeek.endExclusiveDate == expected.thisWeek.endExclusiveDate, "\(vector.id): 이번 주 끝")
            #expect(actual.nextWeek.startDate == expected.nextWeek.startDate, "\(vector.id): 다음 주 시작")
            #expect(actual.nextWeek.endExclusiveDate == expected.nextWeek.endExclusiveDate, "\(vector.id): 다음 주 끝")
        case let .visibility(input, expected):
            #expect(PlanningRules.isToday(input.task, on: input.planningDay) == expected.isToday,
                    "\(vector.id): 오늘 목록")
            #expect(PlanningRules.isReviewCandidate(input.task, on: input.planningDay,
                                                   acknowledgedCurrentPlan: input.acknowledgedCurrentPlan)
                    == expected.reviewCandidate, "\(vector.id): 정리 후보")
        case let .deadlineWarning(input, expected):
            #expect(PlanningRules.requiresAfterDeadlineConfirmation(target: input.target,
                                                                    deadlineLocalDate: input.deadlineLocalDate)
                    == expected.requiresAfterDeadlineConfirmation, "\(vector.id): 마감 이후 확인")
        case let .validatePlan(input, expected):
            #expect(PlanningRules.validatePlan(input.target, on: input.planningDay) == expected.valid,
                    "\(vector.id): 새 배치 유효성")
        case let .contextCheck(input, expected):
            let displayed = try context(input.displayDay.iso8601)
            let current = try context(input.currentDay.iso8601)
            #expect(PlanningRules.checkContext(displayed: displayed, current: current,
                                              matchingReceiptExists: input.matchingReceiptExists).rawValue
                    == expected.result, "\(vector.id): 영수증 우선 / stale context")
        case let .loadingFailure(message):
            throw FixtureError.invalid(message)
        }
    }

    @Test("fixture 손상은 빈 테스트 실행으로 숨기지 않는다",
          arguments: ["empty", "version", "duplicate-id", "unexpected-id", "wrong-kind-count",
                      "unknown-kind", "malformed-payload", "missing-expected", "bad-boolean", "unknown-result"])
    func corruptedFixtureIsRejected(_ corruption: String) throws {
        let original = try FixtureSource.result.get()
        #expect(original.cases.count == 36)
        // 생산 코드의 기대값을 재계산하지 않고 원본 JSON의 구조만 손상시킨다.
        let source = try JSONSerialization.jsonObject(with: FixtureSource.readData())
        var document = try #require(source as? [String: Any])
        var cases = try #require(document["cases"] as? [[String: Any]])
        switch corruption {
        case "empty": cases = []
        case "version": document["fixtureVersion"] = 2
        case "duplicate-id": cases[1]["id"] = cases[0]["id"]
        case "unexpected-id": cases[0]["id"] = "F-999"
        case "wrong-kind-count":
            let id = cases[0]["id"]
            cases[0] = cases[7]
            cases[0]["id"] = id
        case "unknown-kind": cases[0]["kind"] = "silently-ignored-case"
        case "malformed-payload": cases[0]["input"] = ["planningDay": "2026-02-30", "timeZoneID": "Asia/Seoul"]
        case "missing-expected": cases[0].removeValue(forKey: "expected")
        case "bad-boolean": cases[7]["expected"] = ["isToday": "false", "reviewCandidate": true]
        case "unknown-result": cases[33]["expected"] = ["result": "pretend-success"]
        default: throw FixtureError.invalid("정의하지 않은 손상 시나리오")
        }
        document["cases"] = cases
        let data = try JSONSerialization.data(withJSONObject: document)
        #expect(throws: (any Error).self) { try FixtureSource.decode(data) }
    }

}
