import AppKit
@testable import Tacho

/// Every cell of the layout matrix drawn to a folder, and a sheet of each page, to be read by eye.
///
/// Offscreen, a capture of the whole window loses the page once the window has been resized: the page lives in scroll views that the
/// capture no longer reaches, though they still draw. So each scroll view's document is drawn where it sits, over the window's own frame
/// and under its toolbar. The sidebar's glass is drawn by the window server, so it is grey here.
@MainActor
final class ContactSheet {
    private struct Cell {
        var page: Page
        var width: CGFloat
        var height: CGFloat
        var sidebar: String
        var image: CGImage
    }

    private let folder: URL
    private var cells: [Cell] = []

    init?(environment name: String) {
        guard let path = ProcessInfo.processInfo.environment[name], !path.isEmpty else { return nil }
        let language = Bundle.tacho.preferredLocalizations.first ?? "en"
        folder = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(language, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A `variant` of a page is drawn to the folder and stays off its sheet, which has one place for each size.
    func add(_ window: NSWindow, page: Page, variant: String? = nil, width: CGFloat, height: CGFloat, sidebar: String) {
        guard let image = Self.picture(window) else { return }
        write(image, to: "\(page.rawValue)\(variant.map { "-\($0)" } ?? "")-\(Int(width))x\(Int(height))-\(sidebar).png")
        guard variant == nil else { return }
        cells.append(Cell(page: page, width: width, height: height, sidebar: sidebar, image: image))
    }

    /// One sheet a page: a row for each height and sidebar, a column for each width, narrowest first, at a quarter of their size.
    func finish() {
        let scale: CGFloat = 0.25
        let label: CGFloat = 16
        let gap: CGFloat = 10
        for page in Page.allCases {
            let mine = cells.filter { $0.page == page }
            guard !mine.isEmpty else { continue }
            let widths = Array(Set(mine.map(\.width))).sorted()
            let rows = Array(Set(mine.map { "\(Int($0.height)) \($0.sidebar)" })).sorted()
            let columnWidth = (widths.max() ?? 0) * scale
            let rowHeight = (mine.map(\.height).max() ?? 0) * scale + label
            let size = CGSize(width: CGFloat(widths.count) * (columnWidth + gap) + gap, height: CGFloat(rows.count) * (rowHeight + gap) + gap)
            guard let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            context.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for cell in mine {
                guard let column = widths.firstIndex(of: cell.width), let row = rows.firstIndex(of: "\(Int(cell.height)) \(cell.sidebar)") else { continue }
                let x = gap + CGFloat(column) * (columnWidth + gap)
                let top = size.height - gap - CGFloat(row) * (rowHeight + gap)
                let text = "\(page.rawValue) \(Int(cell.width))×\(Int(cell.height)) sidebar \(cell.sidebar)" as NSString
                text.draw(at: NSPoint(x: x, y: top - label + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black])
                let drawn = CGRect(x: x, y: top - label - cell.height * scale, width: cell.width * scale, height: cell.height * scale)
                context.interpolationQuality = .high
                context.draw(cell.image, in: drawn)
            }
            NSGraphicsContext.restoreGraphicsState()
            if let sheet = context.makeImage() { write(sheet, to: "sheet-\(page.rawValue).png") }
        }
        cells.removeAll()
    }

    private func write(_ image: CGImage, to name: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
    }

    private static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for sub in view.subviews { found += views(type, in: sub) }
        return found
    }

    /// The window at 1x: its frame and toolbar, each scroll view's document where it sits, and the sidebar's place in grey.
    static func picture(_ window: NSWindow) -> CGImage? {
        guard let frame = window.contentView?.superview, let base = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: base)
        guard let baseImage = base.cgImage else { return nil }
        let size = frame.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(baseImage, in: CGRect(origin: .zero, size: size))
        let clips = views(NSClipView.self, in: frame).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.documentView != nil }
        let split = views(NSSplitView.self, in: frame).first { $0.arrangedSubviews.count == 2 }
        let sidebar = split.flatMap { split in split.arrangedSubviews.first.flatMap { split.isSubviewCollapsed($0) ? nil : $0 } }
        func draw(_ clip: NSClipView) {
            guard let document = clip.documentView else { return }
            let visible = clip.documentVisibleRect
            guard visible.width >= 1, visible.height >= 1, let rep = document.bitmapImageRepForCachingDisplay(in: visible) else { return }
            document.cacheDisplay(in: visible, to: rep)
            guard let image = rep.cgImage else { return }
            context.saveGState()
            context.clip(to: CGRect(origin: .zero, size: size))
            context.draw(image, in: clip.convert(clip.bounds, to: nil))
            context.restoreGState()
        }
        let inSidebar = { (clip: NSClipView) in sidebar.map { clip.isDescendant(of: $0) } ?? false }
        for clip in clips where !inSidebar(clip) { draw(clip) }
        if let sidebar {
            context.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
            context.fill(sidebar.convert(sidebar.bounds, to: nil).insetBy(dx: 4, dy: 4))
            for clip in clips where inSidebar(clip) { draw(clip) }
        }
        // The toolbar over what scrolls under it.
        let bar = size.height - window.contentLayoutRect.maxY
        if bar > 0, let strip = baseImage.cropping(to: CGRect(x: 0, y: 0, width: baseImage.width, height: Int(bar * CGFloat(baseImage.height) / size.height))) {
            context.draw(strip, in: CGRect(x: 0, y: size.height - bar, width: size.width, height: bar))
        }
        return context.makeImage()
    }
}
