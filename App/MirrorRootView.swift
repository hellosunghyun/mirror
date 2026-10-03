import MirrorDesign
import MirrorDomain
import CoreSpotlight
import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
struct MirrorRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var sceneExposureID = UUID()
    @State private var adjacentCalendarVisible = false
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
    private var usesPhoneTabs: Bool {
        #if os(iOS)
        return isCompact && UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }
    private var commonToolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? .topBarTrailing : .primaryAction
        #else
        return .primaryAction
        #endif
    }
    var body: some View {
        @Bindable var model = model
        Group {
            if isCompact {
                rootContent()
            } else {
                GeometryReader { geometry in
                    rootContent(availableWidth: geometry.size.width)
                }
            }
        }
        #if DEBUG && os(iOS)
        .modifier(MirrorUITestingStatusBarContainer())
        #endif
        .inspector(isPresented: taskInspectorPresentation) {
            NavigationStack {
                if let task = model.selectedTask {
                    MirrorTaskDetail(task: task)
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 380)
        }
        .tint(MirrorPalette.accent)
        .sheet(isPresented: $model.showCapture) { MirrorCaptureView() }
        .sheet(isPresented: $model.showSettings) { MirrorSettingsView() }
        .sheet(isPresented: $model.showReview) { MirrorReviewView() }
        .sheet(item: basePicker, onDismiss: { model.finishWidgetPickerDismissal() }) { MirrorPlanPicker(request: $0) }
        .modifier(MirrorDeadlineConfirmation(enabled: !model.showReview && model.picker == nil && model.selectedTaskID == nil))
        .task { await model.start() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setSceneActive(sceneExposureID, active: phase == .active)
            if phase == .active {
                Task {
                    await model.refresh()
                    await model.refreshCalendarOnForeground()
                }
            }
        }
        .onDisappear { model.setSceneActive(sceneExposureID, active: false) }
        .onOpenURL { url in Task { await model.handleURL(url) } }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            Task { await model.handleSpotlight(activity) }
        }
        #if os(macOS)
        // Inspector는 자신의 최소 폭을 별도로 더하므로, 열렸을 때는 탐색 영역만 확보한다.
        .frame(minWidth: isTaskInspectorVisible ? 520 : 760, minHeight: 520)
        #endif
    }
    private func rootContent(availableWidth: CGFloat = 0) -> some View {
        Group {
            if model.isLoading {
                ProgressView("저장된 일을 불러오고 있어요")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("startup.loading")
            } else if !model.preferences.onboardingComplete {
                MirrorOnboardingView().accessibilityIdentifier("onboarding.screen")
            } else if isCompact {
                compactNavigation
            } else {
                let calendarEligible = model.selectedTask == nil && !model.showReview
                    && showsAdjacentCalendar(width: availableWidth, destination: model.destination)
                NavigationSplitView {
                    List(selection: sidebarSelection) {
                        ForEach(MirrorDestination.allCases) { destination in
                            Button { selectDestination(destination) } label: {
                                Label {
                                    Text(destination.title).foregroundStyle(Color.primary)
                                } icon: {
                                    Image(systemName: destination.symbol).foregroundStyle(MirrorPalette.accent)
                                }
                                    #if os(iOS)
                                    .frame(minWidth: 44, minHeight: 44)
                                    #endif
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .tag(destination)
                            .listRowBackground(model.destination == destination ? MirrorPalette.accent.opacity(0.12) : .clear)
                            .accessibilityIdentifier("destination.\(destination.rawValue)")
                        }
                    }
                    .navigationTitle("미러")
                    .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
                } detail: {
                    mainContent(model.destination, showCalendar: calendarEligible && adjacentCalendarVisible,
                                offersCalendarToggle: calendarEligible)
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private var compactNavigation: some View {
        if usesPhoneTabs {
            VStack(spacing: 0) {
                phoneHeader(model.destination)
                    .fixedSize(horizontal: false, vertical: true)
                compactTabs
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MirrorPalette.canvas)
        } else {
            compactTabs
        }
    }
    private var compactTabs: some View {
        TabView(selection: destinationSelection) {
            ForEach(MirrorDestination.allCases) { destination in
                Tab(destination.title, systemImage: destination.symbol, value: destination) {
                    if usesPhoneTabs {
                        phoneNavigation(destination)
                    } else {
                        mainContent(destination)
                    }
                }
            }
        }
    }
    private var isTaskInspectorVisible: Bool {
        model.preferences.onboardingComplete && !model.isLoading && !model.showReview && model.selectedTask != nil
    }
    private func showsAdjacentCalendar(width: CGFloat, destination: MirrorDestination) -> Bool {
        #if os(iOS)
        return !isCompact && !dynamicTypeSize.isAccessibilitySize
            && UIDevice.current.userInterfaceIdiom == .pad && width >= 1_050 && destination != .calendar
        #else
        return false
        #endif
    }
    @ViewBuilder private func content(_ destination: MirrorDestination) -> some View {
        switch destination { case .today: MirrorTodayView(); case .calendar: MirrorCalendarView(); case .library: MirrorLibraryView() }
    }
    private func phoneNavigation(_ destination: MirrorDestination) -> some View {
        NavigationStack {
            content(destination)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 안내와 되돌리기 공간을 본문의 탭·키보드 안전 영역에서 확보한다.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    statusBar.fixedSize(horizontal: false, vertical: true)
                }
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MirrorPalette.canvas)
    }
    private func phoneHeader(_ destination: MirrorDestination) -> some View {
        HStack(spacing: 12) {
            Text(destination.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            Button { model.openCapture() } label: {
                Label("일단 넣기", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("capture.open")
            .keyboardShortcut("n", modifiers: .command)
            Button { model.showSettings = true } label: {
                Label("설정", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("settings.button")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(MirrorPalette.canvas)
    }
    private func mainContent(_ destination: MirrorDestination, showCalendar: Bool = false,
                             offersCalendarToggle: Bool = false) -> some View {
        HStack(spacing: 0) {
            mainNavigation(destination, offersCalendarToggle: offersCalendarToggle)
                .environment(\.mirrorCalendarDropAvailable, showCalendar)
            #if os(iOS)
            .toolbarMinimizationBehavior(isCompact ? .never : .automatic, for: .navigationBar)
            #endif
            if showCalendar {
                Divider()
                NavigationStack {
                    MirrorCalendarView(compact: true).accessibilityIdentifier("ipad.adjacentCalendar")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                }
                .frame(width: 320)
                .frame(maxHeight: .infinity)
            }
        }
    }
    private func mainNavigation(_ destination: MirrorDestination, offersCalendarToggle: Bool = false) -> some View {
        NavigationStack {
            content(destination)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MirrorPalette.canvas)
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
                .toolbar {
                    commonToolbar
                    if offersCalendarToggle {
                        ToolbarItem(placement: commonToolbarPlacement) { adjacentCalendarToggle }
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var adjacentCalendarToggle: some View {
        Button { adjacentCalendarVisible.toggle() } label: {
            Label(adjacentCalendarVisible ? "보조 일정 숨기기" : "보조 일정 표시", systemImage: "sidebar.right")
        }
        .accessibilityLabel(adjacentCalendarVisible ? "보조 일정 숨기기" : "보조 일정 표시")
        .accessibilityValue(adjacentCalendarVisible ? "표시됨" : "숨겨짐")
        .accessibilityHint(adjacentCalendarVisible ? "일정을 숨겨 작업 목록을 넓게 봐요." : "작업 목록 옆에 날짜별 일정을 함께 보여요.")
        .accessibilityIdentifier("ipad.adjacentCalendar.toggle")
    }
    @ToolbarContentBuilder private var commonToolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: commonToolbarPlacement) {
            HStack(spacing: 8) {
                Button { model.openCapture() } label: {
                    Label("일단 넣기", systemImage: "plus")
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("capture.open")
                .keyboardShortcut("n", modifiers: .command)
                Button { model.showSettings = true } label: {
                    Label("설정", systemImage: "gearshape")
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("settings.button")
            }
            .buttonStyle(.plain)
        }
        #else
        ToolbarItemGroup(placement: commonToolbarPlacement) {
            Button { model.openCapture() } label: {
                Label("일단 넣기", systemImage: "plus")
                    #if os(iOS)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    #endif
            }
                .accessibilityIdentifier("capture.open")
                .keyboardShortcut("n", modifiers: .command)
            Button { model.showSettings = true } label: {
                Label("설정", systemImage: "gearshape")
                    #if os(iOS)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    #endif
            }
                .accessibilityIdentifier("settings.button")
        }
        #endif
    }
    @ViewBuilder private var statusBar: some View {
        if !model.showCapture,
            (!model.showReview || model.systemProblem != nil || model.cleanupProblem != nil),
            model.isSaving || model.feedback != nil || model.problem != nil || model.projectionPending
            || model.lastUndo != nil || model.systemProblem != nil || model.cleanupProblem != nil {
            VStack(alignment: .leading, spacing: 8) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
                layout {
                    statusMessage
                    statusActions
                }
                .buttonStyle(.borderless)
                if let systemProblem = model.systemProblem { Text(systemProblem).font(.caption).foregroundStyle(.secondary) }
                if let cleanupProblem = model.cleanupProblem { Text(cleanupProblem).font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 20).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(reduceTransparency ? AnyShapeStyle(MirrorPalette.surface) : AnyShapeStyle(Material.bar))
        }
    }
    private var statusMessage: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusMorph(state: model.isSaving || model.projectionPending ? .loading : model.problem == nil ? .success : .failure,
                        size: 18, tint: MirrorPalette.accent, pops: false)
                .accessibilityHidden(true)
            if model.isSaving { Text("저장 중…").font(.callout) }
            else if let problem = model.problem {
                Text(problem).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(problem).accessibilityIdentifier("state.error")
            } else if model.projectionPending {
                Text("저장 결과를 확인하고 있어요").font(.callout)
            } else if let feedback = model.feedback {
                Text(feedback).font(.callout).accessibilityIdentifier("state.feedback")
            } else { Text(model.storageLabel).font(.caption).foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var statusActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            if model.problem != nil || model.projectionPending {
                Button("다시 확인") { Task { await model.retry() } }.accessibilityIdentifier("state.retry")
                    .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : nil)
            }
            if let undo = model.lastUndo,
               !isTaskInspectorVisible || undo.taskID != model.selectedTaskID {
                Button("되돌리기") { Task { await model.undo() } }.accessibilityIdentifier("task.undo")
                    .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : nil)
            }
        }
    }
    private var taskInspectorPresentation: Binding<Bool> {
        Binding(get: {
            isTaskInspectorVisible
        }, set: { shown in
            guard !shown, !model.showReview else { return }
            model.selectedTaskID = nil
        })
    }
    private var sidebarSelection: Binding<MirrorDestination?> {
        Binding(get: { model.destination }, set: { if let destination = $0 { selectDestination(destination) } })
    }
    private var destinationSelection: Binding<MirrorDestination> {
        Binding(get: { model.destination }, set: { selectDestination($0) })
    }
    private func selectDestination(_ destination: MirrorDestination) {
        if destination != model.destination && !model.isDetailEditing { model.selectedTaskID = nil }
        model.destination = destination
    }
    private var basePicker: Binding<PlanPickerRequest?> {
        Binding(get: { !model.showReview && model.selectedTaskID == nil ? model.picker : nil }, set: { if $0 == nil { model.picker = nil } })
    }
}

#if DEBUG && os(iOS)
@MainActor
private struct MirrorUITestingStatusBarContainer: ViewModifier {
    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.environment["MIRROR_UI_TESTING"] == "1",
           UIDevice.current.userInterfaceIdiom == .phone {
            content.overlay(alignment: .topLeading) {
                MirrorUITestingStatusBarProbe().frame(width: 1, height: 1)
            }
        } else { content }
    }
}

// 시스템 상태 표시줄은 앱의 AX 트리에 없을 수 있다. 실제 창의 UIKit 경계만 관측한다.
@MainActor
private struct MirrorUITestingStatusBarProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> NativeStatusBarView {
        NativeStatusBarView(frame: .zero)
    }
    func updateUIView(_ uiView: NativeStatusBarView, context: Context) {}

    @MainActor
    final class NativeStatusBarView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityIdentifier = "ui.nativeStatusBar"
            accessibilityLabel = "UI 검증용 시스템 상태 표시줄 경계"
        }
        required init?(coder: NSCoder) { return nil }

        override var accessibilityValue: String? {
            get {
                guard let window, let scene = window.windowScene,
                      scene.activationState == .foregroundActive,
                      UIApplication.shared.connectedScenes.filter({ $0.activationState == .foregroundActive }).count == 1,
                      window.isKeyWindow, !window.isHidden, window.alpha > 0, window.windowLevel == .normal,
                      scene.windows.filter({ $0.isKeyWindow && !$0.isHidden && $0.alpha > 0 }).count == 1,
                      let manager = scene.statusBarManager, !manager.isStatusBarHidden else {
                    return "unavailable"
                }
                let frame = scene.coordinateSpace.convert(manager.statusBarFrame, to: scene.screen.coordinateSpace)
                guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
                      frame.width > 0, frame.height > 0 else { return "unavailable" }
                return "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)"
            }
            set {}
        }
    }
}
#endif

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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "sun.max").font(.largeTitle).accessibilityHidden(true)
                Text("잘 미루면,\n지금 할 일이 남는다.").font(.largeTitle.weight(.semibold))
                Text("생각난 일은 보관함에 일단 넣으세요. 오늘 할 일은 정리할 때 직접 정해요. 날짜를 정하지 않은 일이 오늘 목록에 자동으로 들어가지 않아요.")
                Text("계획 시간대: \(model.preferences.timeZoneID) · 설정에서 바꿀 수 있어요.").font(.caption)
                Button { model.finishOnboarding() } label: {
                    Text("첫 할 일 입력").foregroundStyle(MirrorPalette.onAccent)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding.capture")
                Button("바로 둘러보기") { model.preferences.onboardingComplete = true; model.savePreferences() }
            }.padding(28).frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
