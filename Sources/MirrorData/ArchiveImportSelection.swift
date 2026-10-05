import Foundation

/// 파일 선택·검사·동의를 같은 identity에 묶고 늦게 끝난 검사를 버린다.
public struct ArchiveImportSelection: Sendable {
    public struct Preview: Identifiable, Sendable {
        public let id: UUID
        public let data: Data
        public let report: ImportPreview
    }

    public enum AuthorizationError: Error, Equatable, Sendable {
        case previewChanged
        case accountConfirmationRequired
        case workspaceConfirmationRequired
    }

    public private(set) var selectionID: UUID?
    public private(set) var preview: Preview?

    public init() {}

    /// 파일 선택기를 열 때 이전 bytes·보고서·동의의 유효성을 먼저 없앤다.
    @discardableResult
    public mutating func begin() -> UUID {
        let id = UUID()
        selectionID = id
        preview = nil
        return id
    }

    @discardableResult
    public mutating func complete(id: UUID, data: Data, report: ImportPreview) -> Bool {
        guard selectionID == id, preview == nil else { return false }
        preview = Preview(id: id, data: data, report: report)
        return true
    }

    /// 이전 파일의 실패나 취소는 새 파일의 미리보기를 지우지 않는다.
    @discardableResult
    public mutating func discard(id: UUID) -> Bool {
        guard selectionID == id else { return false }
        clear()
        return true
    }

    public mutating func clear() {
        selectionID = nil
        preview = nil
    }

    public func authorizedPreview(id: UUID, accountConfirmationID: UUID? = nil,
                                  workspaceConfirmationID: UUID? = nil) throws -> Preview {
        guard selectionID == id, let preview, preview.id == id else {
            throw AuthorizationError.previewChanged
        }
        if preview.report.requiresAccountConfirmation, accountConfirmationID != id {
            throw AuthorizationError.accountConfirmationRequired
        }
        if preview.report.requiresWorkspaceConfirmation, workspaceConfirmationID != id {
            throw AuthorizationError.workspaceConfirmationRequired
        }
        return preview
    }
}
