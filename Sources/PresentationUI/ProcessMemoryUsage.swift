/// Immutable whole-process facts from one kernel query. These are neither
/// logical History bytes nor an attribution of memory to a particular cache.
public struct ProcessMemoryUsage: Sendable, Equatable {
    public let residentBytes: Int
    public let peakResidentBytes: Int
    public let footprintBytes: Int

    public init(residentBytes: Int, peakResidentBytes: Int, footprintBytes: Int) {
        self.residentBytes = residentBytes
        self.peakResidentBytes = peakResidentBytes
        self.footprintBytes = footprintBytes
    }
}
