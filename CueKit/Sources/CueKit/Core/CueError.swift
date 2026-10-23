import Foundation

/// A user-facing failure. `code` is stable and safe to log; `message` explains the recovery.
public struct CueError: Error, Equatable, Sendable, LocalizedError {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    /// Storage failures never expose SQL or paths. Existing data is never reset on failure.
    public static func storage(_ detail: Any? = nil) -> CueError {
        CueError("STORAGE_FAILURE", "Could not save or read local data. Your existing data has not been reset.")
    }

    public static func validation(_ message: String) -> CueError {
        CueError("VALIDATION", message)
    }
}
