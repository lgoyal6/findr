import Foundation

/// The XPC interface of the sandboxed PDF reader. Leaf hands it a PDF's bytes and a word;
/// the reader parses the PDF with no file or network access and returns the page and line.
@objc public protocol PDFSnippetReading {
    /// Page is 1-based, or 0 with a nil line when the word is not found.
    func findSnippet(inPDF data: Data, term: String, withReply reply: @escaping (Int, String?) -> Void)
}

public enum SnippetText {
    /// About 90 characters around the first word that starts with the term.
    public static func excerpt(in text: String, term: String) -> String? {
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
