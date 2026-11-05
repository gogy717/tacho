import SwiftUI

/// Where the mark's parts fall on a scale `width` wide: spec §3.1.
struct NeedleGeometry {
    let value: Double
    let p25: Double
    let p75: Double
    let width: CGFloat

    /// Keeps the band in the left half and the needle on the scale: a huge day squeezes the band instead of clipping the needle.
    var domain: Double {
        max(p75 * 2, value * 1.15)
    }

    /// With nothing yet and no use at this hour there is nothing to place, so the ticks stand alone.
    var hasMarks: Bool { domain > 0 }

    /// Fewer on a small scale, where 21 would be too dense to read.
    var ticks: Int { width < 100 ? 11 : 21 }

    var bandRect: CGRect {
        CGRect(x: p25 / domain * width, y: 1, width: max(2, (p75 - p25) / domain * width), height: 7)
    }

    var needleRect: CGRect {
        CGRect(x: min(1, max(0, value / domain)) * (width - 2), y: 0, width: 2, height: Theme.Size.scaleHeight)
    }
}

/// Tacho's own mark: a needle on a tick scale, with the usual range as a band. With no usual range, draw no scale at all.
struct NeedleMark: View {
    let value: Double
    let p25: Double
    let p75: Double

    var body: some View {
        Canvas { context, size in
            let geometry = NeedleGeometry(value: value, p25: p25, p75: p75, width: size.width)
            for tick in 0..<geometry.ticks {
                let x = (size.width - 1) * CGFloat(tick) / CGFloat(geometry.ticks - 1)
                context.fill(Path(CGRect(x: x, y: 8, width: 1, height: 5)), with: .color(Theme.tick))
            }
            guard geometry.hasMarks else { return }
            context.fill(Path(roundedRect: geometry.bandRect, cornerRadius: 2), with: .color(Theme.well))
            context.fill(Path(roundedRect: geometry.needleRect, cornerRadius: 1), with: .color(.primary))
        }
        .frame(height: Theme.Size.scaleHeight)
        // The card's text says the same in words.
        .accessibilityHidden(true)
    }
}
