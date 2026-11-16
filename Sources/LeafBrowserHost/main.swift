import Foundation
import LeafBrowserBridge

let input = FileHandle.standardInput
let output = FileHandle.standardOutput

func readExactly(_ count: Int) throws -> Data? {
    var data = Data()
    while data.count < count {
        guard let chunk = try input.read(upToCount: count - data.count), !chunk.isEmpty else { return nil }
        data.append(chunk)
    }
    return data
}

do {
    while let header = try readExactly(4) {
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, length <= 65_536, let body = try readExactly(Int(length)) else { break }
        let response: [String: Any]
        do {
            guard let message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { break }
            response = try BrowserNativeHost.handle(message, source: .chrome)
        } catch {
            response = ["status": "error", "error": error.localizedDescription]
        }
        let data = try JSONSerialization.data(withJSONObject: response)
        var size = UInt32(data.count).littleEndian
        try withUnsafeBytes(of: &size) { try output.write(contentsOf: Data($0)) }
        try output.write(contentsOf: data)
    }
} catch {
    FileHandle.standardError.write(Data("Leaf native host: \(error.localizedDescription)\n".utf8))
    exit(1)
}
