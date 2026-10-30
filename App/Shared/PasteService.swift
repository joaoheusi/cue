import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CueKit

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

@MainActor final class PasteService {
    static let originType = NSPasteboard.PasteboardType("app.cue.launcher.origin")

    private let log: DiagnosticsLog
    private var session = 0
    private var lastObservation = ""

    init(log: DiagnosticsLog) {
        self.log = log
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

    var canReadTarget: Bool { AXIsProcessTrusted() }
    var canPostPaste: Bool { CGPreflightPostEventAccess() }

    func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func permissionFailure() -> PasteFailure? {
        if !canReadTarget { return .permission }
        return canPostPaste ? nil : .postPermission
    }

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

    func check(_ target: PasteTarget) -> CueError? {
        guard let failure = check(target, foreground: false) else { return nil }
        log.record("\(failure.error.code) app=\(target.app.bundleIdentifier ?? "?") \(lastObservation)", "paste.precheck")
        return failure.error
    }

    private func check(_ target: PasteTarget, foreground: Bool) -> PasteFailure? {
        PasteRules.check(observe(target), foreground: foreground)
    }

    private func observe(_ target: PasteTarget) -> PasteRules.Observation {
        var o = PasteRules.Observation()
        lastObservation = ""
        o.canRead = canReadTarget
        o.canPost = canPostPaste
        o.sameSession = target.session == session
        o.terminated = target.app.isTerminated
        guard o.canRead, o.canPost, o.sameSession, !o.terminated else { return o }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == target.app.processIdentifier {
            o.front = .target
            let (window, windowRead) = read(target.application, kAXFocusedWindowAttribute)
            let (field, fieldRead) = read(target.application, kAXFocusedUIElementAttribute)
            o.focusedWindow = window.map { CFEqual($0, target.window) ? .same : .different } ?? .missing
            o.focusedField = field.map { CFEqual($0, target.field) ? .same : .different } ?? .missing
            o.secureField = field.map(isSecure) ?? false
            lastObservation = "front=target window=\(o.focusedWindow)/\(windowRead) field=\(o.focusedField)/\(fieldRead)"
        } else if front == ProcessInfo.processInfo.processIdentifier {
            o.front = .cue
            let windows = attribute(target.application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            o.windowExists = windows.contains { CFEqual($0, target.window) }
            o.fieldExists = attribute(target.field, kAXRoleAttribute) is String
            o.secureField = isSecure(target.field)
            lastObservation = "front=cue windowExists=\(o.windowExists) fieldExists=\(o.fieldExists)"
        } else {
            o.front = .other
            lastObservation = "front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")"
        }
        return o
    }

    private func activate(_ target: PasteTarget) -> PasteFailure? {
        if let failure = check(target, foreground: false) { return failure }
        guard target.app.activate() else { return .targetChanged }
        AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
        return nil
    }

    var changeCount: Int { NSPasteboard.general.changeCount }

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

    func readText() throws(CueError) -> String {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            throw CueError("CLIPBOARD_EMPTY", "Copy source text before using this action.")
        }
        return text
    }

    func deliver(_ text: String, paste: Bool, target: PasteTarget?, generation: Int?, isCancelled: () -> Bool, hide: () -> Void) async -> Delivery {
        let written: Int
        do {
            written = try write(text, expected: generation)
        } catch {
            return .failedBeforeCopy(error)
        }
        hide()
        guard paste, let target else { return .copied }
        if isCancelled() { return .copiedNotPasted(PasteFailure.cancelled.error) }
        if let failure = activate(target) { return .copiedNotPasted(failure.error) }
        try? await Task.sleep(for: .milliseconds(80))
        let start = Date()
        let deadline = start.addingTimeInterval(0.8)
        var tries = 0
        while true {
            if isCancelled() { return .copiedNotPasted(PasteFailure.cancelled.error) }
            tries += 1
            guard let failure = send(target, generation: written) else { return .pasted }
            guard PasteRules.isRetryable(failure), Date() < deadline else {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                log.record("\(failure.error.code) app=\(target.app.bundleIdentifier ?? "?") tries=\(tries) elapsed=\(elapsed)ms \(lastObservation)", "paste.detail")
                return .copiedNotPasted(failure.error)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func send(_ target: PasteTarget, generation: Int) -> PasteFailure? {
        let held: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        if let failure = PasteRules.send(observe(target), clipboardUnchanged: NSPasteboard.general.changeCount == generation,
                                         modifiersHeld: !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty) {
            return failure
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return .unsupported }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(target.app.processIdentifier)
        up.postToPid(target.app.processIdentifier)
        return nil
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        read(element, name).0
    }

    private func read(_ element: AXUIElement, _ name: String) -> (AXUIElement?, String) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else { return (nil, "ax\(result.rawValue)") }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, "notElement") }
        return ((value as! AXUIElement), "ok")
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
