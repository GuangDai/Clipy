# V2-05 - External Gateway & Audit (X1 ExternalGateway + X2 Operation Record auditing)

> **Status (2026-08-23):** X.1 closed vocabulary, X.2 public contract, X.3
> schema/bootstrap, X.4 audit/admin, X.5 internal denial, and **X.6 granted
> positive paths plus the public facade/factory are landed and
> correctness-green**. The immutable V4 X-HCR prerequisite and its
> migration/rollback/restart suite are also landed and CI-green. **X.7 App
> Intents composition is landed through
> [PR #16](https://github.com/GuangDai/Clipy/pull/16):** the scoped correctness
> evidence is green in
> [run 32609910701](https://github.com/GuangDai/Clipy/actions/runs/32609910701),
> and the runner-regenerated HistoryCore symbol evidence is green in
> [run 32609018894](https://github.com/GuangDai/Clipy/actions/runs/32609018894).
> Those runs prove the hosted/source boundaries recorded under roadmap X.7;
> they do not prove signed Siri/Shortcuts invocation, TCC, or process placement.
> X.8 is landed through
> [PR #17](https://github.com/GuangDai/Clipy/pull/17), with all three
> correctness jobs green in
> [run 32613689337](https://github.com/GuangDai/Clipy/actions/runs/32613689337).
> The evidence-only F0A discriminator is landed through
> [PR #18](https://github.com/GuangDai/Clipy/pull/18): the same SwiftPM graph
> and normal app scheme are green in
> [run 32615569895](https://github.com/GuangDai/Clipy/actions/runs/32615569895),
> and the exact final `CLIPY_UDS_F0` ad-hoc-signed proof artifact passed the
> bounded cold/warm/`SIGKILL` cells in
> [run 32615713100](https://github.com/GuangDai/Clipy/actions/runs/32615713100).
> Those results reach only the claim ceiling in §0.4; they do not establish
> authenticated ingress, credential custody, Python-to-History access, or a
> distribution identity. [PR #19](https://github.com/GuangDai/Clipy/pull/19)
> subsequently landed the storage-only `expectedKind` authoritative recheck;
> [PR #20](https://github.com/GuangDai/Clipy/pull/20) added the dedicated
> wrong-kind rate-denial fixture. Those close a prerequisite needed by a later
> Local Automation adapter, not authentication or X.9. X.4 owns the complete
> `OperationPayloadBlobV1` codec, public operation-kind additions, central audit
> store, current-state connection/grant administration, public in-app admin
> conformance, and startup validation; it does **not** publish an
> `ExternalGateway`, external facade/factory, App Intents, CLI, or transport.
> X.5 adds only the real internal denial substrate. X.6 adds the
> first public `ExternalHistoryFacade`/factory and truthful
> `ExternalTransientReason.insufficientDiskSpace` raw 3 plus `.cancelled`
> raw 4 only alongside the same production actor's granted positive paths. Its
> HistoryCore snapshot was runner-regenerated in
> [run 32606749388](https://github.com/GuangDai/Clipy/actions/runs/32606749388),
> and [PR #15](https://github.com/GuangDai/Clipy/pull/15) is
> correctness-green at
> [run 32607389771](https://github.com/GuangDai/Clipy/actions/runs/32607389771);
> no performance/AB lane ran for that batch. An
> authorized connection must never receive a permanently-denying placeholder. This
> doc extends the v1 specification (`00`–`06`) by **addition only**.
> v1 owns v1 behavior (single in-app writer, no external access, no audit); V2-05
> owns the single external trust boundary (`ExternalGateway`), the
> connection/grant model, the App Intents surface, the `OperationRecord` audit
> domain, and the Connections/Audit durable tables, grafted onto the v1
> single-writer commit kernel. It redefines no v1 public type, `HistoryAction`
> case, `HistoryMutation` case, `StampedMutation` case, `PlannedOutcome` case,
> schema column, codec, invariant (D1–D19, `02` §14), or proof gate. The frozen v1
> `HistoryFailure` enum is **untouched** (V2-05 introduces a sibling
> `ExternalFailure`, §7.3, exactly as V2-03 introduced `ReconnectFailure`).
> `HistoryAction` is **untouched** (admin and external operations live on distinct
> "concern" protocols, §7.2/§7.1). The aggregate Gateway/product behavior is
> not shipped by X.1–X.3 or by the X.4 spec decision alone.
>
> **2026-08-23 DC-25 closure:** X.6 depends on the internal X-HCR substrate
> frozen by `V2-03` §0: immutable `HistorySchemaV4`, five-field HCR rows,
> four-field journal config, manual affected-items codec, validated bounded
> suffix, and one atomic HCR per non-empty commit. That prerequisite and its
> atomic migration/rollback/restart suite are now landed and CI-green. X.6 does
> not publish or rely
> on `ReconnectHistory`, cursors, a journal reader, collection cache, rebase, or
> journal UX. References below to “V2-03 HCR” mean this X-HCR subset unless a
> paragraph explicitly discusses a later J1 consumer.

## 0. 2026-08-22 Local Automation controlling amendment

This amendment is the owning rule when the older App-Intents-only text in this
document is read together with the Local Automation review. It adds a later
`.localAutomation` connection kind without changing the already approved App
Intents surface. The in-process gateway and App Intents composition are landed;
no `clipyctl` executable, Local Automation authenticated ingress, or transport
exists in the current source tree.

### 0.1 Stable public interface and mandatory implementation order

The only stable process-external interface is the first-party `clipyctl`
executable: one versioned UTF-8 JSON request on stdin, one versioned UTF-8 JSON
reply on stdout, and a small frozen set of exit-code classes. Socket paths,
framing, credentials, launch handshakes, XPC names, and App Intent names are
private implementation details and are not a second public interface.

The JSON contract may be reviewed and frozen before implementation. Production
code must nevertheless land in this order:

1. the complete in-process gateway substrate, including authoritative denial
   and one granted bounded positive path through the real Authority;
2. the existing App Intents adapter through a prebound connection-scoped
   facade to that same gateway;
3. the pure `clipyctl` JSON/exit-code codec, with no transport and no fabricated
   gateway result;
4. one selected, replaceable private transport and its restricted authenticated
   ingress;
5. Local Automation browse, content read, and mutations as separate grant-gated
   leaves.

Writing examples or golden JSON before step 1 is specification work, not a
license to ship an `unsupported` CLI shell. No CLI target, socket listener, or
transport may be used to make an absent gateway look implemented.

### 0.1.1 X.8 pure codec boundary

X.8 adds the no-product, Foundation-only SwiftPM target `ClipyCLIContract`.
It owns pure request decoding, reply encoding, and the stable exit-class map;
it owns no `main`, `FileHandle`, executable product, process I/O, launch logic,
credential, authenticated ingress, private transport, Gateway dependency, or
History dependency. A later executable may call this codec, but the codec does
not dispatch a request or fabricate a positive Gateway result. Tests may encode
typed reply fixtures only to prove the wire grammar and stdout bytes; such a
fixture is not evidence that History or Python automation is available.

Protocol v1 admits exactly one request operation: `browsePreview`. It is a
closed wire set for X.8. In particular, `readEffectiveContent`, `organize`,
`deleteItem`, `describeFormatCapabilities`, and `reviseContent` are not v1
codec operations in this leaf. Adding one is a later owner-approved protocol
and Gateway-admission slice, not an unknown-field extension.

Request bytes are admitted under this complete envelope:

- at most **65,536 bytes**, checked on the supplied byte buffer before UTF-8
  decoding, JSON parsing, or any parser-owned allocation; input must be strict
  UTF-8 and must not start with a UTF-8 BOM;
- exactly one root JSON object followed only by RFC 8259 JSON whitespace
  (`0x20`, `0x09`, `0x0A`, `0x0D`); every other leading/trailing byte, a second
  value, or an empty input is invalid;
- maximum nesting depth **8** (the root object is depth 1 and each contained
  object/array adds 1), maximum lexical members in any object **32**, and
  maximum elements in any array **512**;
- unknown fields are rejected at every object boundary, and object keys that
  decode to the same UTF-8 scalar/byte sequence are duplicates and are rejected
  before a typed request is constructed (`"a"` equals `"\u0061"`; the codec
  introduces no NFC/NFD normalization);
- JSON numeric tokens must use the JSON integer lexical form. Fractions,
  exponents, implementation non-finite extensions, and values that fail the
  target field's checked integer conversion are invalid. A decoder must not
  round through floating point.

The encoded reply is at most **33,554,432 bytes**, including the terminal LF.
The bound applies to the complete future stdout byte buffer before any write;
exceeding it is an invalid codec output, never truncation. X.8 adds no
representation or binary-content operation, so this response envelope is not
an admission of large-content export.

`requestID` is exactly a lowercase canonical, 36-character hyphenated,
non-nil UUID string (`8-4-4-4-12`). It is minted by the caller and used only to
correlate one reply. Reusing the same value across requests is accepted by the
codec: X.8 adds no idempotency, retry cache, digest, hash, or identity derived
from the request text.

The root request has exactly `protocolVersion`, `requestID`, `operation`, and
`arguments`. `protocolVersion` is the integer `1` and `operation` is the string
`browsePreview`:

```json
{"protocolVersion":1,"requestID":"9bd92054-bd3f-4d20-8f8a-5d77aa63b726","operation":"browsePreview","arguments":{"limit":20}}
```

`browsePreview.arguments` is one of these exact objects. The union is
discriminated by field presence; it has no `kind` field:

```json
{"limit":20}
{"limit":20,"cursor":"opaque-nonempty-cursor"}
{"query":"needle","mode":"exact","limit":20}
{"query":"needle","mode":"regexp","limit":20,"cursor":"opaque-nonempty-cursor"}
```

The recent form omits both `query` and `mode`; the search form requires both.
`mode` is exactly `exact`, `fuzzy`, or `regexp`. `limit` is an integer in
`1...500`. A search query is non-empty and
at most 4,096 UTF-8 bytes; fuzzy additionally admits at most 64 Characters and
regexp at most 512 Characters, matching `03b` §8 and `06` §2. Exact has no
second Character limit. A cursor, when present, is opaque, non-empty UTF-8 of
at most 4,096 bytes. Having exactly one of `query` and `mode` is invalid. All
string bounds are checked on the decoded string, not on JSON escape spelling.

### 0.1.2 Frozen reply and process-emission grammar

A success reply has exactly this envelope:

```json
{"ok":true,"protocolVersion":1,"requestID":"9bd92054-bd3f-4d20-8f8a-5d77aa63b726","result":{"items":[],"nextCursor":null}}
```

`result.items` preserves the authoritative browse order. Every item is an exact
object with `locator`, `title`, `typeIdentifiers`, `lastCopiedAt`, `pinned`, and
`snippet`. `locator` is non-empty opaque UTF-8 of at most 1,024 bytes;
`typeIdentifiers` contains at most 32 strings and each identifier is at most
512 UTF-8 bytes. `lastCopiedAt` is UTC RFC 3339 with exactly milliseconds and a
literal `Z`. `pinned` is Boolean; `snippet` is either a string or `null`.
`title` and `snippet` must already satisfy their owning History projection
bounds: title at most 1,024 UTF-8 bytes and snippet at most 322 Characters
(`06` §2). These are references to the owning limits, not second wire-specific
literals.
`nextCursor` is either `null` or an opaque, non-empty UTF-8 string of at most
4,096 bytes. Item order and
`typeIdentifiers` order are semantic input order, not encoder-sorted order.
For example, one item is emitted with lexicographically ordered keys as:

```json
{"lastCopiedAt":"2026-08-23T12:34:56.789Z","locator":"opaque-locator","pinned":false,"snippet":null,"title":"Example","typeIdentifiers":["public.utf8-plain-text"]}
```

An error reply has exactly this envelope; `requestID` is the validated request
ID when one was available before the failure, otherwise `null`:

```json
{"error":{"code":"invalid_request"},"ok":false,"protocolVersion":1,"requestID":null}
```

Object keys at every level are emitted in lexicographic order as compact UTF-8
JSON, followed by exactly one LF byte. There are no other stdout bytes. This is
a pure byte-rendering rule in X.8: a real file-descriptor/stdin/stdout proof
belongs to X.9. A future executable's stderr is exactly
`clipyctl: <error.code>\n` on failure and empty on success; it contains no free
text, query, cursor, request fragment, content, credential, or internal error.

The exit class is stable and deliberately coarser than `error.code`:

| Exit | Meaning | Exact `error.code` values |
|---:|---|---|
| `0` | success | Success envelope only; a future `unchanged` result is also success. |
| `2` | invalid invocation/request | `invalid_json`, `invalid_request`, `unsupported_protocol_version`, `unknown_operation`, `request_too_large`, `response_too_large` |
| `3` | denied | `not_enrolled`, `not_granted`, `connection_revoked`, `authentication_failed`, `peer_rejected` |
| `4` | target conflict | `not_found`, `cursor_expired`, `content_stale`, `locator_invalidated` |
| `5` | transient | `not_ready`, `rate_limited`, `busy`, `timeout`, `cancelled`, `outcome_unknown` |
| `6` | Clipy/data failure | `store_open_failed`, `corrupt_data`, `invariant_violation`, `transaction_failed`, `audit_failed` |

Exit-2 parser/encoder classification is deterministic. `request_too_large`
means only that input exceeded the 65,536-byte request envelope. `invalid_json`
covers
invalid UTF-8, BOM, JSON syntax, non-whitespace trailing bytes or a second root,
duplicate decoded keys, depth/width limits, and `NaN`/`Infinity` extensions.
`invalid_request` covers typed root/field shape, unknown or missing fields, type
mismatch, the no-fraction/no-exponent policy, checked integer overflow,
`requestID`, and operation-argument bounds. A valid but unsupported
`protocolVersion` maps to `unsupported_protocol_version`; a valid closed-set
operation miss maps to `unknown_operation`. `response_too_large` means only the
complete encoder-output envelope failed.

The code set is closed for protocol v1. X.8 may render any typed error fixture
in this table to prove stable bytes and exit mapping, but it does not produce a
Gateway failure or claim that the corresponding production path exists.

### 0.2 Connection-kind allow matrix

`ConnectionEnrollKind` is closed. It contains `.appIntents` for the existing
surface and adds `.localAutomation` for user-enabled `clipyctl` access. A
durable connection kind is minted by the owning enrollment path; a request or
adapter cannot self-report or replace it.

Authorization is a total, closed function of connection kind, capability, and
operation. Unknown combinations deny before History access or an audit side
effect. Shared enum constructibility never grants an operation:

| Connection kind | Grantable capability and allowed operations | Always denied |
|---|---|---|
| `.appIntents` | Existing V2-05 surface only: `.browse` -> `recent/search`; `.readContent` -> `details/pastePayload`; `.manage` -> `pin/unpin/remove`, with the existing `.manage`-implies-`.browse` rule | Every Local-Automation-only capability/operation and every unknown pair |
| `.localAutomation` | `.browsePreview` -> bounded recent/search; `.readEffectiveContent` -> Effective-only representations; `.organize` -> pin/unpin; `.deleteItem` -> one-item delete | App-Intents-only `details/pastePayload/manage`, capture, clear, retention/admin, generic action, every unknown pair, and `.reviseContent` until its separate OCC contract is admitted |

This table preserves the current App Intents capability names, implication, and
operation set. Adding `.localAutomation` does not silently narrow, broaden, or
migrate existing App Intents grants. Conversely, `.manage` never becomes a
Local Automation shortcut for delete or revise.

For clarity, this pre-admission rule narrows the older blanket statement that
every denial is audited: an unrecognized raw value or a capability/operation
pair forbidden for its durable connection kind is not an admitted external
operation and produces no OperationRecord. A well-formed operation that belongs
to the kind but lacks a live grant is an admitted request and follows the
existing denial-audit rule. `PLAY-PY-GW0` proves only the pure classification;
the later Gateway denial leaf proves the side-effect ordering.

### 0.3 Account scope, capability declaration, and F1 ingress decision

Local Automation is scoped to the same **effective user account (same EUID)**.
That is an account-wide product boundary, not proof of the same GUI, login, or
audit session and not per-script identity. A final chosen transport must verify
its peer evidence in the signed release matrix; the gateway still performs
enrollment, live-grant, and authoritative operation checks.

`describeFormatCapabilities` is only a declared JSON shape until a production
composition owner can inject immutable Foundation summaries exported by each
format owner. It is not a history-content grant, must not read History, and must
not copy a build/test inventory or a second UTI policy table into the CLI or
gateway. Until that injection owner is approved, no runtime endpoint is
claimed, even if golden JSON examples or a pure serializer exist.

The Local Automation transport also needs a restricted app-facing
authenticated-ingress interface because `ClipyApp` cannot reach an internal
`ExternalGateway` and an unknown credential cannot use the App Intents
prebound facade. The current design direction is an opaque public facade owned
by `HistoryStorage`; only an approved SwiftPM transport target calls its
`package` execution method, using neutral package-only request/result/peer DTOs
rather than Gateway or SwiftData vocabulary. The facade delegates credential
resolution, grant evaluation, authoritative recheck, audit, and execution to
the internal Gateway. F1 may implement this shape only after its neutral DTOs,
framing bounds, and failure mapping are frozen; it must not publish the Gateway,
CredentialStore, socket path, or framing as a second public interface.

For the current **non-sandbox, account-wide** product direction, credential
custody is now decided as follows:

- one credential is exactly 48 opaque bytes: the preassigned connection UUID
  as 16 bytes followed by 32 bytes generated directly with `SecRandomCopyBytes`;
  neither component is a request hash, digest, signature, derived identity, or
  password encoding;
- the server stores that exact 48-byte value in the app-private Data Protection
  Keychain (`kSecUseDataProtectionKeychain`), keyed by the connection UUID. No
  secret is added to SwiftData, an audit payload, argv, environment, or log;
- the first-party client stores the same exact value in one owner-only file
  beneath a validated owner-only directory: directory mode `0700`, regular-file
  mode `0600`, no symlink traversal, no-follow open, owner/mode/type checks on
  the opened descriptor, and byte-exact length/readback. The provisioning
  helper receives the value only through a dedicated inherited stdin descriptor,
  never argv, environment, cwd-derived input, or a caller-selected output path;
- these filesystem modes and same-EUID peer checks exclude other UIDs and
  accidental path substitution under the validated rules. They do **not**
  provide confidentiality against another malicious process already running as
  the same EUID. That limitation is part of the product promise, not a claim
  repaired by calling the bytes a credential.

Enrollment publishes authority last. The app preassigns the connection UUID and
secret, invokes the bounded provisioning helper, verifies an exact client-file
readback, writes and exact-reads the server Keychain item, and only then asks the
single Authority transaction to insert the preassigned `.localAutomation`
connection row plus its successful admin-enroll audit. That row starts with
**zero grants**; enrollment never grants `browsePreview` or another capability
implicitly. A crash before the Authority transaction can leave a client file,
a Keychain item, or both, but no durable connection row or grant: those orphans
are powerless. At startup, exact 48-byte Keychain/client artifacts whose UUID
has no matching durable local-automation row are removed best-effort; a repeated
enable retries the same cleanup before minting a fresh UUID. Cleanup failure is
reported and blocks publication rather than causing a row to be inferred from a
secret.

This is the sole F1 enrollment seam. The existing public
`GatewayAdminHistory.enrollConnection(kind:displayName:credential:)` overload
is not allowed to create a usable `.localAutomation` connection: it cannot
express the preassigned identifier or prove the two custody readbacks. The F1
implementation must therefore route the in-app enable action through one
concrete enrollment coordinator and make the generic overload reject
`.localAutomation` before mutation. Until that coordinator lands, direct
`.localAutomation` enrollment remains only a storage-test fixture for kind and
grant validation; no product composition exposes it as enrollment. The
coordinator alone calls a narrower internal Authority method carrying the
preassigned ID and `credentialWasProvided == true`; callers never supply secret
bytes to the public admin protocol.

Revocation takes the opposite authority-first order. The Authority transaction
first durably marks the connection revoked, revokes every live grant, and appends
the admin-revoke audit. The server then retains a bounded verifier record for
that exact credential so a later valid presentation returns the stable
`connection_revoked` result; retention is bounded by the existing connection
limit and is removed only by an explicit later maintenance policy. Client-file
deletion is best effort and cannot make revocation succeed or fail. Rotation is
enrollment of a **new connection and credential** followed by revocation of the
old one; grants do not migrate or copy, so the new connection again starts with
zero grants.

Ingress classification is ordered and privacy-bounded. A malformed credential,
unknown UUID, wrong secret, malformed frame, or rejected kernel peer fails before
Gateway admission and is unaudited. A byte-exact credential for a durable revoked
connection produces an audited `connection_revoked`; a byte-exact active
credential without the required live grant produces an audited `not_granted`.
The stored secret comparison is byte-exact and timing-safe, but that mechanism
does not change the accepted same-EUID threat model.

This decision removes the former F1 client-custody **spec** blocker only for the
current non-sandbox account-wide promise. Actual Developer ID/team/profile,
Data Protection Keychain round-trip, nested-tool signing, installer/provisioning,
notarization/stapling, Gatekeeper, and the real caller matrix remain open signed
evidence. If a future threat model requires confidentiality from malicious
same-EUID processes or enables App Sandbox, the client must become an app-like
wrapped executable with an approved shared Data Protection Keychain access
group (and matching Team ID/profile/entitlements) or another separately approved
custody model. A bare owner-only file cannot satisfy that stronger promise.

Two wire-identity blockers also remain open. X.8 admits a cursor of at most
4,096 UTF-8 bytes, while the current private `HistoryPageCursor` can encode to
roughly 26 KiB at its admitted query bounds; it therefore cannot be forwarded
as the CLI cursor. The external item locator likewise needs an owner-approved
stable lifetime/invalidated behavior rather than exposing a raw History UUID.
F1 must choose bounded server-side state or another explicit versioned encoding
for each. It must not add a hash, digest, truncated fingerprint, or hash-derived
identity to squeeze either value under the wire bound.

This amendment introduces no request digest, integrity hash, token framework,
or transport security framework. Retry remains non-automatic until a later
typed idempotency contract is separately approved.

### 0.4 F0A ad-hoc-signed UDS discriminator (evidence only)

`PLAY-PY-F0A` is a landed compile-time-isolated platform experiment, not the
selected private transport. PR #18 compiled it only into the manually
dispatched signed-runtime proof artifact. The Apple/XNU provenance and its
claim ceiling are recorded in
the [platform source memo §13.1](../reviews/2026-08-22-clipy-maccy-deep-review/apple-platform-source-memo.md):

- the main-app listener is compiled only with `CLIPY_UDS_F0`;
- `ClipyUDSF0Client` is an XcodeGen diagnostic tool, not a SwiftPM product, not
  a `clipyctl` product, and not part of normal Debug or Release artifacts;
- the dispatch proof copies that tool into the one proof app, signs the nested
  tool and then the outer app, and exercises that exact artifact. The normal
  app has no listener or bundled diagnostic client.

F0A has its own fixed private bytes and must not reuse X.8 JSON. One connection
carries one request and one reply, then closes:

```text
request (25 bytes) = ASCII "CLIPYF0Q" (8) | version 0x01 (1) | client nonce (16)
reply   (53 bytes) = ASCII "CLIPYF0R" (8) | version 0x01 (1) | echoed nonce (16)
                   | per-process generation (16)
                   | effective UID UInt32 big-endian (4)
                   | effective GID UInt32 big-endian (4)
                   | server PID UInt32 big-endian (4)
```

The generation is a fresh opaque 16-byte value for each app process. It is not
derived from the request, executable, endpoint, PID, or a hash. The listener
does no JSON decoding, History request or mutation, credential handling,
authenticated ingress, Gateway call, durable audit, idempotency, or public
stdout/stderr emission. It uses backlog 4, admits at most one request per
connection, and applies a 2-second deadline independently to the complete
accepted-socket read and write. It creates no unbounded task, connection pool,
queue, stream, or retry loop.

The endpoint path is strict UTF-8 and at most 103 bytes before the terminating
NUL for `sockaddr_un.sun_path`. Its dedicated directory is owner-only mode
`0700`; the socket and lifetime advisory-lock file are mode `0600`. The lock is
coordination evidence, not authentication. Existing symlinks, non-socket
nodes, wrong owners, or wrong modes fail closed. If bind reports an occupied
path, a successful connection means a live listener and is never unlinked.
Only `ECONNREFUSED`, followed by two `lstat` observations of the same
owner-owned socket device/inode while the lifetime lock is held, permits stale
unlink and one bind retry. Every other probe result fails closed. Normal stop
unlinks only when the path still has the device/inode captured after bind.
These rules reduce accidental live-node deletion; they do not prevent a
malicious same-EUID process from denial of service.

For a cold attempt the diagnostic client resolves the containing proof
`Clipy.app` from its own executable location, not cwd or a bundle-ID search.
After an observed absent/refused connect, it calls
`NSWorkspace.openApplication` with all four configuration values explicit:
`activates = false`, `addsToRecentItems = false`,
`promptsUserIfNeeded = false`, and
`createsNewApplicationInstance = false`. Launch completion is neither awaited
nor treated as readiness: after issuing the request, the client owns a single
10-second reconnect deadline. The cold success path is structurally admitted
only after an initial absent/refused observation and at least one subsequent
connect attempt, distinguishing it from a client that found a warm listener.

The signed-runtime F0A proof has three required same-EUID cells:

1. **Cold:** start with no app process, observe an initial absent/refused
   connect, launch without requested activation, then receive one valid reply.
2. **Warm:** reconnect without launching another instance and observe the same
   server PID and generation.
3. **Crash residue:** send `SIGKILL`, leave the stale socket, relaunch, and
   observe both a new PID and a new generation after conservative stale
   recovery.

A different-UID rejection and interactive confirmation that no Dock, focus,
panel, or recent-items activation occurred remain open when the hosted runner
cannot observe them. F0A therefore supports only this conclusion: the exact
ad-hoc-signed, non-sandbox proof artifact demonstrated bounded main-app-owned
UDS mechanics for a same-EUID diagnostic client. It does **not** establish
Developer ID identity or team, secure timestamp, notarization/stapling,
Gatekeeper, App Sandbox/App Groups, Keychain sharing or client custody, TCC,
the final caller matrix, Python-to-History access, or a production transport
choice. PR #18's green runs establish exactly those hosted/source cells and do
not upgrade this paragraph's support ceiling.

## 1. Role and boundary

V2-05 answers one question:

> *How is a single, capability-gated, audited trust boundary for external callers
> (App Intents / Siri / Shortcuts / Spotlight) grafted onto the v1 single-writer
> commit kernel — letting those callers read, and within a granted capability
> mutate, retained history — without weakening `00` §3.3 (single write authority),
> `01` §8 (no service locator / no second writer), D1–D19, or the closed
> `HistoryAction` / `ClipboardHistory` seam?*

X1 (`V2-00` §3) and X2 (`V2-00` §3) bundle onto one substrate:

1. **`ExternalGateway` — the single trust boundary (X1).** A `Sendable`
   internal actor in `HistoryStorage` that external callers reach only through
   the public `ExternalHistoryFacade` (§6.5, CRIT-M3).
   Every external request is validated at the gateway, gated against the
   requesting connection's durable capability grant, and — for writes — routed
   through `HistoryAuthority` (the sole writer, `00` §3.3). No external path
   creates a `ModelContext`, loads a planning fact, or bypasses the v1
   stamping/transaction stages (decision 16, `V2-00` §5). The gateway itself
   decodes no blob; an external `.details`/`.pastePayload` read does cause
   lineage decode **inside the Authority** via the unchanged v1 projection
   (`05` §14.3), never in the gateway.
2. **Connections and grants (X1).** Durable, user-enrolled connections
   (`ConnectionRow`) each carrying a granted capability set (`GrantRow`); the
   user (via the UX, V2-07) enrolls and revokes. For V2 the single enrolled
   connection is the **App Intents surface** (Siri / Shortcuts / Spotlight); the
   grant is the user's consent, not a cryptographic credential (§3.3).
3. **App Intents exposure (X1).** A set of `AppIntent` conformances in `ClipyApp`
   (the composition root) that resolve one app-local `AppIntentHistoryIngress`
   via `@Dependency` and `await` it in `perform()` (pending verification under `X-COMPILE-2` / `X-SECURITY-1`; `V2-facts.md`
   cycle 6, facts 1–4). At the earliest launch entry, before awaiting store
   open, `ClipyApp` registers one asynchronous ingress provider into
   `AppDependencyManager.shared`; it awaits the same composition-open work as
   the UI. The ingress contains `makeAppIntentsHistoryFacade()`'s exact value
   plus one MainActor committed-remove sink owned by the composition root
   (§6.5); it owns no grant, audit, or History policy.
   Every write still delegates to `HistoryAuthority`. `@Dependency` is App
   Intents' mandated DI mechanism, NOT
   a banned `.shared`/`.current` service locator — justification and carve-out
   in §6.5.
4. **`OperationRecord` audit (X2).** Every external operation — read or write,
   succeeded, failed, noOp, or denied — produces an `OperationRecord` in the
   Audit domain. Succeeded writes and admin ops produce **exactly one** record,
   committed **atomically with their mutation** in the same
   `ModelContext.transaction` closure — the history mutation for writes, the
   admin-state mutation (ConnectionRow/GrantRow insert or status flip) for admin
   ops (like V2-03's HCR append — crash-consistent: closure failure commits
   neither). Reads first compute an immutable result/failure, then must commit
   exactly one audit record in a separate Authority transaction **before** the
   DTO/content or typed read failure is released to the caller; audit failure
   fails the read closed and publishes no payload. Every admitted noOp, denied,
   or failed write/admin attempt likewise awaits its separate audit append
   before returning or throwing. Thus every completed admitted API attempt has
   exactly one durable record; only its transaction placement differs. The audit log is append-only by API (D36 sole exception:
   compaction). Its executable integrity checks are typed payload decoding, a
   monotone contiguous `auditSequence`, and an explicit compaction floor. These
   detect malformed payloads and incoherent sequence state; they do not provide
   or claim cryptographic tamper evidence.

V2-05 owns:

- the connection/grant/audit data model (new V2 `ConnectionRow`, `GrantRow`,
  `OperationRecordRow` tables, a `GatewayConfigRow` singleton, and versioned
  `OperationPayloadBlobV1` codec, all internal to `HistoryStorage`; X.3 adds
  the models/limits/bootstrap, while X.4 owns the complete codec and audit/admin
  behavior);
- the `ExternalGateway` actor (validation, capability gate, audit coordination,
  delegating every durable lookup and operation directly to
  `HistoryAuthority` through targeted methods; there is no extra intermediary
  actor);
- the `AppIntent` conformances and `ClipboardShortcuts: AppShortcutsProvider` in
  `ClipyApp`;
- the F1 credential-store seam (server-side app-private Data Protection
  Keychain `SecItem*` plus the §0.3 client-file custody decision; unused by the
  App Intents path. PR #20 landed only the internal exact-value/server-store
  leaf; client custody, coordination, authentication, and ingress remain
  unimplemented);
- new public "distinct concern" protocols in `HistoryCore`
  (`ExternalHistory`, `GatewayAdminHistory`) and DTOs;
- the six graft-admission records (`V2-00` §4), V2 proof gates, migration
  impact, and new invariants **D32–D36**.

V2-05 owns no `HistoryAction` case, no `HistoryMutation` case, no
`StampedMutation` case, no `PlannedOutcome` case, and no change to the closed
`ClipboardHistory` protocol or to the v1 `HistoryFailure` enum. The Domain
(`HistoryDomain`) is untouched by the gateway: it remains pure, Foundation-only,
and unaware that external callers or an audit log exist. Admin operations
(enroll/revoke/grant) and external operations live on **distinct protocols**
(`GatewayAdminHistory`, `ExternalHistory`), not on `HistoryAction` (§7.2, §7.1 —
justified against `03a` §1 closed-set discipline).

### 1.1 What V2-05 is NOT

- **Not a second writer.** `ExternalGateway` creates no `ModelContext`; every
  write delegates to `HistoryAuthority` (`00` §3.3; D32). It is a gating/audit
  facade, not a persistence authority.
- **Not multi-process.** App Intents live in the **main app target** and run
  in-process, inheriting the app's single in-process Authority. A separate App
  Intents **extension target** is a second process and is explicitly post-V2
  (`V2-00` §3.1 multi-process exclusion; `V2-facts.md` cycle 6, OPEN 1).
- **Not CloudKit / multi-device sync** (`V2-00` §3.1).
- **Not a replacement for the HCR.** The History Change Record (V2-03) records
  *what changed in history* for reconnect/cache completeness; the
  `OperationRecord` records *which external connection requested what* for audit
  provenance. An external write produces **both** (the HCR by V2-03's always-on
  append, the OperationRecord by V2-05's audit append), cross-referenced by
  `ChangePosition`, in the **same** transaction (§5.4). They never replace each
  other.
- **Not an external surface for every `HistoryAction`.** `capture`, `revise`,
  `clear`, and `setRetentionPolicy` are **app-only** and have no external
  request case (§3.2). External callers get a deliberately smaller, safe
  request set.
- **Not tamper evidence or non-repudiation.** V2-05 deliberately adds no audit
  hash, checksum, signature, HMAC, or chain. Typed decoding and contiguous
  sequence validation are corruption/invariant checks, not evidence against an
  attacker who can coherently rewrite the store (§4.4, Record 6).

### 1.2 What V2-05 explicitly lifts

X1 (`V2-00` §3) lifts the v1 exclusion "`ExternalGateway`, external connections,
grants, App Intents, and request audit records" (`00` §2; `06` §4) and the
product-deferred "`ExternalGateway`, external connection enrollment/grants, App
Intents, or third-party writes" (`06` §4). X2 lifts "Operation Record auditing
and Audit/Connections domains" (`00` §2; `06` §4), admitted as X1's consequence.
v1 states "`HistoryStorage` ... is the sole SwiftData authority" (`00` §2) and
"`ClipyApp` is the sole composition root" (`00` §2); V2-05 preserves both by
placing all `@Model`s in `HistoryStorage` and all `AppIntent` conformances +
`@Dependency` registration in `ClipyApp`. This is stated honestly here rather
than implied: a v1 reader finds no `ExternalGateway`, no connection/grant
tables, no `OperationRecord`, no `AppIntent`, and no `@Dependency`, by design.

## 2. Capability scope

Sections 2–14 specify the first production stage: the App Intents gateway and
audit substrate. The later Local Automation continuation is governed by §0;
where this body says "V2 ships App Intents only," it describes that first stage,
not a permanent prohibition on the ordered `clipyctl` continuation.

### 2.1 In scope (X1 + X2)

- A single enrolled **App Intents surface** connection (Siri / Shortcuts /
  Spotlight) for V2; the connection/grant model is general (§3.3 admits future
  enrollment kinds).
- External **metadata reads** (`browse` capability): `read(.recent(limit:))` /
  `read(.search(text:mode:limit:))` — producing the v1 `HistoryPage` DTO and audited.
- External **content reads** (`readContent` capability): `details(for:)`,
  `pastePayload(for:)` — producing the v1 `HistoryDetails` / `PastePayload` DTOs
  (full content; the content-exfiltration surface, §3.2) and audited.
- External **writes** (`manage` capability, which implies `browse` but **not**
  `readContent`): `.pin`, `.unpin`, `.remove(itemID)` on individual retained
  items — routed through `HistoryAuthority` as the corresponding v1
  `HistoryAction` (§5.1), each producing a History Commit, an HCR row (V2-03),
  and an OperationRecord, all in one transaction.
- Admin operations (in-app UX only, `GatewayAdminHistory`): enroll/revoke a
  connection, grant/revoke a capability, read the audit log. Admin operations
  are themselves audited.
- A durable, append-only-by-API `OperationRecord` audit log; `ConnectionRow` /
  `GrantRow` current-state tables; a `GatewayConfigRow` singleton.

### 2.2 Out of scope (remains post-V2)

- **App Intents extension target / any second process** (`V2-00` §3.1). V2
  routes every external request through one process's `HistoryAuthority`.
- **External `capture`.** An external capture would let any enrolled caller
  inject arbitrary content into history (content injection, dedup-pollution,
  retention-pressure attack). It is **app-only** and has no external request
  case. (A future "trusted ingest" graft would need its own security review.)
- **External `revise`, `clear`, `setRetentionPolicy`.** Destructive / config
  operations with no safe external audit rollback (`clear` is bulk destruction;
  `revise` mutates Canonical lineage; `setRetentionPolicy` is admin config, not
  history content). App-only.
- **CloudKit / multi-device audit sync** (`V2-00` §3.1).
- **Cryptographic integrity, tamper evidence, or non-repudiation.** None is
  claimed or implemented. A future security graft would require explicit user
  approval of that new boundary; it is not predesigned here.
- **A network / remote enrollment kind.** The credential-store seam (Keychain)
  is specified (§6.7) but exercised only by future non-App-Intents enrollment
  kinds (URL-scheme bearer token, XPC service label). V2 ships App Intents only.

### 2.3 Evidence triggers (admit design work)

- **X1** lifts `00` §2 and `06` §4. Trigger: an approved product spec **and** a
  fresh architecture review (`V2-00` §3). This doc **is** that architecture
  review; it does not authorize shipping without its proof gates passing.
- **X2** lifts `00` §2 and `06` §4. Trigger: X1 approved (audit is X1's
  consequence) (`V2-00` §3).

Both triggers have fired: V2-00 approved the graft, and X.1–X.7 are landed.
This subsection records the admission history; it does not waive the separate
proof gates for X.8 or later slices, nor X.7's still-open signed-runtime cells.

## 3. Trust boundary and capability model

### 3.1 The single trust boundary

`ExternalGateway` is the **only** surface an external caller reaches. The trust
boundary is drawn at the gateway's entry:

```text
External caller (App Intent perform() / Siri / Shortcuts / Spotlight)
  -> @Dependency resolves the connection-scoped ExternalHistory facade
       (obtained by ClipyApp from SwiftDataHistory at launch; connectionID
        baked in at construction — the caller CANNOT forge a different
        connectionID)
  -> ExternalGateway.perform(_:as:) / read(_:as:)
       PRE-ADMISSION — CONNECTION, THEN DESCRIPTOR + KIND (§0.2): first compare
          the supplied ID with the actor's startup-validated App Intents ID; a
          mismatch is an unknown connection and returns immediately. For that
          known connection only, derive the operation descriptor and required
          capability purely from the closed typed request, then apply the pure
          `(kind, capability, operation)` allow matrix with the actor's baked-in
          `.appIntents` kind. A kind-forbidden pair returns independently of the
          unknown-connection check. Both failures precede token debit, History
          evaluation, and audit append and are not admitted Gateway operations.
          The same pure admission step validates the bounded scalar fields
          required to form the closed, truthful `RequestSummaryV1`; malformed
          limits/search lengths neither consume a token nor fabricate an audit
          summary.
          No durable lookup occurs here. A future authenticated ingress must
          resolve its durable Local Automation connection and kind before
          entering steps 0a/0b.
       0a. CADENCE MAINTENANCE (§4.5): the Gateway actor counts structurally
          admitted requests. Before every Nth request can debit a token or
          enter a request-specific Authority operation, call the Authority's
          throwing audit compaction. Maintenance failure keeps the cadence due,
          consumes no token, executes and audits no request, and returns that
          failure; the identical retry attempts maintenance again. This
          pre-dispatch ordering means maintenance cannot replace an already
          committed request outcome. Actor reentrancy does not create parallel
          maintenance: the Gateway retains one shared in-flight compaction
          attempt. The request that creates it is the Nth request; concurrent
          followers await that same attempt. On success, followers count as
          requests in the newly opened cadence interval. On shared failure,
          creator and followers all observe the failure and cadence remains at
          N−1 for the next structurally admitted retry.
       0b. RATE-LIMIT (§8, X-SECURITY-3): on the ExternalGateway ACTOR (NOT inside
          the Authority interval — the bucket is process-wide in-memory state),
          debit the process-wide App-Intents token bucket; if exhausted, audit-
          as-denied and throw ExternalFailure.requestDenied(.rateLimited)
          BEFORE the Authority gate. The denial is thrown only after its audit commit;
          append failure becomes persistence failure. Runs
          ahead of the live Authority gate so a rate-exceeding caller never
          reaches History evaluation; the denial record itself is
          appended via `Authority.appendDenialAuditRecord`, carrying
          operationKind/capability derived from the typed request case
          (never raw 0 — §4.3 decode is fail-closed).
          Every admitted rate-limited call appends its own immutable denied
          record before returning the denial; denial audits never debit the
          bucket. Unauthenticated framing garbage is not an admitted Gateway
          call and produces no durable audit record.
       1. VALIDATE the request (D35): parameters within V2 bounds, requested
          HistoryItemIDs well-formed; reject malformed input as
          ExternalFailure.requestDenied before any history read.
       2. DISPATCH + AUTHORITATIVE TARGETED ACCESS GATE (D33): call the
          Authority directly; there is no separate grant-lookup interval.
          - read  -> Authority.performExternalRead fetches ConnectionRow.status
                     and only the required live GrantRow(s) INSIDE its
                     non-suspending audit
                     interval(s); if revoked/ungranted there it audits-as-denied
                     and throws ExternalFailure.unauthorized/.connectionRevoked.
                     Else evaluates the v1 read projection (05 §14) and audits.
                     (.recent/.details/.pastePayload fit one non-suspending
                     interval; .search splits into two bracketing the off-actor
                     SearchWorker await — §5.2 step 2.)
          - manage-> Authority.commitExternal fetches ConnectionRow.status and
                     the required live GrantRow INSIDE the same ModelContext.transaction
                     closure that applies mutations; if revoked/ungranted there it
                     throws and the closure commits nothing (the audit-as-denied
                     record is appended in a separate small follow-up transaction).
                     Else applies the v1 plan + appends HCR + OperationRecord in
                     the SAME transaction (D34).
       4. AUDIT one OperationRecord, crash bound per op class (D34):
          succeeded writes exactly-one, in-commit, atomic with the history
          mutation; admin ops exactly-one, atomic with the admin-state mutation
          (ConnectionRow/GrantRow insert or status flip) in the same transaction;
          all reads commit exactly-one in a separate transaction before their
          result/failure is released; an audit-append failure replaces the read
          outcome with a persistence failure and releases no DTO/content.
          noOp/denied/failed writes also await a separate append before their
          response/failure is released. A targeted-gate denial at step 2 is
          audited before its typed denial is thrown. Outcome
          succeeded/failed/noOp/denied.
  -> ExternalResponse / ExternalReadResult (Sendable HistoryCore DTOs only)
```

External input is **untrusted** (D35). Every primitive that crosses the boundary
— `HistoryItemID`, search text, mode, limits — is validated against the same v1
`HistoryLimits.standard` bounds (`06` §2) at the gateway before it reaches a
planning fact, a blob decode, or the Authority. The gateway performs no blob
decode and no planning; it validates request shape, checks the grant, and
delegates. This mirrors v1's `PasteboardAdapter` posture (raw observation
validated by preparation before it becomes Domain state, `01` §5.1) and the
thumbnail/OCR source-fetch posture (`05` §14.5, `V2-01` §4).

### 3.2 Capability vocabulary (the App Intents safe subset)

The App Intents stage exposes a deliberately **smaller** request set than v1 `HistoryAction`.
External callers cannot spell `capture`, `revise`, `clear`, or
`setRetentionPolicy` — those cases do not exist on `ExternalHistory` (§7.1).
The App Intents capability set is closed and frozen for its existing surface;
§0.2 adds Local-Automation-only cases behind a connection-kind allow matrix:

```swift
public enum ExternalCapability: Int16, Sendable, Hashable, Codable {
    case browse = 1       // read(.recent)/read(.search) under this capability —
                          // HistoryPage (row titles + bounded search snippet;
                          // the v1 browse surface, 03b §8). Metadata-shaped; NOT
                          // full content.
    case readContent = 2  // details (full HistoryDetails incl. canonical/effective
                          // [HistoryRepresentation], 03b §9) + pastePayload (full
                          // PastePayload bytes for paste). The full-content path.
    case manage = 3       // pin, unpin, remove (individual items); IMPLIES
                          // .browse (a manage caller can enumerate items to
                          // manage) but NOT .readContent (manage operations do
                          // not return content).
    // Local Automation only (§0.2); the connection-kind matrix prevents these
    // cases from broadening an App Intents connection.
    case browsePreview = 10
    case readEffectiveContent = 11
    case organize = 12
    case deleteItem = 13
    case reviseContent = 14 // declared but not grantable until separately admitted
}
```

**Implication rules.** `.browse` is granted explicitly OR via `.manage` (the
targeted gate accepts a `.browse` request when either the `.browse` or
`.manage` row is live). `.readContent` is granted **only** explicitly — `.manage` does NOT
imply `.readContent` (a manage caller can find items to pin/unpin/remove but
cannot read their content). `.manage` is granted only explicitly. The capability
check is O(1) over at most two targeted rows (D33; proof `X-PERF-1`).

**Why browse and readContent are SPLIT (content-exfiltration justification).**
v1 `HistoryDetails` carries the canonical and effective `[HistoryRepresentation]`
(`03b` §9) and `PastePayload` carries the full paste bytes — i.e., both are
**full-content** projections (passwords, tokens, secrets the user copied). v1
`HistoryPage` carries only row titles plus a bounded (≤ 322 Character) search
snippet (`03b` §8) — metadata-shaped. A single coarse `.read` capability that
bundled `browse` with `details`/`pastePayload` would let any read-granted caller
enumerate IDs via `read(.recent)` then loop `pastePayload` over every returned
ID to bulk-exfiltrate the entire history (including secrets) well within any
reasonable per-connection rate limit (the rate limit is per single shared App
Intents connection, §8 — it does not mitigate one caller's sequential
exfiltration). Splitting `.browse` (metadata) from `.readContent` (full content)
lets the user grant metadata access — "Siri can search my history" — without
granting bulk content exfiltration. This is the standard least-privilege
decomposition; the split is surfaced to UX (V2-07) as two distinct data
practices, and the content-exfiltration exposure of `.readContent` is recorded
in Record 6.

**Why this subset (justified against the brief).** `capture` is content
injection (excluded, §2.2). `revise` mutates Canonical lineage (D2/D4-bearing)
and is irreversible across the audit log; `clear` is bulk destruction;
`setRetentionPolicy` is admin configuration, not history content. `pin`/`unpin`/
`remove` are the defensible external writes: organizational or per-item, each
auditable, each reversible-in-audit (the OperationRecord retains the affected
IDs and the v1 `RetirementReason` even after the item is gone, because
`HistoryItemID` is never reused, D1). A `manage`-granted malicious caller can
remove items, but every removal is audited and the user can revoke the grant;
this is the standard capability-security tradeoff, recorded in Record 6.

### 3.3 Connection and grant lifecycle

A **connection** is a durable, user-enrolled authorization of one external
surface. For V2 there is exactly one enrolled connection by default — the App
Intents surface:

```swift
public struct ExternalConnectionID: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UUID
    package init(rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public enum ConnectionEnrollKind: Int16, Sendable, Hashable, Codable {
    case appIntents = 1   // Siri / Shortcuts / Spotlight (V2)
    case localAutomation = 2 // same-EUID account, first-party clipyctl (§0)
    // Reserved enrollment kinds; not exercised by this design:
    // case urlScheme = 3  // bearer-token URL scheme
    // case xpc = 4        // XPC service-label connection
}

public enum ConnectionStatus: Int16, Sendable, Hashable, Codable {
    case active = 1
    case revoked = 2
}
```

- **Enrollment** is an in-app admin operation (V2-07 UX). The ordinary
  `GatewayAdminHistory.enrollConnection` path may mint an
  `ExternalConnectionID` for its admitted non-local kinds and creates a
  `ConnectionRow` (`status == active`) with zero grants. The App Intents
  connection is bootstrapped
  at `open` (§4.6) with **no** capability granted by default — the user must
  explicitly grant `read` and/or `manage` via the UX (deny-by-default).
  `.localAutomation` is never bootstrapped and is never created through that
  generic overload. Its sole admitted path is the §0.3 concrete coordinator:
  custody succeeds first, then Authority inserts the preassigned ID and
  successful audit last, still with zero grants. The currently landed generic
  local-enrollment behavior is transitional test scaffolding and must be closed
  in the same F1 leaf that introduces the coordinator; it is not a product
  enrollment contract.
- **Grant** is per `(connectionID, capability)` (`GrantRow`, §4.2). Granting
  `.manage` implicitly satisfies `.browse` requests (no separate `.browse` row
  required, though the UX may record both for clarity); `.manage` does **not**
  satisfy `.readContent` (§3.2). `.readContent` and `.browse` are granted
  independently. There is exactly one current-state row per pair. A row with
  `revokedAt == nil` is live; revocation sets `revokedAt`; re-grant updates that
  same row with a fresh `grantedAt` and clears `revokedAt`. The separate audit
  record stream preserves grant/revoke/re-grant event history.
- **Revocation** flips `ConnectionRow.status` to `.revoked` and sets
  `revokedAt` on every live `GrantRow` for that connection (a per-capability
  revoke sets `revokedAt` on the matching `GrantRow` only, §5.3). The
  authoritative capability gate is the **in-closure check** inside the
  dispatch transaction (§5.1 step 2 / §5.2 step 2): a request whose connection
  is revoked or whose capability grant is revoked at the save boundary is
  rejected there and audited as denied (`D33`). There is no earlier grant
  check or cached decision. Revocation takes effect on the very next
  in-closure check — there is no window in which a
  revoked connection can commit a write, because the check runs inside the
  same non-suspending closure that applies mutations. (Admin revoke bypasses
  the `ExternalGateway` actor — `GatewayAdminHistory` → `HistoryAuthority`
  directly, §5.3 — so the check, not the actor, is what closes the TOCTOU
  window.)
- **Revocation does NOT unregister the facade.** The connection-scoped facade
  registered in `AppDependencyManager.shared` (§6.5) remains resolved for the
  process lifetime; revoking a connection flips its status and causes
  subsequent intent invocations to be **denied at the in-closure gate**, not
  unresolved. A reader should not assume revocation removes the App Intents
  entry point — it denies per-request.
- **No credential for App Intents.** For `ConnectionEnrollKind.appIntents`, the
  system identifies the caller (Siri/Shortcuts/Spotlight invoke the in-process
  intent); the "connection" models the **user's consent**, not a cryptographic
  identity. The credential-store seam (§6.7) is specified for future
  enrollment kinds (URL scheme bearer token, XPC service label) and is unused
  by the V2 App Intents path.

### 3.4 Local Automation credential custody (F1 direction)

The controlling F1 decision is §0.3: an exact 48-byte credential is stored
server-side in the app-private Data Protection Keychain and client-side in a
validated owner-only no-follow file for the deliberately non-sandbox,
account-wide product. `CredentialStore` remains actor-confined around
`SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`; the client file is not
a shared Keychain substitute and makes no malicious-same-EUID confidentiality
claim. App Intents still use no credential.

This section fixes architecture and publication order, not platform evidence.
PR #20 links `Security` only for an internal 48-byte value plus actor-confined
server-store leaf. Its ordinary correctness tests use
an injected in-memory adapter for the true Keychain boundary, so they establish
shape, validation, and content-free store semantics, not Data Protection
Keychain behavior. `X-PLATFORM-3` must still prove exact add/read/delete,
duplicate/retry handling, process restart, and Developer ID/profile behavior in
the actual signed artifact. No positive Local Automation request may be
released from this server-only leaf.

## 4. Data model

All declarations in this section are `internal` to `HistoryStorage` unless
explicitly noted as a public `HistoryCore` type. Under the incremental-shipping
decision (`V2-roadmap` DC-03), `HistorySchemaV2` is already shipped and
immutable. Gateway/Audit/Connections types therefore first appear in a new
immutable `HistorySchemaV3`; neither `HistorySchemaV1` nor `HistorySchemaV2` is
edited.

### 4.1 ConnectionRow (V3 schema)

```swift
@Model
internal final class ConnectionRow {
    @Attribute(.unique)
    var id: UUID                       // ExternalConnectionID.rawValue

    var displayNameRaw: String         // bounded UTF-8 (ExternalLimits, §4.5); UX label
    var enrollKindRaw: Int16           // ConnectionEnrollKind raw; 0 reserved unset/invalid
    var statusRaw: Int16               // ConnectionStatus raw; 0 reserved unset/invalid
    var enrolledAt: Date               // Storage clock (§5.5)
    var revokedAt: Date?               // nil while active; set on revoke
    var configSchemaVersion: UInt16    // 1 for V2-05
}
```

`ConnectionRow` is a new V3 model for the V2-05 feature. It references capabilities **by value** in
`GrantRow` (no SwiftData `@Relationship`), mirroring `EnrichmentRow.itemID`
(`V2-01` §3.2) and `HistoryChangeRecordRow` (`V2-03` §4.1). Lookups use a
bounded `FetchDescriptor` predicate on `id` (`05` §5 fetch-predicate discipline),
never `registeredModel(for:)` (`05` §18). Decode is fail-closed: an unknown
`enrollKindRaw` / `statusRaw` (forward-incompatible raw value, mirroring
`05` §4 exhaustive-decode discipline) or an out-of-range
`configSchemaVersion` is `.persistence(.corruptStoredValue)` /
`.persistence(.invariantViolation)` (`05` §16); 0 raw values fail closed.

### 4.2 GrantRow (V3 schema)

```swift
@Model
internal final class GrantRow {
    @Attribute(.unique)
    var grantKey: String               // "<connectionID>:<capabilityRaw>"; composite-unique
                                       // anchor (one current-state row per pair)

    var connectionIDRaw: UUID          // ExternalConnectionID.rawValue
    var capabilityRaw: Int16           // ExternalCapability raw; 0 reserved unset/invalid
    var grantedAt: Date                // Storage clock
    var revokedAt: Date?               // nil while the grant is active; set on revoke
    var configSchemaVersion: UInt16    // 1 for V2-05
}
```

A separate `GrantRow` table (rather than a capability-set blob on
`ConnectionRow`) gives the grant a lifecycle independent of the connection: a
revoked connection keeps its audit history; a single
capability can be revoked while the connection stays enrolled for others;
re-granting updates the existing pair row with a fresh `grantedAt` and
`revokedAt == nil`. Exactly one current-state row exists per
`(connectionID, capability)`; grant/revoke/re-grant event history lives only in
append-only `OperationRecordRow`s.
`grantKey` is the composite-unique anchor (SwiftData `@Attribute(.unique)` is
single-attribute; the derived key string encodes the pair deterministically).
The **live access decision** is computed at gate time from the connection row
and only the request's required live grant row. A browse request additionally
checks the `.manage` row to implement the frozen implication. These targeted
rows are fetched inside the request's serialized Authority interval (§5.2); no
complete grant set is built or cached. An unknown `capabilityRaw` fails closed
at decode. `manage` implies `browse` at the gate (§3.2), so a connection granted
only `.manage` still passes `.browse` requests; `.readContent` is never implied
and must be granted explicitly.

### 4.3 OperationRecordRow (V3 schema, X2 audit)

```swift
@Model
internal final class OperationRecordRow {
    @Attribute(.unique)
    var auditSequence: UInt64          // audit-log monotone; one per committed audit record.
                                       // Independent of ChangePosition (reads advance it; a write's
                                       // auditSequence is minted in the same closure as its
                                       // ChangePosition but is a separate counter).

    var connectionIDRaw: UUID?         // external/request or connection-targeted admin record;
                                       // nil for global audit maintenance (rebase/compact)
    var capabilityRaw: Int16?          // required external capability or capability-targeted admin;
                                       // nil when no external grant capability applies
    var operationKindRaw: Int16        // ExternalOperationKind raw (§7.3); 0 reserved unset/invalid
    var outcomeRaw: Int16              // ExternalOutcome raw (succeeded/failed/denied); 0 reserved
    var failureKindRaw: Int16?         // nil on success; a typed discriminator on failure/denial
                                       // (ExternalFailureKindRaw stable raw value; never raw strings)
    var denialReasonRaw: Int16?        // nil unless failureKindRaw == requestDenied; the
                                       // ExternalDenialReason raw (1=.invalidInput, 2=.rateLimited,
                                       // §7.3); 0 reserved unset/invalid. Durably persists the
                                       // .invalidInput vs .rateLimited distinction §7.2 exposes
                                       // (OperationRecordDTO.denialReason) and §8's rate-limit-
                                       // transparency guarantee rests on.

    var payloadBlob: Data              // OperationPayloadBlobV1 (§4.4): request summary + result
                                       // summary (affected IDs / query byte count / counts); bounded

    var requestedAt: Date              // Storage clock captured at gateway entry
    var committedAt: Date              // non-optional: the Storage-clock timestamp this OperationRecord
                                       // became durable (every record — reads/admin/denied/noOp/failed
                                       // included — has one from its audit transaction; writes == the
                                       // history commit time). Reconciled with §5.4/§7.2.
    var changePositionRaw: UInt64?     // nil for reads; the write's ChangePosition (cross-ref to
                                       // required X-HCR HistoryChangeRecordRow.sequence, D34)
    var auditSchemaVersion: UInt16     // 1 for V2-05
}
```

`OperationRecordRow` is a new V3 model. When present, it references the
connection **by value** (`connectionIDRaw`), not a SwiftData `@Relationship`,
so connection revocation does not cascade-delete audit history. Global audit
maintenance records (`rebase`/`compact`) have no target connection, and admin
operations have no external grant capability; the optional columns represent
that truth instead of inventing an `.admin` capability or attributing the event
to `.manage`. `auditSequence` is the audit log's own
monotone fetch key (independent of `ChangePosition`, because reads and denied
requests advance audit but not history). Lookups use a bounded
`FetchDescriptor` predicate on `auditSequence` (`#Predicate { $0.auditSequence
> floor }`, ordered ascending, `fetchLimit` bounded by `ExternalLimits`,
`V2-facts.md` cycle 4 (FetchDescriptor predicate/fetchLimit discipline), never `registeredModel(for:)`.

**Raw-column decode is fail-closed (§4.4 discipline).** Each raw discriminator
column decodes against its frozen raw-value enum (§7.3), mirroring the v1
exhaustive-decode discipline (`05` §4) and the `ConnectionRow`/`GrantRow`
decode above: an unknown `operationKindRaw`/`outcomeRaw`/`failureKindRaw`/
`denialReasonRaw` (forward-incompatible raw value) or a `0` raw value is
`.persistence(.corruptStoredValue)` (`05` §16). `denialReasonRaw` is `nil`
unless `failureKindRaw == requestDenied`; on read it decodes to
`ExternalDenialReason` (§7.3) and populates
`OperationRecordDTO.denialReason` (§7.2) - so the `.invalidInput` vs
`.rateLimited` distinction is durably reconstructable by the audit-log reader,
not lost. (The discriminator is a column, not part of `OperationPayloadBlobV1`;
the payload blob carries the request/result summary only, §4.4.)

Optional attribution is also decoded exhaustively against `operationKindRaw`
and outcome: external requests require both connection and capability;
connection-targeted admin has a connection but no external grant capability;
grant/capability-revoke carries the target pair; global/admin-list/audit
maintenance has neither. Enrollment is the one creation-time exception: a
successful enroll record carries the newly minted connection, while a denied
or failed pre-create enroll has `connectionIDRaw == nil` because no identity
exists. Any other nil/non-nil combination is corrupt stored state. Decoding
never invents an ID, an `.admin` capability, or a `.manage` attribution.

**Append-only is enforced by construction (D36).** The Authority exposes **no
arbitrary** `delete`/`update` path for `OperationRecordRow`. The only general
writer method is `appendOperationRecord` (inside a transaction); there is no
`removeOperationRecord`/`updateOperationRecord` reachable from any external,
admin, or read path. The **sole named, audited exception** is `compactAuditIf
Needed` (§4.5 / §5.6), which trims one oldest prefix, advances
`compactionFloor`, and appends a content-free compaction marker in the same
transaction. Readers validate that the surviving rows form the contiguous
interval declared by `compactionFloor` and `nextAuditSequence`; a missing or
duplicate sequence fails closed. This is an internal consistency check only:
SwiftData cannot prevent a sufficiently privileged actor from coherently
rewriting rows and counters, so V2-05 makes no tamper-evidence claim.

### 4.4 Versioned audit codec (X.4 frozen contract)

X.4's spec-first gate is **resolved and its implementation is landed**.
`OperationPayloadBlobV1` is an
explicit versioned value with closed request and result enums; it is not
synthesized `Codable`, a generic map, or an extensible string envelope. This
decision is based on the callable `ExternalHistory` and `GatewayAdminHistory`
protocols plus the already-admitted Local Automation Effective-content read.
It therefore covers all seven approved App-Intents-stage Gateway operations,
including the bounded `.recent` read retained on `ExternalHistory`; X.7 exposes
exactly six intent types and does not add a separate recent intent. The codec
also covers the Effective-content read, all eight public admin requirements (four state mutations, three reads,
and rebase), and the two distinct revoke semantics. It also covers automatic
internal compaction as the ninth admin-class operation.
`reviseContent` and `describeFormatCapabilities` remain unadmitted and have no
V1 payload case; adding either later requires a new exhaustive codec version or
an explicitly compatible owned case before its first writer.

#### 4.4.1 Stable operation discriminators

Raw values 1...15 already exist in `HistoryCore` and are not renumbered.
`adminRevoke` raw 10 is frozen to mean **connection revoke only**. X.4 adds four
public cases so capability revoke and each callable admin read cannot hide
behind `adminRevoke`, `adminGrant`, or a generic admin payload:

```swift
public enum ExternalOperationKind: Int16, Sendable, Hashable, Codable {
    case readRecent = 1
    case readSearch = 2
    case readDetails = 3
    case readPastePayload = 4
    case managePin = 5
    case manageUnpin = 6
    case manageRemove = 7
    case adminEnroll = 8
    case adminGrant = 9
    case adminRevoke = 10             // revokeConnection only
    case adminRebase = 11
    case adminCompact = 12
    case readEffectiveContent = 13
    case reviseContent = 14           // unadmitted; no V1 payload case
    case describeFormatCapabilities = 15 // unadmitted; no V1 payload case
    case adminRevokeCapability = 16
    case adminReadConnections = 17
    case adminReadGrants = 18
    case adminReadAudit = 19
}
```

All three public admin reads are audited. `connections()` uses raw 17,
`grants(for:)` raw 18, and `auditLog(since:)` raw 19. This is the smallest
interpretation consistent with the existing rule that in-app Gateway
administration is auditable; silently exempting the most sensitive read would
make that rule false. An audit-log read takes a snapshot with an exclusive
high-water mark before appending its own raw-19 record, so the returned page
does not recursively include the record that describes that same read. The
Authority then atomically appends that raw-19 record (and performs any triggered
compaction) before it returns the already-built immutable page. Append failure
throws and returns no page. Like every read audit, it advances no
`ChangePosition`.

#### 4.4.2 Closed request cases

The blob header is `formatVersion == 1`. Each request case has the stable
`UInt16` tag shown below. Integers decode through checked conversion to the
owning bound; UUIDs are encoded as 16 bytes. `SearchModeRawV1` is codec-local
and frozen as `exact = 1`, `fuzzy = 2`, `regexp = 3` because public
`SearchMode` deliberately has no persistence raw value.

| Request tag | `RequestSummaryV1` case | Required row kind / attribution | Bounds and privacy |
|---:|---|---|---|
| 1 | `recent(limit: UInt16)` | `readRecent`; connection + `.browse` or Local Automation `.browsePreview` | `1...500` |
| 2 | `search(queryUTF8ByteCount: UInt16, mode: SearchModeRawV1, limit: UInt16)` | `readSearch`; connection + browse capability selected by connection kind | byte count `0...4096`; query text is never stored |
| 3 | `details(itemID: UUID)` | `readDetails`; connection + `.readContent` | target ID only; no returned bytes |
| 4 | `pastePayload(itemID: UUID)` | `readPastePayload`; connection + `.readContent` | target ID only; no returned bytes |
| 5 | `pin(itemID: UUID)` | `managePin`; connection + `.manage` or `.organize` | one ID |
| 6 | `unpin(itemID: UUID)` | `manageUnpin`; connection + `.manage` or `.organize` | one ID |
| 7 | `remove(itemID: UUID)` | `manageRemove`; connection + `.manage` or `.deleteItem` | one ID |
| 8 | `enroll(kind: ConnectionEnrollKind, displayNameUTF8ByteCount: UInt16, credentialWasProvided: Bool)` | `adminEnroll`; nil capability. Succeeded row carries the newly minted connection; denied/failed pre-create row has nil connection | display name `0...256` bytes; neither display-name text nor credential bytes are stored. X.4 rejects non-nil credentials until the separate ingress/credential decision is admitted, but can truthfully audit that redacted request shape without minting a fake ID |
| 9 | `grant(connectionID: UUID, capability: ExternalCapability)` | `adminGrant`; target connection + target capability | exact pair; current-state row is inserted/re-activated |
| 10 | `revokeConnection(connectionID: UUID)` | `adminRevoke`; target connection + nil capability | distinct from capability revoke |
| 11 | `rebase(reason: AuditRebaseReason)` | `adminRebase`; nil connection + nil capability | typed reason only; no free-form recovery text |
| 12 | `compact` | `adminCompact`; nil connection + nil capability | no caller-controlled fields |
| 13 | `readEffectiveContent(itemID: UUID)` | `readEffectiveContent`; Local Automation connection + `.readEffectiveContent` | one ID; no content bytes in audit |
| 14 | `revokeCapability(connectionID: UUID, capability: ExternalCapability)` | `adminRevokeCapability`; target connection + target capability | exact pair; distinct stable operation raw 16 |
| 15 | `readConnections` | `adminReadConnections`; nil connection + nil capability | no filter text |
| 16 | `readGrants(connectionID: UUID)` | `adminReadGrants`; target connection + nil capability | one target connection; returned grant set absent |
| 17 | `readAudit(since: UInt64, limit: UInt16)` | `adminReadAudit`; nil connection + nil capability | limit `1...500`; carries positions only, never prior payload bytes |

Request tag and row `operationKindRaw` are a total one-to-one mapping except
that tags 1, 2, 5, 6, and 7 can be admitted under different capability names
for the two connection kinds. In those cases `capabilityRaw` must equal the
actual capability checked for that request; the codec never infers it. The
surrounding attribution table is exact: external cases require both
connection/capability; connection-targeted admin has a connection and only
grant/revoke-capability has a capability; global/admin-list/audit maintenance
has neither; and enroll gains a connection only after successful creation.

#### 4.4.3 Closed result cases and outcome compatibility

Result tags 1...15 are also stable `UInt16` values. Counts are metadata only; no row
title, query, type identifier, clipboard representation, display name,
credential, error text, or prior audit payload is copied into the blob.

| Result tag | `ResultSummaryV1` case | Compatible request / outcome |
|---:|---|---|
| 1 | `none` | every `.failed` or `.denied` record |
| 2 | `page(returnedCount: UInt16, hasMore: Bool)` | recent/search `.succeeded`; count `0...500` |
| 3 | `details(effectiveRepresentationCount: UInt16, revisionCount: UInt16)` | details `.succeeded`; counts only |
| 4 | `pastePayload(representationCount: UInt16)` | paste `.succeeded`; count only |
| 5 | `affectedItemIDs([UUID])` | pin/unpin/remove `.succeeded` or `.noOp`; at most 32, normally zero or one |
| 6 | `enrolled(connectionID: UUID)` | enroll `.succeeded` |
| 7 | `grantChanged(Bool)` | grant `.succeeded` (`true`) or `.noOp` (`false`) |
| 8 | `connectionRevoked(revokedGrantCount: UInt16)` | connection revoke `.succeeded` or `.noOp`; count `0...8` |
| 9 | `capabilityRevoked(Bool)` | capability revoke `.succeeded` (`true`) or `.noOp` (`false`) |
| 10 | `connections(returnedCount: UInt16)` | connections read `.succeeded`; count `0...500` |
| 11 | `grants(returnedCount: UInt16)` | grants read `.succeeded`; count `0...8` |
| 12 | `auditPage(returnedCount: UInt16, snapshotHead: UInt64)` | audit read `.succeeded`; count `0...500`; `snapshotHead` is exclusive and precedes this read's own audit append |
| 13 | `rebased(oldFloor: UInt64, newFloor: UInt64, discardedCount: UInt32)` | rebase `.succeeded`; `oldFloor <= newFloor <= nextAuditSequence` |
| 14 | `compacted(oldFloor: UInt64, newFloor: UInt64, discardedCount: UInt32, discardedPayloadBytes: UInt64)` | compact `.succeeded` or `.noOp`; checked counts, no discarded payload |
| 15 | `effectiveContent(representationCount: UInt16, totalBytes: UInt64)` | Effective-content read `.succeeded`; checked counts only |

`ExternalOutcome` compatibility is closed rather than repaired on decode:

- `.succeeded` requires the operation-specific success result, nil
  `failureKindRaw`, nil `denialReasonRaw`, and a non-nil `changePositionRaw`
  only for successful pin/unpin/remove commits;
- `.noOp` is allowed only for pin/unpin/remove, grant, connection revoke,
  capability revoke, and compact; it has nil failure/denial and nil
  `changePositionRaw` because no History Commit occurred;
- `.denied` requires `unauthorized`, `connectionRevoked`, or `requestDenied`.
  Only `requestDenied` carries a denial reason. Its result is always `none`;
- `.failed` requires a non-denial `ExternalFailureKindRaw`, result `none`, and
  nil `changePositionRaw`. `auditCompactedBefore` is valid only for an audit
  read whose `since < compactionFloor`;
- admin reads, ordinary external reads, enroll, rebase, and Effective-content
  read have no `.noOp` form. Empty successful reads use their typed zero-count
  success result, not `.noOp`.

The cross-field validator also requires a returned page count not to exceed
its request limit; successful pin/unpin/remove records name exactly their
requested item while their `.noOp` form names none; an audit-read
`snapshotHead` equals that read's own `auditSequence` (the head frozen before
its append); and rebase/compact `discardedCount` equals the checked
`newFloor - oldFloor` contiguous width. These relations are decoded from
literal fields, not inferred from a hash or repaired after read.

The decoder validates `formatVersion`, request/result tags, every enum raw,
checked bounds, UUID widths, row attribution, operation/request/result/outcome
compatibility, and the `affectedItemIDs` cap before allocation. A malformed
payload is `.persistence(.corruptStoredValue)`; a duplicate/missing/out-of-range
retained audit sequence is `.persistence(.invariantViolation)`. It never drops,
repairs, or reclassifies a row.

#### 4.4.4 Evidence ceiling and X.4 code ownership

This frozen table establishes that an X.4 encoder cannot omit or generically
collapse a callable operation, and that an audit reader can reject incompatible
stored combinations. It does **not** establish that the Gateway facade,
transport, App Intent adapter, or Local Automation credential path exists; X.5
and later leaves own those behaviors. Typed decoding and the contiguous
`[compactionFloor, nextAuditSequence)` check detect malformed payloads and
incoherent counter state only. There is no hash, chain, checksum, signature,
request digest, tamper-evidence, or non-repudiation claim.

The implementation DAG is deliberately shallow:

1. `OperationPayloadBlobV1.swift` owns the wire enums, encoder/decoder, and
   compatibility validator; no writer duplicates these switches.
2. `GatewayAuditStore.swift` owns mint+insert, bounded read, counter/byte
   accounting, retained-interval validation, compaction, and recovery rebase.
   Deleting it must leave no other code capable of inserting/deleting an
   `OperationRecordRow` or advancing audit counters.
3. `GatewayAdministration.swift` owns connection/grant current-state
   mutations and calls the audit store inside the same Authority transaction.
   Re-grant updates the existing `GrantRow`; it never inserts an event row.
4. `GatewayBootstrap.swift` replaces X.3's exact-zero audit rule with the audit
   store's full startup validation in the same change that enables the first
   writer.
5. `HistoryAuthority.swift` only composes these owners and supplies transaction,
   clock, and ID seams. Public enum/protocol changes and their symbol tests live
   in `HistoryCore`; no facade, transport, CLI, or credential module belongs to
   X.4.

**Recovery reachability ceiling.** Ordinary `SwiftDataHistory.open` remains
fail-closed when retained audit validation fails, so a facade obtained only
after ordinary open cannot recover that store. Landed X.4 unit-tests the
internal rebase transaction and permits `.adminForced` against an otherwise
healthy open store. Raw `AuditRebaseReason.corruptionDetected` and
its request/result codec are frozen now so a later recovery entry does not
rewrite V1 audit bytes, but X.4 adds no public recovery opener and therefore
does not claim that a store rejected during ordinary open is runtime-recoverable.
Making that case reachable requires a separately reviewed recovery-only opener
that can construct the sole Authority without publishing History/Gateway
facades; it must not be smuggled through the normal admin facade.

### 4.5 ExternalLimits (admission bounds)

A new V2 admission bound, `ExternalLimits` (a `HistoryLimits`-peer fixed value,
`internal` to `HistoryStorage`; evaluated and checked by `HistoryStorage`, not a
user knob, mirroring `06` §2, V2-01's `EnrichmentLimits`, V2-03's
`JournalLimits`):

| Bound | V2 value |
|---|---:|
| `displayName` UTF-8 bytes per connection | 256 |
| `maximumConnections` | 500; enrollment rejects the 501st before insert so the unpaginated public `connections()` result stays bounded |
| `maximumGrantRowsPerConnection` | 8; one row for each currently declared capability raw, while the connection-kind policy admits only its smaller subset |
| `maxAffectedItemsPerRecord` (audit `affectedItemIDs`) | 32 (external writes touch individual items; a `clear` is not exposed externally, so the bound is small) |
| `maximumAuditPayloadBlobBytes` | 16 KiB; a per-record codec envelope, checked before decode allocation and after encode |
| `maxAuditLogSize` (logical audit-byte trim trigger) | 64 MiB, tracked by `GatewayConfigRow.auditBytes` |
| `auditRecordAccountingOverheadBytes` | 128 bytes per retained row |
| `maxAuditAgeSeconds` (trim trigger) | 31,536,000 (365 days) |
| `compactionCadenceOps` (trim every N-th external op) | 100 |
| `maxAuditReadBatchSize` (per-call audit-log fetch limit) | 500 |
| External read `browse` limit (mirrors v1 page limit) | 1–500 (`06` §2) |
| `appIntentsRateLimitCapacity` | 30 tokens; initialized full for each process lifetime |
| `appIntentsRateLimitRefillNanosecondsPerToken` | `1_000_000_000`; refill capped at `appIntentsRateLimitCapacity` |

Rules (matching `06` §2 / V2-03 §4.5):

- All byte/count arithmetic is checked; overflow fails closed and never wraps
  (`06` §2, `02` §13).
- `maximumAuditPayloadBlobBytes` is independent of the 64 MiB whole-log
  trigger. The closed V1 cases contain at most 32 UUIDs plus fixed scalars and
  no clipboard content, so 16 KiB is a deliberate generous envelope rather
  than a content budget. Decode rejects a larger `Data` value before invoking
  the parser; encode checks the produced bytes before insert. The aggregate
  audit cap is never used as a substitute for this per-record admission check.
- `auditBytes` is a deterministic **logical admission counter**, not a claim
  about SQLite/SwiftData physical disk allocation. One retained row contributes
  exactly `UInt64(payloadBlob.count) + 128`; 128 is the frozen
  `ExternalLimits.auditRecordAccountingOverheadBytes` value and ensures an
  empty-content marker still consumes budget. Append checked-adds that exact
  amount; compaction/rebase checked-subtract the same amount for each deleted
  row. Startup recomputes the sum from retained rows and requires exact equality
  with `GatewayConfigRow.auditBytes`. This makes the 64 MiB trigger reproducible
  without guessing a platform-dependent database overhead, while explicitly
  not measuring WAL pages, indexes, allocator slack, or filesystem blocks.
- `maxAuditLogSize` / `maxAuditAgeSeconds` are alternative compaction triggers;
  the audit log is **compacted** (oldest records trimmed) only when a trigger
  fires, and **compaction is itself an audited admin operation** recorded as a
  final OperationRecord before the trim. In the same transaction, it deletes
  exactly one oldest prefix, advances `compactionFloor` to the first retained
  sequence (or `nextAuditSequence` if none remain), and leaves the retained
  rows contiguous. This is the only Authority operation that deletes audit
  rows; it is named, audited, bounded, and exposes the discarded boundary
  honestly rather than claiming a complete pre-floor log. `maxAuditLogSize` is
  a **trigger, not a hard invariant**: the
  compaction-marker append transiently increases `auditBytes` past the cap
  before the trim subtracts the deleted rows' contributions, and a compaction
  pass suppresses re-trigger evaluation until its trim completes (no immediate
  re-compaction loop). Recorded in `X-PERF-2`.
- `compactionCadenceOps` is an X.5 process-local dispatch cadence, not a
  durable counter and never `nextAuditSequence % 100` (that sequence also
  includes admin/read/maintenance records). X.4 owns the synchronous
  `compactIfNeeded` mechanism and its transaction proofs. The Gateway actor
  counts structurally admitted external requests. Before the Nth request may
  debit a rate token or enter any request-specific Authority operation, it must
  synchronously complete the throwing audit-compaction check. If maintenance
  fails, cadence remains due: that attempt consumes no token, executes and
  audits no request, and returns the maintenance failure. The identical retry
  runs maintenance again. Because maintenance is strictly pre-dispatch, its
  failure cannot replace an already committed request outcome. Rate denials and
  live-grant denials still participate in cadence once this pre-dispatch
  maintenance succeeds. Across actor reentrancy the Gateway retains exactly one
  shared in-flight compaction attempt: the creator is the Nth request and every
  concurrent follower awaits that attempt. Success opens a new interval and
  each follower then counts there; shared failure returns to all participants
  and preserves N−1, so no follower can silently consume or skip the due
  maintenance.
- The two App Intents rate scalars are X.5 additions to the internal
  `ExternalLimits`; their presence in this aggregate table does not claim they
  landed with X.4. The X.5 bucket itself is process-local actor state, not
  durable configuration and not a user knob. Gateway construction samples the
  injected uptime witness as `lastRefillUptimeNanoseconds` and starts with 30
  tokens. At each admitted typed request the actor samples its injected uptime
  witness, treats a sample earlier than the prior refill sample as elapsed `0`
  without moving the prior
  sample backward, adds one whole token per `1_000_000_000` elapsed nanoseconds,
  preserves any sub-second remainder by advancing the prior sample only by the
  credited whole-token interval, and caps the result at 30 before debiting one
  token. With zero tokens the call follows the audited rate-denial path. These
  constants and arithmetic are a deterministic correctness/admission contract;
  they are **not** a throughput, latency, energy, or abuse-resistance
  performance claim.
- Search audit carries byte counts, never query text (§4.4).
- These are admission bounds, not user runtime knobs; the UX (V2-07) reads audit
  via `GatewayAdminHistory` but cannot lower them below the v1/v2 floors.

### 4.6 GatewayConfigRow (singleton)

A new `@Model` singleton stores the durable gateway/audit configuration,
mirroring `EnrichmentConfigRow` (`V2-01` §3.5), `JournalConfigRow` (`V2-03`
§4.6), and the v1 `LastChangePositionRow` pattern (`05` §3.2). It does **not**
modify any v1 model:

```swift
@Model
internal final class GatewayConfigRow {
    @Attribute(.unique)
    var key: String                    // always "external-gateway"

    var appIntentsConnectionID: UUID   // the bootstrapped App Intents surface connection
                                       // (enrollKind == .appIntents); minted at first open
    var nextAuditSequence: UInt64      // the audit-log monotone counter (checked arithmetic;
                                       // overflow fails closed). Minted-in-the-closure to close the
                                       // read/write/audit atomicity gap (§5.4).
    var auditBytes: UInt64             // running audit payload-byte counter (§4.5 trim input);
                                       // logical += (blob.count + 128) per row;
                                       // not physical database allocation
                                       // per append; -= deleted rows' contributions on compaction.
    var compactionFloor: UInt64        // min surviving auditSequence after the last compaction pass;
                                       // a read below the floor returns the documented
                                       // "compacted-before" result, not a silent gap.
    var configSchemaVersion: UInt16    // 1 for V2-05
}
```

`nextAuditSequence` is the **authoritative** audit counter, minted inside the
commit closure (writes) or the read-audit transaction (reads). It is not derived
from `max(auditSequence) + 1` at read time, because two concurrent external
requests (e.g., a read and a write) would race on the max. Keeping the counter
on the singleton — incremented under the same transaction atomicity as the
record insert — makes each `auditSequence` unique and monotone by construction
(D34). **There is no audit off-switch (CRIT-4, decision: remove).** X2 ships
audit-on; no `auditEnabled` flag exists on `GatewayConfigRow`, no
`GatewayAdminHistory` method toggles audit, and no code path appends an
`OperationRecord` conditionally on a runtime flag. A security boundary whose
purpose is X2 (audit) cannot carry an unauditable off-switch — disabling audit
would itself be unaudited, defeating the graft. If a future product decision
requires an audit-off mode, it must be its own graft with a fresh architecture
review that specifies a compensating control (the toggle-to-off recorded as a
final `OperationRecord` before the off takes effect, the toggle-on recorded
after, an explicit admin method, and a proof gate); V2-05 takes none of that
and ships audit-unconditionally-on.

**Singleton + connection bootstrap at open (total order).** `SwiftDataHistory.open`
performs the V2-05 steps in a fixed total order after the v1 position singleton
(`05` §13 step 3) and every singleton/projection owned by the actual prior
shipped schema (currently immutable V2 retention state), and before any future
facade may be published:

1. fetch the `GatewayConfigRow` singleton (`key == "external-gateway"`); validate
   exactly-one or zero;
2. **if absent — distinguish migration from corruption (CRIT-M10):**
   - **Fresh/migration-compatible shape (the only allowed re-mint path):** the singleton is absent
     AND a bounded probe finds zero `ConnectionRow` / `GrantRow` /
     `OperationRecordRow` rows. This is the expected shape for a prior-version
     store that has never hosted a gateway, and X.3 permits reconstruction.
     In one bootstrap transaction, create exactly one config row with defaults (`nextAuditSequence == 1`,
     `auditBytes == 0`, `compactionFloor == 1`,
     `configSchemaVersion == 1`, `appIntentsConnectionID == UUID()` minted
     here) plus exactly one matching active App Intents `ConnectionRow` whose
     `displayNameRaw == "Siri / Shortcuts / Spotlight"`; create no grant or
     audit row. The minted `UUID()` is a **one-time durable identity** for the App
     Intents surface connection, not a per-operation ID — it is generated once
     at first `open` and then never changes for the store's lifetime, so it is
     not routed through the per-operation injected ID source (`01` §4); this
     mirrors `V2-03`'s `storeInstance` `UUID()` (`V2-03` §4.6). The
     test-determinism consequence is noted: fixture tests that assert a specific
     connectionID must inject the value via a test seam (a `HistoryStorage`-
     internal connectionID injector wired at `open`), not rely on `UUID()`
     determinism (`X-COMPILE-1` covers the seam).
     **Causal ceiling:** without a durable provenance fact, this shape is
     observationally identical to a future V3 store from which the config and
     all dependent Gateway rows were deleted. X.3 therefore claims only that it
     rejects the distinguishable shape “config absent while any dependent row
     survives”; it cannot detect complete bootstrap deletion. Do not add a
     marker, checksum, hash, or speculative recovery state to overclaim that
     distinction.
   - **Corruption (fail-closed, do NOT re-mint):** the singleton is absent AND
     the probe finds ANY `ConnectionRow` / `GrantRow` / `OperationRecordRow`
     row. Re-minting would orphan those rows (a `GrantRow` /
     `OperationRecordRow` carries the OLD `appIntentsConnectionID`), silently
     breaking grant continuity and audit provenance. `open` throws
     `.persistence(.invariantViolation)` (`05` §16) and refuses to publish the
     facade; recovery requires a separately approved recovery-only path after
     explicit investigation, never a silent re-mint. The detection predicate is
     "singleton absent ∧ ∃ row in {ConnectionRow, GrantRow,
     OperationRecordRow}".
3. **if present:** validate `configSchemaVersion == 1` and field ranges (fail-
   closed, mirroring `V2-03` §4.6); read `appIntentsConnectionID` (never
   re-minted on an existing row);
4. **for an existing config**, require exactly one `ConnectionRow` with `id ==
   appIntentsConnectionID`, `enrollKindRaw == appIntents`, and
   `displayNameRaw == "Siri / Shortcuts / Spotlight"`. Its lifecycle must be
   coherent: active means `revokedAt == nil`; revoked means a finite,
   non-nil `revokedAt >= enrolledAt`. Both timestamps must be finite. Missing,
   duplicate, or mismatched state is `.persistence(.invariantViolation)`;
   open does not silently reactivate, recreate, or rewrite it. Only step 2's
   absent-config bootstrap transaction may create config+connection. The
   zero-grant/zero-audit requirement applies only to that first X.3 bootstrap;
   after X.4, existing stores instead run bounded current-state and retained-
   audit validation;
5. validate `compactionFloor <= nextAuditSequence`, checked counters, and the
   retained audit interval: ordered rows must occupy every sequence in
   `[compactionFloor, nextAuditSequence)` exactly once. X.3 bootstraps zero
   audit rows, so both values are `1`; later X.4 startup validation applies the
   same rule after appends/compaction. A gap, duplicate, or out-of-range row is
   `.persistence(.invariantViolation)` (§5.6). This is sequence/coherence
   validation, not tamper evidence;
6. for an existing X.4 store, validate bounded connection/grant current state,
   decode every retained audit row in sequence-keyed batches, and require exact
   logical-byte accounting. For a first X.3 bootstrap this reduces to one
   active App Intents connection with zero grants/audit. X.3 publishes no
   facade. After this validation succeeds, `open` carries that exact durable
   `appIntentsConnectionID` forward as an immutable `ExternalConnectionID` and
   constructs the X.5 `ExternalGateway` actor; it never calls the ID source
   again, re-mints an identity, or asks a later factory to choose a connection.
   X.5 publishes no facade. X.6 may publish the App Intents facade only after
   the same actor's granted positive paths are real, baking that startup-
   validated ID into the facade.

This step applies to the `.memory` store path too.

## 5. External read/write/admin paths (data flow)

### 5.1 External write path (`manage` capability)

A `manage` request is a capability-gated, audit-annotated extension of the v1
commit path. It reuses the v1 planner/transaction **unchanged** and appends two
derived rows (HCR by V2-03, OperationRecord by V2-05) in the same closure:

```text
ExternalGateway.perform(.remove(itemID), as: connID)   [actor]
  1. VALIDATE (D35): itemID well-formed; bounds ok.
  2. Authority.commitExternal(request: .remove(itemID), connection: connID,
                              requestedAt:)   [single writer; authoritative gate]
       create operation-local context
       -> load action-specific facts (05 §7.3 remove: target scalar summary)
       -> call the v1 pure planner planRemove (UNCHANGED; the Domain is unaware
          the request is external)
       -> if the planner THROWS (failed-WRITE path, mirroring §5.2's failed-READ
          path): planRemove returns .notFound for a .remove on an absent target;
          planUnpin returns .notFound / placePinned returns
          .invalidPinnedPlacement(.targetMissing) for a .pin/.unpin on an absent
          target (v1 WS16). Catch inside the same non-suspending span; append a
          failed-write OperationRecord (outcome .failed) with the matching
          failureKind in a separate small transaction; only after that append
          commits, rethrow. If append fails, throw persistence failure. A planner
          .notFound maps to ExternalFailure.notFound(HistoryItemID) / failureKind
          .notFound (ExternalFailureKindRaw.notFound = 4) — NOT .history —
          because the failure originates at planning (absent target), not inside
          a v1 history projection; the planner's other HistoryFailures wrap as
          ExternalFailure.history(...) / failureKind .history as usual. The
          write commits NO history mutation. (This is the write-side analogue of
          §5.2's failed-read publication barrier; succeeded writes keep audit
          in-commit, while this no-mutation branch awaits its separate append.)
       -> if .unchanged: commit NO history mutation; audit an OperationRecord
          with outcome .noOp (CRIT-M7) in a separate small transaction; return
          `ExternalResponse.unchanged` only after that append succeeds (no
          History Commit, no ChangePosition advance).
       -> derive/stamp a StampedCommitPlan (05 §9) + the V2-03 hcrAppend +
         the V2-05 auditAppend (OperationRecordPayload, §5.4)
       -> prevalidate index delta, receipt, hcrAppend, AND auditAppend
       -> execute ONE ModelContext.transaction (05 §10):
            fetch ConnectionRow.status + the required live GrantRow (the
            authoritative gate, D33); if revoked/ungranted: throw from
            inside the closure (commits nothing); audit-as-denied in a
            separate small follow-up transaction
            for mutation in plan.mutations { try apply(mutation, in: context) }   // v1
            try validateFinalPinOrder(in: context)                                 // v1
            try appendHistoryChangeRow(plan.hcrAppend, in: context)                // V2-03 (always-on)
            try trimHistoryChangePrefixForHardBoundsAndDueAge(                     // X-HCR (§0)
                  newPosition: plan.position, in: context)
            try appendOperationRecord(plan.auditAppend, in: context)               // V2-05 (external path only)
            meta.rawValue = plan.position.rawValue                                 // v1, written last
       -> apply nonthrowing Signature Index delta        (05 §11 step 1, unchanged)
       -> synchronously yield HistoryInvalidation         (05 §11 step 2, unchanged)
       -> construct and return the ExternalResponse      (05 §11 step 3 analogue)
```

`commitExternal` does **not** duplicate the v1 commit kernel. It **invokes the
single v1 commit path** (fact-load → plan → stamp → transaction → index delta →
invalidation), parameterized by the manage-subset `ExternalRequest` mapped to
its corresponding v1 `HistoryAction`, with `auditAppend` threaded via
`StampedCommitPlan` exactly as V2-03 threads `hcrAppend`. There is one commit
code path with an optional audit payload — the V2-03 one-path discipline. The
v1 app-internal `commitRemove`/`commitPinnedPlacement`/`commitUnpin` and the
external `commitExternal` share the same transaction machinery; they differ
only in the entry mapping (HistoryAction vs ExternalRequest) and whether
`auditAppend` is set.

Every `05` §10 transaction rule is preserved: **no `await`** in the closure or
between fact load and closure completion; **closure failure commits nothing** —
neither the item mutation, nor the singleton position, nor the HCR row, nor the
OperationRecord (D34 holds: a crash mid-closure leaves no partial audit entry,
because the OperationRecord and the singleton position share the same atomic
save boundary); **the singleton position is written last**; **closure success is
the save boundary** (no extra `save()`, `05` §10).

The HCR append (V2-03) and the OperationRecord append (V2-05) are independent
derived rows that happen to share the closure: the HCR records the *history
semantic event* (e.g., `.remove`) for reconnect/cache; the OperationRecord
records the *external provenance* (connectionID, capability, requestedAt) for
audit. The OperationRecord's `changePositionRaw` == the commit's `ChangePosition`
== the HCR's `sequence` (D34 cross-reference, by V2-03's D25). The v1 commit
path for an **app-internal** `perform(.remove)` is **behaviorally unchanged**
(`auditAppend == nil` on the app-internal path; the v1 `perform` switch is
unchanged and `StampedCommitPlan` gains an additive optional `auditAppend`
field, `nil` on every v1/app-internal path per §5.4/§7.4 — the internal struct
is extended by addition (V2-03 §5.2 pattern); see §6.4 for how the external
path threads `auditAppend`).

### 5.2 External read path (`read` capability)

A `read` request is a capability-gated, audited delegation to the v1 read
projection (`05` §14). It mutates no history state and produces no HCR row:

```text
ExternalGateway.read(.search(text, mode, limit), as: connID)   [actor]
  1. VALIDATE (D35): text/limit within v1 HistoryLimits bounds; reject as
       requestDenied(.invalidInput) before any read, token debit, or audit append;
       malformed pre-admission has no truthful `RequestSummaryV1` (§3.1).
  2. Authority.performExternalRead(.search(...), connection: connID,
       requestedAt:)   [single writer, read context; authoritative gate]
       Fetch ConnectionRow and only the required live GrantRow, plus the
       `.manage` row when a browse request applies manage-implies-browse. If
       inactive/ungranted, audit-as-denied before throwing.
       The .search read path runs as TWO non-suspending Authority intervals
       bracketing the off-actor SearchWorker await (SearchWorker is a separate
       actor — 01 §6 / 04 §7 / 05 §14.2 — so it CANNOT be invoked inside a
       non-suspending Authority interval; 05 §5/§10 forbid any `await` while a
       commit context, fetched row, or complete facts are live). This
       deliberately SPLITS snapshot-capture from off-actor evaluation, exactly as
       v1 browse does — the request is a v1 HistoryBrowseRequest, no new read
       path:
       (a) interval 1 (authoritative gate + snapshot capture): fetch
           ConnectionRow.status + required live GrantRow row(s); if revoked/ungranted there,
           append the denial audit first and throw only after it commits. If
           that append fails, throw persistence failure. Else
           capture SearchCorpusSnapshot (05 §14.2, a Sendable value snapshot).
           Interval ends; the snapshot is a Sendable value carried across the
           suspension.
       (b) SearchWorker evaluates exact/fuzzy/regexp over the Sendable snapshot
           OFF-ACTOR (the cross-actor `await` lives here, BETWEEN the two
           non-suspending intervals — never inside either; a non-suspending
           Authority closure cannot host it).
       (c) interval 2 (closing audit closure): build HistoryPage from the
           SearchWorker result; AUDIT a read OperationRecord here — reading
           and incrementing `nextAuditSequence` inside this closure. D36
           continuity for reads follows from the same transaction updating the
           singleton counter and inserting the row; no concurrent append can
           mint the same sequence inside the serialized Authority interval.
       Accept the read-side grant-check-vs-evaluation TOCTOU: a revocation
       landing between interval 1 and interval 2 takes effect on the NEXT
       request, not this one (the authoritative check already passed in
       interval 1). This is the acceptable read TOCTOU, distinct from the write
       save-boundary check that closes the write TOCTOU inside one closure.
       For .recent/.details/.pastePayload reads (no off-actor SearchWorker
       evaluation) the grant check, evaluation, and audit genuinely fit ONE
       non-suspending Authority interval.
  4. Read audit outcome .succeeded / .failed / .denied; resultSummary
       pageCount(rows.count) on success; requestedAt / committedAt from the
       Storage clock (§5.5). (Reads advance nextAuditSequence but NOT
       ChangePosition.) The read audit is a SEPARATE transaction from any write
       — there is no history mutation to be atomic with. It is nevertheless a
       fail-closed publication barrier: append must commit before step 5.
  5. Only after the audit commit succeeds, return the already-built immutable
       HistoryPage. If audit append fails, throw persistence failure and do not
       return the page or any content-bearing DTO.
```

**Failed-read audit path (D34).** If `performExternalRead` throws (e.g.,
`HistoryFailure.notFound` for a `details`/`pastePayload` on a removed item, or
`.invalidInput(.invalidSearchTerm)` from the SearchWorker),
`performExternalRead` **does not** skip the audit: it catches the throw,
audits a read `OperationRecord` with `outcome == .failed` and the matching
`failureKind`/`denialReason` (§4.3/§4.4) **inside its own read-audit
closure**, then rethrows the `ExternalFailure`. There is no no-op read: v1
reads either return a value (audited `.succeeded`, `pageCount(0)` for an
empty page) or throw (`05` §14.3 — `details`/`pastePayload` throw
`.notFound` for an absent target; `03b` §9 DTOs are non-optional),
audited `.failed`. The original failure is released only after that audit
append commits. If audit append fails, the caller receives the persistence
failure instead; the underlying DTO/content or failure is not published. A
process crash before the append commits likewise cannot follow a successful
method return, because return is sequenced after the commit.

An admitted search cancellation follows this same failed-read publication
barrier. A `CancellationError` raised after interval 1's authoritative gate is
mapped to `ExternalFailure.temporarilyUnavailable(.cancelled)`; `.cancelled`
has stable `ExternalTransientReason` raw value 4. Before that failure is
released, interval 2 must commit exactly one `outcome == .failed`
OperationRecord with `failureKindRaw == .temporarilyUnavailable` (raw 6) and
no denial reason. If the mandatory audit append fails, its persistence failure
replaces the cancellation; the caller never receives an unaudited cancellation.

**Input-validation classification (D35).** The conceptual class "invalid
input" is caught at two layers: bounds/shape at pre-admission (D35) and
structural safety (e.g., regexp admission — nested quantifiers,
backreferences, per `03b` §8) inside the off-actor SearchWorker. The first has
no truthful admitted request summary and therefore consumes no token and writes
no audit (§3.1). The second has already entered the admitted search path. For
that admitted failure, a SearchWorker-surfaced
`HistoryFailure.invalidInput(...)` is **re-classified to
`failureKind == .requestDenied` (`denialReason == .invalidInput`) for audit**,
NOT `.history`, even though it is thrown to the caller wrapped
as `ExternalFailure.history(HistoryFailure.invalidInput(...))`. (Other
SearchWorker `HistoryFailure`s — e.g., `.notFound` — keep their natural
`failureKind`.) This does not fabricate an audit for malformed pre-admission.

Reads are audited (D34) because clipboard history is sensitive: a connection
reading items is a privacy-relevant event, and the audit gives the user
transparency (V2-07 surfaces "Siri searched your history N times"). The audit
captures the **request shape + result count**, never the query text (§4.4) and
never the returned item content (the audit proves *a search happened returning N
rows*, not *what was searched or returned*). This bounds audit size and avoids
amplifying sensitive content into a second durable store. A `details` /
`pastePayload` read records the requested `HistoryItemID` and whether a payload
was returned (not the payload bytes).

### 5.3 Admin path (in-app UX only, `GatewayAdminHistory`)

Admin operations mutate connections/grants and are themselves audited. They are
**not** `HistoryAction` cases (§7.2) and advance **no** `ChangePosition`:

```text
GatewayAdminHistory.enrollConnection(kind: .appIntents, displayName: "Siri")
  -> Authority.enrollConnection(...): create ConnectionRow (status active); grant
       no capability by default; append an admin OperationRecord (operationKind
       .adminEnroll, outcome succeeded). Return ExternalConnectionID.
GatewayAdminHistory.grantCapability(connectionID:, .manage)
  -> Authority.grantCapability(...): insert the pair row if absent, otherwise
       update that same current-state GrantRow (`grantedAt` fresh,
       `revokedAt = nil`); append admin OperationRecord (.adminGrant) so event
       history is not inferred from the current-state row. (The App Intents surface's
       connectionID is the bootstrapped one; granting it .manage enables external
       writes.)
GatewayAdminHistory.revokeConnection(connectionID:)
  -> Authority.revokeConnection(...): flip ConnectionRow.status revoked; set
       revokedAt on all live GrantRows; append admin OperationRecord
       (.adminRevoke). The next external request's grant load sees the revocation.
GatewayAdminHistory.auditLog(since auditSequence:) -> [OperationRecordDTO]
  -> Authority read: bounded fetch + typed decode + contiguous retained-interval
       validation (D36); Sendable DTOs only.
```

Admin operations are available **only** via `GatewayAdminHistory` (in-app UX on
the main actor, V2-07), never via `ExternalHistory` (an App Intent must not be
able to grant itself a capability). `GatewayAdminHistory` is **not** registered
in `AppDependencyManager` (§6.5) — only the connection-scoped `ExternalHistory`
facade is. **Admin audit transaction boundary (D34):** each admin
`OperationRecord` is committed **atomically with its admin-state mutation** in
the same transaction (the `ConnectionRow`/`GrantRow` insert or the status/
`revokedAt` flip, or the rebase/compaction marker + trim) — closure failure
commits neither. Admin ops advance no `ChangePosition` and yield no
`HistoryInvalidation` (they are not History Commits), but they DO mutate gateway
state, and their audit record shares that mutation's save boundary. Admin reads
and no-op admin attempts use the separate mandatory append barrier and return or
throw only after it commits.

### 5.4 Audit append atomicity and `StampedCommitPlan`

The audit append for a write runs **inside** the commit transaction (§5.1). To
thread it without modifying the v1 `StampedCommitPlan`/`perform` switch, V2-05
uses the same additive-field technique V2-03 used for `hcrAppend`, generalized
to an optional payload that is `nil` for every app-internal path:

```swift
internal struct StampedCommitPlan {
    let position: ChangePosition
    let mutations: [StampedMutation]
    let receiptOutcome: HistoryCommitOutcome
    let indexDelta: SignatureIndexDelta
    let hcrAppend: HistoryChangeRecordPayload        // V2-03 (always-on, non-optional, V2-03 §4.6/§5.2)
    let auditAppend: OperationRecordPayload?         // V2-05 (nil for every app-internal path)
}
```

`auditAppend` is `nil` for every v1 app-internal `perform(...)` and for every
V2-01/V2-02/V2-04 commit (enrichment persist, retention, materialization) — none
of those is an external request. It is set **only** by the external commit path
(`commitExternal`, §5.1). This is an additive optional field on an internal
struct, exactly the pattern V2-03 §5.2 established for `hcrAppend` — an
additive, behavior-preserving extension under the V2 self-review gate
(`V2-00` §8); the v1 public `ClipboardHistory.perform` interface and its
exhaustive switch (`05` §8) are unchanged. (`hcrAppend` is non-optional because
V2-03 ships the HCR always-on, `V2-03` §4.6; V2-05 does not alter that.)

```swift
internal struct OperationRecordPayload: Sendable {
    let connectionID: ExternalConnectionID?           // nil for global rebase/compact
    let capability: ExternalCapability?               // nil for admin without a grant capability
    let operationKind: ExternalOperationKind
    let outcome: ExternalOutcome
    let failureKind: ExternalFailureKind?             // nil on success
    let denialReason: ExternalDenialReason?           // nil unless failureKind == .requestDenied;
                                                       // carried to the append closure so it is
                                                       // persisted to denialReasonRaw (§4.3)
    let requestSummary: RequestSummaryV1
    let resultSummary: ResultSummaryV1
    let requestedAt: Date
    let committedAt: Date                             // the commit timestamp (== hcrAppend.createdAt,
                                                       // captured at stamping under the Storage clock)
    let changePosition: ChangePosition?               // succeeded writes only; nil otherwise
}
```

The payload is constructed during the same Authority-serialized
fact-load → plan → stamp span as `StampedCommitPlan`. The transaction then
reads `GatewayConfigRow.nextAuditSequence` as N, inserts the row with sequence
N, and writes N+1 using checked arithmetic. Counter advance and row insertion
share one save boundary, so a successful transaction cannot expose a consumed
sequence without its row. noOp/denied/failed-write and read branches perform the
same mint+insert pair in their own small Authority transaction. This establishes
monotone contiguous sequence state for committed audit rows without hashing the
payload or deriving identity from its bytes.

**Why same-transaction (not a separate audit path).** Decision (A) in the brief:
the OperationRecord is committed atomically with the history mutation in the
**same** `ModelContext.transaction`, like V2-03's HCR. Justification: (1)
single-writer preserved — no second writer for audit, no second context creator
(D32); (2) crash-consistency — either the external write AND its audit record
commit, or neither (D34; the same D25-style argument V2-03 makes for the HCR);
(3) it matches V2-03's proven pattern, so V2-05 inherits V2-03's
transaction-atomicity evidence (`V2-facts.md` cycle-3 addendum — `ModelContext.transaction(block:)` atomic save) rather than introducing
a new platform dependency. A separate audit path (decision B) would either
weaken crash-consistency (a crash between the write and the audit loses the
audit) or require a compensating mechanism the v1 architecture does not have.
For **reads** (§5.2) there is no history mutation to share a transaction with,
so the Authority first builds an immutable result/failure, then runs a
**separate small audit transaction**. That transaction is still serialized by
the sole Authority; `nextAuditSequence` is minted with the row insert inside
one non-suspending closure. It is also a mandatory publication barrier: no DTO,
clipboard bytes, or typed underlying read failure crosses the method boundary
until the audit commit succeeds. If it fails, the call fails closed with the
audit persistence failure and releases no result. A crash may therefore leave
a committed audit record whose result was never observed (crash after audit,
before return), but cannot produce a successfully returned sensitive read with
no committed record. This is the exact support ceiling; it does not make the
read snapshot and later audit one database snapshot.

**`committedAt` semantics (unified).** `committedAt` is non-optional on both
`OperationRecordRow` (§4.3) and `OperationRecordPayload`, and means uniformly
"the Storage-clock timestamp at which this OperationRecord became durable." For
writes it equals the commit timestamp (== `hcrAppend.createdAt`); for reads,
admin ops, denied, noOp, and failed records it is the read-audit / admin /
denial transaction's Storage-clock timestamp. No timestamp participates in an
audit hash because this design has no audit hash.

### 5.5 Storage clock seam (reused, not added)

`requestedAt` / `committedAt` / `enrolledAt` / `grantedAt` / `revokedAt` reuse
the **same** Storage-side clock seam V2-02 introduced (`.setRetentionPolicies`
R1) and V2-03 reused (HCR `createdAt`): a `Sendable` clock witness (`() -> Date`
closure or `StorageClock` protocol) injected into `HistoryAuthority` at `open`,
defaulting to `Date.now` in production and injectable in tests (`V2-03` §6.4).
V2-05 adds **no** new injection point (`X-COMPILE-1` stays free of a new escape
hatch). The same witness is handed to the `ExternalGateway` actor at its
construction inside `open` (one seam, one witness - no new injection
point) so gateway-entry `requestedAt` capture and §3.1 step-0 denial
audits read the Storage clock.
Wall-clock is not monotonic; a backwards move under-compresses audit
(safe direction, mirroring `V2-03` §6.4's C3-n4). The Domain mints no `Date()`
(`02` §1).

### 5.6 Crash consistency, audit rebase, and compaction

- **Append-only + atomic append (D34/D36).** The OperationRecord is appended in
  the commit closure (writes) or the read-audit transaction (reads). A crash
  mid-closure commits nothing (the write, the HCR, and the OperationRecord share
  the save boundary). A read result is held until its separate audit commit;
  a crash before that commit cannot follow a successful return, while a crash
  after it may leave a record for a result the caller never observed. A committed append advances
  `nextAuditSequence` only in the transaction that inserts that sequence, so
  the next committed append remains contiguous.
- **Sequence validation on open + recovery rebase.** Step 5 of the open
  sequence (§4.6) validates that retained rows occupy exactly
  `[compactionFloor, nextAuditSequence)`. Rows below `compactionFloor` are
  explicitly unavailable; a request below it returns
  `.auditCompactedBefore`. A gap, duplicate, or out-of-range retained row is
  `.persistence(.invariantViolation)` and normal `open` refuses to publish a
  facade. Landed X.4 owns the rebase transaction and the healthy-store
  `.adminForced` path, but adds no opener capable of reaching a store that
  normal `open` rejected. A separately reviewed future recovery-only opener may
  invoke that transaction to quarantine/discard an explicitly identified
  prefix, advance (never decrease) `compactionFloor`, and append a global
  rebase marker whose optional `connectionID`/`capability` are nil. It must not
  reset `nextAuditSequence`, use a `generation` scalar, read clipboard content,
  execute History mutations, or claim to prove what happened before the new
  floor.
- **Compaction.** §4.5. Compaction is the single explicit exception to
  append-only: it appends a global content-free compaction marker, trims exactly
  one oldest prefix, advances `compactionFloor`, and preserves a contiguous
  retained suffix — all in one Authority transaction. A read below
  `compactionFloor` returns
  a typed `ExternalFailure` (`.auditCompactedBefore(floor: compactionFloor)`,
  §7.3), never a silent gap (mirroring V2-03's `compactionFloor` discipline,
  `V2-03` §4.6).

### 5.7 Why this preserves v1

- **Single write authority (`00` §3.3).** `ExternalGateway` creates no context;
  every write delegates to `HistoryAuthority`. The audit append runs inside the
  Authority's existing transaction (D32).
- **No model leakage (`00` §3.4, `01` §6).** Only `Sendable` HistoryCore DTOs
  cross the gateway boundary. `@Model`/`ModelContext`/`PersistentIdentifier`
  remain internal to `HistoryStorage`. The new `@Model`s are internal to
  `HistoryStorage`.
- **Closed `HistoryAction` / `ClipboardHistory` seam.** The v1 `perform` switch
  (`05` §8) is unchanged; external/admin operations live on distinct protocols
  (§7). `StampedCommitPlan.auditAppend` is an additive optional field that is
  `nil` on every v1 path.
- **D1–D19.** The external manage path issues the **same v1 `HistoryAction`**
  (`.remove`/`.pin`/`.unpin`) the app issues; the v1 planner, stamping, OCC,
  dedup, retention, and pin-order invariants apply unchanged. The Domain is
  unaware the request is external (D16, D17, D18 preserved).
- **Forbidden dependencies (`01` §8).** No new `@unchecked Sendable`; no
  `nonisolated(unsafe)`; the `.shared` spelling of `AppDependencyManager.shared`
  is the system DI seam, justified + carve-out in §6.5 (no app-owned
  authoritative locator; no second writer; no bypass of composition-root
  construction).

## 6. Code model

### 6.1 Module and target placement (no new SwiftPM target)

V2-05 introduces **no new SwiftPM target**. The brief's "`HistoryGateway`
module" is realized as three logical concerns placed on existing targets, to
preserve the v1 single-SwiftData-owner rule (`00` §3.4; the quoted import rule
is `01` §8 / `06` §6: "`import SwiftData` appears only in `HistoryStorage`"):

- **Public surface** (`ExternalHistory`, `GatewayAdminHistory` protocols; the
  DTOs `ExternalConnectionID`, `ExternalCapability`, `ConnectionEnrollKind`,
  `ConnectionStatus`, `ExternalRequest`, `ExternalRead`, `ExternalResponse`,
  `ExternalReadResult`, `ExternalOperationKind`, `ExternalOutcome`,
  `ExternalFailure`, `ExternalDenialReason`, `ExternalTransientReason`,
  `ExternalFailureKindRaw`, `AuditRebaseReason`, `OperationRecordDTO`,
  `ConnectionDTO`, `GrantDTO`) is added to `HistoryCore` as a clearly V2-scoped
  section. These types are Foundation-only (`HistoryCore`'s invariant, `01` §8)
  and reuse v1 vocabulary (`HistoryItemID`, `ContentVersion`, `ChangePosition`,
  `HistoryPage`, `HistoryDetails`, `PastePayload`) verbatim. New names do not
  collide with v1 names or with V2-01..V2-04 names (`V2-00` §9). This is the
  "distinct concern protocol" pattern V2-01 (`EnrichmentHistory`) and V2-03
  (`ReconnectHistory`) established. One additional public type —
  `ExternalHistoryFacade` — plus one public accessor —
  `SwiftDataHistory.makeAppIntentsHistoryFacade()` — are exposed on
  `HistoryStorage` (CRIT-M3) because the facade is the single `@Dependency`
  seam resolved by `ClipyApp`'s `AppIntent`s, and `ClipyApp` is the separate
  Xcode app target **outside** the History Swift package (`01` §2); `package`
  access is invisible there, so both the type and the accessor must be `public`.
  This mirrors how v1 exposes `SwiftDataHistory.open(...)` to `ClipyApp`
  (`01` §2: `public` is reserved for the concrete `HistoryStorage` constructor
  needed by `ClipyApp`). The existing §9 symbol snapshot remains a
  `HistoryCore`-only gate. It changes intentionally at X.6 for
  `ExternalTransientReason.insufficientDiskSpace` and `.cancelled`; it
  cannot represent a type declared by `HistoryStorage`.
  X.6 proves the facade and accessor with an out-of-package
  `ClipyIntegrationTests` compile/behavior test that imports `HistoryStorage`
  normally; package-level tests alone cannot prove `public` rather than
  `package` access. This proof belongs to `X-COMPILE-2` (Record 3).
  X.7 adds one narrow `HistoryCore` identity reconstruction seam:
  `HistoryItemID.init?(uuidString:)` accepts only the canonical UUID spelling
  already exported by `description`/`rawValue`. It reconstructs lookup identity
  after App Intents parameter serialization; it does not mint a stored item,
  create a grant, or confer authority. The raw-UUID initializer remains
  package-only, and the Gateway still returns the authoritative not-found or
  authorization result. This also avoids an incomplete retained-history scan
  disguised as an `EntityQuery`.
- **Implementation** (`ExternalGateway`, `CredentialStore`, the `@Model`s,
  codecs, and the `commitExternal` / `performExternalRead` / targeted access
  check / audit-append methods on
  `HistoryAuthority`) is added to `HistoryStorage`. `HistoryStorage` does
  **not** import `AppIntents` — the gateway exposes a Foundation-only
  `ExternalHistory` protocol, and the `AppIntent` conformances that consume it
  live in `ClipyApp` (R-m2 / Lens B nit). Audit adds no hashing or cryptography
  import. The Batch 18 F1 server-custody leaf adds `import Security` only inside
  `HistoryStorage` for `SecRandomCopyBytes` and app-private Data Protection
  Keychain `SecItem*`; it adds no Security edge to audit, Core, Domain, UI, or
  adapters. Ordinary injected-operation tests do not close `X-PLATFORM-3`,
  which still owns supported signed-artifact compile/runtime evidence.
- **App Intents surface** (the `AppIntent` conformances — e.g.,
  `SearchHistoryIntent`, `GetItemDetailsIntent`, `PasteItemIntent`,
  `PinItemIntent`, `UnpinItemIntent`, `RemoveItemIntent` — and
  `ClipboardShortcuts: AppShortcutsProvider`) is added to `ClipyApp`, which
  gains `import AppIntents`. `ClipyApp` obtains the `ExternalGateway`-backed
  connection-scoped `ExternalHistory` facade from `SwiftDataHistory`. At the
  earliest launch entry it registers one asynchronous provider into
  `AppDependencyManager.shared`; the provider and UI await the same single
  composition-open work (§6.5). `ClipyApp` imports
  `HistoryCore` (for the DTOs) `HistoryStorage` (for `SwiftDataHistory` and
  `makeAppIntentsHistoryFacade`); it does **not** touch `@Model` types (they are
  `internal` to `HistoryStorage`). Search output uses an output-only
  `TransientAppEntity`. The five item-target intents take a canonical UUID
  string and call `HistoryItemID(uuidString:)`; there is no `EntityQuery`,
  because resolving through a capped recent-page scan would be incomplete and
  would also require browse permission for manage-only operations.
- X.4 gives `SwiftDataHistory` its landed `GatewayAdminHistory` conformance.
  `SwiftDataHistory` deliberately does **not** conform to `ExternalHistory`:
  that protocol has no connection argument, so direct conformance would create
  an unbound second external entry. X.6 exposes only the connection-bound
  `ExternalHistoryFacade`. The `ExternalGateway` actor is a stored field of
  `SwiftDataHistory` (extending its actor field set, `05` §2). Because it is an
  `actor` type, `SwiftDataHistory: Sendable` remains derived without
  `@unchecked Sendable` (`01` §6) — a private stored-field addition under the V2
  self-review gate (`V2-00` §8).

Incremental order is explicit: X.4 publishes only the thin
`GatewayAdminHistory` conformance after bootstrap/audit/admin behavior is real;
it adds no actor field. X.5 constructs the real stored `ExternalGateway` actor
and proves authoritative denial internally, but publishes no external facade or
factory. X.6 first completes the same actor's granted positive paths, then lands
the connection-bound `ExternalHistoryFacade` and
`makeAppIntentsHistoryFacade()` together; an authorized grant can therefore
never reach an unavailable or denial-only public placeholder.

A new SwiftPM target would either have to import SwiftData (creating a second
SwiftData-owning target, violating `00` §3.4 / `01` §4) or be a pure facade
delegating to `HistoryStorage` (in which case it is logically part of
`HistoryStorage`'s surface with no independence). The chosen placement avoids
both and is consistent with V2-01..V2-04.

### 6.2 ExternalGateway (actor)

```swift
internal actor ExternalGateway {
    private let authority: HistoryAuthority   // Sendable actor ref; all context
                                              // work delegated (preserves 05 §5
                                              // single-context-creator). The
                                              // gateway NEVER creates a
                                              // ModelContext (D32).

    // Capability gate + audit coordination; holds no @Model, no ModelContext.
    // Validation (D35) runs here; the grant decision (D33) and every durable
    // op run inside the Authority.
    func perform(_ request: ExternalRequest, as connection: ExternalConnectionID
    ) async throws -> ExternalResponse

    func read(_ request: ExternalRead, as connection: ExternalConnectionID
    ) async throws -> ExternalReadResult
}
```

The gateway is a new internal `actor` field on `SwiftDataHistory`, so
`SwiftDataHistory: Sendable` is derived. It holds only `Sendable` values. It
performs validation off-Authority (bounds, ID shape) and delegates the grant
load + dispatch + audit to the Authority inside one non-suspending interval per
phase, mirroring V2-01's `EnrichmentScheduler` (coordinates, never creates a
context, `V2-01` §6.3) and V2-03's `ChangeJournal` reader (delegates every
durable read to the Authority, `V2-03` §6.2). The Storage-owned
`ExternalHistoryFacade` remains the thin public `Sendable` value holding the
gateway ref + baked-in `connectionID`. `ClipyApp` wraps that exact value in one
internal `Sendable` `AppIntentHistoryIngress` solely to order a positive
external remove before the already-existing panel surface purge (§6.5).

### 6.3 Direct authoritative targeted access (no forwarding actor)

After pure descriptor/kind admission, token debit, and scalar input validation,
`ExternalGateway` calls `HistoryAuthority.commitExternal` or
`HistoryAuthority.performExternalRead` directly. There is no separate
forwarding actor, grant-lookup interval, or cached grant decision. The
Authority fetches exactly one `ConnectionRow` and the single required live
`GrantRow`; a browse request may additionally target the `.manage` row to
implement the frozen manage-implies-browse rule. The targeted decision is made
inside the dispatch interval that owns evaluation/audit and, for writes, the
save-boundary transaction. `ExternalGateway` creates no `ModelContext`.

### 6.4 Authority methods (single-writer preservation)

New `HistoryAuthority` methods, all opening a fresh operation-local context and
releasing it before return (`05` §5). None is part of the `HistoryAction`
dispatch (`05` §8); the closed `HistoryAction` switch is unchanged.

```swift
internal extension HistoryAuthority {
    // External write: INVOKES the single v1 commit kernel (no duplicated fact-
    // load/plan/transaction logic), parameterized by the manage-subset
    // ExternalRequest mapped to its v1 HistoryAction, with auditAppend threaded
    // via StampedCommitPlan. The ModelContext.transaction closure fetches
    // ConnectionRow.status + the required live GrantRow and throws/audit-as-denied
    // if revoked/ungranted at the save boundary (TOCTOU close, D33). request is
    // one of .pin/.unpin/.remove (§7.1); the v1 HistoryAction enum is NOT
    // modified. .unchanged from the planner -> audit outcome .noOp, no commit.
    // A planner THROW (.notFound / .invalidPinnedPlacement on an absent target)
    // -> failed-WRITE audit path mirroring §5.2's failed-READ path: append a
    // .failed OperationRecord (failureKind .notFound for a planner .notFound,
    // NOT .history; other planner HistoryFailures wrap as .history) in a
    // separate small transaction, await its commit, then rethrow; no History
    // Commit. noOp/denied/failed writes use the same mandatory publication
    // barrier, so a completed admitted call always has one durable record.
    func commitExternal(
        request: ExternalRequest,
        connection: ExternalConnectionID,
        requestedAt: Date
    ) async throws -> ExternalResponse

    // External read: delegates to the v1 read projection (05 §14). For .search
    // the path is TWO non-suspending Authority intervals bracketing the off-
    // actor SearchWorker await (it cannot live in one non-suspending closure):
    // interval 1 fetches ConnectionRow.status + required live GrantRow row(s)
    // (authoritative gate; throws/audit-as-denied if revoked/ungranted) and
    // captures the Sendable SearchCorpusSnapshot; SearchWorker evaluates off-
    // actor between intervals; interval 2 builds the page and audits outcome
    // .succeeded/.failed/.denied, atomically inserting nextAuditSequence and
    // advancing the singleton counter (Authority-serialized D36 continuity).
    // For .recent/.details/
    // .pastePayload (no off-actor evaluation) the gate+evaluate+audit fit ONE
    // non-suspending interval. A throw from the read projection is caught,
    // audited as .failed with the matching failureKind, and rethrown only after
    // that append commits. Audit failure publishes no DTO/content and throws a
    // persistence failure. The read-side grant-check-vs-
    // evaluation TOCTOU is accepted (revocation takes effect on the next
    // request).
    func performExternalRead(
        _ request: ExternalRead,
        connection: ExternalConnectionID,
        requestedAt: Date
    ) async throws -> ExternalReadResult

    // Audit append (denial path off the commit closure; the write path appends
    // in-commit via StampedCommitPlan.auditAppend, the read path appends inside
    // performExternalRead's closure).
    func appendDenialAuditRecord(_ payload: OperationRecordPayload) async throws

    // Admin: enroll/grant/revoke/rebase/compact — each appends an admin audit
    // record. None advances ChangePosition. enrollConnection accepts an optional
    // credential (nil for .appIntents; a bearer token / service-label secret for
    // future urlScheme/xpc kinds, stored via CredentialStore §6.7) so a future
    // credential-bearing kind needs no GatewayAdminHistory protocol change.
    func enrollConnection(
        kind: ConnectionEnrollKind,
        displayName: String,
        credential: Data? = nil
    ) async throws -> ExternalConnectionID
    func grantCapability(_ capability: ExternalCapability, to connection: ExternalConnectionID) async throws
    func revokeConnection(_ connection: ExternalConnectionID) async throws
    func revokeCapability(_ capability: ExternalCapability, of connection: ExternalConnectionID) async throws
    // rebaseAuditLog is recovery-only: record the discarded auditSequence range
    // [oldFloor, newFloor), advance the floor without resetting the head, and
    // optionally quarantine the discarded rows. It carries no connection or
    // capability attribution and claims no tamper evidence.
    func rebaseAuditLog(reason: AuditRebaseReason) async throws
    func compactAuditIfNeeded() async throws

    // Audit read (bounded fetch + typed decode + contiguous retained interval).
    func auditLog(since auditSequence: UInt64) async throws -> [OperationRecordPayload]
}
```

`commitExternal` does **not** duplicate the v1 commit kernel — it invokes the
single v1 commit path (fact-load → plan → stamp → transaction → index delta →
invalidation) with `auditAppend` threaded via `StampedCommitPlan`, exactly as
V2-03 threads `hcrAppend`. The v1 app-internal `commitRemove` /
`commitPinnedPlacement` / `commitUnpin` and the external `commitExternal` share
the same transaction machinery; they differ only in the entry mapping
(`HistoryAction` vs `ExternalRequest`) and whether `auditAppend` is set. The v1
app-internal `commitRemove` etc. remain for `perform(.remove)` and set
`auditAppend == nil`.

### 6.5 `@Dependency` is NOT a banned service locator (`01` §8 carve-out)

The v1 rule (`01` §8): "No `.shared`, `.current`, or other mutable authoritative
service locator." App Intents resolve dependencies through
`AppDependencyManager.shared` (pending verification under `X-COMPILE-2`; `V2-facts.md` cycle 6, fact 2) — a `.shared` spelling.
This is the **only** DI mechanism App Intents provides: App Intents are
constructed by the **system** (not by the app), so normal initializer injection
is impossible, and `@Dependency` / `AppDependencyManager` is, to the doc's
pending-verification understanding, Apple's intended seam (pending verification
under `X-COMPILE-2` / `X-SECURITY-1`; `V2-facts.md` cycle 6, facts 1, 2, 4 —
the pattern Apple's sample code demonstrates, e.g., WWDC24's `OpenAssetIntent`
declares `@Dependency` for its "Navigation Manager"). **Swift 6 strict-
concurrency risk:** a Swift Forums report documents a known crash against
`AppDependencyManager` / `@Dependency` in Swift 6 mode (queue-assertion crash
whenever any `@Dependency` is used in an `AppIntent`; verified and recorded in
`V2-facts.md` cycle 6:
https://forums.swift.org/t/appdependencymanager-and-dependency-usage-crashes-in-swift-6-mode/73226);
`X-COMPILE-2`
must therefore confirm CRASH-FREE resolution under a Siri/Shortcuts-invoked
`perform()` on macOS 26 (not just compilation), and the §6.5 carve-out's
soundness rests on that confirmation. V2-05 preserves the **intent** of `01` §8
by four controls:

1. **The authoritative writer is never registered into `.shared`.** v1
   constructs `HistoryAuthority` **inside**
   `SwiftDataHistory.open(configuration:)` (`05` §2); `ClipyApp` constructs
   `SwiftDataHistory` and never receives an Authority reference (see below).
   What is registered into `AppDependencyManager.shared` is one app-local
   **`AppIntentHistoryIngress`**. It contains the capability-scoped
   `ExternalHistoryFacade` and a content-free MainActor removal sink. The
   facade creates no `ModelContext` and routes every write back through
   `HistoryAuthority`; the sink runs only after `.remove(id)` returns
   `.removed(count > 0)` and before the Intent returns. Neither value can
   reach a writable context except through the single writer (D32).
2. **The ingress provider is registered at the composition root before the
   first store-opening suspension.** `ClipyApp` (`01` §2 sole composition
   root) installs exactly one asynchronous provider at its earliest launch
   entry. That provider awaits the same single composition-open work used by
   the UI and returns that open's app-owned ingress over the connection-bound
   facade; it never calls
   `SwiftDataHistory.open` independently and cannot create a second writer.
   The dependency is not constructed by an App Intent. This preserves the
   composition-root-injection intent of `01` §8 while avoiding a cold-launch
   race caused by registering an already-opened value only after an `await`.
3. **The registry is framework-owned DI infrastructure, not app-owned
   authority.** `01` §8 bans app-owned *authoritative* locators — locators that
   ARE the authority for an app concern (e.g., a hypothetical
   `HistoryAuthority.shared`). `AppDependencyManager.shared` is Apple's
   dependency-resolution table (like the cooperative global executor or `Task`
   machinery): framework infrastructure the app populates, not app authority.
   The literal `.shared` spelling is a system-mandated mechanism with no
   app-level alternative, exactly the kind of framework seam v1 already accepts
   implicitly (v1 does not ban `Task.detach` because the global executor is a
   system singleton).
4. **No second writer, no bypass.** The facade cannot mint a `ContentVersion`
   or `ChangePosition`, cannot create a context, and cannot bypass the grant
   gate or the audit. Decision 16 (`V2-00` §5) — "External writes cross one
   audited, capability-gated boundary; the Authority remains the sole durable
   writer" — is preserved in full.

This carve-out is recorded here honestly rather than hidden. It is a **narrow,
explicit exception** to `01` §8 ("No `.shared`, `.current`, or other mutable
authoritative service locator"), which v1 states without exception. `V2-00`
§2.2 has been **amended** to carve out framework-mandated DI seams: it now reads
"no app-owned authoritative `.shared`/`.current` service locator
(framework-mandated DI seams populated once at the composition root are
excepted - see V2-05 §6.5 `AppDependencyManager.shared` carve-out)." This
carve-out is the single sanctioned registration under that amended rule, not a
pending exception. `AppDependencyManager
.shared` is framework-owned DI infrastructure the app populates once at the
composition root, not app authority (control 3 above). The exception is scoped to
exactly **one asynchronous provider registration** (for
`AppIntentHistoryIngress`) in exactly **one site**
(`ClipyApp`) with no app-owned authoritative locator, no second writer, and no
bypass. The literal `.shared` spelling of `AppDependencyManager.shared` would
trip a naive grep for `01` §8 violations; the §9 source gate is amended to
**permit** the single `AppDependencyManager.shared` registration in `ClipyApp`
(and only there, only for the app-owned ingress containing the one
`ExternalHistoryFacade`) and to continue rejecting
every other `.shared`/`.current` spelling. Proof gate `X-COMPILE-2` confirms the
facade compiles `Sendable` under Swift 6 strict concurrency, delegates every
write to `HistoryAuthority`, and resolves from the out-of-package `ClipyApp`
target (CRIT-M3 / CRIT-M4).

```swift
// ClipyApp (composition root), synchronously at the earliest launch entry:
let compositionOpen = makeTheSingleCompositionOpenWork()
AppDependencyManager.shared.add(dependency: {                      // the ONE permitted .shared use
    let composition = try await compositionOpen.value
    return composition.appIntentHistoryIngress // Sendable facade + exact post-commit UI sink
})
// The UI and the provider await the SAME open work. App Intents resolve one
// `@Dependency var history: AppIntentHistoryIngress` via this registry.
```

`makeAppIntentsHistoryFacade()` is a **`public`, synchronous, no-argument**
accessor on `SwiftDataHistory` (CRIT-M3). It is published only in X.6, after the
positive actor paths exist. `open` constructs the gateway after startup has
created-or-validated the durable App Intents connection and carries that exact
`ExternalConnectionID` into the actor/facade; neither the factory nor any later
open phase re-mints it. The dedicated no-argument spelling is intentional:
`ConnectionEnrollKind.localAutomation` can have multiple enrolled connections,
so a kind-taking factory would have no authoritative single connection to bake
in. Future Local Automation enters through its separately approved
authenticated ingress, not this App Intents factory.

`ClipyApp` never receives a `HistoryAuthority` reference; the Authority stays
internal to `HistoryStorage` exactly as v1 requires (`05` §2).
`ExternalHistoryFacade` is itself a **`public` `Sendable` struct** — a `let`
gateway (`actor`, hence `Sendable`) + a `let connectionID` (`Sendable`). The
conformance is derived without `@unchecked Sendable`. It conforms to
`ExternalHistory` by delegating to the gateway with the baked-in connection ID.
`ClipyApp`'s internal `AppIntentHistoryIngress` also conforms to
`ExternalHistory`: reads delegate unchanged; mutations first await the facade,
then only a positive remove awaits `HistoryViewState`'s exact item purge before
returning. Pin, unpin, unchanged, and failure publish no purge. This adapter is
presentation coordination, not another Gateway or writer.
`SwiftDataHistory` itself does not conform to `ExternalHistory`; callers must
obtain this explicitly bound facade.

**Registration-before-resolution on background launch (CRIT-M4).** Siri /
Shortcuts / Spotlight can invoke an intent while the app is **not running**.
X.7 therefore performs the asynchronous-provider `add` synchronously at the
earliest launch entry, before awaiting the single composition open. A hosted
test may use Apple's public standalone `AppDependencyManager()` initializer to
prove that this provider awaits the same real in-memory-store open and resolves
again on a logical warm call. That evidence does **not** establish when the
framework-owned manager resolves dependencies during a true background launch,
what an absent/unresolved registration does, or whether the reported Swift 6
queue-assertion failure is absent under a Siri/Shortcuts invocation. Those
cold/warm ordering, unresolved-resolution, and crash-free claims remain
signed-runtime `X-COMPILE-2` / `X-SECURITY-1` cells. A provider-side store-open
failure may be mapped to
`ExternalFailure.temporarilyUnavailable(.storeLocked)`; that mapping must not
be described as proof of the framework's missing-dependency behavior.

Direct hosted calls to an intent's `perform()` do not run the framework's
pre-perform dependency-initialization phase. Those tests therefore use Apple's
public `AppDependency.wrappedValue` setter to inject the same real facade after
constructing the wrapper with the standalone manager. This proves the intent
adapter's request/result behavior without claiming that the manager resolved
the dependency; only signed App Intents execution can prove that.

### 6.6 AppIntent conformances (ClipyApp)

```swift
struct SearchHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search clipboard history"
    static var description = IntentDescription("Search retained clipboard items.")
    static let supportedModes: IntentModes = [.background] // macOS 26

    @Parameter(title: "Query", description: "Search text.")
    var query: String
    @Parameter(title: "Mode", default: SearchModeArg.exact)
    var mode: SearchModeArg
    @Parameter(
        title: "Limit",
        default: 20,
        controlStyle: .stepper,
        inclusiveRange: (lowerBound: 1, upperBound: 500)
    )
    var limit: Int   // bounds enforced at the gateway (D35); 1...500 (06 §2).

    @Dependency private var history: AppIntentHistoryIngress // app-local; contains connection-scoped facade

    func perform() async throws -> some IntentResult & ReturnsValue<[ClipboardHistoryItemEntity]> {
        let result = try await history.read(
            .search(text: query, mode: mode.asMode, limit: limit)
        )
        return .result(value: result.asTransientEntities)
    }
}

// Output only: no EntityQuery and therefore no hidden capped-history scan.
struct ClipboardHistoryItemEntity: TransientAppEntity { /* HistoryRow projection */ }

// PinItemIntent / UnpinItemIntent / RemoveItemIntent: String `itemID`, parsed
// through HistoryItemID(uuidString:), then the corresponding .manage request.
// GetItemDetailsIntent: String `itemID`, then the .readContent details request;
// its returned transient entity is a bounded metadata projection, not raw bytes.
// PasteItemIntent: String `itemID`, then audited .pastePayload and
// `PasteboardAdapter.write(payload)` on the main actor. It writes the General
// Pasteboard but never synthesizes Command-V or foreground-app keystrokes.
// ClipboardShortcuts: AppShortcutsProvider surfaces exactly these six intents.
```

Exactly six `AppIntent` types ship: `SearchHistoryIntent`,
`GetItemDetailsIntent`, `PasteItemIntent`, `PinItemIntent`,
`UnpinItemIntent`, and `RemoveItemIntent`, plus one
`ClipboardShortcuts: AppShortcutsProvider`. Search maps each invocation to one
bounded search read; details maps to one details read; pin/unpin/remove each maps to its one
external write. Paste has two sequenced owners: one audited `pastePayload` read
followed by the existing `PasteboardAdapter.write` side effect. It is still not
a new Gateway request or a Command-V operation.

The item-target parameters deliberately use canonical UUID strings rather than
`AppEntity` inputs. `HistoryItemID(uuidString:)` reconstructs the exported
identity, after which the Gateway performs the authoritative grant and
existence checks. Search and details return output-only
`TransientAppEntity` metadata projections; there is no `EntityQuery` and no
raw `Data` result. Paste consumes the audited `PastePayload` only to perform
the adapter write and returns a content-free success value. All six intents declare
macOS 26 `supportedModes = [.background]`; they do not use
`allowedExecutionTargets`, which is a macOS 27 API.

No intent can spell `capture`/`revise`/`clear`/`setRetentionPolicy` — those
cases do not exist on `ExternalHistory`. Each `perform()` awaits the facade,
which awaits the gateway and Authority. The intent carries no
`HistoryAuthority`/`@Model` reference. The parameter declarations improve the
Shortcuts UI, but their values remain untrusted (D35): canonical identity,
mode, text, and bounds are revalidated at the owning boundary. Compilation and
direct hosted invocation do not establish that system-created intents run in
the main app process or inherit its TCC/entitlements; those remain
`X-SECURITY-1` signed-runtime questions.

### 6.7 CredentialStore (F1 Data Protection Keychain direction)

```swift
internal actor CredentialStore {
    // Confines blocking SecItem* calls. F1 stores exactly 48 bytes in the
    // app-private Data Protection Keychain. X-PLATFORM-3 still owns the actual
    // signed-artifact compilation and exact round-trip proof.
    func storeCredential(_ data: Data, for connection: ExternalConnectionID) async throws
    func loadCredential(for connection: ExternalConnectionID) async throws -> Data?
    func deleteCredential(for connection: ExternalConnectionID) async throws
}
```

The actor owns only the server copy. PR #20 implements this actor, exact UUID16
+ secret32 validation/generation, duplicate rejection,
idempotent missing delete, corrupt-value fail-closed behavior, and content-free
failure mapping. Its deterministic tests substitute only the true external
Security operations; they do not exercise a real Keychain. The separately
executed client receives
the exact value through inherited stdin and keeps it in the §0.3 owner-only
file; no access group is claimed for that client. That client leaf is still
BLOCKED-SPEC on its executable/product placement and fixed production path. A
future sandbox or malicious-same-EUID confidentiality requirement invalidates
the file-custody choice and requires an app-like wrapped client plus proven
shared Data Protection Keychain entitlements, not a silent widening of this
actor.

## 7. Public surface (HistoryCore, Foundation-only)

### 7.1 ExternalHistory protocol (distinct concern — App-Intents-facing)

```swift
public protocol ExternalHistory: Sendable {
    func perform(_ request: ExternalRequest) async throws -> ExternalResponse
    func read(_ request: ExternalRead) async throws -> ExternalReadResult
}

public enum ExternalRequest: Sendable, Hashable {
    // .manage capability required:
    case pin(HistoryItemID)
    case unpin(HistoryItemID)
    case remove(HistoryItemID)
    // (No capture/revise/clear/setRetentionPolicy — app-only, §3.2.)
}

public enum ExternalRead: Sendable, Hashable {
    // .browse (or .manage) capability required:
    case recent(limit: Int)
    case search(text: String, mode: SearchMode, limit: Int)   // reuses v1 SearchMode (03a §7)
    // .readContent capability required (NOT implied by .manage — §3.2):
    case details(HistoryItemID)          // full HistoryDetails incl. canonical/effective (03b §9)
    case pastePayload(HistoryItemID)     // full PastePayload bytes (03b §9)
}

public enum ExternalResponse: Sendable {
    case pin(HistoryItemID)            // mirrors v1 .placedPinned outcome family
    case unpin(HistoryItemID)
    case removed(count: Int)
    case unchanged                     // v1 planner returned .unchanged (no commit;
                                       // audited as outcome .noOp, CRIT-M7)
}

public enum ExternalReadResult: Sendable {
    case page(HistoryPage) // reuses v1 HistoryPage (03b §8)
    case details(HistoryDetails)       // reuses v1 HistoryDetails (03b)
    case pastePayload(PastePayload)    // reuses v1 PastePayload (03b)
}
```

`SwiftDataHistory` does **not** conform to `ExternalHistory`: the protocol has
no connection argument, so such a conformance would be an unbound second entry.
The connection-scoped facade consumed by App Intents
(`ExternalHistoryFacade`, §6.5) is the sole conformance. It wraps a gateway plus
the startup-validated, baked-in App Intents connection ID and is the `Sendable`
callable value that `@Dependency` resolves. A v1 caller that holds
`any ClipboardHistory` behaves exactly as on v1; external access requires the
explicit public facade from the concrete `SwiftDataHistory` composition root.

`ExternalRequest` / `ExternalRead` are **closed** for V2 (frozen safe subset,
§3.2). Adding a case is an owned exhaustive-switch change across the gateway,
the Authority external methods, the audit `operationKind` enum, and tests —
exactly as adding a v1 `HistoryAction` case is (`03a` §1) — but it touches only
V2 surface, never the v1 `HistoryAction` enum.

### 7.2 GatewayAdminHistory protocol (distinct concern — in-app UX only)

```swift
public protocol GatewayAdminHistory: Sendable {
    // This generic admin method does not own Local Automation custody. F1 must
    // reject kind == .localAutomation before mutation and route the in-app
    // enable action through the concrete §0.3 coordinator, which preassigns the
    // ID and never exposes credential bytes through this public protocol.
    // `credential` remains reserved for a separately admitted future kind; it
    // is nil for .appIntents and is not an F1 bearer-token input.
    func enrollConnection(
        kind: ConnectionEnrollKind,
        displayName: String,
        credential: Data? = nil
    ) async throws -> ExternalConnectionID
    func revokeConnection(_ id: ExternalConnectionID) async throws
    func grantCapability(_ capability: ExternalCapability, to id: ExternalConnectionID) async throws
    func revokeCapability(_ capability: ExternalCapability, of id: ExternalConnectionID) async throws

    func connections() async throws -> [ConnectionDTO]
    func grants(for id: ExternalConnectionID) async throws -> [GrantDTO]
    func auditLog(since auditSequence: UInt64) async throws -> [OperationRecordDTO]
    // Recovery-only audit rebase records the discarded [oldFloor, newFloor)
    // range, advances the floor without resetting the sequence head, and
    // requires an explicit reason. X.4 owns this admin behavior.
    func rebaseAuditLog(reason: AuditRebaseReason) async throws
}

public struct ConnectionDTO: Sendable, Equatable {
    public let id: ExternalConnectionID
    public let displayName: String
    public let enrollKind: ConnectionEnrollKind
    public let status: ConnectionStatus
    public let enrolledAt: Date
    public let revokedAt: Date?
}

public struct GrantDTO: Sendable, Equatable {
    public let connectionID: ExternalConnectionID
    public let capability: ExternalCapability
    public let grantedAt: Date
    public let revokedAt: Date?
}

public struct OperationRecordDTO: Sendable, Equatable {
    public let auditSequence: UInt64
    public let connectionID: ExternalConnectionID? // nil for global rebase/compact
    public let capability: ExternalCapability?     // nil when no external grant applies
    public let operationKind: ExternalOperationKind
    public let outcome: ExternalOutcome
    public let requestedAt: Date
    public let committedAt: Date                  // non-optional; "when this record became
                                                   // durable" (writes==commit time; reads/admin/
                                                   // denied/noOp/failed==audit-txn clock, §5.4)
    public let changePosition: ChangePosition?    // succeeded writes ONLY (== commit ChangePosition
                                                   // == HCR sequence); nil for reads/admin/noOp/
                                                   // denied/failed (D34, CRIT-M8)
    public let failureKind: ExternalFailureKindRaw?   // nil on success/noOp; the typed discriminator
                                                       // (CRIT-M6) so the audit viewer can distinguish
                                                       // unauthorized / requestDenied / notFound / ...
    public let denialReason: ExternalDenialReason?    // nil unless failureKind == .requestDenied;
                                                       // .invalidInput vs .rateLimited (CRIT-M6) — the
                                                       // rate-limit transparency the quota provides.
                                                       // Populated from row.denialReasonRaw on read
                                                       // (§4.3); the distinction is durably persisted,
                                                       // not re-derived.
    public let affectedItemIDs: [HistoryItemID]?      // pin/unpin/remove: the affected ID(s) (bounded
                                                       // by ExternalLimits); nil for reads/admin (CRIT-M5).
                                                       // §3.2's "retains the affected IDs" justification
                                                       // is now projected to the read surface.
    // (No request text, no returned content — privacy/size, §4.4.)
}
```

`GatewayAdminHistory` is **not** registered in `AppDependencyManager`; it is
reached only via the in-app UX (V2-07) holding `SwiftDataHistory`-as-
`GatewayAdminHistory`. Admin operations advance **no** `ChangePosition` and
yield **no** `HistoryInvalidation` (they are not History Commits) — mirroring
`EnrichmentHistory.setEnrichmentEnabled` (`V2-01` §8). They are themselves
audited (§5.3).

**Why admin operations are NOT `HistoryAction` cases (justified against `03a`
§1).** `03a` §1 closes `HistoryAction` for clipboard-*content* operations
(capture/pin/remove/clear/revise/retention). Connection/grant admin is a
*gateway-administration* concern, not history content: (a) adding admin cases
to `HistoryAction` would force every exhaustive switch (Core/Domain/Storage/
tests) to handle non-content operations; (b) it would muddy the closed enum
with operations the Domain planner cannot plan (the Domain models content
lineage, not gateway consent); (c) it would make the Domain aware of the
external surface (breaking D16/D17 — Domain purity). The distinct-concern
protocol pattern (V2-01 `EnrichmentHistory`, V2-03 `ReconnectHistory`, V2-05
`ExternalHistory`/`GatewayAdminHistory`) avoids all three and keeps
`HistoryAction` frozen. This is the consistent V2 posture.

### 7.3 ExternalFailure and the audit vocabulary

```swift
public enum ExternalFailure: Error, Sendable, Equatable {
    case unauthorized(requestedCapability: ExternalCapability, connectionID: ExternalConnectionID)
    case connectionRevoked(connectionID: ExternalConnectionID)
    case requestDenied(ExternalDenialReason)        // input validation / rate-limit
    case notFound(HistoryItemID)
    case history(HistoryFailure)                    // wraps the frozen v1 HistoryFailure (03b §10)
    case temporarilyUnavailable(ExternalTransientReason)  // transient; carries the reason
    case persistence(PersistenceFailure)            // wraps v1 PersistenceFailure (03b §10)
    case auditCompactedBefore(floor: UInt64)        // read below compactionFloor (§5.6)
}

public enum ExternalDenialReason: Int16, Sendable, Equatable, Codable {
    case invalidInput = 1      // bounds / shape failure (D35)
    case rateLimited = 2       // process-wide App-Intents quota (§8, X-SECURITY-3)
}

public enum ExternalTransientReason: Int16, Sendable, Equatable, Codable {
    case indexRebuild = 1      // Signature Index rebuild in progress
    case storeLocked = 2       // Authority interval unavailable
    case insufficientDiskSpace = 3 // transaction reached the platform's
                                   // truthful ENOSPC/out-of-space classification
    case cancelled = 4         // admitted search was cancelled after its
                               // authoritative gate; retry is caller-controlled
}

// Stable raw-value discriminator persisted in OperationRecordRow.failureKindRaw
// (§4.3). NOT an enum-case ORDINAL (ordinals are fragile to reordering and
// violate 05 §4 stable-raw discipline); the raw values are frozen. The
// associated denial reason is persisted separately in denialReasonRaw (§4.3).
public enum ExternalFailureKindRaw: Int16, Sendable, Hashable, Codable {
    case unauthorized = 1
    case connectionRevoked = 2
    case requestDenied = 3     // pair with denialReasonRaw. NOTE: a SearchWorker-
                               // surfaced HistoryFailure.invalidInput is re-classified
                               // HERE (§5.2 input-validation consistency), NOT .history,
                               // so all invalid-input events share one discriminator.
    case notFound = 4
    case history = 5           // wraps v1 HistoryFailure (the wrapped case is NOT
                               // re-encoded; only the discriminator is persisted)
    case temporarilyUnavailable = 6
    case persistence = 7       // wraps v1 PersistenceFailure
    case auditCompactedBefore = 8
}

// Reason recorded in the rebase marker OperationRecord (§5.6 / §6.4) so the
// discarded auditSequence range [oldFloor, newFloor) is auditable (CRIT-M2).
public enum AuditRebaseReason: Int16, Sendable, Hashable, Codable {
    case corruptionDetected = 1   // retained sequence/payload validation failed
    case adminForced = 2          // user-initiated rebase via GatewayAdminHistory
}

public enum ExternalOperationKind: Int16, Sendable, Hashable, Codable {
    case readRecent = 1
    case readSearch = 2
    case readDetails = 3
    case readPastePayload = 4
    case managePin = 5
    case manageUnpin = 6
    case manageRemove = 7
    case adminEnroll = 8
    case adminGrant = 9
    case adminRevoke = 10
    case adminRebase = 11
    case adminCompact = 12
    case readEffectiveContent = 13 // Local Automation only (§0.2)
    case reviseContent = 14        // declared; denied until separately admitted
    case describeFormatCapabilities = 15 // declared shape; runtime blocked by §0.3
    case adminRevokeCapability = 16 // revokeCapability only; raw 10 remains connection revoke
    case adminReadConnections = 17  // GatewayAdminHistory.connections()
    case adminReadGrants = 18       // GatewayAdminHistory.grants(for:)
    case adminReadAudit = 19        // GatewayAdminHistory.auditLog(since:)
}

public enum ExternalOutcome: Int16, Sendable, Hashable, Codable {
    case succeeded = 1
    case failed = 2        // underlying error (history/persistence/notFound)
    case denied = 3        // unauthorized / revoked / requestDenied
    case noOp = 4          // v1 planner returned .unchanged, or admin no-op
                           // (grant-already-granted / revoke-already-revoked);
                           // benign — NOT a failure (CRIT-M7)
}
```

**Why a sibling `ExternalFailure`, not a new `HistoryFailure` case.** V2-05 does
to `HistoryFailure` what V2-03 did: introduce a sibling enum and leave the
frozen v1 `HistoryFailure` (`03b` §10) untouched. Justification (mirrors
`V2-03` §6.3): (1) different contract and recovery — `ExternalFailure` carries
gateway-specific recovery (revoke/grant, rate-limit backoff) distinct from v1
`HistoryFailure`'s browse/commit recovery; (2) different owning seam —
`ExternalFailure` is produced by the `ExternalHistory`/`GatewayAdminHistory`
protocols, not by v1 `ClipboardHistory.browse`/`perform`; (3) it sidesteps the
V2-02 OPEN question whether enum-case addition to a frozen v1 public enum is
"extension by addition" or "redefinition" (`V2-02` §8.2) — V2-05 does not touch
the v1 enum. `ExternalFailure.history(HistoryFailure)` and
`.persistence(PersistenceFailure)` **reuse** the v1 vocabulary by wrapping it
(standard scoped-error pattern, not a redefinition), exactly as `ReconnectFailure`
does (`V2-03` §6.3).

### 7.3.1 Complete admitted-failure -> ExternalFailure mapping (frozen subset)

`failureKindRaw` is persisted (§4.3), so every failure the gateway can
surface has exactly one row below. Six precedence rules close the
ambiguities left open by §5.1/§5.2:

- **P1 reachable sibling wins.** After P6 confirms that the source failure is
  producible by the active operation, a `HistoryFailure` case with a dedicated
  `ExternalFailure` sibling is never wrapped in `.history`:
  `.notFound` -> `.notFound` (raw 4); `.persistence` -> `.persistence`
  (raw 7); `.temporarilyUnavailable` -> `.temporarilyUnavailable`
  (raw 6). `.history` (raw 5) carries only reachable cases with no sibling.
  A sibling that belongs to a different operation does not bypass P6:
  for example, read-side `.insufficientDiskSpace` is impossible and becomes
  the audited invariant sentinel, not a transient read result.
- **P2 transient reasons.** A reachable v1 `.factProof` ->
  `.storeLocked` (retry-later, not an index rebuild). The public
  `.indexRebuild` reason is reserved vocabulary only:
  `.dedupIndexRebuild` is capture-path-only, and none of the frozen seven
  external operations admits it; any such source therefore takes P6 until a
  future owned operation explicitly adds that reachability. A write-transaction
  `.insufficientDiskSpace` -> `.insufficientDiskSpace` (truthful
  classification; never mislabeled as a lock), while the same source on a read
  is impossible/P6. `.storeLocked` is also gateway-minted for
  facade-resolution failure (§6.5).
- **P3 audit-only reclassification (§5.2 D35).** A SearchWorker-surfaced
  `HistoryFailure.invalidInput` is THROWN as `.history` (raw 5) but
  AUDITED as raw 3 + `denialReasonRaw == .invalidInput`. No other case
  is reclassified.
- **P4 coherence exhaustion.** Stamping-time
  `.capacityExceeded(.coherenceToken)` has no `ExternalFailure` sibling and is
  therefore thrown as `.history(...)` and audited raw 5. It is the only
  capacity kind reachable from the frozen subset.
- **P5 admitted search cancellation.** Cancellation after the search request
  passes interval 1's authoritative gate is not a pre-admission denial and is
  not wrapped as `.history`. It throws
  `.temporarilyUnavailable(.cancelled)` (transient-reason raw 4) only after
  committing one failed audit row (failure-kind raw 6, no denial reason).
  Mandatory audit failure overrides the cancellation with persistence failure.
- **P6 operation-aware fail-closed sentinel.** A globally known
  `HistoryFailure` is not automatically valid for every external operation.
  If a structurally admitted request's real Authority read/write path produces
  a §7.3.1 case that the active operation cannot produce, the gateway rejects
  that impossible pairing as
  `ExternalFailure.persistence(.invariantViolation)`. Before publishing it,
  the request commits one `.failed` audit with failure-kind raw 7 and no
  denial reason; mandatory audit failure still overrides. DEBUG-only
  `TaskLocal` fixtures inject impossible failures at the real Authority
  read/write seams to prove the sentinel and privacy. The hook has no Release
  declaration or path.

| failure (producible case; source) | thrown as | raw |
|---|---|---|
| `.notFound(id)` — unpin/remove planner | `.notFound(id)` | 4 |
| `.notFound(id)` — details/pastePayload read | `.notFound(id)` | 4 |
| `.invalidPinnedPlacement(.targetMissing)` — pin | `.history(...)` | 5 |
| `.invalidInput(.invalidSearchTerm)` — search | `.history` (audit 3) | 5 / 3 |
| `.invalidInput(.invalidRegularExpression)` — search | `.history` (audit 3) | 5 / 3 |
| `.invalidInput(.invalidPageLimit)` — recent/search | `.requestDenied(.invalidInput)` at the pre-admission D35 gate; no OperationRecord because no truthful admitted summary exists | 3 / no audit |
| `CancellationError` — admitted search after the authoritative gate | `.temporarilyUnavailable(.cancelled)`; mandatory `.failed` audit first, audit failure overrides | transient reason 4 / failure kind 6 |
| `HistoryFailure` forbidden for the active operation — operation-aware sentinel | `.persistence(.invariantViolation)`; mandatory `.failed` audit first | 7 |
| `.temporarilyUnavailable(.factProof)` — fact loads | `.temporarilyUnavailable(.storeLocked)` | 6 |
| `.temporarilyUnavailable(.insufficientDiskSpace)` — write transaction | `.temporarilyUnavailable(.insufficientDiskSpace)` | 6 |
| `.capacityExceeded(.coherenceToken)` — stamping at exhausted ChangePosition | `.history(...)` | 5 |
| `.persistence(.corruptStoredValue)` — decode | `.persistence(...)` | 7 |
| `.persistence(.invariantViolation)` — sequence/floor/prevalidation/corpus | `.persistence(...)` | 7 |
| `.persistence(.transaction)` — commit closure | `.persistence(...)` | 7 |

**Not producible** from the frozen subset's healthy production paths (pin is `.first`-only,
`ExternalRead` carries no cursor, no capture/revision/thumbnail/
retention path): `.staleContent`, `.revisionNotFound`,
`.snapshotExpired`, `.capacityExceeded` except the producible
`.coherenceToken` row above,
`.invalidPinnedPlacement(.targetEqualsAnchor/.anchorMissingOrUnpinned)`,
`.temporarilyUnavailable(.dedupIndexRebuild)`,
`.persistence(.openStore)` (open throws before the facade is
published, §4.6), and the ten capture/revision/thumbnail/retention
`.invalidInput` reasons. This is an operation-aware contract, not permission
to accept one of these cases when returned by the wrong operation: after
structural admission P6 converts that impossible pairing to audited
`.persistence(.invariantViolation)` raw 7.

**Gateway-minted (no v1 source):** `.unauthorized`,
`.connectionRevoked`, `.requestDenied(.invalidInput/.rateLimited)`,
`.temporarilyUnavailable(.storeLocked)` (§6.5),
`.temporarilyUnavailable(.cancelled)` for an admitted cancelled search,
`.auditCompactedBefore(floor:)` (§5.6).

**Coherence-token exception to P1.** `ExternalFailure` has no dedicated
capacity sibling. The only capacity failure reachable from the frozen subset is
stamping-time `.capacityExceeded(.coherenceToken)`, so it is deliberately
wrapped as `.history` and audited raw 5. Other capacity kinds remain
not-producible. This is not a reclassification: P1 applies only where a sibling
exists.

**Absent-target asymmetry (deliberate, v1 WS16):** remove/unpin and
details/pastePayload report raw 4; pin reports raw 5 via
`.history(.invalidPinnedPlacement(.targetMissing))` - placement keeps
its dedicated v1 vocabulary (`02` §10), and `ExternalFailure` has no
`invalidPinnedPlacement` sibling, so P1 does not apply to it.

### 7.4 Exhaustive-switch and code-interaction impact

- **`HistoryAction` switch (`05` §8):** unchanged. External/admin operations add
  no `HistoryAction` case. The v1 closed enum and its exhaustive dispatch are
  untouched.
- **`HistoryMutation` / `PlannedOutcome` (`02` §7):** unchanged. The external
  manage path issues the **same** v1 `HistoryAction` (`.remove`/`.placePinned`/
  `.unpin`); the Domain planner is unaware the request is external (D16/D17/
  D18 preserved). The `ExternalRequest` → `HistoryAction` map is total and
  explicit: `.remove(id)` → `.remove(id)`; `.unpin(id)` → `.unpin(id)`;
  `.pin(id)` → `.placePinned(id, at: .first)` (external callers cannot spell
  `.last`/`.before(anchor)` — those remain app-only; `.first` is the only
  sensible default for an external "pin this item" intent). Verified at X-COMPILE-1.
- **`StampedCommitPlan` (`05` §9):** gains one optional field `auditAppend:
  OperationRecordPayload?` (nil on every v1 path) — an additive, behavior-
  preserving extension (V2-03 §5.2 pattern).
- **`ClipboardHistory` protocol (`03a` §3):** unchanged. A v1 caller ignoring
  `ExternalHistory`/`GatewayAdminHistory` behaves exactly as on v1.
- **`SwiftDataHistory` field set (`05` §2):** extended with `ExternalGateway`
  (actor) — derived `Sendable` preserved (`01` §6).
- **New V2 switches:** `ExternalRequest`, `ExternalRead`, `ExternalResponse`,
  `ExternalReadResult`, `ExternalCapability`, `ExternalOutcome`,
  `ExternalOperationKind` are closed V2 enums; adding a case is an owned V2
  exhaustive-switch change (gateway, Authority external methods, audit kind,
  tests) — never touching v1.
- **§11 self-review scan:** `ExternalHistory`, `ExternalGateway`,
  `GatewayAdminHistory`, `OperationRecord`, `ExternalHistoryFacade`,
  `ConnectionRow`/`GrantRow`/`OperationRecordRow`/`GatewayConfigRow`,
  `ExternalFailure`, `ExternalCapability`, and the ClipyApp-only
  `ClipboardHistoryItemEntity` output projection are added to the V2
  naming-consistency scan (`V2-00` §8) — none collides with v1 vocabulary.

## 8. Security boundaries

- **Single trust boundary.** `ExternalGateway` is the only external entry.
  Every request is validated (D35), grant-gated (D33), and audited (D34) before
  reaching Domain/Storage. External input is untrusted.
- **Capability model (deny-by-default; browse/readContent split).** The
  bootstrapped App Intents connection has **no** grant at `open`; the user must
  explicitly grant `browse`, `readContent`, and/or `manage` via the UX (§3.3).
  `capture`/`revise`/`clear`/`setRetentionPolicy` are not external capabilities
  and cannot be granted (no case exists). `manage` implies `browse` but **not**
  `readContent` (§3.2). The `.browse`/`.readContent` split is the
  content-exfiltration control: `.browse` exposes only row titles + bounded
  search snippets (the v1 browse surface); `.readContent` exposes full
  `HistoryDetails` representations and full `PastePayload` bytes (passwords,
  tokens, secrets). The user may grant `.browse` (metadata) without
  `.readContent` (full content).
- **Single shared App Intents connection (accepted risk, CRIT-m1).** V2 has
  exactly ONE App Intents connection shared by all of Siri / Shortcuts /
  Spotlight. There is NO per-caller isolation: every enrolled caller shares one
  non-discriminating grant set and one rate-limit bucket. A Shortcut the user
  installed shares identical authority with Siri; there is no way to grant Siri
  `.browse` while denying a specific Shortcut, no way to attribute an operation
  to a specific Shortcut, and no way to revoke one Shortcut's access without
  revoking the whole surface. Per-Shortcut isolation is post-V2. This is
  surfaced to UX (V2-07) as the scope of the App Intents grant.
- **Rate limiting / quota — honest bound (`X-SECURITY-3`).** A process-wide
  App-Intents token-bucket quota bounds entry into the live Authority gate and
  History evaluation (deny `requestDenied(.rateLimited)`). Pure bounded scalar
  and descriptor admission occurs first so malformed requests consume no token
  and never require a fabricated audit summary. The quota is **in-memory**
  (resets on app relaunch — and App Intents can background-launch the app,
  resetting the bucket) and **per single shared connection** (callers are not
  individually distinguishable on the App Intents surface), so it is a **coarse
  process-wide throttle, not a per-caller cap**: a malicious Shortcut can
  EXHAUST it (denying legitimate Siri use — DoS) OR, if sized for aggregate
  use, under-mitigate a single caller. The honest OUTCOME is therefore "a
  rate-exceeding well-formed caller does not enter the live Authority gate or
  History evaluation." Every over-limit call still awaits its mandatory denial-audit
  append through the Authority, so this bucket does **not** bound incoming call
  rate, denial-audit write rate, or Authority load. Retained audit bytes are
  bounded separately by §4.5 compaction. Per-caller attribution is recorded as
  a known limitation requiring per-intent
  caller identity the surface may not provide (`X-SECURITY-4` surveys what
  caller identity, if any, is available). Whether the system itself
  coalesces/throttles App Intent invocations is undocumented — V2-05 does not
  rely on it. The bucket has capacity 30, starts full for each process lifetime,
  and refills exactly one token per `1_000_000_000` uptime nanoseconds, capped
  at 30. The bucket refills from
  `DispatchTime.now().uptimeNanoseconds` - "the number of nanoseconds since
  boot, excluding any time the system spent asleep" (Apple docs define the
  epoch; monotonicity itself is NOT documented - `V2-facts.md` cycle 6 fact
  9). The defense is the clamp, not the adjective: elapsed = max(0, now -
  last); a backward sample contributes elapsed `0` and does not move the saved
  sample backward. Whole-token refill advances that saved sample only by the
  credited whole-second interval, preserving the sub-second remainder, and the
  refill is capped at 30. A backward or non-monotonic reading can therefore
  only delay a refill, never grant extra. This is a correctness admission bound,
  not a claim about requests per second achieved by the product. The
  Storage-clock witness stays audit-timestamp-only (§5.5).
- **Single writer preserved (D32).** The gateway creates no `ModelContext`;
  every write delegates to `HistoryAuthority`. No external path bypasses the v1
  stamping/transaction stages or the planner.
- **Audit completeness (D34) + retained-sequence honesty (D36).** Succeeded writes and
  admin ops produce **exactly one** `OperationRecord`, committed atomically with
  their mutation (the history mutation for writes, the admin-state mutation for
  admin ops; crash-consistent: closure failure commits neither). Reads hold
  their immutable result/failure until a separate audit transaction commits;
  append failure publishes no DTO/content. Thus a successful read return has
  exactly one durable record, although a crash after audit and before return can
  leave a record the caller never observed. noOp/denied/failed write/admin
  attempts also await their separate audit commit before returning or throwing.
  Append-only is enforced by construction (no arbitrary delete/update writer;
  named exceptions are bounded compact/recovery operations, §4.5/§5.6).
  Typed decode plus the contiguous interval
  `[compactionFloor, nextAuditSequence)` detects malformed payloads, missing
  committed rows, duplicate sequences, and dishonest floor/head state. It does
  not detect a coherent privileged rewrite and is not tamper evidence (§4.4).
- **Privacy discipline.** The audit log records *request shape + result count*,
  never query text, never returned content (§4.4). Search audit carries byte
  counts. This prevents the audit from becoming a second, less-protected copy
  of sensitive clipboard content.
- **In-process App Intents (`V2-facts.md` cycle 6, OPEN 1 / `X-SECURITY-1`).** App Intents live in the
  main app target and run in the app's process, inheriting the app's
  entitlements/TCC. The required OUTCOME: an intent's `perform()` reaches the
  app's single in-process `HistoryAuthority` and the app's pasteboard TCC; no
  separate entitlement is needed for the intent to call `ClipboardHistory`. An
  App Intents extension target is a second process and is post-V2.
- **F1 credential custody.** App Intents need no credential. Local Automation's
  server-side app-private Data Protection Keychain and client-side owner-file
  direction is frozen in §0.3 but remains unimplemented and open under
  `X-PLATFORM-3`; actor confinement applies to blocking Keychain work.
- **Crash safety.** The audit log is durable state (not a derivation): its loss
  loses audit provenance (irreversible — Record 4 states it is NOT a cache).
  Typed payload or retained-sequence corruption is surfaced as a typed failure;
  normal open never silently repairs it (§5.6). A failed external write commits
  neither the mutation nor its audit record (D34).

## 9. Performance analog (Part VI §9)

Correctness gates run first. Performance claims for V2-05 (proof gates
`X-PERF-*`):

- **Capability gate is O(1) per request** (`X-PERF-1`): the targeted check
  fetches one `ConnectionRow` plus one required `GrantRow`, or two grant rows
  for manage-implies-browse, in one non-suspending Authority interval. It does
  not build a complete grant set.
- **Audit append is O(payload) per external op** (`X-PERF-2`): codec encode +
  one `context.insert` + the singleton counter update. Bounded by `ExternalLimits`
  (`maxAffectedItemsPerRecord` = 32; payload never carries query text or
  content). For writes this shares the v1/V2-03 commit closure (no second
  transaction); for reads it is a separate small transaction.
- **External read perf is consistent with v1** (`X-PERF-3`): the read path is
  the unchanged v1 `browse`/`details`/`pastePayload` projection (`05` §14); the
  gateway adds only validation; the Authority's read interval owns the targeted
  access gate and read audit. For `.search`, two non-suspending Authority
  intervals bracket the off-actor SearchWorker await (§5.2 step 2), while
  `.recent`/`.details`/`.pastePayload` fit one.
- **Audit log read is O(batch)** (`X-PERF-4`): bounded by
  `ExternalLimits.maxAuditReadBatchSize` (500); typed decode and contiguous
  sequence validation are O(batch).

No numeric latency target may be declared satisfied by the current repository;
`X-PERF-*` measure the greenfield scaffold on the macOS 26 runner.

## 10. Graft-admission records (`V2-00` §4)

### Record 1 — Lifted exclusion + evidence trigger

- **X1** lifts `00` §2 ("ExternalGateway, external connections, grants, App
  Intents, and request audit records") and `06` §4 ("ExternalGateway, external
  connection enrollment/grants, App Intents, or third-party writes"). Trigger:
  approved product spec **and** fresh architecture review (`V2-00` §3). This doc
  **is** the architecture review.
- **X2** lifts `00` §2 ("request audit records" / "Operation Record auditing
  and Audit/Connections domains") and `06` §4 ("Operation Record auditing and
  Audit/Connections domains"). Trigger: X1 approved (audit is X1's consequence).

### Record 2 — Invariant impact

D1–D19 are **preserved unchanged**. In particular:

- **D1 (stable identity):** external writes issue the same v1 actions; IDs are
  never reused; audit references to removed items remain meaningful.
- **D2/D4 (Canonical immutability / append-only revision):** no external
  capability touches Canonical Content (`revise` is app-only); external
  `.remove` deletes rows per the v1 retirement path.
- **D5/D6 (precise tokens):** the external manage path advances `ContentVersion`
  / `ChangePosition` exactly as the corresponding v1 action; the audit append
  and the targeted access check advance **neither** (they are not History Commits).
- **D7 (fingerprint-is-evidence):** unaffected (no dedup path is external).
- **D8 (complete facts):** the external write loads the **same** complete v1
  facts as the app-internal action; the Domain planner is unaware the request is
  external.
- **D16/D17/D18 (Domain purity / no leakage / semantic-plan completeness):**
  the Domain is untouched; the external request becomes a v1 `HistoryAction`
  before it reaches the planner; no hidden behavior is inferred.
- **Single-writer isolation (`00` §3.3; V2-01 D22, V2-03 D28):** the
  `ExternalGateway` actor creates no `ModelContext` — the V2-05 analogue (D32)
  holds. (D11/D18 are preserved trivially: external writes do not affect
  occurrence monotonicity or plan completeness, but are not the isolation
  invariants.)

V2-05 **extends** the invariant set with **D32–D36** (§11). No D1–D19 (and no
D20–D31 from V2-01..V2-04) is weakened.

### Record 3 — V2 proof gates

The analog of Part VI §6 (compile/dependency), §7 (schema/platform), §9 (perf)
on macOS 26:

- **X-COMPILE-1 (compile/dependency).** Swift 6 complete strict-concurrency
  build succeeds; no hashing/cryptography import is added for audit. The F1
  server-store leaf imports `Security` only in `HistoryStorage`; PR #20 passed
  the macOS Swift 6 compile/import gates in correctness run 32619384577, while
  real DPK behavior remains `X-PLATFORM-3` evidence. `AppIntents` is imported
  only in `ClipyApp` production sources, with the narrow hosted
  `ClipyIntegrationTests` exception needed to exercise those app-owned types;
  `HistoryCore` external-gateway types import only
  Foundation; no `@unchecked Sendable` or `nonisolated(unsafe)`;
  `ExternalGateway` is an `actor` type so
  `SwiftDataHistory: Sendable` is derived.
- **X-COMPILE-2 (`@Dependency` facade + `01` §8 carve-out + CRIT-M3/M4).** The
  `ExternalHistoryFacade` is **`public`** and `Sendable` (derived);
  `makeAppIntentsHistoryFacade()` is a **`public`, synchronous, no-argument**
  accessor on `SwiftDataHistory`
  (CRIT-M3 — `ClipyApp` is the separate Xcode app target outside the package,
  `01` §2; `package` access would not compile). An out-of-package
  `ClipyIntegrationTests` compile/behavior test imports `HistoryStorage`
  normally and calls the accessor. The HistoryCore snapshot changed
  intentionally at X.6 for the new truthful
  `ExternalTransientReason.insufficientDiskSpace` raw-3 and `.cancelled`
  raw-4 cases and was runner-regenerated in run 32606749388; the
  HistoryStorage facade itself remains outside that snapshot.
  `SwiftDataHistory` does not itself conform to `ExternalHistory`. `ClipyApp`
  resolves the facade via `@Dependency` and registers exactly one asynchronous
  provider into `AppDependencyManager.shared` at the earliest launch entry,
  before awaiting store open. That provider and the UI reuse the same single
  composition-open work;
  the facade delegates every write to `HistoryAuthority` (single writer; no
  bypass). The §9 source gate is amended to permit this single `.shared`
  registration in `ClipyApp` and reject every other app-owned authoritative
  `.shared`/`.current` spelling. A hosted test uses
  `AppDependencyManager()` rather than `.shared` to prove the provider against
  one real in-memory `SwiftDataHistory` open and logical repeated provider
  calls. Direct hosted intent calls set the documented writable
  `AppDependency.wrappedValue` and do not claim framework manager resolution.
  **Evidence ceiling:** that hosted proof does not close CRIT-M4. macOS 26
  signed invocation must still confirm true Siri/Shortcuts cold and warm
  launch ordering, framework behavior when registration/resolution is absent
  or unresolved, and crash-free Swift 6 dependency resolution. A provider-side
  store-open failure mapped to `.temporarilyUnavailable(.storeLocked)` is not
  evidence for the framework's missing-dependency behavior.
- **X-COMPILE-3 (import gate).** The v1 source gate (`01` §9) is extended to
  permit `AppIntents` in `ClipyApp` production sources plus only its hosted
  `ClipyIntegrationTests`; no SwiftPM target may import it. Audit adds no
  `CryptoKit`, Security, or hashing exception. The F1 server-store Security
  import is confined to `HistoryStorage` and does not imply a shared client
  access group.
- **X-COMPILE-4 (`@Parameter` controlStyle spelling + Int bounding — Lens B
  minor).** The macOS 26 declaration is frozen as
  `@Parameter(title: "Limit", default: 20, controlStyle: .stepper,
  inclusiveRange: (lowerBound: 1, upperBound: 500))`. X.7 compiled that exact
  spelling on the macOS 26 runner in correctness run 32609910701. The Gateway independently revalidates
  `limit` against `HistoryLimits.standard` (`06` §2) at D35, so parameter UI
  admission cannot bypass the trust boundary. All six intents use
  `supportedModes = [.background]`; they must not use macOS 27-only
  `allowedExecutionTargets`.
- **X-PLATFORM-1 (schema migration).** A new immutable `HistorySchemaV3` adds
  `ConnectionRow`/`GrantRow`/`OperationRecordRow`/`GatewayConfigRow` via the
  additive `V2 -> V3` stage; already-shipped `HistorySchemaV2` is byte-for-byte
  unchanged. Prove migration from every supported prior store, then bootstrap
  config + one active `Siri / Shortcuts / Spotlight` connection + zero grants
  + zero audit rows before any future facade publication. X.3 publishes none.
- **X-PLATFORM-2 (startup/schema validation; X.3).** Round-trip the four V3
  models; reject unknown raw/config versions, duplicate singletons/identities,
  missing config with dependent rows, invalid counters/floors, and any nonzero
  grant/audit bootstrap. Identity persists across reopen. The complete
  `OperationPayloadBlobV1` round-trip/corruption matrix belongs to X.4, where
  every admitted admin literal lands with atomic audit behavior; X.3 must not
  freeze the incomplete §4.4 illustration.
- **X-PLATFORM-3 (F1 credential custody).** In the actual Developer-ID/profile
  configuration, confirm `SecRandomCopyBytes` produces the 32-byte secret and
  actor-confined `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` round-trip
  the exact 48-byte value in the app-private Data Protection Keychain. Separately
  prove inherited-stdin provisioning, no-follow `0700`/`0600` client-file exact
  readback, restart cleanup/retry, and the authority-last enrollment / authority-
  first revocation order from §0.3. This remains open; F0A's ad-hoc signature and
  no-credential hello do not exercise it.
- **X-BEHAVIOR-1 (admitted failure -> ExternalFailure mapping, §7.3.1).**
  Fixture-prove the frozen mapping end to end, none of which
  X.4's codec-corruption proof or `X-PERF-*` (mechanism
  bounds) covers: (a) P1 - every `HistoryFailure` case with a
  dedicated sibling reachable for that active operation is thrown as that sibling (`.notFound`,
  `.persistence`, `.temporarilyUnavailable`), and `.history`
  carries only sibling-less cases; (b) P2 - `.factProof` throws
  `.temporarilyUnavailable(.storeLocked)`; `.indexRebuild` remains reserved
  public vocabulary because every frozen-operation `.dedupIndexRebuild`
  source takes P6, while write-transaction ENOSPC throws
  `.temporarilyUnavailable(.insufficientDiskSpace)` and read-side ENOSPC
  takes P6; (c) P3 - a SearchWorker
  `.invalidInput` is thrown as `.history` (raw 5) but audited
  as raw 3 + `denialReasonRaw == .invalidInput`, and no other
  case is reclassified; (d) the absent-target asymmetry -
  remove/unpin and details/pastePayload report raw 4, pin
  reports raw 5 via `.history(.invalidPinnedPlacement(
  .targetMissing))` (v1 WS16, deliberate); (e) the §7.3.1
  capacity boundary is explicit - exhausted ChangePosition throws
  `.history(.capacityExceeded(.coherenceToken))` and audits raw 5, while all
  other capacity kinds remain not-producible; (f) the remaining
  not-producible list holds - no frozen-subset request can
  surface `.staleContent`, `.revisionNotFound`,
  `.snapshotExpired`, the other `.capacityExceeded` cases, or the capture/
  revision/thumbnail/retention `.invalidInput` reasons, and any
  fixture that surfaces a listed case fails the gate; (g) cancellation after
  an admitted search's authoritative gate throws
  `.temporarilyUnavailable(.cancelled)` (transient raw 4), commits one failed
  audit before publication, and an audit-append failure replaces cancellation
  with persistence failure; (h) DEBUG-only `TaskLocal` fixtures inject
  spec-not-producible and wrong-operation failures through real Authority
  read/write paths, which the operation-aware sentinel converts to
  `.persistence(.invariantViolation)` and audits raw 7; the hook is absent
  from Release.
- **X-SECURITY-1 (App Intents in-process/entitlement).** `V2-facts.md` cycle 6, OPEN 1:
  confirm a main-app-target `AppIntent.perform()` runs in the app process on
  macOS 26 and inherits the app's pasteboard/file TCC + entitlements; confirm
  no separate entitlement is required for the intent to call `ClipboardHistory`.
  Hosted direct `perform()` calls cannot close process placement, system
  discovery, true cold/warm launch, unresolved dependency behavior, the Swift
  6 queue-crash report, or pasteboard/file TCC. These require signed
  Siri/Shortcuts invocation evidence.
- **X-SECURITY-2 (audit sequence/compaction honesty; X.4).** Fixture-prove
  atomic mint+insert, monotone contiguous retained sequences, duplicate/gap
  rejection, and a compaction/recovery transaction that records its marker and
  advances `compactionFloor` without resetting `nextAuditSequence`. Reads below
  the floor return `.auditCompactedBefore`; global rebase/compact records have
  nil connection/capability. State explicitly that these checks are not
  cryptographic tamper evidence and cannot detect a coherent privileged rewrite.
- **X-SECURITY-3 (rate limit — coarse process-wide throttle).** Confirm the
  in-memory, process-wide App-Intents token-bucket quota compiles and follows
  its deterministic admission state machine: a rate-exceeding external caller is throttled
  (`requestDenied(.rateLimited)`, one immutable denied record per well-formed
  call before the denial is returned, §3.1 step 0b) before the live
  authorization gate or History evaluation. It does not bound denial-audit append rate or Authority
  load. The honest bound
  (§8): the quota is per single shared connection (no per-caller
  distinguishability) and resets on app relaunch, so it is a coarse process-wide
  throttle, NOT a per-caller cap. Record the DoS limitation (a malicious
  Shortcut can exhaust the bucket, denying legitimate Siri use) honestly. A
  deterministic fixed-uptime witness (no sleep) proves: the initial 30 debits,
  same-time 31st denial, no refill at `999_999_999` ns, exactly one refill at
  `1_000_000_000` ns, a large-forward jump capped at 30, and a backward sample
  producing zero elapsed without rewinding refill state. Cadence fixtures are
  phrased and asserted as pre-dispatch maintenance proofs: the Nth structurally
  admitted destructive request, History read, live-grant denial, and rate
  denial first complete compaction; injected maintenance failure leaves cadence
  due, consumes no token, executes/audits no request, and the identical retry
  runs maintenance again. Because dispatch has not begun, maintenance failure
  cannot override a committed request outcome. This is correctness admission
  evidence, not a performance measurement.
- **X-SECURITY-4 (per-caller identity survey — OPEN).** The §8 honest-bound
  bullet records that V2's rate limit cannot attribute operations to a specific
  caller (Siri vs a given Shortcut) because the App Intents surface provides a
  single non-discriminating connection. `X-SECURITY-4` surveys, on macOS 26,
  what caller-identity signal (if any) an `AppIntent.perform()` can observe
  (e.g., an invocation-source API), so a future per-caller grant/quota can be
  scoped. Until then V2 ships the single-shared-connection model and surfaces
  its scope to UX (V2-07, CRIT-m1).
- **X-PERF-1..X-PERF-4** (§9): capability gate O(1); audit append O(payload);
  external read consistent with v1; audit read O(batch).

### Record 4 — Cache-law compliance

**N/A — V2-05 introduces no cache.** The `OperationRecord` audit log, the
`ConnectionRow`/`GrantRow` registries, and the `GatewayConfigRow` singleton are
**authoritative durable state**, not caches: they capture information
(external provenance, user consent) that the v1 history store does **not**
store and cannot reconstruct. A "miss" is not recoverable from authoritative
history (the audit proves *which connection requested what*, which history does
not record); a lost audit record is a lost fact, not a latency regression. The
Part IV §12 cache law ("cache hit, miss, eviction, disabled, restart produce
semantically identical values") therefore does not apply — there is no
authoritative source the audit "derives from." The connection/grant tables are
likewise authoritative (the user's consent is the source of truth, not a
derivation). This record restates the law to confirm the negative: V2-05 adds
no cache and so cannot violate the law. Audit sequence numbers are durable log
positions, not cache keys or content-derived identity.

### Record 5 — Migration impact (M1, Part V §17)

X.3 touches the **schema** layer and post-migration bootstrap (`05` §17):

- New tables `ConnectionRow`, `GrantRow`, `OperationRecordRow`,
  `GatewayConfigRow` are added by new immutable `HistorySchemaV3` via an
  additive `V2 -> V3` migration. Shipped `HistorySchemaV1` and
  `HistorySchemaV2` remain frozen; no prior row or column is rewritten.
- **No blob migration** (layer 2): no v1 `CanonicalBlobV1`/`RevisionStateBlobV1`/
  `SignatureBlobV1` is reinterpreted. X.3 creates no audit payload and freezes
  no audit codec; complete `OperationPayloadBlobV1` encoding begins in X.4.
- **No projection rebuild** (layer 3): no v1 `title`/`searchBody`/projection
  is touched.
- **Empty post-migration bootstrap.** Every supported prior store reaching V3
  gains exactly: one
  `GatewayConfigRow` singleton (defaults), one `ConnectionRow` (the bootstrapped
  App Intents surface, `displayNameRaw == "Siri / Shortcuts / Spotlight"`,
  `status == active`, **no grants**), zero `GrantRow`s,
  zero `OperationRecordRow`s. No backfill of past external operations (there
  were none). `nextAuditSequence == compactionFloor == 1`.
- **Bootstrap provenance ceiling.** Config absent + all three dependent tables
  empty is accepted as fresh/migration-compatible and rebuilt, even though it
  is observationally identical to complete deletion of all four Gateway model
  classes from a future V3 store. Only config absent + at least one surviving
  dependent row is distinguishable corruption and rejected. Record 5 claims no
  stronger detection and adds no marker/hash to manufacture one.
- **DC-25 X-HCR migration prerequisite for X.6.** New immutable
  `HistorySchemaV4` adds only `HistoryChangeRecordRow` and the exact four-field
  `JournalConfigRow` through a lightweight V3 -> V4 stage. The migration adds
  no data; Authority bootstrap creates an empty journal with
  `compactionFloorRaw ==` the current ChangePosition and `journalBytes == 0`.
  `AffectedItemsBlobV1` is the manual wire in V2-03 §0.2. There is no historical
  backfill and no public reconnect/cursor/reader/cache/rebase surface.
- **No writes before completeness.** The V2-05 bootstrap (§4.6) runs at `open`,
  followed by the V4 X-HCR bootstrap/validation from V2-03 §0.3, and both
  complete before projection/index construction or facade publication. X.3
  itself constructs no actor, facade, external dispatch, or admin service. No
  capture/write is enabled before Signature Index and X-HCR completeness are
  established.
- **No `ContentVersion` change, no ID reuse, no invented bytes** (`05` §17).

### Record 6 — Security boundary

(§8 states the boundary in full.) Summary: `ExternalGateway` is the single trust
boundary; external input is untrusted (D35); deny-by-default capability grants
(§3.3); single writer preserved (D32); every external op audited (D34) with a
typed payload and monotone contiguous retained sequence (D36), with explicit
compaction/recovery floors and **no tamper-evidence claim**;
privacy discipline (audit carries shape+count, never content/query text);
in-process App Intents (X-SECURITY-1); coarse process-wide rate throttle with
per-caller attribution deferred to X-SECURITY-4 (X-SECURITY-3); F1 credential
custody frozen but unimplemented (X-PLATFORM-3).
**Content-sensitivity note:** the `readContent` capability (especially
`pastePayload`/`details`) exposes sensitive clipboard content to the enrolled
connection; the user grants this explicitly (deny-by-default — `browse` may be
granted without `readContent`, §3.2) and every access is audited. `manage`
(`remove`) is destructive but audited and revocable. These exposures are
surfaced to UX (V2-07) as user-visible data practices. **Deletion latency:**
revoking a connection does not delete its historical `OperationRecord`s (they
are append-only audit); the user clears audit only via compaction (§4.5) or
rebase (§5.6), both admin operations.
There is no audit off-switch. Global rebase/compact records truthfully carry
nil connection/capability rather than fabricating an actor or grant.

## 11. New invariants (D32–D36)

D1–D19 (`02` §14) and D20–D31 (V2-01..V2-04) are preserved unchanged. V2-05
extends the set:

- **D32 External-single-writer.** Every external write routes through
  `HistoryAuthority`; no external path creates a `ModelContext`, loads a
  planning fact, or bypasses the v1 stamping/transaction stages; the gateway
  itself decodes no Canonical/revision blob (external `readContent` decodes
  lineage only inside the Authority via `05` §14.3). (The V2-05 analogue of
  V2-01 D22 / V2-03 D28; preserves `00` §3.3.)
- **D33 Capability-gated execution (authoritative dispatch gate).**
  An external request executes only if its connection is active and the
  targeted live grant row(s) authorize its capability inside the authoritative
  dispatch interval; writes perform that check at the save boundary. The
  external capability vocabulary is `.browse` (read metadata —
  recent/search), `.readContent` (read full content — details/pastePayload), and
  `.manage` (write pin/unpin/remove); `.manage` **implies `.browse`** but **not**
  `.readContent` (a manage caller can find items to manage but cannot read their
  content). The authoritative gate is the targeted fetch of
  `ConnectionRow.status` + the required live `GrantRow` row(s) **inside**
  `commitExternal`'s transaction closure (writes) / `performExternalRead`'s
  read-audit closure (reads). A request whose connection is revoked or whose
  capability is ungranted at the check throws
  `ExternalFailure.unauthorized` / `.connectionRevoked`, is audited as `denied`,
  and — for writes — commits nothing (closure failure commits neither the
  mutation nor any row). Admin revoke bypasses the `ExternalGateway` actor, but
  Authority serialization places it before or after the same dispatch interval;
  there is no separate lookup/dispatch window and no cached grant decision.
  No external request reaches
  Domain/Storage without a valid grant at the save boundary.
- **D34 Audit-completeness, by op class (crash bound stated per class).**
  Each committed audit append carries one unique monotone `auditSequence`; the
  crash-consistency bound is stated per operation class because only
  some classes share a save boundary with a mutation:
  - **Succeeded writes** produce **exactly one** record committed **atomically
    with the history mutation** in the same `ModelContext.transaction`
    (crash-consistent: closure failure commits neither the mutation, the HCR
    row, nor the record). This is the only class with a history mutation.
  - **Admin operations** produce **exactly one** record committed **atomically
    with the admin-state mutation** in the same transaction (e.g., `enrollConnection`'s
    `ConnectionRow` insert, `grantCapability`'s current-state `GrantRow`
    insert/update, `revokeConnection`'s status/`revokedAt` flip, `rebaseAuditLog` /
    `compactAuditIfNeeded`'s marker + trim). Admin ops advance **no**
    `ChangePosition` and yield **no** `HistoryInvalidation` (they are not
    History Commits), but they DO mutate gateway state, and their audit record
    shares that mutation's save boundary (closure failure commits neither).
  - **noOp / denied / failed writes or admin attempts** produce **exactly one
    committed record before their response/failure is released** via a separate
    Authority-serialized small transaction (there is no mutation to share a
    boundary with). Append failure replaces the intended response/failure with
    persistence failure. A crash after append but before return may leave a
    record the caller never observed; a completed call without a record is
    forbidden.
  - **Reads** build an immutable result/failure, then produce **exactly one
    committed record before publication** via a separate Authority-serialized
    transaction. Append failure throws and publishes neither DTO/content nor
    the underlying read failure. A crash after audit commit but before return
    may leave a record without caller observation; the reverse (successful
    return without a committed record) is forbidden.
  `changePositionRaw` is scoped: for **succeeded writes** it equals the commit's
  `ChangePosition` (and the required X-HCR `sequence`); for reads,
  admin ops, noOp, and denied/failed records it is `nil` (no commit). The
  succeeded-write/admin atomicity and the mandatory append-before-publication
  barrier for every no-mutation branch are the audit-completeness guarantee.
- **D35 External-input validation.** All external input (intent parameters,
  requested `HistoryItemID`s, search text, limits) is validated against the v1
  `HistoryLimits.standard` bounds at the gateway **before** it reaches a
  planning fact, a blob decode, or the Authority. Untrusted input never drives a
  Domain decision or a content decode beyond the v1 boundary discipline.
- **D36 Audit retained-sequence honesty.** `OperationRecord` is append-only by
  ordinary APIs; bounded compaction and recovery rebase are the only named
  exceptions. Each committed append inserts sequence N and advances
  `nextAuditSequence` to N+1 in the same transaction. Retained rows occupy every
  sequence in `[compactionFloor, nextAuditSequence)` exactly once. Compaction
  or recovery appends its global marker and advances the floor in the same
  transaction; a read below the floor returns `.auditCompactedBefore`, never a
  silent complete-log claim. Typed payload decoding and range/duplicate/gap
  checks fail closed. This detects incoherent persisted state, not a coherent
  privileged rewrite: V2-05 provides no hash chain, tamper evidence,
  non-repudiation, or content-derived audit identity.

## 12. Migration (M1) — summary

See Record 5. New V3 schema plus post-migration bootstrap; four new tables,
including one singleton; empty
post-migration; no blob/projection migration; no v1 surface rewritten; no
backfill; no ID/`ContentVersion` reuse; bootstrap at `open` before the facade is
eligible for publication, with typed config and retained-sequence validation
gating acceptance. X.3 publishes none.

## 13. UX hooks (full in V2-07; state contract here)

V2-07 owns the full UX. V2-05 supplies the state contract via
`GatewayAdminHistory` (in-app, main-actor) and `OperationRecordDTO` /
`ConnectionDTO` / `GrantDTO` (Foundation-only `Sendable` DTOs; no SwiftData/
Domain leakage, `V2-00` §6.6):

- **Connection management:** enroll (the App Intents surface is pre-bootstrapped;
  the UX offers "Enable Siri/Shortcuts access"), revoke, view active grants.
- **Capability grants:** toggle `browse` / `readContent` / `manage` per
  connection (deny-by-default surfaced explicitly; the browse/readContent split
  is the content-exfiltration control, §3.2 — surfaced as two distinct data
  practices).
- **Audit log viewer:** paginated `OperationRecordDTO` list (capability, kind,
  outcome, `failureKind`/`denialReason`, timestamp, `affectedItemIDs` count);
  privacy-preserving (no query text / content). A "compacted-before" indicator
  when the read floor is hit; a rebase event banner when a discarded
  `[oldFloor, newFloor)` range is present.
- **Privacy/transparency indicators:** "Siri searched your history N times since
  …"; data-practice disclosure for `browse`/`readContent`/`manage` exposure and
  for the audit log's persistence, compaction floor, and durable-before-release
  read bound;
  no tamper-evidence claim.

Observation remains snapshot-replacement (Part IV §5); admin operations advance
no `ChangePosition` and yield no `HistoryInvalidation`, so the UX re-reads the
audit log / grant list on demand (like V2-01 enrichment status, `V2-01` §8).

## 14. Open questions carried into proof gates

> **Platform-fact recording (updated 2026-08-15).** The `V2-facts.md` facts 1-7
> and OPEN 1-4 referenced throughout this doc are MCP-verified platform facts
> recorded in `V2-facts.md` Cycle 6 §6.1 (promoted verbatim 2026-08-15 from the
> sidecar; the former "a future `V2-facts.md` cycle-5 section does not yet
> exist" caveat is obsolete). Recording is not runner confirmation: App Intents
> facts 1-4 remain **pending verification** under `X-COMPILE-2` / `X-SECURITY-1`,
> Keychain facts 5-7 under `X-PLATFORM-3`, and OPEN 1-4 under the `X-*` gates
> mapped below (OPEN 3 is resolved by design). No concrete platform claim in
> V2-05 rests on an unrecorded fact; each is gated or design-resolved,
> satisfying `V2-00` §8.

- `V2-facts.md` cycle 6, OPEN 1 → `X-SECURITY-1` (App Intents in-process / entitlement
  inheritance).
- `V2-facts.md` cycle 6, OPEN 2 → `X-COMPILE-2` (`@Dependency` timing + Swift 6
  isolation of the facade).
- `V2-facts.md` cycle 6, OPEN 3 → resolved by design (§3.2 / §7.1 — capability-scoped
  subset is a distinct protocol, not a `HistoryAction` subset).
- `V2-facts.md` cycle 6, OPEN 4 is superseded for this graft by the user-approved
  no-hash decision; `X-SECURITY-2` proves typed decode, contiguous retained
  sequences, atomic counter+row updates, and compaction-floor honesty only.
- Rate-limit quota values and exact audit-compaction cadence → admission bounds
  fixed at scaffold time (peer to `ExternalLimits`); `X-SECURITY-3` / `X-PERF-2`
  exercise them.
- Per-caller attribution on the single shared App Intents connection →
  `X-SECURITY-4` surveys what caller-identity signal (if any) an intent can
  observe on macOS 26; until then V2 ships the single-shared-connection model
  (§8 / CRIT-m1).
- `@Parameter` `controlStyle` spelling + `Int`-bounding mechanism → `X-COMPILE-4`
  (Lens B minor; not load-bearing — the gateway re-validates `limit` at D35).

Individual leaves may land only with their own recorded proof ceilings: X.1/X.2
reserve the public contract vocabulary, X.3–X.7 are landed at their recorded
boundaries, X.8 is landed as a pure codec, and F0A is landed only as a proof
discriminator. X.9/F1 is current. Until the remaining applicable `X-COMPILE-*`,
`X-PLATFORM-*`, `X-BEHAVIOR-*`, and `X-SECURITY-*` gates pass on macOS 26, the
landed Gateway/administration/App Intents claims stay at their recorded
source/hosted-test ceilings, and the Local Automation external product surface
remains unshipped. Deferred `X-PERF-*` gates support later performance claims
and do not upgrade a correctness leaf's status.
