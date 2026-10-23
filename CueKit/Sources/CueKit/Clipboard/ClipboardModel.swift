import CryptoKit
import Foundation

/// One saved clipboard entry, decrypted. `folded` and `preview` are computed once so search
/// and list rendering never re-scan large items.
public struct ClipItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let source: String?
    public let createdAt: Date
    public var lastUsedAt: Date
    public var pinboardID: String?
    public let folded: String
    public let preview: String

    public init(id: String, text: String, source: String?, createdAt: Date, lastUsedAt: Date, pinboardID: String?) {
        self.id = id
        self.text = text
        self.source = source
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.pinboardID = pinboardID
        folded = ClipboardSearch.fold(text)
        preview = ClipboardSearch.preview(text)
    }

    public var isPinned: Bool { pinboardID != nil }
}

public struct Pinboard: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static let maxNameLength = 60

    /// Trims and checks a pinboard name. Names must be unique, ignoring case.
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

/// Clipboard settings that travel in exports. Capture on/off is per Mac and is stored separately,
/// so importing a file can never turn capture on without the permission explanation.
public struct ClipboardSettings: Codable, Equatable, Sendable {
    public var retention: Retention = .week
    public var maxItems = 500
    public var excludedApps: [String] = ClipboardSettings.defaultExcludedApps
    /// Stored shortcut form, for example `Super+Alt+V`. Nil means no shortcut.
    public var shortcut: String? = "Super+Alt+V"

    public init() {}

    public static let maxItemChoices = [50, 100, 250, 500, 1000, 2000, 5000]
    public static let maxExcludedApps = 200

    /// Password managers and Keychain apps. Users can edit the list.
    public static let defaultExcludedApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.Dashlane", "org.keepassxc.keepassxc",
    ]

    /// Reverse-DNS form such as `com.example.App`: two or more dot-separated parts of letters, digits, and hyphens.
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
        guard excludedApps.count <= Self.maxExcludedApps else { throw .validation("Too many excluded apps.") }
        if let bad = excludedApps.first(where: { !Self.isValidBundleID($0) }) {
            throw .validation("“\(bad.prefix(80))” is not a valid bundle ID.")
        }
        if Set(excludedApps.map { $0.lowercased() }).count != excludedApps.count {
            throw .validation("The excluded apps list contains duplicates.")
        }
        if let shortcut, Shortcut(shortcut) == nil { throw .validation("The clipboard shortcut is not valid.") }
    }

    private enum CodingKeys: String, CodingKey { case retention, maxItems, excludedApps, shortcut }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retention = try c.decode(Retention.self, forKey: .retention)
        maxItems = try c.decode(Int.self, forKey: .maxItems)
        excludedApps = try c.decode([String].self, forKey: .excludedApps)
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(retention, forKey: .retention)
        try c.encode(maxItems, forKey: .maxItems)
        try c.encode(excludedApps, forKey: .excludedApps)
        try c.encode(shortcut, forKey: .shortcut) // explicit null when off
    }
}

// MARK: Capture filter

public enum SkipReason: String, CaseIterable, Sendable {
    case concealed, ownWrite, secureInput, excludedApp, notText, unreadable, blank, tooLarge
}

public enum CaptureDecision: Equatable, Sendable {
    case capture(String)
    case skip(SkipReason)
}

public enum CaptureFilter {
    public static let maxBytes = 256 * 1024
    public static let plainTextType = "public.utf8-plain-text"
    /// Markers that password managers and other apps set on sensitive or temporary content (nspasteboard.org).
    public static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ]

    /// Decides whether to save a clipboard change. `readText` runs only after every metadata check passes,
    /// so concealed items, secure input, and excluded apps never have their content read.
    public static func decide(types: [String], ownType: String, secureInput: Bool, frontmostApp: String?,
                              excludedApps: [String], readText: () -> String?) -> CaptureDecision {
        if types.contains(ownType) { return .skip(.ownWrite) }
        if types.contains(where: sensitiveTypes.contains) { return .skip(.concealed) }
        if secureInput { return .skip(.secureInput) }
        if let app = frontmostApp?.lowercased(), excludedApps.contains(where: { $0.lowercased() == app }) {
            return .skip(.excludedApp)
        }
        guard types.contains(plainTextType) else { return .skip(.notText) }
        guard let text = readText() else { return .skip(.unreadable) }
        if let reason = textProblem(text) { return .skip(reason) }
        return .capture(text)
    }

    static func textProblem(_ text: String) -> SkipReason? {
        if text.utf8.count > maxBytes { return .tooLarge }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .blank }
        return nil
    }
}

// MARK: Search and purge

public enum ClipboardSearch {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// First non-blank line with whitespace collapsed, at most 200 characters.
    public static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        let collapsed = line.prefix(400).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }

    /// Case- and diacritic-insensitive substring match, last used first. `pinboard` limits to one pinboard.
    public static func filter(_ items: [ClipItem], query: String, pinboard: String? = nil) -> [ClipItem] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return items
            .filter { (pinboard == nil || $0.pinboardID == pinboard) && (needle.isEmpty || $0.folded.contains(needle)) }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }
}

public struct PurgeCandidate: Sendable {
    public let id: String
    public let lastUsedAt: Date
    public let pinned: Bool

    public init(id: String, lastUsedAt: Date, pinned: Bool) {
        self.id = id
        self.lastUsedAt = lastUsedAt
        self.pinned = pinned
    }
}

public enum ClipboardPurge {
    /// IDs to delete. Age counts from `lastUsedAt`, the same key the list sorts by, so an item you
    /// keep using stays. Pinned items never expire and do not count toward `maxItems`.
    public static func select(_ items: [PurgeCandidate], now: Date, retention: Retention, maxItems: Int) -> Set<String> {
        let unpinned = items.filter { !$0.pinned }.sorted { $0.lastUsedAt > $1.lastUsedAt }
        var doomed = Set<String>()
        for (index, item) in unpinned.enumerated() {
            let expired = retention.interval.map { now.timeIntervalSince(item.lastUsedAt) > $0 } ?? false
            if expired || index >= maxItems { doomed.insert(item.id) }
        }
        return doomed
    }
}

// MARK: Encryption

/// AES-GCM-256 for content and an HMAC-SHA256 digest for dedupe. Both keys come from the master key via HKDF.
public struct ClipboardCrypto: Sendable {
    private let sealKey: SymmetricKey
    private let digestKey: SymmetricKey
    /// Stored in the database to detect a missing or replaced master key before any item is read.
    public let keyCheck: Data

    public init(master: SymmetricKey) {
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data(info.utf8), outputByteCount: 32)
        }
        sealKey = derive("cue.clipboard.seal.v1")
        digestKey = derive("cue.clipboard.digest.v1")
        keyCheck = Data(HMAC<SHA256>.authenticationCode(for: Data("cue.clipboard.key-check".utf8), using: derive("cue.clipboard.check.v1")))
    }

    /// `context` (row ID plus field) is authenticated, so ciphertext cannot be moved to another row or field.
    public func seal(_ text: String, context: String) throws -> Data {
        guard let combined = try AES.GCM.seal(Data(text.utf8), using: sealKey, authenticating: Data(context.utf8)).combined else {
            throw CueError.storage()
        }
        return combined
    }

    public func open(_ data: Data, context: String) throws -> String {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: sealKey, authenticating: Data(context.utf8))
        guard let text = String(data: plain, encoding: .utf8) else { throw CueError.storage() }
        return text
    }

    public func digest(_ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: digestKey))
    }
}
