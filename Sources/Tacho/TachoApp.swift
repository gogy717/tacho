import AppKit
import SwiftUI

@main
struct TachoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // With a binding, not the plain form: a removed status item otherwise quits the app, which is how macOS blocking it looked like a
        // silent exit 0.08 to 0.3 s after launch.
        MenuBarExtra(isInserted: delegate.menuBarItemInserted) {
            PopoverView(model: delegate.model, open: { delegate.showMainWindow($0) }, quit: { delegate.quit() })
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the model, so that it exists before the scenes do and starts once the app has launched, and the main window, so that every
/// route to it works: launch, the popover, opening the app again, and a blocked status item, when no SwiftUI view is left to open one.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let mainWindowSize = NSSize(width: 1240, height: 720)

    /// Off in tests. The frame is saved under the process's name, and every worktree's test runs share `swiftpm-testing-helper`: a frame
    /// saved there opens every lane's windows at that size.
    var savesWindowFrame = true

    let model: AppModel
    private(set) var mainWindow: NSWindow?
    private var popoverWindow: NSWindow?
    private var quitAsked = false
    private var clickLog: ClickLog?
    private let present: (NSWindow) -> Void
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    private let terminate: () -> Void

    override convenience init() {
        self.init(model: AppModel())
    }

    init(
        model: AppModel,
        present: @escaping (NSWindow) -> Void = {
            $0.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        },
        setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
        terminate: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.model = model
        self.present = present
        self.setActivationPolicy = setActivationPolicy
        self.terminate = terminate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(quitTarget: self, quit: #selector(quitFromMenu(_:)))
        model.start()
        if model.opensMainWindowAtLaunch {
            showMainWindow()
        }
        if UserDefaults.standard.bool(forKey: "TachoShowPopoverWindow") {
            showPopoverWindow()
        }
        if ClickLog.isOn {
            let log = ClickLog()
            log.start()
            clickLog = log
        }
    }

    /// Tacho.app opened again while it runs, from Finder or Spotlight, or the Dock while the status item is blocked.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    /// A menu bar app outlives its windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationReply(
            appleEvent: NSAppleEventManager.shared().currentAppleEvent != nil,
            input: NSApp.currentEvent,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    /// `MenuBarExtra(isInserted:)` is what stops a blocked status item quitting the app: on a real blocked run the removal arrived and no
    /// `terminate:` followed. This is for a macOS where one does follow. A real quit has something behind it: our Quit, a key press, or an
    /// Apple event, which is how the Dock, logging out and `brew uninstall` ask. Anything else is refused, blocked or not.
    func terminationReply(appleEvent: Bool, input: NSEvent?, now: TimeInterval) -> NSApplication.TerminateReply {
        if quitAsked || appleEvent || Self.isUserInput(input, now: now) {
            return .terminateNow
        }
        menuBarItemRemoved()
        return .terminateCancel
    }

    /// `currentEvent` stays set long after its event, so an old one says nothing about this `terminate:`.
    private static func isUserInput(_ event: NSEvent?, now: TimeInterval) -> Bool {
        guard let event, now - event.timestamp < 1 else { return false }
        return [.keyDown, .leftMouseDown, .leftMouseUp].contains(event.type)
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        quit()
    }

    /// The popover's Quit, the blocked note's and the menu's.
    func quit() {
        quitAsked = true
        terminate()
    }

    // MARK: Status item

    var menuBarItemInserted: Binding<Bool> {
        Binding(
            get: { self.model.menuBarItemInserted },
            set: { if !$0 { self.menuBarItemRemoved() } }
        )
    }

    /// macOS took the status item away, or never allowed it. Tacho stays up, in the Dock so that it can be found again, and says why.
    func menuBarItemRemoved() {
        guard !model.menuBarBlocked else { return }
        model.menuBarBlocked = true
        model.menuBarItemInserted = false
        setActivationPolicy(.regular)
        showMainWindow()
    }

    // MARK: Main window

    func showMainWindow(_ route: Route) {
        model.open(route)
        showMainWindow()
    }

    func showMainWindow() {
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        model.mainWindowVisible = true
        present(window)
    }

    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.mainWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = NSHostingController(rootView: MainWindow(model: model) { [weak self] in self?.quit() })
        // The window's minimum comes from the view's. With no options the hosting view clears `contentMinSize` on its first layout.
        controller.sizingOptions = [.minSize]
        controller.sceneBridgingOptions = .all
        window.contentViewController = controller
        window.title = String(localized: "app.name", bundle: .tacho)
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.mainWindowSize)
        window.center()
        if savesWindowFrame { window.setFrameAutosaveName(MainWindow.id) }
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        // Dropping the views ends their tasks: a closed window polls nothing, and the next one starts fresh.
        window.contentViewController = nil
        mainWindow = nil
        model.mainWindowVisible = false
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        model.mainWindowVisible = window.occlusionState.contains(.visible)
    }

    /// `-TachoShowPopoverWindow YES`: the popover in a regular window, for screenshots.
    private func showPopoverWindow() {
        let view = PopoverView(model: model, open: { [weak self] in self?.showMainWindow($0) }, quit: { [weak self] in self?.quit() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = String(localized: "app.name", bundle: .tacho)
        window.isReleasedWhenClosed = false
        present(window)
        popoverWindow = window
    }
}
