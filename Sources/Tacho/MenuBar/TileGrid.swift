import SwiftUI

/// The pinned cards, two to a row, always in the same order so that each stays where it is remembered. Spec §4.6.
struct TileGrid: View {
    /// A say is one line, and the words at its end are the ones that say what a share is of, so it shrinks before it truncates.
    static let sayScale: CGFloat = 0.85

    let tiles: [PanelState.Tile]
    let open: (Route) -> Void

    private var rows: [[PanelState.Tile]] {
        stride(from: 0, to: tiles.count, by: 2).map { Array(tiles[$0..<min($0 + 2, tiles.count)]) }
    }

    var body: some View {
        VStack(spacing: Theme.Size.cardGap) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: Theme.Size.cardGap) {
                    ForEach(rows[index]) { tile($0) }
                    // An odd card leaves its neighbour's cell empty.
                    if rows[index].count == 1 {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
    }

    private func tile(_ tile: PanelState.Tile) -> some View {
        Card(size: .small, action: { open(tile.route) }) {
            CardHeader(tile.title)
            if tile.value == nil {
                // A sentence alone gets two lines, in the room its neighbour's figure and say take.
                figures(tile)
                    .hidden()
                    .overlay(alignment: .topLeading) {
                        Text(tile.say ?? "")
                            .font(Theme.Style.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
            } else {
                figures(tile)
            }
        }
    }

    private func figures(_ tile: PanelState.Tile) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                // The figure goes first, and the mark takes what is left: `命中率 100.0%` needs more than a full-width mark leaves.
                Text(tile.value ?? " ")
                    .font(Theme.Style.value)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                    .layoutPriority(-1)
                mark(tile.mark)
                    .frame(minWidth: 24, maxWidth: 52)
            }
            .frame(height: 20)
            // Always one full line, shrunk or not, so that the two cards of a row stay the same height.
            Text(verbatim: " ")
                .font(Theme.Style.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .overlay(alignment: .leading) {
                    Text(tile.say ?? " ")
                        .font(Theme.Style.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(Self.sayScale)
                        .truncationMode(.tail)
                }
        }
    }

    @ViewBuilder private func mark(_ mark: PanelState.Tile.Mark) -> some View {
        switch mark {
        case .none:
            EmptyView()
        case .needle(let value, let p25, let p75):
            NeedleMark(value: value, p25: p25, p75: p75)
        case .spark(let values):
            Sparkline(values: values, color: Theme.cacheRead)
                .frame(height: 20)
        case .shares(let shares):
            ShareBar(shares: shares)
        case .layers(let shares):
            ShareBar(shares: shares, inks: Theme.stackOrder.map(\.color))
        }
    }
}
