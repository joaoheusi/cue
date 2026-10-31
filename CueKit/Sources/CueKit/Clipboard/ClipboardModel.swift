import CryptoKit
import Foundation

public struct ClipItem: Identifiable, Equatable, Sendable {
    public static let inlineBytes = 8 * 1024

    public let id: String
    public let text: String
    public let source: String?
    public let createdAt: Date
    public var lastUsedAt: Date
    public var pinboardID: String?
    public let sensitive: Bool
    public var expiresAt: Date?
    public let content: ClipContent
    public let byteSize: Int
    public let isTruncated: Bool
    public let hasOCRText: Bool
    public let kind: ClipKind
    public let folded: String
    public let preview: String
    public let foldedPreview: String

    public init(id: String, text: String, source: String?, createdAt: Date, lastUsedAt: Date, pinboardID: String?,
                sensitive: Bool = false, expiresAt: Date? = nil, content: ClipContent = .plain, byteSize: Int = 0, truncated: Bool = false, ocrText: String? = nil) {
        let inline = Self.prefix(text, bytes: Self.inlineBytes)
        self.id = id
        self.text = inline
        self.source = source
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.pinboardID = pinboardID
        self.sensitive = sensitive
        self.expiresAt = expiresAt
        self.content = content
        self.byteSize = byteSize
        isTruncated = content.isText && (truncated || inline.utf8.count < text.utf8.count)
        hasOCRText = !content.isText && ocrText?.isEmpty == false
        switch content {
        case .plain, .rich:
            kind = sensitive ? .text : ClipKind.of(inline)
            preview = sensitive ? SensitiveText.mask(inline) : ClipboardSearch.preview(inline)
            folded = sensitive ? ClipboardSearch.fold(preview) : ClipboardSearch.fold(inline)
        case .image(let type, let width, let height):
            kind = .image
            preview = "\(ClipContent.imageName(type)) image · \(width) × \(height)"
            folded = ClipboardSearch.fold(preview + "\n" + Self.prefix(ocrText ?? "", bytes: Self.inlineBytes))
        case .files(let paths):
            let names = paths.map(ClipContent.fileName)
            kind = .file
            preview = (names.first ?? "") + (names.count > 1 ? " + \(names.count - 1) more" : "")
            folded = ClipboardSearch.fold(String(names.joined(separator: " ").prefix(4096)))
        }
        foldedPreview = ClipboardSearch.fold(preview)
    }

    func withOCRText(_ ocrText: String, byteSize: Int) -> ClipItem {
        ClipItem(id: id, text: text, source: source, createdAt: createdAt, lastUsedAt: lastUsedAt, pinboardID: pinboardID, sensitive: sensitive,
                 expiresAt: expiresAt, content: content, byteSize: byteSize, truncated: isTruncated, ocrText: ocrText)
    }

    public var isPinned: Bool { pinboardID != nil }
    public var display: String { sensitive || !content.isText ? preview : text }
    public var isExportable: Bool { content.isText && !sensitive }
    public var sizeLabel: String { isTruncated ? byteLabel : "\(display.count) chars" }
    private var byteLabel: String { ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file) }

    public static func prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.utf8.index(text.startIndex, offsetBy: bytes)
        while end.samePosition(in: text.unicodeScalars) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end])
    }

    public var summary: String {
        if sensitive { return "Hidden API key or token" }
        switch content {
        case .plain, .rich:
            if isTruncated { return "\(byteLabel) of text" }
            let words = text.split(whereSeparator: \.isWhitespace).count
            return "\(text.count) character\(text.count == 1 ? "" : "s") · \(words) word\(words == 1 ? "" : "s")"
        case .image(let type, let width, let height):
            return "\(ClipContent.imageName(type)) · \(width) × \(height) · \(byteLabel)"
        case .files(let paths):
            let folders = paths.filter { $0.hasSuffix("/") }.count
            let parts = [(paths.count - folders, "file"), (folders, "folder")].filter { $0.0 > 0 }
            return parts.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: ", ")
        }
    }

    public var linkURL: URL? {
        guard kind == .link else { return nil }
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: URLComponents(string: link)?.scheme == nil ? "https://\(link)" : link)
    }
}

public enum ClipContent: Codable, Equatable, Sendable {
    case plain, rich
    case image(type: String, width: Int, height: Int)
    case files([String])

    public var isText: Bool {
        switch self {
        case .plain, .rich: true
        case .image, .files: false
        }
    }

    public var format: String {
        switch self {
        case .plain: "plain"
        case .rich: "rich"
        case .image: "image"
        case .files: "files"
        }
    }

    public static func imageName(_ type: String) -> String { (type.split(separator: ".").last.map(String.init) ?? type).uppercased() }
    public static func fileName(_ path: String) -> String { URL(fileURLWithPath: path).lastPathComponent }
}

public struct ClipCapture: Codable, Equatable, Sendable {
    public var content: ClipContent
    public var text: String
    public var data: [String: Data]
    public var thumbnail: Data?

    public init(content: ClipContent, text: String = "", data: [String: Data] = [:], thumbnail: Data? = nil) {
        self.content = content
        self.text = text
        self.data = data
        self.thumbnail = thumbnail
    }

    public static func plain(_ text: String) -> ClipCapture { ClipCapture(content: .plain, text: text) }
}

public struct ClipFileCheck: Equatable, Sendable {
    public let present: [String]
    public let missing: [String]

    public init(paths: [String], exists: (String) -> Bool) {
        present = paths.filter(exists)
        missing = paths.filter { !exists($0) }
    }

    public var error: CueError? {
        guard present.isEmpty, let first = missing.first else { return nil }
        let message = missing.count == 1 ? "“\(ClipContent.fileName(first))” is no longer at its saved location." : "These \(missing.count) files are no longer at their saved locations."
        return CueError("CLIPBOARD_FILES_MISSING", message)
    }

    public var warning: String? {
        guard !present.isEmpty, !missing.isEmpty else { return nil }
        let names = missing.prefix(3).map(ClipContent.fileName).joined(separator: ", ")
        return "\(missing.count) of \(present.count + missing.count) files \(missing.count == 1 ? "is" : "are") missing: \(names)\(missing.count > 3 ? ", and others" : "")."
    }
}

public enum ClipKind: String, Sendable, CaseIterable {
    case text, link, code, image, file

    public static func of(_ text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLink(trimmed) { return .link }
        return looksLikeCode(trimmed) ? .code : .text
    }

    private static func countExceeds(_ text: String, _ limit: Int) -> Bool {
        var count = 0
        for _ in text { count += 1; if count > limit { return true } }
        return false
    }

    private static let domainPattern = try! NSRegularExpression(pattern: #"^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(/\S*)?$"#)
    private static let keywords: Set<Substring> = ["func", "def", "class", "struct", "enum", "import", "from", "const", "let", "var",
                                                    "return", "if", "for", "while", "public", "private", "#include", "SELECT", "INSERT", "UPDATE"]

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func isLink(_ text: String) -> Bool {
        guard !text.isEmpty, !countExceeds(text, 2048), !text.contains(where: \.isWhitespace) else { return false }
        if let scheme = URLComponents(string: text)?.scheme, ["http", "https", "ftp", "mailto"].contains(scheme.lowercased()) { return true }
        return matches(domainPattern, text) && text.contains("/")
    }

    private static func startsWithKeyword(_ line: Substring) -> Bool {
        let word = line.prefix { $0 == "#" || ($0.isASCII && $0.isLetter) }
        guard keywords.contains(word) else { return false }
        guard let next = line.dropFirst(word.count).first else { return true }
        return !next.isLetter && !next.isNumber && next != "_" && next.unicodeScalars.allSatisfy { $0.properties.generalCategory != .nonspacingMark }
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        var lines = 0, structural = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.drop(while: \.isWhitespace)
            while line.last?.isWhitespace == true { line = line.dropLast() }
            lines += 1
            if line.hasSuffix(";") || line.hasSuffix("{") || line == "}" || line.hasSuffix(");") || startsWithKeyword(line) {
                structural += 1
            }
        }
        guard lines > 0 else { return false }
        return lines == 1 ? structural == 1 && !countExceeds(text, 399) : structural * 3 >= lines
    }
}

public enum SensitiveHandling: String, Codable, CaseIterable, Sendable {
    case maskAndExpire, mask, skip, keep

    public var title: String {
        switch self {
        case .maskAndExpire: "Mask, delete after 5 min"
        case .mask: "Mask, keep"
        case .skip: "Don’t save"
        case .keep: "Save normally"
        }
    }
}

public enum SensitiveText {
    public static let lifetime: TimeInterval = 300
    private static let maxLength = 2048
    private static let patterns = [
        #"sk-[A-Za-z0-9_-]{20,}"#, #"gh[pousr]_[A-Za-z0-9]{30,}"#, #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"xox[abprs]-[A-Za-z0-9-]{10,}"#, #"AKIA[0-9A-Z]{16}"#, #"AIza[0-9A-Za-z_-]{30,}"#, #"glpat-[A-Za-z0-9_-]{16,}"#,
        #"npm_[A-Za-z0-9]{30,}"#, #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
    ]
    private static let compiled = patterns.map { try! NSRegularExpression(pattern: $0) }
    private static let compiledAnchored = patterns.map { try! NSRegularExpression(pattern: "^\($0)$") }
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_-]{16,}"#)

    private static func firstRange(_ pattern: NSRegularExpression, in text: String, from start: String.Index? = nil) -> Range<String.Index>? {
        let range = NSRange((start ?? text.startIndex)..<text.endIndex, in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        return Range(match.range, in: text)
    }

    public static func matches(_ text: String) -> Bool {
        let scalars = text.unicodeScalars, blank = CharacterSet.whitespacesAndNewlines
        guard let first = scalars.firstIndex(where: { !blank.contains($0) }), let last = scalars.lastIndex(where: { !blank.contains($0) }),
              text.utf8.distance(from: first, to: last) < maxLength * 8 else { return false }
        let token = String(String.UnicodeScalarView(scalars[first...last]))
        guard token.count <= maxLength, !token.contains(where: \.isWhitespace) else { return false }
        return compiledAnchored.contains { firstRange($0, in: token) != nil }
    }

    static let maskedLine = "••••••••"
    private static let lookAlikes = Dictionary(uniqueKeysWithValues: zip(
        "аеорсухіјѕһАВЕКМНОРСТХЗЅІЈØøοΟαΑΒΕΖΗΙΚΜΝΡΤΥΧ–—‐ßб", "aeopcyxijshABEKMHOPCTX3SIJ00oOaABEZHIKMNPTYX---B6"))

    public static func maskedLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { hasSecret($0) ? maskedLine : String($0) }.joined(separator: "\n")
    }

    private static func hasSecret(_ line: Substring) -> Bool {
        let plain = String(line.map { lookAlikes[$0] ?? $0 })
        if compiled.contains(where: { firstRange($0, in: plain) != nil }) { return true }
        var start = plain.startIndex
        while let range = firstRange(wordPattern, in: plain, from: start) {
            let word = plain[range], digits = word.filter(\.isNumber).count
            if digits >= 2, word.contains(where: \.isLetter), digits >= 6 || word.contains(where: \.isUppercase) { return true }
            start = range.upperBound
        }
        return false
    }

    public static func mask(_ text: String) -> String {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = token.prefix(12)
        let prefix = head.lastIndex { $0 == "-" || $0 == "_" }.map { String(head[...$0]) } ?? String(token.prefix(4))
        return prefix + String(repeating: "•", count: 8) + token.suffix(4)
    }
}

public struct Pinboard: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static let maxNameLength = 60

    public static func validName(_ name: String, existing: [Pinboard], excluding id: String? = nil) throws(CueError) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .validation("Enter a pinboard name.") }
        guard trimmed.count <= maxNameLength else { throw .validation("Pinboard names can have up to \(maxNameLength) characters.") }
        guard TextLimits.firstInvalidControl(in: trimmed) == nil, !trimmed.contains(where: \.isNewline) else {
            throw .validation("Pinboard names cannot contain control characters or line breaks.")
        }
        if existing.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw .validation("A pinboard named “\(trimmed)” already exists.")
        }
        return trimmed
    }
}

public enum Retention: String, Codable, CaseIterable, Sendable {
    case hour = "1h", day = "1d", week = "7d", month = "30d", never

    public var interval: TimeInterval? {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .never: nil
        }
    }

    public var title: String {
        switch self {
        case .hour: "1 hour"
        case .day: "1 day"
        case .week: "7 days"
        case .month: "30 days"
        case .never: "Never"
        }
    }
}

public enum RecentRange: TimeInterval, CaseIterable, Sendable {
    case fiveMinutes = 300, fifteenMinutes = 900, thirtyMinutes = 1800, hour = 3600, day = 86_400

    public var title: String {
        switch self {
        case .fiveMinutes: "Last 5 minutes"
        case .fifteenMinutes: "Last 15 minutes"
        case .thirtyMinutes: "Last 30 minutes"
        case .hour: "Last hour"
        case .day: "Last 24 hours"
        }
    }

    public func window(endingAt end: Date) -> ClosedRange<Date> { end.addingTimeInterval(-rawValue)...end }
}

public struct ClipboardSettings: Codable, Equatable, Sendable {
    public var retention: Retention = .week
    public var maxItems = 500
    public var maxStorage = ClipboardSettings.defaultMaxStorage
    public var excludedApps: [String] = ClipboardSettings.defaultExcludedApps
    public var shortcut: String? = "Super+Alt+V"
    public var sensitive = SensitiveHandling.maskAndExpire
    public var clearOnQuit = false
    public var clearSystemClipboard = false

    public init() {}

    public static let maxItemChoices = [50, 100, 250, 500, 1000, 2000, 5000]
    public static let defaultMaxStorage = 1024 * 1024 * 1024
    public static let maxStorageChoices = [256, 512, 1024, 2048, 5120].map { $0 * 1024 * 1024 }

    public static func storageTitle(_ bytes: Int) -> String {
        let megabytes = bytes / (1024 * 1024)
        return megabytes >= 1024 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    public static let maxExcludedApps = 200

    public static let defaultExcludedApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.Dashlane", "org.keepassxc.keepassxc",
    ]

    public static func isValidBundleID(_ value: String) -> Bool {
        guard value.count <= 255 else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    public func validate() throws(CueError) {
        guard Self.maxItemChoices.contains(maxItems) else {
            throw .validation("Maximum items must be one of \(Self.maxItemChoices.map(String.init).joined(separator: ", ")).")
        }
        guard Self.maxStorageChoices.contains(maxStorage) else { throw .validation("Choose one of the listed storage limits.") }
        guard excludedApps.count <= Self.maxExcludedApps else { throw .validation("Too many excluded apps.") }
        if let bad = excludedApps.first(where: { !Self.isValidBundleID($0) }) {
            throw .validation("“\(bad.prefix(80))” is not a valid bundle ID.")
        }
        if Set(excludedApps.map { $0.lowercased() }).count != excludedApps.count {
            throw .validation("The excluded apps list contains duplicates.")
        }
        if let shortcut, Shortcut(shortcut) == nil { throw .validation("The clipboard shortcut is not valid.") }
    }

    private enum CodingKeys: String, CodingKey { case retention, maxItems, maxStorage, excludedApps, shortcut, sensitive, clearOnQuit, clearSystemClipboard }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retention = try c.decode(Retention.self, forKey: .retention)
        maxItems = try c.decode(Int.self, forKey: .maxItems)
        maxStorage = try c.decodeIfPresent(Int.self, forKey: .maxStorage) ?? Self.defaultMaxStorage
        excludedApps = try c.decode([String].self, forKey: .excludedApps)
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
        sensitive = try c.decodeIfPresent(SensitiveHandling.self, forKey: .sensitive) ?? .maskAndExpire
        clearOnQuit = try c.decodeIfPresent(Bool.self, forKey: .clearOnQuit) ?? false
        clearSystemClipboard = try c.decodeIfPresent(Bool.self, forKey: .clearSystemClipboard) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(retention, forKey: .retention)
        try c.encode(maxItems, forKey: .maxItems)
        try c.encode(maxStorage, forKey: .maxStorage)
        try c.encode(excludedApps, forKey: .excludedApps)
        try c.encode(shortcut, forKey: .shortcut)
        try c.encode(sensitive, forKey: .sensitive)
        try c.encode(clearOnQuit, forKey: .clearOnQuit)
        try c.encode(clearSystemClipboard, forKey: .clearSystemClipboard)
    }
}

public enum SkipReason: String, CaseIterable, Codable, Sendable {
    case concealed, ownWrite, secureInput, excludedApp, unsupported, unreadable, blank, tooLarge, sensitive, stale, timedOut
}

public enum CaptureDecision: Codable, Equatable, Sendable {
    case capture(ClipCapture)
    case skip(SkipReason)
}

public struct CaptureSource {
    public var text: () -> String?
    public var data: (String) -> Data?
    public var files: () -> [String]

    public init(text: @escaping () -> String?, data: @escaping (String) -> Data?, files: @escaping () -> [String]) {
        self.text = text
        self.data = data
        self.files = files
    }
}

public enum CaptureFilter {
    public static let maxTextBytes = 16 * 1024 * 1024
    public static let maxPathBytes = 256 * 1024
    public static let maxImageBytes = 64 * 1024 * 1024
    public static let maxRichBytes = 1024 * 1024
    public static let plainTextType = "public.utf8-plain-text"
    public static let fileType = "public.file-url"
    public static let imageTypes = ["public.png", "public.jpeg", "public.heic", "public.tiff"]
    public static let richTypes = ["public.rtf", "public.html"]
    public static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ]

    public static func screen(types: [String], ownType: String, secureInput: Bool, frontmostApp: String?, excludedApps: [String]) -> SkipReason? {
        if types.contains(ownType) { return .ownWrite }
        if types.contains(where: sensitiveTypes.contains) { return .concealed }
        if secureInput { return .secureInput }
        if let app = frontmostApp?.lowercased(), excludedApps.contains(where: { $0.lowercased() == app }) {
            return .excludedApp
        }
        return nil
    }

    public static func readText(types: [String], readText: () -> String?) -> CaptureDecision {
        guard types.contains(plainTextType) else { return .skip(.unsupported) }
        return plain(readText())
    }

    public static func read(types: [String], source: CaptureSource) -> CaptureDecision {
        if types.contains(fileType) {
            let paths = source.files()
            if !paths.isEmpty {
                return paths.reduce(0) { $0 + $1.utf8.count } > maxPathBytes ? .skip(.tooLarge) : .capture(ClipCapture(content: .files(paths)))
            }
        }
        let hasText = types.contains(plainTextType)
        let text = hasText ? source.text() : nil
        if let type = imageTypes.first(where: types.contains), imageWins(over: text) {
            guard let data = source.data(type) else { return .skip(.unreadable) }
            return ClipImage.capture(data, type: type)
        }
        guard hasText else { return .skip(.unsupported) }
        let decision = plain(text)
        guard case .capture = decision, let text else { return decision }
        var rich: [String: Data] = [:]
        for type in richTypes where types.contains(type) { rich[type] = source.data(type) }
        guard !rich.isEmpty, rich.values.reduce(0, { $0 + $1.count }) <= maxRichBytes else { return decision }
        return .capture(ClipCapture(content: .rich, text: text, data: rich))
    }

    public static func review(_ decision: CaptureDecision, sensitive: SensitiveHandling) -> CaptureDecision {
        if sensitive == .skip, case .capture(let clip) = decision, clip.content.isText, SensitiveText.matches(clip.text) { return .skip(.sensitive) }
        return decision
    }

    private static func plain(_ text: String?) -> CaptureDecision {
        guard let text else { return .skip(.unreadable) }
        if let reason = textProblem(text) { return .skip(reason) }
        return .capture(.plain(text))
    }

    private static func imageWins(over text: String?) -> Bool {
        guard let text, !isBlank(text) else { return true }
        return text.utf8.count <= 4096 && ClipKind.of(text) == .link
    }

    private static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }

    static func textProblem(_ text: String, limit: Int = maxTextBytes) -> SkipReason? {
        if text.utf8.count > limit { return .tooLarge }
        return isBlank(text) ? .blank : nil
    }
}

public enum ClipboardSearch {
    static let fuzzyMinimum = 3

    public static func fold(_ text: String) -> String {
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        folded.makeContiguousUTF8()
        return folded
    }

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        guard !haystack.isEmpty, !needle.isEmpty else { return false }
        let found = haystack.utf8.withContiguousStorageIfAvailable { field in
            needle.utf8.withContiguousStorageIfAvailable { memmem(field.baseAddress, field.count, $0.baseAddress, $0.count) != nil }
        }
        return (found ?? nil) ?? haystack.contains(needle)
    }

    static func isSubsequence(_ needle: String, of field: String) -> Bool {
        var pending = needle.unicodeScalars.makeIterator()
        var next = pending.next()
        for scalar in field.unicodeScalars where scalar == next {
            next = pending.next()
            if next == nil { return true }
        }
        return next == nil
    }

    public static func preview(_ text: String) -> String {
        var line: Substring = ""
        var rest = text[...]
        while !rest.isEmpty {
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            let candidate = rest[..<end]
            if !candidate.allSatisfy(\.isWhitespace) { line = candidate; break }
            if end == rest.endIndex { break }
            rest = rest[rest.index(after: end)...]
        }
        let collapsed = line.prefix(400).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }

    private static let parallelByteThreshold = 4 << 20

    private final class TierBuffer: @unchecked Sendable {
        let pointer: UnsafeMutableBufferPointer<UInt8>
        init(count: Int) { pointer = .allocate(capacity: count); pointer.initialize(repeating: 2) }
        deinit { pointer.deallocate() }
    }

    private static func tier(_ item: ClipItem, needle: String, tokens: [String]) -> UInt8 {
        if contains(item.folded, needle) { return 0 }
        return !tokens.isEmpty && tokens.allSatisfy({ isSubsequence($0, of: item.foldedPreview) }) ? 1 : 2
    }

    public static func filter(_ items: [ClipItem], query: String, pinboard: String? = nil) -> [ClipItem] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let sorted = items.filter { pinboard == nil || $0.pinboardID == pinboard }.sorted { $0.lastUsedAt > $1.lastUsedAt }
        guard !needle.isEmpty else { return sorted }
        let tokens = needle.count >= fuzzyMinimum ? needle.split(whereSeparator: \.isWhitespace).map(String.init) : []
        var tiers = [UInt8](repeating: 2, count: sorted.count)
        let bytes = sorted.reduce(0) { $0 + $1.folded.utf8.count }
        if bytes > parallelByteThreshold, sorted.count > 32 {
            let buffer = TierBuffer(count: sorted.count)
            let ranges = ParallelChunks.ranges(count: sorted.count, maxParts: ProcessInfo.processInfo.activeProcessorCount)
            DispatchQueue.concurrentPerform(iterations: ranges.count) { chunk in
                for index in ranges[chunk] {
                    buffer.pointer[index] = tier(sorted[index], needle: needle, tokens: tokens)
                }
            }
            tiers = Array(buffer.pointer)
        } else {
            for (index, item) in sorted.enumerated() { tiers[index] = tier(item, needle: needle, tokens: tokens) }
        }
        var exact: [ClipItem] = [], fuzzy: [ClipItem] = []
        for (index, item) in sorted.enumerated() {
            if tiers[index] == 0 { exact.append(item) } else if tiers[index] == 1 { fuzzy.append(item) }
        }
        return exact + fuzzy
    }
}

public struct PurgeCandidate: Sendable {
    public let id: String
    public let lastUsedAt: Date
    public let pinned: Bool
    public let expiresAt: Date?
    public let bytes: Int

    public init(id: String, lastUsedAt: Date, pinned: Bool, expiresAt: Date? = nil, bytes: Int = 0) {
        self.id = id
        self.lastUsedAt = lastUsedAt
        self.pinned = pinned
        self.expiresAt = expiresAt
        self.bytes = bytes
    }
}

public enum ClipboardPurge {
    public static func select(_ items: [PurgeCandidate], now: Date, retention: Retention, maxItems: Int, maxBytes: Int = .max) -> Set<String> {
        let unpinned = items.filter { !$0.pinned }.sorted { $0.lastUsedAt > $1.lastUsedAt }
        var doomed = Set<String>()
        var kept = 0
        for (index, item) in unpinned.enumerated() {
            let expired = retention.interval.map { now.timeIntervalSince(item.lastUsedAt) > $0 } ?? false
            let lapsed = item.expiresAt.map { $0 <= now } ?? false
            if expired || lapsed || index >= maxItems {
                doomed.insert(item.id)
                continue
            }
            kept += item.bytes
            if kept > maxBytes { doomed.insert(item.id) }
        }
        return doomed
    }

    public static func recent(_ items: [PurgeCandidate], in window: ClosedRange<Date>) -> Set<String> {
        Set(items.filter { !$0.pinned && window.contains($0.lastUsedAt) }.map(\.id))
    }
}

public struct ClipboardCrypto: Sendable {
    private let sealKey: SymmetricKey
    private let digestKey: SymmetricKey
    private let contentDigestKey: SymmetricKey
    public let keyCheck: Data

    public init(master: SymmetricKey) {
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data(info.utf8), outputByteCount: 32)
        }
        sealKey = derive("cue.clipboard.seal.v1")
        digestKey = derive("cue.clipboard.digest.v1")
        contentDigestKey = derive("cue.clipboard.digest.content.v1")
        keyCheck = Data(HMAC<SHA256>.authenticationCode(for: Data("cue.clipboard.key-check".utf8), using: derive("cue.clipboard.check.v1")))
    }

    public func seal(_ text: String, context: String) throws -> Data {
        try seal(Data(text.utf8), context: context)
    }

    public func seal(_ data: Data, context: String) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: sealKey, authenticating: Data(context.utf8)).combined else {
            throw CueError.storage()
        }
        return combined
    }

    public func open(_ data: Data, context: String) throws -> String {
        guard let text = String(data: try openData(data, context: context), encoding: .utf8) else { throw CueError.storage() }
        return text
    }

    public func openData(_ data: Data, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: sealKey, authenticating: Data(context.utf8))
    }

    public func digest(_ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: digestKey))
    }

    public func digest(_ clip: ClipCapture) -> Data {
        var code = HMAC<SHA256>(key: contentDigestKey)
        switch clip.content {
        case .plain, .rich:
            return digest(clip.text)
        case .image:
            code.update(data: Data("image".utf8))
            for key in clip.data.keys.sorted() { clip.data[key].map { code.update(data: $0) } }
        case .files(let paths):
            code.update(data: Data("files".utf8))
            code.update(data: Data(paths.sorted().joined(separator: "\0").utf8))
        }
        return Data(code.finalize())
    }
}
