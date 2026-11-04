import FindrCore
import Foundation
import PDFKit

/// Where a word appears inside a file: the page (for PDFs) and a short line around it.
struct Snippet: Equatable {
    var page: Int?
    var text: String
}

enum Snippets {
    static let textExtensions: Set<String> = FileKind.code.extensions
        .union(["txt", "md", "csv", "tsv", "tex", "rtf"])

    /// Looks for the first word starting with the longest term. Nil when the file type
    /// can't be read here (docx, pages, keynote...) or the word isn't found.
    static func find(path: String, terms: [String]) -> Snippet? {
        guard let term = terms.max(by: { $0.count < $1.count }), !term.isEmpty else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "pdf" { return inPDF(path: path, term: term) }
        if textExtensions.contains(ext) { return inText(path: path, term: term) }
        return nil
    }

    static func inPDF(path: String, term: String) -> Snippet? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        for index in 0..<min(doc.pageCount, 800) {
            guard let text = doc.page(at: index)?.string, let line = excerpt(in: text, term: term) else { continue }
            return Snippet(page: index + 1, text: line)
        }
        return nil
    }

    static func inText(path: String, term: String) -> Snippet? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 4 << 20)
        let text = String(decoding: data, as: UTF8.self)
        return excerpt(in: text, term: term).map { Snippet(page: nil, text: $0) }
    }

    /// About 90 characters around the first word that starts with the term.
    static func excerpt(in text: String, term: String) -> String? {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term)
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex
        let squeezed = text[start..<end]
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + squeezed + (end < text.endIndex ? "…" : "")
    }
}
