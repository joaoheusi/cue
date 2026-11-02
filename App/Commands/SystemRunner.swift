import AppKit
import CoreAudio
import CueKit

@MainActor final class SystemRunner {
    static let mediaReason = "To send the play, pause, and track keys, Cue posts the same key events as your keyboard."
    private static let finderID = "com.apple.finder"

    private let canPostEvents: @MainActor () -> Bool
    private var savedMicLevel: Float?

    init(canPostEvents: @escaping @MainActor () -> Bool) {
        self.canPostEvents = canPostEvents
    }

    /// Runs the command and returns a line worth telling the user, or nil when the effect is plain to see.
    func perform(_ command: SystemCommand, front: NSRunningApplication?) async throws(CueError) -> String? {
        switch command {
        case .volumeUp: return try stepVolume(by: 1, key: 0)
        case .volumeDown: return try stepVolume(by: -1, key: 1)
        case .toggleMute: return try toggleMute()
        case .volume0, .volume25, .volume50, .volume75, .volume100:
            return try setVolume(percent: command.volumePercent ?? 0)
        case .toggleMicrophoneMute: return try toggleMicrophone()
        case .playPause: try mediaKey(16, command)
        case .nextTrack: try mediaKey(17, command)
        case .previousTrack: try mediaKey(18, command)
        case .toggleAppearance, .appearanceLight, .appearanceDark, .appearanceAuto:
            try await setAppearance(command.appearance ?? .toggle)
        case .lockScreen: try lockScreen()
        case .sleepDisplays: try await tool("/usr/bin/pmset", ["displaysleepnow"], "Cue could not put the displays to sleep.")
        case .sleep: try await appleScript("tell application \"System Events\" to sleep")
        case .openTrash: try openTrash()
        case .emptyTrash: return try await emptyTrash()
        case .ejectAllDisks: return try ejectAllDisks()
        case .toggleHiddenFiles: return try await toggleHiddenFiles()
        case .hideOtherApps: hideOtherApps(front: front)
        case .unhideAllApps: unhideAllApps()
        case .quitAllApps: return quitAllApps()
        case .restartFrontApp: try await restartFrontApp(front: front)
        }
        return nil
    }

    // MARK: Audio

    private func stepVolume(by steps: Double, key: Int) throws(CueError) -> String? {
        if canPostEvents() {
            postMediaKey(key)
            return nil
        }
        let device = try Self.outputDevice()
        guard let current = Self.volume(of: device, scope: kAudioObjectPropertyScopeOutput) else { throw Self.unsupportedVolume }
        let next = Float(AudioLevel.stepped(Double(current), by: steps))
        guard Self.setVolume(next, of: device, scope: kAudioObjectPropertyScopeOutput) else { throw Self.unsupportedVolume }
        return "Volume \(AudioLevel.percent(Double(next)))%."
    }

    private func toggleMute() throws(CueError) -> String? {
        if canPostEvents() {
            postMediaKey(7)
            return nil
        }
        let device = try Self.outputDevice()
        guard let muted = Self.mute(of: device, scope: kAudioObjectPropertyScopeOutput),
              Self.setMute(!muted, of: device, scope: kAudioObjectPropertyScopeOutput) else { throw Self.unsupportedVolume }
        return muted ? "Sound on." : "Muted."
    }

    private func setVolume(percent: Int) throws(CueError) -> String {
        let device = try Self.outputDevice()
        guard Self.setVolume(Float(percent) / 100, of: device, scope: kAudioObjectPropertyScopeOutput) else { throw Self.unsupportedVolume }
        if percent > 0, Self.mute(of: device, scope: kAudioObjectPropertyScopeOutput) == true {
            _ = Self.setMute(false, of: device, scope: kAudioObjectPropertyScopeOutput)
        }
        return "Volume \(percent)%."
    }

    private func toggleMicrophone() throws(CueError) -> String {
        let device = try Self.inputDevice()
        let scope = kAudioObjectPropertyScopeInput
        if let muted = Self.mute(of: device, scope: scope), Self.setMute(!muted, of: device, scope: scope) {
            return muted ? "Microphone unmuted." : "Microphone muted."
        }
        // Some microphones have no mute switch. Turn the input level to zero and keep the old level to restore.
        if let saved = savedMicLevel {
            guard Self.setVolume(saved, of: device, scope: scope) else { throw Self.unsupportedMic }
            savedMicLevel = nil
            return "Microphone unmuted."
        }
        guard let current = Self.volume(of: device, scope: scope) else { throw Self.unsupportedMic }
        if current <= 0 {
            guard Self.setVolume(0.5, of: device, scope: scope) else { throw Self.unsupportedMic }
            return "Microphone unmuted."
        }
        guard Self.setVolume(0, of: device, scope: scope) else { throw Self.unsupportedMic }
        savedMicLevel = current
        return "Microphone muted."
    }

    private static let unsupportedVolume = CueError("SYSTEM_UNSUPPORTED", "This audio device does not let apps change its volume.")
    private static let unsupportedMic = CueError("SYSTEM_UNSUPPORTED", "This microphone does not let apps mute it.")

    private static func outputDevice() throws(CueError) -> AudioDeviceID {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else {
            throw CueError("SYSTEM_NO_DEVICE", "There is no sound output device.")
        }
        return device
    }

    private static func inputDevice() throws(CueError) -> AudioDeviceID {
        guard let device = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else {
            throw CueError("SYSTEM_NO_DEVICE", "There is no microphone.")
        }
        return device
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private static func volume(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Float32? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return value }
        }
        return nil
    }

    private static func setVolume(_ value: Float32, of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        func set(_ element: AudioObjectPropertyElement) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: element)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
            var level = value
            return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level) == noErr
        }
        if set(kAudioObjectPropertyElementMain) { return true }
        // Devices without a master control take the level per channel.
        let first = set(1), second = set(2)
        return first || second
    }

    private static func mute(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMute(_ muted: Bool, of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    // MARK: Media keys

    private func mediaKey(_ key: Int, _ command: SystemCommand) throws(CueError) {
        guard canPostEvents() else { throw CueError("PERMISSION_REQUIRED", "Cue needs Accessibility to send media keys.") }
        postMediaKey(key)
    }

    /// Posts a keyboard media key, so macOS shows its own HUD and uses its own step size.
    private func postMediaKey(_ keyType: Int) {
        for down in [true, false] {
            let data = (keyType << 16) | ((down ? 0xA : 0xB) << 8)
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Appearance and session

    private func setAppearance(_ mode: AppearanceMode) async throws(CueError) {
        if let script = mode.appleScript {
            try await appleScript(script)
            return
        }
        CFPreferencesSetValue("AppleInterfaceStyleSwitchesAutomatically" as CFString, kCFBooleanTrue,
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw CueError("SYSTEM_FAILED", "Cue could not change the appearance.")
        }
    }

    private func lockScreen() throws(CueError) {
        // There is no public lock API. If the login framework call is missing or fails, say so.
        // Sleeping the display instead would leave the session open on Macs that delay the password.
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            typealias Lock = @convention(c) () -> Int32
            if unsafeBitCast(symbol, to: Lock.self)() == 0 { return }
        }
        throw CueError("SYSTEM_FAILED", "Cue could not lock the screen. Press Control-Command-Q to lock it.")
    }

    // MARK: Files

    private var trashFolders: [URL] {
        let manager = FileManager.default
        var folders = [manager.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)]
        let volumes = manager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path != "/" {
            folders.append(volume.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true))
        }
        return folders
    }

    private func openTrash() throws(CueError) {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        guard NSWorkspace.shared.open(trash) else { throw CueError("SYSTEM_FAILED", "Cue could not open the Trash.") }
    }

    private func emptyTrash() async throws(CueError) -> String {
        let folders = trashFolders
        let result = await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            var removed = 0, failed = 0, unreadable = 0
            for folder in folders {
                // A volume with no Trash folder is normal. A folder Cue cannot read is not.
                guard manager.fileExists(atPath: folder.path) else { continue }
                let items: [URL]
                do {
                    items = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                } catch {
                    unreadable += 1
                    continue
                }
                for item in items {
                    do {
                        try manager.removeItem(at: item)
                        removed += 1
                    } catch {
                        failed += 1
                    }
                }
            }
            return (removed, failed, unreadable)
        }.value
        if result.2 > 0 {
            let lead = result.0 == 0 ? "Cue could not read the Trash, so nothing was deleted." : "Cue emptied part of the Trash, but could not read every Trash folder."
            throw CueError("SYSTEM_FAILED", "\(lead) macOS may be blocking access. Check Privacy & Security.")
        }
        if result.1 > 0 {
            let lead = result.0 == 0 ? "Cue could not empty the Trash." : "Cue emptied part of the Trash."
            throw CueError("SYSTEM_FAILED", "\(lead) \(result.1) item\(result.1 == 1 ? "" : "s") could not be deleted. It may be in use or locked.")
        }
        return result.0 == 0 ? "The Trash is already empty." : "Trash emptied."
    }

    private func ejectAllDisks() throws(CueError) -> String {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let ejectable = volumes.filter { (try? $0.resourceValues(forKeys: Set(keys)).volumeIsEjectable) == true }
        var ejected = 0, failed = 0
        for volume in ejectable {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                ejected += 1
            } catch {
                failed += 1
            }
        }
        if ejected == 0, failed > 0 {
            throw CueError("SYSTEM_FAILED", "No disk could be ejected. A disk may be in use.")
        }
        if ejectable.isEmpty { return "There are no disks to eject." }
        return failed == 0 ? "Ejected \(ejected) disk\(ejected == 1 ? "" : "s")." : "Ejected \(ejected) disk\(ejected == 1 ? "" : "s"). \(failed) could not be ejected."
    }

    private func toggleHiddenFiles() async throws(CueError) -> String {
        let finder = "com.apple.finder" as CFString
        let shown = (CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, finder) as? NSNumber)?.boolValue ?? false
        CFPreferencesSetAppValue("AppleShowAllFiles" as CFString, shown ? kCFBooleanFalse : kCFBooleanTrue, finder)
        guard CFPreferencesAppSynchronize(finder) else {
            throw CueError("SYSTEM_FAILED", "Cue could not change the Finder setting.")
        }
        try? await tool("/usr/bin/killall", ["Finder"], "Finder did not restart.")
        return shown ? "Hidden files are now hidden in Finder." : "Hidden files now show in Finder."
    }

    // MARK: Apps

    private var regularApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated && $0 != .current }
    }

    private func hideOtherApps(front: NSRunningApplication?) {
        let keep = front ?? NSWorkspace.shared.frontmostApplication
        for app in regularApps where app != keep && !app.isHidden { app.hide() }
    }

    private func unhideAllApps() {
        for app in regularApps where app.isHidden { app.unhide() }
    }

    private func quitAllApps() -> String {
        let targets = regularApps.filter { $0.bundleIdentifier != Self.finderID }
        var quit = 0
        for app in targets where app.terminate() { quit += 1 }
        return quit == 0 ? "No other apps are running." : "Quitting \(quit) app\(quit == 1 ? "" : "s")."
    }

    private func restartFrontApp(front: NSRunningApplication?) async throws(CueError) {
        guard let app = front ?? NSWorkspace.shared.frontmostApplication, app != .current, !app.isTerminated else {
            throw CueError("SYSTEM_NO_APP", "There is no front app to restart.")
        }
        guard app.bundleIdentifier != Self.finderID else {
            throw CueError("SYSTEM_NO_APP", "Cue does not restart Finder. Use Force Quit to relaunch it.")
        }
        let name = app.localizedName ?? "The front app"
        guard let url = app.bundleURL ?? app.bundleIdentifier.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) else {
            throw CueError("SYSTEM_NO_APP", "Cue cannot find \(name) to open it again, so it did not quit it.")
        }
        guard app.terminate() else {
            throw CueError("SYSTEM_FAILED", "\(name) did not quit, so Cue did not reopen it.")
        }
        for _ in 0 ..< 50 where !app.isTerminated {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard app.isTerminated else {
            throw CueError("SYSTEM_FAILED", "\(name) is still running, so Cue did not reopen it. It may be waiting for you to save.")
        }
        do {
            try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw CueError("SYSTEM_FAILED", "\(name) quit, but Cue could not open it again.")
        }
    }

    // MARK: Tools

    private func appleScript(_ script: String) async throws(CueError) {
        try await tool("/usr/bin/osascript", ["-e", script], "Cue could not run this system command. macOS may need Automation access for Cue in Privacy & Security.")
    }

    private func tool(_ path: String, _ arguments: [String], _ failure: String) async throws(CueError) {
        let output: Subprocess.Output
        do {
            output = try await Subprocess(executable: URL(fileURLWithPath: path), arguments: arguments)
                .run(timeout: 10, limit: 4096, priority: .userInitiated)
        } catch {
            throw CueError("SYSTEM_FAILED", failure)
        }
        guard !output.expired, output.status == 0 else { throw CueError("SYSTEM_FAILED", failure) }
    }
}
