import CoreGraphics

// Raw values are saved as shortcut owners. Keep them when renaming a command.
public enum WindowCommand: String, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf, centerHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, centerTwoThirds, rightTwoThirds
    case maximize, almostMaximize, maximizeHeight, larger, smaller, center, restore
    case nextDisplay, previousDisplay
    case moveLeft, moveRight, moveUp, moveDown
    case firstFourth, secondFourth, thirdFourth, lastFourth, firstThreeFourths, centerThreeFourths, lastThreeFourths
    case topLeftSixth, topCenterSixth, topRightSixth, bottomLeftSixth, bottomCenterSixth, bottomRightSixth

    /// Sections with a title open as a submenu.
    public static let menuSections: [(title: String?, commands: [WindowCommand])] = [
        (nil, [.leftHalf, .rightHalf, .centerHalf, .topHalf, .bottomHalf]),
        (nil, [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        (nil, [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .centerTwoThirds, .rightTwoThirds]),
        (nil, [.maximize, .almostMaximize, .maximizeHeight, .larger, .smaller, .center, .restore]),
        (nil, [.nextDisplay, .previousDisplay]),
        ("Move to Edge", [.moveLeft, .moveRight, .moveUp, .moveDown]),
        ("Fourths", [.firstFourth, .secondFourth, .thirdFourth, .lastFourth, .firstThreeFourths, .centerThreeFourths, .lastThreeFourths]),
        ("Sixths", [.topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth]),
    ]

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .centerHalf: "Center Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .leftThird: "First Third"
        case .centerThird: "Center Third"
        case .rightThird: "Last Third"
        case .leftTwoThirds: "First Two Thirds"
        case .centerTwoThirds: "Center Two Thirds"
        case .rightTwoThirds: "Last Two Thirds"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .maximizeHeight: "Maximize Height"
        case .larger: "Larger"
        case .smaller: "Smaller"
        case .center: "Center"
        case .restore: "Restore"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        case .moveLeft: "Move Left"
        case .moveRight: "Move Right"
        case .moveUp: "Move Up"
        case .moveDown: "Move Down"
        case .firstFourth: "First Fourth"
        case .secondFourth: "Second Fourth"
        case .thirdFourth: "Third Fourth"
        case .lastFourth: "Last Fourth"
        case .firstThreeFourths: "First Three Fourths"
        case .centerThreeFourths: "Center Three Fourths"
        case .lastThreeFourths: "Last Three Fourths"
        case .topLeftSixth: "Top Left Sixth"
        case .topCenterSixth: "Top Center Sixth"
        case .topRightSixth: "Top Right Sixth"
        case .bottomLeftSixth: "Bottom Left Sixth"
        case .bottomCenterSixth: "Bottom Center Sixth"
        case .bottomRightSixth: "Bottom Right Sixth"
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
        case .centerHalf, .leftThird, .centerThird, .rightThird, .leftTwoThirds, .centerTwoThirds, .rightTwoThirds,
             .firstFourth, .secondFourth, .thirdFourth, .lastFourth, .firstThreeFourths, .centerThreeFourths, .lastThreeFourths:
            "rectangle.split.3x1"
        case .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth: "rectangle.split.2x2"
        case .maximize, .almostMaximize: "rectangle.inset.filled"
        case .maximizeHeight: "arrow.up.and.down"
        case .larger: "plus.rectangle"
        case .smaller: "minus.rectangle"
        case .center: "rectangle.center.inset.filled"
        case .nextDisplay, .previousDisplay: "display.2"
        case .restore: "arrow.uturn.backward"
        case .moveLeft: "arrow.left.to.line"
        case .moveRight: "arrow.right.to.line"
        case .moveUp: "arrow.up.to.line"
        case .moveDown: "arrow.down.to.line"
        }
    }

    public var owner: String { "window:\(rawValue)" }

    /// The shortcut this command has in Rectangle.
    public var rectangleShortcut: Shortcut? {
        let key: String
        switch self {
        case .leftHalf: key = "ArrowLeft"
        case .rightHalf: key = "ArrowRight"
        case .topHalf: key = "ArrowUp"
        case .bottomHalf: key = "ArrowDown"
        case .topLeft: key = "U"
        case .topRight: key = "I"
        case .bottomLeft: key = "J"
        case .bottomRight: key = "K"
        case .leftThird: key = "D"
        case .centerThird: key = "F"
        case .rightThird: key = "R"
        case .leftTwoThirds: key = "E"
        case .rightTwoThirds: key = "T"
        case .maximize: key = "Enter"
        case .larger: key = "Equal"
        case .smaller: key = "Minus"
        case .center: key = "C"
        case .restore: key = "Backspace"
        case .maximizeHeight: return Shortcut(key: "ArrowUp", control: true, option: true, shift: true)
        case .nextDisplay: return Shortcut(key: "ArrowRight", command: true, control: true, option: true)
        case .previousDisplay: return Shortcut(key: "ArrowLeft", command: true, control: true, option: true)
        default: return nil
        }
        return Shortcut(key: key, control: true, option: true)
    }

    /// Where a repeat of this command goes: the opposite side of the neighboring display.
    public var repeatsAcrossDisplays: (command: WindowCommand, step: Int)? {
        switch self {
        case .leftHalf: (.rightHalf, -1)
        case .rightHalf: (.leftHalf, 1)
        case .moveLeft: (.moveRight, -1)
        case .moveRight: (.moveLeft, 1)
        default: nil
        }
    }
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
        case .centerHalf: return part(0.25, 0, 0.5, 1)
        case .topHalf: return part(0, 0, 1, 0.5)
        case .bottomHalf: return part(0, 0.5, 1, 0.5)
        case .topLeft: return part(0, 0, 0.5, 0.5)
        case .topRight: return part(0.5, 0, 0.5, 0.5)
        case .bottomLeft: return part(0, 0.5, 0.5, 0.5)
        case .bottomRight: return part(0.5, 0.5, 0.5, 0.5)
        case .leftThird: return part(0, 0, 1.0 / 3, 1)
        case .centerThird: return part(1.0 / 3, 0, 1.0 / 3, 1)
        case .rightThird: return part(2.0 / 3, 0, 1.0 / 3, 1)
        case .leftTwoThirds: return part(0, 0, 2.0 / 3, 1)
        case .centerTwoThirds: return part(1.0 / 6, 0, 2.0 / 3, 1)
        case .rightTwoThirds: return part(1.0 / 3, 0, 2.0 / 3, 1)
        case .firstFourth: return part(0, 0, 0.25, 1)
        case .secondFourth: return part(0.25, 0, 0.25, 1)
        case .thirdFourth: return part(0.5, 0, 0.25, 1)
        case .lastFourth: return part(0.75, 0, 0.25, 1)
        case .firstThreeFourths: return part(0, 0, 0.75, 1)
        case .centerThreeFourths: return part(0.125, 0, 0.75, 1)
        case .lastThreeFourths: return part(0.25, 0, 0.75, 1)
        case .topLeftSixth: return part(0, 0, 1.0 / 3, 0.5)
        case .topCenterSixth: return part(1.0 / 3, 0, 1.0 / 3, 0.5)
        case .topRightSixth: return part(2.0 / 3, 0, 1.0 / 3, 0.5)
        case .bottomLeftSixth: return part(0, 0.5, 1.0 / 3, 0.5)
        case .bottomCenterSixth: return part(1.0 / 3, 0.5, 1.0 / 3, 0.5)
        case .bottomRightSixth: return part(2.0 / 3, 0.5, 1.0 / 3, 0.5)
        case .maximize: return area
        case .almostMaximize: return part(0.05, 0.05, 0.9, 0.9)
        case .maximizeHeight: return CGRect(x: window.minX, y: area.minY, width: window.width, height: area.height)
        case .larger: return resized(window, by: sizeStep, area: area)
        case .smaller: return resized(window, by: -sizeStep, area: area)
        case .center:
            let size = CGSize(width: min(window.width, area.width), height: min(window.height, area.height))
            return CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        case .moveLeft, .moveRight:
            let size = CGSize(width: min(window.width, area.width), height: min(window.height, area.height))
            return CGRect(x: command == .moveLeft ? area.minX : area.maxX - size.width, y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        case .moveUp, .moveDown:
            let size = CGSize(width: min(window.width, area.width), height: min(window.height, area.height))
            return CGRect(x: (area.midX - size.width / 2).rounded(), y: command == .moveUp ? area.minY : area.maxY - size.height, width: size.width, height: size.height)
        case .nextDisplay, .previousDisplay, .restore: return nil
        }
    }

    private static let sizeStep: CGFloat = 30
    private static let edgeTolerance: CGFloat = 5
    private static let minimumFraction: CGFloat = 0.25

    /// Keeps edges that touch the screen where they are, so a snapped window stays snapped.
    private static func resized(_ window: CGRect, by offset: CGFloat, area: CGRect) -> CGRect {
        func touches(_ start: CGFloat, _ end: CGFloat, _ low: CGFloat, _ high: CGFloat) -> (low: Bool, high: Bool) {
            (abs(start - low) <= edgeTolerance, abs(end - high) <= edgeTolerance)
        }
        let horizontal = touches(window.minX, window.maxX, area.minX, area.maxX)
        let vertical = touches(window.minY, window.maxY, area.minY, area.maxY)
        let filled = horizontal.low && horizontal.high && vertical.low && vertical.high
        func axis(_ start: CGFloat, _ length: CGFloat, _ low: CGFloat, _ high: CGFloat, _ edges: (low: Bool, high: Bool)) -> (start: CGFloat, length: CGFloat) {
            if edges.low && edges.high && !(filled && offset < 0) { return (low, high - low) }
            let size = min(length + offset, high - low)
            let origin = edges.low && !edges.high ? low : edges.high && !edges.low ? high - size : start - (size - length) / 2
            return (min(max(origin, low), high - size).rounded(), size)
        }
        let x = axis(window.minX, window.width, area.minX, area.maxX, horizontal)
        let y = axis(window.minY, window.height, area.minY, area.maxY, vertical)
        if offset < 0, x.length < area.width * minimumFraction || y.length < area.height * minimumFraction { return window }
        return CGRect(x: x.start, y: y.start, width: x.length, height: y.length)
    }

    public static func moved(_ window: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let size = CGSize(width: min(window.width, to.width), height: min(window.height, to.height))
        let x = to.minX + (window.minX - from.minX) / max(from.width - window.width, 1) * (to.width - size.width)
        let y = to.minY + (window.minY - from.minY) / max(from.height - window.height, 1) * (to.height - size.height)
        return CGRect(x: min(max(x, to.minX), to.maxX - size.width).rounded(), y: min(max(y, to.minY), to.maxY - size.height).rounded(),
                      width: size.width, height: size.height)
    }

    /// Fixed-size windows reject the size, and some apps report an error after applying a change.
    public static func accepted(_ target: CGRect, from current: CGRect, result: CGRect?, placed: Bool, sized: Bool) -> Bool {
        (placed && target.origin != current.origin) || (sized && target.size != current.size) || (result ?? current) != current
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
