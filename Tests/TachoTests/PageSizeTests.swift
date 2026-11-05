import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tacho
import TachoKit

/// Real windows, read by their own frames: `fittingSize` hid the empty popover, and offscreen rendering cannot see this either.
@MainActor @Suite(.serialized)
struct PageSizeTests {
    private func answered(_ sandbox: Sandbox) throws {
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
        }
    }

    /// A sleep, not a nested run loop: the test is itself a main-queue job, so SwiftUI's updates only run if it lets go.
    private func windowSize(_ view: some View) async -> NSSize {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        Tests.hide(window)
        try? await Task.sleep(for: .milliseconds(600))
        defer { window.orderOut(nil) }
        return window.contentView?.frame.size ?? .zero
    }

    private func columns(width: CGFloat, right: CGFloat? = nil) -> some View {
        TwoColumns(weight: 1.3) {
            Color.clear.frame(height: 100)
        } right: {
            Color.clear.frame(width: right, height: 100)
        }
        .frame(width: width)
    }

    @Test(.enabled("the screen must hold the whole window") { await Tests.screenHoldsTheWindow }, arguments: Page.allCases)
    func noPageChangesTheWindowsSize(page: Page) async throws {
        let sandbox = try Sandbox()
        try answered(sandbox)
        let delegate = AppDelegate.quiet(AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in })
        delegate.showMainWindow(Route(page: page))
        defer { delegate.mainWindow?.close() }
        let window = try #require(delegate.mainWindow)
        // Long enough for a page that would resize it to have laid out, and then the condition, not the clock.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await Tests.eventually { window.contentView?.frame.size == NSSize(width: 1240, height: 720) })
    }

    @Test(arguments: Page.allCases)
    func theWindowHoldsItsMinimumOnEveryPage(page: Page) async throws {
        let sandbox = try Sandbox()
        try answered(sandbox)
        let delegate = AppDelegate.quiet(AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in })
        delegate.showMainWindow(Route(page: page))
        defer { delegate.mainWindow?.close() }
        let window = try #require(delegate.mainWindow)
        // Asked for less than the minimum, as a drag would, the window stops at it.
        #expect(await Tests.eventually { window.contentMinSize.width == 820 })
        window.setContentSize(NSSize(width: 400, height: 300))
        #expect(await Tests.eventually {
            guard let size = window.contentView?.frame.size else { return false }
            return size.width == 820 && (556...564).contains(size.height)
        })
    }

    private func tables(in view: NSView) -> [NSTableView] {
        view.subviews.flatMap { subview -> [NSTableView] in
            if let table = subview as? NSTableView { return [table] }
            return tables(in: subview)
        }
    }

    /// The real `Table` at each width: adding constants up cannot see what AppKit does with a point too many, which is to shave the first
    /// two columns. The budget is measured, in a real app: in this test host the detail runs under a floating sidebar.
    @Test(arguments: [CGFloat(1039), 900, 612])
    func theRealTableGivesEveryColumnItShowsItsWidth(width: CGFloat) async throws {
        let event = UsageEvent(source: .claudeCode, dedupKey: "k", model: "claude-opus-5-5", time: WindowSamples.now, tokens: WindowSamples.tokens)
        let line = LogLine(row: LogRow(event: event, costUSD: 1, tokensPerSecond: 71, approximateSpeed: true))
        let controller = NSHostingController(rootView: LogTable(lines: [line]) {}.frame(width: width, height: 400))
        let window = NSWindow(contentViewController: controller)
        Tests.hide(window)
        defer {
            window.contentViewController = nil
            window.orderOut(nil)
        }
        let content = try #require(window.contentView)
        let shown = LogColumn.shown(in: width)
        #expect(await Tests.eventually { tables(in: content).first?.tableColumns.filter { !$0.isHidden }.count == shown.count })
        try? await Task.sleep(for: .milliseconds(300))
        let table = try #require(tables(in: content).first)
        for (column, kind) in zip(table.tableColumns, LogColumn.allCases) {
            #expect(column.isHidden == !shown.contains(kind), "\(kind)")
            if !column.isHidden { #expect(column.width >= kind.ideal, "\(kind): \(column.width)") }
        }
        let clip = try #require(table.enclosingScrollView?.contentView.bounds.width)
        #expect(table.frame.width <= clip, "\(table.frame.width) in \(clip): \(table.tableColumns.map { $0.isHidden ? "-" : "\(Int($0.width))" })")
    }

    @Test func columnsSitSideBySideWithRoom() async {
        #expect(await windowSize(columns(width: 1040)).height == 100)
    }

    /// Decided by what the columns hold, not by a width: a side column that needs more than its share stacks them in a wide window.
    @Test func aColumnThatNeedsMoreThanItsShareStacksThem() async {
        #expect(await windowSize(columns(width: 1040, right: 400)).height == 100)
        #expect(await windowSize(columns(width: 1040, right: 460)).height == 100 + 100 + Theme.Size.columnGap)
    }

    /// Laid out wide, then made narrow, as a window is: the columns must stack, not keep the width they had. The first version pinned each
    /// column to the last width it measured, so the root could not get narrower and a smaller window cut off both sides.
    @Test func columnsLaidOutWideStackWhenTheWindowNarrows() async {
        let controller = NSHostingController(rootView: TwoColumns(weight: 1.3) {
            Color.clear.frame(height: 100)
        } right: {
            Color.clear.frame(height: 100)
        })
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        Tests.hide(window)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 1040, height: 300))
        try? await Task.sleep(for: .milliseconds(300))
        window.setContentSize(NSSize(width: 620, height: 300))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(window.contentMinSize.width <= 620)
        #expect(window.contentView?.frame.width == 620)
        #expect(controller.sizeThatFits(in: NSSize(width: 620, height: 10_000)).height == 100 + 100 + Theme.Size.columnGap)
    }

    @Test func waitingIsNotAProblem() {
        #expect(!NoFigures.isProblem(isFailing: false, setupNote: nil))
        #expect(NoFigures.isProblem(isFailing: true, setupNote: nil))
        #expect(NoFigures.isProblem(isFailing: false, setupNote: "Choose the CLIs to read"))
    }

    /// The minimum follows the root view, so a page full of figures must add nothing to it: pages scroll.
    private func smallest(_ view: some View) async -> NSSize {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: controller)
        Tests.hide(window)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 620, height: 508))
        try? await Task.sleep(for: .milliseconds(300))
        _ = await Tests.eventually { window.contentView?.frame.size.width == 620 }
        return window.contentView?.frame.size ?? .zero
    }

    @Test func aFullSummaryAddsNothingToTheMinimum() async {
        let tokens = WindowSamples.tokens
        let quota = WindowSamples.projection(percent: 64, outcome: .runsOut(at: WindowSamples.now + 4_200, beforeReset: 5_100))
        let state = SummaryState(
            dashboard: WindowSamples.dashboard(quotas: [quota], sources: [WindowSamples.source(.codex, today: tokens, usd: 8)], today: tokens, usd: 98),
            insights: nil,
            day: nil,
            week: .ready(WindowSamples.figures(range: .week)),
            preferences: Preferences.defaults(home: URL(fileURLWithPath: "/nonexistent")),
            menuBarBlocked: true,
            now: WindowSamples.now
        )
        let view = SummaryContent(state: state, now: WindowSamples.now, pick: { _ in }, open: { _ in }, edit: {})
        #expect(await smallest(view).width <= 620)
    }

    @Test func aFullLimitsPageAddsNothingToTheMinimum() async {
        let quotas = [
            WindowSamples.projection(percent: 64, outcome: .runsOut(at: WindowSamples.now + 4_200, beforeReset: 5_100)),
            WindowSamples.projection(window: .weekly, percent: 41),
            WindowSamples.projection(provider: .openai, percent: 14, hasRecentData: false),
        ]
        let state = LimitsState(dashboard: WindowSamples.dashboard(quotas: quotas), insights: nil, selected: nil, record: nil, now: WindowSamples.now)
        let view = LimitsContent(state: state, now: WindowSamples.now, select: { _ in }, openSettings: {})
        #expect(await smallest(view).width <= 620)
    }

    /// A slow first read draws the page's shape in its place, and that shape must fit wherever the page would.
    @Test(arguments: [PagePlaceholder.Kind.detail, .log, .calendar])
    func aPlaceholderAddsNothingToTheMinimum(kind: PagePlaceholder.Kind) async {
        let size = await smallest(PagePlaceholder(kind: kind))
        #expect(size.width <= 620)
        #expect(size.height <= 508)
    }

    @Test func columnsStackBelowThatAtTheMinimumWindow() async {
        // At 820 the sidebar leaves about 620.
        #expect(await windowSize(columns(width: 620)).height == 100 + 100 + Theme.Size.columnGap)
    }

    @Test func theBlockedNoteStaysShortAtTheMinimumWidth() async {
        let size = await windowSize(MenuBarBlockedNote(quit: {}, openSystemSettings: {}).frame(width: 820))
        #expect(size.height > 40)
        #expect(size.height < 140)
    }
}
