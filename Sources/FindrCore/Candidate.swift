import Foundation

/// A file found by any search stage, before ranking.
public struct Candidate: Hashable, Sendable {
    public let path: String
    public let size: Int64?
    public let lastUsed: Date?
    public let added: Date?
    public let modified: Date?
    public let isDirectory: Bool

    public init(path: String, size: Int64? = nil, lastUsed: Date? = nil, added: Date? = nil,
                modified: Date? = nil, isDirectory: Bool = false) {
        self.path = path
        self.size = size
        self.lastUsed = lastUsed
        self.added = added
        self.modified = modified
        self.isDirectory = isDirectory
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var parent: String { (path as NSString).deletingLastPathComponent }
    public var kind: FileKind? { isDirectory ? nil : FileKind.of(path: path) }

    /// Newest of last opened, date added and modified.
    public var recency: Date {
        [lastUsed, added, modified].compactMap { $0 }.max() ?? .distantPast
    }

    public static func == (a: Candidate, b: Candidate) -> Bool { a.path == b.path }
    public func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

public enum Section: String, Sendable {
    case name, inside
}

/// One row in the results list.
public struct ResultItem: Identifiable, Equatable, Sendable {
    public var id: String { candidate.path }
    public let candidate: Candidate
    public let section: Section
    public let tier: MatchTier?
    public let pickCount: Int
    /// Paths of duplicates collapsed into this row.
    public var copies: [String]

    /// Why this row matched, e.g. "name", "name · typo", "inside".
    public var tag: String {
        switch section {
        case .name: return tier == .typo ? "name · typo" : "name"
        case .inside: return "inside"
        }
    }
}
