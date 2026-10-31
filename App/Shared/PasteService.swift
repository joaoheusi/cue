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
        case .copiedNotPasted(let e) where e == PasteFailure.selectionChanged.error: e.message
        case .copiedNotPasted(let e): "Text copied, but not pasted. \(e.message)"
        case .failedBeforeCopy(let e): e.message
        }
    }

    var succeeded: Bool { self == .pasted || self == .copied }
}

enum PasteContent {
    case text(String)
    case data(text: String?, [String: Data])
    case files([String])
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

    func selectedText(in app: NSRunningApplication?) async -> (text: String?, copied: Bool) {
        guard canReadTarget, let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return (nil, false) }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let field = element(application, kAXFocusedUIElementAttribute)
        if isSecure(field) { return (nil, false) }
        if let text = field.flatMap({ attribute($0, kAXSelectedTextAttribute) as? String }), !text.isEmpty { return (text, false) }
        return await copySelection(from: app, application: application)
    }

    private func copySelection(from app: NSRunningApplication, application: AXUIElement) async -> (text: String?, copied: Bool) {
        let released = Date().addingTimeInterval(0.8)
        while modifiersHeld {
            guard Date() < released, !Task.isCancelled else { return (nil, false) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard canPostPaste, !Self.isTerminal(app), !isSecure(element(application, kAXFocusedUIElementAttribute)),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        else { return (nil, false) }
        let before = changeCount
        guard post(kVK_ANSI_C, to: app) else { return (nil, false) }
        let deadline = Date().addingTimeInterval(0.3)
        var copied = false
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
            copied = changeCount != before
            if copied, let text = NSPasteboard.general.string(forType: .string) { return (text, true) }
        }
        return (nil, copied)
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
        try write(.text(text), expected: expected)
    }

    @discardableResult
    func write(_ content: PasteContent, expected: Int? = nil) throws(CueError) -> Int {
        let board = NSPasteboard.general
        if let expected, board.changeCount != expected { throw PasteFailure.clipboardChanged.error }
        switch content {
        case .text(let text):
            board.declareTypes([.string, Self.originType], owner: nil)
            guard board.setString(text, forType: .string) else {
                throw CueError("CLIPBOARD_UNAVAILABLE", "Could not write text to the clipboard.")
            }
        case .data(let text, let data):
            let types = data.keys.sorted().map { NSPasteboard.PasteboardType($0) }
            board.declareTypes(types + (text == nil ? [] : [.string]) + [Self.originType], owner: nil)
            let written = types.allSatisfy { board.setData(data[$0.rawValue], forType: $0) }
            guard written, text.map({ board.setString($0, forType: .string) }) ?? true else { throw Self.writeFailed }
        case .files(let paths):
            board.clearContents()
            guard board.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL }) else { throw Self.writeFailed }
            board.addTypes([Self.originType], owner: nil)
        }
        board.setData(Data(), forType: Self.originType)
        return board.changeCount
    }

    private static let writeFailed = CueError("CLIPBOARD_UNAVAILABLE", "Could not write to the clipboard.")

    func clear() -> Int { NSPasteboard.general.clearContents() }

    func readText() throws(CueError) -> String {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            throw CueError("CLIPBOARD_EMPTY", "Copy source text before using this action.")
        }
        return text
    }

    func deliver(_ text: String, paste: Bool, target: PasteTarget?, generation: Int?, replacing original: String? = nil,
                 isCancelled: () -> Bool, hide: () -> Void) async -> Delivery {
        guard paste, let target, let original else {
            return await deliver(.text(text), paste: paste, target: target, generation: generation, isCancelled: isCancelled, hide: hide)
        }
        if let generation, changeCount != generation { return .failedBeforeCopy(PasteFailure.clipboardChanged.error) }
        hide()
        if let failure = await focus(target, isCancelled: isCancelled) { return copyInstead(text, expected: generation, failure) }
        if let failure = await retry(target, isCancelled: isCancelled, { check(target, foreground: true) }) {
            return copyInstead(text, expected: generation, failure)
        }
        let selection = await selectedText(in: target.app)
        let expected = selection.copied && generation != nil ? changeCount : generation
        if let failure = PasteRules.replace(original: original, current: selection.text) {
            return copyInstead(text, expected: expected, failure)
        }
        let written: Int
        do {
            written = try write(text, expected: expected)
        } catch {
            return .failedBeforeCopy(error)
        }
        if let failure = await retry(target, isCancelled: isCancelled, { send(target, generation: written) }) { return .copiedNotPasted(failure.error) }
        return .pasted
    }

    func deliver(_ content: PasteContent, paste: Bool, target: PasteTarget?, generation: Int?, isCancelled: () -> Bool, hide: () -> Void) async -> Delivery {
        let written: Int
        do {
            written = try write(content, expected: generation)
        } catch {
            return .failedBeforeCopy(error)
        }
        hide()
        guard paste, let target else { return .copied }
        if let failure = await focus(target, isCancelled: isCancelled) { return .copiedNotPasted(failure.error) }
        if let failure = await retry(target, isCancelled: isCancelled, { send(target, generation: written) }) { return .copiedNotPasted(failure.error) }
        return .pasted
    }

    private func copyInstead(_ text: String, expected: Int?, _ failure: PasteFailure) -> Delivery {
        do {
            try write(text, expected: expected)
            return .copiedNotPasted(failure.error)
        } catch {
            return .failedBeforeCopy(error)
        }
    }

    private func focus(_ target: PasteTarget, isCancelled: () -> Bool) async -> PasteFailure? {
        if isCancelled() { return .cancelled }
        if let failure = activate(target) { return failure }
        try? await Task.sleep(for: .milliseconds(80))
        return nil
    }

    private func retry(_ target: PasteTarget, isCancelled: () -> Bool, _ step: () -> PasteFailure?) async -> PasteFailure? {
        let start = Date()
        let deadline = start.addingTimeInterval(0.8)
        var tries = 0
        while true {
            if isCancelled() { return .cancelled }
            tries += 1
            guard let failure = step() else { return nil }
            guard PasteRules.isRetryable(failure), Date() < deadline else {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                log.record("\(failure.error.code) app=\(target.app.bundleIdentifier ?? "?") tries=\(tries) elapsed=\(elapsed)ms \(lastObservation)", "paste.detail")
                return failure
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private var modifiersHeld: Bool {
        let held: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        return !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty
    }

    private func send(_ target: PasteTarget, generation: Int) -> PasteFailure? {
        if let failure = PasteRules.send(observe(target), clipboardUnchanged: NSPasteboard.general.changeCount == generation, modifiersHeld: modifiersHeld) {
            return failure
        }
        return post(kVK_ANSI_V, to: target.app) ? nil : .unsupported
    }

    private func post(_ key: Int, to app: NSRunningApplication) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
        return true
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

    private func isSecure(_ field: AXUIElement?) -> Bool {
        field.flatMap { attribute($0, kAXSubroleAttribute) as? String } == kAXSecureTextFieldSubrole || IsSecureEventInputEnabled()
    }

    static func isTerminal(_ app: NSRunningApplication) -> Bool {
        let terminals: Set = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty",
                              "net.kovidgoyal.kitty", "org.alacritty", "org.wezfurlong.wezterm", "co.zeit.hyper"]
        return terminals.contains(app.bundleIdentifier?.lowercased() ?? "")
    }
}
