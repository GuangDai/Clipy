import Foundation

/// Inert text prepared off the UI actor. Segments bound one synchronous
/// text-layout operation; joining them reproduces `text` byte for byte.
/// Segmenting never reduces how much content can be read or copied.
public struct PreviewText: Equatable, Sendable {
    public let text: String
    public let wasTruncated: Bool
    public let displaySegments: [String]

    internal init(text: String, wasTruncated: Bool, configuration: PreviewTextConfiguration = .init()) {
        let end = configuration.maximumCharacters.flatMap {
            text.index(text.startIndex, offsetBy: $0, limitedBy: text.endIndex)
        } ?? text.endIndex
        self.text = String(text[..<end])
        self.wasTruncated = wasTruncated || end != text.endIndex
        self.displaySegments = Self.segment(self.text, budget: configuration.segmentUTF16Budget)
    }

    private static func segment(_ text: String, budget: Int) -> [String] {
        var segments: [String] = []
        var segment = ""
        var units = 0
        for character in text {
            let count = character.utf16.count
            if count <= budget {
                if units + count > budget {
                    segments.append(segment)
                    segment = ""
                    units = 0
                }
                segment.append(character)
                units += count
            } else {
                // A single extended grapheme can contain arbitrarily many
                // combining marks. Keep ordinary graphemes whole, but split
                // this case at scalar boundaries instead of sending an
                // unbounded shaping operation to the main thread. No scalar
                // is discarded, normalized, or replaced.
                for scalar in character.unicodeScalars {
                    let width = scalar.value > 0xFFFF ? 2 : 1
                    if units + width > budget {
                        segments.append(segment)
                        segment = ""
                        units = 0
                    }
                    segment.unicodeScalars.append(scalar)
                    units += width
                }
            }
        }
        if !segment.isEmpty || segments.isEmpty { segments.append(segment) }
        return segments
    }
}
