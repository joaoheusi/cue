import AppKit
import CueKit

struct FileHit: Identifiable, Equatable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isApp: Bool { url.pathExtension == "app" }
    var title: String { isApp ? url.deletingPathExtension().lastPathComponent : name }
    var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
}

enum InstalledApps {
    private static let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]

    static func list() -> [FileHit] {
        let manager = FileManager.default
        var found: [String: FileHit] = [:]
        for root in roots {
            for name in (try? manager.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") {
                let url = URL(fileURLWithPath: root).appendingPathComponent(name)
                if url.pathExtension == "app" {
                    found[name] = FileHit(url: url)
                } else if root == roots[0] {
                    for inner in (try? manager.contentsOfDirectory(atPath: url.path)) ?? [] where inner.hasSuffix(".app") {
                        found[inner] = FileHit(url: url.appendingPathComponent(inner))
                    }
                }
            }
        }
        return found.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

@MainActor @Observable final class FileSearch {
    private(set) var results: [FileHit] = []
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let minimumLength = 2
    private static let scanLimit = 400
    private static let resultLimit = 30
    private static let skipped: Set = ["node_modules", "DerivedData", ".git", ".build", "build"]
    private static let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path + "/"

    func search(_ text: String) {
        stop()
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= Self.minimumLength else {
            results = []
            return
        }
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, needle)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.notificationBatchingInterval = 0.05
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering] {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] note in
                let finished = note.name == .NSMetadataQueryDidFinishGathering
                MainActor.assumeIsolated { self?.collect(needle, finished: finished) }
            })
        }
        self.query = query
        query.start()
    }

    func stop() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func collect(_ needle: String, finished: Bool) {
        guard let query else { return }
        query.disableUpdates()
        let paths = (0..<min(query.resultCount, Self.scanLimit)).compactMap {
            (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
        }
        query.enableUpdates()
        let wanted = paths.filter { path in
            !path.hasPrefix(Self.library) && !path.split(separator: "/").contains { Self.skipped.contains(String($0)) || $0.hasPrefix(".") }
                && !path.contains(".app/") && !path.hasSuffix(".app")
        }
        results = wanted.map { URL(fileURLWithPath: $0) }.map(FileHit.init).sorted { a, b in
            let first = Self.rank(a, needle), second = Self.rank(b, needle)
            if first != second { return first < second }
            return a.name.count != b.name.count ? a.name.count < b.name.count : a.id < b.id
        }.prefix(Self.resultLimit).map { $0 }
        if finished || query.resultCount >= Self.scanLimit { stop() }
    }

    private static func rank(_ hit: FileHit, _ needle: String) -> Int {
        hit.name.lowercased().hasPrefix(needle.lowercased()) ? 0 : 1
    }
}
