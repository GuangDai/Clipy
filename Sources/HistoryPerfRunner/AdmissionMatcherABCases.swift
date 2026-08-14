/// Case table for the record-only exact matcher Release A/B (IND-07):
/// body builders, the input list with per-case corpora and decision
/// thresholds. Split out of AdmissionMatcherAB.swift (file-size
/// hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryStorage

struct AdmissionMatcherABInput {
    let name: String
    let decisionClass: String
    let maximumPairedMedianRatio: Double
    let term: String
    /// Per-case corpus size. The default 128-body (32 MiB) corpus fits the
    /// supported-runner cache envelope; the repeated-prefix adversary uses 2
    /// because its FOUNDATION side is the pathological one — the
    /// 2026-08-14 instrumented dispatch measured NSString at roughly 12 s
    /// per 256 KiB `a` body for a 4,096-byte needle (~0.17 MB/s, ~60× below
    /// its own absent-needle average), so even 8 bodies exceeded 21 minutes.
    /// The case exists to prove the compiled side stays linear on that
    /// shape; two bodies keep a paired Foundation baseline on record.
    let bodiesPerSample: Int
    let makeBody: (Int) -> String

    init(
        name: String,
        decisionClass: String,
        maximumPairedMedianRatio: Double,
        term: String,
        bodiesPerSample: Int = 128,
        makeBody: @escaping (Int) -> String
    ) {
        self.name = name
        self.decisionClass = decisionClass
        self.maximumPairedMedianRatio = maximumPairedMedianRatio
        self.term = term
        self.bodiesPerSample = bodiesPerSample
        self.makeBody = makeBody
    }
}

/// One 256-KiB ASCII value with a short per-body discriminator. The caller's
/// prefix/suffix must themselves be ASCII so logical bytes equal UTF-8 bytes.
func admissionMatcherBody(
    index: Int,
    prefix: String = "",
    repeating byte: Character = "x",
    suffix: String = ""
) -> String {
    let discriminator = "[\(index)]"
    let fixedBytes = prefix.utf8.count
        + discriminator.utf8.count
        + suffix.utf8.count
    precondition(fixedBytes <= admissionSearchBodyBytes)
    return prefix
        + discriminator
        + String(repeating: byte, count: admissionSearchBodyBytes - fixedBytes)
        + suffix
}

/// A source-shaped, all-ASCII body. Repeating a realistic lexical mix avoids
/// treating the deliberately low-entropy admission fixture as representative
/// matcher evidence while preserving an exact 256-KiB envelope.
func admissionMatcherSourceBody(index: Int) -> String {
    let prefix = "[\(index)]"
    let source = """
    struct ClipboardRow: Sendable {
        let identifier: UUID
        let title: String
        let searchBody: String
        func contains(_ term: String) -> Bool { title.contains(term) }
    }

    """
    let remaining = admissionSearchBodyBytes - prefix.utf8.count
    let repetitions = (remaining / source.utf8.count) + 1
    return prefix + String(String(repeating: source, count: repetitions).prefix(remaining))
}

/// Deterministic high-entropy ASCII without test-run randomness. The alphabet
/// excludes neither case nor digits, so it exercises a very different byte
/// distribution from the synthetic repeated-`x` admission corpus.
func admissionMatcherHighEntropyBody(index: Int) -> String {
    let alphabet = Array(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".utf8
    )
    var state = UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15
    var bytes: [UInt8] = []
    bytes.reserveCapacity(admissionSearchBodyBytes)
    while bytes.count < admissionSearchBodyBytes {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        bytes.append(alphabet[Int(state % UInt64(alphabet.count))])
    }
    return String(decoding: bytes, as: UTF8.self)
}

func admissionExactMatcherABInputs() -> [AdmissionMatcherABInput] {
    [
        AdmissionMatcherABInput(
            name: "admission-absent-48",
            decisionClass: "primary",
            maximumPairedMedianRatio: 0.80,
            term: "term-that-does-not-exist-in-the-admission-corpus",
            makeBody: { admissionMatcherBody(index: $0) }
        ),
        AdmissionMatcherABInput(
            name: "early-hit-16",
            decisionClass: "representative",
            maximumPairedMedianRatio: 1.10,
            term: "early-needle-hit",
            makeBody: {
                admissionMatcherBody(index: $0, prefix: "EARLY-NEEDLE-HIT")
            }
        ),
        AdmissionMatcherABInput(
            name: "middle-hit-16",
            decisionClass: "representative",
            maximumPairedMedianRatio: 1.10,
            term: "middle-needle-hit",
            makeBody: { index in
                let discriminator = "[\(index)]"
                let marker = "MIDDLE-NEEDLE-HIT"
                let leading = discriminator
                    + String(
                        repeating: "x",
                        count: (admissionSearchBodyBytes / 2)
                            - discriminator.utf8.count
                    )
                return leading
                    + marker
                    + String(
                        repeating: "x",
                        count: admissionSearchBodyBytes
                            - leading.utf8.count
                            - marker.utf8.count
                    )
            }
        ),
        AdmissionMatcherABInput(
            name: "late-hit-16",
            decisionClass: "representative",
            maximumPairedMedianRatio: 1.10,
            term: "late-needle-hit!",
            makeBody: {
                admissionMatcherBody(index: $0, suffix: "LATE-NEEDLE-HIT!")
            }
        ),
        AdmissionMatcherABInput(
            name: "absent-needle-1",
            decisionClass: "representative",
            maximumPairedMedianRatio: 1.10,
            term: "z",
            makeBody: { admissionMatcherBody(index: $0) }
        ),
        AdmissionMatcherABInput(
            name: "absent-needle-64",
            decisionClass: "representative",
            maximumPairedMedianRatio: 1.10,
            term: String(repeating: "y", count: 64),
            makeBody: { admissionMatcherBody(index: $0) }
        ),
        AdmissionMatcherABInput(
            name: "repeated-prefix-4096",
            decisionClass: "adversarial",
            maximumPairedMedianRatio: 1.10,
            term: String(repeating: "a", count: 4_095) + "b",
            bodiesPerSample: 2,
            makeBody: {
                admissionMatcherBody(index: $0, repeating: "a")
            }
        ),
        AdmissionMatcherABInput(
            name: "source-absent-16",
            decisionClass: "representative",
            maximumPairedMedianRatio: 1.10,
            term: "token-never-here",
            makeBody: admissionMatcherSourceBody
        ),
        AdmissionMatcherABInput(
            name: "source-common-hit-4",
            decisionClass: "representative",
            maximumPairedMedianRatio: 1.10,
            term: "func",
            makeBody: admissionMatcherSourceBody
        ),
        AdmissionMatcherABInput(
            name: "high-entropy-absent-10",
            decisionClass: "representative",
            maximumPairedMedianRatio: 1.10,
            term: "q9ZxP4LmN7",
            makeBody: admissionMatcherHighEntropyBody
        ),
        AdmissionMatcherABInput(
            name: "unicode-needle-fallback",
            decisionClass: "fallback",
            maximumPairedMedianRatio: 1.25,
            term: "CAFÉ",
            makeBody: { index in
                let prefix = "[\(index)]"
                return prefix
                    + String(
                        repeating: "x",
                        count: admissionSearchBodyBytes
                            - prefix.utf8.count
                            - "café".utf8.count
                    )
                    + "café"
            }
        ),
        AdmissionMatcherABInput(
            name: "late-unicode-fallback",
            decisionClass: "fallback",
            maximumPairedMedianRatio: 1.25,
            term: "needle",
            makeBody: { index in
                let prefix = "[\(index)]"
                return prefix
                    + String(
                        repeating: "x",
                        count: admissionSearchBodyBytes
                            - prefix.utf8.count
                            - "😀".utf8.count
                    )
                    + "😀"
            }
        ),
        AdmissionMatcherABInput(
            name: "late-cr-fallback",
            decisionClass: "fallback",
            maximumPairedMedianRatio: 1.25,
            term: "needle",
            makeBody: { index in
                admissionMatcherBody(
                    index: index,
                    suffix: "\r\n"
                )
            }
        ),
    ]
}

