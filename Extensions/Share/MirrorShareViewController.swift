import Foundation
import SwiftUI
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

@MainActor
private final class MirrorShareModel {
    let session = ShareCaptureSession()
    private let context: NSExtensionContext?
    init(context: NSExtensionContext?) { self.context = context }

    func load() async {
        await session.load {
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
            return (text, links)
        }
    }

    func save() async {
        let saved = await session.save { draft, decisionKey in
            let services = try await SystemCompositionRoot.open(role: .sharedExtension)
            _ = try await services.capture(title: draft.title, note: draft.note.isEmpty ? nil : draft.note,
                                           sourceURL: draft.sourceURL.isEmpty ? nil : draft.sourceURL,
                                           source: .share, key: decisionKey)
        }
        if saved { context?.completeRequest(returningItems: nil) }
    }

    func cancel() {
        guard session.cancel() else { return }
        context?.cancelRequest(withError: NSError(domain: "Mirror.Share", code: NSUserCancelledError))
    }

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
    let model: MirrorShareModel
    var body: some View {
        @Bindable var session = model.session
        VStack(alignment: .leading, spacing: 12) {
            Text("미러에 넣기").font(.title2.bold())
            Text("한 작업으로 저장해요. 제목만 필요하고 날짜는 나중에 정해도 돼요.").font(.caption)
            if session.isLoading { ProgressView("공유한 내용 읽는 중…") }
            TextField("제목 (500자 이내)", text: $session.title)
                .accessibilityLabel("할 일 제목")
                .disabled(!session.canEdit)
            Text("공유한 원문과 메모").font(.caption)
            TextEditor(text: $session.note).frame(minHeight: 100)
                .accessibilityLabel("공유한 원문과 메모")
                .disabled(!session.canEdit)
            TextField("원문 링크 (선택)", text: $session.sourceURL)
                .disabled(!session.canEdit)
            if let message = session.message { Text(message).font(.caption).accessibilityAddTraits(.updatesFrequently) }
            HStack {
                Button("취소") { model.cancel() }
                    .disabled(!session.canCancel)
                Spacer()
                Button(session.isSaving ? "저장 중…" : session.needsSaveConfirmation ? "이전 저장 확인" : "한 작업으로 저장") {
                    Task { await model.save() }
                }
                    .disabled(!session.canSave)
            }
        }.padding(20)
    }
}
