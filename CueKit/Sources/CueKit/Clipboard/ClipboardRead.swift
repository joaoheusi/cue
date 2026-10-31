import Foundation

public enum ClipboardAccess: String, Codable, Sendable {
    case standard = "default", ask, alwaysAllow, alwaysDeny, unavailable
}

public enum ClipboardChildReply: Codable, Equatable, Sendable {
    case decision(CaptureDecision, access: ClipboardAccess)
    case denied(child: ClipboardAccess, parent: ClipboardAccess)

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> ClipboardChildReply? {
        try? PropertyListDecoder().decode(ClipboardChildReply.self, from: data)
    }
}

public enum ClipboardReadOutcome: Equatable, Sendable {
    case reply(ClipboardChildReply)
    case failedToStart(String)
    case timedOut
    case crashed
    case cancelled
}

public enum ClipboardReadStep: Equatable, Sendable {
    case finish(CaptureDecision)
    case readOnMainThread
}

public enum ClipboardChild {
    public static let argument = "--clipboard-read"
    public static let timeout: TimeInterval = 30
    public static let watchdog: UInt32 = 35
    static let maxReplyBytes = 1024 * 1024

    public struct Request: Equatable, Sendable {
        public let changeCount: Int
        public let access: ClipboardAccess

        public init(changeCount: Int, access: ClipboardAccess) {
            self.changeCount = changeCount
            self.access = access
        }

        public init?(arguments: [String]) {
            guard arguments.count == 3, arguments[0] == ClipboardChild.argument, let changeCount = Int(arguments[1]),
                  let access = ClipboardAccess(rawValue: arguments[2]) else { return nil }
            self.init(changeCount: changeCount, access: access)
        }

        public var arguments: [String] { [ClipboardChild.argument, String(changeCount), access.rawValue] }
    }

    public struct Source {
        public var changeCount: () -> Int
        public var access: () -> ClipboardAccess
        public var types: () -> [String]
        public var text: () -> String?

        public init(changeCount: @escaping () -> Int, access: @escaping () -> ClipboardAccess, types: @escaping () -> [String], text: @escaping () -> String?) {
            self.changeCount = changeCount
            self.access = access
            self.types = types
            self.text = text
        }
    }

    public static func reply(to request: Request, source: Source) -> ClipboardChildReply {
        let before = source.access()
        guard source.changeCount() == request.changeCount else { return .decision(.skip(.stale), access: before) }
        if before == .alwaysDeny || before != request.access { return .denied(child: before, parent: request.access) }
        let decision = CaptureFilter.read(types: source.types(), readText: source.text)
        let after = source.access()
        if after == .alwaysDeny { return .denied(child: after, parent: request.access) }
        guard source.changeCount() == request.changeCount else { return .decision(.skip(.stale), access: after) }
        return .decision(decision, access: after)
    }

    public static func read(executable: URL?, arguments: [String], timeout: TimeInterval = timeout) async -> ClipboardReadOutcome {
        guard let executable else { return .failedToStart("Cue could not find its own executable.") }
        let process = Subprocess(executable: executable, arguments: arguments)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: outcome(of: process, timeout: timeout))
                }
            }
        } onCancel: {
            process.stop()
        }
    }

    private static func outcome(of process: Subprocess, timeout: TimeInterval) -> ClipboardReadOutcome {
        let output: Subprocess.Output
        do {
            output = try process.run(timeout: timeout, limit: maxReplyBytes)
        } catch {
            return .failedToStart(error.localizedDescription)
        }
        if output.stopped { return .cancelled }
        if output.expired { return .timedOut }
        guard output.status == 0, !output.overflow, let reply = ClipboardChildReply.decode(output.stdout) else { return .crashed }
        return .reply(reply)
    }
}

public struct ClipboardReaderState: Equatable, Sendable {
    public static let failureLimit = 3

    public private(set) var fallbackReason: String?
    public private(set) var childAccess: ClipboardAccess?
    public private(set) var reads = 0
    public private(set) var slowestMilliseconds = 0.0
    public private(set) var timedOut = 0
    public private(set) var crashed = 0
    public private(set) var cancelled = 0
    public private(set) var failuresInARow = 0
    private var crashesInARow = 0
    private var totalMilliseconds = 0.0

    public init() {}

    public var usesChild: Bool { fallbackReason == nil }
    public var failing: Bool { usesChild && failuresInARow >= Self.failureLimit }
    public var averageMilliseconds: Double { reads == 0 ? 0 : totalMilliseconds / Double(reads) }

    public mutating func record(_ outcome: ClipboardReadOutcome, milliseconds: Double) -> ClipboardReadStep {
        switch outcome {
        case .reply(.decision(let decision, let access)):
            timed(milliseconds)
            childAccess = access
            crashesInARow = 0
            switch decision {
            case .skip(.unreadable): failuresInARow += 1
            case .skip(.stale): break
            default: failuresInARow = 0
            }
            return .finish(decision)
        case .reply(.denied(let child, let parent)):
            timed(milliseconds)
            childAccess = child
            fallbackReason = "The reader has \(child.rawValue) pasteboard access, and Cue has \(parent.rawValue)."
            return .readOnMainThread
        case .failedToStart(let detail):
            fallbackReason = "The reader could not start. \(detail)"
            return .readOnMainThread
        case .timedOut:
            timedOut += 1
            failuresInARow += 1
            crashesInARow = 0
            return .finish(.skip(.timedOut))
        case .crashed:
            crashed += 1
            failuresInARow += 1
            crashesInARow += 1
            guard crashesInARow >= Self.failureLimit else { return .finish(.skip(.unreadable)) }
            fallbackReason = "The reader crashed \(crashesInARow) times in a row."
            return .readOnMainThread
        case .cancelled:
            cancelled += 1
            return .finish(.skip(.stale))
        }
    }

    private mutating func timed(_ milliseconds: Double) {
        reads += 1
        totalMilliseconds += milliseconds
        slowestMilliseconds = max(slowestMilliseconds, milliseconds)
    }

    public var diagnostics: [(String, String)] {
        func time(_ milliseconds: Double) -> String { reads == 0 ? "no reads yet" : "\(Int(milliseconds.rounded())) ms" }
        return [
            ("Reader mode", usesChild ? "child" : "fallback"),
            ("Reader fallback reason", fallbackReason ?? "none"),
            ("Reader pasteboard access", childAccess?.rawValue ?? "not read yet"),
            ("Child reads", "\(reads)"),
            ("Child read average", time(averageMilliseconds)),
            ("Child read slowest", time(slowestMilliseconds)),
            ("Child reads timed out", "\(timedOut)"),
            ("Child reads crashed", "\(crashed)"),
            ("Child reads cancelled", "\(cancelled)"),
            ("Child failures in a row", "\(failuresInARow)"),
        ]
    }
}
