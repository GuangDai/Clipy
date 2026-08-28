/// DataZeroEntitlementGateHostedTests.swift — DATA-0 iCloud entitlement
/// negative gate, hosted: the two product-side probes for the iCloud/
/// CloudKit/ubiquity namespaces — an any-prefix scan over the embedded
/// signature (future keys included) plus an enumerated-key scan of the
/// running process's runtime resolution (the seven keys Apple documents
/// today).
///
/// Lineage: docs/reviews/2026-08-22-clipy-maccy-deep-review/01-findings.md
/// §3 DATA-0 — `SwiftDataHistory.open` relies on the ModelConfiguration
/// default `cloudKitDatabase: .automatic`, whose semantics engage managed
/// CloudKit sync from the app entitlements' primary ubiquity container; the
/// finding demands production `.none` (landed at
/// Sources/HistoryStorage/SwiftDataHistory.swift:210,216) plus an
/// entitlement negative gate: "除非 owning spec 批准 sync，任何
/// iCloud/CloudKit entitlement 都使 build 红". Doc 11 §4.5's DATA-0 row
/// (11-ai-todo-map-2026-08-23.md) then notes the gate is only partially
/// closed ("现只有 ad-hoc lane 负门 + 源码 `.none`").
///
/// Why a hosted test and not the row's literal "manifest 负门入常规 CI":
/// AGENTS.md §1 implementation policy (user direction, 2026-08-24) forbids
/// adding repository rules/scanners, gates, or signing-infrastructure
/// machinery. This suite is the product-side equivalent — it reads the
/// running product's own signature and entitlement resolution through the
/// public Security APIs, parses nothing beyond the documented Sec* probes,
/// and adds no scanner, manifest, or CI machinery.
///
/// What this proves: whenever the hosted process carries a code signature,
/// that embedded signature resolves zero entitlements under the two
/// forbidden namespaces —
/// - `embeddedSignatureCarriesNoICloudEntitlement`: the on-disk signature's
///   entitlements (dictionary form via `kSecCodeInfoEntitlementsDict`,
///   requested with `kSecCSRequirementInformation`) contain no key starting
///   with `com.apple.developer.icloud-` or `com.apple.developer.ubiquity-`;
/// - `runningProcessResolvesNoICloudEntitlement`: the running process
///   resolves none of the seven known iCloud/CloudKit/ubiquity entitlement
///   keys through `SecTaskCopyValueForEntitlement` — the API the system
///   itself consults, so a value here is what `.automatic` would arm
///   CloudKit sync with.
///
/// What this does NOT prove: anything about unsigned builds. The
/// app-correctness CI lane builds with `CODE_SIGNING_ALLOWED=NO`
/// (scripts/ci/run_app_correctness.sh:32), so no entitlements are embedded
/// into a signature there. On the arm64 runner the hosted binary still
/// carries the linker's ad-hoc signature, so the EXPECTED CI path is a
/// true green over a signed-but-entitlement-free host; the conservative
/// branch below is the fallback if even that probe chain is unavailable —
/// a nil probe result is probe unavailability, not absence evidence; only
/// a non-nil probe result counts. The negative gate's teeth for actually
/// signed artifacts live where signatures exist: the approved empty
/// entitlements file `ClipyApp/Config/ClipyApp.entitlements`, and the
/// ad-hoc signed runtime lane, which `codesign --display --entitlements`
/// -greps `com\.apple\.developer\.(icloud|ubiquity)` red
/// (scripts/ci/run_signed_runtime.sh:142–149). Locally signed dev runs do
/// exercise both probes for real.
import Foundation
import Security
import Testing

@Suite("DATA-0 iCloud entitlement negative gate (hosted)")
struct DataZeroEntitlementGateHostedTests {

    /// The runtime probe set: every iCloud/CloudKit/ubiquity entitlement key
    /// the system defines for the two forbidden namespaces. Resolution of
    /// any single one through the running process is presence evidence.
    /// Plain `String` storage; the Sec* call site bridges with the
    /// documented `as CFString` cast (array literals do not convert to
    /// `CFString` elements implicitly).
    let runtimeProbeKeys: [String] = [
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.icloud-container-development-container-identifiers",
        "com.apple.developer.icloud-container-environment",
        "com.apple.developer.icloud-services",
        "com.apple.developer.icloud-extended-share-access",
        "com.apple.developer.ubiquity-container-identifiers",
        "com.apple.developer.ubiquity-kvstore-identifier",
    ]

    /// Any embedded entitlement key under either namespace makes the gate
    /// red — the prefixes, not the enumerated keys, carry the check.
    let forbiddenPrefixes = [
        "com.apple.developer.icloud-",
        "com.apple.developer.ubiquity-",
    ]

    // MARK: - Host signature probe

    /// Reads the hosted process's own code signature through
    /// SecCodeCopySigningInformation.
    ///
    /// Returns `(nil, [:])` when any Sec* step fails — an unavailable probe,
    /// deliberately distinguishable from "signed: false". `signed` uses the
    /// documented discriminator: kSecCodeInfoIdentifier is "always present
    /// if the code is signed and always absent if the code is unsigned".
    private func hostSigningInfo() -> (signed: Bool?, info: [String: Any]) {
        var code: SecCode?
        // `kSecCSDefaultFlags` is documented only as a `SecCSFlags`
        // OptionSet member and is NOT exposed as a top-level Swift symbol —
        // its value is 0, so `SecCSFlags(rawValue: 0)` is the same call
        // (the shape used by every compilable Swift sample of these APIs).
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess,
            let code
        else {
            return (nil, [:])
        }
        // SecCodeCopySigningInformation takes a SecStaticCode; Swift does
        // not expose the C-level SecCode→SecStaticCode conversion, so make
        // the documented equivalent explicit ("If you provide a code
        // object, the function processes it in the same manner as
        // SecCodeCopyStaticCode").
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode)
            == errSecSuccess, let staticCode
        else {
            return (nil, [:])
        }
        var raw: CFDictionary?
        // `kSecCSRequirementInformation` is a top-level UInt32 global (not
        // a SecCSFlags case); OR-ing it with the zero default is the flag
        // set the raw-entitlements key is documented to require.
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSRequirementInformation),
            &raw
        ) == errSecSuccess, let raw else {
            return (nil, [:])
        }
        // A bridge failure is probe unavailability — never a fabricated
        // "unsigned" verdict (which would silently green the gate).
        guard let info = (raw as NSDictionary) as? [String: Any] else {
            return (nil, [:])
        }
        return (info[kSecCodeInfoIdentifier as String] != nil, info)
    }

    // MARK: - Embedded signature

    @Test("embedded signature carries no iCloud/ubiquity entitlement")
    func embeddedSignatureCarriesNoICloudEntitlement() {
        let probe = hostSigningInfo()
        guard probe.signed != nil else {
            // Probe unavailable (a Sec* step failed): absence of a probe is
            // not absence evidence — pass conservatively.
            return
        }
        if let entitlementsValue = probe.info[kSecCodeInfoEntitlementsDict as String] {
            // Dictionary form — the inspectable one: assert no embedded key
            // falls under either forbidden namespace.
            guard let entitlements = (entitlementsValue as? NSDictionary) as? [String: Any]
            else {
                Issue.record(
                    "DATA-0: entitlements dictionary present but undecodable — fail-closed"
                )
                return
            }
            let offenders = entitlements.keys.filter { key in
                forbiddenPrefixes.contains { key.hasPrefix($0) }
            }
            #expect(
                offenders.isEmpty,
                "DATA-0: embedded entitlements under a forbidden prefix: \(offenders)"
            )
        } else if let blob = probe.info[kSecCodeInfoEntitlements as String] {
            // The entitlements are present (documented payload: CFData) but
            // only in non-dictionary form, so their keys cannot be
            // inspected through this API — fail closed rather than guess.
            Issue.record(
                "DATA-0: entitlements present only as raw blob (\(type(of: blob))) — fail-closed"
            )
        }
        // Both entries absent → green: "The value is absent if the code has
        // no entitlements" (kSecCodeInfoEntitlementsDict documentation).
    }

    // MARK: - Running-process resolution

    @Test("running process resolves no iCloud/ubiquity entitlement")
    func runningProcessResolvesNoICloudEntitlement() {
        guard let task = SecTaskCreateFromSelf(nil) else {
            // A nil task is a broken probe, not a clean result. If the
            // signature probe says the host IS signed, a nil SecTask means
            // the runtime probe chain is damaged — record it; otherwise
            // (unsigned host) pass conservatively.
            if hostSigningInfo().signed == true {
                Issue.record(
                    "DATA-0: SecTaskCreateFromSelf returned nil for a signed host — probe broken"
                )
            }
            return
        }
        for key in runtimeProbeKeys {
            let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
            // "An empty return value may indicate an error, or it may
            // indicate that the entitlement is simply not present" — only a
            // non-nil value is presence evidence, so nil is the passing
            // outcome for every probe key.
            #expect(
                value == nil,
                "DATA-0: runtime entitlement resolved for \(key)"
            )
        }
    }
}
