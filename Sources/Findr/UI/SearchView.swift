import FindrCore
import SwiftUI

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.6)
            if let error = model.actionError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { model.clearActionError() }
                        .buttonStyle(.plain)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 18).padding(.vertical, 8)
            }
            content
            Divider().opacity(0.6)
            footer
        }
        // The panel's hidden title bar would otherwise push everything down.
        .ignoresSafeArea()
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusRequest) { fieldFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search files, e.g. pace pdf last week", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($fieldFocused)
            if model.searching {
                ProgressView().controlSize(.small)
            }
            if let label = model.query.filterLabel {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    @ViewBuilder
    private var content: some View {
        if model.text.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyHint(history: Array(Store.shared.history.prefix(6))) { model.text = $0 }
        } else if model.flat.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text(model.searching ? "Searching…" : "No files match")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(.tertiary) }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 0) {
                results
                if model.previewOpen, let item = model.selectedItem {
                    Divider()
                    PreviewPane(path: item.candidate.path,
                                page: model.snippet(for: item)?.page,
                                term: model.query.terms.max { $0.count < $1.count })
                        .frame(width: 440)
                }
            }
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            if model.expandedSection != nil {
                HStack {
                    Button { model.showOverview() } label: {
                        Label("Back to all results", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    Spacer()
                }
            }
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 6)
            }
            if !model.visibleName.isEmpty {
                resultSection(.name, title: "Name matches", items: model.visibleName,
                              total: model.name.count, offset: 0)
            }
            if !model.visibleName.isEmpty && !model.visibleInside.isEmpty {
                Divider()
            }
            if !model.visibleInside.isEmpty {
                resultSection(.inside, title: "Found inside", items: model.visibleInside,
                              total: model.inside.count, offset: model.visibleName.count)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultSection(_ section: FindrCore.Section, title: String,
                               items: [ResultItem], total: Int, offset: Int) -> some View {
        VStack(spacing: 0) {
            header(title, count: total)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        rows(items, offset: offset)
                    }
                    .padding(.bottom, 4)
                }
                .onChange(of: model.selected) {
                    guard let item = model.selectedItem, item.section == section else { return }
                    proxy.scrollTo(item.id)
                }
                .onChange(of: model.expandedSection) {
                    if let id = items.first?.id { proxy.scrollTo(id, anchor: .top) }
                }
                .onChange(of: model.text) {
                    if let id = items.first?.id { proxy.scrollTo(id, anchor: .top) }
                }
            }
            if model.expandedSection == nil && total > items.count {
                Button { model.showAll(section) } label: {
                    HStack {
                        Text("Show all \(total)")
                        Image(systemName: "arrow.right")
                        Spacer()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 20).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rows(_ items: [ResultItem], offset: Int) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            ResultRow(item: item,
                      isSelected: offset + index == model.selected,
                      listFocused: model.listFocused,
                      terms: model.query.terms,
                      filterLabel: model.query.filterLabel,
                      snippet: item.section == .inside ? model.snippet(for: item) : nil)
                .id(item.id)
                .onTapGesture(count: 2) { model.open(item) }
                .onTapGesture {
                    model.selected = offset + index
                    model.listFocused = true
                }
                .onDrag { NSItemProvider(object: URL(fileURLWithPath: item.candidate.path) as NSURL) }
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↵", "Open")
            hint("⌘↵", "Show in Finder")
            hint("⌘Y", "Preview")
            hint("⌘C", "Copy file")
            hint("⌘⇧C", "Copy path")
            hint("⌘O", "Open with")
            Spacer()
            if let toast = model.toast {
                Text(toast).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 11, weight: .semibold, design: .rounded))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

/// Shown before anything is typed: how to search, plus recent searches.
private struct EmptyHint: View {
    let history: [String]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Type part of a name. Add a type, date or folder if you like:")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(["pace pdf", "notes doc this week", "screenshot today", "invoice in downloads"], id: \.self) {
                        example in
                        Button(example) { pick(example) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
            }
            if !history.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECENT  (↑ in an empty bar)")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    ForEach(history, id: \.self) { entry in
                        Button { pick(entry) } label: {
                            Label(entry, systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
