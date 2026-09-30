import Foundation
import SwiftUI
import Observation
import UniformTypeIdentifiers
import MirrorSystem

#if os(iOS)
import UIKit
public final class MirrorShareViewController: UIViewController {
    public override func viewDidLoad() {
        super.viewDidLoad()
        let model = MirrorShareModel(context: extensionContext)
        let controller = UIHostingController(rootView: MirrorShareView(model: model))
        addChild(controller); view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
        Task { await model.load() }
    }
}
#elseif os(macOS)
import AppKit
public final class MirrorShareViewController: NSViewController {
    public override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 440)) }
    public override func viewDidLoad() {
        super.viewDidLoad()
        let model = MirrorShareModel(context: extensionContext)
        let controller = NSHostingController(rootView: MirrorShareView(model: model))
        addChild(controller); view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        Task { await model.load() }
    }
}
#endif

private enum SharedValue: Sendable { case text(String), url(String) }
private enum ShareLoadError: Error { case unsupported }

@MainActor @Observable
private final class MirrorShareModel {
    var title = ""
    var note = ""
    var sourceURL = ""
    var message: String?
    var isLoading = true
    var isSaving = false
    var didSave = false
    private let context: NSExtensionContext?
    private let decisionKey = UUID().uuidString
    init(context: NSExtensionContext?) { self.context = context }

    func load() async {
        defer { isLoading = false }
        do {
            let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            var text: [String] = [], links: [String] = []
            for item in items {
                if let content = item.attributedContentText?.string, !content.isEmpty { text.append(content) }
                for provider in item.attachments ?? [] {
                    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        if case let .url(value) = try await read(provider, type: UTType.url.identifier) { links.append(value) }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        if case let .text(value) = try await read(provider, type: UTType.plainText.identifier) { text.append(value) }
                    }
                }
            }
            let raw = text.joined(separator: "\n")
            note = ([raw] + links).filter { !$0.isEmpty }.joined(separator: "\n")
            // 긴 원문을 자동으로 잘라내지 않는다. 메모에 보존하고 제목을 사용자에게 받는다.
            title = raw.count <= 500 ? raw : ""
            sourceURL = links.first ?? ""
            if raw.isEmpty { title = sourceURL.count <= 500 ? sourceURL : "" }
            if text.isEmpty && links.isEmpty { message = "공유된 텍스트나 URL을 읽을 수 없어요." }
            if links.count > 1 { message = "여러 링크가 있어요. 저장할 링크 하나를 확인하세요. 원문을 자동으로 가져오지 않아요." }
        } catch { message = "공유한 텍스트나 URL을 읽을 수 없어요. 입력을 확인하세요." }
    }

    func save() async {
        guard !isSaving, !didSave else { return }
        isSaving = true; message = nil
        defer { isSaving = false }
        do {
            let services = try await SystemCompositionRoot.open(role: .sharedExtension)
            _ = try await services.capture(title: title, note: note.isEmpty ? nil : note,
                                           sourceURL: sourceURL.isEmpty ? nil : sourceURL,
                                           source: .share, key: decisionKey)
            didSave = true; message = "저장했어요. 날짜는 아직 정하지 않았어요."
            context?.completeRequest(returningItems: nil)
        } catch { message = (error as? SystemServiceError)?.errorDescription ?? "저장하지 못했어요. 입력을 유지했으니 확인하고 다시 시도하세요." }
    }

    func cancel() { context?.cancelRequest(withError: NSError(domain: "Mirror.Share", code: NSUserCancelledError)) }

    private func read(_ provider: NSItemProvider, type: String) async throws -> SharedValue {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if type == UTType.url.identifier, let url = item as? URL {
                    continuation.resume(returning: .url(url.absoluteString))
                } else if type == UTType.url.identifier, let text = item as? String {
                    continuation.resume(returning: .url(text))
                } else if let text = item as? String {
                    continuation.resume(returning: .text(text))
                } else if let bytes = item as? Data, let text = String(data: bytes, encoding: .utf8) {
                    continuation.resume(returning: type == UTType.url.identifier ? .url(text) : .text(text))
                } else { continuation.resume(throwing: ShareLoadError.unsupported) }
            }
        }
    }
}

private struct MirrorShareView: View {
    @Bindable var model: MirrorShareModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("미러에 넣기").font(.title2.bold())
            Text("한 작업으로 저장해요. 제목만 필요하고 날짜는 나중에 정해도 돼요.").font(.caption)
            if model.isLoading { ProgressView("공유한 내용 읽는 중…") }
            TextField("제목 (500자 이내)", text: $model.title)
                .accessibilityLabel("할 일 제목")
            Text("공유한 원문과 메모").font(.caption)
            TextEditor(text: $model.note).frame(minHeight: 100)
                .accessibilityLabel("공유한 원문과 메모")
            TextField("원문 링크 (선택)", text: $model.sourceURL)
            if let message = model.message { Text(message).font(.caption).accessibilityAddTraits(.updatesFrequently) }
            HStack {
                Button("취소") { model.cancel() }
                Spacer()
                Button(model.isSaving ? "저장 중…" : "한 작업으로 저장") { Task { await model.save() } }
                    .disabled(model.isLoading || model.isSaving || model.didSave)
            }
        }.padding(20)
    }
}
