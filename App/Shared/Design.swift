import AppKit
import CueKit
import SwiftUI
import UniformTypeIdentifiers

enum IconCache {
    private nonisolated(unsafe) static let files = NSCache<NSString, NSImage>()
    private nonisolated(unsafe) static let types = NSCache<NSString, NSImage>()

    static func file(_ path: String) -> NSImage {
        if let cached = files.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        files.setObject(icon, forKey: path as NSString)
        return icon
    }

    static func type(_ type: UTType) -> NSImage {
        if let cached = types.object(forKey: type.identifier as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(for: type)
        types.setObject(icon, forKey: type.identifier as NSString)
        return icon
    }
}

enum Cue {
    static let claude = Color(red: 0.784, green: 0.392, blue: 0.247)
    static let claudeAccent = adaptive(light: hex(0xC8643F), dark: hex(0xF0A585))
    static let script = Color(red: 0.180, green: 0.545, blue: 0.341)
    static let text = adaptive(light: hex(0x8E8E93), dark: hex(0x636366))
    static let success = adaptive(light: hex(0x2E8B57), dark: hex(0x30D158))
    static let toggle = adaptive(light: hex(0x2E8B57), dark: hex(0x30A46C))
    static let danger = adaptive(light: hex(0xC0362C), dark: hex(0xFF6961))
    static let favorite = adaptive(light: hex(0xD9A400), dark: hex(0xFFD60A))
    static let accent = adaptive(light: hex(0x0A60D0), dark: hex(0x4DA3FF))
    static let link = adaptive(light: hex(0x0060CC), dark: hex(0x4DA3FF))
    static let warning = adaptive(light: hex(0x8A4F00), dark: hex(0xFFB340))
    static let warningFill = adaptive(light: hex(0xFFF6E5), dark: hex(0xFF9F0A, 0.12))
    static let token = adaptive(light: hex(0x8A3D1F), dark: hex(0xF0A585))
    static let tokenFill = adaptive(light: hex(0xF6E7E0), dark: hex(0xC8643F, 0.22))
    static let added = adaptive(light: hex(0xDDF3E4), dark: hex(0x30D158, 0.2))
    static let addedText = adaptive(light: hex(0x14602F), dark: hex(0x7EE2A8))
    static let hairline = Color.primary.opacity(0.08)
    static let card = adaptive(light: hex(0xFFFFFF), dark: hex(0x1C1C1E))
    static let group = adaptive(light: hex(0xFFFFFF), dark: hex(0x2A2A2D))
    static let page = adaptive(light: hex(0xF5F5F7), dark: hex(0x1E1E20))
    static let sidebar = adaptive(light: hex(0xF2F2F5), dark: hex(0x2A2A2D))
    static let well = adaptive(light: hex(0xFAFAFB), dark: hex(0x141416))
    static let wellBar = adaptive(light: hex(0xFFFFFF), dark: hex(0xFFFFFF, 0))
    static let panel = adaptive(light: hex(0xF5F5F7), dark: hex(0x232326))
    static let detail = adaptive(light: hex(0, 0.012), dark: hex(0, 0.12))
    static let fill = adaptive(light: hex(0, 0.06), dark: hex(0xFFFFFF, 0.08))
    static let subtle = adaptive(light: hex(0, 0.05), dark: hex(0xFFFFFF, 0.07))
    static let quiet = adaptive(light: hex(0, 0.04), dark: hex(0xFFFFFF, 0.06))
    static let selection = adaptive(light: hex(0, 0.07), dark: hex(0xFFFFFF, 0.1))
    static let rowSelected = adaptive(light: hex(0x0A60D0), dark: hex(0x0A5FCC))
    static let keyFill = adaptive(light: hex(0, 0.065), dark: hex(0xFFFFFF, 0.1))
    static let keyText = adaptive(light: hex(0x3A3A3C), dark: hex(0xD1D1D6))
    static let input = adaptive(light: hex(0xFFFFFF), dark: hex(0xFFFFFF, 0.07))
    static let control = adaptive(light: hex(0xFFFFFF), dark: hex(0xFFFFFF, 0.04))
    static let controlBorder = adaptive(light: hex(0, 0.12), dark: hex(0xFFFFFF, 0.1))
    static let segment = adaptive(light: hex(0xFFFFFF), dark: hex(0x5A5A5E))
    static let segmentQuiet = adaptive(light: hex(0xFFFFFF), dark: hex(0x48484A))
    static let ink = adaptive(light: hex(0x1D1D1F), dark: hex(0xF2F2F7))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

extension View {
    func bordered(_ fill: Color, radius: CGFloat = 7) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Cue.controlBorder) }
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
        if !needle.isEmpty, let range = result.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) {
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
            .font(.system(size: max(10, size * 0.5), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

struct FileIcon: View {
    var path: String
    var size: CGFloat = 26

    var body: some View {
        Image(nsImage: IconCache.file(path)).resizable().frame(width: size, height: size)
    }
}

struct Key: View {
    var text: String
    var dimmed = false
    var onAccent = false
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 10 : 11, weight: .medium))
            .foregroundStyle(onAccent ? AnyShapeStyle(.white) : dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Cue.keyText))
            .frame(minWidth: 18, minHeight: compact ? 16 : 18)
            .padding(.horizontal, 5)
            .background(onAccent ? Color.white.opacity(0.2) : Cue.keyFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
            .foregroundStyle(selected ? AnyShapeStyle(Cue.card) : AnyShapeStyle(.primary.opacity(0.8)))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(selected ? Cue.ink : Cue.subtle, in: Capsule())
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
        var dot: Color?
    }

    var options: [Option]
    var selection: Value
    var height: CGFloat = 26
    var selectedFill = Cue.segment
    var onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { onSelect(option.value) } label: {
                    HStack(spacing: 6) {
                        if let symbol = option.symbol { Image(systemName: symbol).font(.system(size: 11)) }
                        if let dot = option.dot { StatusDot(color: dot) }
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
                                .fill(selectedFill)
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
        Toggle(label, isOn: $isOn).toggleStyle(.switch).tint(Cue.toggle).labelsHidden().controlSize(.small)
    }
}

struct PopMenu<Value: Hashable>: View {
    var title: String
    var dimmed = false
    @Binding var selection: Value
    var options: [(value: Value, title: String)]

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1).foregroundStyle(dimmed ? .secondary : .primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .bordered(Cue.input)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
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
    var compact = false
    var onChange: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        FlowLayout {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 5) {
                    Text(tag).font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: compact ? 11.5 : 12.5))
                    Button { onChange(tags.filter { $0 != tag }) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(tag)")
                }
                .padding(.horizontal, compact ? 7 : 9)
                .frame(height: compact ? 20 : 24)
                .background(compact ? Cue.keyFill : Cue.fill, in: RoundedRectangle(cornerRadius: compact ? 5 : monospaced ? 6 : 12, style: .continuous))
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(width: 90, height: compact ? 20 : 24)
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
            .background(Cue.group, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .background(Cue.page)
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
