# Apple / SwiftData durability and recovery memo

> Date: 2026-08-22
>
> Scope: current Clipy on macOS 26+, arm64
>
> Evidence policy: Apple Developer Documentation, Apple WWDC transcripts,
> Apple Platform Security, and the repository's own source/tests only. No blog,
> forum answer, or undocumented on-disk filename is used as authority.

## Labels and support ceiling

- **DOC** — Apple publicly documents this behavior. The claim is no broader
  than the cited wording.
- **INFERENCE** — a conclusion drawn from Apple documentation plus Clipy's
  code or measured tests. It is useful for design, but it is not an Apple API
  contract and may need revalidation on a new OS/SDK.
- **UNKNOWN** — neither Apple documentation nor the current tests establish
  the behavior. The named discriminator is required before the claim can be
  promoted.

“Process-crash proof” below means a child process is killed and the store is
reopened through SwiftData. It does **not** prove sudden-power-loss durability:
`SIGKILL` leaves the kernel, filesystem, device cache, and power running.

## Executive conclusions

| Question | Verdict | Consequence for Clipy |
|---|---|---|
| Does `ModelContext.transaction` save on normal closure completion? | **DOC** | Yes. It is the correct single normal-save boundary; no trailing `save()` is needed. |
| Does a throwing closure automatically roll the context back? | **UNKNOWN** as an Apple contract; **INFERENCE** for Clipy's disposable-context path | Current fresh-store tests show no durable change after the injected throw, but Apple documents only explicit `rollback()`. Keep operation-local contexts and do not promise reusable-context rollback. |
| Is `transaction` return a documented fsync/power-loss boundary? | **UNKNOWN** | “Committed” may mean SwiftData save success and read-after-write visibility; it must not be upgraded to guaranteed power-loss-stable storage. |
| Is a successful save all-or-nothing across rows, WAL state, and external blobs after process death? | **UNKNOWN** | Add a child-kill old-or-new-state matrix. Current closure-throw tests do not cover the save window. |
| Is `history.store` the complete store? | **Not a supported standalone backup unit — DOC for Core Data WAL; limited DOC for SwiftData URL** | Apple does not define the SwiftData URL as a complete, independently copyable backup unit. Treat the dedicated parent directory as an opaque store family for quarantine/backup; never assume copying only `history.store` is complete. |
| Does `.externalStorage` define file names, thresholds, cleanup, deletion, or crash atomicity? | **UNKNOWN** | It is a placement hint, not a correctness or secure-delete mechanism. |
| Is a custom migration stage crash-atomic with its schema-version change? | **No Apple guarantee; current Clipy evidence says no** | Keep the idempotent startup reconciliation. The current test kills before the data transaction, not in the save window. |
| Can arbitrary independent processes/containers safely preserve Clipy's single-writer and observation semantics? | **UNKNOWN**, and current architecture does not | One process must own writes and migrations. Future helpers/widgets should use IPC or a deliberately designed read path with persistent history. |
| Is Application Support sandboxed, encrypted, and excluded from backup by definition? | **No** | Location depends on sandbox state; regular backups include Application Support by default; encryption depends on Mac/file-protection state; logical clear is not secure erasure. |

The immediate architectural rule is therefore:

> A successful Clipy transaction is the app's logical save/visibility boundary.
> The opaque store family, recovery, backup, migration interruption, physical
> deletion, and cross-process behavior are separate concerns and need their own
> ownership and evidence.

## Current Clipy facts that matter

1. The production URL is obtained from `applicationSupportDirectory`, then
   appends `Clipy/history.store`; the adjacent comment currently claims this
   always means `~/Library/Application Support`, which is false once App
   Sandbox is enabled
   ([`AppComposition.swift`](../../../ClipyApp/Sources/AppComposition.swift#L68)).
2. The checked-in XcodeGen target has no entitlements file,
   `CODE_SIGN_ENTITLEMENTS`, or `com.apple.security.app-sandbox` setting
   ([`project.yml`](../../../ClipyApp/project.yml#L18)). This establishes only
   the repository state; a later distribution pipeline could still add signing
   configuration.
3. `history.store` is passed as the `ModelConfiguration` URL
   ([`SwiftDataHistory.swift`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L138)).
4. `canonicalBlob` and `revisionStateBlob` use
   `@Attribute(.externalStorage)`, and the schema already correctly calls the
   option an implementation hint
   ([`Schema.swift`](../../../Sources/HistoryStorage/Schema.swift#L65)).
5. Item mutations and the `ChangePosition` singleton update share one
   `ModelContext.transaction`
   ([`HistoryAuthority+TransactionExecution.swift`](../../../Sources/HistoryStorage/HistoryAuthority+TransactionExecution.swift#L11)).
6. The V1-to-V2 custom stage runs the projection backfill from `didMigrate`
   ([`HistoryMigration.swift`](../../../Sources/HistoryStorage/HistoryMigration.swift#L44));
   the backfill itself performs one `context.transaction`
   ([`RetainedBytesBackfill.swift`](../../../Sources/HistoryStorage/RetainedBytesBackfill.swift#L228)).
7. The “already open” set rejects only a second facade in the same process
   ([`AppComposition.swift`](../../../ClipyApp/Sources/AppComposition.swift#L68)).
   It is not a process lock or external-writer protocol.
8. Product source currently sets neither `isExcludedFromBackup` nor an
   explicit file-protection class. This is an implementation observation, not
   evidence about the user's FileVault or Time Machine configuration.

## 1. `transaction`, `save`, and `rollback`

### DOC

- [`ModelContext`](https://developer.apple.com/documentation/swiftdata/modelcontext)
  says model changes remain in memory until an implicit or explicit save. It
  also says `willSave` is posted before a save attempt and `didSave` after a
  successful operation.
- [`save()`](https://developer.apple.com/documentation/swiftdata/modelcontext/save%28%29)
  writes pending inserts, changes, and deletes to persistent storage.
- [`transaction(block:)`](https://developer.apple.com/documentation/swiftdata/modelcontext/transaction%28block%3A%29)
  runs the closure and, once it finishes, writes pending inserts, changes, and
  deletes. The parameter is described as a closure run before the save
  operation. The documented signature is throwing, but the page does not
  describe failure recovery.
- [`rollback()`](https://developer.apple.com/documentation/swiftdata/modelcontext/rollback%28%29)
  explicitly discards pending inserts/deletes, restores changed models to the
  latest committed state, and clears the undo stack.
- [`autosaveEnabled`](https://developer.apple.com/documentation/swiftdata/modelcontext/autosaveenabled)
  defaults to `false` for manually created contexts; Clipy also sets it to
  `false` explicitly.
- SwiftData History describes a model-context write as a transaction boundary
  containing one or more ordered persisted changes
  ([Fetching and filtering time-based model changes](https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes)).

### INFERENCE

- A normally returning Clipy closure needs no following `save()`. The current
  pattern is aligned with the API, and a fresh independent container sees the
  item and position immediately in
  [`TransactionBoundaryProofTests`](../../../Tests/HistoryStorageTests/TransactionBoundaryProofTests.swift#L27).
- When Clipy's injected closure throws, an independent container sees the old
  rows and position. Because the failed operation's context is local and is
  not reused, any residual in-memory changes cannot be saved later by product
  code
  ([same test](../../../Tests/HistoryStorageTests/TransactionBoundaryProofTests.swift#L81)).
- Those tests establish normal read-after-save visibility on the tested macOS
  runtime. Their use of “durably” must be read at that ceiling, not as proof of
  device-cache flush or power-loss survival.

### UNKNOWN

Apple's cited pages do not say:

- that a closure throw automatically invokes `rollback()`;
- what `hasChanges` and registered models contain after the throw;
- that a framework save error leaves every pending row unchanged;
- that an ENOSPC, permission, I/O, or constraint failure is all-or-nothing;
- that `transaction` return means `fsync`/`F_FULLFSYNC`, WAL checkpoint, or
  external-file finalization has completed;
- that a process killed during the save can reopen to only the complete old or
  complete new Clipy state.

### Test discriminators

1. **Throw-state test:** mutate several rows, throw inside `transaction`, then
   inspect `hasChanges` and model values on the same context. Run a second
   variant that explicitly calls `rollback()`. This distinguishes “not saved”
   from “automatically rolled back.” Product code should still discard the
   failed context.
2. **Real save-failure test:** first use `ModelConfiguration(allowsSave: false)`
   to prove error plumbing, then use a bounded disposable volume for ENOSPC and
   a permission/I/O failure. Reopen with a new process and require the complete
   pre-attempt state.
3. **Process-kill save sweep:** use a large external blob and DEBUG-only fixed
   markers at closure return, `willSave`, `didSave`, and transaction return.
   Randomly kill children in the interval between `willSave` and `didSave`.
   Every reopen must be exactly old or new across item bytes, projection row,
   position, pin order, and retention totals; no third/torn state is allowed.
4. **Support ceiling:** passing the sweep proves process-crash consistency for
   the pinned OS/SDK/filesystem. It still does not prove sudden power failure.

## 2. SQLite/WAL and the opaque store family

### DOC

- `ModelConfiguration` calls its URL the on-disk location of the schema's
  persistent storage; it does not call that URL the complete set of storage
  files
  ([initializer](https://developer.apple.com/documentation/swiftdata/modelconfiguration/init%28_%3Aschema%3Aurl%3Aallowssave%3Acloudkitdatabase%3A%29)).
- Apple's SwiftData tutorial says the default persistence is an SQL database
  ([Adding and deleting data](https://developer.apple.com/tutorials/app-dev-training/adding-and-deleting-using-swiftdata)).
- Apple's Core Data QA states that Core Data SQLite stores have used WAL by
  default since OS X Mavericks: saved transactions may remain in the adjacent
  `-wal` file and may not yet be merged into the main file. Copying only the
  main file can therefore lose data or create an inconsistent restore. Apple
  recommends a persistent-store migration operation for backup/restore, or,
  if file copying is unavoidable, treating the main file and WAL as one item
  ([QA1809](https://developer.apple.com/library/archive/qa/qa1809/_index.html)).
- The archived Core Data store guide says the SQLite store format is private
  and must not be manipulated with native SQLite APIs. It also discusses
  `F_FULLFSYNC` as necessary on macOS, but does not specify SwiftData's current
  journal/synchronous settings
  ([Persistent Store Types and Behaviors](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/PersistentStoreFeatures.html)).
- Apple's **DEBUG CloudKit schema-initialization procedure** unloads the Core Data
  persistent store and deallocates that container before opening a SwiftData
  `ModelContainer` on the same URL, to avoid both frameworks trying to sync in
  that narrow workflow. This is not a general prohibition on Core Data/SwiftData
  coexistence; Apple separately documents a coexistence sample with distinct stacks
  ([Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices),
  [Adopting SwiftData for a Core Data app](https://developer.apple.com/documentation/coredata/adopting-swiftdata-for-a-core-data-app)).

### INFERENCE

- `history.store` is a configuration handle, not a safe backup/quarantine
  unit. WAL plus `.externalStorage` means recovery code must conservatively
  own the whole dedicated `Application Support/Clipy` directory.
- A recoverable quarantine should happen only when all SwiftData/Core Data
  owners are gone. With no public close operation in the current facade, the
  cleanest recovery boundary may be a controlled relaunch into a pre-open
  recovery mode, then one same-volume move of the dedicated directory to a
  user-visible quarantine location. The quarantined directory remains
  sensitive data; it is not deletion.
- `NSFileCoordinator` can coordinate participating file operations across
  processes, including directory moves, but Apple does not document that a
  live SwiftData store participates as an `NSFilePresenter`. It is therefore
  not a substitute for closing every store owner
  ([`NSFileCoordinator`](https://developer.apple.com/documentation/foundation/nsfilecoordinator)).

### UNKNOWN

- SwiftData DefaultStore's macOS 26 `journal_mode`, `synchronous`, checkpoint
  policy, busy timeout, and full-fsync behavior;
- the full companion-file set at every lifecycle phase;
- whether a live Time Machine/filesystem copy of this SwiftData store produces
  a restoreable generation;
- a SwiftData-native supported API for copying/replacing this exact store
  family while preserving external blobs.

### Recovery discriminators

- Never validate a backup by comparing files alone. Fully release the source
  stack, copy or quarantine the whole dedicated directory, restore it to a
  fresh location, open through `SwiftDataHistory.open`, and validate every
  item/blob/projection/position invariant.
- Maintain fixtures in which committed data is known to reside outside the
  base filename at copy time. A “copy only `history.store`” negative control
  must fail the gate.
- Direct SQLite inspection, if used diagnostically on a disposable closed
  copy, cannot become product recovery logic or an API guarantee.

## 3. `@Attribute(.externalStorage)`

### DOC

- SwiftData defines `.externalStorage` only as storing a binary property value
  adjacent to model storage
  ([`Schema.Attribute.Option.externalStorage`](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage)).
- The underlying Core Data option is permissive: when enabled, a binary value
  **may** be stored in a file external to the persistent store
  ([`allowsExternalBinaryDataStorage`](https://developer.apple.com/documentation/coredata/nsattributedescription/allowsexternalbinarydatastorage)).
- Apple engineers describe large per-model data as a file next to the database
  rather than inline, but give no lifecycle contract
  ([WWDC26 SwiftData Group Lab, 04:48](https://developer.apple.com/videos/play/wwdc2026/8017/)).

### INFERENCE

- Clipy's schema comment correctly treats external storage as a hint. Tests
  must not require a particular threshold, suffix, directory name, or one-file
  per value.
- Canonical/revision bytes and their scalar projections are logically one
  Clipy commit, but Apple documentation does not establish how the database
  reference and external file are finalized across a crash. That is exactly
  the state the old-or-new child-kill test must cover.

### UNKNOWN

Apple does not publish:

- the inline/external threshold or whether the decision can change by OS;
- file names, directories, URL access, reference counts, deduplication, or
  garbage-collection timing;
- when old external bytes are removed after revise, retire, clear, migration,
  or failed save;
- whether deletion overwrites bytes, punches extents, merely unlinks a file,
  or leaves data in WAL, free pages, APFS snapshots, or backups;
- whether external files inherit a directory's backup-exclusion or file-
  protection attributes after every rewrite;
- cross-file atomicity for process crash or power failure.

### Test discriminators and support ceiling

1. Force genuinely large canonical and revision values, then cover capture,
   coalesce, revise, remove, clear, retention retirement, and migration.
2. At each operation, kill before save, during a randomized save window, after
   `didSave`, and after transaction return. Reopen through the public facade
   and require complete old or new content plus exact projections.
3. After all owners exit, scan the dedicated test directory for a unique
   non-secret marker following revise/clear. Finding it proves live-store
   residue. Not finding it proves only that this marker was absent from this
   visible file tree; it does **not** prove secure erasure from APFS, device
   media, snapshots, or backups.
4. Directory size and companion-file count may be recorded as diagnostics,
   never asserted as an Apple contract.

The product wording should remain “removed from Clipy,” not “securely erased.”
Even SwiftData's `deleteAllData()` documentation saying deletion is permanent
describes model data and undoability; it does not promise physical overwrite
([`deleteAllData()`](https://developer.apple.com/documentation/swiftdata/modelcontainer/deletealldata%28%29)).

## 4. `MigrationStage.custom` and interruption

### DOC

- [`MigrationStage.custom`](https://developer.apple.com/documentation/swiftdata/migrationstage/custom%28fromversion%3Atoversion%3Awillmigrate%3Adidmigrate%3A%29)
  exposes optional `@Sendable (ModelContext) throws -> Void` callbacks. The
  symbol page does not specify their transaction, retry, rollback, or crash
  behavior.
- [`SchemaMigrationPlan`](https://developer.apple.com/documentation/swiftdata/schemamigrationplan)
  describes schema evolution and version-to-version stages. `ModelContainer`
  says a plan lets the app participate so migrations can complete
  successfully; neither page defines interruption atomicity.
- Apple's current custom-migration example fetches/deduplicates in
  `willMigrate` and explicitly calls `context.save()`. This proves the supplied
  context can be used to save; it does not prove that save is atomic with the
  schema-version transition
  ([WWDC25/291, 09:33](https://developer.apple.com/videos/play/wwdc2025/291/)).

### INFERENCE

- Clipy already has direct evidence that schema advancement and custom-stage
  data work are not one interruption-atomic unit on the tested runtime. The
  recorded CI observation is: a child killed before the backfill transaction
  leaves a V2-stamped store with missing projection rows; the stage is not
  rerun, so startup detects that one allowed shape and reexecutes the
  idempotent backfill
  ([`RetainedBytesStamping.swift`](../../../Sources/HistoryStorage/RetainedBytesStamping.swift#L294)).
- This recovery is architecture, not a workaround to remove. Every future
  migration needs an explicit idempotence/reconciliation story or a proven
  fail-closed quarantine path.
- The interruption test proves that the public open path restores invariants
  after a pre-write death. It does **not** prove custom-migration transaction
  crash atomicity: its seam fires in the compute loop and explicitly states
  that the transaction never begins
  ([`HistoryMigrationInterruptionTests.swift`](../../../Tests/HistoryStorageTests/HistoryMigrationInterruptionTests.swift#L190)).
- The test header's phrase “engine-level re-run” is too specific: its assertions
  prove successful reopen and restored invariants, while the production
  recovery comment records that startup — not the migration engine — reruns
  the backfill. The review should describe the observable result, or add a
  phase marker that distinguishes the two mechanisms.

### UNKNOWN

- whether throwing from `willMigrate` or `didMigrate` rolls back schema metadata
  and all callback saves;
- whether Clipy's nested `context.transaction` on the migration-owned context
  is a guaranteed pattern or merely works on the tested OS;
- schema-version-marker ordering relative to callback saves at every kill point;
- retry/reentrancy behavior after a process death during save or immediately
  after a callback returns;
- cleanup of migration temporaries, WAL records, and external blobs.

### Required migration matrix

Use a real V1 store and separate children. Distinguish these barriers:

1. callback entered, before computation;
2. after first in-memory delete and insert, before the transaction closure
   returns;
3. between `willSave` and `didSave` using a kill-time sweep;
4. immediately after `didSave`;
5. after `context.transaction` returns but before `didMigrate` returns;
6. after `didMigrate` returns but before `ModelContainer.init` returns;
7. after container initialization, before Authority startup finishes.

Each reopen must either recover to the exact V2 invariants through the one
approved recovery shape or fail closed with the original store family preserved
for quarantine. Run a second-open cycle to prove convergence, not just one
successful reopen. Keep the current pre-write test as one row in this matrix.

## 5. Multiple contexts, containers, and processes

### DOC

- `ModelContainer` mediates its associated contexts and underlying storage and
  coordinates their operations
  ([`ModelContainer`](https://developer.apple.com/documentation/swiftdata/modelcontainer)).
  That wording does not define one global serialization domain across every
  independently created container/process.
- Core Data's `NSPersistentStoreCoordinator` performs its own work serially on
  a private queue, while Apple also permits multiple coordinators. The page
  does not turn those separate coordinators into one Clipy-level writer or
  observation domain
  ([`NSPersistentStoreCoordinator`](https://developer.apple.com/documentation/coredata/nspersistentstorecoordinator)).
- SwiftData History explicitly supports discovering changes written by another
  process such as a widget or App Intent
  ([history article](https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes)).
- WWDC25 says changes from another context/container/process can update a
  Query, while direct fetch users need to refetch
  ([WWDC25/291, 13:54](https://developer.apple.com/videos/play/wwdc2025/291/)).
- The SwiftData team advises that, in a multi-process app/widget/App Intent
  arrangement, one process — the app — should own the database and migration,
  and access must be coordinated so an extension does not drive migration
  first
  ([WWDC26 SwiftData Group Lab, 02:53](https://developer.apple.com/videos/play/wwdc2026/8017/)).
- Core Data exposes a distinct remote-change notification option for every
  store write, including writes by other processes
  ([`NSPersistentStoreRemoteChangeNotificationPostOptionKey`](https://developer.apple.com/documentation/coredata/nspersistentstoreremotechangenotificationpostoptionkey)).

### INFERENCE

- Multiple read contexts created serially under the one Authority are aligned
  with Clipy's design. The fresh-container tests prove visibility on the tested
  runtime, not a general dual-writer protocol
  ([`FreshContextVisibilityProofTests`](../../../Tests/HistoryStorageTests/FreshContextVisibilityProofTests.swift#L40)).
- A second Clipy process bypasses `openedStoreURLs`, has its own Authority,
  Signature Index, subscriber list, and observation stream, and can race the
  first process. Even if SQLite serializes disk writes, it cannot update the
  other process's in-memory index or emit its process-local invalidation.
- Therefore the supported contract should be **one database-owner process**.
  If a future helper/widget needs mutation, route closed `HistoryAction` values
  through IPC to that owner. If it only reads, the app still owns migration;
  the reader needs an explicit version/readiness protocol and persistent-
  history/refetch behavior.

### UNKNOWN

- busy/merge/error behavior for simultaneous saves from independent SwiftData
  containers at one URL;
- whether Clipy's read-position guard remains linearizable under two processes;
- whether two processes can concurrently initialize/migrate this schema safely;
- whether current observation semantics notice an external writer without
  adopting SwiftData History or another documented remote-change mechanism.

### Test discriminators

- Spawn two child writers with a barrier before their transaction. Require no
  hang, no silent overwrite, contiguous unique positions, exact row/projection
  invariants, and a deterministic typed loser/retry rule.
- Start a V1 migration owner and an extension-like reader concurrently. The
  reader must never initiate migration or observe a partially ready V2 store.
- Write from process B while process A is observing. Prove A refreshes exactly
  according to the chosen persistent-history/IPC contract.

Until those tests and an ownership protocol exist, arbitrary same-store
multi-process access is unsupported rather than “handled by SwiftData.”

## 6. App Sandbox, Application Support, file protection, and backups

### DOC — location and isolation

- On macOS, `applicationSupportDirectory` is inside the app's sandbox
  container for a sandboxed app, and under `~/Library/Application Support` for
  a non-sandboxed app
  ([`applicationSupportDirectory`](https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory)).
- App Sandbox limits filesystem/resource access and is required for Mac App
  Store distribution
  ([Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)).
- On macOS 15+, Apple recommends an App Group container as the primary local
  storage location for a bundled app that intentionally does not use App
  Sandbox; app-data and app-group containers gain system-integrity protection
  from unrelated apps
  ([Protecting local app data using containers on macOS](https://developer.apple.com/documentation/xcode/protecting-local-app-data-using-containers)).

### INFERENCE — location decision

- Enabling Sandbox later changes the URL returned by the existing code. Without
  a deliberate one-time migration, users with the current unsandboxed store
  would appear to have empty history. The current “always resolves to home
  Application Support” comment should not drive design.
- The release design must choose one stable container strategy before shipping:
  Sandbox container when compatible with product requirements, or an App Group
  container for an intentionally unsandboxed bundled app. An App Group should
  not be added merely to invite more direct database writers.

### DOC — at-rest protection

- On Apple-silicon Macs, third-party app data defaults to Data Protection Class
  C. Apple says that default uses a volume key accessible while the volume is
  mounted. macOS does not use iOS-style screen lock/unlock as its class-key
  boundary; classes that depend on user availability use login/logout instead
  ([Data Protection classes](https://support.apple.com/guide/security/secb010e978a/web)).
- On macOS 26.4+, FileVault is on by default, but a user can opt out. Apple also
  allows developers to select a higher per-file/per-extent protection class
  ([Data Protection overview](https://support.apple.com/guide/security/data-protection-overview-secf6276da8a/1/web/1)).
- Foundation exposes file protection through
  [`URLResourceKey.fileProtectionKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/fileprotectionkey)
  and `URLFileProtection` values.

### INFERENCE / UNKNOWN — protection ceiling

- Clipy's deployment floor is macOS 26.0, not 26.4, and users can disable
  FileVault. “Stored on an Apple-silicon Mac” is not equivalent to “protected
  by the user's password in every supported configuration.”
- Sandbox is access control, not a secure-delete or at-rest-encryption promise.
- SwiftData exposes no documented hook that applies one chosen protection class
  to the main database, WAL/SHM, migration files, and every future external
  blob. Setting an attribute on the visible base file would be incomplete.
- Before adopting a higher class, enumerate the closed test store family after
  create/revise/migrate, read each item's protection resource value, and test
  logout/login behavior on the minimum supported OS. Recheck after later
  writes because SwiftData may replace opaque files. This proves observed file
  coverage only; it does not turn companion names into API.

### DOC — backup

- Application Support is for long-lived support data; Apple's general file-placement
  guidance discusses backup treatment
  ([Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)).
- `isExcludedFromBackupKey` asks the system to exclude an item, but some file
  operations reset it, so Apple says to set it again when saving
  ([`isExcludedFromBackupKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey)).
- Apple's backup guidance explicitly calls the exclusion value guidance, not a
  guarantee that data never appears in a backup or restore
  ([Optimizing app data for backup](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)).
- Time Machine backup encryption is a user/destination choice. Apple's erase-to-convert
  warning in this support flow applies to Time Capsule/network backup cases and must
  not be generalized to every directly attached destination
  ([Choose a backup disk and encryption](https://support.apple.com/guide/mac-help/choose-a-backup-disk-set-encryption-options-mh11421/mac)).
- Even user-excluded Time Machine items can remain in local snapshots
  ([Exclude files from a Time Machine backup](https://support.apple.com/guide/mac-help/mh15622/mac)).

These sources do not establish one unified “macOS backup” contract: iCloud Backup
optimization, URL exclusion metadata, Time Machine UI exclusions and local snapshots
are distinct mechanisms. Their inheritance across SwiftData replacement files and
their combined effect on this store family remain `INFERENCE/UNKNOWN` until a signed
backup/restore experiment.

### Backup decision and support ceiling

Authoritative clipboard history is not reconstructible: future clipboard use cannot
recreate past exact bytes/order, and pins/revisions add further user-valued state. The product must choose and
document one policy:

- **Include:** provide restore value, but accept that clear/delete in the live
  app cannot remove historical backup copies. Validate restore from a complete,
  closed store family.
- **Exclude:** reduce propagation by setting exclusion on the dedicated store
  directory and revalidating it after startup/writes, but accept that the key
  is advisory and local snapshots or previous backups may still contain data.

Neither policy permits “securely erased” wording. The strongest honest claim
for current clear/remove is logical unavailability from the live Clipy store
after a successful commit.

## 7. CloudKit default: future entitlement fail-open

### DOC

- The persistent
  [`ModelConfiguration` initializer](https://developer.apple.com/documentation/swiftdata/modelconfiguration/init%28_%3Aschema%3Aurl%3Aallowssave%3Acloudkitdatabase%3A%29)
  defaults `cloudKitDatabase` to `.automatic` when the caller omits it.
- [`.automatic`](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct/automatic)
  enables managed CloudKit sync using the primary ubiquity container declared
  by the app's entitlements.
- [`.none`](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct/none)
  disables managed CloudKit sync.
- Apple's sync guide says SwiftData inspects app entitlements and selects the
  first CloudKit container identifier by default. It also says automatic sync
  requires the iCloud and Background Modes capabilities, that CloudKit cannot
  enforce SwiftData's `unique` option, and that explicitly passing `.none`
  overrides automatic discovery
  ([Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)).

### INFERENCE

- The persistent branch of `SwiftDataHistory.open` currently constructs
  `ModelConfiguration(schema:url:)` without a `cloudKitDatabase` argument, so
  its effective source-level setting is `.automatic`
  ([`SwiftDataHistory.swift`](../../../Sources/HistoryStorage/SwiftDataHistory.swift#L138)).
- The checked-in `project.yml` contains no iCloud/CloudKit entitlement or
  Background Modes configuration. Therefore the cited documentation is **not
  evidence that the current checked-in app has uploaded clipboard data**. The
  final signed artifact's entitlements remain the authoritative runtime input.
- It is nevertheless a privacy fail-open: a future signing/capability change
  can enable managed sync without any HistoryStorage source change. That would
  conflict with the current local-only/no-network boundary and also encounter
  a schema that uses `@Attribute(.unique)`, which Apple identifies as a
  CloudKit limitation. The exact failure or merge behavior is not safe to
  guess.
- For a local-only clipboard manager, `cloudKitDatabase: .none` is the
  fail-closed configuration. This setting controls SwiftData-managed CloudKit
  only; it is not proof that no other component performs network I/O.

### UNKNOWN

- Whether a release/signing pipeline outside the checked-in XcodeGen spec
  injects any iCloud or ubiquity entitlement into the final app.
- The exact open/sync/error behavior if `.automatic` discovers an entitlement
  while the current schema contains unsupported CloudKit features.
- What a later intentional CloudKit adoption would do to an existing local
  store, external blobs, deletion history, backups, and user expectations.

### Fail-closed discriminators

1. **Source gate:** require the persistent configuration to spell
   `cloudKitDatabase: .none`; a source test should assert the constructed
   configuration's `cloudKitDatabase` is `.none` rather than relying on the
   initializer default.
2. **Project gate:** reject iCloud, ubiquity-container, CloudKit-service, or
   remote-notification capability declarations in the checked-in XcodeGen
   inputs unless an approved sync design changes the product boundary.
3. **Artifact gate:** inspect the final signed `.app` entitlements — not only
   `project.yml` — and fail release if iCloud/ubiquity container identifiers or
   CloudKit services appear unexpectedly.
4. **Change-control gate:** intentional sync requires an explicit design
   change covering user consent, schema compatibility, existing-store
   migration, multi-process/history semantics, external blob behavior,
   deletion propagation, recovery, and backup. Only then should `.none` be
   replaced by a deliberately named CloudKit configuration.

## Recommended architecture decisions

1. **Keep `ModelContext.transaction` as the only normal History Commit save
   boundary**, but narrow documentation vocabulary to “logical save/visibility
   boundary” wherever the text currently implies power-loss durability.
2. **Promote `StoreFamily` to a composition/recovery concept, not a list of
   suffixes.** It owns a dedicated directory, container lifecycle, backup
   policy, quarantine, and restore validation. HistoryDomain and HistoryCore
   should never learn companion-file vocabulary.
3. **Keep migration reconciliation idempotent and explicit.** Current measured
   behavior already disproves schema-plus-custom-data interruption atomicity.
   Future stages need a named incomplete shape and convergence proof.
4. **Declare one database-owner process.** The process-local Authority remains
   the sole writer; extensions/helpers use IPC or a separately specified read
   protocol. Do not treat another live `ModelContainer` as a writer replica.
5. **Choose the release container and backup policy before shipping.** Enabling
   Sandbox or moving to an App Group later is a store-location migration, not a
   build-setting-only change.
6. **Offer recovery without silent data loss:** Retry, Reveal, and user-
   confirmed whole-directory Quarantine from a pre-open/relaunch mode. Never
   silently create an empty replacement or fall back to memory when an existing
   store fails to open.
7. **Keep security language bounded:** sandbox/container isolation, FileVault,
   file protection, backup exclusion, logical deletion, and physical erasure
   are different layers with different owners.

## Minimum evidence gate before stronger claims

| Claim sought | Minimum discriminator | Ceiling after it passes |
|---|---|---|
| Closure throw leaves no durable state | Existing fresh-container test plus same-context throw/rollback test | Normal exception path on pinned runtime; not save-I/O failure |
| Transaction is process-crash atomic | Child-kill old/new matrix across inline + external content and every stamped invariant | Pinned OS/SDK process crash; not sudden power loss |
| Migration recovers from interruption | Seven-barrier migration matrix, second reopen convergence, stage-vs-startup marker | Covered kill points and incomplete shapes only |
| Quarantine is recoverable | All owners closed; whole dedicated directory moved; restore/open/invariant proof | That store generation and OS; quarantine still contains secrets |
| Clear removes live external data | Reopen and full public fetch/details absence; closed-directory marker diagnostic | Logical live-store removal; never secure erase |
| Cross-process access is supported | Two-child write/observe/migration matrix plus explicit owner protocol | Only the tested protocol, not arbitrary containers |
| Backup exclusion protects privacy | Verify directory flag after every store lifecycle and inspect configured backup behavior | Best-effort current system; prior backups/local snapshots remain |
| Higher file protection covers the store | Inspect every opaque file after all write/migration paths and test logout/relogin | Observed current file set; repeat on OS/SDK changes |

Until these gates exist, the conservative design — one writer process, opaque
whole-directory recovery, idempotent migration repair, logical-delete wording,
and explicit backup/container policy — is both simpler and better supported by
Apple's published contracts.
