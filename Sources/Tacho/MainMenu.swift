import AppKit

/// The commands a window needs. They arrive through the main menu even in an app that shows no menu bar, and with no window scene nothing
/// else promises one: a text field would have no Command-C, the window no Command-W.
enum MainMenu {
    static func make(quitTarget: AnyObject, quit: Selector) -> NSMenu {
        let quitItem = item("menu.quit", quit, "q")
        quitItem.target = quitTarget

        let menu = NSMenu()
        add(String(localized: "app.name", bundle: .tacho), [quitItem], to: menu)
        add(String(localized: "menu.edit", bundle: .tacho), [
            item("menu.undo", Selector(("undo:")), "z"),
            item("menu.redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("menu.cut", #selector(NSText.cut(_:)), "x"),
            item("menu.copy", #selector(NSText.copy(_:)), "c"),
            item("menu.paste", #selector(NSText.paste(_:)), "v"),
            item("menu.selectAll", #selector(NSText.selectAll(_:)), "a"),
        ], to: menu)
        // The standard item for a window with a sidebar. It sends what the sidebar's own button sends, to whatever holds the sidebar, which
        // retitles it Show or Hide as it stands.
        add(String(localized: "menu.view", bundle: .tacho), [
            item("menu.toggleSidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.control, .command]),
        ], to: menu)
        add(String(localized: "menu.window", bundle: .tacho), [
            item("menu.close", #selector(NSWindow.performClose(_:)), "w"),
            item("menu.minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ], to: menu)
        return menu
    }

    private static func item(
        _ title: String.LocalizationValue,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title, bundle: .tacho), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func add(_ title: String, _ items: [NSMenuItem], to menu: NSMenu) {
        let submenu = NSMenu(title: title)
        submenu.items = items
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        menu.addItem(holder)
    }
}
