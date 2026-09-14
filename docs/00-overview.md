# Greenfield Clipboard Manager — v1 Design Specification

> **Current storage implementation direction (2026-09-07):** the user approved
> [SQLite metadata + immutable blob storage](v2/V2-09-multilevel-storage.md).
> It replaces the SwiftData layout and full-store in-memory indexes described
> in this historical v1 specification. There is no dual writer or migration.
> History actions, immutable content revisions and coherence semantics remain;
> SQLite read transactions now own search snapshots. The replacement is the
> current implementation; this is not a claim of completed scale evidence.

> **Scope:** the original v1 semantics are extended by the owning V2 documents,
> including retention, the durable HCR journal, Gateway/App Intents, local
> automation and SQLite storage. Historical implementation/CI records describe
> their cited revisions, not the current worktree's verification status.

## 1. Purpose

This document set defines a from-zero macOS clipboard-history architecture. It must be internally consistent enough to drive a later scaffold without requiring an implementer to choose between competing versions of the design.

The v1 product captures clipboard values, coalesces repeat copies, lists and searches retained history, pins and reorders items, removes or clears items, appends immutable content revisions, produces paste payloads, and produces thumbnails. It targets macOS 26+ and Swift 6 complete strict-concurrency checking.

The repository outside `docs/` may inform product behavior, terminology, and known platform hazards. It does not constrain target ownership, types, persistence layout, or implementation technique chosen here.

## 2. The single v1 truth

### Included

- `HistoryCore`: the public caller interface, public identity/coherence values, closed `HistoryAction` instruction set, purpose-specific read DTOs, receipts, and typed failures.
- `HistoryDomain`: package-only, Foundation-only content lineage, complete action facts, pure planners, and strongly typed mutation plans.
- `HistoryStorage`: the sole SQLite writer, immutable blob files, indexed candidate queries, action-specific fact loading, scalar read projections, transient observation plumbing, and thumbnail single-flight.
- `ContentPreview`: one package-only concrete preview renderer owning exact
  source selection, fixed resource profiles, and bounded inert text/raster or
  copied-address metadata; it never reads History or owns UI lifecycle/thumbnail semantics.
- `PasteboardAdapter`: AppKit pasteboard values to and from `HistoryCore` values. It never constructs Domain state or fingerprints.
- `ClipboardFormats`: exact format identifiers and declared text-codec facts.
- `ClipyCLIContract`: package-only Foundation wire values and codecs.
- `LocalAutomation`: in-process service and local client transport using the
  existing authenticated History/Gateway operations.
- `ClipyApp`: the sole composition root, native AppKit/SwiftUI UI under
  `ClipyApp/Sources/UI`, and outbound paste orchestration. UI state uses
  History DTOs and bounded preview artifacts; there is no PresentationUI target.
- Configurable count, age, storage and revision retention, the durable HCR
  journal, and connection-bound Gateway/App Intents operations, as specified
  in the owning V2 documents and [local automation guide](local-automation.md).
- One persistent source of truth, no semantic read cache, and one transient thumbnail single-flight coordinator.

### Excluded

- Enrichment and OCR.
- A public reconnect/replay cursor API.
- Shared or disk materialization caches, collection caches, generic purpose/source-stamp systems, and five-store materialization frameworks.
- Migration from the current Maccy schema. This is a greenfield schema.

Part VI records possible future grafts and the evidence required before introducing them. Excluded concepts do not reserve public protocols, schema columns, or placeholder types in v1.

## 3. Load-bearing decisions

1. **Caller-first deep interface.** Callers express a History Action or request a purpose-specific value. They do not submit Domain transitions, construct Working Sets, or observe storage events.
2. **Stable History Item identity.** `HistoryItemID` is independent of storage row identity and content hashes. Copy Coalescing updates the winning item in place.
3. **Single write authority.** HistoryAuthority owns the writable SQLite connection and immutable blob publication. History, accounting, HCR, Gateway audit and ChangePosition commit atomically.
4. **No model leakage.** Only immutable `Sendable` values cross module or actor boundaries. SQLite connections, statements and mutable file handles stay with their owner.
5. **Immutable content lineage.** Canonical Content is never overwritten. A meaningful replace or revert appends a complete new Content Revision; earlier revisions remain unchanged.
6. **Precise coherence tokens.** `ContentVersion` advances only when Effective Content bytes change. `ChangePosition` advances exactly once for every non-empty History Commit.
7. **Two-stage deduplication.** xxh3 signature entries generate a complete candidate set; byte-exact comparison makes the decision. A fingerprint is evidence, never identity.
8. **Complete facts or no mutation.** Every cross-item invariant is planned from an action-specific fact value whose construction proves completeness. There is no partial aggregate and no bounded-empty-scan insertion rule.
9. **Strong mutation plan.** Domain planners return ordered, typed mutations carrying their semantic payload. Storage never infers Copy Coalescing, pin shifts, revision effects, or retirement from an underspecified change tag.
10. **Observation returns state, not events.** The public observation API produces authoritative snapshots. A process-local invalidation signal is hidden inside `HistoryStorage`, may coalesce, and is not a durable History Change Record.
11. **No cache-dependent semantics.** A read result is derived from durable state. Thumbnail single-flight only shares concurrent work; it does not retain a completed semantic cache.
12. **Claims require proof.** Build, runtime and performance claims require evidence covering the implementation and workload being claimed; historical CI does not verify a later worktree.

## 4. Parts and ownership

1. [Architecture](01-architecture.md): target graph, runtime boundaries, end-to-end flows, isolation, and dependency rules.
2. [Domain Model](02-domain.md): content lineage, state, action-specific complete facts, pure planning, deduplication, retention, pin order, and invariants.
3. Caller Interface (Part III, split for size): [A — identity, protocol, actions, receipts, requests](03a-instruction-set.md) + [B — read DTOs, detail/paste/thumbnail DTOs, typed failures, guarantees, caller examples](03b-instruction-set.md).
4. [Read and Observation Coherence](04-coherence.md): snapshot semantics, read-after-commit, race-free observation, pagination, search, and thumbnail single-flight.
5. [Authority Commit Kernel](05-authority-kernel.md): SQLite/blob storage, validation, connection ownership, preparation, fact loading, transaction flow, indexed queries, and read projection.
6. [Cross-cutting Gates and Deferred Grafts](06-cross-cutting.md): hard limits, deferred work, scaffold proofs, walking skeleton, and the definition of design completion.

The **implementation roadmap** lives at [`roadmap/`](roadmap/README.md): a traceable map covering all 8 Part I §2 design modules, ordered by Part VI §5. It restates the spec for navigation only and owns no new semantics (except explicitly-marked build-ordering decisions).

## 5. Specification precedence

- These files (Parts I–VI, with Part III split across `03a` and `03b` for size) are one specification; no Part may silently redefine a type owned by another Part.
- Part III owns the public surface. Part II owns package-only semantic planning. Part V owns persistence and version minting.
- When a platform behavior is not guaranteed by documented API, the specification states the required outcome and assigns an implementation-time proof instead of inventing an API.
- The owning V2 documents extend the original v1 scope. HCR is implemented by V2-03; its presence does not imply a public reconnect/replay API.
- There are no intentionally unresolved semantic choices in v1. Items that require platform or performance evidence are explicit Part VI proof gates, not alternate designs.
