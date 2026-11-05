import SwiftUI

/// A read shorter than this draws nothing in its place. Kept off the view so the environment default stays nonisolated.
enum FigureTiming: Sendable {
    static let hold: Duration = .milliseconds(150)
}

private struct FigureHoldKey: EnvironmentKey {
    static let defaultValue: Duration = FigureTiming.hold
}

extension EnvironmentValues {
    /// How long a page waits before it draws a placeholder. A fast read never draws one. Tests shorten or lengthen it.
    var figureHold: Duration {
        get { self[FigureHoldKey.self] }
        set { self[FigureHoldKey.self] = newValue }
    }
}

/// The shape of a page, for a read that has already taken a moment. One sweep of light, and then it rests: a repeating
/// animation would keep redrawing for as long as the read hung, and an idle Tacho must not redraw (spec §9).
struct PagePlaceholder: View {
    enum Kind {
        /// Stat line, chart, and the cards beside them.
        case detail
        /// Filter row and lines of the log.
        case log
        /// The year grid and the hour grid.
        case calendar
    }

    /// A read shorter than this draws nothing in its place.
    static let hold: Duration = FigureTiming.hold

    /// Nil when Reduce Motion is on, so the shapes sit still.
    static func shimmer(reduceMotion: Bool) -> Animation? {
        Theme.motion(.easeInOut(duration: 0.8), reduceMotion: reduceMotion)
    }

    var kind: Kind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        content
            .overlay {
                if Self.shimmer(reduceMotion: reduceMotion) != nil {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.07), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: geometry.size.width * 0.55)
                        .offset(x: (phase - 0.4) * geometry.size.width)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "popover.waiting", bundle: .tacho))
            .onAppear {
                guard let animation = Self.shimmer(reduceMotion: reduceMotion) else { return }
                withAnimation(animation) { phase = 1.4 }
            }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .detail: detail
        case .log: log
        case .calendar: calendar
        }
    }

    private var detail: some View {
        // In a narrow window the page's cards go below its chart, out of first sight, so the shape leaves them out there.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Size.columnGap) {
                detailMain
                VStack(spacing: 8) {
                    block(height: 72)
                    block(height: 72)
                    block(height: 72)
                    block(height: 96)
                }
                .frame(width: 260)
            }
            detailMain
        }
        .padding(Theme.Size.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detailMain: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom, spacing: 28) {
                block(width: 132, height: 52)
                block(width: 88, height: 36)
                block(width: 88, height: 36)
            }
            block(height: 240)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 12) {
            block(height: 28)
            ForEach(0..<10, id: \.self) { _ in
                block(height: 18)
            }
        }
        .padding(Theme.Size.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var calendar: some View {
        VStack(alignment: .leading, spacing: 22) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 18), spacing: 4) {
                ForEach(0..<90, id: \.self) { _ in
                    block(height: 14)
                }
            }
            block(height: 160)
        }
        .padding(Theme.Size.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func block(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Theme.Size.noteRadius, style: .continuous)
            .fill(Theme.tile)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// Draws `PagePlaceholder` only after `figureHold`. A read that returns first removes this view, and the placeholder never appears.
struct HeldPlaceholder: View {
    var kind: PagePlaceholder.Kind

    @Environment(\.figureHold) private var hold
    @State private var shown = false

    var body: some View {
        Group {
            if shown {
                PagePlaceholder(kind: kind)
                    .preference(key: PageNoteKey.self, value: .waiting)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: hold) {
            shown = false
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            shown = true
        }
    }
}

/// A short fade when a page's answer is replaced by a different one. The view stays put, so a scroll position does too.
/// The first answer just appears. Spec §9: `.easeOut(duration: 0.2)`, and nothing of it when Reduce Motion is on.
struct FigureFade<Value: Equatable, Content: View>: View {
    var value: Value
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity: Double = 1
    @State private var shown: Value?

    var body: some View {
        content()
            .opacity(opacity)
            .onChange(of: value) { _, new in
                guard shown != nil, new != shown else {
                    shown = new
                    return
                }
                shown = new
                guard let animation = Theme.motion(.easeOut(duration: 0.2), reduceMotion: reduceMotion) else { return }
                opacity = 0.35
                withAnimation(animation) { opacity = 1 }
            }
            .onAppear { shown = value }
    }
}
