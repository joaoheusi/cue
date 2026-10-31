import Foundation

public enum DeliveryMode: String, Codable, Sendable, CaseIterable {
    case inherit, copy, paste
}

public struct Action: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var template: String
    public var aliases: [String]
    public var tags: [String]
    public var category: String?
    public var deliveryMode: DeliveryMode
    public var favorite: Bool
    public var enabled: Bool
    public var ai: Bool?
    public var revision: Int
    public var useCount: Int
    public var lastUsedAt: String?
    public var createdAt: String
    public var updatedAt: String

    public init(id: String = UUID().uuidString.lowercased(), name: String = "", description: String = "", template: String = "",
                aliases: [String] = [], tags: [String] = [], category: String? = nil, deliveryMode: DeliveryMode = .inherit,
                favorite: Bool = false, enabled: Bool = true, ai: Bool? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.template = template
        self.aliases = aliases
        self.tags = tags
        self.category = category
        self.deliveryMode = deliveryMode
        self.favorite = favorite
        self.enabled = enabled
        self.ai = ai
        revision = 0
        useCount = 0
        lastUsedAt = nil
        createdAt = Timestamp.now()
        updatedAt = createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(template, forKey: .template)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(tags, forKey: .tags)
        try c.encode(category, forKey: .category)
        try c.encode(deliveryMode, forKey: .deliveryMode)
        try c.encode(favorite, forKey: .favorite)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(ai, forKey: .ai)
        try c.encode(revision, forKey: .revision)
        try c.encode(useCount, forKey: .useCount)
        try c.encode(lastUsedAt, forKey: .lastUsedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    public var export: ExportAction {
        ExportAction(id: id, name: name, description: description, template: template, aliases: aliases, tags: tags,
                     category: category, deliveryMode: deliveryMode, favorite: favorite, enabled: enabled)
    }
}

public struct ExportAction: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var template: String
    public var aliases: [String]
    public var tags: [String]
    public var category: String?
    public var deliveryMode: DeliveryMode
    public var favorite: Bool
    public var enabled: Bool

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(template, forKey: .template)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(tags, forKey: .tags)
        try c.encode(category, forKey: .category)
        try c.encode(deliveryMode, forKey: .deliveryMode)
        try c.encode(favorite, forKey: .favorite)
        try c.encode(enabled, forKey: .enabled)
    }

    public var action: Action {
        Action(id: id, name: name, description: description, template: template, aliases: aliases, tags: tags,
               category: category, deliveryMode: deliveryMode, favorite: favorite, enabled: enabled)
    }
}

public struct ExportFile: Codable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: String
    public var actions: [ExportAction]

    public init(actions: [ExportAction]) {
        schemaVersion = 1
        exportedAt = Timestamp.now()
        self.actions = actions
    }
}

public enum Theme: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

public enum SearchSource: String, Codable, Sendable, CaseIterable {
    case actions, apps, folders, files
}

public enum KeyStorage: String, Codable, Sendable, CaseIterable {
    case env, keychain
}

public enum ScriptOutput: String, Codable, Sendable, CaseIterable {
    case copy, show
}

public struct PromptSettings: Codable, Sendable, Equatable {
    public var theme: Theme = .system
    public var defaultDelivery: DeliveryMode = .paste
    public var onboarded = false
    public var paletteShortcut = "Alt+Space"
    public var launchAtLogin = false
    public var keepRunning = true
    public var previewPane = true
    public var menuBarScopeShortcut = "Super+Alt+B"
    public var searchIn = SearchSource.allCases
    public var fileLocations = FileLocation.defaults
    public var skipFolders = FileScope.defaultSkips
    public var keyStorage = KeyStorage.env
    public var scriptTimeout = Int(Scripts.timeout)
    public var scriptOutput = ScriptOutput.copy
    public var scriptUsage: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PromptSettings()
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? d.theme
        defaultDelivery = try c.decodeIfPresent(DeliveryMode.self, forKey: .defaultDelivery) ?? d.defaultDelivery
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? d.onboarded
        paletteShortcut = try c.decodeIfPresent(String.self, forKey: .paletteShortcut) ?? d.paletteShortcut
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        keepRunning = try c.decodeIfPresent(Bool.self, forKey: .keepRunning) ?? d.keepRunning
        previewPane = try c.decodeIfPresent(Bool.self, forKey: .previewPane) ?? d.previewPane
        menuBarScopeShortcut = try c.decodeIfPresent(String.self, forKey: .menuBarScopeShortcut) ?? d.menuBarScopeShortcut
        searchIn = try c.decodeIfPresent([SearchSource].self, forKey: .searchIn) ?? d.searchIn
        fileLocations = try c.decodeIfPresent([FileLocation].self, forKey: .fileLocations) ?? d.fileLocations
        skipFolders = try c.decodeIfPresent([String].self, forKey: .skipFolders) ?? d.skipFolders
        keyStorage = try c.decodeIfPresent(KeyStorage.self, forKey: .keyStorage) ?? d.keyStorage
        scriptTimeout = try c.decodeIfPresent(Int.self, forKey: .scriptTimeout) ?? d.scriptTimeout
        scriptOutput = try c.decodeIfPresent(ScriptOutput.self, forKey: .scriptOutput) ?? d.scriptOutput
        scriptUsage = try c.decodeIfPresent([String: String].self, forKey: .scriptUsage) ?? d.scriptUsage
    }
}

public enum Template {
    public static let outputLimit = 1_048_576
    public static let templateLimit = 65_536
    private static let tokens = ["{{clipboard}}", "{{selection}}", "{{date}}", "{{time}}", "{{ask"]

    public enum Segment: Equatable, Sendable {
        case text(String)
        case token(String)
    }

    public struct Inputs: Sendable {
        public var clipboard = ""
        public var selection = ""
        public var answers: [String: String] = [:]

        public init(clipboard: String = "", selection: String = "", answers: [String: String] = [:]) {
            self.clipboard = clipboard
            self.selection = selection
            self.answers = answers
        }
    }

    public struct Uses: Equatable, Sendable {
        public var clipboard = false
        public var selection = false
        public var questions: [String] = []
    }

    public static func render(_ template: String, clipboard: String, date: String, time: String) throws(CueError) -> String {
        var uses = Uses()
        return try render(template, inputs: Inputs(clipboard: clipboard), date: date, time: time, uses: &uses)
    }

    public static func renderLocal(_ template: String, clipboard: String, now: Date = Date()) throws(CueError) -> String {
        try renderLocal(template, inputs: Inputs(clipboard: clipboard), now: now)
    }

    public static func renderLocal(_ template: String, inputs: Inputs, now: Date = Date()) throws(CueError) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        var uses = Uses()
        return try render(template, inputs: inputs,
                          date: String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!),
                          time: String(format: "%02d:%02d", c.hour!, c.minute!), uses: &uses)
    }

    public static func needsClipboard(_ template: String) throws(CueError) -> Bool {
        try uses(template).clipboard
    }

    public static func uses(_ template: String) throws(CueError) -> Uses {
        var uses = Uses()
        _ = try render(template, inputs: Inputs(clipboard: "sample", selection: "sample"), date: "2000-01-01", time: "00:00", uses: &uses)
        return uses
    }

    public static func question(_ name: String) -> String? {
        guard name == "ask" || name.hasPrefix("ask:") else { return nil }
        let label = name.dropFirst(3).drop { $0 == ":" }.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "Ask" : label
    }

    public static func segments(_ template: String) -> [Segment] {
        var result: [Segment] = []
        var rest = Substring(template)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let name = String(rest[open.upperBound..<close.lowerBound])
            guard ["clipboard", "selection", "date", "time"].contains(name) || question(name) != nil else {
                result.append(.text(String(rest[..<close.upperBound])))
                rest = rest[close.upperBound...]
                continue
            }
            if open.lowerBound > rest.startIndex { result.append(.text(String(rest[..<open.lowerBound]))) }
            result.append(.token(question(name).map { $0 == "Ask" ? "ask…" : "ask: \($0)" } ?? name))
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { result.append(.text(String(rest))) }
        return result
    }

    private static func render(_ template: String, inputs: Inputs, date: String, time: String, uses: inout Uses) throws(CueError) -> String {
        let chars = Array(template.unicodeScalars)
        var out = String.UnicodeScalarView()
        var bytes = 0
        func starts(_ token: String, at index: Int) -> Bool {
            let t = Array(token.unicodeScalars)
            return index + t.count <= chars.count && Array(chars[index..<index + t.count]) == t
        }
        func append<S: Sequence<Unicode.Scalar>>(_ scalars: S) {
            for s in scalars {
                out.append(s)
                bytes += String(s).utf8.count
            }
        }
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" {
                let start = i
                while i < chars.count && chars[i] == "\\" { i += 1 }
                let count = i - start
                if tokens.contains(where: { starts($0, at: i) }) {
                    append(String(repeating: "\\", count: count / 2).unicodeScalars)
                    if count % 2 == 1 {
                        append("{{".unicodeScalars)
                        i += 2
                        continue
                    }
                } else {
                    append(chars[start..<i])
                    continue
                }
            }
            if i + 1 < chars.count && chars[i] == "{" && chars[i + 1] == "{" {
                var end = i + 2
                while end + 1 < chars.count && !(chars[end] == "}" && chars[end + 1] == "}") { end += 1 }
                if end + 1 >= chars.count {
                    append(chars[i...])
                    break
                }
                let value: String
                let name = String(String.UnicodeScalarView(chars[(i + 2)..<end]))
                switch name {
                case "clipboard":
                    uses.clipboard = true
                    value = inputs.clipboard
                case "selection":
                    uses.selection = true
                    value = inputs.selection
                case "date": value = date
                case "time": value = time
                case _ where question(name) != nil:
                    let label = question(name) ?? ""
                    if !uses.questions.contains(label) { uses.questions.append(label) }
                    value = inputs.answers[label] ?? ""
                default:
                    append(chars[i..<(end + 2)])
                    i = end + 2
                    continue
                }
                if bytes + value.utf8.count > outputLimit {
                    throw CueError("OUTPUT_TOO_LARGE", "Rendered text exceeds 1 MiB.")
                }
                append(value.unicodeScalars)
                i = end + 2
            } else {
                append(CollectionOfOne(chars[i]))
                i += 1
            }
        }
        let result = String(out)
        try validateText(result, maxBytes: outputLimit)
        return result
    }

    public static func validateText(_ text: String, maxBytes: Int) throws(CueError) {
        if text.utf8.count > maxBytes {
            throw CueError("OUTPUT_TOO_LARGE", "Text is too large. Reduce it before trying again.")
        }
        if let position = TextLimits.firstInvalidControl(in: text) {
            throw CueError("TEMPLATE_INVALID", "Invalid control character at position \(position).")
        }
    }
}

public enum ActionRules {
    public static let libraryLimit = 5000

    public static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping.lowercased()
    }

    private static func limit(_ value: String, _ max: Int, required: Bool, _ field: String) throws(CueError) {
        let count = value.unicodeScalars.count
        if count > max || (required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            throw CueError.validation("\(field) must contain \(required ? 1 : 0)–\(max) characters.")
        }
    }

    public static func validate(_ a: inout Action) throws(CueError) {
        guard UUID(uuidString: a.id) != nil else { throw CueError.validation("Action ID is invalid.") }
        a.name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try limit(a.name, 100, required: true, "Name")
        try limit(a.description, 300, required: false, "Description")
        a.template = a.template.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if a.template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CueError("TEMPLATE_INVALID", "Text cannot be empty.")
        }
        try Template.validateText(a.template, maxBytes: Template.templateLimit)
        _ = try Template.renderLocal(a.template, clipboard: "sample clipboard")
        a.aliases = try normalizeList(a.aliases, max: 50, field: "Alias")
        a.tags = try normalizeList(a.tags, max: 30, field: "Tag")
        if let category = a.category {
            let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
            try limit(trimmed, 50, required: true, "Category")
            a.category = trimmed
        }
    }

    private static func normalizeList(_ items: [String], max: Int, field: String) throws(CueError) -> [String] {
        if items.count > 10 { throw CueError.validation("At most 10 tags or aliases are allowed.") }
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            try limit(trimmed, max, required: true, field)
            if seen.insert(key(trimmed)).inserted { result.append(trimmed) }
        }
        return result
    }
}

public enum ActionSearch {
    public static func normalize(_ text: String) -> String {
        let scalars = text.decomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: false
            default: true
            }
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    public static func match(_ query: String, _ field: String) -> Int? {
        let q = Array(query.unicodeScalars), f = Array(field.unicodeScalars)
        if q.count > f.count { return nil }
        if field == query { return 0 }
        if field.hasPrefix(query) { return 1 }
        if field.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(query) }) { return 2 }
        if field.contains(query) { return 3 }
        var p = 0
        for c in f where p < q.count && c == q[p] { p += 1 }
        return p == q.count ? 4 : nil
    }

    public static func score(_ query: String, name: String, fields: [(String, Int)] = []) -> (tier: Int, weight: Int)? {
        let q = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if q.isEmpty { return (0, 0) }
        if normalize(name) == q { return (-1, 0) }
        if fields.contains(where: { $0.1 == 1 && normalize($0.0) == q }) { return (-1, 1) }
        var tier = 0, weight = 0
        for token in q.split(whereSeparator: \.isWhitespace).map(String.init) {
            let best = ([(name, 0)] + fields).compactMap { field, w in match(token, normalize(field)).map { $0 * 10 + w } }.min()
            guard let best else { return nil }
            tier = max(tier, best / 10)
            weight += best % 10
        }
        return (tier, weight)
    }

    public static func search(_ actions: [Action], query: String, enabledOnly: Bool = true) -> [Action] {
        scored(actions, query: query, enabledOnly: enabledOnly).map(\.action)
    }

    public static func scored(_ actions: [Action], query: String, enabledOnly: Bool = true) -> [(action: Action, tier: Int, weight: Int)] {
        var scored: [(action: Action, tier: Int, weight: Int)] = []
        for action in actions where !enabledOnly || action.enabled {
            let fields = action.aliases.map { ($0, 1) } + action.tags.map { ($0, 2) } + [(action.category ?? "", 3)]
            if let score = score(query, name: action.name, fields: fields) { scored.append((action, score.tier, score.weight)) }
        }
        return scored.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.weight != b.weight { return a.weight < b.weight }
            if a.action.favorite != b.action.favorite { return a.action.favorite }
            let au = a.action.lastUsedAt ?? "", bu = b.action.lastUsedAt ?? ""
            if au != bu { return au > bu }
            let an = normalize(a.action.name), bn = normalize(b.action.name)
            if an != bn { return an.localizedCompare(bn) == .orderedAscending }
            return a.action.id < b.action.id
        }
    }
}

public enum Starters {
    public static func assistant() -> [Action] {
        let rows: [(String, String, String, String)] = [
            ("Fix Grammar", "Correct the clipboard with Claude", "grammar,spelling,proofread",
             "Fix the grammar, spelling, and punctuation of the text below. Keep its meaning, tone, and language. Return only the corrected text.\n\nText:\n{{clipboard}}"),
            ("Summarize", "Summarize the clipboard with Claude", "summary,tldr",
             "Summarize the text below in a few short sentences, in the same language. Return only the summary.\n\nText:\n{{clipboard}}"),
            ("Translate", "Translate the clipboard with Claude", "translation,english",
             "Translate the text below into English. Keep its tone and formatting. Return only the translation.\n\nText:\n{{clipboard}}"),
        ]
        return rows.map { row in
            Action(name: row.0, description: row.1, template: row.3, aliases: row.2.split(separator: ",").map(String.init),
                   category: "AI", deliveryMode: .copy, ai: true)
        }
    }

    public static func actions() -> [Action] {
        let rows: [(String, String, String, String, String, String)] = [
            ("Resolve CI", "Inspect failing checks and make the smallest fix", "Coding", "ci,fix,git", "fix build,fix checks",
             "Work in this conversation and the current checkout. Inspect the CI failures for the current branch or pull request using the tools available to you. Identify the cause, make the smallest appropriate fix, and run the relevant checks. Do not commit, push, or start another conversation unless I ask. If you cannot access the failure logs, ask me to provide them. Report what changed and what you verified."),
            ("Resolve merge conflicts", "Preserve the intent of both changes", "Coding", "git,conflicts", "merge conflicts",
             "Inspect the current Git state and explain which operation caused the conflicts. Resolve them while preserving the intent of both changes. Ask when the intended behavior is ambiguous. Do not discard unrelated work, commit, push, or continue a rebase or merge without my approval. Summarize the resolutions and the checks you ran."),
            ("Explain this PR", "Understand the change as a linear flow", "Coding", "review,explain", "pull request",
             "Explain this pull request as a linear flow. First describe the behavior before the change: what called what, in what order, and what happened. Then explain the new flow and its user-visible effects. Identify changed conditions, removed calls, side effects, and failure paths. Use simple technical English. Ask for the PR or diff if it is not available in this conversation."),
            ("Review current changes", "Find concrete bugs and unsafe assumptions", "Coding", "review,bugs", "",
             "Review the current changes for correctness, regressions, missing cases, and unsafe assumptions. Focus on concrete issues rather than style preferences. Explain each finding with the relevant file, behavior, and consequence. Do not modify files unless I ask. State what you could not verify."),
            ("Rewrite clearly", "Clear, natural English from your clipboard", "Writing", "english,rewrite", "rewrite text",
             "Rewrite the text below in clear, natural English. Keep the meaning and tone. Remove filler and unnecessary jargon. Return only the rewritten text.\n\nText:\n{{clipboard}}"),
            ("Create a handoff", "Carry decisions and context into the next session", "Coding", "docs,handoff", "",
             "Create an implementation handoff from this conversation. Include the goal, decisions, interfaces, affected areas, edge cases, completed work, pending work, and verification steps. Clearly separate confirmed details from assumptions. Do not invent missing implementation details."),
        ]
        return rows.enumerated().map { index, row in
            Action(name: row.0, description: row.1, template: row.5,
                   aliases: row.4.isEmpty ? [] : row.4.split(separator: ",").map(String.init),
                   tags: row.3.split(separator: ",").map(String.init), category: row.2,
                   favorite: [0, 2, 4].contains(index))
        } + assistant()
    }
}
