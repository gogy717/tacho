import SwiftUI
import Testing
@testable import Tacho

/// What the headline hands SwiftUI, read off the view itself: a test process builds no accessibility tree, and no animation runs
/// in one. The joined `spoken` text appears nowhere in what is drawn, where the figure and the mode are two `Text`s.
@MainActor
struct HeadlineTests {
    /// Any `.animation(_:value:)`, whatever its value's type.
    private static let animation = "_AnimationModifier<"
    /// The one the header keeps: the chart and the figure swap on a change of mode.
    private static let modeAnimation = "_AnimationModifier<TachoKit.RateMode>"

    private func dumped(_ value: some Any) -> String {
        var text = ""
        dump(value, to: &text, maxDepth: 80, maxItems: 40_000)
        return text
    }

    private func rate(_ headline: PanelState.Rate.Headline) -> PanelState.Rate {
        var rate = PanelSamples.busy.rate
        rate.headline = headline
        return rate
    }

    private func figure(_ rate: PanelState.Rate) -> String {
        dumped(RateFigure(rate: rate, pick: { _ in }, openSettings: {}).body)
    }

    private func header(_ rate: PanelState.Rate) -> String {
        dumped(PanelHeader(rate: rate, now: Date(), pick: { _ in }, openSettings: {}).body)
    }

    @Test func voiceOverIsGivenTheFigureAndMode() {
        let rate = rate(.live(figure: "11.2k/min"))
        #expect(rate.spoken == "11.2k/min, Output")
        #expect(figure(rate).contains(rate.spoken))
    }

    @Test func voiceOverIsGivenTheIdleLine() {
        let rate = rate(.idle(lastSeen: "last request 38 min ago"))
        #expect(figure(rate).contains(rate.spoken))
    }

    // The rate can change on any tick. Animating the figure on its value kept a core busy for about 0.8 s after each change, in a
    // hosted window: 780 ms of CPU a second against 2 to 4. So nothing animates on the figure, in the figure or around it.

    /// So that the two below cannot pass by no longer finding anything.
    @Test func anAnimationIsThereToBeFound() {
        #expect(dumped(Text(verbatim: "x").animation(.default, value: "x")).contains(Self.animation))
    }

    @Test func nothingInTheFigureAnimates() {
        #expect(!figure(rate(.live(figure: "11.2k/min"))).contains(Self.animation))
    }

    @Test func theHeaderAnimatesOnTheModeAlone() {
        let text = header(rate(.live(figure: "11.2k/min")))
        #expect(text.contains(Self.modeAnimation))
        #expect(!text.replacingOccurrences(of: Self.modeAnimation, with: "").contains(Self.animation))
    }
}
