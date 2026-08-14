/// Compiled exact-literal matcher for HistoryStorage's exact-search worker.
/// Owning semantics: docs/03b-instruction-set.md §8. Complexity investigation:
/// docs/AUDIT.md IND-07.
import Foundation

/// First-match offsets in both coordinate systems consumed by search
/// presentation. Keeping offsets as values avoids exporting `String.Index`
/// across the matcher seam and lets eligible-ASCII matches skip extra walks.
package struct ExactLiteralMatch: Equatable, Sendable {
    package let characterOffset: Int
    package let characterLength: Int
    package let utf16Offset: Int
    package let utf16Length: Int

    package init(
        characterOffset: Int,
        characterLength: Int,
        utf16Offset: Int,
        utf16Length: Int
    ) {
        self.characterOffset = characterOffset
        self.characterLength = characterLength
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
    }
}

#if DEBUG
/// Debug-only route evidence for the worker trace. Release builds carry only
/// the match value, with no result wrapper or route-classification scan.
internal struct ExactLiteralMatchDebugResult: Equatable, Sendable {
    let match: ExactLiteralMatch?
    let usedASCIILinearPath: Bool
}
#endif

/// One compiled needle reused for every title/body in one public exact search.
///
/// The eligible ASCII subset uses Knuth-Morris-Pratt after one ASCII-only case
/// fold, giving O(m) preprocessing and O(n) worst-case search even for
/// repeated-prefix adversaries. If either operand contains non-ASCII or CR,
/// the complete comparison delegates to Foundation's frozen
/// `.caseInsensitive + .literal` behavior; a provisional ASCII-prefix match
/// is never returned from a mixed string. CR is excluded because Swift treats
/// CRLF as one `Character`, so byte and Character coordinates can diverge.
package struct ExactLiteralMatcher: Sendable {
    private enum ASCIIScanResult {
        case evaluated(ExactLiteralMatch?)
        case requiresFoundation
    }

    private let term: String
    private let asciiNeedle: [UInt8]?
    private let failureTable: [Int]

    package init(term: String) {
        self.term = term
        let bytes = Array(term.utf8)
        guard !bytes.isEmpty,
              bytes.allSatisfy({ $0 < 0x80 && $0 != 0x0D })
        else {
            asciiNeedle = nil
            failureTable = []
            return
        }
        let folded = bytes.map(Self.foldASCII)
        asciiNeedle = folded
        failureTable = Self.makeFailureTable(for: folded)
    }

    /// Returns the first match with exactly the coordinates the public row
    /// presentation needs. Empty terms use Foundation here defensively; the
    /// worker normally routes them through recent-equivalent evaluation.
    package func firstMatch(in text: String) -> ExactLiteralMatch? {
        switch scanASCII(in: text) {
        case .evaluated(let match):
            return match
        case .requiresFoundation:
            return foundationMatch(in: text)
        }
    }

#if DEBUG
    internal func firstMatchWithDebugRoute(
        in text: String
    ) -> ExactLiteralMatchDebugResult {
        switch scanASCII(in: text) {
        case .evaluated(let match):
            return ExactLiteralMatchDebugResult(
                match: match,
                usedASCIILinearPath: true
            )
        case .requiresFoundation:
            return ExactLiteralMatchDebugResult(
                match: foundationMatch(in: text),
                usedASCIILinearPath: false
            )
        }
    }
#endif

    /// Performs exactly one eligibility/search pass. The route is returned
    /// with the provisional match so Debug instrumentation never adds a second
    /// full-body scan merely to classify the matcher lane.
    private func scanASCII(in text: String) -> ASCIIScanResult {
        guard let asciiNeedle else {
            return .requiresFoundation
        }

        var matchedCount = 0
        var byteOffset = 0
        var firstMatchOffset: Int?
        for rawByte in text.utf8 {
            // The optimization is valid only when the WHOLE haystack is ASCII.
            // If a later scalar disproves that, discard any provisional match
            // and let Foundation decide the entire string.
            guard rawByte < 0x80, rawByte != 0x0D else {
                return .requiresFoundation
            }
            let byte = Self.foldASCII(rawByte)
            while matchedCount > 0, byte != asciiNeedle[matchedCount] {
                matchedCount = failureTable[matchedCount - 1]
            }
            if byte == asciiNeedle[matchedCount] {
                matchedCount += 1
            }
            if matchedCount == asciiNeedle.count {
                if firstMatchOffset == nil {
                    firstMatchOffset = byteOffset + 1 - asciiNeedle.count
                }
                // Continue through the row to prove that it is all-ASCII, but
                // retain only the first match required by 03b §8.
                matchedCount = failureTable[matchedCount - 1]
            }
            byteOffset += 1
        }

        guard let firstMatchOffset else {
            return .evaluated(nil)
        }
        return .evaluated(ExactLiteralMatch(
            characterOffset: firstMatchOffset,
            characterLength: asciiNeedle.count,
            utf16Offset: firstMatchOffset,
            utf16Length: asciiNeedle.count
        ))
    }

    /// Foundation is the semantic oracle for every non-ASCII comparison.
    private func foundationMatch(in text: String) -> ExactLiteralMatch? {
        guard let range = text.range(
            of: term,
            options: [.caseInsensitive, .literal]
        ) else {
            return nil
        }
        let utf16Range = NSRange(range, in: text)
        return ExactLiteralMatch(
            characterOffset: text.distance(
                from: text.startIndex,
                to: range.lowerBound
            ),
            characterLength: text.distance(
                from: range.lowerBound,
                to: range.upperBound
            ),
            utf16Offset: utf16Range.location,
            utf16Length: utf16Range.length
        )
    }

    private static func foldASCII(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }

    private static func makeFailureTable(for needle: [UInt8]) -> [Int] {
        var table = Array(repeating: 0, count: needle.count)
        var prefixLength = 0
        for index in 1..<needle.count {
            while prefixLength > 0, needle[index] != needle[prefixLength] {
                prefixLength = table[prefixLength - 1]
            }
            if needle[index] == needle[prefixLength] {
                prefixLength += 1
            }
            table[index] = prefixLength
        }
        return table
    }
}
