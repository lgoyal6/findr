import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PanelController!
    private var hotKey: HotKey!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let settings = SettingsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        panel = PanelController(openSettings: { [weak self] in self?.showSettings() })
        hotKey = HotKey { [weak self] in self?.panel.toggle() }
        settings.registerHotKey = { [weak self] in self?.registerHotKey() ?? false }
        if !registerHotKey() {
            settings.hotKeyError = "\(Store.shared.hotKey.label) is taken by another app. Pick a new shortcut."
        }
        settings.applyAppearance()
        setUpStatusItem()
        requestFolderAccess()

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render"), index + 1 < arguments.count {
            let down = arguments.firstIndex(of: "--down").flatMap { Int(arguments[$0 + 1]) } ?? 0
            panel.renderOffscreen(query: arguments[index + 1], down: down,
                                  preview: arguments.contains("--preview")) { window in
                print("window \(window)")
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            }
        } else if let index = arguments.firstIndex(of: "--show") {
            panel.show(query: index + 1 < arguments.count ? arguments[index + 1] : nil)
        } else if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            panel.show()
        }
    }

    /// Spotlight silently leaves out files in Desktop, Documents and Downloads until the
    /// app has access, and macOS only asks when the app reads a folder itself. Reading
    /// each one at launch makes macOS ask once, instead of results quietly going missing.
    private func requestFolderAccess() {
        DispatchQueue.global(qos: .utility).async {
            for folder in ["Downloads", "Desktop", "Documents"] {
                _ = try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/" + folder)
            }
        }
    }

    @discardableResult
    private func registerHotKey() -> Bool {
        let key = Store.shared.hotKey
        let ok = hotKey.register(code: key.code, modifiers: key.modifiers)
        statusItem?.menu?.item(at: 0)?.title = "Open findr  \(key.label)"
        return ok
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "findr")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open findr  \(Store.shared.hotKey.label)", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit findr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
    }

    @objc private func togglePanel() {
        panel.toggle()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "findr Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: settings))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Menu-bar apps have no visible menu, but text editing shortcuts
    /// (paste, select all, undo) only work when an Edit menu exists.
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
