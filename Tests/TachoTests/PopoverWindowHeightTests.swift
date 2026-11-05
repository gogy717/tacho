import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tacho
import TachoKit

/// The test that would have caught the empty popover. It hosts `PopoverPanel` the way the app does, in a real NSHostingController in a real
/// NSWindow, and asserts on the WINDOW's height. `fittingSize` cannot see the bug: on the broken code it reported 720 and 556 while the
/// window was 45. Offscreen rendering (ImageRenderer) cannot either.
@MainActor @Suite(.serialized)
struct PopoverWindowHeightTests {
    /// A sleep, not a nested run loop: the test is itself a main-queue job, so SwiftUI's updates only run if it lets go.
    private func windowSize(_ state: PanelState?) async -> NSSize {
        let controller = NSHostingController(rootView: PopoverPanel(state: state, isFailing: false, pick: { _ in }, open: { _ in }, quit: {}))
        let window = NSWindow(contentViewController: controller)
        Tests.hide(window)
        try? await Task.sleep(for: .milliseconds(600))
        defer { window.orderOut(nil) }
        return window.contentView?.frame.size ?? .zero
    }

    @Test func aBusyPanelFitsUnderTheCapWithNothingToScroll() async {
        let size = await windowSize(PanelSamples.busy)
        // Spec §6.1 aims for about 680 and caps the content at 652, plus the footer.
        #expect(size.height > 600)
        // Past the cap, a divider and the footer, the content scrolls.
        #expect(size.height < 695)
        #expect(size.width == 360)
    }

    /// The notice only ever shows after an index was set aside, and it may push a busy panel to scroll but not past the panel's limit.
    @Test func aNoticeKeepsThePanelWithinItsLimit() async {
        let controller = NSHostingController(rootView: PopoverPanel(
            state: PanelSamples.busy,
            isFailing: false,
            notice: "Tacho couldn't read its old index, so it's reading your logs again. The old file is kept.",
            pick: { _ in },
            open: { _ in },
            quit: {}
        ))
        let window = NSWindow(contentViewController: controller)
        Tests.hide(window)
        try? await Task.sleep(for: .milliseconds(600))
        defer { window.orderOut(nil) }
        let height = window.contentView?.frame.size.height ?? 0
        let plain = await windowSize(PanelSamples.busy).height
        #expect(height > plain)
        #expect(height <= 720)
    }

    @Test func theHeaderChartTakesTheHeightAskedOf() {
        func height(_ header: PanelHeader) -> CGFloat {
            NSHostingController(rootView: header.frame(width: 328)).view.fittingSize.height
        }
        let rate = PanelSamples.busy.rate
        let standard = height(PanelHeader(rate: rate, now: Date(), pick: { _ in }, openSettings: {}))
        let tall = height(PanelHeader(rate: rate, now: Date(), chartHeight: 44, pick: { _ in }, openSettings: {}))
        #expect(tall - standard == 10)
    }

    @Test func aSayLongEnoughToShrinkLeavesTheCardItsHeight() async {
        var short = PanelSamples.busy
        short.tiles = Array(short.tiles.prefix(2)).map { tile in
            var tile = tile
            tile.say = "Codex: 64% of cost"
            return tile
        }
        var long = short
        long.tiles = long.tiles.map { tile in
            var tile = tile
            tile.say = "Claude Code: 100% of tokens"
            return tile
        }
        let plain = await windowSize(short)
        let shrunk = await windowSize(long)
        #expect(shrunk.height == plain.height)
    }

    /// Section 4.5: one line, truncated. However many CLIs there are, the panel does not grow.
    @Test func aLongNoQuotaRowStaysOneLine() async {
        var short = PanelSamples.noQuota
        short.limits.rows.append(.init(name: "No quota", content: .line("OpenCode ≈ $0.20/h")))
        var long = PanelSamples.noQuota
        long.limits.rows.append(.init(name: "No quota", content: .line("OpenCode ≈ $0.20/h · pi ≈ $0.10/h · Grok Build ≈ $0.08/h · Copilot CLI ≈ $0.05/h · oh-my-pi ≈ $0.02/h")))
        let one = await windowSize(short)
        let many = await windowSize(long)
        #expect(many.height == one.height)
    }

    /// Its end is the age, so this one wraps, and the row above it is what is cut short.
    @Test func aNoRecentLineKeepsItsAge() async {
        var short = PanelSamples.noQuota
        short.limits.rows.append(.init(name: "xAI", content: .message("No recent data")))
        var long = PanelSamples.noQuota
        long.limits.rows.append(.init(name: "xAI", content: .message("No recent quota data · last figure 15 d ago, and then some more to be sure")))
        let one = await windowSize(short)
        let two = await windowSize(long)
        #expect(two.height > one.height)
    }

    /// The longest the CLIs card says, in both languages, against the room a card has inside its padding.
    @Test func theLongestShareFitsItsCard() {
        let padding = Theme.Size.smallCardPadding
        let room = (Theme.Size.panelWidth - 2 * Theme.Size.panelInset - Theme.Size.cardGap) / 2 - padding.leading - padding.trailing
        for say in ["Claude Code: 100% of tokens", "Copilot CLI 占 token 的 100%"] {
            let width = NSHostingController(rootView: Text(say).font(Theme.Style.caption).fixedSize()).view.fittingSize.width
            #expect(width * TileGrid.sayScale <= room)
        }
    }

    /// Both cards of the row, because a row is as tall as its taller card: one alone could be shorter and not show.
    @Test func aSentenceCardIsAsTallAsAFigureCard() async {
        var figures = PanelSamples.busy
        figures.tiles = Array(figures.tiles.prefix(2))
        var sentences = figures
        sentences.tiles = ["one", "two"].map {
            .init(id: $0, title: "When you work", value: nil, say: "Busiest: Mon, and 09:00 to 12:00", mark: .none, route: Route(page: .calendar))
        }
        let plain = await windowSize(figures)
        let worded = await windowSize(sentences)
        #expect(worded.height == plain.height)
    }

    @Test func theProgressLineStaysUnderTheCap() async {
        var state = PanelSamples.busy
        state.progress = .init(text: "Reading older logs: 212 of 704 files", fraction: 0.3)
        let size = await windowSize(state)
        #expect(size.height > 600)
        #expect(size.height <= 720)
    }

    @Test func theLegendOfAllTokensStaysUnderTheCap() async {
        let size = await windowSize(PanelSamples.allTokens)
        #expect(size.height > 500)
        #expect(size.height <= 720)
    }

    @Test func notesStayUnderTheCap() async {
        let size = await windowSize(PanelSamples.unpriced)
        #expect(size.height > 500)
        #expect(size.height <= 720)
    }

    @Test func aNewInstallFitsItsContent() async {
        let size = await windowSize(PanelSamples.newInstall)
        #expect(size.height > 300)
        #expect(size.height <= 720)
    }

    @Test func noQuotaIsShorterThanBusy() async {
        let busy = await windowSize(PanelSamples.busy)
        let noQuota = await windowSize(PanelSamples.noQuota)
        #expect(noQuota.height < busy.height)
        #expect(noQuota.height > 300)
    }

    @Test func theEmptyStateStaysSmall() async {
        let size = await windowSize(nil)
        #expect(size.height > 80)
        #expect(size.height < 300)
    }
}
