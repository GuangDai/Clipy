/// Offline RTF body-text extraction (REVIEW PREVIEW-RTF; 01 §6).
/// Parses only supplied bytes: fields are never evaluated, pictures/objects
/// become text placeholders, and font names never trigger font loading.
/// Syntax follows Microsoft's RTF specification: scoped groups, control
/// words/symbols, Unicode fallback characters and length-delimited binary.
import Foundation

internal enum PreviewRTFRenderer {
    internal static func render(_ bytes: Data, textConfiguration: PreviewTextConfiguration = .init()) -> PreviewOutcome {
        guard bytes.count <= 1_048_576 else { return .failed(.resourceLimit) }
        do {
            var parser = Parser(bytes: Array(bytes))
            let decoded = try parser.parse()
            return .content(.text(PreviewText(
                text: decoded, wasTruncated: false, configuration: textConfiguration
            )))
        } catch let failure as ParseFailure {
            switch failure {
            case .malformed: return .failed(.malformedRepresentation)
            case .resource: return .failed(.resourceLimit)
            case .unsupported: return .unavailable(.unsupported)
            case .cancelled: return .failed(.cancelled)
            }
        } catch {
            return .failed(.malformedRepresentation)
        }
    }
}

private enum ParseFailure: Error { case malformed, resource, unsupported, cancelled }

private struct Parser {
    let bytes: [UInt8]
    private var offset = 0
    private var output: [UInt16] = []
    private var encodedRun: [UInt8] = []
    private var stack: [State] = []
    private var state = State()
    private var fallbackRemaining = 0
    private var sawHeader = false
    private var finished = false
    private var attachmentCount = 0
    private var defaultFont = 0
    private var fontCodePages: [Int: Int] = [:]

    private struct State {
        var skipped = false
        var hidden = false
        var deleted = false
        var ignorableDestination = false
        var fontTable = false
        var font = 0
        var codePage = 1252
        var unicodeFallbackCount = 1
        var unicodeAlternative = false
        var alternativeChildren = 0
        var expectsUnicodeDestination = false
        var nextGraphicMarker = false
        var isVisible: Bool { !skipped && !hidden && !deleted }
    }

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parse() throws -> String {
        guard bytes.starts(with: Array("{\\rtf1".utf8)) else { throw ParseFailure.malformed }
        var nextCancellationCheck = 0
        while offset < bytes.count {
            if offset >= nextCancellationCheck {
                guard !Task.isCancelled else { throw ParseFailure.cancelled }
                nextCancellationCheck = offset + 1_024
            }
            let byte = bytes[offset]
            offset += 1
            if finished {
                guard [9, 10, 13, 32].contains(byte) else { throw ParseFailure.malformed }
                continue
            }
            switch byte {
            case 123: // {
                try flushEncodedRun()
                state.nextGraphicMarker = false
                guard stack.count < 128 else { throw ParseFailure.resource }
                guard !state.expectsUnicodeDestination else { throw ParseFailure.malformed }
                if state.unicodeAlternative {
                    state.alternativeChildren += 1
                    guard state.alternativeChildren <= 2 else { throw ParseFailure.malformed }
                    stack.append(state)
                    state.skipped = state.skipped || state.alternativeChildren == 1
                    state.expectsUnicodeDestination = state.alternativeChildren == 2
                    state.unicodeAlternative = false
                    state.alternativeChildren = 0
                } else {
                    stack.append(state)
                }
                fallbackRemaining = 0
            case 125: // }
                try flushEncodedRun()
                guard !state.expectsUnicodeDestination,
                      !state.unicodeAlternative || state.alternativeChildren == 2 else {
                    throw ParseFailure.malformed
                }
                guard let previous = stack.popLast() else { throw ParseFailure.malformed }
                state = previous
                fallbackRemaining = 0
                finished = stack.isEmpty
            case 92: try readControl()
            case 10, 13: break // Physical RTF line wrapping is not body text.
            default:
                guard !stack.isEmpty, sawHeader, byte != 0 else { throw ParseFailure.malformed }
                try appendEncodedByte(byte)
            }
        }
        guard finished, sawHeader else { throw ParseFailure.malformed }
        try flushEncodedRun()
        guard let text = String(validating: output, as: UTF16.self) else {
            throw ParseFailure.malformed
        }
        guard !Task.isCancelled else { throw ParseFailure.cancelled }
        return text
    }

    private mutating func readControl() throws {
        guard offset < bytes.count else { throw ParseFailure.malformed }
        let first = bytes[offset]
        offset += 1
        if first == 39 { // \'hh: keep adjacent bytes together for multibyte encodings.
            guard offset + 2 <= bytes.count,
                  let high = hex(bytes[offset]), let low = hex(bytes[offset + 1]) else {
                throw ParseFailure.malformed
            }
            offset += 2
            try appendEncodedByte(high * 16 + low)
            return
        }
        guard isLetter(first) else {
            if first == 92 || first == 123 || first == 125 {
                try appendEncodedByte(first)
                return
            }
            try flushEncodedRun()
            if fallbackRemaining > 0 { fallbackRemaining -= 1; return }
            switch first {
            case 42: state.ignorableDestination = true
            case 126: try appendUnits([0x00A0])
            case 95: try appendUnits([0x2011])
            case 45: try appendUnits([0x00AD])
            case 10, 13: try appendUnits([10])
            default: break
            }
            return
        }
        let start = offset - 1
        while offset < bytes.count, isLetter(bytes[offset]) { offset += 1 }
        guard offset - start <= 32 else { throw ParseFailure.malformed }
        let word = String(decoding: bytes[start..<offset], as: UTF8.self)
        var negative = false
        if offset < bytes.count, bytes[offset] == 45 { negative = true; offset += 1 }
        let numberStart = offset
        var number = 0
        while offset < bytes.count, (48...57).contains(bytes[offset]) {
            number = number * 10 + Int(bytes[offset] - 48)
            guard number <= 2_147_483_648 else { throw ParseFailure.malformed }
            offset += 1
        }
        guard !negative || offset != numberStart else { throw ParseFailure.malformed }
        let parameter: Int? = offset == numberStart ? nil : (negative ? -number : number)
        if offset < bytes.count, bytes[offset] == 32 { offset += 1 }
        try flushEncodedRun()
        if word == "bin" {
            guard let length = parameter, length >= 0, length <= bytes.count - offset else {
                throw ParseFailure.malformed
            }
            offset += length
            if fallbackRemaining > 0 { fallbackRemaining -= 1 }
            return
        }
        if fallbackRemaining > 0 { fallbackRemaining -= 1; return }
        try apply(word, parameter)
    }

    private mutating func apply(_ word: String, _ value: Int?) throws {
        if state.expectsUnicodeDestination {
            guard word == "ud", state.ignorableDestination else { throw ParseFailure.malformed }
            state.expectsUnicodeDestination = false
            state.ignorableDestination = false
        }
        if word == "pict" || word == "shppict" || word == "object" || word == "NeXTGraphic" {
            // Microsoft RTF §Pictures: Word wraps the primary picture in
            // {\*\shppict{\pict ...}} and may append a nonshppict fallback.
            // Represent the complete primary destination once, even with
            // its ignorable marker; nested pict and compatibility copies
            // remain skipped instead of disappearing or being counted twice.
            if state.isVisible {
                attachmentCount += 1
                guard attachmentCount <= 128 else { throw ParseFailure.resource }
            }
            try appendUnits(Array("[Attachment]".utf16))
            // Apple's attachment form is {{\NeXTGraphic ...}<0xAC>}.
            // Its outer group's one marker byte is not document body text.
            // Require that outer group so an unrelated following ¬ survives.
            if word == "NeXTGraphic", stack.count >= 3 {
                stack[stack.count - 1].nextGraphicMarker = true
            }
            state.skipped = true
        }
        if state.ignorableDestination {
            state.skipped = true
            state.ignorableDestination = false
        }
        if word == "fonttbl" { state.fontTable = true }
        if Self.skippedDestinations.contains(word) { state.skipped = true }
        switch word {
        case "rtf":
            guard !sawHeader, stack.count == 1, value == 1 else { throw ParseFailure.malformed }
            sawHeader = true
        case "ansi": state.codePage = 1252
        case "mac": state.codePage = 10000
        case "pc": state.codePage = 437
        case "pca": state.codePage = 850
        case "ansicpg":
            guard let value, value > 0 else { throw ParseFailure.malformed }
            state.codePage = value
        case "deff":
            guard let value, value >= 0 else { throw ParseFailure.malformed }
            defaultFont = value
            state.font = value
        case "f":
            guard let value, value >= 0 else { throw ParseFailure.malformed }
            state.font = value
        case "fcharset" where state.fontTable:
            guard let value else { throw ParseFailure.malformed }
            fontCodePages[state.font] = Self.codePage(forCharset: value, default: state.codePage)
        case "cpg" where state.fontTable:
            guard let value, value > 0 else { throw ParseFailure.malformed }
            fontCodePages[state.font] = value
        case "plain": state.hidden = false; state.deleted = false; state.font = defaultFont
        case "v": state.hidden = value != 0
        case "deleted": state.deleted = value != 0
        case "uc":
            guard let value, (0...32).contains(value) else { throw ParseFailure.malformed }
            state.unicodeFallbackCount = value
        case "u":
            guard let value, (-32768...32767).contains(value) else { throw ParseFailure.malformed }
            try appendUnits([UInt16(bitPattern: Int16(value))])
            fallbackRemaining = state.unicodeFallbackCount
        case "par", "line", "page", "sect", "row": try appendUnits([10])
        case "tab", "cell": try appendUnits([9])
        case "emdash": try appendUnits([0x2014])
        case "endash": try appendUnits([0x2013])
        case "bullet": try appendUnits([0x2022])
        case "lquote": try appendUnits([0x2018])
        case "rquote": try appendUnits([0x2019])
        case "ldblquote": try appendUnits([0x201C])
        case "rdblquote": try appendUnits([0x201D])
        case "enspace": try appendUnits([0x2002])
        case "emspace": try appendUnits([0x2003])
        case "qmspace": try appendUnits([0x2005])
        case "upr" where !state.skipped:
            // The first child is the ANSI fallback, the second is \*\ud.
            // Only the Unicode branch contributes to the displayed body.
            state.unicodeAlternative = true
            state.alternativeChildren = 0
        default: break // Unknown formatting controls carry no visible text.
        }
    }

    private mutating func appendEncodedByte(_ byte: UInt8) throws {
        if fallbackRemaining > 0 { fallbackRemaining -= 1; return }
        guard !state.expectsUnicodeDestination else { throw ParseFailure.malformed }
        guard state.isVisible else { return }
        if state.nextGraphicMarker {
            state.nextGraphicMarker = false
            if byte == 0xAC { return }
        }
        encodedRun.append(byte)
    }

    private mutating func flushEncodedRun() throws {
        guard !encodedRun.isEmpty else { return }
        defer { encodedRun.removeAll(keepingCapacity: true) }
        let codePage = fontCodePages[state.font] ?? state.codePage
        // Symbol-font byte values are glyph indices, including ASCII-range
        // bytes. Do not mislabel a glyph as its unrelated Latin character.
        guard codePage != -2 else { throw ParseFailure.unsupported }
        if encodedRun.allSatisfy({ $0 < 128 }) {
            try appendUnits(encodedRun.map(UInt16.init))
            return
        }
        guard let encoding = Self.encoding(for: codePage) else { throw ParseFailure.unsupported }
        // UTF-8 byte runs carry content scalars, not an encoding signature
        // to consume. Keep U+FEFF while still rejecting malformed sequences.
        let decoded = codePage == 65001
            ? String(validating: encodedRun, as: UTF8.self)
            : String(bytes: encodedRun, encoding: encoding)
        guard let string = decoded else { throw ParseFailure.malformed }
        try appendUnits(Array(string.utf16))
    }

    private mutating func appendUnits(_ units: [UInt16]) throws {
        guard state.isVisible else { return }
        state.nextGraphicMarker = false
        guard units.count <= 1_048_576 - output.count else { throw ParseFailure.resource }
        output.append(contentsOf: units)
    }

    private func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    private func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func codePage(forCharset value: Int, default defaultPage: Int) -> Int {
        switch value {
        case 0, 1: defaultPage
        case 2: -2
        case 77: 10000
        case 128: 932
        case 129: 949
        case 134: 936
        case 136: 950
        case 161: 1253
        case 162: 1254
        case 204: 1251
        case 238: 1250
        default: -1
        }
    }

    private static func encoding(for page: Int) -> String.Encoding? {
        switch page {
        case 1250: .windowsCP1250
        case 1251: .windowsCP1251
        case 1252: .windowsCP1252
        case 1253: .windowsCP1253
        case 1254: .windowsCP1254
        case 10000: .macOSRoman
        case 932: .shiftJIS
        case 936: foundationEncoding(.dosChineseSimplif)
        case 949: foundationEncoding(.dosKorean)
        case 950: foundationEncoding(.dosChineseTrad)
        case 65001: .utf8
        default: nil
        }
    }

    /// Apple's DOS-named constants specify these exact Windows code pages
    /// (936/949/950), including their Windows extensions. Do not substitute
    /// GB18030, EUC-KR or Big5-HKSCS, which accept different byte sequences.
    private static func foundationEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(encoding.rawValue)
        ))
    }

    private static let skippedDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "filetbl", "revtbl",
        "listtable", "listoverridetable", "generator", "xmlnstbl", "rsidtbl",
        "fldinst", "datafield", "formfield", "objdata", "objclass", "objname",
        "header", "headerl", "headerr", "headerf", "footer", "footerl", "footerr", "footerf",
        "annotation", "atnauthor", "atnid", "footnote", "bkmkstart", "bkmkend", "xe", "tc",
        "shp", "shpinst", "nonshppict", "private", "docvar", "themedata", "colorschememapping",
    ]
}
