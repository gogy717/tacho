import SwiftUI
import TachoKit

/// The rate now and the last hour: spec §4.1 and §3.4.
struct PanelHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection: Int?

    let rate: PanelState.Rate
    let now: Date
    /// 44 in the blocked strip.
    var chartHeight: CGFloat = 34
    let pick: (RateMode) -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RateFigure(rate: rate, pick: pick, openSettings: openSettings)
                Spacer(minLength: 8)
                switch rate.headline {
                case .reading:
                    EmptyView()
                case .live:
                    LiveBadge(isLive: true, text: String(localized: "live.on", bundle: .tacho))
                case .idle:
                    LiveBadge(isLive: false, text: String(localized: "live.off", bundle: .tacho))
                }
            }
            if let note = rate.note {
                Say(note, tone: .warning)
            }
            MinuteChart(
                series: rate.series,
                layers: rate.layers.map { .init(name: $0.name, color: $0.color) },
                label: String(localized: "panel.chartLabel", bundle: .tacho),
                emptyText: rate.emptyText,
                selection: $selection
            )
            .equatable()
            .frame(height: chartHeight)
            axis
        }
        .padding(EdgeInsets(top: 12, leading: Theme.Size.panelInset, bottom: 10, trailing: Theme.Size.panelInset))
        .animation(Theme.motion(.easeOut(duration: 0.2), reduceMotion: reduceMotion), value: rate.mode)
    }

    private var axis: some View {
        HStack(spacing: 6) {
            Text(String(localized: "chart.hourAgo", bundle: .tacho))
                .fixedSize()
            Spacer(minLength: 0)
            if let reading = selectedReading {
                Text(reading)
                    .monospacedDigit()
            } else {
                legend
            }
            Spacer(minLength: 0)
            Text(String(localized: "chart.now", bundle: .tacho))
                .fixedSize()
        }
        .font(Theme.Style.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// Output has one layer, so its name is enough; with more, colour alone cannot say which is which.
    @ViewBuilder private var legend: some View {
        if rate.layers.count == 1 {
            Text(rate.modeName)
        } else {
            HStack(spacing: 5) {
                ForEach(rate.layers, id: \.self) { category in
                    HStack(spacing: 3) {
                        Swatch(color: category.color)
                        Text(category.name)
                    }
                }
            }
            .fixedSize()
        }
    }

    /// The minute under the pointer and its value: `15:12 · 18.2k`.
    private var selectedReading: String? {
        guard let selection, let figure = rate.figure(ofMinute: rate.series.count - 1 + selection) else { return nil }
        return String(format: String(localized: "rate.menu.item", bundle: .tacho), Self.minute(selection, now: now), figure)
    }

    /// When a minute of the chart was, which just after midnight is yesterday.
    nonisolated static func minute(_ selection: Int, now: Date, calendar: Calendar = .current) -> String {
        Labels.reset(now.addingTimeInterval(Double(selection) * 60), now: now, calendar: calendar)
    }
}

/// The headline as a menu of the three readings, so that it answers before you pick.
struct RateFigure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let rate: PanelState.Rate
    let pick: (RateMode) -> Void
    let openSettings: () -> Void

    var body: some View {
        switch rate.headline {
        case .reading:
            Text(String(localized: "rate.reading", bundle: .tacho))
                .font(Theme.Style.figureL)
        case .live(let figure):
            menu {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(figure)
                        .font(Theme.Style.figureL)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text(rate.modeName)
                        .font(Theme.Style.caption)
                        .foregroundStyle(.secondary)
                    indicator
                }
            }
        case .idle(let lastSeen):
            menu {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(localized: "rate.idle", bundle: .tacho))
                        .font(Theme.Style.figureL)
                    if let lastSeen {
                        Text(lastSeen)
                            .font(Theme.Style.caption)
                            .foregroundStyle(.secondary)
                    }
                    indicator
                }
            }
        }
    }

    /// Drawn in the label: a plain menu shows no indicator of its own.
    private var indicator: some View {
        Image(systemName: "chevron.down")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func menu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            Picker(String(localized: "rate.switch", bundle: .tacho), selection: Binding(get: { rate.mode }, set: { pick($0) })) {
                ForEach(rate.readings) { Text($0.title).tag($0.mode) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button(String(localized: "rate.menu.settings", bundle: .tacho), action: openSettings)
        } label: {
            label()
        }
        // Not `.borderlessButton`: that draws a label's first text alone, which would drop the mode's name.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "rate.average", bundle: .tacho))
        .accessibilityLabel(String(localized: "rate.switch", bundle: .tacho))
        .accessibilityValue(rate.spoken)
    }
}
