import CoreServices
import FindrCore
import Foundation

/// Runs Spotlight queries in-process against the index macOS already keeps.
enum Spotlight {
    /// Fetched with the results in one pass, which is much faster than asking each item.
    static let attributes = [kMDItemPath, kMDItemFSSize, kMDItemLastUsedDate, kMDItemDateAdded,
                             kMDItemContentModificationDate, kMDItemContentType] as [CFString]

    static func run(_ query: String, scopes: [String], limit: Int) -> [Candidate] {
        guard let q = MDQueryCreate(kCFAllocatorDefault, query as CFString, attributes as CFArray, nil) else {
            return []
        }
        MDQuerySetSearchScope(q, scopes as CFArray, 0)
        MDQuerySetMaxCount(q, limit)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        let count = MDQueryGetResultCount(q)
        func value(_ attribute: CFString, _ index: Int) -> AnyObject? {
            guard let raw = MDQueryGetAttributeValueOfResultAtIndex(q, attribute, index) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        }
        var results: [Candidate] = []
        results.reserveCapacity(count)
        for index in 0..<count {
            // The path is not served from the value list, so read it from the item itself.
            guard let raw = MDQueryGetResultAtIndex(q, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            results.append(Candidate(
                path: path,
                size: (value(kMDItemFSSize, index) as? NSNumber)?.int64Value,
                lastUsed: value(kMDItemLastUsedDate, index) as? Date,
                added: value(kMDItemDateAdded, index) as? Date,
                modified: value(kMDItemContentModificationDate, index) as? Date,
                isDirectory: value(kMDItemContentType, index) as? String == "public.folder"
            ))
        }
        return results
    }
}
