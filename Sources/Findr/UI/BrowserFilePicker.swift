import AppKit
import Combine
import FindrCore
import LeafBrowserBridge
import SwiftUI

struct BrowserFileRow: Identifiable {
    let url: URL
    let directory: Bool
    let modified: Date?
    let size: Int64?
    var id: String { url.path }
    var name: String { url.lastPathComponent }

    init(_ url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        directory = values?.isDirectory ?? false
        modified = values?.contentModificationDate
        size = values?.fileSize.map(Int64.init)
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
    @Published var selection = Set<String>()
    @Published var grid = false
    @Published var preview = true
    @Published var error: String?
    @Published var exporting = false
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
        metadataQuery?.stop()
        metadataObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var selectedFiles: [URL] { rows.filter { selection.contains($0.id) && !$0.directory }.map(\.url) }
    var previewFile: BrowserFileRow? { rows.first { selection.contains($0.id) && !$0.directory } }
    var canChoose: Bool { !exporting && !selectedFiles.isEmpty && selectedFiles.allSatisfy(request.allows) }

    var rows: [BrowserFileRow] {
        guard !search.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return files }
        var seen = Set<String>()
        return (search.name + search.inside).compactMap { item in
            let url = URL(fileURLWithPath: item.candidate.path)
            guard seen.insert(url.path).inserted else { return nil }
            return BrowserFileRow(url)
        }
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

    func select(_ row: BrowserFileRow) {
        guard !exporting else { return }
        if request.multiple, NSEvent.modifierFlags.contains(.command) {
            if selection.contains(row.id) { selection.remove(row.id) }
            else { selection.insert(row.id) }
        } else { selection = [row.id] }
    }

    func openSelection(choose: () -> Void) {
        guard let row = rows.first(where: { selection.contains($0.id) }) else { return }
        if row.directory { navigate(row.url) }
        else if canChoose { choose() }
    }

    func loadFolder() {
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
                options: [.skipsHiddenFiles]).map(BrowserFileRow.init).sorted {
                    if $0.directory != $1.directory { return $0.directory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
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
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if !model.request.accept.isEmpty {
                    Text("Allowed types \(model.request.accept)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(model.request.multiple && model.selectedFiles.count > 1
                       ? "Choose \(model.selectedFiles.count) Files" : "Choose", action: choose)
                    .keyboardShortcut(.defaultAction).disabled(!model.canChoose)
            }.padding(14)
        }
        .frame(minWidth: 820, minHeight: 490)
        .disabled(model.exporting)
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
                .disabled(!model.canGoBack).help("Back")
            Button(action: model.goForward) { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward).help("Forward")
            Text(model.location.title).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 4)
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
                if search.searching { ProgressView().controlSize(.mini) }
            }.padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                .frame(width: 215)
        }.buttonStyle(.borderless).padding(10)
    }

    @ViewBuilder private var fileContent: some View {
        if model.loading, search.text.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty, search.text.isEmpty {
            Text("No items in \(model.location.title)").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
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
                        .onTapGesture(count: 2) { model.select(row); model.openSelection(choose: choose) }
                        .onTapGesture { model.select(row) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.select(row) }
                    }
                }.padding(12)
            }
        } else {
            Table(model.rows, selection: $model.selection) {
                TableColumn("Name") { row in
                    HStack(spacing: 7) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: row.id)).resizable().frame(width: 18, height: 18)
                        Text(row.name).lineLimit(1)
                            .foregroundStyle(row.directory || model.request.allows(row.url) ? .primary : .tertiary)
                    }.padding(.vertical, 3)
                }.width(min: 140, ideal: 240)
                TableColumn("Date Modified") { row in
                    Text(row.modified?.formatted(date: .abbreviated, time: .omitted) ?? "")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.width(105)
                TableColumn("Size") { row in
                    Text(row.directory ? "" : row.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.width(65)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { _ in
                model.openSelection(choose: choose)
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
final class BrowserUploadController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: BrowserFilePickerModel?
    private var session: BrowserUploadSession?
    private var pending: [BrowserUploadSession] = []
    private var timer: Timer?
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
        guard let window else { return }
        if window.isVisible { window.orderOut(nil) }
        else { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
            choose: { [weak self] in self?.choose() }, cancel: { [weak self] in self?.cancel() }))
        window.center()
        self.window = window
        show()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                if session.cancelled || (try? session.request()) == nil { self.close() }
            }
        }
    }

    private func choose() {
        guard let session, let model, model.canChoose else { return }
        let urls = model.selectedFiles
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
        timer?.invalidate()
        timer = nil
        model?.stop()
        window?.orderOut(nil)
        window = nil
        model = nil
        session = nil
        next()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
}
