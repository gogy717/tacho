import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Tacho
import TachoKit

/// A repeatable stream of made-up numbers, so that two runs tell the same story.
private struct Dice {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    /// 0 up to 1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func pick<Value>(_ weighted: [(Value, Double)]) -> Value {
        var left = unit() * weighted.reduce(0) { $0 + $1.1 }
        for (value, weight) in weighted {
            left -= weight
            if left <= 0 { return value }
        }
        return weighted[weighted.count - 1].0
    }
}

/// Someone who uses five CLIs on four invented projects. Every name is public or made up, and nothing here came from a log.
private struct DemoHistory {
    private struct Tool {
        var source: Source
        var provider: String
        var models: [(String, Double)]
        var share: Double
        var thinks: Bool
        /// How the source times a reply, for the Speed page.
        var timing: Timing
    }

    private enum Timing { case start, generation, none }

    private static let tools = [
        Tool(source: .claudeCode, provider: "anthropic", models: [("claude-opus-5-5", 5), ("claude-sonnet-5-5", 3), ("claude-haiku-5-5", 1)], share: 55, thinks: false, timing: .start),
        Tool(source: .codex, provider: "openai", models: [("gpt-6.1-sol", 3), ("gpt-5.3-codex", 2)], share: 24, thinks: true, timing: .none),
        Tool(source: .opencode, provider: "anthropic", models: [("claude-sonnet-5-5", 1)], share: 9, thinks: false, timing: .none),
        Tool(source: .grok, provider: "xai", models: [("grok-4.3", 1)], share: 7, thinks: true, timing: .none),
        Tool(source: .pi, provider: "anthropic", models: [("claude-haiku-5-5", 1)], share: 5, thinks: false, timing: .generation),
    ]
    private static let projects: [(String, Double)] = [
        ("/Users/demo/Code/demo-app", 5), ("/Users/demo/Code/notes-api", 3), ("/Users/demo/Code/pixel-garden", 2), ("/Users/demo/Code/weather-cli", 1),
    ]
    private static let historyDays = 200

    let now: Date
    let calendar: Calendar
    private var dice = Dice(seed: 717)
    private var count = 0

    init(now: Date, calendar: Calendar) {
        self.now = now
        self.calendar = calendar
    }

    private mutating func event(at time: Date, project: String, weight: Double, isLive: Bool = false) -> UsageEvent {
        // No Codex in the last half hour: a burst against a quiet week would forecast its week gone by tonight, true of the rule and silly to read.
        let tools = isLive && now.timeIntervalSince(time) < 1_900 ? Self.tools.filter { $0.source != .codex } : Self.tools
        let tool = dice.pick(tools.map { ($0, $0.share) })
        let model = dice.pick(tool.models)
        let output = Int(Double(dice.int(180...2_200)) * weight)
        let reasoning = tool.thinks ? output * dice.int(15...45) / 100 : 0
        let speed = (model.contains("haiku") ? 150.0 : model.contains("sonnet") ? 95 : 68) * (0.8 + dice.unit() * 0.4)
        let seconds = Double(output) / speed
        count += 1
        return UsageEvent(
            source: tool.source,
            client: "cli",
            dedupKey: "demo:\(count)",
            sessionId: "demo-session-\(count / 20)",
            project: project,
            // Not in the newest rows of the log, whose model column a tag would cut short.
            isSubagent: !isLive && tool.source == .claudeCode && dice.unit() < 0.18,
            provider: tool.provider,
            model: model,
            time: time,
            startTime: tool.timing == .start ? time.addingTimeInterval(-seconds - 1.2) : nil,
            generationMs: tool.timing == .generation ? seconds * 1_000 : nil,
            tokens: TokenCounts(
                input: dice.int(40...900),
                output: output,
                reasoning: reasoning,
                cacheRead: Int(Double(dice.int(24_000...150_000)) * weight),
                cacheWrite5m: Int(Double(dice.int(600...6_000)) * weight),
                cacheWrite1h: tool.source == .claudeCode && dice.unit() < 0.2 ? dice.int(500...4_000) : 0
            )
        )
    }

    /// A working day's sessions, up to `limit`.
    private mutating func day(_ start: Date, scale: Double, limit: Date) -> [UsageEvent] {
        var events: [UsageEvent] = []
        let hours: [(Int, Double)] = [(9, 3), (10, 5), (11, 5), (13, 3), (14, 5), (15, 5), (16, 4), (17, 2), (20, 1), (21, 1)]
        func session(from first: Date, requests: Int, dice: inout Dice, history: inout DemoHistory) {
            let project = dice.pick(Self.projects)
            var time = first
            for _ in 0..<requests {
                time.addTimeInterval(Double(dice.int(35...210)))
                if time < limit { events.append(history.event(at: time, project: project, weight: 0.7 + dice.unit() * 0.6)) }
            }
        }
        // Every working day starts before the time of this run, so that "usually about" has something to say at any hour.
        let opening = min(7, max(0, calendar.component(.hour, from: now) - 2))
        var rolls = dice
        session(from: start.addingTimeInterval(Double(opening) * 3_600 + Double(rolls.int(0...5_400))), requests: rolls.int(8...14), dice: &rolls, history: &self)
        for _ in 0..<max(1, Int((3.5 * scale).rounded())) {
            let hour = rolls.pick(hours)
            session(from: start.addingTimeInterval(Double(hour) * 3_600 + Double(rolls.int(0...3_000))), requests: rolls.int(9...24), dice: &rolls, history: &self)
        }
        dice = rolls
        return events
    }

    mutating func events() -> [UsageEvent] {
        var events: [UsageEvent] = []
        let today = calendar.startOfDay(for: now)
        for offset in (0...Self.historyDays).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let start = calendar.startOfDay(for: date)
            let isWeekend = calendar.isDateInWeekend(start)
            // A fortnight away, and the odd quiet day.
            if (70...80).contains(offset) || (isWeekend && dice.unit() < 0.6) || dice.unit() < 0.04 { continue }
            let trend = 0.75 + 0.5 * Double(Self.historyDays - offset) / Double(Self.historyDays)
            let scale = (isWeekend ? 0.4 : 1) * trend * (0.55 + dice.unit() * 0.95)
            // Today's sessions stop where the live stream starts, so that what is said of it holds at whatever hour this runs.
            events += day(start, scale: scale, limit: now.addingTimeInterval(-3_300))
        }
        // At work right now, whatever the hour: the rate and its last hour.
        var time = now.addingTimeInterval(-3_300)
        while time < now.addingTimeInterval(-20) {
            events.append(event(at: time, project: dice.pick(Array(Self.projects.prefix(2))), weight: 1, isLive: true))
            time.addTimeInterval(Double(dice.int(55...170)))
        }
        return events
    }

    /// Each limit's readings, with the windows before them, so that its record has peaks to speak of.
    mutating func snapshots() -> [QuotaSnapshot] {
        var snapshots: [QuotaSnapshot] = []
        func readings(_ provider: QuotaProvider, _ limit: QuotaWindow, _ origin: QuotaOrigin, resets: Date, peak: Double, step: TimeInterval) -> [QuotaSnapshot] {
            let opened = resets.addingTimeInterval(-limit.length)
            let end = min(now.addingTimeInterval(-60), resets)
            let span = end.timeIntervalSince(opened)
            guard span > 0 else { return [] }
            // The last at the end of the span, so that a current window's figure is fresh and a finished one reaches its peak. Curved, as use
            // that has picked up is: on a straight line the chart would rise at half the pace its forecast sentence goes by.
            return (Array(stride(from: step, to: span, by: step)) + [span]).map { elapsed in
                QuotaSnapshot(
                    provider: provider, window: limit, usedPercent: (peak * elapsed * elapsed / (span * span)).rounded(),
                    resetsAt: resets, observedAt: opened.addingTimeInterval(elapsed), origin: origin
                )
            }
        }
        let weekPeaks: [Double] = [58, 71, 64, 92, 66, 74, 100, 69]
        let weekResets = now.addingTimeInterval(3 * 86_400 + 4 * 3_600)
        for (index, peak) in weekPeaks.enumerated() {
            let resets = weekResets.addingTimeInterval(-Double(weekPeaks.count - index) * 7 * 86_400)
            snapshots += readings(.anthropic, .weekly, .claudeCache, resets: resets, peak: peak, step: 6 * 3_600)
        }
        snapshots += readings(.anthropic, .weekly, .claudeCache, resets: weekResets, peak: 55, step: 3_600)
        snapshots += readings(.anthropic, .fiveHour, .claudeCache, resets: now.addingTimeInterval(2.4 * 3_600), peak: 58, step: 600)
        snapshots += readings(.openai, .weekly, .codexLog, resets: now.addingTimeInterval(5 * 86_400), peak: 22, step: 3_600)
        snapshots += readings(.openai, .fiveHour, .codexLog, resets: now.addingTimeInterval(3.1 * 3_600), peak: 14, step: 600)
        return snapshots
    }
}

/// The README's screenshots: the app's own views on the real engine, over a store of made-up use. It reads no log, no key and no network.
///
/// `scripts/screenshots.sh` runs it once for each language, with `TACHO_SCREENSHOTS` naming the folder. A language is fixed for a process, as
/// it is for the app, and only a launch argument sets one, which `swift test` cannot pass. So this is XCTest, the one case in a Swift Testing
/// suite: `xcrun xctest` passes launch arguments. An in-process volatile domain was tried and changes nothing. Without the variable it is skipped.
final class ReadmeScreenshots: XCTestCase {
    private struct BlankPage: Error {
        var file: String
    }

    private struct NeverWentLive: Error {}

    /// A root the generator will not touch.
    struct OutsideTheSandbox: Error, Equatable {
        var path: String
    }

    /// Stands between the generator and any log: a real project name in a public README cannot be taken back. Seeding the sandbox's roots is not
    /// enough, since `Preferences` falls back to the real home when its roots fail to decode, so this looks at what the model really loaded,
    /// before anything is read. It allows only what resolves inside `sandbox`, which rules out the real home and every CLI's directory under it.
    static func refuseAnythingReal(_ roots: SourceRoots, sandbox: URL, realHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let inside = resolved(sandbox.path)
        let home = resolved(realHome.path)
        guard inside != home, !inside.hasPrefix(home + "/") else { throw OutsideTheSandbox(path: sandbox.path) }
        for path in roots.roots.values.joined() where !resolved(path).hasPrefix(inside + "/") {
            throw OutsideTheSandbox(path: path)
        }
    }

    /// The generator's only way to a running model, so that what `ScreenshotGuardTests` proves of this is what a render does. Building the model
    /// reads only the sandbox's own store and price overrides, and no log until `start`.
    @MainActor static func startedModel(_ sandbox: Sandbox, launch: @escaping @Sendable (Engine) async -> Void = { await $0.start() }) throws -> AppModel {
        let model = AppModel(home: sandbox.home, defaults: sandbox.defaults, launch: launch)
        try refuseAnythingReal(model.preferences.roots, sandbox: model.home)
        model.start()
        return model
    }

    /// `path` with `..` and every link followed, as far as it exists: a root's last part often does not, and `/var` is a link on this system.
    private static func resolved(_ path: String) -> String {
        var known = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while known.path != "/" {
            if let real = realpath(known.path, nil) {
                defer { free(real) }
                return ([String(cString: real)] + rest).joined(separator: "/")
            }
            rest.insert(known.lastPathComponent, at: 0)
            known.deleteLastPathComponent()
        }
        return "/" + rest.joined(separator: "/")
    }

    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let windowSize = NSSize(width: 1240, height: 720)
    private static let scale: CGFloat = 2
    /// What a page has to cover, or something failed to draw and the image must not stand.
    private static let leastInk = 0.02

    /// `view` at 2x whatever the screen, cropped to `area`.
    @MainActor private func image(of view: NSView, area: NSRect) throws -> NSBitmapImageRep {
        let bounds = view.bounds
        let image = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * Self.scale), pixelsHigh: Int(bounds.height * Self.scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        image.size = bounds.size
        view.cacheDisplay(in: bounds, to: image)
        let rect = CGRect(x: area.minX, y: bounds.height - area.maxY, width: area.width, height: area.height)
            .applying(CGAffineTransform(scaleX: Self.scale, y: Self.scale))
        return NSBitmapImageRep(cgImage: try XCTUnwrap(try XCTUnwrap(image.cgImage).cropping(to: rect)))
    }

    /// The share of a sample of `image` that is not near white.
    private func ink(_ image: NSBitmapImageRep) -> Double {
        var inked = 0
        var sampled = 0
        for y in stride(from: 0, to: image.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: image.pixelsWide, by: 7) {
                sampled += 1
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.9, color.alphaComponent > 0.5 { inked += 1 }
            }
        }
        return Double(inked) / Double(max(sampled, 1))
    }

    /// `image` on white with no alpha. The panel draws on a see-through material, and a README in a dark theme would show black behind its dark text.
    private func onWhite(_ image: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let source = try XCTUnwrap(image.cgImage)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(source.colorSpace), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let area = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.setFillColor(CGColor.white)
        context.fill(area)
        context.draw(source, in: area)
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }

    /// Throws rather than asserts: a blank page must not replace a good one.
    private func write(_ image: NSBitmapImageRep, to url: URL) throws {
        guard ink(image) > Self.leastInk else { throw BlankPage(file: url.lastPathComponent) }
        try XCTUnwrap(try onWhite(image).representation(using: .png, properties: [:])).write(to: url)
    }

    /// As the app builds it, but with no saved frame: that would go in the shared defaults of whatever runs the tests.
    @MainActor private func mainWindow(_ model: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = NSHostingController(rootView: MainWindow(model: model, quit: {}))
        controller.sizingOptions = [.minSize]
        controller.sceneBridgingOptions = .all
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(Self.windowSize)
        Tests.hide(window)
        return window
    }

    @MainActor private func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap(splitView).first
    }

    @MainActor func testRender() async throws {
        let path = ProcessInfo.processInfo.environment["TACHO_SCREENSHOTS"]
        try XCTSkipUnless(path != nil, "Rendered by scripts/screenshots.sh")
        let folder = Self.repository.appendingPathComponent(try XCTUnwrap(path), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let sandbox = try Sandbox()
        try sandbox.seed {
            $0.askedAboutSources = true
            $0.askedAboutAnthropicQuery = true
            $0.enabledSources = Set(Source.allCases)
        }
        let support = sandbox.home.appendingPathComponent("Library/Application Support/Tacho", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var history = DemoHistory(now: Date(), calendar: .current)
        let store = try EventStore(url: support.appendingPathComponent("tacho.sqlite"))
        try store.upsert(history.events())
        try store.record(history.snapshots())

        let model = try Self.startedModel(sandbox)
        guard await Tests.eventually(within: .seconds(60), { model.dashboard?.progress.phase == .live }) else { throw NeverWentLive() }

        let window = mainWindow(model)
        defer { window.close() }
        model.mainWindowVisible = true
        // Cost first: offscreen, a window that opens on Summary keeps an empty detail for good, and `write` would stop on it. Going to another
        // page at once does not. The sidebar is left out: macOS draws its glass in the window server, so offscreen it is blank.
        for (page, name, cut) in [(Page.cost, "cost", CGFloat(0)), (.summary, "summary", 0), (.activity, "activity", 20), (.calendar, "calendar", 0)] {
            model.page = page
            try await Task.sleep(for: .seconds(4))
            let frame = try XCTUnwrap(window.contentView?.superview)
            let sidebar = try XCTUnwrap(splitView(in: frame)?.arrangedSubviews.first).frame.width
            let area = NSRect(x: sidebar, y: cut, width: frame.bounds.width - sidebar, height: frame.bounds.height - cut)
            try write(try image(of: frame, area: area), to: folder.appendingPathComponent("\(name).png"))
        }

        await model.refreshInsights()
        let panel = NSWindow(contentViewController: NSHostingController(rootView: PopoverView(model: model, open: { _ in }, quit: {})))
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua)
        Tests.hide(panel)
        defer { panel.close() }
        try await Task.sleep(for: .seconds(2))
        let content = try XCTUnwrap(panel.contentView)
        try write(try image(of: content, area: content.bounds), to: folder.appendingPathComponent("panel.png"))
    }
}
