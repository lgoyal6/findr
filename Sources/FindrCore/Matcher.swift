import Foundation

/// How well a file name matches the query. Lower is better.
public enum MatchTier: Int, Comparable, Sendable {
    case exact, prefix, wordStart, contains, typo

    public static func < (a: MatchTier, b: MatchTier) -> Bool { a.rawValue < b.rawValue }
}

public enum Matcher {
    /// Tier for a file name against the query terms, or nil when it does not match.
    public static func tier(name: String, terms: [String]) -> MatchTier? {
        guard !terms.isEmpty else { return .wordStart }
        let stem = Self.stem(of: name)
        let lowerStem = stem.lowercased()
        let words = Self.words(in: stem)
        let squashed = String(lowerStem.filter { $0.isLetter || $0.isNumber })

        if terms.joined(separator: " ") == lowerStem || terms.joined() == squashed {
            return .exact
        }
        var worst = MatchTier.exact
        for term in terms {
            guard let t = termTier(term, stem: lowerStem, words: words, squashed: squashed) else { return nil }
            worst = max(worst, t)
        }
        return worst
    }

    static func termTier(_ term: String, stem: String, words: [String], squashed: String) -> MatchTier? {
        if stem.hasPrefix(term) { return .prefix }
        if words.contains(where: { $0.hasPrefix(term) }) { return .wordStart }
        if stem.contains(term) || squashed.contains(term) { return .contains }
        if term.count >= 5, words.contains(where: { isTypo(term, of: $0) }) { return .typo }
        return nil
    }

    /// File name without its extension. Folders and dotfiles keep their full name.
    public static func stem(of name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 6, !name.hasPrefix(".") else { return name }
        return (name as NSString).deletingPathExtension
    }

    /// Lowercased words, split on separators and camelCase: "Pace_ForwardDeck" -> pace, forward, deck.
    public static func words(in stem: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for ch in stem {
            if !(ch.isLetter || ch.isNumber) {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else if ch.isUppercase, let p = previous, p.isLowercase {
                if !current.isEmpty { result.append(current) }
                current = String(ch)
            } else {
                current.append(ch)
            }
            previous = ch
        }
        if !current.isEmpty { result.append(current) }
        return result.map { $0.lowercased() }
    }

    /// One typo allowed for short words, two for words of 8+ letters.
    /// Compares against the whole word and against prefixes of similar length.
    static func isTypo(_ term: String, of word: String) -> Bool {
        let allowed = term.count >= 8 ? 2 : 1
        let t = Array(term.unicodeScalars), w = Array(word.unicodeScalars)
        // A word much shorter than the term can't be within reach.
        guard w.count + allowed >= t.count else { return false }
        if w.count <= t.count + allowed, distance(t, w[...]) <= allowed { return true }
        for length in max(1, t.count - allowed)...(t.count + allowed) where length < w.count {
            if distance(t, w[0..<length]) <= allowed { return true }
        }
        return false
    }

    /// Optimal string alignment distance (Levenshtein plus adjacent swaps), three rolling rows.
    static func distance(_ a: [Unicode.Scalar], _ b: ArraySlice<Unicode.Scalar>) -> Int {
        let b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var before = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], before[j - 2] + 1)
                }
            }
            (before, previous, current) = (previous, current, before)
        }
        return previous[b.count]
    }

    /// Ranges of the name to highlight: every case-insensitive occurrence of each term.
    public static func highlights(in name: String, terms: [String]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var searchStart = name.startIndex
            while let r = name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: searchStart..<name.endIndex) {
                ranges.append(r)
                searchStart = r.upperBound
            }
        }
        return ranges
    }
}
