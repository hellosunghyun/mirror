import Foundation
import EventKit

public enum CalendarAccess: String, Codable, Sendable {
    case notDetermined, fullAccess, writeOnly, denied, restricted, unknown
}
public enum CalendarServiceError: Error, Equatable, Sendable { case accessRequired, invalidRange }
public struct CalendarDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}
public struct CalendarEventSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let calendarID: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public init(id: String, calendarID: String, title: String, start: Date, end: Date, isAllDay: Bool) {
        self.id = id; self.calendarID = calendarID; self.title = title
        self.start = start; self.end = end; self.isAllDay = isAllDay
    }
}

/// 기기 로컬, 읽기 전용 어댑터다. 쓰기/미리 알림 API를 공개하지 않는다.
public actor CalendarService {
    private let eventStore = EKEventStore()
    private var observer: CalendarObserver?
    private var cached: (start: Date, end: Date, calendarIDs: [String], at: Date, events: [CalendarEventSummary])?

    public init() {}

    public func authorization() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .fullAccess, .authorized: .fullAccess
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    /// UI에서 사용자가 기존 약속 보기를 선택한 경우에만 호출한다.
    public func requestFullAccess() async throws -> Bool {
        let granted: Bool = try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
        cached = nil
        return granted
    }

    public func calendars() throws -> [CalendarDescriptor] {
        try requireAccess()
        observeChanges()
        return eventStore.calendars(for: .event).map { .init(id: $0.calendarIdentifier, title: $0.title) }
    }

    public func events(from start: Date, to end: Date, calendarIDs: [String], now: Date = Date()) throws -> [CalendarEventSummary] {
        try requireAccess()
        guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              end > start, end.timeIntervalSince(start) <= 120 * 86_400 else { throw CalendarServiceError.invalidRange }
        observeChanges()
        let ids = calendarIDs.sorted()
        if let cached, cached.start == start, cached.end == end, cached.calendarIDs == ids,
           now.timeIntervalSince(cached.at) >= 0, now.timeIntervalSince(cached.at) < 15 * 60 { return cached.events }
        // 선택하지 않은 상태를 모든 캘린더 읽기로 해석하지 않는다.
        guard !ids.isEmpty else { cached = nil; return [] }
        let selected = eventStore.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { cached = nil; return [] }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: selected)
        let result = eventStore.events(matching: predicate).map {
            CalendarEventSummary(id: $0.eventIdentifier ?? UUID().uuidString,
                                 calendarID: $0.calendar.calendarIdentifier,
                                 title: $0.title ?? "제목 없는 일정", start: $0.startDate,
                                 end: $0.endDate, isAllDay: $0.isAllDay)
        }.sorted { $0.start < $1.start }
        cached = (start, end, ids, now, result)
        return result
    }

    /// 전경 복귀·선택 캘린더 변경·권한 철회에 호출한다.
    public func clearCache() { cached = nil }

    private func requireAccess() throws {
        guard authorization() == .fullAccess else { cached = nil; throw CalendarServiceError.accessRequired }
    }

    private func observeChanges() {
        guard observer == nil else { return }
        let token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: nil) { [weak self] _ in
            Task { await self?.clearCache() }
        }
        observer = CalendarObserver(token: token)
    }
}

/// NotificationCenter의 등록/해제는 스레드 안전하고 토큰은 관찰 종료에만 사용한다.
private final class CalendarObserver: @unchecked Sendable {
    private let token: any NSObjectProtocol
    init(token: any NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
