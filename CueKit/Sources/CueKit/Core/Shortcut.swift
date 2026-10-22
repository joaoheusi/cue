import Foundation

/// A global keyboard chord. The stored form matches the former Tauri format,
/// for example `Super+Shift+Space`, so existing libraries keep their shortcuts.
public struct Shortcut: Hashable, Sendable, CustomStringConvertible {
    public var command = false
    public var control = false
    public var option = false
    public var shift = false
    /// Canonical key name from `Shortcut.keyCodes`, for example `A`, `1`, `Space`, or `F5`.
    public var key: String

    public init(key: String, command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false) {
        self.key = key
        self.command = command
        self.control = control
        self.option = option
        self.shift = shift
    }

    /// Parses `Super+Control+Alt+Shift+Key`. Accepts common aliases. Returns nil for unknown keys
    /// or chords that would capture ordinary typing (no Command, Control, or Option, except function keys).
    public init?(_ text: String) {
        let parts = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.count >= 2, let last = parts.last else { return nil }
        guard let key = Self.keyCodes.keys.first(where: { $0.lowercased() == last }) ?? Self.aliases[last] else { return nil }
        self.key = key
        for part in parts.dropLast() {
            switch part {
            case "super", "cmd", "command", "meta", "commandorcontrol", "cmdorctrl", "cmdorcontrol": command = true
            case "control", "ctrl": control = true
            case "alt", "option", "opt": option = true
            case "shift": shift = true
            default: return nil
            }
        }
        guard isValid else { return nil }
    }

    public var isValid: Bool {
        Self.keyCodes[key] != nil && (command || control || option || (key.hasPrefix("F") && key.count > 1))
    }

    /// Stored form, ordered Super, Control, Alt, Shift.
    public var description: String {
        ([command ? "Super" : nil, control ? "Control" : nil, option ? "Alt" : nil, shift ? "Shift" : nil].compactMap { $0 } + [key])
            .joined(separator: "+")
    }

    /// Menu-style symbols, for example `⌃⌥⇧⌘Space`.
    public var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key
    }

    public var keyCode: UInt32 { Self.keyCodes[key] ?? 0 }

    public init?(keyCode: UInt16, command: Bool, control: Bool, option: Bool, shift: Bool) {
        guard let key = Self.keyCodes.first(where: { $0.value == UInt32(keyCode) })?.key else { return nil }
        self.init(key: key, command: command, control: control, option: option, shift: shift)
        guard isValid else { return nil }
    }

    static let aliases: [String: String] = [
        "return": "Enter", "esc": "Escape", "left": "ArrowLeft", "right": "ArrowRight",
        "up": "ArrowUp", "down": "ArrowDown", "grave": "Backquote",
    ]

    /// macOS ANSI virtual key codes (Carbon `kVK_*`).
    public static let keyCodes: [String: UInt32] = [
        "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05, "Z": 0x06, "X": 0x07,
        "C": 0x08, "V": 0x09, "B": 0x0B, "Q": 0x0C, "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10,
        "T": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "Equal": 0x18,
        "9": 0x19, "7": 0x1A, "Minus": 0x1B, "8": 0x1C, "0": 0x1D, "BracketRight": 0x1E, "O": 0x1F,
        "U": 0x20, "BracketLeft": 0x21, "I": 0x22, "P": 0x23, "Enter": 0x24, "L": 0x25, "J": 0x26,
        "Quote": 0x27, "K": 0x28, "Semicolon": 0x29, "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C,
        "N": 0x2D, "M": 0x2E, "Period": 0x2F, "Tab": 0x30, "Space": 0x31, "Backquote": 0x32,
        "Backspace": 0x33, "Escape": 0x35, "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60,
        "F6": 0x61, "F7": 0x62, "F8": 0x64, "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
        "Home": 0x73, "PageUp": 0x74, "Delete": 0x75, "End": 0x77, "PageDown": 0x79,
        "ArrowLeft": 0x7B, "ArrowRight": 0x7C, "ArrowDown": 0x7D, "ArrowUp": 0x7E,
    ]
}
