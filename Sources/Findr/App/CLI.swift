import FindrCore
import Foundation

/// `findr --query "pace pdf"` prints what the panel would show, for checking ranking from a terminal.
enum CLI {
    static func run(_ text: String) {
        let started = Date()
        var last: SearchSnapshot?
        SearchEngine.run(text, picks: Store.shared.picks(for: text), skips: Store.shared.skipFolders,
                         isCurrent: { true }, publish: { last = $0 })
        guard let snapshot = last else { return }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("query: \(text)  terms=\(snapshot.query.terms) filters=\(snapshot.query.filterLabel ?? "none")  \(ms) ms")
        if let notice = snapshot.notice { print("notice: \(notice)") }
        let home = NSHomeDirectory()
        func show(_ title: String, _ items: [ResultItem], snippets: Bool) {
            print("\n\(title.uppercased()) (\(items.count))")
            for item in items.prefix(12) {
                let path = item.candidate.path.replacingOccurrences(of: home, with: "~")
                let copies = item.copies.isEmpty ? "" : "  +\(item.copies.count) cop\(item.copies.count == 1 ? "y" : "ies")"
                var tag = item.tag
                if snippets, let s = Snippets.find(path: item.candidate.path, terms: snapshot.query.terms) {
                    if let page = s.page { tag += " p.\(page)" }
                }
                print("  [\(tag)] \(path)\(copies)")
            }
        }
        show("Name", snapshot.output.name, snippets: false)
        show("Inside", snapshot.output.inside, snippets: true)
    }
}
