# Module 4 — PasteboardAdapter

- **Status:** not-started
- **Spec references:** ownership `../01-architecture.md` §2 row + §4 (Framework dependency, NSPasteboard/AppKit) + §8 (forbidden imports); capture seam `../03a-instruction-set.md` §4; paste payload `../03b-instruction-set.md` §9 (`PastePayload`); paste coherence `../04-coherence.md` §8; flows `../01-architecture.md` §5.1 (capture) + §5.6 (paste).
- **Dependencies:** `HistoryCore` (raw values + `PastePayload`); `AppKit` (`NSPasteboard`). Never imports `HistoryDomain`, `HistoryStorage`, SwiftData, or another adapter; never constructs `CanonicalContent` or calls xxh3.
- **Test target:** `PasteboardAdapterTests`.
- **Step:** 9a.

## Deliverables

- **Capture (NSPasteboard → HistoryCore):** freeze raw typed bytes + the source/lineage observation into `CapturedRepresentation` / `ClipboardCapture` / `CopyOriginObservation` (03a §4); decode the prior paste's lineage hint back into `CopyOriginObservation.lineageHint` when present.
- **Paste (HistoryCore → NSPasteboard):** translate a `PastePayload` (current Effective Content, 03b §9) into framework pasteboard values and write the lineage hint equal to the item ID (Part I §5.6; Part IV §8).
- **Pasteboard observation** that triggers `history.perform(.capture(...))` (Part I §5.1).

## Acceptance

- `PasteboardAdapterTests`: capture freezes all relevant types; paste writes the lineage hint equal to the item ID; the adapter decodes a prior-paste lineage hint back into `CopyOriginObservation.lineageHint`. (End-to-end coalescing via the hint is exercised by WS4 through History, not by this target.)
- Import confinement (Part VI §6): `AppKit` is confined to this target; a deliberate `HistoryDomain`/`HistoryStorage` import fails the scan.
- Negative: the adapter never builds `CanonicalContent`, never fingerprints, never touches persistence (Part I §2 "Must not own").

## Risks / notes

- The adapter is deliberately dumb: all dedup/coalescing/OCC decisions live behind `ClipboardHistory`. It only translates observations (Part I §5.1).
- Paste orchestration is owned by **ClipyApp**, not this adapter — `history.pastePayload(for:)` → `ClipyApp` → `adapter.write(payload)` (Part I §5.6, 03b §12), to avoid an adapter-to-adapter dependency and keep the clipboard side effect outside the History transaction.
