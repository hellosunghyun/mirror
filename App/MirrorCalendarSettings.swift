import MirrorData
import MirrorDomain
import MirrorSystem
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MirrorCalendarView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedDate = Date()
    @State private var weekly = false
    @State private var initialized = false
    private var localDate: LocalDate? {
        try? PlanningContext.capture(at: selectedDate, timeZoneID: model.preferences.timeZoneID,
                                     policyRevision: model.preferences.policyRevision).planningDay
    }
    private var days: [LocalDate] {
        guard let localDate else { return [] }
        if weekly, let week = try? localDate.mondayWeek() { return (0..<7).compactMap { try? week.startDate.addingDays($0) } }
        return [localDate]
    }
    var body: some View {
        List {
            Section {
                Picker("보기", selection: $weekly) { Text("일간").tag(false); Text("주간").tag(true) }.pickerStyle(.segmented)
                DatePicker("살펴볼 날짜", selection: $selectedDate, displayedComponents: .date)
                    .environment(\.timeZone, TimeZone(identifier: model.preferences.timeZoneID) ?? .gmt)
                    .accessibilityIdentifier("calendar.date")
                Text("할 일은 날짜 목록에 표시해요. 시간이 없는 일을 09:00 약속으로 만들지 않아요.").font(.caption)
            }
            ForEach(days, id: \.self) { date in
                Section(AppDate.label(date)) {
                    let tasks = model.tasks.filter { $0.status == .open && $0.plan.target == .day(date) }
                    if tasks.isEmpty { Text("이 날짜에 정한 일이 없어요.").foregroundStyle(.secondary) }
                    ForEach(tasks, id: \.taskID) { MirrorTaskRow(task: $0) }
                    let events = model.calendarEvents.filter { event in
                        guard let zone = TimeZone(identifier: model.preferences.timeZoneID),
                              let noon = AppDate.instant(date, zone: zone.identifier), let nextDay = try? date.addingDays(1),
                              let nextNoon = AppDate.instant(nextDay, zone: zone.identifier) else { return false }
                        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                        return event.end > calendar.startOfDay(for: noon) && event.start < calendar.startOfDay(for: nextNoon)
                    }
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(event.title, systemImage: "calendar")
                            if event.isAllDay { Text("종일 · 기존 약속").font(.caption) }
                            else { Text("\(timeLabel(event.start))–\(timeLabel(event.end)) · 기존 약속").font(.caption) }
                        }.accessibilityLabel("기존 약속, \(event.title), 읽기 전용")
                    }
                }
            }
            if let date = localDate, let week = try? date.mondayWeek() {
                Section("\(weekLabel(week)) · 요일 미정") {
                    let tasks = model.tasks.filter { $0.status == .open && $0.plan.target == .week(startDate: week.startDate, endExclusiveDate: week.endExclusiveDate) }
                    if tasks.isEmpty { Text("이 주의 요일 미정 작업이 없어요.").foregroundStyle(.secondary) }
                    ForEach(tasks, id: \.taskID) { MirrorTaskRow(task: $0) }
                }
            }
            Section("기존 캘린더 약속 · 선택 기능") {
                if let problem = model.calendarProblem { Text(problem).foregroundStyle(.secondary) }
                if model.preferences.calendarEnabled {
                    Text("약속은 읽기 전용이에요. 종일·겹친 일정으로 사용 가능한 시간을 단정하지 않아요.").font(.caption)
                    if model.preferences.selectedCalendars.isEmpty { Text("설정에서 읽을 캘린더를 선택해 주세요.") }
                    Button("일정 새로고침") { Task { await loadEvents() } }
                } else {
                    Button("기존 약속 보기 선택") { Task { await model.requestCalendarAccess(); await loadEvents() } }
                    Text("허용하지 않아도 할 일 날짜를 정할 수 있어요.").font(.caption)
                }
            }
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
                Section("정리와 날짜") {
                    Text("계획 시간대: \(model.preferences.timeZoneID)")
                    TextField("시간대 검색", text: $timezoneSearch)
                    Picker("새 계획 시간대", selection: $selectedZone) {
                        Text("선택하세요").tag("")
                        ForEach(zones, id: \.self) { Text($0).tag($0) }
                    }
                    Button("계획 시간대 변경") { Task { await model.changeTimeZone(selectedZone) } }
                        .disabled(selectedZone.isEmpty || selectedZone == model.preferences.timeZoneID)
                    Text("기존 날짜 문자열은 유지해요. 정리 세션을 새로 만들고 알림을 다시 예약해요. 기기 시간대를 따라 자동으로 바뀌지 않아요.").font(.caption)
                    Picker("주간 정리 요일", selection: $model.preferences.weeklyWeekday) {
                        ForEach(1...7, id: \.self) { value in Text(["", "일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일"][value]).tag(value) }
                    }.onChange(of: model.preferences.weeklyWeekday) { _, _ in model.savePreferences() }
                }
                Section("이 기기의 알림 · 선택 기능") {
                    Toggle("정리 알림", isOn: Binding(get: { model.preferences.reviewNotifications }, set: { enabled in
                        Task { await model.enableNotifications(review: enabled, deadlines: model.preferences.deadlineNotifications) }
                    }))
                    Stepper("정리 시각: \(model.preferences.reviewHour)시", value: $model.preferences.reviewHour, in: 0...23)
                    Stepper("정리 시각: \(model.preferences.reviewMinute)분", value: $model.preferences.reviewMinute, in: 0...59)
                    Toggle("직접 설정한 실제 마감 알림", isOn: Binding(get: { model.preferences.deadlineNotifications }, set: { enabled in
                        Task { await model.enableNotifications(review: model.preferences.reviewNotifications, deadlines: enabled) }
                    }))
                    Text("실제 마감 알림은 작업 상세에서 따로 고르세요. 알림은 집중 모드·기기 상태의 영향을 받아요. 정리 알림은 28일 범위로 보충하며 무기한 전달을 보장하지 않아요.").font(.caption)
                    if model.notificationOmittedCount > 0 { Text("예약 범위 밖의 알림 \(model.notificationOmittedCount)개는 앱을 다시 열 때 확인해요.") }
                }.onChange(of: model.preferences.reviewHour) { _, _ in model.savePreferences() }
                    .onChange(of: model.preferences.reviewMinute) { _, _ in model.savePreferences() }
                Section("기존 캘린더 · 읽기 전용") {
                    Button("캘린더 접근 선택") { Task { await model.requestCalendarAccess() } }
                    ForEach(model.calendars) { calendar in
                        Toggle(calendar.title, isOn: Binding(get: { model.preferences.selectedCalendars.contains(calendar.id) }, set: { selected in
                            if selected { model.preferences.selectedCalendars.append(calendar.id) }
                            else { model.preferences.selectedCalendars.removeAll { $0 == calendar.id } }
                            model.savePreferences()
                        }))
                    }
                    Button("캘린더 읽기 중지") { model.preferences.calendarEnabled = false; model.preferences.selectedCalendars = []; model.calendarEvents = []; model.savePreferences() }
                    Text("허용·철회는 시스템 설정에서도 바꿀 수 있어요. 이 앱은 외부 약속을 쓰거나 옮기지 않아요.").font(.caption)
                }
                Section("동기화와 상태") {
                    Text(model.storageLabel).accessibilityIdentifier("settings.syncState")
                    Text(cloudStatusLabel(model.cloudSyncStatus)).accessibilityIdentifier("settings.cloudState")
                    Button("선택적으로 iCloud 연결 시작") { Task { await model.previewCloudConnection() } }.disabled(model.isSaving || model.cloudConnected)
                    if let preview = model.cloudPreview {
                        Text("이 기기의 원본 \(preview.localOperationCount)개 · 현재 수신된 계정 원본 \(preview.cloudOperationCount)개 · 중복 \(preview.duplicateCount)개")
                        ForEach(preview.warnings, id: \.self) { Text($0).font(.caption) }
                        Toggle("작업 제목과 변경 이력을 이 iCloud 개인 공간에 병합하는 데 동의", isOn: $cloudMergeConfirmed)
                        Button("확인한 계정에 연결하고 병합") { Task { await model.confirmCloudConnection() } }.disabled(!cloudMergeConfirmed || model.isSaving)
                        Button("연결 취소") { Task { await model.cancelCloudConnection() }; cloudMergeConfirmed = false }
                    }
                    Button("iCloud 연결 중지") { disableCloudConfirmed = true }.disabled(!model.cloudConnected && model.cloudSyncStatus != .accountTransitionRequired)
                    Text("선택적 iCloud 동기화는 Apple 계정과 이 앱의 서명 설정이 필요해요. 다른 모든 기기가 최신이라는 표시를 하지 않아요.").font(.caption)
                    if model.quarantinedCount > 0 { Text("검사할 원본 \(model.quarantinedCount)개가 격리되어 있어요. 조용히 덮어쓰지 않았어요.") }
                    Button("저장된 화면 다시 불러오기") { Task { await model.refresh() } }
                }
                Section("개인정보와 시스템 검색") {
                    Toggle("위젯·외부 화면에 제목 숨기기", isOn: $model.preferences.hideExternalTitles)
                        .onChange(of: model.preferences.hideExternalTitles) { _, _ in model.savePreferences() }
                    Toggle("Spotlight 검색에 작업 제목 표시", isOn: $model.preferences.spotlightEnabled)
                        .onChange(of: model.preferences.spotlightEnabled) { _, _ in model.savePreferences() }
                    Text("제목 숨김과 잠금 인증은 별도예요. 민감한 제목·메모·캘린더 원문을 진단 로그에 넣지 않아요. Spotlight 노출을 끄면 앱 인덱스를 제거해요.").font(.caption)
                    Toggle("익명 동작 횟수 요약 파일을 직접 공유하는 데 동의", isOn: $diagnosticsConsent)
                    Button("동의한 진단 요약 내보내기") { Task { await model.exportDiagnostics(consentGiven: diagnosticsConsent); exporting = model.archiveData != nil } }.disabled(!diagnosticsConsent)
                    Button("이 기기의 진단 기록 지우기") { Task { await model.eraseDiagnostics() } }
                    Text("기본 진단 기록은 이 기기에 남아요. 요약에는 제목·메모·작업 ID·계정 문자열을 넣지 않아요. 파일 위치와 공유 대상은 직접 고르세요.").font(.caption)
                }
                Section("내보내기와 복원") {
                    Text("작업 제목과 변경 이력이 포함된 평문 UTF-8 JSON이에요. 암호화된 백업이 아니며 파일의 공유 위치를 직접 고르세요.").font(.caption)
                    Button("JSON 내보내기") { Task { await model.exportArchive(); exporting = model.archiveData != nil } }
                    Button("JSON 복원 파일 선택") { importing = true }
                    if let preview = model.importPreview {
                        Text(preview)
                        if model.archivePreview?.requiresAccountConfirmation == true {
                            Toggle("다른 계정 출처의 원본 이력을 이 공간에 가져오는 데 동의", isOn: $accountImportConfirmed)
                        }
                        Button("검사한 파일 복원") {
                            if model.archivePreview?.requiresWorkspaceConfirmation == true { confirmImport = true }
                            else { Task { await model.importArchive(confirmAccount: accountImportConfirmed) } }
                        }.disabled(model.archivePreview?.requiresAccountConfirmation == true && !accountImportConfirmed)
                        Button("복원 취소") { model.importData = nil; model.importPreview = nil; model.archivePreview = nil; accountImportConfirmed = false }
                    }
                }
                Section("데이터 삭제") {
                    Text("휴지통 작업은 복구할 수 있어요. 기기 데이터 삭제와 iCloud 개인 공간 전체 삭제는 달라요.").font(.caption)
                    Button("이 기기에서만 지우기", role: .destructive) { model.showDeleteConfirmation = true }
                    Button("iCloud 포함 개인 공간 전체 삭제 안내", role: .destructive) { cloudDeleteFirstConfirmation = true }
                    Text("전체 삭제는 실제 CloudKit 공간·권위 있는 세대와 오프라인 기기의 재연결 검증이 필요해요. 아직 모든 기기의 완전 삭제로 안내하지 않아요.").font(.caption)
                }
                Section("미러") {
                    Button("SwiftPieces와 오픈소스 고지") { showLicenses = true }
                    Text("미러 · iPhone, iPad, Mac").font(.caption)
                }
                if let problem = model.problem { Text(problem).foregroundStyle(.red).accessibilityIdentifier("state.error") }
            }
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
                        guard bytes.count <= 32 * 1024 * 1024 else { model.problem = "복원 파일은 32MB 이하로 선택해 주세요."; return }
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
                Button("전체 삭제 조건 확인", role: .destructive) { cloudDeleteSecondConfirmation = true }
                Button("취소", role: .cancel) {}
            } message: { Text("iCloud를 포함한 개인 공간의 원본 이력 삭제는 다른 기기와 복원 파일에도 영향을 줘요. 필요하면 먼저 내보내세요.") }
            .alert("개인 공간 전체 삭제 재확인", isPresented: $cloudDeleteSecondConfirmation) {
                Button("삭제 가능 조건 검사", role: .destructive) { Task { await model.inspectCloudDeletion() } }
                Button("취소", role: .cancel) {}
            } message: { Text("인터넷·계정·개인 공간 세대와 오프라인 기기의 재연결 검증이 필요해요. 조건을 확인한 뒤 실제 삭제 결과를 구분해 안내해요.") }
            .alert("전체 삭제 상태", isPresented: Binding(get: { model.cloudDeletionMessage != nil }, set: { if !$0 { model.cloudDeletionMessage = nil } })) {
                Button("확인", role: .cancel) { model.cloudDeletionMessage = nil }
            } message: { Text(model.cloudDeletionMessage ?? "") }
            .alert("iCloud 연결 중지", isPresented: $disableCloudConfirmed) {
                Button("기기 전용 공간으로 돌아가기") { Task { await model.disableCloudConnection() } }
                Button("취소", role: .cancel) {}
            } message: { Text("연결 전의 기기 전용 공간으로 돌아가요. iCloud 원본을 지우거나 현재 계정의 작업을 다른 로컬 공간으로 자동 복사하지 않아요. 필요하면 먼저 내보내세요.") }
            .alert("다른 세대의 개인 공간 복원", isPresented: $confirmImport) {
                Button("기기 작업을 교체하고 원래 공간 복원", role: .destructive) {
                    Task { await model.importArchive(confirmAccount: accountImportConfirmed, confirmWorkspace: true) }
                }
                Button("취소", role: .cancel) {}
            } message: { Text("이 기기의 현재 작업을 교체해요. 필요하다면 먼저 내보내세요. 원본 기록의 ID와 이력은 그대로 보존하며 iCloud 전체 삭제나 다른 기기 변경을 뜻하지 않아요.") }
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
