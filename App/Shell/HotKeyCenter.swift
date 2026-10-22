import Carbon.HIToolbox
import CueKit

/// System-wide shortcuts through Carbon `RegisterEventHotKey`. Needs no permission.
/// Owners are stable strings such as `palette`, `clipboard`, or `action:<uuid>`.
@MainActor final class HotKeyCenter {
    struct Status: Equatable {
        var requested: Shortcut?
        var active: Bool
        var error: String?
    }

    private struct Binding {
        let shortcut: Shortcut
        let ref: EventHotKeyRef?
        let handler: @MainActor () -> Void
    }

    private var bindings: [String: Binding] = [:]
    private var ids: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private(set) var paused = false
    /// Every requested shortcut with its live state, for settings and diagnostics.
    private(set) var statuses: [String: Status] = [:]
    var onChange: () -> Void = {}

    /// Registers `shortcut` for `owner`. On failure the owner's previous working binding stays active.
    func register(_ owner: String, _ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) throws(CueError) {
        if bindings.contains(where: { $0.key != owner && $0.value.shortcut == shortcut }) {
            throw CueError("SHORTCUT_CONFLICT", "This shortcut is already used in Cue. Choose another.")
        }
        if paused {
            unregister(owner)
            bindings[owner] = Binding(shortcut: shortcut, ref: nil, handler: handler)
            statuses[owner] = Status(requested: shortcut, active: false, error: "Shortcuts paused")
            onChange()
            return
        }
        let ref = try install(shortcut, owner: owner)
        if let old = bindings[owner]?.ref { UnregisterEventHotKey(old) }
        bindings[owner] = Binding(shortcut: shortcut, ref: ref, handler: handler)
        statuses[owner] = Status(requested: shortcut, active: true, error: nil)
        onChange()
    }

    /// Records a shortcut that could not be activated, so settings can show why.
    func markUnavailable(_ owner: String, _ shortcut: Shortcut?, reason: String) {
        unregister(owner)
        statuses[owner] = Status(requested: shortcut, active: false, error: reason)
        onChange()
    }

    func unregister(_ owner: String) {
        if let ref = bindings.removeValue(forKey: owner)?.ref { UnregisterEventHotKey(ref) }
        ids = ids.filter { $0.value != owner }
        statuses[owner] = nil
        onChange()
    }

    /// Pausing keeps every binding but releases it from the system. Resuming re-registers each one.
    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        let current = bindings
        for (owner, binding) in current {
            if let ref = binding.ref { UnregisterEventHotKey(ref) }
            bindings[owner] = Binding(shortcut: binding.shortcut, ref: nil, handler: binding.handler)
            statuses[owner] = Status(requested: binding.shortcut, active: false, error: value ? "Shortcuts paused" : nil)
        }
        if !value {
            for (owner, binding) in current {
                do {
                    let ref = try install(binding.shortcut, owner: owner)
                    bindings[owner] = Binding(shortcut: binding.shortcut, ref: ref, handler: binding.handler)
                    statuses[owner] = Status(requested: binding.shortcut, active: true, error: nil)
                } catch {
                    statuses[owner] = Status(requested: binding.shortcut, active: false, error: error.message)
                }
            }
        }
        onChange()
    }

    func unregisterAll() {
        for owner in Array(bindings.keys) { unregister(owner) }
    }

    private func install(_ shortcut: Shortcut, owner: String) throws(CueError) -> EventHotKeyRef? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var modifiers: UInt32 = 0
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        if shortcut.control { modifiers |= UInt32(controlKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, modifiers, EventHotKeyID(signature: 0x4355_4521, id: id), GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr else {
            throw CueError("SHORTCUT_CONFLICT", "macOS could not register \(shortcut.display). Another app may use it. Choose another.")
        }
        ids[id] = owner
        return ref
    }

    fileprivate func fire(_ id: UInt32) {
        guard let owner = ids[id], let binding = bindings[owner] else { return }
        binding.handler()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard let context else { return noErr }
            let id = key.id
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue().fire(id)
            }
            return noErr
        }, 1, &spec, context, nil)
    }
}
