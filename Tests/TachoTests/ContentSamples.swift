import Foundation
import SwiftUI
@testable import Tacho
import TachoKit

/// Each page's figures, read from the engine and worded as the page words them, with every string its view draws, for `DrawnText`.
@MainActor
enum ContentSamples {
    struct Sample {
        var name: String
        var check: (CGFloat) async -> DrawnText.Report
    }

    private struct NoFigures: Error {}

    static func all(_ model: AppModel) async throws -> [Sample] {
        guard let engine = model.engine, let dashboard = model.dashboard else { throw NoFigures() }
        let now = Date()
        let insights = try await engine.insights(now: now)
        var samples: [Sample] = []

        for range in [DetailRange.day, .month, .year] {
            let state = RangeState(
                figures: try await engine.detail(range: range, now: now), kind: .cost, metric: .allTokens,
                rate: Labels.rate(dashboard, mode: .cost, unit: model.preferences.rateUnit), isReading: false, today: insights.results.today.rule
            )
            samples.append(Sample(name: "cost \(range)") { width in
                await DrawnText.check(state, strings: rangeStrings, width: width) { RangeContent(state: $0, about: RangePage.Kind.cost.about) }
            })
        }
        for grouping in DetailGrouping.allCases {
            let month = try await engine.detail(range: .month, grouping: grouping, now: now)
            for (kind, metric, name) in [(RangePage.Kind.cost, TokensMetric.allTokens, "cost"), (.tokens, .allTokens, "tokens"), (.tokens, .output, "output")] {
                let state = RangeState(figures: month, kind: kind, metric: metric, isReading: false, grouping: grouping, colours: LayerColours())
                samples.append(Sample(name: "\(name) by \(grouping)") { width in
                    await DrawnText.check(state, strings: rangeStrings, width: width) { RangeContent(state: $0, about: kind.about) }
                })
                // Each name alone, at the narrowest its column gets: in the page the marks are too faint to find in this grey and meet the axis's,
                // and beside another name two marks can run together.
                let layers = state.chart?.layers ?? []
                samples.append(Sample(name: "\(name) legend by \(grouping)") { _ in
                    var report = DrawnText.Report()
                    for layer in layers {
                        let one = await DrawnText.check([layer], strings: legendStrings, width: Theme.Size.mainColumn) { CategoryLegend(layers: $0).foregroundStyle(.primary) }
                        report.missing += one.missing
                        report.strays += one.strays
                    }
                    return report
                })
            }
        }
        let week = try await engine.detail(range: .week, now: now)
        for metric in [TokensMetric.allTokens, .output] {
            let state = RangeState(figures: week, kind: .tokens, metric: metric, isReading: false)
            samples.append(Sample(name: "tokens \(metric)") { width in
                await DrawnText.check(state, strings: rangeStrings, width: width) { RangeContent(state: $0, about: RangePage.Kind.tokens.about) }
            })
        }
        let cache = CacheState(figures: week)
        samples.append(Sample(name: "cache") { width in
            await DrawnText.check(cache, strings: cacheStrings, width: width) { CacheContent(state: $0) }
        })
        let speed = SpeedState(figures: try await engine.speed(range: .week, model: nil, now: now), chosen: nil, insight: insights.results.speed)
        samples.append(Sample(name: "speed") { width in
            await DrawnText.check(speed, strings: speedStrings, width: width) { SpeedContent(state: $0) }
        })

        let picked = insights.results.limits.limit ?? dashboard.quotas.first(where: \.hasRecentData)
        let scoped = dashboard.quotas.first { $0.snapshot.scope == LayoutSamples.scope }
        for (name, limit) in [("limits", picked), ("limits scoped", scoped)] {
            guard let limit else { continue }
            let record = LimitRecord(of: limit, history: try await engine.limitHistory(of: limit.snapshot, now: now))
            let state = LimitsState(dashboard: dashboard, insights: insights.results.limits, selected: LimitKey(limit.snapshot), record: record, now: now)
            samples.append(Sample(name: name) { width in
                await DrawnText.check(state, strings: limitsStrings, width: width) {
                    LimitsContent(state: $0, now: now, select: { _ in }, openSettings: {})
                }
            })
        }

        let history: LimitHistory? = if let picked { try await engine.limitHistory(of: picked.snapshot, now: now) } else { nil }
        let summary = SummaryState(
            dashboard: dashboard, insights: insights, day: try await engine.detail(range: .day, now: now), week: .ready(week), history: history,
            preferences: model.preferences, menuBarBlocked: false, now: now
        )
        samples.append(Sample(name: "summary") { width in
            await DrawnText.check(summary, strings: summaryStrings, width: width) {
                SummaryContent(state: $0, now: now, pick: { _ in }, open: { _ in }, edit: {})
            }
        })
        return samples
    }

    // MARK: What each view draws

    private static func visit(_ text: inout String?, _ visit: (inout String) -> Void) {
        guard var value = text else { return }
        visit(&value)
        text = value
    }

    private static func visit(_ stat: inout Stat, _ visit: (inout String) -> Void) {
        visit(&stat.label)
        visit(&stat.value)
        Self.visit(&stat.note, visit)
    }

    private static func visit(_ row: inout FigureRow, _ visit: (inout String) -> Void) {
        visit(&row.name)
        Self.visit(&row.note, visit)
        visit(&row.figure)
        for index in row.clients.indices { Self.visit(&row.clients[index], visit) }
    }

    static func legendStrings(_ layers: inout [ColumnSeries.Layer], _ visit: (inout String) -> Void) {
        for index in layers.indices { visit(&layers[index].name) }
    }

    static func rangeStrings(_ state: inout RangeState, _ visit: (inout String) -> Void) {
        for index in state.stats.indices { Self.visit(&state.stats[index], visit) }
        if var chart = state.chart {
            for index in chart.columns.indices { Self.visit(&chart.columns[index].axis, visit) }
            state.chart = chart
        }
        Self.visit(&state.note, visit)
        for index in state.highlights.indices { visit(&state.highlights[index]) }
        for index in state.byTypeLegend.indices { visit(&state.byTypeLegend[index].text) }
        for index in state.byTypeRows.indices { Self.visit(&state.byTypeRows[index], visit) }
        for index in state.bySource.indices { Self.visit(&state.bySource[index], visit) }
        // By model shows its top five.
        for index in state.byModel.indices.prefix(5) { Self.visit(&state.byModel[index], visit) }
    }

    static func cacheStrings(_ state: inout CacheState, _ visit: (inout String) -> Void) {
        for index in state.stats.indices { Self.visit(&state.stats[index], visit) }
        if var trend = state.trend {
            for index in trend.indices { Self.visit(&trend[index].axis, visit) }
            state.trend = trend
        }
        if var twoWays = state.twoWays {
            visit(&twoWays.tokensTotal)
            visit(&twoWays.costTotal)
            for index in twoWays.legend.indices { visit(&twoWays.legend[index].text) }
            state.twoWays = twoWays
        }
        for index in state.highlights.indices { visit(&state.highlights[index]) }
        for index in state.byCLI.indices { Self.visit(&state.byCLI[index], visit) }
    }

    static func speedStrings(_ state: inout SpeedState, _ visit: (inout String) -> Void) {
        for index in state.stats.indices { Self.visit(&state.stats[index], visit) }
        if var points = state.points, points.compactMap(\.tokensPerSecond).count >= 2 {
            for index in points.indices { Self.visit(&points[index].axis, visit) }
            state.points = points
        }
        for index in state.highlights.indices { visit(&state.highlights[index]) }
        for index in state.models.indices { Self.visit(&state.models[index], visit) }
    }

    static func limitsStrings(_ state: inout LimitsState, _ visit: (inout String) -> Void) {
        Self.visit(&state.message, visit)
        guard !state.rows.isEmpty else { return }
        for index in state.stats.indices { Self.visit(&state.stats[index], visit) }
        if state.runway != nil {
            for index in state.captions.indices { visit(&state.captions[index]) }
        }
        for index in state.highlights.indices { visit(&state.highlights[index]) }
        for index in state.how.indices {
            visit(&state.how[index].label)
            visit(&state.how[index].value)
        }
        for index in state.rows.indices {
            visit(&state.rows[index].name)
            if state.rows[index].message != nil {
                Self.visit(&state.rows[index].message, visit)
            } else {
                Self.visit(&state.rows[index].percent, visit)
            }
        }
        for index in state.noQuota.indices { Self.visit(&state.noQuota[index], visit) }
    }

    static func summaryStrings(_ state: inout SummaryState, _ visit: (inout String) -> Void) {
        if var progress = state.progress {
            visit(&progress.text)
            state.progress = progress
        }
        visit(&state.today.title)
        visit(&state.today.sentence)
        visit(&state.todayFigure)
        Self.visit(&state.today.note, visit)
        if var limit = state.limit {
            visit(&limit.name)
            Self.visit(&limit.age, visit)
            visit(&limit.sentence)
            visit(&limit.percent)
            visit(&limit.start)
            visit(&limit.middle)
            visit(&limit.end)
            state.limit = limit
        } else {
            Self.visit(&state.limitsSay, visit)
        }
        visit(&state.weekSentence)
        for index in state.cards.indices {
            visit(&state.cards[index].title)
            Self.visit(&state.cards[index].value, visit)
            if case .rows(var rows, let more) = state.cards[index].visual {
                for row in rows.indices {
                    visit(&rows[row].name)
                    visit(&rows[row].figure)
                }
                state.cards[index].visual = .rows(rows, more: more)
            }
            Self.visit(&state.cards[index].say, visit)
        }
    }
}
