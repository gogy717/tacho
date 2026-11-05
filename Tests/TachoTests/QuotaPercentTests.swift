import Foundation
import Testing
@testable import Tacho
import TachoKit

@MainActor
struct QuotaPercentTests {
    private let now = Date(timeIntervalSince1970: 1_793_800_000)

    private func projection(_ provider: QuotaProvider = .openai, _ window: QuotaWindow = .fiveHour, percent: Double = 0, hasRecentData: Bool = false) -> Projection {
        let snapshot = QuotaSnapshot(provider: provider, window: window, scope: nil, usedPercent: percent, resetsAt: now.addingTimeInterval(-90_000), observedAt: now.addingTimeInterval(-200_000), origin: .claudeCache)
        return Projection(snapshot: snapshot, estimatedPercent: percent, isEstimate: true, method: .windowAverage, outcome: .unknown, isStale: true, resetsAt: snapshot.resetsAt, hasRecentData: hasRecentData)
    }

    private func dashboard(_ quotas: [Projection]) -> Dashboard {
        Dashboard(perMinute: 0, perSecond: 0, isIdle: true, lastMinute: .zero, series: [], sources: [], quotas: quotas, today: TodaySummary(tokens: .zero, cost: CostSummary(usd: 0, unpricedModels: [], unpricedTokens: 0), speeds: []), alert: .none, progress: IngestProgress(phase: .live, filesDone: 0, filesTotal: 0))
    }

    private func preferences(_ style: MenuBarStyle) -> Preferences {
        var preferences = Preferences.defaults(home: URL(fileURLWithPath: "/nowhere"))
        preferences.menuBarStyle = style
        return preferences
    }

    @Test func aHighFigureGoesTheSameWay() {
        // Old data at 73% is no truer than old data at 0%.
        #expect(Labels.percent(projection(percent: 73)) == nil)
    }

    @Test func thereIsNoPercentToShow() {
        #expect(Labels.percent(projection()) == nil)
    }

    @Test func theMenuBarShowsNoBareZero() {
        let title = MenuBarLabel.title(dashboard: dashboard([projection(.anthropic)]), preferences: preferences(.fiveHourPercent))
        #expect(title == nil)
    }

    @Test func theMenuBarKeepsARecentFigure() {
        let title = MenuBarLabel.title(dashboard: dashboard([projection(.anthropic, percent: 42, hasRecentData: true)]), preferences: preferences(.fiveHourPercent))
        #expect(title?.contains("42%") == true)
    }
}
