import MirrorDesign
import MirrorDomain
import MirrorSystem
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct MirrorTaskSelectionRequest: Equatable, Sendable {
    let id = UUID()
    let ownerID: UUID
    let destinationID: UUID
    let workspaceKey: String
    let workspaceEpoch: String
    let navigation: SceneNavigationTarget
}

@MainActor @Observable
final class MirrorDetailNavigationState {
    var closeRequestedID: UUID?
    var draftTaskID: UUID?
    var selectionRequested: MirrorTaskSelectionRequest?

    func requestTaskSelection(_ id: UUID, model: AppModel, scene: SceneNavigationState) {
        guard !model.isSaving, let navigation = model.navigationTarget(in: scene),
              let target = model.tasks.first(where: { $0.taskID == id }) else { return }
        if let owner = model.selectedTask(in: scene), (draftTaskID == owner.taskID || model.isDetailEditing(in: scene)) {
            guard id != owner.taskID, !model.projectionPending,
                  target.workspaceKey == owner.workspaceKey, target.workspaceEpoch == owner.workspaceEpoch else { return }
            selectionRequested = MirrorTaskSelectionRequest(ownerID: owner.taskID, destinationID: id,
                                                           workspaceKey: owner.workspaceKey, workspaceEpoch: owner.workspaceEpoch,
                                                           navigation: navigation)
        } else { model.selectTask(id, in: scene) }
    }
}

nonisolated struct MirrorTaskSelectionAction: Equatable, Sendable {
    let model: AppModel
    let navigation: MirrorDetailNavigationState
    let scene: SceneNavigationState

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.navigation === rhs.navigation && lhs.scene === rhs.scene
    }

    @MainActor
    func callAsFunction(_ id: UUID) {
        navigation.requestTaskSelection(id, model: model, scene: scene)
    }
}

/// custom environment/focused value에는 동등한 scene 입력을 비교할 수 있는 값만 보관한다.
nonisolated struct MirrorCaptureOpenAction: Equatable, Sendable {
    let model: AppModel
    let owner: CaptureSceneOwner

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.owner === rhs.owner
    }

    @MainActor
    func callAsFunction() {
        model.openCaptureWhenReady(owner: owner)
    }
}

private struct MirrorCaptureOpenKey: EnvironmentKey {
    static let defaultValue: MirrorCaptureOpenAction? = nil
}

extension EnvironmentValues {
    var mirrorCaptureOpen: MirrorCaptureOpenAction? {
        get { self[MirrorCaptureOpenKey.self] }
        set { self[MirrorCaptureOpenKey.self] = newValue }
    }
}

private struct MirrorTaskSelectionKey: EnvironmentKey {
    static let defaultValue: MirrorTaskSelectionAction? = nil
}

extension EnvironmentValues {
    var mirrorTaskSelection: MirrorTaskSelectionAction? {
        get { self[MirrorTaskSelectionKey.self] }
        set { self[MirrorTaskSelectionKey.self] = newValue }
    }
}

@MainActor
struct MirrorTodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneNavigationState.self) private var scene
    @Environment(\.mirrorCaptureOpen) private var openCapture
    @Environment(\.mirrorTaskSelection) private var selectTask
    @State private var showCompleted = false
    @State private var showReviewSummary = false
    @State private var showMoreDeadlines = false
    var body: some View {
        let deadlines = model.deadlines
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    if let context = model.context {
                        Text(AppDate.label(context.planningDay))
                            .font(.subheadline).foregroundStyle(MirrorPalette.supportingText).accessibilityAddTraits(.isHeader)
                    }
                    MirrorActionGroup {
                        if model.tasks.isEmpty {
                            reviewButton.buttonStyle(.bordered)
                        } else {
                            reviewButton.buttonStyle(.borderedProminent)
                        }
                        Menu {
                            if let review = model.review, !review.cards.isEmpty {
                                Button("이어서 정리") { model.beginReview(in: scene, mode: .manualResume) }
                                    .accessibilityIdentifier("today.resumeReview")
                            }
                            Button("오늘 다시 정리") { model.beginReview(in: scene, mode: .manualTodayOverride) }
                                .accessibilityIdentifier("today.reviewAgain")
                            if model.reviewSummary != nil, !model.pendingTasks.isEmpty {
                                Button("새로 넣은 일도 정리") { model.beginReview(in: scene, mode: .manualResume, includeNewInputs: true) }
                            }
                        } label: {
                            Label("정리 옵션", systemImage: "ellipsis")
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                            .accessibilityLabel("정리 옵션")
                            #if os(macOS)
                            .menuStyle(.borderlessButton)
                            #endif
                            .disabled(model.isDetailEditing)
                    }
                }.padding(.vertical, 8)
            }
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            if !deadlines.isEmpty {
                Section("실제 마감 안내 · 총 \(deadlines.count)개 · 계획과 별개") {
                    ForEach(deadlines.prefix(3), id: \.taskID) { task in deadlineRow(task) }
                    if deadlines.count > 3 {
                        DisclosureGroup(isExpanded: $showMoreDeadlines) {
                            ForEach(deadlines.dropFirst(3), id: \.taskID) { task in deadlineRow(task) }
                        } label: {
                            Text("나머지 \(deadlines.count - 3)개 더 보기")
                                .fixedSize(horizontal: false, vertical: true)
                                #if os(iOS)
                                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                #endif
                        }
                    }
                }
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            Section {
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
                            .font(.subheadline).foregroundStyle(MirrorPalette.supportingText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("today.empty.description")
                        if model.tasks.isEmpty {
                            emptyCaptureButton.buttonStyle(.borderedProminent)
                        } else {
                            emptyCaptureButton.buttonStyle(.borderless)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
                ForEach(model.todayTasks, id: \.taskID) {
                    MirrorTaskRow(task: $0).listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            } header: {
                Text("오늘에 남긴 일").foregroundStyle(MirrorPalette.supportingText)
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
        .onChange(of: model.isReviewPresented(in: scene)) { _, isPresented in
            if !isPresented { showReviewSummary = false }
        }
    }
    private func deadlineRow(_ task: TaskProjection) -> some View {
        Button { selectTask?(task.taskID) } label: {
            Label { VStack(alignment: .leading) { Text(task.title).lineLimit(3).accessibilityLabel(task.title); Text(deadlineLabel(task.deadline, context: model.context)).font(.caption) } } icon: { Image(systemName: "flag") }
        }.buttonStyle(.plain).padding(.vertical, 4)
    }
    private var reviewButton: some View {
        Button { model.beginReview(in: scene, mode: .manualResume) } label: {
            Text(reviewButtonTitle)
                .foregroundStyle(model.tasks.isEmpty ? MirrorPalette.accent : MirrorPalette.onAccent)
        }
        .controlSize(.regular).frame(minHeight: 44)
        .accessibilityLabel(reviewButtonAccessibilityLabel)
        .accessibilityIdentifier("today.review")
        .disabled(model.isDetailEditing)
    }
    private var emptyCaptureButton: some View {
        Button { openCapture?.callAsFunction() } label: {
            Text("일단 넣기")
                .foregroundStyle(model.tasks.isEmpty ? MirrorPalette.onAccent : MirrorPalette.accent)
                .frame(minHeight: 44)
        }
        .disabled(openCapture == nil)
        .accessibilityIdentifier("today.empty.capture")
    }
    private var reviewButtonTitle: String {
        if let session = model.review, !session.cards.isEmpty {
            return "이어서 정리 · \(session.cards.count)개"
        }
        return model.pendingTasks.isEmpty ? "오늘 정리" : "오늘 정리 · \(model.pendingTasks.count)개"
    }
    private var reviewButtonAccessibilityLabel: String {
        if let session = model.review, !session.cards.isEmpty {
            return "이어서 정리, 남은 일 \(session.cards.count)개"
        }
        return "오늘 정리, 정하지 않은 일 \(model.pendingTasks.count)개"
    }
}

@MainActor
struct MirrorTaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneNavigationState.self) private var scene
    @Environment(\.mirrorTaskSelection) private var selectTask
    @Environment(\.mirrorCalendarDropAvailable) private var calendarDropAvailable
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let task: TaskProjection
    var onOpen: (() -> Void)? = nil
    var body: some View {
        let displayedContext = model.context
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            TaskRow(task.title, status: Binding(get: { task.status == .completed ? .completed : .open }, set: { value in
                if value != .snoozed { Task { await model.setCompleted(task, completed: value == .completed) } }
            }), due: planLabel(task.plan.target), style: rowStyle, onTap: openDetail, snoozeLabel: "내일로 미루기",
                    onSnooze: tomorrowAction(context: displayedContext), onDelete: { Task { await model.trash(task) } })
                .background {
                    if scene.selectedTaskID == task.taskID {
                        RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
                    }
                }
                .disabled(model.isSaving || model.projectionPending || task.status == .deleted)
                .accessibilityIdentifier("task.row.\(task.taskID.uuidString)")
                .contextMenu {
                    Button("상세 열기", action: openDetail)
                    Button(task.status == .completed ? "다시 열기" : "완료") { Task { await model.setCompleted(task, completed: task.status != .completed) } }
                    if task.status == .open, !model.isDetailEditing, let displayedContext,
                       model.canPostponeToTomorrow(task, context: displayedContext) {
                        Button("내일로 미루기") { Task { await model.postponeToTomorrow(task, context: displayedContext, in: scene) } }
                    }
                    if task.status == .open, !model.isDetailEditing {
                        Button("날짜 바꾸기") { model.makePicker(taskIDs: [task.taskID], in: scene) }
                        Button("당분간 보관") { Task { await model.park(task) } }
                    }
                    Button("휴지통으로 이동", role: .destructive) { Task { await model.trash(task) } }
                }
            if task.status == .open {
                Button { model.makePicker(taskIDs: [task.taskID], in: scene) } label: {
                    Text("미루기").font(.callout)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 60, minHeight: 44)
                        .background(MirrorPalette.accent.opacity(0.08), in: Capsule())
                }
                    .buttonStyle(.borderless)
                    .disabled(model.isSaving || model.projectionPending || model.isDetailEditing)
                    .accessibilityLabel("\(task.title), 미루기, 날짜 선택")
                    .accessibilityIdentifier("task.postpone.\(task.taskID.uuidString)")
                if calendarDropAvailable, let displayedContext { MirrorCalendarDragHandle(task: task, context: displayedContext) }
            }
        }
    }
    private var rowStyle: TaskRow.Style {
        var style = TaskRow.Style.standard
        style.surface = .clear
        style.text = .primary
        style.muted = .secondary
        style.dueText = MirrorPalette.supportingText
        style.cornerRadius = 10
        return style
    }
    private func tomorrowAction(context: PlanningContext?) -> (() -> Void)? {
        guard task.status == .open, !model.isDetailEditing, let context else { return nil }
        guard model.canPostponeToTomorrow(task, context: context) else { return nil }
        return { Task { await model.postponeToTomorrow(task, context: context, in: scene) } }
    }
    private func openDetail() {
        if let onOpen { onOpen() }
        else if let selectTask { selectTask(task.taskID) }
    }
}

#if os(iOS)
/// toolbar의 크기 요청과 분리해 실제 조작 영역을 구성한다.
@MainActor
private struct MirrorSheetHeader: View {
    let title: String
    let actionTitle: String
    let actionIdentifier: String
    let isDisabled: Bool
    let dynamicTypeScope: MirrorDynamicTypeValue.Scope
    let action: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button { action() } label: {
                Text(actionTitle)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(MirrorPalette.accent)
            .disabled(isDisabled)
            .accessibilityIdentifier(actionIdentifier)
            .modifier(MirrorDynamicTypeValue(scope: dynamicTypeScope))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(MirrorPalette.canvas)
    }
}
#endif

@MainActor
struct MirrorCaptureView: View {
    let request: CapturePresentationRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var title = ""
    @State private var note = ""
    @State private var sourceURL = ""
    @State private var more = false
    @State private var splitPreview = false
    @State private var requestToken = UUID().uuidString
    @State private var pendingCapture = CaptureDraftCommitState()
    @State private var pendingTitleFocus = false
    @State private var captureFlowStarted = false
    @State private var showSavedFeedback = false
    @State private var savedFeedback = "보관함에 넣었어요."
    @State private var initialPlan: PlanTarget?
    @State private var planContext: PlanningContext?
    @State private var datePickerContext: PlanningContext?
    @State private var showDatePicker = false
    private enum InputField: Hashable { case title, note, url }
    @FocusState private var focusedField: InputField?
    @State private var textEditingOwnerID = UUID()
    private var lines: [String] { title.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    private var captureBusy: Bool { pendingCapture.isSubmitting || model.isSaving }
    private var canRestoreTitleFocus: Bool {
        pendingTitleFocus && !request.single && !captureBusy && !model.projectionPending
            && !splitPreview && !showDatePicker
            && model.capturePresentation(for: request.ownerSceneID) == request
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("할 일 제목", text: $title, prompt: Text("할 일 제목").foregroundColor(MirrorPalette.inputPrompt), axis: .vertical)
                        .font(.title3)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4).focused($focusedField, equals: .title)
                        .disabled(captureBusy || model.projectionPending)
                        .accessibilityIdentifier("capture.title")
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MirrorPalette.card, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            if !more { pendingTitleFocus = false; focusedField = nil }
                            if more, focusedField == .note || focusedField == .url { focusedField = .title }
                            more.toggle()
                        } label: {
                            HStack(spacing: 12) {
                                Text("날짜·메모·링크")
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Image(systemName: more ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(captureBusy)
                        .accessibilityValue(more ? "펼침" : "접힘")
                        .accessibilityHint(more ? "추가 입력을 접습니다" : "날짜, 메모와 링크 입력을 펼칩니다")
                        .accessibilityIdentifier("capture.more")
                        if more {
                            VStack(alignment: .leading, spacing: 14) {
                                capturePlanChoices
                                TextField("메모", text: $note, axis: .vertical).lineLimit(1...10).focused($focusedField, equals: .note).disabled(captureBusy || model.projectionPending).accessibilityIdentifier("capture.note")
                                TextField("https:// 원문 링크", text: $sourceURL).focused($focusedField, equals: .url).disabled(captureBusy || model.projectionPending).accessibilityIdentifier("capture.url")
                                Text("링크를 저장해도 웹 내용을 자동으로 가져오지 않아요.").font(.caption).foregroundStyle(MirrorPalette.supportingText)
                            }.textFieldStyle(.roundedBorder).padding(.top, 12)
                        }
                    }
                    .padding(16)
                    .background(MirrorPalette.card, in: RoundedRectangle(cornerRadius: 12))
                    if !more, let initialPlan {
                        Text(planLabel(initialPlan))
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("capture.planCollapsedSummary")
                    }
                    if lines.count > 1 {
                        Button("줄마다 나누기 · \(lines.count)개 미리 보기") { splitPreview = true }.disabled(captureBusy || model.projectionPending)
                            .buttonStyle(.borderless).frame(minHeight: 44)
                    }
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(MirrorPalette.canvas)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { captureActions }
            #if os(iOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                MirrorSheetHeader(title: "일단 넣기", actionTitle: "닫기", actionIdentifier: "capture.close",
                                  isDisabled: captureBusy, dynamicTypeScope: .capture, action: closeCapture)
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            #else
            .navigationTitle("일단 넣기")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { closeCapture() }
                        .disabled(captureBusy).accessibilityIdentifier("capture.close")
                }
            }
            #endif
            .interactiveDismissDisabled(captureBusy)
            .onAppear { model.clearCaptureInputProblem(); focusedField = .title; startCaptureFlow() }
            .onChange(of: title) { _, value in
                if !value.isEmpty { pendingTitleFocus = false; showSavedFeedback = false; startCaptureFlow() }
            }
            .onChange(of: note) { _, value in if !value.isEmpty { pendingTitleFocus = false; showSavedFeedback = false } }
            .onChange(of: sourceURL) { _, value in if !value.isEmpty { pendingTitleFocus = false; showSavedFeedback = false } }
            .onChange(of: initialPlan) { _, value in
                if value != nil { pendingTitleFocus = false; showSavedFeedback = false }
            }
            .onChange(of: more) { _, expanded in
                if !expanded, focusedField == .note || focusedField == .url { focusedField = .title }
            }
            .onChange(of: focusedField, initial: true) { _, focused in model.setTextEditing(focused != nil, ownerID: textEditingOwnerID) }
            .onChange(of: canRestoreTitleFocus) { _, ready in
                guard ready, canRestoreTitleFocus else { return }
                pendingTitleFocus = false
                focusedField = .title
            }
            .onDisappear {
                pendingTitleFocus = false
                model.setTextEditing(false, ownerID: textEditingOwnerID); model.clearCaptureInputProblem()
            }
            .onChange(of: model.presentedCaptureCommittedToken) { _, token in
                acceptCaptureCommit(token)
            }
            .sheet(isPresented: $splitPreview) {
                NavigationStack {
                    List {
                        Text("각 줄이 별개의 새 작업으로 저장돼요. 저장되지 않은 줄은 입력에 남겨요.")
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line) }
                        Button("\(lines.count)개를 각각 저장", action: saveSplitCapture)
                            .disabled(captureBusy || model.projectionPending)
                    }.navigationTitle("줄마다 나누기")
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("취소") { if !captureBusy { splitPreview = false } }.disabled(captureBusy)
                        } }
                }.tint(MirrorPalette.accent)
                    #if os(macOS)
                    .frame(minWidth: 320, idealWidth: 460, minHeight: 320, idealHeight: 420)
                    #endif
                    .interactiveDismissDisabled(captureBusy)
                    .modifier(MirrorPresentationDynamicType(size: dynamicTypeSize, scope: "captureSplit"))
            }
            .sheet(isPresented: $showDatePicker, onDismiss: {
                if model.capturePresentation(for: request.ownerSceneID) == request { focusedField = .title }
            }) {
                if let datePickerContext {
                    MirrorCaptureDatePicker(context: datePickerContext) { target in
                        guard !captureBusy, !model.projectionPending else { return }
                        initialPlan = target
                        planContext = datePickerContext
                        showDatePicker = false
                        focusedField = .title
                    }
                    .modifier(MirrorPresentationDynamicType(size: dynamicTypeSize, scope: "captureDate"))
                }
            }
        }
        .tint(MirrorPalette.accent)
        #if os(macOS)
        .frame(idealWidth: 460, idealHeight: 340)
        .presentationSizing(.fitted)
        .frame(minWidth: 320, minHeight: 280)
        #endif
    }
    private var captureActions: some View {
        VStack(spacing: 8) {
            if let problem = model.problem {
                Text(problem).font(.callout).foregroundStyle(MirrorPalette.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(problem).accessibilityIdentifier("state.error")
            }
            if showSavedFeedback, model.problem == nil, !model.projectionPending, !model.isSaving {
                Text(savedFeedback).font(.callout).foregroundStyle(MirrorPalette.supportingText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("capture.feedback")
            }
            Button { save() } label: {
                Text(captureBusy ? "저장 중…" : lines.count > 1 ? "한 개로 저장" : initialPlan == nil ? "보관함에 넣기" : "날짜에 넣기")
                    .foregroundStyle(MirrorPalette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
                .buttonStyle(.borderedProminent)
                .disabled(captureBusy || model.projectionPending)
                .accessibilityIdentifier("capture.save")
                #if DEBUG && os(macOS)
                .modifier(MirrorRootDynamicTypeValue())
                #endif
                .keyboardShortcut(.return, modifiers: .command)
                #if os(macOS)
                .frame(maxWidth: 200)
                #endif
            if model.canRetryPresentedCapture(request) {
                Button(model.projectionPending ? "저장 결과 다시 확인" : "이전 입력 다시 시도", action: retryCapture)
                    .disabled(captureBusy)
                    .frame(minHeight: 44)
            }
        }.padding(12).frame(maxWidth: .infinity).background(MirrorPalette.surface)
    }
    private var capturePlanChoices: some View {
        let displayedContext = model.context
        return VStack(alignment: .leading, spacing: 10) {
            Text(initialPlan.map(planLabel) ?? "날짜는 나중에 정해도 돼요")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("capture.planSummary")
            MirrorActionGroup {
                Button("오늘") { selectInitialPlan(offset: 0, context: displayedContext) }.accessibilityIdentifier("capture.planToday")
                Button("내일") { selectInitialPlan(offset: 1, context: displayedContext) }.accessibilityIdentifier("capture.planTomorrow")
                Button("다른 날짜") {
                    guard let displayedContext else { return }
                    datePickerContext = displayedContext; focusedField = nil; showDatePicker = true
                }.accessibilityIdentifier("capture.planOther")
            }.buttonStyle(.bordered).controlSize(.regular)
            if initialPlan != nil {
                Button("날짜 정하지 않기") { showSavedFeedback = false; initialPlan = nil; planContext = nil }
                    .frame(minHeight: 44).accessibilityIdentifier("capture.planClear")
            }
        }
        .disabled(captureBusy || model.projectionPending)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("날짜 선택")
        .accessibilityIdentifier("capture.planChoices")
    }
    private func selectInitialPlan(offset: Int, context: PlanningContext?) {
        guard let context, let day = try? context.planningDay.addingDays(offset) else { return }
        planContext = context; initialPlan = .day(day)
    }
    private func closeCapture() {
        guard !captureBusy, model.closeCapture(request) else { return }
        pendingTitleFocus = false
        model.clearCaptureInputProblem()
        focusedField = nil
        dismiss()
    }
    private func save() {
        guard !captureBusy, !model.projectionPending else { return }
        let accepted = acceptCaptureCommit(model.presentedCaptureCommittedToken)
        if accepted == .clearDraft || (accepted == .removeFirstLine && title.isEmpty && sourceURL.isEmpty) { return }
        if pendingCapture.matchesWholeDraft(captureDraft), model.canRetryPresentedCapture(request) {
            retryCapture()
            return
        }
        guard let submission = pendingCapture.beginSubmission(draft: captureDraft) else { return }
        pendingTitleFocus = false
        let submitted = submission.draft
        let token = UUID().uuidString
        guard model.registerPresentedCapture(token: token, presentation: request) else {
            pendingCapture.endSubmission(submission)
            return
        }
        requestToken = token
        pendingCapture.clearPending()
        showSavedFeedback = false
        startCaptureFlow()
        Task {
            defer { pendingCapture.endSubmission(submission) }
            if await model.capture(title: submitted.title, note: submitted.note, sourceURL: submitted.sourceURL, requestToken: token,
                                   initialPlan: submitted.initialPlan, displayedContext: submitted.planContext, presentation: request) {
                title = ""; note = ""; sourceURL = ""
                initialPlan = nil; planContext = nil
                requestToken = UUID().uuidString
                captureFlowStarted = false
                finishSavedCapture()
            } else { pendingCapture.register(token: token, draft: submitted) }
        }
    }
    private func saveSplitCapture() {
        guard !captureBusy, !model.projectionPending else { return }
        let accepted = acceptCaptureCommit(model.presentedCaptureCommittedToken)
        if accepted == .clearDraft || (accepted == .removeFirstLine && lines.isEmpty) {
            splitPreview = false
            return
        }
        guard let submission = pendingCapture.beginSubmission(draft: captureDraft) else { return }
        pendingTitleFocus = false
        let submitted = submission.draft
        let submittedLines = submitted.title.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        showSavedFeedback = false
        startCaptureFlow()
        Task {
            defer { pendingCapture.endSubmission(submission) }
            var remaining = submittedLines
            for line in submittedLines {
                let remainingDraft = CaptureDraftSnapshot(title: remaining.joined(separator: "\n"),
                    note: submitted.note, sourceURL: submitted.sourceURL,
                    initialPlan: submitted.initialPlan, planContext: submitted.planContext)
                let token = UUID().uuidString
                guard model.registerPresentedCapture(token: token, presentation: request) else { break }
                requestToken = token
                pendingCapture.clearPending()
                guard await model.capture(title: line, note: submitted.note, sourceURL: submitted.sourceURL, requestToken: token,
                                          initialPlan: submitted.initialPlan, displayedContext: submitted.planContext, presentation: request) else {
                    pendingCapture.register(token: token, draft: remainingDraft, firstLine: line)
                    break
                }
                remaining.removeFirst()
            }
            title = remaining.joined(separator: "\n")
            splitPreview = false
            if remaining.isEmpty { initialPlan = nil; planContext = nil; finishSavedCapture() }
            else { focusedField = .title }
        }
    }
    private func retryCapture() {
        // pending 상태에서도 자기 재시도는 허용하되 같은 화면의 새 제출과 겹치지 않는다.
        guard !captureBusy, model.canRetryPresentedCapture(request),
              let submission = pendingCapture.beginSubmission(draft: captureDraft) else { return }
        pendingTitleFocus = false
        Task {
            defer { pendingCapture.endSubmission(submission) }
            await model.retryPresentedCapture(request)
        }
    }
    private var captureDraft: CaptureDraftSnapshot {
        CaptureDraftSnapshot(title: title, note: note, sourceURL: sourceURL, initialPlan: initialPlan, planContext: planContext)
    }
    @discardableResult
    private func acceptCaptureCommit(_ token: String?) -> CaptureDraftCommitDisposition? {
        guard token == requestToken,
              let disposition = pendingCapture.consume(token: token, draft: captureDraft) else { return nil }
        requestToken = UUID().uuidString
        switch disposition {
        case .clearDraft:
            title = ""; note = ""; sourceURL = ""
            initialPlan = nil; planContext = nil; captureFlowStarted = false
            finishSavedCapture()
        case .removeFirstLine:
            var remaining = title.components(separatedBy: .newlines)
            remaining.removeFirst(); title = remaining.joined(separator: "\n")
            if remaining.isEmpty { initialPlan = nil; planContext = nil; finishSavedCapture() }
            else { focusedField = .title }
        case .preserveDraft:
            pendingTitleFocus = false
            savedFeedback = "이전 입력은 저장됐어요. 수정한 내용은 그대로 남겼어요."
            showSavedFeedback = true
        }
        return disposition
    }
    private func finishSavedCapture() {
        // 원본 저장과 projection 갱신을 확인한 성공 경로에서만 단일 입력을 닫는다.
        let single = request.single
        savedFeedback = model.feedback ?? "보관함에 넣었어요."
        if !single { showSavedFeedback = true }
        note = ""; sourceURL = ""
        more = false
        // 제출 잠금이 풀려 TextField가 다시 활성화된 화면 갱신에서 포커스를 복원한다.
        pendingTitleFocus = !single
        focusedField = nil
        if model.finishCapture(request) { dismiss() }
    }
    private func startCaptureFlow() {
        guard !captureFlowStarted else { return }
        captureFlowStarted = true
        Task { await model.recordCaptureFlowStarted() }
    }
}

/// 선택만 하는 달력이다. 날짜를 골라도 저장 버튼 전에는 작업·계획을 쓰지 않는다.
@MainActor
struct MirrorCaptureDatePicker: View {
    @Environment(\.dismiss) private var dismiss
    let context: PlanningContext
    let choose: (PlanTarget) -> Void
    @State private var anchor: LocalDate?
    @State private var useWeek = false
    var body: some View {
        NavigationStack {
            Form {
                Text("저장할 때 함께 정할 날짜를 골라 주세요.").font(.callout)
                Toggle("요일은 나중에 정하기", isOn: $useWeek).accessibilityIdentifier("capture.planWeek")
                MirrorMonthGrid(anchor: Binding(get: { anchor ?? context.planningDay }, set: { anchor = $0 }),
                                minimum: context.planningDay) { date in
                    if useWeek, let week = try? date.mondayWeek() {
                        choose(.week(startDate: week.startDate, endExclusiveDate: week.endExclusiveDate))
                    } else { choose(.day(date)) }
                }.accessibilityIdentifier("capture.planCalendar")
            }
            .navigationTitle("날짜 선택")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("취소") { dismiss() }.accessibilityIdentifier("capture.planCancel")
            } }
        }
        .tint(MirrorPalette.accent)
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 460, minHeight: 420, idealHeight: 540)
        #endif
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case inbox, past, future, parked, completed, trash, all
    var id: String { rawValue }
    var label: String {
        switch self { case .inbox: "정하지 않은 일"; case .past: "지난 계획"; case .future: "미래 계획"; case .parked: "당분간 보관"; case .completed: "완료 기록"; case .trash: "휴지통"; case .all: "전체" }
    }
}

@MainActor @Observable
final class MirrorLibraryNavigationState {
    var filter: LibraryFilter = .inbox
    var selecting = false
    var selectedTaskIDs: Set<UUID> = []
    var pendingBatchPickerID: UUID?
    var search = ""
    var searchRequested = false
}

nonisolated struct MirrorLibrarySearchAction: Equatable, Sendable {
    let model: AppModel
    let navigation: MirrorLibraryNavigationState
    let scene: SceneNavigationState
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model === rhs.model && lhs.navigation === rhs.navigation && lhs.scene === rhs.scene }
    @MainActor func callAsFunction() {
        guard model.navigationTarget(in: scene) != nil else { return }
        model.selectDestination(.library, in: scene)
        navigation.searchRequested = true
    }
}

@MainActor
struct MirrorLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneNavigationState.self) private var scene
    @Environment(\.mirrorTaskSelection) private var selectTask
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding private var filter: LibraryFilter
    @Binding private var selecting: Bool
    @Binding private var selectedTaskIDs: Set<UUID>
    @Binding private var pendingBatchPickerID: UUID?
    @Binding private var search: String
    @Binding private var searchRequested: Bool
    @FocusState private var searchFocused: Bool
    @State private var textEditingOwnerID = UUID()
    init(navigation: MirrorLibraryNavigationState) {
        @Bindable var state = navigation
        _filter = $state.filter
        _selecting = $state.selecting
        _selectedTaskIDs = $state.selectedTaskIDs
        _pendingBatchPickerID = $state.pendingBatchPickerID
        _search = $state.search
        _searchRequested = $state.searchRequested
    }
    private var filtered: [TaskProjection] {
        model.tasks.filter { task in
            let matchesSearch = search.isEmpty || task.title.localizedStandardContains(search)
                || task.content.note?.localizedStandardContains(search) == true
                || task.content.sourceURL?.localizedStandardContains(search) == true
            guard matchesSearch else { return false }
            if !search.isEmpty, filter == .inbox { return task.status != .deleted }
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
    private var selectableTaskIDs: Set<UUID> {
        Set(filtered.filter { $0.status == .open }.map(\.taskID))
    }
    private var searchesWholeLibrary: Bool { !search.isEmpty && filter == .inbox }
    var body: some View {
        @Bindable var model = model
        let eligibleTaskIDs = filtered.filter { $0.status == .open }.map(\.taskID)
        let selectedIDs = selectedTaskIDs.intersection(Set(eligibleTaskIDs))
        let bulkTaskIDs = Set(eligibleTaskIDs.prefix(20))
        let bulkSelected = !bulkTaskIDs.isEmpty && selectedIDs == bulkTaskIDs
        let bulkLabel = bulkSelected ? "선택 해제" : eligibleTaskIDs.count > 20 ? "앞 20개 선택" : "모두 선택"
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField(filter == .inbox ? "미래·완료·보관까지 검색" : "\(filter.label)에서 검색", text: $search,
                                  prompt: Text(filter == .inbox ? "미래·완료·보관까지 검색" : "\(filter.label)에서 검색")
                                    .foregroundColor(MirrorPalette.inputPrompt))
                            .textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("library.search")
                            .onSubmit { searchFocused = false; model.setTextEditing(false, ownerID: textEditingOwnerID) }
                        if !search.isEmpty {
                            Button { search = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                                .buttonStyle(.plain)
                                .accessibilityLabel("검색어 지우기")
                                .accessibilityIdentifier("library.clearSearch")
                        }
                    }
                    .padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    MirrorActionGroup {
                        Picker("목록", selection: $filter) {
                            ForEach(LibraryFilter.allCases) { option in
                                Text(option == .inbox && !search.isEmpty ? "전체에서 검색" : option.label).tag(option)
                            }
                        }.pickerStyle(.menu).labelsHidden()
                            .accessibilityLabel(searchesWholeLibrary ? "검색 범위, 전체" : "목록")
                            .frame(minHeight: 44)
                        Button {
                            selectedTaskIDs.removeAll()
                            pendingBatchPickerID = nil
                            selecting.toggle()
                        } label: {
                            Text(selecting ? "선택 마치기" : "선택")
                                #if os(iOS)
                                .frame(minWidth: 44, minHeight: 48).contentShape(Rectangle())
                                #endif
                        }
                            .buttonStyle(.borderless)
                            #if os(iOS)
                            .frame(minWidth: 44, minHeight: 48)
                            #else
                            .frame(minWidth: 44, minHeight: 44)
                            #endif
                            .accessibilityLabel(selecting ? "여러 개 선택 마치기" : "여러 개 선택")
                            .accessibilityIdentifier("library.selectToggle")
                    }
                    if !search.isEmpty {
                        Text(searchesWholeLibrary ? "미래·완료·보관한 일까지 검색해요. 휴지통은 제외해요." : "\(filter.label)에서 검색해요.")
                            .font(.caption).foregroundStyle(MirrorPalette.supportingText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("library.searchScope")
                    }
                    if selecting {
                        Text("현재 목록의 미완료 작업만, 최대 20개까지 선택해요.")
                            .font(.caption).foregroundStyle(.secondary)
                        MirrorActionGroup {
                            if !bulkTaskIDs.isEmpty {
                                Button {
                                    if bulkSelected { selectedTaskIDs.removeAll() }
                                    else { selectedTaskIDs = bulkTaskIDs }
                                } label: {
                                    Text(bulkLabel)
                                        #if os(iOS)
                                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                        #endif
                                }
                                    .buttonStyle(.borderless).frame(minHeight: 44)
                                    .accessibilityLabel("\(bulkLabel), 현재 목록")
                                    .accessibilityValue("선택한 \(selectedIDs.count)개, 대상 \(bulkTaskIDs.count)개")
                                    .accessibilityHint("검색과 목록에 표시된 미완료 작업만 선택해요.")
                                    .accessibilityIdentifier("library.selectAll")
                            }
                        }
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
                                toggleSelection(task)
                            } label: {
                                Image(systemName: selectedTaskIDs.contains(task.taskID) ? "checkmark.square" : "square")
                                    #if os(iOS)
                                    .frame(minWidth: 48, minHeight: 48).contentShape(Rectangle())
                                    #endif
                            }
                                .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
                                .accessibilityLabel("\(task.title), 배치 대상 선택")
                                .accessibilityValue(selectedTaskIDs.contains(task.taskID) ? "선택됨" : "선택 안 됨")
                                .accessibilityIdentifier("task.select.\(task.taskID.uuidString)")
                        }
                        if selecting {
                            selectionRow(task)
                        } else if task.status == .deleted {
                            Button { openDetail(task) } label: {
                                VStack(alignment: .leading) { Text(task.title); Text("휴지통 · \(planLabel(task.plan.target))").font(.caption) }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button("복구") { Task { await model.restore(task) } }.disabled(model.isSaving)
                        } else { MirrorTaskRow(task: task, onOpen: { openDetail(task) }) }
                    }.listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            } header: {
                Text(search.isEmpty ? filter.label : "검색 결과")
                    .foregroundStyle(MirrorPalette.supportingText)
                    .accessibilityIdentifier("library.resultsTitle")
            }
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .navigationTitle("보관함")
        .accessibilityIdentifier("library.list")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                VStack(spacing: 0) {
                    Button {
                        let taskIDs = eligibleTaskIDs.filter(selectedIDs.contains)
                        let previousPickerID = model.picker(in: scene)?.id
                        model.makePicker(taskIDs: taskIDs, in: scene)
                        if let request = model.picker(in: scene), request.id != previousPickerID, request.taskIDs == taskIDs,
                           request.review == nil, request.widgetState == nil {
                            pendingBatchPickerID = request.id
                            model.registerLibraryBatchPicker(request)
                        }
                    } label: {
                        Text("선택한 \(selectedIDs.count)개 날짜 배치")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedIDs.isEmpty || selectedIDs.count > 20 || model.isSaving
                              || model.projectionPending || model.isDetailEditing)
                    .accessibilityIdentifier("library.batchPlan")
                    #if os(macOS)
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 560 : 320)
                    #else
                    .frame(maxWidth: 560)
                    #endif
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(MirrorPalette.surface)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.batchFooter")
            }
        }
        .onChange(of: model.completedBatchPickerID, initial: true) { _, receipt in
            guard let pendingBatchPickerID, let receipt, receipt == pendingBatchPickerID else { return }
            selecting = false; selectedTaskIDs.removeAll(); self.pendingBatchPickerID = nil
        }
        .onChange(of: selectableTaskIDs, initial: true) { _, visibleIDs in
            selectedTaskIDs.formIntersection(visibleIDs)
        }
        .onChange(of: searchRequested, initial: true) { _, requested in if requested { searchFocused = true; searchRequested = false } }
        .onChange(of: searchFocused, initial: true) { _, focused in model.setTextEditing(focused, ownerID: textEditingOwnerID) }
        .onDisappear { model.setTextEditing(false, ownerID: textEditingOwnerID) }
    }
    private func toggleSelection(_ task: TaskProjection) {
        guard task.status == .open else { return }
        if selectedTaskIDs.contains(task.taskID) { selectedTaskIDs.remove(task.taskID) }
        else if selectedTaskIDs.count < 20 { selectedTaskIDs.insert(task.taskID) }
        else { model.problem = "한 번에 최대 20개를 선택해 주세요." }
    }
    private func selectionRow(_ task: TaskProjection) -> some View {
        let status = task.status == .completed ? "완료" : task.status == .deleted ? "휴지통" : "미완료"
        return Button { toggleSelection(task) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.body.weight(.medium)).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(planLabel(task.plan.target)).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            }
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.title)
        .accessibilityValue(task.status == .open
            ? "\(status), 배치: \(planLabel(task.plan.target)), \(selectedTaskIDs.contains(task.taskID) ? "선택됨" : "선택 안 됨")"
            : "\(status), 배치: \(planLabel(task.plan.target))")
        .accessibilityHint(task.status == .open ? "일괄 날짜 배치 대상을 선택하거나 해제해요." : "미완료 작업만 선택할 수 있어요.")
        .accessibilityIdentifier("task.row.\(task.taskID.uuidString)")
        .disabled(task.status != .open)
    }
    private func openDetail(_ task: TaskProjection) {
        searchFocused = false
        model.setTextEditing(false, ownerID: textEditingOwnerID)
        if let selectTask { selectTask(task.taskID) }
    }
}

@MainActor
struct MirrorReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneNavigationState.self) private var scene
    let presentation: ScenePresentationRequest
    @AccessibilityFocusState private var cardFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var exposureID = UUID()
    @State private var detailNavigation = MirrorDetailNavigationState()

    var body: some View {
        @Bindable var detailState = detailNavigation
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
                                    .font(.caption).foregroundStyle(MirrorPalette.supportingText)
                            }
                        }
                        if let task = model.currentReviewTask, let card = model.currentCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top, spacing: 12) {
                                    ExpandableText(task.title, lineLimit: 3, togglesOnTap: false,
                                                   style: .init(link: MirrorPalette.accent),
                                                   paragraphAccessibilityIdentifier: "review.card",
                                                   paragraphAccessibilityFocus: $cardFocused)
                                        .font(.title3.weight(.semibold))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(task.taskID)
                                    Button { taskSelectionAction(task.taskID) } label: {
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(MirrorPalette.canvas, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            #endif
            .onChange(of: model.currentCard?.id, initial: true) { _, _ in
                cardFocused = false
                Task { @MainActor in await Task.yield(); cardFocused = true }
            }
            .onChange(of: model.currentReviewFeedback) { _, message in
                if let message { AccessibilityNotification.Announcement(message).post() }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.currentCard?.id)
            .sheet(item: reviewPickerPresentation) {
                MirrorPlanPicker(request: $0).modifier(MirrorPresentationDynamicType(size: dynamicTypeSize, scope: "plan"))
            }
            .sheet(item: reviewDetailPresentation) { detail in
                NavigationStack {
                    if let task = model.tasks.first(where: { $0.taskID == detail.id }) { MirrorTaskDetail(task: task, closeRequestedID: $detailState.closeRequestedID, draftTaskID: $detailState.draftTaskID, selectionRequested: $detailState.selectionRequested) }
                }
                .modifier(MirrorPresentationDynamicType(size: dynamicTypeSize, scope: "detail"))
            }
            .modifier(MirrorDeadlineConfirmation(enabled: model.picker(in: scene) == nil && scene.selectedTaskID == nil))
        }
        .environment(\.mirrorTaskSelection, taskSelectionAction)
        .tint(MirrorPalette.accent)
        .disabled(model.isSaving)
        .frame(minWidth: 300, idealWidth: 580, minHeight: 460)
        #if os(macOS)
        .frame(idealHeight: 640)
        #endif
        .onAppear { model.setReviewVisible(exposureID, visible: true) }
        .onDisappear { model.setReviewVisible(exposureID, visible: false) }
        .interactiveDismissDisabled(model.isSaving || model.isDetailEditing(in: scene))
    }

    private var reviewPickerPresentation: Binding<PlanPickerRequest?> {
        let displayedRequest = scene.selectedTaskID == nil ? model.picker(in: scene) : nil
        return Binding(get: { scene.selectedTaskID == nil ? model.picker(in: scene) : nil }, set: { presented in
            guard presented == nil, let displayedRequest else { return }
            model.closePlanPicker(requestID: displayedRequest.id)
        })
    }
    private var reviewDetailPresentation: Binding<MirrorDetailRequest?> {
        let displayedTaskID = scene.selectedTaskID
        let displayedTarget = model.navigationTarget(in: scene)
        return Binding(get: {
            model.isReviewPresented(in: scene) ? scene.selectedTaskID.map(MirrorDetailRequest.init(id:)) : nil
        }, set: { detail in
            guard detail == nil, let displayedTaskID, scene.selectedTaskID == displayedTaskID,
                  let displayedTarget, model.navigationTarget(in: scene) == displayedTarget,
                  model.reviewPresentation(in: scene) == presentation, !model.isSaving else { return }
            if detailNavigation.draftTaskID == displayedTaskID || model.isDetailEditing(in: scene) {
                detailNavigation.closeRequestedID = displayedTaskID
            } else { model.selectTask(nil, in: scene) }
        })
    }
    private var taskSelectionAction: MirrorTaskSelectionAction {
        MirrorTaskSelectionAction(model: model, navigation: detailNavigation, scene: scene)
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
        Button { Task { await model.decide(.day(day), card: card, session: session, in: scene) } } label: {
            Text("오늘").foregroundStyle(MirrorPalette.onAccent)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("오늘, \(AppDate.label(day))에 배치, 완료 아님").accessibilityIdentifier("review.today")
        .keyboardShortcut("1", modifiers: []).disabled(model.isTextEditing || model.isDetailEditing)
    }

    private func tomorrowButton(_ day: LocalDate, card: ReviewCard, session: AppReviewSession) -> some View {
        Button { Task { await model.decide(.day(day), card: card, session: session, in: scene) } } label: {
            Text("내일").fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("내일, \(AppDate.label(day))에 배치").accessibilityIdentifier("review.tomorrow")
        .keyboardShortcut("2", modifiers: []).disabled(model.isTextEditing || model.isDetailEditing)
    }

    private func thisWeekButton(_ week: WeekRange, card: ReviewCard, session: AppReviewSession) -> some View {
        Button { model.makePicker(taskIDs: [card.taskID], week: week, reviewCard: card, reviewSession: session, in: scene) } label: {
            Text("이번 주").font(.callout.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("3", modifiers: []).disabled(model.isTextEditing || model.isDetailEditing)
        .accessibilityLabel("이번 주, \(weekLabel(week)), 날짜 선택").accessibilityIdentifier("review.thisWeek")
        .help("이번 주 날짜 선택 · 키보드 3")
    }

    private func nextWeekButton(_ week: WeekRange, card: ReviewCard, session: AppReviewSession) -> some View {
        Button { model.makePicker(taskIDs: [card.taskID], week: week, reviewCard: card, reviewSession: session, in: scene) } label: {
            Text("다음 주").font(.callout.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("4", modifiers: []).disabled(model.isTextEditing || model.isDetailEditing)
        .accessibilityLabel("다음 주, \(weekLabel(week)), 날짜 선택").accessibilityIdentifier("review.nextWeek")
        .help("다음 주 날짜 선택 · 키보드 4")
    }

    private func otherDayButton(card: ReviewCard, session: AppReviewSession) -> some View {
        Button { model.makePicker(taskIDs: [card.taskID], reviewCard: card, reviewSession: session, in: scene) } label: {
            Text("다른 날").font(.callout.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("5", modifiers: []).disabled(model.isTextEditing || model.isDetailEditing)
        .accessibilityLabel("다른 날, 달력에서 날짜 선택").accessibilityIdentifier("review.other")
        .help("달력에서 날짜 선택 · 키보드 5")
    }

    @ViewBuilder private var reviewFeedback: some View {
        if model.currentReviewFeedback != nil || model.currentReviewUndo != nil {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                if let feedback = model.currentReviewFeedback {
                    Text(feedback).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("state.feedback")
                }
                if let undo = model.currentReviewUndo, let sessionID = model.review?.id {
                    Button("되돌리기") { Task { await model.undoReview(operationID: undo.id, sessionID: sessionID) } }
                        .frame(minHeight: 44)
                        .disabled(model.projectionPending)
                        .accessibilityLabel("직전 결정 되돌리기")
                        .accessibilityIdentifier("task.undo")
                }
            }
        }
        if let problem = model.problem {
            VStack(alignment: .leading, spacing: 8) {
                Text(problem).foregroundStyle(MirrorPalette.errorText).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(problem).accessibilityIdentifier("state.error")
                Button("최신 상태 확인") { Task { await model.refreshReviewCard() } }
                    .frame(minHeight: 44).accessibilityIdentifier("state.retry")
            }
        }
        if model.projectionPending {
            Button("저장 결과 다시 확인") { Task { await model.retry(in: scene) } }.frame(minHeight: 44)
        }
    }

    private var reviewFooter: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            if let session = model.review {
                Text("이번에 정한 \(session.decidedToday + session.decidedElsewhere)개")
                    .font(.caption).foregroundStyle(MirrorPalette.supportingText)
                    .accessibilityIdentifier("review.progress")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { Task { await model.finishReview(in: scene) } } label: {
                HStack {
                    if model.isSaving { ProgressView().controlSize(.small) }
                    Text(model.isSaving ? "저장 중…" : "오늘은 여기까지")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 44)
            }
            .accessibilityLabel("오늘은 여기까지")
            .accessibilityValue(model.isSaving ? "저장 중, 잠시 기다려 주세요" : "정리를 마치고 오늘 목록 보기")
            .modifier(MirrorDynamicTypeValue(scope: .review))
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let request: PlanPickerRequest
    @State private var monthAnchor: LocalDate?
    @State private var useWeek = false
    @State private var showDates = false
    @State private var showTaskTitles = false
    private var usesQuickChoices: Bool { request.review == nil && request.widgetState == nil }
    private var planChoicesDisabled: Bool {
        request.widgetState == nil && (model.projectionPending || model.hasPendingPlanPickerDecision(request))
    }
    @ViewBuilder var body: some View {
        Group {
            if model.completedWidgetPickerID == request.id {
                MirrorWidgetPlanCompletion(request: request)
            } else { planner }
        }
        .interactiveDismissDisabled(model.isSaving)
    }
    private var planner: some View {
        NavigationStack {
            Form {
                if request.week == nil, usesQuickChoices {
                    Section {
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
                    } header: {
                        Text("빠르게 정하기").foregroundStyle(MirrorPalette.supportingText)
                    }
                    .disabled(planChoicesDisabled)
                }
                Section {
                    if request.taskIDs.count > 1 {
                        Button { showTaskTitles.toggle() } label: {
                            HStack(spacing: 12) {
                                Text("선택한 작업 \(request.taskIDs.count)개")
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Image(systemName: showTaskTitles ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            #if os(iOS)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            #else
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            #endif
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("선택한 작업 \(request.taskIDs.count)개")
                        .accessibilityIdentifier("plan.tasksDisclosure")
                        .accessibilityValue(showTaskTitles ? "펼쳐짐" : "접힘")
                        if showTaskTitles { taskTitles }
                    } else {
                        taskTitles
                    }
                } footer: {
                    Text("계획 날짜를 바꿔도 실제 마감은 바뀌지 않아요.")
                        .foregroundStyle(MirrorPalette.supportingText)
                }
                if let week = request.week {
                    Section {
                        weekDateGrid(week)
                        Button { choose(.week(startDate: week.startDate, endExclusiveDate: week.endExclusiveDate)) } label: {
                            Text("요일은 나중에 정하기").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("plan.weekOnly")
                    } header: {
                        Text(weekLabel(week)).foregroundStyle(MirrorPalette.supportingText)
                    }
                    .disabled(planChoicesDisabled)
                } else {
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
                    .disabled(planChoicesDisabled)
                    Section {
                        Button("당분간 보관") { choose(.parked) }.accessibilityIdentifier("plan.park")
                    }
                    .disabled(planChoicesDisabled)
                }
                if let target = model.pendingPlanPickerTarget(request) {
                    Text("‘\(planLabel(target))’ 저장 결과를 먼저 확인해 주세요.")
                        .accessibilityIdentifier("plan.pending")
                    if model.hasUnconfirmedPlanPickerResult(request) {
                        Text("닫기는 저장 요청을 취소하지 않아요. 닫은 뒤에도 결과를 다시 확인할 수 있어요.")
                            .font(.caption).foregroundStyle(MirrorPalette.supportingText)
                    }
                    Button("저장 결과 다시 확인") { Task { await model.retryPlanPicker(requestID: request.id) } }
                        .disabled(!model.canRetryPlanPicker(request))
                        .frame(minHeight: 44).accessibilityIdentifier("plan.retry")
                }
                if let problem = model.problem { Text(problem).foregroundStyle(MirrorPalette.errorText) }
            }
            .formStyle(.grouped)
            #if os(iOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                MirrorSheetHeader(title: request.taskIDs.count > 1 ? "여러 개 날짜 배치" : "미루기",
                                  actionTitle: model.hasUnconfirmedPlanPickerResult(request) ? "닫기" : "취소",
                                  actionIdentifier: "plan.cancel", isDisabled: model.isSaving, dynamicTypeScope: .plan) {
                    model.closePlanPicker(requestID: request.id)
                }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            #else
            .navigationTitle(request.taskIDs.count > 1 ? "여러 개 날짜 배치" : "미루기")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { model.closePlanPicker(requestID: request.id) } label: {
                        Text(model.hasUnconfirmedPlanPickerResult(request) ? "닫기" : "취소")
                    }
                    .accessibilityIdentifier("plan.cancel")
                    .modifier(MirrorDynamicTypeValue(scope: .plan))
                }
            }
            #endif
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
            .frame(minWidth: 300, idealWidth: 460, minHeight: 320, idealHeight: request.week == nil ? 400 : 560)
            #endif
            .modifier(MirrorDeadlineConfirmation(enabled: true))
    }
    @ViewBuilder private var taskTitles: some View {
        ForEach(request.taskIDs, id: \.self) { id in
            let title = model.tasks.first { $0.taskID == id }?.title ?? "작업을 찾을 수 없어요"
            ExpandableText(title, lineLimit: 2, togglesOnTap: false,
                           style: .init(link: MirrorPalette.accent),
                           paragraphAccessibilityIdentifier: "plan.task.\(id.uuidString)")
                .id(id)
        }
    }
    private func weekDateGrid(_ week: WeekRange) -> some View {
        let singleColumn = [GridItem(.flexible(), alignment: .leading)]
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                LazyVGrid(columns: singleColumn, alignment: .leading, spacing: 8) {
                    weekDateButtons(week)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    LazyVGrid(columns: [
                        GridItem(.flexible(minimum: 160), spacing: 8, alignment: .leading),
                        GridItem(.flexible(minimum: 160), alignment: .leading)
                    ], alignment: .leading, spacing: 8) {
                        weekDateButtons(week)
                    }
                    .frame(minWidth: 328)
                    LazyVGrid(columns: singleColumn, alignment: .leading, spacing: 8) {
                        weekDateButtons(week)
                    }
                }
            }
        }
    }

    @ViewBuilder private func weekDateButtons(_ week: WeekRange) -> some View {
        ForEach(0..<7) { offset in
            if let date = try? week.startDate.addingDays(offset) {
                Button { choose(.day(date)) } label: {
                    Text(AppDate.label(date))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.borderless)
                    .disabled(date < request.displayedContext.planningDay)
                    .accessibilityLabel("\(AppDate.label(date)), \(date < request.displayedContext.planningDay ? "지나간 날짜라 선택할 수 없음" : "이 날짜로 배치")")
                    .accessibilityIdentifier("plan.day.\(date.iso8601)")
            }
        }
    }

    private func choose(_ target: PlanTarget) { Task { await model.choosePlan(request, target: target, fromPicker: true) } }
}

@MainActor
struct MirrorWidgetPlanCompletion: View {
    @Environment(AppModel.self) private var model
    let request: PlanPickerRequest
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(MirrorPalette.accent).accessibilityHidden(true)
                    Text("날짜를 정했어요").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(model.feedback ?? "선택한 날짜에 넣었어요.").fixedSize(horizontal: false, vertical: true)
                    Button { model.finishWidgetPlan(request, resume: true) } label: {
                        Text("이어서 정리").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("widget.nextReview")
                    Button { model.finishWidgetPlan(request, resume: false) } label: {
                        Text("오늘 목록").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).accessibilityIdentifier("widget.nextToday")
                }.padding(24).frame(maxWidth: 480, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("저장 완료")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("닫기") { model.closePlanPicker(requestID: request.id) }.accessibilityIdentifier("widget.nextClose")
            } }
        }.tint(MirrorPalette.accent)
    }
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
                availableDateList
            } else {
                ViewThatFits(in: .horizontal) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: 0), count: 7), spacing: 4) {
                        ForEach(["월", "화", "수", "목", "금", "토", "일"], id: \.self) { Text($0).font(.caption).accessibilityHidden(true) }
                        ForEach(0..<leadingSlots, id: \.self) { _ in Color.clear.frame(height: 44).accessibilityHidden(true) }
                        ForEach(days, id: \.self) { date in dateButton(date, fullLabel: false) }
                    }
                    .frame(minWidth: 308)
                    VStack(spacing: 12) {
                        availableDateList
                    }
                }
            }
        }
    }
    @ViewBuilder private var availableDateList: some View {
        let availableDates = days.filter { $0 >= minimum }
        if availableDates.isEmpty {
            Text("이 달에는 선택할 수 있는 날짜가 없어요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(availableDates, id: \.self) { date in dateButton(date, fullLabel: true) }
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

/// 표시 전에 claim을 확보한다. 창이나 sheet가 사라져도 다른 표시 회차의 claim을 해제하지 않는다.
@MainActor @Observable
private final class MirrorDeadlineEditingRequest: Identifiable {
    struct Submission {
        let task: TaskProjection
        let deadline: Deadline
        let alarmAt: Date?
    }
    nonisolated let id: UUID
    let claim: AppModel.DetailEditingClaim
    private let model: AppModel
    private let policyRevision: String
    var task: TaskProjection
    var date: Date
    var precise: Bool
    var alarm: Bool
    var alarmAt: Date
    let timeZoneID: String
    var submitting = false
    var showDiscardConfirmation = false
    var saveConflict = false
    var pendingSubmission: Submission?
    private(set) var closed = false
    private var initialDeadline: Deadline?
    private var initialAlarmAt: Date?
    private(set) var savedDeadline: Deadline?

    init?(task: TaskProjection, model: AppModel, scene: SceneNavigationState) {
        let ownerID = UUID()
        guard let claim = model.beginDetailEditing(ownerID: ownerID, task: task, in: scene) else { return nil }
        id = ownerID; self.claim = claim; self.model = model; self.task = task
        policyRevision = model.preferences.policyRevision
        let initialDate: Date
        switch task.deadline {
        case let .day(day, zone):
            timeZoneID = zone; initialDate = AppDate.instant(day, zone: zone) ?? model.now; precise = false
        case let .instant(instant, zone):
            timeZoneID = zone; initialDate = instant; precise = true
        case nil:
            timeZoneID = model.preferences.timeZoneID; initialDate = model.now; precise = false
        }
        date = initialDate
        alarmAt = model.preferences.deadlineAlarmDates[task.taskID] ?? initialDate
        alarm = model.preferences.deadlineAlarmDates[task.taskID] != nil
        initialDeadline = deadline
        initialAlarmAt = alarm ? alarmAt : nil
    }
    deinit {
        // 표시되기 전에 host가 제거된 경우도 원래 claim만 정리한다.
        let model = model, ownerID = id, claim = claim
        Task { @MainActor in model.endDetailEditing(ownerID: ownerID, claim: claim) }
    }
    var isCurrent: Bool { !closed && model.isCurrentDetailEditing(ownerID: id, claim: claim) }
    var deadline: Deadline? {
        if precise { return .instant(utcTimestamp: date, displayTimeZoneID: timeZoneID) }
        guard let day = try? PlanningContext.capture(at: date, timeZoneID: timeZoneID, policyRevision: policyRevision).planningDay else { return nil }
        return .day(localDate: day, timeZoneID: timeZoneID)
    }
    var hasUnsavedChanges: Bool { deadline != initialDeadline || (alarm ? alarmAt : nil) != initialAlarmAt }
    var deadlineChangedExternally: Bool {
        model.tasks.first { $0.taskID == task.taskID }?.versions[.deadline] != task.versions[.deadline]
    }
    func requestClose() -> Bool {
        if closed { return true }
        guard !submitting, !model.isSaving else { return false }
        if hasUnsavedChanges { showDiscardConfirmation = true; return false }
        finish()
        return true
    }
    func finish() {
        guard !closed else { return }
        closed = true
        model.endDetailEditing(ownerID: id, claim: claim)
    }
    func acceptSavedDeadline(_ deadline: Deadline) -> Bool {
        guard isCurrent, let latest = model.tasks.first(where: { $0.taskID == task.taskID }), latest.deadline == deadline else { return false }
        task = latest; savedDeadline = deadline; initialDeadline = deadline
        return true
    }
    func acceptSavedAlarm(_ fireAt: Date?) { initialAlarmAt = fireAt }
}

@MainActor
struct MirrorTaskDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(SceneNavigationState.self) private var scene
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let task: TaskProjection
    @Binding private var closeRequestedID: UUID?
    @Binding private var draftTaskID: UUID?
    @Binding private var selectionRequested: MirrorTaskSelectionRequest?
    @State private var discardSelectionRequest: MirrorTaskSelectionRequest?
    @State private var discardRequestedID: UUID?
    @State private var showDiscardConfirmation = false
    @State private var title = ""
    @State private var note = ""
    @State private var link = ""
    @State private var editing = false
    @State private var editingSnapshot: TaskProjection?
    @State private var detailEditorOwnerID = UUID()
    @State private var editingClaim: AppModel.DetailEditingClaim?
    @State private var deadlineEditor: MirrorDeadlineEditingRequest?
    @State private var showHistory = false
    @State private var showNotes = false
    init(task: TaskProjection, closeRequestedID: Binding<UUID?> = .constant(nil), draftTaskID: Binding<UUID?> = .constant(nil),
         selectionRequested: Binding<MirrorTaskSelectionRequest?> = .constant(nil)) {
        self.task = task; self._closeRequestedID = closeRequestedID; self._draftTaskID = draftTaskID
        self._selectionRequested = selectionRequested
    }
    private var hasUnsavedChanges: Bool {
        guard editing else { return false }
        guard let original = editingSnapshot, original.taskID == task.taskID else { return true }
        return title != original.title || note != (original.content.note ?? "") || link != (original.content.sourceURL ?? "")
    }
    private func finishEditing() {
        model.endDetailEditing(ownerID: detailEditorOwnerID, claim: editingClaim)
        editingClaim = nil; editing = false; editingSnapshot = nil
    }
    private func requestClose() {
        guard scene.selectedTaskID == task.taskID, !model.isSaving,
              !editing || editingSnapshot?.taskID == task.taskID else { return }
        if hasUnsavedChanges {
            guard !model.projectionPending else { return }
            discardSelectionRequest = nil
            if selectionRequested?.ownerID == task.taskID { selectionRequested = nil }
            discardRequestedID = task.taskID; showDiscardConfirmation = true
        }
        else { finishEditing(); model.selectTask(nil, in: scene) }
    }
    private func selectionIsCurrent(_ request: MirrorTaskSelectionRequest) -> Bool {
        selectionRequested == request && request.ownerID == task.taskID && scene.selectedTaskID == task.taskID
            && request.navigation == model.navigationTarget(in: scene)
            && request.workspaceKey == task.workspaceKey && request.workspaceEpoch == task.workspaceEpoch
            && (!editing || (editingSnapshot?.taskID == task.taskID
                && editingSnapshot?.workspaceKey == request.workspaceKey && editingSnapshot?.workspaceEpoch == request.workspaceEpoch))
            && model.tasks.contains { $0.taskID == request.destinationID
                && $0.workspaceKey == request.workspaceKey && $0.workspaceEpoch == request.workspaceEpoch }
    }
    private var actionMaxWidth: CGFloat {
        #if os(macOS)
        return dynamicTypeSize.isAccessibilitySize ? .infinity : 200
        #else
        return .infinity
        #endif
    }
    private var actionMinHeight: CGFloat {
        #if os(macOS)
        return dynamicTypeSize.isAccessibilitySize ? 44 : 20
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
                        .font(.caption.weight(.medium)).foregroundStyle(MirrorPalette.supportingText)
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
                                Text(problem).foregroundStyle(MirrorPalette.errorText).accessibilityLabel(problem).accessibilityIdentifier("state.error")
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ExpandableText(task.title, lineLimit: 3, togglesOnTap: false,
                                           style: .init(link: MirrorPalette.accent),
                                           paragraphAccessibilityIdentifier: "detail.contentTitle")
                                .font(.title2.weight(.semibold)).textSelection(.enabled)
                                .id(task.taskID)
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
                                guard let claim = model.beginDetailEditing(ownerID: detailEditorOwnerID, task: task, in: scene) else { return }
                                editingClaim = claim
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
                            Label("계획", systemImage: "calendar").font(.caption.weight(.semibold)).foregroundStyle(MirrorPalette.supportingText)
                            Text(planLabel(task.plan.target)).font(.body).accessibilityIdentifier("detail.plan")
                            if task.status == .open {
                                MirrorActionGroup {
                                    if !model.isReviewPresented(in: scene), let displayedContext = model.context,
                                       model.canPostponeToTomorrow(task, context: displayedContext) {
                                        Button {
                                            Task { await model.postponeToTomorrow(task, context: displayedContext, in: scene) }
                                        } label: {
                                            Text("내일로 미루기").frame(minHeight: 44)
                                        }
                                        .accessibilityIdentifier("detail.postponeTomorrow")
                                        .disabled(model.projectionPending)
                                    }
                                    Button { model.makePicker(taskIDs: [task.taskID], in: scene) } label: {
                                        Text("날짜 바꾸기").frame(minHeight: 44)
                                    }
                                    .disabled(model.projectionPending)
                                }.buttonStyle(.bordered).frame(minHeight: 44)
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            if task.deadline != nil {
                                Label("실제 마감 · 계획과 별개", systemImage: "flag")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(deadlineLabel(task.deadline, context: model.context))
                                Button("실제 마감 편집", action: openDeadlineEditor).buttonStyle(.borderless).frame(minHeight: 44)
                                Text(model.preferences.deadlineAlarmDates[task.taskID].map { "이 기기 알림: \($0.formatted())" } ?? "이 작업의 실제 마감 알림은 꺼져 있어요.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button(action: openDeadlineEditor) { Label("실제 마감 추가", systemImage: "flag") }
                                    .buttonStyle(.borderless).frame(minHeight: 44)
                            }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Button { showHistory.toggle() } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: showHistory ? "chevron.down" : "chevron.right")
                                        .font(.caption.weight(.semibold)).accessibilityHidden(true)
                                    Text("변경 이력과 관리")
                                        .foregroundStyle(MirrorPalette.supportingText)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("변경 이력과 관리")
                            .accessibilityValue(showHistory ? "펼쳐짐" : "접힘")
                            .accessibilityIdentifier("detail.history")
                            if showHistory {
                                VStack(alignment: .leading, spacing: 16) {
                                    if task.status == .open {
                                        Button("당분간 보관") { Task { await model.park(task) } }.frame(minHeight: 44)
                                    }
                                    if task.deadline != nil {
                                        Button("실제 마감 알림 설정", action: openDeadlineEditor).frame(minHeight: 44)
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
                                                Button("이 변경 되돌리기") { Task { await model.undo(record) } }
                                                    .frame(minHeight: 44)
                                                    .accessibilityIdentifier("history.undo.\(record.commandKind.rawValue).\(record.operationID)")
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
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: 600, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if editing {
                VStack(alignment: .leading, spacing: 8) {
                    if let feedback = model.detailEditingFeedback {
                        Text(feedback).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("detail.feedback")
                    }
                    Button {
                        Task {
                            let ownerID = detailEditorOwnerID
                            guard let original = editingSnapshot, original.taskID == task.taskID, let claim = editingClaim,
                                  model.canSaveDetailEditing(ownerID: ownerID, claim: claim) else { return }
                            if await model.edit(original, title: title, note: note, sourceURL: link) {
                                guard editingClaim == claim, model.canSaveDetailEditing(ownerID: ownerID, claim: claim) else { return }
                                finishEditing()
                            }
                        }
                    } label: {
                        Text("내용 저장").foregroundStyle(MirrorPalette.onAccent)
                            .frame(maxWidth: .infinity, minHeight: actionMinHeight)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    #if os(macOS)
                    .frame(maxWidth: actionMaxWidth,
                           minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : 32,
                           maxHeight: dynamicTypeSize.isAccessibilitySize ? nil : 44, alignment: .leading)
                    #else
                    .frame(minHeight: 44)
                    #endif
                    .disabled(editingSnapshot?.taskID != task.taskID)
                    .accessibilityIdentifier("detail.save")
                    Button("편집 취소") { finishEditing() }
                        .buttonStyle(.borderless).frame(minHeight: 44)
                    if model.problem != nil || model.projectionPending {
                        Button { Task { await model.retry(in: scene) } } label: {
                            Text("저장 결과 다시 확인")
                                #if os(iOS)
                                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                #endif
                        }
                        .buttonStyle(.borderless).accessibilityIdentifier("detail.retry")
                    }
                }.padding(.horizontal, 24).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading).background(MirrorPalette.surface)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let feedback = model.detailEditingFeedback {
                        Text(feedback).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("detail.feedback")
                    }
                    if let problem = model.problem {
                        Text(problem).font(.callout).foregroundStyle(MirrorPalette.errorText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(problem).accessibilityIdentifier("detail.actionError")
                    }
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
                        .frame(maxWidth: actionMaxWidth,
                               minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : 32,
                               maxHeight: dynamicTypeSize.isAccessibilitySize ? nil : 44, alignment: .leading)
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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("상세 닫기") { requestClose() }
                    .accessibilityIdentifier("detail.close")
                    .modifier(MirrorDynamicTypeValue(scope: .detail))
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges || model.isSaving)
        .onChange(of: hasUnsavedChanges, initial: true) { _, dirty in
            if dirty { draftTaskID = task.taskID }
            else if draftTaskID == task.taskID { draftTaskID = nil }
        }
        .onChange(of: closeRequestedID) { _, requested in
            closeRequestedID = nil
            guard requested == task.taskID else { return }
            requestClose()
        }
        .onChange(of: selectionRequested) { _, request in
            guard let request else { return }
            guard selectionIsCurrent(request), !model.isSaving, !model.projectionPending,
                  !editing || editingSnapshot?.taskID == task.taskID else {
                if selectionRequested?.id == request.id { selectionRequested = nil }
                return
            }
            if hasUnsavedChanges {
                discardRequestedID = task.taskID; discardSelectionRequest = request; showDiscardConfirmation = true
            } else { finishEditing(); selectionRequested = nil; model.selectTask(request.destinationID, in: scene) }
        }
        .alert(discardSelectionRequest == nil ? "편집한 내용을 버리고 닫을까요?" : "편집한 내용을 버리고 다른 일을 열까요?", isPresented: $showDiscardConfirmation) {
            Button(discardSelectionRequest == nil ? "버리고 닫기" : "버리고 다른 일 열기", role: .destructive) {
                guard discardRequestedID == task.taskID, scene.selectedTaskID == task.taskID,
                      editingSnapshot?.taskID == task.taskID, !model.isSaving, !model.projectionPending else { return }
                if let request = discardSelectionRequest {
                    guard selectionRequested == request, selectionIsCurrent(request) else { return }
                    finishEditing(); title = ""; note = ""; link = ""
                    discardRequestedID = nil; discardSelectionRequest = nil; selectionRequested = nil
                    model.selectTask(request.destinationID, in: scene)
                } else { finishEditing(); discardRequestedID = nil; model.selectTask(nil, in: scene) }
            }.accessibilityIdentifier("detail.discardEdit")
            Button("계속 편집", role: .cancel) {
                showDiscardConfirmation = false
                if selectionRequested == discardSelectionRequest { selectionRequested = nil }
                discardRequestedID = nil; discardSelectionRequest = nil
            }
                .accessibilityIdentifier("detail.keepEditing")
        }
        .disabled(model.isSaving)
        .onChange(of: editing, initial: true) { _, value in
            model.setTextEditing(value, ownerID: detailEditorOwnerID)
        }
        .onDisappear {
            model.endDetailEditing(ownerID: detailEditorOwnerID, claim: editingClaim)
            editingClaim = nil; model.setTextEditing(false, ownerID: detailEditorOwnerID)
            if draftTaskID == task.taskID { draftTaskID = nil }
            if closeRequestedID == task.taskID { closeRequestedID = nil }
            if selectionRequested?.ownerID == task.taskID { selectionRequested = nil }
        }
        .onChange(of: task.taskID) { oldID, _ in
            if selectionRequested?.ownerID == oldID { selectionRequested = nil }
            discardSelectionRequest = nil
            showNotes = false; showHistory = false; discardRequestedID = nil; showDiscardConfirmation = false; closeRequestedID = nil
            draftTaskID = hasUnsavedChanges ? task.taskID : nil
        }
        .sheet(item: deadlinePresentation) { request in
            MirrorDeadlineEditor(request: request).modifier(MirrorPresentationDynamicType(size: dynamicTypeSize, scope: "deadline"))
        }
        .sheet(item: detailPickerPresentation) {
            MirrorPlanPicker(request: $0).modifier(MirrorPresentationDynamicType(size: dynamicTypeSize, scope: "plan"))
        }
        .modifier(MirrorDeadlineConfirmation(enabled: model.picker(in: scene) == nil))
    }
    private func openDeadlineEditor() {
        guard deadlineEditor == nil, !model.isSaving else { return }
        deadlineEditor = MirrorDeadlineEditingRequest(task: task, model: model, scene: scene)
    }
    private var deadlinePresentation: Binding<MirrorDeadlineEditingRequest?> {
        let displayed = deadlineEditor
        return Binding(get: { deadlineEditor }, set: { next in
            guard next == nil, let displayed, deadlineEditor?.id == displayed.id, displayed.requestClose() else { return }
            deadlineEditor = nil
        })
    }
    private var detailPickerPresentation: Binding<PlanPickerRequest?> {
        let displayedRequest = model.picker(in: scene)
        return Binding(get: { model.picker(in: scene) }, set: { presented in
            guard presented == nil, let displayedRequest else { return }
            model.closePlanPicker(requestID: displayedRequest.id)
        })
    }
    private var statusLabel: String {
        switch task.status { case .open: "미완료"; case .completed: "완료한 일"; case .deleted: "휴지통에 있는 일" }
    }
    private var statusSymbol: String {
        switch task.status { case .open: "circle"; case .completed: "checkmark.circle"; case .deleted: "trash" }
    }
}

@MainActor
private struct MirrorDeadlineEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: MirrorDeadlineEditingRequest
    var body: some View {
        @Bindable var draft = request
        NavigationStack {
            Form {
                Text("실제 마감은 계획 날짜와 별도예요. 날짜 배치로 마감이 바뀌지 않아요.")
                Toggle("정확한 시각까지 정하기", isOn: $draft.precise)
                DatePicker("실제 마감", selection: $draft.date, displayedComponents: request.precise ? [.date, .hourAndMinute] : [.date])
                Text("마감 시간대: \(request.timeZoneID)").font(.caption)
                Toggle("이 기기에서 이 작업의 실제 마감 알림", isOn: $draft.alarm)
                if request.alarm { DatePicker("알림을 받을 시각", selection: $draft.alarmAt, displayedComponents: [.date, .hourAndMinute]) }
                if !request.isCurrent || request.deadlineChangedExternally || request.saveConflict {
                    Text("편집을 시작한 뒤 작업이나 실제 마감이 바뀌었어요. 입력한 값은 유지했어요. 취소하고 최신 마감을 확인한 뒤 다시 편집하세요.").font(.callout)
                }
                if let problem = model.problem {
                    Text(problem).foregroundStyle(MirrorPalette.errorText).accessibilityLabel(problem).accessibilityIdentifier("state.error")
                }
                Button("실제 마감 저장") { save(retrying: false) }
                    .disabled(model.projectionPending || request.pendingSubmission != nil)
                if request.pendingSubmission != nil {
                    Button("저장 결과 다시 확인") { save(retrying: true) }
                }
            }
            .disabled(request.submitting || model.isSaving || !request.isCurrent)
            .navigationTitle("실제 마감")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("취소") { if request.requestClose() { dismiss() } }
                    .disabled(request.submitting || model.isSaving)
            } }
            .environment(\.timeZone, TimeZone(identifier: request.timeZoneID) ?? .gmt)
        }
        .frame(minWidth: 300, idealWidth: 450, minHeight: 300)
        .interactiveDismissDisabled(request.hasUnsavedChanges || request.submitting || model.isSaving)
        .alert("편집한 실제 마감을 버리고 닫을까요?", isPresented: $draft.showDiscardConfirmation) {
            Button("버리고 닫기", role: .destructive) {
                guard !request.submitting, !model.isSaving else { return }
                request.finish(); dismiss()
            }
            Button("계속 편집", role: .cancel) {}
        }
        .onDisappear { request.finish() }
    }
    private func save(retrying: Bool) {
        guard request.isCurrent, !request.submitting, !model.isSaving else { return }
        let submission: MirrorDeadlineEditingRequest.Submission
        if retrying {
            guard let pending = request.pendingSubmission else { return }
            submission = pending
        } else {
            guard request.pendingSubmission == nil, let deadline = request.deadline, !model.projectionPending else { return }
            submission = .init(task: request.task, deadline: deadline, alarmAt: request.alarm ? request.alarmAt : nil)
        }
        request.submitting = true
        request.pendingSubmission = submission
        Task {
            defer { request.submitting = false }
            guard request.isCurrent else { return }
            let saved: Bool
            if retrying {
                saved = await model.retryDeadlineEditorSave(submission.task, deadline: submission.deadline, ownerID: request.id, claim: request.claim)
            } else if request.savedDeadline == submission.deadline, !request.deadlineChangedExternally {
                saved = true
            } else {
                saved = await model.saveDeadlineEditor(submission.task, deadline: submission.deadline, ownerID: request.id, claim: request.claim)
            }
            guard request.isCurrent else { return }
            guard saved else {
                if !model.canRetryDeadlineEditorSave(submission.task, deadline: submission.deadline, ownerID: request.id, claim: request.claim) {
                    request.pendingSubmission = nil
                }
                return
            }
            guard request.acceptSavedDeadline(submission.deadline) else {
                request.pendingSubmission = nil; request.saveConflict = true
                return
            }
            var notificationReady = true
            if submission.alarmAt != nil {
                let authorized = await model.authorizeDeadlineEditorNotifications(request.task, ownerID: request.id, claim: request.claim)
                guard request.isCurrent else { return }
                guard !request.deadlineChangedExternally else {
                    request.pendingSubmission = nil; request.saveConflict = true
                    return
                }
                guard let authorized else { return }
                notificationReady = authorized
            }
            guard request.isCurrent else { return }
            guard !request.deadlineChangedExternally else {
                request.pendingSubmission = nil; request.saveConflict = true
                return
            }
            model.setDeadlineAlarm(submission.task, fireAt: submission.alarmAt)
            request.acceptSavedAlarm(submission.alarmAt)
            request.pendingSubmission = nil
            // 오래된 제출을 재확인한 동안 바꾼 초안은 그대로 남긴다.
            if notificationReady, !request.hasUnsavedChanges { request.finish(); dismiss() }
        }
    }
}

@MainActor
private struct MirrorActionGroup<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { content }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { content }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { content }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
