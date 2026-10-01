import Foundation
import MirrorData
import MirrorDomain

#if os(macOS)
private enum BaselineFailure: Error { case invalidFixture, invalidResult, unsafeDirectory }

private struct TimingSamples: Encodable {
    var rawMilliseconds: [Double] = []
    var sampleCount: Int { rawMilliseconds.count }
    var p50Milliseconds: Double? { percentile(0.50) }
    var p95Milliseconds: Double? { percentile(0.95) }

    private func percentile(_ fraction: Double) -> Double? {
        guard !rawMilliseconds.isEmpty else { return nil }
        let sorted = rawMilliseconds.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }

    private enum CodingKeys: String, CodingKey {
        case rawMilliseconds, sampleCount, p50Milliseconds, p95Milliseconds
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(rawMilliseconds, forKey: .rawMilliseconds)
        try values.encode(sampleCount, forKey: .sampleCount)
        try values.encodeIfPresent(p50Milliseconds, forKey: .p50Milliseconds)
        try values.encodeIfPresent(p95Milliseconds, forKey: .p95Milliseconds)
    }
}

private struct DatasetCounts: Encodable {
    let tasks: Int
    let openTasks: Int
    let records: Int
    let quarantinedRecords: Int
    let pendingOperations: Int
}

private struct ImportCounts: Encodable {
    let inserted: Int
    let duplicates: Int
    let quarantined: Int
    let projectionPending: Bool
    init(_ report: ImportReport) {
        inserted = report.inserted
        duplicates = report.duplicates
        quarantined = report.quarantined
        projectionPending = report.projectionPending
    }
}

private struct CalendarMeasurement: Encodable {
    let requiredEvents = 2_000
    let actualEventKitQueryMeasured = false
    let status = "blocked"
    let reason = "실제 EventKit 입력·권한·계정이 없고 생산 CalendarService의 이벤트 저장소 입력을 주입할 수 없다. 합성 fixture는 실제 조회 측정을 대체하지 않는다."
}

private struct RoundTripVerification: Encodable {
    var firstImport: ImportCounts?
    var secondImport: ImportCounts?
    var restoredCounts: DatasetCounts?
    var taskIDsEqual = false
    var allTaskStatesAndVersionsEqual = false
    var allOriginalRecordsEqual = false
    var planningPolicyEqual = false
    var representativeTasksChecked = 0
    var representativeGroupsChecked = 0
    var representativeGroupDigestsEqual = false
    var completed = false
}

private struct BaselineReport: Encodable {
    let formatVersion = 1
    let scope = "production_sqlite_runner_baseline"
    let configuration = "Release"
    let clock = "ContinuousClock"
    let semanticInstant = "2026-09-30T03:00:00Z"
    let timeZone = "Asia/Seoul"
    let expectedInitialTasks = 10_000
    let expectedInitialRecords = 100_000
    let recordsPerInitialTask = 10
    let plannedSnapshotSamples = 20
    let plannedCommandSamples = 20
    let plannedExportSamples = 3
    let commandKind = "editContent"
    let percentileMethod = "nearest_rank"
    let measurementOrder = ["snapshot", "single_command", "exportArchive"]
    let snapshotCacheCondition = "initial import and validation snapshot completed before samples"
    let localCommandTargetMilliseconds = 500.0
    let realDeviceAcceptanceEvaluated = false
    let widgetDisplayMeasured = false
    let q086AcceptanceResult = "not_run"
    let calendar = CalendarMeasurement()
    var status = "running"
    var stage = "environment"
    var environment: [String: String] = [:]
    var preparationMilliseconds: [String: Double] = [:]
    var roundTripMilliseconds: [String: Double] = [:]
    var initialImport: ImportCounts?
    var initialCounts: DatasetCounts?
    var finalCounts: DatasetCounts?
    var snapshot = TimingSamples()
    var singleCommand = TimingSamples()
    var exportArchive = TimingSamples()
    var commandResultCounts: [String: Int] = [:]
    var archiveBytes: [Int] = []
    var archiveExceedsFormer32MiBLimit: [Bool] = []
    var localCommandP95TargetMetOnRunner: Bool?
    var allLocalCommandSamplesMetTargetOnRunner: Bool?
    var roundTrip = RoundTripVerification()
}

private struct SeedArchive: Encodable {
    let formatVersion = 1
    let workspaceKey: String
    let workspaceEpoch: String
    let sourceAccountScope = "local-only"
    let originAccountScopes = ["local-only"]
    let planningPolicy: PlanningPolicy
    let operations: [OperationRecord]
}

private struct PreparedSeed {
    var data: Data
    let taskIDs: [UUID]
    let generationMilliseconds: Double
    let encodingMilliseconds: Double
}

/// SQL 직접 주입이나 비공개 저장 훅 없이 production API만 측정한다.
enum PerformanceBaseline {
    private static let taskCount = 10_000
    private static let recordsPerTask = 10
    private static let sampleCount = 20
    private static let exportSampleCount = 3
    private static let workspaceKey = "personal-v1"
    private static let workspaceEpoch = "performance-baseline-v1"
    private static let deviceID = "11111111-1111-4111-8111-111111111111"
    private static let instant = Date(timeIntervalSince1970: 1_790_737_200)

    static func run(directory: URL, reportURL: URL, metadataURL: URL) async throws {
        var report = BaselineReport()
        do {
            report.environment = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: metadataURL))
            try require(report.environment["configuration"] == "Release")
            report.stage = "fresh-directory"
            guard directory.isFileURL,
                  try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
                throw BaselineFailure.unsafeDirectory
            }
            try persist(report, at: reportURL)

            report.stage = "seed-generation"
            try persist(report, at: reportURL)
            let policy = try PlanningPolicy(timeZoneID: "Asia/Seoul", revision: "policy-v1")
            var prepared = try prepareSeed(policy: policy)
            report.preparationMilliseconds["operationFactoryGeneration"] = prepared.generationMilliseconds
            report.preparationMilliseconds["seedArchiveEncoding"] = prepared.encodingMilliseconds
            let sourceURL = directory.appendingPathComponent("source", isDirectory: true)
            let sourceConfiguration = configuration(directory: sourceURL, deviceID: deviceID)
            report.stage = "source-store-open"
            try persist(report, at: reportURL)
            let clock = ContinuousClock()
            var start = clock.now
            let store = try await MirrorStore(configuration: sourceConfiguration)
            report.preparationMilliseconds["sourceStoreOpen"] = milliseconds(start.duration(to: clock.now))

            report.stage = "seed-production-import"
            try persist(report, at: reportURL)
            start = clock.now
            let importResult = try await store.importArchive(prepared.data)
            report.preparationMilliseconds["productionImport"] = milliseconds(start.duration(to: clock.now))
            prepared.data = Data()
            report.initialImport = ImportCounts(importResult)
            try require(importResult.inserted == taskCount * recordsPerTask && importResult.duplicates == 0
                && importResult.quarantined == 0 && !importResult.projectionPending)
            report.stage = "initial-validation"
            try persist(report, at: reportURL)
            start = clock.now
            let initial = try await store.snapshot()
            try validate(initial, expectedRecords: taskCount * recordsPerTask, taskIDs: prepared.taskIDs)
            report.initialCounts = counts(initial)
            report.preparationMilliseconds["initialValidation"] = milliseconds(start.duration(to: clock.now))
            try persist(report, at: reportURL)
            print("baseline prepared tasks=\(initial.tasks.count) records=\(initial.records.count)")

            report.stage = "snapshot-samples"
            try persist(report, at: reportURL)
            for _ in 0..<sampleCount {
                start = clock.now
                let observed = try await store.snapshot()
                report.snapshot.rawMilliseconds.append(milliseconds(start.duration(to: clock.now)))
                try require(observed.tasks.count == taskCount && observed.records.count == taskCount * recordsPerTask)
                try persist(report, at: reportURL)
            }

            report.stage = "single-command-samples"
            try persist(report, at: reportURL)
            let tasksByID = Dictionary(uniqueKeysWithValues: initial.tasks.map { ($0.taskID, $0) })
            let context = try PlanningContext.capture(at: instant, timeZoneID: policy.timeZoneID, policyRevision: policy.revision)
            let measuredTaskIDs = (0..<sampleCount).map { prepared.taskIDs[$0 * (taskCount / sampleCount)] }
            for (index, taskID) in measuredTaskIDs.enumerated() {
                guard let task = tasksByID[taskID], let version = task.versions[.content]?.headsDigest else {
                    throw BaselineFailure.invalidFixture
                }
                // 서로 다른 20작업을 편집해 같은 작업의 오래된 expected version을 측정하지 않는다.
                let content = try TaskContent(title: "합성 성능 표본 \(index)")
                let envelope = CommandEnvelope(requestID: "performance-request-\(index)",
                    idempotencyKey: "performance-command-\(index)", source: .app, context: context,
                    workspaceEpoch: workspaceEpoch, payload: .editContent(taskID: taskID, content: content, expectedContent: version))
                start = clock.now
                let result = await store.execute(envelope, at: instant)
                report.singleCommand.rawMilliseconds.append(milliseconds(start.duration(to: clock.now)))
                report.commandResultCounts[result.state.rawValue, default: 0] += 1
                try require(result.state == .locallyCommitted && result.operationID != nil)
                try persist(report, at: reportURL)
            }
            report.localCommandP95TargetMetOnRunner = (report.singleCommand.p95Milliseconds ?? .infinity)
                <= report.localCommandTargetMilliseconds
            report.allLocalCommandSamplesMetTargetOnRunner = report.singleCommand.rawMilliseconds.allSatisfy {
                $0 <= report.localCommandTargetMilliseconds
            }
            report.stage = "final-source-validation"
            try persist(report, at: reportURL)
            let final = try await store.snapshot()
            try validate(final, expectedRecords: taskCount * recordsPerTask + sampleCount, taskIDs: prepared.taskIDs)
            report.finalCounts = counts(final)

            report.stage = "export-samples"
            try persist(report, at: reportURL)
            var fullArchive = Data()
            for _ in 0..<exportSampleCount {
                start = clock.now
                fullArchive = try await store.exportArchive(exportedAt: instant)
                report.exportArchive.rawMilliseconds.append(milliseconds(start.duration(to: clock.now)))
                report.archiveBytes.append(fullArchive.count)
                report.archiveExceedsFormer32MiBLimit.append(fullArchive.count > 32 * 1_024 * 1_024)
                try require(!fullArchive.isEmpty)
                try persist(report, at: reportURL)
            }
            // 마지막 측정의 전체 production export를 사용한다. 요약 fixture로 바꾸지 않는다.
            report.stage = "roundtrip-store-open"
            try persist(report, at: reportURL)
            let restoredURL = directory.appendingPathComponent("restored", isDirectory: true)
            try require(!FileManager.default.fileExists(atPath: restoredURL.path))
            start = clock.now
            let restored = try await MirrorStore(configuration: configuration(directory: restoredURL,
                deviceID: "22222222-2222-4222-8222-222222222222"))
            report.roundTripMilliseconds["storeOpen"] = milliseconds(start.duration(to: clock.now))

            report.stage = "roundtrip-first-import"
            try persist(report, at: reportURL)
            start = clock.now
            let first = try await restored.importArchive(fullArchive)
            report.roundTripMilliseconds["firstImport"] = milliseconds(start.duration(to: clock.now))
            report.roundTrip.firstImport = ImportCounts(first)
            try require(first.inserted == final.records.count && first.duplicates == 0
                && first.quarantined == 0 && !first.projectionPending)
            try persist(report, at: reportURL)

            report.stage = "roundtrip-second-import"
            try persist(report, at: reportURL)
            start = clock.now
            let second = try await restored.importArchive(fullArchive)
            report.roundTripMilliseconds["secondImport"] = milliseconds(start.duration(to: clock.now))
            report.roundTrip.secondImport = ImportCounts(second)
            try require(second.inserted == 0 && second.duplicates == final.records.count
                && second.quarantined == 0 && !second.projectionPending)

            report.stage = "roundtrip-verification"
            try persist(report, at: reportURL)
            start = clock.now
            let restoredSnapshot = try await restored.snapshot()
            try validate(restoredSnapshot, expectedRecords: final.records.count, taskIDs: prepared.taskIDs)
            report.roundTrip.restoredCounts = counts(restoredSnapshot)
            report.roundTrip.taskIDsEqual = Set(restoredSnapshot.tasks.map(\.taskID)) == Set(final.tasks.map(\.taskID))
            report.roundTrip.allTaskStatesAndVersionsEqual = restoredSnapshot.tasks == final.tasks
            report.roundTrip.allOriginalRecordsEqual = restoredSnapshot.records == final.records
            report.roundTrip.planningPolicyEqual = restoredSnapshot.policy == final.policy
            let sourceTasks = Dictionary(uniqueKeysWithValues: final.tasks.map { ($0.taskID, $0) })
            let restoredTasks = Dictionary(uniqueKeysWithValues: restoredSnapshot.tasks.map { ($0.taskID, $0) })
            let representativeIDs = measuredTaskIDs + [prepared.taskIDs[taskCount - 1]]
            report.roundTrip.representativeTasksChecked = representativeIDs.count
            report.roundTrip.representativeGroupsChecked = representativeIDs.count * MutationGroup.allCases.count
            report.roundTrip.representativeGroupDigestsEqual = representativeIDs.allSatisfy { taskID in
                MutationGroup.allCases.allSatisfy { group in
                    guard let source = sourceTasks[taskID]?.versions[group]?.headsDigest,
                          let restored = restoredTasks[taskID]?.versions[group]?.headsDigest else { return false }
                    return source == restored
                }
            }
            report.roundTripMilliseconds["verification"] = milliseconds(start.duration(to: clock.now))
            try require(report.roundTrip.taskIDsEqual && report.roundTrip.allTaskStatesAndVersionsEqual
                && report.roundTrip.allOriginalRecordsEqual && report.roundTrip.planningPolicyEqual
                && report.roundTrip.representativeGroupDigestsEqual)
            report.roundTrip.completed = true
            report.status = "completed"
            report.stage = "completed"
            try persist(report, at: reportURL)
            print("baseline completed tasks=\(final.tasks.count) records=\(final.records.count) snapshotSamples=\(report.snapshot.sampleCount) commandSamples=\(report.singleCommand.sampleCount) exportSamples=\(report.exportArchive.sampleCount) restoredDuplicates=\(second.duplicates)")
        } catch {
            report.status = "failed"
            try? persist(report, at: reportURL)
            // 오류 원문·입력·ID는 공개 로그나 artifact로 내보내지 않고 고정 stage만 저장한다.
            print("baseline failed stage=\(report.stage)")
            throw error
        }
    }

    private static func prepareSeed(policy: PlanningPolicy) throws -> PreparedSeed {
        guard let writer = UUID(uuidString: deviceID) else { throw BaselineFailure.invalidFixture }
        let clock = ContinuousClock()
        let start = clock.now
        var taskIDs: [UUID] = []
        var records: [OperationRecord] = []
        taskIDs.reserveCapacity(taskCount)
        records.reserveCapacity(taskCount * recordsPerTask)
        for index in 0..<taskCount {
            guard let taskID = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", UInt64(index + 1))) else {
                throw BaselineFailure.invalidFixture
            }
            taskIDs.append(taskID)
            var previousContentOperation = ""
            for revision in 0..<recordsPerTask {
                let operationID = "performance-seed-\(index)-\(revision)"
                let content = try TaskContent(title: "합성 작업 \(index) 변경 \(revision)")
                let mutations: [TaskMutation]
                if revision == 0 {
                    mutations = [
                        TaskMutation(taskID: taskID, value: .content(content)),
                        TaskMutation(taskID: taskID, value: .plan(PlanValue(target: .unassigned))),
                        TaskMutation(taskID: taskID, value: .status(StatusValue(status: .open))),
                        TaskMutation(taskID: taskID, value: .deadline(nil))
                    ]
                } else {
                    mutations = [TaskMutation(taskID: taskID, value: .content(content),
                        observedHeadIDs: [previousContentOperation])]
                }
                let record = try OperationRecord.create(operationID: operationID, workspaceKey: workspaceKey,
                    workspaceEpoch: workspaceEpoch, deviceID: writer,
                    lamport: Int64(index * recordsPerTask + revision + 1), recordedAt: instant,
                    commandKind: revision == 0 ? .capture : .editContent, mutations: mutations)
                records.append(record)
                previousContentOperation = operationID
            }
        }
        let generation = milliseconds(start.duration(to: clock.now))
        let encodingStart = clock.now
        let data = try CanonicalDigest.data(SeedArchive(workspaceKey: workspaceKey, workspaceEpoch: workspaceEpoch,
            planningPolicy: policy, operations: records))
        return PreparedSeed(data: data, taskIDs: taskIDs, generationMilliseconds: generation,
            encodingMilliseconds: milliseconds(encodingStart.duration(to: clock.now)))
    }

    private static func configuration(directory: URL, deviceID: String) -> StoreConfiguration {
        StoreConfiguration(directory: directory, workspaceKey: workspaceKey, workspaceEpoch: workspaceEpoch,
            deviceID: deviceID, initialTimeZoneID: "Asia/Seoul", initialPolicyRevision: "policy-v1")
    }

    private static func validate(_ snapshot: StoreSnapshot, expectedRecords: Int, taskIDs: [UUID]) throws {
        try require(snapshot.tasks.count == taskCount && snapshot.records.count == expectedRecords
            && snapshot.quarantinedCount == 0 && snapshot.pendingOperationIDs.isEmpty
            && snapshot.workspaceKey == workspaceKey && snapshot.workspaceEpoch == workspaceEpoch
            && snapshot.tasks.allSatisfy({ $0.status == .open && $0.isProjectionComplete && $0.conflictGroups.isEmpty })
            && Set(snapshot.tasks.map(\.taskID)) == Set(taskIDs))
    }

    private static func counts(_ snapshot: StoreSnapshot) -> DatasetCounts {
        DatasetCounts(tasks: snapshot.tasks.count, openTasks: snapshot.tasks.filter { $0.status == .open }.count,
            records: snapshot.records.count, quarantinedRecords: snapshot.quarantinedCount,
            pendingOperations: snapshot.pendingOperationIDs.count)
    }

    private static func require(_ condition: Bool) throws {
        guard condition else { throw BaselineFailure.invalidResult }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let values = duration.components
        return Double(values.seconds) * 1_000 + Double(values.attoseconds) / 1_000_000_000_000_000
    }

    private static func persist(_ report: BaselineReport, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
#endif
