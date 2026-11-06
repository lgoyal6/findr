import FindrCore
import Foundation

/// Talks to the sandboxed LeafPDFReader helper inside the app bundle. PDFs are never
/// parsed in Leaf's own process; without the helper (a bare `swift build` binary)
/// PDF snippets are simply skipped.
enum PDFReaderService {
    static let serviceName = "io.github.lgoyal6.findr.pdfreader"
    static let maxBytes = 100 << 20

    private static let lock = NSLock()
    nonisolated(unsafe) private static var connection: NSXPCConnection?

    static var isBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Contents/XPCServices/LeafPDFReader.xpc")
    }

    private static func current() -> NSXPCConnection? {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        guard isBundled else { return nil }
        let made = NSXPCConnection(serviceName: serviceName)
        made.remoteObjectInterface = NSXPCInterface(with: PDFSnippetReading.self)
        made.invalidationHandler = { reset() }
        made.interruptionHandler = { reset() }
        made.resume()
        connection = made
        return made
    }

    private static func reset() {
        lock.lock(); defer { lock.unlock() }
        connection = nil
    }

    /// Page and line where the term appears, or nil. Gives up after `timeout` seconds.
    static func snippet(data: Data, term: String, timeout: TimeInterval = 3) -> Snippet? {
        guard let connection = current() else { return nil }
        let done = DispatchSemaphore(value: 0)
        let result = Box()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? PDFSnippetReading
        guard let proxy else { return nil }
        proxy.findSnippet(inPDF: data, term: term) { page, line in
            if page > 0, let line { result.set(Snippet(page: page, text: line)) }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // A stuck parse: drop this helper so the next request gets a fresh one.
            connection.invalidate()
            return nil
        }
        return result.get()
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Snippet?
        func set(_ snippet: Snippet) { lock.lock(); value = snippet; lock.unlock() }
        func get() -> Snippet? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
