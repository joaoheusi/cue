import AppKit
import CoreServices
import CueKit

struct FileHit: Identifiable, Equatable, Sendable {
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
                                "/System/Library/CoreServices/Applications",
                                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
    private static let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    static func list() -> [FileHit] {
        let manager = FileManager.default
        var found = [finder.lastPathComponent: FileHit(url: finder)]
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

/// One Spotlight query. It runs on its own serial queue because reading a large result set takes far longer than one frame.
private final class SpotlightQuery: @unchecked Sendable {
    private static let scanLimit = 2000
    private static let resultLimit = 60

    private let query = NSMetadataQuery()
    private let queue = OperationQueue()
    private var observers: [NSObjectProtocol] = []

    init(needle: String, scope: FileScope) {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        query.operationQueue = queue
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, needle)
        query.searchScopes = scope.roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        query.notificationBatchingInterval = 0.05
    }

    func start(needle: String, scope: FileScope, publish: @escaping @Sendable (_ hits: [FileHit], _ finished: Bool) -> Void) {
        queue.addOperation { [self] in
            for name in [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: queue) { [self] note in
                    guard !observers.isEmpty else { return }
                    let hits = collect(needle, scope: scope)
                    let finished = note.name == .NSMetadataQueryDidFinishGathering || query.resultCount >= Self.scanLimit
                    if finished { end() }
                    publish(hits, finished)
                })
            }
            query.start()
        }
    }

    func stop() {
        queue.addOperation { [self] in end() }
    }

    private func end() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// Reads the content type only for the hits that are kept. Each read costs about 0.4 ms, and ranking does not need it.
    // ponytail: each progress batch rescans up to 2000 hits off the main thread. Keep a cursor if that CPU time ever matters.
    private func collect(_ needle: String, scope: FileScope) -> [FileHit] {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var items: [NSMetadataItem] = [], paths: [String] = []
        for index in 0..<min(query.resultCount, Self.scanLimit) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String, scope.allows(path) else { continue }
            items.append(item)
            paths.append(path)
        }
        return FileScope.ranked(paths, needle: needle, limit: Self.resultLimit).map { index in
            FileHit(url: URL(fileURLWithPath: paths[index]), isFolder: items[index].value(forAttribute: NSMetadataItemContentTypeKey) as? String == "public.folder")
        }
    }
}

@MainActor @Observable final class FileSearch {
    private(set) var results: [FileHit] = [] { didSet { if results != oldValue { resultsRevision += 1 } } }
    private(set) var resultsRevision = 0
    @ObservationIgnored private var active: SpotlightQuery?

    private static let minimumLength = 2

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Keeps the hits that still match, so file rows do not vanish on each keystroke while Spotlight answers.
    func narrow(to text: String) {
        stop()
        let needle = Self.trimmed(text)
        let kept = needle.count < Self.minimumLength ? [] : results.filter { $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if kept != results { results = kept }
    }

    func search(_ text: String, scope: FileScope) {
        stop()
        let needle = Self.trimmed(text)
        guard needle.count >= Self.minimumLength, !scope.locations.isEmpty else {
            if !results.isEmpty { results = [] }
            return
        }
        let query = SpotlightQuery(needle: needle, scope: scope)
        active = query
        query.start(needle: needle, scope: scope) { [weak self] hits, finished in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(hits, finished: finished, from: query) } }
        }
    }

    func stop() {
        active?.stop()
        active = nil
    }

    private func receive(_ hits: [FileHit], finished: Bool, from query: SpotlightQuery) {
        guard active === query else { return }
        if finished { active = nil }
        if (finished || hits.count >= results.count), hits != results { results = hits }
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
    /// Folders return no size here, because adding one up can take seconds. Use `folderSize` for those.
    static func load(_ hit: FileHit) async -> FileDetails {
        let url = hit.url
        return await Task.detached(priority: .utility) {
            var details = FileDetails(location: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
            let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .isDirectoryKey, .totalFileAllocatedSizeKey]
            let values = try? url.resourceValues(forKeys: keys)
            details.kind = values?.localizedTypeDescription ?? ""
            details.version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
                details.lastOpened = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            }
            if values?.isDirectory != true {
                details.size = ByteCountFormatter.string(fromByteCount: Int64(values?.totalFileAllocatedSize ?? 0), countStyle: .file)
            }
            return details
        }.value
    }

    static func folderSize(_ hit: FileHit) async -> String {
        let url = hit.url
        let task = Task.detached(priority: .utility) {
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [])
            var bytes: Int64 = 0, seen = 0
            while let next = walker?.nextObject() as? URL, seen < 200_000, !Task.isCancelled {
                seen += 1
                bytes += Int64((try? next.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
