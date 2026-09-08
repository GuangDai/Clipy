/// Immutable whole-process facts from one kernel query. These are neither
/// logical History bytes nor an attribution of memory to a particular cache.
struct ProcessMemoryUsage: Sendable, Equatable {
    let residentBytes: Int
    let peakResidentBytes: Int
    let footprintBytes: Int

    init(residentBytes: Int, peakResidentBytes: Int, footprintBytes: Int) {
        self.residentBytes = residentBytes
        self.peakResidentBytes = peakResidentBytes
        self.footprintBytes = footprintBytes
    }
}
