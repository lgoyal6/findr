import Foundation

/// Builds Spotlight query strings (the same language `mdfind` takes).
public enum SpotlightQuery {
    /// Files whose name contains every term, narrowed by kind and date.
    /// Nil when there is nothing to search for.
    public static func name(_ q: ParsedQuery) -> String? {
        var clauses = q.terms.map { #"kMDItemFSName == "*\#($0)*"cd"# }
        if let kinds = kindClause(q.kinds) { clauses.append(kinds) }
        if let date = dateClause(q.date) { clauses.append(date) }
        if clauses.isEmpty {
            guard q.folder != nil else { return nil }
            clauses.append(#"kMDItemFSName == "*""#)
        }
        return clauses.joined(separator: " && ")
    }

    /// Loose name query that pulls in candidates for typo matching: names containing
    /// the start or end of any term of 5+ letters (4 letters for long terms, 3 for short).
    public static func typo(_ q: ParsedQuery) -> String? {
        var chunks: [String] = []
        for term in q.terms where term.count >= 5 {
            let size = term.count >= 7 ? 4 : 3
            chunks.append(String(term.prefix(size)))
            chunks.append(String(term.suffix(size)))
        }
        guard !chunks.isEmpty else { return nil }
        let any = Array(Set(chunks)).sorted().map { #"kMDItemFSName == "*\#($0)*"cd"# }
        var clauses = ["(" + any.joined(separator: " || ") + ")"]
        if let kinds = kindClause(q.kinds) { clauses.append(kinds) }
        return clauses.joined(separator: " && ")
    }

    /// Files whose text contains a word starting with every term.
    public static func content(_ q: ParsedQuery) -> String? {
        guard !q.terms.isEmpty else { return nil }
        var clauses = q.terms.map { #"kMDItemTextContent == "\#($0)*"cdw"# }
        if let kinds = kindClause(q.kinds) { clauses.append(kinds) }
        if let date = dateClause(q.date) { clauses.append(date) }
        return clauses.joined(separator: " && ")
    }

    static func kindClause(_ kinds: Set<FileKind>) -> String? {
        let exts = kinds.flatMap(\.extensions).sorted()
        guard !exts.isEmpty else { return nil }
        return "(" + exts.map { #"kMDItemFSName == "*.\#($0)"c"# }.joined(separator: " || ") + ")"
    }

    /// Lower bound only; the exact range is checked after the query returns.
    static func dateClause(_ range: DateRange?) -> String? {
        guard let range else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let start = formatter.string(from: range.start)
        let fields = ["kMDItemLastUsedDate", "kMDItemDateAdded", "kMDItemContentModificationDate"]
        return "(" + fields.map { "\($0) >= $time.iso(\(start))" }.joined(separator: " || ") + ")"
    }
}
