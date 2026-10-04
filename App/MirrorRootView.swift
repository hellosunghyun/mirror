import MirrorDesign
import MirrorDomain
import MirrorSystem
import CoreSpotlight
import SwiftUI
#if os(iOS)
import UIKit
#endif

nonisolated struct MirrorSettingsOpenAction: Equatable, Sendable {
    let model: AppModel
    let owner: CaptureSceneOwner

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.owner === rhs.owner
    }

    @MainActor
    func callAsFunction() { model.openSettings(owner: owner) }
}

@MainActor
struct MirrorRootView: View {
    let windowRequestID: UUID?
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var navigation = SceneNavigationState()
    @State private var adjacentCalendarVisible = false
    @State private var libraryNavigation = MirrorLibraryNavigationState()
    @State private var calendarNavigation = MirrorCalendarNavigationState()
    @State private var adjacentCalendarNavigation = MirrorCalendarNavigationState()
    @State private var detailNavigation = MirrorDetailNavigationState()
    @State private var basePickerPresentationState = PlanPickerPresentationState()
    @State private var displayedBasePicker: PlanPickerRequest?
    @State private var basePickerDidAppear = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    init(windowRequestID: UUID? = nil) { self.windowRequestID = windowRequestID }
    private var sceneOwner: CaptureSceneOwner { navigation.owner }
    private var sceneExposureID: UUID { sceneOwner.id }
    private var isReviewPresented: Bool { model.isReviewPresented(in: navigation) }
    private var isCompact: Bool {
        #if os(iOS)
        // 큰 글자에서는 iPad의 좁은 사이드바 대신 탭으로 본문 너비를 확보한다.
        return sizeClass == .compact || dynamicTypeSize.isAccessibilitySize
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
        @Bindable var detailState = detailNavigation
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
                if let task = model.selectedTask(in: navigation) {
                    MirrorTaskDetail(task: task, closeRequestedID: $detailState.closeRequestedID, draftTaskID: $detailState.draftTaskID, selectionRequested: $detailState.selectionRequested)
                }
            }
            .environment(navigation)
            .modifier(MirrorPresentationDynamicType(size: dynamicTypeSize, scope: "detail"))
            .inspectorColumnWidth(min: 280, ideal: 340, max: 380)
        }
        .environment(\.mirrorTaskSelection, taskSelectionAction)
        .environment(\.mirrorCaptureOpen, captureOpenAction)
        #if os(macOS)
        .focusedSceneValue(\.mirrorCaptureOpen, captureOpenAction)
        .focusedSceneValue(\.mirrorLibrarySearch, MirrorLibrarySearchAction(model: model, navigation: libraryNavigation, scene: navigation))
        .focusedSceneValue(\.mirrorSettingsOpen, settingsOpenAction)
        .focusedSceneValue(\.mirrorNavigation, MirrorSceneNavigationAction(model: model, scene: navigation))
        #endif
        .tint(MirrorPalette.accent)
        .sheet(item: capturePresentation) { request in
            MirrorCaptureView(request: request)
                .environment(navigation)
                .modifier(MirrorPresentationDynamicType(size: dynamicTypeSize, scope: "capture"))
        }
        .sheet(item: settingsPresentation) { _ in
            MirrorSettingsView().environment(navigation)
                .modifier(MirrorPresentationDynamicType(size: dynamicTypeSize, scope: "settings"))
        }
        .sheet(item: reviewPresentation) { request in
            MirrorReviewView(presentation: request).environment(navigation)
                .modifier(MirrorPresentationDynamicType(size: dynamicTypeSize, scope: "review"))
        }
        .sheet(item: basePicker, onDismiss: basePickerDismissal) { request in
            MirrorPlanPicker(request: request).environment(navigation)
                .modifier(MirrorPresentationDynamicType(size: dynamicTypeSize, scope: "plan"))
                .onAppear {
                    if displayedBasePicker?.id == request.id { basePickerDidAppear = true }
                }
        }
        .onChange(of: model.picker(in: navigation)?.id, initial: true) { _, _ in retainBasePickerIfNeeded() }
        .onChange(of: isReviewPresented) { _, _ in retainBasePickerIfNeeded() }
        .onChange(of: navigation.selectedTaskID) { _, _ in retainBasePickerIfNeeded() }
        .modifier(MirrorDeadlineConfirmation(enabled: !isReviewPresented && model.picker(in: navigation) == nil && navigation.selectedTaskID == nil))
        .environment(navigation)
        .onAppear {
            model.registerScene(navigation, windowRequestID: windowRequestID)
            model.setSceneActive(navigation, active: scenePhase == .active)
        }
        .task { await model.start() }
        .onChange(of: model.sceneNavigationGeneration) { _, _ in
            libraryNavigation = MirrorLibraryNavigationState()
            calendarNavigation = MirrorCalendarNavigationState()
            adjacentCalendarNavigation = MirrorCalendarNavigationState()
            detailNavigation = MirrorDetailNavigationState()
            adjacentCalendarVisible = false
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setSceneActive(navigation, active: phase == .active)
            if phase == .active {
                Task {
                    await model.refresh()
                    await model.refreshCalendarOnForeground()
                }
            }
        }
        .onDisappear { model.unregisterScene(navigation) }
        .onOpenURL { url in
            model.registerScene(navigation, windowRequestID: windowRequestID)
            Task { await model.handleURL(url, in: navigation) }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            model.registerScene(navigation, windowRequestID: windowRequestID)
            Task { await model.handleSpotlight(activity, in: navigation) }
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
                let calendarEligible = model.selectedTask(in: navigation) == nil && !isReviewPresented
                    && showsAdjacentCalendar(width: availableWidth, destination: navigation.destination)
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
                            .listRowBackground(navigation.destination == destination ? MirrorPalette.accent.opacity(0.12) : .clear)
                            .accessibilityIdentifier("destination.\(destination.rawValue)")
                        }
                    }
                    .navigationTitle("미러")
                    .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
                } detail: {
                    mainContent(navigation.destination, showCalendar: calendarEligible && adjacentCalendarVisible,
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
                phoneHeader(navigation.destination)
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
        model.preferences.onboardingComplete && !model.isLoading && !isReviewPresented && model.selectedTask(in: navigation) != nil
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
        switch destination {
        case .today: MirrorTodayView()
        case .calendar: MirrorCalendarView(navigation: $calendarNavigation)
        case .library: MirrorLibraryView(navigation: libraryNavigation)
        }
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
            Button { captureOpenAction.callAsFunction() } label: {
                Label("일단 넣기", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("capture.open")
            .keyboardShortcut("n", modifiers: .command)
            Button { settingsOpenAction.callAsFunction() } label: {
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
                    MirrorCalendarView(compact: true, navigation: $adjacentCalendarNavigation).accessibilityIdentifier("ipad.adjacentCalendar")
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
                        ToolbarItem(placement: commonToolbarPlacement) {
                            HStack { adjacentCalendarToggle }
                                .buttonStyle(.plain)
                        }
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var adjacentCalendarToggle: some View {
        Button { adjacentCalendarVisible.toggle() } label: {
            Label(adjacentCalendarVisible ? "보조 일정 숨기기" : "보조 일정 표시", systemImage: "sidebar.right")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
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
                Button { captureOpenAction.callAsFunction() } label: {
                    Label("일단 넣기", systemImage: "plus")
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("capture.open")
                .keyboardShortcut("n", modifiers: .command)
                Button { settingsOpenAction.callAsFunction() } label: {
                    Label("설정", systemImage: "gearshape")
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("settings.button")
            }
            .buttonStyle(.plain)
        }
        #else
        ToolbarItemGroup(placement: commonToolbarPlacement) {
            Button { captureOpenAction.callAsFunction() } label: {
                Label("일단 넣기", systemImage: "plus")
                    #if os(iOS)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    #endif
            }
                .accessibilityIdentifier("capture.open")
                .keyboardShortcut("n", modifiers: .command)
                #if DEBUG && os(macOS)
                .modifier(MirrorRootDynamicTypeValue())
                #endif
            Button { settingsOpenAction.callAsFunction() } label: {
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
        if model.capturePresentation(for: sceneExposureID) == nil,
            (!isReviewPresented || model.systemProblem != nil || model.cleanupProblem != nil),
            model.isSaving || model.feedback != nil || model.problem != nil || model.projectionPending
            || model.lastUndo != nil || model.systemProblem != nil || model.cleanupProblem != nil {
            VStack(alignment: .leading, spacing: 8) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
                if !isReviewPresented {
                    layout {
                        statusMessage
                        statusActions
                    }
                    .buttonStyle(.borderless)
                }
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { statusActionButtons }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { statusActionButtons }
        }
    }
    @ViewBuilder private var statusActionButtons: some View {
        if model.problem != nil || model.projectionPending || model.systemProblem != nil {
            Button { Task { await model.retry(in: navigation) } } label: {
                Text("다시 확인")
                    #if os(iOS)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    #endif
            }.accessibilityIdentifier("state.retry")
                .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : nil)
        }
        if let undo = model.lastUndo,
           !isTaskInspectorVisible || undo.taskID != navigation.selectedTaskID {
            Button { Task { await model.undo(in: navigation) } } label: {
                Text("되돌리기")
                    #if os(iOS)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    #endif
            }.accessibilityIdentifier("task.undo")
                .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 44 : nil)
        }
        if model.feedback != nil, model.problem == nil, !model.isSaving, !model.projectionPending {
            Button {
                guard model.problem == nil, !model.isSaving, !model.projectionPending else { return }
                model.feedback = nil
                model.detailEditingFeedback = nil
            } label: {
                Label("안내 닫기", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    #if os(iOS)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    #endif
            }.accessibilityIdentifier("state.dismissFeedback")
        }
    }
    private var captureOpenAction: MirrorCaptureOpenAction {
        MirrorCaptureOpenAction(model: model, owner: sceneOwner)
    }
    private var settingsOpenAction: MirrorSettingsOpenAction {
        MirrorSettingsOpenAction(model: model, owner: sceneOwner)
    }
    private var settingsPresentation: Binding<SettingsPresentationRequest?> {
        let displayedRequest = model.settingsPresentation(for: sceneExposureID)
        return Binding(get: {
            model.settingsPresentation(for: sceneExposureID)
        }, set: { presented in
            guard presented == nil, let displayedRequest else { return }
            model.closeSettings(displayedRequest)
        })
    }
    private var capturePresentation: Binding<CapturePresentationRequest?> {
        // Binding 생성 시의 요청을 닫는다. 오래된 false setter는 새 요청을 해제하지 못한다.
        let displayedRequest = model.capturePresentation(for: sceneExposureID)
        return Binding(get: {
            model.capturePresentation(for: sceneExposureID)
        }, set: { presented in
            guard presented == nil, let displayedRequest else { return }
            model.closeCapture(displayedRequest)
        })
    }
    private var taskInspectorPresentation: Binding<Bool> {
        let displayedTaskID = navigation.selectedTaskID
        let displayedTarget = model.navigationTarget(in: navigation)
        return Binding(get: {
            isTaskInspectorVisible
        }, set: { shown in
            guard !shown, !isReviewPresented, !model.isSaving, let displayedTaskID,
                  navigation.selectedTaskID == displayedTaskID, let displayedTarget,
                  model.navigationTarget(in: navigation) == displayedTarget else { return }
            if detailNavigation.draftTaskID == displayedTaskID || model.isDetailEditing(in: navigation) { detailNavigation.closeRequestedID = displayedTaskID }
            else { model.selectTask(nil, in: navigation) }
        })
    }
    private var sidebarSelection: Binding<MirrorDestination?> {
        Binding(get: { navigation.destination }, set: { if let destination = $0 { selectDestination(destination) } })
    }
    private var destinationSelection: Binding<MirrorDestination> {
        Binding(get: { navigation.destination }, set: { selectDestination($0) })
    }
    private func selectDestination(_ destination: MirrorDestination) {
        model.selectDestination(destination, in: navigation)
    }
    private var taskSelectionAction: MirrorTaskSelectionAction {
        MirrorTaskSelectionAction(model: model, navigation: detailNavigation, scene: navigation)
    }
    private var reviewPresentation: Binding<ScenePresentationRequest?> {
        let displayedRequest = model.reviewPresentation(in: navigation)
        return Binding(get: { model.reviewPresentation(in: navigation) }, set: { presented in
            guard presented == nil, let displayedRequest else { return }
            model.closeReview(displayedRequest)
        })
    }
    private var basePicker: Binding<PlanPickerRequest?> {
        let displayedRequest = displayedBasePicker
        return Binding(get: {
            guard let displayedRequest, eligibleBasePicker?.id == displayedRequest.id else { return nil }
            return displayedRequest
        }, set: { presented in
            guard presented == nil, let displayedRequest else { return }
            model.closePlanPicker(requestID: displayedRequest.id)
        })
    }
    private var eligibleBasePicker: PlanPickerRequest? {
        !isReviewPresented && navigation.selectedTaskID == nil ? model.picker(in: navigation) : nil
    }
    private func retainBasePickerIfNeeded() {
        let next = eligibleBasePicker
        // 아직 표시되지 않은 요청은 dismissal이 오지 않을 수 있으므로 최신 요청으로 교체한다.
        if !basePickerDidAppear, let displayedBasePicker, displayedBasePicker.id != next?.id {
            basePickerPresentationState.close(requestID: displayedBasePicker.id)
            self.displayedBasePicker = nil
        }
        guard let next, basePickerPresentationState.presentIfIdle(requestID: next.id) else { return }
        displayedBasePicker = next
        basePickerDidAppear = false
    }
    private var basePickerDismissal: () -> Void {
        // source가 이미 nil 또는 Q여도 실제 표시했던 P의 ID는 완료 콜백까지 보유한다.
        let dismissedRequestID = displayedBasePicker?.id
        return {
            guard let dismissedRequestID, basePickerPresentationState.close(requestID: dismissedRequestID) else { return }
            displayedBasePicker = nil
            basePickerDidAppear = false
            model.finishWidgetPickerDismissal(requestID: dismissedRequestID)
            retainBasePickerIfNeeded()
        }
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
    @Environment(SceneNavigationState.self) private var scene
    let enabled: Bool
    func body(content: Content) -> some View {
        let displayed = model.confirmation(in: scene)
        let displayedTarget = model.navigationTarget(in: scene)
        return content.alert("실제 마감 이후로 배치할까요?", isPresented: Binding(
            get: { enabled && displayed != nil && model.confirmation(in: scene) == displayed },
            set: {
                if !$0, let displayed, let displayedTarget {
                    model.dismissDeadlineConfirmation(displayed, expectedNavigation: displayedTarget)
                }
            }), presenting: displayed) { envelope in
            Button("마감은 유지하고 배치") {
                if let displayedTarget { Task { await model.confirmAfterDeadline(envelope, expectedNavigation: displayedTarget) } }
            }
            Button("취소", role: .cancel) {
                if let displayedTarget { model.cancelDeadlineConfirmation(envelope, expectedNavigation: displayedTarget) }
            }
        } message: { _ in Text("선택한 계획이 실제 마감 뒤예요. 원래 마감은 변경하지 않아요.") }
    }
}

@MainActor
struct MirrorOnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.mirrorCaptureOpen) private var openCapture
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "sun.max").font(.largeTitle).accessibilityHidden(true)
                Text("잘 미루면,\n지금 할 일이 남는다.").font(.largeTitle.weight(.semibold))
                Text("생각난 일은 보관함에 일단 넣으세요. 오늘 할 일은 정리할 때 직접 정해요. 날짜를 정하지 않은 일이 오늘 목록에 자동으로 들어가지 않아요.")
                Text("계획 시간대: \(model.preferences.timeZoneID) · 설정에서 바꿀 수 있어요.").font(.caption)
                Button { model.finishOnboarding(); openCapture?.callAsFunction() } label: {
                    Text("첫 할 일 입력").foregroundStyle(MirrorPalette.onAccent)
                }.disabled(openCapture == nil).buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding.capture")
                Button("바로 둘러보기") { model.preferences.onboardingComplete = true; model.savePreferences() }
            }.padding(28).frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
