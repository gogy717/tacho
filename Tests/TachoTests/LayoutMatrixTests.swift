import AppKit
import SwiftUI
import XCTest
@testable import Tacho
import TachoKit

/// The main window at every size, on every page: spec section 10. In the app's own window with its real toolbar, on the real engine over a
/// made-up store whose model id is as long as OpenRouter's.
///
/// XCTest, as `ReadmeScreenshots` is and for the same reason: only a launch argument sets a language, so `scripts/layout-matrix.sh` runs
/// the whole matrix in English and in Chinese, and it is the only way to: `swift test` skips it. It needs window focus, a quiet machine and
/// minutes, so it would hang or fail on a CI runner, and it took a quarter of an hour of a merge gate under load. With `TACHO_LAYOUT_SHEET`
/// naming a folder, it also draws every cell there, and a contact sheet of each page, to be read by eye: the checks prove only that nothing
/// is cut.
final class LayoutMatrixTests: XCTestCase {
    /// Shrinking after growing, as a person does: a page that can only grow passes a matrix that only grows.
    static let widths: [CGFloat] = [1240, 1600, 820, 1100, 900, 1000]
    static let heights: [CGFloat] = [560, 900]
    static let rangePages: [Page] = [.cost, .tokens, .cache, .speed]
    /// Every page, and the two with a chart that stacks once for each way it can.
    static let views: [(page: Page, grouping: DetailGrouping?)] = Page.allCases.map { ($0, nil) }
        + [Page.cost, .tokens].flatMap { page in DetailGrouping.allCases.map { (page, $0) } }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TACHO_LAYOUT_MATRIX"] != nil, "Run by scripts/layout-matrix.sh.")
    }

    /// The items SwiftUI and AppKit put in every toolbar.
    @MainActor private static func isSystem(_ item: NSToolbarItem) -> Bool {
        let id = item.itemIdentifier.rawValue
        return id.hasPrefix("com.apple.SwiftUI.navigationSplitView") || id.hasPrefix("com.apple.SwiftUI.splitViewSeparator")
            || item.itemIdentifier == .flexibleSpace || item.itemIdentifier == .space
    }

    private struct Opened {
        var sandbox: Sandbox
        var model: AppModel
        var delegate: AppDelegate
        var window: NSWindow
    }

    @MainActor private func open(on page: Page) async throws -> Opened {
        let sandbox = try Sandbox()
        let model = try await LayoutSamples.startedModel(sandbox)
        let delegate = AppDelegate.quiet(model)
        delegate.showMainWindow(Route(page: page))
        let window = try XCTUnwrap(delegate.mainWindow)
        window.appearance = NSAppearance(named: .aqua)
        await settle(window)
        return Opened(sandbox: sandbox, model: model, delegate: delegate, window: window)
    }

    // MARK: Looking at the window

    @MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for sub in view.subviews { found += views(type, in: sub) }
        return found
    }

    @MainActor private func frameView(_ window: NSWindow) -> NSView {
        window.contentView?.superview ?? window.contentView ?? NSView()
    }

    @MainActor private func splitView(_ window: NSWindow) -> NSSplitView? {
        views(NSSplitView.self, in: frameView(window)).first { $0.arrangedSubviews.count == 2 }
    }

    @MainActor private func isSidebarShown(_ window: NSWindow) -> Bool {
        guard let split = splitView(window), let sidebar = split.arrangedSubviews.first else { return false }
        return !split.isSubviewCollapsed(sidebar) && sidebar.frame.width > 1
    }

    /// The scroll views of the page itself, not of the sidebar.
    @MainActor private func pageClips(_ window: NSWindow) -> [NSClipView] {
        guard let split = splitView(window), let detail = split.arrangedSubviews.last else { return [] }
        return views(NSClipView.self, in: detail).filter { ($0.documentView?.frame.width ?? 0) > 100 }
    }

    /// What moves while a page settles: its frames, its scroll views' documents and the toolbar.
    @MainActor private func signature(_ window: NSWindow) -> String {
        let split = splitView(window)?.arrangedSubviews.map { NSStringFromRect($0.frame) }.joined() ?? ""
        let documents = pageClips(window).map { NSStringFromRect($0.documentView?.frame ?? .zero) }.joined()
        let items = window.toolbar?.items.map { $0.itemIdentifier.rawValue + NSStringFromRect($0.view?.frame ?? .zero) }.joined() ?? ""
        return split + documents + items
    }

    /// Until nothing has moved for a while: a page reads its figures, lays out, and the toolbar follows.
    @MainActor private func settle(_ window: NSWindow) async {
        try? await Task.sleep(for: .milliseconds(150))
        var last = signature(window)
        var steady = 0
        for _ in 0..<80 where steady < 4 {
            try? await Task.sleep(for: .milliseconds(40))
            let next = signature(window)
            steady = next == last ? steady + 1 : 0
            last = next
        }
    }

    /// Shows or hides the sidebar as a person does: by its toolbar button, or by View > Toggle Sidebar, Control-Command-S.
    ///
    /// A test's window cannot become key without taking the user's focus, so the action does not go out to the key window as it does in
    /// the app. The button's action goes with the button as its sender, which is how AppKit finds its window; the menu item's goes down
    /// the window's own responder chain, which is where the app sends it.
    /// - Returns: a problem, if it did not move.
    @MainActor private func setSidebar(shown: Bool, byKeyboard: Bool = false, _ window: NSWindow) async -> String? {
        guard isSidebarShown(window) != shown else { return nil }
        if byKeyboard {
            let menu = MainMenu.make(quitTarget: NSApp, quit: #selector(NSApplication.terminate(_:)))
            let item = menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.keyEquivalent == "s" && $0.keyEquivalentModifierMask == [.control, .command] }
            if let item, let action = item.action { _ = window.firstResponder?.tryToPerform(action, with: item) }
        } else {
            let button = window.toolbar?.items.first { $0.itemIdentifier.rawValue.hasPrefix("com.apple.SwiftUI.navigationSplitView.toggleSidebar") }
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: button)
        }
        // The animation runs slowly on a busy machine. Waiting on the state costs nothing when it is quick.
        let moved = await Tests.eventually(within: .seconds(30)) { self.isSidebarShown(window) == shown }
        await settle(window)
        return moved ? nil : "the sidebar did not \(shown ? "show" : "hide") \(byKeyboard ? "by Control-Command-S" : "by its button")"
    }

    // MARK: The checks

    /// Nothing of the window lies outside it: a page that cannot shrink pushes the whole split view out at both sides.
    @MainActor private func splitProblems(_ window: NSWindow) -> [String] {
        guard let split = splitView(window) else { return ["no split view"] }
        let width = window.contentView?.bounds.width ?? 0
        return split.arrangedSubviews.filter { !split.isSubviewCollapsed($0) }.compactMap { view in
            let frame = view.convert(view.bounds, to: nil)
            return frame.minX < -0.5 || frame.maxX > width + 0.5 ? "a column lies outside the window: \(NSStringFromRect(frame)) in \(Int(width))" : nil
        }
    }

    /// Summary's one control and nothing on any other page; nothing in the overflow; nothing overlapping.
    @MainActor private func toolbarProblems(_ window: NSWindow, page: Page) -> [String] {
        guard let toolbar = window.toolbar else { return ["no toolbar"] }
        var problems: [String] = []
        let visible = toolbar.visibleItems ?? []
        let own = toolbar.items.filter { !Self.isSystem($0) }
        if own.count > (page == .summary ? 1 : 0) { problems.append("\(own.count) controls in the toolbar") }
        for item in toolbar.items where item.view != nil && !item.itemIdentifier.rawValue.hasPrefix("com.apple.SwiftUI.splitViewSeparator") {
            if !visible.contains(item) { problems.append("\(Self.isSystem(item) ? "the sidebar button" : "a toolbar control") is in the overflow") }
        }
        let shown = visible.compactMap { item -> NSRect? in
            guard let view = item.view, view.window != nil else { return nil }
            let frame = view.convert(view.bounds, to: nil)
            return frame.width > 1 ? frame : nil
        }
        for (index, frame) in shown.enumerated() {
            for other in shown[(index + 1)...] where frame.intersection(other).width > 1 {
                problems.append("toolbar items overlap: \(NSStringFromRect(frame)) and \(NSStringFromRect(other))")
            }
        }
        let titleTexts = views(NSTextField.self, in: frameView(window)).filter { field in
            field.window != nil && !field.isHiddenOrHasHiddenAncestor && !field.stringValue.isEmpty
                && field.convert(field.bounds, to: nil).minY >= window.contentLayoutRect.maxY - 1
        }
        for field in titleTexts {
            let frame = field.convert(field.bounds, to: nil)
            for item in shown where frame.intersection(item).width > 1 {
                problems.append("'\(field.stringValue)' overlaps a toolbar item")
            }
        }
        return problems
    }

    /// One range control, in the page and not the title bar, with every point of it answering. In the title bar the user's app answered on less
    /// than it drew, about 20 pt short at each end, where offscreen every point answered: a title bar is what this test cannot see, and a page is not.
    @MainActor private func rangeProblems(_ window: NSWindow, page: Page) -> [String] {
        guard Self.rangePages.contains(page) else { return [] }
        var problems: [String] = []
        let ranges = views(NSSegmentedControl.self, in: frameView(window)).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.segmentCount == 4 }
        if ranges.count != 1 { problems.append("\(ranges.count) range controls") }
        for control in ranges {
            if control.convert(control.bounds, to: nil).maxY > window.contentLayoutRect.maxY + 0.5 { problems.append("the range control is in the title bar") }
            // The whole of each segment, a point at a time across and at three heights: in the user's app the left half of Day
            // did not answer, so a check at the centre is not enough.
            for (index, rect) in segments(control).enumerated() {
                let covered = stride(from: rect.minX + 1, to: rect.maxX - 1, by: 1).lazy.flatMap { x in
                    [rect.midY - 6, rect.midY, rect.midY + 6].lazy.map { NSPoint(x: x, y: $0) }
                }.compactMap { point -> String? in
                    let hit = frameView(window).hitTest(point)
                    return hit === control || (hit?.isDescendant(of: control) ?? false)
                        ? nil : "segment \(index) at x \(Int(point.x)) is covered by \(hit.map { String(describing: type(of: $0)) } ?? "nothing")"
                }.first
                if let covered { problems.append(covered) }
            }
        }
        return problems
    }

    /// Nothing drawn in the page's side margins, where content pushed sideways would go; the log's table no wider than its view.
    @MainActor private func overflowProblems(_ window: NSWindow, page: Page) -> [String] {
        var problems: [String] = []
        let sidebar = isSidebarShown(window) ? (splitView(window)?.arrangedSubviews.first.map { $0.convert($0.bounds, to: nil).maxX } ?? 0) : 0
        for clip in pageClips(window) {
            guard let document = clip.documentView else { continue }
            if let table = document as? NSTableView {
                if table.frame.width > clip.bounds.width + 0.5 { problems.append("the log is \(Int(table.frame.width)) wide in \(Int(clip.bounds.width))") }
                // Below its ideal width a column cuts what it was measured to hold: Time's widest older row, for one.
                for (column, kind) in zip(table.tableColumns, LogColumn.allCases) where !column.isHidden && column.width + 0.5 < kind.ideal {
                    problems.append("log column \(kind) shaved to \(Int(column.width))")
                }
                continue
            }
            // The table's header runs to the edge with the table: it has no page margin.
            if document is NSTableHeaderView { continue }
            let visible = clip.documentVisibleRect
            guard let image = document.bitmapImageRepForCachingDisplay(in: visible) else { continue }
            document.cacheDisplay(in: visible, to: image)
            let clipLeft = clip.convert(clip.bounds, to: nil).minX
            // The margins inside the page's inset: right of the content, and left of it beside the sidebar.
            let bands = [(visible.width - 14, visible.width - 3), (max(sidebar - clipLeft, 0) + 3, max(sidebar - clipLeft, 0) + 12)]
            for (from, to) in bands where from > 0 && to < visible.width {
                if let row = inkedRow(image, fromX: from, toX: to) {
                    problems.append("something is drawn in the page's margin at x \(Int(from))...\(Int(to)), y \(row)")
                }
            }
        }
        return problems
    }

    /// The first row with ink in the band, against that row's own background: text is never one colour all along a band.
    /// Type, Model and CLI, whole and inside the window, on the two pages that have them.
    @MainActor private func switchProblems(_ window: NSWindow, page: Page) -> [String] {
        guard page == .cost || page == .tokens else { return [] }
        guard let control = views(NSSegmentedControl.self, in: frameView(window)).first(where: { $0.segmentCount == 3 }) else { return ["no switch"] }
        let frame = control.convert(control.bounds, to: nil)
        var problems: [String] = []
        if frame.width < control.fittingSize.width - 1 { problems.append("the switch is cut, \(frame.width) of \(control.fittingSize.width)") }
        if !frameView(window).bounds.contains(frame) { problems.append("the switch is outside the window: \(frame)") }
        return problems
    }

    @MainActor private func inkedRow(_ image: NSBitmapImageRep, fromX: CGFloat, toX: CGFloat) -> Int? {
        guard let data = image.bitmapData, image.bitsPerSample == 8, !image.isPlanar else { return nil }
        let scale = CGFloat(image.pixelsWide) / image.size.width
        let left = Int(fromX * scale), right = Int(toX * scale)
        guard left < right, right < image.pixelsWide else { return nil }
        let step = image.bitsPerPixel / 8
        for y in 0..<image.pixelsHigh {
            let row = data + y * image.bytesPerRow
            let fill = row + left * step
            for x in left...right {
                let here = row + x * step
                let difference = (0..<step).reduce(0) { $0 + abs(Int(here[$1]) - Int(fill[$1])) }
                if difference > 40 { return Int(CGFloat(y) / scale) }
            }
        }
        return nil
    }

    /// A segmented control's segments, in window coordinates.
    @MainActor private func segments(_ control: NSSegmentedControl) -> [NSRect] {
        let bounds = control.convert(control.bounds, to: nil)
        if let children = control.accessibilityChildren(), children.count == control.segmentCount {
            let rects = children.compactMap { ($0 as? NSAccessibilityElementProtocol)?.accessibilityFrame() }.compactMap { control.window?.convertFromScreen($0) }
            if rects.count == control.segmentCount, rects.allSatisfy({ $0.width > 0 && bounds.insetBy(dx: -1, dy: -1).contains($0) }) { return rects }
        }
        let width = bounds.width / CGFloat(max(control.segmentCount, 1))
        return (0..<control.segmentCount).map { NSRect(x: bounds.minX + CGFloat($0) * width, y: bounds.minY, width: width, height: bounds.height) }
    }

    // MARK: The matrix

    @MainActor func testEveryPageFitsTheWindowAtEverySize() async throws {
        let opened = try await open(on: .summary)
        let window = opened.window
        defer { window.close() }
        let sheet = ContactSheet(environment: "TACHO_LAYOUT_SHEET")
        var failures: [String] = []
        for height in Self.heights {
            for sidebar in ["shown", "hidden"] {
                if let problem = await setSidebar(shown: sidebar == "shown", byKeyboard: sidebar == "hidden", window) {
                    failures.append("\(Int(height)): \(problem)")
                }
                // Each page sees the window grow and shrink while it shows, as a person resizes it.
                for (page, grouping) in Self.views {
                    opened.model.page = page
                    opened.model.chart.setGrouping(grouping, on: page)
                    for width in Self.widths {
                        window.setContentSize(NSSize(width: width, height: height))
                        await settle(window)
                        let cell = "\(page.rawValue)\(grouping.map { " by \($0)" } ?? "") \(Int(width))x\(Int(height)) sidebar \(sidebar)"
                        let problems = splitProblems(window) + toolbarProblems(window, page: page) + rangeProblems(window, page: page) + overflowProblems(window, page: page) + switchProblems(window, page: page)
                        failures += problems.map { "\(cell): \($0)" }
                        sheet?.add(window, page: page, variant: grouping?.rawValue, width: width, height: height, sidebar: sidebar)
                    }
                    opened.model.chart.setGrouping(nil, on: page)
                }
            }
            // Shut and opened again at each width, by the button and the keyboard in turn: the page must give the sidebar its room back.
            opened.model.page = .cost
            for (step, width) in Self.widths.enumerated() {
                window.setContentSize(NSSize(width: width, height: height))
                await settle(window)
                let size = "\(Int(width))x\(Int(height))"
                for shown in [false, true] {
                    if let problem = await setSidebar(shown: shown, byKeyboard: (step % 2 == 1) == shown, window) {
                        failures.append("\(size): \(problem)")
                    }
                }
                failures += splitProblems(window).map { "cost \(size) sidebar reopened: \($0)" }
            }
        }
        sheet?.finish()
        XCTAssert(failures.isEmpty, "\(failures.count) problems:\n" + failures.joined(separator: "\n"))
    }

    // MARK: Clicks on the range

    @MainActor private func rangeControl(_ window: NSWindow) -> NSSegmentedControl? {
        views(NSSegmentedControl.self, in: frameView(window)).first { $0.window != nil && $0.segmentCount == 4 && !$0.isHiddenOrHasHiddenAncestor }
    }

    @MainActor private func click(_ window: NSWindow, segment: Int) {
        guard let control = rangeControl(window) else { return }
        let rect = segments(control)[segment]
        let point = NSPoint(x: rect.midX, y: rect.midY)
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.08, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return }
        // The control tracks the press itself and takes the release from the queue.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    /// The toolbar's items and the range control as they stand, but for what is chosen.
    @MainActor private func toolbarState(_ window: NSWindow) -> String {
        let items = window.toolbar?.items.map(\.itemIdentifier.rawValue).joined(separator: ",") ?? "-"
        guard let control = rangeControl(window) else { return items + " no range" }
        return items + " \(ObjectIdentifier(control).hashValue) \(NSStringFromRect(control.convert(control.bounds, to: nil)))"
    }

    @MainActor func testARangeClickLandsAndNothingMoves() async throws {
        let opened = try await open(on: .cost)
        let window = opened.window
        defer { window.close() }
        var failures: [String] = []
        for (width, sidebar) in [(CGFloat(820), true), (1240, true), (820, false)] {
            window.setContentSize(NSSize(width: width, height: 720))
            if let problem = await setSidebar(shown: sidebar, window) { failures.append(problem) }
            var places: [Page: NSPoint] = [:]
            for page in Self.rangePages {
                opened.model.page = page
                await settle(window)
                let cell = "\(page.rawValue) at \(Int(width)), sidebar \(sidebar ? "shown" : "hidden")"
                guard let control = rangeControl(window) else {
                    failures.append("\(cell): no range control")
                    continue
                }
                let chosen = control.selectedSegment
                places[page] = control.convert(control.bounds, to: nil).origin
                // While the page reads the new range, nothing around it appears, goes or moves.
                let before = toolbarState(window)
                click(window, segment: (chosen + 1) % 4)
                var changes = Set<String>()
                for _ in 0..<120 {
                    try await Task.sleep(for: .milliseconds(5))
                    let now = toolbarState(window)
                    if now != before { changes.insert(now) }
                }
                if !changes.isEmpty { failures.append("\(cell): the range or the toolbar changed \(changes.count) way(s) during a range change") }
                await settle(window)
                // Day, chosen while the page is still reading another range.
                for delay in [10, 30, 60] {
                    click(window, segment: 2)
                    try await Task.sleep(for: .milliseconds(delay))
                    click(window, segment: 0)
                    await settle(window)
                    let landed = rangeControl(window)?.selectedSegment
                    if landed != 0 { failures.append("\(cell): Day clicked \(delay) ms after Month did not land (\(landed.map(String.init) ?? "none"))") }
                }
            }
            if Set(places.values.map(NSStringFromPoint)).count > 1 { failures.append("at \(Int(width)), sidebar \(sidebar): the range moves between pages: \(places)") }
        }
        XCTAssert(failures.isEmpty, "\(failures.count) problems:\n" + failures.joined(separator: "\n"))
    }

    // MARK: Every figure and label drawn whole

    /// Each page's figures from the engine, worded as the page words them, at every width the detail takes in the matrix.
    @MainActor func testEveryFigureAndLabelIsDrawnWhole() async throws {
        let opened = try await open(on: .cost)
        let window = opened.window
        defer { window.close() }
        let sidebar = splitView(window)?.arrangedSubviews.first.map { $0.convert($0.bounds, to: nil).maxX } ?? 208
        let widths = Self.widths.flatMap { [$0 - sidebar, $0] }.sorted()
        let pages = try await ContentSamples.all(opened.model)
        var failures: [String] = []
        for sample in pages {
            for width in widths {
                var report = await sample.check(width)
                // A drawing that changed with no mark to account for it proves nothing either way, so it is drawn again, once. Seen once
                // in many runs, on Summary.
                if report.strays != 0 { report = await sample.check(width) }
                if report.strays != 0 { failures.append("\(sample.name) at \(Int(width)): the drawing was not steady (\(report.strays))") }
                failures += report.missing.map { "\(sample.name) at \(Int(width)): \($0) is not drawn whole" }
            }
        }
        XCTAssert(failures.isEmpty, "\(failures.count) problems:\n" + failures.joined(separator: "\n"))
    }
}
