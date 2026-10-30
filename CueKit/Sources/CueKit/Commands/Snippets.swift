import Foundation

public struct Snippet: Codable, Equatable, Sendable, Identifiable {
    public var keyword: String
    public var expansion: String
    public var id: String { keyword }

    public init(keyword: String, expansion: String) {
        self.keyword = keyword
        self.expansion = expansion
    }

    public var template: String {
        expansion.replacingOccurrences(of: #"(?<!\{)\{(clipboard|date|time)\}(?!\})"#, with: "{{$1}}", options: .regularExpression)
    }
}

public enum Snippets {
    public static let fileName = "snippets.json"
    public static let maxBytes = 1 << 20
    public static let sample = #"""
    [
      { "keyword": "today", "expansion": "{date}" },
      { "keyword": "quote", "expansion": "> {clipboard}" }
    ]

    """#

    public static func load(_ url: URL) throws(CueError) -> [Snippet] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do {
            data = try BoundedFile.read(url, maxBytes: maxBytes)
        } catch {
            throw error.cueError
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws(CueError) -> [Snippet] {
        guard let list = try? JSONDecoder().decode([Snippet].self, from: data) else {
            throw CueError("SNIPPETS_INVALID", "snippets.json must be a list of { \"keyword\", \"expansion\" } entries.")
        }
        var seen = Set<String>()
        return list.filter { !$0.keyword.isEmpty && seen.insert($0.keyword).inserted }
    }
}
