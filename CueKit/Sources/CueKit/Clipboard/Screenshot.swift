import Foundation

public enum Screenshot {
    /// The macOS preferences domain that holds the screenshot folder under `location`.
    public static let domain = "com.apple.screencapture"
    /// Screenshot.app, shown as the source of screenshots in history.
    public static let sourceApp = "com.apple.screenshot.launcher"

    /// The folder macOS saves screenshots to. `location` is the raw preference value.
    /// macOS uses the Desktop when the value is missing or does not name a folder.
    public static func folder(location: String?, home: URL, isDirectory: (URL) -> Bool) -> URL {
        let desktop = home.appending(path: "Desktop", directoryHint: .isDirectory)
        guard let raw = location?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return desktop }
        let path = raw == "~" ? home.path : raw.hasPrefix("~/") ? home.path + raw.dropFirst() : raw
        guard path.hasPrefix("/") else { return desktop }
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        return isDirectory(url) ? url : desktop
    }
}

/// Admits each new screenshot image once. Files created before `start`, recordings, and other types are skipped.
public struct ScreenshotFilter: Sendable {
    public let start: Date
    private var seen: Set<String> = []

    public init(start: Date) { self.start = start }

    public mutating func admit(path: String, type: String?, created: Date?) -> Bool {
        guard let type, CaptureFilter.imageTypes.contains(type), let created, created >= start else { return false }
        return seen.insert(path).inserted
    }
}
