import Foundation
import Testing
@testable import Tacho
import TachoKit

/// A card says where it goes in more words than a sidebar row can: spec section 10.
@MainActor @Suite(.serialized)
struct RouteTests {
    private func delegate(_ sandbox: Sandbox) throws -> AppDelegate {
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
        }
        return .quiet(AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in })
    }

    @Test func theSidebarListsThePagesInItsOrder() {
        #expect(Page.allCases == [.summary, .limits, .cost, .tokens, .cache, .speed, .activity, .calendar, .settings])
    }

    @Test func aRouteOpensItsPageAndWaitsForIt() throws {
        let sandbox = try Sandbox()
        let delegate = try delegate(sandbox)
        let route = Route(page: .tokens, metric: .output, range: .week)
        delegate.model.open(route)
        #expect(delegate.model.page == .tokens)
        #expect(delegate.model.pendingRoute == route)
    }

    /// In the real window: a route nothing takes would sit there and be applied by the next visit.
    @Test(arguments: [
        Route(page: .limits),
        Route(page: .limits, limit: LimitKey(WindowSamples.projection(percent: 40).snapshot)),
        Route(page: .cost, range: .day),
        Route(page: .tokens, metric: .output, range: .week),
        Route(page: .cache, range: .day),
        Route(page: .speed, model: "claude-opus-5-5"),
    ])
    func theRealPageTakesItsRoute(route: Route) async throws {
        let sandbox = try Sandbox()
        let delegate = try delegate(sandbox)
        defer { delegate.mainWindow?.close() }
        delegate.showMainWindow(route)
        #expect(delegate.model.page == route.page)
        #expect(await Tests.eventually { delegate.model.pendingRoute == nil })
    }

    @Test func aPageTakesItsRouteOnce() throws {
        let sandbox = try Sandbox()
        let delegate = try delegate(sandbox)
        let route = Route(page: .speed, model: "claude-opus-5-5")
        delegate.model.open(route)
        #expect(delegate.model.takeRoute(for: .speed) == route)
        #expect(delegate.model.takeRoute(for: .speed) == nil)
        #expect(delegate.model.pendingRoute == nil)
    }

    @Test func aRouteForAnotherPageStaysForIt() throws {
        let sandbox = try Sandbox()
        let delegate = try delegate(sandbox)
        delegate.model.open(Route(page: .cost, range: .day))
        #expect(delegate.model.takeRoute(for: .tokens) == nil)
        #expect(delegate.model.pendingRoute != nil)
    }

    @Test func aBarePageStillOpens() throws {
        let sandbox = try Sandbox()
        let delegate = try delegate(sandbox)
        defer { delegate.mainWindow?.close() }
        delegate.showMainWindow(Route(page: .settings))
        #expect(delegate.model.page == .settings)
        #expect(delegate.model.pendingRoute == nil)
    }

    @Test func aLimitIsNamedByItsProviderWindowAndScope() {
        let snapshot = QuotaSnapshot(provider: .anthropic, window: .weekly, scope: "Fable", usedPercent: 40, resetsAt: .now, observedAt: .now, origin: .claudeCache)
        #expect(LimitKey(snapshot) == LimitKey(provider: .anthropic, window: .weekly, scope: "Fable"))
    }
}
