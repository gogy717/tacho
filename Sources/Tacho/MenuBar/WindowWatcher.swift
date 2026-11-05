import AppKit
import SwiftUI

/// Says whether the window around it is on screen. A `MenuBarExtra` is free to keep its view when it closes, so the panel does not
/// count on SwiftUI's own view lifetime to learn it has gone.
struct WindowWatcher: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> WatcherView {
        WatcherView(changed: changed)
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.changed = changed
    }
}

final class WatcherView: NSView {
    var changed: (Bool) -> Void
    private var isShown = false
    private var visibility: NSKeyValueObservation?

    init(changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Built in code")
    }

    /// `isVisible`, not `occlusionState`: a window ordered out is what closing means, and that holds with no window server to ask.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        visibility = window?.observe(\.isVisible) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.lookSoon() }
        }
        lookSoon()
    }

    /// Both callers arrive in the middle of an update, which is no time to change SwiftUI's state.
    private func lookSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shown = window?.isVisible == true
            guard shown != isShown else { return }
            isShown = shown
            changed(shown)
        }
    }
}
