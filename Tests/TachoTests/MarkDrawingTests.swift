import AppKit
import SwiftUI
import Testing
@testable import Tacho

/// What the marks put on screen, in pixels: a frame cannot show this, since a mark can overflow it or ignore its figures.
@MainActor
struct MarkDrawingTests {
    private let width: CGFloat = 100
    private let margin: CGFloat = 20

    private func bitmap(_ mark: some View) async -> (image: NSBitmapImageRep, scale: CGFloat)? {
        let size = NSSize(width: width + 2 * margin, height: 60)
        let view = NSHostingView(rootView: mark.frame(width: width).padding(margin).frame(width: size.width, height: size.height).background(Color.white))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        Tests.hide(window)
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: image)
        return (image, CGFloat(image.pixelsWide) / size.width)
    }

    private func isInked(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return color.redComponent < 0.98 || color.greenComponent < 0.98 || color.blueComponent < 0.98
    }

    /// Points of colour in the column `x` points into the mark.
    private func drawn(_ mark: some View, atX x: CGFloat) async -> Int {
        guard let (image, scale) = await bitmap(mark) else { return -1 }
        let column = Int((margin + x) * scale)
        let rows = (0..<image.pixelsHigh).filter { isInked(image, column, $0) }
        return Int((CGFloat(rows.count) / scale).rounded())
    }

    /// Each stretch of colour along the middle row, left to right, in points.
    private func runs(_ mark: some View) async -> [CGFloat] {
        guard let (image, scale) = await bitmap(mark) else { return [] }
        var runs: [CGFloat] = []
        var length = 0
        for x in 0..<image.pixelsWide {
            if isInked(image, x, image.pixelsHigh / 2) {
                length += 1
            } else if length > 0 {
                runs.append(CGFloat(length) / scale)
                length = 0
            }
        }
        return runs
    }

    @Test func theBarIsFivePointsTall() async {
        #expect(await drawn(Meter(value: 1, level: .critical), atX: 20) == 5)
    }

    @Test func aTickDoesNotMakeTheBarTaller() async {
        #expect(await drawn(Meter(value: 1, tick: 0.5, level: .critical), atX: 20) == 5)
    }

    @Test func theTickStandsProudOfTheBar() async {
        #expect(await drawn(Meter(value: 1, tick: 0.5, level: .critical), atX: 49.5) == 9)
    }

    // A bar beside a sentence saying 50% must draw 50%.
    @Test func fourSharesKeepTheirTrueWidths() {
        let segments = ShareBar.segments(of: [0.5, 0.25, 0.15, 0.1], inks: ShareBar.fading)
        #expect(segments.map(\.fraction) == [0.5, 0.25, 0.15, 0.1])
        #expect(segments.map(\.ink) == ShareBar.fading + [Theme.well])
    }

    @Test func everythingPastTheInksIsOneSegment() throws {
        let segments = ShareBar.segments(of: [0.4, 0.3, 0.1, 0.1, 0.06, 0.04], inks: ShareBar.fading)
        try #require(segments.count == 4)
        #expect(abs(segments[0].fraction - 0.4) < 1e-9)
        #expect(abs(segments[3].fraction - 0.2) < 1e-9)
        #expect(segments[3].ink == Theme.well)
    }

    @Test func threeSharesHaveNoRest() {
        let segments = ShareBar.segments(of: [0.8, 0.15, 0.05], inks: ShareBar.fading)
        #expect(segments.map(\.ink) == ShareBar.fading)
    }

    @Test func aShareOfNothingDrawsNothing() {
        #expect(ShareBar.segments(of: [1, 0, 0], inks: ShareBar.fading).count == 1)
        #expect(ShareBar.segments(of: [0, 0], inks: ShareBar.fading).isEmpty)
        #expect(ShareBar.segments(of: [], inks: ShareBar.fading).isEmpty)
    }

    @Test func theTokensLayersAreAllDrawnInTheirOwnInk() {
        let inks = Theme.stackOrder.map(\.color)
        let segments = ShareBar.segments(of: [0.9, 0.05, 0.03, 0.02], inks: inks)
        #expect(segments.map(\.ink) == inks)
    }

    @Test func theBarDrawsThoseWidths() async {
        let drawn = await runs(ShareBar(shares: [0.5, 0.25, 0.15, 0.1]))
        // Three 2 pt gaps leave 94 of the 100.
        #expect(drawn.count == 4)
        for (run, fraction) in zip(drawn, [0.5, 0.25, 0.15, 0.1]) {
            #expect(abs(run - 94 * fraction) <= 1)
        }
    }
}
