import FindrCore
import Foundation

struct SearchSnapshot {
    var query: ParsedQuery
    var output: Assembler.Output
    /// Shown above the results when Leaf changed what it searched for.
    var notice: String?
    var searching: Bool
}

/// Runs one search in stages, publishing after each so results appear fast:
/// 1. fresh folders on disk, 2. Spotlight by name and contents, 3. fallback scans.
enum SearchEngine {
    static let home = NSHomeDirectory()

    static func run(_ text: String, picks: [String: Int], skips: [String],
                    isCurrent: () -> Bool, publish: (SearchSnapshot) -> Void) {
        let parsed = QueryParser.parse(text)
        let assembler = Assembler(junk: JunkFilter(home: home, skips: skips), picks: picks)
        guard isCurrent() else { return }
        let fresh = DirectScan.fresh(home: home, isCurrent: isCurrent)
        guard isCurrent() else { return }

        publish(SearchSnapshot(query: parsed,
                               output: assembler.build(parsed, nameCandidates: fresh, contentCandidates: [], isCurrent: isCurrent),
                               notice: nil, searching: true))
        guard isCurrent() else { return }

        var effectiveQuery = parsed
        var result = spotlightStage(parsed, fresh: fresh, assembler: assembler, isCurrent: isCurrent)
        var notice: String?
        guard isCurrent() else { return }

        if result.output.isEmpty, parsed.hasFilters, !parsed.plainTerms.isEmpty {
            let plain = parsed.asPlain
            result = spotlightStage(plain, fresh: fresh, assembler: assembler, isCurrent: isCurrent)
            if !result.output.isEmpty {
                effectiveQuery = plain
                notice = "No \(parsed.filterLabel ?? "filtered") matches. Showing results for every word."
            }
        }
        guard isCurrent() else { return }

        if result.spotlightEmpty, result.output.isEmpty, !parsed.terms.isEmpty {
            publish(SearchSnapshot(query: parsed, output: result.output,
                                   notice: "Spotlight returned nothing. Searching your files directly…",
                                   searching: true))
            let junk = JunkFilter(home: home, skips: skips)
            let scanned = DirectScan.deep(home: home, terms: parsed.terms, junk: junk, isCurrent: isCurrent)
            guard isCurrent() else { return }
            result.output = assembler.build(parsed, nameCandidates: scanned, contentCandidates: [], isCurrent: isCurrent)
            notice = "Spotlight returned nothing, so these come from a direct scan of your files (names only)."
        }
        guard isCurrent() else { return }
        publish(SearchSnapshot(query: effectiveQuery, output: result.output, notice: notice, searching: false))
    }

    struct StageResult {
        var output: Assembler.Output
        var spotlightEmpty: Bool
    }

    static func spotlightStage(_ q: ParsedQuery, fresh: [Candidate], assembler: Assembler,
                               isCurrent: () -> Bool = { true }) -> StageResult {
        let scope = [q.folder.map { home + "/" + $0 } ?? home]
        var byName: [Candidate] = []
        var byContent: [Candidate] = []
        if let query = SpotlightQuery.name(q) {
            byName = Spotlight.run(query, scopes: scope, limit: 3000, isCurrent: isCurrent)
        }
        guard isCurrent() else { return StageResult(output: .init(name: [], inside: []), spotlightEmpty: true) }
        if let query = SpotlightQuery.content(q) {
            byContent = Spotlight.run(query, scopes: scope, limit: 1500, isCurrent: isCurrent)
        }
        guard isCurrent() else { return StageResult(output: .init(name: [], inside: []), spotlightEmpty: true) }

        var names = fresh + byName
        var output = assembler.build(q, nameCandidates: names, contentCandidates: byContent, isCurrent: isCurrent)
        // Few real name hits: widen the pool so near-miss spellings can match.
        if output.name.count < 10, let query = SpotlightQuery.typo(q) {
            names += Spotlight.run(query, scopes: scope, limit: 3000, isCurrent: isCurrent)
            output = assembler.build(q, nameCandidates: names, contentCandidates: byContent, isCurrent: isCurrent)
        }
        return StageResult(output: output, spotlightEmpty: byName.isEmpty && byContent.isEmpty)
    }
}
