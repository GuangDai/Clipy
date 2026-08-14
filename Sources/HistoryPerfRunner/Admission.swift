/// Manual performance-admission workloads for measurement-gated deferred
/// work (docs/06-cross-cutting.md §9; V1-Verified G2/G5/G8).
///
/// These workloads are intentionally absent from per-push CI. The full
/// dispatch runs the release binary against one 5,000-row persistent corpus,
/// records 101 latency samples plus nearest-rank p50/p95/p99, and wraps each
/// process with macOS `/usr/bin/time -l` for peak-RSS evidence. A separate
/// short, store-free Release A/B can reject matcher experiments before that
/// cost. Results are record-only until an authoritative product budget is
/// admitted; this runner must not invent one from its own observation.
import Foundation
import HistoryCore
import HistoryStorage

struct AdmissionProfile: Sendable, Equatable {
    let retainedRows: Int
    let searchBodyBytes: Int
    let sampleCount: Int
    let warmupCount: Int
    let pageLimit: Int

    static let full = AdmissionProfile(
        retainedRows: 5_000,
        searchBodyBytes: 256 * 1_024,
        sampleCount: 101,
        warmupCount: 1,
        pageLimit: 50
    )

    /// Crosses the exact platform failure interval observed after the 750-row
    /// marker and before 1,000, with identical per-row storage pressure.
    static let prepareSmoke = AdmissionProfile(
        retainedRows: 1_000,
        searchBodyBytes: 256 * 1_024,
        sampleCount: 0,
        warmupCount: 0,
        pageLimit: 50
    )
}

let admissionProfile = AdmissionProfile.full
let admissionRetainedRows = admissionProfile.retainedRows
let admissionSearchBodyBytes = admissionProfile.searchBodyBytes
let admissionSampleCount = admissionProfile.sampleCount
let admissionWarmupCount = admissionProfile.warmupCount
let admissionPageLimit = admissionProfile.pageLimit

enum AdmissionMode: String, Sendable, Equatable {
    case seed
    case seedSmoke = "seed-smoke"
    case prepare
    case prepareSmoke = "prepare-smoke"
    case browseTies = "browse-ties"
    case exactSearch = "exact-search"
    case exactMatcherAB = "exact-matcher-ab"
    case exactSearchProbe = "exact-search-probe"
    case openOnce = "open-once"
    case openOnceAndValidate = "open-once-and-validate"
    case warmOpen = "warm-open"

    var createsStore: Bool {
        switch self {
        case .seed, .seedSmoke:
            return true
        case .prepare, .prepareSmoke, .browseTies, .exactSearch,
             .exactMatcherAB,
             .exactSearchProbe,
             .openOnce, .openOnceAndValidate, .warmOpen:
            return false
        }
    }

    var profile: AdmissionProfile {
        switch self {
        case .seedSmoke, .prepareSmoke:
            return .prepareSmoke
        case .seed, .prepare, .browseTies, .exactSearch, .exactMatcherAB,
             .exactSearchProbe,
             .openOnce,
             .openOnceAndValidate, .warmOpen:
            return .full
        }
    }

    var expectedSeedMode: AdmissionMode? {
        switch self {
        case .prepare:
            return .seed
        case .prepareSmoke:
            return .seedSmoke
        case .seed, .seedSmoke, .browseTies, .exactSearch, .exactMatcherAB,
             .exactSearchProbe,
             .openOnce,
             .openOnceAndValidate, .warmOpen:
            return nil
        }
    }

    var isSetupFixture: Bool {
        self == .prepare || self == .prepareSmoke
    }
}

enum AdmissionError: Error, Sendable, Equatable {
    case storeAlreadyExists
    case storeMissing
    case unexpectedSeedFixture
    case unexpectedPage
    case unexpectedPosition
    case diagnosticConfigurationMissing
    case exactMatcherMismatch
    case invalidExactMatcherMeasurement
}

func runAdmission(arguments: [String]) async -> Int {
    guard let rawMode = arguments.first,
          let mode = AdmissionMode(rawValue: rawMode) else {
        print("HistoryPerfRunner admission: invalid arguments")
        return 2
    }
    guard arguments.count == (mode == .warmOpen ? 4 : 3) else {
        print("HistoryPerfRunner admission: invalid arguments")
        return 2
    }

    do {
        let storeURL = URL(fileURLWithPath: arguments[1])
        if mode != .exactMatcherAB {
            let storeExists = FileManager.default.fileExists(atPath: storeURL.path)
            if mode.createsStore, storeExists {
                throw AdmissionError.storeAlreadyExists
            }
            if !mode.createsStore, !storeExists {
                throw AdmissionError.storeMissing
            }
        }
        print("HistoryPerfRunner admission: starting \(mode.rawValue)")
        switch mode {
        case .seed, .seedSmoke:
            try await seedAdmissionStore(
                storeURL: storeURL,
                outputPath: arguments[2],
                mode: mode,
                profile: mode.profile
            )
        case .prepare, .prepareSmoke:
            try await prepareAdmissionStore(
                storeURL: storeURL,
                outputPath: arguments[2],
                mode: mode,
                profile: mode.profile
            )
        case .browseTies:
            try await measureAdmissionBrowseTies(
                storeURL: storeURL,
                outputPath: arguments[2]
            )
        case .exactSearch:
            try await measureAdmissionExactSearch(
                storeURL: storeURL,
                outputPath: arguments[2]
            )
        case .exactMatcherAB:
            try measureAdmissionExactMatcherAB(outputPath: arguments[2])
        case .exactSearchProbe:
            try await measureAdmissionExactSearchProbe(
                storeURL: storeURL,
                outputPath: arguments[2]
            )
        case .openOnce:
            try await measureAdmissionOpenOnce(
                storeURL: storeURL,
                outputPath: arguments[2],
                validateCorpus: false
            )
        case .openOnceAndValidate:
            try await measureAdmissionOpenOnce(
                storeURL: storeURL,
                outputPath: arguments[2],
                validateCorpus: true
            )
        case .warmOpen:
            try await summarizeAdmissionWarmOpen(
                samplesDirectoryURL: URL(fileURLWithPath: arguments[2]),
                outputPath: arguments[3]
            )
        }
        print("HistoryPerfRunner admission: completed \(mode.rawValue)")
        return 0
    } catch {
        print("HistoryPerfRunner admission: failed \(mode.rawValue): \(error)")
        return 1
    }
}
