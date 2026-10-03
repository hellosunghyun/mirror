// Copyright (c) 2026 Saivion Hayes. MIT + Commons Clause; see LICENSE.swiftpieces.
// Adapted for Mirror; see PROVENANCE.md.
// swiftpieces:
// title: Expandable Text
// description: A paragraph clamped to a line limit that measures whether it is really truncated, and only then fades the end of its last line into a trailing "more" link; tapping grows the block smoothly to its full height with no reflow, a "less" link collapses it, links stay tappable, and VoiceOver always reads the whole text.
// category: text
// minIOSVersion: "17.0"
// version: "1.0.0"
// added: "2026-09-23"
// tags: [text, read-more, truncation, expand, collapse, line-limit, review]

import SwiftUI

/// A "Read more" paragraph that shows `more` only when the text is actually truncated.
///
/// SwiftUI cannot tell you whether a `Text` was truncated, so this measures three hidden copies at the real width:
/// the full text, the text at `lineLimit` lines, and the text at one line fewer (which locates the last visible line).
/// The copies re-measure on width, Dynamic Type and text changes. When the full height exceeds the limited height,
/// the visible text is laid out in full and clipped to the limited height; the end of the last line fades out
/// (a transparent mask, so it works over any background) and a `more` link sits in the faded space on the trailing edge.
/// Expanding animates the clip to the full height, so lines never reflow or jump.
///
/// Font and color come from the environment like `Text`: apply `.font(...)`, `.foregroundStyle(...)` and
/// `.multilineTextAlignment(...)` to the piece. VoiceOver reads the full text in both states and gets
/// "Show more" / "Show less" actions; the visual links are also accessible buttons.
///
/// - Parameters:
///   - text: The paragraph. A `String` is shown verbatim; an `AttributedString` keeps bold, italics and tappable links.
///   - lineLimit: Lines shown while collapsed. Values below 1 are treated as 1.
///   - isExpanded: Optional binding to drive or observe the state from outside. `nil` keeps the state internally.
///   - moreLabel: The trailing link on the last collapsed line. Localized from your app's strings; defaults to "more".
///   - lessLabel: The link under the expanded text. Localized from your app's strings; defaults to "less".
///   - showsLess: When false, an expanded paragraph stays expanded (no "less" link, and tapping the body does nothing).
///   - togglesOnTap: When true, tapping anywhere on the paragraph also expands or collapses it. Links inside the text still open.
///   - style: Link color and weight, fade width, and an optional solid fade color. Defaults to the house palette.
///   - paragraphAccessibilityIdentifier: An optional identifier for the visible paragraph after layout and clipping; measuring copies and buttons keep their own accessibility behavior.
///   - paragraphAccessibilityFocus: An optional accessibility focus binding applied directly to the visible paragraph; measuring copies and buttons are excluded.
@MainActor
public struct ExpandableText: View {
    /// Link color and weight, and how the last line fades. `.standard` is the house palette.
    public struct Style: Sendable {
        /// The "more" and "less" links.
        public var link: Color
        /// Weight of the links, applied on top of the environment font.
        public var linkWeight: Font.Weight
        /// Width of the fade in front of "more", at the default Dynamic Type size. Scales with the text.
        public var fadeWidth: CGFloat
        /// `nil` (default) fades the text itself to transparent, which works over any background: images, materials, gradients.
        /// Set a color to paint a gradient into that color instead, for example to match a card behind the text exactly.
        public var fade: Color?

        /// Pass only what you want to change; `nil` keeps the house palette value.
        public init(link: Color? = nil, linkWeight: Font.Weight = .semibold, fadeWidth: CGFloat = 40, fade: Color? = nil) {
            self.link = link ?? adaptive(light: 0xD70000, dark: 0xFF3B30)
            self.linkWeight = linkWeight
            self.fadeWidth = max(fadeWidth, 0)
            self.fade = fade
        }

        public static let standard = Style()
    }

    private enum Content {
        case plain(String)
        case attributed(AttributedString)
    }

    /// Heights of the hidden measuring copies at the current width.
    private struct Metrics: Equatable {
        var full: CGFloat = 0
        var limited: CGFloat = 0
        var head: CGFloat = 0
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.multilineTextAlignment) private var textAlignment
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @State private var storedExpanded = false
    @State private var metrics = Metrics()
    @State private var lastLinkOpen = Date.distantPast
    @State private var pendingToggle: Task<Void, Never>?

    private let content: Content
    private let lineLimit: Int
    private let externalExpanded: Binding<Bool>?
    private let moreLabel: LocalizedStringKey
    private let lessLabel: LocalizedStringKey
    private let showsLess: Bool
    private let togglesOnTap: Bool
    private let style: Style
    private let paragraphAccessibilityIdentifier: String?
    private let paragraphAccessibilityFocus: AccessibilityFocusState<Bool>.Binding?

    /// A plain string, shown verbatim.
    public init(_ text: String, lineLimit: Int = 3, isExpanded: Binding<Bool>? = nil, moreLabel: LocalizedStringKey = "더 보기", lessLabel: LocalizedStringKey = "접기", showsLess: Bool = true, togglesOnTap: Bool = true, style: Style = .standard, paragraphAccessibilityIdentifier: String? = nil, paragraphAccessibilityFocus: AccessibilityFocusState<Bool>.Binding? = nil) {
        self.init(content: .plain(text), lineLimit: lineLimit, isExpanded: isExpanded, moreLabel: moreLabel, lessLabel: lessLabel, showsLess: showsLess, togglesOnTap: togglesOnTap, style: style, paragraphAccessibilityIdentifier: paragraphAccessibilityIdentifier, paragraphAccessibilityFocus: paragraphAccessibilityFocus)
    }

    /// An attributed string: bold, italics and links are kept, and links stay tappable.
    public init(_ text: AttributedString, lineLimit: Int = 3, isExpanded: Binding<Bool>? = nil, moreLabel: LocalizedStringKey = "더 보기", lessLabel: LocalizedStringKey = "접기", showsLess: Bool = true, togglesOnTap: Bool = true, style: Style = .standard, paragraphAccessibilityIdentifier: String? = nil, paragraphAccessibilityFocus: AccessibilityFocusState<Bool>.Binding? = nil) {
        self.init(content: .attributed(text), lineLimit: lineLimit, isExpanded: isExpanded, moreLabel: moreLabel, lessLabel: lessLabel, showsLess: showsLess, togglesOnTap: togglesOnTap, style: style, paragraphAccessibilityIdentifier: paragraphAccessibilityIdentifier, paragraphAccessibilityFocus: paragraphAccessibilityFocus)
    }

    private init(content: Content, lineLimit: Int, isExpanded: Binding<Bool>?, moreLabel: LocalizedStringKey, lessLabel: LocalizedStringKey, showsLess: Bool, togglesOnTap: Bool, style: Style, paragraphAccessibilityIdentifier: String?, paragraphAccessibilityFocus: AccessibilityFocusState<Bool>.Binding?) {
        self.content = content
        self.lineLimit = max(lineLimit, 1)
        self.externalExpanded = isExpanded
        self.moreLabel = moreLabel
        self.lessLabel = lessLabel
        self.showsLess = showsLess
        self.togglesOnTap = togglesOnTap
        self.style = style
        self.paragraphAccessibilityIdentifier = paragraphAccessibilityIdentifier
        self.paragraphAccessibilityFocus = paragraphAccessibilityFocus
    }

    // MARK: State

    private var expanded: Bool { externalExpanded?.wrappedValue ?? storedExpanded }

    private func setExpanded(_ value: Bool) {
        if let externalExpanded { externalExpanded.wrappedValue = value } else { storedExpanded = value }
    }

    /// All copies have reported, so the limited and full heights are real for this width.
    private var isMeasured: Bool { metrics.full > 0 && metrics.limited > 0 && (lineLimit == 1 || metrics.head > 0) }

    /// Truncated means the full layout is taller than the clamped one. The half point absorbs rounding.
    private var isTruncated: Bool { isMeasured && metrics.full > metrics.limited + 0.5 }

    private var hasLinks: Bool {
        if case .attributed(let string) = content { return string.runs.contains { $0.link != nil } }
        return false
    }

    private var text: Text {
        switch content {
        case .plain(let string): Text(verbatim: string)
        case .attributed(let string): Text(string)
        }
    }

    private var frameAlignment: Alignment {
        switch textAlignment {
        case .center: .top
        case .trailing: .topTrailing
        default: .topLeading
        }
    }

    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.38) }

    // MARK: Body

    public var body: some View {
        let truncated = isTruncated
        let collapsed = truncated && !expanded
        let lastLine = max(metrics.limited - metrics.head, 0)

        VStack(alignment: .trailing, spacing: 2) {
            paragraph(truncated: truncated, collapsed: collapsed, lastLine: lastLine)

            if truncated && expanded && showsLess {
                link(lessLabel)
                    .transition(.opacity)
            }
        }
        .animation(motion, value: expanded)
        .onDisappear { pendingToggle?.cancel() }
    }

    /// The full text, clipped to the limited height while collapsed, with the fade and "more" on the last line.
    private func paragraph(truncated: Bool, collapsed: Bool, lastLine: CGFloat) -> some View {
        let visibleParagraph = text
            // Before the first measurement, a plain clamped Text shows the same first lines, so nothing jumps.
            .lineLimit(isMeasured ? nil : lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .frame(height: truncated ? (expanded ? metrics.full : metrics.limited) : nil, alignment: .top)
            .clipped()
            .mask(alignment: .top) {
                if style.fade == nil { fadeMask(lastLine: lastLine, collapsed: collapsed) } else { Rectangle() }
            }
            // Clipped lines keep no hit area: a link hidden below the fold cannot be tapped by accident.
            .contentShape(.rect)
            .simultaneousGesture(TapGesture().onEnded(bodyTapped), including: togglesOnTap && truncated ? .all : .subviews)
            .environment(\.openURL, OpenURLAction { url in
                lastLinkOpen = .now
                openURL(url)
                return .handled
            })
            // After the body tap, so tapping "more" never also counts as a body tap.
            .overlay(alignment: .topTrailing) {
                if collapsed {
                    moreAffordance(lastLine: lastLine)
                        .padding(.top, metrics.head)
                        .transition(.opacity)
                }
            }
            .background(alignment: .top) { measurers }
            // The text element always reads in full; the action only resizes it for sighted VoiceOver users.
            .accessibilityActions {
                if truncated && isEnabled && (!expanded || showsLess) {
                    Button(expanded ? LocalizedStringKey("접기") : LocalizedStringKey("더 보기")) {
                        setExpanded(!expanded)
                    }
                }
            }
        return Group {
            if let paragraphAccessibilityFocus {
                if let paragraphAccessibilityIdentifier {
                    visibleParagraph
                        .accessibilityIdentifier(paragraphAccessibilityIdentifier)
                        .accessibilityFocused(paragraphAccessibilityFocus)
                } else {
                    visibleParagraph.accessibilityFocused(paragraphAccessibilityFocus)
                }
            } else if let paragraphAccessibilityIdentifier {
                visibleParagraph.accessibilityIdentifier(paragraphAccessibilityIdentifier)
            } else {
                visibleParagraph
            }
        }
    }

    /// Opaque everywhere except the trailing end of the last collapsed line: a fade, then a hole the width of "more".
    private func fadeMask(lastLine: CGFloat, collapsed: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle().frame(height: metrics.head)
            HStack(spacing: 0) {
                Rectangle()
                fadeGradient([.black, .clear])
                    .frame(width: style.fadeWidth * scale)
                linkLabel(moreLabel).hidden()
            }
            .frame(height: lastLine)
            .overlay { Rectangle().opacity(collapsed ? 0 : 1) }
            Rectangle()
        }
        .overlay { Rectangle().opacity(isTruncated ? 0 : 1) }
    }

    /// "More" in the faded space, trailing edge of the last line. With a solid `fade` color, the gradient is painted here instead.
    private func moreAffordance(lastLine: CGFloat) -> some View {
        HStack(spacing: 0) {
            if let fade = style.fade {
                fadeGradient([fade.opacity(0), fade])
                    .frame(width: style.fadeWidth * scale)
                    .allowsHitTesting(false)
            }
            link(moreLabel)
                .background { style.fade }
        }
        .frame(height: lastLine)
    }

    private func fadeGradient(_ colors: [Color]) -> some View {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            .flipsForRightToLeftLayoutDirection(true)
    }

    private func linkLabel(_ label: LocalizedStringKey) -> some View {
        Text(label)
            .fontWeight(style.linkWeight)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 4)
            .frame(minWidth: 44)
    }

    /// A text link whose hit area is at least 44 x 44 even though it draws at one line tall.
    private func link(_ label: LocalizedStringKey) -> some View {
        Button {
            pendingToggle?.cancel()
            setExpanded(!expanded)
        } label: {
            linkLabel(label)
                .foregroundStyle(style.link)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle().inset(by: -12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(expanded ? "expandableText.collapse" : "expandableText.expand")
    }

    // MARK: Measuring

    /// Hidden copies laid out at the paragraph's width. They never depend on the expanded state, so there is no layout loop.
    private var measurers: some View {
        ZStack(alignment: .top) {
            text
                .fixedSize(horizontal: false, vertical: true)
                .modifier(HeightReader { metrics.full = $0 })
            text
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(HeightReader { metrics.limited = $0 })
            if lineLimit > 1 {
                text
                    .lineLimit(lineLimit - 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(HeightReader { metrics.head = $0 })
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Taps

    private func bodyTapped() {
        guard isEnabled, isTruncated, !expanded || showsLess else { return }
        guard hasLinks else { return setExpanded(!expanded) }
        // A tap on a link also ends this gesture. Wait a beat and skip the toggle if a link opened.
        let tapped = Date.now
        pendingToggle?.cancel()
        pendingToggle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, lastLinkOpen < tapped.addingTimeInterval(-0.4) else { return }
            setExpanded(!expanded)
        }
    }
}

/// Reports a view's height on first layout and on every change: `onGeometryChange` on iOS 18, a GeometryReader before.
private struct HeightReader: ViewModifier {
    let action: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                action(height)
            }
        } else {
            content.background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { action(proxy.size.height) }
                        .onChange(of: proxy.size.height) { _, height in action(height) }
                }
            }
        }
    }
}

/// A house-palette color that follows the interface style.
private func adaptive(light: UInt32, dark: UInt32) -> Color {
    mirrorAdaptiveColor(light: light, dark: dark)
}
