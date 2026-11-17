import AppKit

/// The menu bar menus while the window shows. Edit makes copy and paste work in the fields; the View
/// items do what their keys do, for a mouse, as MainView's keys take the keys first.
@MainActor
final class MainMenu: NSObject {
    private let model: WindowModel
    private let window: MainWindow

    init(model: WindowModel, window: MainWindow) {
        self.model = model
        self.window = window
    }

    func install() {
        let bar = NSMenu()
        bar.addItem(submenu(app))
        bar.addItem(submenu(file))
        bar.addItem(submenu(edit))
        bar.addItem(submenu(view))
        let windowMenu = self.windowMenu
        bar.addItem(submenu(windowMenu))
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windowMenu
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                      target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private var app: NSMenu {
        let menu = NSMenu(title: "Lord of the Claudes")
        menu.addItem(item("About Lord of the Claudes", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Hide Lord of the Claudes", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Lord of the Claudes", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private var file: NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Chat", #selector(newChat), target: self))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private var edit: NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private var view: NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Show or Hide Sidebar", #selector(toggleSidebar), "0", target: self))
        menu.addItem(item("Overseer Chat", #selector(showChat), "l", target: self))
        menu.addItem(item("Filter Sessions", #selector(filter), "f", target: self))
        menu.addItem(.separator())
        menu.addItem(item("Group by Topic", #selector(groupByTopic), target: self))
        menu.addItem(item("Group by Window", #selector(groupByWindow), target: self))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private var windowMenu: NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimise", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    @objc private func newChat() { model.chat.newChat() }
    @objc private func toggleSidebar() { model.toggleSidebar() }
    @objc private func showChat() { model.showChat() }
    @objc private func groupByTopic() { model.grouping = .topic }
    @objc private func groupByWindow() { model.grouping = .window }

    @objc private func filter() {
        model.revealSidebar()
        model.focusRequests.send(.filter)
    }
}
