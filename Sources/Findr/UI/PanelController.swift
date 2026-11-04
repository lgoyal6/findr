import AppKit
import Combine
import SwiftUI

/// A panel that can take keyboard focus without activating the app, so the app
/// you were in stays frontmost, like Spotlight.
final class SearchPanel: NSPanel {
    /// Off for screenshot renders, so they never take keystrokes meant for another app.
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model = SearchModel()
    private let panel: SearchPanel
    private var monitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let openSettings: () -> Void

    static let width: CGFloat = 780
    static let previewWidth: CGFloat = 440
    static let height: CGFloat = 540

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            panel.standardWindowButton($0)?.isHidden = true
        }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        let host = NSHostingView(rootView: SearchView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background

        model.onDismiss = { [weak self] in self?.hide() }
        // @Published fires before the value changes; resizing then (with its animation loop)
        // made SwiftUI miss the update and the preview pane never appeared. Wait a turn.
        model.$previewOpen
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] open in self?.resize(previewOpen: open) }
            .store(in: &cancellables)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show(query: String? = nil) {
        model.reset()
        if let query { model.text = query }
        place(width: Self.width)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        model.cancelSearch()
        model.previewOpen = false
        panel.orderOut(nil)
    }

    /// Draws the panel off-screen without taking keyboard focus, for screenshots
    /// (`Leaf --render "pace pdf" --down 2 --preview`). Calls back with the window number.
    func renderOffscreen(query: String, down: Int, preview: Bool, done: @escaping (Int) -> Void) {
        panel.allowsKey = false
        model.reset()
        model.text = query
        let width = Self.width + (preview ? Self.previewWidth : 0)
        panel.setFrame(NSRect(x: -6000, y: 200, width: width, height: Self.height), display: true)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            for _ in 0..<down { model.moveDown() }
            model.previewOpen = preview
            panel.setFrame(NSRect(x: -6000, y: 200, width: width, height: Self.height), display: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
                done(panel.windowNumber)
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    /// Top third of the screen the mouse is on.
    private func place(width: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - width / 2
        let y = visible.maxY - visible.height * 0.16 - Self.height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: Self.height), display: true)
    }

    /// Widens the panel around its centre when the preview opens.
    private func resize(previewOpen: Bool) {
        guard panel.isVisible else { return }
        let width = Self.width + (previewOpen ? Self.previewWidth : 0)
        var frame = panel.frame
        frame.origin.x = frame.midX - width / 2
        frame.size.width = width
        panel.setFrame(frame, display: true, animate: true)
    }

    /// Keyboard handling. Returns true when the key was used here and should not reach the text field.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        switch event.keyCode {
        case 53: // Esc
            if model.previewOpen { model.previewOpen = false }
            else if model.expandedSection != nil { model.showOverview() }
            else { hide() }
            return true
        case 125: // Down
            model.moveDown()
            return true
        case 126: // Up
            model.moveUp()
            return true
        case 36, 76: // Return, Enter
            command ? model.reveal() : model.open()
            return true
        case 49 where model.listFocused && !command: // Space previews only inside the list
            model.previewOpen.toggle()
            return true
        case 16 where command: // Cmd-Y
            if model.selectedItem != nil { model.previewOpen.toggle() }
            return true
        case 8 where command && shift: // Cmd-Shift-C
            model.copyPath()
            return true
        case 8 where command && model.listFocused: // Cmd-C on a highlighted result
            model.copyFile()
            return true
        case 31 where command: // Cmd-O
            showOpenWith()
            return true
        case 43 where command: // Cmd-,
            hide()
            openSettings()
            return true
        default:
            // Typing while in the list hands control back to the search bar.
            if model.listFocused, !command, !(event.characters ?? "").isEmpty {
                model.listFocused = false
            }
            return false
        }
    }

    private func showOpenWith() {
        let apps = model.appsForSelected()
        guard !apps.isEmpty, let content = panel.contentView else { return }
        let menu = NSMenu()
        for app in apps {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path),
                                  action: #selector(openWith(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        let point = NSPoint(x: Self.width / 2 - 100, y: content.bounds.height / 2)
        menu.popUp(positioning: nil, at: point, in: content)
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        model.open(with: app)
    }
}
