import AppKit
import CryptoKit
import SafariServices

enum BrowserExtensionSetup {
    static func installChromeHost() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let resources = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("LeafBrowserHost").path) else { return }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            resources.appendingPathComponent("BrowserExtension/manifest.json"))) as? [String: Any]
        guard let key = manifest?["key"] as? String, let data = Data(base64Encoded: key) else { return }
        let id = SHA256.hash(data: data).prefix(16).flatMap { byte in
            [Character(UnicodeScalar(97 + Int(byte >> 4))!), Character(UnicodeScalar(97 + Int(byte & 15))!)]
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host: [String: Any] = ["name": "io.github.lgoyal6.findr.browser",
            "description": "Leaf file upload picker", "type": "stdio",
            "path": resources.appendingPathComponent("LeafBrowserHost").path,
            "allowed_origins": ["chrome-extension://\(String(id))/"]]
        try JSONSerialization.data(withJSONObject: host, options: .prettyPrinted)
            .write(to: directory.appendingPathComponent("io.github.lgoyal6.findr.browser.json"), options: .atomic)
    }

    static func showChromeExtension() {
        guard let resources = Bundle.main.resourceURL,
              let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return }
        NSWorkspace.shared.open([URL(string: "chrome://extensions")!], withApplicationAt: chrome,
                               configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        NSWorkspace.shared.activateFileViewerSelecting([resources.appendingPathComponent("BrowserExtension")])
    }

    static func showSafariExtension() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: "io.github.lgoyal6.findr.safari") { _ in }
    }
}
