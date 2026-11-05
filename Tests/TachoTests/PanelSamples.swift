import Foundation
@testable import Tacho
import TachoKit

/// The panel's states, as the canvas draws them. Invented figures throughout.
enum PanelSamples {
    private static let shape: [Double] = [0, 0, 0, 0, 0, 0, 0, 0, 0.01, 0.02, 0.06, 0.14, 0.24, 0.34, 0.44, 0.58, 0.72, 0.84, 0.92, 0.97, 1, 1, 1, 1, 1]

    private static var day: UsualRangeSeries {
        UsualRangeSeries(
            band: shape.enumerated().map { .init(hour: Double($0.offset), low: $0.element * 58.6, high: $0.element * 120) },
            line: [(0, 0), (9, 0), (10, 2.1), (11, 8.5), (12, 19.7), (13, 32.7), (14, 42.1), (15, 65.6), (15.7, 98.74)].map { .init(hour: $0.0, value: $0.1) }
        )
    }

    private static var hour: [[Double]] {
        (0..<60).map { minute in
            let wave = abs(sin(Double(minute) / 3.5))
            return [wave * 80, wave * 20, wave * 8, wave * 2]
        }
    }

    private static var readings: [PanelState.Reading] {
        [
            .init(mode: .output, title: "Output · 11.2k/min"),
            .init(mode: .allTokens, title: "All tokens · 4.1M/min"),
            .init(mode: .cost, title: "Cost · $1.20/min"),
        ]
    }

    private static var limits: PanelState.Limits {
        PanelState.Limits(
            age: "updated 2 min ago",
            say: "Anthropic 5 hours: at this pace empty about 16:52, 1 h 25 min before the 18:17 reset.",
            tone: .warning,
            rows: [
                .init(name: "Anthropic", content: .cells([
                    .init(label: "5 h", percent: "≈ 64%", value: 0.64, pace: 0.48, level: .warning, caption: "18:17"),
                    .init(label: "Week", percent: "41%", value: 0.41, pace: 0.58, level: .normal, caption: "Sat 09:00"),
                    .init(label: "Fable", percent: "78%", value: 0.78, pace: 0.58, level: .normal, caption: "Sat 09:00"),
                ])),
                .init(name: "ChatGPT", content: .cells([
                    .init(label: "5 h", percent: "18%", value: 0.18, pace: 0.3, level: .normal, caption: "19:40"),
                    .init(label: "Week", percent: "9%", value: 0.09, pace: 0.22, level: .normal, caption: "Mon 08:10"),
                ])),
                .init(name: "xAI", content: .cells([
                    .init(label: "Week", percent: "≈ 33%", value: 0.33, pace: nil, level: .stale, caption: "7 d old"),
                ])),
            ]
        )
    }

    private static var tiles: [PanelState.Tile] {
        [
            .init(id: "output", title: "Output today", value: "1.81M", say: "above your usual", mark: .needle(value: 1.8, p25: 0.5, p75: 1.2), route: Route(page: .summary)),
            .init(id: "cache", title: "Cache", value: "97.8% hit", say: "≈ $864 kept off the bill", mark: .spark([94.2, 95.1, 96, 95.8, 96.9, 97.4, 97.8]), route: Route(page: .summary)),
            .init(id: "speed", title: "Speed", value: "≈ 71 tok/s", say: "Opus 5.5, usual speed", mark: .needle(value: 71, p25: 60, p75: 80), route: Route(page: .summary)),
            .init(id: "clis", title: "CLIs", value: "4", say: "Claude Code: 80%", mark: .shares([0.8, 0.12, 0.05, 0.03]), route: Route(page: .summary)),
        ]
    }

    static var busy: PanelState {
        PanelState(
            rate: .init(headline: .live(figure: "11.2k/min"), mode: .output, modeName: "Output", readings: readings, note: nil, series: hour.map { [$0[2]] }, layers: [.output]),
            today: .init(title: "Cost today", sentence: "30% above your usual by this time of day.", series: day, value: "$98.74 so far", usual: "usually about $76 by 15:42", note: nil),
            limits: limits,
            tiles: tiles,
            progress: nil
        )
    }

    static var allTokens: PanelState {
        var state = busy
        state.rate = .init(headline: .live(figure: "4.1M/min"), mode: .allTokens, modeName: "All tokens", readings: readings, note: nil, series: hour, layers: Theme.stackOrder)
        return state
    }

    static var idle: PanelState {
        var state = busy
        state.rate = .init(headline: .idle(lastSeen: "last request 38 min ago"), mode: .output, modeName: "Output", readings: readings, note: nil, series: hour.map { _ in [0] }, layers: [.output])
        state.today.sentence = "Inside your usual range for this time of day."
        state.limits.say = "Every limit is clear for now."
        state.limits.tone = .plain
        return state
    }

    static var noQuota: PanelState {
        var state = busy
        state.limits = .init(age: nil, say: "No quota data yet. Turn on the Claude quota query in Settings.", tone: .plain, rows: [
            .init(name: "ChatGPT", content: .message("No recent quota data · last figure 15 days ago")),
            .init(name: "xAI", content: .message("No recent quota data · last figure 15 days ago")),
        ])
        return state
    }

    static var unpriced: PanelState {
        var state = busy
        state.rate = .init(headline: .live(figure: "$1.20+/min"), mode: .cost, modeName: "Cost", readings: readings, note: "Excludes acme-coder-2: no price", series: hour, layers: Theme.stackOrder)
        state.today.value = "$98.74+ so far"
        state.today.note = "Not counted: acme-coder-2, 12.4M tokens. Add a price in Settings."
        return state
    }

    static var newInstall: PanelState {
        var state = busy
        state.rate = .init(headline: .reading, mode: .output, modeName: "Output", readings: readings, note: nil, series: hour.map { _ in [0] }, layers: [.output])
        state.today = .init(title: "Cost today", sentence: "Reading your logs. Today's figure is still rising.", series: UsualRangeSeries(line: [.init(hour: 0, value: 0), .init(hour: 9, value: 4.1)]), value: "$4.10 so far", usual: nil, note: nil)
        state.limits = .init(age: nil, say: "No quota data yet. Turn on the Claude quota query in Settings.", tone: .plain, rows: [])
        state.tiles = [
            .init(id: "output", title: "Output today", value: "41.8k", say: "needs 5 more days of use", mark: .none, route: Route(page: .summary)),
            .init(id: "cache", title: "Cache", value: "96.1% hit", say: "≈ $2.40 kept off the bill", mark: .none, route: Route(page: .summary)),
            .init(id: "speed", title: "Speed", value: "≈ 71 tok/s", say: "Opus 5.5", mark: .none, route: Route(page: .summary)),
            .init(id: "clis", title: "CLIs", value: "2", say: "Claude Code: 80%", mark: .none, route: Route(page: .summary)),
        ]
        state.progress = .init(text: "Reading recent logs: 212 of 704 files", fraction: 0.3)
        return state
    }
}
