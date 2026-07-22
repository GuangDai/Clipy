/// HistoryStorage — public concrete adapter (`SwiftDataHistory`) plus internal
/// Authority actor, schema/codecs, fact loaders, version minting, ingest
/// preparation, Signature Index, read projections, observation plumbing, and
/// thumbnail production. Owning spec: docs/04-coherence.md (Part IV) and
/// docs/05-authority-kernel.md (Part V); target role: docs/01-architecture.md §2.
///
/// Step-0 confinement: no SwiftData import yet (schema lands at roadmap step 4);
/// the Fuse edge lands at step 3; the xxh3 dependency holds placeholder C source
/// until step 3 (docs/roadmap/README.md §3).
import Foundation

/// Step-0 scaffold placeholder; real surface lands per docs/roadmap README §3.
public enum HistoryStorageScaffold {}
