import Foundation
@testable import MirrorData
import Testing

private func selectionReport(taskCount: Int, account: Bool = false, workspace: Bool = false) -> ImportPreview {
    ImportPreview(operationCount: taskCount, taskCount: taskCount, newTaskCount: taskCount,
                  duplicateCount: 0, quarantinedRecordCount: 0, warnings: [],
                  requiresWorkspaceConfirmation: workspace, requiresAccountConfirmation: account,
                  sourceWorkspaceEpoch: "selection-epoch")
}

@Suite("복원 파일 선택과 동의 identity")
struct ArchiveImportSelectionTests {
    @Test("백업 A에서 동의한 뒤 B를 고르면 두 동의를 B에서 다시 받아야 한다")
    func replacementRequiresItsOwnConsent() throws {
        var selection = ArchiveImportSelection()
        let first = selection.begin()
        let firstApplied = selection.complete(id: first, data: Data("A".utf8), report: selectionReport(taskCount: 1, account: true, workspace: true))
        #expect(firstApplied)
        #expect(try selection.authorizedPreview(id: first, accountConfirmationID: first, workspaceConfirmationID: first).data == Data("A".utf8))

        let second = selection.begin()
        #expect(selection.preview == nil)
        #expect(throws: ArchiveImportSelection.AuthorizationError.previewChanged) {
            try selection.authorizedPreview(id: first, accountConfirmationID: first, workspaceConfirmationID: first)
        }
        let secondApplied = selection.complete(id: second, data: Data("B".utf8), report: selectionReport(taskCount: 2, account: true, workspace: true))
        #expect(secondApplied)
        #expect(throws: ArchiveImportSelection.AuthorizationError.accountConfirmationRequired) {
            try selection.authorizedPreview(id: second, accountConfirmationID: first, workspaceConfirmationID: first)
        }
        #expect(throws: ArchiveImportSelection.AuthorizationError.workspaceConfirmationRequired) {
            try selection.authorizedPreview(id: second, accountConfirmationID: second, workspaceConfirmationID: first)
        }
        let ready = try selection.authorizedPreview(id: second, accountConfirmationID: second, workspaceConfirmationID: second)
        #expect(ready.data == Data("B".utf8))
        #expect(ready.report.taskCount == 2)
    }

    @Test("B 검사가 먼저 끝난 뒤 A가 완료되어도 B bytes와 보고서가 함께 유지된다")
    func outOfOrderCompletionKeepsLatestBytesAndReport() throws {
        var selection = ArchiveImportSelection()
        let first = selection.begin(), second = selection.begin()
        let secondApplied = selection.complete(id: second, data: Data("B".utf8), report: selectionReport(taskCount: 2))
        #expect(secondApplied)
        let firstApplied = selection.complete(id: first, data: Data("A".utf8), report: selectionReport(taskCount: 1))
        #expect(!firstApplied)
        let ready = try selection.authorizedPreview(id: second)
        #expect(ready.id == second)
        #expect(ready.data == Data("B".utf8))
        #expect(ready.report.taskCount == 2)
        let firstDiscarded = selection.discard(id: first)
        #expect(!firstDiscarded)
        #expect(try selection.authorizedPreview(id: second).data == Data("B".utf8))
    }

    @Test("B 검사 중 먼저 끝난 A는 실행할 수 있는 미리보기를 되살리지 않는다")
    func staleCompletionWhileLatestIsPendingIsDiscarded() throws {
        var selection = ArchiveImportSelection()
        let first = selection.begin(), second = selection.begin()
        let firstApplied = selection.complete(id: first, data: Data("A".utf8), report: selectionReport(taskCount: 1))
        #expect(!firstApplied)
        #expect(selection.preview == nil)
        #expect(throws: ArchiveImportSelection.AuthorizationError.previewChanged) {
            try selection.authorizedPreview(id: second)
        }
        let secondApplied = selection.complete(id: second, data: Data("B".utf8), report: selectionReport(taskCount: 2))
        #expect(secondApplied)
        #expect(try selection.authorizedPreview(id: second).report.taskCount == 2)
    }

    @Test("선택 취소·읽기 실패·공간 전환 뒤 늦은 완료와 이전 동의는 복원을 시작하지 못한다")
    func cancellationFailureAndWorkspaceResetInvalidatePendingPreview() {
        var selection = ArchiveImportSelection()
        let previous = selection.begin()
        let previousApplied = selection.complete(id: previous, data: Data("A".utf8), report: selectionReport(taskCount: 1))
        #expect(previousApplied)
        let failed = selection.begin()
        let failedDiscarded = selection.discard(id: failed)
        #expect(failedDiscarded)
        #expect(selection.selectionID == nil)
        #expect(selection.preview == nil)
        let failedApplied = selection.complete(id: failed, data: Data("B".utf8), report: selectionReport(taskCount: 2))
        #expect(!failedApplied)
        #expect(throws: ArchiveImportSelection.AuthorizationError.previewChanged) {
            try selection.authorizedPreview(id: previous, accountConfirmationID: previous, workspaceConfirmationID: previous)
        }

        let pending = selection.begin()
        selection.clear()
        let pendingApplied = selection.complete(id: pending, data: Data("C".utf8), report: selectionReport(taskCount: 3))
        #expect(!pendingApplied)
        #expect(selection.preview == nil)
    }

    @Test("같은 선택의 중복 완료도 사용자가 확인한 원본과 보고서를 교체하지 않는다")
    func duplicateCompletionPreservesReviewedPreview() throws {
        var selection = ArchiveImportSelection()
        let id = selection.begin()
        let firstApplied = selection.complete(id: id, data: Data("A".utf8), report: selectionReport(taskCount: 1, account: true))
        #expect(firstApplied)
        let duplicateApplied = selection.complete(id: id, data: Data("B".utf8), report: selectionReport(taskCount: 2))
        #expect(!duplicateApplied)
        let ready = try selection.authorizedPreview(id: id, accountConfirmationID: id)
        #expect(ready.data == Data("A".utf8))
        #expect(ready.report.taskCount == 1)
        #expect(ready.report.requiresAccountConfirmation)
    }
}
