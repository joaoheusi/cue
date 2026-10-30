import CoreGraphics

public enum WindowCommand: String, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case maximize, center, nextDisplay, restore

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left Quarter"
        case .topRight: "Top Right Quarter"
        case .bottomLeft: "Bottom Left Quarter"
        case .bottomRight: "Bottom Right Quarter"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        case .maximize: "Maximize"
        case .center: "Center"
        case .nextDisplay: "Next Display"
        case .restore: "Restore"
        }
    }

    public var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .leftThird, .centerThird, .rightThird: "rectangle.split.3x1"
        case .maximize: "rectangle.inset.filled"
        case .center: "rectangle.center.inset.filled"
        case .nextDisplay: "display.2"
        case .restore: "arrow.uturn.backward"
        }
    }

    public var owner: String { "window:\(rawValue)" }
}

public enum WindowLayout {
    public static func frame(_ command: WindowCommand, window: CGRect, area: CGRect) -> CGRect? {
        func part(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: (area.minX + area.width * x).rounded(), y: (area.minY + area.height * y).rounded(),
                   width: (area.width * width).rounded(), height: (area.height * height).rounded())
        }
        switch command {
        case .leftHalf: return part(0, 0, 0.5, 1)
        case .rightHalf: return part(0.5, 0, 0.5, 1)
        case .topHalf: return part(0, 0, 1, 0.5)
        case .bottomHalf: return part(0, 0.5, 1, 0.5)
        case .topLeft: return part(0, 0, 0.5, 0.5)
        case .topRight: return part(0.5, 0, 0.5, 0.5)
        case .bottomLeft: return part(0, 0.5, 0.5, 0.5)
        case .bottomRight: return part(0.5, 0.5, 0.5, 0.5)
        case .leftThird: return part(0, 0, 1.0 / 3, 1)
        case .centerThird: return part(1.0 / 3, 0, 1.0 / 3, 1)
        case .rightThird: return part(2.0 / 3, 0, 1.0 / 3, 1)
        case .maximize: return area
        case .center:
            let size = CGSize(width: min(window.width, area.width), height: min(window.height, area.height))
            return CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        case .nextDisplay, .restore: return nil
        }
    }

    public static func moved(_ window: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let size = CGSize(width: min(window.width, to.width), height: min(window.height, to.height))
        let x = to.minX + (window.minX - from.minX) / max(from.width - window.width, 1) * (to.width - size.width)
        let y = to.minY + (window.minY - from.minY) / max(from.height - window.height, 1) * (to.height - size.height)
        return CGRect(x: min(max(x, to.minX), to.maxX - size.width).rounded(), y: min(max(y, to.minY), to.maxY - size.height).rounded(),
                      width: size.width, height: size.height)
    }

    public static func area(of window: CGRect, in areas: [CGRect]) -> Int? {
        let overlap = areas.indices.max { a, b in
            let first = areas[a].intersection(window), second = areas[b].intersection(window)
            return first.width * first.height < second.width * second.height
        }
        guard let overlap else { return nil }
        return areas[overlap].intersects(window) ? overlap : areas.indices.min { distance(window, areas[$0]) < distance(window, areas[$1]) }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
}
