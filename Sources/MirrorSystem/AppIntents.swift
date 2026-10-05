import Foundation
import AppIntents
import MirrorDomain

/// 앱과 위젯의 includedPackages가 이 정적 framework의 인텐트 metadata를 포함한다.
public struct MirrorAppIntentsPackage: AppIntentsPackage {}

public enum MirrorDeadlineKind: String, AppEnum, Sendable {
    case notSet, day, instant
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "실제 마감 종류")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .notSet: "마감 없음", .day: "날짜 마감", .instant: "시각 마감"
    ]
}

public struct MirrorTaskEntity: AppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "할 일")
    public static let defaultQuery = MirrorTaskQuery()
    public let id: UUID
    public let title: String
    public let planSummary: String
    public let completed: Bool
    @Property(title: "실제 마감 종류") public var deadlineKind: MirrorDeadlineKind
    /// 날짜 마감을 임의의 자정 Date로 바꾸지 않는다.
    @Property(title: "실제 마감 날짜 (YYYY-MM-DD)") public var deadlineDay: String?
    @Property(title: "실제 마감 시각") public var deadlineInstant: Date?
    @Property(title: "실제 마감 시간대") public var deadlineTimeZoneID: String?
    public let deadlineSummary: String
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(planSummary) · \(deadlineSummary)")
    }
    public init(task: TaskProjection, hideTitle: Bool) {
        let entityID = task.taskID
        let entityTitle = hideTitle ? "할 일" : task.title
        let isCompleted = task.status == .completed
        let resolvedPlanSummary: String
        switch task.plan.target {
        case .unassigned: resolvedPlanSummary = "날짜 미정"
        case let .day(date): resolvedPlanSummary = "계획 \(date)"
        case let .week(start, _): resolvedPlanSummary = "\(start) 주, 요일 미정"
        case .parked: resolvedPlanSummary = "보관"
        }
        let resolvedDeadlineKind: MirrorDeadlineKind
        let resolvedDeadlineDay: String?
        let resolvedDeadlineInstant: Date?
        let resolvedDeadlineTimeZoneID: String?
        let resolvedDeadlineSummary: String
        switch task.deadline {
        case nil:
            resolvedDeadlineKind = .notSet; resolvedDeadlineDay = nil; resolvedDeadlineInstant = nil; resolvedDeadlineTimeZoneID = nil
            resolvedDeadlineSummary = "실제 마감 없음"
        case let .day(date, timeZoneID):
            resolvedDeadlineKind = .day; resolvedDeadlineDay = date.description; resolvedDeadlineInstant = nil; resolvedDeadlineTimeZoneID = timeZoneID
            resolvedDeadlineSummary = "실제 마감 \(date) (\(timeZoneID))"
        case let .instant(timestamp, timeZoneID):
            resolvedDeadlineKind = .instant; resolvedDeadlineDay = nil; resolvedDeadlineInstant = timestamp; resolvedDeadlineTimeZoneID = timeZoneID
            if let timeZone = TimeZone(identifier: timeZoneID) {
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "ko_KR")
                formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd HH:mm"
                resolvedDeadlineSummary = "실제 마감 \(formatter.string(from: timestamp)) (\(timeZoneID))"
            } else {
                resolvedDeadlineSummary = "실제 마감 \(ISO8601DateFormatter().string(from: timestamp)) (\(timeZoneID))"
            }
        }
        // @Property의 setter가 self를 사용하기 전에 일반 저장 프로퍼티를 모두 초기화한다.
        id = entityID; title = entityTitle; completed = isCompleted
        planSummary = resolvedPlanSummary; deadlineSummary = resolvedDeadlineSummary
        deadlineKind = resolvedDeadlineKind; deadlineDay = resolvedDeadlineDay
        deadlineInstant = resolvedDeadlineInstant; deadlineTimeZoneID = resolvedDeadlineTimeZoneID
    }
}

public struct MirrorTaskQuery: EntityStringQuery {
    public init() {}
    public func entities(for identifiers: [UUID]) async throws -> [MirrorTaskEntity] {
        let services = try await SystemCompositionRoot.open()
        let preferences = try await services.preferences()
        let ids = Set(identifiers)
        return try await services.tasks().filter { ids.contains($0.taskID) && $0.status != .deleted && $0.isProjectionComplete }
            .map { MirrorTaskEntity(task: $0, hideTitle: preferences.hideExternalTitles) }
    }
    public func entities(matching string: String) async throws -> [MirrorTaskEntity] {
        try await entities(matching: string, status: nil)
    }
    func entities(matching string: String, status: MirrorTaskStatusFilter?) async throws -> [MirrorTaskEntity] {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, string.count <= 500 else { return [] }
        let services = try await SystemCompositionRoot.open()
        let preferences = try await services.preferences()
        let identifier = UUID(uuidString: string)
        // 권한/노출 제한을 작업 없음으로 위장하지 않는다. 명시 ID 조회는 현재 공간 안에서만 한다.
        if identifier == nil, (!preferences.spotlightEnabled || preferences.hideExternalTitles) {
            throw SystemServiceError.externalSearchDisabled
        }
        return MirrorTaskSearchPolicy.matches(try await services.tasks(), query: string, status: status)
            .map { MirrorTaskEntity(task: $0, hideTitle: preferences.hideExternalTitles) }
    }
    public func suggestedEntities() async throws -> [MirrorTaskEntity] {
        let services = try await SystemCompositionRoot.open()
        let preferences = try await services.preferences(), context = try await services.currentContext()
        let tasks = try await services.tasks().filter { $0.status != .deleted && $0.isProjectionComplete }
        let today = try await services.todayTasks(on: context.planningDay)
        let recent = tasks.sorted { $0.createdAt > $1.createdAt }.prefix(10)
        var seen: Set<UUID> = []
        return (today + recent).filter { seen.insert($0.taskID).inserted }.prefix(20)
            .map { MirrorTaskEntity(task: $0, hideTitle: preferences.hideExternalTitles) }
    }
}

public struct AddTaskIntent: AppIntent {
    public static let title: LocalizedStringResource = "할 일 넣기"
    public static let description = IntentDescription("제목만으로 날짜를 정하지 않은 할 일을 저장해요.")
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "제목") public var title: String
    @Parameter(title: "메모") public var note: String?
    @Parameter(title: "링크") public var link: URL?
    public static var parameterSummary: some ParameterSummary { Summary("\(\.$title) 넣기") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<MirrorTaskEntity> & ProvidesDialog {
        let services = try await SystemCompositionRoot.open()
        let task = try await services.capture(title: title, note: note, sourceURL: link?.absoluteString, source: .shortcut)
        let preferences = try await services.preferences()
        let warning = await services.lastSurfaceReport?.safeUserMessage ?? ""
        return .result(value: MirrorTaskEntity(task: task, hideTitle: preferences.hideExternalTitles), dialog: "저장했어요. 날짜는 나중에 정해도 돼요. \(warning)")
    }
}

public struct GetTodayTasksIntent: AppIntent {
    public static let title: LocalizedStringResource = "오늘 남긴 일"
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "계획 날짜 (YYYY-MM-DD)") public var planningDate: String?
    public static var parameterSummary: some ParameterSummary { Summary("오늘 남긴 일 보기") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<[MirrorTaskEntity]> & ProvidesDialog {
        let services = try await SystemCompositionRoot.open()
        let context = try await services.currentContext(), preferences = try await services.preferences()
        let date = try planningDate.map { try LocalDate($0) } ?? context.planningDay
        let reply = MirrorTodayTaskReplyPolicy.response(try await services.todayTasks(on: date),
                                                      hideTitle: preferences.hideExternalTitles)
        if reply.totalCount > reply.entities.count {
            return .result(value: reply.entities, dialog: "명시적으로 이 날짜에 남긴 일은 총 \(reply.totalCount)개예요. 그중 \(reply.entities.count)개를 보여드려요.")
        }
        return .result(value: reply.entities, dialog: "명시적으로 이 날짜에 남긴 일이 \(reply.entities.count)개예요.")
    }
}

/// 외부 반환 한도와 해당 날짜의 전체 개수를 분리해 일부 결과를 전체로 안내하지 않는다.
enum MirrorTodayTaskReplyPolicy {
    static func response(_ tasks: [TaskProjection], hideTitle: Bool) -> (entities: [MirrorTaskEntity], totalCount: Int) {
        (tasks.prefix(50).map { MirrorTaskEntity(task: $0, hideTitle: hideTitle) }, tasks.count)
    }
}

public enum MirrorTaskStatusFilter: String, AppEnum {
    case open, completed
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "할 일 상태")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.open: "미완료", .completed: "완료"]
}

/// 검색과 상태 조건을 모두 적용한 결과에서만 외부 응답의 개수 제한을 적용한다.
enum MirrorTaskSearchPolicy {
    static func matches(_ tasks: [TaskProjection], query: String?, status: MirrorTaskStatusFilter?) -> [TaskProjection] {
        let identifier = query.flatMap { UUID(uuidString: $0) }
        return Array(tasks.lazy.filter { task in
            guard task.status != .deleted, task.isProjectionComplete else { return false }
            if let status, task.status != (status == .completed ? .completed : .open) { return false }
            guard let query else { return true }
            return identifier.map { $0 == task.taskID } ?? task.title.localizedStandardContains(query)
        }.prefix(50))
    }
}

public struct FindTasksIntent: AppIntent {
    public static let title: LocalizedStringResource = "할 일 찾기"
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "제목 또는 작업 ID") public var query: String?
    @Parameter(title: "상태") public var status: MirrorTaskStatusFilter?
    public static var parameterSummary: some ParameterSummary { Summary("할 일 찾기") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<[MirrorTaskEntity]> {
        let text = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text?.isEmpty == false || status != nil else { throw SystemServiceError.invalidInput }
        let matches: [MirrorTaskEntity]
        if let text, !text.isEmpty { matches = try await MirrorTaskQuery().entities(matching: text, status: status) }
        else {
            let services = try await SystemCompositionRoot.open(), preferences = try await services.preferences()
            matches = MirrorTaskSearchPolicy.matches(try await services.tasks(), query: nil, status: status)
                .map { MirrorTaskEntity(task: $0, hideTitle: preferences.hideExternalTitles) }
        }
        return .result(value: matches)
    }
}

public struct ScheduleTaskIntent: AppIntent {
    public static let title: LocalizedStringResource = "할 일 날짜 바꾸기"
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "할 일") public var task: MirrorTaskEntity
    @Parameter(title: "정확한 날짜") public var date: Date
    public static var parameterSummary: some ParameterSummary { Summary("\(\.$task)을 \(\.$date)에 배치") }
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<MirrorTaskEntity> & ProvidesDialog {
        let services = try await SystemCompositionRoot.open()
        let context = try await services.currentContext()
        let original = try await services.task(task.id)
        let target = PlanTarget.day(try PlanningContext.capture(at: date, timeZoneID: context.timeZoneID,
                                                              policyRevision: context.policyRevision).planningDay)
        var result = try await services.execute(.setPlan(item: .init(taskID: task.id, expected: .init(original)), target: target, review: nil), source: .shortcut, displayedContext: context)
        if result.state == .requiresConfirmation {
            try await requestConfirmation(result: .result(dialog: "실제 마감 뒤로 배치해요. 마감은 그대로 유지해요. 계속할까요?"))
            guard let revision = original.versions[.deadline]?.headsDigest else { throw SystemServiceError.unavailable }
            let acknowledgment = DeadlineAcknowledgment(taskID: task.id.uuidString, deadlineRevision: revision, target: target)
            result = try await services.execute(.setPlan(item: .init(taskID: task.id, expected: .init(original), acknowledgment: acknowledgment), target: target, review: nil), source: .shortcut, displayedContext: context)
        }
        try await services.requireCommitted(result)
        let updated = try await services.task(task.id), preferences = try await services.preferences()
        return .result(value: MirrorTaskEntity(task: updated, hideTitle: preferences.hideExternalTitles), dialog: "\(result.safeUserMessage)")
    }
}

public struct ScheduleTaskForWeekIntent: AppIntent {
    public static let title: LocalizedStringResource = "할 일의 주만 정하기"
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "할 일") public var task: MirrorTaskEntity
    @Parameter(title: "주 시작 월요일") public var weekStart: Date
    public static var parameterSummary: some ParameterSummary { Summary("\(\.$task)을 \(\.$weekStart) 주에 배치") }
    public init() {}
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try await SystemCompositionRoot.open(), context = try await services.currentContext()
        let start = try PlanningContext.capture(at: weekStart, timeZoneID: context.timeZoneID,
                                               policyRevision: context.policyRevision).planningDay
        let week = try start.mondayWeek()
        guard start == week.startDate else { throw SystemServiceError.invalidInput }
        let target = PlanTarget.week(startDate: start, endExclusiveDate: week.endExclusiveDate)
        let original = try await services.task(task.id)
        var result = try await services.execute(.setPlan(item: .init(taskID: task.id, expected: .init(original)), target: target, review: nil), source: .shortcut, displayedContext: context)
        if result.state == .requiresConfirmation {
            try await requestConfirmation(result: .result(dialog: "실제 마감 뒤의 주예요. 마감은 유지하고 이 주를 선택할까요?"))
            guard let revision = original.versions[.deadline]?.headsDigest else { throw SystemServiceError.unavailable }
            let acknowledgment = DeadlineAcknowledgment(taskID: task.id.uuidString, deadlineRevision: revision, target: target)
            result = try await services.execute(.setPlan(item: .init(taskID: task.id, expected: .init(original), acknowledgment: acknowledgment), target: target, review: nil), source: .shortcut, displayedContext: context)
        }
        try await services.requireCommitted(result)
        return .result(dialog: "\(result.safeUserMessage) 월요일 할 일로 정한 것은 아니에요.")
    }
}

public struct SetTaskCompletedIntent: AppIntent {
    public static let title: LocalizedStringResource = "할 일 완료 상태 정하기"
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "할 일") public var task: MirrorTaskEntity
    @Parameter(title: "완료") public var completed: Bool
    public static var parameterSummary: some ParameterSummary { Summary("\(\.$task)의 완료를 \(\.$completed)로 설정") }
    public init() {}
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try await SystemCompositionRoot.open()
        let result = try await services.setCompleted(id: task.id, completed: completed, source: .shortcut)
        try await services.requireCommitted(result)
        return .result(dialog: "\(result.safeUserMessage)")
    }
}

public enum MirrorReviewMode: String, AppEnum {
    case daily, weekly
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "정리 종류")
    public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.daily: "오늘 정리", .weekly: "이번 주 정리"]
}
public struct OpenReviewIntent: AppIntent {
    public static let title: LocalizedStringResource = "정리 열기"
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "정리 종류", default: .daily) public var mode: MirrorReviewMode
    public static var parameterSummary: some ParameterSummary { Summary("\(\.$mode) 열기") }
    public init() {}
    public init(mode: MirrorReviewMode) { self.mode = mode }
    public func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(MirrorDeepLink.url(for: .review(weekly: mode == .weekly))))
    }
}
public struct OpenTaskIntent: AppIntent {
    public static let title: LocalizedStringResource = "할 일 열기"
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "할 일") public var task: MirrorTaskEntity
    public static var parameterSummary: some ParameterSummary { Summary("\(\.$task) 열기") }
    public init() {}
    public func perform() async throws -> some IntentResult & OpensIntent {
        let services = try await SystemCompositionRoot.open()
        _ = try await services.task(task.id)
        return .result(opensIntent: OpenURLIntent(MirrorDeepLink.url(for: .task(task.id))))
    }
}
public struct UndoLastDecisionIntent: AppIntent {
    public static let title: LocalizedStringResource = "직전 결정 되돌리기"
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "변경 ID") public var operationID: String?
    public static var parameterSummary: some ParameterSummary { Summary("직전 결정 되돌리기") }
    public init() {}
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = try await SystemCompositionRoot.open(), snapshot = try await services.store.snapshot()
        guard let operation = snapshot.records.last(where: { record in
            if let operationID { return record.operationID == operationID && !record.undoValues.isEmpty }
            return !record.undoValues.isEmpty
        }) else { throw SystemServiceError.missingTask }
        let result = try await services.execute(.undo(operationID: operation.operationID, expected: operation.undoExpectations()), source: .shortcut,
                                                key: "undo:\(operation.operationID)")
        try await services.requireCommitted(result)
        return .result(dialog: "\(result.safeUserMessage)")
    }
}

public struct WidgetDecisionPayload: Codable, Sendable {
    public let scopeKey: String
    public let sessionID: UUID
    public let card: WidgetCard
    public let target: PlanTarget
    public init(scopeKey: String, sessionID: UUID, card: WidgetCard, target: PlanTarget) {
        self.scopeKey = scopeKey; self.sessionID = sessionID; self.card = card; self.target = target
    }
}
public struct CommitWidgetDecisionIntent: AppIntent {
    public static let title: LocalizedStringResource = "위젯의 보였던 작업 배치"
    public static let isDiscoverable = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "내부 카드") public var payload: String
    public init() {}
    public init(_ decision: WidgetDecisionPayload) throws { payload = String(decoding: try JSONEncoder().encode(decision), as: UTF8.self) }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard payload.utf8.count <= 24_000 else { throw SystemServiceError.invalidInput }
        let decision = try JSONDecoder().decode(WidgetDecisionPayload.self, from: Data(payload.utf8))
        let services = try await SystemCompositionRoot.open()
        let result = try await services.widget.commit(scopeKey: decision.scopeKey, sessionID: decision.sessionID,
                                                     card: decision.card, target: decision.target)
        if result.state == .requiresConfirmation {
            // 위젯은 오래된 token으로 확인을 만들어 내지 않는다. 해당 작업의 전경 날짜 선택으로 연결한다.
            throw SystemServiceError.commandRejected("실제 마감 뒤예요. 미러에서 확인하고 배치하세요.")
        }
        try await services.requireCommitted(result)
        return .result(dialog: "\(result.safeUserMessage)")
    }
}
public struct ShowWidgetDatePanelIntent: AppIntent {
    public static let title: LocalizedStringResource = "위젯 날짜 패널 보기"
    public static let isDiscoverable = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "범위") public var scopeKey: String
    @Parameter(title: "카드 ID") public var cardID: String
    @Parameter(title: "패널 버전") public var panelVersion: Int
    @Parameter(title: "패널") public var panel: String
    public init() {}
    public init(state: WidgetReviewState, card: WidgetCard, panel: WidgetDatePanel) {
        scopeKey = state.scopeKey; cardID = card.cardID.uuidString; panelVersion = state.panelVersion; self.panel = panel.rawValue
    }
    public func perform() async throws -> some IntentResult {
        guard let card = UUID(uuidString: cardID), let panel = WidgetDatePanel(rawValue: panel) else { throw SystemServiceError.invalidInput }
        let services = try await SystemCompositionRoot.open()
        try await services.widget.showPanel(scopeKey: scopeKey, cardID: card, expectedPanelVersion: panelVersion, panel: panel)
        return .result()
    }
}
public struct FinishReviewIntent: AppIntent {
    public static let title: LocalizedStringResource = "이번 정리 마치기"
    public static let isDiscoverable = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "범위") public var scopeKey: String
    @Parameter(title: "세션") public var sessionID: String
    public init() {}
    public init(state: WidgetReviewState) { scopeKey = state.scopeKey; sessionID = state.sessionID.uuidString }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let session = UUID(uuidString: sessionID) else { throw SystemServiceError.invalidInput }
        let services = try await SystemCompositionRoot.open()
        let result = try await services.widget.finish(scopeKey: scopeKey, sessionID: session)
        try await services.requireCommitted(result)
        return .result(dialog: "\(result.safeUserMessage) 미검토는 그대로 남겨 두고 오늘 목록을 보여드려요.")
    }
}
public struct OpenDatePickerIntent: AppIntent {
    public static let title: LocalizedStringResource = "이 작업의 날짜 고르기"
    public static let isDiscoverable = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "작업 ID") public var taskID: String
    @Parameter(title: "세션") public var sessionID: String?
    @Parameter(title: "카드") public var cardID: String?
    public init() {}
    public init(state: WidgetReviewState, card: WidgetCard) {
        taskID = card.taskID.uuidString; sessionID = state.sessionID.uuidString; cardID = card.cardID.uuidString
    }
    public func perform() async throws -> some IntentResult & OpensIntent {
        guard let id = UUID(uuidString: taskID) else { throw SystemServiceError.invalidInput }
        let services = try await SystemCompositionRoot.open()
        _ = try await services.task(id)
        let route = MirrorRoute.schedule(taskID: id, sessionID: sessionID.flatMap(UUID.init(uuidString:)), cardID: cardID.flatMap(UUID.init(uuidString:)))
        return .result(opensIntent: OpenURLIntent(MirrorDeepLink.url(for: route)))
    }
}

public struct MirrorAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTaskIntent(), phrases: ["\(.applicationName)에 할 일 넣기"], shortTitle: "할 일 넣기", systemImageName: "plus")
        AppShortcut(intent: GetTodayTasksIntent(), phrases: ["\(.applicationName) 오늘 남긴 일"], shortTitle: "오늘 남긴 일", systemImageName: "sun.max")
        AppShortcut(intent: OpenReviewIntent(mode: .daily), phrases: ["\(.applicationName) 오늘 정리"], shortTitle: "오늘 정리", systemImageName: "square.stack")
        AppShortcut(intent: OpenReviewIntent(mode: .weekly), phrases: ["\(.applicationName) 이번 주 정리"], shortTitle: "이번 주 정리", systemImageName: "calendar")
        AppShortcut(intent: ScheduleTaskIntent(), phrases: ["\(.applicationName) 할 일 날짜 바꾸기"], shortTitle: "날짜 바꾸기", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: SetTaskCompletedIntent(), phrases: ["\(.applicationName) 할 일 완료"], shortTitle: "완료", systemImageName: "checkmark.circle")
    }
}

public struct CompleteDisplayedWidgetTaskIntent: AppIntent {
    public static let title: LocalizedStringResource = "위젯에 표시한 할 일 완료"
    public static let isDiscoverable = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "작업") public var taskID: String
    @Parameter(title: "표시 상태 버전") public var expectedStatus: String
    public init() {}
    public init(item: WidgetTodayItem) { taskID = item.taskID.uuidString; expectedStatus = item.expectedStatus }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let id = UUID(uuidString: taskID), !expectedStatus.isEmpty else { throw SystemServiceError.invalidInput }
        let services = try await SystemCompositionRoot.open()
        let result = try await services.execute(.completion(taskID: id, desiredCompleted: true, expectedStatus: expectedStatus),
                                                source: .widget, key: "widget-complete:\(taskID):\(expectedStatus)")
        try await services.requireCommitted(result)
        return .result(dialog: "\(result.safeUserMessage)")
    }
}
public struct WidgetUndoPayload: Codable, Sendable {
    public let scopeKey: String
    public let operationID: String
    public let expected: [TaskVersionExpectation]
    public init(state: WidgetReviewState, operationID: String) {
        scopeKey = state.scopeKey; self.operationID = operationID; expected = state.undoExpected
    }
}
public struct StartTodayWidgetReviewIntent: AppIntent {
    public static let title: LocalizedStringResource = "위젯에서 오늘 다시 정리"
    public static let isDiscoverable = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "범위") public var scopeKey: String
    public init() {}
    public init(scopeKey: String) { self.scopeKey = scopeKey }
    public func perform() async throws -> some IntentResult {
        let services = try await SystemCompositionRoot.open()
        _ = try await services.widget.startReview(scopeKey: scopeKey, todayOnly: true)
        return .result()
    }
}
public struct UndoDisplayedWidgetDecisionIntent: AppIntent {
    public static let title: LocalizedStringResource = "위젯의 직전 결정 되돌리기"
    public static let isDiscoverable = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "직전 결정") public var payload: String
    public init() {}
    public init(_ value: WidgetUndoPayload) throws { payload = String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard payload.utf8.count <= 8_000 else { throw SystemServiceError.invalidInput }
        let value = try JSONDecoder().decode(WidgetUndoPayload.self, from: Data(payload.utf8))
        let services = try await SystemCompositionRoot.open()
        let result = try await services.widget.undo(scopeKey: value.scopeKey, operationID: value.operationID, expected: value.expected)
        try await services.requireCommitted(result)
        return .result(dialog: "\(result.safeUserMessage)")
    }
}
