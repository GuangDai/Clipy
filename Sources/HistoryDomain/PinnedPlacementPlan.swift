/// Constant-size pin-order changes (02 §7/§10, D12). These are semantic
/// ordinal movements, not SQL update ordering or a list of affected IDs.
import HistoryCore

package struct PinOrdinalShift: Sendable, Equatable {
    /// Inclusive ORIGINAL ordinals. The target is never in this interval.
    package let range: ClosedRange<Int>
    /// Exactly +1 or -1 for a planner-produced shift.
    package let delta: Int

    package init(range: ClosedRange<Int>, delta: Int) {
        self.range = range
        self.delta = delta
    }
}

package struct PinRelocation: Sendable, Equatable {
    package let itemID: HistoryItemID
    package let previousOrdinal: PinOrdinal?
    package let destinationOrdinal: PinOrdinal?
    package let pinnedCountBefore: Int
    package let shift: PinOrdinalShift?

    package init(itemID: HistoryItemID, previousOrdinal: PinOrdinal?,
                 destinationOrdinal: PinOrdinal?, pinnedCountBefore: Int,
                 shift: PinOrdinalShift?) {
        self.itemID = itemID
        self.previousOrdinal = previousOrdinal
        self.destinationOrdinal = destinationOrdinal
        self.pinnedCountBefore = pinnedCountBefore
        self.shift = shift
    }
}
