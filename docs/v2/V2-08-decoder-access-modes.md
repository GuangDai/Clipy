# V2-08 — Decoder Access-Mode Characterization (PLAY-TIER-1A) and the Pure Access-Plan Proposal

> **Status (PLAY-TIER-1A evidence leaf):** characterization record, not a
> graft. This doc extends no v1 surface and admits nothing: it redefines no
> public type, no `HistoryAction` case, no schema column, no codec, and no
> invariant. It exists because the TDD playbook gates PLAY-TIER-1B's pure
> access-plan planner on an approved 1A evidence profile
> (docs/reviews/2026-08-22-clipy-maccy-deep-review/
> 04-tdd-remediation-playbook.md §26 TIER rows 1–2: "用具体
> decoder、fixture与OS trace记录某个 purpose实际使用header/range/full中的
> 哪一种；不能按UTI名称预设'header-only'"). The decision gate for doing
> 1A pre-G8 is the same playbook §26 track list: "`PLAY-TIER-1A` 和首张
> `PLAY-TIER-2A-THUMB` 可直接用当前layout characterization/caller
> shape领取" — 2A-THUMB is landed, 1A may proceed, and both "产生G8证据且
> 不新增History seam". The design background is that review's
> 09-tiered-storage-and-unbounded-history.md §5 (per-type loading
> boundaries) and §12 DESIGN-TIER-16 ("access mode 是具体
> decoder+fixture+OS 实测分类，不由 UTI 名称静态推断").
>
> Nothing in this leaf changes product behavior. The measurement code is
> DEBUG-only and package-scoped (`Sources/ContentPreview/
> PreviewAccessProbe.swift`, the `ThumbnailMeasurement` posture of
> `Sources/PresentationUI/ThumbnailStore.swift`), executed one child process
> per fixture by the DEBUG-only test-evidence executable
> `PreviewAccessProbeRunner` (§4 explains why the probe cannot run inside a
> CI test process); its owner tests live in
> `Tests/ContentPreviewTests/PreviewAccessProbeTests.swift`. No G8
> admission is claimed; P3, PLAY-TIER-2B physical range reads, and any
> app-managed blob tier remain BLOCKED-SPEC/BLOCKED-G8 exactly as before.

## 1. Role and boundary

PLAY-TIER-1A asks one question: for the decoder the product actually runs,
which of **header-only**, **incremental-range**, or **full-decode** does a
purpose really consume — measured on concrete fixtures, not inferred from
UTI names. This doc records:

- the decoder under test and its exact configuration (§2);
- the fixture set and its byte-layout facts (§3);
- the measurement harness and how its evidence is extracted (§4);
- the evidence profile: structural facts locked by CI owner tests, plus
  the timing table a recorded macOS run fills in (§5);
- the pure access-plan proposal that PLAY-TIER-1B would turn into a
  planner Red after approval (§6);
- the evidence ceiling — what this leaf does not establish (§7).

The boundary is deliberate: the probe measures the decoder's byte
*consumption* and operation *durations* on in-memory sources. It does not
trace syscalls (an in-memory `CGImageSource` performs no file I/O to
trace), does not measure RSS (whole-aggregate hydration upstream of the
decoder is current-layout fact, already accounted by PLAY-TIER-2A-THUMB's
`returnedRepresentationBytes`/`aggregateHydratedBytes` receipt pair), and
never adjudicates a threshold — characterization per playbook §26 ("只
保存事实，不因'还没有阈值'而失败").

## 2. Decoder under characterization

The concrete decoder is **ContentPreview's ImageIO raster path**
(`Sources/ContentPreview/ContentPreview.swift`, `renderRaster`):

- source construction: `CGImageSourceCreateWithData` over an immutable
  full-payload `Data` (the bytes are already materialized by the time the
  decoder sees them — the current layout);
- decode: `CGImageSourceCreateThumbnailAtIndex` at
  `CGImageSourceGetPrimaryImageIndex` with the four frozen options
  `kCGImageSourceThumbnailMaxPixelSize` (640 for the history-pane profile,
  2,048 for `displayPNG`), `kCGImageSourceCreateThumbnailFromImageAlways`,
  `kCGImageSourceCreateThumbnailWithTransform`,
  `kCGImageSourceShouldCacheImmediately`;
- materialization: an eager premultiplied BGRA8 redraw into a bounded
  `w×h×4` buffer (cost deterministic from output dimensions; not
  re-measured — the end-to-end product-path timing is already the
  running-app lane's `ThumbnailMeasurement.rasterMs` evidence).

The probe's `fullDecode` mode reuses that exact option dictionary;
characterizing any other configuration would not be evidence for *this*
decoder. The sibling `HistoryStorage` `ThumbnailService` decode (same
ImageIO thumbnail API at capture time) is outside this leaf's scope.

Purposes classified (ContentPreview's real operation vocabulary):

- **P-dims** — intrinsic primary-image pixel dimensions without pixel
  decode (no current caller; the prospective consumer of any header-mode
  plan, e.g. a dimensions-only details surface);
- **P-thumb** — a bounded raster at the 640-px history-pane box (today's
  `renderHistoryPane` image route and, at 2,048 px,
  `rasterizePNGForDisplay`);
- **P-full** — full-fidelity pixel access. No current ContentPreview
  purpose needs it; it is recorded as the upper bound the other modes are
  compared against and is the only honest plan where partial output is
  inadmissible.

## 3. Fixture manifest and byte-layout facts

Representative fixtures are the pinned `fixtures-v1` image set (generated
by `scripts/generate_fixtures.py`, fetched by `scripts/fetch_fixtures.sh`,
CI-always; six of the seven frozen v1 image UTIs — HEIC/HEIF are
deliberately uncovered there because Pillow cannot encode them), plus one
always-available 64×48 PNG synthesized in-test through ImageIO. Byte
counts are literal facts of the pinned tree's `manifest.json`; the header
floor is the first byte after the field carrying the dimensions, from a
direct byte scan of the pinned files:

| Fixture | UTI | Pixels | Encoded bytes | Header floor (byte) | Header structure |
|---|---|---|---|---|---|
| `images/photo4k-a.png` | public.png | 3840×2160 | 848,017 | 24 | 8-byte signature + IHDR; w/h at bytes 16–23; IHDR chunk ends at 33 |
| `images/icon-512.png` | public.png | 512×512 | 56,889 | 24 | same |
| `images/huge-8k.png` | public.png | 7680×4320 | 3,136,852 | 24 | same |
| `images/photo4k-b.jpg` | public.jpeg | 3840×2160 | 189,348 | 158 | SOF0 (`0xFFC0`) marker at offset 158, segment ends at 177 |
| `images/anim-720.gif` | com.compuserve.gif | 1280×720 (3 frames) | 342,612 | 10 | GIF89a logical screen descriptor; w/h LE at bytes 6–9 |
| `images/photo-1080.bmp` | com.microsoft.bmp | 1920×1080 | 6,220,854 | 26 | BITMAPINFOHEADER; w/h at bytes 18–25 |
| `images/photo4k-c.tiff` | public.tiff | 3840×2160 | 1,189,326 | **1,185,764** | little-endian; **IFD at offset 1,185,738 (99.7% into the file)**; width entry at 1,185,740–1,185,751, height at 1,185,752–1,185,763; IFD ends at 1,185,864 |

The TIFF row is the load-bearing counterexample for the playbook's "never
presume header-only from the UTI" rule: this encoder (Pillow LZW TIFF)
places the directory that carries the dimensions at the *end* of the
file, so a prefix read cannot serve P-dims for this layout at any useful
bound. IFD placement is an encoder choice, not a TIFF property — which is
exactly why access plans must key on measured layout evidence, never on
the UTI (09 §12).

## 4. Measurement harness

`PreviewAccessProbe` (DEBUG-only, `package`, no product call sites) runs
the three modes per fixture and returns one content-free
`PreviewAccessRecord` per mode, in the fixed wire order
`[headerOnly, incrementalRange, fullDecode]`:

- **headerOnly** — one timed `CGImageSourceCopyPropertiesAtIndex` over the
  full in-memory input (the current-layout cost of P-dims), then a binary
  search with *verified endpoints* for the exact minimum prefix whose
  fresh `CGImageSourceCreateIncremental` source (never finalized — a range
  read has no completion flag to give) surfaces both pixel dimensions.
  Satisfaction is monotone in prefix length for these parsers (a parser
  that has seen a header never un-sees it); both endpoints are probed,
  not assumed.
- **incrementalRange** — fresh unfinalized sources fed a factor-4 prefix
  ladder (64 B upward; coarse by design, since each rung costs a real
  partial decode proportional to the prefix) until
  `CGImageSourceCreateThumbnailAtIndex` with the product options returns
  an image. Records the first satisfying rung, the previous failing rung,
  the partial output dimensions, and the satisfying decode's duration;
  plus `decodesUnfinalizedAtFullLength` to separate "the tail bytes were
  required" from "the completion flag was required" when no proper prefix
  decodes.
- **fullDecode** — one timed complete-source thumbnail decode with the
  exact product options; output dimensions and the `w×h×4` BGRA8 artifact
  byte cost.

"Bytes read" throughout means the decoder-consumed prefix, the honest
proxy for what a future physical range read (PLAY-TIER-2B,
BLOCKED-SPEC/BLOCKED-G8) would have to deliver; there is no ImageIO
file-I/O to trace for in-memory sources (§7).

**Execution boundary (why a child process).** The incremental-range mode
decodes deliberately truncated payloads, and framework decoders log on
partial data — libpng partial-decode error lines failed the CI log
self-scan in run 32259544566 (the reason
`scripts/generate_fixtures.py` excludes truncated/corrupt image fixtures).
The probe therefore never runs inside a test process: the DEBUG-only
`PreviewAccessProbeRunner` executable (one short-lived child per fixture,
the `HistoryRestartProbe`/`TrueRestartChildTests` precedent — build edge
on the test target, launched from `.build/debug`, never a nested SwiftPM
process) runs all three modes and writes the three records as JSONL; the
parent asserts the records plus the child's fixed `PROBE_OK` stdout marker
and drops the child's stderr, keeping decoder diagnostics out of the CI
log and any partial-data decoder crash out of the test process.

Optional persistence: `PreviewAccessMeasurement` appends one sorted-key
JSON line per record to the absolute path named by
`CLIPY_PREVIEW_ACCESS_MEASUREMENT_PATH` (create-on-first-write, failures
observed-and-dropped — measurement never takes down the lane). Unlike
`ThumbnailMeasurement` it does not require the running-app envelope: this
probe is test-lane driven. The child writes through the same sink (each
child run is one sink, so `seq` is 1–3 per fixture and `fixtureID` is the
grouping key), and the profile suite additionally re-records the child's
records through the sink when the variable is set on the test lane, so one
command extracts the durable profile on any macOS runner:

```sh
CLIPY_FIXTURES_DIR=<fixture-root>/clipy-fixtures-v1 \
CLIPY_PREVIEW_ACCESS_MEASUREMENT_PATH=/tmp/access-modes.jsonl \
swift test --filter 'PreviewAccessProfileTests\.'
```

Owner tests (`Tests/ContentPreviewTests/PreviewAccessProbeTests.swift`)
lock the recording semantics (one JSONL line per record, sink-assigned
`seq`/monotone `monotonicMs`, exact field round trip with durations
asserted present-and-non-negative only — the ThumbnailMeasurementTests
posture), the envelope gate, fail-closed recording for non-image bytes,
and the structural facts below. Durations are never threshold-checked;
this leaf is characterization, and G8 adjudication stays with
docs/06-cross-cutting.md §3 and V2-06's P3 record.

## 5. Evidence profile

### 5.1 Structural facts (CI-locked by the owner suites)

For all six head-fixed-layout fixtures (three PNG scales, JPEG, GIF,
BMP), the profile suite asserts:

- P-dims is served from a small early prefix: the probe's minimum
  satisfying prefix is ≥ the §3 floor and ≤ 4,096 B — i.e. within one
  4 KiB read — and strictly below the encoded size; the returned
  dimensions equal the fixture's pinned intrinsic dimensions;
- P-thumb at the 640-px box yields the expected bounded output
  (3840×2160 → 640×360; 7680×4320 → 640×360; 1920×1080 → 640×360;
  1280×720 → 640×360; 512×512 → 512×512 unscaled, since the box is a
  maximum), `outputBytes = w×h×4`;
- range-mode results are recorded relationally only (a satisfying prefix
  is never smaller than the header prefix; partial output, when the
  decoder produces any, is reported with its own dimensions) — no outcome
  is presumed for partial decodes.

For the TIFF fixture the suite locks the negative fact either way the
decoder behaves: a satisfying header prefix, if one exists unfinalized,
lies above `inputBytes − 8,192` (≈ the tail-IFD position), or no
unfinalized prefix ever surfaces dimensions. Full decode still yields the
640×360 thumbnail.

### 5.2 Timing profile (record-only, populated by a macOS run)

Durations are runner-relative evidence, not thresholds. The profile table
is filled from the JSONL of the §4 command on the macOS 26 arm64 CI
runner; until that run is attached to the admitting PR, the cells are
intentionally blank rather than fabricated:

| Fixture | headerOnly wallMs (full-data property read) | headerOnly minimum prefix | incrementalRange first decode prefix | incrementalRange decode wallMs | fullDecode wallMs | fullDecode outputBytes |
|---|---|---|---|---|---|---|
| photo4k-a.png (848,017 B) | _(recorded run)_ | ≤ 4,096 B (CI-locked) | _(recorded run)_ | _(recorded run)_ | _(recorded run)_ | 640×360×4 = 921,600 |
| icon-512.png (56,889 B) | _(recorded run)_ | ≤ 4,096 B (CI-locked) | _(recorded run)_ | _(recorded run)_ | _(recorded run)_ | 512×512×4 = 1,048,576 |
| huge-8k.png (3,136,852 B) | _(recorded run)_ | ≤ 4,096 B (CI-locked) | _(recorded run)_ | _(recorded run)_ | _(recorded run)_ | 640×360×4 = 921,600 |
| photo4k-b.jpg (189,348 B) | _(recorded run)_ | ≤ 4,096 B (CI-locked) | _(recorded run)_ | _(recorded run)_ | _(recorded run)_ | 640×360×4 = 921,600 |
| anim-720.gif (342,612 B) | _(recorded run)_ | ≤ 4,096 B (CI-locked) | _(recorded run)_ | _(recorded run)_ | _(recorded run)_ | 640×360×4 = 921,600 |
| photo-1080.bmp (6,220,854 B) | _(recorded run)_ | ≤ 4,096 B (CI-locked) | _(recorded run)_ | _(recorded run)_ | _(recorded run)_ | 640×360×4 = 921,600 |
| photo4k-c.tiff (1,189,326 B) | _(recorded run)_ | **> 1,181,134 B or none** (CI-locked) | _(recorded run)_ | _(recorded run)_ | _(recorded run)_ | 640×360×4 = 921,600 |

Note for the reader: under the *current* layout the headerOnly timing is
paid on already-materialized full bytes, so its wall time is the property
read alone; the byte column is where the access-mode difference lives.

## 6. Pure access-plan proposal (input to PLAY-TIER-1B, not admitted)

PLAY-TIER-1B is a pure planner Red — it outputs a range, a maximum byte
count, and a fallback per purpose, and its tests must not invoke the
decoder. It may only be written once this profile is approved. The
proposal this profile supports, keyed on §3's *measured layout classes*
(not UTI names):

| Purpose | Layout evidence class | Plan | Maximum bytes | Fallback |
|---|---|---|---|---|
| P-dims | head-fixed (PNG/GIF/BMP + JPEG layouts with SOF inside the first 4 KiB — all six §5.1 fixtures) | prefix read `[0, 4 KiB)` | 4,096 | properties absent at 4 KiB → escalate to full read |
| P-dims | tail-IFD (the probed TIFF layout) | no prefix plan; full read under the current layout; a two-range read `{[0, 8), [N−4 KiB, N)}` only if a post-G8 physical range seam exists | full encoded bytes (current) | none needed — full read always serves |
| P-dims | unknown/unprofiled layout | full read | full encoded bytes | — |
| P-thumb | all probed layouts | full read. Partial incremental output, where the range mode records any, is a *fidelity-degraded* artifact and cannot serve the product's thumbnail contract; the range-mode numbers exist to feed the G8 decision, not to admit a range plan | full encoded bytes | — |
| P-full | all | full read (only honest plan for full-fidelity purposes) | full encoded bytes | — |

Consequences the approver should weigh:

- Under the current SwiftData aggregate layout, *every* plan above still
  hydrates the whole Canonical/revision aggregate upstream of the decoder
  (PLAY-TIER-2A-THUMB's `aggregateHydratedBytes` accounting). The P-dims
  prefix plan only becomes physical bytes-on-disk savings after a G8-admitted
  range seam; before that it is a decoder-side fact, honestly recorded as
  such.
- The plan table is per layout *class* with an explicit unknown-layout
  default; a new encoder that relocates a header (the TIFF lesson) must
  fall out of the head-fixed class by measurement, not by assumption —
  that is the discipline the binary-search probe encodes.
- No cache, permit, BlobStore, or History seam follows from this leaf;
  those remain behind their own playbook gates.

## 7. Evidence ceiling

- One decoder (ContentPreview's ImageIO raster path), one OS/toolchain
  (macOS 26 arm64 CI runner), one fixture tree. Nothing generalizes to
  PDFKit, AVFoundation, or other OS versions without their own 1A-shaped
  leaves (09 §12's per-renderer rule).
- "Bytes read" is decoder-consumed prefixes on in-memory sources. There
  is no ImageIO-internal file I/O to trace for `CGImageSourceCreateWithData`
  inputs, so no fs_usage/DTrace artifact exists or is claimed; parser
  scratch memory is likewise out of scope (playbook §26's MEM rules
  already treat native decoder workspace as concurrency-slot plus
  child-RSS bounded, never precisely chargeable).
- Timings are record-only until a measured run is attached; even then
  they are that runner's facts, and no SLO is adjudicated here.
- The TIFF conclusion is specific to the probed tail-IFD layout; it
  demonstrates the *class* of failure (UTI-name presumption), not a
  universal TIFF property.
- HEIC/HEIF remain uncharacterized (the fixture tree cannot encode them);
  any future HEIC evidence must come from its own fixture addition.
