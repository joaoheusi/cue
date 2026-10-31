import AppKit
import CueKit
import SwiftUI

@MainActor @Observable final class ActionRun: Identifiable {
    enum Phase: Equatable {
        case running, finished, stopped
        case failed(CueError)
    }

    enum Finish: String, CaseIterable, Identifiable {
        case paste, copy, keep
        var id: String { rawValue }
    }

    enum Surface { case palette, library }

    let id = UUID()
    let title: String
    let kind: RunsAs
    let surface: Surface
    let prompt: String
    let input: String?
    let inputName: String
    let action: Action?
    let invocation: Invocation
    let target: PasteTarget?
    let targetName: String?
    var generation: Int?
    var output = ""
    var phase = Phase.running
    var finish: Finish
    var showChanges = true
    var started = Date()
    var ended: Date?
    var message: String?
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String, kind: RunsAs, surface: Surface, prompt: String = "", input: String? = nil, inputName: String = "clipboard", action: Action? = nil,
         invocation: Invocation, target: PasteTarget? = nil, targetName: String? = nil, generation: Int? = nil, finish: Finish) {
        self.title = title
        self.kind = kind
        self.surface = surface
        self.prompt = prompt
        self.input = input
        self.inputName = inputName
        self.action = action
        self.invocation = invocation
        self.target = target
        self.targetName = targetName
        self.generation = generation
        self.finish = finish
    }

    var isRunning: Bool { phase == .running }
    var hasResult: Bool { !isRunning && !output.isEmpty }
    var canCompare: Bool { kind == .claude && input != nil }
    var elapsed: Double { (ended ?? Date()).timeIntervalSince(started) }

    func finishTitle(_ finish: Finish) -> String {
        switch finish {
        case .paste: "Paste into \(targetName ?? "front app")"
        case .copy: "Copy"
        case .keep: "Keep open"
        }
    }

    var attributedOutput: AttributedString {
        guard canCompare, showChanges, let input else { return AttributedString(output) }
        var text = AttributedString()
        for run in TextDiff.additions(from: input, to: output) {
            var piece = AttributedString(run.text)
            if run.added {
                piece.backgroundColor = Cue.added
                piece.foregroundColor = Cue.addedText
            }
            text += piece
        }
        return text
    }

    var displayOutput: AttributedString {
        var text = attributedOutput
        if isRunning {
            var caret = AttributedString("▍")
            caret.foregroundColor = Cue.claudeAccent
            text += caret
        } else if output.isEmpty, phase == .finished {
            text = AttributedString("No output.")
        }
        return text
    }
}
