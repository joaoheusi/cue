import Foundation

public struct Script: Equatable, Sendable, Identifiable {
    public let url: URL
    public var id: String { url.path }
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public init(url: URL) { self.url = url }
}

public enum Scripts {
    public static let folderName = "commands"
    public static let timeout: TimeInterval = 30
    public static let timeoutChoices = [10, 30, 60, 120, 300]

    public static func list(in folder: URL) -> [Script] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let urls = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Script.init)
    }

    public static func run(_ script: Script, timeout: TimeInterval = timeout, limit: Int = Template.outputLimit) async throws(CueError) -> String {
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: execute(script.url, timeout: timeout, limit: limit)) }
        }
        return try result.get()
    }

    private static func execute(_ url: URL, timeout: TimeInterval, limit: Int) -> Result<String, CueError> {
        let direct = FileManager.default.isExecutableFile(atPath: url.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        let process = Subprocess(executable: direct ? url : URL(fileURLWithPath: "/bin/sh"), arguments: direct ? [] : [url.path],
                                 directory: url.deletingLastPathComponent(), environment: environment)
        let output: Subprocess.Output
        do {
            output = try process.run(timeout: timeout, limit: limit)
        } catch {
            return .failure(CueError("SCRIPT_FAILED", "Could not start \(url.lastPathComponent). \(error.localizedDescription)"))
        }
        if output.expired { return .failure(CueError("SCRIPT_TIMEOUT", "\(url.lastPathComponent) ran longer than \(Int(timeout)) seconds, so Cue stopped it.")) }
        if output.overflow { return .failure(CueError("OUTPUT_TOO_LARGE", "\(url.lastPathComponent) printed more than Cue can hold.")) }
        guard output.status == 0 else {
            let detail = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CueError("SCRIPT_FAILED", detail.isEmpty ? "\(url.lastPathComponent) exited with code \(output.status)." : String(detail.prefix(300))))
        }
        return .success(String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .newlines))
    }
}
