import Foundation
@testable import HistoryStorage

extension HistoryAuthority {
    /// Existing corruption/interleaving tests operate on the actual writer's
    /// database. The isolated parameter makes confinement compiler-visible;
    /// only each assertion's immutable result leaves this actor interval.
    func withTestDatabase<T: Sendable>(
        _ body: @Sendable (isolated HistoryAuthority) throws -> T
    ) rethrows -> T {
        try body(self)
    }
}
