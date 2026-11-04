import AppKit
import PDFKit
import Quartz
import SwiftUI

/// Preview of the selected file. PDFs open at the page where the word was found,
/// with the word highlighted; everything else uses Quick Look.
struct PreviewPane: NSViewRepresentable {
    let path: String
    let page: Int?
    let term: String?

    final class Coordinator {
        var shown: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let key = "\(path)|\(page ?? 0)|\(term ?? "")"
        guard context.coordinator.shown != key else { return }
        context.coordinator.shown = key
        view.subviews.forEach { $0.removeFromSuperview() }

        let url = URL(fileURLWithPath: path)
        let content: NSView
        if url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url) {
            let pdfView = PDFView()
            pdfView.document = doc
            pdfView.autoScales = true
            pdfView.displayMode = .singlePageContinuous
            pdfView.backgroundColor = .clear
            if let page, let target = doc.page(at: page - 1) {
                pdfView.go(to: target)
                if let term { pdfView.highlightedSelections = Self.selections(of: term, on: target) }
            }
            content = pdfView
        } else if let ql = QLPreviewView(frame: .zero, style: .normal) {
            ql.previewItem = url as NSURL
            ql.autostarts = true
            content = ql
        } else {
            content = NSView()
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Every word on the page starting with the term, as highlight selections.
    static func selections(of term: String, on page: PDFPage) -> [PDFSelection] {
        guard let text = page.string else { return [] }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\w*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.prefix(40).compactMap { match in
            let selection = page.selection(for: match.range)
            selection?.color = NSColor.systemYellow.withAlphaComponent(0.6)
            return selection
        }
    }
}
