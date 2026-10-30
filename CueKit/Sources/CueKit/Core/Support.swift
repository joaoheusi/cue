import Foundation

public enum Timestamp {
    public static func now() -> String { iso(Date()) }

    public static func iso(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    public static func parse(_ value: String) -> Date? {
        if let date = try? Date(value, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) { return date }
        return try? Date(value, strategy: .iso8601)
    }

    public static func sortable(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d.%03d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, c.nanosecond! / 1_000_000)
    }
}

public enum ShortAge {
    public static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(seconds / 3600)h" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return "\(max(2, calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 2))d"
    }

    public static func until(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        return seconds < 60 ? "\(seconds)s" : "\(Int((Double(seconds) / 60).rounded(.up)))m"
    }
}

public enum SafeFilename {
    public static func make(_ base: String, ext: String, date: Date? = nil) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var name = String(String.UnicodeScalarView(base.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        if name.unicodeScalars.count > 80 {
            name = String(String.UnicodeScalarView(name.unicodeScalars.prefix(80))).trimmingCharacters(in: .whitespaces)
        }
        if name.isEmpty { name = "Cue" }
        if let date {
            let stamp = Timestamp.sortable(date)
            let day = "\(stamp.prefix(4))-\(stamp.dropFirst(4).prefix(2))-\(stamp.dropFirst(6).prefix(2))"
            name += " \(day) \(stamp.dropFirst(9).prefix(6))"
        }
        let cleanExt = ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return cleanExt.isEmpty ? name : "\(name).\(cleanExt)"
    }
}

public enum TextLimits {
    public static func firstInvalidControl(in text: String) -> Int? {
        for (index, scalar) in text.unicodeScalars.enumerated() {
            let v = scalar.value
            if (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D) || v == 0x7F { return index + 1 }
        }
        return nil
    }
}

public enum BoundedFile {
    public static func read(_ url: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else {
            throw CueError("OUTPUT_TOO_LARGE", "The file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)).")
        }
        return data
    }

}
