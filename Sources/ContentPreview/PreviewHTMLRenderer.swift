/// Offline HTML text extraction for the history pane (REVIEW §4.9).
/// This consumes an immutable byte value, never a URL or a document loader.
/// Tags only supply text separation; attributes never become capabilities.
import Foundation

internal enum PreviewHTMLRenderer {
    internal static func render(
        _ bytes: Data,
        maximumInputBytes: Int,
        maximumOutputBytes: Int,
        textConfiguration: PreviewTextConfiguration = .init()
    ) -> PreviewOutcome {
        guard bytes.count <= maximumInputBytes, maximumOutputBytes > 0 else {
            return .failed(.resourceLimit)
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard let source = decode(bytes) else { return .failed(.malformedRepresentation) }
        do {
            var parser = Parser(source, maximumOutputBytes: maximumOutputBytes, textConfiguration: textConfiguration)
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
        let textConfiguration: PreviewTextConfiguration
        var output = ""
        var outputBytes = 0
        var consumed = 0
        var outputScalars = 0
        var nextCharacterCheck = 4_096
        var truncated = false
        var pendingSeparator = ""
        var preDepth = 0
        var headDepth = 0
        var templateDepth = 0
        var rawTextTag: String?
        enum ScriptEscaping { case data, escaped, doubleEscaped }
        var scriptEscaping = ScriptEscaping.data
        var scriptDashes = 0
        var textAreaActive = false
        var ignoreLeadingNewline = false
        var isSuppressed: Bool { headDepth > 0 || templateDepth > 0 }

        init(_ source: String, maximumOutputBytes: Int, textConfiguration: PreviewTextConfiguration) {
            scalars = source.unicodeScalars
            index = scalars.startIndex
            self.maximumOutputBytes = maximumOutputBytes
            self.textConfiguration = textConfiguration
        }

        mutating func render() throws -> PreviewText {
            while index != scalars.endIndex, !truncated {
                if rawTextTag == "script" {
                    try consumeScriptText()
                    continue
                }
                let scalar = scalars[index]
                // HTML input preprocessing folds source CR/CRLF to LF.
                // Do this before text extraction, including preformatted
                // code, but never change a CR produced by `&#13;`.
                if scalar == "\r" {
                    try advance()
                    if index != scalars.endIndex, scalars[index] == "\n" { try advance() }
                    if rawTextTag == nil, !isSuppressed { append("\n") }
                    continue
                }
                if scalar == "<" {
                    let start = index
                    try advance()
                    if textAreaActive {
                        // RCDATA recognizes only its own end tag. Markup,
                        // comments and script source inside a textarea are
                        // user-visible text, not new document instructions.
                        // WHATWG parsing.html#rcdata-state / #parsing-main-inbody.
                        if startsRawTag("textarea", closing: true), let tag = try consumeTag() {
                            handle(tag)
                        } else if !isSuppressed {
                            append("<")
                        }
                        continue
                    }
                    if let rawTextTag {
                        // Style raw text has no ordinary tags or comments.
                        // Script's additional escape forms are handled above.
                        // Only this element's own closing tag ends the skip.
                        if startsRawTag(rawTextTag, closing: true),
                           let tag = try consumeTag() { handle(tag) }
                        continue
                    }
                    // The pre rule applies to its next token only. A comment
                    // or child tag ends that opportunity even if it supplies
                    // no visible text; textarea markup remains literal above.
                    ignoreLeadingNewline = false
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
            return PreviewText(
                text: output,
                wasTruncated: truncated,
                configuration: textConfiguration
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
            // WHATWG comment-start/start-dash: abrupt empty comments still
            // terminate here, rather than swallowing the remaining document.
            if index != scalars.endIndex, scalars[index] == ">" {
                try advance()
                return true
            }
            if scalars[index...].starts(with: "->".unicodeScalars) {
                for _ in 0..<2 { try advance() }
                return true
            }
            while index != scalars.endIndex {
                if scalars[index...].starts(with: "-->".unicodeScalars) {
                    for _ in 0..<3 { try advance() }
                    return true
                }
                if scalars[index...].starts(with: "--!>".unicodeScalars) {
                    for _ in 0..<4 { try advance() }
                    return true
                }
                try advance()
            }
            return true
        }

        /// Consume script data without interpreting JS syntax or building a
        /// token buffer. HTML's escaped/double-escaped forms matter even for
        /// inert text: the first </script> inside <!-- <script> is script
        /// content, and treating it as a close would leak the remaining code.
        /// WHATWG §13.2.5.18–31; all lookahead is at most eight scalars.
        mutating func consumeScriptText() throws {
            let scalar = scalars[index]
            if scriptEscaping != .data {
                if scalar == "-" {
                    scriptDashes = min(2, scriptDashes + 1)
                    try advance()
                    return
                }
                if scalar == ">", scriptDashes == 2 { scriptEscaping = .data }
            }
            scriptDashes = 0
            guard scalar == "<" else { try advance(); return }
            try advance()
            if startsRawTag("script", closing: true) {
                if scriptEscaping == .doubleEscaped {
                    // /script plus its delimiter ends double escaping; it
                    // does not close the HTML script element.
                    for _ in 0..<8 { try advance() }
                    scriptEscaping = .escaped
                } else if let tag = try consumeTag() {
                    handle(tag)
                }
            } else if scriptEscaping == .escaped,
                      startsRawTag("script", closing: false) {
                for _ in 0..<7 { try advance() }
                scriptEscaping = .doubleEscaped
            } else if scriptEscaping == .data,
                      scalars[index...].starts(with: "!--".unicodeScalars) {
                for _ in 0..<3 { try advance() }
                scriptEscaping = .escaped
                scriptDashes = 2
            }
        }

        func startsRawTag(_ name: String, closing: Bool) -> Bool {
            var cursor = index
            if closing {
                guard cursor != scalars.endIndex, scalars[cursor] == "/" else { return false }
                cursor = scalars.index(after: cursor)
            }
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
                if !tag.closing {
                    rawTextTag = tag.name
                    scriptEscaping = .data
                    scriptDashes = 0
                }
                return
            }
            if tag.name == "textarea" {
                textAreaActive = !tag.closing
                ignoreLeadingNewline = !tag.closing
                if !isSuppressed { separate("\n") }
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
                // WHATWG parsing.html#parsing-main-inbody: ignore one LF
                // character token immediately after the opening pre tag.
                ignoreLeadingNewline = !tag.closing
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
            if ignoreLeadingNewline {
                ignoreLeadingNewline = false
                if scalar == "\n" { return }
            }
            // HTML collapses only ASCII whitespace. NBSP remains selectable
            // content, including when produced by a character reference.
            if preDepth == 0, !textAreaActive, Self.isWhitespace(scalar) {
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
            // Geometric checkpoints bound the sum of full-string counting
            // scans. A long combining sequence may contain many scalars but
            // few Characters; fixed 4K intervals repeatedly scanned its
            // entire growing prefix. The byte budget remains authoritative,
            // and render() still cuts the exact 50,000-Character prefix.
            if outputScalars >= nextCharacterCheck {
                if let maximum = textConfiguration.maximumCharacters,
                   output.count > maximum { truncated = true }
                nextCharacterCheck *= 2
            }
        }

        mutating func consumeEntity() throws -> String? {
            let start = index
            if index != scalars.endIndex, scalars[index] == "#" {
                return try consumeNumericEntity()
            }
            var spelling = ""
            var legacyMatch: (value: String, end: String.Index)?
            while index != scalars.endIndex, spelling.utf8.count <= 32 {
                let scalar = scalars[index]
                if scalar == ";" {
                    try advance()
                    if let value = PreviewHTMLEntities.decode(spelling) { return value }
                    break
                }
                guard Self.isASCIIAlpha(scalar) || ("0"..."9").contains(scalar) else { break }
                spelling.unicodeScalars.append(scalar)
                try advance()
                if PreviewHTMLEntities.legacyNames.contains(spelling),
                   let value = PreviewHTMLEntities.decode(spelling) {
                    legacyMatch = (value, index)
                }
            }
            // WHATWG §13.2.5.78: text uses the longest supported reference,
            // including a legacy prefix in `&copycat`. The alphanumeric/=
            // exception applies only to attributes, which we never render.
            if let legacyMatch {
                index = legacyMatch.end
                return legacyMatch.value
            }
            index = start
            return nil
        }

        mutating func consumeNumericEntity() throws -> String? {
            let start = index
            try advance() // #
            var radix: UInt32 = 10
            if index != scalars.endIndex, scalars[index] == "x" || scalars[index] == "X" {
                radix = 16
                try advance()
            }
            let digitStart = index
            var value: UInt32 = 0
            while index != scalars.endIndex {
                let scalar = scalars[index].value
                let digit: UInt32
                switch scalar {
                case 48...57: digit = scalar - 48
                case 65...70 where radix == 16: digit = scalar - 55
                case 97...102 where radix == 16: digit = scalar - 87
                default: digit = radix
                }
                guard digit < radix else { break }
                // Consume all digits with bounded storage, even when the
                // reference exceeds UInt32. All values above Unicode's range
                // produce the same replacement scalar (WHATWG §13.2.5.84).
                value = min(0x110000, value * radix + digit)
                try advance()
            }
            guard index != digitStart else { index = start; return nil }
            if index != scalars.endIndex, scalars[index] == ";" { try advance() }
            // Missing semicolons do not consume the first non-digit: e.g.
            // `&#65abc` renders as `Aabc`, not as an unknown reference.
            return PreviewHTMLEntities.decode("#\(value)")
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
