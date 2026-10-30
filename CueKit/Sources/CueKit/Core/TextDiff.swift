import Foundation

public enum TextDiff {
    public struct Run: Equatable, Sendable {
        public var text: String
        public var added: Bool

        public init(_ text: String, added: Bool) {
            self.text = text
            self.added = added
        }
    }

    private static let tokenLimit = 6000

    public static func additions(from original: String, to revised: String) -> [Run] {
        let old = tokens(original), new = tokens(revised)
        guard old.count + new.count <= tokenLimit else { return revised.isEmpty ? [] : [Run(revised, added: false)] }
        var added = Set<Int>()
        for change in new.difference(from: old) {
            if case .insert(let offset, _, _) = change { added.insert(offset) }
        }
        var runs: [Run] = []
        for (index, token) in new.enumerated() {
            let isAdded = added.contains(index) && !token.allSatisfy(\.isWhitespace)
            if let last = runs.indices.last, runs[last].added == isAdded {
                runs[last].text += token
            } else {
                runs.append(Run(token, added: isAdded))
            }
        }
        return runs
    }

    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var kind = 0
        for character in text {
            let next = character.isWhitespace ? 1 : character.isLetter || character.isNumber ? 2 : 3
            if next != kind || next == 3 {
                if !current.isEmpty { result.append(current) }
                current = ""
                kind = next
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
