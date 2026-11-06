import Foundation

/// Files that run code when opened, and names built to look like something else.
public enum Runnable {
    static let apps: Set<String> = ["app", "prefpane", "saver", "appex"]
    static let scripts: Set<String> = ["command", "tool", "terminal", "sh", "zsh", "bash", "csh", "fish",
                                       "scpt", "scptd", "applescript", "workflow", "action", "jar"]
    static let installers: Set<String> = ["pkg", "mpkg"]

    /// Characters that reorder text on screen, used to make "invoice‮fdp.app" read as "invoiceppa.pdf".
    static let directionMarks: Set<Unicode.Scalar> = [
        "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]

    public static func hasDirectionMarks(_ name: String) -> Bool {
        name.unicodeScalars.contains { directionMarks.contains($0) }
    }

    /// The name with any reordering characters made visible as "?".
    public static func visibleName(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { directionMarks.contains($0) ? "?" : $0 }))
    }

    /// "app", "script", "installer" or "program" for files that run code, "odd name" for
    /// names that hide their real extension, nil for ordinary files.
    public static func label(name: String, isExecutableFile: Bool) -> String? {
        if hasDirectionMarks(name) { return "odd name" }
        let ext = (name as NSString).pathExtension.lowercased()
        if apps.contains(ext) { return "app" }
        if scripts.contains(ext) { return "script" }
        if installers.contains(ext) { return "installer" }
        if isExecutableFile { return "program" }
        return nil
    }

    public static func label(for candidate: Candidate) -> String? {
        let executable = !candidate.isDirectory && FileManager.default.isExecutableFile(atPath: candidate.path)
        return label(name: candidate.name, isExecutableFile: executable)
    }
}
