import Foundation

/// Turns raw candidates into the two ranked sections.
public struct Assembler: Sendable {
    public let junk: JunkFilter
    /// Path -> how many times it was opened for this exact query.
    public let picks: [String: Int]

    public init(junk: JunkFilter, picks: [String: Int] = [:]) {
        self.junk = junk
        self.picks = picks
    }

    public struct Output: Equatable, Sendable {
        public var name: [ResultItem]
        public var inside: [ResultItem]
        public var isEmpty: Bool { name.isEmpty && inside.isEmpty }

        public init(name: [ResultItem], inside: [ResultItem]) {
            self.name = name
            self.inside = inside
        }
    }

    /// - Parameters:
    ///   - nameCandidates: files found by name (Spotlight, fresh scan, fallback scan, typo pool).
    ///   - contentCandidates: files Spotlight says contain the terms.
    public func build(_ q: ParsedQuery, nameCandidates: [Candidate], contentCandidates: [Candidate],
                      isCurrent: () -> Bool = { true }) -> Output {
        var seen = Set<String>()
        var name: [ResultItem] = []
        for c in nameCandidates where !seen.contains(c.path) && passes(c, q) {
            guard isCurrent() else { return Output(name: [], inside: []) }
            guard let tier = Matcher.tier(name: c.name, terms: q.terms) else { continue }
            seen.insert(c.path)
            name.append(ResultItem(candidate: c, section: .name, tier: tier,
                                   pickCount: picks[c.path] ?? 0, copies: []))
        }
        var inside: [ResultItem] = []
        for c in contentCandidates where seen.insert(c.path).inserted && passes(c, q) {
            guard isCurrent() else { return Output(name: [], inside: []) }
            inside.append(ResultItem(candidate: c, section: .inside, tier: nil,
                                     pickCount: picks[c.path] ?? 0, copies: []))
        }
        let codeWanted = q.kinds.contains(.code)
        return Output(name: Dedupe.collapse(rank(name, codeWanted: codeWanted), isCurrent: isCurrent),
                      inside: Dedupe.collapse(rank(inside, codeWanted: codeWanted), isCurrent: isCurrent))
    }

    func passes(_ c: Candidate, _ q: ParsedQuery) -> Bool {
        if junk.isJunk(c.path) { return false }
        if !q.kinds.isEmpty {
            guard let kind = c.kind, q.kinds.contains(kind) else { return false }
        }
        if let date = q.date, !date.contains(c.recency) { return false }
        if let folder = q.folder {
            let root = junk.home + "/" + folder
            guard c.path.hasPrefix(root + "/") else { return false }
        }
        return true
    }

    /// Match tier, then non-code before code (unless code was asked for),
    /// then how often it was picked, then most recent first. Typos always sit last.
    /// Starts-with and word-start rank as one tier, so "pacer.go" can't push
    /// "Laksh_Goyal_Pace.pdf" down just by starting with the word.
    func rank(_ items: [ResultItem], codeWanted: Bool) -> [ResultItem] {
        func order(_ tier: MatchTier?) -> Int {
            guard let tier else { return 0 }
            return tier == .prefix ? MatchTier.wordStart.rawValue : tier.rawValue
        }
        return items.sorted { a, b in
            let ta = order(a.tier), tb = order(b.tier)
            if ta != tb { return ta < tb }
            if !codeWanted {
                let ca = a.candidate.kind == .code, cb = b.candidate.kind == .code
                if ca != cb { return !ca }
            }
            if a.pickCount != b.pickCount { return a.pickCount > b.pickCount }
            if a.candidate.recency != b.candidate.recency { return a.candidate.recency > b.candidate.recency }
            return a.candidate.path < b.candidate.path
        }
    }
}
