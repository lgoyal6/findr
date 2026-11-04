import AppKit
import Testing
@testable import Findr
@testable import FindrCore

@MainActor
struct ReviewFixTests {
    private func populate(_ model: SearchModel) {
        model.text = "report"
        let item = ResultItem(candidate: Candidate(path: "/fixture/report.pdf"), section: .name,
                              tier: .exact, pickCount: 0, copies: [])
        model.apply(SearchSnapshot(query: QueryParser.parse("report"),
                                   output: .init(name: [item], inside: []), notice: nil, searching: false),
                    generation: 1)
    }

    @Test func failedOpenKeepsPanelAndDoesNotTrainRanking() {
        var dismissed = false
        var picks = 0
        let model = SearchModel(openFile: { _ in false }, recordPick: { _, _ in picks += 1 })
        defer { model.reset() }
        populate(model)
        model.onDismiss = { dismissed = true }
        model.open()
        #expect(model.actionError != nil)
        #expect(!dismissed)
        #expect(picks == 0)
        #expect(model.selectedItem != nil)
    }

    @Test func successfulOpenRecordsPickAndDismisses() {
        var dismissed = false
        var picks: [String] = []
        let model = SearchModel(openFile: { _ in true }, recordPick: { picks.append($0 + ":" + $1) })
        defer { model.reset() }
        populate(model)
        model.onDismiss = { dismissed = true }
        model.open()
        #expect(picks == ["report:/fixture/report.pdf"])
        #expect(dismissed)
        #expect(model.actionError == nil)
    }

    @Test func staleRowCannotOpenAfterQueryChanges() {
        var opens = 0
        let model = SearchModel(openFile: { _ in opens += 1; return true })
        defer { model.reset() }
        populate(model)
        let old = model.selectedItem
        model.text = "another query"
        model.open(old)
        #expect(opens == 0)
        #expect(model.selectedItem == nil)
    }

    @Test func failedOpenWithDoesNotTrainOrDismiss() async throws {
        var dismissed = false
        var picks = 0
        let model = SearchModel(openFileWith: { _, _, done in
            done(NSError(domain: "FindrTest", code: 1))
        }, recordPick: { _, _ in picks += 1 })
        defer { model.reset() }
        populate(model)
        model.onDismiss = { dismissed = true }
        model.open(with: URL(fileURLWithPath: "/Applications/Preview.app"))
        for _ in 0..<100 where model.actionError == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(model.actionError != nil)
        #expect(!dismissed)
        #expect(picks == 0)
    }

    @Test func delayedOpenWithCannotDismissNewSearch() async throws {
        var completion: ((Error?) -> Void)?
        var dismissed = false
        var queries: [String] = []
        let model = SearchModel(openFileWith: { _, _, done in completion = done },
                                recordPick: { query, _ in queries.append(query) })
        defer { model.reset() }
        populate(model)
        model.onDismiss = { dismissed = true }
        model.open(with: URL(fileURLWithPath: "/Applications/Preview.app"))
        model.text = "new query"
        completion?(nil)
        for _ in 0..<100 where queries.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(queries == ["report"])
        #expect(!dismissed)
    }

    @Test func successfulOpenWithRecordsAndDismisses() async throws {
        var dismissed = false
        var picks = 0
        let model = SearchModel(openFileWith: { _, _, done in done(nil) },
                                recordPick: { _, _ in picks += 1 })
        defer { model.reset() }
        populate(model)
        model.onDismiss = { dismissed = true }
        model.open(with: URL(fileURLWithPath: "/Applications/Preview.app"))
        for _ in 0..<100 where !dismissed { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(dismissed)
        #expect(picks == 1)
        #expect(model.actionError == nil)
    }

    @Test func shortcutRecordingCanCancelAndRestart() {
        let settings = SettingsModel()
        let original = settings.hotKeyLabel
        defer { settings.stopRecording() }
        settings.startRecording()
        settings.startRecording()
        #expect(settings.recording)
        settings.stopRecording()
        #expect(!settings.recording)
        settings.startRecording()
        settings.stopRecording()
        #expect(settings.hotKeyLabel == original)
    }

    @Test func canceledSearchDoesNotPublish() {
        let token = SearchCancellation()
        token.cancel()
        var published = false
        SearchEngine.run("pace", picks: [:], skips: [], isCurrent: { token.isCurrent },
                         publish: { _ in published = true })
        #expect(!published)
    }

    @Test func spotlightStopsWhenCanceledAfterStarting() {
        var checks = 0
        let start = Date()
        let result = Spotlight.run("kMDItemFSName == \"*\"", scopes: [NSTemporaryDirectory()], limit: 5) {
            checks += 1
            return checks == 1
        }
        #expect(result.isEmpty)
        #expect(checks > 1)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func canceledSnippetDoesNotReadFile() {
        #expect(Snippets.find(path: "/fixture/document.pdf", terms: ["report"], isCurrent: { false }) == nil)
    }

    @Test func snippetCacheIsBoundedAndInvalidated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = try (0..<80).map { index -> ResultItem in
            let url = directory.appendingPathComponent("file\(index).txt")
            try Data("report content".utf8).write(to: url)
            return ResultItem(candidate: Candidate(path: url.path), section: .inside,
                              tier: nil, pickCount: 0, copies: [])
        }
        let model = SearchModel()
        defer { model.reset() }
        model.apply(SearchSnapshot(query: QueryParser.parse("report"),
                                   output: .init(name: [], inside: items), notice: nil, searching: false),
                    generation: 0)
        model.showAll(.inside)
        for index in items.indices {
            model.selected = index
            for _ in 0..<500 where model.snippet(for: items[index]) == nil {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            #expect(model.snippet(for: items[index]) != nil)
            #expect(model.snippets.count <= 64)
        }
        #expect(model.snippets.count == 64)
        model.text = "new query"
        #expect(model.snippets.isEmpty)
        model.reset()
    }
}
