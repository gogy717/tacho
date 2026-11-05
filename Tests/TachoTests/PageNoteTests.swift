import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tacho
import TachoKit

/// The real pages in a real window, read through the note they publish: what a page says when a read fails, while it waits, and when
/// a chosen model has gone. State mapping is tested elsewhere; this is that the page reaches the view.
@MainActor @Suite(.serialized)
struct PageNoteTests {
    private struct ReadFailed: Error {}

    @MainActor private final class Seen {
        var note = PageNote.none
        var asked = false
    }

    /// Never reads any preference: every model here keeps to its sandbox, and nothing touches the test tool's shared defaults.
    private func model(_ sandbox: Sandbox) -> AppModel {
        AppModel(home: sandbox.home, defaults: sandbox.defaults) { _ in }
    }

    private func answered(_ sandbox: Sandbox) throws {
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
        }
    }

    private func show(_ view: some View, _ seen: Seen) -> NSWindow {
        let root = view
            .onPreferenceChange(PageNoteKey.self) { note in
                MainActor.assumeIsolated { seen.note = note }
            }
            .onPreferenceChange(ShownAskKey.self) { ask in
                MainActor.assumeIsolated { if ask != nil { seen.asked = true } }
            }
            .frame(width: 1040, height: 668)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        Tests.hide(window)
        return window
    }

    private func close(_ window: NSWindow) async {
        window.contentViewController = nil
        window.orderOut(nil)
        await Task.yield()
    }

    private func note(of view: some View, is expected: PageNote) async {
        let seen = Seen()
        let window = show(view, seen)
        #expect(await Tests.eventually { seen.note == expected }, "saw \(seen.note)")
        await close(window)
    }

    private func page(_ page: Page, model: AppModel, fails: Bool) -> AnyView {
        let read: DetailRead = { range in
            if fails { throw ReadFailed() }
            return WindowSamples.figures(range: range)
        }
        let speed: SpeedRead = { _, _ in
            if fails { throw ReadFailed() }
            return SpeedFigures(range: .week)
        }
        return switch page {
        case .cost: AnyView(RangePage(model: model, kind: .cost, read: read))
        case .tokens: AnyView(RangePage(model: model, kind: .tokens, read: read))
        case .cache: AnyView(CachePage(model: model, read: read))
        default: AnyView(SpeedPage(model: model, read: speed))
        }
    }

    // MARK: A failed read

    @Test(arguments: [Page.cost, .tokens, .cache, .speed])
    func aFailedReadShowsTheProblem(page: Page) async throws {
        let sandbox = try Sandbox(noEngine: true)
        await note(of: self.page(page, model: model(sandbox), fails: true), is: .problem)
    }

    @Test(arguments: [Page.cost, .tokens, .cache, .speed])
    func aGoodReadShowsNoNote(page: Page) async throws {
        let sandbox = try Sandbox(noEngine: true)
        let seen = Seen()
        let window = show(self.page(page, model: model(sandbox), fails: false), seen)
        // The first note is .none before the read, so wait until the page has drawn an answer, then for a poll that does not come.
        #expect(await Tests.eventually(within: .seconds(30)) { seen.asked })
        #expect(seen.note == .none)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(seen.note == .none)
        await close(window)
    }

    @Test func aFailedWeekReadOnSummaryShowsTheProblem() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.apply(WindowSamples.dashboard())
        await note(of: SummaryPage(model: model, read: { _ in throw ReadFailed() }), is: .problem)
    }

    @Test func aGoodWeekReadOnSummaryShowsNoNote() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.apply(WindowSamples.dashboard())
        let figures = WindowSamples.figures(range: .week)
        let seen = Seen()
        let window = show(SummaryPage(model: model, read: { _ in figures }), seen)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await Tests.eventually { seen.note == .none })
        await close(window)
    }

    // MARK: Before the first figures

    @Test(arguments: [Page.summary, .limits])
    func waitingForTheFirstFiguresIsNotAProblem(page: Page) async throws {
        let sandbox = try Sandbox()
        try answered(sandbox)
        let model = model(sandbox)
        #expect(!model.isFailing)
        #expect(model.dashboard == nil)
        let view = page == .summary ? AnyView(SummaryPage(model: model)) : AnyView(LimitsPage(model: model))
        await note(of: view, is: .waiting)
    }

    @Test(arguments: [Page.summary, .limits])
    func anEngineThatWouldNotOpenIsAProblem(page: Page) async throws {
        let sandbox = try Sandbox(noEngine: true)
        try answered(sandbox)
        let model = model(sandbox)
        #expect(model.isFailing)
        let view = page == .summary ? AnyView(SummaryPage(model: model)) : AnyView(LimitsPage(model: model))
        await note(of: view, is: .problem)
    }

    @Test func beforeTheChooserTheSetupNoteShows() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        #expect(Labels.setupNote(model) != nil)
        await note(of: SummaryPage(model: model), is: .problem)
    }

    // MARK: A chosen model gone from the range

    @Test func aChosenModelGoneFromTheRangeIsLetGoAndTheOthersFiguresRead() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.open(Route(page: .speed, model: "claude-haiku-5-5", range: .week))
        let opus = SpeedFigures.Model(speed: ModelSpeed(model: "claude-opus-5-5", tokensPerSecond: 71, samples: 300, approximate: true))
        var asked: [String?] = []
        let read: SpeedRead = { range, chosen in
            asked.append(chosen)
            return SpeedFigures(range: range, models: [opus])
        }
        let seen = Seen()
        let window = show(SpeedPage(model: model, read: read), seen)
        // Asked for the model that was chosen, found it gone, and asked again for none.
        #expect(await Tests.eventually { asked.first == "claude-haiku-5-5" && asked.contains(nil) })
        // Not left waiting for the next tick: a route sets `chosen` before the first read, so clearing it restarts nothing.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await Tests.eventually { seen.note == .none })
        await close(window)
    }

    @Test func aChosenModelStillInTheRangeIsKept() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.open(Route(page: .speed, model: "claude-opus-5-5", range: .week))
        let opus = SpeedFigures.Model(speed: ModelSpeed(model: "claude-opus-5-5", tokensPerSecond: 71, samples: 300, approximate: true))
        var asked: [String?] = []
        let read: SpeedRead = { range, chosen in
            asked.append(chosen)
            return SpeedFigures(range: range, models: [opus])
        }
        let window = show(SpeedPage(model: model, read: read), Seen())
        #expect(await Tests.eventually { !asked.isEmpty })
        try? await Task.sleep(for: .milliseconds(300))
        // Maybe twice, as `.task` can start before the route lands. Never for anything else.
        #expect(asked.allSatisfy { $0 == "claude-opus-5-5" })
        await close(window)
    }

    /// Answers as the engine does: `models` holds what each range has, and every read says which range it was.
    private func speedPage(_ model: AppModel, week: [String], day: [String], asked: @escaping (DetailRange, String?) -> Void) -> SpeedPage {
        let read: SpeedRead = { range, chosen in
            asked(range, chosen)
            let names = range == .day ? day : week
            return SpeedFigures(range: range, models: names.map {
                SpeedFigures.Model(speed: ModelSpeed(model: $0, tokensPerSecond: 71, samples: 300, approximate: true))
            })
        }
        return SpeedPage(model: model, read: read)
    }

    @Test func aCardsModelInTheWeekStaysOnTheWeek() async throws {
        // Used yesterday and not yet today: the morning's common case. Day would have nothing, or another model.
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.open(Route(page: .speed, model: "claude-opus-5-5"))
        var asked: [String] = []
        let page = speedPage(model, week: ["claude-opus-5-5"], day: ["claude-sonnet-5-5"]) { range, chosen in asked.append("\(range) \(chosen ?? "none")") }
        let window = show(page, Seen())
        #expect(await Tests.eventually { !asked.isEmpty })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(asked.allSatisfy { $0 == "week claude-opus-5-5" }, "\(asked)")
        await close(window)
    }

    @Test func aCardsModelNotInTheRangeIsLetGo() async throws {
        let sandbox = try Sandbox(noEngine: true)
        let model = model(sandbox)
        model.open(Route(page: .speed, model: "claude-gone-5-5"))
        var asked: [String] = []
        let page = speedPage(model, week: ["claude-opus-5-5"], day: ["claude-sonnet-5-5"]) { range, chosen in asked.append("\(range) \(chosen ?? "none")") }
        let seen = Seen()
        let window = show(page, seen)
        #expect(await Tests.eventually { asked.contains { $0.hasSuffix("none") } }, "\(asked)")
        #expect(await Tests.eventually { seen.note == .none })
        await close(window)
    }

    // MARK: The model cell

    private func event(model: String, agent: Bool, fast: Bool) -> UsageEvent {
        UsageEvent(source: .claudeCode, dedupKey: "k", isSubagent: agent, model: model, time: WindowSamples.now, speed: fast ? "fast" : nil, tokens: WindowSamples.tokens)
    }

    private func fit(_ cell: LogModelCell, width: CGFloat) -> NSSize {
        NSHostingController(rootView: cell).sizeThatFits(in: NSSize(width: width, height: 300))
    }

    @Test(arguments: [LogColumn.model.ideal, 90])
    func aLongModelIdCannotRunOverItsChips(width: CGFloat) {
        let long = "claude-sonnet-5-5-20261104-with-a-very-long-suffix"
        let size = fit(LogModelCell(event: event(model: long, agent: true, fast: true)), width: width)
        #expect(size.width <= width, "\(size)")
        // One line: a row has room for no more, and a second line would be cut off.
        #expect(size.height < 24, "\(size)")
    }

    @Test(arguments: ["claude-opus-5-5", "claude-sonnet-5-5-20261104", "claude-haiku-5-5-20261001"])
    func aRealIdBesideBothChipsStaysOnOneLineInItsColumn(model: String) {
        let size = fit(LogModelCell(event: event(model: model, agent: true, fast: true)), width: LogColumn.model.ideal)
        #expect(size.width <= LogColumn.model.ideal, "\(size)")
        #expect(size.height < 24, "\(size)")
    }

    @Test func aShortModelIdIsLeftWhole() {
        let size = fit(LogModelCell(event: event(model: "gpt-6.1-sol", agent: false, fast: false)), width: LogColumn.model.ideal)
        #expect(size.width < LogColumn.model.ideal)
    }
}
