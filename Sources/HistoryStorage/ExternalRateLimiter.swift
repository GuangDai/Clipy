/// ExternalRateLimiter — the in-memory token bucket used by the coarse
/// process-wide External Gateway throttle (V2-05 §8, X-SECURITY-3).

/// A small value owned by the future `ExternalGateway` actor. It does not read
/// a clock itself: the owner supplies process-uptime nanoseconds, keeping this
/// arithmetic deterministic without introducing a clock abstraction.
internal struct ExternalRateLimiter: Sendable {
    private static let capacity: UInt64 = 30
    private static let refillIntervalNanoseconds: UInt64 = 1_000_000_000

    private var availableTokens = Self.capacity
    private var refillAnchorUptimeNanoseconds: UInt64

    internal init(initialUptimeNanoseconds: UInt64) {
        refillAnchorUptimeNanoseconds = initialUptimeNanoseconds
    }

    /// Refills from nonnegative elapsed uptime, then debits exactly one token
    /// when available. Backward readings leave the anchor and balance intact,
    /// so they can delay refill but never grant capacity.
    internal mutating func admit(atUptimeNanoseconds now: UInt64) -> Bool {
        refill(atUptimeNanoseconds: now)
        guard availableTokens > 0 else { return false }
        availableTokens -= 1
        return true
    }

    private mutating func refill(atUptimeNanoseconds now: UInt64) {
        guard now >= refillAnchorUptimeNanoseconds else { return }

        let elapsed = now - refillAnchorUptimeNanoseconds
        let restored = elapsed / Self.refillIntervalNanoseconds
        guard restored > 0 else { return }

        let missing = Self.capacity - availableTokens
        if restored >= missing {
            availableTokens = Self.capacity
            // Capacity discards excess whole-token credit, but the anchor
            // still advances only to the latest whole-token boundary so the
            // sub-second remainder survives the cap.
            refillAnchorUptimeNanoseconds = now
                - (elapsed % Self.refillIntervalNanoseconds)
            return
        }

        // `restored < missing <= capacity`, so this addition cannot wrap.
        availableTokens += restored

        // Advancing by division/multiplication could overflow near UInt64.max.
        // Subtracting the sub-interval remainder yields the same anchor using
        // checked-by-construction arithmetic.
        refillAnchorUptimeNanoseconds = now
            - (elapsed % Self.refillIntervalNanoseconds)
    }
}
