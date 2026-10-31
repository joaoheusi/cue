import CoreGraphics
import Foundation
import ImageIO
import Vision

public enum ClipboardOCROutcome: Equatable, Sendable {
    case text(String)
    case failed
    case cancelled
}

public enum ClipboardOCR {
    public static let argument = "--clipboard-ocr"
    public static let timeout: TimeInterval = 60
    public static let watchdog: UInt32 = 65
    public static let maxTextBytes = 64 * 1024
    static let maxReplyBytes = 4 * maxTextBytes
    static let tileSize = 2560
    static let tileOverlap = 200

    struct Reply: Codable, Equatable {
        var text: String
    }

    struct Span: Equatable {
        var lower: Int
        var upper: Int
        var coreLower: Int
        var coreUpper: Int
    }

    static func spans(_ total: Int) -> [Span] {
        guard total > tileSize else { return [Span(lower: 0, upper: total, coreLower: 0, coreUpper: total)] }
        let step = tileSize - tileOverlap
        let count = (total - tileOverlap + step - 1) / step
        let lowers = (0..<count).map { min($0 * step, total - tileSize) }
        return lowers.indices.map { index in
            let lower = lowers[index], upper = lower + tileSize
            let coreLower = index == 0 ? 0 : (lower + lowers[index - 1] + tileSize) / 2
            let coreUpper = index == count - 1 ? total : (lowers[index + 1] + upper) / 2
            return Span(lower: lower, upper: upper, coreLower: coreLower, coreUpper: coreUpper)
        }
    }

    public static func recognize(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
        let sideways = orientation.rawValue >= CGImagePropertyOrientation.leftMirrored.rawValue
        let width = sideways ? image.height : image.width, height = sideways ? image.width : image.height
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        var lines: [String] = []
        for row in spans(height).reversed() {
            for column in spans(width) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.automaticallyDetectsLanguage = true
                request.usesLanguageCorrection = false
                let region = CGRect(x: Double(column.lower) / Double(width), y: Double(row.lower) / Double(height),
                                    width: Double(column.upper - column.lower) / Double(width), height: Double(row.upper - row.lower) / Double(height))
                request.regionOfInterest = region
                guard (try? handler.perform([request])) != nil else { return nil }
                for observation in request.results ?? [] {
                    let box = observation.boundingBox
                    let x = (region.minX + box.midX * region.width) * Double(width), y = (region.minY + box.midY * region.height) * Double(height)
                    guard x >= Double(column.coreLower), x < Double(column.coreUpper), y >= Double(row.coreLower), y < Double(row.coreUpper),
                          let line = observation.topCandidates(1).first?.string else { continue }
                    lines.append(line)
                }
            }
        }
        return ClipItem.prefix(lines.joined(separator: "\n"), bytes: maxTextBytes)
    }

    public static func runChild() -> Never {
        alarm(watchdog)
        signal(SIGPIPE, SIG_IGN)
        guard let image = try? FileHandle.standardInput.readToEnd(), let text = recognize(image) else { exit(1) }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Reply(text: text)), (try? FileHandle.standardOutput.write(contentsOf: data)) != nil else { exit(1) }
        exit(0)
    }

    public static func run(executable: URL?, arguments: [String] = [argument], image: Data, timeout: TimeInterval = timeout) async -> ClipboardOCROutcome {
        guard let executable else { return .failed }
        let process = Subprocess(executable: executable, arguments: arguments, input: image, quality: .background)
        guard let output = try? await process.run(timeout: timeout, limit: maxReplyBytes, priority: .utility) else { return .failed }
        if output.stopped { return .cancelled }
        guard output.status == 0, !output.overflow, !output.expired, let reply = try? PropertyListDecoder().decode(Reply.self, from: output.stdout) else { return .failed }
        return .text(reply.text)
    }
}

public struct ClipboardOCRState: Equatable, Sendable {
    public private(set) var runs = 0
    public private(set) var failed = 0
    public private(set) var slowestMilliseconds = 0.0
    private var totalMilliseconds = 0.0

    public init() {}

    public var averageMilliseconds: Double { runs == 0 ? 0 : totalMilliseconds / Double(runs) }

    public mutating func record(_ outcome: ClipboardOCROutcome, milliseconds: Double) {
        guard outcome != .cancelled else { return }
        runs += 1
        if outcome == .failed { failed += 1 }
        totalMilliseconds += milliseconds
        slowestMilliseconds = max(slowestMilliseconds, milliseconds)
    }

    public func diagnostics(pending: Int?) -> [(String, String)] {
        func time(_ milliseconds: Double) -> String { runs == 0 ? "no runs yet" : "\(Int(milliseconds.rounded())) ms" }
        return [
            ("OCR pending", pending.map(String.init) ?? "unknown"),
            ("OCR runs", "\(runs)"),
            ("OCR failed", "\(failed)"),
            ("OCR average", time(averageMilliseconds)),
            ("OCR slowest", time(slowestMilliseconds)),
        ]
    }
}
