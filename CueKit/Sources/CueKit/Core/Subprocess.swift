import Foundation

public final class Subprocess: @unchecked Sendable {
    public struct Output: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let status: Int32
        public let overflow: Bool
        public let expired: Bool
        public let stopped: Bool
    }

    private let process = Process()
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var overflow = false
    private var expired = false
    private var stopped = false
    private var group: pid_t?

    public init(executable: URL, arguments: [String] = [], directory: URL? = nil, environment: [String: String]? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
    }

    public func stop() {
        let group = lock.withLock {
            stopped = true
            return self.group
        }
        if let group { Self.terminate(group) }
    }

    public func run(timeout: TimeInterval, limit: Int) throws -> Output {
        guard !lock.withLock({ stopped }) else { return output(status: -1) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let group = -process.processIdentifier
        if lock.withLock({
            self.group = group
            return stopped
        }) { Self.terminate(group) }
        let readers = DispatchGroup()
        for (pipe, isError) in [(out, false), (err, true)] {
            let handle = pipe.fileHandleForReading
            readers.enter()
            DispatchQueue.global().async {
                defer { readers.leave() }
                while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
                    if !self.add(chunk, error: isError, limit: limit) {
                        Self.terminate(group)
                        return
                    }
                }
            }
        }
        let deadline = DispatchWorkItem {
            guard self.process.isRunning else { return }
            self.lock.withLock { self.expired = true }
            Self.terminate(group)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        if readers.wait(timeout: .now() + 1) == .timedOut {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        return output(status: process.terminationStatus)
    }

    private func add(_ chunk: Data, error: Bool, limit: Int) -> Bool {
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

    private func output(status: Int32) -> Output {
        lock.withLock { Output(stdout: stdout, stderr: stderr, status: status, overflow: overflow, expired: expired, stopped: stopped) }
    }

    private static func terminate(_ group: pid_t) {
        kill(group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(group, SIGKILL) }
    }
}
