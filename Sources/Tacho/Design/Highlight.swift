import SwiftUI

/// The top of a page: one sentence on what changed, drawn on the person's own usual range.
struct Highlight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let sentence: String
    let series: UsualRangeSeries
    let chartLabel: String
    /// The figure beside the sentence, in the window. In the panel the figure goes in `value`, under the chart.
    var figure: String?
    /// The figure under the chart, such as "$98.74 so far".
    var value: String?
    /// What it is usually by now; nil until there is enough history to say.
    var usual: String?
    /// Something the figure leaves out.
    var note: String?
    /// The captions under the chart in the window: left, centre, right.
    var axis: [String]?
    var lineColor = Color.primary
    /// `Theme.Style.sentenceL` in the window.
    var sentenceStyle = Theme.Style.sentence
    /// 96 in the window.
    var chartHeight: CGFloat = 48
    /// Why the card reads as it does, when that is not plain from the card.
    var help: String?
    var open: (() -> Void)?

    var body: some View {
        if let help {
            card.help(help)
        } else {
            card
        }
    }

    private var card: some View {
        Card(action: open) {
            CardHeader(title, opens: open != nil)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(sentence)
                    .font(sentenceStyle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(sentence)
                    .transition(.opacity)
                if let figure {
                    Spacer(minLength: 0)
                    Text(figure)
                        .font(Theme.Style.figureL)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }
            .animation(Theme.motion(.easeOut(duration: 0.2), reduceMotion: reduceMotion), value: sentence)
            UsualRangeChart(series: series, label: chartLabel, lineColor: lineColor)
                .equatable()
                .frame(height: chartHeight)
            if let axis {
                HStack {
                    ForEach(axis.indices, id: \.self) { index in
                        if index > 0 { Spacer(minLength: 4) }
                        Text(axis[index])
                    }
                }
                .font(Theme.Style.caption)
                .foregroundStyle(.secondary)
            }
            if value != nil || usual != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let value {
                        Text(value)
                            .font(Theme.Style.small.weight(.semibold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    if let usual {
                        Text(usual)
                            .font(Theme.Style.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            if let note {
                Say(note, tone: .warning)
            }
        }
    }
}
