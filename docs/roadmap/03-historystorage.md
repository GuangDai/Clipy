# Module 3 — HistoryStorage

- **Status:** in-progress (sub-steps 4–5 done, 6–8 not-started — see Sub-steps and Progress below)
- **Spec references:** coherence `../04-coherence.md` §1–§12 (Part IV); commit kernel `../05-authority-kernel.md` §1–§18 (Part V); adapter + config `../05-authority-kernel.md` §2.
- **Dependencies:** `HistoryCore`, `HistoryDomain`, `xxh3`, `Fuse`; frameworks `SwiftData` (sole importer), `ImageIO` (thumbnail decode). Never imports AppKit/SwiftUI or an adapter.
- **Test target:** `HistoryStorageTests` (in-memory semantic tests + persistent temp-store durability tests; also owns Module 7's xxh3 collision + Fuse fixture tests).
- **Steps:** 4–8 (sub-steps below).

HistoryStorage is built across roadmap steps 4–8 (one sub-section each).

## Deliverables (from spec "Owns")

- **Public adapter:** `SwiftDataHistory: ClipboardHistory, Sendable` (5 actor fields — Part V §2); `HistoryConfiguration`, `HistoryPersistence`, `open(configuration:)`.
- **Actors (all `Sendable`):** `HistoryAuthority` (sole writer + snapshot/observer serialization), `IngestPreparationActor`, `RevisionPreparationActor`, `SearchWorker` (confines non-Sendable Fuse), `ThumbnailService` (owns the flight table) + `ThumbnailWorker` (owned by ThumbnailService).
- **Schema v1:** `HistoryItemRow`, `LastChangePositionRow`, `v1Schema = Schema(...)`; `@Attribute(.externalStorage)` on the two big blobs (Part V §3).
- **Versioned codecs:** `CanonicalBlobV1`, `RevisionStateBlobV1`, `SignatureBlobV1`, `EffectiveTypeIdentifiersBlobV1` (+ `Stored*` members); exhaustive decode checks (Part V §4).
- **Context confinement:** fresh `ModelContext(container)` per isolated op; no `await` in commit/read intervals; manual context (not the main-actor SwiftUI-env context) (Part V §5; the manual-context rule `@ModelActor` would replace — 01 §6).
- **Preparation:** `PreparedCaptureBundle`/`ContentProjection` and `PreparedRevisionBundle`; `RevisionPreparationSnapshot` + two-phase OCC-safe revision prep (Part V §6).
- **Complete fact loading:** per-action loaders with proved completeness (Part V §7).
- **Closed dispatch:** exhaustive `perform` switch (Part V §8).
- **Stamped commit plan:** `StampedMutation`, `StoredNewItem`, `StoredRevisionUpdate`, `SignatureIndexDelta`, `StampedCommitPlan`; the Domain→Stamped rename table (Part V §9).
- **Atomic transaction:** `ModelContext.transaction` as the sole commit primitive; closure-success = save boundary, no trailing `save()` (Part V §10).
- **Post-commit:** Signature Index delta + invalidation + receipt, no suspension (Part V §11).
- **Signature Index:** `State.unready` / `.ready(generation:)`; lifecycle + startup rebuild (Part V §12, §13).
- **Reads:** recent/search browse (`SearchCorpusSnapshot`/`SearchCorpusRow`), detail/paste, observation registration, thumbnail source (Part V §14).
- **Projection:** `ContentProjector` (title/searchBody/effectiveTypeIdentifiers) (Part V §15).
- **Failure translation** at the boundary (Part V §16).
- **Test infrastructure (roadmap-owned, not in spec):** a deterministic concurrency harness + a transaction-injection seam inside `HistoryAuthority`'s transaction closure — required to run WS12 (observation race), WS13 (transaction failure), WS15 (thumbnail version fence), WS20 (concurrent revision+coalesce). Scaffolded at step 0, finished at step 5.

## Sub-steps (roadmap §3 steps 4–8)

- **Step 4 — schema + codecs** — **done** ([`39038b3`](https://github.com/GuangDai/Clipy/commit/39038b3334c2b822352d229539b85edd9d36b209) + fixes [`f0b0651`](https://github.com/GuangDai/Clipy/commit/f0b06518177a59462ebc331ac165f6f1148f4d55)/[`8b5ce2f`](https://github.com/GuangDai/Clipy/commit/8b5ce2ff0c02ccda76efaf8c3db489684797a9e7)/[`6ba9cd3`](https://github.com/GuangDai/Clipy/commit/6ba9cd33e11d4b3fb53c2ec0f58b631748959297)/[`52a7bb0`](https://github.com/GuangDai/Clipy/commit/52a7bb0f91a71003fc1e14838a15800302601424); CI [`4d0693b`](https://github.com/GuangDai/Clipy/commit/4d0693b49258b65fdaa3eef20e3d309a96c4f57d)) (`HistoryItemRow`, `LastChangePositionRow`, `v1Schema`, all V1 codecs). Gates: none yet; proofs §7.3 (codec round trip), §7.4 (corruption rejection) — **green** at run [29964640300](https://github.com/GuangDai/Clipy/actions/runs/29964640300).
- **Step 5 — Authority + capture** — **done** (impl [`66a8b14`](https://github.com/GuangDai/Clipy/commit/66a8b1422d7fb08a35c7b7db2b9882b37661aca7) + fixes [`81dbba9`](https://github.com/GuangDai/Clipy/commit/81dbba91244f6d4cfc462b4f22b1b66304a2db4f)/[`11bc1f7`](https://github.com/GuangDai/Clipy/commit/11bc1f70ddc449432e899aa90c0f98bcd1cff7fe); gates [`51962db`](https://github.com/GuangDai/Clipy/commit/51962dbd884d90ff5cd98503f6438ce3e94863e3) + fixes [`bb1bced`](https://github.com/GuangDai/Clipy/commit/bb1bced65c28a5bff2b6239c525bf8622b8f8b4b)/[`7994844`](https://github.com/GuangDai/Clipy/commit/7994844e23ec2df1bdf0cfc52a5d053889f5947a)) (open, position singleton, Signature Index rebuild, capture insert/coalesce, **+ finish the concurrency harness & transaction-injection seam**). Gates: WS1–WS3, WS5, WS19 — **green**; proofs §7.1 (transaction boundary), §7.6 (forced collision) — **green** at run [29964640300](https://github.com/GuangDai/Clipy/actions/runs/29964640300). *(At step 5, `RevisionPreparationActor`, `SearchWorker`, and `ThumbnailService` are compiled as stub actors — `SwiftDataHistory.open` constructs all five facade fields, and a stub `actor` is still `Sendable`, so `SwiftDataHistory: Sendable` is derivable — with full implementations landing at steps 6–8. The `SearchWorker` stub has no Fuse field yet; Fuse is added inside it at step 7.)*
- **Step 6 — mutations** — not-started (pin, revision, remove/clear, retention). Gates: WS6–WS10, WS13, WS14, WS16, WS20, WS21.
- **Step 7 — reads + observation** — not-started. Gates: WS4, WS11, WS12, WS17, WS18; proofs §7.2 (fresh-context visibility), §7.5 (scalar read isolation). *(Closes the deferred public-read / observation / no-emission clauses of WS1, WS2, WS5, WS6, WS7, WS8, WS9, WS10, WS13, WS14, WS16, WS19, WS21.)*
- **Step 8 — thumbnail single-flight** — not-started. Gate: WS15.

## Acceptance

- **WS1–WS21** through real `SwiftDataHistory` (in-memory for semantic tests, persistent temp store for durability), grouped by step:
  - capture/coalesce (step 5): WS1–WS3, WS5, WS19;
  - mutations (step 6): WS6–WS10, WS13, WS14, WS16, WS20, WS21;
  - reads/observation (step 7): WS4 (lineage-hint paste-payload — read side, not capture), WS11, WS12, WS17, WS18;
  - thumbnail (step 8): WS15.
  *(Per README §3 WS-clause phasing: steps 5–6 close the commit/storage side; public-read/observation/no-emission clauses of WS1, WS2, WS5, WS6, WS7, WS8, WS9, WS10, WS13, WS14, WS16, WS19, WS21 defer to step 7; the full suite re-runs end-to-end at 9b.)*
- **Part VI §7 platform proofs** (phased by step): §7.3/§7.4 (step 4); §7.1/§7.6 (step 5); §7.2/§7.5 (step 7); §7.7/§7.8 (scan + deployment-target configured at step 0, proven incrementally as HistoryStorage code lands steps 5–8, fully closed by step 8).
- **Part VI §9 performance proofs** — all 9 bullets (see ../06-cross-cutting.md §9; measured incrementally — capture/candidate/index at step 5, pin/retention at step 6, browse/search/detail at step 7, thumbnail at step 8; §9 closes as a group at step 8 on the release-like runner): capture commit interval excludes pasteboard/fingerprint/projection/decode; candidate work ∝ incoming bytes; index rebuild O(signature metadata) ≤ 5,000 items; pin reorder O(pinned); retention/clear O(retained scalar); recent browse ≤ `limit+1` scalar rows; search may scan all bounded projections; detail/paste decode one item; thumbnail one bounded source fetch + one shared decode.
- **Fact-loader completeness:** each action's fact loader is shown to load every fact the corresponding Domain planner reads (Part V §7); a deliberate fact-omission is caught at the **Storage fact-loading boundary** as `.temporarilyUnavailable(.factProof)` (02 §5.1) before planning, never by a silent default.
- **Failure-producer test homes:** producers without a dedicated WS path — `.factProof`, `.revisionNotFound`, `.invalidRetentionPolicy` (at `open`), `.persistence(.openStore/.corruptStoredValue/.invariantViolation)` — are covered by §7.4 corruption rejection + the failure-translation unit tests (not by a WS path).
- **Import confinement (Part VI §6):** `import SwiftData` appears only in this target; `ImageIO` only here; no AppKit/SwiftUI/HistoryDomain-leak; no `@unchecked Sendable` / `nonisolated(unsafe)` / service locator / second writer.

## Risks / notes (open proof gates — BLOCKERS unless proven)

- **§7.1 transaction boundary — BLOCKER, no fallback:** if `ModelContext.transaction` closure-failure does NOT commit-nothing, the Part V §10 atomicity model and WS10/WS13 are invalid with no recovery primitive (the kernel calls no compensating `rollback()`). Failure requires design revision. Confirm first on the supported runtime.
- **§7.2 fresh-context visibility — BLOCKER, no fallback:** a newly created serialized read context must see a just-committed transaction without notification/refresh; if not, WS11 (read-after-write) is unprovable. Must be confirmed on the runner.
- **§7.5 scalar read isolation:** if `FetchDescriptor.propertiesToFetch` cannot be proven to avoid faulting the external-storage blobs, the performance claim is dropped and an alternative projection schema is designed — correctness tests still pass. Failure triggers a projection-schema redesign task (06 §7.5) — conditional work outside the M2 critical path. Not a correctness blocker.
- **Concurrency harness prerequisite (delivered step 5):** WS12/WS13/WS15/WS20 require the deterministic concurrency harness + (for WS13) the transaction-injection seam; neither is designed in the spec — both are roadmap-owned test infrastructure, scaffolded at step 0 and finished at step 5 so the gates are runnable.
- **§9 performance runner:** Part VI §9 proofs require a release-like runner with recorded fixtures + machine metadata (06 §9); neither is designed in the spec — must be provisioned before §9 can close.
- **Swift 6 compilability of manual-`ModelContext`-on-a-plain-actor** (Part VI §6): `@ModelActor` is a documented fallback that would not change the public surface (01 §6, 05 §5).
- xxh3 collisions are handled by mandatory byte-confirmation (D7); the index may gain a spurious candidate but never a false confirmed match.

## Progress

- **Step 4 — schema + codecs: done.** Schema v1 + all V1 codecs landed at [`39038b3`](https://github.com/GuangDai/Clipy/commit/39038b3334c2b822352d229539b85edd9d36b209) (05 §3–§4); fixes [`f0b0651`](https://github.com/GuangDai/Clipy/commit/f0b06518177a59462ebc331ac165f6f1148f4d55) (missing `import Foundation`), [`8b5ce2f`](https://github.com/GuangDai/Clipy/commit/8b5ce2ff0c02ccda76efaf8c3db489684797a9e7)/[`6ba9cd3`](https://github.com/GuangDai/Clipy/commit/6ba9cd33e11d4b3fb53c2ec0f58b631748959297)/[`52a7bb0`](https://github.com/GuangDai/Clipy/commit/52a7bb0f91a71003fc1e14838a15800302601424) (codec-test suite-struct symbols); CI log-scan noise exclusion [`4d0693b`](https://github.com/GuangDai/Clipy/commit/4d0693b49258b65fdaa3eef20e3d309a96c4f57d). Proofs §7.3 (codec round trip) + §7.4 (corruption rejection) green on the macos-26 runner.
- **Step 5 — Authority + capture: done.** Implementation [`66a8b14`](https://github.com/GuangDai/Clipy/commit/66a8b1422d7fb08a35c7b7db2b9882b37661aca7) (05 §2, §5–§13) + fixes [`81dbba9`](https://github.com/GuangDai/Clipy/commit/81dbba91244f6d4cfc462b4f22b1b66304a2db4f) (`SignatureIndex` `Self.` qualification), [`11bc1f7`](https://github.com/GuangDai/Clipy/commit/11bc1f70ddc449432e899aa90c0f98bcd1cff7fe) (`@escaping` harness closures); WS gates + proofs [`51962db`](https://github.com/GuangDai/Clipy/commit/51962dbd884d90ff5cd98503f6438ce3e94863e3) (WS1–WS3/WS5/WS19 + §7.1/§7.6) + fixes [`bb1bced`](https://github.com/GuangDai/Clipy/commit/bb1bced65c28a5bff2b6239c525bf8622b8f8b4b) (WS temp-store dirs upfront), [`7994844`](https://github.com/GuangDai/Clipy/commit/7994844e23ec2df1bdf0cfc52a5d053889f5947a) (WS5 `.dedupIndexRebuild` reachability — readiness resolution before inventory). Gates WS1–WS3, WS5, WS19 and proofs §7.1 (transaction boundary), §7.6 (forced collision) all green at run [29964640300](https://github.com/GuangDai/Clipy/actions/runs/29964640300) (HEAD `7994844`, all 3 CI jobs). The concurrency harness + transaction-injection seam are delivered; `RevisionPreparationActor`/`SearchWorker`/`ThumbnailService` remain stubs per the step-5 note above.
- **Steps 6–8: not-started.** WS6–WS21 gates, proofs §7.2/§7.5 (step 7), and the §9 performance proofs remain open.
