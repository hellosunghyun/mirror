import Foundation
import MirrorData
import MirrorDomain
import MirrorSystem
import Observation
import SwiftUI

enum MirrorDestination: String, CaseIterable, Identifiable {
    case today, calendar, library
    var id: String { rawValue }
    var title: String { switch self { case .today: "오늘"; case .calendar: "일정"; case .library: "보관함" } }
    var symbol: String { switch self { case .today: "sun.max"; case .calendar: "calendar"; case .library: "tray" } }
}

struct ReviewCard: Codable, Identifiable {
    let id: String
    let taskID: UUID
    let expected: ExpectedVersions
    let decisionToken: String
}

struct AppReviewSession: Codable {
    let id: String
    let cycleID: String
    let context: PlanningContext
    let isWeekly: Bool
    var todayOverride = false
    var cards: [ReviewCard]
    var decidedToday: Int = 0
    var decidedElsewhere: Int = 0
}

struct SafeUndo: Identifiable {
    let id: String
    let expected: [TaskVersionExpectation]
    let taskID: UUID?
}

struct PlanPickerRequest: Identifiable {
    let id = UUID()
    let taskIDs: [UUID]
    let expected: [PlanCommandItem]
    let displayedContext: PlanningContext
    let token: String
    let review: ReviewDecisionContext?
    let week: WeekRange?
    var widgetState: WidgetReviewState? = nil
}

struct MirrorPreferences: Codable {
    var onboardingComplete = false
    var timeZoneID = TimeZone.current.identifier
    var policyRevision = "local-v1"
    var weeklyWeekday = 2
    var reviewHour = 9
    var reviewMinute = 0
    var reviewNotifications = false
    var deadlineNotifications = false
    var calendarEnabled = false
    var selectedCalendars: [String] = []
    var hideExternalTitles = true
    var spotlightEnabled = false
    var deadlineAlarmDates: [UUID: Date] = [:]
}

/// UI는 저장된 projection만 표시한다. 성공, 저장 실패, 원본 성공 후 화면 재구축을 구분한다.
@Observable
@MainActor
final class AppModel {
    var destination: MirrorDestination = .today
    var tasks: [TaskProjection] = []
    var selectedTaskID: UUID?
    var search = ""
    var searchRequested = false
    var isTextEditing = false
    var isDetailEditing = false
    var selectedTaskIDs: Set<UUID> = []
    var showCapture = false
    var captureIsSingle = false
    var showSettings = false
    var showReview = false
    var picker: PlanPickerRequest?
    var completedWidgetPickerID: UUID?
    @ObservationIgnored private var widgetNextDestination: (resume: Bool, observationID: UUID)?
    var isLoading = true
    var isSaving = false
    var feedback: String?
    var problem: String? = nil {
        didSet { problemRevision += 1 }
    }
    var systemProblem: String?
    var cleanupProblem: String?
    var projectionPending = false
    var projectionRecovery: ProjectionRecoveryNotice?
    var lastCaptureCommittedToken: String?
    var confirmation: CommandEnvelope?
    var lastUndo: SafeUndo?
    var review: AppReviewSession?
    var reviewSummary: String?
    var preferences: MirrorPreferences
    var syncState: StoreSyncState = .localOnly
    var quarantinedCount = 0
    var context: PlanningContext?
    var archiveData: Data?
    var exportFileName = "Mirror-backup"
    var importData: Data?
    var importPreview: String?
    var archivePreview: ImportPreview?
    var showDeleteConfirmation = false
    var records: [OperationRecord] = []
    var calendars: [CalendarDescriptor] = []
    var calendarEvents: [CalendarEventSummary] = []
    var calendarAccess: CalendarAccess = .notDetermined
    var calendarProblem: String?
    var notificationsAuthorized = false
    var notificationOmittedCount = 0
    var cloudSyncStatus: CloudSyncStatus = .localOnly
    var cloudPreview: CloudActivationPreview?
    var cloudDeletionMessage: String?

    @ObservationIgnored private var store: MirrorStore?
    @ObservationIgnored private var configuration: StoreConfiguration?
    @ObservationIgnored private var services: SystemServices?
    @ObservationIgnored private var cloud: CloudSyncService?
    @ObservationIgnored private var cloudStatusObservation: Task<Void, Never>?
    @ObservationIgnored private var cloudObservationID = UUID()
    @ObservationIgnored private var canonicalObservation: Task<Void, Never>?
    @ObservationIgnored private var canonicalRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var systemReconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var systemReconciliationPending = false
    @ObservationIgnored private var storeObservationID = UUID()
    private struct CalendarDrag {
        let request: PlanPickerRequest
        let workspaceKey: String
        let workspaceEpoch: String
        let observationID: UUID
        let expiresAt: ContinuousClock.Instant
    }
    @ObservationIgnored private var calendarDrags: [UUID: CalendarDrag] = [:]
    @ObservationIgnored private var navigationHasBeenBound = false
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var navigationBindingTask: Task<Void, Never>?
    var recoveryConfigurationBlocked = false
    @ObservationIgnored private var canonicalChangePending = false
    @ObservationIgnored private var canonicalStreamEnded = false
    @ObservationIgnored private var lamportByOperationID: [String: Int64] = [:]
    @ObservationIgnored private var problemRevision: UInt64 = 0
    @ObservationIgnored private var captureInputProblemRevision: UInt64? = nil
    @ObservationIgnored private var retryEnvelope: CommandEnvelope?
    @ObservationIgnored private var pendingImportFeedback: String?
    @ObservationIgnored private var calendarDisplayRange: (start: Date, end: Date)?
    @ObservationIgnored private var calendarLoadID = UUID()
    @ObservationIgnored private var widgetDecision: (request: PlanPickerRequest, target: PlanTarget)?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let preferenceKey = "Mirror.preferences.v1"
    @ObservationIgnored private let sessionKey = "Mirror.review.session.v1"
    @ObservationIgnored private var reviewExposures: Set<UUID> = []
    @ObservationIgnored private var activeScenes: Set<UUID> = []
    @ObservationIgnored private var reviewExposureStart: ContinuousClock.Instant?
    @ObservationIgnored private var activeReviewMilliseconds = 0

    init() {
        if let bytes = defaults.data(forKey: preferenceKey),
           let saved = try? JSONDecoder().decode(MirrorPreferences.self, from: bytes) { preferences = saved }
        else { preferences = MirrorPreferences() }
    }
    deinit {
        cloudStatusObservation?.cancel()
        canonicalObservation?.cancel()
        canonicalRefreshTask?.cancel()
        systemReconciliationTask?.cancel()
    }

    var selectedTask: TaskProjection? { tasks.first { $0.taskID == selectedTaskID } }
    var todayTasks: [TaskProjection] {
        guard let context else { return [] }
        return tasks.filter { PlanningRules.isToday($0.planningState, on: context.planningDay) }.sorted(by: todayOrder)
    }
    var completedToday: [TaskProjection] {
        guard let context else { return [] }
        return tasks.filter { $0.status == .completed && $0.plan.target == .day(context.planningDay) }
    }
    var deadlines: [TaskProjection] {
        guard let context else { return [] }
        return tasks.filter { task in
            task.status == .open && task.deadline.flatMap { try? $0.planningDate(in: context) }.map { $0 <= ((try? context.planningDay.addingDays(1)) ?? context.planningDay) } == true
        }
    }
    var pendingTasks: [TaskProjection] { tasks.filter { $0.status == .open && $0.plan.target == .unassigned } }
    var currentCard: ReviewCard? { review?.cards.first }
    var currentReviewTask: TaskProjection? { currentCard.flatMap { card in tasks.first { $0.taskID == card.taskID } } }
    var storageLabel: String {
        if projectionPending { return "저장했어요. 화면을 갱신하고 있어요." }
        switch syncState {
        case .localOnly: return "이 기기에 저장됨"
        case .awaitingCloudSynchronization: return "이 기기에 저장됨 · iCloud 동기화 대기"
        case .accountTransitionRequired: return "이 기기에 저장됨 · iCloud 계정 확인 필요"
        }
    }

    func start() async {
        if let startupTask { await startupTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        startupTask = task
        await task.value
        startupTask = nil
    }
    private func performStart() async {
        guard store == nil else { await refresh(); return }
        isLoading = true
        do {
            let configuredGroup = (Bundle.main.object(forInfoDictionaryKey: "MirrorAppGroupIdentifier") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let identityDefaults = configuredGroup.flatMap { $0.isEmpty ? nil : UserDefaults(suiteName: $0) } ?? defaults
            let deviceKey = "mirror.device-id.v1"
            let deviceID = identityDefaults.string(forKey: deviceKey) ?? UUID().uuidString
            identityDefaults.set(deviceID, forKey: deviceKey)
            let base: StoreConfiguration
            if let configuredGroup, !configuredGroup.isEmpty { base = try StoreConfiguration.appGroup(identifier: configuredGroup, deviceID: deviceID) }
            else { base = try StoreConfiguration.localApplicationSupport(deviceID: deviceID) }
            var config = StoreConfiguration(directory: base.directory, workspaceKey: base.workspaceKey,
                                            workspaceEpoch: base.workspaceEpoch, deviceID: deviceID,
                                            initialTimeZoneID: preferences.timeZoneID,
                                            initialPolicyRevision: preferences.policyRevision)
            #if DEBUG
            if ProcessInfo.processInfo.environment["MIRROR_UI_TESTING"] == "1" {
                let directory = ProcessInfo.processInfo.environment["MIRROR_TEST_STORE_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("MirrorUITest-\(UUID().uuidString)", isDirectory: true)
                config = StoreConfiguration(directory: directory, deviceID: deviceID,
                                            initialTimeZoneID: "Asia/Seoul", initialPolicyRevision: "ui-test-v1")
                preferences.onboardingComplete = true
                review = nil
            }
            #endif
            let containerID = (Bundle.main.object(forInfoDictionaryKey: "MirrorCloudContainerIdentifier") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let setup = CloudSyncSetup(containerIdentifier: containerID.flatMap { $0.isEmpty ? nil : $0 },
                                       appGroupIdentifier: configuredGroup.flatMap { $0.isEmpty ? nil : $0 })
            cloud = CloudSyncService(localConfiguration: config, setup: setup)
            if let cloud { observeCloudStatus(cloud) }
            configuration = config
            if !isUITesting, let configuredGroup, !configuredGroup.isEmpty,
               let active = try await CloudSyncService.resolveActiveConfiguration(appGroupIdentifier: configuredGroup,
                                                                                    deviceID: deviceID,
                                                                                    expectedContainerIdentifier: setup.containerIdentifier) { config = active }
            configuration = config
            let system = try await SystemCompositionRoot.open(configuration: config)
            services = system
            store = await system.store
            do { projectionRecovery = try await system.projectionRecoveryNotice(); recoveryConfigurationBlocked = false }
            catch { projectionRecovery = nil; recoveryConfigurationBlocked = true }
            if projectionRecovery != nil || recoveryConfigurationBlocked {
                resetExternalPreferencesAfterRecovery()
                savePreferences()
                systemProblem = "화면 캐시를 원본에서 복구했어요. 외부 노출·알림은 꺼져 있어요. 설정에서 복구를 확인해 주세요."
            }
            if config.cloudSync != nil, let cloud, let store {
                try await cloud.resumeActiveStore(store)
                await system.attachCloudMonitor(cloud)
            }
            if projectionRecovery == nil, !recoveryConfigurationBlocked, !isUITesting,
               let bytes = try await store?.localValue(forKey: "system-preferences-v1"),
               let systemPreferences = try? JSONDecoder().decode(SystemPreferences.self, from: bytes) {
                preferences.hideExternalTitles = systemPreferences.hideExternalTitles
                preferences.spotlightEnabled = systemPreferences.spotlightEnabled
                preferences.selectedCalendars = systemPreferences.selectedCalendarIDs
                preferences.calendarEnabled = !systemPreferences.selectedCalendarIDs.isEmpty
                preferences.reviewNotifications = systemPreferences.reviewNotification.enabled
                preferences.reviewHour = systemPreferences.reviewNotification.hour
                preferences.reviewMinute = systemPreferences.reviewNotification.minute
                preferences.weeklyWeekday = systemPreferences.reviewNotification.weeklyWeekday
                preferences.deadlineNotifications = systemPreferences.notificationsOnThisDevice && !systemPreferences.deadlineNotifications.isEmpty
                preferences.deadlineAlarmDates = Dictionary(uniqueKeysWithValues: systemPreferences.deadlineNotifications.map { ($0.taskID, $0.fireAt) })
            }
            if let store { await observeCanonicalChanges(store) }
            await refresh()
            if !isUITesting, let bytes = defaults.data(forKey: sessionKey),
               let saved = try? JSONDecoder().decode(AppReviewSession.self, from: bytes),
               saved.context.planningDay == context?.planningDay,
               saved.context.policyRevision == context?.policyRevision { review = saved }
        } catch {
            problem = "저장소를 열지 못했어요. 원본은 지우지 않았어요. 다시 시도해 주세요."
        }
        isLoading = false
        drainCanonicalChanges()
    }

    @discardableResult
    func refresh() async -> Bool {
        guard let store else { return false }
        let identity = storeObservationID
        do {
            if configuration?.cloudSync != nil, let cloud {
                _ = await cloud.validateLocalIdentity()
                let status = await cloud.status()
                guard storeObservationID == identity else { return false }
                cloudSyncStatus = status
                if cloudSyncStatus == .accountTransitionRequired {
                    stopCanonicalObservation()
                    clearTransientData()
                    problem = "iCloud 계정이 바뀌었어요. 이전 계정의 자료를 새 계정에 자동으로 업로드하지 않아요. 동기화 설정을 확인해 주세요."
                    return false
                }
            }
            let snapshot = try await store.snapshot()
            guard storeObservationID == identity else { return false }
            tasks = snapshot.tasks.sorted { $0.createdAt < $1.createdAt }
            records = snapshot.records
            lamportByOperationID = Dictionary(snapshot.records.map { ($0.operationID, $0.lamport) },
                                             uniquingKeysWith: { first, _ in first })
            syncState = snapshot.syncState
            quarantinedCount = snapshot.quarantinedCount
            preferences.timeZoneID = snapshot.policy.timeZoneID
            preferences.policyRevision = snapshot.policy.revision
            let next = try PlanningContext.capture(at: now, timeZoneID: preferences.timeZoneID,
                                                   policyRevision: preferences.policyRevision)
            if let context, context.planningDay != next.planningDay || context.policyRevision != next.policyRevision {
                review = nil; picker = nil; confirmation = nil
                defaults.removeObject(forKey: sessionKey)
                feedback = "날짜나 계획 시간대가 바뀌었어요. 현재 기준으로 다시 보여드려요."
            }
            context = next
            selectedTaskIDs.formIntersection(Set(tasks.filter { $0.status == .open }.map(\.taskID)))
            if retryEnvelope == nil { projectionPending = false }
            if let pendingImportFeedback {
                feedback = pendingImportFeedback
                problem = nil
                self.pendingImportFeedback = nil
            }
            requestSystemReconciliation()
            return true
        } catch {
            guard storeObservationID == identity else { return false }
            problem = "저장된 화면을 불러오지 못했어요. 원본을 유지한 채 다시 시도해 주세요."
            return false
        }
    }

    private func observeCanonicalChanges(_ activeStore: MirrorStore) async {
        stopCanonicalObservation()
        let identity = storeObservationID
        if let services {
            do {
                let notice = try await services.projectionRecoveryNotice()
                guard storeObservationID == identity else { return }
                projectionRecovery = notice; recoveryConfigurationBlocked = false
                if notice != nil {
                    resetExternalPreferencesAfterRecovery(); savePreferences()
                    systemProblem = "화면 캐시를 원본에서 복구했어요. 설정에서 복구를 확인해 주세요."
                }
            } catch {
                guard storeObservationID == identity else { return }
                recoveryConfigurationBlocked = true
                resetExternalPreferencesAfterRecovery(); savePreferences()
                systemProblem = "복구 안내를 읽지 못했어요. 외부 노출·알림을 끈 채 저장소를 다시 확인해 주세요."
            }
        }
        bindSystemNavigation(identity: identity)
        canonicalObservation = Task { [weak self] in
            do {
                let changes = try await activeStore.changes()
                for await _ in changes {
                    guard !Task.isCancelled, let self, self.storeObservationID == identity else { return }
                    self.canonicalChangePending = true
                    self.drainCanonicalChanges()
                }
            } catch {
                // 종료와 구독 실패는 현재 원본의 읽기 경계를 다시 검사한다.
            }
            guard !Task.isCancelled, let self, self.storeObservationID == identity else { return }
            self.canonicalStreamEnded = true
            self.canonicalChangePending = true
            self.drainCanonicalChanges()
        }
    }
    private func stopCanonicalObservation() {
        canonicalObservation?.cancel(); canonicalObservation = nil
        canonicalRefreshTask?.cancel(); canonicalRefreshTask = nil
        systemReconciliationTask?.cancel(); systemReconciliationTask = nil
        navigationBindingTask?.cancel(); navigationBindingTask = nil
        systemReconciliationPending = false
        calendarDrags.removeAll()
        if navigationHasBeenBound { NotificationService.suspendNavigation() }
        storeObservationID = UUID()
        canonicalChangePending = false; canonicalStreamEnded = false
    }
    private func bindSystemNavigation(identity: UUID) {
        guard let services, let configuration else { return }
        navigationHasBeenBound = true
        let epoch = configuration.workspaceEpoch
        navigationBindingTask = Task { [weak self] in
            guard let self, self.storeObservationID == identity else { return }
            do {
                let notifications = await services.notifications
                guard self.storeObservationID == identity, !Task.isCancelled else { return }
                try await notifications.installNavigationHandler(workspaceEpoch: epoch,
                    isCurrent: { [weak self] in self?.storeObservationID == identity }) { [weak self] route in
                    guard let self, self.storeObservationID == identity else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.storeObservationID == identity else { return }
                        await self.handleURL(MirrorDeepLink.url(for: route), expectedObservationID: identity)
                    }
                }
            } catch {
                guard self.storeObservationID == identity else { return }
                self.systemProblem = "알림에서 화면을 여는 연결을 확인하지 못했어요. 앱 안의 목록은 사용할 수 있어요."
            }
        }
    }
    private func drainCanonicalChanges() {
        guard canonicalChangePending, !isSaving, !isLoading, canonicalRefreshTask == nil else { return }
        let identity = storeObservationID
        canonicalRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.storeObservationID == identity,
                  self.canonicalChangePending, !self.isSaving, !self.isLoading {
                self.canonicalChangePending = false
                let ended = self.canonicalStreamEnded
                let refreshed = await self.refresh()
                guard !Task.isCancelled, self.storeObservationID == identity else { return }
                if ended {
                    self.stopCanonicalObservation()
                    if !refreshed {
                        self.store = nil; self.services = nil
                        self.clearTransientData()
                        self.problem = "현재 개인 공간의 저장소 연결을 확인할 수 없어요. 이전 화면을 비웠어요. 원본을 다시 열거나 선택한 복원 파일로 복구해 주세요."
                    } else {
                        self.problem = "현재 작업은 읽었지만 원본 변경의 자동 갱신 연결을 확인하지 못했어요. 다시 확인을 선택해 저장소를 연결해 주세요."
                    }
                    return
                }
            }
            guard self.storeObservationID == identity else { return }
            self.canonicalRefreshTask = nil
            self.drainCanonicalChanges()
        }
    }
    private func finishSaving() {
        isSaving = false
        drainCanonicalChanges()
    }

    func savePreferences() {
        if projectionRecovery != nil || recoveryConfigurationBlocked { resetExternalPreferencesAfterRecovery() }
        if let bytes = try? JSONEncoder().encode(preferences) { defaults.set(bytes, forKey: preferenceKey) }
        requestSystemReconciliation()
    }
    private func resetExternalPreferencesAfterRecovery() {
        preferences.hideExternalTitles = true; preferences.spotlightEnabled = false
        preferences.reviewNotifications = false; preferences.deadlineNotifications = false
        preferences.deadlineAlarmDates = [:]; preferences.selectedCalendars = []
        preferences.calendarEnabled = false
    }
    func acknowledgeProjectionRecovery() async {
        guard let services, let notice = projectionRecovery, !isSaving else { return }
        isSaving = true
        let identity = storeObservationID
        defer { finishSaving() }
        do {
            try await services.acknowledgeProjectionRecovery(notice)
            guard storeObservationID == identity else { return }
            projectionRecovery = nil
            systemProblem = nil
            feedback = "원본에서 목록을 복구했어요. 외부 노출과 알림은 필요할 때 다시 켜 주세요."
            savePreferences()
        } catch {
            guard storeObservationID == identity else { return }
            systemProblem = "복구 상태를 확인하지 못했어요. 외부 노출과 알림은 계속 꺼져 있어요."
        }
    }
    func openCapture(single: Bool = false) {
        captureIsSingle = single
        showCapture = true
    }
    func finishCapture() {
        guard captureIsSingle else { return }
        showCapture = false
        captureIsSingle = false
        destination = .today
    }
    func finishOnboarding() { preferences.onboardingComplete = true; savePreferences(); openCapture() }

    @discardableResult
    func capture(title: String, note: String, sourceURL: String, requestToken: String = UUID().uuidString,
                 initialPlan: PlanTarget? = nil, displayedContext: PlanningContext? = nil) async -> Bool {
        let effectiveTitle = title.isEmpty ? sourceURL : title
        do {
            let content = try TaskContent(title: effectiveTitle,
                                          note: note.isEmpty ? nil : note,
                                          sourceURL: sourceURL.isEmpty ? nil : sourceURL)
            guard let context = displayedContext ?? context else { return false }
            let id = UUID()
            let payload: CommandPayload = initialPlan.map { .captureWithPlan(taskID: id, content: content, initialPlan: $0) }
                ?? .capture(taskID: id, content: content)
            guard let envelope = makeEnvelope(payload, context: context, token: requestToken) else { return false }
            let feedback: String
            switch initialPlan {
            case let .day(date): feedback = "\(AppDate.label(date))에 넣었어요."
            case .week: feedback = "선택한 주에 넣었어요."
            case .none, .unassigned, .parked: feedback = "보관함에 넣었어요."
            }
            return await execute(envelope, success: feedback)
        } catch {
            problem = contentInputErrorMessage(error, title: effectiveTitle, note: note)
            captureInputProblemRevision = problemRevision
            await recordMetric(kind: .captureRejected, outcome: .failure)
            return false
        }
    }

    func clearCaptureInputProblem() {
        let capturedRevision = captureInputProblemRevision
        captureInputProblemRevision = nil
        guard let capturedRevision, capturedRevision == problemRevision else { return }
        problem = nil
    }

    private func contentInputErrorMessage(_ error: any Error, title: String, note: String) -> String {
        guard let contract = error as? DomainContractError else { return "입력을 확인해 주세요." }
        switch contract {
        case .invalidContent:
            // TaskContent가 거부한 입력의 표시 원인만 구분한다. 입력이나 저장 검증은 바꾸지 않는다.
            let titleCount = title.trimmingCharacters(in: .whitespacesAndNewlines).count
            if titleCount == 0 { return "할 일 제목을 입력해 주세요." }
            if titleCount > 500 { return "제목은 500자 이하로 입력해 주세요." }
            if note.count > 20_000 { return "메모는 20,000자 이하로 입력해 주세요." }
            return "입력을 확인해 주세요."
        case .invalidSourceURL:
            return "링크 주소를 확인해 주세요."
        default:
            return "입력을 확인해 주세요."
        }
    }

    func edit(_ task: TaskProjection, title: String, note: String, sourceURL: String) async -> Bool {
        do {
            let value = try TaskContent(title: title, note: note.isEmpty ? nil : note,
                                        sourceURL: sourceURL.isEmpty ? nil : sourceURL)
            guard let digest = task.versions[.content]?.headsDigest else { return false }
            return await submit(.editContent(taskID: task.taskID, content: value, expectedContent: digest), success: "내용을 저장했어요.")
        } catch {
            problem = "입력을 유지했어요. " + contentInputErrorMessage(error, title: title, note: note)
            return false
        }
    }

    func setCompleted(_ task: TaskProjection, completed: Bool) async {
        guard let version = task.versions[.status]?.headsDigest else { return }
        _ = await submit(.completion(taskID: task.taskID, desiredCompleted: completed, expectedStatus: version),
                         success: completed ? "완료했어요." : "다시 열었어요. 원래 계획은 유지했어요.")
    }
    func park(_ task: TaskProjection) async {
        _ = await submit(.park(taskID: task.taskID, expected: ExpectedVersions(task)), success: "당분간 보관해요. 자동 정리에는 나오지 않아요.")
    }
    func trash(_ task: TaskProjection) async {
        guard let version = task.versions[.status]?.headsDigest else { return }
        _ = await submit(.trash(taskID: task.taskID, expectedStatus: version), success: "휴지통으로 옮겼어요. 복구할 수 있어요.")
    }
    func restore(_ task: TaskProjection) async {
        guard let version = task.versions[.status] else { return }
        _ = await submit(.restore(taskID: task.taskID, observedDeleteHeadIDs: version.headIDs,
                                  expectedStatus: version.headsDigest), success: "원래 계획으로 복구했어요.")
    }
    @discardableResult
    func setDeadline(_ task: TaskProjection, deadline: Deadline?) async -> Bool {
        guard let digest = task.versions[.deadline]?.headsDigest else { return false }
        return await submit(.setDeadline(taskID: task.taskID, deadline: deadline, expectedDeadline: digest),
                            success: deadline == nil ? "실제 마감을 지웠어요. 계획은 유지했어요." : "실제 마감을 저장했어요. 계획은 유지했어요.")
    }

    func makePicker(taskIDs: [UUID], week: WeekRange? = nil, reviewCard: ReviewCard? = nil,
                    reviewSession: AppReviewSession? = nil) {
        guard let context, (1...20).contains(taskIDs.count) else { return }
        if reviewCard != nil {
            guard let reviewSession, review?.id == reviewSession.id else { return }
        }
        let fixedTasks = taskIDs.compactMap { id in tasks.first { $0.taskID == id } }
        guard fixedTasks.count == taskIDs.count else { return }
        let items = fixedTasks.map { task in
            PlanCommandItem(taskID: task.taskID, expected: reviewCard?.expected ?? ExpectedVersions(task))
        }
        let decision = reviewCard.flatMap { card in
            reviewSession.map { ReviewDecisionContext(cycleID: $0.cycleID, sessionID: $0.id, cardID: card.id, taskID: card.taskID) }
        }
        picker = PlanPickerRequest(taskIDs: taskIDs, expected: items,
                                   displayedContext: reviewCard == nil ? context : (reviewSession?.context ?? context),
                                   token: reviewCard?.decisionToken ?? UUID().uuidString, review: decision, week: week)
    }
    /// 전송에는 작업 ID를 싣지 않는다. 표시한 원본 버전·날짜는 프로세스 안에 고정한다.
    func beginCalendarDrag(_ task: TaskProjection, context displayedContext: PlanningContext) -> UUID? {
        guard !isSaving, !projectionPending, !isDetailEditing, !showReview, !showCapture, !showSettings,
              picker == nil, confirmation == nil, widgetDecision == nil,
              let configuration, let context, task.status == .open, task.isProjectionComplete,
              task.workspaceKey == configuration.workspaceKey, task.workspaceEpoch == configuration.workspaceEpoch,
              PlanningRules.checkContext(displayed: displayedContext, current: context,
                  matchingReceiptExists: false) == .continueValidation else { return nil }
        let instant = ContinuousClock.now
        calendarDrags = calendarDrags.filter { $0.value.expiresAt > instant && $0.value.observationID == storeObservationID }
        guard calendarDrags.count < 32 else { return nil }
        let token = UUID()
        let request = PlanPickerRequest(taskIDs: [task.taskID],
            expected: [PlanCommandItem(taskID: task.taskID, expected: ExpectedVersions(task))],
            displayedContext: displayedContext, token: token.uuidString, review: nil, week: nil)
        calendarDrags[token] = CalendarDrag(request: request, workspaceKey: configuration.workspaceKey,
            workspaceEpoch: configuration.workspaceEpoch, observationID: storeObservationID,
            expiresAt: instant.advanced(by: .seconds(120)))
        return token
    }
    func takeCalendarDrag(token: UUID) -> PlanPickerRequest? {
        guard let drag = calendarDrags.removeValue(forKey: token),
              !isSaving, !projectionPending, !isDetailEditing, !showReview, !showCapture, !showSettings,
              picker == nil, confirmation == nil, widgetDecision == nil,
              let configuration, drag.observationID == storeObservationID,
              drag.workspaceKey == configuration.workspaceKey, drag.workspaceEpoch == configuration.workspaceEpoch,
              drag.expiresAt > ContinuousClock.now else { return nil }
        return drag.request
    }

    func canPostponeToTomorrow(_ task: TaskProjection, context displayedContext: PlanningContext) -> Bool {
        guard task.status == .open,
              let tomorrow = try? displayedContext.planningDay.addingDays(1) else { return false }
        return task.plan.target != .day(tomorrow)
    }

    func postponeToTomorrow(_ task: TaskProjection, context displayedContext: PlanningContext) async {
        guard task.status == .open, !isSaving, !projectionPending,
              !showCapture, !showSettings, !showReview, !isDetailEditing,
              picker == nil, confirmation == nil, widgetDecision == nil else { return }
        guard let tomorrow = try? displayedContext.planningDay.addingDays(1) else {
            problem = "내일 날짜를 확인할 수 없어요."
            return
        }
        guard task.plan.target != .day(tomorrow) else { return }
        let request = PlanPickerRequest(taskIDs: [task.taskID],
                                        expected: [PlanCommandItem(taskID: task.taskID, expected: ExpectedVersions(task))],
                                        displayedContext: displayedContext, token: UUID().uuidString,
                                        review: nil, week: nil)
        await choosePlan(request, target: .day(tomorrow))
    }

    func choosePlan(_ request: PlanPickerRequest, target: PlanTarget) async {
        if request.widgetState != nil {
            _ = await commitWidget(request, target: target)
            return
        }
        let payload: CommandPayload
        if request.expected.count == 1, let item = request.expected.first {
            payload = .setPlan(item: item, target: target, review: request.review)
        } else { payload = .batchSetPlan(items: request.expected, target: target) }
        let envelope = makeEnvelope(payload, context: request.displayedContext, token: request.token)
        guard let envelope else { return }
        if await execute(envelope, success: "\(planLabel(target))로 보냈어요.") { picker = nil }
    }

    func decide(_ target: PlanTarget, card: ReviewCard, session: AppReviewSession) async {
        guard review?.id == session.id else { return }
        let item = PlanCommandItem(taskID: card.taskID, expected: card.expected)
        let decision = ReviewDecisionContext(cycleID: session.cycleID, sessionID: session.id, cardID: card.id, taskID: card.taskID)
        guard let envelope = makeEnvelope(.setPlan(item: item, target: target, review: decision),
                                          context: session.context, token: card.decisionToken) else { return }
        _ = await execute(envelope, success: "\(planLabel(target))로 보냈어요.")
    }

    func beginReview(mode: ReviewMode = .automatic, includeNewInputs: Bool = false, weekly: Bool? = nil) {
        guard let context, let configuration else { return }
        selectedTaskID = nil
        if !includeNewInputs, mode == .manualResume, let review, !review.cards.isEmpty,
           weekly == nil || weekly == review.isWeekly {
            refreshUpcomingCards(renewCurrentCard: false)
            persistSession()
            showReview = true
            return
        }
        let cycleID = ReviewCycle.id(workspaceEpoch: configuration.workspaceEpoch, context: context)
        activeReviewMilliseconds = 0
        reviewExposureStart = nil
        let report = TaskReducer.reduce(records, workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
        let closed = report.isCycleClosed(cycleID)
        let cards = tasks.filter {
            PlanningRules.isReviewCandidate($0.planningState, on: context.planningDay,
                                            acknowledgedCurrentPlan: report.acknowledges(task: $0, cycleID: cycleID), cycleClosed: closed, mode: mode)
        }.sorted { reviewOrder($0, context: context) < reviewOrder($1, context: context) }
            .map { ReviewCard(id: UUID().uuidString, taskID: $0.taskID, expected: ExpectedVersions($0), decisionToken: UUID().uuidString) }
        let weekday = AppDate.weekday(context.planningDay)
        review = AppReviewSession(id: UUID().uuidString, cycleID: cycleID, context: context,
                                  isWeekly: weekly ?? (weekday == preferences.weeklyWeekday), todayOverride: mode == .manualTodayOverride, cards: cards)
        persistSession()
        reviewSummary = nil
        showReview = true
    }

    func finishReview() async {
        guard let session = review else { showReview = false; return }
        let weeklyStart = session.isWeekly ? (try? session.context.planningDay.mondayWeek().startDate) : nil
        let remaining = session.cards.count
        let summary = "이번 정리에서 오늘에 남긴 일 \(session.decidedToday)개 · 다른 때로 보낸 일 \(session.decidedElsewhere)개 · 아직 정하지 않은 일 \(remaining)개"
        let result = await submit(.reviewClose(ReviewClosure(cycleID: session.cycleID, sessionID: session.id,
                                                            weeklyCoverageStartDate: weeklyStart)), success: "오늘은 여기까지 정리했어요.")
        if result { reviewSummary = summary; showReview = false; destination = .today }
    }
    func refreshReviewCard() async {
        guard await refresh(), review != nil else { return }
        refreshUpcomingCards()
        problem = nil
        persistSession()
    }

    func undo() async {
        guard let candidate = lastUndo else { return }
        await undo(candidate)
    }
    func undo(_ original: OperationRecord) async {
        guard !original.undoValues.isEmpty else { return }
        let candidate = SafeUndo(id: original.operationID, expected: original.undoExpectations(),
                                 taskID: original.affectedTaskIDs.count == 1 ? original.affectedTaskIDs.first : nil)
        await undo(candidate)
    }
    private func undo(_ candidate: SafeUndo) async {
        if await submit(.undo(operationID: candidate.id, expected: candidate.expected), success: "직전 변경을 되돌렸어요.") {
            lastUndo = nil
            if let taskID = candidate.taskID, let task = tasks.first(where: { $0.taskID == taskID }), review != nil {
                review?.cards.insert(ReviewCard(id: UUID().uuidString, taskID: taskID,
                                                expected: ExpectedVersions(task), decisionToken: UUID().uuidString), at: 0)
                persistSession()
            }
        }
    }

    func confirmAfterDeadline() async {
        if let decision = widgetDecision, confirmation != nil,
           let card = decision.request.widgetState?.card, let digest = card.expected.deadline {
            confirmation = nil
            let acknowledgment = DeadlineAcknowledgment(taskID: card.taskID.uuidString, deadlineRevision: digest, target: decision.target)
            _ = await commitWidget(decision.request, target: decision.target, acknowledgment: acknowledgment)
            return
        }
        guard let envelope = confirmation else { return }
        let payload: CommandPayload
        switch envelope.payload {
        case let .setPlan(item, target, review):
            guard let task = tasks.first(where: { $0.taskID == item.taskID }), let deadline = task.versions[.deadline] else { return }
            payload = .setPlan(item: PlanCommandItem(taskID: item.taskID, expected: item.expected,
                               acknowledgment: DeadlineAcknowledgment(taskID: item.taskID.uuidString,
                                                                       deadlineRevision: deadline.headsDigest, target: target)), target: target, review: review)
        case let .batchSetPlan(items, target):
            let acknowledgedItems = items.map { item -> PlanCommandItem in
                guard let task = tasks.first(where: { $0.taskID == item.taskID }), let stamp = task.versions[.deadline] else { return item }
                return PlanCommandItem(taskID: item.taskID, expected: item.expected,
                                       acknowledgment: DeadlineAcknowledgment(taskID: item.taskID.uuidString,
                                                                               deadlineRevision: stamp.headsDigest, target: target))
            }
            payload = .batchSetPlan(items: acknowledgedItems, target: target)
        default: return
        }
        confirmation = nil
        let confirmed = CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: envelope.idempotencyKey,
                                        source: .app, context: envelope.context, workspaceEpoch: envelope.workspaceEpoch, payload: payload)
        if await execute(confirmed, success: "마감은 유지하고 선택한 날짜로 보냈어요.") { picker = nil }
    }

    func changeTimeZone(_ zone: String) async {
        guard zone != preferences.timeZoneID else { return }
        do {
            let policy = try PlanningPolicy(timeZoneID: zone, revision: UUID().uuidString)
            if await submit(.settings(policy: policy, expectedRevision: preferences.policyRevision), success: "계획 시간대를 바꿨어요. 기존 날짜 문자열은 유지해요.") {
                preferences.timeZoneID = policy.timeZoneID; preferences.policyRevision = policy.revision
                review = nil; picker = nil; savePreferences(); await refresh()
            }
        } catch { problem = "올바른 시간대를 선택해 주세요." }
    }

    func exportArchive() async {
        guard let store else { return }
        do { archiveData = try await store.exportArchive(exportedAt: now); exportFileName = "Mirror-\(context?.planningDay.iso8601 ?? "backup")" }
        catch { problem = "내보내기 파일을 만들지 못했어요. 저장된 원본은 유지했어요." }
    }
    func previewImport(_ bytes: Data) async {
        do {
            let report: ImportPreview
            if let store { report = try await store.previewArchive(bytes) }
            else if let configuration, configuration.cloudSync == nil { report = try MirrorStore.previewArchiveForRecovery(bytes, configuration: configuration) }
            else { problem = "개인 공간의 설정을 먼저 복구해야 해요. 현재 원본은 지우지 않았어요."; return }
            importData = bytes
            archivePreview = report
            importPreview = "작업 \(report.taskCount)개 · 새 작업 \(report.newTaskCount)개 · 원본 기록 \(report.operationCount)개 · 중복 \(report.duplicateCount)개 · 격리·미해석 원본 \(report.quarantinedRecordCount)개. \(report.warnings.joined(separator: " ")) 변경 이력의 개인 정보도 복원될 수 있어요."
        } catch { problem = "파일의 버전·개인 공간·원본 형식을 확인해 주세요. 현재 데이터는 바뀌지 않았어요." }
    }
    func importArchive(confirmAccount: Bool = false, confirmWorkspace: Bool = false) async {
        guard let bytes = importData, !isSaving else { return }
        if archivePreview?.requiresAccountConfirmation == true, !confirmAccount {
            problem = "다른 계정의 자료를 이 공간에 가져올지 먼저 확인해 주세요."; return
        }
        if archivePreview?.requiresWorkspaceConfirmation == true, !confirmWorkspace {
            problem = "현재 기기의 작업을 교체하고 원래 자료의 공간을 복원할지 확인해 주세요."; return
        }
        isSaving = true
        defer { finishSaving() }
        var sourceRestored = false
        do {
            let oldServices = services
            let report: ImportReport
            if store == nil, let configuration, configuration.cloudSync == nil {
                let restoration = try await MirrorStore.recoverInterruptedLocalRestoration(from: bytes, directory: configuration.directory,
                                                                                            deviceID: configuration.deviceID, confirmed: confirmWorkspace)
                sourceRestored = true
                try await openRestoredWorkspace(restoration.newConfiguration, replacing: oldServices)
                report = restoration.importReport
            } else if let store, archivePreview?.requiresWorkspaceConfirmation == true {
                let restoration = try await store.restoreArchiveAsLocalWorkspace(bytes, confirmed: confirmWorkspace)
                sourceRestored = true
                try await openRestoredWorkspace(restoration.newConfiguration, replacing: oldServices)
                report = restoration.importReport
            } else if let store { report = try await store.importArchive(bytes, consent: ArchiveImportConsent(accountChangeConfirmed: confirmAccount)) }
            else { problem = "저장소 설정을 먼저 확인해 주세요. 원본은 지우지 않았어요."; return }
            if let configuration, configuration.cloudSync == nil { resetCloudService(localConfiguration: configuration) }
            pendingImportFeedback = "복원했어요. 새 기록 \(report.inserted)개, 중복 \(report.duplicates)개, 격리 \(report.quarantined)개."
            problem = nil
            feedback = report.projectionPending ? "원본 자료는 복원했어요. 화면을 갱신하고 있어요. 다시 확인을 선택해 주세요." : nil
            projectionPending = report.projectionPending
            importData = nil; importPreview = nil; archivePreview = nil
            if !(await refresh()) {
                projectionPending = true
                feedback = "원본 자료는 복원했어요. 화면을 갱신하고 있어요. 다시 확인을 선택해 주세요."
            }
        } catch {
            problem = sourceRestored ? "원본 자료는 복원했어요. 새 저장소를 열지 못해 다시 확인해야 해요. 다시 확인을 선택해 주세요." : "복원하지 못했어요. 파일과 저장된 원본을 확인해 주세요."
        }
    }
    private func openRestoredWorkspace(_ config: StoreConfiguration, replacing oldServices: SystemServices?) async throws {
        // 교체된 원본에 예전 actor나 화면의 작업을 다시 연결하지 않는다.
        stopCanonicalObservation()
        store = nil; services = nil; configuration = config
        clearTransientData()
        preferences.deadlineAlarmDates = [:]
        if let oldServices { await reportCleanup(await oldServices.eraseLocalSurfaceData()) }
        let next = try await MirrorStore(configuration: config)
        store = next
        services = SystemServices(store: next, directory: config.directory, workspaceEpoch: config.workspaceEpoch)
        await observeCanonicalChanges(next)
    }
    func deleteLocalData() async {
        guard let store, !isSaving else { return }
        isSaving = true
        defer { finishSaving() }
        var sourceDeleted = false
        do {
            let oldServices = services
            let report = try await store.deleteLocalData()
            guard report.deleted, let config = report.newConfiguration else { problem = report.safeUserMessage; return }
            sourceDeleted = true
            stopCanonicalObservation()
            self.store = nil; services = nil
            configuration = config
            clearTransientData()
            preferences.deadlineAlarmDates = [:]
            preferences.reviewNotifications = false; preferences.deadlineNotifications = false
            preferences.spotlightEnabled = false; preferences.selectedCalendars = []; preferences.calendarEnabled = false
            if let oldServices { await reportCleanup(await oldServices.eraseLocalSurfaceData()) }
            let next = try await MirrorStore(configuration: config)
            self.store = next
            services = SystemServices(store: next, directory: config.directory, workspaceEpoch: config.workspaceEpoch)
            await observeCanonicalChanges(next)
            resetCloudService(localConfiguration: config)
            defaults.set(config.workspaceEpoch, forKey: "Mirror.workspaceEpoch.v1")
            tasks = []; records = []; review = nil; lastUndo = nil
            defaults.removeObject(forKey: sessionKey)
            feedback = "이 기기의 데이터를 지웠어요. iCloud 자료와 다른 기기는 삭제하지 않았어요."
            await refresh()
        } catch {
            problem = sourceDeleted ? "이 기기의 원본은 지웠어요. 새 저장소를 열지 못해 다시 확인해야 해요. iCloud 자료는 지우지 않았어요." : "기기 데이터를 지우지 못했어요. 삭제 상태를 다시 확인해 주세요."
        }
    }

    func retry() async {
        if let widgetDecision { _ = await commitWidget(widgetDecision.request, target: widgetDecision.target) }
        else if let retryEnvelope { _ = await execute(retryEnvelope, success: "이 기기에 저장했어요.") }
        else if store == nil { await start() }
        else {
            if let store, canonicalObservation == nil || recoveryConfigurationBlocked,
               cloudSyncStatus != .accountTransitionRequired { await observeCanonicalChanges(store) }
            await refresh()
        }
    }

    @discardableResult
    private func submit(_ payload: CommandPayload, success: String) async -> Bool {
        guard let context, let envelope = makeEnvelope(payload, context: context, token: UUID().uuidString) else { return false }
        return await execute(envelope, success: success)
    }
    private func makeEnvelope(_ payload: CommandPayload, context: PlanningContext, token: String) -> CommandEnvelope? {
        guard let configuration else { return nil }
        return CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: token, source: .app,
                               context: context, workspaceEpoch: configuration.workspaceEpoch, payload: payload)
    }

    @discardableResult
    private func execute(_ envelope: CommandEnvelope, success: String) async -> Bool {
        guard let store, !isSaving, !projectionPending || envelope.idempotencyKey == retryEnvelope?.idempotencyKey else { return false }
        isSaving = true; problem = nil
        defer { finishSaving() }
        if configuration?.cloudSync != nil, let cloud, !isUITesting {
            guard await cloud.validateLocalIdentity() else {
                cloudSyncStatus = await cloud.status()
                stopCanonicalObservation()
                problem = "iCloud 계정을 확인하지 못했어요. 이전 계정 공간의 쓰기를 잠시 멈췄어요. 동기화 설정을 확인해 주세요."
                return false
            }
        }
        let current: PlanningContext
        do { current = try PlanningContext.capture(at: now, timeZoneID: preferences.timeZoneID, policyRevision: preferences.policyRevision) }
        catch { problem = "계획 시간대를 확인해 주세요."; return false }
        let result = await store.execute(envelope, context: current)
        return await handleResult(envelope, result: result, success: success)
    }
    private func handleResult(_ envelope: CommandEnvelope, result: CommandResult, success: String) async -> Bool {
        if envelope.source == .app, result.state != .alreadyApplied, let services {
            let committed = result.state == .locallyCommitted || result.state == .committedProjectionPending
            let kind: LocalMetricKind
            if envelope.kind == .capture { kind = committed ? .captureSaved : .captureRejected }
            else if case .reviewClose = envelope.payload { kind = .reviewClosed }
            else if case .undo = envelope.payload { kind = .undoResult }
            else { kind = committed ? .decisionCommitted : .decisionRejected }
            let outcome: MetricOutcome
            switch result.state {
            case .locallyCommitted: outcome = .success
            case .committedProjectionPending: outcome = .projectionPending
            case .requiresConfirmation: outcome = .confirmation
            case .staleContext, .staleSnapshot, .alreadyDecided: outcome = .stale
            case .notFound, .unavailable: outcome = .unavailable
            case .alreadyApplied: outcome = .success
            case .persistenceFailed: outcome = .failure
            }
            let metrics = await services.metrics
            let activeTime: Int?
            if case .reviewClose = envelope.payload, committed {
                endReviewExposureSegment()
                activeTime = activeReviewMilliseconds
                activeReviewMilliseconds = 0
            } else { activeTime = nil }
            try? await metrics.record(LocalMetric(kind: kind, at: now, surface: .app, outcome: outcome,
                                                  activeReviewMilliseconds: activeTime,
                                                  countBucket: result.affectedTaskIDs.isEmpty ? 0 : result.affectedTaskIDs.count == 1 ? 1 : result.affectedTaskIDs.count <= 5 ? 5 : 20))
        }
        switch result.state {
        case .locallyCommitted, .alreadyApplied:
            retryEnvelope = nil
            projectionPending = false
            guard await refresh() else {
                projectionPending = true; retryEnvelope = envelope
                feedback = "저장했어요. 화면을 갱신하고 있어요."
                return false
            }
            feedback = success
            advanceReview(envelope, result: result)
            recordUndo(envelope, result: result)
            if envelope.kind == .capture { lastCaptureCommittedToken = envelope.idempotencyKey }
            return true
        case .committedProjectionPending:
            projectionPending = true; feedback = "저장했어요. 화면을 갱신하고 있어요."
            retryEnvelope = envelope
            return false
        case .requiresConfirmation: confirmation = envelope; return false
        case .staleContext, .staleSnapshot, .alreadyDecided:
            problem = result.safeUserMessage
            retryEnvelope = nil
            await refresh()
            return false
        case .notFound, .unavailable, .persistenceFailed:
            problem = result.safeUserMessage
            retryEnvelope = envelope
            return false
        }
    }

    private func advanceReview(_ envelope: CommandEnvelope, result: CommandResult) {
        guard case let .setPlan(item, target, decision) = envelope.payload,
              let decision, review?.id == decision.sessionID,
              review?.cards.first?.id == decision.cardID,
              Set(result.affectedTaskIDs) == Set([item.taskID]),
              review?.cards.first?.taskID == item.taskID else { return }
        review?.cards.removeFirst()
        if target == .day(envelope.context.planningDay) { review?.decidedToday += 1 }
        else { review?.decidedElsewhere += 1 }
        refreshUpcomingCards()
        persistSession()
    }
    private func refreshUpcomingCards(renewCurrentCard: Bool = true) {
        guard var session = review, let configuration else { return }
        let previousCurrentTaskID = session.cards.first?.taskID
        let latest = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        let report = TaskReducer.reduce(records, workspaceKey: configuration.workspaceKey, workspaceEpoch: configuration.workspaceEpoch)
        let planningDay = session.context.planningDay
        let cycleID = session.cycleID
        let reviewMode: ReviewMode = session.todayOverride ? .manualTodayOverride : .manualResume
        session.cards.removeAll { card in
            guard let task = latest[card.taskID], task.isProjectionComplete else { return true }
            return !PlanningRules.isReviewCandidate(task.planningState, on: planningDay,
                                                    acknowledgedCurrentPlan: report.acknowledges(task: task, cycleID: cycleID),
                                                    mode: reviewMode)
        }
        // 이어 정리는 유효한 현재 카드의 stale 검사와 token을 유지한다. 새로 노출하는 다음 카드는 최신화한다.
        if let next = session.cards.first, let task = latest[next.taskID],
           renewCurrentCard || next.taskID != previousCurrentTaskID {
            session.cards[0] = ReviewCard(id: UUID().uuidString, taskID: task.taskID,
                                          expected: ExpectedVersions(task), decisionToken: UUID().uuidString)
        }
        review = session
    }
    private func recordUndo(_ envelope: CommandEnvelope, result: CommandResult) {
        guard let operationID = result.operationID else { return }
        guard let original = records.first(where: { $0.operationID == operationID }), !original.undoValues.isEmpty else { return }
        let expectations = original.undoExpectations()
        lastUndo = SafeUndo(id: operationID, expected: expectations, taskID: result.affectedTaskIDs.count == 1 ? result.affectedTaskIDs.first : nil)
    }
    private func persistSession() {
        if let review, let bytes = try? JSONEncoder().encode(review) { defaults.set(bytes, forKey: sessionKey) }
    }

    var now: Date {
        #if DEBUG
        if isUITesting, let value = ProcessInfo.processInfo.environment["MIRROR_TEST_DATE"],
           let instant = ISO8601DateFormatter().date(from: value) { return instant }
        #endif
        return Date()
    }
    private var isUITesting: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["MIRROR_UI_TESTING"] == "1"
        #else
        return false
        #endif
    }
    func history(for taskID: UUID) -> [OperationRecord] {
        records.filter { $0.affectedTaskIDs.contains(taskID) }.sorted { $0.lamport > $1.lamport }.prefix(20).map { $0 }
    }
    private func todayOrder(_ lhs: TaskProjection, _ rhs: TaskProjection) -> Bool {
        let leftID = lhs.versions[.plan]?.winningOperationID
        let rightID = rhs.versions[.plan]?.winningOperationID
        let left = leftID.flatMap { lamportByOperationID[$0] } ?? 0
        let right = rightID.flatMap { lamportByOperationID[$0] } ?? 0
        return left == right ? lhs.taskID.uuidString < rhs.taskID.uuidString : left < right
    }
    private func reviewOrder(_ task: TaskProjection, context: PlanningContext) -> (Int, Date, String) {
        let deadline = task.deadline.flatMap { try? $0.planningDate(in: context) }
        let rank: Int
        if let deadline, deadline < context.planningDay { rank = 0 }
        else if let deadline, deadline <= ((try? context.planningDay.addingDays(1)) ?? context.planningDay) { rank = 1 }
        else {
            switch task.plan.target {
            case let .day(day): rank = day < context.planningDay ? 2 : 3
            case .week: rank = 4
            case .unassigned: rank = 5
            case .parked: rank = 6
            }
        }
        return (rank, task.createdAt, task.taskID.uuidString)
    }
    func requestCalendarAccess() async {
        guard let services else { return }
        do {
            let calendar = await services.calendar
            let granted = try await calendar.requestFullAccess()
            preferences.calendarEnabled = granted
            calendarAccess = await calendar.authorization()
            if granted { calendars = try await calendar.calendars(); calendarProblem = nil }
            else { calendars = []; calendarEvents = []; calendarProblem = "캘린더 접근을 허용하지 않았어요. 할 일 날짜 배치는 계속 사용할 수 있어요." }
            savePreferences()
        } catch { calendarProblem = "일정을 불러오지 못했어요. 할 일 목록은 계속 사용할 수 있어요." }
    }
    func loadCalendar(from start: Date, to end: Date) async {
        let loadID = UUID()
        calendarLoadID = loadID
        calendarDisplayRange = (start, end)
        guard let services, preferences.calendarEnabled else { calendarEvents = []; return }
        let identity = storeObservationID
        let calendar = await services.calendar
        let access = await calendar.authorization()
        guard storeObservationID == identity, calendarLoadID == loadID else { return }
        calendarAccess = access
        guard access == .fullAccess else {
            calendarEvents = []; calendars = []
            calendarProblem = "캘린더 권한이 없어요. 할 일 날짜 배치는 계속 사용할 수 있어요."
            await calendar.clearCache()
            return
        }
        do {
            let available = try await calendar.calendars()
            let events = try await calendar.events(from: start, to: end, calendarIDs: preferences.selectedCalendars, now: now)
            guard storeObservationID == identity, calendarLoadID == loadID, preferences.calendarEnabled else { return }
            calendars = available
            calendarEvents = events
            calendarProblem = nil
        } catch {
            guard storeObservationID == identity, calendarLoadID == loadID else { return }
            calendarEvents = []; calendars = []
            calendarProblem = "일정을 불러오지 못했어요. 할 일 목록은 계속 사용할 수 있어요."
            await calendar.clearCache()
        }
    }
    func refreshCalendarOnForeground() async {
        guard let services else { return }
        let identity = storeObservationID
        let loadID = UUID()
        calendarLoadID = loadID
        let calendar = await services.calendar
        await calendar.clearCache()
        let access = await calendar.authorization()
        guard storeObservationID == identity, calendarLoadID == loadID else { return }
        calendarAccess = access
        guard access == .fullAccess else {
            calendarEvents = []; calendars = []
            if preferences.calendarEnabled {
                calendarProblem = "캘린더 권한이 없어요. 할 일 날짜 배치는 계속 사용할 수 있어요."
            }
            return
        }
        guard preferences.calendarEnabled else { calendarEvents = []; calendars = []; return }
        if let calendarDisplayRange {
            await loadCalendar(from: calendarDisplayRange.start, to: calendarDisplayRange.end)
        } else {
            do {
                let available = try await calendar.calendars()
                guard storeObservationID == identity, calendarLoadID == loadID else { return }
                calendars = available
                calendarProblem = nil
            } catch {
                guard storeObservationID == identity, calendarLoadID == loadID else { return }
                calendarEvents = []; calendars = []
                calendarProblem = "일정을 불러오지 못했어요. 할 일 목록은 계속 사용할 수 있어요."
            }
        }
    }
    func enableNotifications(review: Bool, deadlines: Bool) async {
        guard let services else { return }
        if review || deadlines {
            do {
                let notifications = await services.notifications
                notificationsAuthorized = try await notifications.requestAuthorization()
                guard notificationsAuthorized else { problem = "알림이 허용되지 않았어요. 앱에서 직접 정리와 마감을 확인할 수 있어요."; return }
            } catch { problem = "알림 권한을 확인하지 못했어요."; return }
        }
        preferences.reviewNotifications = review; preferences.deadlineNotifications = deadlines
        savePreferences()
    }
    func setDeadlineAlarm(_ task: TaskProjection, fireAt: Date?) {
        if let fireAt { preferences.deadlineAlarmDates[task.taskID] = fireAt }
        else { preferences.deadlineAlarmDates.removeValue(forKey: task.taskID) }
        savePreferences()
    }
    func handleURL(_ url: URL, expectedObservationID: UUID? = nil) async {
        do {
            if store == nil || isLoading { await start() }
            guard await refresh() else { return }
            if let expectedObservationID, expectedObservationID != storeObservationID { return }
            let route = try MirrorDeepLink.parse(url)
            let displayedReview = review
            var trustedCards: [UUID: UUID] = Dictionary(uniqueKeysWithValues: (displayedReview?.cards ?? []).compactMap { card in
                UUID(uuidString: card.id).map { ($0, card.taskID) }
            })
            var widgetState: WidgetReviewState?
            if case let .schedule(taskID, sessionID, cardID) = route, let services,
               let sessionID, let cardID {
                let widget = await services.widget
                let state = try await widget.snapshot(at: now)
                if state.sessionID == sessionID, let card = state.card,
                   card.cardID == cardID, card.taskID == taskID {
                    trustedCards[cardID] = taskID
                    widgetState = state
                }
            }
            if let expectedObservationID, expectedObservationID != storeObservationID { return }
            let validated = try MirrorDeepLink.validate(route, ownedTaskIDs: Set(tasks.map(\.taskID)), trustedCards: trustedCards)
            switch validated {
            case .capture: openCapture(single: true)
            case .today: destination = .today
            case let .review(weekly): beginReview(mode: .manualResume, weekly: weekly)
            case let .task(id): selectedTaskID = id
            case let .schedule(id, _, cardID):
                if let widgetState, let card = widgetState.card {
                    selectedTaskID = nil
                    picker = PlanPickerRequest(taskIDs: [id], expected: [PlanCommandItem(taskID: id, expected: card.expected)],
                                               displayedContext: card.context, token: card.decisionToken,
                                               review: ReviewDecisionContext(cycleID: widgetState.cycleID, sessionID: widgetState.sessionID.uuidString,
                                                                             cardID: card.cardID.uuidString, taskID: id), week: nil,
                                               widgetState: widgetState)
                    return
                }
                let card = displayedReview?.cards.first { UUID(uuidString: $0.id) == cardID && $0.taskID == id }
                makePicker(taskIDs: [id], reviewCard: card, reviewSession: card == nil ? nil : displayedReview)
            }
        } catch { problem = "이 공간의 작업을 찾을 수 없거나 링크가 오래되었어요. 데이터는 바뀌지 않았어요." }
    }
    func handleSpotlight(_ activity: NSUserActivity) async {
        if store == nil || isLoading { await start() }
        let identity = storeObservationID
        guard await refresh() else { return }
        guard storeObservationID == identity, let services else { return }
        do {
            let currentPreferences = try await services.preferences()
            guard storeObservationID == identity else { return }
            guard let route = SpotlightService.navigationRoute(for: activity, tasks: tasks,
                enabled: currentPreferences.spotlightEnabled, hideTitles: currentPreferences.hideExternalTitles) else {
                problem = "검색 노출 설정이나 현재 작업을 확인해 주세요. 데이터는 바뀌지 않았어요."
                return
            }
            await handleURL(MirrorDeepLink.url(for: route), expectedObservationID: identity)
        } catch {
            guard storeObservationID == identity else { return }
            problem = "현재 검색 노출 동의를 확인하지 못했어요. 데이터는 바뀌지 않았어요."
        }
    }
    private func requestSystemReconciliation() {
        guard services != nil, context != nil else { return }
        systemReconciliationPending = true
        guard systemReconciliationTask == nil else { return }
        let identity = storeObservationID
        // OS 후처리는 저장된 화면과 명령의 성공 응답을 기다리게 하지 않는다.
        // 실행 중 들어온 여러 요청은 다음 한 번의 최신 설정 갱신으로 합친다.
        systemReconciliationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.storeObservationID == identity, self.systemReconciliationPending {
                self.systemReconciliationPending = false
                await self.reconcileSystemServices(identity: identity)
            }
            guard self.storeObservationID == identity else { return }
            self.systemReconciliationTask = nil
        }
    }
    private func reconcileSystemServices(identity: UUID) async {
        guard !Task.isCancelled, storeObservationID == identity, let services, let context else { return }
        do {
            let reviewPreference = ReviewNotificationPreference(enabled: preferences.reviewNotifications,
                                                                 hour: preferences.reviewHour, minute: preferences.reviewMinute,
                                                                 weeklyWeekday: preferences.weeklyWeekday)
            let deadlinePreferences = preferences.deadlineNotifications ? preferences.deadlineAlarmDates.map { DeadlineNotificationPreference(taskID: $0.key, fireAt: $0.value) } : []
            let systemPreferences = SystemPreferences(planningTimeZoneID: context.timeZoneID, policyRevision: context.policyRevision,
                                                      hideExternalTitles: preferences.hideExternalTitles, spotlightEnabled: preferences.spotlightEnabled,
                                                      notificationsOnThisDevice: preferences.reviewNotifications || preferences.deadlineNotifications,
                                                      selectedCalendarIDs: preferences.selectedCalendars,
                                                      reviewNotification: reviewPreference, deadlineNotifications: deadlinePreferences)
            try await services.savePreferences(systemPreferences)
            guard !Task.isCancelled, storeObservationID == identity else { return }
            let report = await services.reconcileExternalSurfaces(at: now)
            guard !Task.isCancelled, storeObservationID == identity else { return }
            notificationOmittedCount = report.omittedNotificationCount
            WidgetReload.request()
            systemProblem = report.safeUserMessage ?? (projectionRecovery != nil || recoveryConfigurationBlocked
                ? "목록을 복구한 뒤 외부 노출·알림을 꺼 두었어요. 설정에서 복구 상태를 확인해 주세요." : nil)
        } catch {
            guard !Task.isCancelled, storeObservationID == identity else { return }
            systemProblem = "할 일은 저장되어 있어요. 알림 또는 시스템 검색 갱신을 다시 확인해 주세요."
        }
    }
    private func commitWidget(_ request: PlanPickerRequest, target: PlanTarget, acknowledgment: DeadlineAcknowledgment? = nil) async -> Bool {
        guard let services, let state = request.widgetState, let card = state.card, !isSaving,
              let configuration else { return false }
        isSaving = true; problem = nil
        defer { finishSaving() }
        let envelope = CommandEnvelope(requestID: UUID().uuidString, idempotencyKey: card.decisionToken, source: .widget,
                                       context: card.context, workspaceEpoch: configuration.workspaceEpoch,
                                       payload: .setPlan(item: PlanCommandItem(taskID: card.taskID, expected: card.expected, acknowledgment: acknowledgment),
                                                         target: target, review: request.review))
        do {
            let widget = await services.widget
            let result = try await widget.commit(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card,
                                                  target: target, acknowledgment: acknowledgment, at: now)
            let committed = await handleResult(envelope, result: result, success: "\(planLabel(target))로 보냈어요.")
            if committed { widgetDecision = nil; completedWidgetPickerID = request.id }
            else { widgetDecision = (request, target) }
            return committed
        } catch {
            widgetDecision = (request, target)
            problem = "위젯의 작업이나 저장소를 확인하지 못했어요. 대상 카드를 유지했어요. 다시 확인해 주세요."
            return false
        }
    }
    func finishWidgetPlan(_ request: PlanPickerRequest, resume: Bool) {
        guard completedWidgetPickerID == request.id, picker?.id == request.id, !isSaving, !projectionPending else { return }
        widgetNextDestination = (resume, storeObservationID)
        completedWidgetPickerID = nil
        picker = nil
    }
    func finishWidgetPickerDismissal() {
        guard let next = widgetNextDestination else { completedWidgetPickerID = nil; return }
        widgetNextDestination = nil
        guard next.observationID == storeObservationID else { return }
        selectedTaskID = nil
        if next.resume { beginReview(mode: .manualResume) }
        else { destination = .today }
    }
    var cloudConnected: Bool { configuration?.cloudSync != nil }
    private func resetCloudService(localConfiguration: StoreConfiguration) {
        let container = (Bundle.main.object(forInfoDictionaryKey: "MirrorCloudContainerIdentifier") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = (Bundle.main.object(forInfoDictionaryKey: "MirrorAppGroupIdentifier") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        cloud = CloudSyncService(localConfiguration: localConfiguration,
                                setup: CloudSyncSetup(containerIdentifier: container.flatMap { $0.isEmpty ? nil : $0 },
                                                      appGroupIdentifier: group.flatMap { $0.isEmpty ? nil : $0 }))
        cloudSyncStatus = .localOnly
        cloudPreview = nil
        if let cloud { observeCloudStatus(cloud) }
    }
    private func observeCloudStatus(_ connection: CloudSyncService) {
        cloudStatusObservation?.cancel()
        let identity = UUID()
        cloudObservationID = identity
        cloudStatusObservation = Task { [weak self] in
            let stream = await connection.statuses()
            for await status in stream {
                guard !Task.isCancelled, let self, self.cloudObservationID == identity else { break }
                self.cloudSyncStatus = status
                if status == .accountTransitionRequired {
                    self.stopCanonicalObservation()
                    self.clearTransientData()
                    self.problem = "iCloud 계정이 바뀌어 이전 개인 공간의 화면을 비웠어요. 새 계정으로 자동 병합하지 않아요. 동기화 설정을 확인해 주세요."
                }
            }
        }
    }
    func previewCloudConnection() async {
        guard let cloud, let store, !isSaving else { return }
        isSaving = true
        defer { finishSaving() }
        cloudPreview = await cloud.previewEnable(localStore: store, explicitOptIn: true, at: now)
        cloudSyncStatus = await cloud.status()
    }
    func confirmCloudConnection() async {
        guard let cloud, let preview = cloudPreview, !isSaving else { return }
        isSaving = true
        defer { finishSaving() }
        if let cloudStore = await cloud.confirmEnable(token: preview.token, consentToMerge: true) {
            let config = await cloudStore.configuration
            self.store = cloudStore; configuration = config
            services = SystemServices(store: cloudStore, directory: config.directory, workspaceEpoch: config.workspaceEpoch)
            if let services { await services.attachCloudMonitor(cloud) }
            await observeCanonicalChanges(cloudStore)
            cloudPreview = nil; review = nil; picker = nil; lastUndo = nil
            defaults.removeObject(forKey: sessionKey)
            cloudSyncStatus = await cloud.status()
            await refresh()
            feedback = "이 기기의 작업을 연결했어요. iCloud 전송과 다른 기기의 반영은 별도 상태로 확인해요."
        } else {
            let failureStatus = await cloud.status()
            do {
                // 병합 전에 exportAndSuspend로 닫힌 로컬 actor도 새로 개설한다.
                let local = try await cloud.disable()
                let config = await local.configuration
                self.store = local; configuration = config
                services = SystemServices(store: local, directory: config.directory, workspaceEpoch: config.workspaceEpoch)
                await observeCanonicalChanges(local)
                cloudPreview = nil
                cloudSyncStatus = await cloud.status()
                await refresh()
                problem = "iCloud 연결을 마치지 못해 기기 전용 공간을 다시 열었어요. 기존 원본은 유지했어요. 계정과 병합 상태를 다시 확인해 주세요."
            } catch {
                stopCanonicalObservation()
                self.store = nil; services = nil
                cloudSyncStatus = failureStatus
                problem = "iCloud 연결과 기기 전용 저장소를 다시 확인해야 해요. 저장된 원본은 지우지 않았어요. 다시 확인을 선택해 주세요."
            }
        }
    }
    func cancelCloudConnection() async {
        guard let cloud else { return }
        await cloud.cancelPreview(); cloudPreview = nil; cloudSyncStatus = await cloud.status()
    }
    func disableCloudConnection() async {
        guard let cloud, !isSaving else { return }
        isSaving = true
        defer { finishSaving() }
        do {
            let local = try await cloud.disable()
            let config = await local.configuration
            self.store = local; configuration = config
            services = SystemServices(store: local, directory: config.directory, workspaceEpoch: config.workspaceEpoch)
            await observeCanonicalChanges(local)
            cloudPreview = nil; review = nil; lastUndo = nil; cloudSyncStatus = .localOnly
            await refresh()
            feedback = "동기화 연결을 중지했어요. 연결 전의 기기 전용 공간으로 돌아왔어요. iCloud 원본은 지우거나 자동 복사하지 않았어요."
        } catch { problem = "동기화 연결을 중지하지 못했어요. 이전 공간을 유지하고 있어요." }
    }
    func inspectCloudDeletion() async {
        guard let cloud else { return }
        let status = await cloud.cloudDeletionStatus(confirmedTwice: true)
        switch status {
        case .configurationRequired: cloudDeletionMessage = "현재 앱에서 iCloud 전체 삭제를 사용할 수 없어요. 데이터를 지우지 않았어요. 이 기기에서 지우기와 내보내기는 사용할 수 있어요."
        case .requiresDoubleConfirmation: cloudDeletionMessage = "개인 공간 전체 삭제를 두 번 확인해야 해요. 데이터를 삭제하지 않았어요."
        case .blocked: cloudDeletionMessage = "다른 기기와 iCloud에 남은 데이터까지 지우는 기능은 아직 준비 중이에요. 데이터를 지우지 않았어요. 이 기기에서 지우기와 내보내기는 사용할 수 있어요."
        }
    }
    func exportDiagnostics(consentGiven: Bool) async {
        guard let services, consentGiven else { return }
        do {
            let metrics = await services.metrics
            archiveData = try await metrics.exportSummary(consentGiven: true)
            exportFileName = "Mirror-local-diagnostics"
        } catch { problem = "진단 요약을 만들지 못했어요. 할 일 원본은 유지했어요." }
    }
    func eraseDiagnostics() async {
        guard let services else { return }
        do { let metrics = await services.metrics; try await metrics.erase(); feedback = "이 기기의 진단 기록을 지웠어요." }
        catch { problem = "이 기기의 진단 기록을 지우지 못했어요." }
    }
    func setSceneActive(_ id: UUID, active: Bool) {
        if active { activeScenes.insert(id) } else { activeScenes.remove(id) }
        updateReviewExposure()
    }
    func setReviewVisible(_ id: UUID, visible: Bool) {
        if visible { reviewExposures.insert(id) } else { reviewExposures.remove(id) }
        updateReviewExposure()
    }
    private func updateReviewExposure() {
        if !activeScenes.isEmpty && !reviewExposures.isEmpty {
            if reviewExposureStart == nil { reviewExposureStart = .now }
        } else { endReviewExposureSegment() }
    }
    private func endReviewExposureSegment() {
        guard let start = reviewExposureStart else { return }
        let duration = start.duration(to: .now).components
        let milliseconds = max(0, Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1_000_000_000_000_000)
        let elapsed = milliseconds < Double(Int.max) ? Int(milliseconds) : Int.max
        let (sum, overflow) = activeReviewMilliseconds.addingReportingOverflow(elapsed)
        activeReviewMilliseconds = overflow ? Int.max : sum
        reviewExposureStart = nil
    }
    func recordCaptureFlowStarted() async { await recordMetric(kind: .captureAttempt) }
    private func recordMetric(kind: LocalMetricKind, outcome: MetricOutcome? = nil) async {
        guard let services else { return }
        let metrics = await services.metrics
        try? await metrics.record(LocalMetric(kind: kind, at: now, surface: .app, outcome: outcome))
    }
    private func clearTransientData() {
        endReviewExposureSegment()
        activeReviewMilliseconds = 0; reviewExposures = []
        tasks = []; records = []; review = nil; lastUndo = nil; picker = nil; confirmation = nil
        completedWidgetPickerID = nil; widgetNextDestination = nil
        projectionRecovery = nil; recoveryConfigurationBlocked = false
        lamportByOperationID = [:]
        retryEnvelope = nil; widgetDecision = nil; archiveData = nil; importData = nil
        pendingImportFeedback = nil; calendarDisplayRange = nil
        calendarLoadID = UUID()
        importPreview = nil; archivePreview = nil; selectedTaskID = nil; selectedTaskIDs = []
        calendarEvents = []; calendars = []; showReview = false; projectionPending = false
        feedback = nil; problem = nil
        defaults.removeObject(forKey: sessionKey)
    }
    private func reportCleanup(_ report: LocalSurfaceCleanupReport) async {
        if report.failures.isEmpty {
            cleanupProblem = "OS가 이미 표시한 위젯 등은 즉시 사라진다고 보장할 수 없어요. 새로고침을 요청했어요."
        } else {
            cleanupProblem = "원본 처리 후 시스템 검색 또는 기기 진단 자료 정리의 일부를 확인하지 못했어요. 이미 렌더링된 OS 화면의 즉시 제거도 보장하지 않아요. 설정에서 다시 확인해 주세요."
        }
    }
}

func cloudStatusLabel(_ status: CloudSyncStatus) -> String {
    switch status {
    case .localOnly: "기기 전용 저장"
    case let .configurationRequired(missing): "설정 필요: " + missing.map { item in
        switch item { case .cloudContainerIdentifier: "iCloud 연결"; case .appGroupIdentifier: "앱과 위젯 연결"; case .signedAppGroupAccess: "앱 연결 권한"; case .stableWorkspaceEpoch: "개인 공간 설정" }
    }.joined(separator: ", ")
    case .checkingAccount: "선택한 iCloud 계정 확인 중"
    case .accountUnavailable: "iCloud 계정을 사용할 수 없어요. 기기 전용 저장은 계속 사용할 수 있어요."
    case .awaitingMergeConsent: "기기와 계정의 원본 병합 확인 대기"
    case .awaitingSynchronization: "이 기기에 저장됨 · iCloud 동기화 대기"
    case .synchronizing: "이 기기에 저장됨 · iCloud 변경 전송 또는 수신 중"
    case .idle: "최근 iCloud 작업 완료 · 다른 기기의 반영 상태는 별도"
    case .failed: "iCloud 동기화 문제 · 로컬 저장 결과는 유지해요."
    case .accountTransitionRequired: "iCloud 계정 전환 확인 필요 · 이전 계정 공간 쓰기 중지"
    }
}

extension OperationRecord {
    var kindLabel: String {
        switch commandKind {
        case .capture: "보관함에 넣기"
        case .setPlan: "계획 변경"
        case .setStatus: "완료·휴지통 상태 변경"
        case .setDeadline: "실제 마감 변경"
        case .editContent: "내용 편집"
        case .undo: "조건부 되돌리기"
        case .reviewClose: "정리 종료"
        case .settings: "계획 설정 변경"
        }
    }
}

func planLabel(_ plan: PlanTarget) -> String {
    switch plan {
    case .unassigned: "아직 정하지 않음"
    case let .day(date): "\(AppDate.label(date))에 하기"
    case let .week(start, end): "\(AppDate.short(start))–\(AppDate.short((try? end.addingDays(-1)) ?? end)) 중 날짜 미정"
    case .parked: "당분간 보관"
    }
}

enum AppDate {
    static func label(_ date: LocalDate) -> String { "\(date.month)월 \(date.day)일 \(weekdayLabel(date))" }
    static func short(_ date: LocalDate) -> String { "\(date.month)/\(date.day)" }
    static func weekday(_ date: LocalDate) -> Int {
        guard let start = try? date.mondayWeek().startDate else { return 2 }
        for i in 0..<7 where (try? start.addingDays(i)) == date { return (i + 1) % 7 + 1 }
        return 2
    }
    static func weekdayLabel(_ date: LocalDate) -> String { ["", "일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일"][weekday(date)] }
    static func instant(_ date: LocalDate, zone: String) -> Date? {
        guard let timeZone = TimeZone(identifier: zone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 12))
    }
}
