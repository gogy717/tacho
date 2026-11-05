import SwiftUI

/// Every limit at a glance: how far through it, and when it resets. Spec §4.5.
///
/// One line to a limit, in columns, and not cells side by side. A cell has to hold a label and a percent on one line and a reset
/// time on another, about 85 pt, and three beside the provider's name have 66: `≈ 78%` and `Sun 12:06 pm` were cut off, and a figure
/// nobody can read is the card failing at its one job.
struct LimitsCard: View {
    let limits: PanelState.Limits
    let open: () -> Void

    /// What the columns lay out, a line at a time.
    private enum Line {
        case limit(name: String?, PanelState.LimitCell)
        case message(name: String, String)
        case list(name: String, String)
    }

    private var lines: [Line] {
        limits.rows.flatMap { row -> [Line] in
            switch row.content {
            case .message(let text): [.message(name: row.name, text)]
            case .line(let text): [.list(name: row.name, text)]
            case .cells(let cells): cells.enumerated().map { .limit(name: $0.offset == 0 ? row.name : nil, $0.element) }
            }
        }
    }

    var body: some View {
        Card(action: open) {
            CardHeader(String(localized: "quota.title", bundle: .tacho), opens: true) {
                if let age = limits.age {
                    Text(age)
                        .font(Theme.Style.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let say = limits.say {
                Say(say, tone: limits.tone)
            }
            if !limits.rows.isEmpty {
                LimitColumns {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        self.line(line, at: index)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private func line(_ line: Line, at index: Int) -> some View {
        switch line {
        case .limit(let name, let cell):
            if let name { self.name(name, at: index) }
            Text(cell.label)
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutValue(key: LimitColumns.Place.self, value: .init(line: index, column: .label))
            Meter(value: cell.value, tick: cell.pace, level: cell.level)
                .help(String(localized: "limit.tickHelp", bundle: .tacho))
                .layoutValue(key: LimitColumns.Place.self, value: .init(line: index, column: .meter))
            Text(cell.percent)
                .font(Theme.Style.small.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                .layoutValue(key: LimitColumns.Place.self, value: .init(line: index, column: .percent))
            Text(cell.caption)
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutValue(key: LimitColumns.Place.self, value: .init(line: index, column: .reset))
        case .message(let name, let text):
            self.name(name, at: index)
            Text(text)
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
                .layoutValue(key: LimitColumns.Place.self, value: .init(line: index, column: .text))
        case .list(let name, let text):
            self.name(name, at: index)
            Text(text)
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutValue(key: LimitColumns.Place.self, value: .init(line: index, column: .text))
        }
    }

    private func name(_ text: String, at index: Int) -> some View {
        Text(text)
            .font(Theme.Style.small)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .layoutValue(key: LimitColumns.Place.self, value: .init(line: index, column: .name))
    }
}

/// The card's columns. The name, percent and reset each get their widest entry, a label what is left after the shortest meter, and the
/// meter all the rest, so a figure is never cut, whatever the language. A line of text runs from the label's column to the edge and
/// takes no part in any of this: no length of it moves a column, which a `Grid` could not promise.
private struct LimitColumns: Layout {
    enum Column {
        case name, label, meter, percent, reset, text
    }

    struct Place: LayoutValueKey {
        static let defaultValue = Place(line: 0, column: .text)

        var line: Int
        var column: Column
    }

    private static let columnGap: CGFloat = 6
    private static let lineGap: CGFloat = 5
    private static let shortestMeter: CGFloat = 24
    /// What a meter gets when nothing proposes a width.
    private static let idealMeter: CGFloat = 64

    struct Widths {
        var name: CGFloat
        var label: CGFloat
        var meter: CGFloat
        var percent: CGFloat
        var reset: CGFloat
        var text: CGFloat

        func of(_ column: Column) -> CGFloat {
            switch column {
            case .name: name
            case .label: label
            case .meter: meter
            case .percent: percent
            case .reset: reset
            case .text: text
            }
        }
    }

    /// What a width comes to. It is worked out once: the card is laid out every time a limit's pace moves.
    struct Measured {
        var proposed: CGFloat?
        var total: CGFloat
        var widths: Widths
        var heights: [CGFloat]
    }

    struct Cache {
        var measured: Measured?
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    private func measure(_ subviews: Subviews, within proposed: CGFloat?, cache: inout Cache) -> Measured {
        if let measured = cache.measured, measured.proposed == proposed { return measured }
        var name: CGFloat = 0, label: CGFloat = 0, percent: CGFloat = 0, reset: CGFloat = 0
        var lines = 0
        for subview in subviews {
            let place = subview[Place.self]
            lines = max(lines, place.line + 1)
            switch place.column {
            case .name: name = max(name, subview.sizeThatFits(.unspecified).width)
            case .label: label = max(label, subview.sizeThatFits(.unspecified).width)
            case .percent: percent = max(percent, subview.sizeThatFits(.unspecified).width)
            case .reset: reset = max(reset, subview.sizeThatFits(.unspecified).width)
            case .meter, .text: break
            }
        }
        let fixed = name + percent + reset + 4 * Self.columnGap
        let total = proposed.flatMap { $0.isFinite ? $0 : nil } ?? (fixed + label + Self.idealMeter)
        let room = max(0, min(label, total - fixed - Self.shortestMeter))
        let widths = Widths(name: name, label: room, meter: max(0, total - fixed - room), percent: percent, reset: reset, text: max(0, total - name - Self.columnGap))
        var heights = [CGFloat](repeating: 0, count: lines)
        for subview in subviews {
            let place = subview[Place.self]
            let height = subview.sizeThatFits(ProposedViewSize(width: widths.of(place.column), height: nil)).height
            heights[place.line] = max(heights[place.line], height)
        }
        let measured = Measured(proposed: proposed, total: total, widths: widths, heights: heights)
        cache.measured = measured
        return measured
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let measured = measure(subviews, within: proposal.width, cache: &cache)
        return CGSize(width: measured.total, height: measured.heights.reduce(0, +) + Self.lineGap * CGFloat(max(0, measured.heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let measured = measure(subviews, within: bounds.width, cache: &cache)
        let widths = measured.widths, heights = measured.heights
        var tops: [CGFloat] = []
        var top = bounds.minY
        for height in heights {
            tops.append(top)
            top += height + Self.lineGap
        }
        let hasText = Set(subviews.filter { $0[Place.self].column == .text }.map { $0[Place.self].line })
        let label = bounds.minX + widths.name + Self.columnGap
        let meter = label + widths.label + Self.columnGap
        let percentEnd = bounds.maxX - widths.reset - Self.columnGap
        for subview in subviews {
            let place = subview[Place.self]
            let top = tops[place.line], middle = top + heights[place.line] / 2
            let size = ProposedViewSize(width: widths.of(place.column), height: place.column == .meter ? nil : heights[place.line])
            switch place.column {
            case .name:
                // On a line of text that wraps, the name stays with its first line.
                let isAtTop = hasText.contains(place.line)
                subview.place(at: CGPoint(x: bounds.minX, y: isAtTop ? top : middle), anchor: isAtTop ? .topLeading : .leading, proposal: size)
            case .label:
                subview.place(at: CGPoint(x: label, y: middle), anchor: .leading, proposal: size)
            case .meter:
                subview.place(at: CGPoint(x: meter, y: middle), anchor: .leading, proposal: size)
            case .percent:
                subview.place(at: CGPoint(x: percentEnd, y: middle), anchor: .trailing, proposal: size)
            case .reset:
                subview.place(at: CGPoint(x: bounds.maxX, y: middle), anchor: .trailing, proposal: size)
            case .text:
                subview.place(at: CGPoint(x: label, y: top), anchor: .topLeading, proposal: size)
            }
        }
    }
}
