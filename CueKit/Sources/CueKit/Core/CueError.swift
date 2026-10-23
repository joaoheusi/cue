import Foundation

public struct CueError: Error, Equatable, Sendable, LocalizedError {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    public static func storage(_ detail: Any? = nil) -> CueError {
        CueError("STORAGE_FAILURE", "Could not save or read local data. Your existing data has not been reset.")
    }

    public static func validation(_ message: String) -> CueError {
        CueError("VALIDATION", message)
    }
}
