/// Pure query-admission boundaries; public pre-I/O behavior is covered by
/// SearchAdmissionBeforeIOTests. Character limits must not become scalar,
/// UTF-16-unit, or byte limits when stopping after the first excess cluster.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct AdmittedSearchRequestTests {
    @Test(arguments: ["e\u{301}", "😀", "👩‍💻"])
    func fuzzyLimitCountsWholeGraphemesAndRejectsAnOverLimitSuffix(character: String) throws {
        let accepted = String(repeating: character, count: 64)
        let admitted = try AdmittedSearchRequest(
            HistoryBrowseRequest(kind: .search(text: accepted, mode: .fuzzy), limit: 10),
            limits: .standard
        )
        #expect(Data(admitted.term.utf8) == Data(accepted.utf8))

        // The longer suffix stays below the separate 4,096-byte envelope,
        // so it exercises fuzzy Character admission rather than byte size.
        for suffix in ["z", "z" + String(repeating: "e\u{301}", count: 1_000)] {
            let rejected = accepted + suffix
            #expect(rejected.utf8.count <= HistoryLimits.standard.maximumSearchTermUTF8Bytes)
            #expect(throws: HistoryFailure.invalidInput(.invalidSearchTerm)) {
                _ = try AdmittedSearchRequest(
                    HistoryBrowseRequest(kind: .search(text: rejected, mode: .fuzzy), limit: 10),
                    limits: .standard
                )
            }
        }
    }

    @Test(arguments: [SearchMode.exact, .regexp])
    func otherModesKeepTheirCompleteQuery(mode: SearchMode) throws {
        let query = String(repeating: "e\u{301}", count: 64) + "😀TAIL"
        let admitted = try AdmittedSearchRequest(
            HistoryBrowseRequest(kind: .search(text: query, mode: mode), limit: 10),
            limits: .standard
        )
        #expect(admitted.mode == mode)
        #expect(Data(admitted.term.utf8) == Data(query.utf8))
    }
}
