import Foundation

/// 이 함수는 원본을 준비할 뿐 저장하지 않는다. 저장 계층이 쓰기 게이트 안에서 최신 snapshot을 주입한다.
public enum CommandValidator {
    public static func prepare(_ command: CommandEnvelope, snapshot: CommandSnapshot) -> CommandPreparation {
        func reject(_ state: CommandResultState, _ message: String, _ tasks: [UUID] = []) -> CommandPreparation {
            .rejected(CommandRejection(state: state, message: message, taskIDs: tasks))
        }
        guard command.contractVersion == 1, (1...200).contains(command.requestID.unicodeScalars.count),
              (1...200).contains(command.idempotencyKey.unicodeScalars.count),
              !command.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !command.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !snapshot.workspaceKey.isEmpty, command.workspaceEpoch == snapshot.workspaceEpoch,
              snapshot.recordedAt.timeIntervalSinceReferenceDate.isFinite else {
            return reject(.unavailable, "현재 데이터 공간에서 처리할 수 없는 요청이에요.")
        }
        guard let digest = try? command.logicalDigest() else { return reject(.unavailable, "요청 내용을 확인해 주세요.") }
        // 계정·세대 경계 확인 후 영수증을 먼저 조회한다. 날짜가 지난 동일 입력도 다시 실행하지 않는다.
        let receipts = snapshot.receipts.filter { $0.workspaceEpoch == snapshot.workspaceEpoch && $0.key == command.idempotencyKey }
        if Set(receipts.map(\.digest)).count > 1 { return reject(.unavailable, "기존 변경 기록을 확인해야 해요.") }
        if let receipt = receipts.first {
            return receipt.digest == digest ? .alreadyApplied(receipt) : .alreadyDecided(receipt)
        }
        let prior = snapshot.records.filter { $0.workspaceKey == snapshot.workspaceKey
            && $0.workspaceEpoch == snapshot.workspaceEpoch && $0.idempotencyKey == command.idempotencyKey }
        if !prior.isEmpty {
            guard Set(prior.map(\.operationID)).count == 1, Set(prior.map(\.payloadDigest)).count == 1,
                  prior.allSatisfy({ (try? $0.computedDigest()) == $0.payloadDigest }),
                  let receipt = prior.first?.recoveredReceipt(requestID: command.requestID) else {
                return reject(.unavailable, "기존 변경 기록을 확인해야 해요.")
            }
            return receipt.digest == digest ? .alreadyApplied(receipt) : .alreadyDecided(receipt)
        }
        guard let logicalID = try? OperationRecord.logicalID(workspaceKey: snapshot.workspaceKey,
            workspaceEpoch: snapshot.workspaceEpoch, idempotencyKey: command.idempotencyKey),
              !snapshot.records.contains(where: { $0.operationID == logicalID }) else {
            return reject(.unavailable, "변경 키와 원본 기록을 확인해야 해요.")
        }
        guard PlanningRules.checkContext(displayed: command.context, current: snapshot.currentContext,
                                         matchingReceiptExists: false) == .continueValidation else {
            return reject(.staleContext, "날짜나 계획 설정이 바뀌었어요. 새 화면에서 다시 선택해 주세요.")
        }
        var mutations: [TaskMutation] = []
        var undoValues: [TaskMutation] = []
        var operationKind: OperationKind = .capture
        var compensates: String?
        var decision: ReviewDecisionContext?
        var closure: ReviewClosure?
        var settings: PlanningPolicy?
        var schemaVersion = 1

        func task(_ id: UUID) throws -> TaskProjection {
            guard let value = snapshot.tasks[id] else { throw ValidationFailure(.notFound, "작업을 찾을 수 없어요.", [id]) }
            guard value.workspaceKey == snapshot.workspaceKey, value.workspaceEpoch == snapshot.workspaceEpoch,
                  value.isProjectionComplete else {
                throw ValidationFailure(.unavailable, "이 작업의 변경을 반영 중이에요.", [id])
            }
            return value
        }
        func check(_ value: TaskProjection, group: MutationGroup, expected: String?) throws {
            guard let expected, !expected.isEmpty, expected == value.versions[group]?.headsDigest else {
                throw ValidationFailure(.staleSnapshot, "다른 변경이 반영됐어요. 새 화면에서 다시 선택해 주세요.", [value.taskID])
            }
        }
        func append(_ value: TaskProjection, _ newValue: MutationValue) {
            mutations.append(TaskMutation(taskID: value.taskID, value: newValue,
                                           observedHeadIDs: value.versions[newValue.group]?.headIDs ?? []))
            undoValues.append(TaskMutation(taskID: value.taskID, value: value.value(for: newValue.group)))
        }
        func plan(_ item: PlanCommandItem, _ target: PlanTarget) throws {
            let value = try task(item.taskID)
            for group in MutationGroup.allCases { try check(value, group: group, expected: item.expected[group]) }
            guard value.status == .open else { throw ValidationFailure(.staleSnapshot, "이미 완료하거나 휴지통에 보낸 작업이에요.", [value.taskID]) }
            guard PlanningRules.validatePlan(target, on: snapshot.currentContext.planningDay) else {
                throw ValidationFailure(.unavailable, "오늘 이후의 날짜나 올바른 주를 선택해 주세요.", [value.taskID])
            }
            let deadlineDate: LocalDate?
            do { deadlineDate = try value.deadline?.planningDate(in: snapshot.currentContext) }
            catch { throw ValidationFailure(.unavailable, "작업의 마감을 확인해야 해요.", [value.taskID]) }
            if PlanningRules.needsDeadlineConfirmation(taskID: value.taskID.uuidString,
                deadlineRevision: value.versions[.deadline]?.headsDigest ?? "", target: target,
                deadlineLocalDate: deadlineDate, acknowledgment: item.acknowledgment) {
                throw ValidationFailure(.requiresConfirmation, "선택한 날짜가 실제 마감 이후예요. 계속할지 확인해 주세요.", [value.taskID])
            }
            append(value, .plan(try PlanValue.assignment(target, in: snapshot.currentContext)))
        }
        func capture(_ id: UUID, _ content: TaskContent, initialPlan: PlanTarget) throws {
            guard snapshot.tasks[id] == nil,
                  !snapshot.records.contains(where: { $0.mutations.contains { $0.taskID == id } }) else {
                throw ValidationFailure(.staleSnapshot, "이미 있는 작업 ID예요.", [id])
            }
            guard PlanningRules.validatePlan(initialPlan, on: snapshot.currentContext.planningDay) else {
                throw ValidationFailure(.unavailable, "오늘 이후의 날짜나 올바른 주를 선택해 주세요.", [id])
            }
            operationKind = .capture
            mutations = [TaskMutation(taskID: id, value: .content(content)),
                         TaskMutation(taskID: id, value: .plan(try PlanValue.assignment(initialPlan, in: snapshot.currentContext))),
                         TaskMutation(taskID: id, value: .status(StatusValue(status: .open))),
                         TaskMutation(taskID: id, value: .deadline(nil))]
            undoValues = [TaskMutation(taskID: id, value: .status(StatusValue(status: .deleted, deletedAt: snapshot.recordedAt)))]
        }
        do {
            switch command.payload {
            case let .capture(id, content):
                try capture(id, content, initialPlan: .unassigned)
            case let .captureWithPlan(id, content, initialPlan):
                switch initialPlan {
                case .day, .week: break
                case .unassigned, .parked:
                    throw ValidationFailure(.unavailable, "입력에서 선택한 날짜를 확인해 주세요.", [id])
                }
                schemaVersion = 2
                try capture(id, content, initialPlan: initialPlan)
            case let .setPlan(item, target, review):
                operationKind = .setPlan
                if let review {
                    guard review.taskID == item.taskID, !review.cardID.isEmpty, !review.sessionID.isEmpty,
                          review.cycleID == ReviewCycle.id(workspaceEpoch: snapshot.workspaceEpoch,
                                                          context: snapshot.currentContext) else {
                        throw ValidationFailure(.staleSnapshot, "표시한 정리 카드에서 다시 선택해 주세요.", [item.taskID])
                    }
                }
                try plan(item, target); decision = review
            case let .batchSetPlan(items, target):
                operationKind = .setPlan
                guard (1...20).contains(items.count), Set(items.map(\.taskID)).count == items.count else {
                    throw ValidationFailure(.unavailable, "서로 다른 작업을 최대 20개까지 선택해 주세요.", items.map(\.taskID))
                }
                for item in items { try plan(item, target) }
            case let .park(id, expected):
                operationKind = .setPlan
                let value = try task(id)
                try check(value, group: .plan, expected: expected.plan)
                try check(value, group: .status, expected: expected.status)
                guard value.status == .open else { throw ValidationFailure(.staleSnapshot, "열린 작업만 보관할 수 있어요.", [id]) }
                append(value, .plan(PlanValue(target: .parked)))
            case let .completion(id, desired, expected):
                operationKind = .setStatus
                let value = try task(id); try check(value, group: .status, expected: expected)
                guard value.status != .deleted else { throw ValidationFailure(.staleSnapshot, "휴지통 작업은 먼저 복구해 주세요.", [id]) }
                let state = desired ? StatusValue(status: .completed, completedAt: value.lifecycle.completedAt ?? snapshot.recordedAt)
                                    : StatusValue(status: .open)
                append(value, .status(state))
            case let .trash(id, expected):
                operationKind = .setStatus
                let value = try task(id); try check(value, group: .status, expected: expected)
                guard value.status != .deleted else { throw ValidationFailure(.staleSnapshot, "이미 휴지통에 보낸 작업이에요.", [id]) }
                append(value, .status(StatusValue(status: .deleted, completedAt: value.lifecycle.completedAt,
                                                  deletedAt: snapshot.recordedAt)))
            case let .restore(id, observedDeleteHeadIDs, expected):
                operationKind = .setStatus
                let value = try task(id); try check(value, group: .status, expected: expected)
                guard value.status == .deleted else { throw ValidationFailure(.staleSnapshot, "현재 휴지통에 있는 작업을 선택해 주세요.", [id]) }
                let heads = value.versions[.status]?.headIDs ?? []
                let deleteHeads = heads.filter { head in
                    snapshot.records.contains { record in
                        record.operationID == head && record.mutations.contains { mutation in
                            guard mutation.taskID == id, case let .status(state) = mutation.value else { return false }
                            return state.status == .deleted
                        }
                    }
                }
                guard !deleteHeads.isEmpty, Set(deleteHeads) == Set(observedDeleteHeadIDs),
                      observedDeleteHeadIDs.count == Set(observedDeleteHeadIDs).count else {
                    throw ValidationFailure(.staleSnapshot, "최신 삭제 기록을 확인한 뒤 복구해 주세요.", [id])
                }
                append(value, .status(StatusValue(status: .open, restoreReference: deleteHeads)))
            case let .setDeadline(id, deadline, expected):
                operationKind = .setDeadline
                let value = try task(id); try check(value, group: .deadline, expected: expected)
                guard deadline?.isStructurallyValid != false else {
                    throw ValidationFailure(.unavailable, "올바른 마감과 시간대를 선택해 주세요.", [id])
                }
                append(value, .deadline(deadline))
            case let .editContent(id, content, expected):
                operationKind = .editContent
                let value = try task(id); try check(value, group: .content, expected: expected)
                append(value, .content(content))
            case let .undo(id, expected):
                operationKind = .undo
                guard let original = snapshot.records.first(where: { $0.operationID == id }),
                      original.workspaceKey == snapshot.workspaceKey, original.workspaceEpoch == snapshot.workspaceEpoch,
                      (try? original.computedDigest()) == original.payloadDigest,
                      !original.undoValues.isEmpty else {
                    throw ValidationFailure(.unavailable, "되돌릴 원본 변경을 찾을 수 없어요.")
                }
                let required = Set(original.undoValues.map { "\($0.taskID.uuidString):\($0.group.rawValue)" })
                guard expected.count == required.count,
                      Set(expected.map { "\($0.taskID.uuidString):\($0.group.rawValue)" }) == required else {
                    throw ValidationFailure(.staleSnapshot, "되돌릴 변경의 전체 버전을 확인해 주세요.", original.affectedTaskIDs)
                }
                for before in original.undoValues {
                    let value = try task(before.taskID)
                    let stamp = value.versions[before.group]
                    guard let expectation = expected.first(where: { $0.taskID == before.taskID && $0.group == before.group }),
                          stamp?.headsDigest == expectation.headsDigest, stamp?.headIDs == [id] else {
                        throw ValidationFailure(.staleSnapshot, "그 이후의 변경이 있어 함께 되돌릴 수 없어요.", [before.taskID])
                    }
                    var previous = before.value
                    if case let .status(status) = previous {
                        previous = .status(StatusValue(status: status.status,
                            completedAt: status.completedAt,
                            deletedAt: status.status == .deleted ? snapshot.recordedAt : nil,
                            restoreReference: value.status == .deleted ? (stamp?.headIDs ?? []) : status.restoreReference))
                    }
                    append(value, previous)
                }
                compensates = id
            case let .reviewClose(value):
                operationKind = .reviewClose
                guard value.cycleID == ReviewCycle.id(workspaceEpoch: snapshot.workspaceEpoch, context: snapshot.currentContext),
                      !value.sessionID.isEmpty else { throw ValidationFailure(.staleContext, "현재 정리 화면에서 마쳐 주세요.") }
                if let week = value.weeklyCoverageStartDate,
                   week != (try snapshot.currentContext.planningDay.mondayWeek()).startDate {
                    throw ValidationFailure(.staleContext, "현재 주의 정리 화면에서 마쳐 주세요.")
                }
                closure = value
            case let .settings(policy, expectedRevision):
                operationKind = .settings
                guard expectedRevision == snapshot.currentContext.policyRevision else {
                    throw ValidationFailure(.staleSnapshot, "계획 설정이 바뀌었어요. 다시 확인해 주세요.")
                }
                guard TimeZone(identifier: policy.timeZoneID) != nil, !policy.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      policy.revision != expectedRevision else {
                    throw ValidationFailure(.unavailable, "새 계획 설정의 시간대와 버전을 확인해 주세요.")
                }
                settings = policy
            }
            let observed = max(snapshot.observedLamport, snapshot.records.map(\.lamport).max() ?? 0)
            guard observed < Int64.max, observed >= 0 else { throw ValidationFailure(.unavailable, "변경 기록의 버전을 확인해야 해요.") }
            let operation = try OperationRecord.create(
                operationID: logicalID,
                schemaVersion: schemaVersion,
                workspaceKey: snapshot.workspaceKey, workspaceEpoch: snapshot.workspaceEpoch, deviceID: snapshot.deviceID,
                lamport: observed + 1, recordedAt: snapshot.recordedAt, commandKind: operationKind, mutations: mutations,
                idempotencyKey: command.idempotencyKey, logicalCommandDigest: digest, undoValues: undoValues,
                compensatesOperationID: compensates, reviewDecision: decision, reviewClosure: closure, settings: settings)
            return .prepared(PreparedCommand(operation: operation, affectedTaskIDs: operation.affectedTaskIDs, logicalDigest: digest))
        } catch let failure as ValidationFailure {
            return reject(failure.state, failure.message, failure.taskIDs)
        } catch { return reject(.unavailable, "요청 내용을 확인한 뒤 다시 시도해 주세요.") }
    }
    private struct ValidationFailure: Error {
        let state: CommandResultState; let message: String; let taskIDs: [UUID]
        init(_ state: CommandResultState, _ message: String, _ taskIDs: [UUID] = []) {
            self.state = state; self.message = message; self.taskIDs = taskIDs
        }
    }
}
