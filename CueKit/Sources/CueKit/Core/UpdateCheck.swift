import Foundation

/// Compares release versions for the opt-in update check. Cue never downloads or installs updates.
public enum UpdateCheck {
    /// Parses `v1.2.3`, `1.2`, or `1.2.3-beta` into numeric parts. Pre-release suffixes are ignored.
    public static func parts(_ version: String) -> [Int]? {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let core = text.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return numbers.map { $0! }
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var a = parts(candidate), var b = parts(current) else { return false }
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        return a.lexicographicallyPrecedes(b) == false && a != b
    }

    public struct Release: Equatable, Sendable {
        public let version: String
        public let page: URL
    }

    /// Reads a GitHub "latest release" response. Only `https` release pages are accepted.
    public static func release(from data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, parts(tag) != nil,
              let link = object["html_url"] as? String, let url = URL(string: link), url.scheme == "https"
        else { return nil }
        return Release(version: tag, page: url)
    }
}
