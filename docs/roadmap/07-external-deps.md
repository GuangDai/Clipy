# Module 7 — Dependencies (xxh3 + Fuse)

- **Status:** not-started
- **Spec references:** dependency classification `../01-architecture.md` §2 rows + §4 table; Fuse search behavior `../03b-instruction-set.md` §8; fingerprint evidence `../02-domain.md` §2.2; safety bounds `../06-cross-cutting.md` §2.
- **Dependencies:** external; consumed only inside `HistoryStorage` (xxh3, Fuse) and confined there.
- **Test target:** fixtures live in `HistoryStorageTests` (xxh3 collision double, Fuse result/range fixtures).
- **Step:** 3.

## Deliverables

- **xxh3 — 64-bit content fingerprint:**
  - Create the package-internal C/ObjC++ sibling target at a pinned resolved revision.
  - Provide the package-only deterministic xxh3 collision double for **Storage** tests (HistoryDomain D7 invariant tests at step 2 use a Domain-local mock; the xxh3 double is Storage-only, created at step 3 and first exercised at step 5 in §7.6 forced-collision tests).
- **Fuse — fuzzy matching (`krisk/fuse-swift` 1.4.x):**
  - Pin the exact resolved stable revision (1.4.x; **not** the 2.0.0-rc.x pre-release).
  - Wire it confined to the `SearchWorker` actor (non-`Sendable` Swift 5 class; never crosses isolation).

## xxh3

- **Role:** `ContentFingerprint.rawValue: UInt64` = xxh3-64 over one representation's bytes; a signature entry is derived from a Canonical representation (02 §2.2). Evidence only — never identity, never sufficient for Copy Coalescing (D7).
- **Acceptance:** forced-collision still requires byte-confirmation (Part VI §7.6); the package-only deterministic collision double is permitted in Domain/Storage tests (Part I §4).

## Fuse

- **Role:** threshold-based fuzzy matching **inside `SearchWorker` only** (Part I §4). Non-`Sendable` Swift 5 class, created and held inside the `SearchWorker` actor (01 §6).
- **Pinned behavior:** exact resolved revision; fixtures lock results. Options fixed: `threshold` 0.7, `location` 0, `distance` 100, `isCaseSensitive` false (03b §8).
- **`maxPatternLength` is a dead parameter in 1.4.0** (the option is unread, so the documented "return nil" never fires): the `SearchWorker` enforces the Part VI 256-Character fuzzy-query bound itself, rejecting over-length queries as `invalidInput(.invalidSearchTerm)` before Fuse is called (03b §8; AUDIT §4b).
- **Range translation:** Fuse returns Character offsets into its lowercased working copy; `SearchWorker` translates them to UTF-16 offsets into the original title/excerpt before building `matchedRanges` (03b §8).
- **Acceptance:** fixture tests own Unicode conversion, Fuse option pinning, title-before-body behavior, tie-breakers, and excerpt/range stability (03b §8). *(Unsafe-regexp rejection fixtures belong to the regexp lane in 03b §8 / `SearchWorker`, not to this dependency module.)*

## Acceptance (shared)

- Fixture tests lock xxh3 and Fuse behavior (above).
- xxh3 + Fuse never appear in a public signature (Part I §2, §8); no public search score or cross-actor matcher state crosses out; no `@unchecked Sendable` (Fuse confinement handles Swift 6, Part I §6/§8).

## Risks / notes

- Fuse 1.4.x is the latest **stable** tag (1.4.0); 2.0.0-rc.1 is a pre-release with a different API and is **not** used (AUDIT §4b).
- **Sequencing (roadmap §3 step 3):** under the incremental convention, step 3 pins real revisions and adds the HistoryStorage→Fuse edge. **xxh3 is first used at step 5** (`IngestPreparationActor`, 05 §6.1); **Fuse is first used at step 7** (the full `SearchWorker` for WS17; the step-5 `SearchWorker` is a Fuse-less stub). Step 4 (schema/codecs) imports neither.
