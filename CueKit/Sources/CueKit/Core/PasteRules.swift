import Foundation

public enum PasteFailure: Int, Sendable {
    case permission = 1, targetUnavailable, targetChanged, protectedInput, terminal, clipboardChanged, modifiersHeld,
         unsupported, focusTimeout, cancelled, postPermission

    public var error: CueError {
        switch self {
        case .permission: CueError("PERMISSION_REQUIRED", "Cue cannot access your text field. Enable Cue in System Settings → Privacy & Security → Accessibility. If it is already on, turn it off and on, then quit and reopen Cue.")
        case .targetUnavailable: CueError("TARGET_UNAVAILABLE", "Focus a text field in another app, then open Cue with your shortcut.")
        case .targetChanged: CueError("TARGET_CHANGED", "The target window or text field changed. Reopen Cue from the field you want to paste into.")
        case .protectedInput: CueError("PROTECTED_INPUT", "Automatic paste is unavailable in protected text fields.")
        case .terminal: CueError("PASTE_UNSUPPORTED", "Terminal apps use Copy. Paste manually in your terminal.")
        case .clipboardChanged: CueError("CLIPBOARD_CHANGED", "The clipboard changed. Reopen Cue to prepare the action again.")
        case .modifiersHeld: CueError("MODIFIERS_HELD", "Release the shortcut keys and try again.")
        case .unsupported: CueError("PASTE_UNSUPPORTED", "Automatic paste is unavailable. Use Copy.")
        case .focusTimeout: CueError("FOCUS_TIMEOUT", "Could not return to the target window. Paste manually.")
        case .cancelled: CueError("CANCELLED", "Paste cancelled.")
        case .postPermission: CueError("PASTE_PERMISSION_REQUIRED", "macOS allows Cue to read the target but is blocking the paste shortcut. Refresh Cue’s Accessibility access, then quit and reopen Cue.")
        }
    }
}

public enum PasteRules {
    public enum Front: Sendable { case target, cue, other }
    public enum Focus: Sendable { case same, different, missing }

    public struct Observation: Sendable {
        public var canRead = true
        public var canPost = true
        public var sameSession = true
        public var terminated = false
        public var front = Front.target
        public var windowExists = true
        public var fieldExists = true
        public var focusedWindow = Focus.same
        public var focusedField = Focus.same
        public var secureField = false

        public init() {}
    }

    public static func check(_ o: Observation, foreground: Bool) -> PasteFailure? {
        if !o.canRead { return .permission }
        if !o.canPost { return .postPermission }
        if !o.sameSession || o.terminated { return .targetChanged }
        switch o.front {
        case .other:
            return .targetChanged
        case .cue:
            if foreground { return .focusTimeout }
            if o.secureField { return .protectedInput }
            return o.windowExists && o.fieldExists ? nil : .targetChanged
        case .target:
            if o.secureField { return .protectedInput }
            if o.focusedWindow == .same && o.focusedField == .same { return nil }
            let changed = o.focusedWindow == .different || o.focusedField == .different
            return changed ? .targetChanged : .focusTimeout
        }
    }

    public static func send(_ o: Observation, clipboardUnchanged: Bool, modifiersHeld: Bool) -> PasteFailure? {
        if let failure = check(o, foreground: true) { return failure }
        if !clipboardUnchanged { return .clipboardChanged }
        if modifiersHeld { return .modifiersHeld }
        return nil
    }

    public static func isRetryable(_ failure: PasteFailure) -> Bool {
        failure == .modifiersHeld || failure == .focusTimeout
    }
}
