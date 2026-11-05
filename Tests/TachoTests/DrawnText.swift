import AppKit
import SwiftUI
@testable import Tacho

/// Whether every string a view shows is drawn whole, told from the drawing, as lane beluga-2's check in TLC does: measuring a width and
/// comparing it with the room once gave a false pass. Made fast enough for a matrix of pages and widths.
///
/// A string is marked after its last character, and apart from that after its middle one, with U+0332, COMBINING LOW LINE, which has no
/// width (measured: +0.00 pt in SF and PingFang from 11 to 36 pt), so marking moves nothing on the page. Where that character is drawn the
/// mark shows as a short line under it; where it is cut off, truncated at the end or in the middle, or pushed out of the view, it does not.
/// Every mark is drawn at once to find where marks show, then once for each bit of their numbers, so that each line found is traced to
/// its string. Last and middle are found apart: in a short string the two would touch and read as one line.
@MainActor
enum DrawnText {
    static let mark = "\u{0332}"

    /// Every string of `Value` that its view draws, in a fixed order, handed over to be changed.
    typealias Strings<Value> = (inout Value, (inout String) -> Void) -> Void

    struct Report {
        /// The strings with a character that is not drawn, and which.
        var missing: [String] = []
        /// Lines that changed with no mark to account for them, or drawings that never settled: the check proves nothing.
        var strays = 0
        var checked = 0
    }

    private enum Place: String { case middle, last }

    /// A drawing, as bytes.
    private struct Pixels {
        var width: Int
        var height: Int
        var rowBytes: Int
        var bytes: [UInt8]

        @MainActor init?(_ view: NSView) {
            let size = view.bounds.size
            guard size.width >= 1, size.height >= 1, let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            rep.size = size
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.bitmapData else { return nil }
            width = rep.pixelsWide
            height = rep.pixelsHigh
            rowBytes = rep.bytesPerRow
            bytes = Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
        }

        func sameSize(_ other: Pixels) -> Bool {
            width == other.width && height == other.height && rowBytes == other.rowBytes
        }

        func same(as other: Pixels) -> Bool {
            sameSize(other) && bytes.withUnsafeBytes { mine in other.bytes.withUnsafeBytes { memcmp(mine.baseAddress, $0.baseAddress, bytes.count) == 0 } }
        }

        /// Whether row `y` from `x0` to `x1` differs from `other`'s, by more than the edge of a glyph would.
        func differs(from other: Pixels, row y: Int, from x0: Int = 0, to x1: Int? = nil) -> [Int] {
            let start = y * rowBytes + x0 * 4
            let end = y * rowBytes + ((x1 ?? (width - 1)) + 1) * 4
            let equal = bytes.withUnsafeBytes { mine in
                other.bytes.withUnsafeBytes { memcmp(mine.baseAddress! + start, $0.baseAddress! + start, end - start) == 0 }
            }
            guard !equal else { return [] }
            var changed: [Int] = []
            for x in x0...(x1 ?? (width - 1)) {
                let offset = y * rowBytes + x * 4
                for channel in 0..<3 where abs(Int(bytes[offset + channel]) - Int(other.bytes[offset + channel])) > 40 {
                    changed.append(x)
                    break
                }
            }
            return changed
        }
    }

    private struct Box {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
    }

    /// Checks `value` drawn by `content` at `width`.
    static func check<Value, Content: View>(
        _ value: Value,
        strings: Strings<Value>,
        width: CGFloat,
        @ViewBuilder content: @escaping (Value) -> Content
    ) async -> Report {
        var texts: [String] = []
        var copy = value
        strings(&copy) { texts.append($0) }
        // One character has no end apart from its start, so it cannot be told from the first mark.
        let checked = texts.indices.filter { texts[$0].trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 }
        var report = Report(checked: checked.count)
        guard !checked.isEmpty else { return report }
        let isChecked = Set(checked)

        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        Tests.hide(window)
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        /// The drawing once three in a row agree: a view can still be arriving after it first draws.
        func show(_ value: Value) async -> Pixels? {
            host.rootView = AnyView(
                content(value)
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.white)
                    .environment(\.colorScheme, .light)
                    .transaction { $0.disablesAnimations = true }
            )
            var last: Pixels?
            var agreeing = 0
            for _ in 0..<40 {
                host.layoutSubtreeIfNeeded()
                let fitting = host.fittingSize
                if abs(window.frame.height - fitting.height) > 0.5 {
                    window.setContentSize(NSSize(width: width, height: max(fitting.height, 1)))
                    host.layoutSubtreeIfNeeded()
                }
                let next = Pixels(host)
                if let next, let last, next.same(as: last) {
                    agreeing += 1
                    if agreeing == 2 { return next }
                } else {
                    agreeing = 0
                }
                last = next
                try? await Task.sleep(for: .milliseconds(8))
            }
            return nil
        }

        /// `value` with every checked string marked at its first character, and those chosen by their number also at `place`. The first
        /// mark is drawn in both drawings compared: a string with a mark is set a fraction of a point apart from one without, so marking it
        /// redraws all of it, and a truncated string would seem to change. Numbers count from 1, so that every number has a bit set.
        func marked(_ place: Place?, _ chosen: (Int) -> Bool) -> Value {
            var picked = Set<Int>()
            for (number, index) in zip(1..., checked) where chosen(number) { picked.insert(index) }
            var copy = value
            var index = 0
            strings(&copy) { text in
                defer { index += 1 }
                if isChecked.contains(index) { text = Self.marking(text, at: picked.contains(index) ? place : nil) }
            }
            return copy
        }

        guard let base = await show(marked(nil) { _ in false }) else {
            report.strays = -1
            return report
        }
        let numbers = Dictionary(uniqueKeysWithValues: zip(1..., checked).map { ($1, $0) })
        for place in [Place.last, .middle] {
            let numbered = Set(place == .middle ? checked.filter { texts[$0].count > 2 } : checked)
            guard !numbered.isEmpty else { continue }
            let isNumbered = { (number: Int) in numbered.contains(checked[number - 1]) }
            guard let all = await show(marked(place, isNumbered)), all.sameSize(base) else {
                report.strays = -1
                return report
            }
            let boxes = Self.lines(all, base)
            var codes = Array(repeating: 0, count: boxes.count)
            let bits = Int.bitWidth - checked.count.leadingZeroBitCount
            for bit in 0..<bits {
                guard let drawn = await show(marked(place) { $0 & (1 << bit) != 0 && isNumbered($0) }), drawn.sameSize(base) else {
                    report.strays = -1
                    return report
                }
                for (box, area) in boxes.enumerated() where Self.changes(drawn, base, in: area) { codes[box] |= 1 << bit }
            }
            var found = Set<Int>()
            for code in codes {
                if (1...checked.count).contains(code) { found.insert(code) } else { report.strays += 1 }
            }
            for index in checked where numbered.contains(index) && !found.contains(numbers[index] ?? 0) {
                report.missing.append("'\(texts[index])' (\(place.rawValue))")
            }
        }
        return report
    }

    /// `text` with a mark after its first character, and one more after its last or its middle.
    private static func marking(_ text: String, at place: Place?) -> String {
        var characters = Array(text).map(String.init)
        guard !characters.isEmpty else { return text }
        characters[0] += mark
        switch place {
        case .last: characters[characters.count - 1] += mark
        case .middle: characters[characters.count / 2] += mark
        case nil: break
        }
        return characters.joined()
    }

    /// The changed areas, each a mark: changed pixels within a few of each other are one.
    private static func lines(_ changed: Pixels, _ base: Pixels) -> [Box] {
        var pixels = Set<Int>()
        for y in 0..<base.height {
            for x in changed.differs(from: base, row: y) { pixels.insert(y * base.width + x) }
        }
        var boxes: [Box] = []
        var seen = Set<Int>()
        for start in pixels.sorted() where !seen.contains(start) {
            var box = Box(minX: start % base.width, minY: start / base.width, maxX: start % base.width, maxY: start / base.width)
            var stack = [start]
            seen.insert(start)
            while let here = stack.popLast() {
                let x = here % base.width, y = here / base.width
                box = Box(minX: min(box.minX, x), minY: min(box.minY, y), maxX: max(box.maxX, x), maxY: max(box.maxY, y))
                for dy in -2...2 {
                    for dx in -3...3 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < base.width, ny < base.height else { continue }
                        let next = ny * base.width + nx
                        if pixels.contains(next), seen.insert(next).inserted { stack.append(next) }
                    }
                }
            }
            boxes.append(box)
        }
        return boxes
    }

    private static func changes(_ drawn: Pixels, _ base: Pixels, in box: Box) -> Bool {
        (box.minY...box.maxY).contains { !drawn.differs(from: base, row: $0, from: box.minX, to: box.maxX).isEmpty }
    }
}
