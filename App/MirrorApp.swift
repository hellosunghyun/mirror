import MirrorDomain
import MirrorSystem
import AppIntents
import SwiftUI
#if DEBUG && os(iOS)
import UIKit
#endif

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
            if MirrorDynamicTypeFixture.requested == .system {
                content.modifier(MirrorAppliedDynamicType(fixtureMode: .system))
            } else {
                content.modifier(MirrorAppliedDynamicType(fixtureMode: MirrorDynamicTypeFixture.requested))
                    .dynamicTypeSize(.accessibility5)
            }
        } else { content }
        #else
        content
        #endif
    }
}

/// 시트를 여는 화면에서 읽은 글자 크기를 전달한다. 시스템 값과 검사용 override 모두 같은 경계를 지난다.
struct MirrorPresentationDynamicType: ViewModifier {
    let size: DynamicTypeSize
    let scope: String

    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MIRROR_UI_TESTING"] == "1",
           ProcessInfo.processInfo.environment["MIRROR_UI_DYNAMIC_TYPE"] == "accessibility5" {
            #if os(macOS)
            if scope == "capture" || scope == "review" {
                content.dynamicTypeSize(size)
            } else {
                content.modifier(MirrorAppliedDynamicType(identifier: "ui.appliedDynamicType." + scope))
                    .dynamicTypeSize(size)
            }
            #else
            if MirrorDynamicTypeFixture.requested == .system {
                // 시스템 비교군은 시트에서도 단일 값 override 없이 실제 상속 값을 관측한다.
                content.modifier(MirrorAppliedDynamicType(identifier: "ui.appliedDynamicType." + scope,
                                                          fixtureMode: .system))
            } else {
                content.modifier(MirrorAppliedDynamicType(identifier: "ui.appliedDynamicType." + scope,
                                                          fixtureMode: MirrorDynamicTypeFixture.requested))
                    .dynamicTypeSize(size)
            }
            #endif
        } else {
            content.dynamicTypeSize(size)
        }
        #else
        content.dynamicTypeSize(size)
        #endif
    }
}

#if DEBUG
private enum MirrorDynamicTypeFixture: String {
    case pinned, system

    static var requested: Self? {
        #if os(iOS)
        return ProcessInfo.processInfo.environment["MIRROR_UI_DYNAMIC_TYPE_FIXTURE"].flatMap(Self.init(rawValue:))
        #else
        return nil
        #endif
    }
}

@MainActor
private struct MirrorAppliedDynamicType: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var identifier = "ui.appliedDynamicType"
    var fixtureMode: MirrorDynamicTypeFixture?
    func body(content: Content) -> some View {
        content.accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(dynamicTypeSize == .accessibility5 ? "accessibility5" : String(describing: dynamicTypeSize))
            .accessibilityLabel(appliedLabel)
    }
    private var appliedLabel: String {
        #if os(iOS)
        if let fixtureMode {
            // 대상 앱의 시스템 값을 읽는다. SwiftUI override와 테스트 runner의 UIKit 값은 사용하지 않는다.
            let fields = ["actualMode": fixtureMode.rawValue,
                          "scope": identifier == "ui.appliedDynamicType" ? "root"
                              : String(identifier.dropFirst("ui.appliedDynamicType.".count)),
                          "swiftUI": appliedTypeName ?? "unavailable", "uiKit": applicationContentSizeName,
                          "uiKitSource": "appSystem"]
            if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
        }
        #endif
        return appliedTypeName.map { "글자 크기 환경: " + $0 } ?? "글자 크기 환경"
    }
    #if os(iOS)
    private var applicationContentSizeName: String {
        switch UIApplication.shared.preferredContentSizeCategory {
        case .extraSmall: "extraSmall"
        case .small: "small"
        case .medium: "medium"
        case .large: "large"
        case .extraLarge: "extraLarge"
        case .extraExtraLarge: "extraExtraLarge"
        case .extraExtraExtraLarge: "extraExtraExtraLarge"
        case .accessibilityMedium: "accessibilityMedium"
        case .accessibilityLarge: "accessibilityLarge"
        case .accessibilityExtraLarge: "accessibilityExtraLarge"
        case .accessibilityExtraExtraLarge: "accessibilityExtraExtraLarge"
        case .accessibilityExtraExtraExtraLarge: "accessibilityExtraExtraExtraLarge"
        case .unspecified: "unspecified"
        default: "unavailable"
        }
    }
    #endif
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
    @State private var textEditingOwnerID = UUID()
    @State private var captureFlowStarted = false
    @State private var captureRequestToken = UUID().uuidString
    @State private var submittedTitle: String?
    @State private var submittingCapture = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("일단 넣고, 나중에 정하세요").font(.headline)
            TextField("할 일 제목", text: $title, axis: .vertical).focused($focused)
                .lineLimit(1...4)
                .disabled(submittingCapture || model.isSaving || model.projectionPending)
                .accessibilityIdentifier("menuBar.title")
            Button("보관함에 넣기") { saveCapture() }
                .disabled(model.isLoading || model.context == nil || submittingCapture || model.isSaving || model.projectionPending
                          || model.canRetryMenuBarCapture(token: captureRequestToken))
                .accessibilityIdentifier("menuBar.save")
            if model.canRetryMenuBarCapture(token: captureRequestToken) {
                Button(model.projectionPending ? "저장 결과 다시 확인" : "이전 입력 다시 시도", action: retryCapture)
                    .disabled(submittingCapture || model.isSaving)
                    .accessibilityIdentifier("menuBar.retry")
            }
            if submittingCapture || model.isSaving {
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
            .onChange(of: focused, initial: true) { _, value in model.setTextEditing(value, ownerID: textEditingOwnerID) }
            .onChange(of: title) { _, value in if !value.isEmpty { startCaptureFlow() } }
            .onChange(of: model.menuBarCaptureCommittedReceipt, initial: true) { _, receipt in acceptCaptureReceipt(receipt) }
            .onDisappear { model.setTextEditing(false, ownerID: textEditingOwnerID) }
    }
    private func saveCapture() {
        guard !model.isLoading, model.context != nil, !submittingCapture, !model.isSaving, !model.projectionPending,
              !model.canRetryMenuBarCapture(token: captureRequestToken) else { return }
        // onChange가 전달되기 전 자기 성공을 먼저 수용하고, 비운 입력으로 새 저장을 하지 않는다.
        if acceptCaptureReceipt(model.menuBarCaptureCommittedReceipt), title.isEmpty {
            focused = true
            return
        }
        startCaptureFlow()
        let capturedTitle = title
        let token = captureRequestToken
        submittingCapture = true
        guard model.registerMenuBarCapture(token: token, title: capturedTitle) else {
            submittingCapture = false
            return
        }
        submittedTitle = capturedTitle
        Task {
            defer { submittingCapture = false }
            if await model.capture(title: capturedTitle, note: "", sourceURL: "", requestToken: token) {
                acceptCaptureReceipt(model.menuBarCaptureCommittedReceipt)
                focused = true
            }
        }
    }
    private func retryCapture() {
        guard !submittingCapture, !model.isSaving,
              model.canRetryMenuBarCapture(token: captureRequestToken) else { return }
        let token = captureRequestToken
        submittingCapture = true
        Task {
            defer { submittingCapture = false }
            if await model.retryMenuBarCapture(token: token) {
                acceptCaptureReceipt(model.menuBarCaptureCommittedReceipt)
                focused = true
            }
        }
    }
    @discardableResult
    private func acceptCaptureReceipt(_ receipt: CaptureCommittedReceipt?) -> Bool {
        guard let disposition = receipt?.disposition(token: captureRequestToken,
            submittedTitle: submittedTitle, currentTitle: title) else { return false }
        if disposition == .clearTitle { title = "" }
        self.submittedTitle = nil
        captureRequestToken = UUID().uuidString
        captureFlowStarted = false
        if !title.isEmpty { startCaptureFlow() }
        return true
    }
    private func startCaptureFlow() {
        guard !captureFlowStarted else { return }
        captureFlowStarted = true
        Task { await model.recordCaptureFlowStarted() }
    }
}
#endif

#if os(macOS)
private struct MirrorCaptureOpenFocusedKey: FocusedValueKey {
    typealias Value = MirrorCaptureOpenAction
}
private struct MirrorLibrarySearchFocusedKey: FocusedValueKey {
    typealias Value = MirrorLibrarySearchAction
}
private struct MirrorSettingsOpenFocusedKey: FocusedValueKey {
    typealias Value = MirrorSettingsOpenAction
}

extension FocusedValues {
    var mirrorSettingsOpen: MirrorSettingsOpenAction? {
        get { self[MirrorSettingsOpenFocusedKey.self] }
        set { self[MirrorSettingsOpenFocusedKey.self] = newValue }
    }
    var mirrorLibrarySearch: MirrorLibrarySearchAction? {
        get { self[MirrorLibrarySearchFocusedKey.self] }
        set { self[MirrorLibrarySearchFocusedKey.self] = newValue }
    }
    var mirrorCaptureOpen: MirrorCaptureOpenAction? {
        get { self[MirrorCaptureOpenFocusedKey.self] }
        set { self[MirrorCaptureOpenFocusedKey.self] = newValue }
    }
}

@MainActor
struct MirrorCommands: Commands {
    let model: AppModel
    @FocusedValue(\.mirrorCaptureOpen) private var openCapture
    @FocusedValue(\.mirrorLibrarySearch) private var searchLibrary
    @FocusedValue(\.mirrorSettingsOpen) private var openSettings
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("할 일 일단 넣기") { openCapture?.callAsFunction() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(openCapture == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("전체 작업 검색") { searchLibrary?.callAsFunction() }.keyboardShortcut("f", modifiers: .command)
                .disabled(searchLibrary == nil)
        }
        CommandGroup(after: .undoRedo) {
            Button(model.showReview ? "직전 정리 결정 되돌리기" : "미러의 직전 작업 되돌리기") {
                if model.showReview {
                    if let candidate = model.currentReviewUndo, let sessionID = model.review?.id {
                        Task { await model.undoReview(operationID: candidate.id, sessionID: sessionID) }
                    }
                } else {
                    Task { await model.undo() }
                }
            }
                .keyboardShortcut("z", modifiers: .command)
                .disabled((model.showReview ? model.currentReviewUndo == nil : model.lastUndo == nil)
                          || model.isTextEditing || model.isDetailEditing || model.isSaving || model.projectionPending)
        }
        CommandMenu("정리") {
            Button(model.review?.cards.isEmpty == false ? "이어서 정리" : "오늘 정리") { model.beginReview(mode: .manualResume) }
                .disabled(model.isDetailEditing)
            Button("오늘 다시 정리") { model.beginReview(mode: .manualTodayOverride) }
                .disabled(model.isDetailEditing)
            Button("오늘은 여기까지") { Task { await model.finishReview() } }.disabled(model.review == nil || model.isDetailEditing)
        }
        CommandGroup(replacing: .appSettings) {
            Button("미러 설정…") { openSettings?.callAsFunction() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(openSettings == nil)
        }
    }
}
#endif
