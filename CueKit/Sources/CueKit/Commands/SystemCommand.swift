import Foundation

// Raw values are saved as shortcut owners. Keep them when renaming a command.
public enum SystemCommand: String, CaseIterable, Identifiable, Sendable {
    case volumeUp, volumeDown, toggleMute
    case volume0, volume25, volume50, volume75, volume100
    case toggleMicrophoneMute
    case playPause, nextTrack, previousTrack
    case toggleAppearance, appearanceLight, appearanceDark, appearanceAuto
    case lockScreen, sleepDisplays, sleep
    case openTrash, emptyTrash, ejectAllDisks, toggleHiddenFiles
    case hideOtherApps, unhideAllApps, quitAllApps, restartFrontApp

    public static let sections: [(title: String, commands: [SystemCommand])] = [
        ("Audio & Media", [.volumeUp, .volumeDown, .toggleMute, .volume0, .volume25, .volume50, .volume75, .volume100,
                           .toggleMicrophoneMute, .playPause, .nextTrack, .previousTrack]),
        ("Appearance", [.toggleAppearance, .appearanceLight, .appearanceDark, .appearanceAuto]),
        ("Session", [.lockScreen, .sleepDisplays, .sleep]),
        ("Files", [.openTrash, .emptyTrash, .ejectAllDisks, .toggleHiddenFiles]),
        ("Apps", [.hideOtherApps, .unhideAllApps, .quitAllApps, .restartFrontApp]),
    ]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .volumeUp: "Turn Volume Up"
        case .volumeDown: "Turn Volume Down"
        case .toggleMute: "Toggle Mute"
        case .volume0: "Set Volume to 0%"
        case .volume25: "Set Volume to 25%"
        case .volume50: "Set Volume to 50%"
        case .volume75: "Set Volume to 75%"
        case .volume100: "Set Volume to 100%"
        case .toggleMicrophoneMute: "Toggle Microphone Mute"
        case .playPause: "Play / Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .toggleAppearance: "Toggle System Appearance"
        case .appearanceLight: "Set Light Appearance"
        case .appearanceDark: "Set Dark Appearance"
        case .appearanceAuto: "Set Auto Appearance"
        case .lockScreen: "Lock Screen"
        case .sleepDisplays: "Sleep Displays"
        case .sleep: "Sleep"
        case .openTrash: "Open Trash"
        case .emptyTrash: "Empty Trash"
        case .ejectAllDisks: "Eject All Disks"
        case .toggleHiddenFiles: "Toggle Hidden Files"
        case .hideOtherApps: "Hide All Apps Except Frontmost"
        case .unhideAllApps: "Unhide All Hidden Apps"
        case .quitAllApps: "Quit All Apps"
        case .restartFrontApp: "Restart Frontmost App"
        }
    }

    public var symbol: String {
        switch self {
        case .volumeUp: "speaker.wave.3"
        case .volumeDown: "speaker.wave.1"
        case .toggleMute: "speaker.slash"
        case .volume0: "speaker"
        case .volume25, .volume50: "speaker.wave.2"
        case .volume75, .volume100: "speaker.wave.3"
        case .toggleMicrophoneMute: "mic.slash"
        case .playPause: "playpause"
        case .nextTrack: "forward.end"
        case .previousTrack: "backward.end"
        case .toggleAppearance: "circle.lefthalf.filled"
        case .appearanceLight: "sun.max"
        case .appearanceDark: "moon"
        case .appearanceAuto: "circle.righthalf.filled"
        case .lockScreen: "lock"
        case .sleepDisplays: "display"
        case .sleep: "moon.zzz"
        case .openTrash: "trash"
        case .emptyTrash: "trash.slash"
        case .ejectAllDisks: "eject"
        case .toggleHiddenFiles: "eye"
        case .hideOtherApps: "rectangle.on.rectangle.slash"
        case .unhideAllApps: "rectangle.on.rectangle"
        case .quitAllApps: "xmark.rectangle"
        case .restartFrontApp: "arrow.clockwise"
        }
    }

    /// One line for the detail pane.
    public var summary: String {
        switch self {
        case .volumeUp: "Step the output volume up, like the volume key."
        case .volumeDown: "Step the output volume down, like the volume key."
        case .toggleMute: "Mute or unmute the output, like the mute key."
        case .volume0, .volume25, .volume50, .volume75, .volume100: "Set the output volume right away."
        case .toggleMicrophoneMute: "Mute or unmute the default microphone."
        case .playPause: "Play or pause the current track, like the play key."
        case .nextTrack: "Play the next track, like the next key."
        case .previousTrack: "Play the previous track, like the previous key."
        case .toggleAppearance: "Switch macOS between light and dark."
        case .appearanceLight: "Set macOS to the light appearance."
        case .appearanceDark: "Set macOS to the dark appearance."
        case .appearanceAuto: "Let macOS switch appearance automatically."
        case .lockScreen: "Lock this Mac's screen."
        case .sleepDisplays: "Put the displays to sleep now."
        case .sleep: "Put this Mac to sleep now."
        case .openTrash: "Open the Trash in Finder."
        case .emptyTrash: "Delete everything in the Trash for good."
        case .ejectAllDisks: "Eject every ejectable disk and disk image."
        case .toggleHiddenFiles: "Show or hide hidden files in Finder. Finder restarts."
        case .hideOtherApps: "Hide every app except the one in front."
        case .unhideAllApps: "Bring every hidden app back into view."
        case .quitAllApps: "Quit every running app except Finder and Cue."
        case .restartFrontApp: "Quit the app in front and open it again."
        }
    }

    /// Extra search terms, so “dark mode” finds the appearance commands.
    public var keywords: [String] {
        switch self {
        case .toggleMute: ["mute", "silence"]
        case .toggleMicrophoneMute: ["mic mute", "mute mic", "microphone"]
        case .toggleAppearance: ["dark mode", "light mode", "theme"]
        case .appearanceLight: ["light mode", "dark mode off"]
        case .appearanceDark: ["dark mode", "dark mode on"]
        case .appearanceAuto: ["auto dark mode", "automatic appearance"]
        case .toggleHiddenFiles: ["show hidden files", "invisible files", "dotfiles"]
        case .emptyTrash: ["delete trash", "clear trash"]
        default: []
        }
    }

    public var owner: String { "system:\(rawValue)" }

    /// The preset level for the Set Volume commands, as a percentage.
    public var volumePercent: Int? {
        switch self {
        case .volume0: 0
        case .volume25: 25
        case .volume50: 50
        case .volume75: 75
        case .volume100: 100
        default: nil
        }
    }

    public var appearance: AppearanceMode? {
        switch self {
        case .toggleAppearance: .toggle
        case .appearanceLight: .light
        case .appearanceDark: .dark
        case .appearanceAuto: .auto
        default: nil
        }
    }

    /// Destructive commands ask first, with Cancel as the default button.
    public var needsConfirmation: Bool {
        switch self {
        case .emptyTrash, .quitAllApps: true
        default: false
        }
    }

    public var confirmationText: String? {
        switch self {
        case .emptyTrash: "Everything in the Trash is deleted for good. You cannot undo this."
        case .quitAllApps: "Every running app quits except Finder and Cue. Apps with unsaved work may ask to save."
        default: nil
        }
    }

    public var group: String {
        Self.sections.first { $0.commands.contains(self) }?.title ?? "System"
    }
}

public enum AppearanceMode: Sendable {
    case light, dark, auto, toggle

    /// The System Events script for this mode. Auto has none: it is a defaults key.
    public var appleScript: String? {
        switch self {
        case .dark: "tell application \"System Events\" to tell appearance preferences to set dark mode to true"
        case .light: "tell application \"System Events\" to tell appearance preferences to set dark mode to false"
        case .toggle: "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        case .auto: nil
        }
    }
}

public enum AudioLevel {
    /// One media-key step, as macOS moves the volume.
    public static let step = 1.0 / 16

    public static func stepped(_ level: Double, by steps: Double) -> Double {
        min(1, max(0, level + steps * step))
    }

    public static func percent(_ level: Double) -> Int {
        Int((min(1, max(0, level)) * 100).rounded())
    }
}
