import SwiftUI
import TachoKit

/// The panel the menu bar opens: the model's state, handed on as plain values.
struct PopoverView: View {
    let model: AppModel
    let open: (Route) -> Void
    let quit: () -> Void

    /// On screen. A closed panel reads nothing.
    @State private var isOpen = false

    var body: some View {
        PopoverPanel(
            state: model.dashboard.map { PanelState(dashboard: $0, preferences: model.preferences, insights: model.insights, now: model.refreshedAt) },
            isFailing: model.isFailing,
            setupNote: Labels.setupNote(model),
            notice: model.indexWasSetAside ? String(localized: "popover.indexSetAside", bundle: .tacho) : nil,
            now: model.refreshedAt,
            pick: { model.setRateMode($0) },
            open: open,
            quit: quit
        )
        .background(WindowWatcher { isOpen = $0 })
        .task(id: isOpen) {
            if isOpen { await model.whilePanelOpen() }
        }
    }
}

/// The panel itself: plain values in, so that every state draws and measures the same anywhere. Spec §6.
struct PopoverPanel: View {
    /// The content's cap, lower while the progress block shows, so that the whole panel stays within 720. Spec §6 says 632; measured
    /// through a real window that gives 722, so it is 630.
    private static let contentCap: CGFloat = 652
    private static let contentCapWithProgress: CGFloat = 630

    /// The content's own height, measured inside the scroll view.
    @State private var contentHeight: CGFloat = 0

    /// nil until the first figures arrive, and whenever they cannot be read.
    let state: PanelState?
    let isFailing: Bool
    /// Why there are no figures yet, while the first-launch question stands.
    var setupNote: String?
    /// Something about this launch that the figures alone would leave a stranger to guess.
    var notice: String?
    var now = Date()
    let pick: (RateMode) -> Void
    /// Opens the main window where a card points.
    let open: (Route) -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let state {
                // A scroll view's ideal height is next to nothing, and that is what a hosting window sizes itself by, so it is given
                // the height of what it holds: the panel fits its content up to the cap, and scrolls past it.
                ScrollView {
                    content(state)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(contentHeight, state.progress == nil ? Self.contentCap : Self.contentCapWithProgress))
                if let progress = state.progress {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(progress.text)
                            .font(Theme.Style.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Group {
                            if let fraction = progress.fraction {
                                ProgressView(value: fraction)
                            } else {
                                ProgressView()
                            }
                        }
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, Theme.Size.panelInset)
                }
            } else {
                emptyState
            }
            Divider()
            footer
        }
        .frame(width: Theme.Size.panelWidth)
    }

    private func content(_ state: PanelState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(rate: state.rate, now: now, pick: pick) { open(Route(page: .settings)) }
            Divider()
            VStack(spacing: Theme.Size.cardGap) {
                if let notice {
                    Say(notice)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Highlight(
                    title: state.today.title,
                    sentence: state.today.sentence,
                    series: state.today.series,
                    chartLabel: String(localized: "panel.usualChartLabel", bundle: .tacho),
                    value: state.today.value,
                    usual: state.today.usual,
                    note: state.today.note,
                    lineColor: state.today.isOutput ? Theme.output : .primary,
                    help: state.today.help,
                    open: { open(state.today.route) }
                )
                LimitsCard(limits: state.limits) { open(state.limits.route) }
                TileGrid(tiles: state.tiles, open: open)
            }
            .padding(EdgeInsets(top: 10, leading: Theme.Size.panelInset, bottom: 12, trailing: Theme.Size.panelInset))
        }
    }

    private var emptyState: some View {
        Text(setupNote ?? String(localized: isFailing ? "popover.unavailable" : "popover.waiting", bundle: .tacho))
            .font(Theme.Style.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Size.panelInset)
            .frame(maxWidth: .infinity, minHeight: 80)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button(String(localized: "footer.open", bundle: .tacho)) { open(Route(page: .summary)) }
                .buttonStyle(.link)
            Spacer()
            icon("gearshape", String(localized: "footer.settings", bundle: .tacho)) { open(Route(page: .settings)) }
            icon("power", String(localized: "footer.quit", bundle: .tacho), action: quit)
                .keyboardShortcut("q")
        }
        .padding(EdgeInsets(top: 8, leading: Theme.Size.panelInset, bottom: 8, trailing: 10))
    }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A section's heading.
struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
