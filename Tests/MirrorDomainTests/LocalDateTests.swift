import Foundation
import Testing
@testable import MirrorDomain

@Suite("D-02 엄격한 달력 날짜와 고정 계획 시간대")
struct LocalDateTests {
    @Test("유효하지 않은 날짜와 모호한 문자열 거부", arguments: [
        "", "2026-2-03", "2026-02-3", "26-02-03", "2026/02/03",
        "2026-00-01", "2026-13-01", "2026-01-00", "2026-04-31", "2026-02-29",
        "1900-02-29", "2026-02-30", "0000-01-01", "10000-01-01",
        " 2026-09-30", "2026-09-30 ", "2026-09-30T00:00:00Z", "２０２６-０９-３０"
    ])
    func invalidDate(_ raw: String) throws {
        #expect(throws: PlanningError.invalidLocalDate) { try LocalDate(raw) }
        let json = try JSONEncoder().encode(raw)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LocalDate.self, from: json) }
    }

    @Test("숫자 구성자도 날짜 정규화로 오류를 숨기지 않는다")
    func invalidComponents() {
        #expect(throws: (any Error).self) { try LocalDate(year: 2026, month: 2, day: 30) }
        #expect(throws: (any Error).self) { try LocalDate(year: 0, month: 1, day: 1) }
        #expect(throws: (any Error).self) { try LocalDate(year: 10000, month: 1, day: 1) }
        #expect(throws: (any Error).self) { try LocalDate(year: 2026, month: 13, day: 1) }
    }

    @Test("윤년·월말·연말·지원 연도 경계", arguments: [
        ("1582-10-04", 1, "1582-10-05"),
        ("1582-10-14", 1, "1582-10-15"),
        ("1900-02-28", 1, "1900-03-01"),
        ("2000-02-28", 1, "2000-02-29"),
        ("2000-02-29", 1, "2000-03-01"),
        ("2026-02-28", 1, "2026-03-01"),
        ("2028-03-01", -1, "2028-02-29"),
        ("2026-12-31", 1, "2027-01-01"),
        ("2027-01-01", -1, "2026-12-31"),
        ("0001-01-01", 1, "0001-01-02"),
        ("9999-12-31", -1, "9999-12-30")
    ])
    func calendarAddition(_ start: String, _ offset: Int, _ expected: String) throws {
        #expect(try LocalDate(start).addingDays(offset) == LocalDate(expected))
    }

    @Test("지원 연도 밖의 계산은 실패")
    func yearOverflow() throws {
        let first = try LocalDate("0001-01-01")
        let last = try LocalDate("9999-12-31")
        #expect(throws: PlanningError.dateArithmeticOutOfRange) { try first.addingDays(-1) }
        #expect(throws: PlanningError.dateArithmeticOutOfRange) { try last.addingDays(1) }
        #expect(throws: PlanningError.dateArithmeticOutOfRange) { try first.addingDays(Int.min) }
        #expect(throws: PlanningError.dateArithmeticOutOfRange) { try last.addingDays(Int.max) }
    }

    @Test("달력 날짜를 JSON 문자열 그대로 보존")
    func localDateCodable() throws {
        let original = try LocalDate("2028-02-29")
        let data = try JSONEncoder().encode(original)
        #expect(String(decoding: data, as: UTF8.self) == "\"2028-02-29\"")
        #expect(try JSONDecoder().decode(LocalDate.self, from: data) == original)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LocalDate.self, from: Data("20280229".utf8))
        }
    }

    @Test("계획 시간대와 정책은 호출자가 주입", arguments: [
        ("Asia/Seoul", "2026-09-30"),
        ("America/Los_Angeles", "2026-09-29"),
        ("UTC", "2026-09-30")
    ])
    func sameInstantDifferentPlanningDay(_ zone: String, _ expected: String) throws {
        let captured = try instant("2026-09-30T00:30:00Z")
        let ctx = try PlanningContext.capture(at: captured, timeZoneID: zone, policyRevision: "fixed-policy")
        #expect(try ctx.planningDay == LocalDate(expected))
        #expect(ctx.timeZoneID == zone)
        #expect(ctx.policyRevision == "fixed-policy")
        #expect(ctx.capturedAt == captured)
    }

    @Test("서울 자정 직전과 직후", arguments: [
        ("2026-09-30T14:59:59Z", "2026-09-30", "2026-10-01"),
        ("2026-09-30T15:00:00Z", "2026-10-01", "2026-10-02")
    ])
    func seoulMidnight(_ timestamp: String, _ day: String, _ tomorrow: String) throws {
        let ctx = try PlanningContext.capture(at: instant(timestamp), timeZoneID: "Asia/Seoul",
                                              policyRevision: "policy-v1")
        #expect(try ctx.planningDay == LocalDate(day))
        #expect(try ctx.destinations().tomorrow == LocalDate(tomorrow))
    }

    @Test("DST 23시간·25시간 하루에도 다음 달력 날짜 선택", arguments: [
        ("2026-03-08T08:00:00Z", "2026-03-09T07:00:00Z", "2026-03-08", "2026-03-09", 23),
        ("2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z", "2026-11-01", "2026-11-02", 25)
    ])
    func daylightSavingCalendarDay(_ startInstant: String, _ nextInstant: String,
                                  _ day: String, _ tomorrow: String, _ elapsedHours: Int) throws {
        let start = try instant(startInstant)
        let next = try instant(nextInstant)
        #expect(next.timeIntervalSince(start) == Double(elapsedHours * 3600))
        let ctx = try PlanningContext.capture(at: start, timeZoneID: "America/Los_Angeles",
                                              policyRevision: "policy-v1")
        let nextContext = try PlanningContext.capture(at: next, timeZoneID: "America/Los_Angeles",
                                                      policyRevision: "policy-v1")
        #expect(try ctx.planningDay == LocalDate(day))
        #expect(try nextContext.planningDay == LocalDate(tomorrow))
        #expect(try ctx.destinations().tomorrow == nextContext.planningDay)
        #expect(try ctx.planningDay.addingDays(1) == nextContext.planningDay)
    }

    @Test("DST 반복 시각에서도 같은 날짜", arguments: ["2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z"])
    func repeatedHour(_ timestamp: String) throws {
        let ctx = try PlanningContext.capture(at: instant(timestamp), timeZoneID: "America/Los_Angeles",
                                              policyRevision: "policy-v1")
        #expect(try ctx.planningDay == LocalDate("2026-11-01"))
    }

    @Test("잘못된 시간대를 기기 기본값으로 대신하지 않는다", arguments: ["", "Not/A_Time_Zone"])
    func invalidTimeZone(_ zone: String) throws {
        let captured = try instant("2026-09-30T00:30:00Z")
        #expect(throws: PlanningError.invalidTimeZone) {
            try PlanningContext.capture(at: captured, timeZoneID: zone, policyRevision: "policy-v1")
        }
        #expect(throws: PlanningError.invalidTimeZone) {
            try PlanningContext(planningDay: LocalDate("2026-09-30"), timeZoneID: zone,
                                policyRevision: "policy-v1", capturedAt: captured)
        }
    }

    @Test("빈 정책 버전은 날짜가 같아도 유효한 기준이 아니다", arguments: ["", " \n\t "])
    func invalidPolicy(_ revision: String) throws {
        #expect(throws: PlanningError.invalidPolicyRevision) {
            try PlanningContext.capture(at: instant("2026-09-30T00:30:00Z"),
                                        timeZoneID: "Asia/Seoul", policyRevision: revision)
        }
    }

    @Test("유한하지 않은 시각을 계획 날짜로 만들지 않는다")
    func invalidInstant() {
        #expect(throws: PlanningError.invalidInstant) {
            try PlanningContext.capture(at: Date(timeIntervalSinceReferenceDate: .infinity),
                                        timeZoneID: "Asia/Seoul", policyRevision: "policy-v1")
        }
    }

    @Test("같은 주의 모든 요일과 일요일의 이번 주 의미", arguments: [
        "2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01",
        "2026-10-02", "2026-10-03", "2026-10-04"
    ])
    func everyWeekday(_ day: String) throws {
        let week = try LocalDate(day).mondayWeek()
        #expect(try week.startDate == LocalDate("2026-09-28"))
        #expect(try week.endExclusiveDate == LocalDate("2026-10-05"))
    }

    @Test("최초 지원 날짜도 월요일 시작 주")
    func firstSupportedWeek() throws {
        let week = try LocalDate("0001-01-01").mondayWeek()
        #expect(try week.startDate == LocalDate("0001-01-01"))
        #expect(try week.endExclusiveDate == LocalDate("0001-01-08"))
    }

    @Test("UTC epoch를 역사적 달력 전환 없이 그레고리력 날짜로 해석", arguments: [
        (-12_220_243_200.0, "1582-10-04"),
        (-12_219_724_800.0, "1582-10-10"),
        (-12_219_292_800.0, "1582-10-15"),
        (-14_826_758_400.0, "1500-02-28"),
        (-14_826_672_000.0, "1500-03-01"),
        (-11_670_998_400.0, "1600-02-29"),
        (-49_512_902_400.0, "0400-12-31"),
        (-49_512_816_000.0, "0401-01-01"),
        (-62_135_596_800.0, "0001-01-01")
    ])
    func prolepticGregorianCapture(_ unixSeconds: Double, _ expected: String) throws {
        // 날짜 문자열 파서나 생산 구현으로 기대 시각을 만들지 않는 독립 epoch 벡터다.
        let ctx = try PlanningContext.capture(at: Date(timeIntervalSince1970: unixSeconds),
                                              timeZoneID: "UTC", policyRevision: "policy-v1")
        #expect(try ctx.planningDay == LocalDate(expected))
        #expect(ctx.capturedAt.timeIntervalSince1970 == unixSeconds)
    }

    @Test("400년 주기의 큰 달력 덧셈과 주기 경계", arguments: [
        ("0001-01-01", 146_097, "0401-01-01"),
        ("0401-01-01", -146_097, "0001-01-01"),
        ("2028-02-29", 146_097, "2428-02-29"),
        ("2028-02-29", -146_097, "1628-02-29"),
        ("1900-02-28", 146_097, "2300-02-28"),
        ("0400-12-31", 1, "0401-01-01"),
        ("0401-01-01", -1, "0400-12-31")
    ])
    func largeCalendarAddition(_ start: String, _ offset: Int, _ expected: String) throws {
        #expect(try LocalDate(start).addingDays(offset) == LocalDate(expected))
    }
}
