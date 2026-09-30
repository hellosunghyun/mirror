import Foundation

public enum TaskReducer {
    public static func reduce(_ records: [OperationRecord], workspaceKey: String,
                              workspaceEpoch: String) -> ReductionReport {
        var quarantined: [String: ReductionIssue] = [:]
        var pending: [String: ReductionIssue] = [:]
        var valid: [String: OperationRecord] = [:]
        // 같은 ID의 모든 변형을 함께 격리한다. 먼저 도착한 변형을 승자로 남기지 않는다.
        for (id, copies) in Dictionary(grouping: records, by: \.operationID) {
            let calculated = copies.map { try? $0.computedDigest() }
            if Set(copies.map(\.payloadDigest)).count > 1 || Set(calculated.compactMap { $0 }).count > 1 {
                quarantined[id] = .conflictingDuplicate; continue
            }
            guard let record = copies.first, calculated.allSatisfy({ $0 == record.payloadDigest }) else {
                quarantined[id] = .invalidDigest; continue
            }
            guard record.workspaceKey == workspaceKey, record.workspaceEpoch == workspaceEpoch else {
                quarantined[id] = .wrongWorkspace; continue
            }
            guard record.schemaVersion == 1 else { quarantined[id] = .unsupportedSchema; continue }
            guard structurallyValid(record) else { quarantined[id] = .malformedRecord; continue }
            valid[id] = record
        }
        // 알려진 기록끼리 만드는 순환은 단순 미도착과 구분하여 격리한다.
        for id in cyclicIDs(in: valid) {
            quarantined[id] = .cyclicDependency
            valid.removeValue(forKey: id)
        }
        var creations: [UUID: OperationRecord] = [:]
        for (taskID, candidates) in Dictionary(grouping: valid.values.filter { $0.commandKind == .capture },
                                              by: { $0.mutations[0].taskID }) {
            guard candidates.count == 1, let candidate = candidates.first else {
                for candidate in candidates { quarantined[candidate.operationID] = .malformedRecord }
                continue
            }
            creations[taskID] = candidate
        }
        for id in quarantined.keys { valid.removeValue(forKey: id) }
        var applied: [String: OperationRecord] = [:]
        var waiting = valid
        var progressed = true
        while progressed {
            progressed = false
            for record in waiting.values.sorted(by: precedes) {
                let id = record.operationID
                let parentIDs = Set(record.mutations.flatMap(\.observedHeadIDs))
                if parentIDs.contains(id) {
                    pending[id] = .cyclicDependency; continue
                }
                if let original = record.compensatesOperationID, applied[original] == nil {
                    pending[id] = .missingParent; continue
                }
                guard parentIDs.allSatisfy({ applied[$0] != nil }) else {
                    pending[id] = .missingParent; continue
                }
                if record.commandKind != .capture {
                    guard record.affectedTaskIDs.allSatisfy({ taskID in
                        if let creation = creations[taskID] { return applied[creation.operationID] != nil }
                        return false
                    }) else { pending[id] = .missingCreation; continue }
                }
                let parentsMatch = record.mutations.allSatisfy { mutation in
                    guard record.commandKind == .capture || !mutation.observedHeadIDs.isEmpty else { return false }
                    guard mutation.observedHeadIDs.allSatisfy({ parentID in
                        guard let parent = applied[parentID], parent.lamport < record.lamport else { return false }
                        return parent.mutations.contains { $0.taskID == mutation.taskID && $0.group == mutation.group }
                    }) else { return false }
                    if case let .status(next) = mutation.value, next.status != .deleted {
                        let deleteParents = mutation.observedHeadIDs.filter { parentID in
                            applied[parentID]?.mutations.contains { parentMutation in
                                guard parentMutation.taskID == mutation.taskID,
                                      case let .status(previous) = parentMutation.value else { return false }
                                return previous.status == .deleted
                            } == true
                        }
                        // 이미 관측한 삭제를 완료 취소로 우회하여 부활시키지 않는다.
                        guard Set(deleteParents).isSubset(of: Set(next.restoreReference)) else { return false }
                    }
                    return true
                }
                guard parentsMatch else {
                    quarantined[id] = .invalidParent; waiting.removeValue(forKey: id)
                    pending.removeValue(forKey: id); progressed = true; continue
                }
                if record.commandKind == .undo {
                    guard let originalID = record.compensatesOperationID, let original = applied[originalID],
                          original.undoValues.count == record.mutations.count,
                          record.mutations.allSatisfy({ mutation in
                            guard mutation.observedHeadIDs == [originalID],
                                  let before = original.undoValues.first(where: {
                                    $0.taskID == mutation.taskID && $0.group == mutation.group
                                  }) else { return false }
                            if case let .status(next) = mutation.value, case let .status(previous) = before.value {
                                return next.status == previous.status && next.completedAt == previous.completedAt
                            }
                            return mutation.value == before.value
                          }) else {
                        quarantined[id] = .malformedRecord; waiting.removeValue(forKey: id)
                        pending.removeValue(forKey: id); progressed = true; continue
                    }
                }
                // 한 기록의 모든 mutation을 함께 받아들인다. batch의 부분 투영은 하지 않는다.
                applied[id] = record; waiting.removeValue(forKey: id); pending.removeValue(forKey: id)
                progressed = true
            }
        }
        var tasks: [UUID: TaskProjection] = [:]
        // 초기 복원에서도 작업 수 × 전체 기록 수를 반복하지 않는다. batch는 각 영향 그룹에 한 번씩 색인한다.
        var groupRecords: [UUID: [MutationGroup: [OperationRecord]]] = [:]
        for record in applied.values {
            for mutation in record.mutations {
                groupRecords[mutation.taskID, default: [:]][mutation.group, default: []].append(record)
            }
        }
        let affectedPending = Set(records.filter { $0.workspaceKey == workspaceKey && $0.workspaceEpoch == workspaceEpoch
            && (pending[$0.operationID] != nil || quarantined[$0.operationID] != nil) }.flatMap(\.affectedTaskIDs))
        for (taskID, creation) in creations where applied[creation.operationID] != nil {
            var winners: [MutationGroup: MutationValue] = [:]
            var versions: [MutationGroup: VersionStamp] = [:]
            var conflicts: Set<MutationGroup> = []
            for group in MutationGroup.allCases {
                let relevant = groupRecords[taskID]?[group] ?? []
                let replaced = Set(relevant.flatMap { record in
                    record.mutations.filter { $0.taskID == taskID && $0.group == group }.flatMap(\.observedHeadIDs)
                })
                let heads = relevant.filter { !replaced.contains($0.operationID) }
                guard let winner = heads.max(by: { preferredLess($0, $1, taskID: taskID, group: group) }),
                      let mutation = winner.mutations.first(where: { $0.taskID == taskID && $0.group == group }) else { continue }
                winners[group] = mutation.value
                versions[group] = VersionStamp(taskID: taskID, group: group,
                    winningOperationID: winner.operationID, headIDs: heads.map(\.operationID))
                if heads.count > 1 { conflicts.insert(group) }
            }
            guard case let .content(content)? = winners[.content], case let .plan(plan)? = winners[.plan],
                  case let .status(lifecycle)? = winners[.status], case let .deadline(deadline)? = winners[.deadline] else { continue }
            tasks[taskID] = TaskProjection(taskID: taskID, workspaceKey: workspaceKey, workspaceEpoch: workspaceEpoch,
                content: content, plan: plan, lifecycle: lifecycle, deadline: deadline, createdAt: creation.recordedAt,
                versions: versions, conflictGroups: conflicts, isProjectionComplete: !affectedPending.contains(taskID))
        }
        let acknowledgments = applied.values.sorted(by: precedes).compactMap { record -> ReviewAcknowledgment? in
            guard let decision = record.reviewDecision,
                  record.mutations.contains(where: { $0.taskID == decision.taskID && $0.group == .plan }) else { return nil }
            return ReviewAcknowledgment(cycleID: decision.cycleID, taskID: decision.taskID,
                planVersion: CanonicalDigest.heads(taskID: decision.taskID, group: .plan, ids: [record.operationID]),
                decisionOperationID: record.operationID)
        }
        var cycles: [String: ReviewCycleProjection] = [:]
        for record in applied.values.sorted(by: precedes) {
            guard let closure = record.reviewClosure else { continue }
            cycles[closure.cycleID] = ReviewCycleProjection(cycleID: closure.cycleID, closed: true,
                closeOperationID: record.operationID,
                weeklyCoverageStartDate: closure.weeklyCoverageStartDate ?? cycles[closure.cycleID]?.weeklyCoverageStartDate)
        }
        return ReductionReport(tasks: tasks, pending: pending, quarantined: quarantined,
            appliedOperationIDs: Set(applied.keys), acknowledgments: acknowledgments, cycles: cycles,
            settings: applied.values.filter { $0.commandKind == .settings }.max(by: precedes)?.settings)
    }

    private static func cyclicIDs(in records: [String: OperationRecord]) -> Set<String> {
        struct Frame { let id: String; let parents: [String]; var index: Int }
        var state: [String: Int] = [:]
        var cycles: Set<String> = []
        for root in records.keys.sorted() where state[root] == nil {
            var stack: [Frame] = []
            var positions: [String: Int] = [:]
            func push(_ id: String) {
                guard let record = records[id] else { return }
                var parents = Set(record.mutations.flatMap(\.observedHeadIDs))
                if let original = record.compensatesOperationID { parents.insert(original) }
                state[id] = 1; positions[id] = stack.count
                stack.append(Frame(id: id, parents: parents.filter { records[$0] != nil }.sorted(), index: 0))
            }
            push(root)
            while !stack.isEmpty {
                let last = stack.count - 1
                if stack[last].index == stack[last].parents.count {
                    let id = stack.removeLast().id
                    state[id] = 2; positions.removeValue(forKey: id)
                    continue
                }
                let parent = stack[last].parents[stack[last].index]
                stack[last].index += 1
                if state[parent] == 1, let start = positions[parent] {
                    cycles.formUnion(stack[start...].map(\.id))
                } else if state[parent] == nil { push(parent) }
            }
        }
        return cycles
    }
    private static func precedes(_ a: OperationRecord, _ b: OperationRecord) -> Bool {
        if a.lamport != b.lamport { return a.lamport < b.lamport }
        if a.deviceID != b.deviceID { return a.deviceID.uuidString < b.deviceID.uuidString }
        return a.operationID < b.operationID
    }
    private static func preferredLess(_ a: OperationRecord, _ b: OperationRecord,
                                      taskID: UUID, group: MutationGroup) -> Bool {
        if group == .status {
            func rank(_ record: OperationRecord) -> Int {
                guard case let .status(value)? = record.mutations.first(where: {
                    $0.taskID == taskID && $0.group == .status
                })?.value else { return 0 }
                switch value.status { case .open: return 0; case .completed: return 1; case .deleted: return 2 }
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
        }
        if (a.commandKind == .undo) != (b.commandKind == .undo) { return a.commandKind == .undo }
        return precedes(a, b)
    }
    private static func structurallyValid(_ record: OperationRecord) -> Bool {
        guard !record.operationID.isEmpty, record.operationID.count <= 200, !record.workspaceKey.isEmpty,
              !record.workspaceEpoch.isEmpty, record.lamport > 0,
              record.recordedAt.timeIntervalSinceReferenceDate.isFinite,
              record.mutations.allSatisfy({ $0.value.isStructurallyValid
                && Set($0.observedHeadIDs).count == $0.observedHeadIDs.count
                && $0.observedHeadIDs.allSatisfy({ !$0.isEmpty }) }),
              Set(record.mutations.map { "\($0.taskID.uuidString):\($0.group.rawValue)" }).count == record.mutations.count,
              record.affectedTaskIDs.count <= 20,
              (record.idempotencyKey == nil) == (record.logicalCommandDigest == nil),
              record.undoValues.allSatisfy({ $0.value.isStructurallyValid && $0.observedHeadIDs.isEmpty }),
              Set(record.undoValues.map { "\($0.taskID.uuidString):\($0.group.rawValue)" }).count == record.undoValues.count,
              record.undoValues.allSatisfy({ record.affectedTaskIDs.contains($0.taskID) }),
              (record.compensatesOperationID != nil) == (record.commandKind == .undo),
              (record.settings != nil) == (record.commandKind == .settings),
              (record.reviewClosure != nil) == (record.commandKind == .reviewClose) else { return false }
        if let decision = record.reviewDecision {
            guard record.commandKind == .setPlan, !decision.cycleID.isEmpty, !decision.sessionID.isEmpty,
                  !decision.cardID.isEmpty, record.mutations.count == 1,
                  record.mutations[0].taskID == decision.taskID else { return false }
        }
        switch record.commandKind {
        case .capture:
            guard record.affectedTaskIDs.count == 1, record.mutations.count == 4,
                  Set(record.mutations.map(\.group)) == Set(MutationGroup.allCases),
                  record.mutations.allSatisfy({ $0.observedHeadIDs.isEmpty }) else { return false }
            return record.mutations.allSatisfy { mutation in
                switch mutation.value {
                case .content: true
                case let .plan(value): value.target == .unassigned && value.reviewNotBefore == nil
                case let .status(value): value.status == .open
                case let .deadline(value): value == nil
                }
            }
        case .setPlan: return !record.mutations.isEmpty && record.mutations.allSatisfy { $0.group == .plan }
        case .setStatus: return record.mutations.count == 1 && record.mutations[0].group == .status
        case .setDeadline: return record.mutations.count == 1 && record.mutations[0].group == .deadline
        case .editContent: return record.mutations.count == 1 && record.mutations[0].group == .content
        case .undo: return !record.mutations.isEmpty && record.compensatesOperationID != nil
        case .reviewClose:
            guard let closure = record.reviewClosure else { return false }
            return record.mutations.isEmpty && !closure.cycleID.isEmpty && !closure.sessionID.isEmpty
        case .settings:
            guard let settings = record.settings else { return false }
            return record.mutations.isEmpty && TimeZone(identifier: settings.timeZoneID) != nil && !settings.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
