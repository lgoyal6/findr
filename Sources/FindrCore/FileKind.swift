import Foundation

/// Coarse file categories that the type words in a query map to.
public enum FileKind: String, CaseIterable, Sendable {
    case pdf, doc, slides, sheet, image, video, code

    public var extensions: Set<String> {
        switch self {
        case .pdf: return ["pdf"]
        case .doc: return ["doc", "docx", "pages", "rtf", "rtfd", "odt", "txt", "md", "tex", "epub"]
        case .slides: return ["ppt", "pptx", "key", "odp"]
        case .sheet: return ["xls", "xlsx", "numbers", "csv", "tsv", "ods"]
        case .image: return ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg", "raw", "dng"]
        case .video: return ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
        case .code: return [
            "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "go", "rs", "c", "cc", "cpp", "h", "hpp",
            "m", "mm", "java", "kt", "rb", "php", "sh", "zsh", "bash", "fish", "json", "yaml", "yml", "toml",
            "xml", "plist", "html", "css", "scss", "sql", "lua", "ipynb", "cs", "ini", "cfg", "conf", "env",
            "lock", "gradle", "mk", "cmake", "proto", "srt", "log", "jac", "vue", "svelte", "dart", "zig",
        ]
        }
    }

    /// The kind of a file, judged by extension. Nil for anything uncategorised.
    public static func of(path: String) -> FileKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return allCases.first { $0.extensions.contains(ext) }
    }

    /// Words a person might type for each kind.
    static let words: [String: FileKind] = [
        "pdf": .pdf, "pdfs": .pdf,
        "doc": .doc, "docs": .doc, "document": .doc, "documents": .doc, "word": .doc,
        "slides": .slides, "slide": .slides, "deck": .slides, "ppt": .slides, "keynote": .slides,
        "presentation": .slides,
        "sheet": .sheet, "sheets": .sheet, "spreadsheet": .sheet, "excel": .sheet, "csv": .sheet,
        "image": .image, "images": .image, "photo": .image, "photos": .image, "pic": .image,
        "pics": .image, "screenshot": .image, "screenshots": .image,
        "video": .video, "videos": .video, "movie": .video,
        "code": .code,
    ]
}
