/// Compiled exact-literal matcher for HistoryStorage's exact-search worker.
/// Owning semantics: docs/03b-instruction-set.md §8. Complexity investigation:
/// docs/AUDIT.md IND-07.
///
/// The scan is the word-prefilter pipeline glibc/musl `memmem` and Rust's
/// `memchr::memmem` use on scalar builds: one 8-byte SWAR sweep answers three
/// questions per word — all-ASCII eligibility, no-CR eligibility, and the
/// presence of a case-folded needle-head byte — and only candidate offsets
/// pay a folded verification. A failed-verification budget detects
/// adversary-shaped corpora (256 KiB of `a` against `aaa…ab`) and switches to
/// the linear KMP automaton, so the worst case stays O(n + m).
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
/// The eligible ASCII subset uses the word-prefiltered case-folded search,
/// giving O(m) preprocessing and O(n) worst-case search even for
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

    /// After this many failed candidate verifications the scan concludes the
    /// corpus is adversary-shaped and stops prefilters: the remaining bytes
    /// (and, because per-byte checks are idempotent, safely re-read ones) run
    /// through the linear KMP automaton instead, restoring the O(n) bound the
    /// verification loop would otherwise lose on `aaaa…` against `aaa…ab`.
    private static let maxFailedVerifications = 256

    private static let swarHighs: UInt64 = 0x8080_8080_8080_8080
    private static let swarOnes: UInt64 = 0x0101_0101_0101_0101

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

    /// Performs exactly one eligibility/search pass over the UTF-8 bytes.
    ///
    /// Eligibility contract for an accelerated (non-Foundation) result at
    /// offset `s`: every byte of the PREFIX `[0, s + needle.count)` is
    /// all-ASCII and CR-free. That prefix is sufficient because a
    /// `.caseInsensitive + .literal` Foundation match has exactly the
    /// needle's length, so any earlier Foundation-visible match lies wholly
    /// inside `[0, s + m)` — and one that would rely on non-ASCII case
    /// folding (e.g. U+212A KELVIN SIGN matching `k`) also needs its
    /// non-ASCII byte inside that prefix. Both match coordinates are
    /// prefix-determined (Character and UTF-16 counts), so bytes at or
    /// beyond `s + m` cannot change the returned offsets. A byte past the
    /// prefix therefore never forces a fallback: the scan stops at
    /// `s + m` instead of proving the whole body, matching Foundation's
    /// early exit on hit rows. With no match, every byte is proven eligible
    /// before the accelerated nil verdict; one ineligible byte anywhere in
    /// the scanned span forfeits the whole comparison to Foundation.
    ///
    /// SWAR vocabulary (the identities glibc/musl use for `memchr`/`memmem`):
    /// a word contains byte `b` iff `word ^ splat(b)` contains a zero byte,
    /// and `(x - 0x01…) & ~x & 0x80…` reports zero bytes with no per-byte
    /// branch. `splat(b) = b * 0x0101…01` is endianness-independent because
    /// XOR compares byte lanes, whose order matches the load.
    private func scanASCII(in text: String) -> ASCIIScanResult {
        guard let needle = asciiNeedle else {
            return .requiresFoundation
        }

        // withUTF8 may native-ify the storage, so it needs a mutable local;
        // for already-native strings (every stored search body) this is a
        // retain, not a copy.
        var mutableText = text
        return mutableText.withUTF8 { utf8 -> ASCIIScanResult in
            let count = utf8.count
            let rawBase = utf8.baseAddress.map { UnsafeRawPointer($0) }
            let head = needle[0]
            let headIsLetter = (0x61...0x7A).contains(head)
            var firstMatchOffset: Int?
            var failedVerifications = 0
            var useAutomaton = false
            var automatonMatched = 0
            var index = 0
            // Once a word-path verify succeeds, only the prefix through
            // `matchEndLimit` still needs its eligibility proven; the scan
            // then stops instead of walking the whole body.
            var matchEndLimit = -1

            while index < count {
                if matchEndLimit >= 0 {
                    if index >= matchEndLimit {
                        return .evaluated(match(at: firstMatchOffset!, needle: needle))
                    }
                    // Finish mode: eligibility only, still word-shaped.
                    if let rawBase, count &- index >= 8 {
                        let word = rawBase
                            .loadUnaligned(fromByteOffset: index, as: UInt64.self)
                        if word & Self.swarHighs != 0
                            || Self.containsByte(word, 0x0D) {
                            // Conservative by at most 7 trailing bytes of
                            // word overshoot; the result stays Foundation's.
                            return .requiresFoundation
                        }
                        index &+= 8
                        continue
                    }
                    let raw = utf8[index]
                    if raw >= 0x80 || raw == 0x0D {
                        return .requiresFoundation
                    }
                    index &+= 1
                    continue
                }

                if !useAutomaton, let rawBase, count &- index >= 8 {
                    let word = rawBase
                        .loadUnaligned(fromByteOffset: index, as: UInt64.self)
                    if word & Self.swarHighs != 0
                        || Self.containsByte(word, 0x0D) {
                        return .requiresFoundation
                    }
                    if firstMatchOffset == nil,
                       Self.mayContainHead(word, head: head, isLetter: headIsLetter) {
                        var candidate = index
                        var adversarySwitched = false
                        wordScan: while candidate < index &+ 8 {
                            if Self.foldsEqual(utf8[candidate], head) {
                                if let start = verifyCandidate(
                                    utf8,
                                    needle: needle,
                                    at: candidate,
                                    count: count
                                ) {
                                    firstMatchOffset = start
                                    matchEndLimit = start &+ needle.count
                                    break wordScan
                                }
                                failedVerifications &+= 1
                                if failedVerifications >= Self.maxFailedVerifications {
                                    adversarySwitched = true
                                    break wordScan
                                }
                            }
                            candidate &+= 1
                        }
                        if adversarySwitched {
                            // Re-read this word byte-by-byte through the
                            // automaton (checks are idempotent), never past
                            // an unverified candidate.
                            useAutomaton = true
                            continue
                        }
                    }
                    index &+= 8
                    continue
                }

                // Scalar automaton pass: tail bytes and adversary corpora.
                let raw = utf8[index]
                if raw >= 0x80 || raw == 0x0D {
                    return .requiresFoundation
                }
                let byte = Self.foldASCII(raw)
                while automatonMatched > 0, byte != needle[automatonMatched] {
                    automatonMatched = failureTable[automatonMatched - 1]
                }
                if byte == needle[automatonMatched] {
                    automatonMatched &+= 1
                }
                if automatonMatched == needle.count {
                    if firstMatchOffset == nil {
                        // The automaton eligibility-checked every byte it
                        // consumed, and the match ends at this index — the
                        // whole prefix `[0, s + m)` is already proven.
                        return .evaluated(
                            match(at: index &+ 1 &- needle.count, needle: needle)
                        )
                    }
                    automatonMatched = failureTable[automatonMatched - 1]
                }
                index &+= 1
            }

            return .evaluated(firstMatchOffset.map { offset in
                match(at: offset, needle: needle)
            })
        }
    }

    private func match(at offset: Int, needle: [UInt8]) -> ExactLiteralMatch {
        ExactLiteralMatch(
            characterOffset: offset,
            characterLength: needle.count,
            utf16Offset: offset,
            utf16Length: needle.count
        )
    }

    /// Verifies one candidate offset against the folded needle. Bounded by
    /// the needle length; a candidate too close to the end to hold the whole
    /// needle cannot match here (the automaton pass re-decides tail offsets).
    private func verifyCandidate(
        _ bytes: UnsafeBufferPointer<UInt8>,
        needle: [UInt8],
        at start: Int,
        count: Int
    ) -> Int? {
        guard start &+ needle.count <= count else {
            return nil
        }
        for offset in needle.indices {
            guard Self.foldsEqual(bytes[start &+ offset], needle[offset]) else {
                return nil
            }
        }
        return start
    }

    /// Folded byte equality: ASCII letters compare across their two cases;
    /// every other byte compares exactly (03b §8 case-insensitivity).
    private static func foldsEqual(_ lhs: UInt8, _ rhs: UInt8) -> Bool {
        foldASCII(lhs) == foldASCII(rhs)
    }

    /// `b * 0x0101…01` repeats `b` into all eight byte lanes exactly.
    private static func splat(_ byte: UInt8) -> UInt64 {
        UInt64(byte) &* swarOnes
    }

    /// The classic zero-byte detector: a lane is zero iff subtracting 1
    /// borrows into the high bit that was not already set.
    private static func hasZeroByte(_ value: UInt64) -> Bool {
        (value &- swarOnes) & ~value & swarHighs != 0
    }

    private static func containsByte(_ word: UInt64, _ byte: UInt8) -> Bool {
        hasZeroByte(word ^ splat(byte))
    }

    /// Whether the word may hold the needle head in either of its two ASCII
    /// cases. Non-letter heads occur in exactly one byte value.
    private static func mayContainHead(
        _ word: UInt64,
        head: UInt8,
        isLetter: Bool
    ) -> Bool {
        if containsByte(word, head) {
            return true
        }
        return isLetter && containsByte(word, head &- 0x20)
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
