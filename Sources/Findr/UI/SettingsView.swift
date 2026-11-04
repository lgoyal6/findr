import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var hotKeyLabel = Store.shared.hotKey.label
    @Published private(set) var recording = false
    @Published var hotKeyError: String?
    @Published private(set) var skipFolders = Store.shared.skipFolders
    @Published var appearance = Store.shared.appearance {
        didSet {
            Store.shared.appearance = appearance
            applyAppearance()
        }
    }
    @Published var launchError: String?

    /// Re-registers the global shortcut; returns false if macOS refused it.
    var registerHotKey: () -> Bool = { true }
    private var monitor: Any?
    private weak var recordingWindow: NSWindow?

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchError = nil
            } catch {
                launchError = "macOS said no: \(error.localizedDescription). Move findr to Applications and try again."
            }
            objectWillChange.send()
        }
    }

    func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Captures the next key press with a modifier as the new shortcut. Esc cancels.
    func startRecording() {
        guard !recording else { return }
        recording = true
        recordingWindow = NSApp?.keyWindow
        hotKeyError = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.recording, let window = self.recordingWindow,
                  event.window === window else { return event }
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else {
                self.hotKeyError = "Include ⌘, ⌥ or ⌃ so the shortcut doesn't fire while you type."
                return nil
            }
            let previous = Store.shared.hotKey
            Store.shared.hotKey = (UInt32(event.keyCode), HotKey.carbonModifiers(flags), HotKey.label(for: event))
            if self.registerHotKey() {
                self.hotKeyLabel = Store.shared.hotKey.label
            } else {
                Store.shared.hotKey = previous
                _ = self.registerHotKey()
                self.hotKeyError = "macOS refused that shortcut. Try another."
            }
            self.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingWindow = nil
    }

    func addSkipFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Skip"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.path).filter { !skipFolders.contains($0) }
        skipFolders += added
        Store.shared.skipFolders = skipFolders
    }

    func removeSkipFolder(_ path: String) {
        skipFolders.removeAll { $0 == path }
        Store.shared.skipFolders = skipFolders
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Shortcut") {
                HStack {
                    Text("Open findr")
                    Spacer()
                    Text(model.recording ? "Press keys…" : model.hotKeyLabel)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    Button(model.recording ? "Cancel" : "Change") {
                        model.recording ? model.stopRecording() : model.startRecording()
                    }
                }
                if let error = model.hotKeyError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                if model.skipFolders.isEmpty {
                    Text("None yet. Hidden folders, Library and node_modules are always skipped.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.skipFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            model.removeSkipFolder(path)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add folder…") { model.addSkipFolder() }
            } header: {
                Text("Folders to skip")
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                        set: { model.launchAtLogin = $0 }))
                if let error = model.launchError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Picker("Appearance", selection: $model.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 460)
        .onDisappear { model.stopRecording() }
    }
}
