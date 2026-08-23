/// V2-02 §6.4 — the Storage-side clock seam for Storage-owned timestamps.
///
/// R1 needs a reference `now`. Capture uses the caller-supplied
/// `observedAt` (`02` §4 `PreparedCapture.observedAt`); the
/// `.setRetentionPolicies` sweep lane carries no caller time, so the
/// Authority reads `now` on the Storage side and passes it to the pure
/// planner as `now: Date` — the Domain mints no `Date()` (`02` §1). This
/// seam is that witness: a `Sendable` clock injected into
/// `HistoryAuthority`'s internal initializer, never a `@Model` field, never
/// a stored mutable on `SwiftDataHistory`, and never a `.shared`/`.current`
/// service locator (`01` §8 gates).
///
/// Injection mechanism (`V2-02` §6.4 "Injection mechanism",
/// `RET-COMPILE-1`; `V2-05` §5.5): production constructs one witness inside
/// `SwiftDataHistory.open` and injects that same value into `HistoryAuthority`
/// and `ExternalGateway`. Tests inject a fixed witness only through internal
/// initializers. This adds no independent or public clock seam: the v1 public
/// `SwiftDataHistory.open(configuration:)` signature and frozen
/// `HistoryConfiguration` remain untouched.
///
/// Slice boundary (`V2-roadmap` §6): the seam and its init plumbing landed
/// with R.3 per that slice's row ("inject the Storage clock internally");
/// later consumers reuse it for the R.6 policy sweep, HCR commit timestamps,
/// Gateway bootstrap/admin/audit timestamps, and X.6 gateway-entry request
/// timestamps. Each operation freezes the value at its owning Storage point;
/// no consumer introduces a second clock seam.
import Foundation

// MARK: - Storage-side clock (V2-02 §6.4 / V2-05 §4.6)

/// The Storage-side clock witness supplying Storage-owned timestamps.
/// `Sendable` by inheritance so an injected witness crosses no isolation
/// boundary unsafely.
internal protocol StorageClock: Sendable {
    /// The wall-clock reference for one Storage-owned operation.
    func now() -> Date
}

/// The production clock witness `SwiftDataHistory.open` wires to both Storage
/// actors: stateless, so every read is the machine clock at that instant.
/// There is no static accessor (the banned service-locator spelling; `01` §8).
internal struct SystemStorageClock: StorageClock {
    internal init() {}

    internal func now() -> Date {
        Date.now
    }
}
