import FindrCore
import Foundation

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
    static func find(path: String, terms: [String], isCurrent: () -> Bool = { true }) -> Snippet? {
        guard isCurrent() else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        func active() -> Bool { isCurrent() && ProcessInfo.processInfo.systemUptime < deadline }
        guard let term = terms.max(by: { $0.count < $1.count }), !term.isEmpty else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "pdf" { return inPDF(path: path, term: term, isCurrent: active) }
        if textExtensions.contains(ext) { return inText(path: path, term: term, isCurrent: active) }
        return nil
    }

    /// Reads the bytes here, parses them in the sandboxed helper (see PDFReaderService).
    static func inPDF(path: String, term: String, isCurrent: () -> Bool = { true }) -> Snippet? {
        guard isCurrent() else { return nil }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size <= PDFReaderService.maxBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe), isCurrent() else { return nil }
        return PDFReaderService.snippet(data: data, term: term)
    }

    static func inText(path: String, term: String, isCurrent: () -> Bool = { true }) -> Snippet? {
        guard isCurrent() else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        do {
            while data.count < 4 << 20 {
                guard isCurrent() else { return nil }
                guard let chunk = try handle.read(upToCount: min(64 << 10, (4 << 20) - data.count)),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch { return nil }
        guard isCurrent() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return excerpt(in: text, term: term).map { Snippet(page: nil, text: $0) }
    }

    /// About 90 characters around the first word that starts with the term.
    static func excerpt(in text: String, term: String) -> String? {
        SnippetText.excerpt(in: text, term: term)
    }
}
