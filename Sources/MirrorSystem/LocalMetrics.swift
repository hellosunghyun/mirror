import Foundation
import Darwin

public enum LocalMetricKind: String, Codable, Sendable {
    case captureAttempt, captureSaved, captureRejected, reviewOpened, reviewClosed, decisionCommitted, decisionRejected
    case undoRequested, undoResult, calendarPermissionChanged, syncStateChanged, widgetInteractionFinished
}
public enum MetricSurface: String, Codable, Sendable { case app, widget, shortcut, siri, share, spotlight }
public enum MetricOutcome: String, Codable, Sendable { case success, failure, stale, confirmation, unavailable, projectionPending }
public enum MetricDestination: String, Codable, Sendable { case day, week, unassigned, parked }
public struct LocalMetric: Codable, Sendable {
    public let kind: LocalMetricKind
    public let at: Date
    public let surface: MetricSurface
    public let outcome: MetricOutcome?
    public let destination: MetricDestination?
    public let processingMilliseconds: Int?
    public let activeReviewMilliseconds: Int?
    public let countBucket: Int?
    public init(kind: LocalMetricKind, at: Date, surface: MetricSurface, outcome: MetricOutcome? = nil,
                destination: MetricDestination? = nil, processingMilliseconds: Int? = nil,
                activeReviewMilliseconds: Int? = nil, countBucket: Int? = nil) {
        self.kind = kind; self.at = at; self.surface = surface; self.outcome = outcome; self.destination = destination
        self.processingMilliseconds = processingMilliseconds; self.activeReviewMilliseconds = activeReviewMilliseconds
        self.countBucket = countBucket
    }
}

/// 허용 속성을 타입으로 제한한다. taskID·제목·메모·마감·계정 문자열을 저장할 필드가 없다.
public actor LocalMetrics {
    private let fileURL: URL
    public init(directory: URL) { fileURL = directory.appendingPathComponent("diagnostics-v1.json") }
    public func record(_ event: LocalMetric) throws {
        guard (event.processingMilliseconds ?? 0) >= 0, (event.activeReviewMilliseconds ?? 0) >= 0 else {
            throw SystemServiceError.invalidInput
        }
        let lock = try acquire()
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        var events = try read()
        events.append(event)
        let earliest = event.at.addingTimeInterval(-14 * 24 * 60 * 60)
        events = Array(events.filter { $0.at >= earliest && $0.at <= event.at }.suffix(1_000))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(events).write(to: fileURL, options: .atomic)
    }
    public func erase() throws {
        let lock = try acquire()
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
    }
    /// 사용자가 연구용 요약 공유를 명시적으로 선택한 경우에만 호출한다.
    public func exportSummary(consentGiven: Bool) throws -> Data {
        guard consentGiven else { throw SystemServiceError.invalidInput }
        let lock = try acquire()
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        let events = try read()
        var counts: [String: Int] = [:]
        for event in events { counts[event.kind.rawValue, default: 0] += 1 }
        let active = try events.compactMap(\.activeReviewMilliseconds).reduce(0) { sum, value in
            let next = sum.addingReportingOverflow(value)
            guard !next.overflow else { throw SystemServiceError.invalidInput }
            return next.partialValue
        }
        if active > 0 { counts["activeReviewMilliseconds"] = active }
        return try JSONEncoder().encode(counts)
    }
    private func read() throws -> [LocalMetric] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([LocalMetric].self, from: Data(contentsOf: fileURL))
    }
    private func acquire() throws -> Int32 {
        let url = fileURL.deletingLastPathComponent().appendingPathComponent("Diagnostics.lock")
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SystemServiceError.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw SystemServiceError.unavailable }
        return descriptor
    }
}
