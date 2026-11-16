import AppKit
import Testing
@testable import Findr
@testable import FindrCore

@MainActor
struct UploadSelectionTests {
    private func populate(_ model: SearchModel, path: String = "/fixture/report.pdf") {
        model.text = "report"
        let item = ResultItem(candidate: Candidate(path: path), section: .name,
                              tier: .exact, pickCount: 0, copies: [])
        model.apply(SearchSnapshot(query: QueryParser.parse("report"),
                                   output: .init(name: [item], inside: []), notice: nil, searching: false),
                    generation: 1)
    }

    @Test func choosingAFileUsesTheDialogAndRecordsOnlySuccess() {
        var opened = false
        var picked: URL?
        var picks = 0
        var dismissed = false
        let model = SearchModel(openFile: { _ in opened = true; return true },
                                recordPick: { _, _ in picks += 1 })
        defer { model.reset() }
        populate(model)
        model.chooseFile = { file, done in picked = file; done(.success(())) }
        model.onDismiss = { dismissed = true }
        model.open()
        #expect(picked?.path == "/fixture/report.pdf")
        #expect(!opened)
        #expect(picks == 1)
        #expect(dismissed)
        #expect(!model.choosingFile)
    }

    @Test func failedSelectionKeepsTheErrorAndDoesNotOpenOrRecord() {
        var opened = false
        var picks = 0
        var dismissed = false
        let model = SearchModel(openFile: { _ in opened = true; return true },
                                recordPick: { _, _ in picks += 1 })
        defer { model.reset() }
        populate(model)
        model.chooseFile = { _, done in done(.failure(CocoaError(.fileReadNoSuchFile))) }
        model.onDismiss = { dismissed = true }
        model.open()
        #expect(!opened)
        #expect(picks == 0)
        #expect(!dismissed)
        #expect(model.actionError != nil)
        #expect(!model.choosingFile)
    }

    @Test func duplicateReturnCannotChooseTwice() {
        var calls = 0
        let model = SearchModel(recordPick: { _, _ in })
        defer { model.reset() }
        populate(model)
        model.chooseFile = { _, _ in calls += 1 }
        model.open()
        model.open()
        #expect(calls == 1)
        #expect(model.choosingFile)
    }

    @Test func choosingAnExecutableDoesNotExecuteIt() {
        var chosen = false
        let model = SearchModel(openFile: { _ in Issue.record("An upload must not execute the file"); return false },
                                recordPick: { _, _ in })
        defer { model.reset() }
        populate(model, path: "/fixture/report.app")
        model.chooseFile = { _, done in chosen = true; done(.success(())) }
        model.open()
        #expect(chosen)
        #expect(model.actionError == nil)
    }

    @Test func completionForAnOldSearchCannotDismissTheNewSearch() {
        var completion: ((Result<Void, Error>) -> Void)?
        var dismissed = false
        let model = SearchModel(recordPick: { _, _ in })
        defer { model.reset() }
        populate(model)
        model.chooseFile = { _, done in completion = done }
        model.onDismiss = { dismissed = true }
        model.open()
        model.reset()
        model.text = "new search"
        completion?(.success(()))
        #expect(!dismissed)
        #expect(model.text == "new search")
        #expect(!model.choosingFile)
    }
}
