import AppKit
import CueKit

if CommandLine.arguments.dropFirst().first == ClipboardChild.argument { ClipboardReader.runChild() }

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
