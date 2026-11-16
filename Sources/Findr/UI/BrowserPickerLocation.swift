import AppKit

enum BrowserPickerLocation: Hashable {
    case folder(URL)
    case recents
    case shared
    case tag(String)
    case allTags

    var folder: URL? {
        if case .folder(let url) = self { return url }
        return nil
    }

    var title: String {
        switch self {
        case .folder(let url): return FileManager.default.displayName(atPath: url.path)
        case .recents: return "Recents"
        case .shared: return "Shared"
        case .tag(let name): return name
        case .allTags: return "All Tags"
        }
    }

    var predicate: NSPredicate? {
        switch self {
        case .folder: return nil
        case .recents:
            return NSPredicate(format: "kMDItemContentTypeTree == %@ AND kMDItemLastUsedDate >= %@",
                               "public.content", Date(timeIntervalSince1970: 0) as NSDate)
        case .shared:
            return NSPredicate(format: "%K == YES", NSMetadataUbiquitousItemIsSharedKey)
        case .tag(let name):
            return NSPredicate(format: "ANY kMDItemUserTags == %@", name)
        case .allTags:
            return NSPredicate(format: "kMDItemUserTags != nil")
        }
    }
}

struct BrowserSidebarItem: Identifiable {
    let title: String
    let icon: String
    let location: BrowserPickerLocation
    var id: BrowserPickerLocation { location }
}

struct BrowserSidebarSection: Identifiable {
    let title: String
    let items: [BrowserSidebarItem]
    var id: String { title }

    static func available(manager: FileManager = .default, home: URL? = nil) -> [Self] {
        let home = home ?? manager.homeDirectoryForCurrentUser
        func folder(_ title: String, _ icon: String, _ url: URL) -> BrowserSidebarItem {
            BrowserSidebarItem(title: title, icon: icon, location: .folder(url))
        }
        var sections = [Self(title: "", items: [
            BrowserSidebarItem(title: "Recents", icon: "clock", location: .recents),
            BrowserSidebarItem(title: "Shared", icon: "person.2", location: .shared)
        ]), Self(title: "Favorites", items: [
            folder("Applications", "square.stack.3d.up", URL(fileURLWithPath: "/Applications", isDirectory: true)),
            folder("Downloads", "arrow.down.circle", home.appendingPathComponent("Downloads")),
            folder("Desktop", "desktopcomputer", home.appendingPathComponent("Desktop")),
            folder("Documents", "doc", home.appendingPathComponent("Documents"))
        ])]
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var cloud: [BrowserSidebarItem] = []
        if manager.fileExists(atPath: iCloud.path) { cloud.append(folder("iCloud Drive", "icloud", iCloud)) }
        let providers = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        for url in (try? manager.contentsOfDirectory(at: providers,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [] {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                cloud.append(folder(manager.displayName(atPath: url.path), "cloud", url))
            }
        }
        if !cloud.isEmpty { sections.append(Self(title: "iCloud & Cloud Storage", items: cloud)) }
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        var locations = [folder(manager.displayName(atPath: root.path), "internaldrive", root),
                         folder(home.lastPathComponent, "house", home)]
        let volumes = manager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey],
                                               options: .skipHiddenVolumes) ?? []
        for url in volumes where url.path != "/" {
            if (try? url.resourceValues(forKeys: [.volumeIsBrowsableKey]).volumeIsBrowsable) != false {
                locations.append(folder(manager.displayName(atPath: url.path), "externaldrive", url))
            }
        }
        sections.append(Self(title: "Locations", items: locations))
        let defaults = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
        let names = UserDefaults(suiteName: "com.apple.finder")?.stringArray(forKey: "FavoriteTagNames")
            .map { $0.filter { !$0.isEmpty } } ?? defaults
        var tags = names.map { BrowserSidebarItem(title: $0, icon: "circle.fill", location: .tag($0)) }
        tags.append(BrowserSidebarItem(title: "All Tags…", icon: "tag", location: .allTags))
        sections.append(Self(title: "Tags", items: tags))
        return sections
    }
}
