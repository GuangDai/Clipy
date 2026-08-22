/// Dispatch-lane progress reporting helpers.
/// Split out of Admission.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryStorage

func admissionProgressElapsedText(_ elapsedMs: Double) -> String {
    String(
        format: "%.3f",
        locale: Locale(identifier: "en_US_POSIX"),
        elapsedMs
    )
}

func admissionProgressLine(
    mode: AdmissionMode,
    event: AdmissionProgressEvent
) -> String {
    let prefix = "HistoryPerfRunner admission progress mode=\(mode.rawValue)"
    switch event {
    case let .preparationPhaseBegan(phase):
        return "\(prefix) phase=\(phase.rawValue) state=begin"
    case let .preparationPhaseCompleted(phase, elapsedMs):
        return "\(prefix) phase=\(phase.rawValue) state=completed "
            + "elapsed_ms=\(admissionProgressElapsedText(elapsedMs))"
    case .validationBegan:
        return "\(prefix) phase=validation state=begin"
    case let .validationCompleted(elapsedMs):
        return "\(prefix) phase=validation state=completed "
            + "elapsed_ms=\(admissionProgressElapsedText(elapsedMs))"
    case let .warmupBegan(index, total):
        return "\(prefix) phase=warmup index=\(index) total=\(total) state=begin"
    case let .warmupCompleted(index, total, elapsedMs):
        return "\(prefix) phase=warmup index=\(index) total=\(total) "
            + "state=completed elapsed_ms=\(admissionProgressElapsedText(elapsedMs))"
    case let .sampleBegan(index, total):
        return "\(prefix) phase=sample index=\(index) total=\(total) state=begin"
    case let .sampleCompleted(index, total, elapsedMs):
        return "\(prefix) phase=sample index=\(index) total=\(total) "
            + "state=completed elapsed_ms=\(admissionProgressElapsedText(elapsedMs))"
    case .diagnosticRequestBegan:
        return "\(prefix) phase=diagnostic-request state=begin"
    case let .diagnosticRequestCompleted(elapsedMs):
        return "\(prefix) phase=diagnostic-request state=completed "
            + "elapsed_ms=\(admissionProgressElapsedText(elapsedMs))"
    }
}

func writeAdmissionProgress(
    mode: AdmissionMode,
    event: AdmissionProgressEvent
) {
    // FileHandle writes immediately even when the runner is piped through tee;
    // a timeout therefore leaves the last entered/completed checkpoint behind.
    try? FileHandle.standardError.write(
        contentsOf: Data("\(admissionProgressLine(mode: mode, event: event))\n".utf8)
    )
}

func measureAdmissionSamples(
    warmups: Int = admissionWarmupCount,
    samples: Int = admissionSampleCount,
    progress: ((AdmissionProgressEvent) -> Void)? = nil,
    operation: () async throws -> Void
) async throws -> [Double] {
    precondition(warmups >= 0)
    precondition(samples > 0)
    let clock = ContinuousClock()
    for index in 0..<warmups {
        progress?(.warmupBegan(index: index + 1, total: warmups))
        let start = clock.now
        try await operation()
        progress?(.warmupCompleted(
            index: index + 1,
            total: warmups,
            elapsedMs: durationToMs(start.duration(to: clock.now))
        ))
        await Task.yield()
    }

    var values: [Double] = []
    values.reserveCapacity(samples)
    for index in 0..<samples {
        progress?(.sampleBegan(index: index + 1, total: samples))
        let start = clock.now
        try await operation()
        let elapsedMs = durationToMs(start.duration(to: clock.now))
        values.append(elapsedMs)
        progress?(.sampleCompleted(
            index: index + 1,
            total: samples,
            elapsedMs: elapsedMs
        ))
        // Yield outside the measured interval so released facades/DTOs get a
        // scheduling opportunity without contaminating operation latency.
        await Task.yield()
    }
    return values
}

func admissionMachineMetadata() -> MachineMetadata {
    let processInfo = ProcessInfo.processInfo
    return MachineMetadata(
        osVersion: processInfo.operatingSystemVersionString,
        architecture: commandOutput("/usr/bin/uname", arguments: ["-m"]),
        hardwareModel: commandOutput(
            "/usr/sbin/sysctl",
            arguments: ["-n", "hw.model"]
        ),
        processorModel: commandOutput(
            "/usr/sbin/sysctl",
            arguments: ["-n", "machdep.cpu.brand_string"]
        ),
        processorCount: processInfo.processorCount,
        physicalMemory: processInfo.physicalMemory
    )
}

func admissionDate() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

func admissionCapture(
    index: Int,
    profile: AdmissionProfile = .full
) -> ClipboardCapture {
    let prefix = Data("admission-row-\(index)-".utf8)
    let suffix = Data("-tail-\(index)".utf8)
    precondition(prefix.count + suffix.count <= profile.searchBodyBytes)

    // ASCII bytes are valid UTF-8 and make the durable search projection hit
    // its full 256 KiB bound. Build one row at a time so fixture preparation
    // retains O(bodyBytes), not O(rows × bodyBytes), in user-invisible setup.
    var body = Data(repeating: 0x78, count: profile.searchBodyBytes)
    body.replaceSubrange(0..<prefix.count, with: prefix)
    body.replaceSubrange(
        (body.count - suffix.count)..<body.count,
        with: suffix
    )
    return ClipboardCapture(
        representations: [CapturedRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: body
        )],
        origin: CopyOriginObservation(
            sourceApplication: "perf-admission",
            lineageHint: nil
        ),
        // One timestamp intentionally forces every recent-page boundary into
        // the UUID-tie exactness lane.
        observedAt: Date(timeIntervalSinceReferenceDate: 650_000_000)
    )
}

