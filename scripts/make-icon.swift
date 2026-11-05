// Draws Tacho's app icon, a tachometer dial, and builds packaging/AppIcon.icns from it.
// Usage: swift scripts/make-icon.swift

import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func mix(_ from: [CGFloat], _ to: [CGFloat], _ amount: CGFloat) -> CGColor {
    color(
        from[0] + (to[0] - from[0]) * amount,
        from[1] + (to[1] - from[1]) * amount,
        from[2] + (to[2] - from[2]) * amount
    )
}

// All the drawing below is in a 1024-point space with the origin at the bottom left.

let center = CGPoint(x: 512, y: 486)
let tickColor = color(201, 206, 216)
let needleColor = color(244, 245, 247)
let amber: [CGFloat] = [255, 176, 32]
let red: [CGFloat] = [255, 59, 48]
/// Where the scale turns from ticks to the amber-to-red zone.
let zoneStart: CGFloat = 0.7

/// The direction of a point on the scale in radians: 0 is the low end at the lower left, 1 the top end at the lower right.
func angle(_ scale: CGFloat) -> CGFloat {
    (225 - 270 * scale) * .pi / 180
}

func point(_ scale: CGFloat, radius: CGFloat) -> CGPoint {
    CGPoint(x: center.x + radius * cos(angle(scale)), y: center.y + radius * sin(angle(scale)))
}

/// How much heavier to draw at a size: what is fine at 1024 px disappears at 64.
func weight(_ pixels: Int) -> CGFloat {
    pixels >= 128 ? 1 : pixels >= 48 ? 1.7 : 2.2
}

func drawFace(in context: CGContext, pixels: Int) {
    // The rounded square of Apple's macOS icon grid: 824 points in the 1024-point canvas.
    let tile = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
        cornerWidth: 185,
        cornerHeight: 185,
        transform: nil
    )

    // Shadows are in device space, so unlike the paths they have to be scaled by hand. On the small sizes one only blurs the edge.
    context.saveGState()
    if pixels >= 128 {
        let pixelsPerPoint = CGFloat(pixels) / 1024
        context.setShadow(offset: CGSize(width: 0, height: -12 * pixelsPerPoint), blur: 28 * pixelsPerPoint, color: color(0, 0, 0, 0.35))
    }
    context.addPath(tile)
    context.setFillColor(color(18, 22, 29))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(47, 54, 69), color(16, 19, 26)] as CFArray,
        locations: [0, 1]
    )
    if let gradient {
        context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    }
    context.restoreGState()
}

func drawTicks(in context: CGContext, pixels: Int) {
    context.setLineCap(.butt)
    // Fine ticks turn to noise when small, so the small sizes keep fewer, heavier ones.
    let steps = pixels >= 128 ? 35 : pixels >= 48 ? 7 : 0
    guard steps > 0 else { return }
    for step in 0...steps {
        let scale = CGFloat(step) / CGFloat(steps)
        guard scale <= zoneStart else { continue }
        let major = pixels < 128 || step % 5 == 0
        context.setStrokeColor(tickColor)
        context.setLineWidth((major ? 16 : 7) * weight(pixels))
        context.move(to: point(scale, radius: 318))
        context.addLine(to: point(scale, radius: major ? 262 : 288))
        context.strokePath()
    }
}

func drawArc(in context: CGContext, pixels: Int) {
    let width: CGFloat = pixels >= 48 ? 44 : 84
    let radius: CGFloat = pixels >= 48 ? 296 : 276
    context.setLineCap(.butt)
    context.setLineWidth(width)

    if pixels < 48 {
        // No ticks at this size, so a plain arc stands for them.
        context.setStrokeColor(tickColor)
        context.addArc(center: center, radius: radius, startAngle: angle(0), endAngle: angle(zoneStart), clockwise: true)
        context.strokePath()
    }

    let segments = 72
    for segment in 0..<segments {
        let amount = CGFloat(segment) / CGFloat(segments)
        let start = zoneStart + (1 - zoneStart) * amount
        // Each piece runs slightly into the next, so no hairline shows between them.
        let end = min(1, zoneStart + (1 - zoneStart) * (amount + 1.5 / CGFloat(segments)))
        context.setStrokeColor(mix(amber, red, amount))
        context.addArc(center: center, radius: radius, startAngle: angle(start), endAngle: angle(end), clockwise: true)
        context.strokePath()
    }
}

func drawNeedle(in context: CGContext, pixels: Int) {
    let heavy = weight(pixels)
    let scale: CGFloat = 0.62
    let direction = angle(scale)
    let side = direction + .pi / 2
    let tip = point(scale, radius: 262)
    let base = 20 * heavy
    let end = 5 * heavy

    context.setFillColor(needleColor)
    context.move(to: CGPoint(x: center.x + base * cos(side), y: center.y + base * sin(side)))
    context.addLine(to: CGPoint(x: tip.x + end * cos(side), y: tip.y + end * sin(side)))
    context.addLine(to: CGPoint(x: tip.x - end * cos(side), y: tip.y - end * sin(side)))
    context.addLine(to: CGPoint(x: center.x - base * cos(side), y: center.y - base * sin(side)))
    context.closePath()
    context.fillPath()

    let hub = 50 * (pixels >= 48 ? 1 : 1.5)
    context.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2))
    if pixels >= 48 {
        context.setFillColor(color(30, 35, 45))
        context.fillEllipse(in: CGRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40))
    }
}

func drawIcon(pixels: Int) -> CGImage {
    guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { fail("could not create a \(pixels) px bitmap") }

    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawFace(in: context, pixels: pixels)
    drawTicks(in: context, pixels: pixels)
    drawArc(in: context, pixels: pixels)
    drawNeedle(in: context, pixels: pixels)

    guard let image = context.makeImage() else { fail("could not render the \(pixels) px icon") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("could not create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
}

let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("packaging/AppIcon.icns")
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tacho-icon-\(UUID().uuidString)")
let iconset = scratch.appendingPathComponent("AppIcon.iconset")
defer { try? FileManager.default.removeItem(at: scratch) }

do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

    for size in [16, 32, 128, 256, 512] {
        writePNG(drawIcon(pixels: size), to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
        writePNG(drawIcon(pixels: size * 2), to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { fail("iconutil exited with \(iconutil.terminationStatus)") }
} catch {
    fail("\(error)")
}

print("wrote \(output.path)")
