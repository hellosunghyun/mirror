import Foundation
import SwiftUI
import WidgetKit
import AppIntents
import MirrorDomain
import MirrorSystem

@main
struct MirrorWidgets: WidgetBundle {
    var body: some Widget {
        MirrorReviewWidget()
        #if os(iOS)
        MirrorCaptureControl()
        #endif
    }
}

struct MirrorWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "미러 정리와 오늘"
    static let description = IntentDescription("같은 설정 위젯은 현재 정리 카드와 결정을 공유해요.")
}
struct MirrorWidgetEntry: TimelineEntry {
    let date: Date
    let state: WidgetReviewState
}
struct MirrorWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = MirrorWidgetConfiguration
    typealias Entry = MirrorWidgetEntry
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), state: .init(mode: .loading))
    }
    func snapshot(for configuration: Intent, in context: Context) async -> Entry { await entry() }
    func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let value = await entry()
        let refresh: Date
        if let planning = value.state.context, let zone = TimeZone(identifier: planning.timeZoneID),
           let tomorrow = try? planning.planningDay.addingDays(1) {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            refresh = calendar.date(from: DateComponents(year: tomorrow.year, month: tomorrow.month, day: tomorrow.day)) ?? value.date.addingTimeInterval(15 * 60)
        } else { refresh = value.date.addingTimeInterval(15 * 60) }
        return Timeline(entries: [value], policy: .after(refresh))
    }
    private func entry() async -> Entry {
        do {
            let services = try await SystemCompositionRoot.open(role: .sharedExtension)
            return Entry(date: Date(), state: try await services.widget.snapshot())
        } catch {
            let mode: WidgetDisplayMode
            switch error {
            case SystemServiceError.configurationRequired: mode = .configurationRequired
            case SystemServiceError.privacyLocked: mode = .privacyLocked
            default: mode = .unavailable
            }
            return Entry(date: Date(), state: .init(mode: mode))
        }
    }
}
struct MirrorReviewWidget: Widget {
    let kind = "mirror.review-today"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: MirrorWidgetConfiguration.self, provider: MirrorWidgetProvider()) { entry in
            MirrorWidgetView(state: entry.state).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("정리하고 오늘에 남기기")
        .description("미검토는 오늘 할 일이 아니에요. 날짜를 정하거나 오늘 목록을 확인하세요.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

struct MirrorWidgetView: View {
    let state: WidgetReviewState
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 2 : 8) {
            HStack {
                Text(state.context?.planningDay.description ?? "미러").font(.caption)
                Spacer()
                if state.mode == .review {
                    Button(intent: FinishReviewIntent(state: state)) { Image(systemName: "pause.circle") }
                        .frame(minWidth: 44, minHeight: 44).accessibilityLabel("이번엔 여기까지, 정리 마치기")
                }
                Link(destination: MirrorDeepLink.url(for: .capture)) { Image(systemName: "plus") }
                    .frame(minWidth: 44, minHeight: 44).accessibilityLabel("할 일 넣기")
            }
            switch state.mode {
            case .review:
                if let card = state.card {
                    if family == .systemSmall { smallReview(card) }
                    else if typeSize.isAccessibilitySize { accessibleReview(card) }
                    else { review(card) }
                } else { unavailable("카드를 다시 불러오세요.") }
            case .today: today
            case .empty:
                Text("정리할 후보가 없어요.").font(.headline)
                Text("미검토를 오늘에 자동으로 넣지 않아요.").font(.caption)
                Button(intent: FinishReviewIntent(state: state)) { Text("이번 정리 마치기") }.frame(minHeight: 44)
            case .configurationRequired: unavailable("앱과 위젯의 공유 저장소 설정이 필요해요.")
            case .privacyLocked: unavailable("잠금을 해제하고 미러를 여세요.")
            case .unavailable: unavailable("지금 데이터를 읽을 수 없어요.")
            case .loading: Text("불러오는 중…").font(.headline)
            }
            if family != .systemSmall, let message = state.message {
                Text(message).font(.caption2).lineLimit(2)
            }
            if family == .systemLarge || family == .systemExtraLarge {
                if let operation = state.lastOperationID {
                    if let intent = try? UndoDisplayedWidgetDecisionIntent(.init(state: state, operationID: operation)) {
                        Button(intent: intent) { Label("직전 결정 되돌리기", systemImage: "arrow.uturn.backward") }.frame(minHeight: 44)
                    } else { Text("되돌리기 정보를 읽을 수 없어요. 앱에서 변경 이력을 확인하세요.").font(.caption) }
                }
            }
        }.padding(8)
    }

    @ViewBuilder private func review(_ card: WidgetCard) -> some View {
        Text(card.title).font(.headline).lineLimit(family == .systemMedium ? 1 : 3).privacySensitive()
        if family != .systemMedium, let deadline = card.deadlineSummary {
            Text("실제 마감 \(deadline)").font(.caption)
        }
        if state.panel == .card {
            if let context = state.context, let destinations = try? context.destinations() {
                HStack(spacing: 4) {
                    decision("오늘", card: card, target: .day(destinations.today))
                    decision("내일", card: card, target: .day(destinations.tomorrow))
                    Button(intent: ShowWidgetDatePanelIntent(state: state, card: card, panel: .thisWeek)) { Text("이번 주") }.frame(maxWidth: .infinity, minHeight: 44)
                }
                HStack(spacing: 4) {
                    Button(intent: ShowWidgetDatePanelIntent(state: state, card: card, panel: .nextWeek)) { Text("다음 주") }.frame(maxWidth: .infinity, minHeight: 44)
                    Button(intent: OpenDatePickerIntent(state: state, card: card)) { Text("기타") }.frame(maxWidth: .infinity, minHeight: 44)
                }
            } else { Text("날짜 기준을 다시 불러오세요.").font(.caption) }
            if family != .systemMedium {
                Button(intent: FinishReviewIntent(state: state)) { Text("이번엔 여기까지") }.frame(minHeight: 44)
            }
        } else { weekPanel(card) }
    }

    @ViewBuilder private func weekPanel(_ card: WidgetCard) -> some View {
        if let context = state.context, let destinations = try? context.destinations() {
            let week = state.panel == .thisWeek ? destinations.thisWeek : destinations.nextWeek
            let dates = (0..<7).compactMap { try? week.startDate.addingDays($0) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
                ForEach(dates, id: \.self) { date in
                    if date >= context.planningDay {
                        decision("\(weekday(date)) \(date.day)", card: card, target: .day(date))
                            .accessibilityLabel("\(date.month)월 \(date.day)일 \(weekday(date))요일에 배치")
                    } else { Text("\(weekday(date)) \(date.day)").font(.caption).foregroundStyle(.secondary).frame(minHeight: 44).accessibilityLabel("이미 지난 날짜") }
                }
                Button(intent: ShowWidgetDatePanelIntent(state: state, card: card, panel: .card)) { Text("뒤로") }.frame(minHeight: 44)
            }
            decision("요일은 나중에", card: card, target: .week(startDate: week.startDate, endExclusiveDate: week.endExclusiveDate))
        } else { unavailable("주간 날짜를 읽을 수 없어요.") }
    }

    @ViewBuilder private func decision(_ title: String, card: WidgetCard, target: PlanTarget) -> some View {
        if let intent = try? CommitWidgetDecisionIntent(.init(scopeKey: state.scopeKey, sessionID: state.sessionID, card: card, target: target)) {
            Button(intent: intent) { Text(title).font(.caption).frame(maxWidth: .infinity) }.frame(maxWidth: .infinity, minHeight: 44)
        } else { Text("결정을 준비할 수 없어요.").font(.caption) }
    }
    private func smallReview(_ card: WidgetCard) -> some View {
        VStack(alignment: .leading) {
            Text("날짜를 정할 일 \(state.queue.count)개").font(.headline)
            Link("정리 열기", destination: MirrorDeepLink.url(for: .review(weekly: false))).frame(minHeight: 44)
        }
    }
    private func accessibleReview(_ card: WidgetCard) -> some View {
        VStack(alignment: .leading) {
            Text(card.title).font(.headline).privacySensitive()
            Text("큰 글자에서는 앱에서 5개 목적지를 선택하세요.").font(.caption)
            Link("이 작업의 날짜 고르기", destination: MirrorDeepLink.url(for: .schedule(taskID: card.taskID, sessionID: state.sessionID, cardID: card.cardID))).frame(minHeight: 44)
        }
    }
    private var today: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("오늘에 남긴 일").font(.headline)
            if state.today.isEmpty { Text("아직 오늘에 남긴 일이 없어요.").font(.caption) }
            ForEach(Array(state.today.prefix(family == .systemSmall ? 1 : family == .systemMedium ? 2 : 5)), id: \.taskID) { item in
                Button(intent: CompleteDisplayedWidgetTaskIntent(item: item)) {
                    Label(item.title, systemImage: "circle").lineLimit(1).privacySensitive()
                }.frame(minHeight: 44).accessibilityLabel("\(item.title), 완료하기")
            }
            Link("오늘 다시 정리", destination: MirrorDeepLink.url(for: .review(weekly: false)))
        }
    }
    private func unavailable(_ message: String) -> some View {
        VStack(alignment: .leading) {
            Text(message).font(.caption)
            Link("미러 열기", destination: MirrorDeepLink.url(for: .today)).frame(minHeight: 44)
        }
    }
    private func weekday(_ date: LocalDate) -> String {
        guard let week = try? date.mondayWeek() else { return "" }
        let names = ["월", "화", "수", "목", "금", "토", "일"]
        return (0..<7).first(where: { (try? week.startDate.addingDays($0)) == date }).map { names[$0] } ?? ""
    }
}

#if os(iOS)
struct MirrorCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "mirror.capture-control") {
            ControlWidgetButton(action: MirrorOpenCaptureIntent()) { Label("할 일 넣기", systemImage: "plus") }
        }.displayName("미러에 할 일 넣기").description("미러의 빠른 입력을 열어요. 컨트롤 배치는 사용자가 선택해요.")
    }
}
struct MirrorOpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "미러 빠른 입력 열기"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(MirrorDeepLink.url(for: .capture)))
    }
}
#endif
