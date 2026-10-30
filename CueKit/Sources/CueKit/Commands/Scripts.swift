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

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var overflow = false
        private var expired = false

        func add(_ chunk: Data, error: Bool, limit: Int) -> Bool {
            lock.withLock {
                if error {
                    if stderr.count < 4096 { stderr.append(chunk) }
                } else {
                    stdout.append(chunk)
                    overflow = overflow || stdout.count > limit
                }
                return !overflow
            }
        }

        func expire() { lock.withLock { expired = true } }
        var state: (stdout: Data, stderr: Data, overflow: Bool, expired: Bool) { lock.withLock { (stdout, stderr, overflow, expired) } }
    }

    private static func execute(_ url: URL, timeout: TimeInterval, limit: Int) -> Result<String, CueError> {
        let process = Process()
        if FileManager.default.isExecutableFile(atPath: url.path) {
            process.executableURL = url
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [url.path]
        }
        process.currentDirectoryURL = url.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(CueError("SCRIPT_FAILED", "Could not start \(url.lastPathComponent). \(error.localizedDescription)"))
        }
        let group = -process.processIdentifier
        let stop: @Sendable () -> Void = {
            kill(group, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(group, SIGKILL) }
        }
        let capture = Capture()
        let readers = DispatchGroup()
        for (pipe, isError) in [(out, false), (err, true)] {
            let handle = pipe.fileHandleForReading
            readers.enter()
            DispatchQueue.global().async {
                defer { readers.leave() }
                while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                    if !capture.add(chunk, error: isError, limit: limit) {
                        stop()
                        return
                    }
                }
            }
        }
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            capture.expire()
            stop()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        if readers.wait(timeout: .now() + 1) == .timedOut {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        let state = capture.state
        if state.expired { return .failure(CueError("SCRIPT_TIMEOUT", "\(url.lastPathComponent) ran longer than \(Int(timeout)) seconds, so Cue stopped it.")) }
        if state.overflow { return .failure(CueError("OUTPUT_TOO_LARGE", "\(url.lastPathComponent) printed more than Cue can hold.")) }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: state.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CueError("SCRIPT_FAILED", detail.isEmpty ? "\(url.lastPathComponent) exited with code \(process.terminationStatus)." : String(detail.prefix(300))))
        }
        return .success(String(decoding: state.stdout, as: UTF8.self).trimmingCharacters(in: .newlines))
    }
}
