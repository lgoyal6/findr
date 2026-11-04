import XCTest
@testable import FindrCore

final class QueryParserTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-04T02:00:00Z")!
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    func testTypeWordBecomesFilter() {
        let q = QueryParser.parse("pace pdf", now: now, calendar: calendar)
        XCTAssertEqual(q.terms, ["pace"])
        XCTAssertEqual(q.kinds, [.pdf])
        XCTAssertEqual(q.plainTerms, ["pace", "pdf"])
        XCTAssertEqual(q.filterLabel, "pdf")
    }

    func testDateAndFolderWords() {
        let q = QueryParser.parse("Pace PDF last week in downloads", now: now, calendar: calendar)
        XCTAssertEqual(q.terms, ["pace"])
        XCTAssertEqual(q.date?.label, "last week")
        XCTAssertEqual(q.folder, "Downloads")
        XCTAssertEqual(q.filterLabel, "pdf · last week · in downloads")
    }

    func testYesterdayRangeExcludesToday() {
        let q = QueryParser.parse("yesterday", now: now, calendar: calendar)
        let range = try! XCTUnwrap(q.date)
        XCTAssertFalse(range.contains(now))
        XCTAssertTrue(range.contains(now.addingTimeInterval(-86_400)))
    }

    func testInWithoutKnownFolderIsPlain() {
        let q = QueryParser.parse("notes in spain", now: now, calendar: calendar)
        XCTAssertEqual(q.terms, ["notes", "in", "spain"])
        XCTAssertNil(q.folder)
    }

    func testQuotesAndStarsStripped() {
        XCTAssertEqual(QueryParser.parse(#"pa"ce*"#).terms, ["pace"])
    }
}

final class MatcherTests: XCTestCase {
    func testTiers() {
        XCTAssertEqual(Matcher.tier(name: "pace.pdf", terms: ["pace"]), .exact)
        XCTAssertEqual(Matcher.tier(name: "pacemaker.pdf", terms: ["pace"]), .prefix)
        XCTAssertEqual(Matcher.tier(name: "Laksh_Goyal_Pace_Forward.pdf", terms: ["pace"]), .wordStart)
        XCTAssertEqual(Matcher.tier(name: "aerospike-namespace.yaml", terms: ["pace"]), .contains)
        XCTAssertNil(Matcher.tier(name: "budget.xlsx", terms: ["pace"]))
    }

    func testMultiWordAcrossUnderscores() {
        XCTAssertEqual(Matcher.tier(name: "Laksh_Goyal_Pace_Forward.pdf", terms: ["pace", "forward"]), .wordStart)
        XCTAssertEqual(Matcher.tier(name: "Laksh_Goyal_Pace_Forward.pdf", terms: ["paceforward"]), .contains)
        XCTAssertNil(Matcher.tier(name: "Laksh_Goyal_Pace.pdf", terms: ["pace", "forward"]))
    }

    func testCamelCaseWords() {
        XCTAssertEqual(Matcher.words(in: "PaceForwardDeck_v2"), ["pace", "forward", "deck", "v2"])
        XCTAssertEqual(Matcher.tier(name: "PaceForwardDeck.key", terms: ["deck"]), .wordStart)
    }

    func testTypos() {
        XCTAssertEqual(Matcher.tier(name: " Voltaire - Candide.pdf", terms: ["voltare"]), .typo)
        XCTAssertEqual(Matcher.tier(name: "Voltaire - Candide.pdf", terms: ["candid"]), .wordStart)
        XCTAssertEqual(Matcher.tier(name: "Introduction.pdf", terms: ["introdcution"]), .typo)
        XCTAssertNil(Matcher.tier(name: "pacer.pdf", terms: ["pzq"]))
        XCTAssertNil(Matcher.tier(name: "budget.pdf", terms: ["voltare"]))
    }

    func testHighlights() {
        let name = "Laksh_Goyal_Pace_pace.pdf"
        XCTAssertEqual(Matcher.highlights(in: name, terms: ["pace"]).count, 2)
    }
}

final class JunkFilterTests: XCTestCase {
    let junk = JunkFilter(home: "/Users/me", skips: ["/Users/me/Archive"])

    func testJunk() {
        XCTAssertTrue(junk.isJunk("/Users/me/Library/Caches/pace.json"))
        XCTAssertTrue(junk.isJunk("/Users/me/repo/.git/pace"))
        XCTAssertTrue(junk.isJunk("/Users/me/repo/node_modules/pace/index.js"))
        XCTAssertTrue(junk.isJunk("/Users/me/Apps/Pace.app/Contents/Info.plist"))
        XCTAssertTrue(junk.isJunk("/Users/me/Archive/pace.pdf"))
        XCTAssertFalse(junk.isJunk("/Users/me/Apps/Pace.app"))
        XCTAssertFalse(junk.isJunk("/Users/me/Downloads/pace.pdf"))
        XCTAssertFalse(junk.isJunk("/Users/me/Archived/pace.pdf"))
    }
}

final class DedupeTests: XCTestCase {
    func item(_ path: String, size: Int64, added: TimeInterval) -> ResultItem {
        ResultItem(candidate: Candidate(path: path, size: size, added: Date(timeIntervalSince1970: added)),
                   section: .name, tier: .wordStart, pickCount: 0, copies: [])
    }

    func testKey() {
        XCTAssertEqual(Dedupe.key(for: "DS3 Sponsorship (1).pdf"), "ds3 sponsorship.pdf")
        XCTAssertEqual(Dedupe.key(for: "(Copy) 0 Introduction.pdf"), "0 introduction.pdf")
        XCTAssertEqual(Dedupe.key(for: "Notes copy 2.txt"), "notes.txt")
        XCTAssertEqual(Dedupe.key(for: "Lecture-1.pdf"), "lecture-1.pdf")
    }

    func testCollapsesVerifiedCopiesKeepingNewest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("DS3.pdf").path
        let copy = directory.appendingPathComponent("DS3 (1).pdf").path
        try Data(repeating: 65, count: 100).write(to: URL(fileURLWithPath: original))
        try Data(repeating: 65, count: 100).write(to: URL(fileURLWithPath: copy))
        let items = [
            item(original, size: 100, added: 1),
            item(copy, size: 100, added: 5),
            item("/d/other.pdf", size: 7, added: 3),
        ]
        let out = Dedupe.collapse(items)
        XCTAssertEqual(out.map(\.candidate.path), [copy, "/d/other.pdf"])
        XCTAssertEqual(out[0].copies, [original])
    }

    func testDifferentSizesStaySeparate() {
        let items = [item("/d/Lecture (1).pdf", size: 10, added: 1), item("/d/Lecture (2).pdf", size: 20, added: 2)]
        XCTAssertEqual(Dedupe.collapse(items).count, 2)
    }
}

final class AssemblerTests: XCTestCase {
    let home = "/Users/me"

    func testSectionsRankingAndJunk() {
        let assembler = Assembler(junk: JunkFilter(home: home))
        let q = QueryParser.parse("pace")
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 9_000)
        let names = [
            Candidate(path: "\(home)/repo/aerospike-namespace.yaml", modified: new),
            Candidate(path: "\(home)/repo/pace.go", modified: new),
            Candidate(path: "\(home)/Downloads/Laksh_Goyal_Pace_Forward.pdf", added: old),
            Candidate(path: "\(home)/Downloads/Pace notes.pdf", added: new),
            Candidate(path: "\(home)/repo/.git/pace", modified: new),
        ]
        let contents = [
            Candidate(path: "\(home)/Downloads/Pace notes.pdf", added: new),
            Candidate(path: "\(home)/Downloads/Candide.pdf", added: old),
        ]
        let out = assembler.build(q, nameCandidates: names, contentCandidates: contents)
        XCTAssertEqual(out.name.map(\.candidate.name),
                       ["pace.go", "Pace notes.pdf", "Laksh_Goyal_Pace_Forward.pdf", "aerospike-namespace.yaml"])
        XCTAssertEqual(out.inside.map(\.candidate.name), ["Candide.pdf"])
    }

    func testCodeRanksBelowDocsInSameTier() {
        let assembler = Assembler(junk: JunkFilter(home: home))
        let new = Date(timeIntervalSince1970: 9_000), old = Date(timeIntervalSince1970: 1_000)
        let names = [
            Candidate(path: "\(home)/repo/pace_config.json", modified: new),
            Candidate(path: "\(home)/Downloads/pace_resume.pdf", added: old),
        ]
        let out = assembler.build(QueryParser.parse("pace"), nameCandidates: names, contentCandidates: [])
        XCTAssertEqual(out.name.first?.candidate.name, "pace_resume.pdf")
        let code = assembler.build(QueryParser.parse("pace code"), nameCandidates: names, contentCandidates: [])
        XCTAssertEqual(code.name.map(\.candidate.name), ["pace_config.json"])
    }

    func testStartsWithCodeDoesNotBeatWordStartDoc() {
        let assembler = Assembler(junk: JunkFilter(home: home))
        let names = [
            Candidate(path: "\(home)/src/pacer.go", modified: Date()),
            Candidate(path: "\(home)/Downloads/Laksh_Goyal_Pace.pdf", added: .distantPast),
        ]
        let out = assembler.build(QueryParser.parse("pace"), nameCandidates: names, contentCandidates: [])
        XCTAssertEqual(out.name.first?.candidate.name, "Laksh_Goyal_Pace.pdf")
    }

    func testFourLetterWordsGetNoTypos() {
        XCTAssertNil(Matcher.tier(name: "PACCAR.pdf", terms: ["pace"]))
        XCTAssertTrue(JunkFilter(home: home).isJunk("\(home)/go/pkg/mod/golang.org/x/net/pacer.go"))
    }

    func testPicksBeatRecencyButNotTier() {
        let resume = "\(home)/Downloads/pace_resume.pdf"
        let assembler = Assembler(junk: JunkFilter(home: home), picks: [resume: 3])
        let names = [
            Candidate(path: "\(home)/Downloads/pace_notes.pdf", added: Date(timeIntervalSince1970: 9_000)),
            Candidate(path: resume, added: Date(timeIntervalSince1970: 1_000)),
            Candidate(path: "\(home)/Downloads/pace.pdf", added: Date(timeIntervalSince1970: 1)),
        ]
        let out = assembler.build(QueryParser.parse("pace"), nameCandidates: names, contentCandidates: [])
        XCTAssertEqual(out.name.map(\.candidate.name), ["pace.pdf", "pace_resume.pdf", "pace_notes.pdf"])
    }

    func testTypoAlwaysLast() {
        let assembler = Assembler(junk: JunkFilter(home: home), picks: ["\(home)/a/Voltaire.pdf": 9])
        let names = [
            Candidate(path: "\(home)/a/Voltaire.pdf", added: Date()),
            Candidate(path: "\(home)/a/voltare_essay.pdf", added: .distantPast),
        ]
        let out = assembler.build(QueryParser.parse("voltare"), nameCandidates: names, contentCandidates: [])
        XCTAssertEqual(out.name.map(\.tier), [.prefix, .typo])
    }

    func testFiltersKindDateFolder() {
        let assembler = Assembler(junk: JunkFilter(home: home))
        let now = Date()
        let names = [
            Candidate(path: "\(home)/Downloads/pace.pdf", added: now),
            Candidate(path: "\(home)/Desktop/pace.pdf", added: now),
            Candidate(path: "\(home)/Downloads/pace.docx", added: now),
            Candidate(path: "\(home)/Downloads/pace_old.pdf", added: now.addingTimeInterval(-90 * 86_400)),
        ]
        let out = assembler.build(QueryParser.parse("pace pdf this month in downloads", now: now),
                                  nameCandidates: names, contentCandidates: [])
        XCTAssertEqual(out.name.map(\.candidate.path), ["\(home)/Downloads/pace.pdf"])
    }
}

final class SpotlightQueryTests: XCTestCase {
    func testNameAndContent() {
        let q = QueryParser.parse("pace pdf")
        XCTAssertEqual(SpotlightQuery.name(q), #"kMDItemFSName == "*pace*"cd && (kMDItemFSName == "*.pdf"c)"#)
        XCTAssertEqual(SpotlightQuery.content(q), #"kMDItemTextContent == "pace*"cdw && (kMDItemFSName == "*.pdf"c)"#)
    }

    func testTypoChunks() {
        let q = QueryParser.parse("voltare")
        XCTAssertEqual(SpotlightQuery.typo(q), #"(kMDItemFSName == "*tare*"cd || kMDItemFSName == "*volt*"cd)"#)
        XCTAssertNil(SpotlightQuery.typo(QueryParser.parse("pace")))
    }

    func testEmptyQueryHasNoSearch() {
        XCTAssertNil(SpotlightQuery.name(QueryParser.parse("")))
        XCTAssertNotNil(SpotlightQuery.name(QueryParser.parse("in downloads")))
    }
}
