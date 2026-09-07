/// V2-09 §6: a best-effort hint while publishing new content before SQL BEGIN.
/// Demand accumulates new blob bytes and newly inserted inline bytes; reused
/// blob references add zero. Actual SQLite/file errors remain authoritative.
import Foundation
import HistoryCore

internal enum CaptureCapacityAdmission {
    /// Approximate SQLite/WAL/metadata headroom, not a physical disk quota.
    internal static let marginBytes: Int64 = 1_048_576

    /// The typed refusal for a plan whose external demand exceeds the
    /// volume's spare capacity, or `nil` when the plan must proceed:
    /// no new external bytes, or a readable capacity with room for the
    /// demand plus the margin.
    internal static func failure(
        demandBytes: Int64,
        availableCapacity: Int64?
    ) -> HistoryFailure? {
        guard demandBytes > 0, let availableCapacity else {
            return nil
        }
        guard availableCapacity >= marginBytes,
              availableCapacity - marginBytes >= demandBytes else {
            return .temporarilyUnavailable(.insufficientDiskSpace)
        }
        return nil
    }
}

// MARK: - Test seam (docs/05-authority-kernel.md §16)

extension HistoryAuthority {
    /// Installs (or clears) the fixed spare-capacity witness that overrides
    /// the volume reader for deterministic admission tests. Test seam —
    /// `nil` in production, compiled in always, set via `@testable`; see
    /// `setTransactionFailureInjection` for the failure-forcing sibling
    /// this mirrors. The Release evidence probe runs only the
    /// initializer-injected reader.
    internal func setVolumeAvailableCapacityOverride(_ capacity: Int64?) {
        volumeAvailableCapacityOverride = capacity
    }
}
