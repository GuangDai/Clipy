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
/// `RET-COMPILE-1`): the parameter exists ONLY on `HistoryAuthority`'s
/// internal init. Production wires `SystemStorageClock` inside
/// `SwiftDataHistory.open`; tests inject a fixed `Date` via the `@testable`
/// initializer. The v1 public `SwiftDataHistory.open(configuration:)`
/// signature and the frozen `HistoryConfiguration` are untouched — the
/// clock never rides on the public seam.
///
/// Slice boundary (`V2-roadmap` §6): the seam and its init plumbing landed
/// with R.3 per that slice's row ("inject the Storage clock internally");
/// its behavioral consumers are the R.6 policy sweep and X.3 Gateway
/// bootstrap. Each reads the clock once at its existing Storage-owned point.
import Foundation

// MARK: - Storage-side clock (V2-02 §6.4 / V2-05 §4.6)

/// The Storage-side clock witness supplying Storage-owned timestamps.
/// `Sendable` by inheritance so an injected witness crosses no isolation
/// boundary unsafely.
internal protocol StorageClock: Sendable {
    /// The wall-clock reference for one Storage-owned operation.
    func now() -> Date
}

/// The production clock witness `SwiftDataHistory.open` wires: stateless, so
/// every read is the machine clock at that instant. Constructed and injected
/// at `HistoryAuthority` init — there is no static accessor (the banned
/// service-locator spelling; `01` §8).
internal struct SystemStorageClock: StorageClock {
    internal init() {}

    internal func now() -> Date {
        Date.now
    }
}
