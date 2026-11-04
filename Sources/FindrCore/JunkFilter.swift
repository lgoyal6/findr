import Foundation

/// Decides which paths never show up: hidden folders, Library, dependency
/// folders, the insides of app bundles, and folders the user chose to skip.
public struct JunkFilter: Sendable {
    public let home: String
    public let skips: [String]

    static let junkNames: Set<String> = [
        "node_modules", "__pycache__", "site-packages", "Pods", "DerivedData", "Caches",
        "bower_components", "venv",
    ]
    static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "photoslibrary", "xcodeproj", "xcworkspace", "xcassets",
        "musiclibrary", "tvlibrary", "plugin", "kext", "appex", "sparsebundle", "pkg",
    ]

    public init(home: String, skips: [String] = []) {
        self.home = home
        self.skips = skips
    }

    public func isJunk(_ path: String) -> Bool {
        for skip in skips where path == skip || path.hasPrefix(skip + "/") {
            return true
        }
        guard path.hasPrefix(home + "/") else { return false }
        let components = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        if components.first == "Library" { return true }
        for (index, component) in components.enumerated() {
            if component.hasPrefix(".") || Self.junkNames.contains(component) { return true }
            // Go module cache: ~/go/pkg/mod
            if component == "mod", index > 0, components[index - 1] == "pkg" { return true }
            let isLast = index == components.count - 1
            if !isLast, Self.bundleExtensions.contains((component as NSString).pathExtension.lowercased()) {
                return true
            }
        }
        return false
    }
}
