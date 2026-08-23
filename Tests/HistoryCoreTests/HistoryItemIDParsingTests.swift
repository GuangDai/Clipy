/// Public reconstruction of exported history-item identity.
/// Owning spec: docs/03a-instruction-set.md §2.
import HistoryCore
import Testing

@Test func historyItemIDReconstructsCanonicalUUIDStrings() throws {
    let uppercase = try #require(HistoryItemID(
        uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF"
    ))
    let lowercase = try #require(HistoryItemID(
        uuidString: "12345678-90ab-cdef-1234-567890abcdef"
    ))

    #expect(uppercase == lowercase)
    #expect(uppercase.description == "12345678-90AB-CDEF-1234-567890ABCDEF")
}

@Test func historyItemIDRejectsNoncanonicalOrInvalidUUIDStrings() {
    #expect(HistoryItemID(uuidString: "1234567890ABCDEF1234567890ABCDEF") == nil)
    #expect(HistoryItemID(uuidString: "{12345678-90AB-CDEF-1234-567890ABCDEF}") == nil)
    #expect(HistoryItemID(uuidString: " 12345678-90AB-CDEF-1234-567890ABCDEF") == nil)
    #expect(HistoryItemID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEG") == nil)
}
