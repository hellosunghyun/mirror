import MirrorDesign
import MirrorDomain
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MirrorTodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showCompleted = false
    @State private var showReviewSummary = false
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    if let context = model.context {
                        Text(AppDate.label(context.planningDay))
                            .font(.subheadline).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                    }
                    MirrorActionGroup {
                        Button { model.beginReview() } label: {
                            Text(model.pendingTasks.isEmpty ? "오늘 정리" : "오늘 정리 · \(model.pendingTasks.count)개")
                                .foregroundStyle(MirrorPalette.onAccent)
                        }
                            .buttonStyle(.borderedProminent).controlSize(.regular)
                            .frame(minHeight: 44)
                            .accessibilityLabel("오늘 정리, 정하지 않은 일 \(model.pendingTasks.count)개")
                            .accessibilityIdentifier("today.review")
                        Menu {
                            if let review = model.review, !review.cards.isEmpty {
                                Button("이어서 정리") { model.beginReview(mode: .manualResume) }
                                    .accessibilityIdentifier("today.resumeReview")
                            }
                            Button("오늘 다시 정리") { model.beginReview(mode: .manualTodayOverride) }
                                .accessibilityIdentifier("today.reviewAgain")
                            if model.reviewSummary != nil, !model.pendingTasks.isEmpty {
                                Button("새로 넣은 일도 정리") { model.beginReview(mode: .manualResume, includeNewInputs: true) }
                            }
                        } label: { Label("정리 옵션", systemImage: "ellipsis").frame(minHeight: 44) }
                            #if os(macOS)
                            .menuStyle(.borderlessButton)
                            #endif
                    }
                }.padding(.vertical, 8)
            }
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            if !model.deadlines.isEmpty {
                Section("실제 마감 안내 · 계획과 별개") {
                    ForEach(model.deadlines, id: \.taskID) { task in
                        Button { model.selectedTaskID = task.taskID } label: {
                            Label { VStack(alignment: .leading) { Text(task.title); Text(deadlineLabel(task.deadline, context: model.context)).font(.caption) } } icon: { Image(systemName: "flag") }
                        }.buttonStyle(.plain).padding(.vertical, 4)
                    }
                }
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            Section("오늘에 남긴 일") {
                if model.todayTasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "sun.max")
                            .font(.largeTitle).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("오늘에 남긴 일이 없어요")
                            .font(.headline).accessibilityAddTraits(.isHeader)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("today.empty.title")
                        Text(model.pendingTasks.isEmpty ? "직접 날짜를 정한 일만 여기에 보여요." : "정하지 않은 일은 보관함에 있어요.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("today.empty.description")
                        Button("일단 넣기") { model.openCapture() }
                            .buttonStyle(.borderless).frame(minHeight: 44)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
                ForEach(model.todayTasks, id: \.taskID) {
                    MirrorTaskRow(task: $0).listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            }
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            if let summary = model.reviewSummary {
                Section {
                    DisclosureGroup("이번 정리 결과", isExpanded: $showReviewSummary) {
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            if !model.completedToday.isEmpty {
                Section {
                    DisclosureGroup("완료한 일 \(model.completedToday.count)개", isExpanded: $showCompleted) {
                        ForEach(model.completedToday, id: \.taskID) { MirrorTaskRow(task: $0) }
                    }.foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .accessibilityIdentifier("today.list")
        .navigationTitle("오늘")
        .onChange(of: model.showReview) { _, isPresented in
            if !isPresented { showReviewSummary = false }
        }
    }
}

@MainActor
struct MirrorTaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskProjection
    var onOpen: (() -> Void)? = nil
    var body: some View {
        let displayedContext = model.context
        HStack(spacing: 8) {
            TaskRow(task.title, status: Binding(get: { task.status == .completed ? .completed : .open }, set: { value in
                if value != .snoozed { Task { await model.setCompleted(task, completed: value == .completed) } }
            }), due: planLabel(task.plan.target), style: rowStyle, onTap: openDetail, snoozeLabel: "내일로 미루기",
                    onSnooze: tomorrowAction(context: displayedContext), onDelete: { Task { await model.trash(task) } })
                .background {
                    if model.selectedTaskID == task.taskID {
                        RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
                    }
                }
                .disabled(model.isSaving || model.projectionPending || task.status == .deleted)
                .accessibilityIdentifier("task.row.\(task.taskID.uuidString)")
                .contextMenu {
                    Button("상세 열기", action: openDetail)
                    Button(task.status == .completed ? "다시 열기" : "완료") { Task { await model.setCompleted(task, completed: task.status != .completed) } }
                    if task.status == .open, let displayedContext {
                        Button("내일로 미루기") { Task { await model.postponeToTomorrow(task, context: displayedContext) } }
                    }
                    Button("날짜 바꾸기") { model.makePicker(taskIDs: [task.taskID]) }
                    Button("당분간 보관") { Task { await model.park(task) } }
                    Button("휴지통으로 이동", role: .destructive) { Task { await model.trash(task) } }
                }
            if task.status == .open {
                Button { model.makePicker(taskIDs: [task.taskID]) } label: {
                    Text("미루기").font(.callout)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 60, minHeight: 44)
                        .background(MirrorPalette.accent.opacity(0.08), in: Capsule())
                }
                    .buttonStyle(.borderless)
                    .disabled(model.isSaving || model.projectionPending)
                    .accessibilityLabel("\(task.title), 미루기, 날짜 선택")
                    .accessibilityIdentifier("task.postpone.\(task.taskID.uuidString)")
            }
        }
    }
    private var rowStyle: TaskRow.Style {
        var style = TaskRow.Style.standard
        style.surface = .clear
        style.text = .primary
        style.muted = .secondary
        style.cornerRadius = 10
        return style
    }
    private func tomorrowAction(context: PlanningContext?) -> (() -> Void)? {
        guard task.status == .open, let context else { return nil }
        return { Task { await model.postponeToTomorrow(task, context: context) } }
    }
    private func openDetail() {
        if let onOpen { onOpen() }
        else { model.selectedTaskID = task.taskID }
    }
}

@MainActor
struct MirrorCaptureView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var sourceURL = ""
    @State private var more = false
    @State private var splitPreview = false
    @State private var requestToken = UUID().uuidString
    @State private var pendingLine: String?
    @State private var pendingSingle = false
    @State private var captureFlowStarted = false
    @State private var showSavedFeedback = false
    private enum InputField: Hashable { case title, note, url }
    @FocusState private var focusedField: InputField?
    private var lines: [String] { title.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("할 일 제목", text: $title, prompt: Text("할 일 제목").foregroundColor(MirrorPalette.inputPrompt), axis: .vertical)
                        .font(.title3)
                        .textFieldStyle(.plain)
                        .lineLimit(1...8).focused($focusedField, equals: .title)
                        .disabled(model.isSaving || model.projectionPending)
                        .accessibilityIdentifier("capture.title")
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MirrorPalette.card, in: RoundedRectangle(cornerRadius: 12))
                    DisclosureGroup("메모와 원문 링크", isExpanded: $more) {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("메모", text: $note, axis: .vertical).lineLimit(3...10).focused($focusedField, equals: .note).disabled(model.isSaving || model.projectionPending).accessibilityIdentifier("capture.note")
                            TextField("https:// 원문 링크", text: $sourceURL).focused($focusedField, equals: .url).disabled(model.isSaving || model.projectionPending).accessibilityIdentifier("capture.url")
                            Text("링크를 저장해도 웹 내용을 자동으로 가져오지 않아요.").font(.caption).foregroundStyle(.secondary)
                        }.textFieldStyle(.roundedBorder).padding(.top, 12)
                    }
                    .padding(16)
                    .background(MirrorPalette.card, in: RoundedRectangle(cornerRadius: 12))
                    if lines.count > 1 {
                        Button("줄마다 나누기 · \(lines.count)개 미리 보기") { splitPreview = true }.disabled(model.isSaving || model.projectionPending)
                            .buttonStyle(.borderless).frame(minHeight: 44)
                    }
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(MirrorPalette.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) { captureActions }
            .navigationTitle("일단 넣기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { model.clearCaptureInputProblem(); focusedField = nil; dismiss() }.accessibilityIdentifier("capture.close") } }
            .onAppear { model.clearCaptureInputProblem(); focusedField = .title; startCaptureFlow() }
            .onChange(of: title) { _, value in
                if !value.isEmpty { showSavedFeedback = false; startCaptureFlow() }
            }
            .onChange(of: note) { _, value in if !value.isEmpty { showSavedFeedback = false } }
            .onChange(of: sourceURL) { _, value in if !value.isEmpty { showSavedFeedback = false } }
            .onChange(of: more) { _, expanded in
                if !expanded, focusedField == .note || focusedField == .url { focusedField = .title }
            }
            .onChange(of: focusedField) { _, focused in model.isTextEditing = focused != nil }
            .onDisappear { model.isTextEditing = false; model.clearCaptureInputProblem() }
            .onChange(of: model.lastCaptureCommittedToken) { _, token in
                guard token == requestToken else { return }
                if pendingSingle {
                    title = ""; note = ""; sourceURL = ""; pendingSingle = false
                    requestToken = UUID().uuidString; captureFlowStarted = false
                    finishSavedCapture()
                } else if let pendingLine {
                    var remaining = title.components(separatedBy: .newlines)
                    if remaining.first == pendingLine { remaining.removeFirst(); title = remaining.joined(separator: "\n") }
                    self.pendingLine = nil; requestToken = UUID().uuidString
                    if remaining.isEmpty { finishSavedCapture() }
                }
            }
            .sheet(isPresented: $splitPreview) {
                NavigationStack {
                    List {
                        Text("각 줄이 별개의 새 작업으로 저장돼요. 저장되지 않은 줄은 입력에 남겨요.")
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line) }
                        Button("\(lines.count)개를 각각 저장") {
                            Task {
                                var remaining = lines
                                for line in lines {
                                    requestToken = UUID().uuidString
                                    guard await model.capture(title: line, note: note, sourceURL: sourceURL, requestToken: requestToken) else {
                                        if model.projectionPending { pendingLine = line }
                                        break
                                    }
                                    remaining.removeFirst()
                                }
                                title = remaining.joined(separator: "\n")
                                splitPreview = false
                                if remaining.isEmpty { finishSavedCapture() }
                                else { focusedField = .title }
                            }
                        }.disabled(model.isSaving || model.projectionPending)
                    }.navigationTitle("줄마다 나누기")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { splitPreview = false } } }
                }.tint(MirrorPalette.accent)
            }
        }
        .tint(MirrorPalette.accent)
        .frame(idealWidth: 460, idealHeight: 340)
        .presentationSizing(.fitted)
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 280)
        #endif
    }
    private var captureActions: some View {
        VStack(spacing: 8) {
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(problem).accessibilityIdentifier("state.error")
            }
            if showSavedFeedback, model.problem == nil, !model.projectionPending, !model.isSaving {
                Text("보관함에 넣었어요.").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("capture.feedback")
            }
            Button { save() } label: {
                Text(model.isSaving ? "저장 중…" : lines.count > 1 ? "한 개로 저장" : "보관함에 넣기")
                    .foregroundStyle(MirrorPalette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSaving || model.projectionPending)
                .accessibilityIdentifier("capture.save")
                .keyboardShortcut(.return, modifiers: .command)
                #if os(macOS)
                .frame(maxWidth: 200)
                #endif
            if model.projectionPending {
                Button("저장 결과 다시 확인") { Task { await model.retry() } }
                    .frame(minHeight: 44)
            }
        }.padding(12).frame(maxWidth: .infinity).background(.bar)
    }
    private func save() {
        showSavedFeedback = false
        startCaptureFlow()
        Task {
            requestToken = UUID().uuidString
            if await model.capture(title: title, note: note, sourceURL: sourceURL, requestToken: requestToken) {
                title = ""; note = ""; sourceURL = ""
                requestToken = UUID().uuidString
                captureFlowStarted = false
                finishSavedCapture()
            } else if model.projectionPending { pendingSingle = true }
        }
    }
    private func finishSavedCapture() {
        // 원본 저장과 projection 갱신을 확인한 성공 경로에서만 단일 입력을 닫는다.
        let single = model.captureIsSingle
        if !single { showSavedFeedback = true }
        focusedField = single ? nil : .title
        model.finishCapture()
        if single { dismiss() }
    }
    private func startCaptureFlow() {
        guard !captureFlowStarted else { return }
        captureFlowStarted = true
        Task { await model.recordCaptureFlowStarted() }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case inbox, past, future, parked, completed, trash, all
    var id: String { rawValue }
    var label: String {
        switch self { case .inbox: "정하지 않은 일"; case .past: "지난 계획"; case .future: "미래 계획"; case .parked: "당분간 보관"; case .completed: "완료 기록"; case .trash: "휴지통"; case .all: "전체" }
    }
}

@MainActor
struct MirrorLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: LibraryFilter = .inbox
    @State private var selecting = false
    @FocusState private var searchFocused: Bool
    private var filtered: [TaskProjection] {
        model.tasks.filter { task in
            let matchesSearch = model.search.isEmpty || task.title.localizedStandardContains(model.search)
                || task.content.note?.localizedStandardContains(model.search) == true
                || task.content.sourceURL?.localizedStandardContains(model.search) == true
            guard matchesSearch else { return false }
            if !model.search.isEmpty, filter == .inbox { return task.status != .deleted }
            switch filter {
            case .inbox: return task.status == .open && task.plan.target == .unassigned
            case .past:
                guard task.status == .open, let day = model.context?.planningDay else { return false }
                switch task.plan.target { case let .day(date): return date < day; case let .week(_, end): return end <= day; default: return false }
            case .future:
                guard task.status == .open, let day = model.context?.planningDay else { return false }
                switch task.plan.target { case let .day(date): return date > day; case let .week(start, _): return start > day; default: return false }
            case .parked: return task.status == .open && task.plan.target == .parked
            case .completed: return task.status == .completed
            case .trash: return task.status == .deleted
            case .all: return true
            }
        }
    }
    var body: some View {
        @Bindable var model = model
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("미래·완료·보관까지 검색", text: $model.search)
                            .textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("library.search")
                            .onSubmit { searchFocused = false; model.isTextEditing = false }
                    }
                    .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    MirrorActionGroup {
                        Picker("목록", selection: $filter) {
                            ForEach(LibraryFilter.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.menu).labelsHidden().accessibilityLabel("목록").frame(minHeight: 44)
                        Button(selecting ? "선택 마치기" : "선택") { selecting.toggle() }
                            .buttonStyle(.borderless).frame(minHeight: 44)
                            .accessibilityLabel(selecting ? "여러 개 선택 마치기" : "여러 개 선택")
                    }
                    if selecting {
                        Text("같은 날짜로 최대 20개를 한 번에 배치해요. 하나라도 오래된 상태이면 전체를 저장하지 않아요.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("선택한 \(model.selectedTaskIDs.count)개 날짜 배치") { model.makePicker(taskIDs: Array(model.selectedTaskIDs)) }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                            .disabled(model.selectedTaskIDs.isEmpty || model.selectedTaskIDs.count > 20)
                            .accessibilityIdentifier("library.batchPlan")
                    }
                }.padding(.vertical, 4)
            }
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            Section {
                if filtered.isEmpty { ContentUnavailableView("여기에 표시할 일이 없어요", systemImage: "tray", description: Text("목록을 바꾸거나 새로운 일을 넣을 수 있어요.")) }
                ForEach(filtered, id: \.taskID) { task in
                    HStack {
                        if selecting, task.status == .open {
                            Button {
                                if model.selectedTaskIDs.contains(task.taskID) { model.selectedTaskIDs.remove(task.taskID) }
                                else if model.selectedTaskIDs.count < 20 { model.selectedTaskIDs.insert(task.taskID) }
                                else { model.problem = "한 번에 최대 20개를 선택해 주세요." }
                            } label: { Image(systemName: model.selectedTaskIDs.contains(task.taskID) ? "checkmark.square" : "square") }
                                .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
                                .accessibilityLabel("\(task.title), 배치 대상 선택")
                        }
                        if task.status == .deleted {
                            Button { openDetail(task) } label: {
                                VStack(alignment: .leading) { Text(task.title); Text("휴지통 · \(planLabel(task.plan.target))").font(.caption) }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button("복구") { Task { await model.restore(task) } }.disabled(model.isSaving)
                        } else { MirrorTaskRow(task: task, onOpen: { openDetail(task) }) }
                    }.listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            } header: {
                Text(model.search.isEmpty ? filter.label : "검색 결과")
                    .accessibilityIdentifier("library.resultsTitle")
            }
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .navigationTitle("보관함")
        .accessibilityIdentifier("library.list")
        .onChange(of: model.searchRequested, initial: true) { _, requested in if requested { searchFocused = true; model.searchRequested = false } }
        .onChange(of: searchFocused) { _, focused in model.isTextEditing = focused }
        .onDisappear { model.isTextEditing = false }
    }
    private func openDetail(_ task: TaskProjection) {
        searchFocused = false
        model.isTextEditing = false
        model.selectedTaskID = task.taskID
    }
}

@MainActor
struct MirrorReviewView: View {
    @Environment(AppModel.self) private var model
    @AccessibilityFocusState private var cardFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var exposureID = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let session = model.review {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.isWeekly ? "이번 주에 할 일인가요?" : "오늘 할 일인가요?")
                                    .font(.title2.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)
                                Text(session.isWeekly ? "주간 정리 · \(weekLabel(try? session.context.planningDay.mondayWeek()))" : "일간 정리 · \(AppDate.label(session.context.planningDay))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let task = model.currentReviewTask, let card = model.currentCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(task.title)
                                        .font(.title3.weight(.semibold))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityFocused($cardFocused)
                                        .accessibilityIdentifier("review.card")
                                    Button { model.selectedTaskID = task.taskID } label: {
                                        Label("작업 상세", systemImage: "info.circle")
                                            .labelStyle(.iconOnly)
                                            .font(.title3)
                                            .frame(minWidth: 44, minHeight: 44)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("review.detail")
                                }
                                if task.plan.target != .unassigned {
                                    Text(planLabel(task.plan.target)).font(.caption).foregroundStyle(.secondary)
                                }
                                if task.deadline != nil {
                                    Label("실제 마감: \(deadlineLabel(task.deadline, context: model.context))", systemImage: "flag")
                                        .font(.callout)
                                }
                                if let note = task.content.note, !note.isEmpty {
                                    ExpandableText(note, lineLimit: 1).font(.callout).foregroundStyle(.secondary)
                                }
                                if task.content.sourceURL != nil {
                                    Label("원문 링크가 있어요", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(reduceTransparency ? AnyShapeStyle(MirrorPalette.surface) : AnyShapeStyle(Material.regular), in: RoundedRectangle(cornerRadius: 18))

                            if let session = model.review, let destinations = try? session.context.destinations() {
                                VStack(spacing: 12) {
                                    immediateChoices(destinations, card: card, session: session)
                                    laterChoices(destinations, card: card, session: session)
                                    #if os(macOS)
                                    Text("1 오늘 · 2 내일 · 3 이번 주 · 4 다음 주 · 5 다른 날")
                                        .font(.caption).foregroundStyle(.secondary)
                                    #endif
                                }
                            }
                        } else {
                            ContentUnavailableView("지금 정리할 카드가 없어요", systemImage: "tray", description: Text("오늘 목록으로 돌아갈 수 있어요."))
                        }
                        reviewFeedback
                    }
                    .padding(20)
                    .frame(maxWidth: 580, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
                reviewFooter
            }
            .navigationTitle("정리")
            .onChange(of: model.currentCard?.id, initial: true) { _, _ in
                cardFocused = false
                Task { @MainActor in await Task.yield(); cardFocused = true }
            }
            .onChange(of: model.feedback) { _, message in
                if let message { AccessibilityNotification.Announcement(message).post() }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.currentCard?.id)
            .sheet(item: Binding(get: { model.selectedTaskID == nil ? model.picker : nil }, set: { if $0 == nil { model.picker = nil } })) { MirrorPlanPicker(request: $0) }
            .sheet(item: Binding(get: { model.showReview ? model.selectedTaskID.map(MirrorDetailRequest.init(id:)) : nil }, set: { if $0 == nil, model.showReview { model.selectedTaskID = nil } })) { detail in
                NavigationStack {
                    if let task = model.tasks.first(where: { $0.taskID == detail.id }) { MirrorTaskDetail(task: task) }
                }
            }
            .modifier(MirrorDeadlineConfirmation(enabled: model.picker == nil && model.selectedTaskID == nil))
        }
        .tint(MirrorPalette.accent)
        .disabled(model.isSaving)
        .frame(minWidth: 300, idealWidth: 580, minHeight: 460)
        #if os(macOS)
        .frame(idealHeight: 640)
        #endif
        .onAppear { model.setReviewVisible(exposureID, visible: true) }
        .onDisappear { model.setReviewVisible(exposureID, visible: false) }
    }

    @ViewBuilder private func immediateChoices(_ destinations: DateDestinations, card: ReviewCard, session: AppReviewSession) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                todayButton(destinations.today, card: card, session: session)
                tomorrowButton(destinations.tomorrow, card: card, session: session)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    todayButton(destinations.today, card: card, session: session)
                    tomorrowButton(destinations.tomorrow, card: card, session: session)
                }
                VStack(spacing: 10) {
                    todayButton(destinations.today, card: card, session: session)
                    tomorrowButton(destinations.tomorrow, card: card, session: session)
                }
            }
        }
    }

    @ViewBuilder private func laterChoices(_ destinations: DateDestinations, card: ReviewCard, session: AppReviewSession) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                thisWeekButton(destinations.thisWeek, card: card, session: session)
                nextWeekButton(destinations.nextWeek, card: card, session: session)
                otherDayButton(card: card, session: session)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    thisWeekButton(destinations.thisWeek, card: card, session: session)
                    nextWeekButton(destinations.nextWeek, card: card, session: session)
                    otherDayButton(card: card, session: session)
                }
                VStack(spacing: 8) {
                    thisWeekButton(destinations.thisWeek, card: card, session: session)
                    nextWeekButton(destinations.nextWeek, card: card, session: session)
                    otherDayButton(card: card, session: session)
                }
            }
        }
    }

    private func todayButton(_ day: LocalDate, card: ReviewCard, session: AppReviewSession) -> some View {
        Button { Task { await model.decide(.day(day), card: card, session: session) } } label: {
            Text("오늘").foregroundStyle(MirrorPalette.onAccent)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("오늘, \(AppDate.label(day))에 배치, 완료 아님").accessibilityIdentifier("review.today")
        .keyboardShortcut("1", modifiers: []).disabled(model.isTextEditing)
    }

    private func tomorrowButton(_ day: LocalDate, card: ReviewCard, session: AppReviewSession) -> some View {
        Button { Task { await model.decide(.day(day), card: card, session: session) } } label: {
            Text("내일").fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("내일, \(AppDate.label(day))에 배치").accessibilityIdentifier("review.tomorrow")
        .keyboardShortcut("2", modifiers: []).disabled(model.isTextEditing)
    }

    private func thisWeekButton(_ week: WeekRange, card: ReviewCard, session: AppReviewSession) -> some View {
        Button { model.makePicker(taskIDs: [card.taskID], week: week, reviewCard: card, reviewSession: session) } label: {
            Text("이번 주").font(.callout.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("3", modifiers: []).disabled(model.isTextEditing)
        .accessibilityLabel("이번 주, \(weekLabel(week)), 날짜 선택").accessibilityIdentifier("review.thisWeek")
        .help("이번 주 날짜 선택 · 키보드 3")
    }

    private func nextWeekButton(_ week: WeekRange, card: ReviewCard, session: AppReviewSession) -> some View {
        Button { model.makePicker(taskIDs: [card.taskID], week: week, reviewCard: card, reviewSession: session) } label: {
            Text("다음 주").font(.callout.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("4", modifiers: []).disabled(model.isTextEditing)
        .accessibilityLabel("다음 주, \(weekLabel(week)), 날짜 선택").accessibilityIdentifier("review.nextWeek")
        .help("다음 주 날짜 선택 · 키보드 4")
    }

    private func otherDayButton(card: ReviewCard, session: AppReviewSession) -> some View {
        Button { model.makePicker(taskIDs: [card.taskID], reviewCard: card, reviewSession: session) } label: {
            Text("다른 날").font(.callout.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("5", modifiers: []).disabled(model.isTextEditing)
        .accessibilityLabel("다른 날, 달력에서 날짜 선택").accessibilityIdentifier("review.other")
        .help("달력에서 날짜 선택 · 키보드 5")
    }

    @ViewBuilder private var reviewFeedback: some View {
        if model.feedback != nil || model.lastUndo != nil {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                if let feedback = model.feedback {
                    Text(feedback).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("state.feedback")
                }
                if model.lastUndo != nil {
                    Button("되돌리기") { Task { await model.undo() } }
                        .frame(minHeight: 44)
                        .accessibilityLabel("직전 결정 되돌리기")
                        .accessibilityIdentifier("task.undo")
                }
            }
        }
        if let problem = model.problem {
            VStack(alignment: .leading, spacing: 8) {
                Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(problem).accessibilityIdentifier("state.error")
                Button("최신 상태 확인") { Task { await model.refreshReviewCard() } }
                    .frame(minHeight: 44).accessibilityIdentifier("state.retry")
            }
        }
        if model.projectionPending {
            Button("저장 결과 다시 확인") { Task { await model.retry() } }.frame(minHeight: 44)
        }
    }

    private var reviewFooter: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            if let session = model.review {
                Text("이번에 정한 \(session.decidedToday + session.decidedElsewhere)개")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { Task { await model.finishReview() } } label: {
                HStack {
                    if model.isSaving { ProgressView().controlSize(.small) }
                    Text(model.isSaving ? "저장 중…" : "오늘은 여기까지")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 44)
            }
            .accessibilityLabel("오늘은 여기까지")
            .accessibilityValue(model.isSaving ? "저장 중, 잠시 기다려 주세요" : "정리를 마치고 오늘 목록 보기")
            .accessibilityIdentifier("review.finish").disabled(model.isSaving)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .frame(maxWidth: 580)
        .frame(maxWidth: .infinity)
        .background(reduceTransparency ? AnyShapeStyle(MirrorPalette.surface) : AnyShapeStyle(Material.bar))
    }
}

@MainActor
struct MirrorPlanPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PlanPickerRequest
    @State private var monthAnchor: LocalDate?
    @State private var useWeek = false
    @State private var showDates = false
    private var usesQuickChoices: Bool { request.review == nil && request.widgetState == nil }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(request.taskIDs, id: \.self) { id in
                        Text(model.tasks.first { $0.taskID == id }?.title ?? "작업을 찾을 수 없어요")
                            .accessibilityIdentifier("plan.task.\(id.uuidString)")
                    }
                } footer: {
                    Text("계획 날짜를 바꿔도 실제 마감은 바뀌지 않아요.")
                }
                if let week = request.week {
                    Section(weekLabel(week)) {
                        ForEach(0..<7) { offset in
                            if let date = try? week.startDate.addingDays(offset) {
                                Button { choose(.day(date)) } label: {
                                    Text(AppDate.label(date)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                    .buttonStyle(.borderless)
                                    .disabled(date < request.displayedContext.planningDay)
                                    .accessibilityLabel("\(AppDate.label(date)), \(date < request.displayedContext.planningDay ? "지나간 날짜라 선택할 수 없음" : "이 날짜로 배치")")
                                    .accessibilityIdentifier("plan.day.\(date.iso8601)")
                            }
                        }
                        Button { choose(.week(startDate: week.startDate, endExclusiveDate: week.endExclusiveDate)) } label: {
                            Text("요일은 나중에 정하기").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("plan.weekOnly")
                    }
                } else {
                    if usesQuickChoices {
                        Section("빠르게 정하기") {
                            MirrorActionGroup {
                                Button { choose(.day(request.displayedContext.planningDay)) } label: {
                                    Text("오늘").frame(maxWidth: .infinity, minHeight: 44)
                                }
                                    .accessibilityIdentifier("plan.today")
                                if let tomorrow = try? request.displayedContext.planningDay.addingDays(1) {
                                    Button { choose(.day(tomorrow)) } label: {
                                        Text("내일").frame(maxWidth: .infinity, minHeight: 44)
                                    }
                                        .accessibilityIdentifier("plan.tomorrow")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Section {
                        DisclosureGroup("다른 날짜", isExpanded: $showDates) {
                            Toggle("선택한 주만 정하기", isOn: $useWeek)
                            MirrorMonthGrid(anchor: Binding(get: { monthAnchor ?? request.displayedContext.planningDay }, set: { monthAnchor = $0 }), minimum: request.displayedContext.planningDay) { date in
                                if useWeek, let week = try? date.mondayWeek() { choose(.week(startDate: week.startDate, endExclusiveDate: week.endExclusiveDate)) }
                                else { choose(.day(date)) }
                            }.accessibilityIdentifier("plan.calendar")
                            Text(useWeek ? "날짜를 고르면 그 주만 저장해요. 월요일에 자동 배치하지 않아요." : "날짜 버튼을 누르면 해당 날짜로 저장해요. 달력을 열거나 월을 넘기는 행동은 저장하지 않아요.").font(.caption)
                        }
                    }
                    Section {
                        Button("당분간 보관") { choose(.parked) }.accessibilityIdentifier("plan.park")
                    }
                }
                if let problem = model.problem { Text(problem).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(request.taskIDs.count > 1 ? "여러 개 날짜 배치" : "미루기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.accessibilityIdentifier("plan.cancel") } }
            .disabled(model.isSaving)
            .onAppear {
                showDates = !usesQuickChoices
                let task = request.taskIDs.first.flatMap { id in model.tasks.first { $0.taskID == id } }
                let local: LocalDate
                if case let .day(day) = task?.plan.target, day >= request.displayedContext.planningDay { local = day }
                else { local = request.displayedContext.planningDay }
                monthAnchor = local
            }
        }
            .tint(MirrorPalette.accent)
            #if os(macOS)
            .frame(minWidth: 300, idealWidth: 460, minHeight: 320, idealHeight: 400)
            #endif
            .modifier(MirrorDeadlineConfirmation(enabled: true))
    }
    private func choose(_ target: PlanTarget) { Task { await model.choosePlan(request, target: target) } }
}

@MainActor
struct MirrorMonthGrid: View {
    @Binding var anchor: LocalDate
    let minimum: LocalDate
    let choose: (LocalDate) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    private var days: [LocalDate] { (1...31).compactMap { try? LocalDate(year: anchor.year, month: anchor.month, day: $0) } }
    private var leadingSlots: Int { days.first.map { (AppDate.weekday($0) + 5) % 7 } ?? 0 }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("이전 달")
                Spacer()
                Text("\(anchor.year)년 \(anchor.month)월").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("다음 달")
            }
            if typeSize.isAccessibilitySize {
                ForEach(days, id: \.self) { date in dateButton(date, fullLabel: true) }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                    ForEach(["월", "화", "수", "목", "금", "토", "일"], id: \.self) { Text($0).font(.caption).accessibilityHidden(true) }
                    ForEach(0..<leadingSlots, id: \.self) { _ in Color.clear.frame(height: 44).accessibilityHidden(true) }
                    ForEach(days, id: \.self) { date in dateButton(date, fullLabel: false) }
                }
            }
        }
    }
    private func dateButton(_ date: LocalDate, fullLabel: Bool) -> some View {
        Button(fullLabel ? AppDate.label(date) : String(date.day)) { choose(date) }
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(date < minimum)
            .accessibilityLabel("\(AppDate.label(date)), \(date < minimum ? "지나간 날짜라 선택할 수 없음" : "이 날짜 또는 이 주로 배치")")
            .accessibilityIdentifier("plan.day.\(date.iso8601)")
    }
    private func moveMonth(_ offset: Int) {
        let index = (anchor.year - 1) * 12 + anchor.month - 1 + offset
        guard (0..<(9999 * 12)).contains(index), let date = try? LocalDate(year: index / 12 + 1, month: index % 12 + 1, day: 1) else { return }
        anchor = date
    }
}

@MainActor
struct MirrorTaskDetail: View {
    @Environment(AppModel.self) private var model
    let task: TaskProjection
    @State private var title = ""
    @State private var note = ""
    @State private var link = ""
    @State private var editing = false
    @State private var editingSnapshot: TaskProjection?
    @State private var showDeadline = false
    @State private var showHistory = false
    @State private var showNotes = false
    private var actionMaxWidth: CGFloat {
        #if os(macOS)
        return 200
        #else
        return .infinity
        #endif
    }
    private var actionMinHeight: CGFloat {
        #if os(macOS)
        return 20
        #else
        return 32
        #endif
    }
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label(statusLabel, systemImage: statusSymbol)
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if editing {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("제목", text: $title, prompt: Text("제목").foregroundColor(MirrorPalette.inputPrompt), axis: .vertical)
                                .font(.title3).textFieldStyle(.roundedBorder).accessibilityIdentifier("detail.title")
                            TextField("메모", text: $note, prompt: Text("메모").foregroundColor(MirrorPalette.inputPrompt), axis: .vertical)
                                .lineLimit(3...12).textFieldStyle(.roundedBorder)
                            TextField("원문 링크", text: $link, prompt: Text("원문 링크").foregroundColor(MirrorPalette.inputPrompt))
                                .textFieldStyle(.roundedBorder)
                            if let original = editingSnapshot,
                               original.taskID != task.taskID || original.versions[.content]?.headsDigest != task.versions[.content]?.headsDigest {
                                Text("편집을 시작한 뒤 작업이나 내용이 바뀌었어요. 입력한 내용은 유지했어요. 편집을 취소하고 최신 내용을 확인한 뒤 다시 편집하세요.")
                                    .font(.callout)
                            }
                            if let problem = model.problem {
                                Text(problem).foregroundStyle(.red).accessibilityLabel(problem).accessibilityIdentifier("state.error")
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(task.title).font(.title2.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled).accessibilityIdentifier("detail.contentTitle")
                            if task.content.note != nil || task.content.sourceURL != nil {
                                DisclosureGroup("메모와 원문 링크", isExpanded: $showNotes) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        if let note = task.content.note { ExpandableText(note).textSelection(.enabled).foregroundStyle(.secondary) }
                                        if let original = task.content.sourceURL, let url = URL(string: original), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                            Link("원문 링크 열기", destination: url)
                                            Text(original).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                    }.padding(.top, 8)
                                }.font(.callout)
                            }
                            Button("내용 편집") {
                                editingSnapshot = task
                                title = task.title; note = task.content.note ?? ""; link = task.content.sourceURL ?? ""; editing = true
                            }.buttonStyle(.borderless).frame(minHeight: 44).accessibilityIdentifier("detail.edit")
                        }
                    }
                    if editing, task.deadline != nil {
                        Label("실제 마감: \(deadlineLabel(task.deadline, context: model.context))", systemImage: "flag")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !task.conflictGroups.isEmpty {
                        Label("다른 변경과 충돌한 이력이 있어요. 최신 상태를 확인해 주세요.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !editing {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("계획", systemImage: "calendar").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(planLabel(task.plan.target)).font(.body).accessibilityIdentifier("detail.plan")
                            if task.status == .open {
                                MirrorActionGroup {
                                    if !model.showReview, let displayedContext = model.context {
                                        Button {
                                            Task { await model.postponeToTomorrow(task, context: displayedContext) }
                                        } label: {
                                            Text("내일로 미루기").frame(minHeight: 44)
                                        }
                                        .accessibilityIdentifier("detail.postponeTomorrow")
                                        .disabled(model.projectionPending)
                                    }
                                    Button { model.makePicker(taskIDs: [task.taskID]) } label: {
                                        Text("날짜 바꾸기").frame(minHeight: 44)
                                    }
                                }.buttonStyle(.bordered).frame(minHeight: 44)
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            if task.deadline != nil {
                                Label("실제 마감 · 계획과 별개", systemImage: "flag")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(deadlineLabel(task.deadline, context: model.context))
                                Button("실제 마감 편집") { showDeadline = true }.buttonStyle(.borderless).frame(minHeight: 44)
                                Text(model.preferences.deadlineAlarmDates[task.taskID].map { "이 기기 알림: \($0.formatted())" } ?? "이 작업의 실제 마감 알림은 꺼져 있어요.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        DisclosureGroup("변경 이력과 관리", isExpanded: $showHistory) {
                            VStack(alignment: .leading, spacing: 16) {
                                if task.status == .open {
                                    Button("당분간 보관") { Task { await model.park(task) } }.frame(minHeight: 44)
                                }
                                if task.deadline == nil {
                                    Button { showDeadline = true } label: { Label("실제 마감 추가", systemImage: "flag") }
                                        .frame(minHeight: 44)
                                }
                                if task.deadline != nil {
                                    Button("실제 마감 알림 설정") { showDeadline = true }.frame(minHeight: 44)
                                    if model.preferences.deadlineAlarmDates[task.taskID] != nil {
                                        Button("이 작업 마감 알림 끄기") { model.setDeadlineAlarm(task, fireAt: nil) }.frame(minHeight: 44)
                                    }
                                    Button("실제 마감 지우기") { Task { await model.setDeadline(task, deadline: nil) } }.frame(minHeight: 44)
                                }
                                ForEach(model.history(for: task.taskID), id: \.operationID) { record in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.kindLabel).font(.callout)
                                        Text(record.recordedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                        if !record.undoValues.isEmpty {
                                            Button("이 변경 되돌리기") { Task { await model.undo(record) } }.frame(minHeight: 44)
                                        }
                                    }
                                }
                                if task.status == .deleted {
                                    Text("개별 작업의 이력은 영구 삭제하지 않아요.").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button("휴지통으로 이동", role: .destructive) { Task { await model.trash(task) } }.frame(minHeight: 44)
                                }
                            }.buttonStyle(.borderless).padding(.top, 12)
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: 600, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if editing {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task {
                            guard let original = editingSnapshot, original.taskID == task.taskID else { return }
                            if await model.edit(original, title: title, note: note, sourceURL: link) {
                                editing = false; editingSnapshot = nil
                            }
                        }
                    } label: {
                        Text("내용 저장").foregroundStyle(MirrorPalette.onAccent)
                            .frame(maxWidth: .infinity, minHeight: actionMinHeight)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    #if os(macOS)
                    .frame(maxWidth: actionMaxWidth, minHeight: 32, maxHeight: 44, alignment: .leading)
                    #else
                    .frame(minHeight: 44)
                    #endif
                    .disabled(editingSnapshot?.taskID != task.taskID)
                    .accessibilityIdentifier("detail.save")
                    Button("편집 취소") { editing = false; editingSnapshot = nil }
                        .buttonStyle(.borderless).frame(minHeight: 44)
                }.padding(.horizontal, 24).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(MirrorPalette.surface)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if task.status != .deleted {
                        Button {
                            Task { await model.setCompleted(task, completed: task.status != .completed) }
                        } label: {
                            Text(task.status == .completed ? "완료 취소 · 다시 열기" : "완료")
                                .foregroundStyle(MirrorPalette.onAccent)
                                .frame(maxWidth: .infinity, minHeight: actionMinHeight)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                        #if os(macOS)
                        .frame(maxWidth: actionMaxWidth, minHeight: 32, maxHeight: 44, alignment: .leading)
                        #else
                        .frame(minHeight: 44)
                        #endif
                        .accessibilityIdentifier("task.complete")
                    } else {
                        Button("휴지통에서 복구") { Task { await model.restore(task) } }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                    }
                    if model.lastUndo?.taskID == task.taskID {
                        Button("직전 변경 되돌리기") { Task { await model.undo() } }
                            .buttonStyle(.borderless).frame(minHeight: 44)
                            .accessibilityIdentifier("task.undo")
                    }
                }.padding(.horizontal, 24).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(MirrorPalette.surface)
            }
        }
        .navigationTitle("작업 상세")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("상세 닫기") { model.selectedTaskID = nil }.accessibilityIdentifier("detail.close") } }
        .disabled(model.isSaving)
        .onChange(of: editing) { _, value in
            model.isDetailEditing = value
            model.isTextEditing = value
        }
        .onDisappear { model.isDetailEditing = false; model.isTextEditing = false }
        .onChange(of: task.taskID) { _, _ in showNotes = false; showHistory = false }
        .sheet(isPresented: $showDeadline) { MirrorDeadlineEditor(task: task) }
        .sheet(item: $model.picker) { MirrorPlanPicker(request: $0) }
        .modifier(MirrorDeadlineConfirmation(enabled: model.picker == nil))
    }
    private var statusLabel: String {
        switch task.status { case .open: "미완료"; case .completed: "완료한 일"; case .deleted: "휴지통에 있는 일" }
    }
    private var statusSymbol: String {
        switch task.status { case .open: "circle"; case .completed: "checkmark.circle"; case .deleted: "trash" }
    }
}

@MainActor
struct MirrorDeadlineEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: TaskProjection
    @State private var date = Date()
    @State private var precise = false
    @State private var alarm = false
    @State private var alarmAt = Date()
    @State private var deadlineTimeZoneID: String?
    @State private var editingSnapshot: TaskProjection?
    private var editorTimeZoneID: String { deadlineTimeZoneID ?? model.preferences.timeZoneID }
    var body: some View {
        NavigationStack {
            Form {
                Text("실제 마감은 계획 날짜와 별도예요. 날짜 배치로 마감이 바뀌지 않아요.")
                Toggle("정확한 시각까지 정하기", isOn: $precise)
                DatePicker("실제 마감", selection: $date, displayedComponents: precise ? [.date, .hourAndMinute] : [.date])
                Text("마감 시간대: \(editorTimeZoneID)").font(.caption)
                Toggle("이 기기에서 이 작업의 실제 마감 알림", isOn: $alarm)
                if alarm { DatePicker("알림을 받을 시각", selection: $alarmAt, displayedComponents: [.date, .hourAndMinute]) }
                if let original = editingSnapshot,
                   original.taskID != task.taskID || original.versions[.deadline]?.headsDigest != task.versions[.deadline]?.headsDigest {
                    Text("편집을 시작한 뒤 작업이나 실제 마감이 바뀌었어요. 입력한 값은 유지했어요. 취소하고 최신 마감을 확인한 뒤 다시 편집하세요.").font(.callout)
                }
                if let problem = model.problem {
                    Text(problem).foregroundStyle(.red).accessibilityLabel(problem).accessibilityIdentifier("state.error")
                }
                Button("실제 마감 저장") {
                    guard let original = editingSnapshot, original.taskID == task.taskID else { return }
                    let submittedDate = date
                    let submittedZone = editorTimeZoneID
                    let submittedPrecise = precise
                    let submittedAlarm = alarm
                    let submittedAlarmAt = alarmAt
                    Task {
                        let deadline: Deadline
                        if submittedPrecise { deadline = .instant(utcTimestamp: submittedDate, displayTimeZoneID: submittedZone) }
                        else {
                            guard let value = try? PlanningContext.capture(at: submittedDate, timeZoneID: submittedZone,
                                                                          policyRevision: model.preferences.policyRevision).planningDay else { return }
                            deadline = .day(localDate: value, timeZoneID: submittedZone)
                        }
                        guard await model.setDeadline(original, deadline: deadline) else { return }
                        if submittedAlarm { await model.enableNotifications(review: model.preferences.reviewNotifications, deadlines: true) }
                        model.setDeadlineAlarm(original, fireAt: submittedAlarm ? submittedAlarmAt : nil)
                        if model.problem == nil { dismiss() }
                    }
                }.disabled(model.isSaving || model.projectionPending || editingSnapshot?.taskID != task.taskID)
                if model.projectionPending {
                    Button("저장 결과 다시 확인") { Task { await model.retry() } }
                }
            }.navigationTitle("실제 마감")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
                .environment(\.timeZone, TimeZone(identifier: editorTimeZoneID) ?? .gmt)
                .onAppear {
                    guard editingSnapshot == nil else { return }
                    editingSnapshot = task
                    switch task.deadline {
                    case let .day(day, zone): deadlineTimeZoneID = zone; date = AppDate.instant(day, zone: zone) ?? model.now
                    case let .instant(instant, zone): deadlineTimeZoneID = zone; date = instant; precise = true
                    case nil: deadlineTimeZoneID = model.preferences.timeZoneID; date = model.now
                    }
                    alarmAt = model.preferences.deadlineAlarmDates[task.taskID] ?? date
                    alarm = model.preferences.deadlineAlarmDates[task.taskID] != nil
                }
        }.frame(minWidth: 300, idealWidth: 450, minHeight: 300)
    }
}

@MainActor
private struct MirrorActionGroup<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout { content }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

func weekLabel(_ week: WeekRange?) -> String {
    guard let week else { return "날짜 범위를 확인해 주세요" }
    return "\(AppDate.short(week.startDate))–\(AppDate.short((try? week.endExclusiveDate.addingDays(-1)) ?? week.endExclusiveDate))"
}
func deadlineLabel(_ deadline: Deadline?, context: PlanningContext?) -> String {
    guard let deadline else { return "실제 마감 없음" }
    switch deadline {
    case let .day(day, zone): return "\(AppDate.label(day))까지 · \(zone)"
    case let .instant(instant, zone):
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ko_KR"); formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return "\(formatter.string(from: instant))까지 · \(zone)"
    }
}
