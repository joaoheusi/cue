import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CueKit

/// The text field Cue will paste into, captured before the command window takes focus.
@MainActor final class PasteTarget {
    let app: NSRunningApplication
    let application: AXUIElement
    let window: AXUIElement
    let field: AXUIElement
    let session: Int

    init(app: NSRunningApplication, application: AXUIElement, window: AXUIElement, field: AXUIElement, session: Int) {
        self.app = app
        self.application = application
        self.window = window
        self.field = field
        self.session = session
    }
}

enum Delivery: Equatable {
    case pasted, copied, cancelled
    case copiedNotPasted(CueError)
    case failedBeforeCopy(CueError)

    var message: String {
        switch self {
        case .pasted: "Paste sent."
        case .copied: "Copied."
        case .cancelled: "Cancelled."
        case .copiedNotPasted(let e): "Text copied, but not pasted. \(e.message)"
        case .failedBeforeCopy(let e): e.message
        }
    }

    var succeeded: Bool { self == .pasted || self == .copied }
}

/// Copies text and pastes it into a captured text field with Accessibility.
/// Safety rules: it rejects secure fields and terminals, checks the exact window and field,
/// requires an unchanged clipboard and released modifiers, and posts at most one ⌘V per delivery.
@MainActor final class PasteService {
    /// Marks Cue's own clipboard writes so the clipboard history can skip them.
    static let originType = NSPasteboard.PasteboardType("app.cue.launcher.origin")

    private var session = 0

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session += 1 }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session += 1 }
        }
    }

    // MARK: Permissions

    /// Reading the target and posting the paste key are separate grants on macOS. Report both.
    var canReadTarget: Bool { AXIsProcessTrusted() }
    var canPostPaste: Bool { CGPreflightPostEventAccess() }

    /// Shows the system prompt and opens Accessibility settings. Call only after explaining why.
    func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func permissionFailure() -> PasteFailure? {
        if !canReadTarget { return .permission }
        return canPostPaste ? nil : .postPermission
    }

    // MARK: Target

    func capture() -> Result<PasteTarget, CueError> {
        if let failure = permissionFailure() { return .failure(failure.error) }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return .failure(PasteFailure.targetUnavailable.error) }
        if Self.isTerminal(app) { return .failure(PasteFailure.terminal.error) }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let window = element(application, kAXFocusedWindowAttribute),
              let field = element(application, kAXFocusedUIElementAttribute)
        else { return .failure(PasteFailure.targetUnavailable.error) }
        if isSecure(field) { return .failure(PasteFailure.protectedInput.error) }
        return .success(PasteTarget(app: app, application: application, window: window, field: field, session: session))
    }

    /// Verifies the captured window and field still exist and that nothing else took focus.
    func check(_ target: PasteTarget) -> CueError? {
        check(target, foreground: false)?.error
    }

    private func check(_ target: PasteTarget, foreground: Bool) -> PasteFailure? {
        if let failure = permissionFailure() { return failure }
        if target.session != session || target.app.isTerminated { return .targetChanged }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front != target.app.processIdentifier {
            if front != ProcessInfo.processInfo.processIdentifier { return .targetChanged }
            if foreground { return .focusTimeout }
            // An inactive app may clear its focused element while Cue is open. Validate the
            // retained target now; verify active focus after activation, just before pasting.
            let windows = attribute(target.application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let windowExists = windows.contains { CFEqual($0, target.window) }
            let fieldExists = attribute(target.field, kAXRoleAttribute) is String
            if isSecure(target.field) { return .protectedInput }
            return windowExists && fieldExists ? nil : .targetChanged
        }
        let window = element(target.application, kAXFocusedWindowAttribute)
        let field = element(target.application, kAXFocusedUIElementAttribute)
        if let field, isSecure(field) { return .protectedInput }
        if let window, let field, CFEqual(window, target.window), CFEqual(field, target.field) { return nil }
        let changed = (window.map { !CFEqual($0, target.window) } ?? false) || (field.map { !CFEqual($0, target.field) } ?? false)
        // Activation can precede the app's focus update. Only an absent focus is retryable.
        return (window == nil || field == nil) && !changed ? .focusTimeout : .targetChanged
    }

    private func activate(_ target: PasteTarget) -> PasteFailure? {
        if let failure = check(target, foreground: false), failure != .focusTimeout { return failure }
        guard target.app.activate() else { return .targetChanged }
        AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
        return nil
    }

    // MARK: Clipboard

    var changeCount: Int { NSPasteboard.general.changeCount }

    /// Writes plain text. With `expected`, refuses to overwrite a clipboard that changed since preflight.
    @discardableResult
    func write(_ text: String, expected: Int? = nil) throws(CueError) -> Int {
        let board = NSPasteboard.general
        if let expected, board.changeCount != expected { throw PasteFailure.clipboardChanged.error }
        board.declareTypes([.string, Self.originType], owner: nil)
        guard board.setString(text, forType: .string) else {
            throw CueError("CLIPBOARD_UNAVAILABLE", "Could not write text to the clipboard.")
        }
        board.setData(Data(), forType: Self.originType)
        return board.changeCount
    }

    /// Reads plain text from the clipboard. Used only in direct response to a user action.
    func readText() throws(CueError) -> String {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            throw CueError("CLIPBOARD_EMPTY", "Copy source text before using this action.")
        }
        return text
    }

    // MARK: Delivery

    /// Copies `text`, then (when `paste` is true) returns focus to `target` and sends one ⌘V.
    /// `generation` is the clipboard change count read during preflight.
    /// `hide` runs after the copy succeeds and before focus moves.
    func deliver(_ text: String, paste: Bool, target: PasteTarget?, generation: Int?, isCancelled: () -> Bool, hide: () -> Void) async -> Delivery {
        let written: Int
        do {
            written = try write(text, expected: paste ? generation : nil)
        } catch {
            return .failedBeforeCopy(error)
        }
        hide()
        guard paste, let target else { return .copied }
        if isCancelled() { return .copiedNotPasted(PasteFailure.cancelled.error) }
        if let failure = activate(target) { return .copiedNotPasted(failure.error) }
        // Let AppKit finish activation before verifying the exact window and field.
        try? await Task.sleep(for: .milliseconds(80))
        let deadline = Date().addingTimeInterval(0.8)
        while true {
            if isCancelled() { return .copiedNotPasted(PasteFailure.cancelled.error) }
            guard let failure = send(target, generation: written) else { return .pasted }
            // Wait only for activation or released modifiers. Never retry a sent chord.
            guard failure == .modifiersHeld || failure == .focusTimeout, Date() < deadline else {
                return .copiedNotPasted(failure.error)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func send(_ target: PasteTarget, generation: Int) -> PasteFailure? {
        if let failure = check(target, foreground: true) { return failure }
        if NSPasteboard.general.changeCount != generation { return .clipboardChanged }
        let held: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        if !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return .modifiersHeld }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return .unsupported }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Route both events to the captured process. Never retry after this point.
        down.postToPid(target.app.processIdentifier)
        up.postToPid(target.app.processIdentifier)
        return nil
    }

    // MARK: Accessibility helpers

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func isSecure(_ field: AXUIElement) -> Bool {
        (attribute(field, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole || IsSecureEventInputEnabled()
    }

    static func isTerminal(_ app: NSRunningApplication) -> Bool {
        let terminals: Set = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty",
                              "net.kovidgoyal.kitty", "org.alacritty", "org.wezfurlong.wezterm", "co.zeit.hyper"]
        return terminals.contains(app.bundleIdentifier?.lowercased() ?? "")
    }
}

enum PasteFailure: Int {
    case permission = 1, targetUnavailable, targetChanged, protectedInput, terminal, clipboardChanged, modifiersHeld,
         unsupported, focusTimeout, cancelled, postPermission

    var error: CueError {
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
