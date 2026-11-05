import AppKit
import Testing
@testable import Tacho

/// With no window scene, nothing else promises a main menu, and without one a text field has no Command-C and the window no Command-W.
@MainActor
struct MainMenuTests {
    private final class Target: NSObject {
        @objc func quit(_ sender: Any?) {}
    }

    private func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
    }

    private func item(_ key: String, in menu: NSMenu, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
        items(menu).first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
    }

    @Test func theEditCommandsReachTheTextField() throws {
        let menu = MainMenu.make(quitTarget: Target(), quit: #selector(Target.quit(_:)))
        #expect(item("c", in: menu)?.action == #selector(NSText.copy(_:)))
        #expect(item("v", in: menu)?.action == #selector(NSText.paste(_:)))
        #expect(item("x", in: menu)?.action == #selector(NSText.cut(_:)))
        #expect(item("a", in: menu)?.action == #selector(NSText.selectAll(_:)))
        #expect(item("z", in: menu)?.action == Selector(("undo:")))
        #expect(item("z", in: menu, modifiers: [.command, .shift])?.action == Selector(("redo:")))
    }

    @Test func theWindowCommandsAreThere() throws {
        let menu = MainMenu.make(quitTarget: Target(), quit: #selector(Target.quit(_:)))
        #expect(item("w", in: menu)?.action == #selector(NSWindow.performClose(_:)))
        #expect(item("m", in: menu)?.action == #selector(NSWindow.performMiniaturize(_:)))
    }

    /// The standard Mac item for a window with a sidebar: it sends what the sidebar's own button sends, so both reach the split view.
    @Test func theSidebarShowsAndHidesFromTheViewMenu() throws {
        let menu = MainMenu.make(quitTarget: Target(), quit: #selector(Target.quit(_:)))
        let toggle = try #require(item("s", in: menu, modifiers: [.control, .command]))
        #expect(toggle.action == #selector(NSSplitViewController.toggleSidebar(_:)))
        #expect(toggle.target == nil)
        #expect(menu.items.map(\.title) == ["Tacho", "Edit", "View", "Window"])
    }

    @Test func quitGoesThroughTheAppsOwnQuit() throws {
        let target = Target()
        let menu = MainMenu.make(quitTarget: target, quit: #selector(Target.quit(_:)))
        let quit = try #require(item("q", in: menu))
        #expect(quit.action == #selector(Target.quit(_:)))
        #expect(quit.target === target)
    }

    @Test func everyTitleHasAString() throws {
        let menu = MainMenu.make(quitTarget: Target(), quit: #selector(Target.quit(_:)))
        #expect(items(menu).allSatisfy { $0.isSeparatorItem || !$0.title.hasPrefix("menu.") })
    }
}
