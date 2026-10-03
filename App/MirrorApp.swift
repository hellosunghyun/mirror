import MirrorDomain
import MirrorSystem
import AppIntents
import SwiftUI

struct MirrorAppIntentsRegistration: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [MirrorAppIntentsPackage.self] }
}

@main
@MainActor
struct MirrorApp: App {
    @State private var model = AppModel()
    init() { NotificationService.bootstrapNavigation() }
    var body: some Scene {
        WindowGroup(id: "main") {
            MirrorRootView()
                .environment(model)
                .preferredColorScheme(uiTestingColorScheme)
                .modifier(MirrorUITestingDynamicType())
        }
        #if os(macOS)
        .commands { MirrorCommands(model: model) }
        #endif
        .defaultSize(width: 1_100, height: 740)
        #if os(macOS)
        .defaultWindowPlacement { content, context in
            let idealSize = content.sizeThatFits(.unspecified)
            let visibleRect = context.defaultDisplay.visibleRect
            let size = CGSize(width: min(max(idealSize.width, 1_100), visibleRect.width),
                              height: min(max(idealSize.height, 740), visibleRect.height))
            return WindowPlacement(size: size)
        }
        .windowIdealPlacement { content, context in
            let visibleRect = context.defaultDisplay.visibleRect
            let idealSize = content.sizeThatFits(ProposedViewSize(visibleRect.size))
            let size = CGSize(width: min(idealSize.width, visibleRect.width),
                              height: min(idealSize.height, visibleRect.height))
            return WindowPlacement(size: size)
        }
        #endif
        #if os(macOS)
        MenuBarExtra("미러", systemImage: "sun.max") {
            MirrorMenuBarContent().environment(model)
        }.menuBarExtraStyle(.window)
        #endif
    }

    private var uiTestingColorScheme: ColorScheme? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["MIRROR_UI_TESTING"] == "1" else { return nil }
        return environment["MIRROR_UI_APPEARANCE"] == "dark" ? .dark : nil
        #else
        return nil
        #endif
    }
}

/// 실제 시스템 값을 보존하고, 독립 UI 수용 검사의 명시적 launch 값만 적용한다.
private struct MirrorUITestingDynamicType: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MIRROR_UI_TESTING"] == "1",
           ProcessInfo.processInfo.environment["MIRROR_UI_DYNAMIC_TYPE"] == "accessibility5" {
            content.modifier(MirrorAppliedDynamicType()).dynamicTypeSize(.accessibility5)
        } else { content }
        #else
        content
        #endif
    }
}

#if DEBUG
private struct MirrorAppliedDynamicType: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    func body(content: Content) -> some View {
        content.accessibilityElement(children: .contain)
            .accessibilityIdentifier("ui.appliedDynamicType")
            .accessibilityValue(dynamicTypeSize == .accessibility5 ? "accessibility5" : String(describing: dynamicTypeSize))
            .accessibilityLabel(appliedTypeName.map { "글자 크기 환경: " + $0 } ?? "글자 크기 환경")
    }
    private var appliedTypeName: String? {
        switch dynamicTypeSize {
        case .xSmall: "xSmall"
        case .small: "small"
        case .medium: "medium"
        case .large: "large"
        case .xLarge: "xLarge"
        case .xxLarge: "xxLarge"
        case .xxxLarge: "xxxLarge"
        case .accessibility1: "accessibility1"
        case .accessibility2: "accessibility2"
        case .accessibility3: "accessibility3"
        case .accessibility4: "accessibility4"
        case .accessibility5: "accessibility5"
        @unknown default: nil
        }
    }
}
#endif

#if os(macOS)
@MainActor
struct MirrorMenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var title = ""
    @FocusState private var focused: Bool
    @State private var captureFlowStarted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("일단 넣고, 나중에 정하세요").font(.headline)
            TextField("할 일 제목", text: $title, axis: .vertical).focused($focused)
                .disabled(model.isSaving || model.projectionPending)
                .accessibilityIdentifier("menuBar.title")
            Button("보관함에 넣기") {
                startCaptureFlow()
                Task { if await model.capture(title: title, note: "", sourceURL: "") { title = ""; focused = true; captureFlowStarted = false } }
            }.disabled(model.isSaving || model.projectionPending).accessibilityIdentifier("menuBar.save")
            if model.isSaving {
                Text("저장 중…")
            } else if model.projectionPending {
                Text("저장 결과를 확인하고 있어요")
            } else if let problem = model.problem {
                Text(problem).foregroundStyle(.red)
            } else if title.isEmpty, let feedback = model.feedback {
                Text(feedback).font(.caption)
            }
            Divider()
            Button("오늘 목록 열기") { openWindow(id: "main"); model.destination = .today }
            Button(model.review?.cards.isEmpty == false ? "이어서 정리" : "오늘 정리") { openWindow(id: "main"); model.beginReview(mode: .manualResume) }
                .disabled(model.isDetailEditing)
            Text(model.storageLabel).font(.caption).foregroundStyle(.secondary)
        }.padding().frame(width: 320)
            .task { await model.start() }
            .onChange(of: focused) { _, value in model.isTextEditing = value }
            .onChange(of: title) { _, value in if !value.isEmpty { startCaptureFlow() } }
            .onDisappear { model.isTextEditing = false }
    }
    private func startCaptureFlow() {
        guard !captureFlowStarted else { return }
        captureFlowStarted = true
        Task { await model.recordCaptureFlowStarted() }
    }
}
#endif

#if os(macOS)
@MainActor
struct MirrorCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("할 일 일단 넣기") { model.openCapture() }.keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("전체 작업 검색") { model.destination = .library; model.searchRequested = true }.keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(after: .undoRedo) {
            Button("미러의 직전 작업 되돌리기") { Task { await model.undo() } }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.lastUndo == nil || model.isTextEditing || model.isDetailEditing || model.isSaving)
        }
        CommandMenu("정리") {
            Button(model.review?.cards.isEmpty == false ? "이어서 정리" : "오늘 정리") { model.beginReview(mode: .manualResume) }
                .disabled(model.isDetailEditing)
            Button("오늘 다시 정리") { model.beginReview(mode: .manualTodayOverride) }
                .disabled(model.isDetailEditing)
            Button("오늘은 여기까지") { Task { await model.finishReview() } }.disabled(model.review == nil || model.isDetailEditing)
        }
        CommandGroup(replacing: .appSettings) {
            Button("미러 설정…") { model.showSettings = true }.keyboardShortcut(",", modifiers: .command)
        }
    }
}
#endif
