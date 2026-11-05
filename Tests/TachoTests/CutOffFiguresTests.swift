import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import Tacho

/// What a window of `CutOffFiguresTests` is showing.
@MainActor @Observable
final class CutOffShown<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

struct CutOffHost<Value, Content: View>: View {
    let shown: CutOffShown<Value>
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        content(shown.value).background(Color.white)
    }
}

/// Whether a figure can be read, told from the drawing. Measuring a width and comparing it with the room gave a false pass here: the sum
/// said a tile's figure fit, and the tile cut it off. So these look at pixels, for each way a figure is lost:
///
/// - **Its end cut off:** change the last character and draw again. If the picture does not change, that character was never drawn.
/// - **Pushed out:** nothing may be drawn in the card's side padding. A column that follows its text moves when the text changes, so the
///   first check cannot see this one.
/// - **Its start cut off, or shrunk:** blank the string, and the pixels that change are its ink, which must be as wide as the same text
///   drawn alone. The figures are aligned to the right, so what does not fit goes off to the left, where the first check never looks.
/// - **Overprinted:** the ink of two neighbours must not meet.
@MainActor @Suite(.serialized)
struct CutOffFiguresTests {
    private static let cardWidth = Theme.Size.panelWidth - 2 * Theme.Size.panelInset
    private static let padding = Theme.Size.cardPadding.leading

    // Drawing.

    /// Draws each of `values` in turn, in one real window.
    private func drawings<Value, Content: View>(
        of values: [Value],
        width: CGFloat,
        @ViewBuilder content: @escaping (Value) -> Content
    ) async -> [NSBitmapImageRep] {
        guard let first = values.first else { return [] }
        let shown = CutOffShown(first)
        let view = NSHostingView(rootView: CutOffHost(shown: shown, content: content).frame(width: width).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        // Off every screen. A card lights up under the pointer, whatever the window's alpha or `ignoresMouseEvents`, so a window the
        // pointer happens to cross draws differently from its twin.
        window.setFrameTopLeftPoint(NSPoint(x: -20000, y: -20000))
        Tests.hide(window)
        defer { window.orderOut(nil) }
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "the pointer can reach this window")

        func image() -> NSBitmapImageRep? {
            view.layoutSubtreeIfNeeded()
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: image)
            return image
        }

        /// A view can still be arriving after it first draws, and a picture taken then differs from everything: every string would
        /// seem to be drawn. So this waits for three drawings in a row to agree.
        func settled() async -> NSBitmapImageRep? {
            var last = image(), agreed = 0
            for _ in 0..<60 where agreed < 2 {
                try? await Task.sleep(for: .milliseconds(50))
                let next = image()
                agreed = isSame(next, last) ? agreed + 1 : 0
                last = next
            }
            #expect(agreed == 2, "the picture never settled, so a difference would mean nothing")
            return last
        }

        var images: [NSBitmapImageRep] = []
        for value in values {
            shown.value = value
            if let drawn = await settled() { images.append(drawn) }
        }
        #expect(images.count == values.count)
        return images
    }

    /// For each change, whether the picture differs from `base`'s.
    private func differs<Value, Content: View>(
        from base: Value,
        _ changes: [Value],
        width: CGFloat,
        sidePadding: CGFloat? = nil,
        @ViewBuilder content: @escaping (Value) -> Content
    ) async -> [Bool] {
        let images = await drawings(of: [base] + changes, width: width, content: content)
        guard let first = images.first else { return [] }
        if let sidePadding {
            #expect(!isDrawn(in: sidePadding, of: first), "something has been pushed into the card's side padding")
        }
        return images.dropFirst().map { !isSame($0, first) }
    }

    /// Whether anything but the card itself shows in its left or right padding. Each row is compared with itself: the card's fill is the
    /// same all along a row, and text is not. The rows of its rounded corners do not count.
    private func isDrawn(in padding: CGFloat, of image: NSBitmapImageRep) -> Bool {
        let scale = CGFloat(image.pixelsWide) / image.size.width
        let band = Int(padding * scale) - 2
        let middle = image.pixelsWide / 2
        func color(_ x: Int, _ y: Int) -> NSColor? { image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }
        // A window taller than its view leaves transparent rows, which read as black.
        func isCard(_ y: Int) -> Bool {
            guard let pixel = color(middle, y), pixel.alphaComponent > 0.5 else { return false }
            return pixel.redComponent < 0.995
        }
        let rows = (0..<image.pixelsHigh).filter(isCard)
        guard let top = rows.first, let bottom = rows.last else { return false }
        // A continuous corner curves for further than its radius.
        let corner = Int(Theme.Size.cardRadius * scale * 1.6)
        guard top + corner < bottom - corner else { return false }
        for y in (top + corner)..<(bottom - corner) {
            let edges = [Array(1..<band), Array((image.pixelsWide - band)..<(image.pixelsWide - 1))]
            for columns in edges {
                guard let fill = color(columns[columns.count / 2], y) else { continue }
                for x in columns {
                    guard let here = color(x, y) else { continue }
                    if abs(here.redComponent - fill.redComponent) + abs(here.greenComponent - fill.greenComponent) + abs(here.blueComponent - fill.blueComponent) > 0.03 { return true }
                }
            }
        }
        return false
    }

    /// The smallest box around every pixel that differs between two drawings, in points. Whole rows are compared first, and only the
    /// ends of a row that differs are walked: a walk over every pixel held the main actor, which every suite shares, for seconds.
    private func ink(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> CGRect? {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow, let x = a.bitmapData, let y = b.bitmapData else { return nil }
        let width = a.pixelsWide, stride = a.bitsPerPixel / 8
        var left = Int.max, right = -1, top = Int.max, bottom = -1
        for row in 0..<a.pixelsHigh {
            let here = x + row * a.bytesPerRow, there = y + row * a.bytesPerRow
            guard memcmp(here, there, width * stride) != 0 else { continue }
            var first = 0, last = width - 1
            while memcmp(here + first * stride, there + first * stride, stride) == 0 { first += 1 }
            while memcmp(here + last * stride, there + last * stride, stride) == 0 { last -= 1 }
            left = min(left, first)
            right = max(right, last)
            top = min(top, row)
            bottom = max(bottom, row)
        }
        guard right >= 0 else { return nil }
        let scale = CGFloat(width) / a.size.width
        return CGRect(x: CGFloat(left) / scale, y: CGFloat(top) / scale, width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    /// Byte for byte, with nothing encoded on the way.
    private func isSame(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Bool {
        guard let a, let b, a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow, let x = a.bitmapData, let y = b.bitmapData else { return false }
        return memcmp(x, y, a.bytesPerRow * a.pixelsHigh) == 0
    }

    /// How wide `text` comes out with nothing in its way.
    private func inkAlone(_ text: String, _ font: Font) async -> CGFloat {
        let images = await drawings(of: [" ", text], width: 300) { value in
            Text(verbatim: value).font(font).fixedSize().frame(width: 300, alignment: .leading)
        }
        guard images.count == 2 else { return 0 }
        return ink(images[0], images[1])?.width ?? 0
    }

    private func changedEnd(_ text: String) -> String {
        String(text.dropLast()) + (text.last == "X" ? "Y" : "X")
    }

    /// The last digit, for another. Digits here are all one width, which matters: this line may shrink to fit, so a change of width
    /// alone would redraw all of it, and a figure cut off before that digit would still seem drawn.
    private func changedDigit(_ text: String) -> String {
        guard let index = text.lastIndex(where: \.isNumber) else { return text }
        return text.replacingCharacters(in: index...index, with: text[index] == "7" ? "4" : "7")
    }

    // Each check, shown to fire.

    @Test func itCatchesATextThatIsCutOff() async {
        let results = await differs(from: "≈ 100%", ["≈ 100X"], width: 30) { text in
            Text(verbatim: text).font(Theme.Style.small).lineLimit(1).frame(width: 30, alignment: .leading)
        }
        #expect(results == [false])
    }

    @Test func itPassesATextThatFits() async {
        let results = await differs(from: "≈ 100%", ["≈ 100X"], width: 200) { text in
            Text(verbatim: text).font(Theme.Style.small).lineLimit(1).frame(width: 200, alignment: .leading)
        }
        #expect(results == [true])
    }

    /// A line that shrinks seems to change at its end even when that end is cut off.
    @Test func aDigitCatchesWhatAShrinkingLineHides() async {
        let results = await differs(from: "命中率 98.3%", [changedDigit("命中率 98.3%")], width: 60) { value in
            Text(verbatim: value).font(Theme.Style.value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: 60, alignment: .leading)
        }
        #expect(results == [false])
    }

    /// Tall enough to have rows clear of the card's corners.
    private func padded(_ text: String) -> some View {
        Card {
            ForEach(0..<8, id: \.self) { _ in
                Text(verbatim: text).fixedSize()
            }
        }
        .frame(width: 200)
    }

    @Test func itPassesTextInsideACard() async {
        _ = await differs(from: "short", [], width: 200, sidePadding: Self.padding) { padded($0) }
    }

    @Test func itFindsTextPushedOutOfACard() async {
        let text = String(repeating: "pushed out of the card ", count: 4)
        await withKnownIssue("the check must fire on text that runs past the padding") {
            _ = await differs(from: text, [], width: 200, sidePadding: Self.padding) { padded($0) }
        }
    }

    /// `00%`: the end is drawn, and the start is gone.
    @Test func inkFindsAFigureThatLostItsStart() async {
        let font = Theme.Style.small.weight(.medium)
        let images = await drawings(of: [" ", "≈ 100%"], width: 100) { value in
            Text(verbatim: value).font(font).monospacedDigit().fixedSize().frame(width: 26, alignment: .trailing).clipped().frame(width: 100, alignment: .leading)
        }
        let alone = await inkAlone("≈ 100%", font.monospacedDigit())
        #expect(images.count == 2)
        #expect(alone > 30)
        #expect((ink(images[0], images[1])?.width ?? 0) < alone - 5)
    }

    // The worst cases.

    struct Case: Sendable, CustomTestStringConvertible {
        var locale: String
        var language: String

        var testDescription: String { locale }
    }

    nonisolated static let cases = [
        Case(locale: "en_US", language: "en"),
        Case(locale: "en_AU", language: "en"),
        Case(locale: "en_MX", language: "en"),
        Case(locale: "en_IN", language: "en"),
        Case(locale: "zh-Hans-AU", language: "zh-Hans"),
    ]

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Tacho/Resources")

    private func string(_ key: String, _ language: String) throws -> String {
        let data = try Data(contentsOf: Self.sources.appendingPathComponent("\(language).lproj/Localizable.strings"))
        let list = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        return try #require(list?[key])
    }

    private func width(_ text: String) -> CGFloat {
        NSHostingController(rootView: Text(verbatim: text).font(Theme.Style.caption).fixedSize()).view.fittingSize.width
    }

    private static var widestResets: [String: String] = [:]

    /// The widest reset this locale writes, in each form `Labels.reset` has: today, tomorrow, a weekday and a date, with two-digit months and each
    /// kind of hour. Finding it takes many views, so each locale's is kept, and it gives way between them: every suite shares the main actor,
    /// and a poll elsewhere timed out behind this.
    private func widestReset(_ locale: Locale) async -> String {
        if let known = Self.widestResets[locale.identifier] { return known }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let language = locale.language.languageCode == .chinese ? "zh-Hans" : "en"
        let table = Bundle.tacho.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .tacho
        var said: [String] = []
        for (month, hour, minute) in [(11, 10, 48), (12, 0, 48), (3, 12, 48), (5, 22, 58), (9, 10, 58), (10, 0, 58)] {
            guard let date = calendar.date(from: DateComponents(year: 2026, month: month, day: 28, hour: hour, minute: minute)) else { continue }
            for days in [0, 1, 2, 7] {
                said.append(Labels.reset(date, now: date.addingTimeInterval(Double(-days) * 86_400), calendar: calendar, locale: locale, bundle: table))
            }
        }
        var widest = "", most: CGFloat = 0
        for text in Set(said) {
            let measured = width(text)
            if measured > most { (widest, most) = (text, measured) }
            await Task.yield()
        }
        Self.widestResets[locale.identifier] = widest
        return widest
    }

    private func cell(_ label: String, _ reset: String, percent: String = "≈ 100%", value: Double = 1) -> PanelState.LimitCell {
        PanelState.LimitCell(label: label, percent: percent, value: value, pace: 0.5, level: .normal, caption: reset)
    }

    private func worstCells(_ language: Case) async throws -> [PanelState.LimitCell] {
        let reset = await widestReset(Locale(identifier: language.locale))
        return [
            cell(try string("limit.short.fiveHour", language.language), reset),
            cell(try string("limit.short.week", language.language), reset),
            cell("Sonnet", reset),
        ]
    }

    private func limits(_ cells: [PanelState.LimitCell], name: String = "Anthropic", below: [PanelState.LimitRow] = []) -> PanelState.Limits {
        PanelState.Limits(age: nil, say: nil, tone: .plain, rows: [PanelState.LimitRow(name: name, content: .cells(cells))] + below)
    }

    private func card(_ limits: PanelState.Limits) -> some View {
        LimitsCard(limits: limits, open: {}).frame(width: Self.cardWidth)
    }

    /// Each string of each cell, with its end changed, one at a time.
    private func changes(of cells: [PanelState.LimitCell], below: [PanelState.LimitRow] = []) -> [(what: String, limits: PanelState.Limits)] {
        var changes: [(what: String, limits: PanelState.Limits)] = []
        for index in cells.indices {
            var percent = cells, reset = cells, label = cells
            percent[index].percent = changedEnd(percent[index].percent)
            reset[index].caption = changedEnd(reset[index].caption)
            label[index].label = changedEnd(label[index].label)
            changes.append(("percent of \(cells[index].label)", limits(percent, below: below)))
            changes.append(("reset of \(cells[index].label)", limits(reset, below: below)))
            changes.append(("label \(cells[index].label)", limits(label, below: below)))
        }
        return changes
    }

    @Test(arguments: cases)
    func threeLimitsAreDrawnToTheirEnds(_ language: Case) async throws {
        let cells = try await worstCells(language)
        let edits = changes(of: cells)
        let results = await differs(from: limits(cells), edits.map(\.limits), width: Self.cardWidth, sidePadding: Self.padding) { card($0) }
        for (edit, drawn) in zip(edits, results) {
            #expect(drawn, "\(language.locale): the end of the \(edit.what) is not drawn")
        }
    }

    /// The other rows hold each column while one string is blanked, so that what changes is that string and nothing else.
    @Test(arguments: cases)
    func everyFigureIsItsFullWidthAndClearOfTheNext(_ language: Case) async throws {
        let cells = try await worstCells(language)
        var variants = [limits(cells)]
        for index in cells.indices {
            var percent = cells, reset = cells, meter = cells
            percent[index].percent = " "
            reset[index].caption = " "
            meter[index].value = 0
            variants += [limits(percent), limits(reset), limits(meter)]
        }
        // `Sonnet` is the widest label, so blanking the first leaves the column where it is.
        var label = cells
        label[0].label = " "
        variants.append(limits(label))
        let images = await drawings(of: variants, width: Self.cardWidth) { card($0) }
        try #require(images.count == variants.count)
        let percentAlone = await inkAlone(cells[0].percent, Theme.Style.small.weight(.medium).monospacedDigit())
        let resetAlone = await inkAlone(cells[0].caption, Theme.Style.caption)
        for index in cells.indices {
            let at = 1 + index * 3
            let percent = try #require(ink(images[0], images[at]), "\(language.locale): no percent drawn")
            let reset = try #require(ink(images[0], images[at + 1]), "\(language.locale): no reset drawn")
            let meter = try #require(ink(images[0], images[at + 2]), "\(language.locale): no meter drawn")
            #expect(abs(percent.width - percentAlone) <= 1.5, "\(language.locale): the percent is \(percent.width) wide, alone \(percentAlone)")
            #expect(abs(reset.width - resetAlone) <= 1.5, "\(language.locale): the reset is \(reset.width) wide, alone \(resetAlone)")
            #expect(!percent.intersects(reset), "\(language.locale): percent and reset meet")
            #expect(!percent.intersects(meter), "\(language.locale): percent and meter meet")
        }
        let firstLabel = try #require(ink(images[0], images[variants.count - 1]), "\(language.locale): no label drawn")
        let firstMeter = try #require(ink(images[0], images[3]))
        #expect(!firstLabel.intersects(firstMeter), "\(language.locale): label and meter meet")
    }

    @Test(arguments: cases)
    func theProviderIsItsFullWidth(_ language: Case) async throws {
        let cells = try await worstCells(language)
        // A longer name below holds the column.
        let below = [PanelState.LimitRow(name: "Anthropic Max", content: .cells([cells[0]]))]
        var blanked = cells
        blanked[0].label = " "
        let images = await drawings(of: [limits(cells, below: below), limits(cells, name: " ", below: below), limits(blanked, below: below)], width: Self.cardWidth) { card($0) }
        try #require(images.count == 3)
        let name = try #require(ink(images[0], images[1]))
        let label = try #require(ink(images[0], images[2]))
        let alone = await inkAlone("Anthropic", Theme.Style.small)
        #expect(abs(name.width - alone) <= 1.5)
        #expect(!name.intersects(label), "\(language.locale): the provider runs into the label")
    }

    /// A scope is whatever the API calls it. A long one may lose its own end, but never a figure's.
    @Test(arguments: cases)
    func aLongScopeNeverCostsAFigure(_ language: Case) async throws {
        let reset = await widestReset(Locale(identifier: language.locale))
        let cells = [cell(try string("limit.short.fiveHour", language.language), reset), cell("A Very Long Scope Name From The API", reset)]
        var edits = changes(of: cells).filter { !$0.what.hasPrefix("label") }
        edits.append(("provider", limits(cells, name: "AnthropiX")))
        let results = await differs(from: limits(cells), edits.map(\.limits), width: Self.cardWidth, sidePadding: Self.padding) { card($0) }
        for (edit, drawn) in zip(edits, results) {
            #expect(drawn, "\(language.locale): the end of the \(edit.what) is not drawn")
        }
    }

    /// Two of them, so that one can be blanked and the other hold the column.
    @Test(arguments: cases)
    func aLongScopeStopsShortOfTheFigures(_ language: Case) async throws {
        let reset = await widestReset(Locale(identifier: language.locale))
        let long = "A Very Long Scope Name From The API"
        let cells = [cell(long, reset), cell(long, reset)]
        var label = cells, percent = cells
        label[0].label = " "
        percent[0].percent = " "
        let images = await drawings(of: [limits(cells), limits(label), limits(percent)], width: Self.cardWidth) { card($0) }
        try #require(images.count == 3)
        let scope = try #require(ink(images[0], images[1]))
        let figure = try #require(ink(images[0], images[2]))
        #expect(scope.maxX <= figure.minX, "\(language.locale): the scope ends at \(scope.maxX), the percent starts at \(figure.minX)")
    }

    private func rows(_ text: String) -> [PanelState.LimitRow] {
        [PanelState.LimitRow(name: "xAI", content: .message(text)), PanelState.LimitRow(name: "No quota", content: .line(text))]
    }

    /// These rows run the whole width, and however long they are they must leave the figures alone.
    @Test(arguments: cases)
    func aLongRowBelowLeavesTheFiguresWhole(_ language: Case) async throws {
        let cells = try await worstCells(language)
        let below = rows(String(repeating: "OpenCode ≈ $0.20/h · ", count: 8))
        let edits = changes(of: cells, below: below).filter { !$0.what.hasPrefix("label") }
        let results = await differs(from: limits(cells, below: below), edits.map(\.limits), width: Self.cardWidth, sidePadding: Self.padding) { card($0) }
        for (edit, drawn) in zip(edits, results) {
            #expect(drawn, "\(language.locale): the end of the \(edit.what) is not drawn")
        }
    }

    /// Its end is the age: `limit.noRecent`.
    @Test func aMessageKeepsItsEnd() async throws {
        let text = String(repeating: "No recent quota data · last figure ", count: 3) + "15 d ago"
        func message(_ text: String) -> PanelState.Limits {
            PanelState.Limits(age: nil, say: nil, tone: .plain, rows: [PanelState.LimitRow(name: "xAI", content: .message(text))])
        }
        let results = await differs(from: message(text), [message(changedEnd(text))], width: Self.cardWidth) { card($0) }
        #expect(results == [true])
    }

    /// A provider's name reads with the start of its message, not beside the middle of it.
    @Test func aNameStaysWithTheFirstLineOfItsMessage() async throws {
        let text = String(repeating: "No recent quota data · last figure ", count: 4) + "15 d ago"
        func message(_ name: String, _ text: String) -> PanelState.Limits {
            // The second row holds the column, or blanking the name would slide the whole message over and all of it would seem to be the name.
            PanelState.Limits(age: nil, say: nil, tone: .plain, rows: [PanelState.LimitRow(name: name, content: .message(text)), PanelState.LimitRow(name: "xAI", content: .message("short"))])
        }
        // Only the first letter changes, as blanking the message would make the card shorter and leave nothing to compare.
        let images = await drawings(of: [message("xAI", text), message(" ", text), message("xAI", "H" + text.dropFirst()), message("xAI", "short")], width: Self.cardWidth) { card($0) }
        try #require(images.count == 4)
        #expect(images[0].size.height > images[3].size.height + 10, "the message did not wrap, so this shows nothing")
        let name = try #require(ink(images[0], images[1]))
        let first = try #require(ink(images[0], images[2]))
        #expect(abs(name.minY - first.minY) <= 3, "the name is at \(name.minY), the message starts at \(first.minY)")
    }

    /// A row of text below must not move the columns, or the meter, whatever it says: one more CLI would shift every figure above it.
    @Test func theColumnsStayPutWhateverIsBelow() async throws {
        let cells = [cell("5 h", "Wed 10:58 pm"), cell("Week", "Wed 10:58 pm"), cell("Sonnet", "Wed 10:58 pm")]
        var blanked = cells, empty = cells
        blanked[0].percent = " "
        empty[0].value = 0
        var boxes: [(percent: CGRect, meter: CGRect)] = []
        for below in [[], rows("short"), rows("OpenCode ≈ $0.20/h · pi ≈ $0.10/h"), rows(String(repeating: "OpenCode ≈ $0.20/h · ", count: 8))] {
            let images = await drawings(of: [limits(cells, below: below), limits(blanked, below: below), limits(empty, below: below)], width: Self.cardWidth) { card($0) }
            try #require(images.count == 3)
            boxes.append((try #require(ink(images[0], images[1])), try #require(ink(images[0], images[2]))))
        }
        for box in boxes {
            #expect(abs(box.percent.maxX - boxes[0].percent.maxX) <= 0.5, "the percent moved: \(box.percent.maxX), not \(boxes[0].percent.maxX)")
            #expect(abs(box.meter.width - boxes[0].meter.width) <= 0.5, "the meter changed: \(box.meter.width), not \(boxes[0].meter.width)")
        }
    }

    /// The columns are measured once for each change, and a measure left over from before one would cut off the figure that grew.
    @Test func aFigureThatGrowsInPlaceDrawsLikeANewOne() async throws {
        let narrow = limits([cell("5 h", "18:17", percent: "4%"), cell("Week", "18:17", percent: "4%")])
        let wide = limits([cell("5 h", "Wed 10:58 pm"), cell("Week", "Wed 10:58 pm")])
        let updated = await drawings(of: [narrow, wide, narrow], width: Self.cardWidth) { card($0) }
        let new = await drawings(of: [wide], width: Self.cardWidth) { card($0) }
        let newNarrow = await drawings(of: [narrow], width: Self.cardWidth) { card($0) }
        try #require(updated.count == 3 && new.count == 1 && newNarrow.count == 1)
        #expect(isSame(updated[1], new[0]), "the card did not follow a figure that grew")
        #expect(isSame(updated[2], newNarrow[0]), "the card did not follow a figure that shrank")
    }

    @Test func aLimitThatArrivesDrawsLikeANewOne() async throws {
        let two = limits([cell("5 h", "Wed 10:58 pm"), cell("Week", "Wed 10:58 pm")])
        let three = limits([cell("5 h", "Wed 10:58 pm"), cell("Sonnet", "Wed 10:58 pm"), cell("Week", "Wed 10:58 pm")])
        let updated = await drawings(of: [two, three], width: Self.cardWidth) { card($0) }
        let new = await drawings(of: [three], width: Self.cardWidth) { card($0) }
        try #require(updated.count == 2 && new.count == 1)
        #expect(isSame(updated[1], new[0]), "the card did not follow a new limit")
    }

    /// A scroll bar that takes up room narrows the card with nothing inside it having changed.
    @Test func aCardFollowsAChangeOfWidth() async throws {
        let shown = limits([cell("5 h", "Wed 10:58 pm"), cell("Week", "Wed 10:58 pm")])
        let narrower = Self.cardWidth - 17
        func view(_ width: CGFloat) -> some View {
            LimitsCard(limits: shown, open: {}).frame(width: width).frame(width: Self.cardWidth, alignment: .leading)
        }
        let updated = await drawings(of: [Self.cardWidth, narrower, Self.cardWidth], width: Self.cardWidth) { view($0) }
        let new = await drawings(of: [narrower], width: Self.cardWidth) { view($0) }
        let newFull = await drawings(of: [Self.cardWidth], width: Self.cardWidth) { view($0) }
        try #require(updated.count == 3 && new.count == 1 && newFull.count == 1)
        #expect(isSame(updated[1], new[0]), "the card did not follow a narrower width")
        #expect(isSame(updated[2], newFull[0]), "the card did not follow the width back")
    }

    /// In line with the chevron above them.
    @Test func theFiguresEndAtTheCardsEdge() async throws {
        let cells = [cell("5 h", "Wed 10:58 pm"), cell("Week", "Wed 10:58 pm")]
        var blanked = cells
        blanked[0].caption = " "
        let below = rows("OpenCode ≈ $0.20/h · pi ≈ $0.10/h")
        let images = await drawings(of: [limits(cells, below: below), limits(blanked, below: below)], width: Self.cardWidth) { card($0) }
        try #require(images.count == 2)
        let reset = try #require(ink(images[0], images[1]))
        #expect(abs(reset.maxX - (Self.cardWidth - Self.padding)) <= 3, "the reset ends at \(reset.maxX)")
    }

    // A first day.

    private struct FirstDay: Equatable {
        var state: PanelState
        var notice: String?
    }

    private func firstDay(sentence: String, say: String, note: String, notice: String) -> FirstDay {
        var state = PanelSamples.busy
        state.today.sentence = sentence
        state.today.note = note
        state.limits.say = say
        state.limits.rows = []
        return FirstDay(state: state, notice: notice)
    }

    /// The real panel, at its width. In the language the text is written in, whatever this process runs in.
    @Test(arguments: ["en", "zh-Hans"])
    func aFirstDaysSentencesAreDrawnWhole(language: String) async throws {
        let sentence = String(format: try string("highlight.h2", language), 1)
        let tomorrow = try string("highlight.h2Tomorrow", language)
        let say = try string("limit.say.noQuotaOther", language)
        let note = try string("today.clockBehind", language)
        let notice = try string("popover.indexSetAside", language)
        let base = firstDay(sentence: sentence, say: say, note: note, notice: notice)
        let edits = [
            ("the day count", firstDay(sentence: changedDigit(sentence), say: say, note: note, notice: notice)),
            ("the end of the sentence", firstDay(sentence: changedEnd(sentence), say: say, note: note, notice: notice)),
            ("the last day", firstDay(sentence: tomorrow, say: say, note: note, notice: notice)),
            ("the quota line", firstDay(sentence: sentence, say: changedEnd(say), note: note, notice: notice)),
            ("the clock line", firstDay(sentence: sentence, say: say, note: changedEnd(note), notice: notice)),
            ("the notice", firstDay(sentence: sentence, say: say, note: note, notice: changedEnd(notice))),
        ]
        let results = await differs(from: base, edits.map(\.1), width: Theme.Size.panelWidth) { shown in
            PopoverPanel(state: shown.state, isFailing: false, notice: shown.notice, pick: { _ in }, open: { _ in }, quit: {})
        }
        for (edit, drawn) in zip(edits, results) {
            #expect(drawn, "\(language): the end of \(edit.0) is not drawn")
        }
    }

    @Test(arguments: ["en", "zh-Hans"])
    func aPanelThatCannotShowFiguresSaysItAll(language: String) async throws {
        let said = try string("popover.unavailable", language)
        // `setupNote` takes the same line as the failure, so the text can be varied without a second language in the bundle.
        let results = await differs(from: said, [changedEnd(said)], width: Theme.Size.panelWidth) { text in
            PopoverPanel(state: nil, isFailing: true, setupNote: text, pick: { _ in }, open: { _ in }, quit: {})
        }
        #expect(results == [true], "\(language): the end of the failure line is not drawn")
    }

    // The Cache card.

    private func tile(_ value: String) -> [PanelState.Tile] {
        [
            PanelState.Tile(id: "output", title: "Output", value: "1.81M", say: "above your usual", mark: .needle(value: 1.8, p25: 0.5, p75: 1.2), route: Route(page: .tokens)),
            PanelState.Tile(id: "cache", title: "Cache", value: value, say: "≈ $864 kept off the bill", mark: .spark([0.9, 0.92, 0.95, 0.93, 0.97, 0.98, 1]), route: Route(page: .cache)),
        ]
    }

    @Test(arguments: ["100.0% hit", "命中率 100.0%", "命中率 98.3%", "100.0%", "98.3% hit"])
    func theCacheFigureIsDrawnWhole(value: String) async {
        let results = await differs(from: value, [changedDigit(value), changedEnd(value)], width: Self.cardWidth) { value in
            TileGrid(tiles: tile(value), open: { _ in }).frame(width: Self.cardWidth)
        }
        #expect(results == [true, true], "the digits or the end of \(value) are not drawn")
    }

    /// The first digit, for another.
    private func changedFirstDigit(_ text: String) -> String {
        guard let index = text.firstIndex(where: \.isNumber) else { return text }
        return text.replacingCharacters(in: index...index, with: text[index] == "7" ? "4" : "7")
    }

    /// How far apart a figure's first and last digits are drawn. All digits being one width, nothing else moves, and any shrinking shows.
    private func digitSpan<Content: View>(_ value: String, width: CGFloat, @ViewBuilder content: @escaping (String) -> Content) async throws -> CGFloat {
        let images = await drawings(of: [value, changedFirstDigit(value), changedDigit(value)], width: width, content: content)
        try #require(images.count == 3)
        let first = try #require(ink(images[0], images[1]))
        let last = try #require(ink(images[0], images[2]))
        return last.minX - first.minX
    }

    /// Not shrunk to fit, which no change of a character's end can see.
    @Test(arguments: ["100.0% hit", "命中率 100.0%", "命中率 98.3%"])
    func theCacheFigureIsFullSize(value: String) async throws {
        let drawn = try await digitSpan(value, width: Self.cardWidth) { value in
            TileGrid(tiles: tile(value), open: { _ in }).frame(width: Self.cardWidth)
        }
        let alone = try await digitSpan(value, width: 300) { value in
            Text(verbatim: value).font(Theme.Style.value).monospacedDigit().fixedSize().frame(width: 300, alignment: .leading)
        }
        #expect(abs(drawn - alone) <= 0.5, "\(value): its digits span \(drawn), alone \(alone)")
    }

    /// The same measure, shown to fire.
    @Test func theSpanFindsAShrunkenFigure() async throws {
        let shrunk = try await digitSpan("命中率 100.0%", width: 300) { value in
            Text(verbatim: value).font(Theme.Style.value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: 100, alignment: .leading).frame(width: 300, alignment: .leading)
        }
        let alone = try await digitSpan("命中率 100.0%", width: 300) { value in
            Text(verbatim: value).font(Theme.Style.value).monospacedDigit().fixedSize().frame(width: 300, alignment: .leading)
        }
        #expect(shrunk < alone - 0.5)
    }
}
