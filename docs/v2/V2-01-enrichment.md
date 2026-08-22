# V2-01 - Enrichment Pipeline (E1 OCR derivation + S1 source fingerprints)

> **Status (2026-07-23):** V2 design-consolidated, scaffold proof pending. This
> doc extends the v1 specification (`00`–`06`); it redefines no v1 public type,
> `HistoryAction` case, schema column, codec, invariant (D1–D19, `02` §14), or
> proof gate. v1 behavior is owned by `00`–`06`. V2-01 owns only new surface and
> the graft of E1 (Enrichment / OCR + enrichment search corpus) and S1
> (per-purpose content source fingerprints) onto the v1 architecture. It is admitted
> only after v1 reaches executable specification (Part VI state 2) and after its
> evidence triggers fire (`V2-00` §3). Like v1 at consolidation time, V2-01 is
> "design-consolidated, scaffold proof pending."

## 1. Role and boundary

V2-01 answers one question:

> *After a History Commit retains image or PDF content, how is searchable text
> derived from that content off the commit interval and grafted onto the v1
> search/read architecture without weakening a single v1 load-bearing decision
> or invariant?*

Enrichment is a **derivation**, not a History Action. It produces derived text
indexed off Canonical/Effective Content; it never overwrites Canonical Content,
never mints or advances `ContentVersion` or `ChangePosition`, and never
participates in dedup identity (`V2-00` §5 decision 13). It branches off the
canonical/commit path as a side pipeline (`V2-00` §6.1) and writes a durable
enrichment index through the single `HistoryAuthority` writer.

V2-01 owns:

- the enrichment data model (a new V2 `EnrichmentRow` table and versioned
  `EnrichmentBlobV1` codec, internal to `HistoryStorage`);
- the enrichment pipeline (source fetch via the Authority, OCR/PDF-text
  extraction on an `EnrichmentWorker` actor, durable persist via the
  Authority);
- S1 per-purpose source fingerprints (the per-purpose fingerprint that prevents
  re-derivation when `ContentVersion` advances but the enrichment source bytes
  are unchanged);
- the capability-gated extension of the v1 search corpus with enrichment
  text;
- a new `EnrichmentHistory` protocol and `EnrichmentStatus` DTO in
  `HistoryCore`;
- the six graft-admission records (`V2-00` §4), V2 proof gates, migration
  impact, and new invariants D20–D22.

V2-01 owns no `HistoryAction` case, no `HistoryMutation` case, no Domain
planner, and no change to the closed `ClipboardHistory` protocol. The Domain
(`HistoryDomain`) is untouched by enrichment: it remains pure, Foundation-only,
and unaware that derivations exist.

## 2. Capability scope

### 2.1 In scope (E1)

- Deriving searchable text from a retained item's eligible image and/or PDF
  representation(s) in **Effective Content**:
  - image types (`public.png`, `public.jpeg`, `public.tiff`,
    `com.compuserve.gif`, and other ImageIO-decodable image UTIs): on-device
    Vision OCR via `VNRecognizeTextRequest` (`V2-facts.md` fact 1, 6);
  - PDF type (`com.adobe.pdf`): PDFKit text-layer extraction via
    `PDFDocument`/`PDFPage.string` (`V2-facts.md` fact 8, 9).
- Persisting the derived text in a durable, version-fenced enrichment index.
- Extending the internal search corpus with enrichment text **only when
  enrichment is enabled** (capability gate); with enrichment disabled, search is
  byte-for-byte v1.
- Exposing per-item enrichment status to callers via a new
  `EnrichmentHistory` protocol.

### 2.2 Out of scope (remains post-V2)

- **Scanned-PDF / image-only-PDF OCR.** When `PDFPage.string` is `nil`/empty
  (no text layer), V2-01 records empty enrichment text; it does not render PDF
  pages and OCR them. That is a future graft (`V2-facts.md` OPEN questions
  item 4).
- **PDF text-layer quality is best-effort.** `PDFPage.string` can return non-empty
  mojibake for PDFs whose embedded fonts lack a ToUnicode CMap (common for
  scanned-then-OCR'd or poorly-generated PDFs). V2-01 does not validate text-layer
  quality; such garbage is normalized, bounded, and indexed as enrichment text,
  producing wrong-but-safe search matches (a user searching "invoice" may match
  garbage). This is an accepted limitation (garbage-in-garbage-out, bounded by the
  256 KiB text bound, degrades to a wrong search match - never a durability or
  correctness invariant break), recorded in Record 6.
- **Embedding / semantic / ML search.** V2-01 is OCR/PDF text only
  (`V2-00` §3.1).
- **Network OCR or cloud text services.** Vision is on-device only (`V2-facts.md`
  fact 6); no network path exists.
- **Enrichment of non-image/non-PDF content.** Text captures already feed the
  v1 `searchBody` projection (`05` §15); they need no enrichment.
- **An in-memory enrichment read cache.** V2-01 owns the durable index only.
  Any read cache is a separate, future, cache-law-gated graft (not C1/C2/C3,
  which are thumbnail caches in V2-04).

### 2.3 Evidence triggers (admit design work)

- **E1:** lifts `00` §2 ("Enrichment and OCR") and `06` §4
  ("Enrichment/OCR and enrichment-derived search corpus"). Trigger: an approved
  product spec **and** OCR p95 within the agreed budget on the minimum
  supported hardware profile (`V2-00` §3).
- **S1:** lifts `06` §3 G4 ("Per-purpose content subversions/source stamps").
  Trigger: profiling shows material enrichment work repeatedly invalidated by
  Effective Content changes that provably leave the enrichment purpose's source
  bytes unchanged (`V2-00` §3).

Until both triggers fire, V2-01 is design only and reserves no v1 surface.

## 3. Enrichment data model

All declarations in this section are `internal` to `HistoryStorage` unless
explicitly noted as a public `HistoryCore` type. Enrichment types are part of
`HistorySchemaV2`; they never appear in `HistorySchemaV1` (`05` §3, frozen).

### 3.1 Eligible source representation

Enrichment derives from **eligible image/PDF representations** in current
Effective Content. Eligibility is a deterministic, fixture-locked predicate over
the representation's `typeIdentifier`:

```swift
internal enum EnrichmentSourceKind: Sendable, Hashable {
    case image        // ImageIO-decodable image UTI -> Vision OCR
    case pdf          // com.adobe.pdf -> PDFKit text-layer extraction
}

internal struct EnrichmentSourceCandidate: Sendable, Hashable {
    let kind: EnrichmentSourceKind
    let typeIdentifier: String
    let bytes: Data            // immutable copy of the source representation bytes
    let sourceFingerprint: EnrichmentSourceFingerprint
}

internal struct EnrichmentSourceSelection: Sendable, Hashable {
    let contentVersion: ContentVersion     // fetch-time ContentVersion (cheap short-circuit, §6.2)
    let candidates: [EnrichmentSourceCandidate]   // all eligible image/PDF reps; non-empty, else nil
    let storedFingerprint: EnrichmentSourceFingerprint?   // the existing row's fingerprint, if a row exists (S1-win detection, §6.2)
}
```

The fingerprint is named `EnrichmentSourceFingerprint` (not `*SourceStamp*`)
to align with v1's `ContentFingerprint` / `ContentSignatureEntry` vocabulary
(`02` §2.2) and to avoid the deleted-vocabulary token `SourceStamp` (`04` §11,
`06` §10). It is a concrete, **enrichment-purpose-specific** fingerprint type -
not the deleted generic `SourceStamp<T>` / `ItemKey<Purpose>` framework. Each
purpose defines its own independent concrete fingerprint struct; there is **no**
shared generic type, protocol, or store between the enrichment and (future)
thumbnail purposes. "Per-purpose pattern" means a repeated design, never a
reusable generic API (`04` §11, `V2-00` §3.1).

Authority-side selection (type-identifier only, no framework probe). The
Authority collects candidates by `typeIdentifier` matching and computes each
candidate's S1 fingerprint - **no `PDFDocument` is constructed on the Authority
interval** (`PDFDocument` is non-`Sendable`, `V2-facts.md` fact 8; v1 keeps all
framework decode off the Authority, `05` §14.5 "ImageIO decode occurs only after
all SwiftData objects and context have been released"). The PDF text-layer
precedence probe runs **off the Authority** in `derive` (§6.2); the write-time
fingerprint fence (§5.3) reconciles any fetch/probe/persist race. The candidate
collection is computed inside one non-suspending `HistoryAuthority` interval
(§6) so the source bytes and the version fence are consistent. Selection rule
(applied by the worker off-Authority, deterministic, mirrors the v1 thumbnail
source pick, `05` §14.5):

1. From Effective Content, the Authority collects representations whose
   `typeIdentifier` matches an eligible image UTI set or the PDF UTI, in the v1
   stable `typeIdentifier` Unicode-scalar ordering (`02` §2.1), each with its
   S1 fingerprint. If none, selection is `nil` (not-applicable).
2. **PDF-with-text-layer precedence (off-Authority).** If a PDF candidate
   exists **and** `PDFDocument(data:).page(at: 0)?.string` is non-empty (a real
   text layer), the worker selects the PDF even when image candidates are also
   present. This avoids losing multi-page PDF text when an item carries both a
   PDF and a PNG first-page preview (a common pasteboard shape): selecting the
   preview would OCR only page 1 and discard the PDF's full text layer
   (`PDFPage.string`, `V2-facts.md` fact 9). The one-page `string` probe is
   bounded and runs on the worker, never on the Authority.
3. Else if one or more image candidates exist, select the first by ordering
   (multiple image format-variants of the same picture produce equivalent OCR,
   so the first suffices). (Variant-equivalence is not Apple-documented;
   first-by-order selection bounds OCR work, and no correctness property
   may depend on variants OCRing identically - any equivalence check is a
   fixture property, not a platform fact.) This bounds OCR to one image per
   item.
4. Else if a PDF candidate exists (no text layer, or only reached when no
   image exists), select it; it yields empty enrichment text (§2.2 scanned-PDF
   scope).
5. Else the item is **not applicable** to enrichment (`EnrichmentStatus.notApplicable`).

The selected candidate's `sourceFingerprint` is the S1 per-purpose fingerprint
(§5) carried into `PendingEnrichment` for the write-time fence. When current
Effective Content has no eligible source representation (e.g., a revision
`.hide`d the only image/PDF type, `03a` §5 `RevisionDecisionAction.hide`),
selection returns not-applicable; the drain treats the row as stale/not-applicable
and rewrites it to `statusRaw == notApplicable` (§6.5). A `ready` row is never
served when the current Effective Content has no eligible source (D21).

### 3.2 EnrichmentRow (V2 schema)

```swift
@Model
internal final class EnrichmentRow {
    @Attribute(.unique)
    var itemID: UUID                 // HistoryItemID.rawValue; at most one row per item ID

    var contentVersionRaw: UInt64    // ContentVersion derived from (the read-time fence, §5.3)
    var sourceFingerprintRaw: UInt64 // S1: xxh3-64 over the selected source bytes (write-time fence, §5)
    var statusRaw: Int16            // EnrichmentStatus.rawValue (internal encoding)
    var enrichmentSchemaVersion: UInt16   // the EnrichmentBlob codec version (currently 1)
    var derivationSchemaVersion: UInt16    // OCR/PDF materializer schema version, mirrored from the blob (§5.2)
    var reDerivationAttempts: Int16        // bounded re-derivation attempt counter (§6.5; cap 8, §3.4); durable
                                           // across drains/restarts, mirrored as a scalar so the drain
                                           // increments/resets it without blob decode

    var recognizedText: String      // scalar projection of EnrichmentBlobV1.recognizedText (§3.3); bounded 256 KiB;
                                    // the field the search path reads (mirrors v1 searchBody, 05 §3.1/§14.2)
                                    // so search decodes zero enrichment blobs (E1-PERF-2)

    @Attribute(.externalStorage)
    var enrichmentBlob: Data        // versioned EnrichmentBlobV1 (§3.3); the self-describing redundant copy
                                    // (recognizedText + confidence/level metadata); empty when notApplicable.
                                    // Read only on the status/detail path, never on the search path.

    var updatedAt: Date
}
```

Apple documents only that `.unique` "Ensures the property's value is
unique across all models of the same type"; conflict behavior is
undocumented, so V2 relies on the single-writer Authority (no concurrent
inserts) rather than on defined conflict semantics.

`recognizedText` is a scalar projection of the blob's `recognizedText`,
mirroring v1's scalar-projection discipline: v1 stores `searchBody` as a scalar
`String` column on `HistoryItemRow` (`05` §3.1) precisely so `SearchCorpusRow`
carries it as a scalar and search never decodes a blob (`05` §14.2); enrichment
text is the direct analogue and follows the same discipline. The doc already
mirrored `derivationSchemaVersion` as a scalar so staleness-by-materializer-version
is checkable without decoding the blob; the same scalar-projection logic applies to
the searchable text itself, which the search path needs. The blob stays as the
self-describing redundant copy (carries `recognizedText` plus
`topCandidateConfidence`/`recognitionLevel` metadata used only on the
status/detail path, never on the search path). Truncation at the 256 KiB bound
(§3.4) applies to the scalar column exactly as it does to `searchBody`.

Semantic mapping:

| Column | Meaning |
|---|---|
| `itemID` | Stable business ID of the enriched item. A row is absent for items never evaluated; a not-applicable item, once evaluated, has exactly one row with `statusRaw == notApplicable` (§6.5). Orphaned rows for retired items are swept lazily (§6.5); `itemID` is never reused (`02` §7 plan-invariant 9 + D1, `05` §17), so an orphan never self-heals and must be swept. |
| `contentVersionRaw` | The `ContentVersion` at which the stored enrichment text is current - the CV of the source bytes it was derived from, or a later CV whose source bytes fingerprint-match them (the S1-win refresh writes the current CV without re-OCR, §5.3). The **read-time fence** (§5.3): search consults this row only when `contentVersionRaw` equals the item's current `ContentVersion` (a scalar compare, no blob decode, preserving Part VI §7.5). `persistEnrichment` refreshes `contentVersionRaw` to the item's current `ContentVersion` on every persist, including the no-re-OCR S1-win refresh path (§5.3). |
| `sourceFingerprintRaw` | S1 per-purpose fingerprint of the selected source bytes. The **write-time/drain fence** (§5.3): recomputed only on the background drain/persist path (blob decode permitted there, mirroring `05` §14.5 thumbnail source); independent of `ContentVersion`. Unchanged source bytes keep enrichment valid across revisions that touch only non-source representations. |
| `statusRaw` | Internal encoding of `EnrichmentStatus` (`pending` / `ready` / `failed` / `notApplicable`). |
| `enrichmentSchemaVersion` | The `EnrichmentBlob` codec version, mirroring v1's `projectionSchemaVersion` discipline (`05` §3.1). |
| `derivationSchemaVersion` | The OCR/PDF-extraction materializer schema version (§5.2), **mirrored as a scalar column** from the blob exactly as v1 mirrors `projectionSchemaVersion` on `HistoryItemRow` (`05` §3.1). Makes staleness-by-materializer-version checkable on the read/drain path **without decoding the enrichment blob** (the blob still carries it redundantly for self-describing decode). |
| `reDerivationAttempts` | Bounded re-derivation attempt counter (§6.5; the fixed `EnrichmentLimits` value 8, §3.4 - a fixed admission bound, not a runtime tuning knob, `06` §2). **Mirrored as a scalar column** so the persist transaction increments it on a fence-fail discard (writing only the counter; the row is created if absent), resets it to 0 on a successful persist, and caps it at 8 (transitioning the row to `statusRaw == failed`) **without decoding the enrichment blob**. Durable across drains/restarts so a churning item cannot evade the 8-attempt cap across launches (an in-memory counter would be lost on restart). |
| `recognizedText` | Scalar projection of the searchable enrichment text (the v1 `searchBody` analogue). The field the search path reads to attach enrichment text to the corpus (§4.2) without decoding the enrichment blob. Bounded to 256 KiB UTF-8 (§3.4). Inline-storage cost is up to 256 KiB per retained item (the same order as `searchBody`, `05` §3.1); additive via the M1 migration (Record 5). |
| `enrichmentBlob` | Versioned, bounded derived text + metadata. `@Attribute(.externalStorage)` is a storage hint, not a correctness guarantee (`01` §10). |

`EnrichmentRow` is a new V2 model. It is **not** a v1 schema column: it adds a
table; it does not alter `HistoryItemRow` or `LastChangePositionRow`. `itemID`
is a business-ID `@Attribute(.unique)`
column; lookups use a bounded fetch predicate on `itemID`, exactly as v1 looks
up `HistoryItemRow.id` (`05` §5) — never `registeredModel(for:)` (`01` §10,
`05` §18). **Two decode paths, two policies.** The status/detail/drain path
decodes `enrichmentBlob` fail-closed: a corrupt blob is
`.persistence(.corruptStoredValue)` / `.invariantViolation` (`05` §16), never
silently dropped (mirroring v1 codec discipline, `05` §4). The search path reads
only the scalar `recognizedText` (no blob decode); a row whose scalar
`recognizedText`/`contentVersionRaw` is inconsistent with its blob (a corrupt
row) is excluded at read time and re-derived by the drain (self-healing), per
D21's "loss degrades to a miss" - the search path's silent skip is transient
best-effort over a derived projection, not a durable-state acceptance of
corruption. The divergence is justified: the search path is a hot read over up
to 5,000 rows and cannot afford fail-closed blob decode; the status/drain path
is a single-row read/derive where fail-closed is correct.

### 3.3 EnrichmentBlobV1 codec

Enrichment text is persisted through an explicit versioned wire value, not
synthesized `Codable`, mirroring the v1 codec discipline (`05` §4):

```swift
internal struct EnrichmentBlobV1: Codable, Sendable {
    let formatVersion: UInt16       // exactly 1
    let kind: String                 // "image" | "pdf" | "none"
    let recognizedText: String       // concatenated, normalized, bounded (§3.4); concat order is Vision results order
    let topCandidateConfidence: Float   // for image: the MINIMUM across per-observation top-candidate confidences
                                       // (a conservative quality signal for multi-region images); 0.0 for pdf/none/empty
    let recognitionLevel: String    // "fast" | "accurate" (image OCR only); "n/a" for pdf/none
    let derivationSchemaVersion: UInt16   // the OCR/PDF extraction algorithm fingerprint (§5.2)
}
```

`EnrichmentBlobV1` is declared `Sendable` explicitly because it crosses an
isolation boundary: the worker builds it and it travels inside
`EnrichmentDerivation`/`PendingEnrichment` from `EnrichmentWorker` to
`HistoryAuthority.persistEnrichment`. Unlike v1's internal blobs
(`CanonicalBlobV1` etc.), which are decoded *inside* the Authority interval and
never cross isolation, `EnrichmentBlobV1` genuinely crosses. All stored
properties are `let` of `Sendable` types (`UInt16`, `String`, `Float`), so the
conformance is derived without `@unchecked Sendable`, mirroring v1's explicit
marking of crossing values (`PreparedCaptureBundle: Sendable`, `05` §6.1).
`topCandidateConfidence` is a single `Float`. A single image typically yields
multiple `VNRecognizedTextObservation` objects (one per text region/line), each
with its own `topCandidates(1).first?.confidence` (the method does
not throw but "may return fewer than n" - including zero; an observation
with no candidates contributes no text and a `0.0` confidence, mirroring
the `EnrichmentDerivation.empty` encoding), so there are N confidences for N
observations, not "exactly one." V2-01 stores the **minimum** across the
per-observation top-candidate confidences as a conservative quality signal (the
lowest-confidence region is the limiting quality of the recognized text). For
`kind == "pdf"`, `kind == "none"`, and the image `EnrichmentDerivation.empty`
case (no text found), `topCandidateConfidence` is encoded as `0.0`. The
`EnrichmentDerivation.empty` image case maps to
`statusRaw == ready`, `kind == "image"`, `recognizedText == ""`,
`topCandidateConfidence == 0.0` (a ready-but-empty result, not a failure).
`recognizedText` concatenation order is Vision's `results` order (concat
order is `request.results` index order - observation-index order;
Apple documents no ordering for `VNRequest.results`, so D9 determinism
pins concat order to observation-index order only. A bounding-box sort
(top-to-bottom, then left-to-right) is permitted solely as a
fixture-gated tie-break, verified in `E1-PLATFORM-3`.), fixture-locked in
the V2 parallel fixtures (D9 determinism).

Decode reconstructs through validators and checks, exactly as v1 codecs
(`05` §4):

- known `formatVersion` (exactly 1);
- bounded `recognizedText` UTF-8 byte count (≤ the V2 enrichment-text bound, §3.4)
  before any large allocation;
- `kind` is one of the known set; `recognitionLevel` is valid for the kind;
- `topCandidateConfidence` is finite, NaN-free, and in `[0, 1]` for `kind == "image"`;
  for `kind == "pdf"`/`"none"` it is exactly `0.0` (any other value is corrupt);
- `derivationSchemaVersion` is a known enrichment materializer schema version
  (the column `EnrichmentRow.derivationSchemaVersion` mirrors it and is the
  scalar used on read/drain paths without decoding this blob);
- a `notApplicable` item encodes `kind == "none"` and empty text.

Any violation is `.persistence(.corruptStoredValue)` or
`.persistence(.invariantViolation)` (`05` §16). The decoder does not silently
drop text, reset to a default, or substitute Canonical bytes.

### 3.4 Enrichment text bounds

A new V2 admission bound, `EnrichmentLimits` (a `HistoryLimits`-peer fixed
value, `internal` to `HistoryStorage` since enrichment is internal, evaluated
and checked by `HistoryStorage`, not a user retention knob and not a
modification of `HistoryLimits`, mirroring `06` §2):

| Bound | V2 value |
|---|---:|
| Stored enrichment text UTF-8 bytes per item | 256 KiB |
| OCR candidate count retained per observation | 1 (top candidate only) |
| PDF pages scanned per item | `min(pageCount, 1000)` - iteration stops at `min(pageCount, 1000)` **or** once accumulated recognized text reaches the 256 KiB text bound, whichever first |
| Enrichment re-derivation attempts per item | 8 (bounded retry with backoff; §6.5) |

Rules (matching `06` §2):

- Enrichment text is **truncated at a deterministic Unicode scalar boundary**
  when it exceeds the bound. Truncation is allowed for enrichment text (it is a
  search projection, like `searchBody`, not Canonical/revision bytes) but must
  not split a Unicode scalar.
- OCR produces the top candidate per observation (`topCandidates(1)`); lower
  candidates are not stored, bounding work and storage.
- PDF page iteration is bounded: pages are scanned in index order
  (`0 ..< doc.pageCount`, `PDFDocument.page(at:)` is zero-based and raises an
  Objective-C exception - a Swift crash - on an out-of-bounds index, so the bound
  is mandatory, `V2-facts.md` fact 12), and iteration stops at `min(pageCount,
  1000)` or as soon as the accumulated recognized text reaches the 256 KiB bound,
  whichever first. The explicit 1,000-page cap bounds a textless or near-textless
  PDF (minimal pages are tiny, so the 64 MiB representation bound does not bound
  page count) that would otherwise iterate every page accumulating no text. This
  bounds per-item PDF extraction work and memory. OCR is already bounded to one
  image and `topCandidates(1)`.
- All byte-count arithmetic is checked; overflow fails closed and never wraps
  (`06` §2, `02` §13).

### 3.5 EnrichmentConfigRow (capability gate)

Enrichment is gated by a durable capability flag, persisted in its own V2
singleton (the v1 `LastChangePositionRow` is frozen and must not gain a
column):

```swift
@Model
internal final class EnrichmentConfigRow {
    @Attribute(.unique)
    var key: String                  // always "enrichment"
    var enabled: Bool                // capability gate; default false (v1-faithful)
}
```

> There is no `lastDrainPosition` watermark. v1 has no per-item `ChangePosition`
> column (only the global `LastChangePositionRow` singleton, `05` §3.2) and no
> durable change journal (`04` §1, `04` §4), so a position-bounded per-item scan
> is unimplementable on the v1 schema. The invalidation-driven drain (§7.2)
> targets precise itemIDs yielded post-commit (no position scan); the
> startup/on-enable backlog drain (§7.1) scans retained items by
> row-absence/staleness (no position predicate) and is bounded by the 5,000-item
> hard retained maximum (`06` §2). A drain watermark is therefore redundant and
> is omitted.

`enabled == false` is the **v1-faithful mode**: no enrichment is performed, the
search corpus has no enrichment dimension, and every v1 path is unchanged. The
flag is written only through `HistoryAuthority` (single writer); toggling it is
not a `HistoryAction` (it does not mutate history items and does not advance
`ChangePosition`) and therefore lives on the `EnrichmentHistory` protocol, not
on `HistoryAction` (§8).

**Singleton bootstrap at open.** `SwiftDataHistory.open` creates exactly one
`EnrichmentConfigRow` (`key == "enrichment"`, `enabled == false`) if none exists, after the v1 `LastChangePositionRow`
singleton (step 3, `05` §13) and before the facade is published, and validates
exactly-one on open. This mirrors the v1 position-singleton creation (`05` §13
step 3); a migrated v1 store therefore gains exactly this one default row and
starts disabled (v1-faithful), so the §4.2 `EnrichmentConfigRow.enabled` gate is
always defined. This step applies to the `.memory` store path too.

## 4. Enrichment pipeline (data flow)

The enrichment side pipeline branches off the canonical/commit path and never
enters it (`V2-00` §6.1). It is a derivation/observation of authoritative state.

```text
History Commit (capture / revise) completes
  -> HistoryAuthority post-commit (05 §11): alongside yielding HistoryInvalidation
       to registered continuations (synchronous, non-blocking AsyncThrowingStream yield),
       also yields the affected itemID(s) it just executed into the
       EnrichmentScheduler's own channel (non-suspending; see §6.3)
  -> EnrichmentScheduler (internal) receives the precise itemID(s) (a new internal consumer, §7)
  -> debounced drain:
       EnrichmentWorker.drainPending(budget)
         -> for each enqueued candidate (precise itemID; bounded by per-cycle budget, §7):
              1. Authority.enrichmentSource(for: id)         [non-suspending Authority interval]
                   - fetch item, verify current ContentVersion
                   - derive Effective Content (02 §2.6)
                   - collect eligible source candidates by typeIdentifier (§3.1; NO
                     PDFDocument probe on the Authority - PDFDocument is non-Sendable)
                   - compute each candidate's S1 source fingerprint (§5)
                   - return EnrichmentSourceOutcome (§6.4): .selection
                     carrying the fetch-time ContentVersion + all candidate
                     bytes + fingerprints, OR .notApplicable, OR .rowCurrent
                     (the no-op skip below)
                   - release all @Model and the context before returning
                   - row-current no-op skip: in the same Authority
                     interval, read the stored row's scalar statusRaw /
                     contentVersionRaw; if row.contentVersionRaw == the
                     item's current ContentVersion and statusRaw is ready
                     or notApplicable, return .rowCurrent - no
                     Effective-Content derivation, no candidate collection
                     or fingerprinting, no OCR, no persist; the drain
                     drops the item (§6.5)
              2. EnrichmentWorker.derive(selection)           [off-Authority, on the worker actor]
                   (row-current items never reach derive: step 1
                    returned the .rowCurrent marker and the drain dropped
                    the item before any OCR or persist (§6.5))
                   (SKIPPED on S1-win: if the fetched candidate fingerprint matches the
                   stored row's fingerprint and ContentVersion advanced, the drain bundles
                   .reuseStored and skips to step 3 - no re-OCR, §6.2)
                   - apply the precedence rule off-Authority (§3.1): probe PDF text layer,
                     else first image, else PDF-no-text-layer -> pick ONE candidate
                   - image: VNImageRequestHandler(data: candidate.bytes).perform([request])
                     (no completion handler; read request.results synchronously, §6.2)
                   - pdf:   bounded page iteration 0..<min(doc.pageCount, 1000)
                     (doc.page(at: i)?.string; stop at the 256 KiB text bound or 1000 pages, §3.4)
                   - normalize + bound + truncate the text (§3.4); collapse confidence (§3.3)
                   - build EnrichmentBlobV1 + recognizedText scalar
                   - bundle into PendingEnrichment (itemID, fetch-time contentVersion, the
                     selected candidate's sourceFingerprint, derivation) for the write-time
                     fence + row population (§6.2)
              3. Authority.persistEnrichment(pending)        [single-writer, separate transaction]
                   - open context, fetch EnrichmentRow by itemID; re-fetch the item's current
                     source bytes (background path; blob decode permitted, mirrors 05 §14.5)
                   - WRITE-TIME FENCE (§5.3): recompute the current source fingerprint and compare
                     to pending.sourceFingerprint (xxh3-64, evidence-not-identity per D7). When the
                     stored row's fingerprint equals the current fingerprint and the ContentVersion
                     advanced, this is the S1 win - refresh contentVersionRaw WITHOUT re-OCR.
                     When the fetch-time and persist-time fingerprints differ, source changed
                     during the drain cycle.
                   - on fence pass: write/update EnrichmentRow, refreshing contentVersionRaw to
                     the item's CURRENT ContentVersion (so the read-time ContentVersion fence
                     subsequently passes), plus the (unchanged) fingerprint, derivationSchemaVersion,
                     recognizedText scalar, and blob (status ready/failed)
                   - on fence fail (source changed between fetch and persist): discard + requeue
                     the item (bounded retry, §6.5)
                   - on missing item at persist (retired between the
                     step-1 fetch and this persist): discard the
                     derivation, write nothing, and let the orphan sweep
                     remove any row (§6.5) - not surfaced as an error;
                     the drain is internal
                   - transaction commits (no ChangePosition advance; not a History Commit;
                     no HistoryInvalidation yielded - enrichment is not a History Commit and
                     advances no ChangePosition, so it does not wake a live observe(.search);
                     the UI re-browses or waits for the next real History Commit, §4.1)
                   - release context
```

### 4.1 Why this preserves v1

- The capture/revision **commit interval** (`05` §6, §10) is unchanged. No OCR,
  no PDF parsing, no enrichment write occurs in the `ModelContext.transaction`
  closure of a History Commit. The post-commit order (`05` §11) is unchanged:
  the enrichment wake-up is delivered to the scheduler as a **new internal
  invalidation consumer** - specifically, the Authority performs a synchronous,
  non-awaiting yield into the scheduler's own `AsyncThrowingStream`/channel
  continuation in post-commit step 2 (the same non-blocking primitive v1 uses for
  observer continuations, `05` §14.4; `V2-facts.md` cycle-2 fact directly
  verifies `AsyncThrowingStream.Continuation.yield` "returns to the caller
  immediately without blocking for any awaiting consumption"). It is **not** a
  direct
  `await scheduler.wake(at:)` call, which would be an actor-isolation
  suspension hop forbidden by `05` §11's "without suspension." The affected
  itemID(s) the Authority just executed are yielded into the same channel, so
  the scheduler targets precise items rather than scanning recent pages
  (verified `E1-PERF-4`).
- The source fetch (step 1) mirrors the v1 thumbnail source fetch (`05` §14.5):
  one item, version check, Effective-Content derivation, immutable `Sendable`
  bytes out, context released. No `@Model` crosses the boundary (`01` §6).
- The derivation (step 2) runs off the Authority, mirroring `ThumbnailWorker`
  (`01` §6, `05` §14.5): expensive, non-`Sendable` framework objects
  (`VNRecognizeTextRequest`, `VNImageRequestHandler`, `PDFDocument`) are created
  and consumed entirely inside the `EnrichmentWorker` actor and never cross an
  isolation boundary.
- The persist (step 3) goes through `HistoryAuthority`, preserving the single
  write authority (`00` §3.3). It is a **separate transaction** that writes
  only `EnrichmentRow`; it does not touch `HistoryItemRow`,
  `LastChangePositionRow`, or the Signature Index, and it does not advance
  `ChangePosition`. Its write-time fence recomputes the current source
  fingerprint and compares it to the fetch-time/stored fingerprint (xxh3-64,
  evidence-not-identity per D7, §5.3) - it does **not** byte-exact-compare (the
  fetch-time derivation bytes are not retained across the worker boundary; the
  S1-win path cannot recover the bytes the stored text was derived from).
- **Enrichment is not live-observed.** `persistEnrichment` and
  `setEnrichmentEnabled` advance no `ChangePosition` and are not History Commits,
  so they yield **no** `HistoryInvalidation`. v1's race-free observer wakes only
  on an invalidation whose position is strictly greater than the yielded page
  (`04` §5 steps 4 and 6: "position > P"), and a same-position synthetic
  invalidation is inert. Rather than extend `04` §5's wake predicate (a deeper
  internal-coherence change), V2-01 states honestly that enrichment/toggle
  changes are reflected only on the **next real History Commit** (which advances
  `ChangePosition` and wakes the observer naturally, re-capturing a fresh
  `SearchCorpusSnapshot` that includes any persisted enrichment text) or on a
  **fresh `browse(.search)`** call (which always reflects current state). The
  UX (V2-07) re-browses on toggle and on the next History Commit / a fresh
  `browse(.search)` (no OCR-completion push - `EnrichmentHistory` exposes no
  observation stream, §8). No public
  invalidation contract changes; durable correctness is intact (one-shot reads
  are always current).

**V2-03 collection-cache composition:** persistEnrichment and
setEnrichmentEnabled bump the Authority's enrichmentCorpusEpoch in the
same serialization as their transaction. V2-03's collection-cache fence
and key carry that epoch (V2-03 §7.1/§7.2), so the claim that a fresh
browse(.search) always reflects current state holds only through this
epoch - it is false against a position-only fence, because enrichment
changes the corpus without advancing ChangePosition.

### 4.2 Read path (search consultation)

When `EnrichmentConfigRow.enabled == true`, the internal search corpus is
extended:

```text
browse(.search(text:mode:)) / observe(.search(...))
  -> HistoryAuthority captures SearchCorpusSnapshot (05 §14.2) in one interval
       + for each SearchCorpusRow whose EnrichmentRow exists with status == ready
         AND row.contentVersionRaw == searchCorpusRow.contentVersion.rawValue
         (scalar ContentVersion equality; no Canonical/revision blob decode,
          no enrichment-blob decode - recognizedText + derivationSchemaVersion are
          scalar columns)
         AND row.derivationSchemaVersion == CURRENT_DERIVATION_SCHEMA_VERSION
         AND row.enrichmentSchemaVersion == CURRENT_ENRICHMENT_SCHEMA_VERSION:
              attach row.recognizedText (the scalar column) as the enrichment
              corpus field (no blob decode)
  -> SearchWorker evaluates exact/fuzzy/regexp over the fields in fixed precedence
       title -> searchBody -> enrichment (first match wins; default order preserved)
  -> a match found in enrichment text produces a SearchPresentation
       whose snippet is a deterministic bounded excerpt of the enrichment text
       and whose matchedRanges are UTF-16 offsets into that snippet (03b §8)
  -> HistoryPage(position, rows, cursor)  [unchanged public types]
```

**Read-time fence (D21).** The read-time fence is the scalar
`row.contentVersionRaw == searchCorpusRow.contentVersion.rawValue` (`contentVersionRaw`
is `UInt64`, §3.2; `ContentVersion.rawValue` is the same `UInt64`, exact per D5,
no decode). This is the cheap, collision-free arbiter: when `ContentVersion` is
unchanged, Effective Content is unchanged (D5), so the source bytes are unchanged
and the recorded enrichment text remains valid - serve without any hash. The S1
source fingerprint is **not** recomputed on the search path; it is a write-time/drain
optimization only (§5.3). A row whose `ContentVersion` advanced (source bytes may
have changed) is excluded at read time until the drain re-derives and refreshes
`contentVersionRaw` - exactly the safety D21 requires, with no search-path blob
decode (the served text is the scalar `recognizedText`, preserving Part VI §7.5,
`05` §14.2).

**Field precedence and ranking.** Enrichment text is a third searchable field.
**Within a row**, the scan precedence is **title -> searchBody -> enrichment**
(first match wins): exactly mirroring v1's "title first, only on title miss the
body" discipline (`03b` §8), a `searchBody` match precludes scanning enrichment
for that row (so "body wins" is a within-row scan rule, not a cross-row ranking
rule). Per-mode scan limits apply to enrichment text as they do to body: exact
scans the full bounded enrichment text; fuzzy scans the first 5,000 Characters;
regexp scans the first 1,000 Characters (reusing the v1 body limits, since the
stored 256 KiB bound >> those scan limits). A title match keeps `snippet == nil`
(ranges into `HistoryRow.title`); a body match supplies the `03b` §8 bounded
excerpt; an enrichment-only match supplies a deterministic bounded excerpt of
the enrichment text (the `03b` §8 windowing algorithm applied to enrichment text,
320-Character window, at most 322 with ellipses), preserving v1's
single-snippet-per-row contract (`SearchPresentation` carries one snippet + one
`matchedRanges` array, `03b` §8).

**Cross-row ranking differs by mode.** For **exact/regexp**, results preserve the
default row order (title/body/enrichment first-match, `03b` §8) - field
precedence holds within and across rows. For **fuzzy**, v1 ranks by ascending
Fuse score, then `lastCopiedAt` descending, then ID bytes ascending (`03b` §8;
pinned rows still come first, ordered by `pinOrdinal` — the Fuse ordering
governs the unpinned segment) - **not** by field precedence: an
enrichment-only-match row at a
better Fuse score **can** outrank a `searchBody`-match row at a worse score.
This is a behavior change from v1 fuzzy (enrichment is now a fuzzy input) and is
fixture-locked in the V2 parallel fixtures (§10): a fixture pins the cross-row
ordering where an enrichment-match row outranks a body-match row by score, and a
fixture pins the within-row body-precludes-enrichment scan.

When `enabled == false`, the `SearchCorpusSnapshot` carries no enrichment field
and `SearchWorker` evaluates exactly the v1 corpus; the public search types
(`HistoryBrowseRequest`, `SearchMode`, `SearchPresentation`, `HistoryPage`) are
unchanged. The v1 search fixtures (WS17, `06` §8) run with enrichment disabled,
so they pass unchanged; V2-01 adds parallel fixtures with enrichment enabled
(§10).

Enrichment consultation is an **additive extension**: with enrichment on, search
may additionally match OCR text; with enrichment off, search is byte-for-byte
v1. This is not a modification of a v1 public type — `SearchCorpusSnapshot` and
`SearchWorker` are `internal` to `HistoryStorage` (`05` §14.2), and the v1
public search surface is untouched.

**`SearchCorpusRow` extension (recorded).** `SearchCorpusRow` gains an optional
`enrichmentText: String?` field - a capability-gated extension of a v1 *internal*
type per `V2-00` §2.1 (v1 states "there is no... enrichment field" on the row,
`05` §3.1; V2-01 concretizes that absence behind the capability gate rather than
redefining the v1 row). It is `nil` whenever `EnrichmentConfigRow.enabled ==
false`, so the disabled-path snapshot is byte-for-byte v1; WS17 (`06` §8)
disabled-path fixtures are re-run to confirm byte-for-byte v1 search behavior.
`SearchCorpusRow` extension is added to the §11 self-review scan list.

## 5. S1 - per-purpose content source fingerprints

S1 (`06` §3 G4) is the mechanism that prevents redundant re-derivation when a
revision advances `ContentVersion` without changing the bytes enrichment
derives from. It is the enrichment-purpose analogue of the v1 thumbnail
version fence (`04` §9), refined to the *source* bytes rather than the
whole-item version. V2-01 owns its **enrichment instantiation**
(`EnrichmentSourceFingerprint`). Each purpose defines its own independent
concrete fingerprint struct - there is **no** shared generic
`SourceStamp<Purpose>` / `ItemKey<Purpose>` type, protocol, or store (`04` §11,
`06` §10); "per-purpose pattern" means a repeated design, never a reusable
generic API. If V2-04 (materialization caches) later instantiates the same
design for the thumbnail purpose, it defines its own independent concrete type;
neither purpose reserves the other's surface.

### 5.1 Definition

```swift
internal struct EnrichmentSourceFingerprint: Sendable, Hashable {
    let rawValue: UInt64     // xxh3-64 over the selected source representation bytes
}
```

The fingerprint is xxh3-64 over each **candidate source representation's bytes**
(§3.1), computed for every candidate inside the same non-suspending Authority
interval as the version check and candidate collection. The worker selects one
candidate off-Authority (precedence probe, §3.1/§6.2); that candidate's
fingerprint is the one carried into `PendingEnrichment`. xxh3 is the v1
fingerprint primitive (`01` §4, `05` §1); reuse - not a new hash - keeps the
derivation on the v1 evidence discipline.

**Collision honesty (D7).** Like every v1 fingerprint, this value is
**evidence, never identity** (D7, `02` §2.2, `02` §14): it narrows the work but
never completes a decision. Unlike v1 dedup - where the fingerprint only
*generates* a candidate and a byte-exact comparison is the final arbiter
(`02` §9.2, `05` §12 "Fingerprints may collide; full content confirmation
remains mandatory") - the S1 fingerprint must not become the sole verdict,
because then an xxh3-64 collision between old source bytes B1 and new source
bytes B2 would report "unchanged" and serve stale OCR text derived from B1 for
an item whose image is now B2 (exactly the failure D21 forbids). V2-01
therefore **does not use the fingerprint alone as the read-time serve verdict**:
at read time the fence is the collision-free `ContentVersion` counter (D5, §5.3),
never the fingerprint. At **write time**, however, the fence *is* the fingerprint:
the fetch-time derivation bytes are not retained across the worker boundary
(`PendingEnrichment` carries the fingerprint, not the bytes, §6.2), and the
S1-win (skip-re-OCR) path cannot recover the bytes the stored text was derived
from (only their xxh3 survives in `sourceFingerprintRaw`). The write-time fence
therefore recomputes the current source fingerprint and compares it to the
fetch-time/stored fingerprint (xxh3-64, evidence-not-identity). The S1 collision
residual is **not eliminated** - it is the xxh3-64 birthday bound (~5000^2 /
2^65, about 7e-13 at the retained scale). A collision on the S1-win path would,
in principle, refresh `contentVersionRaw` for bytes that changed and serve stale
OCR text under the new `ContentVersion` until the next re-derivation. This is
accepted (enrichment is a derivation, not durable history state; the residual is
~7e-13, and loss degrades to a miss on re-derivation - it never corrupts durable
history or violates D2/D5/D6). D7's evidence-not-identity thus holds fully at
read time (the `ContentVersion` counter is the serve arbiter) and is
evidence-bounded at write time; D21 is stated as this residual bound, not a
"never." (A byte-exact write-time fence would require retaining the fetch-time
derivation bytes - up to a 64 MiB representation, `06` §2 - across isolation, or
recovering them from the append-only revision history, D4; both are heavier
than the accepted residual and are not taken in V2-01.)

### 5.2 Derivation schema version

`EnrichmentBlobV1.derivationSchemaVersion` is the **structural materializer
schema version** required by the cache/derivation key law (`04` §12): it
identifies the OCR/PDF-extraction algorithm shape (recognition level, revision,
language set, truncation rule). When the enrichment materializer changes
(e.g., a new Vision revision is pinned), `derivationSchemaVersion` advances and
all prior enrichment rows are treated as stale (re-derived). This mirrors the v1
`projectionSchemaVersion` discipline (`05` §3.1, §15) and the cache-key
requirement for a "structural materializer schema version" (`04` §12).

### 5.3 Fence check (the D21 rule)

The fence has **two layers**, split by where they run and what they cost:

**Read-time fence (search path, cheap, no decode).** An `EnrichmentRow` is
served by search only when:

```text
row.contentVersionRaw == searchCorpusRow.contentVersion.rawValue
  AND row.enrichmentSchemaVersion == CURRENT_ENRICHMENT_SCHEMA_VERSION
  AND row.derivationSchemaVersion == CURRENT_DERIVATION_SCHEMA_VERSION
```

All three operands are scalar columns already present in `EnrichmentRow` /
`SearchCorpusRow` (`05` §14.2); none requires decoding a Canonical, revision, or
enrichment blob (`derivationSchemaVersion` is mirrored as a scalar column,
§3.2). This preserves Part VI §7.5 / `05` §14.2 scalar-read isolation
(proof `E1-PERF-2`, amended `E1-PERF-5`). When the item's current
`ContentVersion` is unchanged, Effective Content is unchanged (D5), so the
source bytes are unchanged and the recorded enrichment text remains valid -
serve without any hash. When `ContentVersion` advanced (source bytes *may* have
changed), the row is excluded at read time until the drain re-derives and
refreshes `contentVersionRaw` (D21: a stale fence is never relabeled current).

**Write-time / drain fence (background path, decode permitted).** On the drain,
the Authority re-fetches the item's current source bytes (blob decode permitted
here, mirroring `05` §14.5 thumbnail source) and:

- if the current source selection is not-applicable (e.g., a revision `.hide`d
  the only image/PDF type, `03a` §5): rewrite the row to `statusRaw ==
  notApplicable`; a `ready` row is never served when current Effective Content
  has no eligible source (D21);
- else **fingerprint-compare** the recomputed current source fingerprint to the
  fetch-time/stored fingerprint (xxh3-64, evidence-not-identity per D7, §5.1).
  When the fetch-time and persist-time fingerprints differ, the source changed
  during the drain cycle - discard and requeue (bounded retry, §6.5). When they
  are equal, the source is unchanged (fingerprint evidence) and the derivation
  is persisted. This is **not** a byte-exact compare: the fetch-time derivation
  bytes are not retained across the worker boundary (`PendingEnrichment` carries
  the fingerprint, not the bytes, §6.2), and the S1-win path cannot recover the
  bytes the stored text was derived from. The residual is the xxh3-64 birthday
  bound (~7e-13, §5.1), accepted. (v1's two-stage dedup narrows with a
  fingerprint then **byte-confirms** - `02` §9.2, `05` §12; V2-01's enrichment
  fence narrows with the fingerprint but does **not** byte-confirm, because
  retaining the derivation bytes is disproportionate to the residual. D7 is
  evidence-not-identity at read time via the `ContentVersion` counter; at write
  time it is fingerprint-bounded.)

**The S1 win is write-time-only.** When a revision advances `ContentVersion`
without changing the source bytes (the S1 trigger condition, `06` §3 G4), the
drain recomputes the fingerprint (background, decode allowed), finds it
unchanged (fingerprint evidence), and **refreshes `row.contentVersionRaw` to the
item's new `ContentVersion` without re-OCR** - so the read-time `ContentVersion`
fence subsequently passes and the row stays served. The read path never recomputes the
fingerprint; it relies on the scalar `ContentVersion` fence, which the drain
keeps current. `persistEnrichment` writes the item's current `ContentVersion`
into `row.contentVersionRaw` on every persist, including this no-re-OCR refresh
path. The S1-win path does not byte-confirm (the stored text's derivation bytes
are not recoverable; only their xxh3 survives), so its safety is the xxh3-64
residual (§5.1) - accepted because enrichment is a derivation.

The write-time fence is checked inside the persist transaction and discards the
result if the source changed between fetch and persist (analogous to the
thumbnail version check, `04` §9 step 2, and the revision two-phase OCC,
`05` §6.2).

## 6. Code model

### 6.1 Module and target placement

- **Public surface** (`EnrichmentHistory` protocol, `EnrichmentStatus`) is
  added to `HistoryCore` as a clearly V2-scoped section. No `EnrichmentTextExcerpt`
  type is declared: enrichment matches reuse the existing `SearchPresentation`
  (`03b` §8; no new public DTO is required for the match - §12, this doc), so the v1 gate that every declared public
  type compiles (`06` §6) is not strained by a referenced-but-undeclared type. These types are Foundation-only (HistoryCore's invariant, `01` §8) and
  reuse v1 vocabulary (`HistoryItemID`, `ContentVersion`) verbatim. Adding new
  types to `HistoryCore` is a "capability-gated extension of an existing
  module," explicitly permitted (`V2-00` §2.1); no existing v1 `HistoryCore`
  type is modified.
- **Implementation** (`EnrichmentWorker`, `EnrichmentScheduler`, `EnrichmentRow`,
  codecs, source fetch/persist on `HistoryAuthority`) is added to
  `HistoryStorage`, which gains `import Vision` and `import PDFKit`. These are
  framework imports in the storage target, consistent with v1's `ImageIO`
  import (`01` §4, `05` §14.5); the source gate (`01` §9) is extended to permit
  `Vision`/`PDFKit` in `HistoryStorage` and to continue forbidding them in
  `HistoryCore`/`HistoryDomain`/adapters/UI (proof gate `E1-COMPILE-3`,
  `V2-facts.md` OPEN questions item 5).
- `SwiftDataHistory` gains an `EnrichmentHistory` conformance; the
  `EnrichmentWorker` and `EnrichmentScheduler` are stored fields of
  `SwiftDataHistory` (extending its actor field set, `05` §2). Because they are
  `actor` types, `SwiftDataHistory: Sendable` remains derived without
  `@unchecked Sendable` (`01` §6). This is a **private stored-field addition**
  to a v1 public concrete type: the public interface (the `ClipboardHistory`/
  `EnrichmentHistory` conformances and the `open(...)` signature) is unchanged,
  so it is an additive extension, not a redefinition, under the V2 self-review
  gate (`V2-00` §8).

### 6.2 EnrichmentWorker (actor)

```swift
internal actor EnrichmentWorker {
    private let authority: HistoryAuthority   // for enrichmentSource/persistEnrichment (Sendable actor ref)

    // Owns non-Sendable Vision/PDFKit objects; they are created per-derivation
    // and never cross the actor boundary (mirrors SearchWorker's Fuse matcher,
    // 01 §6). The blocking derive body runs on a custom non-cooperative executor
    // ("Off the cooperative pool" below), so neither the worker's default
    // cooperative executor nor the cooperative pool is ever blocked by it.

    // Drives the drain: for each enqueued candidate, fetch via the Authority,
    // derive off-Authority, persist via the Authority (§4 flow, §7).
    func drainPending(budget: Int) async

    func derive(_ selection: EnrichmentSourceSelection) async -> EnrichmentDerivation
}

internal struct PendingEnrichment: Sendable {
    let itemID: HistoryItemID
    let contentVersion: ContentVersion      // fetch-time CV; cheap short-circuit (see below)
    let sourceFingerprint: EnrichmentSourceFingerprint   // the selected candidate's fingerprint
    let derivation: EnrichmentDerivation
}

internal enum EnrichmentDerivation: Sendable {
    case text(EnrichmentBlobV1)        // recognized/extracted text, bounded (+ recognizedText scalar)
    case empty                         // no text found (e.g., image with no text, empty PDF)
    case failed                        // OCR/extraction error (non-fatal)
    case reuseStored                   // S1-win: skip re-OCR; refresh contentVersionRaw only (§5.3)
}
```

`PendingEnrichment` bundles the fields the write-time fence and row population
require: `itemID`, the fetch-time `ContentVersion`, the selected candidate's S1
`sourceFingerprint`, and the `EnrichmentDerivation`. `contentVersion` is a cheap
short-circuit: `persistEnrichment` re-fetches the item's **current**
`ContentVersion` and writes *that* into `row.contentVersionRaw` (not the
fetch-time value); the fetch-time `contentVersion` lets the persist path skip
straight to the refresh when the fetch-time and persist-time `ContentVersion`
are equal (the item did not change during the drain cycle) before the fingerprint
compare. The byte-exact write-time bytes are **not** carried (the S1 residual is
accepted, §5.1). It is `Sendable` (all-`let` `Sendable` members) so it crosses
from the worker to the Authority. The `.reuseStored` case expresses the S1-win
no-re-OCR path: the drain decides S1-win by comparing the fetched candidate
fingerprint to the stored row's fingerprint (read on the background Authority
path, where decode is permitted) and, on a match, bundles `.reuseStored` instead
of calling `derive`; `persistEnrichment` then refreshes `contentVersionRaw`
leaving the scalar `recognizedText`/blob unchanged.

`derive` first applies the precedence rule off-Authority (§3.1: probe PDF text
layer, else first image, else PDF-no-text-layer) to pick one candidate from
`selection.candidates`, then runs the image path as
`VNImageRequestHandler(data: candidate.bytes).perform([request])` and the PDF
path as bounded page iteration `for i in 0..<min(doc.pageCount, 1000) {
doc.page(at: i)?.string }` (zero-based; an out-of-bounds index raises an
Objective-C exception - a Swift crash - so the bound is mandatory,
`V2-facts.md` fact 12; iteration stops at `min(pageCount, 1000)` or the 256 KiB
text bound, §3.4). Because `perform(_:)` is synchronous and blocking
(`V2-facts.md` fact 2), `derive` is an `async` actor method.

**No completion handler.** `VNRecognizeTextRequest` is constructed via the
no-completion-handler path `init()` (or `init(completionHandler: nil)`, the
inherited `VNRequest` initializer, `V2-facts.md` cycle-1 fact): Apple documents
that a supplied completion handler "runs on a queue different from the one where
you called perform(_:)", so reading the non-`Sendable` results
(`VNRecognizedTextObservation`, `VNRecognizedText`) from a handler would be a
Swift 6 isolation violation. V2-01 therefore calls the synchronous blocking
`perform(_:)` and reads `request.results` synchronously **after** it returns, on
the worker's own thread; results are consumed and discarded inside the actor.
Only the bounded `String` leaves as `EnrichmentDerivation` (a `Sendable` enum).

**Off the cooperative pool.** `perform(_:)` can block for seconds on a large
image (longer than v1's tightly bounded ImageIO thumbnail decode). To avoid
starving the cooperative global executor (and potentially `HistoryAuthority`
actors sharing it), the blocking `perform(_:)` / PDF iteration runs off the
cooperative pool on a **custom non-cooperative executor** (the
`Actor.unownedExecutor` override, §13; API-existence subsumed by `E1-COMPILE-1`'s
Swift 6 build) the `EnrichmentWorker` actor overrides - never on the worker's default cooperative
executor. (A detached `Task` is **not** a valid alternative: the non-`Sendable`
`VNRecognizeTextRequest`/`VNImageRequestHandler`/`PDFDocument` cannot be captured
into a detached `Task` without crossing isolation - a Swift 6 strict-concurrency
violation - and if the detached `Task` constructs them itself, confinement is the
`Task`, not the actor, breaking the `EnrichmentWorker`-confinement claim and
`E1-COMPILE-2`. An off-thread dispatch that receives `Sendable` bytes and
returns a `Sendable` `EnrichmentDerivation` is a valid but distinct design; V2-01
commits to the custom-executor-on-the-actor approach so confinement is the actor
and the `SearchWorker` mirror holds.) `E1-PERF-6` proves OCR does not starve the
cooperative pool / Authority under sustained backlog. No
`VNRequest`/`VNImageRequestHandler`/`PDFDocument`/`VNRecognizedText*` reference
crosses isolation (`01` §6 boundary rule); `derive` never runs on the
`HistoryAuthority` or the main actor.

### 6.3 EnrichmentScheduler (actor)

```swift
internal actor EnrichmentScheduler {
    // Deterministic drain order: enqueue order, then lastCopiedAt DESC
    // (most-recently-copied first; drain priority), then HistoryItemID bytes ASC
    // (final tie-breaker mirrors 02 §12's final ID ordering) - NOT a Set, so
    // drain order and V2 parallel fixtures are reproducible (D9). NOTE: this is
    // NOT the v1 eviction ordering, whose direction is lastCopiedAt ASC
    // (oldest-first for victim selection, 02 §12); the direction is inverted
    // for drain priority.
    private var pending: [HistoryItemID] = []
    private var seen: Set<HistoryItemID> = []   // dedupe while queued; an ID
                                                // is removed when its drain
                                                // cycle completes, so a later
                                                // commit re-enqueues it (§7.2)
    private var drainTask: Task<Void, Never>?

    // The Authority yields affected itemIDs into this stream in post-commit
    // step 2 (a synchronous AsyncThrowingStream continuation yield, NOT a
    // direct actor-method call). The scheduler consumes it asynchronously.
    let inbox: AsyncThrowingStream<HistoryItemID, Error>
    func enqueue(_ id: HistoryItemID)              // explicit enqueue (e.g., on enable)
    func cancel()
}
```

The scheduler debounces wake-ups and drives `EnrichmentWorker.drainPending` at a
bounded rate (§7). It holds only `Sendable` values (IDs, positions). It does
not hold `@Model` or `ModelContext`, and it **never creates a writable
`ModelContext`** (preserving D22): all enrichment writes go through
`HistoryAuthority` (§6.4). It is a new internal invalidation consumer
(`04` §4), wired exactly like v1 observer continuations (`05` §14.4): the
`HistoryAuthority` registers the scheduler's `inbox` stream continuation, and
post-commit step 2 (`05` §11) performs a synchronous, non-awaiting
`continuation.yield(itemID)` for each item the commit just executed - plus the
existing `HistoryInvalidation` yield to observer continuations. Apple documents
`AsyncStream.Continuation.yield` "returns to the caller immediately without
blocking for any awaiting consumption" (`V2-facts.md` cycle-1 fact), so this
adds **no `await`** to the Authority's post-commit phase and the v1 post-commit
order is unchanged (proof `E1-PERF-4`). Delivery is explicitly **not** a direct
`await scheduler.wake(at:)` call, which would be an actor-isolation suspension
hop forbidden by `05` §11's "without suspension"; the scheduler reads its own
`inbox` asynchronously on its own executor. Receiving a retired itemID (the
item is gone) enqueues it only; the drain skips it on the not-found fetch and
its orphaned row is removed by the cadence sweep (§6.5) - no per-ID delete
exists.

**Inbox buffering policy.** Unlike the v1 invalidation stream (which carries
only a position and may coalesce to the newest - `04` §4 - safe to drop), the
enrichment inbox's itemIDs are **payload**: a dropped itemID means that item's
enrichment is never re-derived until the next startup/on-enable backlog scan.
The inbox is therefore `.unbounded` (no silent loss), with a bounded queue-depth
backpressure: when the pending queue exceeds an implementation-time cap (a
scheduler-memory tuning value, not one of the §3.4 `EnrichmentLimits` admission
bounds), the scheduler suspends consumption of further yields (the Authority's
`continuation.yield` is non-blocking, `V2-facts.md` cycle-1 fact, so the yielder
never blocks - the cap bounds scheduler memory, not the Authority). On overflow
(the cap exceeded and the Authority yields more), the overflow path is a
fallback **backlog scan** (§7.1-style row-absence/staleness scan over retained
items, bounded by the 5,000-item hard maximum) that re-discovers any itemID
whose inbox processing was deferred (not lost - the `.unbounded` inbox
guarantees no itemID is dropped) between the cap and consumption - the inbox is
best-effort precise targeting,
with the backlog scan as the completeness fallback. `E1-PERF-4` proves no itemID
is permanently lost between commit and enrichment under sustained load.

### 6.4 Authority methods (single-writer preservation)

New `HistoryAuthority` methods, all opening a fresh operation-local context and
releasing it before return (`05` §5), none advancing `ChangePosition`:

```swift
internal extension HistoryAuthority {
    // Read: source fetch (mirrors 05 §14.5 thumbnail source)
    internal enum EnrichmentSourceOutcome: Sendable {
        case selection(EnrichmentSourceSelection)
        case rowCurrent    // no-op skip: stored row already current (§6.5)
        case notApplicable
    }
    func enrichmentSource(for id: HistoryItemID) async throws -> EnrichmentSourceOutcome

    // Write: persist a derivation (separate transaction; not a History Commit)
    func persistEnrichment(_ pending: PendingEnrichment) async throws

    // Orphan sweep: remove EnrichmentRows whose itemID is no longer retained.
    // Bounded anti-join; performed by the Authority in its own operation-local
    // transaction (the scheduler only enqueues orphan IDs; it never opens a
    // context, preserving D22).
    func sweepOrphanedEnrichmentRows() async throws
}
```

`enrichmentSource` fetches the item, verifies its current `ContentVersion`,
derives Effective Content (`02` §2.6), collects eligible source candidates by
`typeIdentifier` (§3.1; no `PDFDocument` probe - it constructs no non-`Sendable`
framework object), computes each candidate's S1 fingerprint (§5), and returns
an `EnrichmentSourceOutcome` (§6.4): `.selection`, `.notApplicable`, or
`.rowCurrent` (the no-op skip). It performs no OCR and no PDF
text-layer probe. `persistEnrichment` re-checks the write-time fence inside the
transaction (§5.3: recompute the current source fingerprint, fingerprint-compare
to the fetch-time/stored fingerprint - evidence-not-identity, not byte-exact),
writes the `EnrichmentRow` **refreshing `contentVersionRaw` to the item's
current `ContentVersion`** (on every persist, including the no-re-OCR S1-win
`.reuseStored` refresh path) plus the scalar `recognizedText` and blob, and
commits. It yields **no** `HistoryInvalidation` (enrichment is not a History
Commit and advances no `ChangePosition`; see §4.1 - enrichment is not
live-observed). `sweepOrphanedEnrichmentRows` is the named writer for orphan
cleanup (§6.5); the scheduler never performs the deletion. None of these methods
is part of the `HistoryAction` dispatch (`05` §8); the closed `HistoryAction`
switch is unchanged.

### 6.5 EnrichmentRow lifecycle

- **Created/updated** by `persistEnrichment` when enrichment is enabled and the
  item has an eligible source. A **not-applicable** item, once evaluated, gets
  exactly one row with `statusRaw == notApplicable` (and `kind == "none"`, empty
  blob) so the scheduler does not re-evaluate it; this is the uniform lifecycle
  agreed by §3.2 and §8 (a missing row means *never evaluated* / `.pending` for
  an eligible item, never not-applicable). Only items possessing an image/PDF
  type identifier are enqueued and can receive a `notApplicable` row; an item
  with no image/PDF type identifier is never enqueued and `enrichmentStatus`
  resolves `.notApplicable` from the item's type identifiers (in
  `effectiveTypeIdentifiersBlob`, `05` §3.1 - a bounded projection-blob decode,
  not a scalar check, §8) without a row.
- **Invalidated** (becomes stale) when the item's source bytes change (S1
  fingerprint differs at the write-time fence); the scheduler re-derives. A
  `ContentVersion` advance with an unchanged fingerprint leaves the row current
  (the S1 win, §5.3) after the drain refreshes `contentVersionRaw`.
- **Removed (decoupled cleanup).** When the underlying item is retired, the
  retirement History Commit (`HistoryMutation.retire`, `02` §7) is **unchanged**
  - it deletes only `HistoryItemRow` and advances `ChangePosition` exactly as
  v1 (`05` §10). Because `EnrichmentRow` references the item by business-ID
  value (`itemID: UUID`, not a SwiftData `@Relationship`), retirement does
  **not** cascade-delete the row; the row becomes orphaned. Because `itemID`
  is never reused (`02` §7 plan-invariant 9 + D1, `05` §17), an orphan never self-heals and must be swept.
  Cleanup is performed by `HistoryAuthority.sweepOrphanedEnrichmentRows()`
  (§6.4): a bounded anti-join of `EnrichmentRow.itemID` against the retained
  `HistoryItemRow` set, deleted in the Authority's own operation-local
  transaction. The scheduler only **enqueues** orphan IDs (including IDs whose
  `enrichmentSource` fetch returns not-found); it **never opens a writable
  `ModelContext`**, preserving D22. The sweep trigger: every Nth drain (N an implementation-time cadence, not an
  `EnrichmentLimits` admission bound) and on the startup/on-enable backlog drain;
  a disable does not guarantee sweeping
  (orphaned rows are bounded by the retired-item count, ≤ the hard retained
  maximum, `06` §2). Because drains are commit-driven, an inactive user (no
  History Commits between launches) has removed-item OCR text linger as an
  orphan until the next app launch triggers the startup sweep; the sweep cadence
  is therefore **not wall-clock-bounded** for inactive users. The security record
  (Record 6, §9) states this retention window honestly: `remove` does not
  promptly delete derived OCR text; latency is unbounded between launches for
  inactive users. (A wall-clock periodic sweep is a future hardening option, not
  taken in V2-01.) This keeps every v1 History Commit transaction
  byte-for-byte unchanged; enrichment owns its own cleanup entirely.
- **Bounded re-derivation.** A rapidly-revised item (source bytes changing on
  each revision) is re-queued on each fence-fail discard. To prevent an
  unbounded re-derive loop across drains, the row carries a bounded
  re-derivation attempt counter (`reDerivationAttempts`, §3.2; the fixed
  `EnrichmentLimits` value 8, §3.4 - a fixed admission bound, not a runtime
  tuning knob, `06` §2) with backoff. The counter is a durable scalar column:
  it is **incremented, inside the persist transaction, on each fence-fail
  discard** (the transaction writes only the counter and creates the row if
  absent, so churn before any successful persist still counts) and **reset to
  0 on a successful persist** (a later `ContentVersion`-stable commit - the
  source stopped churning); once it reaches
  the cap of 8 the row transitions terminally to `statusRaw == failed` (search
  degrades to no-match for that item, per D21 safety). Because the counter is
  durable (persisted on the row, not held in scheduler memory), the cap survives
  a launch - a churning item cannot evade the 8-attempt bound across restarts, so
  a transiently-revised item that stops churning is not permanently failed (the
  next successful persist resets it to 0).
- **Not invalidated** by Copy Coalescing, pin, unpin, or retention-policy
  changes: those preserve the item ID and its source bytes. those commits
  preserve ContentVersion (`05` §9 occurrence/pin), so the drain's
  row-current no-op skip (§4 step 1) does no source fetch (the item-row
  metadata fetch remains) and no OCR for them. A
  retention that retires an item orphans its row (swept as above), not a
  transaction change.

## 7. Trigger and drain

The enrichment trigger is fully decoupled from the capture/revision commit
path:

1. **Startup drain.** `SwiftDataHistory.open` first creates the
   `EnrichmentConfigRow` singleton if absent (§3.5). Then, if
   `EnrichmentConfigRow.enabled`, the scheduler performs a bounded backlog scan:
   query retained items with image/PDF type identifiers whose `EnrichmentRow` is
   absent or stale, and enqueue them. This scans no Canonical/revision blob (it
   decodes the `effectiveTypeIdentifiersBlob` projection blob to filter by
   image/PDF UTI, which is permitted on startup - not a Canonical/revision blob;
   the O(retained) projection-blob decode cost is bounded by the hard retained
   maximum, `06` §2). The backlog scan is **dispatched to the scheduler after
   `open` returns** (the facade is published in `05` §13 step 12 first, then the
   scheduler runs the scan asynchronously on its own executor) - it does **not**
   run synchronously inside `open`, so store open is never blocked for user reads
   by enrichment. The startup drain also runs a `sweepOrphanedEnrichmentRows()`
   pass (§6.4). **G5 / P1 interaction:** the projection-blob decode over up to
   5,000 retained items is a new non-metadata startup cost introduced by V2-01
   (v1's startup is metadata-only, `05` §13 / G5 trigger `06` §3). If
   enrichment-enabled startup p95 exceeds the G5 budget (250 ms), the P1
   persistent-startup-checkpoint graft (V2-06) or an enrichment-specific
   checkpoint is required; this is assigned proof gate `E1-PERF-7`.
2. **Invalidation-driven drain (precise item targeting).** In post-commit step 2
   (`05` §11), alongside yielding `HistoryInvalidation` to observer
   continuations, the Authority yields the **affected itemID(s) it just
   executed** into the scheduler's `inbox` stream (§6.3) - it already has these
   IDs in hand from executing the `HistoryMutation` plan. So the scheduler
   enqueues the precise changed item(s), not a heuristic recent-page scan: a
   source-changing revision on an old, not-recently-copied item is re-derived
   promptly instead of waiting until restart. Debounced, the scheduler drains up
   to a per-cycle budget in deterministic order (§6.3); if more remain, it
   reschedules. A received itemID whose item is now gone (retired) is skipped
   by the drain; its orphaned row is removed by the
   Nth-drain/startup/on-enable sweep (§6.5). This drain uses precise itemID
   targeting - no position scan and no `lastDrainPosition` watermark (§3.5).
3. **On enable.** Toggling `enabled` to `true` triggers a startup-style backlog
   drain (and an orphan sweep).

The drain decodes Canonical/revision/source blobs only via the Authority's
`enrichmentSource` (one item at a time, on the background path where decode is
permitted, §5.3) - never on the search path. It is background, cancelable, and
may be paused under memory pressure. Its loss or interruption leaves enrichment
rows absent/stale; search degrades to the v1 corpus, never to wrong text (D21).

## 8. Public surface (EnrichmentHistory)

A new public protocol in `HistoryCore`, conformed to by `SwiftDataHistory`. It
is a "distinct concern" protocol (`V2-00` §6.5), not an extension of
`ClipboardHistory`:

```swift
public protocol EnrichmentHistory: Sendable {
    func enrichmentStatus(for id: HistoryItemID) async throws -> EnrichmentStatus
    func setEnrichmentEnabled(_ enabled: Bool) async throws
}

public enum EnrichmentStatus: Sendable, Hashable {
    case notApplicable        // no eligible image/PDF source
    case pending              // eligible; derivation not yet persisted
    case ready                // enrichment text current (ContentVersion fence passes, §5.3)
    case failed               // derivation failed (non-fatal; search degrades)
}
```

- `enrichmentStatus(for:)` reads scalar columns where a row exists. It resolves
  an item with no image/PDF type identifier to `.notApplicable` from the item's
  type identifiers - which live **only** in `HistoryItemRow.effectiveTypeIdentifiersBlob`
  (`05` §3.1), a `Data` blob, not a scalar column. So the **absent-row**
  `.notApplicable` path (an eligible-looking item never evaluated, vs. a truly
  not-applicable item) decodes the bounded `effectiveTypeIdentifiersBlob`
  projection (not Canonical/revision) to resolve the eligible-type check - a
  bounded one-per-status-query blob decode, not a scalar no-decode read. When a
  row exists, it maps `statusRaw` + the **read-time `ContentVersion` fence**
  (scalar `row.contentVersionRaw == current ContentVersion.rawValue`, plus the
  scalar `enrichmentSchemaVersion`/`derivationSchemaVersion` checks, §5.3) to the
  public status - no Canonical/revision/enrichment-blob decode (the scalar
  columns suffice). A missing row for an eligible item is `.pending`; a row with
  `statusRaw == notApplicable` is `.notApplicable` (a missing row never means
  not-applicable). A `.ready` row whose `ContentVersion` advanced is reported
  `.pending` (stale, re-derivation pending). Any row - including `.notApplicable`
  - whose read-time `ContentVersion` fence fails is likewise reported `.pending`
  (stale, re-evaluation pending); the drain re-evaluates and rewrites the row. Failure translation follows v1
  (`05` §16): a missing item is `.notFound`; a corrupt row is
  `.persistence(.corruptStoredValue)`/`.invariantViolation`.
- `setEnrichmentEnabled(_:)` toggles the durable capability flag through the
  Authority. It is **not** a `HistoryAction`: it does not mutate history items
  and does not advance `ChangePosition`. Because it advances no `ChangePosition`,
  it yields **no** `HistoryInvalidation` and does not wake a live
  `observe(.search)` (§4.1 - enrichment/toggle changes are not live-observed);
  the UI re-browses or waits for the next real History Commit to reflect the
  new enabled state. Like `persistEnrichment`, the toggle bumps the Authority's
  `enrichmentCorpusEpoch` in the same serialization (§4.1), so a V2-03
  collection-cached search page cannot survive the toggle stale (V2-03 §7.1/§7.2).
  Disabling stops new derivation but retains existing rows
  (search simply stops consulting them until re-enabled); an orphan sweep runs
  on re-enable (§6.5). Failure translation follows v1 (`05` §16): the method
  takes a `Bool` and targets no item, so it defines no `.invalidInput` and no
  `.notFound` case; a failed durable `EnrichmentConfigRow` write fails
  `.persistence(.transaction)` (transaction closure or commit failure,
  `05` §16), and a violated storage invariant - e.g. the exactly-one
  singleton guarantee of §3.5 - fails `.persistence(.invariantViolation)`.
  V2-07 §4.2's `try?` swallow therefore records no typed failure for
  these two cases (UI feedback is limited to later status reads).
- `EnrichmentHistory` reuses `HistoryItemID` verbatim and adds no name that
  collides with v1 vocabulary (`V2-00` §9).

### 8.1 Exhaustive-switch and code-interaction impact

- **`HistoryAction` switch (`05` §8):** unchanged. Enrichment adds no case. The
  closed enum and its exhaustive dispatch are untouched.
- **`HistoryMutation` / `PlannedOutcome` (`02` §7):** unchanged. Enrichment is
  not a Domain mutation; the Domain is unaware of derivations (preserves D16,
  D17, D18).
- **`ClipboardHistory` protocol (`03a` §3):** unchanged. A v1 caller that holds
  `any ClipboardHistory` and ignores `EnrichmentHistory` behaves exactly as on
  v1. `SwiftDataHistory` conforms to both; `ClipyApp` casts to `EnrichmentHistory`
  only when it wants V2 surface.
- **`SwiftDataHistory` field set (`05` §2):** extended with
  `EnrichmentWorker` and `EnrichmentScheduler`. Both are `actor` types, so the
  derived `Sendable` conformance is preserved (`01` §6).

## 9. Security boundaries

- **On-device OCR (verified).** "All of Vision's processing happens on the
  user's device" (`V2-facts.md` fact 6). Image/PDF bytes never leave the
  process; there is no network path and no cloud text service. Enrichment is
  not external-facing — it is an internal derivation, not an X1
  `ExternalGateway` boundary (`V2-00` §6.4).
- **Byte confinement.** Source bytes are fetched as immutable `Sendable` `Data`
  inside one Authority interval and handed to the worker; no `@Model`,
  `CGImage`, `NSImage`, or `PDFDocument` crosses isolation (`01` §6).
- **Storage discipline.** Enrichment text uses `@Attribute(.externalStorage)`
  (`05` §3.1), the same hint as Canonical/revision blobs; correctness and byte
  bounds do not depend on it (`01` §10).
- **TCC / entitlement.** No additional TCC permission is expected, because OCR
  processes bytes already in-process (captured pasteboard content), and Vision
  is documented on-device. This is assigned proof gate `E1-SECURITY-1`
  (`V2-facts.md` OPEN questions item 6): confirm no privacy-usage string or
  entitlement is required on macOS 26 for on-device `VNRecognizeTextRequest`.
- **Content-sensitivity amplification (Record 6).** v1 stores image bytes but
  they are **not** full-text-searchable. V2 derives and durably persists
  recognized text, making the textual content of copied images/screenshots
  (which users often copy precisely because they are sensitive - a screenshot
  of credentials, a photo of a document) durable **and** full-text-searchable.
  This is a new searchable exposure of image content with backup/restore and
  search-leakage implications, surfaced to UX (V2-07) as a user-visible data
  practice and recorded in the security boundary (Record 6).
- **Deletion latency.** Because cleanup is decoupled (§6.5), when a user
  removes an item the `EnrichmentRow` (OCR text) is **not** deleted in that
  History Commit - it lingers as an orphan until the lazy `sweepOrphanedEnrichmentRows()`
  sweep. So `remove` does not promptly delete the derived text of the removed
  item; the deletion latency is bounded by the sweep cadence (every Nth drain
  and on startup/on-enable) - but because drains are commit-driven, an inactive
  user's removed-item OCR text lingers until the next app launch (the startup
  sweep). The sweep is **not wall-clock-bounded** for inactive users. The
  security record states this retention window honestly (Record 6). (A
  synchronous in-commit `EnrichmentRow` delete is **not** taken, to keep every
  v1 History Commit transaction byte-for-byte unchanged; the V2 table is touched
  only in separate Authority transactions.)
- **Crash safety.** The enrichment index is a derivation. Its loss or corruption
  degrades search to the v1 corpus and triggers a rebuild; it never produces
  wrong durable history state (decisions §13, §14; D20, D22).

## 10. Graft-admission records (`V2-00` §4)

### Record 1 — Lifted exclusion + evidence trigger

- **E1** lifts `00` §2 ("Enrichment and OCR") and `06` §4
  ("Enrichment/OCR and enrichment-derived search corpus"). Evidence trigger:
  approved product spec **and** OCR p95 within the agreed budget on the minimum
  supported hardware profile (`V2-00` §3).
- **S1** lifts `06` §3 G4 ("Per-purpose content subversions/source stamps").
  Evidence trigger: profiling shows material enrichment work repeatedly
  invalidated by Effective Content changes that provably leave the enrichment
  purpose's source bytes unchanged (`V2-00` §3; `V2-facts.md` facts ground the
  Vision/PDFKit primitives S1 builds on).

### Record 2 — Invariant impact

D1–D19 are **preserved unchanged**. In particular:

- **D2 (Canonical immutability):** enrichment never touches Canonical Content;
  it derives from Effective Content source bytes.
- **D5/D6 (precise tokens):** enrichment mints neither `ContentVersion` nor
  `ChangePosition`; the persist transaction advances neither.
- **D7 (fingerprint-is-evidence):** the S1 source fingerprint is evidence, never
  identity - exactly as v1 dedup treats `ContentFingerprint` (`02` §2.2). D7 is
  **preserved at read time**: the read-time serve arbiter is the collision-free
  `ContentVersion` counter (D5), never the fingerprint. At **write time** the
  fence *is* the fingerprint (the fetch-time derivation bytes are not retained
  across the worker boundary, and the S1-win path cannot recover the bytes the
  stored text was derived from - §5.1), so D7 is **evidence-bounded, not
  identity-exact** at write time: a collision on the S1-win path could refresh
  `contentVersionRaw` for changed bytes, serving stale OCR text until the next
  re-derivation. The residual is the xxh3-64 birthday bound (~7e-13 at the
  retained scale), accepted (enrichment is a derivation; loss degrades to a
  miss, never corrupting durable history). D7 is therefore **partially
  transferred**: exact at read time (the `ContentVersion` counter), fingerprint-
  bounded at write time. The v1 thumbnail fence (`04` §9) is exact because it
  fences on `ContentVersion` (a precise monotone counter) and re-decodes on a
  version advance; V2-01's read-time fence shares that exactness, but its
  write-time S1-win shortcut accepts the fingerprint residual rather than
  re-OCR on every `ContentVersion` advance.
- **Enrichment is not live-observed (no `04` §4 extension).** `persistEnrichment`
  and `setEnrichmentEnabled` advance no `ChangePosition` and are not History
  Commits, so they yield **no** `HistoryInvalidation`. v1's race-free observer
  wakes only on an invalidation whose position is strictly greater than the
  yielded page (`04` §5 steps 4 and 6), and a same-position synthetic
  invalidation would be inert. Rather than extend `04` §5's wake predicate (a
  deeper internal-coherence change), V2-01 retracts the live-refresh claim:
  enrichment/toggle changes are reflected on the next real History Commit or a
  fresh `browse(.search)` (§4.1). No `04` §4 invalidation extension is taken;
  no public invalidation contract changes.
- **D8 (complete facts):** enrichment is a derivation, not a planning fact; the
  Domain planners receive no enrichment input and remain complete-fact-bounded.
- **D11 (Monotone occurrence):** enrichment does not participate in Copy
  Coalescing; occurrence monotonicity is untouched.
- **D18 (Semantic-plan completeness):** enrichment is not a `HistoryMutation`;
  the Domain and stamping contract are untouched.
- The v1 thumbnail fence (`04` §9) is the model for the enrichment fence (D21).

V2-01 **extends** the invariant set with D20–D22 (§11). No D1–D19 is weakened.

### Record 3 — V2 proof gates

The analog of Part VI §6 (compile), §7 (schema/platform), §9 (perf) on macOS 26:

Gates follow spec-section order, not ID order: PERF-5 and BEHAVIOR-1 are
adjacent status gates (BEHAVIOR-1 covers the mapping PERF-5's mechanism
bound cannot), then PERF-6/3/4/7 run worker, capture isolation, drain,
startup.

- **E1-COMPILE-1 (compile/dependency).** Swift 6 complete strict-concurrency
  build succeeds with `Vision`/`PDFKit` imported only in `HistoryStorage`;
  `HistoryCore` enrichment types import only Foundation; no `@unchecked Sendable`
  or `nonisolated(unsafe)` is introduced; `EnrichmentWorker`/`EnrichmentScheduler`
  are `actor` types so `SwiftDataHistory: Sendable` is derived.
- **E1-COMPILE-2 (non-Sendable confinement + no completion handler).**
  `VNRecognizeTextRequest`, `VNImageRequestHandler`, `VNRecognizedText*`, and
  `PDFDocument`/`PDFPage` are confirmed non-`Sendable` and are created,
  configured, and consumed entirely within `EnrichmentWorker`; none crosses
  isolation. **Widened:** V2-01 must use the no-completion-handler path
  (`init()` / inherited `VNRequest.init(completionHandler: nil)`) and read
  `request.results` synchronously after the blocking `perform(_:)` returns - not
  a supplied completion handler, which Apple documents runs on a different queue
  than the `perform(_:)` caller and would be a Swift 6 isolation violation
  (`V2-facts.md` cycle-1 facts: `usesLanguageCorrection` is
  `var usesLanguageCorrection: Bool { get set }` and
  `init(completionHandler:)` is inherited from `VNRequest` - both confirmed).
- **E1-COMPILE-3 (import gate).** The v1 source gate (`01` §9) is extended to
  permit `import Vision`/`import PDFKit` in `HistoryStorage` only. Confirmed at
  the API level (`V2-facts.md` cycle-1 facts): `PDFDocument`/`PDFPage` inherit
  only from `NSObject` (no `NSView`/AppKit type) and are cross-platform
  (iOS/tvOS/visionOS have no AppKit), so the model surface V2-01 uses is
  AppKit-free; `import PDFKit` is a distinct source statement from `import
  AppKit`. Residual (OPEN, retained here): whether `PDFKit.framework` transitively
  **links** `AppKit.framework` at the binary level (PDFView is an NSView) - a
  build/link-map judgment. The CoreGraphics `CGPDFDocument` fallback is **not** a
  drop-in equivalent of `PDFPage.string` (it requires content-stream parsing for
  Tj/TJ operators and font/CMap handling); if PDFKit is disallowed, the PDF
  half of E1 needs its own sub-design with a proof gate, not a one-line fallback.
- **E1-PLATFORM-1 (schema migration).** `MigrationStage.lightweight` is
  declared `case lightweight(fromVersion: any VersionedSchema.Type, toVersion:
  any VersionedSchema.Type)` (`V2-facts.md` cycle-1 fact) - both arguments must
  be `VersionedSchema`-conforming **types**. In v1, `HistorySchemaV1` is a
  conceptual label over a plain `Schema` *value* (`internal let v1Schema =
  Schema(HistoryItemRow.self, LastChangePositionRow.self)`, `05` §3), **not** a
  `VersionedSchema` type, and it is frozen. M1 therefore retrofits an
  **additive** `HistorySchemaV1: VersionedSchema` type in `HistoryStorage`
  (supplying `versionIdentifier` and the unchanged model set
  `{HistoryItemRow, LastChangePositionRow}`) to anchor the migration - this does
  not modify v1's `v1Schema` value, models, rows, or behavior (an additive,
behavior-preserving change anticipated by `05` §3, which states "a future
schema change increments it and adds a migration plan" in its Part V §17
migration stance). `HistorySchemaV2` is the frozen v1
  models plus `EnrichmentRow`/`EnrichmentConfigRow`; the migration is a
  `SchemaMigrationPlan` with the lightweight stage, purely additive, no v1 row
  or column rewritten. Confirms a v1 store opens under the V2 plan with v1 rows
  untouched; folded into `E1-PLATFORM-4`.
- **E1-PLATFORM-2 (codec round trip).** `EnrichmentBlobV1` encode/decode round
  trips and rejects every corruption class (unknown version, oversize text,
  invalid kind/level) as `.persistence(.corruptStoredValue)` /
  `.invariantViolation` (`05` §16), mirroring v1 codec proofs (Part VI §7.4).
- **E1-PLATFORM-3 (OCR revision pin).** On macOS 26 the revision to pin is
  **Revision 3** (`VNRecognizeTextRequestRevision3`, macOS 13.0+): Revisions 1
  and 2 are **deprecated** (`V2-facts.md` cycle-1 fact). The language set is
  fixture-locked via the **non-deprecated** instance method
  `func supportedRecognitionLanguages() throws -> [String]` (reflecting the
  revision set on the request) - **not** the deprecated class method
  `supportedRecognitionLanguages(for:revision:)`. The recognition level
  (`fast`/`accurate`), language set, and `derivationSchemaVersion` are recorded
  (path+revision determines language support, `V2-facts.md` cycle-1 facts).
- **E1-PLATFORM-UTI (decodable image UTI set).** The eligible image UTI set
  (`public.png`, `public.jpeg`, `public.tiff`, `com.compuserve.gif`, HEIC, ...) is
  fixture-locked, but the set `VNImageRequestHandler(data:)` actually decodes on
  macOS 26 is **not** MCP-verified (`V2-facts.md` fact 3 confirms only that
  `init(data:)` exists, not the accepted formats). Fix the eligibility set to the
  verified set and clarify HEIC and animated-GIF handling; do not rely on the
  "ImageIO-decodable" hedge in §2.1.
- **E1-PLATFORM-4 (migration atomicity).** The V1->V2 additive migration leaves
  the Signature Index, singleton position, and v1 projections untouched
  (`V2-facts.md` OPEN questions item 8); enrichment rows are absent on a
  fresh v1 store.
- **E1-PERF-1 (OCR p95 admission workload).** Per-OCR p95 on the minimum
  supported hardware is within the agreed budget — the E1 evidence trigger
  itself. OCR completion has no public signal (E.8 adds no push or polling
  loop), so no public envelope can express it: this must be admitted as a
  **named workload** in the `06` §9 runner table (approved scale, bound,
  headroom policy, and hardware profile), driven package-internally on the
  greenfield scaffold (seeder precedent, `06` §9) with per-OCR percentiles
  in the versioned fixture; debug traces are never evidence, and the
  current repo is never measured (`06` §9).
- **E1-PERF-2 (search p95 / no decode).** Enrichment-inclusive search p95 ≤ v1
  search p95 + a bounded enrichment-text scan. The read-time fence is the scalar
  `contentVersionRaw == contentVersion.rawValue` plus scalar
  `enrichmentSchemaVersion`/`derivationSchemaVersion` checks; the served text is
  the scalar `recognizedText` column (§3.2, the `searchBody` analogue). The
  search path decodes **zero** Canonical/revision/enrichment blobs in the common
  case (preserves Part VI §7.5, `05` §14.2).
- **E1-PERF-5 (enrichmentStatus + staleness cheap path).** When an
  `EnrichmentRow` exists, `enrichmentStatus(for:)` and the startup staleness scan
  resolve from scalar columns only (no blob decode);
  `derivationSchemaVersion` is mirrored as a scalar column (§3.2) so a
  materializer-version bump is detectable without decoding the enrichment blob.
  The **absent-row** `.notApplicable` path decodes the bounded
  `effectiveTypeIdentifiersBlob` projection (not Canonical/revision) to resolve
  the eligible-type check - a bounded one-per-query projection decode, not a
  no-decode read (§8).
- **E1-BEHAVIOR-1 (EnrichmentHistory public-contract mapping).**
  Fixture tests of the public `EnrichmentStatus` mapping and toggle
  semantics, none of which `E1-PERF-5` (a scalar-read mechanism
  bound) covers: (a) an absent row for an item whose
  `effectiveTypeIdentifiersBlob` carries an image/PDF identifier
  reads `.pending`, and one without reads `.notApplicable` (§8;
  §6.5); (b) a `.ready` row whose item's `ContentVersion` advanced
  reads `.pending` (§8); (c) the durable `reDerivationAttempts`
  cap of 8 transitions the row terminally to `.failed` (§3.2/§6.5);
  (d) `setEnrichmentEnabled` retains rows on disable, yields no
  `HistoryInvalidation`, and bumps `enrichmentCorpusEpoch` (§8);
  (e) the drain's `.rowCurrent` no-op skip persists nothing when
  the stored row is current and `ready`/`notApplicable` (§6.4/§6.5).
- **E1-PERF-6 (OCR cooperative-pool isolation).** The blocking `perform(_:)` /
  PDF iteration runs on a custom non-cooperative executor overriding the
  `EnrichmentWorker` actor (§6.2 - not a detached `Task`, which would violate
  non-`Sendable` confinement); the executor API's existence is subsumed by
  `E1-COMPILE-1` (the Swift 6 strict-concurrency build compiles the
  `Actor.unownedExecutor` override) and cited in §13, closing the API-existence
  gap. Prove, as the public envelope, that user-commit and search p95 under
  a sustained enrichment backlog stay within the E1 budgets of their
  no-enrichment baselines (same runner and hardware, `06` §9) - pool and
  Authority starvation is observable only through that envelope - and bound
  per-OCR input size.
- **E1-PERF-3 (capture isolation + bounded persist blocking).** The
  capture/revision commit interval excludes OCR, PDF parsing, and enrichment
  writes. `persistEnrichment` serializes on `HistoryAuthority` (single-writer,
  `00` §3.3), so its transaction (including the source-blob re-fetch + fingerprint
  recompute the write-time fence requires) **does block** a concurrent user
  commit for the persist transaction's duration. Prove the public envelope
  instead: user-commit p95 with a drain active under sustained backlog stays
  within the E1 budget of the no-enrichment baseline - same runner, hardware,
  and 101-public-call unit (`06` §9); the persist duration itself is recorded
  only as a non-percentile fixture sum. Bound the drain rate (max K
  persists/sec, yielding between) so a sustained backlog does not saturate
  the Authority.
- **E1-PERF-4 (drain non-blocking).** The debounced enrichment drain never
  blocks the `HistoryAuthority` commit path's post-commit phase (the inbox yield
  is non-blocking, `V2-facts.md` cycle-1 fact) and never starves user commits
  (`V2-facts.md` OPEN questions item 7); prove no itemID is permanently lost
  between commit and enrichment under sustained load (§6.3 inbox buffering).
- **E1-PERF-7 (startup-with-enrichment p95).** With enrichment enabled, startup
  decodes the `effectiveTypeIdentifiersBlob` projection over up to 5,000 retained
  items (a new non-metadata startup cost, §7.1). Prove enrichment-enabled startup
  p95 is within budget; if it exceeds the G5 budget (`06` §3, 250 ms), P1
  (V2-06) or an enrichment-specific checkpoint is required.

### Record 4 — Cache-law compliance

Enrichment is a **durable derived projection**, not a transparent cache. The
Part IV §12 law ("for the same authoritative source state and request, cache
hit, cache miss, eviction, disabled cache, and process restart produce
semantically identical values and failures; only latency and resource use may
differ") is **inapplicable as stated**, because enrichment **extends** search
semantics: presence adds matches that absence cannot produce. The two are not
"semantically identical" and are not claimed to be.

Instead, V2-01 is governed by the **derivation-fence law** (D21, §11): an
enrichment result is either absent or correct for its recorded source version;
a stale fence (source bytes changed) is excluded from search or re-derived,
never relabeled as current. Concretely:

- **Disabled enrichment** is the v1-faithful path: search is byte-for-byte v1
  (no enrichment dimension), so cache-law identity trivially holds (there is no
  cache).
- **Enabled enrichment, row present and current:** search may match OCR text.
- **Enabled enrichment, row absent/stale/failed:** search behaves as v1 for that
  item (no OCR match); a rebuild/re-derivation eventually restores the match.
  Loss degrades to a miss, never to wrong bytes — exactly the cache-law's safety
  half, restated for a derivation.
- **Restart:** enrichment rows are durable; a crash mid-derive leaves a
  `pending`/absent row, never a partial/wrong one (the persist is one
  transaction, `05` §10).

This is recorded, not hidden: the owning doc states the law does not apply as a
transparent cache and substitutes the derivation-fence law (D21).

### Record 5 — Migration impact (Part V §17 three layers)

- **Schema layer (SwiftData migration):** add `EnrichmentRow` and
  `EnrichmentConfigRow` tables. `HistorySchemaV1` is frozen (`V2-00` §2.1);
  `HistorySchemaV2` = the unchanged v1 models (`HistoryItemRow`,
  `LastChangePositionRow`) **plus** the V2 models. Because
  `MigrationStage.lightweight` requires `VersionedSchema`-conforming *types*
  while v1's `HistorySchemaV1` is a plain `Schema` *value* (`05` §3), M1 retrofits
  an additive `HistorySchemaV1: VersionedSchema` type (see `E1-PLATFORM-1`) - it
  does not modify the frozen `v1Schema` value. The migration is
  `MigrationStage.lightweight(fromVersion: HistorySchemaV1.self,
  toVersion: HistorySchemaV2.self)` (`V2-facts.md` cycle-1 fact) - purely
  additive; no v1 row or column is rewritten. **Data bootstrap (not migration):**
  a lightweight migration adds schema, not data; `SwiftDataHistory.open` creates
  the `EnrichmentConfigRow` singleton (`enabled == false`) if absent (§3.5),
  mirroring the v1 `LastChangePositionRow` singleton creation (`05` §13 step 3),
  so a migrated v1 store starts v1-faithful (disabled). `EnrichmentRow` carries
  a scalar `recognizedText: String` column (§3.2) - an additive column on the
  new V2 table (not a v1 column), populated by `persistEnrichment` alongside the
  blob; no v1 row or column is rewritten. Proof gate
  `E1-PLATFORM-1`/`E1-PLATFORM-4`.
- **Blob layer (versioned blob migration):** `EnrichmentBlobV1` is a new codec
  (`formatVersion == 1`). No v1 blob (`CanonicalBlobV1`, `RevisionStateBlobV1`,
  `SignatureBlobV1`, `EffectiveTypeIdentifiersBlobV1`, `05` §4) is
  reinterpreted. A future enrichment codec bump would add `EnrichmentBlobV2` and
  a derivation-schema-version advance that re-derives, exactly as v1 projection
  schema changes rebuild (`05` §15).
- **Projection layer (rebuild):** enrichment text is a rebuildable projection.
  Loss or schema advance triggers re-derivation from source bytes (re-OCR). No
  migration invents missing bytes, reinterprets an old `ContentVersion`, reuses
  removed IDs, or enables capture before Signature Index completeness is
  restored (`V2-00` §5 decision 18, verbatim "Signature Index / change-journal
  completeness"; E1's analogue is enrichment-index completeness, restored by
  the orphan/startup sweep, §6.4).

### Record 6 — Security boundary

Enrichment is **not external-facing** (no X1 boundary). Its security record:

- **Trust boundary:** the process boundary; no external/network input.
- **On-device guarantee:** Vision processing is on-device (`V2-facts.md` fact 6);
  PDFKit extraction is local. No bytes leave the process.
- **Capability model:** enrichment is gated by `EnrichmentConfigRow.enabled`
  (default false). There is no per-item grant; enrichment is an internal
  derivation, unlike X1's capability-scoped external writes.
- **TCC/sandbox/entitlement:** no additional permission expected (bytes already
  in-process); proof gate `E1-SECURITY-1` confirms (`V2-facts.md`
  OPEN questions item 6).
- **Content-sensitivity amplification:** V2 durably persists and full-text-indexes
  the textual content of copied images/PDFs (a sensitivity escalation for image
  content, with backup/restore and search-leakage implications) - surfaced to UX
  (V2-07) as a user-visible data practice (§9).
- **PDF text-layer quality (accepted limitation):** `PDFPage.string` can return
  non-empty mojibake for PDFs whose fonts lack a ToUnicode CMap (§2.2). V2-01
  does not validate text-layer quality; such garbage is indexed as enrichment
  text, producing wrong-but-safe search matches. This is garbage-in-garbage-out,
  bounded by the 256 KiB text bound - it degrades to a wrong search match, never
  a durability or correctness invariant break. No proof gate (accepted).
- **Deletion latency:** removed-item OCR text is not deleted in the retirement
  History Commit; it lingers as an orphan until the lazy sweep (§6.5). Because
  drains are commit-driven, the sweep is **not wall-clock-bounded** for inactive
  users - removed-item OCR text lingers until the next app launch (startup
  sweep). The security record states this retention window honestly; a
  wall-clock periodic sweep is a future hardening option, not taken in V2-01.
- **Audit:** enrichment is not an audited external write (X2, V2-05); it produces
  no `OperationRecord`. It is internal derivation state.

## 11. New invariants D20–D22 (extend `02` §14)

- **D20 Enrichment derivation purity.** Enrichment derives searchable text from
  Canonical/Effective Content source bytes only. It never overwrites Canonical
  Content, never mints or advances `ContentVersion` or `ChangePosition`, and
  never participates in dedup identity or Copy Coalescing. *(Applies the
  principles of D2, D5, D6, D7 to the enrichment domain - those v1 invariants are
  themselves preserved unchanged per Record 2; D20 governs the new enrichment
  domain consistently with them. Restates `V2-00` §5 decision 13 as an
  invariant.)*

- **D21 Enrichment version fence.** Every persisted enrichment result carries
  the source `ContentVersion` and a per-purpose source fingerprint (S1) over
  the source bytes it was derived from. The **read-time** fence is the scalar
  `contentVersionRaw == current ContentVersion.rawValue` (collision-free, D5; no
  blob decode); the **write-time/drain** fence is the S1 source fingerprint
  (xxh3-64, evidence-not-identity per D7, §5.3) - it is **not** byte-exact,
  because the fetch-time derivation bytes are not retained across the worker
  boundary and the S1-win path cannot recover the bytes the stored text was
  derived from (§5.1). An enrichment result is served by search only when the
  read-time fence passes; otherwise it is excluded or re-derived. A stale fence
  is never relabeled as current, and current bytes are never served under a
  stale fence **except** the residual: an xxh3-64 collision on the S1-win path
  (~7e-13 at the retained scale) could refresh `contentVersionRaw` for changed
  bytes, serving stale OCR text until the next re-derivation. Because the
  read-time arbiter is a counter (not a hash) and the write-time arbiter is a
  fingerprint (evidence, D7), the collision residual is the xxh3-64 birthday
  bound - accepted (enrichment is a derivation; loss degrades to a miss, never
  corrupting durable history). D7 is exact at read time (the `ContentVersion`
  counter is the serve arbiter) and evidence-bounded at write time. *(Mirrors
  `04` §9 thumbnail fence (which fences on `ContentVersion`, exact, and re-decodes
  on a version advance) and the `04` §12 cache-key requirement for an
  authoritative version + materializer schema version, adapted to a derivation;
  the S1-win shortcut accepts the fingerprint residual rather than re-OCR on
  every `ContentVersion` advance.)*

- **D22 Enrichment single-writer persistence.** Enrichment durable state
  (`EnrichmentRow`, `EnrichmentConfigRow`) is written only through
  `HistoryAuthority`, including orphan cleanup (`sweepOrphanedEnrichmentRows`,
  §6.4); no component outside the Authority - in particular the
  `EnrichmentScheduler`, which only enqueues IDs - creates a writable
  `ModelContext` for the enrichment tables. Enrichment loss or corruption
  degrades search to the v1 corpus and triggers a rebuild; it never produces
  wrong durable history state. *(Extends `00` §3.3 single-writer to the V2
  tables; restates `V2-00` §6.3 isolation.)*

These extend D1–D19; none weakens any. The v1 self-review gate (`06` §10) and the V2 self-review gate (`V2-00` §8)
both apply: a mechanical scan confirms no v1 public type/schema column/codec/
invariant is redefined and that every V2 type introduced - `EnrichmentHistory`,
`EnrichmentStatus`, `EnrichmentRow`, `EnrichmentBlobV1`,
`EnrichmentSourceFingerprint`, `EnrichmentConfigRow`, `EnrichmentSourceSelection`,
`EnrichmentSourceKind`, `EnrichmentSourceCandidate`, `EnrichmentDerivation`,
`PendingEnrichment`, `EnrichmentWorker`, `EnrichmentScheduler`, `EnrichmentLimits`,
`HistorySchemaV2`, and the retrofitted `HistorySchemaV1: VersionedSchema` type
(M1-owned; concretizing the v1 conceptual label `HistorySchemaV1` into a
`VersionedSchema` type is the additive, behavior-preserving retrofit `05` §17
anticipates, not a redefinition of the frozen `v1Schema` value, §10
`E1-PLATFORM-1`/Record 5) - does not collide with v1 names. The v1 internal
`SearchCorpusRow` gains a capability-gated `enrichmentText: String?` field (§4.2,
an additive extension of a v1 *internal* type per `V2-00` §2.1, not a redefinition
of a v1 public type). The deleted-vocabulary scan (`06` §10) mechanically scans
`docs/` (including `docs/v2/`); V2 docs use any deleted token from `06` §10's
scan list (`SourceStamp`, `VersionMap`, ...) or `04` §11's absent-machinery list
(`ItemKey<Purpose>`, "reap state machines", ...) only in verbatim-quoted or
explicit-rejection statements, which both sections permit - so the scan passes
on that basis.
`EnrichmentSourceFingerprint` is a V2-scoped per-purpose fingerprint
(aligning with `ContentFingerprint`, `02` §2.2), not the deleted generic
`SourceStamp`/`ItemKey<Purpose>` framework (`04` §11, `V2-00` §3.1).


## 12. UX interaction hooks (deferred detail to V2-07)

V2-01 provides the data hooks V2-07 (UX) consumes; it owns no SwiftUI:

- **Enrichment status indicator.** A `HistoryRow`-adjacent status (pending/ready/
  failed/not-applicable) sourced from `enrichmentStatus(for:)`, rendered on the
  main actor from `HistoryCore` DTOs only (`V2-00` §6.6). Observation remains
  snapshot-replacement (`04` §5). Because `persistEnrichment` and
  `setEnrichmentEnabled` advance no `ChangePosition` and yield **no**
  `HistoryInvalidation` (§4.1), enrichment/toggle changes are **not
  live-observed**: an active `observe(.search)` reflects new OCR text / the
  toggle only on the next real History Commit (which advances `ChangePosition`
  and wakes the observer) or on a fresh `browse(.search)` call (which always
  reflects current state). V2-07 re-browses on the next History Commit / a fresh
  `browse(.search)` (no OCR-completion push - `EnrichmentHistory` exposes no
  observation stream, §8) and on toggle.
- **Enrichment-enabled setting.** A settings toggle bound to
  `setEnrichmentEnabled(_:)`; toggling off does not delete existing rows.
- **Search transparency.** When enrichment is on, an OCR-text match is shown as
  a `SearchPresentation` snippet (UTF-16 ranges into the enrichment excerpt),
  using the existing public presentation type unchanged (`03b` §8). No new
  public DTO is required for the match itself.
- **Accessibility / localization.** Enrichment status text and the setting are
  localizable; OCR language selection (§10 `E1-PLATFORM-3`) is a separate
  concern from UI localization (P2, V2-06) and is fixture-locked, not
  user-configurable in V2-01.

## 13. Platform reference anchors

Implementation must verify against the macOS 26 SDK rather than copy pseudocode
(`05` §18, `00` §5):

- [VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest) - on-device text recognition (macOS 10.15+; non-`Sendable`).
- [VNRequest.init(completionHandler:)](https://developer.apple.com/documentation/vision/vnrequest/init(completionhandler:)) - inherited initializer; `completionHandler` defaults to `nil` and runs on a different queue than `perform(_:)` (use the no-handler path).
- [VNRecognizeTextRequest.usesLanguageCorrection](https://developer.apple.com/documentation/vision/vnrecognizetextrequest/useslanguagecorrection) - `var ...: Bool { get set }`.
- [VNRecognizeTextRequestRevision3](https://developer.apple.com/documentation/vision/vnrecognizetextrequestrevision3) - the only non-deprecated revision (macOS 13.0+); pin on macOS 26.
- [VNRecognizeTextRequest.supportedRecognitionLanguages()](https://developer.apple.com/documentation/vision/vnrecognizetextrequest) - non-deprecated instance method (the `for:revision:` class method is deprecated).
- [VNImageRequestHandler.init(data:options:)](https://developer.apple.com/documentation/vision/vnimagerequesthandler/init(data:options:)) - handler from image `Data`.
- [VNImageRequestHandler.perform(_:)](https://developer.apple.com/documentation/vision/vnimagerequesthandler/perform(_:)) - synchronous, throwing, blocking.
- [Recognizing Text in Images](https://developer.apple.com/documentation/vision/recognizing-text-in-images) - on-device guarantee; fast/accurate paths; language config.
- [PDFDocument.init(data:)](https://developer.apple.com/documentation/pdfkit/pdfdocument/init(data:)) - failable (`init?(data:)`); non-`Sendable`; cross-platform (AppKit-free at the API level).
- [PDFDocument.page(at:)](https://developer.apple.com/documentation/pdfkit/pdfdocument/page(at:)) / [PDFPage.string](https://developer.apple.com/documentation/pdfkit/pdfpage/string) - zero-based page access (out-of-bounds raises an Obj-C exception) and page text-layer extraction.
- [MigrationStage.lightweight(fromVersion:toVersion:)](https://developer.apple.com/documentation/swiftdata/migrationstage/lightweight(fromversion:toversion:)) / [VersionedSchema](https://developer.apple.com/documentation/swiftdata/versionedschema) - V1->V2 additive schema migration; both args must be `VersionedSchema`-conforming types (M1 retrofits `HistorySchemaV1: VersionedSchema`).
- [AsyncStream.Continuation.yield(_:)](https://developer.apple.com/documentation/swift/asyncstream/continuation/yield(_:)) / [AsyncThrowingStream.Continuation.yield(_:)](https://developer.apple.com/documentation/swift/asyncthrowingstream/continuation/yield(_:)) - non-blocking yield; the primitive for non-suspending invalidation delivery and the scheduler inbox yield (§6.3; cycle 2 directly verified the `AsyncThrowingStream` variant).
- [SchemaMigrationPlan](https://developer.apple.com/documentation/swiftdata/schemamigrationplan) / [ModelContainer](https://developer.apple.com/documentation/swiftdata/modelcontainer) - migration-plan protocol + automatic-migration behavioral prose (cycle 2; `E1-PLATFORM-4`).
- [Actor.unownedExecutor](https://developer.apple.com/documentation/swift/actor/unownedexecutor) / [Executor](https://developer.apple.com/documentation/swift/executor) - the `Actor` protocol's `nonisolated var unownedExecutor: UnownedSerialExecutor { get }` (macOS 10.15+), the override `EnrichmentWorker` uses to route its blocking `derive` body onto a custom `SerialExecutor` off the cooperative pool (§6.2). MCP-verified via the Swift framework symbol search (the Apple-docs prose search returns no result); API-existence is also subsumed by `E1-COMPILE-1`'s Swift 6 build, and cooperative-pool isolation is proven by `E1-PERF-6` (cycle 5).

All facts above are recorded with verdicts in `docs/v2/V2-facts.md`, including
the custom-actor-executor anchor (recorded in cycle 5). Cycle 1
appended the MCP-verified `usesLanguageCorrection` / `init(completionHandler:)` /
Revision 3 / `supportedRecognitionLanguages` / PDFKit model-tier / lightweight
migration / non-blocking yield facts, and corrected the completion-handler and
deprecated-API misstatements. Cycle 2 re-verified the Vision/PDFKit/SwiftData
primitives with fresh platform-compatibility citations (VNRecognizeTextRequest,
VNRecognizeTextRequestRevision3, VNImageRequestHandler/perform/init(data:),
on-device processing, VersionedSchema, SchemaMigrationPlan,
MigrationStage.lightweight, AsyncThrowingStream.Continuation.yield) and
strengthened E1-SECURITY-1 (required-reason API reporting does not apply on
macOS) and E1-PLATFORM-4 (automatic-migration behavioral prose + WWDC2025/291
lightweight-migration intent). Where a behavior could not be MCP-fetched (TCC
explicit-absence, PDFKit transitive AppKit link, migration atomicity, decodable
UTI set, OCR cooperative-pool starvation), it is marked OPEN there and assigned a
V2 proof gate in §10 - V2-01 makes no concrete platform claim without either a
citation or a proof gate, exactly as v1 (`00` §5).
