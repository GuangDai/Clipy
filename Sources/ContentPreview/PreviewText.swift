import Foundation

/// Inert text prepared off the UI actor. Segments bound one synchronous
/// text-layout operation; joining them reproduces `text` byte for byte.
/// Segmenting never reduces how much content can be read or copied.
public struct PreviewText: Equatable, Sendable {
    // ContentPreview's text parameters live together here. The retained
    // preview length is the existing history-pane policy. The separate
    // UTF-16 budget is a layout work unit, not a document-length limit:
    // increasing it trades fewer segments for longer main-thread shaping.
    package static let maximumCharacters = 50_000
    package static let segmentUTF16Budget = 1_024

    public let text: String
    public let wasTruncated: Bool
    public let displaySegments: [String]

    internal init(text: String, wasTruncated: Bool) {
        self.text = text
        self.wasTruncated = wasTruncated
        self.displaySegments = Self.segment(text)
    }

    private static func segment(_ text: String) -> [String] {
        var segments: [String] = []
        var segment = ""
        var units = 0
        for character in text {
            let count = character.utf16.count
            if count <= segmentUTF16Budget {
                if units + count > segmentUTF16Budget {
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
                    if units + width > segmentUTF16Budget {
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
