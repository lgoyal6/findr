import AppKit
import Combine
import Darwin
import FindrCore
import LeafBrowserBridge
import SwiftUI

struct BrowserFileRow: Identifiable {
    let url: URL
    let directory: Bool
    let modified: Date?
    let size: Int64?
    let hidden: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var modifiedForSorting: Date { modified ?? .distantPast }
    var sizeForSorting: Int64 { size ?? -1 }

    init(_ url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .isHiddenKey])
        directory = values?.isDirectory ?? false
        modified = values?.contentModificationDate
        size = values?.fileSize.map(Int64.init)
        hidden = values?.isHidden == true || url.lastPathComponent.hasPrefix(".")
    }
}

@MainActor
final class BrowserFilePickerModel: ObservableObject {
    let search = SearchModel()
    let request: BrowserUploadRequest
    @Published private(set) var location: BrowserPickerLocation
    @Published private(set) var sidebarSections = BrowserSidebarSection.available()
    @Published private(set) var loading = false
    @Published private(set) var files: [BrowserFileRow] = []
    @Published var selection = Set<String>() {
        didSet { if selection.isEmpty { selectionAnchor = nil } }
    }
    @Published var grid = false
    @Published var preview = true
    @Published var error: String?
    @Published var exporting = false
    @Published var sortOrder = [KeyPathComparator(\BrowserFileRow.modifiedForSorting, order: .reverse)]
    @Published var fileKind: FileKind? { didSet { selection = [] } }
    @Published var modifiedSince = "Any date" { didSet { selection = [] } }
    @Published var matchingTypesOnly = true { didSet { selection = [] } }
    @Published var showHiddenFiles = false { didSet { refresh() } }
    @Published var showingGoToFolder = false
    @Published var folderPath = ""
    private var selectionAnchor: String?
    private var selectionLead: String?
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var back: [BrowserPickerLocation] = []
    private var forward: [BrowserPickerLocation] = []
    private var metadataQuery: NSMetadataQuery?
    private var metadataObservers: [NSObjectProtocol] = []

    init(request: BrowserUploadRequest) {
        self.request = request
        location = .folder(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        loadFolder()
    }

    deinit {
        folderWatcher?.cancel()
        metadataQuery?.stop()
        metadataObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var hasSearch: Bool { !search.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var selectedFiles: [URL] { rows.filter { selection.contains($0.id) && !$0.directory }.map(\.url) }
    var previewFile: BrowserFileRow? { rows.first { selection.contains($0.id) && !$0.directory } }
    var canChoose: Bool {
        !exporting && !selectedFiles.isEmpty && (request.multiple || selectedFiles.count == 1)
            && selectedFiles.allSatisfy(request.allows)
    }
    var selectedFolder: BrowserFileRow? {
        guard selection.count == 1 else { return nil }
        return rows.first { selection.contains($0.id) && $0.directory }
    }
    var canOpenSelection: Bool { !exporting && (selectedFolder != nil || canChoose) }

    var rows: [BrowserFileRow] {
        let source: [BrowserFileRow]
        if !hasSearch {
            source = files
        } else {
            var seen = Set<String>()
            source = (search.name + search.inside).compactMap { item in
                let url = URL(fileURLWithPath: item.candidate.path)
                guard seen.insert(url.path).inserted else { return nil }
                return BrowserFileRow(url)
            }
        }
        let date = QueryParser.parse(modifiedSince).date
        return source.filter { row in
            if !showHiddenFiles && row.hidden { return false }
            if row.directory { return true }
            if matchingTypesOnly && !request.allows(row.url) { return false }
            if let fileKind, FileKind.of(path: row.id) != fileKind { return false }
            if let date, !date.contains(row.modified ?? .distantPast) { return false }
            return true
        }.sorted(using: sortOrder + [KeyPathComparator(\BrowserFileRow.name), KeyPathComparator(\BrowserFileRow.id)])
    }

    var ancestors: [URL] {
        guard let folder = location.folder else { return [] }
        var result = [folder]
        while let first = result.first, first.path != "/" {
            result.insert(first.deletingLastPathComponent(), at: 0)
        }
        return result
    }

    func navigate(_ url: URL) {
        navigate(.folder(url))
    }

    func navigate(_ target: BrowserPickerLocation) {
        guard !exporting, target != location else { return }
        back.append(location)
        forward = []
        location = target
        search.text = ""
        loadFolder()
    }

    func goBack() {
        guard !exporting, let previous = back.popLast() else { return }
        forward.append(location)
        location = previous
        search.text = ""
        loadFolder()
    }

    func goForward() {
        guard !exporting, let next = forward.popLast() else { return }
        back.append(location)
        location = next
        search.text = ""
        loadFolder()
    }

    func select(_ row: BrowserFileRow, modifiers: NSEvent.ModifierFlags? = nil) {
        guard !exporting else { return }
        let modifiers = modifiers ?? NSApp?.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if request.multiple, modifiers.contains(.shift),
           let anchor = selectionAnchor,
           let start = rows.firstIndex(where: { $0.id == anchor }),
           let end = rows.firstIndex(where: { $0.id == row.id }) {
            let range = Set(rows[min(start, end)...max(start, end)].map(\.id))
            selection = modifiers.contains(.command) ? selection.union(range) : range
            selectionLead = row.id
            return
        }
        if request.multiple, modifiers.contains(.command) {
            if selection.contains(row.id) { selection.remove(row.id) }
            else { selection.insert(row.id) }
        } else { selection = [row.id] }
        selectionAnchor = row.id
        selectionLead = row.id
    }

    func moveSelection(by offset: Int, extending: Bool = false) {
        let visible = rows
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectionLead && selection.contains($0.id) }
            ?? visible.firstIndex { selection.contains($0.id) }
        let index = current.map { min(max($0 + offset, 0), visible.count - 1) } ?? 0
        select(visible[index], modifiers: extending ? .shift : [])
    }

    func openSelection(choose: () -> Void) {
        if let folder = selectedFolder { navigate(folder.url) }
        else if canChoose { choose() }
    }

    func goToFolder(_ path: String) -> Bool {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let base = location.folder ?? FileManager.default.homeDirectoryForCurrentUser
        let url = URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL
        guard !expanded.isEmpty, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            error = "That folder could not be found."
            return false
        }
        error = nil
        if location.folder == url { refresh() }
        else { navigate(url) }
        return true
    }

    func beginGoToFolder() {
        folderPath = location.folder?.path ?? "~"
        error = nil
        showingGoToFolder = true
    }

    func goToParent() {
        guard let folder = location.folder, folder.path != "/" else { return }
        navigate(folder.deletingLastPathComponent())
    }

    func refresh() {
        guard !exporting else { return }
        let previousSelection = selection
        let previousAnchor = selectionAnchor
        let previousLead = selectionLead
        loadFolder()
        let visible = Set(rows.map(\.id))
        selection = previousSelection.intersection(visible)
        selectionAnchor = previousAnchor.flatMap { visible.contains($0) ? $0 : nil }
        selectionLead = previousLead.flatMap { visible.contains($0) ? $0 : nil }
        sidebarSections = BrowserSidebarSection.available()
    }

    func loadFolder() {
        folderWatcher?.cancel()
        folderWatcher = nil
        metadataQuery?.stop()
        metadataQuery = nil
        metadataObservers.forEach(NotificationCenter.default.removeObserver)
        metadataObservers = []
        selection = []
        error = nil
        files = []
        loading = false
        guard let folder = location.folder else { loadMetadata(); return }
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: showHiddenFiles ? [] : [.skipsHiddenFiles]).map(BrowserFileRow.init)
            let descriptor = Darwin.open(folder.path, O_EVTONLY)
            if descriptor >= 0 {
                let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                    eventMask: [.write, .delete, .rename], queue: .main)
                watcher.setCancelHandler { Darwin.close(descriptor) }
                watcher.setEventHandler { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.location.folder == folder else { return }
                        self.refresh()
                    }
                }
                folderWatcher = watcher
                watcher.resume()
            }
        } catch {
            files = []
            self.error = error.localizedDescription
        }
    }

    private func loadMetadata() {
        guard let predicate = location.predicate else { return }
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false),
                                 NSSortDescriptor(key: "kMDItemContentModificationDate", ascending: false)]
        metadataQuery = query
        loading = true
        for notification in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            metadataObservers.append(NotificationCenter.default.addObserver(forName: notification,
                object: query, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let query = notification.object as? NSMetadataQuery,
                              self.metadataQuery === query else { return }
                        query.disableUpdates()
                        self.files = query.results.compactMap { item in
                            guard let item = item as? NSMetadataItem,
                                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                            return BrowserFileRow(URL(fileURLWithPath: path))
                        }
                        query.enableUpdates()
                        self.loading = false
                    }
                })
        }
        if !query.start() {
            loading = false
            error = "macOS could not load this view. Try another location."
        }
    }

    func stop() {
        folderWatcher?.cancel()
        folderWatcher = nil
        metadataQuery?.stop()
        metadataQuery = nil
        metadataObservers.forEach(NotificationCenter.default.removeObserver)
        metadataObservers = []
        search.cancelSearch()
    }
}

struct BrowserFilePicker: View {
    @ObservedObject var model: BrowserFilePickerModel
    @ObservedObject var search: SearchModel
    let choose: () -> Void
    let cancel: () -> Void
    let useFinder: () -> Void
    @FocusState private var filesFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: LeafLogo.image(size: 24)).accessibilityHidden(true)
                Text("Choose \(model.request.multiple ? "files" : "a file") for \(model.request.displayOrigin)")
                    .font(.headline).lineLimit(1)
                Spacer()
                if model.exporting { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 170)
                Divider()
                VStack(spacing: 0) {
                    toolbar
                    filters
                    Divider()
                    HStack(spacing: 0) {
                        fileContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if model.preview {
                            Divider()
                            preview.frame(width: 240)
                        }
                    }
                    Divider()
                    breadcrumbs
                }
            }
            Divider()
            HStack {
                Button("Use Finder", action: useFinder)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .help("Use the macOS file picker (⌘⇧F)")
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if !model.request.accept.isEmpty {
                    Text("Allowed types \(model.request.accept)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(model.selectedFolder != nil ? "Open" : model.request.multiple && model.selectedFiles.count > 1
                       ? "Choose \(model.selectedFiles.count) Files" : "Choose") {
                    model.openSelection(choose: choose)
                }.keyboardShortcut(.defaultAction).disabled(!model.canOpenSelection)
            }.padding(14)
        }
        .frame(minWidth: 820, minHeight: 490)
        .disabled(model.exporting)
        .sheet(isPresented: $model.showingGoToFolder) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Go to Folder").font(.headline)
                TextField("Folder path", text: $model.folderPath).frame(width: 430)
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { model.showingGoToFolder = false }.keyboardShortcut(.cancelAction)
                    Button("Go") {
                        if model.goToFolder(model.folderPath) { model.showingGoToFolder = false }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }
        .onChange(of: search.text) { model.selection = [] }
        .onChange(of: model.selection) { _, selected in
            if !model.request.multiple, selected.count > 1 {
                model.selection = Set(selected.sorted().prefix(1))
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding<BrowserPickerLocation?>(get: { model.location }, set: { location in
            if let location { model.navigate(location) }
        })) {
            ForEach(model.sidebarSections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        Label {
                            Text(item.title).lineLimit(1)
                        } icon: {
                            Image(systemName: item.icon).foregroundStyle(tagColor(item.location))
                        }.padding(.vertical, 2).tag(item.location)
                    }
                }
            }
        }.listStyle(.sidebar)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: model.goBack) { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack).help("Back").keyboardShortcut("[", modifiers: .command)
            Button(action: model.goForward) { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward).help("Forward").keyboardShortcut("]", modifiers: .command)
            Text(model.hasSearch ? "Search Results" : model.location.title).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                Button("Go to Folder…", action: model.beginGoToFolder)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Enclosing Folder", action: model.goToParent)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.location.folder == nil || model.location.folder?.path == "/")
                Button("Refresh", action: model.refresh).keyboardShortcut("r", modifiers: .command)
                Toggle("Show Hidden Files", isOn: $model.showHiddenFiles)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            } label: { Image(systemName: "ellipsis.circle") }
                .help("Folder actions").accessibilityLabel("Folder actions")
            Menu {
                Button("Name (A–Z)") { model.sortOrder = [KeyPathComparator(\BrowserFileRow.name)] }
                Button("Date Modified (Newest First)") {
                    model.sortOrder = [KeyPathComparator(\BrowserFileRow.modifiedForSorting, order: .reverse)]
                }
                Button("Size (Largest First)") {
                    model.sortOrder = [KeyPathComparator(\BrowserFileRow.sizeForSorting, order: .reverse)]
                }
                Divider()
                Button("Reverse Order") {
                    model.sortOrder = model.sortOrder.map { comparator in
                        var reversed = comparator
                        reversed.order = comparator.order == .forward ? .reverse : .forward
                        return reversed
                    }
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
                .help("Sort files").accessibilityLabel("Sort files")
            Picker("View", selection: $model.grid) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 72)
            Toggle(isOn: $model.preview) { Image(systemName: "sidebar.right") }
                .toggleStyle(.button).help("Show preview")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search with Leaf", text: $search.text).textFieldStyle(.plain)
                    .accessibilityLabel("Search with Leaf")
                    .onKeyPress(.downArrow) {
                        filesFocused = true
                        model.moveSelection(by: 1)
                        return .handled
                    }
                if search.searching { ProgressView().controlSize(.mini) }
            }.padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                .frame(width: 215)
        }.buttonStyle(.borderless).padding(10)
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("Kind", selection: $model.fileKind) {
                Text("All kinds").tag(nil as FileKind?)
                ForEach(FileKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue.uppercased()).tag(Optional(kind))
                }
            }.frame(width: 175)
            Picker("Modified", selection: $model.modifiedSince) {
                ForEach(["Any date", "Today", "Yesterday", "This week", "Last week", "This month", "Last month", "This year"], id: \.self) {
                    Text($0)
                }
            }.frame(width: 200)
            if !model.request.accept.isEmpty {
                Toggle("Allowed types only", isOn: $model.matchingTypesOnly)
                    .help("Show files accepted by this website")
            }
            Spacer(minLength: 0)
        }.font(.system(size: 11)).padding(.horizontal, 10).padding(.bottom, 10)
    }

    @ViewBuilder private var fileContent: some View {
        if (model.loading && !model.hasSearch) || (search.searching && model.rows.isEmpty) {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty {
            Text(model.hasSearch ? "No files match your search" : "No files match in \(model.location.title)").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.grid {
            gridContent
        } else {
            Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 7) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: row.id)).resizable().frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).lineLimit(1)
                            if model.hasSearch {
                                Text(row.url.deletingLastPathComponent().path)
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }.help(row.id)
                            .foregroundStyle(row.directory || model.request.allows(row.url) ? .primary : .tertiary)
                    }.padding(.vertical, 3)
                }.width(min: 140, ideal: 240)
                TableColumn("Date Modified", value: \.modifiedForSorting) { row in
                    Text(row.modified?.formatted(date: .abbreviated, time: .omitted) ?? "")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.width(105)
                TableColumn("Size", value: \.sizeForSorting) { row in
                    Text(row.directory ? "" : row.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.width(65)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { _ in
                model.openSelection(choose: choose)
            }
            .focused($filesFocused)
        }
    }

    private var gridContent: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        ForEach(model.rows) { row in
                            VStack(spacing: 7) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: row.id)).resizable()
                                    .frame(width: 44, height: 44)
                                Text(row.name).font(.system(size: 12)).lineLimit(2)
                                    .multilineTextAlignment(.center).frame(height: 32)
                            }
                            .padding(9).frame(maxWidth: .infinity)
                            .background(model.selection.contains(row.id) ? Color.accentColor.opacity(0.2) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .opacity(row.directory || model.request.allows(row.url) ? 1 : 0.4)
                            .contentShape(Rectangle())
                            .help(row.id)
                            .onTapGesture(count: 2) {
                                model.selection = [row.id]
                                model.openSelection(choose: choose)
                            }
                            .onTapGesture { filesFocused = true; model.select(row) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { filesFocused = true; model.select(row) }
                            .id(row.id)
                        }
                    }.padding(12)
                }
                .focusable().focused($filesFocused)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    let columns = max(1, Int((geometry.size.width - 12) / 112))
                    let offset: Int
                    switch press.key {
                    case .leftArrow: offset = -1
                    case .rightArrow: offset = 1
                    case .upArrow: offset = -columns
                    case .downArrow: offset = columns
                    default: return .ignored
                    }
                    model.moveSelection(by: offset, extending: press.modifiers.contains(.shift))
                    return .handled
                }
                .onChange(of: model.selection) { _, selected in
                    if let id = model.rows.last(where: { selected.contains($0.id) })?.id {
                        scroll.scrollTo(id)
                    }
                }
            }
        }
    }

    private func tagColor(_ location: BrowserPickerLocation) -> Color {
        guard case .tag(let name) = location else { return .secondary }
        switch name.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        default: return .gray
        }
    }

    @ViewBuilder private var preview: some View {
        if let file = model.previewFile {
            VStack(spacing: 8) {
                PreviewPane(path: file.id, page: nil, term: nil)
                Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text(file.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }.padding(12)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc").font(.system(size: 32)).foregroundStyle(.tertiary)
                Text("Select a file to preview").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if model.ancestors.isEmpty { Text(model.location.title).font(.system(size: 11)) }
                ForEach(model.ancestors, id: \.path) { url in
                    if url.path != "/" { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
                    Button(url.path == "/" ? "Macintosh HD" : url.lastPathComponent) { model.navigate(url) }
                        .buttonStyle(.plain).font(.system(size: 11))
                }
            }.padding(10)
        }
    }
}

@MainActor
final class BrowserUploadController: NSObject, NSWindowDelegate, NSOpenSavePanelDelegate {
    private var window: NSWindow?
    private var model: BrowserFilePickerModel?
    private var session: BrowserUploadSession?
    private var pending: [BrowserUploadSession] = []
    private var timer: Timer?
    private var nativePanel: NSOpenPanel?
    private var keyMonitor: Any?
    var hasSession: Bool { session != nil }

    func receive(_ url: URL) {
        guard url.scheme == "leaf-upload", url.host == "pick",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let sourceText = components.queryItems?.first(where: { $0.name == "source" })?.value,
              let source = BrowserSource(rawValue: sourceText),
              let token = components.queryItems?.first(where: { $0.name == "session" })?.value,
              let id = UUID(uuidString: token), session?.id != id, !pending.contains(where: { $0.id == id }) else { return }
        let request = BrowserUploadSession(id: id, source: source)
        guard (try? request.request()) != nil else { return }
        pending.append(request)
        if session == nil { next() }
    }

    func toggle() {
        if nativePanel != nil { show(); return }
        guard let window else { return }
        if window.isVisible { window.orderOut(nil) }
        else { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        nativePanel?.makeKeyAndOrderFront(nil)
    }

    private func next() {
        guard !pending.isEmpty else { return }
        let session = pending.removeFirst()
        guard let request = try? session.request(), !session.cancelled else { next(); return }
        self.session = session
        let model = BrowserFilePickerModel(request: request)
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_040, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Leaf"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: BrowserFilePicker(model: model, search: model.search,
            choose: { [weak self] in self?.choose() }, cancel: { [weak self] in self?.cancel() },
            useFinder: { [weak self] in self?.useFinder() }))
        window.center()
        self.window = window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model, event.window === self.window,
                  self.nativePanel == nil, !model.exporting, !model.showingGoToFolder else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if modifiers == [.command, .shift] {
                if event.charactersIgnoringModifiers?.lowercased() == "g" {
                    model.beginGoToFolder()
                    return nil
                }
                if event.keyCode == 47 {
                    model.showHiddenFiles.toggle()
                    return nil
                }
            }
            if modifiers == .command {
                switch event.charactersIgnoringModifiers {
                case "r": model.refresh(); return nil
                case "[": model.goBack(); return nil
                case "]": model.goForward(); return nil
                default: break
                }
                if event.keyCode == 126 { model.goToParent(); return nil }
            }
            return event
        }
        show()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                if session.cancelled || (try? session.request()) == nil { self.close() }
            }
        }
    }

    private func choose() {
        guard let model, model.canChoose else { return }
        export(model.selectedFiles)
    }

    private func useFinder() {
        guard let window, let model, let session, !model.exporting, nativePanel == nil else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose \(model.request.multiple ? "files" : "a file") for \(model.request.displayOrigin)"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = model.request.multiple
        panel.directoryURL = model.location.folder
        panel.delegate = self
        nativePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.session?.id == session.id else { return }
            self.nativePanel = nil
            if response == .OK { self.export(panel.urls) }
        }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return true }
        return model?.request.allows(url) ?? false
    }

    private func export(_ urls: [URL]) {
        guard let session, let model, !model.exporting else { return }
        let request = model.request
        model.exporting = true
        model.error = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try session.export(urls, request: request) }
            Task { @MainActor in
                guard let self, self.session?.id == session.id else { return }
                model.exporting = false
                switch result {
                case .success:
                    for url in urls { Store.shared.recordPick(query: model.search.text, path: url.path) }
                    self.close()
                case .failure(let error): model.error = error.localizedDescription
                }
            }
        }
    }

    private func cancel() {
        if let session { try? session.respond(BrowserUploadResponse(status: "cancelled")) }
        close()
    }

    private func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        timer?.invalidate()
        timer = nil
        nativePanel?.cancel(nil)
        nativePanel = nil
        model?.stop()
        window?.orderOut(nil)
        window = nil
        model = nil
        session = nil
        next()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
}
