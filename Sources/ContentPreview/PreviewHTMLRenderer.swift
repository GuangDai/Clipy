/// Offline HTML text extraction for the history pane (REVIEW §4.9).
/// This consumes an immutable byte value, never a URL or a document loader.
/// Tags only supply text separation; attributes never become capabilities.
import Foundation

internal enum PreviewHTMLRenderer {
    internal static func render(
        _ bytes: Data,
        maximumInputBytes: Int,
        maximumOutputBytes: Int
    ) -> PreviewOutcome {
        guard bytes.count <= maximumInputBytes, maximumOutputBytes > 0 else {
            return .failed(.resourceLimit)
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard let source = decode(bytes) else { return .failed(.malformedRepresentation) }
        do {
            var parser = Parser(source, maximumOutputBytes: maximumOutputBytes)
            return .content(.text(try parser.render()))
        } catch {
            return .failed(.cancelled)
        }
    }

    private static func decode(_ bytes: Data) -> String? {
        let littleEndian = bytes.starts(with: [0xFF, 0xFE])
        if littleEndian || bytes.starts(with: [0xFE, 0xFF]) {
            guard bytes.count.isMultiple(of: 2) else { return nil }
            // Consume exactly one encoding signature, then decode code units
            // in that fixed byte order. A second FEFF/FFFE is content, not a
            // fresh signature for Foundation to consume or use to swap bytes.
            var units: [UInt16] = []
            units.reserveCapacity((bytes.count - 2) / 2)
            var iterator = bytes.dropFirst(2).makeIterator()
            while let first = iterator.next(), let second = iterator.next() {
                units.append(littleEndian
                    ? UInt16(first) | UInt16(second) << 8
                    : UInt16(first) << 8 | UInt16(second))
            }
            return String(validating: units, as: UTF16.self)
        }
        let payload = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes.dropFirst(3) : bytes[...]
        return String(validating: payload, as: UTF8.self)
    }

    private struct Parser {
        let scalars: String.UnicodeScalarView
        var index: String.Index
        let maximumOutputBytes: Int
        var output = ""
        var outputBytes = 0
        var consumed = 0
        var outputScalars = 0
        var truncated = false
        var pendingSeparator = ""
        var preDepth = 0
        var headDepth = 0
        var templateDepth = 0
        var rawTextTag: String?
        var isSuppressed: Bool { headDepth > 0 || templateDepth > 0 }

        init(_ source: String, maximumOutputBytes: Int) {
            scalars = source.unicodeScalars
            index = scalars.startIndex
            self.maximumOutputBytes = maximumOutputBytes
        }

        mutating func render() throws -> PreviewText {
            while index != scalars.endIndex, !truncated {
                let scalar = scalars[index]
                if scalar == "<" {
                    let start = index
                    try advance()
                    if let rawTextTag {
                        // Raw script/style text has no ordinary tags or
                        // comments. Only its own closing tag ends the skip.
                        if startsRawClosingTag(rawTextTag),
                           let tag = try consumeTag() { handle(tag) }
                        continue
                    }
                    if try consumeComment() { continue }
                    if let tag = try consumeTag() {
                        handle(tag)
                        continue
                    }
                    // A literal comparison such as `2 < 3` stays text. A
                    // recognized but incomplete tag is consumed to EOF.
                    index = scalars.index(after: start)
                    if rawTextTag == nil, !isSuppressed { append("<") }
                } else if rawTextTag != nil || isSuppressed {
                    try advance()
                } else if scalar == "&" {
                    try advance()
                    if let entity = try consumeEntity() {
                        for decoded in entity.unicodeScalars { append(decoded) }
                    } else {
                        append("&")
                    }
                } else {
                    try advance()
                    append(scalar)
                }
            }
            try Task.checkCancellation()
            let end = output.index(
                output.startIndex, offsetBy: PreviewText.maximumCharacters,
                limitedBy: output.endIndex
            ) ?? output.endIndex
            return PreviewText(
                text: String(output[..<end]),
                wasTruncated: truncated || end != output.endIndex
            )
        }

        mutating func advance() throws {
            index = scalars.index(after: index)
            consumed += 1
            if consumed.isMultiple(of: 4_096) { try Task.checkCancellation() }
        }

        mutating func consumeComment() throws -> Bool {
            guard scalars[index...].starts(with: "!--".unicodeScalars) else { return false }
            for _ in 0..<3 { try advance() }
            while index != scalars.endIndex {
                if scalars[index...].starts(with: "-->".unicodeScalars) {
                    for _ in 0..<3 { try advance() }
                    return true
                }
                try advance()
            }
            return true
        }

        func startsRawClosingTag(_ name: String) -> Bool {
            var cursor = index
            guard cursor != scalars.endIndex, scalars[cursor] == "/" else { return false }
            cursor = scalars.index(after: cursor)
            for expected in name.unicodeScalars {
                guard cursor != scalars.endIndex else { return false }
                let value = scalars[cursor].value
                let folded = (65...90).contains(value) ? value + 32 : value
                guard folded == expected.value else { return false }
                cursor = scalars.index(after: cursor)
            }
            guard cursor != scalars.endIndex else { return false }
            return Self.isWhitespace(scalars[cursor]) || scalars[cursor] == ">" || scalars[cursor] == "/"
        }

        struct Tag {
            let name: String
            let closing: Bool
        }

        mutating func consumeTag() throws -> Tag? {
            guard index != scalars.endIndex else { return nil }
            var closing = false
            if scalars[index] == "/" {
                closing = true
                try advance()
            }
            guard index != scalars.endIndex else { return nil }
            let declaration = scalars[index] == "!" || scalars[index] == "?"
            guard declaration || Self.isASCIIAlpha(scalars[index]) else { return nil }
            var name = ""
            while index != scalars.endIndex {
                let scalar = scalars[index]
                if Self.isWhitespace(scalar) || scalar == "/" || scalar == ">" { break }
                // Names beyond this length cannot be one of the structural
                // HTML tags below. Consume them without retaining attributes.
                if name.utf8.count < 32 { name.unicodeScalars.append(scalar) }
                try advance()
            }
            var quote: Unicode.Scalar?
            while index != scalars.endIndex {
                let scalar = scalars[index]
                try advance()
                if let delimiter = quote {
                    if scalar == delimiter { quote = nil }
                } else if scalar == "\"" || scalar == "'" {
                    quote = scalar
                } else if scalar == ">" {
                    return Tag(name: declaration ? "" : name.lowercased(), closing: closing)
                }
            }
            return Tag(name: "", closing: false)
        }

        mutating func handle(_ tag: Tag) {
            if let rawTextTag {
                if tag.closing, tag.name == rawTextTag { self.rawTextTag = nil }
                return
            }
            if tag.name == "script" || tag.name == "style" {
                if !tag.closing { rawTextTag = tag.name }
                return
            }
            if tag.name == "head" {
                headDepth = tag.closing ? max(0, headDepth - 1) : headDepth + 1
                return
            }
            if tag.name == "body", !tag.closing { headDepth = 0 }
            if tag.name == "template" {
                templateDepth = tag.closing ? max(0, templateDepth - 1) : templateDepth + 1
                return
            }
            guard !isSuppressed else { return }
            if tag.name == "pre" {
                preDepth = tag.closing ? max(0, preDepth - 1) : preDepth + 1
            }
            if Self.blockTags.contains(tag.name) || tag.name == "br" || tag.name == "hr" {
                separate("\n")
            } else if tag.name == "td" || tag.name == "th" {
                separate("\t")
            }
        }

        mutating func separate(_ separator: String) {
            guard !output.isEmpty else { return }
            if separator == "\n" || pendingSeparator.isEmpty { pendingSeparator = separator }
        }

        mutating func append(_ scalar: Unicode.Scalar) {
            guard !truncated else { return }
            // HTML collapses only ASCII whitespace. NBSP remains selectable
            // content, including when produced by a character reference.
            if preDepth == 0, Self.isWhitespace(scalar) {
                separate(" ")
                return
            }
            let scalarBytes: Int
            switch scalar.value {
            case 0...0x7F: scalarBytes = 1
            case 0...0x7FF: scalarBytes = 2
            case 0...0xFFFF: scalarBytes = 3
            default: scalarBytes = 4
            }
            guard outputBytes + pendingSeparator.utf8.count + scalarBytes <= maximumOutputBytes else {
                // Drop the final Character only if this undisplayed scalar
                // extends it; an ordinary ASCII cutoff keeps the whole budget.
                if pendingSeparator.isEmpty, let last = output.last,
                   (String(last) + String(scalar)).count == 1 { output.removeLast() }
                truncated = true
                return
            }
            output.append(pendingSeparator)
            outputBytes += pendingSeparator.utf8.count + scalarBytes
            pendingSeparator = ""
            output.unicodeScalars.append(scalar)
            outputScalars += 1
            // Amortize Character counting instead of recounting the growing
            // string for each scalar. One extra Character proves the retained
            // 50,000-Character prefix is complete before stopping the parser.
            if outputScalars.isMultiple(of: 4_096), output.count > PreviewText.maximumCharacters {
                truncated = true
            }
        }

        mutating func consumeEntity() throws -> String? {
            let start = index
            var spelling = ""
            while index != scalars.endIndex, spelling.utf8.count <= 32 {
                let scalar = scalars[index]
                if scalar == ";" {
                    try advance()
                    if let value = PreviewHTMLEntities.decode(spelling) { return value }
                    index = start
                    return nil
                }
                guard Self.isASCIIAlpha(scalar) || ("0"..."9").contains(scalar)
                    || scalar == "#" else { break }
                spelling.unicodeScalars.append(scalar)
                try advance()
            }
            // Common legacy entities also occur without a semicolon at a
            // word boundary. Unknown references remain literal source text.
            if spelling.hasPrefix("#") || PreviewHTMLEntities.legacyNames.contains(spelling),
               let decoded = PreviewHTMLEntities.decode(spelling) { return decoded }
            index = start
            return nil
        }

        static func isASCIIAlpha(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        }

        static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{C}"
        }

        static let blockTags: Set<String> = [
            "address", "article", "aside", "blockquote", "caption", "dd", "div", "dl", "dt",
            "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4",
            "h5", "h6", "header", "li", "main", "nav", "ol", "p", "pre", "section", "table",
            "tr", "ul"
        ]
    }
}
