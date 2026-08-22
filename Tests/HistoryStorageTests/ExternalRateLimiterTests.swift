/// ExternalRateLimiterTests — literal token-bucket proofs for the coarse
/// process-wide External Gateway throttle (V2-05 §8, X-SECURITY-3).
import Testing
@testable import HistoryStorage

struct ExternalRateLimiterTests {
    @Test func thirtyCallsAreAdmittedAndTheThirtyFirstIsDenied() {
        var limiter = ExternalRateLimiter(initialUptimeNanoseconds: 7)

        for _ in 0..<30 {
            let admitted = limiter.admit(atUptimeNanoseconds: 7)
            #expect(admitted)
        }
        let denied = limiter.admit(atUptimeNanoseconds: 7)
        #expect(!denied)
    }

    @Test func oneSecondRestoresExactlyOneToken() {
        var limiter = exhaustedLimiter(initialUptimeNanoseconds: 10)

        let restored = limiter.admit(atUptimeNanoseconds: 1_000_000_010)
        let denied = limiter.admit(atUptimeNanoseconds: 1_000_000_010)
        #expect(restored)
        #expect(!denied)
    }

    @Test func largeElapsedTimeRefillsOnlyToCapacity() {
        var limiter = exhaustedLimiter(initialUptimeNanoseconds: 0)

        let first = limiter.admit(atUptimeNanoseconds: UInt64.max)
        #expect(first)
        for _ in 0..<29 {
            let admitted = limiter.admit(atUptimeNanoseconds: UInt64.max)
            #expect(admitted)
        }
        let denied = limiter.admit(atUptimeNanoseconds: UInt64.max)
        #expect(!denied)
    }

    @Test func capacityRefillPreservesTheFractionalRemainder() {
        var limiter = exhaustedLimiter(initialUptimeNanoseconds: 0)

        let first = limiter.admit(atUptimeNanoseconds: 30_500_000_000)
        #expect(first)
        for _ in 0..<29 {
            let admitted = limiter.admit(
                atUptimeNanoseconds: 30_500_000_000
            )
            #expect(admitted)
        }
        let beforeBoundary = limiter.admit(
            atUptimeNanoseconds: 30_999_999_999
        )
        let atBoundary = limiter.admit(
            atUptimeNanoseconds: 31_000_000_000
        )
        #expect(!beforeBoundary)
        #expect(atBoundary)
    }

    @Test func backwardClockReadingGrantsNoExtraToken() {
        var limiter = exhaustedLimiter(
            initialUptimeNanoseconds: 10_000_000_000
        )

        let backward = limiter.admit(atUptimeNanoseconds: 9_000_000_000)
        let beforeBoundary = limiter.admit(
            atUptimeNanoseconds: 10_999_999_999
        )
        let atBoundary = limiter.admit(
            atUptimeNanoseconds: 11_000_000_000
        )
        #expect(!backward)
        #expect(!beforeBoundary)
        #expect(atBoundary)
    }

    @Test func uptimeValuesNearUInt64BoundsDoNotWrap() {
        var nearMaximum = exhaustedLimiter(
            initialUptimeNanoseconds: UInt64.max - 500_000_000
        )
        let nearMaximumDenied = nearMaximum.admit(
            atUptimeNanoseconds: UInt64.max
        )
        #expect(!nearMaximumDenied)

        var fullRange = exhaustedLimiter(initialUptimeNanoseconds: 0)
        let first = fullRange.admit(atUptimeNanoseconds: UInt64.max)
        let second = fullRange.admit(atUptimeNanoseconds: UInt64.max)
        #expect(first)
        #expect(second)
    }

    private func exhaustedLimiter(
        initialUptimeNanoseconds: UInt64
    ) -> ExternalRateLimiter {
        var limiter = ExternalRateLimiter(
            initialUptimeNanoseconds: initialUptimeNanoseconds
        )
        for _ in 0..<30 {
            _ = limiter.admit(
                atUptimeNanoseconds: initialUptimeNanoseconds
            )
        }
        return limiter
    }
}
