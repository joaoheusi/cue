import AppKit
import CueKit

enum ClipboardReader {
    static var access: ClipboardAccess {
        guard #available(macOS 15.4, *) else { return .unavailable }
        return switch NSPasteboard.general.accessBehavior {
        case .default: .standard
        case .ask: .ask
        case .alwaysAllow: .alwaysAllow
        case .alwaysDeny: .alwaysDeny
        @unknown default: .unavailable
        }
    }

    static func runChild() -> Never {
        alarm(ClipboardChild.watchdog)
        signal(SIGPIPE, SIG_IGN)
        guard let request = ClipboardChild.Request(arguments: Array(CommandLine.arguments.dropFirst())) else { exit(2) }
        let board = NSPasteboard.general
        let reply = ClipboardChild.reply(to: request, source: ClipboardChild.Source(
            changeCount: { board.changeCount }, access: { access }, types: { board.types?.map(\.rawValue) ?? [] },
            text: { board.string(forType: .string) }))
        guard let data = try? reply.encoded(), (try? FileHandle.standardOutput.write(contentsOf: data)) != nil else { exit(1) }
        exit(0)
    }
}
