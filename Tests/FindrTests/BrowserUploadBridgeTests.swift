import Foundation
import Testing
@testable import LeafBrowserBridge

struct BrowserUploadBridgeTests {
    private func session(accept: String = "", multiple: Bool = false) throws -> (BrowserUploadSession, BrowserUploadRequest) {
        let session = BrowserUploadSession(id: UUID(), source: .chrome, inNativeHost: true)
        try FileManager.default.createDirectory(at: session.directory, withIntermediateDirectories: true)
        let request = BrowserUploadRequest(origin: "https://example.test", accept: accept,
                                           multiple: multiple, created: Date())
        try JSONEncoder().encode(request).write(to: session.directory.appendingPathComponent("request.json"))
        return (session, request)
    }

    @Test func fileTypesRespectExtensionsMimeGroupsAndUnknownTypes() {
        let request = BrowserUploadRequest(origin: "https://example.test", accept: ".PDF,image/*,text/plain",
                                           multiple: false, created: Date())
        #expect(request.allows(URL(fileURLWithPath: "/report.pdf")))
        #expect(request.allows(URL(fileURLWithPath: "/photo.png")))
        #expect(request.allows(URL(fileURLWithPath: "/notes.txt")))
        #expect(!request.allows(URL(fileURLWithPath: "/script.sh")))
        let unknown = BrowserUploadRequest(origin: "https://example.test", accept: "invalid/type",
                                           multiple: false, created: Date())
        #expect(!unknown.allows(URL(fileURLWithPath: "/photo.png")))
    }

    @Test func chosenFilesAreSnapshotsAndChunksCannotReadArbitraryFiles() throws {
        let (session, request) = try session()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let original = session.directory.appendingPathComponent("report.txt")
        try Data("original".utf8).write(to: original)
        try session.export([original], request: request)
        try Data("changed".utf8).write(to: original)
        let response = try BrowserNativeHost.handle(["action": "read", "session": session.id.uuidString,
                                                    "index": 0, "offset": 0], source: .chrome)
        #expect(Data(base64Encoded: response["data"] as! String) == Data("original".utf8))
        #expect(throws: (any Error).self) {
            try BrowserNativeHost.handle(["action": "read", "session": session.id.uuidString,
                                          "index": -1, "offset": 0], source: .chrome)
        }
        #expect(throws: (any Error).self) {
            try BrowserNativeHost.handle(["action": "read", "session": "../../Desktop",
                                          "index": 0, "offset": 0], source: .chrome)
        }
    }

    @Test func failedExportCanBeRetriedAndCancellationCannotExport() throws {
        let (session, request) = try session(accept: ".pdf", multiple: true)
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let valid = session.directory.appendingPathComponent("report.pdf")
        let invalid = session.directory.appendingPathComponent("notes.txt")
        try Data("pdf fixture".utf8).write(to: valid)
        try Data("text fixture".utf8).write(to: invalid)
        #expect(throws: (any Error).self) { try session.export([valid, invalid], request: request) }
        #expect(!FileManager.default.fileExists(atPath: session.directory.appendingPathComponent("files").path))
        try session.export([valid], request: request)
        _ = try BrowserNativeHost.handle(["action": "cancel", "session": session.id.uuidString], source: .chrome)
        #expect(session.cancelled)
        #expect(throws: (any Error).self) { try session.export([valid], request: request) }
    }

    @Test func singleSelectionAndExpiredSessionsAreRejected() throws {
        let (session, request) = try session()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        #expect(throws: (any Error).self) {
            try session.export([URL(fileURLWithPath: "/a.txt"), URL(fileURLWithPath: "/b.txt")], request: request)
        }
        let expired = BrowserUploadRequest(origin: "https://example.test", accept: "", multiple: false,
                                           created: Date().addingTimeInterval(-700))
        try JSONEncoder().encode(expired).write(to: session.directory.appendingPathComponent("request.json"))
        #expect(throws: (any Error).self) { try session.request() }
    }
}
