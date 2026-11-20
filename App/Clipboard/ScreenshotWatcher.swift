import AppKit
import CueKit

/// Watches the macOS screenshot folder and hands each new screenshot to `deliver`.
/// It only reads files. It never moves or deletes them.
@MainActor final class ScreenshotWatcher {
    struct Shot: Sendable {
        let file: URL
        let type: String
        let data: Data
        let decision: CaptureDecision
    }

    static let folderDeniedError = CueError(
        "SCREENSHOT_FOLDER_DENIED",
        "macOS is blocking Cue from reading your screenshot folder, so new screenshots are not copied. Allow Cue in System Settings → Privacy & Security → Files & Folders.")
    static let filesSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    private nonisolated static let tooLarge = CueError("SCREENSHOT_TOO_LARGE", "The screenshot is larger than 64 MB, so Cue did not copy it.")

    private(set) var folder: URL?
    private let deliver: (Shot) -> Void
    private let failed: (Error) -> Void
    private var filter = ScreenshotFilter(start: .now)
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var locationTask: Task<Void, Never>?
    private var reads: [String: Task<Void, Never>] = [:]

    init(deliver: @escaping (Shot) -> Void, failed: @escaping (Error) -> Void) {
        self.deliver = deliver
        self.failed = failed
    }

    var isRunning: Bool { locationTask != nil }

    func start() {
        guard locationTask == nil else { return }
        filter = ScreenshotFilter(start: .now)
        watch(Self.currentFolder())
        // ponytail: polls the preference every 5 s; screenshots taken in the first seconds after a folder change can be missed.
        locationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                let next = Self.currentFolder()
                if next != folder { watch(next) }
            }
        }
    }

    func stop() {
        locationTask?.cancel()
        locationTask = nil
        stopQuery()
        reads.values.forEach { $0.cancel() }
        reads = [:]
        folder = nil
    }

    static func isDenied(_ error: Error) -> Bool {
        if let error = error as? CocoaError, error.code == .fileReadNoPermission { return true }
        let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return posix?.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(posix?.code)
    }

    private static func currentFolder() -> URL {
        let location = UserDefaults(suiteName: Screenshot.domain)?.string(forKey: "location")
        return Screenshot.folder(location: location, home: FileManager.default.homeDirectoryForCurrentUser) { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
    }

    private func watch(_ folder: URL) {
        stopQuery()
        self.folder = folder
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K == 1", "kMDItemIsScreenCapture")
        query.searchScopes = [folder]
        observers = [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate].map { name in
            NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] note in
                let added = Self.files(note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? [])
                MainActor.assumeIsolated {
                    guard let self, let query = self.query else { return }
                    self.found(name == .NSMetadataQueryDidFinishGathering ? Self.files(query.results as? [NSMetadataItem] ?? []) : added)
                }
            }
        }
        self.query = query
        query.start()
    }

    private func stopQuery() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private struct Found: Sendable {
        let path: String
        let type: String?
        let created: Date?
    }

    private nonisolated static func files(_ items: [NSMetadataItem]) -> [Found] {
        items.compactMap { item in
            (item.value(forAttribute: NSMetadataItemPathKey) as? String).map {
                Found(path: $0, type: item.value(forAttribute: NSMetadataItemContentTypeKey) as? String,
                      created: item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date)
            }
        }
    }

    private func found(_ files: [Found]) {
        for file in files where filter.admit(path: file.path, type: file.type, created: file.created) {
            read(URL(filePath: file.path), type: file.type ?? "")
        }
    }

    private func read(_ file: URL, type: String) {
        let key = file.path
        reads[key] = Task { [weak self] in
            let result: Result<Shot, Error> = await Task.detached(priority: .utility) {
                do { return .success(try await Self.load(file, type: type)) } catch { return .failure(error) }
            }.value
            guard !Task.isCancelled, let self else { return }
            reads[key] = nil
            switch result {
            case .success(let shot): deliver(shot)
            case .failure(let error): failed(error)
            }
        }
    }

    /// Waits until the file stops growing, so a partly written screenshot is never copied.
    private nonisolated static func load(_ file: URL, type: String) async throws -> Shot {
        var size = -1
        for _ in 0..<40 {
            let current = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if current > 0, current == size { break }
            size = current
            try await Task.sleep(for: .milliseconds(250))
        }
        guard size <= CaptureFilter.maxImageBytes else { throw tooLarge }
        let data = try Data(contentsOf: file)
        return Shot(file: file, type: type, data: data, decision: ClipImage.capture(data, type: type))
    }
}
