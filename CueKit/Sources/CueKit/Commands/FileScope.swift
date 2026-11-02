import Foundation

public struct FileLocation: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var path: String
    public var depth: Int?
    public var id: String { path }

    public init(path: String, depth: Int?) {
        self.path = path
        self.depth = depth
    }

    public static let defaults = [
        FileLocation(path: "~", depth: 2), FileLocation(path: "~/Projects", depth: nil), FileLocation(path: "/Applications", depth: 1),
    ]
    public static let depthChoices: [Int?] = [1, 2, 3, 4, nil]

    public var expanded: String { (path as NSString).expandingTildeInPath }
}

public struct FileScope: Sendable {
    public static let defaultSkips = ["node_modules", ".venv", "venv*", "site-packages", "Pods", ".git", "build", "dist", "_worktrees", "DerivedData"]

    public var locations: [FileLocation]
    public var skip: [String]
    private let library: String

    public init(locations: [FileLocation], skip: [String], home: String = NSHomeDirectory()) {
        self.locations = locations
        self.skip = skip
        library = (home as NSString).appendingPathComponent("Library") + "/"
    }

    public var roots: [String] { locations.map(\.expanded) }

    /// Positions of the best `limit` paths: names that start with the needle first, then shorter names, then path order.
    public static func ranked(_ paths: [String], needle: String, limit: Int) -> [Int] {
        let lowered = needle.lowercased()
        let keyed = paths.enumerated().map { offset, path in
            let name = (path as NSString).lastPathComponent
            return (rank: name.lowercased().hasPrefix(lowered) ? 0 : 1, length: name.count, path: path, offset: offset)
        }
        return keyed.sorted { ($0.rank, $0.length, $0.path) < ($1.rank, $1.length, $1.path) }.prefix(limit).map(\.offset)
    }

    public func allows(_ path: String) -> Bool {
        if path.contains(".app/") || path.hasSuffix(".app") { return false }
        return locations.contains { location in
            let root = location.expanded
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard path.hasPrefix(prefix) else { return false }
            if path.hasPrefix(library), !root.hasPrefix(library.dropLast()) { return false }
            let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            if let depth = location.depth, parts.count > depth { return false }
            return !parts.contains { part in part.hasPrefix(".") || skip.contains { fnmatch($0, part, 0) == 0 } }
        }
    }
}
