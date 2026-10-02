// Copyright (c) 2026 Saivion Hayes. MIT + Commons Clause; see LICENSE.swiftpieces.
// Adapted for Mirror; see PROVENANCE.md.
// swiftpieces:
// title: Task Row
// description: A task card whose check draws itself while the card flashes into a solid color block, a priority label block, a swipe-right that completes with a strike-through then compacts the row, swipe-left snooze and delete blocks, and a long-press lift that reports reorder moves.
// category: lists
// minIOSVersion: "17.0"
// version: "2.0.0"
// pro: transaction-row
// tags: [task, todo, swipe, reorder, productivity, blocks]

import SwiftUI


/// Interactive task row for to-do lists, driven by a bound `Status`.
///
/// - Parameters:
///   - title: Task text.
///   - status: `.open`, `.completed`, or `.snoozed`. Set it from outside and the row animates to match.
///   - due: Optional secondary label, such as "Today, 5 PM".
///   - priority: Optional priority label block at the trailing edge.
///   - tint: Block color for the check, the completion flash and the complete tile. `nil` uses `style.complete`.
///   - style: Card surface, text colors, priority and tile blocks, and corner radius. Defaults to the house palette.
///   - onTap: Called when the row body is tapped, typically to open the task.
///   - snoozeLabel: Label shared by the Snooze block, snoozed status and accessibility action. Defaults to "당분간 보관".
///   - onSnooze: Adds a Snooze block behind a left swipe and is called when it is chosen.
///   - onDelete: Adds a Delete block behind a left swipe and is called when it is chosen.
///   - onMove: Enables long-press lift and reports how many rows the user dragged it (negative is up) on release.
@MainActor
public struct TaskRow: View {
    public enum Status: Equatable { case open, completed, snoozed }
    public enum Priority { case low, medium, high }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Binding private var status: Status
    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat? = nil
    @State private var armed = false
    @State private var check: CGFloat = 0
    @State private var strike: CGFloat = 0
    @State private var compact = false
    @State private var lifted = false
    @State private var lift: CGFloat = 0
    @State private var rowHeight: CGFloat = 52
    @State private var completions = 0

    private let title: String
    private let due: String?
    private let priority: Priority?
    private let tint: Color
    private let style: Style
    private let onTap: (() -> Void)?
    private let snoozeLabel: String
    private let onSnooze: (() -> Void)?
    private let onDelete: (() -> Void)?
    private let onMove: ((Int) -> Void)?

    private let tileWidth: CGFloat = 76
    private let tileGap: CGFloat = 6
    private let completeThreshold: CGFloat = 104

    public init(_ title: String, status: Binding<Status>, due: String? = nil, priority: Priority? = nil, tint: Color? = nil, style: Style = .standard, onTap: (() -> Void)? = nil, snoozeLabel: String = "당분간 보관", onSnooze: (() -> Void)? = nil, onDelete: (() -> Void)? = nil, onMove: ((Int) -> Void)? = nil) {
        self.title = title
        self._status = status
        self.due = due
        self.priority = priority
        self.tint = tint ?? style.complete
        self.style = style
        self.onTap = onTap
        self.snoozeLabel = snoozeLabel
        self.onSnooze = onSnooze
        self.onDelete = onDelete
        self.onMove = onMove
    }

    private var completing: Bool { status == .completed && !compact }
    private var spring: Animation { reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.18) }
    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous) }

    public var body: some View {
        card
            .scaleEffect(lifted ? 1.03 : 1)
            .shadow(color: .black.opacity(lifted ? 0.2 : 0), radius: 22, y: 12)
            .offset(x: offset, y: lift)
            .zIndex(lifted ? 1 : 0)
            .background(alignment: .leading) { completeTile }
            .background(alignment: .trailing) { trailingTiles }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(.rect)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
            .gesture(swipe, including: isEnabled ? .all : .subviews)
            .highPriorityGesture(liftGesture, including: onMove == nil || !isEnabled ? .none : .all)
            .animation(.spring(duration: 0.35, bounce: 0.2), value: lifted)
            .onChange(of: status, initial: true) { old, new in apply(new, from: old) }
            .sensoryFeedback(.impact(flexibility: .rigid), trigger: armed) { _, isArmed in isArmed }
            .sensoryFeedback(.impact(flexibility: .soft), trigger: lifted) { _, isLifted in isLifted }
            .sensoryFeedback(.success, trigger: completions)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap?() }
            .accessibilityActions {
                Button(status == .completed ? "다시 열기" : "완료") { toggle() }
                if let onSnooze { Button(snoozeLabel) { status = .snoozed; onSnooze() } }
                if let onDelete { Button("휴지통으로 이동", role: .destructive, action: onDelete) }
                if let onMove {
                    Button("위로 이동") { onMove(-1) }
                    Button("아래로 이동") { onMove(1) }
                }
            }
    }

    // MARK: Card

    private var card: some View {
        HStack(spacing: 8) {
            checkControl
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(compact ? .subheadline : .body.weight(.medium))
                    .foregroundStyle(status == .open ? style.text : style.muted)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: .leading) {
                        // The strike draws from the leading edge over the text's own width.
                        Capsule()
                            .fill(style.muted)
                            .frame(height: 2)
                            .scaleEffect(x: strike, y: 1, anchor: .leading)
                            .opacity(strike > 0 ? 1 : 0)
                    }
                if !compact, status == .snoozed || due != nil {
                    meta
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if let priority, !compact, status == .open {
                priorityLabel(priority)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                style.surface
                // 저장된 완료 상태의 짧은 피드백만 남기고 목록의 대비와 밀도를 유지한다.
                tint.opacity(completing ? 0.12 : 0)
            }
        }
        .clipShape(cardShape)
        .contentShape(cardShape)
        .onTapGesture { if offset != 0 { settle(0) } else { onTap?() } }
    }

    @ViewBuilder
    private var meta: some View {
        if status == .snoozed {
            Label(snoozeLabel, systemImage: "moon.zzz.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(style.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(style.snooze, in: Capsule())
        } else if let due {
            Label(due, systemImage: "calendar")
                .font(.footnote.weight(.medium))
                .foregroundStyle(style.muted)
                .labelStyle(TightLabel())
        }
    }

    private func priorityLabel(_ priority: Priority) -> some View {
        let (label, color): (String, Color) = switch priority {
        case .low: ("LOW", style.low)
        case .medium: ("MED", style.medium)
        case .high: ("HIGH", style.high)
        }
        return Text(label)
            .font(.caption2.weight(.heavy))
            .tracking(0.8)
            .foregroundStyle(style.ink)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(color, in: Capsule())
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var checkControl: some View {
        Button(action: toggle) {
            ZStack {
                Circle()
                    .strokeBorder(status == .open ? style.muted.opacity(0.55) : .clear, lineWidth: 1.5)
                Circle()
                    .fill(status == .snoozed ? style.snooze : completing ? style.ink : tint)
                    .scaleEffect(status == .open ? 0.001 : 1)
                if status == .snoozed {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(style.ink)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    checkmark
                        .trim(from: 0, to: check)
                        .stroke(completing ? tint : style.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .animation(spring, value: status)
        }
        .buttonStyle(PressStyle(reduceMotion: reduceMotion))
    }

    private var checkmark: Path {
        Path { path in
            let s = compact ? 18.0 : 20.0
            path.move(to: CGPoint(x: s * 0.29, y: s * 0.52))
            path.addLine(to: CGPoint(x: s * 0.44, y: s * 0.67))
            path.addLine(to: CGPoint(x: s * 0.72, y: s * 0.37))
        }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        switch status {
        case .open: parts.append("미완료")
        case .completed: parts.append("완료")
        case .snoozed: parts.append(snoozeLabel)
        }
        if let due, status != .snoozed { parts.append("배치: \(due)") }
        if let priority, status == .open {
            switch priority {
            case .low: parts.append("낮은 우선순위")
            case .medium: parts.append("보통 우선순위")
            case .high: parts.append("높은 우선순위")
            }
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Tiles

    @ViewBuilder
    private var completeTile: some View {
        let revealed = max(offset - tileGap, 0)
        if revealed > 0 {
            let reveal = min(1, revealed / completeThreshold)
            Image(systemName: status == .completed ? "arrow.uturn.backward" : "checkmark")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(style.ink)
                .scaleEffect(0.55 + 0.45 * reveal + (armed ? 0.2 : 0))
                .frame(width: revealed, height: rowHeight)
                .background(tint, in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
                .animation(.snappy(duration: 0.2), value: armed)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailingTiles: some View {
        let revealed = max(-offset, 0)
        if revealed > 0, trailingCount > 0 {
            let reveal = min(1, revealed / trailingWidth)
            HStack(spacing: tileGap) {
                if let onSnooze {
                    tile(snoozeLabel, systemImage: "moon.zzz", color: style.snooze, reveal: reveal) { status = .snoozed; onSnooze() }
                }
                if let onDelete {
                    tile("휴지통으로 이동", systemImage: "trash", color: style.delete, reveal: reveal, action: onDelete)
                }
            }
            .padding(.leading, tileGap)
            .frame(width: revealed, alignment: .leading)
            .clipped()
            .accessibilityHidden(true)
        }
    }

    private func tile(_ label: String, systemImage: String, color: Color, reveal: CGFloat, action: @escaping () -> Void) -> some View {
        Button { settle(0); action() } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .scaleEffect(0.55 + 0.45 * reveal)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .opacity(max(0, (reveal - 0.45) / 0.55))
            }
            .foregroundStyle(style.ink)
            .frame(width: tileWidth - tileGap, height: rowHeight)
            .background(color, in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        }
        .buttonStyle(PressStyle(reduceMotion: reduceMotion))
    }

    private var trailingCount: Int { (onSnooze == nil ? 0 : 1) + (onDelete == nil ? 0 : 1) }
    private var trailingWidth: CGFloat { tileWidth * CGFloat(trailingCount) }

    // MARK: Gestures

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !lifted else { return }
                if dragStart == nil {
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragStart = offset
                }
                guard let dragStart else { return }
                let x = dragStart + value.translation.width
                if x > 0 {
                    // Past the threshold the row eases toward a limit so the commit point feels like a detent.
                    offset = x < completeThreshold ? x : completeThreshold + rubber(x - completeThreshold)
                } else {
                    offset = trailingCount == 0 ? -rubber(-x) : max(x, -trailingWidth - rubber(-x - trailingWidth))
                }
                let nowArmed = offset >= completeThreshold
                if nowArmed != armed { armed = nowArmed }
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                dragStart = nil
                if armed {
                    armed = false
                    settle(0)
                    toggle()
                    return
                }
                let projected = start + value.predictedEndTranslation.width
                settle(projected < -trailingWidth / 2 && trailingCount > 0 ? -trailingWidth : 0)
            }
    }

    private var liftGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !lifted { lifted = true }
                lift = drag?.translation.height ?? 0
            }
            .onEnded { _ in
                let steps = Int((lift / (rowHeight + 8)).rounded())
                withAnimation(spring) { lift = 0 }
                lifted = false
                if steps != 0 { onMove?(steps) }
            }
    }

    private func rubber(_ distance: CGFloat) -> CGFloat { 40 * (1 - 1 / (1 + distance / 40)) }

    private func settle(_ target: CGFloat) {
        withAnimation(spring) { offset = target }
    }

    // MARK: State

    private func toggle() {
        status = status == .completed ? .open : .completed
    }

    private func apply(_ new: Status, from old: Status) {
        switch new {
        case .completed:
            if old != .completed { completions += 1 }
            if old == new {
                // Rows that load already completed start settled, with no flash.
                check = 1; strike = 1; compact = true
            } else if reduceMotion {
                withAnimation(.easeOut(duration: 0.25)) { check = 1; strike = 1; compact = true }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { check = 1 }
                withAnimation(.easeInOut(duration: 0.35).delay(0.15)) { strike = 1 }
                withAnimation(.spring(duration: 0.45, bounce: 0.12).delay(0.7)) { compact = true }
            }
        case .open, .snoozed:
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.1)) {
                check = 0
                strike = 0
                compact = false
            }
        }
    }

    private struct PressStyle: ButtonStyle {
        let reduceMotion: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
                .animation(.spring(duration: 0.3, bounce: 0.3), value: configuration.isPressed)
        }
    }

    private struct TightLabel: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) {
                configuration.icon.imageScale(.small)
                configuration.title
            }
        }
    }
}

public extension TaskRow {
    /// Look of a `TaskRow`. Start from `.standard` and change what you need.
    struct Style: Sendable {
        /// Card fill. Adapts to light and dark.
        public var surface: Color = Style.adaptive(0xFFFFFF, 0x1C1C1C)
        /// Title color for open tasks.
        public var text: Color = Style.adaptive(0x141414, 0xF4F3EF)
        /// Due label, strike-through and finished titles.
        public var muted: Color = Style.adaptive(0x5C5A56, 0xA6A49F)
        /// Dark ink used on every block.
        public var ink: Color = Color(red: 0.078, green: 0.078, blue: 0.078)
        /// Check fill, completion wash and complete tile, unless `tint` is passed.
        public var complete: Color = Color(red: 0.663, green: 0.863, blue: 0.718)
        /// Snooze tile, snoozed check and label.
        public var snooze: Color = Color(red: 0.804, green: 0.722, blue: 1)
        /// Delete tile.
        public var delete: Color = Color(red: 1, green: 0, blue: 0)
        /// Priority label blocks.
        public var high: Color = Color(red: 1, green: 0, blue: 0)
        public var medium: Color = Color(red: 1, green: 0.851, blue: 0.463)
        public var low: Color = Color(red: 0.612, green: 0.761, blue: 1)
        /// Corner radius of the card and its tiles.
        public var cornerRadius: CGFloat = 22

        public init() {}

        /// The house palette: white or charcoal cards, sage check, lilac snooze, signal delete.
        public static let standard = Style()

        private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
            mirrorAdaptiveColor(light: light, dark: dark)
        }
    }
}
