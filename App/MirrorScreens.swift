import MirrorDesign
import MirrorDomain
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MirrorTodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showCompleted = false
    var body: some View {
        List {
            if let context = model.context {
                Section { Text(AppDate.label(context.planningDay)).font(.title2).accessibilityAddTraits(.isHeader) }
            }
            if !model.deadlines.isEmpty {
                Section("실제 마감 안내 · 계획과 별개") {
                    ForEach(model.deadlines, id: \.taskID) { task in
                        Button { model.selectedTaskID = task.taskID } label: {
                            Label { VStack(alignment: .leading) { Text(task.title); Text(deadlineLabel(task.deadline, context: model.context)).font(.caption) } } icon: { Image(systemName: "flag") }
                        }.buttonStyle(.plain)
                    }
                }
            }
            Section("오늘에 남긴 일") {
                if model.todayTasks.isEmpty {
                    ContentUnavailableView {
                        Label("오늘에 남긴 일이 없어요", systemImage: "sun.max")
                    } description: {
                        Text(model.pendingTasks.isEmpty ? "직접 날짜를 정한 일만 여기에 보여요." : "정하지 않은 일은 보관함에 있어요.")
                    } actions: { Button("일단 넣기") { model.showCapture = true } }
                }
                ForEach(model.todayTasks, id: \.taskID) { MirrorTaskRow(task: $0) }
            }
            Section {
                Button("오늘 정리") { model.beginReview() }
                    .accessibilityIdentifier("today.review")
                if let review = model.review, !review.cards.isEmpty {
                    Button("이어서 정리") { model.beginReview(mode: .manualResume) }
                        .accessibilityIdentifier("today.resumeReview")
                }
                Button("오늘 다시 정리") { model.beginReview(mode: .manualTodayOverride) }
                    .accessibilityIdentifier("today.reviewAgain")
                if !model.pendingTasks.isEmpty { Text("보관함에 정하지 않은 일 \(model.pendingTasks.count)개").font(.caption).foregroundStyle(.secondary) }
                if let summary = model.reviewSummary { Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true) }
                if model.reviewSummary != nil, !model.pendingTasks.isEmpty {
                    Button("새로 넣은 일도 정리") { model.beginReview(mode: .manualResume, includeNewInputs: true) }
                }
            }
            Section {
                DisclosureGroup("완료한 일", isExpanded: $showCompleted) {
                    ForEach(model.completedToday, id: \.taskID) { MirrorTaskRow(task: $0) }
                }
            }
        }
        .accessibilityIdentifier("today.list")
        .navigationTitle("오늘")
    }
}

@MainActor
struct MirrorTaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskProjection
    var body: some View {
        TaskRow(task.title, status: Binding(get: { task.status == .completed ? .completed : .open }, set: { value in
            if value != .snoozed { Task { await model.setCompleted(task, completed: value == .completed) } }
        }), due: planLabel(task.plan.target), onTap: { model.selectedTaskID = task.taskID },
                onSnooze: { Task { await model.park(task) } }, onDelete: { Task { await model.trash(task) } })
            .disabled(model.isSaving || task.status == .deleted)
            .accessibilityIdentifier("task.row.\(task.taskID.uuidString)")
            .contextMenu {
                Button("상세 열기") { model.selectedTaskID = task.taskID }
                Button(task.status == .completed ? "다시 열기" : "완료") { Task { await model.setCompleted(task, completed: task.status != .completed) } }
                Button("날짜 바꾸기") { model.makePicker(taskIDs: [task.taskID]) }
                Button("당분간 보관") { Task { await model.park(task) } }
                Button("휴지통으로 이동", role: .destructive) { Task { await model.trash(task) } }
            }
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
    private enum InputField: Hashable { case title, note, url }
    @FocusState private var focusedField: InputField?
    private var lines: [String] { title.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("일단 넣고, 나중에 정하세요").font(.headline)
                    TextField("할 일 제목", text: $title, axis: .vertical)
                        .lineLimit(1...8).focused($focusedField, equals: .title)
                        .disabled(model.isSaving || model.projectionPending)
                        .accessibilityIdentifier("capture.title")
                    Text("\(title.count)/500자 · 입력은 자동으로 잘리지 않아요").font(.caption).foregroundStyle(title.count > 500 ? .red : .secondary)
                }
                DisclosureGroup("메모와 원문 링크", isExpanded: $more) {
                    TextField("메모", text: $note, axis: .vertical).lineLimit(3...10).focused($focusedField, equals: .note).disabled(model.isSaving || model.projectionPending).accessibilityIdentifier("capture.note")
                    TextField("https:// 원문 링크", text: $sourceURL).focused($focusedField, equals: .url).disabled(model.isSaving || model.projectionPending).accessibilityIdentifier("capture.url")
                    Text("링크를 저장해도 웹 내용을 자동으로 가져오지 않아요.").font(.caption)
                }
                if lines.count > 1 {
                    Section("여러 줄 입력") {
                        Text("자동으로 여러 작업을 만들지 않아요. 저장 방식을 고르세요.")
                        Button("한 개로 저장") { save() }.disabled(model.isSaving || model.projectionPending)
                        Button("줄마다 나누기 · \(lines.count)개 미리 보기") { splitPreview = true }.disabled(model.isSaving || model.projectionPending)
                    }
                }
                if let problem = model.problem { Text(problem).foregroundStyle(.red).accessibilityIdentifier("state.error") }
                Section {
                    Button(model.isSaving ? "저장 중…" : "보관함에 넣기") { save() }
                        .disabled(model.isSaving || model.projectionPending)
                        .accessibilityIdentifier("capture.save")
                    if model.projectionPending { Button("저장 결과 다시 확인") { Task { await model.retry() } } }
                }
            }
            .navigationTitle("일단 넣기")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.accessibilityIdentifier("capture.close") } }
            .onAppear { focusedField = .title }
            .onChange(of: focusedField) { _, focused in model.isTextEditing = focused != nil }
            .onDisappear { model.isTextEditing = false }
            .onChange(of: model.lastCaptureCommittedToken) { _, token in
                guard token == requestToken else { return }
                if pendingSingle { title = ""; note = ""; sourceURL = ""; pendingSingle = false; requestToken = UUID().uuidString }
                else if let pendingLine {
                    var remaining = title.components(separatedBy: .newlines)
                    if remaining.first == pendingLine { remaining.removeFirst(); title = remaining.joined(separator: "\n") }
                    self.pendingLine = nil; requestToken = UUID().uuidString
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
                                focusedField = .title
                            }
                        }.disabled(model.isSaving || model.projectionPending)
                    }.navigationTitle("줄마다 나누기")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { splitPreview = false } } }
                }
            }
        }.frame(minWidth: 300, idealWidth: 480, minHeight: 340)
    }
    private func save() {
        Task {
            requestToken = UUID().uuidString
            if await model.capture(title: title, note: note, sourceURL: sourceURL, requestToken: requestToken) {
                title = ""; note = ""; sourceURL = ""; focusedField = .title
                requestToken = UUID().uuidString
            } else if model.projectionPending { pendingSingle = true }
        }
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
                TextField("미래·완료·보관까지 검색", text: $model.search).focused($searchFocused).accessibilityIdentifier("library.search")
                Picker("목록", selection: $filter) { ForEach(LibraryFilter.allCases) { Text($0.label).tag($0) } }
                Toggle("여러 개 선택", isOn: $selecting)
                if selecting {
                    Text("같은 날짜로 최대 20개를 한 번에 배치해요. 하나라도 오래된 상태이면 전체를 저장하지 않아요.").font(.caption)
                    Button("선택한 \(model.selectedTaskIDs.count)개 날짜 배치") { model.makePicker(taskIDs: Array(model.selectedTaskIDs)) }
                        .disabled(model.selectedTaskIDs.isEmpty || model.selectedTaskIDs.count > 20)
                        .accessibilityIdentifier("library.batchPlan")
                }
            }
            Section(filter.label) {
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
                            Button { model.selectedTaskID = task.taskID } label: {
                                VStack(alignment: .leading) { Text(task.title); Text("휴지통 · \(planLabel(task.plan.target))").font(.caption) }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button("복구") { Task { await model.restore(task) } }.disabled(model.isSaving)
                        } else { MirrorTaskRow(task: task) }
                    }
                }
            }
        }
        .navigationTitle("보관함")
        .accessibilityIdentifier("library.list")
        .onChange(of: model.searchRequested) { _, requested in if requested { searchFocused = true; model.searchRequested = false } }
        .onChange(of: searchFocused) { _, focused in model.isTextEditing = focused }
        .onDisappear { model.isTextEditing = false }
    }
}

@MainActor
struct MirrorReviewView: View {
    @Environment(AppModel.self) private var model
    @AccessibilityFocusState private var cardFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let session = model.review {
                        Text(session.isWeekly ? "이번 주에 할 일인가요?" : "오늘 할 일인가요?").font(.title2).accessibilityAddTraits(.isHeader)
                        Text(session.isWeekly ? "주간 정리 · \(weekLabel(try? session.context.planningDay.mondayWeek()))" : "일간 정리 · \(AppDate.label(session.context.planningDay))").foregroundStyle(.secondary)
                        Text("이번에 정한 \(session.decidedToday + session.decidedElsewhere)개").font(.caption)
                    }
                    if let task = model.currentReviewTask, let card = model.currentCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(task.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                                .accessibilityFocused($cardFocused).accessibilityIdentifier("review.card")
                            Text(planLabel(task.plan.target)).font(.callout)
                            if task.deadline != nil { Label("실제 마감: \(deadlineLabel(task.deadline, context: model.context))", systemImage: "flag") }
                            if let note = task.content.note, !note.isEmpty { ExpandableText(note, lineLimit: 2).foregroundStyle(.secondary) }
                            if task.content.sourceURL != nil { Label("원문 링크가 있어요", systemImage: "link").font(.caption) }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(reduceTransparency ? AnyShapeStyle(MirrorPalette.surface) : AnyShapeStyle(Material.regular), in: RoundedRectangle(cornerRadius: 18))
                        if let destinations = try? model.review?.context.destinations() {
                            ViewThatFits(in: .horizontal) {
                                HStack { todayButton(destinations.today); tomorrowButton(destinations.tomorrow) }
                                VStack { todayButton(destinations.today); tomorrowButton(destinations.tomorrow) }
                            }
                            Button { model.makePicker(taskIDs: [card.taskID], week: destinations.thisWeek, reviewCard: card) } label: {
                                Label("이번 주 ›", systemImage: "calendar")
                            }.frame(minHeight: 44).keyboardShortcut("3", modifiers: []).disabled(model.isTextEditing).accessibilityLabel("이번 주, \(weekLabel(destinations.thisWeek)), 날짜 선택").accessibilityIdentifier("review.thisWeek")
                            Button { model.makePicker(taskIDs: [card.taskID], week: destinations.nextWeek, reviewCard: card) } label: {
                                Label("다음 주 ›", systemImage: "calendar.badge.plus")
                            }.frame(minHeight: 44).keyboardShortcut("4", modifiers: []).disabled(model.isTextEditing).accessibilityLabel("다음 주, \(weekLabel(destinations.nextWeek)), 날짜 선택").accessibilityIdentifier("review.nextWeek")
                            Button { model.makePicker(taskIDs: [card.taskID], reviewCard: card) } label: {
                                Label("기타 ›", systemImage: "calendar.circle")
                            }.frame(minHeight: 44).keyboardShortcut("5", modifiers: []).disabled(model.isTextEditing).accessibilityIdentifier("review.other")
                            #if os(macOS)
                            Text("키보드 1 오늘 · 2 내일 · 3 이번 주 · 4 다음 주 · 5 기타").font(.caption).foregroundStyle(.secondary)
                            #endif
                        }
                        Button("작업 상세") { model.selectedTaskID = task.taskID }
                    } else {
                        ContentUnavailableView("지금 정리할 카드가 없어요", systemImage: "tray", description: Text("정한 미래 날짜와 보관한 일은 자동 큐에 나오지 않아요. 오늘 목록으로 돌아갈 수 있어요."))
                    }
                    if let feedback = model.feedback { Text(feedback).font(.callout).accessibilityIdentifier("state.feedback") }
                    if let problem = model.problem {
                        Text(problem).foregroundStyle(.red).accessibilityIdentifier("state.error")
                        Button("최신 상태 확인") { Task { await model.refreshReviewCard() } }.accessibilityIdentifier("state.retry")
                    }
                    if model.lastUndo != nil { Button("직전 결정 되돌리기") { Task { await model.undo() } }.accessibilityIdentifier("task.undo") }
                    if model.projectionPending { Button("저장 결과 다시 확인") { Task { await model.retry() } } }
                }.padding().frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button("오늘은 여기까지") { Task { await model.finishReview() } }
                    .frame(maxWidth: .infinity, minHeight: 44).padding().background(.bar)
                    .accessibilityIdentifier("review.finish").disabled(model.isSaving)
            }
            .navigationTitle("정리")
            .onChange(of: model.currentCard?.id, initial: true) { _, _ in cardFocused = true }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.currentCard?.id)
            .sheet(item: Binding(get: { model.selectedTaskID == nil ? model.picker : nil }, set: { if $0 == nil { model.picker = nil } })) { MirrorPlanPicker(request: $0) }
            .sheet(item: Binding(get: { model.selectedTaskID.map(MirrorDetailRequest.init(id:)) }, set: { if $0 == nil { model.selectedTaskID = nil } })) { detail in
                NavigationStack {
                    if let task = model.tasks.first(where: { $0.taskID == detail.id }) { MirrorTaskDetail(task: task) }
                }
            }
            .modifier(MirrorDeadlineConfirmation(enabled: model.picker == nil && model.selectedTaskID == nil))
        }
        .disabled(model.isSaving)
        .frame(minWidth: 300, idealWidth: 580, minHeight: 460)
    }
    private func todayButton(_ day: LocalDate) -> some View {
        Button("오늘") { Task { await model.decide(.day(day)) } }
            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityLabel("오늘, \(AppDate.label(day))에 배치, 완료 아님").accessibilityIdentifier("review.today")
            .keyboardShortcut("1", modifiers: []).disabled(model.isTextEditing)
    }
    private func tomorrowButton(_ day: LocalDate) -> some View {
        Button("내일") { Task { await model.decide(.day(day)) } }
            .buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityLabel("내일, \(AppDate.label(day))에 배치").accessibilityIdentifier("review.tomorrow")
            .keyboardShortcut("2", modifiers: []).disabled(model.isTextEditing)
    }
}

@MainActor
struct MirrorPlanPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PlanPickerRequest
    @State private var monthAnchor: LocalDate?
    @State private var useWeek = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(request.taskIDs, id: \.self) { id in
                        Text(model.tasks.first { $0.taskID == id }?.title ?? "작업을 찾을 수 없어요")
                    }
                    Text("계획 날짜를 바꿔도 실제 마감은 바뀌지 않아요.").font(.caption)
                }
                if let week = request.week {
                    Section(weekLabel(week)) {
                        ForEach(0..<7) { offset in
                            if let date = try? week.startDate.addingDays(offset) {
                                Button(AppDate.label(date)) { choose(.day(date)) }
                                    .frame(minHeight: 44)
                                    .disabled(date < request.displayedContext.planningDay)
                                    .accessibilityLabel("\(AppDate.label(date)), \(date < request.displayedContext.planningDay ? "지나간 날짜라 선택할 수 없음" : "이 날짜로 배치")")
                                    .accessibilityIdentifier("plan.day.\(date.iso8601)")
                            }
                        }
                        Button("요일은 나중에 정하기") { choose(.week(startDate: week.startDate, endExclusiveDate: week.endExclusiveDate)) }
                            .accessibilityIdentifier("plan.weekOnly")
                    }
                } else {
                    Section("날짜 선택") {
                        Toggle("선택한 주만 정하기", isOn: $useWeek)
                        MirrorMonthGrid(anchor: Binding(get: { monthAnchor ?? request.displayedContext.planningDay }, set: { monthAnchor = $0 }), minimum: request.displayedContext.planningDay) { date in
                            if useWeek, let week = try? date.mondayWeek() { choose(.week(startDate: week.startDate, endExclusiveDate: week.endExclusiveDate)) }
                            else { choose(.day(date)) }
                        }.accessibilityIdentifier("plan.calendar")
                        Text(useWeek ? "날짜를 고르면 그 주만 저장해요. 월요일에 자동 배치하지 않아요." : "날짜 버튼을 누르면 해당 날짜로 저장해요. 달력을 열거나 월을 넘기는 행동은 저장하지 않아요.").font(.caption)
                    }
                    Section { Button("당분간 보관") { choose(.parked) }.accessibilityIdentifier("plan.park") }
                }
                if let problem = model.problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle(request.taskIDs.count > 1 ? "여러 개 날짜 배치" : "날짜 배치")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.accessibilityIdentifier("plan.cancel") } }
            .disabled(model.isSaving)
            .onAppear {
                let task = request.taskIDs.first.flatMap { id in model.tasks.first { $0.taskID == id } }
                let local: LocalDate
                if case let .day(day) = task?.plan.target, day >= request.displayedContext.planningDay { local = day }
                else { local = request.displayedContext.planningDay }
                monthAnchor = local
            }
        }.frame(minWidth: 300, idealWidth: 500, minHeight: 420)
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
    @State private var showDeadline = false
    var body: some View {
        @Bindable var model = model
        Form {
            Section("내용") {
                if editing {
                    TextField("제목", text: $title, axis: .vertical).accessibilityIdentifier("detail.title")
                    TextField("메모", text: $note, axis: .vertical).lineLimit(3...12)
                    TextField("원문 링크", text: $link)
                    Button("내용 저장") { Task { if await model.edit(task, title: title, note: note, sourceURL: link) { editing = false } } }.accessibilityIdentifier("detail.save")
                    Button("편집 취소") { editing = false }
                } else {
                    Text(task.title).font(.title2).textSelection(.enabled).accessibilityIdentifier("detail.contentTitle")
                    if let note = task.content.note { ExpandableText(note).textSelection(.enabled) }
                    if let original = task.content.sourceURL, let url = URL(string: original), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        Link("원문 링크 열기", destination: url)
                        Text(original).font(.caption).textSelection(.enabled)
                    }
                    Button("내용 편집") { title = task.title; note = task.content.note ?? ""; link = task.content.sourceURL ?? ""; editing = true }.accessibilityIdentifier("detail.edit")
                }
            }
            Section("계획") {
                Text(planLabel(task.plan.target)).accessibilityIdentifier("detail.plan")
                Button("날짜 바꾸기") { model.makePicker(taskIDs: [task.taskID]) }.disabled(task.status != .open)
                if let day = model.context?.planningDay {
                    Button("오늘에 남기기") { model.makePicker(taskIDs: [task.taskID]); if let request = model.picker { Task { await model.choosePlan(request, target: .day(day)) } } }
                        .disabled(task.status != .open)
                }
                Button("당분간 보관") { Task { await model.park(task) } }.disabled(task.status != .open)
            }
            Section("실제 마감 · 계획과 별개") {
                Text(deadlineLabel(task.deadline, context: model.context))
                Button("실제 마감 편집") { showDeadline = true }
                if task.deadline != nil { Button("실제 마감 지우기") { Task { await model.setDeadline(task, deadline: nil) } } }
                if task.deadline != nil {
                    Text(model.preferences.deadlineAlarmDates[task.taskID].map { "이 기기 알림: \($0.formatted())" } ?? "이 작업의 실제 마감 알림은 꺼져 있어요.").font(.caption)
                    Button("실제 마감 알림 설정") { showDeadline = true }
                    if model.preferences.deadlineAlarmDates[task.taskID] != nil { Button("이 작업 마감 알림 끄기") { model.setDeadlineAlarm(task, fireAt: nil) } }
                }
            }
            Section("상태") {
                if task.status == .deleted {
                    Button("휴지통에서 복구") { Task { await model.restore(task) } }
                    Text("개별 작업의 이력은 영구 삭제하지 않아요.").font(.caption)
                } else {
                    Button(task.status == .completed ? "완료 취소 · 다시 열기" : "완료") { Task { await model.setCompleted(task, completed: task.status != .completed) } }
                        .accessibilityIdentifier("task.complete")
                    Button("휴지통으로 이동", role: .destructive) { Task { await model.trash(task) } }
                }
                if !task.conflictGroups.isEmpty { Label("다른 변경과 충돌한 이력이 있어요. 최신 상태를 확인해 주세요.", systemImage: "exclamationmark.triangle") }
            }
            Section("최근 변경") {
                if model.lastUndo?.taskID == task.taskID { Button("직전 변경 되돌리기") { Task { await model.undo() } }.accessibilityIdentifier("task.undo") }
                ForEach(model.history(for: task.taskID), id: \.operationID) { record in
                    VStack(alignment: .leading) { Text(record.kindLabel); Text(record.recordedAt, style: .date).font(.caption) }
                    if !record.undoValues.isEmpty { Button("이 변경을 조건부로 되돌리기") { Task { await model.undo(record) } } }
                }
            }
        }
        .navigationTitle("작업 상세")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("상세 닫기") { model.selectedTaskID = nil }.accessibilityIdentifier("detail.close") } }
        .disabled(model.isSaving)
        .onChange(of: editing) { _, value in model.isTextEditing = value }
        .onDisappear { model.isTextEditing = false }
        .sheet(isPresented: $showDeadline) { MirrorDeadlineEditor(task: task) }
        .sheet(item: $model.picker) { MirrorPlanPicker(request: $0) }
        .modifier(MirrorDeadlineConfirmation(enabled: model.picker == nil))
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
    var body: some View {
        NavigationStack {
            Form {
                Text("실제 마감은 계획 날짜와 별도예요. 날짜 배치로 마감이 바뀌지 않아요.")
                Toggle("정확한 시각까지 정하기", isOn: $precise)
                DatePicker("실제 마감", selection: $date, displayedComponents: precise ? [.date, .hourAndMinute] : [.date])
                Text("시간대: \(model.preferences.timeZoneID)").font(.caption)
                Toggle("이 기기에서 이 작업의 실제 마감 알림", isOn: $alarm)
                if alarm { DatePicker("알림을 받을 시각", selection: $alarmAt, displayedComponents: [.date, .hourAndMinute]) }
                Button("실제 마감 저장") {
                    Task {
                        let deadline: Deadline
                        if precise { deadline = .instant(utcTimestamp: date, displayTimeZoneID: model.preferences.timeZoneID) }
                        else {
                            guard let value = try? LocalDate.from(date, timeZone: TimeZone(identifier: model.preferences.timeZoneID) ?? .gmt) else { return }
                            deadline = .day(localDate: value, timeZoneID: model.preferences.timeZoneID)
                        }
                        await model.setDeadline(task, deadline: deadline)
                        if model.problem == nil {
                            if alarm { await model.enableNotifications(review: model.preferences.reviewNotifications, deadlines: true) }
                            model.setDeadlineAlarm(task, fireAt: alarm ? alarmAt : nil)
                            if model.problem == nil { dismiss() }
                        }
                    }
                }.disabled(model.isSaving)
            }.navigationTitle("실제 마감")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
                .environment(\.timeZone, TimeZone(identifier: model.preferences.timeZoneID) ?? .gmt)
                .onAppear {
                    switch task.deadline {
                    case let .day(day, zone): date = AppDate.instant(day, zone: zone) ?? model.now
                    case let .instant(instant, _): date = instant; precise = true
                    case nil: date = model.now
                    }
                    alarmAt = model.preferences.deadlineAlarmDates[task.taskID] ?? date
                    alarm = model.preferences.deadlineAlarmDates[task.taskID] != nil
                }
        }.frame(minWidth: 300, idealWidth: 450, minHeight: 300)
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
