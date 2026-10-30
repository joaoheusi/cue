import AppKit
import CueKit
import SwiftUI

struct RunView: View {
    @Bindable var run: ActionRun
    let model: PromptsModel
    @State private var inputOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Cue.hairline).frame(height: 1)
            VStack(spacing: 14) {
                if let input = run.input { inputRow(input) }
                output
                if let message = run.message {
                    ErrorBanner(error: CueError("RUN_MESSAGE", message), retryTitle: "Dismiss") {
                        model.closeRun()
                        model.context.closeCommand()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            footer
        }
        .accessibilityIdentifier("run.view")
        .background {
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func cancel() {
        if run.isRunning { return model.stopRun() }
        let closesPanel = run.surface == .palette
        model.closeRun()
        if closesPanel { model.context.closeCommand() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: model.closeRun) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Cue.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back (⌘[)")
            .accessibilityLabel("Back")
            Tile(run.kind)
            Text(run.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            Spacer()
            if run.kind == .claude { status }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(height: CommandMetrics.searchHeight)
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            switch run.phase {
            case .running: Spinner()
            case .finished: StatusDot(color: Cue.success)
            case .stopped: StatusDot(color: Cue.warning)
            case .failed: StatusDot(color: .red)
            }
            Text("Claude")
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(String(format: "%.1fs", run.elapsed)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func inputRow(_ input: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { inputOpen.toggle() } label: {
                HStack(spacing: 10) {
                    Text("Input").fontWeight(.semibold).foregroundStyle(.secondary)
                    Text("\(run.inputName) · \(input.count) chars").foregroundStyle(.secondary)
                    Text(ClipboardSearch.preview(input)).lineLimit(1).truncationMode(.tail).opacity(inputOpen ? 0 : 1)
                    Spacer(minLength: 0)
                    Image(systemName: inputOpen ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if inputOpen {
                ScrollView {
                    Text(input).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: run.isRunning || run.kind == .claude ? "Output" : "Result")
                Spacer()
                if run.canCompare {
                    HStack(spacing: 8) {
                        Text("Show changes")
                        SwitchToggle(isOn: $run.showChanges, label: "Show changes")
                        Key(text: "⌘D")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .background {
                        Button("Show Changes") { run.showChanges.toggle() }
                            .keyboardShortcut("d", modifiers: .command)
                            .opacity(0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        outputText.frame(maxWidth: .infinity, alignment: .leading)
                        if case .failed(let error) = run.phase {
                            Text(error.message).font(.system(size: 12.5)).foregroundStyle(.orange).padding(.top, 8)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                .onChange(of: run.output) {
                    if run.isRunning { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .background(Cue.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cue.hairline) }
        }
        .frame(maxHeight: .infinity)
    }

    private var outputText: some View {
        var text = run.attributedOutput
        if run.isRunning {
            var caret = AttributedString("▍")
            caret.foregroundColor = Cue.claude
            text += caret
        } else if run.output.isEmpty, run.phase == .finished {
            text = AttributedString("No output.")
        }
        return Text(text)
            .font(run.kind == .script ? .system(size: 12.5, design: .monospaced) : .system(size: 15))
            .lineSpacing(4)
            .textSelection(.enabled)
    }

    private var footer: some View {
        CommandFooter {
            if run.kind == .claude, run.surface == .palette {
                Menu {
                    ForEach(ActionRun.Finish.allCases.filter { $0 != .paste || run.target != nil }) { option in
                        Button(run.finishTitle(option)) { run.finish = option }
                    }
                } label: {
                    Text("On finish  ") + Text(run.finishTitle(run.finish)).fontWeight(.semibold)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!run.isRunning)
            } else if run.surface == .library {
                Text(run.input == nil ? "Test run" : "Test run. Your real \(run.inputName) was used.")
            }
        } trailing: {
            if run.isRunning {
                Button(action: model.stopRun) { KeyHint(label: "Stop", keys: "esc", primary: true) }
                    .buttonStyle(.plain)
            }
            if run.surface == .palette, run.target != nil {
                command("Paste now", keys: "↵", primary: !run.isRunning, enabled: run.hasResult, shortcut: .return, modifiers: []) {
                    Task { await model.deliver(run, paste: true) }
                }
                command("Copy", keys: "⌘↵", enabled: run.hasResult, shortcut: .return, modifiers: .command) { copy() }
            } else {
                command("Copy", keys: "↵", primary: !run.isRunning, enabled: run.hasResult, shortcut: .return, modifiers: []) { copy() }
            }
            if run.kind == .claude {
                command("Retry", keys: "⌘R", enabled: true, shortcut: "r", modifiers: .command, action: model.retryRun)
            }
        }
    }

    private func copy() {
        run.generation = nil
        Task { await model.deliver(run, paste: false) }
    }

    private func command(_ label: String, keys: String, primary: Bool = false, enabled: Bool, shortcut: KeyEquivalent, modifiers: EventModifiers,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) { KeyHint(label: label, keys: keys, primary: primary && enabled, dimmed: !enabled) }
            .buttonStyle(.plain)
            .keyboardShortcut(shortcut, modifiers: modifiers)
            .disabled(!enabled)
    }
}

private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Cue.claude, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) * 450))
                .frame(width: 12, height: 12)
        }
    }
}

struct AskView: View {
    let title: String
    let kind: RunsAs
    let questions: [String]
    let back: () -> Void
    let submit: ([String: String]) -> Void
    @State private var answers: [String: String] = [:]
    @FocusState private var focused: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Cue.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Back")
                Tile(kind)
                Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: CommandMetrics.searchHeight)
            Rectangle().fill(Cue.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(questions, id: \.self) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: question)
                        TextField(question, text: Binding(get: { answers[question] ?? "" }, set: { answers[question] = $0 }), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused, equals: question)
                            .onSubmit { submit(answers) }
                    }
                }
                Spacer()
            }
            .padding(20)
            CommandFooter { EmptyView() } trailing: { KeyHint(label: "Continue", keys: "↵", primary: true) }
        }
        .onAppear { DispatchQueue.main.async { focused = questions.first } }
    }
}
