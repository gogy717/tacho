import AppKit
import Foundation
@testable import Tacho
import TachoKit

/// Preferences in memory only. A real suite leaves a plist in ~/Library/Preferences for every test, on the Mac of whoever runs them.
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}

/// A temporary home and defaults, gone with the value. Nothing real is read or written.
final class Sandbox {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("tacho-test-\(UUID().uuidString)")
    let defaults: UserDefaults = MemoryDefaults(suiteName: nil)!

    /// - Parameter noEngine: a file where the support folder goes, so that no `Engine` can open. Used wherever the Anthropic query is
    ///   allowed, so that no fetcher can exist, whatever a test does.
    init(installed: [String] = [], noEngine: Bool = false) throws {
        let library = home.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        if noEngine {
            FileManager.default.createFile(atPath: library.appendingPathComponent("Tacho").path, contents: Data())
        }
        for path in installed {
            let url = home.appendingPathComponent(path)
            if url.pathExtension == "db" {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: Data())
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    /// What was answered so far, as a launch would load it.
    func seed(_ change: (inout Preferences) -> Void) throws {
        var preferences = Preferences.defaults(home: home)
        change(&preferences)
        defaults.set(try JSONEncoder().encode(preferences), forKey: "preferences")
    }
}

/// Stands in for `Engine.start`, which would read real files.
actor LaunchLog {
    private(set) var count = 0
    /// The sources the engine had switched on at each start.
    private(set) var enabled: [Set<Source>] = []

    func record(_ engine: Engine) async {
        count += 1
        enabled.append(Set(await engine.statuses().filter(\.enabled).map(\.source)))
    }
}

extension AppDelegate {
    /// A delegate whose windows stay out of sight and whose process keeps its place, so that tests do not disturb the screen.
    @MainActor static func quiet(
        _ model: AppModel,
        policy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ in },
        terminate: @escaping () -> Void = {}
    ) -> AppDelegate {
        let delegate = AppDelegate(model: model, present: Tests.hide, setActivationPolicy: policy, terminate: terminate)
        delegate.savesWindowFrame = false
        return delegate
    }
}

enum Tests {
    /// The strings of `language`. SwiftPM's debug build on Swift 6.1 writes `zh-hans.lproj`; a release build keeps the case.
    static func strings(_ language: String) -> Bundle? {
        (Bundle.tacho.path(forResource: language, ofType: "lproj") ?? Bundle.tacho.path(forResource: language.lowercased(), ofType: "lproj"))
            .flatMap(Bundle.init(path:))
    }

    /// Whether this screen can hold the window at full size. A CI runner's is 1024 by 768, and a window takes only what the screen has.
    @MainActor static var screenHoldsTheWindow: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.visibleFrame.width >= 1240 && screen.visibleFrame.height >= 800
    }

    /// Waits on the condition, not on a clock: under a loaded full run any fixed sleep is too short sooner or later.
    @MainActor static func eventually(within limit: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @MainActor static func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.orderBack(nil)
    }
}
