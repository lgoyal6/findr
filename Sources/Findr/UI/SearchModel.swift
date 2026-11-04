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
    @Published var selected = 0
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
    private var snippetQueue = OperationQueue()

    init() {
        snippetQueue.maxConcurrentOperationCount = 2
        snippetQueue.qualityOfService = .userInitiated
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
        debounce?.cancel()
        generation += 1
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            name = []; inside = []; notice = nil; searching = false; selected = 0
            query = QueryParser.parse("")
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.startSearch(trimmed) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    private func startSearch(_ text: String) {
        let gen = generation
        let picks = Store.shared.picks(for: text)
        let skips = Store.shared.skipFolders
        searching = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            SearchEngine.run(text, picks: picks, skips: skips,
                             isCurrent: { [weak self] in
                                 DispatchQueue.main.sync { self?.generation == gen }
                             },
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
        searching = snapshot.searching
        // Keep the highlighted file if it is still there; otherwise start at the top.
        selected = flat.firstIndex { $0.id == previousID } ?? 0
        if !listFocused { selected = 0 }
        loadSnippets()
    }

    /// Finds where the word is inside the first rows of the Inside section.
    private func loadSnippets() {
        let terms = query.terms
        guard !terms.isEmpty else { return }
        let key = terms.joined(separator: " ")
        for item in inside.prefix(25) {
            let cacheKey = item.id + "\u{1}" + key
            guard snippets[cacheKey] == nil, !pending.contains(cacheKey) else { continue }
            pending.insert(cacheKey)
            let path = item.candidate.path
            snippetQueue.addOperation { [weak self] in
                let hit = Snippets.find(path: path, terms: terms)
                DispatchQueue.main.async {
                    self?.pending.remove(cacheKey)
                    if let hit { self?.snippets[cacheKey] = hit }
                }
            }
        }
    }

    private var pending = Set<String>()

    func snippet(for item: ResultItem) -> Snippet? {
        snippets[item.id + "\u{1}" + query.terms.joined(separator: " ")]
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
        text = ""
        previewOpen = false
        listFocused = false
        historyIndex = nil
        focusRequest += 1
    }

    // MARK: Actions

    func open(_ item: ResultItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        let url = URL(fileURLWithPath: item.candidate.path)
        Store.shared.recordPick(query: text, path: item.candidate.path)
        NSWorkspace.shared.open(url)
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

    private func flash(_ message: String) {
        toast = message
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
        Store.shared.recordPick(query: text, path: item.candidate.path)
        NSWorkspace.shared.open([URL(fileURLWithPath: item.candidate.path)], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
        onDismiss()
    }
}
