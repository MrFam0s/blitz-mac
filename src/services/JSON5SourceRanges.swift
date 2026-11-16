import Foundation

/// Locates values in an already semantically decoded Xcode JSON5 document.
/// Edits use these ranges to retain comments, ordering and unrelated content.
/// Unsupported/duplicate syntax fails before any project file is written.
struct JSON5SourceRanges {
    struct Node {
        var range: Range<String.Index>
        var entries: [String: Node] = [:]
        var elements: [Node] = []
        var members: [String: Range<String.Index>] = [:]
        var followingCommas: [String: Range<String.Index>] = [:]
    }

    private let text: String
    private var index: String.Index

    init(_ text: String) { self.text = text; index = text.startIndex }

    mutating func parseDocument() throws -> Node {
        let node = try parse(depth: 0)
        try skipTrivia()
        guard index == text.endIndex else { throw invalid() }
        return node
    }

    private mutating func parse(depth: Int) throws -> Node {
        guard depth < 256 else { throw invalid() }
        try skipTrivia()
        let start = index
        guard index < text.endIndex else { throw invalid() }
        if text[index] == "{" {
            advance()
            var entries: [String: Node] = [:]
            var members: [String: Range<String.Index>] = [:]
            var followingCommas: [String: Range<String.Index>] = [:]
            try skipTrivia()
            while index < text.endIndex && text[index] != "}" {
                let memberStart = index
                let key = try key()
                guard entries[key] == nil else { throw invalid() }
                try consume(":")
                entries[key] = try parse(depth: depth + 1)
                members[key] = memberStart..<index
                try skipTrivia()
                if index < text.endIndex && text[index] == "," {
                    let commaStart = index
                    advance()
                    followingCommas[key] = commaStart..<index
                    try skipTrivia()
                } else if index >= text.endIndex || text[index] != "}" {
                    throw invalid()
                }
            }
            try consume("}")
            return Node(range: start..<index, entries: entries, members: members, followingCommas: followingCommas)
        }
        if text[index] == "[" {
            advance()
            var elements: [Node] = []
            try skipTrivia()
            while index < text.endIndex && text[index] != "]" {
                elements.append(try parse(depth: depth + 1))
                try skipTrivia()
                if index < text.endIndex && text[index] == "," {
                    advance()
                    try skipTrivia()
                } else if index >= text.endIndex || text[index] != "]" {
                    throw invalid()
                }
            }
            try consume("]")
            return Node(range: start..<index, elements: elements)
        }
        try token()
        return Node(range: start..<index)
    }

    private mutating func key() throws -> String {
        try skipTrivia()
        let start = index
        try token()
        let literal = String(text[start..<index])
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        guard let object = try? decoder.decode([String: Bool].self, from: Data("{\(literal):true}".utf8)),
              object.count == 1, let key = object.keys.first else { throw invalid() }
        return key
    }

    private mutating func token() throws {
        try skipTrivia()
        guard index < text.endIndex else { throw invalid() }
        let start = index
        if text[index] == "\"" || text[index] == "'" {
            let quote = text[index]
            advance()
            while index < text.endIndex {
                let character = text[index]
                advance()
                if character == quote { return }
                if character == "\\" {
                    guard index < text.endIndex else { throw invalid() }
                    advance()
                }
            }
            throw invalid()
        }
        while index < text.endIndex && !text[index].isWhitespace && !"{}[]:,/".contains(text[index]) {
            advance()
        }
        guard start < index else { throw invalid() }
    }

    private mutating func consume(_ character: Character) throws {
        try skipTrivia()
        guard index < text.endIndex && text[index] == character else { throw invalid() }
        advance()
    }

    private mutating func skipTrivia() throws {
        while index < text.endIndex {
            if text[index].isWhitespace { advance(); continue }
            if text[index...].hasPrefix("//") {
                while index < text.endIndex && text[index] != "\n" && text[index] != "\r" { advance() }
            } else if text[index...].hasPrefix("/*") {
                guard let end = text[index...].range(of: "*/") else { throw invalid() }
                index = end.upperBound
            } else { return }
        }
    }

    private mutating func advance() { index = text.index(after: index) }
    private func invalid() -> XcodeProjectIdentityEditor.IdentityError {
        .init(message: L10n.tr("Unsupported or ambiguous Xcode JSON5 syntax. No settings were changed; edit the application target in Xcode."))
    }
}
