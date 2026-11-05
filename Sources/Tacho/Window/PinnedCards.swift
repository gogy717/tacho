import Charts
import SwiftUI
import TachoKit

/// A pinned card at the window's size: spec section 11.2.
struct PinnedCardView: View {
    let card: SummaryState.PinnedCardState
    let open: (Route) -> Void

    var body: some View {
        Card(action: { open(card.route) }) {
            CardHeader(card.title)
            if let value = card.value {
                Text(value)
                    .font(Theme.Style.figureL)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            visual
                .padding(.top, 2)
            if let say = card.say {
                Say(say)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var visual: some View {
        switch card.visual {
        case .none:
            EmptyView()
        case .needle(let value, let p25, let p75):
            NeedleMark(value: value, p25: p25, p75: p75)
        case .spark(let values, let color):
            Sparkline(values: values, color: color)
                .frame(height: 44)
        case .shares(let parts):
            SplitBar(parts: parts)
        case .rows(let rows, let more):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 6)
                            Text(row.figure)
                                .monospacedDigit()
                                .fixedSize()
                        }
                        .font(Theme.Style.small)
                        if let fraction = row.fraction {
                            FractionBar(fraction: fraction)
                        }
                    }
                }
                if more > 0 {
                    Text(String(format: String(localized: "list.more", bundle: .tacho), more))
                        .font(Theme.Style.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .hours(let hours):
            HourMap(hours: hours)
                .frame(height: 78)
        case .bars(let values):
            HourBars(values: values)
                .frame(height: 50)
        }
    }
}

/// Cards in as many equal columns as the room holds, one at least, none narrower than its content needs or than `narrowest`. A row's
/// cards share the height of its tallest, so that a short card is not left short.
struct CardGrid: Layout {
    /// 12 em of `small`: a card's figure in `figureL`, its title, and a say that wraps.
    static let narrowest: CGFloat = 12 * NSFont.preferredFont(forTextStyle: .callout).pointSize

    var spacing: CGFloat

    private func columns(in width: CGFloat, _ subviews: Subviews) -> Int {
        guard !subviews.isEmpty else { return 1 }
        let card = max(Self.narrowest, subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width }.max() ?? 0)
        return max(1, min(subviews.count, Int((width + spacing) / (card + spacing))))
    }

    private func rows(in width: CGFloat, _ subviews: Subviews) -> (columns: Int, column: CGFloat, heights: [CGFloat]) {
        let columns = columns(in: width, subviews)
        let column = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)].map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        }
        return (columns, column, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            // Its narrowest is one column; with no width asked, two side by side.
            let card = max(Self.narrowest, subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width }.max() ?? 0)
            return CGSize(width: proposal.width == 0 ? card : 2 * card + spacing, height: 0)
        }
        let rows = rows(in: width, subviews)
        return CGSize(width: width, height: rows.heights.reduce(0, +) + spacing * CGFloat(max(rows.heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(in: bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in rows.heights.enumerated() {
            for column in 0..<rows.columns {
                let index = row * rows.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (rows.column + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: rows.column, height: height))
            }
            y += height + spacing
        }
    }
}

/// Output by the day: the 7 days before in grey, the last 7 in Output's colour, on one scale.
struct WeekBars: View {
    private static let dayAxis = String(localized: "chart.category", bundle: .tacho)
    private static let valueAxis = String(localized: "chart.value", bundle: .tacho)

    let week: SummaryState.WeekColumns

    var body: some View {
        Chart {
            ForEach(week.before.indices, id: \.self) { index in
                BarMark(x: .value(Self.dayAxis, "b\(index)"), y: .value(Self.valueAxis, week.before[index]))
                    .cornerRadius(1.5)
                    .foregroundStyle(Theme.well)
            }
            ForEach(week.last.indices, id: \.self) { index in
                BarMark(x: .value(Self.dayAxis, "l\(index)"), y: .value(Self.valueAxis, week.last[index]))
                    .cornerRadius(1.5)
                    .foregroundStyle(Theme.output)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

/// A day's output by the hour.
struct HourBars: View {
    private static let hourAxis = String(localized: "chart.hour", bundle: .tacho)
    private static let valueAxis = String(localized: "chart.value", bundle: .tacho)

    let values: [Double]

    var body: some View {
        Chart {
            ForEach(values.indices, id: \.self) { index in
                BarMark(x: .value(Self.hourAxis, String(index)), y: .value(Self.valueAxis, values[index]))
                    .cornerRadius(1.5)
                    .foregroundStyle(Theme.output)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

/// When use falls in the week, in the shades of the Calendar page.
struct HourMap: View {
    let hours: [[Int]]

    var body: some View {
        Canvas { context, size in
            let scale = HeatScale(hours.flatMap { $0.map(Double.init) })
            let rows = hours.count
            let columns = hours.first?.count ?? 0
            guard rows > 0, columns > 0 else { return }
            let width = size.width / CGFloat(columns)
            let height = size.height / CGFloat(rows)
            for (row, line) in hours.enumerated() {
                for (column, value) in line.enumerated() {
                    let cell = CGRect(x: CGFloat(column) * width, y: CGFloat(row) * height, width: width - 1, height: height - 1)
                    context.fill(Path(cell), with: .color(scale.color(of: Double(value))))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Which cards to keep, and in what order: spec section 11.3.
struct PinsSheet: View {
    @State private var cards: [PinnedCard]
    @State private var kept: Set<PinnedCard>

    let done: ([PinnedCard]) -> Void

    init(pinned: [PinnedCard], done: @escaping ([PinnedCard]) -> Void) {
        _cards = State(initialValue: pinned + PinnedCard.allCases.filter { !pinned.contains($0) })
        _kept = State(initialValue: Set(pinned))
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "pins.title", bundle: .tacho))
                .font(Theme.Style.value)
            Text(String(localized: "pins.note", bundle: .tacho))
                .font(Theme.Style.small)
                .foregroundStyle(.secondary)
            List {
                ForEach(cards, id: \.self) { card in
                    Toggle(WindowLabels.title(of: card), isOn: Binding(
                        get: { kept.contains(card) },
                        set: { isOn in
                            if isOn { kept.insert(card) } else { kept.remove(card) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
                .onMove { cards.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: 190)
            HStack {
                Spacer()
                Button(String(localized: "common.done", bundle: .tacho)) { done(cards.filter(kept.contains)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
