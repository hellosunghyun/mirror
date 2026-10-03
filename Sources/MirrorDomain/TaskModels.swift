import Foundation
import CryptoKit

public enum DomainContractError: Error, Equatable, Sendable {
    case invalidContent, invalidSourceURL, invalidDeadline, invalidRecord, invalidCommand
}

/// 원문을 실행하지 않는다. 제목은 확장 문자소 단위로 검증하고 임의로 자르지 않는다.
public struct TaskContent: Hashable, Codable, Sendable {
    public let title: String
    public let note: String?
    public let sourceURL: String?

    public init(title: String, note: String? = nil, sourceURL: String? = nil) throws {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...500).contains(cleaned.count), (note?.count ?? 0) <= 20_000 else {
            throw DomainContractError.invalidContent
        }
        if let sourceURL {
            guard let parts = URLComponents(string: sourceURL),
                  let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil,
                  sourceURL == sourceURL.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw DomainContractError.invalidSourceURL
            }
        }
        self.title = cleaned
        self.note = note
        self.sourceURL = sourceURL
    }

    private enum CodingKeys: String, CodingKey { case title, note, sourceURL }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(title: c.decode(String.self, forKey: .title),
                      note: c.decodeIfPresent(String.self, forKey: .note),
                      sourceURL: c.decodeIfPresent(String.self, forKey: .sourceURL))
    }
}

public enum MutationGroup: String, CaseIterable, Hashable, Codable, Sendable {
    case content, plan, status, deadline
}

public struct PlanValue: Hashable, Codable, Sendable {
    public let target: PlanTarget
    public let reviewNotBefore: LocalDate?
    public init(target: PlanTarget, reviewNotBefore: LocalDate? = nil) {
        self.target = target
        self.reviewNotBefore = reviewNotBefore
    }

    public static func assignment(_ target: PlanTarget, in context: PlanningContext) throws -> Self {
        let notBefore: LocalDate?
        if case let .week(start, _) = target {
            notBefore = start <= context.planningDay ? try context.planningDay.addingDays(1) : start
        } else { notBefore = nil }
        return Self(target: target, reviewNotBefore: notBefore)
    }
}

public struct StatusValue: Hashable, Codable, Sendable {
    public let status: TaskStatus
    public let completedAt: Date?
    public let deletedAt: Date?
    public let restoreReference: [String]
    public init(status: TaskStatus, completedAt: Date? = nil, deletedAt: Date? = nil,
                restoreReference: [String] = []) {
        self.status = status
        self.completedAt = completedAt
        self.deletedAt = deletedAt
        self.restoreReference = restoreReference.sorted()
    }
    public var isStructurallyValid: Bool {
        guard completedAt?.timeIntervalSinceReferenceDate.isFinite != false,
              deletedAt?.timeIntervalSinceReferenceDate.isFinite != false,
              Set(restoreReference).count == restoreReference.count else { return false }
        switch status {
        case .open: return completedAt == nil && deletedAt == nil
        case .completed: return completedAt != nil && deletedAt == nil
        case .deleted: return deletedAt != nil
        }
    }
}

public struct VersionStamp: Hashable, Codable, Sendable {
    public let winningOperationID: String
    public let headsDigest: String
    public let headIDs: [String]
    public init(taskID: UUID, group: MutationGroup, winningOperationID: String, headIDs: [String]) {
        self.winningOperationID = winningOperationID
        self.headIDs = headIDs.sorted()
        // 문자열을 구분자 없이 이어 붙이지 않고 길이와 경계를 보존하는 JSON으로 해시한다.
        self.headsDigest = CanonicalDigest.heads(taskID: taskID, group: group, ids: headIDs)
    }
}

public struct TaskProjection: Hashable, Codable, Sendable {
    public let taskID: UUID
    public let workspaceKey: String
    public let workspaceEpoch: String
    public let content: TaskContent
    public let plan: PlanValue
    public let lifecycle: StatusValue
    public let deadline: Deadline?
    public let createdAt: Date
    public let versions: [MutationGroup: VersionStamp]
    public let conflictGroups: Set<MutationGroup>
    public let isProjectionComplete: Bool
    public var title: String { content.title }
    public var status: TaskStatus { lifecycle.status }
    public var planningState: TaskPlanningState {
        TaskPlanningState(status: status, plan: plan.target, reviewNotBefore: plan.reviewNotBefore)
    }
    public init(taskID: UUID, workspaceKey: String, workspaceEpoch: String, content: TaskContent,
                plan: PlanValue, lifecycle: StatusValue, deadline: Deadline?, createdAt: Date,
                versions: [MutationGroup: VersionStamp], conflictGroups: Set<MutationGroup> = [],
                isProjectionComplete: Bool = true) {
        self.taskID = taskID; self.workspaceKey = workspaceKey; self.workspaceEpoch = workspaceEpoch
        self.content = content; self.plan = plan; self.lifecycle = lifecycle; self.deadline = deadline
        self.createdAt = createdAt; self.versions = versions; self.conflictGroups = conflictGroups
        self.isProjectionComplete = isProjectionComplete
    }
    public func value(for group: MutationGroup) -> MutationValue {
        switch group {
        case .content: .content(content)
        case .plan: .plan(plan)
        case .status: .status(lifecycle)
        case .deadline: .deadline(deadline)
        }
    }
}

/// SHA-256 대상은 정렬된 키의 UTF-8 JSON이다. 시각은 반올림한 정수 밀리초로 고정하여 재직렬화에도 안정적이다.
public enum CanonicalDigest {
    public static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
            guard milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) else {
                throw DomainContractError.invalidRecord
            }
            var container = encoder.singleValueContainer()
            try container.encode(Int64(milliseconds))
        }
        return try encoder.encode(value)
    }
    public static func hash<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try data(value)).map { String(format: "%02x", $0) }.joined()
    }
    public static func heads(taskID: UUID, group: MutationGroup, ids: [String]) -> String {
        struct Heads: Encodable { let taskID: String; let group: String; let heads: [String] }
        // 모든 값은 문자열이므로 이 고정 구조의 JSON 변환은 실패하지 않는다.
        let value = Heads(taskID: taskID.uuidString.lowercased(), group: group.rawValue, heads: ids.sorted())
        let bytes = (try? data(value)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

extension Deadline: Codable {
    private enum CodingKeys: String, CodingKey { case kind, localDate, timeZoneID, utcTimestamp, displayTimeZoneID }
    private enum Kind: String, Codable { case day, instant }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .day:
            self = .day(localDate: try c.decode(LocalDate.self, forKey: .localDate),
                        timeZoneID: try c.decode(String.self, forKey: .timeZoneID))
        case .instant:
            self = .instant(utcTimestamp: try c.decode(Date.self, forKey: .utcTimestamp),
                            displayTimeZoneID: try c.decode(String.self, forKey: .displayTimeZoneID))
        }
        guard isStructurallyValid else { throw DomainContractError.invalidDeadline }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .day(date, zone):
            try c.encode(Kind.day, forKey: .kind); try c.encode(date, forKey: .localDate)
            try c.encode(zone, forKey: .timeZoneID)
        case let .instant(date, zone):
            try c.encode(Kind.instant, forKey: .kind); try c.encode(date, forKey: .utcTimestamp)
            try c.encode(zone, forKey: .displayTimeZoneID)
        }
    }
    public var isStructurallyValid: Bool {
        switch self {
        case let .day(_, zone): return TimeZone(identifier: zone) != nil
        case let .instant(date, zone):
            return date.timeIntervalSinceReferenceDate.isFinite && TimeZone(identifier: zone) != nil
        }
    }
}

extension PlanningContext: Codable {
    private enum CodingKeys: String, CodingKey { case planningDay, timeZoneID, policyRevision, capturedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(planningDay: c.decode(LocalDate.self, forKey: .planningDay),
                      timeZoneID: c.decode(String.self, forKey: .timeZoneID),
                      policyRevision: c.decode(String.self, forKey: .policyRevision),
                      capturedAt: c.decode(Date.self, forKey: .capturedAt))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(planningDay, forKey: .planningDay); try c.encode(timeZoneID, forKey: .timeZoneID)
        try c.encode(policyRevision, forKey: .policyRevision); try c.encode(capturedAt, forKey: .capturedAt)
    }
}

extension DeadlineAcknowledgment: Codable {
    private enum CodingKeys: String, CodingKey { case taskID, deadlineRevision, target }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(taskID: try c.decode(String.self, forKey: .taskID),
                  deadlineRevision: try c.decode(String.self, forKey: .deadlineRevision),
                  target: try c.decode(PlanTarget.self, forKey: .target))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskID, forKey: .taskID); try c.encode(deadlineRevision, forKey: .deadlineRevision)
        try c.encode(target, forKey: .target)
    }
}
