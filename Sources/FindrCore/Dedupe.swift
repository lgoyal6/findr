import Foundation

public enum Dedupe {
    /// Name with copy markers removed: "DS3 (1).pdf" and "(Copy) DS3.pdf" both become "ds3.pdf".
    public static func key(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        var stem = Matcher.stem(of: name).lowercased()
        let patterns = [#"\s*\(\d+\)$"#, #"^\(copy\)\s*"#, #"\s+copy(\s+\d+)?$"#, #"^copy of\s+"#]
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                let next = stem.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                if next != stem, !next.isEmpty {
                    stem = next
                    changed = true
                }
            }
        }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// Collapses copies of the same file into one row, keeping the most recent.
    /// Size is only a prefilter. Unverified, large or unreadable files stay visible.
    /// Keeps the input order of the surviving rows.
    public static func collapse(_ items: [ResultItem], isCurrent: () -> Bool = { true }) -> [ResultItem] {
        var groups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() where !item.candidate.isDirectory {
            groups[key(for: item.candidate.name), default: []].append(index)
        }
        var absorbedInto: [Int: Int] = [:]
        // Bound disk work per search; never hide a file just to stay within the budget.
        var bytesRemaining: Int64 = 32 << 20
        for indices in groups.values where indices.count > 1 {
            guard isCurrent() else { return items }
            var clusters: [[Int]] = []
            for index in indices {
                let c = items[index].candidate
                if let at = clusters.firstIndex(where: { cluster in
                    cluster.contains { other in
                        let o = items[other].candidate
                        guard isCurrent(), let size = c.size, size > 0, size <= 8 << 20,
                              size == o.size, size * 2 <= bytesRemaining else { return false }
                        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                        let first = try? URL(fileURLWithPath: c.path).resourceValues(forKeys: keys)
                        let second = try? URL(fileURLWithPath: o.path).resourceValues(forKeys: keys)
                        guard first?.isRegularFile == true, second?.isRegularFile == true,
                              first?.isSymbolicLink != true, second?.isSymbolicLink != true,
                              first?.fileSize == Int(size), second?.fileSize == Int(size) else { return false }
                        bytesRemaining -= size * 2
                        return FileManager.default.contentsEqual(atPath: c.path, andPath: o.path) && isCurrent()
                    }
                }) {
                    clusters[at].append(index)
                } else {
                    clusters.append([index])
                }
            }
            for cluster in clusters where cluster.count > 1 {
                let keeper = cluster.max { a, b in
                    (items[a].candidate.recency, -a) < (items[b].candidate.recency, -b)
                }!
                for index in cluster where index != keeper {
                    absorbedInto[index] = keeper
                }
            }
        }
        var result = items
        for (index, keeper) in absorbedInto {
            result[keeper].copies.append(items[index].candidate.path)
        }
        return result.enumerated().filter { absorbedInto[$0.offset] == nil }.map(\.element)
    }
}
