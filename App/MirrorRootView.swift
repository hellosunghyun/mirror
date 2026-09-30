import MirrorDesign
import MirrorDomain
import SwiftUI

@MainActor
struct MirrorRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var sceneExposureID = UUID()
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    private var isCompact: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }
    var body: some View {
        @Bindable var model = model
        Group {
            if model.isLoading {
                ProgressView("저장된 일을 불러오고 있어요").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.preferences.onboardingComplete {
                MirrorOnboardingView()
            } else if isCompact {
                TabView(selection: $model.destination) {
                    ForEach(MirrorDestination.allCases) { destination in
                        NavigationStack { content(destination).toolbar { commonToolbar } }
                            .tabItem { Label(destination.title, systemImage: destination.symbol) }
                            .tag(destination)
                            .accessibilityIdentifier("destination.\(destination.rawValue)")
                    }
                }
            } else {
                NavigationSplitView {
                    List {
                        ForEach(MirrorDestination.allCases) { destination in
                            Button { model.destination = destination } label: { Label(destination.title, systemImage: destination.symbol) }
                                .buttonStyle(.plain)
                                .listRowBackground(model.destination == destination ? MirrorPalette.accent.opacity(0.12) : .clear)
                                .accessibilityIdentifier("destination.\(destination.rawValue)")
                        }
                    }.navigationTitle("미러").navigationSplitViewColumnWidth(min: 160, ideal: 190)
                } content: {
                    content(model.destination).toolbar { commonToolbar }
                        .navigationSplitViewColumnWidth(min: 280, ideal: 420)
                } detail: {
                    if let task = model.selectedTask { MirrorTaskDetail(task: task) }
                    else { ContentUnavailableView("작업 상세", systemImage: "sidebar.right", description: Text("작업을 선택하면 내용·계획·실제 마감을 볼 수 있어요.")) }
                }
            }
        }
        .tint(MirrorPalette.accent)
        .safeAreaInset(edge: .bottom) { statusBar }
        .sheet(isPresented: $model.showCapture) { MirrorCaptureView() }
        .sheet(isPresented: $model.showSettings) { MirrorSettingsView() }
        .sheet(isPresented: $model.showReview) { MirrorReviewView() }
        .sheet(item: basePicker) { MirrorPlanPicker(request: $0) }
        .sheet(item: detailSheet) { detail in
            NavigationStack {
                if let task = model.tasks.first(where: { $0.taskID == detail.id }) {
                    MirrorTaskDetail(task: task)
                }
            }
        }
        .modifier(MirrorDeadlineConfirmation(enabled: !model.showReview && model.picker == nil && model.selectedTaskID == nil))
        .task { await model.start() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setSceneActive(sceneExposureID, active: phase == .active)
            if phase == .active { Task { await model.refresh() } }
        }
        .onDisappear { model.setSceneActive(sceneExposureID, active: false) }
        .onOpenURL { url in Task { await model.handleURL(url) } }
        .frame(minWidth: isCompact ? 0 : 720, minHeight: isCompact ? 0 : 480)
    }
    @ViewBuilder private func content(_ destination: MirrorDestination) -> some View {
        switch destination { case .today: MirrorTodayView(); case .calendar: MirrorCalendarView(); case .library: MirrorLibraryView() }
    }
    @ToolbarContentBuilder private var commonToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.showCapture = true } label: { Label("일단 넣기", systemImage: "plus") }
                .accessibilityIdentifier("capture.open")
                .keyboardShortcut("n", modifiers: .command)
            Button { model.showSettings = true } label: { Label("설정", systemImage: "gearshape") }
                .accessibilityIdentifier("settings.button")
        }
    }
    @ViewBuilder private var statusBar: some View {
        if model.isSaving || model.feedback != nil || model.problem != nil || model.projectionPending {
            VStack(alignment: .leading, spacing: 6) {
                StatusMorph(state: model.isSaving || model.projectionPending ? .loading : model.problem == nil ? .success : .failure,
                            captions: .saving, size: 24, pops: false)
                if model.isSaving { HStack { ProgressView(); Text("저장 중 · 현재 작업을 유지하고 있어요") } }
                else if let problem = model.problem {
                    HStack(alignment: .top) {
                        Label(problem, systemImage: "exclamationmark.triangle").accessibilityIdentifier("state.error")
                        Spacer()
                        Button("다시 확인") { Task { await model.retry() } }.accessibilityIdentifier("state.retry")
                    }
                } else if let feedback = model.feedback { Text(feedback).accessibilityIdentifier("state.feedback") }
                if model.projectionPending { Button("저장 결과 다시 확인") { Task { await model.retry() } } }
                if let systemProblem = model.systemProblem { Text(systemProblem).font(.caption).foregroundStyle(.secondary) }
                if let cleanupProblem = model.cleanupProblem { Text(cleanupProblem).font(.caption).foregroundStyle(.secondary) }
                if model.lastUndo != nil { Button("되돌리기") { Task { await model.undo() } }.accessibilityIdentifier("task.undo") }
                Text(model.storageLabel).font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(reduceTransparency ? AnyShapeStyle(MirrorPalette.surface) : AnyShapeStyle(Material.bar))
        }
    }
    private var detailSheet: Binding<MirrorDetailRequest?> {
        Binding(get: { isCompact && !model.showReview ? model.selectedTaskID.map(MirrorDetailRequest.init(id:)) : nil }, set: { if $0 == nil { model.selectedTaskID = nil } })
    }
    private var basePicker: Binding<PlanPickerRequest?> {
        Binding(get: { !model.showReview && model.selectedTaskID == nil ? model.picker : nil }, set: { if $0 == nil { model.picker = nil } })
    }
}

struct MirrorDetailRequest: Identifiable { let id: UUID }

@MainActor
struct MirrorDeadlineConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    let enabled: Bool
    func body(content: Content) -> some View {
        content.alert("실제 마감 이후로 배치할까요?", isPresented: Binding(get: { enabled && model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })) {
            Button("마감은 유지하고 배치") { Task { await model.confirmAfterDeadline() } }
            Button("취소", role: .cancel) { model.confirmation = nil }
        } message: { Text("선택한 계획이 실제 마감 뒤예요. 원래 마감은 변경하지 않아요.") }
    }
}

@MainActor
struct MirrorOnboardingView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "sun.max").font(.largeTitle).accessibilityHidden(true)
            Text("잘 미루면,\n지금 할 일이 남는다.").font(.largeTitle.weight(.semibold))
            Text("생각난 일은 보관함에 일단 넣으세요. 오늘 할 일은 정리할 때 직접 정해요. 날짜를 정하지 않은 일이 오늘 목록에 자동으로 들어가지 않아요.")
            Text("계획 시간대: \(model.preferences.timeZoneID) · 설정에서 바꿀 수 있어요.").font(.caption)
            Button("첫 할 일 입력") { model.finishOnboarding() }.buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding.capture")
            Button("바로 둘러보기") { model.preferences.onboardingComplete = true; model.savePreferences() }
        }.padding(28).frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
