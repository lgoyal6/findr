import AppKit
import Foundation
import UniformTypeIdentifiers

public enum BrowserSource: String, Codable, Sendable {
    case chrome, safari
}

public struct BrowserUploadRequest: Codable, Sendable {
    public let origin: String
    public let accept: String
    public let multiple: Bool
    public let created: Date

    public var displayOrigin: String {
        URL(string: origin)?.host ?? "Local file"
    }

    public func allows(_ url: URL) -> Bool {
        let filters = accept.lowercased().split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !filters.isEmpty else { return true }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        return filters.contains { filter in
            if filter.hasPrefix(".") { return ext == String(filter.dropFirst()) }
            if filter.hasSuffix("/*") {
                return type?.preferredMIMEType?.hasPrefix(String(filter.dropLast())) == true
            }
            return type?.preferredMIMEType?.lowercased() == filter
        }
    }
}

public struct BrowserUploadFile: Codable {
    public let name: String
    public let type: String
    public let size: UInt64
    public let lastModified: Double
}

public struct BrowserUploadResponse: Codable {
    public let status: String
    public let files: [BrowserUploadFile]
    public let error: String?

    public init(status: String, files: [BrowserUploadFile] = [], error: String? = nil) {
        self.status = status
        self.files = files
        self.error = error
    }
}

public struct BrowserUploadSession: Sendable {
    public static let safariIdentifier = "io.github.lgoyal6.findr.safari"
    public let id: UUID
    public let source: BrowserSource
    public let directory: URL

    public init(id: UUID, source: BrowserSource, inNativeHost: Bool = false) {
        self.id = id
        self.source = source
        let caches: URL
        if source == .safari, !inNativeHost {
            caches = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(Self.safariIdentifier)/Data/Library/Caches")
        } else {
            caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        }
        directory = caches.appendingPathComponent("LeafBrowserUploads", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func request() throws -> BrowserUploadRequest {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw failure("Invalid upload session.") }
        let data = try Data(contentsOf: directory.appendingPathComponent("request.json"))
        guard data.count <= 16_384 else { throw failure("Invalid upload request.") }
        let request = try JSONDecoder().decode(BrowserUploadRequest.self, from: data)
        guard (0..<600).contains(Date().timeIntervalSince(request.created)),
              ["http", "https", "file"].contains(URL(string: request.origin)?.scheme ?? "") else {
            throw failure("This upload request has expired. Click Upload again.")
        }
        return request
    }

    public var cancelled: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel").path) }

    public func respond(_ response: BrowserUploadResponse) throws {
        try JSONEncoder().encode(response).write(to: directory.appendingPathComponent("response.json"), options: .atomic)
    }

    public func export(_ urls: [URL], request: BrowserUploadRequest) throws {
        guard !urls.isEmpty, request.multiple || urls.count == 1 else { throw failure("Choose a file to continue.") }
        let files = directory.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.removeItem(at: files)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: files) } }
        var metadata: [BrowserUploadFile] = []
        for (index, url) in urls.enumerated() {
            guard !cancelled, request.allows(url), FileManager.default.isReadableFile(atPath: url.path),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw failure("Choose readable files that match the website’s allowed types.")
            }
            let target = files.appendingPathComponent(String(index))
            try FileManager.default.copyItem(at: url, to: target)
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            let modified = attributes[.modificationDate] as? Date ?? Date()
            metadata.append(BrowserUploadFile(name: url.lastPathComponent,
                type: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                lastModified: modified.timeIntervalSince1970 * 1_000))
        }
        guard !cancelled else { throw failure("Upload cancelled.") }
        try respond(BrowserUploadResponse(status: "selected", files: metadata))
        completed = true
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "LeafBrowserUpload", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Both browser hosts expose the same bounded protocol. Only explicitly chosen snapshots can be read.
public enum BrowserNativeHost {
    public static func handle(_ message: [String: Any], source: BrowserSource) throws -> [String: Any] {
        let action = message["action"] as? String ?? ""
        if action == "choose" {
            guard let origin = message["origin"] as? String, origin.count < 2_048,
                  ["http", "https", "file"].contains(URL(string: origin)?.scheme ?? "") else {
                throw protocolError("Unsupported upload origin.")
            }
            let session = BrowserUploadSession(id: UUID(), source: source, inNativeHost: true)
            try FileManager.default.createDirectory(at: session.directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let request = BrowserUploadRequest(origin: origin,
                accept: String((message["accept"] as? String ?? "").prefix(4_096)),
                multiple: message["multiple"] as? Bool ?? false, created: Date())
            try JSONEncoder().encode(request).write(to: session.directory.appendingPathComponent("request.json"), options: .atomic)
            let url = URL(string: "leaf-upload://pick?source=\(source.rawValue)&session=\(session.id.uuidString)")!
            guard NSWorkspace.shared.open(url) else {
                try? FileManager.default.removeItem(at: session.directory)
                throw protocolError("Open Leaf from Applications, then try Upload again.")
            }
            return ["status": "pending", "session": session.id.uuidString]
        }
        guard let token = message["session"] as? String, let id = UUID(uuidString: token) else {
            throw protocolError("Invalid upload session.")
        }
        let session = BrowserUploadSession(id: id, source: source, inNativeHost: true)
        _ = try session.request()
        switch action {
        case "status":
            let response = session.directory.appendingPathComponent("response.json")
            guard FileManager.default.fileExists(atPath: response.path) else { return ["status": "pending"] }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any] ?? [:]
        case "read":
            guard let index = message["index"] as? Int, let offset = message["offset"] as? Int,
                  index >= 0, offset >= 0 else { throw protocolError("Invalid file chunk.") }
            let response = try JSONDecoder().decode(BrowserUploadResponse.self,
                from: Data(contentsOf: session.directory.appendingPathComponent("response.json")))
            guard response.status == "selected", response.files.indices.contains(index),
                  UInt64(offset) <= response.files[index].size else { throw protocolError("Invalid file chunk.") }
            let file = try FileHandle(forReadingFrom: session.directory.appendingPathComponent("files/\(index)"))
            defer { try? file.close() }
            try file.seek(toOffset: UInt64(offset))
            let data = try file.read(upToCount: 196_608) ?? Data()
            return ["data": data.base64EncodedString(), "length": data.count]
        case "cancel":
            try Data().write(to: session.directory.appendingPathComponent("cancel"))
            return ["status": "cancelled"]
        case "finish":
            try FileManager.default.removeItem(at: session.directory)
            return ["status": "finished"]
        default:
            throw protocolError("Unknown upload action.")
        }
    }

    private static func protocolError(_ message: String) -> NSError {
        NSError(domain: "LeafBrowserUpload", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
