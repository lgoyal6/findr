import XCTest
@testable import FindrCore

final class ReviewRegressionTests: XCTestCase {
    func testFreshFileStillAppearsAsContentMatch() {
        let file = Candidate(path: "/fixture/Downloads/document.txt", size: 10)
        let result = Assembler(junk: JunkFilter(home: "/fixture")).build(
            QueryParser.parse("needle"), nameCandidates: [file], contentCandidates: [file, file])
        XCTAssertTrue(result.name.isEmpty)
        XCTAssertEqual(result.inside.map(\.id), [file.path])
    }

    func testEqualSizeDoesNotProveIdenticalContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("report.txt")
        let second = directory.appendingPathComponent("report (1).txt")
        try Data("AAAA".utf8).write(to: first)
        try Data("BBBB".utf8).write(to: second)
        let candidates = [first, second].map { Candidate(path: $0.path, size: 4) }
        let output = Assembler(junk: JunkFilter(home: directory.path)).build(
            QueryParser.parse("report"), nameCandidates: candidates, contentCandidates: [])
        XCTAssertEqual(output.name.count, 2)
    }

    func testUnreadableCandidatesAreNeverAssumedToBeCopies() {
        let files = ["/missing/report.txt", "/missing/report (1).txt"].map {
            Candidate(path: $0, size: 10)
        }
        let output = Assembler(junk: JunkFilter(home: "/missing")).build(
            QueryParser.parse("report"), nameCandidates: files, contentCandidates: [])
        XCTAssertEqual(output.name.count, 2)
    }

    func testCanceledAssemblyReturnsNoResults() {
        let output = Assembler(junk: JunkFilter(home: "/fixture")).build(
            QueryParser.parse("report"), nameCandidates: [Candidate(path: "/fixture/report.txt")],
            contentCandidates: [], isCurrent: { false })
        XCTAssertTrue(output.isEmpty)
    }
}

final class RunnableTests: XCTestCase {
    func testAppsScriptsAndInstallersAreLabelled() {
        XCTAssertEqual(Runnable.label(name: "Leaf.app", isExecutableFile: true), "app")
        XCTAssertEqual(Runnable.label(name: "setup.command", isExecutableFile: false), "script")
        XCTAssertEqual(Runnable.label(name: "Installer.pkg", isExecutableFile: false), "installer")
        XCTAssertEqual(Runnable.label(name: "invoice", isExecutableFile: true), "program")
        XCTAssertNil(Runnable.label(name: "lease.pdf", isExecutableFile: false))
    }

    func testReorderingCharactersAreFlaggedAndShown() {
        let spoof = "invoice\u{202E}fdp.app"
        XCTAssertEqual(Runnable.label(name: spoof, isExecutableFile: false), "odd name")
        XCTAssertEqual(Runnable.visibleName(spoof), "invoice?fdp.app")
    }
}
