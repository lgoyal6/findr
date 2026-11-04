import Foundation

/// Picks, search history and settings. Picks and history live in
/// ~/Library/Application Support/findr/state.json; settings in UserDefaults.
final class Store {
    static let shared = Store()

    private struct State: Codable {
        /// Normalised query -> path -> times opened.
        var picks: [String: [String: Int]] = [:]
        /// Most recent first.
        var history: [String] = []
    }

    private var state = State()
    private let file: URL
    private let defaults = UserDefaults.standard

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("findr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: file), let loaded = try? JSONDecoder().decode(State.self, from: data) {
            state = loaded
        }
    }

    static func normalise(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func picks(for text: String) -> [String: Int] {
        state.picks[Self.normalise(text)] ?? [:]
    }

    func recordPick(query: String, path: String) {
        let key = Self.normalise(query)
        guard !key.isEmpty else { return }
        state.picks[key, default: [:]][path, default: 0] += 1
        addHistory(query)
    }

    var history: [String] { state.history }

    func addHistory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        state.history.removeAll { Self.normalise($0) == Self.normalise(trimmed) }
        state.history.insert(trimmed, at: 0)
        state.history = Array(state.history.prefix(50))
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: Settings

    /// Carbon key code and modifier mask. Defaults to Cmd-Shift-Space.
    var hotKey: (code: UInt32, modifiers: UInt32, label: String) {
        get {
            guard defaults.object(forKey: "hotKeyCode") != nil else { return (49, 768, "⌘⇧Space") }
            return (UInt32(defaults.integer(forKey: "hotKeyCode")),
                    UInt32(defaults.integer(forKey: "hotKeyModifiers")),
                    defaults.string(forKey: "hotKeyLabel") ?? "")
        }
        set {
            defaults.set(Int(newValue.code), forKey: "hotKeyCode")
            defaults.set(Int(newValue.modifiers), forKey: "hotKeyModifiers")
            defaults.set(newValue.label, forKey: "hotKeyLabel")
        }
    }

    var skipFolders: [String] {
        get { defaults.stringArray(forKey: "skipFolders") ?? [] }
        set { defaults.set(newValue, forKey: "skipFolders") }
    }

    /// "system", "light" or "dark".
    var appearance: String {
        get { defaults.string(forKey: "appearance") ?? "system" }
        set { defaults.set(newValue, forKey: "appearance") }
    }
}
