import Foundation

/// Inert text prepared off the UI actor. Segments bound one synchronous
/// text-layout operation; joining them reproduces `text` byte for byte.
/// Segmenting never reduces how much content can be read or copied.
public struct PreviewText: Equatable, Sendable {
    public let text: String
    public let wasTruncated: Bool
    public let displaySegments: [Substring]

    internal init(text: String, wasTruncated: Bool, configuration: PreviewTextConfiguration = .init()) {
        let end = configuration.maximumCharacters.flatMap {
            text.index(text.startIndex, offsetBy: $0, limitedBy: text.endIndex)
        } ?? text.endIndex
        self.text = String(text[..<end])
        self.wasTruncated = wasTruncated || end != text.endIndex
        self.displaySegments = Self.segment(self.text, budget: configuration.segmentUTF16Budget)
    }

    private static func segment(_ text: String, budget: Int) -> [Substring] {
        var segments: [Substring] = []
        var start = text.startIndex
        var index = start
        var units = 0
        while index != text.endIndex {
            let next = text.index(after: index)
            let count = text[index..<next].utf16.count
            if count <= budget {
                if units + count > budget {
                    segments.append(text[start..<index])
                    start = index
                    units = 0
                }
                units += count
            } else {
                // Preserve ordinary graphemes. An arbitrarily long combining
                // sequence is split at scalar boundaries, without dropping or
                // normalizing any bytes. Substrings share the immutable text
                // buffer; only visible segments become native text strings.
                var scalarIndex = index
                while scalarIndex != next {
                    let scalar = text.unicodeScalars[scalarIndex]
                    let width = scalar.value > 0xFFFF ? 2 : 1
                    if units + width > budget {
                        segments.append(text[start..<scalarIndex])
                        start = scalarIndex
                        units = 0
                    }
                    units += width
                    text.unicodeScalars.formIndex(after: &scalarIndex)
                }
            }
            index = next
        }
        if start != text.endIndex || segments.isEmpty {
            segments.append(text[start...])
        }
        return segments
    }
}
