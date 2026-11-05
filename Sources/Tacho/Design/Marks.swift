import SwiftUI

/// How far through a limit, with a tick where even use would be by now: spec §3.2. Drawn, because a system progress bar greys out in a
/// window that is not key, and a warning must not.
struct Meter: View {
    enum Level: Equatable {
        case normal, warning, critical, stale

        var color: Color {
            switch self {
            case .normal: .accentColor
            case .warning: Theme.amberFill
            case .critical: Theme.redFill
            case .stale: .secondary
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Both as fractions.
    let value: Double
    var tick: Double?
    var level = Level.normal

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well)
                Capsule()
                    .fill(level.color)
                    .frame(width: geometry.size.width * min(1, max(0, value)))
            }
            // An overlay, so that the tick stands proud of the bar and does not set its height.
            .overlay(alignment: .leading) {
                if let tick {
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 1.5, height: 9)
                        .offset(x: (geometry.size.width - 1.5) * min(1, max(0, tick)))
                }
            }
        }
        .frame(height: Theme.Size.meterHeight)
        .animation(Theme.motion(.easeOut(duration: 0.25), reduceMotion: reduceMotion), value: value)
        .accessibilityHidden(true)
    }
}

/// A small trend with no axis: only its shape counts, and the figure beside it gives the number.
struct Sparkline: View {
    private struct Trace: Shape {
        let values: [Double]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            guard values.count > 1, let low = values.min(), let high = values.max() else { return path }
            let spread = high > low ? high - low : 1
            for (index, value) in values.enumerated() {
                let point = CGPoint(
                    x: rect.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: rect.height - 2 - CGFloat((value - low) / spread) * (rect.height - 4)
                )
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
    }

    let values: [Double]
    var color = Theme.output

    var body: some View {
        Trace(values: values)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            .accessibilityHidden(true)
    }
}

/// Who has how much: one row of fractions. By default the top three of something, largest first, in fading ink.
struct ShareBar: View {
    struct Segment: Equatable {
        var fraction: Double
        var ink: Color
    }

    static let fading = [0.7, 0.45, 0.25].map { Color.primary.opacity($0) }

    /// Fractions of the whole.
    let shares: [Double]
    /// One for each share drawn by itself.
    var inks = ShareBar.fading

    /// Every share at its true width, since a sentence beside the bar quotes them: any past the inks go into one muted segment, and
    /// are not left out, which would stretch the others. A share of nothing draws nothing, and leaves no gap.
    static func segments(of shares: [Double], inks: [Color]) -> [Segment] {
        let total = shares.reduce(0, +)
        guard total > 0 else { return [] }
        let rest = shares.dropFirst(inks.count).reduce(0, +)
        let named = zip(shares, inks).map { Segment(fraction: $0 / total, ink: $1) }
        return (named + [Segment(fraction: rest / total, ink: Theme.well)]).filter { $0.fraction > 0 }
    }

    var body: some View {
        GeometryReader { geometry in
            let segments = Self.segments(of: shares, inks: inks)
            let room = geometry.size.width - 2 * CGFloat(max(0, segments.count - 1))
            HStack(spacing: 2) {
                ForEach(segments.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(segments[index].ink)
                        .frame(width: room * segments[index].fraction)
                }
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}

/// A legend's colour, beside the name it belongs to.
struct Swatch: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: Theme.Size.swatch, height: Theme.Size.swatch)
            .accessibilityHidden(true)
    }
}

/// Whether anything is happening. The words go with the dot: colour alone says nothing to some.
struct LiveBadge: View {
    let isLive: Bool
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isLive ? Theme.live : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
        }
    }
}
