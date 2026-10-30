import AppKit
import CoreServices
import CueKit

struct FileHit: Identifiable, Equatable {
    let url: URL
    var isFolder = false
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
    private static let scanLimit = 2000
    private static let resultLimit = 60

    func clear() {
        stop()
        results = []
    }

    func search(_ text: String, scope: FileScope) {
        clear()
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= Self.minimumLength, !scope.locations.isEmpty else { return }
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, needle)
        query.searchScopes = scope.roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        query.notificationBatchingInterval = 0.05
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering] {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] note in
                let finished = note.name == .NSMetadataQueryDidFinishGathering
                MainActor.assumeIsolated { self?.collect(needle, scope: scope, finished: finished) }
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

    private func collect(_ needle: String, scope: FileScope, finished: Bool) {
        guard let query else { return }
        query.disableUpdates()
        let found = (0..<min(query.resultCount, Self.scanLimit)).compactMap { index -> FileHit? in
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String, scope.allows(path) else { return nil }
            return FileHit(url: URL(fileURLWithPath: path), isFolder: item.value(forAttribute: NSMetadataItemContentTypeKey) as? String == "public.folder")
        }
        query.enableUpdates()
        results = found.sorted { a, b in
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

struct FileDetails: Equatable, Sendable {
    var kind = ""
    var location = ""
    var version: String?
    var size: String?
    var lastOpened: Date?
}

enum FileInfo {
    static func load(_ hit: FileHit) async -> FileDetails {
        let url = hit.url
        let task = Task.detached(priority: .utility) {
            var details = FileDetails(location: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
            let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .isDirectoryKey, .totalFileAllocatedSizeKey]
            let values = try? url.resourceValues(forKeys: keys)
            details.kind = values?.localizedTypeDescription ?? ""
            details.version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
                details.lastOpened = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            }
            var bytes = values?.totalFileAllocatedSize.map(Int64.init) ?? 0
            if values?.isDirectory == true {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [])
                var seen = 0
                while let next = walker?.nextObject() as? URL, seen < 200_000, !Task.isCancelled {
                    seen += 1
                    bytes += Int64((try? next.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
                }
            }
            details.size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return details
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
