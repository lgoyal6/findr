import AppKit
import ApplicationServices

struct UploadDialog: Equatable {
    let application: NSRunningApplication
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.application.processIdentifier == rhs.application.processIdentifier && CFEqual(lhs.element, rhs.element)
    }
}

/// Watches the frontmost application's native Open panel. AX work stays off the UI thread.
@MainActor
final class UploadDialogs {
    var onChange: (UploadDialog?) -> Void = { _ in }
    var onPermissionChange: (Bool) -> Void = { _ in }
    private let queue = DispatchQueue(label: "Leaf.upload-dialogs", qos: .userInitiated)
    private var timer: Timer?
    private var scanning = false
    private var scanAgain = false
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var activationObserver: NSObjectProtocol?
    private var choosing = false
    private var current: UploadDialog?
    private var trusted = AXIsProcessTrusted()

    deinit {
        timer?.invalidate()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func start() {
        guard timer == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        observe(nil)
    }

    private func observe(_ app: NSRunningApplication?) {
        let pid = app?.processIdentifier
        guard observedPID != pid else { return }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedPID = pid
        guard let pid else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var observer: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<UploadDialogs>.fromOpaque(context).takeUnretainedValue().poll()
                }
            }, &observer) == .success, let observer else { return }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.2)
            let context = Unmanaged.passUnretained(self).toOpaque()
            for notification in [kAXSheetCreatedNotification, kAXWindowCreatedNotification,
                                 kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification] {
                _ = AXObserverAddNotification(observer, application, notification as CFString, context)
            }
            Task { @MainActor in
                guard self.timer != nil, self.observedPID == pid else { return }
                self.observer = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
    }

    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func poll() {
        guard timer != nil else { return }
        let allowed = AXIsProcessTrusted()
        if trusted != allowed {
            trusted = allowed
            onPermissionChange(allowed)
        }
        guard !choosing else { return }
        if scanning {
            scanAgain = true
            return
        }
        guard allowed, Store.shared.useUploadDialogs else {
            observe(nil)
            update(nil)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        observe(app)
        scanning = true
        queue.async { [weak self] in
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.2)
            let panel = DialogAccessibility.openPanel(in: application)
            Task { @MainActor in
                guard let self else { return }
                self.scanning = false
                defer {
                    if self.scanAgain {
                        self.scanAgain = false
                        self.poll()
                    }
                }
                guard self.timer != nil, !self.choosing,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                guard AXIsProcessTrusted(), Store.shared.useUploadDialogs else {
                    self.update(nil)
                    return
                }
                self.update(panel.map { UploadDialog(application: app, element: $0) })
            }
        }
    }

    private func update(_ dialog: UploadDialog?) {
        guard current != dialog else { return }
        current = dialog
        onChange(dialog)
    }

    func choose(_ url: URL, in dialog: UploadDialog, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !choosing else { return }
        choosing = true
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            NSApp.yieldActivation(to: dialog.application)
            dialog.application.activate(options: [])
        }
        queue.async { [weak self] in
            let result = Result { try DialogAccessibility.choose(url, in: dialog) }
            Task { @MainActor in
                self?.choosing = false
                completion(result)
            }
        }
    }
}

private enum DialogAccessibility {
    struct SelectionError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    static func identifier(_ element: AXUIElement) -> String? {
        value(element, kAXIdentifierAttribute) as? String
    }

    /// Inspect windows and sheets, without walking browser page contents or file listings.
    static func openPanel(in application: AXUIElement) -> AXUIElement? {
        var windows = elements(application, kAXWindowsAttribute)
        if let focused = value(application, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            windows.insert(focused as! AXUIElement, at: 0)
        }
        for window in windows {
            if identifier(window) == "open-panel" { return window }
            for sheet in elements(window, "AXSheets") + elements(window, kAXChildrenAttribute) {
                if identifier(sheet) == "open-panel" { return sheet }
                for nested in elements(sheet, "AXSheets") where identifier(nested) == "open-panel" {
                    return nested
                }
            }
        }
        return nil
    }

    static func find(_ root: AXUIElement, matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var pending = [root]
        var visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while visited < pending.count, visited < 300, ProcessInfo.processInfo.systemUptime < deadline {
            let element = pending[visited]
            visited += 1
            if predicate(element) { return element }
            let role = value(element, kAXRoleAttribute) as? String
            if role == kAXOutlineRole || role == "AXWebArea" { continue }
            pending.append(contentsOf: elements(element, "AXSheets"))
            pending.append(contentsOf: elements(element, kAXChildrenAttribute))
        }
        return nil
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.timestamp = DispatchTime.now().uptimeNanoseconds
            event?.post(tap: .cghidEventTap)
        }
    }

    static func automationKey(_ code: CGKeyCode, commandShift: Bool = false, dialog: UploadDialog) throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        guard AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true) == noErr else {
            throw SelectionError("Allow Leaf to control System Events in System Settings → Privacy & Security → Automation, then try again.")
        }
        DispatchQueue.main.sync {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != dialog.application.processIdentifier {
                NSApp.yieldActivation(to: dialog.application)
                dialog.application.activate(options: [])
            }
        }
        for _ in 0..<10 where NSWorkspace.shared.frontmostApplication?.processIdentifier != dialog.application.processIdentifier {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try validate(dialog, enteringPath: true)
        try DispatchQueue.main.sync {
            let modifiers = commandShift ? " using {command down, shift down}" : ""
            guard let script = NSAppleScript(source: "tell application \"System Events\" to key code \(code)\(modifiers)") else {
                throw SelectionError("Leaf couldn’t prepare the file-dialog shortcut. Try again.")
            }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if error != nil { throw SelectionError("Leaf couldn’t send the file-dialog shortcut through System Events. Try again.") }
        }
    }

    static func validate(_ dialog: UploadDialog, enteringPath: Bool = false) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == dialog.application.processIdentifier else {
            throw SelectionError("The active app changed. Return to the upload dialog and try again.")
        }
        var panelID = identifier(dialog.element)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        while enteringPath, panelID == nil, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            panelID = identifier(dialog.element)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == dialog.application.processIdentifier,
              AXIsProcessTrusted(), !dialog.application.isTerminated,
              panelID == "open-panel" || (enteringPath && panelID == "GoToWindow") else {
            throw SelectionError("The file dialog changed or closed. Open the upload dialog and try again.")
        }
    }

    static func pathField(in dialog: UploadDialog, application: AXUIElement,
                          timeout: TimeInterval = 2) throws -> AXUIElement? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            try validate(dialog, enteringPath: true)
            if let focused = value(application, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(),
               identifier(focused as! AXUIElement) == "PathTextField" {
                return (focused as! AXUIElement)
            }
            for window in [dialog.element] + elements(application, kAXWindowsAttribute) {
                if let field = find(window, matching: { identifier($0) == "PathTextField" }) { return field }
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }

    static func choose(_ url: URL, in dialog: UploadDialog) throws {
        var directory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              !directory.boolValue, FileManager.default.isReadableFile(atPath: url.path) else {
            throw SelectionError("That file is unavailable. Choose a readable file and try again.")
        }
        let pid = dialog.application.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        // macOS returns keyboard focus after the nonactivating panel has ordered out.
        Thread.sleep(forTimeInterval: 0.1)
        for _ in 0..<10 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try validate(dialog)
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        var usesAutomation = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, false) == noErr
        if usesAutomation { try automationKey(5, commandShift: true, dialog: dialog) }
        else { key(5, flags: [.maskCommand, .maskShift]) }

        var field = try pathField(in: dialog, application: application, timeout: 0.35)
        if field == nil {
            usesAutomation = true
            try automationKey(5, commandShift: true, dialog: dialog)
            field = try pathField(in: dialog, application: application)
        }
        try validate(dialog, enteringPath: true)
        guard let field,
              AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, url.path as CFString) == .success else {
            throw SelectionError("Leaf couldn’t enter the file path in this dialog. You can drag the result into the dialog.")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw SelectionError("The active app changed. Return to the upload dialog and try again.")
        }
        if usesAutomation {
            // Notify the dialog's field editor after setting its Accessibility value.
            try automationKey(124, dialog: dialog)
            try automationKey(49, dialog: dialog)
            try automationKey(51, dialog: dialog)
        }
        if usesAutomation { try automationKey(36, dialog: dialog) }
        else {
            Thread.sleep(forTimeInterval: 0.2)
            key(36)
        }

        let selectionDeadline = ProcessInfo.processInfo.systemUptime + 2.5
        repeat {
            // The Open panel briefly stops answering AX while the path sheet closes.
            Thread.sleep(forTimeInterval: 0.02)
            guard identifier(dialog.element) != nil else { continue }
            try validate(dialog, enteringPath: true)
            guard let list = find(dialog.element, matching: { identifier($0) == "ListView" }) else { continue }
            let selected = elements(list, kAXSelectedRowsAttribute)
            let selectedFile = selected.contains { row in
                find(row) { element in
                    guard let file = value(element, kAXURLAttribute) else { return false }
                    let path = (file as? URL) ?? (file as? String).flatMap(URL.init(string:))
                    return path?.resolvingSymlinksInPath().standardizedFileURL.path ==
                        url.resolvingSymlinksInPath().standardizedFileURL.path
                } != nil
            }
            guard selectedFile,
                  let button = find(dialog.element, matching: { identifier($0) == "OKButton" }),
                  value(button, kAXEnabledAttribute) as? Bool == true else { continue }
            try validate(dialog)
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { break }
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.1)
                if identifier(dialog.element) != "open-panel" { return }
            }
            throw SelectionError("The dialog is still open. Check its selection or file-type restrictions.")
        } while ProcessInfo.processInfo.systemUptime < selectionDeadline
        throw SelectionError("This dialog couldn’t select that file. Check its file-type restrictions or drag in the result.")
    }
}
