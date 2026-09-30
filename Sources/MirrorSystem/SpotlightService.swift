import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import MirrorDomain

public enum SpotlightServiceError: Error, Equatable, Sendable { case configurationRequired }

public actor SpotlightService {
    private var index: CSSearchableIndex?
    private let domainIdentifier = "mirror.tasks"
    public init(index: CSSearchableIndex? = nil) { self.index = index }

    /// 사용자가 검색 노출을 허용한 경우에만 제목을 시스템 인덱스에 보낸다.
    public func reconcile(tasks: [TaskProjection], enabled: Bool, hideTitles: Bool) async throws {
        try await removeAll()
        guard enabled, !hideTitles else { return }
        let index = try resolvedIndex()
        let items = tasks.filter { $0.status != .deleted && $0.isProjectionComplete }.map { task in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = task.title
            attributes.contentDescription = planDescription(task.plan.target)
            // 메모·원문 URL·계정 ID·변경 이력은 인덱스에 넣지 않는다.
            return CSSearchableItem(uniqueIdentifier: task.taskID.uuidString,
                                    domainIdentifier: domainIdentifier, attributeSet: attributes)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.indexSearchableItems(items) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    public func removeAll() async throws {
        let index = try resolvedIndex()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func resolvedIndex() throws -> CSSearchableIndex {
        guard SystemAppleRuntimeHost.isApplicationOrExtension else { throw SpotlightServiceError.configurationRequired }
        if let index { return index }
        let resolved = CSSearchableIndex.default()
        index = resolved
        return resolved
    }

    private func planDescription(_ plan: PlanTarget) -> String {
        switch plan {
        case .unassigned: "아직 날짜를 정하지 않음"
        case let .day(date): "계획 \(date)"
        case let .week(start, _): "\(start)부터 그 주, 요일 미정"
        case .parked: "보관"
        }
    }
}
