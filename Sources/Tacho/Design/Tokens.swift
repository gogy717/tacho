import AppKit
import SwiftUI

extension Color {
    /// A colour stepped for each appearance. The alphas are for surfaces, which lay a tint over whatever is behind them.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255,
                green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }
}

/// Direction B's tokens: docs/design/direction-b-spec.md, section 2. Backgrounds are the system's, so nothing here paints one, and text
/// is `.primary` or `.secondary`, which follow vibrancy and Increase Contrast as a custom grey would not.
enum Theme {
    /// Motion that reads the setting: with Reduce Motion on, figures just change. Spec §9.
    static func motion(_ animation: Animation, reduceMotion: Bool) -> Animation? { reduceMotion ? nil : animation }

    // Surfaces.
    static let tile = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.06)
    static let well = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.11)
    static let hover = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.13)
    static let tick = Color.primary.opacity(0.24)

    // Warnings. Reserved: no chart series may use them.
    static let amberFill = Color.orange
    static let amberInk = Color(light: 0x8A4B00, dark: 0xFFC56E)
    static let amberWash = Color.orange.opacity(0.14)
    static let redFill = Color.red
    static let redInk = Color(light: 0xB3211A, dark: 0xFF8F87)
    static let live = Color.green

    // The token categories, which keep off orange and amber so that a warning stays one. Text never takes these: a swatch sits beside it.
    static let cacheRead = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let cacheWrite = Color(light: 0x1BAF7A, dark: 0x199E70)
    static let output = Color(light: 0x6250D6, dark: 0x9085E9)
    static let input = Color(light: 0xE87BA4, dark: 0xD55181)

    /// Bottom to top. The colour-vision check passed for these neighbours, and `TokenCategory.allCases` is in a different order, so charts
    /// stack by this.
    static let stackOrder: [TokenCategory] = [.cacheRead, .cacheWrite, .output, .input]

    /// A chart stacked by model or CLI, in the order the colours are given out. A colour stays with its model while the stack reorders by size,
    /// so any two can touch, and this set was chosen to pass for every pair and not only neighbours: colour-blind separation of at least 9.5
    /// and normal separation of at least 17.8 in both modes, and 3:1 against the page. No set of five distinct hues does, so two are green,
    /// which are the last pair to meet. Orange and red stay out, as they say something else here. `seriesOther` is in that check too.
    static let series = [
        Color(light: 0x0375E2, dark: 0x256ABC),
        Color(light: 0xB61F7A, dark: 0xBA3280),
        Color(light: 0x34A226, dark: 0x1FB000),
        Color(light: 0x6F20B8, dark: 0xA96FF3),
        Color(light: 0x1F6617, dark: 0x397732),
    ]
    /// Everything past the top five: grey, so that it does not read as one more model.
    static let seriesOther = Color(light: 0x8E8E93, dark: 0x8E8E93)

    /// The type scale. On macOS `.caption` is 10 pt, so it is not used. Figures also take `.monospacedDigit()`.
    enum Style {
        static let figureXL = Font.system(size: 36, weight: .semibold)
        static let figureL = Font.system(size: 21, weight: .semibold)
        static let sentenceL = Font.system(size: 18, weight: .semibold)
        static let sentence = Font.system(size: 16, weight: .semibold)
        static let value = Font.title3.weight(.semibold)
        static let body = Font.body
        static let small = Font.callout
        static let caption = Font.subheadline
        static let cardTitle = Font.subheadline.weight(.semibold)
    }

    enum Size {
        static let panelWidth: CGFloat = 360
        static let panelInset: CGFloat = 16
        static let cardGap: CGFloat = 8
        static let cardPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        static let smallCardPadding = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        static let cardRadius: CGFloat = 12
        static let noteRadius: CGFloat = 8
        static let swatch: CGFloat = 7
        static let meterHeight: CGFloat = 5
        static let scaleHeight: CGFloat = 13
        static let pageInset: CGFloat = 20
        static let columnGap: CGFloat = 20
        /// The narrowest a page's side column is worth showing at beside the main one: 21 em of `small`, about 40 Latin or 21 Chinese
        /// characters of a highlight a line. Narrower, a page stacks: a column also never goes below what its own content needs.
        static let sideColumn: CGFloat = 21 * NSFont.preferredFont(forTextStyle: .callout).pointSize
        /// The narrowest a main column is worth showing at: 30 em, room for a chart's columns under the stats.
        static let mainColumn: CGFloat = 30 * NSFont.preferredFont(forTextStyle: .callout).pointSize
    }
}
