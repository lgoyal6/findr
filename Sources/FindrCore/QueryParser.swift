import Foundation

public struct DateRange: Equatable, Sendable {
    public let start: Date
    /// Exclusive. Nil means "up to now".
    public let end: Date?
    public let label: String

    public func contains(_ date: Date) -> Bool {
        date >= start && (end.map { date < $0 } ?? true)
    }
}

public struct ParsedQuery: Equatable, Sendable {
    /// Words to match against names and contents, lowercased.
    public var terms: [String]
    public var kinds: Set<FileKind>
    public var date: DateRange?
    /// Folder name under home, e.g. "Downloads".
    public var folder: String?
    /// Every word as a plain term, used when the filtered search finds nothing.
    public var plainTerms: [String]

    public var hasFilters: Bool { !kinds.isEmpty || date != nil || folder != nil }

    /// The same query with every word treated as a plain search word.
    public var asPlain: ParsedQuery {
        ParsedQuery(terms: plainTerms, kinds: [], date: nil, folder: nil, plainTerms: plainTerms)
    }

    /// Short description of the active filters, e.g. "pdf · last week".
    public var filterLabel: String? {
        var parts = kinds.map(\.rawValue).sorted()
        if let date { parts.append(date.label) }
        if let folder { parts.append("in \(folder.lowercased())") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public enum QueryParser {
    static let folders = ["downloads": "Downloads", "desktop": "Desktop", "documents": "Documents",
                          "pictures": "Pictures", "movies": "Movies", "music": "Music"]

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedQuery {
        let words = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map(clean)
            .filter { !$0.isEmpty }

        var query = ParsedQuery(terms: [], kinds: [], date: nil, folder: nil, plainTerms: words)
        var i = 0
        while i < words.count {
            let word = words[i]
            let next = i + 1 < words.count ? words[i + 1] : nil

            if word == "in", let next, let folder = folders[next] {
                query.folder = folder
                i += 2
                continue
            }
            if let next, let range = dateRange(for: "\(word) \(next)", now: now, calendar: calendar) {
                query.date = range
                i += 2
                continue
            }
            if let range = dateRange(for: word, now: now, calendar: calendar) {
                query.date = range
                i += 1
                continue
            }
            if let kind = FileKind.words[word] {
                query.kinds.insert(kind)
                i += 1
                continue
            }
            query.terms.append(word)
            i += 1
        }
        return query
    }

    /// Strips characters that would break a Spotlight query string.
    static func clean(_ word: String) -> String {
        word.filter { !"\"*\\'".contains($0) }
    }

    static func dateRange(for phrase: String, now: Date, calendar: Calendar) -> DateRange? {
        let today = calendar.startOfDay(for: now)
        func start(of unit: Calendar.Component) -> Date {
            calendar.dateInterval(of: unit, for: now)?.start ?? today
        }
        func add(_ value: Int, _ unit: Calendar.Component, to date: Date) -> Date {
            calendar.date(byAdding: unit, value: value, to: date) ?? date
        }
        switch phrase {
        case "today":
            return DateRange(start: today, end: nil, label: "today")
        case "yesterday":
            return DateRange(start: add(-1, .day, to: today), end: today, label: "yesterday")
        case "this week":
            return DateRange(start: start(of: .weekOfYear), end: nil, label: "this week")
        case "last week":
            let thisWeek = start(of: .weekOfYear)
            return DateRange(start: add(-1, .weekOfYear, to: thisWeek), end: thisWeek, label: "last week")
        case "this month":
            return DateRange(start: start(of: .month), end: nil, label: "this month")
        case "last month":
            let thisMonth = start(of: .month)
            return DateRange(start: add(-1, .month, to: thisMonth), end: thisMonth, label: "last month")
        case "this year":
            return DateRange(start: start(of: .year), end: nil, label: "this year")
        default:
            return nil
        }
    }
}
