import FindrCore
import Foundation

/// Reads folders straight from disk, for files Spotlight has not indexed yet
/// and for when Spotlight returns nothing at all.
enum DirectScan {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey, .isPackageKey,
    ]

    /// Top level of Downloads, Desktop and home. Cheap enough to run on every keystroke.
    static func fresh(home: String) -> [Candidate] {
        let folders = [home + "/Downloads", home + "/Desktop", home]
        var results: [Candidate] = []
        for folder in folders {
            let url = URL(fileURLWithPath: folder)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            results += urls.map(candidate)
        }
        return results
    }

    /// Walks the home folder matching names, skipping junk, until the deadline.
    static func deep(home: String, terms: [String], junk: JunkFilter, deadline: TimeInterval = 4) -> [Candidate] {
        let stop = Date().addingTimeInterval(deadline)
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: home), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var results: [Candidate] = []
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited % 500 == 0, Date() > stop { break }
            if junk.isJunk(url.path) {
                walker.skipDescendants()
                continue
            }
            if Matcher.tier(name: url.lastPathComponent, terms: terms) != nil {
                results.append(candidate(url))
                if results.count >= 2000 { break }
            }
        }
        return results
    }

    static func candidate(_ url: URL) -> Candidate {
        let values = try? url.resourceValues(forKeys: Set(keys))
        let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
        return Candidate(
            path: url.path,
            size: values?.fileSize.map(Int64.init),
            added: values?.addedToDirectoryDate,
            modified: values?.contentModificationDate,
            isDirectory: isDirectory
        )
    }
}
