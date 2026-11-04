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
    /// Two files are copies when their cleaned names match and their sizes are equal,
    /// so "Lecture (1).pdf" and "Lecture (2).pdf" with different contents stay separate.
    /// Keeps the input order of the surviving rows.
    public static func collapse(_ items: [ResultItem]) -> [ResultItem] {
        var groups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() where !item.candidate.isDirectory {
            groups[key(for: item.candidate.name), default: []].append(index)
        }
        var absorbedInto: [Int: Int] = [:]
        for indices in groups.values where indices.count > 1 {
            var clusters: [[Int]] = []
            for index in indices {
                let c = items[index].candidate
                if let at = clusters.firstIndex(where: { cluster in
                    cluster.contains { other in
                        let o = items[other].candidate
                        return (c.size ?? 0) > 0 && c.size == o.size
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
