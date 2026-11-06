import FindrCore
import Foundation
import PDFKit

/// Runs inside an App Sandbox with no entitlements: it cannot open files, reach the
/// network or see Leaf's folder access. A PDF crafted to exploit a parser bug lands here,
/// not in Leaf.
final class Reader: NSObject, PDFSnippetReading {
    func findSnippet(inPDF data: Data, term: String, withReply reply: @escaping (Int, String?) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        guard !term.isEmpty, let doc = PDFDocument(data: data) else { return reply(0, nil) }
        for index in 0..<min(doc.pageCount, 800) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if let text = doc.page(at: index)?.string, let line = SnippetText.excerpt(in: text, term: term) {
                return reply(index + 1, line)
            }
        }
        reply(0, nil)
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PDFSnippetReading.self)
        connection.exportedObject = Reader()
        connection.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
