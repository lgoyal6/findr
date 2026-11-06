import AppKit
import FindrCore
import SwiftUI

/// File icons are slow to fetch, so keep the ones already shown.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 64, height: 64)
        if icons.count > 2000 { icons.removeAll() }
        icons[path] = icon
        return icon
    }
}

struct ResultRow: View {
    let item: ResultItem
    let isSelected: Bool
    let listFocused: Bool
    let terms: [String]
    let filterLabel: String?
    let snippet: Snippet?
    @Environment(\.colorSchemeContrast) private var contrast

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: IconCache.icon(for: item.candidate.path))
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(highlightedName)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !item.copies.isEmpty {
                        Text("+\(item.copies.count) cop\(item.copies.count == 1 ? "y" : "ies")")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                            .help(item.copies.joined(separator: "\n"))
                    }
                }
                Text(folder)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.head)
                if let snippet {
                    Text(snippet.text)
                        .font(.system(size: 11))
                        .italic()
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85))
                                         : contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(isSelected ? Color.white.opacity(0.22) : tagColor.opacity(0.16)))
                    .foregroundStyle(isSelected ? Color.white : tagColor)
                if let date {
                    Text(date)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(listFocused ? 1 : 0.75) : Color.clear)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens the file")
    }

    /// What VoiceOver reads for the row: name, where it is, why it matched and when.
    var accessibilityText: String {
        var parts = [item.candidate.name.trimmingCharacters(in: .whitespaces), "in \(folder)"]
        if !item.copies.isEmpty { parts.append("\(item.copies.count + 1) identical copies") }
        if let snippet { parts.append(snippet.text) }
        parts.append(tag)
        if let date { parts.append(date) }
        return parts.joined(separator: ", ")
    }

    private var highlightedName: AttributedString {
        let name = item.candidate.name.trimmingCharacters(in: .whitespaces)
        var text = AttributedString(name)
        guard item.section == .name else { return text }
        for range in Matcher.highlights(in: name, terms: terms) {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].font = .system(size: 14, weight: .bold)
        }
        return text
    }

    private var folder: String {
        item.candidate.parent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Why it matched: "name", "name · typo", "inside p.3", plus any filters ("pdf · last week").
    private var tag: String {
        var parts = [item.tag]
        if item.section == .inside, let page = snippet?.page { parts[0] += " p.\(page)" }
        if let filterLabel { parts.append(filterLabel) }
        return parts.joined(separator: " · ")
    }

    private var tagColor: Color { item.section == .name ? (item.tier == .typo ? .orange : .blue) : .purple }

    private var date: String? {
        let recency = item.candidate.recency
        guard recency > .distantPast else { return nil }
        return Self.relative.localizedString(for: recency, relativeTo: Date())
    }
}
