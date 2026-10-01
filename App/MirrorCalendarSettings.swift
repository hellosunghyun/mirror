import MirrorData
import MirrorDesign
import MirrorDomain
import MirrorSystem
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MirrorCalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedDate = Date()
    @State private var weekly = false
    @State private var initialized = false

    private var selectedContext: PlanningContext? {
        try? PlanningContext.capture(at: selectedDate, timeZoneID: model.preferences.timeZoneID,
                                     policyRevision: model.preferences.policyRevision)
    }
    private var localDate: LocalDate? { selectedContext?.planningDay }
    private var days: [LocalDate] {
        guard let localDate else { return [] }
        if weekly, let week = try? localDate.mondayWeek() {
            return (0..<7).compactMap { try? week.startDate.addingDays($0) }
        }
        return [localDate]
    }
    private func columns(availableWidth: CGFloat) -> [GridItem] {
        weekly && !dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.adaptive(minimum: min(300, max(1, availableWidth))), spacing: 16, alignment: .topLeading)]
            : [GridItem(.flexible(), alignment: .topLeading)]
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    calendarControls
                    LazyVGrid(columns: columns(availableWidth: geometry.size.width - 40), alignment: .leading, spacing: 16) {
                        ForEach(days, id: \.self) { date in dayCard(date) }
                    }
                    weeklyBasket
                    calendarAccess
                }
                .frame(maxWidth: 1080)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(MirrorPalette.canvas)
        }
        .navigationTitle("일정")
        .task {
            if !initialized, let day = model.context?.planningDay {
                selectedDate = AppDate.instant(day, zone: model.preferences.timeZoneID) ?? model.now
                initialized = true
            }
            await loadEvents()
        }
        .onChange(of: selectedDate) { _, _ in Task { await loadEvents() } }
        .onChange(of: weekly) { _, _ in Task { await loadEvents() } }
        .onChange(of: model.preferences.selectedCalendars) { _, _ in Task { await loadEvents() } }
    }

    private var calendarControls: some View {
        calendarCard {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    scopePicker.frame(width: 180)
                    datePicker
                }
                VStack(alignment: .leading, spacing: 14) {
                    scopePicker
                    datePicker
                }
            }
            Text("할 일은 날짜별 목록에, 실제 마감은 따로 표시해요.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var scopePicker: some View {
        Picker("보기", selection: $weekly) {
            Text("일간").tag(false)
            Text("주간").tag(true)
        }.pickerStyle(.segmented)
    }
    private var datePicker: some View {
        DatePicker("살펴볼 날짜", selection: $selectedDate, displayedComponents: .date)
            .datePickerStyle(.compact)
            .environment(\.timeZone, TimeZone(identifier: model.preferences.timeZoneID) ?? .gmt)
            .accessibilityIdentifier("calendar.date")
    }

    private func dayCard(_ date: LocalDate) -> some View {
        let context = selectedContext
        let tasks = model.tasks.filter { $0.status == .open && $0.plan.target == .day(date) }
        let deadlines = model.tasks.filter { task in
            guard let context, let deadline = task.deadline else { return false }
            return task.status == .open && task.plan.target != .day(date)
                && (try? deadline.planningDate(in: context)) == date
        }
        let events = events(on: date)
        return calendarCard {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(AppDate.label(date)).font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if date == model.context?.planningDay {
                    Text("오늘").font(.caption.weight(.medium))
                        .foregroundStyle(MirrorPalette.accent)
                }
            }
            Label("할 일 \(tasks.count)개", systemImage: "checklist")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if tasks.isEmpty {
                Text("이 날짜에 정한 일이 없어요.").font(.callout).foregroundStyle(.secondary)
            }
            taskRows(tasks)
            if !deadlines.isEmpty {
                Divider()
                Label("이 날의 실제 마감", systemImage: "flag")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(deadlines, id: \.taskID) { task in
                    Button { model.selectedTaskID = task.taskID } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.title).foregroundStyle(.primary)
                            Text(deadlineLabel(task.deadline, context: context))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("계획: \(planLabel(task.plan.target))")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(task.title), 실제 마감 \(deadlineLabel(task.deadline, context: context)), 계획 \(planLabel(task.plan.target)), 상세 열기")
                }
            }
            if !events.isEmpty {
                Divider()
                Label("기존 약속 · 읽기 전용", systemImage: "calendar")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.title).font(.callout)
                        Text(eventTimeLabel(event, on: date)).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("기존 약속, \(event.title), \(eventTimeLabel(event, on: date)), 읽기 전용")
                }
            }
        }
    }

    private func taskRows(_ tasks: [TaskProjection]) -> some View {
        let context = selectedContext
        return ForEach(tasks, id: \.taskID) { task in
            VStack(alignment: .leading, spacing: 4) {
                MirrorTaskRow(task: task)
                if task.deadline != nil {
                    Label("실제 마감: \(deadlineLabel(task.deadline, context: context))", systemImage: "flag")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var weeklyBasket: some View {
        if let date = localDate, let week = try? date.mondayWeek() {
            let tasks = model.tasks.filter {
                $0.status == .open
                    && $0.plan.target == .week(startDate: week.startDate, endExclusiveDate: week.endExclusiveDate)
            }
            calendarCard {
                Label("\(weekLabel(week)) · 요일 미정", systemImage: "tray").font(.headline)
                if tasks.isEmpty {
                    Text("이 주의 요일 미정 작업이 없어요.").font(.callout).foregroundStyle(.secondary)
                }
                taskRows(tasks)
            }
        }
    }

    private var calendarAccess: some View {
        calendarCard {
            Label("기존 캘린더 약속", systemImage: "calendar.badge.clock").font(.headline)
            if let problem = model.calendarProblem {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            }
            if model.preferences.calendarEnabled {
                if model.preferences.selectedCalendars.isEmpty {
                    Text("설정에서 읽을 캘린더를 선택해 주세요.").font(.callout).foregroundStyle(.secondary)
                }
                Button("일정 새로고침") { Task { await loadEvents() } }.buttonStyle(.bordered)
                Text("약속은 읽기 전용이에요. 종일·겹친 일정으로 사용 가능한 시간을 단정하지 않아요.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("기존 약속 보기 선택") {
                    Task { await model.requestCalendarAccess(); await loadEvents() }
                }.buttonStyle(.bordered)
                Text("허용하지 않아도 할 일 날짜를 정할 수 있어요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func calendarCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(MirrorPalette.card, in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(MirrorPalette.border, lineWidth: 1) }
    }

    private func events(on date: LocalDate) -> [CalendarEventSummary] {
        guard let range = dayRange(date) else { return [] }
        return model.calendarEvents.filter { $0.end > range.start && $0.start < range.end }
    }
    private func dayRange(_ date: LocalDate) -> (start: Date, end: Date)? {
        guard let zone = TimeZone(identifier: model.preferences.timeZoneID),
              let noon = AppDate.instant(date, zone: zone.identifier), let nextDay = try? date.addingDays(1),
              let nextNoon = AppDate.instant(nextDay, zone: zone.identifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return (calendar.startOfDay(for: noon), calendar.startOfDay(for: nextNoon))
    }
    private func eventTimeLabel(_ event: CalendarEventSummary, on date: LocalDate) -> String {
        if event.isAllDay { return "종일" }
        if let range = dayRange(date), event.start < range.start || event.end > range.end {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.timeZone = TimeZone(identifier: model.preferences.timeZoneID)
            formatter.dateFormat = "M월 d일 a h:mm"
            return "\(formatter.string(from: event.start))–\(formatter.string(from: event.end))"
        }
        return "\(timeLabel(event.start))–\(timeLabel(event.end))"
    }
    private func loadEvents() async {
        guard let first = days.first, let last = days.last,
              let endDay = try? last.addingDays(1), let zone = TimeZone(identifier: model.preferences.timeZoneID),
              let startNoon = AppDate.instant(first, zone: zone.identifier), let endNoon = AppDate.instant(endDay, zone: zone.identifier) else { return }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        await model.loadCalendar(from: calendar.startOfDay(for: startNoon), to: calendar.startOfDay(for: endNoon))
    }
    private func timeLabel(_ instant: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: model.preferences.timeZoneID); formatter.timeStyle = .short
        return formatter.string(from: instant)
    }
}

struct MirrorArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
struct MirrorSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var importing = false
    @State private var deleteConfirmed = false
    @State private var cloudDeleteFirstConfirmation = false
    @State private var timezoneSearch = ""
    @State private var showTimeZonePicker = false
    @State private var selectedZone = ""
    @State private var showLicenses = false
    @State private var confirmImport = false
    @State private var accountImportConfirmed = false
    @State private var cloudMergeConfirmed = false
    @State private var disableCloudConfirmed = false
    @State private var cloudDeleteSecondConfirmation = false
    @State private var diagnosticsConsent = false
    private var zones: [String] {
        TimeZone.knownTimeZoneIdentifiers.filter { timezoneSearch.isEmpty || $0.localizedCaseInsensitiveContains(timezoneSearch) }
    }
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                if let problem = model.problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red).accessibilityIdentifier("state.error")
                    }
                }
                planningSection
                notificationsSection
                calendarsSection
                syncSection
                privacySection
                diagnosticsSection
                archiveSection
                deletionSection
                aboutSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .background(MirrorPalette.canvas)
            .navigationTitle("설정")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: MirrorArchiveDocument(data: model.archiveData ?? Data()), contentType: .json, defaultFilename: model.exportFileName) { result in
                if case .failure = result { model.problem = "내보내기 파일을 저장하지 못했어요. 원본은 유지했어요." }
                model.archiveData = nil
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case let .success(url):
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                        Task { await model.previewImport(bytes) }
                    } catch { model.problem = "파일을 읽지 못했어요. 원본은 유지했어요." }
                case .failure: model.problem = "복원 파일을 선택하지 못했어요. 데이터는 바뀌지 않았어요."
                }
            }
            .confirmationDialog("이 기기의 원본·화면·알림·검색 자료를 지울까요? iCloud 자료는 지우지 않으며 동기화하면 다시 내려올 수 있어요.", isPresented: $model.showDeleteConfirmation, titleVisibility: .visible) {
                Button("이 기기에서만 지우기", role: .destructive) { deleteConfirmed = true }
                Button("취소", role: .cancel) {}
            }
            .alert("기기 데이터를 지우기", isPresented: $deleteConfirmed) {
                Button("기기 데이터 삭제", role: .destructive) { Task { await model.deleteLocalData() } }
                Button("취소", role: .cancel) {}
            } message: { Text("이 기기에서 복원하려면 내보낸 파일이 필요해요. 다른 기기와 iCloud는 삭제하지 않아요.") }
            .alert("개인 공간 전체 삭제", isPresented: $cloudDeleteFirstConfirmation) {
                Button("전체 삭제 안내 계속 보기", role: .destructive) { cloudDeleteSecondConfirmation = true }
                Button("취소", role: .cancel) {}
            } message: { Text("iCloud와 다른 기기의 작업까지 함께 지우는 기능은 아직 준비 중이에요. 이 안내를 확인해도 데이터를 지우지 않아요.") }
            .alert("개인 공간 전체 삭제 재확인", isPresented: $cloudDeleteSecondConfirmation) {
                Button("현재 지원 상태 확인", role: .destructive) { Task { await model.inspectCloudDeletion() } }
                Button("취소", role: .cancel) {}
            } message: { Text("현재 전체 삭제를 사용할 수 있는지 확인해요. 다른 기기에 남은 데이터까지 삭제됐다고 보장할 수 없어 지금은 삭제를 실행하지 않아요.") }
            .alert("전체 삭제 상태", isPresented: Binding(get: { model.cloudDeletionMessage != nil }, set: { if !$0 { model.cloudDeletionMessage = nil } })) {
                Button("확인", role: .cancel) { model.cloudDeletionMessage = nil }
            } message: { Text(model.cloudDeletionMessage ?? "") }
            .alert("iCloud 연결 중지", isPresented: $disableCloudConfirmed) {
                Button("기기 전용 공간으로 돌아가기") { Task { await model.disableCloudConnection() } }
                Button("취소", role: .cancel) {}
            } message: { Text("연결 전의 기기 전용 공간으로 돌아가요. iCloud 원본을 지우거나 현재 계정의 작업을 다른 로컬 공간으로 자동 복사하지 않아요. 필요하면 먼저 내보내세요.") }
            .alert("다른 개인 공간의 백업 복원", isPresented: $confirmImport) {
                Button("기기 작업을 교체하고 원래 공간 복원", role: .destructive) {
                    Task { await model.importArchive(confirmAccount: accountImportConfirmed, confirmWorkspace: true) }
                }
                Button("취소", role: .cancel) {}
            } message: { Text("이 기기의 현재 작업을 백업의 작업과 변경 이력으로 교체해요. 필요하다면 먼저 내보내세요. iCloud와 다른 기기의 작업은 바꾸지 않아요.") }
            .sheet(isPresented: $showLicenses) {
                NavigationStack {
                    ScrollView { Text(MirrorOpenSourceNotice.text).font(.body).textSelection(.enabled).padding() }
                        .navigationTitle("오픈소스 고지")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { showLicenses = false } } }
                }
            }
            .onChange(of: model.cloudPreview?.token) { _, _ in cloudMergeConfirmed = false }
        }.frame(minWidth: 300, idealWidth: 580, minHeight: 500)
    }

    private var planningSection: some View {
        @Bindable var model = model
        return Section {
            Picker("주간 정리 요일", selection: $model.preferences.weeklyWeekday) {
                ForEach(1...7, id: \.self) { value in
                    Text(["", "일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일"][value]).tag(value)
                }
            }.onChange(of: model.preferences.weeklyWeekday) { _, _ in model.savePreferences() }
            LabeledContent("계획 시간대", value: model.preferences.timeZoneID)
            DisclosureGroup("계획 시간대 바꾸기", isExpanded: $showTimeZonePicker) {
                TextField("시간대 검색", text: $timezoneSearch).autocorrectionDisabled()
                Picker("새 계획 시간대", selection: $selectedZone) {
                    Text("선택하세요").tag("")
                    ForEach(zones, id: \.self) { Text($0).tag($0) }
                }
                Button("계획 시간대 변경") { Task { await model.changeTimeZone(selectedZone) } }
                    .disabled(selectedZone.isEmpty || selectedZone == model.preferences.timeZoneID)
                settingNote("기존 날짜 문자열은 유지해요. 정리 세션을 새로 만들고 알림을 다시 예약해요.")
            }
        } header: {
            Label("정리와 날짜", systemImage: "calendar")
        } footer: {
            settingNote("계획 시간대는 기기 시간대를 따라 자동으로 바뀌지 않아요.")
        }
    }

    private var notificationsSection: some View {
        @Bindable var model = model
        return Section {
            Toggle("정리 알림", isOn: Binding(get: { model.preferences.reviewNotifications }, set: { enabled in
                Task { await model.enableNotifications(review: enabled, deadlines: model.preferences.deadlineNotifications) }
            }))
            Stepper("정리 시각: \(model.preferences.reviewHour)시", value: $model.preferences.reviewHour, in: 0...23)
            Stepper("정리 시각: \(model.preferences.reviewMinute)분", value: $model.preferences.reviewMinute, in: 0...59)
            Toggle("직접 설정한 실제 마감 알림", isOn: Binding(get: { model.preferences.deadlineNotifications }, set: { enabled in
                Task { await model.enableNotifications(review: model.preferences.reviewNotifications, deadlines: enabled) }
            }))
            if model.notificationOmittedCount > 0 {
                Label("예약 범위 밖의 알림 \(model.notificationOmittedCount)개는 앱을 다시 열 때 확인해요.", systemImage: "bell.badge")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Label("이 기기의 알림 · 선택 기능", systemImage: "bell")
        } footer: {
            settingNote("실제 마감 알림은 작업 상세에서 따로 고르세요. 알림은 집중 모드·기기 상태의 영향을 받아요. 정리 알림은 28일 범위로 보충하며 무기한 전달을 보장하지 않아요.")
        }
        .onChange(of: model.preferences.reviewHour) { _, _ in model.savePreferences() }
        .onChange(of: model.preferences.reviewMinute) { _, _ in model.savePreferences() }
    }

    private var calendarsSection: some View {
        Section {
            Button("캘린더 접근 선택") { Task { await model.requestCalendarAccess() } }
            ForEach(model.calendars) { calendar in
                Toggle(calendar.title, isOn: Binding(get: {
                    model.preferences.selectedCalendars.contains(calendar.id)
                }, set: { selected in
                    if selected { model.preferences.selectedCalendars.append(calendar.id) }
                    else { model.preferences.selectedCalendars.removeAll { $0 == calendar.id } }
                    model.savePreferences()
                }))
            }
            Button("캘린더 읽기 중지") {
                model.preferences.calendarEnabled = false
                model.preferences.selectedCalendars = []
                model.calendarEvents = []
                model.savePreferences()
            }
        } header: {
            Label("기존 캘린더 · 읽기 전용", systemImage: "calendar.badge.clock")
        } footer: {
            settingNote("허용·철회는 시스템 설정에서도 바꿀 수 있어요. 이 앱은 외부 약속을 쓰거나 옮기지 않아요.")
        }
    }

    private var syncSection: some View {
        Section {
            LabeledContent("저장 상태") {
                Text(model.storageLabel).accessibilityIdentifier("settings.syncState")
            }
            LabeledContent("iCloud") {
                Text(cloudStatusLabel(model.cloudSyncStatus)).accessibilityIdentifier("settings.cloudState")
            }
            Button("선택적으로 iCloud 연결 시작") { Task { await model.previewCloudConnection() } }
                .disabled(model.isSaving || model.cloudConnected)
            if let preview = model.cloudPreview {
                Text("이 기기의 원본 \(preview.localOperationCount)개 · 현재 수신된 계정 원본 \(preview.cloudOperationCount)개 · 중복 \(preview.duplicateCount)개")
                    .font(.callout)
                ForEach(preview.warnings, id: \.self) { settingNote($0) }
                Toggle("작업 제목과 변경 이력을 이 iCloud 개인 공간에 병합하는 데 동의", isOn: $cloudMergeConfirmed)
                Button("확인한 계정에 연결하고 병합") { Task { await model.confirmCloudConnection() } }
                    .disabled(!cloudMergeConfirmed || model.isSaving)
                Button("연결 취소") {
                    Task { await model.cancelCloudConnection() }
                    cloudMergeConfirmed = false
                }
            }
            Button("iCloud 연결 중지") { disableCloudConfirmed = true }
                .disabled(!model.cloudConnected && model.cloudSyncStatus != .accountTransitionRequired)
            if model.quarantinedCount > 0 {
                Label("검사할 원본 \(model.quarantinedCount)개가 격리되어 있어요. 조용히 덮어쓰지 않았어요.", systemImage: "exclamationmark.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("저장된 화면 다시 불러오기") { Task { await model.refresh() } }
        } header: {
            Label("동기화와 상태", systemImage: "externaldrive")
        } footer: {
            settingNote("선택적 iCloud 동기화는 Apple 계정과 이 앱의 서명 설정이 필요해요. 다른 모든 기기가 최신이라는 표시를 하지 않아요.")
        }
    }

    private var privacySection: some View {
        @Bindable var model = model
        return Section {
            Toggle("위젯·외부 화면에 제목 숨기기", isOn: $model.preferences.hideExternalTitles)
                .onChange(of: model.preferences.hideExternalTitles) { _, _ in model.savePreferences() }
            Toggle("Spotlight 검색에 작업 제목 표시", isOn: $model.preferences.spotlightEnabled)
                .onChange(of: model.preferences.spotlightEnabled) { _, _ in model.savePreferences() }
        } header: {
            Label("개인정보와 시스템 검색", systemImage: "hand.raised")
        } footer: {
            settingNote("제목 숨김과 잠금 인증은 별도예요. 민감한 제목·메모·캘린더 원문을 진단 로그에 넣지 않아요. Spotlight 노출을 끄면 앱 인덱스를 제거해요.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Toggle("익명 동작 횟수 요약 파일을 직접 공유하는 데 동의", isOn: $diagnosticsConsent)
            Button("동의한 진단 요약 내보내기") {
                Task {
                    await model.exportDiagnostics(consentGiven: diagnosticsConsent)
                    exporting = model.archiveData != nil
                }
            }.disabled(!diagnosticsConsent)
            Button("이 기기의 진단 기록 지우기") { Task { await model.eraseDiagnostics() } }
        } header: {
            Label("진단 기록", systemImage: "waveform.path")
        } footer: {
            settingNote("기본 진단 기록은 이 기기에 남아요. 요약에는 제목·메모·작업 ID·계정 문자열을 넣지 않아요. 파일 위치와 공유 대상은 직접 고르세요.")
        }
    }

    private var archiveSection: some View {
        Section {
            Button("JSON 내보내기") {
                Task { await model.exportArchive(); exporting = model.archiveData != nil }
            }
            Button("JSON 복원 파일 선택") { importing = true }
            if let preview = model.importPreview {
                Text(preview).font(.callout)
                if model.archivePreview?.requiresAccountConfirmation == true {
                    Toggle("다른 계정 출처의 원본 이력을 이 공간에 가져오는 데 동의", isOn: $accountImportConfirmed)
                }
                Button("검사한 파일 복원") {
                    if model.archivePreview?.requiresWorkspaceConfirmation == true { confirmImport = true }
                    else { Task { await model.importArchive(confirmAccount: accountImportConfirmed) } }
                }.disabled(model.archivePreview?.requiresAccountConfirmation == true && !accountImportConfirmed)
                Button("복원 취소") {
                    model.importData = nil
                    model.importPreview = nil
                    model.archivePreview = nil
                    accountImportConfirmed = false
                }
            }
        } header: {
            Label("내보내기와 복원", systemImage: "arrow.up.doc")
        } footer: {
            settingNote("작업 제목과 변경 이력이 포함된 평문 UTF-8 JSON이에요. 암호화된 백업이 아니며 파일의 공유 위치를 직접 고르세요.")
        }
    }

    private var deletionSection: some View {
        Section {
            Button("이 기기에서만 지우기", role: .destructive) { model.showDeleteConfirmation = true }
            Button("iCloud 포함 개인 공간 전체 삭제 안내", role: .destructive) { cloudDeleteFirstConfirmation = true }
        } header: {
            Label("데이터 삭제", systemImage: "trash")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                settingNote("휴지통 작업은 복구할 수 있어요. 기기 데이터 삭제와 iCloud 개인 공간 전체 삭제는 달라요.")
                settingNote("다른 기기와 iCloud에 남은 데이터까지 지우는 기능은 아직 준비 중이에요. 이 기기에서 지우기와 내보내기는 사용할 수 있어요.")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            Button("SwiftPieces와 오픈소스 고지") { showLicenses = true }
        } header: {
            Label("미러", systemImage: "info.circle")
        } footer: {
            settingNote("미러 · iPhone, iPad, Mac")
        }
    }

    private func settingNote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum MirrorOpenSourceNotice {
    static let text = """
    SwiftPieces — TaskRow, ExpandableText, StatusMorph
    https://github.com/Saivion/SwiftPieces
    Commit: 15e4a68ce09a58f7c93a8043f88fca9ea224af75

    MIT + Commons Clause License Condition v1.0

    Copyright (c) 2026 Saivion Hayes

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, and distribute the Software as part of
    an application, website, or product, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    Commons Clause Restriction

    You may use this Software, including for any commercial purpose, so long as
    you do not sell, sublicense, or redistribute the components themselves, whether
    alone, in a bundle, or as a ported version.

    No Warranty

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
