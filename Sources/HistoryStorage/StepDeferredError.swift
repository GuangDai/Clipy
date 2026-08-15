/// StepDeferredError — the internal marker thrown by not-yet-implemented
/// roadmap paths. Reintroduced (it previously scaffolded v1 storage steps
/// 6–8 and was removed when they landed) for the V2-02 slices: the R.1
/// enum-case additions keep every closed Core switch compiler-exhaustive
/// (`RET-COMPILE-2`, `V2-02` §8.2) while the capture/revise expansion
/// composition (R.4/R.5) and the `.setRetentionPolicies` commit (R.6)
/// remain unimplemented (`V2-roadmap` §6).
///
/// It is NOT a `HistoryFailure`, is never translated into one, and
/// propagates through the `SwiftDataHistory` facade unchanged so a caller
/// hitting a not-yet-implemented path sees a distinct programmer-visible
/// failure rather than a misclassified public one. It is removed as the
/// owning slices land.
internal enum StepDeferredError: Error, Sendable {
    /// The named operation is implemented at a later roadmap slice. The name
    /// is diagnostic-only — nothing branches on it.
    case notYetImplemented(operation: String)
}
