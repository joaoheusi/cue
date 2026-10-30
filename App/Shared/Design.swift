import AppKit
import CueKit
import SwiftUI

enum Cue {
    static let claude = Color(red: 0.784, green: 0.392, blue: 0.247)
    static let script = Color(red: 0.180, green: 0.545, blue: 0.341)
    static let text = Color(red: 0.557, green: 0.557, blue: 0.576)
    static let success = script
    static let warning = adaptive(light: NSColor(red: 0.541, green: 0.310, blue: 0, alpha: 1), dark: NSColor(red: 0.98, green: 0.72, blue: 0.36, alpha: 1))
    static let warningFill = adaptive(light: NSColor(red: 1, green: 0.965, blue: 0.898, alpha: 1), dark: NSColor(red: 0.98, green: 0.72, blue: 0.36, alpha: 0.16))
    static let token = adaptive(light: NSColor(red: 0.541, green: 0.239, blue: 0.122, alpha: 1), dark: NSColor(red: 0.96, green: 0.68, blue: 0.56, alpha: 1))
    static let tokenFill = adaptive(light: NSColor(red: 0.965, green: 0.906, blue: 0.878, alpha: 1), dark: NSColor(red: 0.784, green: 0.392, blue: 0.247, alpha: 0.28))
    static let added = adaptive(light: NSColor(red: 0.18, green: 0.545, blue: 0.341, alpha: 0.16), dark: NSColor(red: 0.3, green: 0.75, blue: 0.5, alpha: 0.26))
    static let hairline = Color.primary.opacity(0.08)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let fill = Color.primary.opacity(0.06)
    static let selection = Color.primary.opacity(0.09)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

enum RunsAs: String, CaseIterable {
    case claude, text, script

    var title: String {
        switch self {
        case .claude: "Claude"
        case .text: "Text"
        case .script: "Script"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .text: "text.alignleft"
        case .script: "chevron.right"
        }
    }

    var color: Color {
        switch self {
        case .claude: Cue.claude
        case .text: Cue.text
        case .script: Cue.script
        }
    }
}

extension Action {
    var runsAs: RunsAs { ai == true ? .claude : .text }
}

extension AttributedString {
    static func template(_ text: String) -> AttributedString {
        var result = AttributedString()
        for segment in Template.segments(text) {
            switch segment {
            case .text(let value):
                result += AttributedString(value)
            case .token(let name):
                var token = AttributedString(" \(name) ")
                token.backgroundColor = Cue.tokenFill
                token.foregroundColor = Cue.token
                result += token
            }
        }
        return result
    }

    static func highlighted(_ text: String, matching query: String) -> AttributedString {
        var result = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, let range = result.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].underlineStyle = .single
        }
        return result
    }
}

struct Tile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 26

    init(symbol: String, color: Color, size: CGFloat = 26) {
        self.symbol = symbol
        self.color = color
        self.size = size
    }

    init(_ kind: RunsAs, size: CGFloat = 26) {
        self.init(symbol: kind.symbol, color: kind.color, size: size)
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

struct FileIcon: View {
    var path: String
    var size: CGFloat = 26

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: size, height: size)
    }
}

struct Key: View {
    var text: String
    var dimmed = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(dimmed ? .tertiary : .secondary)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 5)
            .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct SectionLabel: View {
    var text: String

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}

struct Chip: View {
    enum Style { case neutral, claude }
    var text: String
    var style = Style.neutral

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: style == .claude ? .semibold : .medium))
            .foregroundStyle(style == .claude ? AnyShapeStyle(Cue.token) : AnyShapeStyle(.primary.opacity(0.75)))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(style == .claude ? Cue.tokenFill : Cue.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct FilterChip: View {
    var title: String
    var count: Int?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let count { Text("\(count)").opacity(0.7) }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.primary.opacity(0.8)))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.05)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct Segmented<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var symbol: String?
        var key: String?
        var identifier: String?
        var enabled = true
    }

    var options: [Option]
    var selection: Value
    var height: CGFloat = 26
    var onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { onSelect(option.value) } label: {
                    HStack(spacing: 6) {
                        if let symbol = option.symbol { Image(systemName: symbol).font(.system(size: 11)) }
                        Text(option.title)
                        if let key = option.key { Text(key).foregroundStyle(.tertiary).fontWeight(.medium) }
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : option.enabled ? .secondary : .tertiary)
                    .padding(.horizontal, 10)
                    .frame(height: height)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(nsColor: .controlColor))
                                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!option.enabled)
                .accessibilityLabel(option.title)
                .accessibilityIdentifier(option.identifier ?? option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Cue.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

struct SwitchToggle: View {
    @Binding var isOn: Bool
    var label = ""

    var body: some View {
        Toggle(label, isOn: $isOn).toggleStyle(.switch).tint(Cue.success).labelsHidden().controlSize(.small)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> (positions: [CGPoint], size: CGSize) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (positions, CGSize(width: widest, height: y + line))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let positions = rows(subviews, width: bounds.width).positions
        for (view, point) in zip(subviews, positions) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
}

struct TagField: View {
    var tags: [String]
    var placeholder = "Add…"
    var monospaced = false
    var onChange: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        FlowLayout {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 5) {
                    Text(tag).font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                    Button { onChange(tags.filter { $0 != tag }) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(tag)")
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Cue.fill, in: RoundedRectangle(cornerRadius: monospaced ? 6 : 12, style: .continuous))
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(width: 90, height: 24)
                .onSubmit(commit)
        }
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        if !value.isEmpty, !tags.contains(value) { onChange(tags + [value]) }
    }
}

struct CardList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .background(Cue.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cue.hairline) }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct CardDivider: View {
    var body: some View { Rectangle().fill(Cue.hairline).frame(height: 1) }
}

struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content() }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
    }
}

struct SettingsSection<Trailing: View, Content: View>: View {
    var title: String?
    var trailing: () -> Trailing
    var content: () -> Content

    init(_ title: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary.opacity(0.85))
                    Spacer()
                    trailing()
                }
                .padding(.horizontal, 4)
            }
            CardList(content: content)
        }
    }
}

struct SettingsRow<Content: View>: View {
    var title: String
    var note: String?
    var weight = Font.Weight.regular
    var content: () -> Content

    init(_ title: String, note: String? = nil, weight: Font.Weight = .regular, @ViewBuilder content: @escaping () -> Content = { EmptyView() }) {
        self.title = title
        self.note = note
        self.weight = weight
        self.content = content
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).fontWeight(weight)
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }
}

struct PlusMinusBar<Add: View>: View {
    var removeEnabled: Bool
    var remove: () -> Void
    @ViewBuilder var add: () -> Add

    var body: some View {
        HStack(spacing: 0) {
            add().menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 26)
            Rectangle().fill(Cue.hairline).frame(width: 1, height: 16)
            Button(action: remove) { Image(systemName: "minus").frame(width: 26, height: 26).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .disabled(!removeEnabled)
                .accessibilityLabel("Remove")
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(Color.primary.opacity(0.025))
    }
}

struct SettingsNote: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true)
    }
}

enum PanelMenu {
    @MainActor static func show(_ build: (NSMenu) -> Void) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.accessibilityIdentifier() == "command.window" })?.contentView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        build(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - 230, y: view.isFlipped ? view.bounds.maxY - 46 : 46), in: view)
    }
}
