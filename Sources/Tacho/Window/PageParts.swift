import SwiftUI
import TachoKit

/// What a page shows in place of its figures. A preference, so that a test can read it from the real view tree: SwiftUI gives a test no
/// other way to see what a page drew.
enum PageNote: Equatable, Sendable {
    case none, waiting, problem
}

struct PageNoteKey: PreferenceKey {
    static let defaultValue = PageNote.none

    static func reduce(value: inout PageNote, nextValue: () -> PageNote) {
        let next = nextValue()
        if next != .none { value = next }
    }
}

/// Which answer a page is drawing. Nil while it has none: a test reads it, since nothing else in the view tree says.
struct ShownAsk: Equatable, Sendable {
    var page: Page
    var range: String
    /// A piece of the answer itself, so a test can tell two answers for one range apart.
    var marker: String
}

struct ShownAskKey: PreferenceKey {
    static let defaultValue: ShownAsk? = nil

    static func reduce(value: inout ShownAsk?, nextValue: () -> ShownAsk?) {
        if let next = nextValue() { value = next }
    }
}

/// Where a page's figures come from: the engine, unless a test says otherwise.
typealias DetailRead = @MainActor (DetailRange) async throws -> DetailFigures?
typealias SpeedRead = @MainActor (DetailRange, String?) async throws -> SpeedFigures?

extension AppModel {
    func detail(_ range: DetailRange, grouping: DetailGrouping? = nil, via read: DetailRead?) async throws -> DetailFigures? {
        if let read { return try await read(range) }
        return try await engine?.detail(range: range, grouping: grouping, now: Date())
    }

    func speed(_ range: DetailRange, model: String?, via read: SpeedRead?) async throws -> SpeedFigures? {
        if let read { return try await read(range, model) }
        return try await engine?.speed(range: range, model: model, now: Date())
    }
}

/// Figures are on their way.
struct WaitingNote: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preference(key: PageNoteKey.self, value: .waiting)
    }
}

/// What a page shows before its first figures: spec section 10. Waiting is not a failure.
struct NoFigures: View {
    let model: AppModel

    static func isProblem(isFailing: Bool, setupNote: String?) -> Bool {
        isFailing || setupNote != nil
    }

    var body: some View {
        if Self.isProblem(isFailing: model.isFailing, setupNote: Labels.setupNote(model)) {
            ProblemNote(model: model)
        } else {
            WaitingNote()
        }
    }
}

/// A page's scroll view and inset.
struct PageBody<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .padding(Theme.Size.pageInset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A page's own controls, above its figures rather than in the toolbar: the toolbar keeps one control on every page, so the range never
/// moves between pages. Outside what loads, so that nothing here appears, goes or moves while the figures are read.
struct PageControls<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Flow(spacing: 16, lineSpacing: 8) { content }
            .padding(EdgeInsets(top: 12, leading: Theme.Size.pageInset, bottom: 0, trailing: Theme.Size.pageInset))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Two columns by weight while each column holds its content, one above the other once either would not: spec section 10.
///
/// Decided at each layout from what the columns need now, never from a width measured before: the version before this pinned each column
/// to the last width it measured, so a page could grow but never shrink, and a smaller window cut it off at both sides.
struct TwoColumns<Left: View, Right: View>: View {
    /// The left column's width for each 1 of the right's.
    let weight: CGFloat
    /// The narrowest each is worth showing at beside the other, whatever its content could be squeezed to.
    var leftMinimum = Theme.Size.mainColumn
    var rightMinimum = Theme.Size.sideColumn
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        ColumnsLayout(weight: weight, minimums: [leftMinimum, rightMinimum], gap: Theme.Size.columnGap) {
            VStack(alignment: .leading, spacing: 0) { left }
            VStack(alignment: .leading, spacing: 0) { right }
        }
    }
}

/// `TwoColumns`' arithmetic: side by side when both fit their share, else stacked.
struct ColumnsLayout: Layout {
    var weight: CGFloat
    var minimums: [CGFloat]
    var gap: CGFloat

    /// What each column needs: its own narrowest, measured, or its minimum.
    private func needs(_ subviews: Subviews) -> [CGFloat] {
        subviews.indices.map { index in
            max(subviews[index].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width, minimums.indices.contains(index) ? minimums[index] : 0)
        }
    }

    /// The columns' widths side by side in `width`, or nil when either needs more than its share.
    func columns(in width: CGFloat, _ subviews: Subviews) -> (left: CGFloat, right: CGFloat)? {
        guard subviews.count == 2 else { return nil }
        let right = ((width - gap) / (weight + 1)).rounded(.down)
        let left = width - gap - right
        let needs = needs(subviews)
        return needs[0] <= left && needs[1] <= right ? (left, right) : nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width, width.isFinite else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            return CGSize(width: sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(max(sizes.count - 1, 0)), height: sizes.map(\.height).max() ?? 0)
        }
        // Asked for its narrowest: one above the other, as narrow as the widest column's content goes. The floors are for sitting side by
        // side, not for this.
        if width <= 0 {
            let narrowest = subviews.map { $0.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width }.max() ?? 0
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: narrowest, height: nil)).height }
            return CGSize(width: narrowest, height: heights.reduce(0, +) + gap * CGFloat(max(heights.count - 1, 0)))
        }
        if let columns = columns(in: width, subviews) {
            let left = subviews[0].sizeThatFits(ProposedViewSize(width: columns.left, height: nil)).height
            let right = subviews[1].sizeThatFits(ProposedViewSize(width: columns.right, height: nil)).height
            return CGSize(width: width, height: max(left, right))
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + gap * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if let columns = columns(in: bounds.width, subviews) {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: columns.left, height: nil))
            subviews[1].place(
                at: CGPoint(x: bounds.minX + columns.left + gap, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: columns.right, height: nil)
            )
            return
        }
        var y = bounds.minY
        let whole = ProposedViewSize(width: bounds.width, height: nil)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: whole)
            y += subview.sizeThatFits(whole).height + gap
        }
    }
}

/// Items along a line, onto the next when the line is full: what reflows as a window narrows. An item keeps its own width and is never
/// squeezed, unless it is wider than the whole line, when it gets the line to wrap in.
struct Flow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4
    /// Lines line up on their text's last baseline, so that figures of two sizes sit on one line.
    var baseline = false
    /// When everything fits on one line, the room left goes between the items: first at the start, last at the end.
    var spread = false

    private struct Line {
        var items: [Int] = []
        var width: CGFloat = 0
    }

    private func size(of subview: LayoutSubview, in width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return ideal.width <= width ? ideal : subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private func lines(_ sizes: [CGSize], in width: CGFloat) -> [Line] {
        var lines = [Line()]
        for (index, size) in sizes.enumerated() {
            let added = lines[lines.count - 1].items.isEmpty ? size.width : lines[lines.count - 1].width + spacing + size.width
            if added > width, !lines[lines.count - 1].items.isEmpty {
                lines.append(Line(items: [index], width: size.width))
            } else {
                lines[lines.count - 1].items.append(index)
                lines[lines.count - 1].width = added
            }
        }
        return lines
    }

    /// Each line's height, and where its items' baseline falls from its top.
    private func metrics(_ line: Line, _ subviews: Subviews, _ sizes: [CGSize]) -> (height: CGFloat, baseline: CGFloat) {
        guard baseline else { return (line.items.map { sizes[$0].height }.max() ?? 0, 0) }
        let dimensions = line.items.map { subviews[$0].dimensions(in: ProposedViewSize(sizes[$0])) }
        let above = dimensions.map { $0[VerticalAlignment.lastTextBaseline] }.max() ?? 0
        let below = dimensions.map { $0.height - $0[VerticalAlignment.lastTextBaseline] }.max() ?? 0
        return (above + below, above)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let sizes = subviews.map { size(of: $0, in: max(width, 0)) }
        let lines = lines(sizes, in: width)
        let height = lines.reduce(0) { $0 + metrics($1, subviews, sizes).height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { $0.isFinite && $0 > 0 && spread ? max($0, widest) : widest } ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { size(of: $0, in: bounds.width) }
        let lines = lines(sizes, in: bounds.width)
        var y = bounds.minY
        for line in lines {
            let (height, baselineOffset) = metrics(line, subviews, sizes)
            let extra = spread && lines.count == 1 && line.items.count > 1 ? (bounds.width - line.width) / CGFloat(line.items.count - 1) : 0
            var x = bounds.minX
            for index in line.items {
                let proposal = ProposedViewSize(sizes[index])
                let top = baseline ? y + baselineOffset - subviews[index].dimensions(in: proposal)[VerticalAlignment.lastTextBaseline] : y
                subviews[index].place(at: CGPoint(x: x, y: top), anchor: .topLeading, proposal: proposal)
                x += sizes[index].width + spacing + max(extra, 0)
            }
            y += height + lineSpacing
        }
    }
}

/// A figure with its name above it.
struct Stat: Equatable, Identifiable {
    var label: String
    var value: String
    var tone = Tone.plain
    /// What the figure needs said beside it, such as "may be out of date".
    var note: String?

    var id: String { label }
}

/// The figures across the top of a detail page: the first large, the rest less so. They go onto a second line rather than squeeze, and a
/// figure is never wrapped or cut.
struct StatRow: View {
    let stats: [Stat]

    var body: some View {
        if !stats.isEmpty {
            Flow(spacing: 28, lineSpacing: 10, baseline: true) {
                ForEach(stats.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stats[index].label)
                            .font(Theme.Style.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(stats[index].value)
                            .font(index == 0 ? Theme.Style.figureXL : Theme.Style.figureL)
                            .foregroundStyle(stats[index].tone == .plain ? AnyShapeStyle(.primary) : AnyShapeStyle(stats[index].tone.color))
                            .monospacedDigit()
                            .fixedSize()
                        if let note = stats[index].note {
                            Text(note)
                                .font(Theme.Style.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// A section's heading in the window.
struct PageHeading: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.Style.cardTitle)
            .foregroundStyle(.secondary)
    }
}

/// What a page found worth saying.
struct HighlightList: View {
    let sentences: [String]

    var body: some View {
        if !sentences.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                PageHeading(String(localized: "summary.highlights", bundle: .tacho))
                ForEach(sentences, id: \.self) { sentence in
                    Text(sentence)
                        .font(Theme.Style.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.Size.noteRadius, style: .continuous))
                }
            }
        }
    }
}

/// How a figure is made.
struct AboutBox: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PageHeading(String(localized: "detail.about", bundle: .tacho))
            Text(text)
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.Size.noteRadius, style: .continuous))
    }
}

/// Said in place of a chart when a range holds nothing.
struct EmptyRangeNote: View {
    var height: CGFloat

    var body: some View {
        Text(String(localized: "overview.empty", bundle: .tacho))
            .font(Theme.Style.small)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}

/// Parts of a whole, side by side: every part stays visible, however small.
struct SplitBar: View {
    struct Part: Equatable {
        var share: Double
        var color: Color
    }

    private static let gap: CGFloat = 2
    private static let smallest: CGFloat = 4

    let parts: [Part]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let room = geometry.size.width - Self.gap * CGFloat(max(parts.count - 1, 0)) - Self.smallest * CGFloat(parts.count)
            HStack(spacing: Self.gap) {
                ForEach(parts.indices, id: \.self) { index in
                    Rectangle()
                        .fill(parts[index].color)
                        .frame(width: Self.smallest + max(room, 0) * parts[index].share)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A colour and what it stands for.
struct SwatchLine: Equatable, Identifiable {
    var color: Color
    var text: String

    var id: String { text }
}

/// As many to a line as fit, so that a legend of four keeps to a narrow column and lies on one line in a wide one.
struct SwatchGrid: View {
    let lines: [SwatchLine]

    var body: some View {
        Flow(spacing: 12, lineSpacing: 3) {
            ForEach(lines) { line in
                HStack(spacing: 4) {
                    Swatch(color: line.color)
                    Text(line.text)
                        .monospacedDigit()
                }
                .fixedSize()
            }
        }
        .font(Theme.Style.caption)
        .foregroundStyle(.secondary)
    }
}

/// How one row stands against the largest of its list. Thinner than `Meter`, which says how full something is.
struct FractionBar: View {
    let fraction: Double
    var color = Color.secondary

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// A list row: a name, a figure, and a bar against the largest of its list, with its clients under it.
struct FigureRow: Equatable, Identifiable {
    var name: String
    var figure: String
    /// Against the largest row, 0 to 1. nil for no bar.
    var fraction: Double?
    /// Beside the name, smaller.
    var note: String?
    var clients: [FigureRow] = []

    var id: String { name }
}

struct FigureList: View {
    let title: String
    let rows: [FigureRow]
    /// By model opens on its top five; every other list is short by nature.
    var shown = Int.max
    var color = Color.secondary

    /// What the list holds as it stands.
    static func visible(_ rows: [FigureRow], shown: Int, isExpanded: Bool) -> [FigureRow] {
        isExpanded ? rows : Array(rows.prefix(shown))
    }

    @State private var isExpanded = false

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                PageHeading(title)
                ForEach(Self.visible(rows, shown: shown, isExpanded: isExpanded)) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        figures(row)
                            .font(Theme.Style.small)
                        if let fraction = row.fraction {
                            FractionBar(fraction: fraction, color: color)
                        }
                        ForEach(row.clients) { client in
                            figures(client)
                                .font(Theme.Style.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 12)
                        }
                    }
                }
                if rows.count > shown {
                    Button(isExpanded ? String(localized: "list.showFewer", bundle: .tacho) : String(format: String(localized: "list.showAll", bundle: .tacho), rows.count)) {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.link)
                    .font(Theme.Style.caption)
                }
            }
        }
    }

    /// The name wraps where the row is short of room, and the figure is never cut: a model's id can be longer than the column.
    private func figures(_ row: FigureRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(row.name)
                .fixedSize(horizontal: false, vertical: true)
            if let note = row.note {
                Text(note)
                    .font(Theme.Style.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Text(row.figure)
                .monospacedDigit()
                .fixedSize()
        }
    }
}
