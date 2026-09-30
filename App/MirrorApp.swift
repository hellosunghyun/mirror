import MirrorDomain
import SwiftUI

@main
@MainActor
struct MirrorApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            MirrorRootView()
                .environment(model)
        }
        .commands { MirrorCommands(model: model) }
        .defaultSize(width: 1_100, height: 740)
        #if os(macOS)
        MenuBarExtra("미러", systemImage: "sun.max") {
            Button("일단 넣기") { model.showCapture = true }
            Button("오늘 목록") { model.destination = .today }
            Button("이어서 정리") { model.beginReview(mode: .manualResume) }
            Divider()
            Text(model.storageLabel)
        }
        #endif
    }
}

@MainActor
struct MirrorCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("할 일 일단 넣기") { model.showCapture = true }.keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("전체 작업 검색") { model.destination = .library; model.searchRequested = true }.keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(after: .undoRedo) {
            Button("미러의 직전 작업 되돌리기") { Task { await model.undo() } }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.lastUndo == nil || model.isTextEditing || model.isSaving)
        }
        CommandMenu("정리") {
            Button("오늘 정리") { model.beginReview() }
            Button("이어서 정리") { model.beginReview(mode: .manualResume) }
            Button("오늘 다시 정리") { model.beginReview(mode: .manualTodayOverride) }
            Button("오늘은 여기까지") { Task { await model.finishReview() } }.disabled(model.review == nil)
        }
        #if os(macOS)
        CommandGroup(replacing: .appSettings) {
            Button("미러 설정…") { model.showSettings = true }.keyboardShortcut(",", modifiers: .command)
        }
        #endif
    }
}
