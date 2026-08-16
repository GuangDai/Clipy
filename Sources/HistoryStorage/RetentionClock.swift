/// V2-02 §6.4 — the Storage-side clock seam for the R1 reference time.
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
/// internal init. Production wires `SystemRetentionClock` inside
/// `SwiftDataHistory.open`; tests inject a fixed `Date` via the `@testable`
/// initializer. The v1 public `SwiftDataHistory.open(configuration:)`
/// signature and the frozen `HistoryConfiguration` are untouched — the
/// clock never rides on the public seam.
///
/// Slice boundary (`V2-roadmap` §6): the seam and its init plumbing landed
/// with R.3 per that slice's row ("inject the Storage clock internally");
/// its behavioral consumer is the R.6 policy sweep — the clock read occurs
/// inside the serialized Authority interval before fact load, captured once
/// per commit (§6.4) — in RetentionPolicySweep.swift.
import Foundation

// MARK: - Storage-side clock (V2-02 §6.4)

/// The Storage-side clock witness supplying the R1 sweep lane's reference
/// `now` (`V2-02` §6.4). `Sendable` by inheritance so an injected witness
/// crosses no isolation boundary unsafely.
internal protocol RetentionClock: Sendable {
    /// The wall-clock reference for one serialized Authority interval.
    func now() -> Date
}

/// The production clock witness `SwiftDataHistory.open` wires
/// (`V2-02` §6.4: "production wires `{ Date.now }`"): stateless, so every
/// read is the machine clock at that instant. Constructed and injected at
/// `HistoryAuthority` init — there is no static accessor (the banned
/// service-locator spelling; `01` §8).
internal struct SystemRetentionClock: RetentionClock {
    internal init() {}

    internal func now() -> Date {
        Date.now
    }
}
