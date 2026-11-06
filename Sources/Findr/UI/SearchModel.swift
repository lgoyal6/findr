import AppKit
import FindrCore
import SwiftUI

/// State behind the panel: the query, both result sections, selection and preview.
@MainActor
final class SearchModel: ObservableObject {
    @Published var text = "" {
        didSet { if text != oldValue { textChanged() } }
    }
    @Published private(set) var name: [ResultItem] = []
    @Published private(set) var inside: [ResultItem] = []
    @Published private(set) var query = QueryParser.parse("")
    @Published private(set) var searching = false
    @Published private(set) var notice: String?
    @Published private(set) var snippets: [String: Snippet] = [:]
    @Published var selected = 0 {
        didSet {
            loadSnippets()
            if listFocused, selected != oldValue || !oldListFocused, let item = selectedItem {
                Announcer.say("\(item.candidate.name), \(selected + 1) of \(flat.count)")
            }
            oldListFocused = listFocused
        }
    }
    private var oldListFocused = false
    /// True once the person arrows into the list. Space and Cmd-C act on the file only then.
    @Published var listFocused = false
    @Published var previewOpen = false
    /// Bumped each time the panel opens so the text field takes focus again.
    @Published var focusRequest = 0

    var onDismiss: () -> Void = {}

    private var generation = 0
    private var debounce: DispatchWorkItem?
    private var historyIndex: Int?
    private var settingFromHistory = false
    private let snippetQueue = OperationQueue()
    private let searchQueue = OperationQueue()
    private var cancellation = SearchCancellation()
    private let openFile: (URL) -> Bool
    private let openFileWith: (URL, URL, @escaping (Error?) -> Void) -> Void
    private let recordPick: (String, String) -> Void

    init(openFile: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         openFileWith: @escaping (URL, URL, @escaping (Error?) -> Void) -> Void = { file, app, done in
             NSWorkspace.shared.open([file], withApplicationAt: app,
                                     configuration: NSWorkspace.OpenConfiguration()) { _, error in done(error) }
         },
         recordPick: @escaping (String, String) -> Void = { Store.shared.recordPick(query: $0, path: $1) }) {
        self.openFile = openFile
        self.openFileWith = openFileWith
        self.recordPick = recordPick
        snippetQueue.maxConcurrentOperationCount = 2
        snippetQueue.qualityOfService = .userInitiated
        searchQueue.maxConcurrentOperationCount = 1
        searchQueue.qualityOfService = .userInitiated
    }

    deinit {
        cancellation.cancel()
        searchQueue.cancelAllOperations()
        snippetQueue.cancelAllOperations()
    }

    @Published private(set) var expandedSection: FindrCore.Section?

    var visibleName: [ResultItem] {
        expandedSection == .inside ? [] : expandedSection == .name ? name : Array(name.prefix(5))
    }

    var visibleInside: [ResultItem] {
        expandedSection == .name ? [] : expandedSection == .inside ? inside : Array(inside.prefix(5))
    }

    var flat: [ResultItem] { visibleName + visibleInside }

    func showAll(_ section: FindrCore.Section) {
        changeSection(to: section)
    }

    func showOverview() {
        changeSection(to: nil)
    }

    private func changeSection(to section: FindrCore.Section?) {
        let previousID = selectedItem?.id
        expandedSection = section
        selected = flat.firstIndex { $0.id == previousID } ?? 0
        listFocused = false
    }

    var selectedItem: ResultItem? {
        let all = flat
        return all.indices.contains(selected) ? all[selected] : nil
    }

    // MARK: Searching

    private func textChanged() {
        if !settingFromHistory { historyIndex = nil }
        listFocused = false
        expandedSection = nil
        selected = 0
        cancelSearch()
        name = []
        inside = []
        notice = nil
        actionError = nil
        previewOpen = false
        query = QueryParser.parse(text)

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            name = []; inside = []; notice = nil; searching = false; selected = 0
            query = QueryParser.parse("")
            return
        }
        searching = true
        let work = DispatchWorkItem { [weak self] in self?.startSearch(trimmed) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    private func startSearch(_ text: String) {
        let gen = generation
        let token = cancellation
        let picks = Store.shared.picks(for: text)
        let skips = Store.shared.skipFolders
        searching = true
        searchQueue.addOperation { [weak self] in
            SearchEngine.run(text, picks: picks, skips: skips,
                             isCurrent: { token.isCurrent },
                             publish: { snapshot in
                                 DispatchQueue.main.async { self?.apply(snapshot, generation: gen) }
                             })
        }
    }

    func apply(_ snapshot: SearchSnapshot, generation gen: Int) {
        guard gen == generation else { return }
        let previousID = selectedItem?.id
        name = snapshot.output.name
        inside = snapshot.output.inside
        query = snapshot.query
        notice = snapshot.notice
        if searching, !snapshot.searching {
            Announcer.say(name.isEmpty && inside.isEmpty ? "No files match"
                          : "\(name.count) name matches, \(inside.count) found inside")
        }
        searching = snapshot.searching
        // Keep the highlighted file if it is still there; otherwise start at the top.
        selected = flat.firstIndex { $0.id == previousID } ?? 0
        if !listFocused { selected = 0 }
        loadSnippets()
    }

    /// Keep only a bounded set of current-query snippets and misses.
    private var pending = Set<String>()
    private var attempted = Set<String>()
    private var snippetOrder: [String] = []

    private func snippetKey(_ item: ResultItem) -> String {
        item.id + "\u{1}" + query.terms.joined(separator: " ") + "\u{1}"
            + String(item.candidate.modified?.timeIntervalSince1970 ?? 0)
            + ":" + String(item.candidate.size ?? -1)
    }

    private func loadSnippets() {
        let terms = query.terms
        guard !terms.isEmpty, cancellation.isCurrent else { return }
        var targets = Array(visibleInside.prefix(25))
        if let item = selectedItem, item.section == .inside { targets.insert(item, at: 0) }
        for item in targets {
            let key = snippetKey(item)
            guard pending.count < 26, !attempted.contains(key), !pending.contains(key) else { continue }
            pending.insert(key)
            let gen = generation
            let token = cancellation
            snippetQueue.addOperation { [weak self] in
                guard token.isCurrent else { return }
                let hit = Snippets.find(path: item.candidate.path, terms: terms, isCurrent: { token.isCurrent })
                DispatchQueue.main.async {
                    guard let self, self.generation == gen, token.isCurrent else { return }
                    self.pending.remove(key)
                    self.attempted.insert(key)
                    self.snippetOrder.append(key)
                    if let hit { self.snippets[key] = hit }
                    while self.snippetOrder.count > 64 {
                        let evicted = self.snippetOrder.removeFirst()
                        self.attempted.remove(evicted)
                        self.snippets.removeValue(forKey: evicted)
                    }
                }
            }
        }
    }

    func snippet(for item: ResultItem) -> Snippet? { snippets[snippetKey(item)] }

    func cancelSearch() {
        generation += 1
        debounce?.cancel()
        cancellation.cancel()
        cancellation = SearchCancellation()
        searchQueue.cancelAllOperations()
        snippetQueue.cancelAllOperations()
        pending.removeAll()
        attempted.removeAll()
        snippetOrder.removeAll()
        snippets.removeAll()
        searching = false
    }

    // MARK: Keyboard

    func moveDown() {
        guard !flat.isEmpty else { return }
        if listFocused {
            selected = min(selected + 1, flat.count - 1)
        } else {
            listFocused = true
            selected = min(1, flat.count - 1)
        }
    }

    func moveUp() {
        if !listFocused {
            if text.isEmpty || historyIndex != nil { stepHistory() }
            return
        }
        if selected == 0 {
            listFocused = false
        } else {
            selected -= 1
        }
    }

    /// Up arrow in an empty bar walks back through past searches.
    private func stepHistory() {
        let history = Store.shared.history
        guard !history.isEmpty else { return }
        let next = historyIndex.map { min($0 + 1, history.count - 1) } ?? 0
        historyIndex = next
        settingFromHistory = true
        text = history[next]
        settingFromHistory = false
    }

    func reset() {
        cancelSearch()
        text = ""
        previewOpen = false
        listFocused = false
        historyIndex = nil
        focusRequest += 1
    }

    // MARK: Actions

    func open(_ item: ResultItem? = nil) {
        guard let item = item ?? selectedItem, flat.contains(where: { $0.id == item.id }) else { return }
        let url = URL(fileURLWithPath: item.candidate.path)
        guard openFile(url) else {
            actionError = "Couldn’t open \(item.candidate.name). Check that the file still exists, or use Open with."
            return
        }
        actionError = nil
        recordPick(text, item.candidate.path)
        onDismiss()
    }

    func reveal() {
        guard let item = selectedItem else { return }
        Store.shared.addHistory(text)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.candidate.path)])
        onDismiss()
    }

    func copyFile() {
        guard let item = selectedItem else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: item.candidate.path) as NSURL])
        flash("Copied file")
    }

    func copyPath() {
        guard let item = selectedItem else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(item.candidate.path, forType: .string)
        flash("Copied path")
    }

    @Published private(set) var toast: String?
    @Published private(set) var actionError: String? {
        didSet { if let actionError { Announcer.say(actionError) } }
    }

    func clearActionError() { actionError = nil }

    private func flash(_ message: String) {
        toast = message
        Announcer.say(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }

    /// Apps that can open the selected file, default first.
    func appsForSelected() -> [URL] {
        guard let item = selectedItem else { return [] }
        let url = URL(fileURLWithPath: item.candidate.path)
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
        return ([preferred].compactMap { $0 } + apps.filter { $0 != preferred }).prefix(12).map { $0 }
    }

    func open(with app: URL) {
        guard let item = selectedItem else { return }
        let gen = generation
        let actionQuery = text
        openFileWith(URL(fileURLWithPath: item.candidate.path), app) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    if self.generation == gen {
                        self.actionError = "Couldn’t open \(item.candidate.name): \(error.localizedDescription)"
                    }
                    return
                }
                self.recordPick(actionQuery, item.candidate.path)
                if self.generation == gen {
                    self.actionError = nil
                    self.onDismiss()
                }
            }
        }
    }
}
