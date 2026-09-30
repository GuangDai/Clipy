import Foundation

/// Read complete, already byte-count-validated UTF-16 code units without
/// allocating a second document-sized array. The byte order is fixed by the
/// caller; content FEFF/FFFE units never become encoding markers.
internal struct PreviewUTF16CodeUnits: Sequence {
    let bytes: Data
    let littleEndian: Bool

    func makeIterator() -> Iterator {
        Iterator(bytes: bytes.makeIterator(), littleEndian: littleEndian)
    }

    struct Iterator: IteratorProtocol {
        var bytes: Data.Iterator
        let littleEndian: Bool

        mutating func next() -> UInt16? {
            guard let first = bytes.next(), let second = bytes.next() else { return nil }
            return littleEndian
                ? UInt16(first) | (UInt16(second) << 8)
                : (UInt16(first) << 8) | UInt16(second)
        }
    }
}
