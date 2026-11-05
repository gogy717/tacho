import AppKit
import os

/// `-TachoLogClicks YES`: every press in a window's title bar, and every release a control does not take while tracking its press,
/// written to the system log as points, frames and view classes, never anything read from the logs. A click on the toolbar that
/// comes to nothing shows here: what took it, or, with no line at all, that it never reached Tacho, because macOS took it as the
/// start of a window drag. Read with `log show --last 10m --predicate 'subsystem == "io.github.gogy717.tacho" AND category == "clicks"'`.
@MainActor
final class ClickLog {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "TachoLogClicks") }

    private static let logger = Logger(subsystem: "io.github.gogy717.tacho", category: "clicks")

    private var monitor: Any?

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            // Local monitors are called on the main thread, before the event is sent on.
            MainActor.assumeIsolated {
                if let line = Self.line(for: event) {
                    Self.logger.notice("\(line, privacy: .public)")
                }
            }
            return event
        }
    }

    /// Nil for a click below the title bar.
    static func line(for event: NSEvent) -> String? {
        guard let window = event.window, let frameView = window.contentView?.superview else { return nil }
        let point = event.locationInWindow
        guard point.y > window.contentLayoutRect.maxY else { return nil }
        var parts = [
            "\(event.type == .leftMouseDown ? "down" : "up") at \(text(point)) in \(Int(window.frame.width))x\(Int(window.frame.height))",
        ]
        if let hit = frameView.hitTest(point) {
            let chain = sequence(first: hit, next: \.superview).prefix(5).map { className($0) }
            parts.append("hit \(chain.joined(separator: " < ")) \(text(hit.convert(hit.bounds, to: nil)))")
        } else {
            parts.append("hit nothing")
        }
        for control in views(in: frameView).compactMap({ $0 as? NSSegmentedControl }) where !control.isHiddenOrHasHiddenAncestor {
            let segment = segments(of: control).firstIndex { $0.contains(point) }.map(String.init) ?? "none"
            parts.append(
                "segmented \(text(control.convert(control.bounds, to: nil))) of \(control.segmentCount), selected \(control.selectedSegment), "
                    + "under the click \(segment)"
            )
        }
        // What a toolbar holds: each item's frame and the title's, which reaches across to the first centred item.
        for view in views(in: frameView) where !view.isHiddenOrHasHiddenAncestor {
            let name = className(view)
            guard name.hasPrefix("NSToolbarItemViewer") || name.contains("ToolbarTitle") || name.contains("ToolbarPrimaryTitle") else { continue }
            parts.append("\(name) \(text(view.convert(view.bounds, to: nil)))")
        }
        return parts.joined(separator: "; ")
    }

    private static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    /// In window coordinates, from Accessibility, which knows each segment's own width.
    private static func segments(of control: NSSegmentedControl) -> [NSRect] {
        let children = control.accessibilityChildren() ?? []
        return children.compactMap { ($0 as? NSAccessibilityElementProtocol)?.accessibilityFrame() }.compactMap { control.window?.convertFromScreen($0) }
    }

    private static func className(_ view: NSView) -> String {
        let name = String(describing: type(of: view))
        // SwiftUI's hosting views carry their whole view type in the name.
        return name.firstIndex(of: "<").map { String(name[..<$0]) } ?? name
    }

    private static func text(_ point: NSPoint) -> String {
        "(\(round(point.x * 2) / 2), \(round(point.y * 2) / 2))"
    }

    private static func text(_ rect: NSRect) -> String {
        "(\(round(rect.minX * 2) / 2), \(round(rect.minY * 2) / 2), \(round(rect.width * 2) / 2), \(round(rect.height * 2) / 2))"
    }
}
