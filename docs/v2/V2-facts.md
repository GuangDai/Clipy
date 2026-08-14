# V2 Facts Sidecar (append-only, shared across cycles)

> MCP-verified platform facts and OPEN questions for V2 design. Each cycle
> appends; later cycles read to avoid re-verifying. A fact's verdict is either
> **VERIFIED** (MCP-fetched, sourceUrl cited) or **OPEN** (could not fetch;
> assigned a V2 proof gate in the owning doc). This file is NOT a v1 doc; it
> lives only in `docs/v2/` and owns no spec semantics.

## Verified platform facts

### Vision OCR

1. **Claim:** `VNRecognizeTextRequest` recognizes text in an image and is
   available on macOS 26.
   - **Verdict:** VERIFIED.
   - **Correct statement:** `class VNRecognizeTextRequest` is an Objective-C
     class (NSObject subclass, NOT `Sendable`) introduced macOS 10.15+ (iOS
     13.0+). It finds and recognizes text in an image; results are
     `VNRecognizedTextObservation` objects. It is a `VNImageBasedRequest`.
     Because it is not `Sendable`, it must be created, configured, and consumed
     entirely within one actor (mirrors v1's non-`Sendable` Fuse matcher in
     `SearchWorker`, `01` §6).
   - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrecognizetextrequest

2. **Claim:** `VNImageRequestHandler.perform(_:)` is a synchronous, throwing
   execution method.
   - **Verdict:** VERIFIED.
   - **Correct statement:** `func perform(_ requests: [VNRequest]) throws` —
     "The function returns after all requests have either completed or failed."
     It is blocking; individual request results/errors are read from each
     request after return. macOS 10.13+. Therefore OCR must run off the
     `HistoryAuthority` commit interval (on a dedicated `EnrichmentWorker`
     actor), never inline in a serialized commit.
   - **sourceUrl:** https://developer.apple.com/documentation/vision/vnimagerequesthandler/perform(_:)

3. **Claim:** A `VNImageRequestHandler` can be constructed directly from image
   `Data` (no `CGImage`/decode required upstream).
   - **Verdict:** VERIFIED.
   - **Correct statement:** `init(data imageData: Data, options: [VNImageOption : Any] = [:])`
     — "Creates a handler to use for performing requests on an image in a data
     object. Image content is immutable." macOS 10.13+. This lets enrichment
     feed the Effective-Content image representation bytes straight to Vision
     without an intermediate `CGImage`/ImageIO decode in the commit interval.
     `init(cgImage:options:)` and `init(ciImage:options:)` also exist.
   - **sourceUrl:** https://developer.apple.com/documentation/vision/vnimagerequesthandler/init(data:options:)

4. **Claim:** Recognized text and confidence are exposed as simple properties.
   - **Verdict:** VERIFIED.
   - **Correct statement:** `VNRecognizedText.string` is `var string: String { get }`
     ("the top candidate for recognized text") and `VNRecognizedText.confidence`
     exists (referenced from `string`'s See Also). Both macOS 10.15+.
     `VNRecognizedTextObservation.topCandidates(_:)` returns the candidate
     list. All are NSObject subclasses (non-`Sendable`).
   - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrecognizedtext/string
     , https://developer.apple.com/documentation/vision/vnrecognizedtextobservation/topcandidates(_:)

5. **Claim:** Recognition languages, language correction, and custom words are
   configurable per request.
   - **Verdict:** VERIFIED (recognitionLanguages direct; others by See-Also
     reference).
   - **Correct statement:** `var recognitionLanguages: [String] { get set }`
     (ISO language codes, priority order; macOS 10.15+). `usesLanguageCorrection`,
     `automaticallyDetectsLanguage`, and `customWords` are documented sibling
     properties (listed in `recognitionLanguages` See Also). The exact Swift
     signature of `usesLanguageCorrection` did not resolve by direct URL (OPEN
     below); treat as `var usesLanguageCorrection: Bool { get set }` pending the
     proof gate.
   - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrecognizetextrequest/recognitionlanguages

6. **Claim:** Vision OCR runs entirely on-device.
   - **Verdict:** VERIFIED.
   - **Correct statement:** The official article states: "all of Vision's
     processing happens on the user's device to enhance performance and user
     privacy." Two paths exist: fast (character-based) and accurate
     (whitespace-tokenized). Language support is path+revision dependent via
     `supportedRecognitionLanguages(for:revision:)`.
   - **sourceUrl:** https://developer.apple.com/documentation/vision/recognizing-text-in-images

7. **Claim:** `VNRecognizeTextRequest` is completion-handler based (results
   read from `request.results` after `perform`).
   - **Verdict:** VERIFIED (by article).
   - **Correct statement:** The article confirms the request receives a
     completion closure invoked during processing, and results are retrieved by
     querying `request.results` as `[VNRecognizedTextObservation]`. The exact
     `init(completionHandler:)` signature did not resolve by direct URL (OPEN
     below); the completion handler is captured and confined to the
     `EnrichmentWorker` actor (it is not `Sendable`), exactly as v1 confines the
     non-`Sendable` Fuse matcher.
     **NOTE: this confinement sub-claim is REFUTED in Cycle 1** - the completion
     handler runs on a different queue than the `perform(_:)` caller, so accessing
     non-`Sendable` results from it is a Swift 6 isolation violation; use the
     no-completion-handler path (`init()` / `init(completionHandler: nil)`,
     synchronous `perform(_:)`, read `request.results` after return) per
     `E1-COMPILE-2`.
   - **sourceUrl:** https://developer.apple.com/documentation/vision/recognizing-text-in-images

### PDFKit (PDF text extraction)

8. **Claim:** `PDFDocument` loads PDF data and is available on macOS 26.
   - **Verdict:** VERIFIED.
   - **Correct statement:** `class PDFDocument` (NSObject subclass, NOT
     `Sendable`) macOS 10.4+. Initialized from data or URL; provides page count,
     page access, find. Must be confined to the `EnrichmentWorker` actor.
   - **sourceUrl:** https://developer.apple.com/documentation/pdfkit/pdfdocument

9. **Claim:** `PDFPage` exposes its text as an optional String.
   - **Verdict:** VERIFIED.
   - **Correct statement:** `var string: String? { get }` — "Returns an object
     representing the text on the page." macOS 10.4+. `numberOfCharacters`,
     `attributedString` also available. A `nil`/empty result means the PDF page
     has no text layer (scanned/image PDF); V2-01 treats that as empty
     enrichment text (scanned-PDF OCR is deferred, see OPEN).
   - **sourceUrl:** https://developer.apple.com/documentation/pdfkit/pdfpage/string

### SwiftData schema migration

10. **Claim:** SwiftData provides versioned schemas and a migration-plan API.
    - **Verdict:** VERIFIED.
    - **Correct statement:** `protocol VersionedSchema : SendableMetatype`
      (macOS 14.0+) requires `versionIdentifier` (a `Schema.Version`) and the
      model set; `Schema.init(versionedSchema:)` builds a `Schema` from it.
      `protocol SchemaMigrationPlan` declares `static var stages: [MigrationStage]`.
      `enum MigrationStage` (macOS 14.0+, `Sendable`) provides
      `.lightweight(fromVersion:toVersion:)` and `.custom(...)`.
      `ModelContainer.init(for:migrationPlan:configurations:)` opens a store
      with a plan. All available on macOS 26.
    - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/versionedschema
      , https://developer.apple.com/documentation/swiftdata/migrationstage
      , https://developer.apple.com/documentation/swiftdata/schemamigrationplan/stages

11. **Claim:** Adding a new `@Model` table alongside unchanged v1 models is an
    additive (lightweight) migration that does not touch v1 rows.
    - **Verdict:** VERIFIED (API existence); behavioral safety is a V2 proof gate.
    - **Correct statement:** `MigrationStage.lightweight(fromVersion:toVersion:)`
      exists for additive schema changes. Because `HistoryItemRow` and
      `LastChangePositionRow` are unchanged (frozen) and `EnrichmentRow` is a new
      model with no v1 data, the V1→V2 migration is purely additive. The
      proof gate must confirm SwiftData performs this without rewriting v1 rows
      and that a v1 store opens cleanly under the V2 plan.
    - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/migrationstage

## OPEN questions

1. **`usesLanguageCorrection` exact signature.** Direct content fetch returned
   404; property is confirmed by See-Also reference only. Treat as
   `var usesLanguageCorrection: Bool { get set }`. Assigned proof gate
   `E1-COMPILE-2` in V2-01 §10.

2. **`VNRecognizeTextRequest.init(completionHandler:)` exact signature.**
   Confirmed by article prose (completion-closure model) but direct URL 404.
   Assigned proof gate `E1-COMPILE-2`.

3. **`VNRecognizeTextRequest` revision to pin on macOS 26.** Vision exposes
   revisions (`supportedRecognitionLanguages(for:revision:)`); the revision
   affects language support and accuracy. V2-01 must pin a revision and
   fixture-lock its supported languages. Assigned proof gate `E1-PLATFORM-3`.

4. **Scanned-PDF OCR scope.** `PDFPage.string` returns `nil`/empty for
   image-only PDFs. Whether V2-01 OCRs rendered PDF pages via Vision is a
   product/scope decision. V2-01 §2 defers scanned-PDF OCR (enrichment text is
   empty for image PDFs); a future graft may add rendered-page OCR. Assigned as
   an explicit out-of-scope note, not a proof gate.

5. **PDFKit import-gate compliance.** v1 (`01` §8) forbids `import AppKit`
   outside the adapter. `import PDFKit` is a distinct framework; `PDFDocument`/
   `PDFPage` are NSObject (not AppKit view) types. Whether `import PDFKit`
   transitively links AppKit and whether the v1 source gate treats it as an
   AppKit import must be confirmed. Assigned proof gate `E1-COMPILE-3`. Fallback:
   CoreGraphics `CGPDFDocument` text extraction (no AppKit).

6. **On-device OCR TCC/entitlement impact on macOS 26.** No additional TCC
   permission is expected because OCR processes bytes already in-process
   (captured pasteboard content), and Vision is documented on-device. Confirm
   no entitlement/privacy-usage string is required. Assigned proof gate
   `E1-SECURITY-1`.

7. **Non-suspending invalidation delivery to the EnrichmentWorker.** V2-01
   triggers enrichment off the internal invalidation stream (a new internal
   consumer). Confirm the debounced drain never blocks the `HistoryAuthority`
   commit path and never starves user commits. Assigned proof gate
   `E1-PERF-4`.

8. **SwiftData lightweight-migration atomicity for the additive V2 table.**
   Confirm the V1→V2 migration leaves the Signature Index and singleton
   position untouched (the migration adds a table only). Assigned proof gate
   `E1-PLATFORM-4`.


## Cycle 1 verified facts

Appended 2026-07-23 (IMPROVE cycle 1). Each entry: claim / verdict / correct
statement / sourceUrl. Verdicts are VERIFIED (MCP-fetched), REFUTED
(MCP-fetched and corrected), or OPEN (could not fetch; V2 proof gate retained).

### Vision OCR (cycle 1)

- **Claim (OPEN 1):** `VNRecognizeTextRequest.usesLanguageCorrection` exact Swift
  signature.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `var usesLanguageCorrection: Bool { get set }` -
    "A Boolean value that indicates whether the request applies language
    correction during the recognition process." Disabling returns raw results
    (faster, less accurate). macOS 10.15+ (iOS 13.0+). Non-`@Sendable` (instance
    property on the non-Sendable `VNRecognizeTextRequest` class). Resolves OPEN 1;
    `E1-COMPILE-2` narrows from "confirm signature" to "confirm confinement +
    no-completion-handler path."
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrecognizetextrequest/useslanguagecorrection

- **Claim (OPEN 2):** `VNRecognizeTextRequest.init(completionHandler:)` exact
  signature.
  - **Verdict:** VERIFIED (inherited from `VNRequest`).
  - **Correct statement:** The init is INHERITED from `VNRequest` (which is why the
    `VNRecognizeTextRequest`-scoped URL 404'd): `init(completionHandler:
    VNRequestCompletionHandler? = nil)` where `typealias VNRequestCompletionHandler
    = (VNRequest, (any Error)?) -> Void`. Optional (default nil), non-`@Sendable`.
    `VNRecognizeTextRequest` also inherits the no-arg `init()`.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrequest/init(completionhandler:)

- **Claim (V2-01 §6.2 confinement):** the `VNRecognizeTextRequest` completion
  handler and results are "read and discarded inside the actor."
  - **Verdict:** REFUTED as worded.
  - **Correct statement:** Apple documents (on BOTH the init page and the
    `VNRequestCompletionHandler` typealias): "Vision executes the completion
    handler on the same queue that it executes the request; however, this queue
    differs from the one where you called perform(_:)." A supplied completion
    handler does NOT run on the `EnrichmentWorker` actor's executor, so accessing
    non-`Sendable` results from it is a Swift 6 isolation violation. The
    confinement claim is ONLY safe via the no-completion-handler path: construct
    via `init()` (or `init(completionHandler: nil)`), call the synchronous blocking
    `perform(_:)`, and read `request.results` synchronously after return on the
    worker's own thread. `E1-COMPILE-2` widened accordingly.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrequestcompletionhandler

- **Claim (OPEN 3 / E1-PLATFORM-3):** the `VNRecognizeTextRequest` revision to
  pin on macOS 26.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `VNRequest.revision` is `var revision: Int { get set }`
    (macOS 10.14+). `VNRecognizeTextRequestRevision3` (`var ...: Int { get }`,
    macOS 13.0+ / iOS 16.0+) is the ONLY non-deprecated revision; Revisions 1 and
    2 are DEPRECATED. On macOS 26 pin Revision 3
    (`request.revision = VNRecognizeTextRequestRevision3`).
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrecognizetextrequestrevision3

- **Claim (E1-PLATFORM-3 language set):** fixture-lock the language set via
  `supportedRecognitionLanguages(for:revision:)`.
  - **Verdict:** REFUTED as stated.
  - **Correct statement:** `class func supportedRecognitionLanguages(for:
    VNRequestTextRecognitionLevel, revision: Int) throws -> [String]` is
    DEPRECATED (macOS 12.0+ / iOS 15.0+). The non-deprecated instance method is
    `func supportedRecognitionLanguages() throws -> [String]` ("Returns the
    identifiers of the languages that the request supports"), reflecting the
    revision set on the request. E1-PLATFORM-3 rewritten to pin Revision 3 and
    fixture-lock via the non-deprecated instance method.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrecognizetextrequest/supportedrecognitionlanguages(for:revision:)

- **Claim (V2-01 §3.3 recognitionLevel):** encodes `fast`/`accurate`.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `var recognitionLevel: VNRequestTextRecognitionLevel {
    get set }` - fast prioritizes speed, accurate is more intensive. macOS 10.15+.
    Validates the `EnrichmentBlobV1.recognitionLevel` encoding; language support
    is path+level+revision dependent.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrecognizetextrequest/recognitionlevel

- **Claim (V2-01 §2.1/§9 customWords):** sibling of `usesLanguageCorrection`.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `var customWords: [String] { get set }` - supplements
    recognized languages at the word-recognition stage; custom words take
    precedence; ignored when `usesLanguageCorrection` is false. macOS 10.15+.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrecognizetextrequest/customwords

### PDFKit (cycle 1)

- **Claim (OPEN 5 / E1-COMPILE-3):** `PDFDocument`/`PDFPage` usable without
  AppKit at the API level.
  - **Verdict:** VERIFIED (API level).
  - **Correct statement:** `class PDFDocument` (macOS 10.4+) and `class PDFPage`
    (macOS 10.4+) both inherit from `NSObject` and conform only to
    `CVarArg`/`CustomDebugStringConvertible`/`CustomStringConvertible` - NO
    `NSView`/`NSResponder`/AppKit type. `PDFView` (an `NSView` subclass) is the
    AppKit-dependent class; V2-01 references only `PDFDocument`/`PDFPage.string`,
    never `PDFView`. PDFKit has its own docs collection, distinct from appkit, and
    is cross-platform (iOS 11.0+/tvOS/visionOS have no AppKit). The transitive
    *link* question (PDFKit.framework linking AppKit.framework at the binary level)
    is NOT answerable from API docs and remains `E1-COMPILE-3` (OPEN).
  - **sourceUrl:** https://developer.apple.com/documentation/pdfkit/pdfpage

- **Claim (fact 6 / V2-01 §9):** Vision OCR is on-device.
  - **Verdict:** VERIFIED (re-verified).
  - **Correct statement:** "all of Vision's processing happens on the user's
    device to enhance performance and user privacy." Two paths (fast/accurate);
    language support is path+revision dependent.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/recognizing-text-in-images

- **Claim (PDFDocument init):** initialized directly from PDF `Data`, failable.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `init?(data: Data)` - "The data must be PDF data...
    otherwise this method returns NULL." macOS 10.4+, iOS 11.0+, cross-platform.
    The failable return is load-bearing: bytes presented as `com.adobe.pdf` that
    are not valid PDF yield nil -> failed/empty derivation. `PDFDocument` is a
    non-`Sendable` class confined to `EnrichmentWorker`.
  - **sourceUrl:** https://developer.apple.com/documentation/pdfkit/pdfdocument/init(data:)

- **Claim (PDFDocument page access):** zero-based page count and access.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `var pageCount: Int { get }` and
    `func page(at index: Int) -> PDFPage?` ("Indexes are zero based... raises an
    exception if index is out of bounds."). macOS 10.4+, cross-platform. The
    out-of-bounds Objective-C exception is a Swift crash, so page iteration MUST be
    bounded to `0 ..< pageCount` (E1-COMPILE-2). This is V2-facts.md fact 12
    (page-access spelling).
  - **sourceUrl:** https://developer.apple.com/documentation/pdfkit/pdfdocument/page(at:)

### SwiftData migration (cycle 1)

- **Claim (fact 11 / Record 5):** `MigrationStage.lightweight` takes two
  `VersionedSchema` types and is the additive case.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `case lightweight(fromVersion: any VersionedSchema.Type,
    toVersion: any VersionedSchema.Type)`. macOS 14.0+, iOS 17.0+, Swift 5.9+;
    `MigrationStage` is `Sendable`. Sibling is `.custom(...)`. LOAD-BEARING for
    V2-01: v1's `HistorySchemaV1` is a plain `Schema` *value* (`05` §3), not a
    `VersionedSchema` *type*, and is frozen. M1 retrofits an additive
    `HistorySchemaV1: VersionedSchema` type (behavior-preserving) to anchor the
    migration - this does NOT modify the frozen `v1Schema` value/models/rows.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/migrationstage/lightweight(fromversion:toversion:)

- **Claim (E1-PLATFORM-4):** the V1->V2 additive migration leaves v1 rows, the
  Signature Index, and the singleton position untouched.
  - **Verdict:** OPEN (API existence verified; behavioral safety unverified).
  - **Correct statement:** API existence verified. The `MigrationStage` page has
    NO behavioral prose confirming existing rows are preserved; a SwiftData
    migration-behavior article/WWDC transcript search returned nothing. The
    structural argument (frozen v1 models + new `EnrichmentRow`/`EnrichmentConfigRow`
    with no `@Relationship` to v1 models = purely additive) supports the claim, but
    behavioral verification remains `E1-PLATFORM-4`.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/migrationstage

### Delivery and security (cycle 1)

- **Claim (OPEN 7 / E1-PERF-4):** `AsyncStream`/`AsyncThrowingStream`
  continuation yield is synchronous and non-blocking.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `@discardableResult func yield(_ value: sending Element)
    -> AsyncStream<Element>.Continuation.YieldResult` - "returns to the caller
    immediately without blocking for any awaiting consumption." macOS 10.15+,
    iOS 13.0+. `AsyncThrowingStream.Continuation.yield` shares this non-blocking
    semantics. This is the primitive v1 invalidation yield is built on; combined
    with v1 `05` §11 ("without suspension") / `05` §14.4 (synchronous actor
    operations), registering `EnrichmentScheduler` as an additional continuation
    adds exactly one more non-blocking yield and NO `await` to the Authority's
    post-commit phase. Substantively verifies the non-blocking-delivery premise of
    `E1-PERF-4`; the residual narrows to CPU/memory scheduling not starving the
    system (a measurement).
  - **sourceUrl:** https://developer.apple.com/documentation/swift/asyncstream/continuation/yield(_:)

- **Claim (OPEN 6 / E1-SECURITY-1):** on-device `VNRecognizeTextRequest` on
  macOS 26 requires no additional TCC permission, privacy-usage string, or
  entitlement.
  - **Verdict:** OPEN.
  - **Correct statement:** On-device processing is VERIFIED; OCR is image-data
    based (`VNImageRequestHandler(data:)`) and accesses no protected resource
    (camera `AVCaptureDevice`, photo library `PHPhotoLibrary`) that requires TCC.
    No privacy-usage string/entitlement/required-reason code appears in fetched
    Vision docs, and `VNRecognizeTextRequest` is not a Privacy Manifest
    required-reason API category. Strongly implied, but no Apple document
    EXPLICITLY states the absence; per v1 `00` §5, the required OUTCOME (no
    TCC/entitlement for in-process image OCR) is stated and `E1-SECURITY-1`
    confirms at build/runtime on macOS 26 against `PrivacyInfo.xcprivacy`.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/recognizing-text-in-images

### Summary of OPEN retained gates (cycle 1)

- `E1-SECURITY-1` - no TCC/entitlement for on-device OCR (OPEN, strongly implied).
- `E1-COMPILE-3` - whether `import PDFKit` transitively links AppKit.framework at
  the binary level (OPEN; API-level AppKit-freeness VERIFIED).
- `E1-PLATFORM-4` - SwiftData additive-migration behavioral atomicity (OPEN;
  API existence VERIFIED).
- `E1-PLATFORM-UTI` (new) - the decodable image UTI set `VNImageRequestHandler`
  accepts on macOS 26 (OPEN; `init(data:)` existence VERIFIED, accepted formats
  not).

## Cycle 2 verified facts

Appended 2026-07-23 (IMPROVE cycle 2). Each entry: claim / verdict / correct
statement / sourceUrl. Verdicts are VERIFIED (MCP-fetched), REFUTED
(MCP-fetched and corrected), or OPEN (could not fetch; V2 proof gate retained).
Cycle 2 re-verified the Vision/PDFKit/SwiftData primitives with fresh
platform-compatibility citations and strengthened E1-SECURITY-1 and
E1-PLATFORM-4.

### Vision OCR (cycle 2)

- **Claim:** `VNRecognizeTextRequest` is available on macOS 26 (introduced
  macOS 10.15+), cross-platform, non-`Sendable` (NSObject subclass), and
  on-device.
  - **Verdict:** VERIFIED.
  - **Correct statement:** Platform compatibility confirms
    `VNRecognizeTextRequest` is introduced macOS 10.15 (iOS 13.0, iPadOS 13.0,
    Mac Catalyst 13.1, tvOS 13.0, visionOS 1.0), cross-platform (6 platforms),
    so present on macOS 26. The "Recognizing Text in Images" article confirms
    "all of Vision's processing happens on the user's device to enhance
    performance and user privacy." It is an Objective-C class (NSObject
    subclass), therefore non-`Sendable`, and must be confined to one actor
    (V2-01 `EnrichmentWorker`), mirroring v1's non-`Sendable` Fuse matcher.
    Strengthens facts 1/6 with a fresh platform-compatibility citation.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrecognizetextrequest

- **Claim:** `VNRecognizeTextRequestRevision3` (the revision V2-01 pins on
  macOS 26) is available macOS 13.0+ and is the only non-deprecated revision.
  - **Verdict:** VERIFIED.
  - **Correct statement:** Platform compatibility confirms
    `VNRecognizeTextRequestRevision3` is introduced macOS 13.0 (iOS 16.0,
    iPadOS 16.0, Mac Catalyst 16.0, tvOS 16.0, visionOS 1.0), cross-platform,
    so present on macOS 26. Cycle 1 verified it is the ONLY non-deprecated
    revision and that Revisions 1 and 2 are DEPRECATED; the platform-availability
    fetch this cycle independently confirms the macOS 13.0+ floor cited in
    `E1-PLATFORM-3`. The pin `request.revision = VNRecognizeTextRequestRevision3`
    is valid on macOS 26.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnrecognizetextrequestrevision3

- **Claim:** `VNImageRequestHandler` (macOS 10.13+) processes a single image via
  the synchronous `perform(_:)`; a supplied completion handler runs on a
  DIFFERENT thread/queue than the `perform(_:)` caller.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `class VNImageRequestHandler` is macOS 10.13+ (iOS
    11.0+), present on macOS 26. The "Detecting Objects in Still Images" sample
    states "Vision runs each request and executes its completion handler on its
    own thread" and "Even when Vision calls its completion handlers on a
    background thread, always dispatch UI calls ... to the main thread" - a
    second independent confirmation (in addition to the cycle-1
    `VNRequestCompletionHandler` doc) that the completion handler does NOT run on
    the `perform(_:)` caller's thread. Validates `E1-COMPILE-2`'s
    no-completion-handler path: construct via `init()` / `init(completionHandler:
    nil)`, call the synchronous blocking `perform(_:)`, read `request.results`
    synchronously after return on the `EnrichmentWorker`'s own thread.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnimagerequesthandler

- **Claim:** `VNImageRequestHandler.init(data:options:)` takes image `Data`; the
  data path accepts compressed image data broadly (JPEG and other compressed
  formats), and the exact decodable UTI set is not enumerated by Apple.
  - **Verdict:** VERIFIED (data-path broad; exact UTI set OPEN).
  - **Correct statement:** `init(data imageData: Data, options: [VNImageOption :
    Any] = [:])` (macOS 10.13+). Discussion: "The intended use cases of this type
    of initializer include compressed images and network downloads, where a
    client may receive a JPEG from a website or the cloud." The data path is for
    compressed image data broadly, NOT JPEG-only. The exact decodable UTI set
    (public.png, public.jpeg, public.tiff, com.compuserve.gif, HEIC,
    animated-GIF) is NOT enumerated in any accessible Vision doc; Vision decodes
    via ImageIO/CGImageSource internally, so the decodable set equals ImageIO's.
    The V2-01 §2.1 "ImageIO-decodable image UTIs" hedge is consistent.
    Strengthens `E1-PLATFORM-UTI`: JPEG confirmed, data path compressed-image-broad,
    exact UTI set remains a proof gate.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnimagerequesthandler/init(data:options:)

- **Claim:** Vision OCR is on-device (no network path); image bytes never leave
  the process.
  - **Verdict:** VERIFIED.
  - **Correct statement:** Re-verified: the "Recognizing Text in Images" article
    states "all of Vision's processing happens on the user's device to enhance
    performance and user privacy." Combined with `VNImageRequestHandler(data:)`
    processing in-memory image bytes, there is no network path and no cloud text
    service. This is the security premise of V2-01 §9 (on-device guarantee) and
    Record 6.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/recognizing-text-in-images

- **Claim:** `VNImageRequestHandler.perform(_:)` is synchronous, throwing, and
  blocking ("returns after all requests have either completed or failed");
  results read from each request after return.
  - **Verdict:** VERIFIED (re-affirmed cycle-1 fact 2).
  - **Correct statement:** `func perform(_ requests: [VNRequest]) throws` -
    "The function returns after all requests have either completed or failed."
    Blocking; individual request results/errors read from each request after
    return. macOS 10.13+. This is why OCR must run off the `HistoryAuthority`
    commit interval on the `EnrichmentWorker` actor (and off the cooperative
    pool per `E1-PERF-6`), never inline in a serialized commit.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnimagerequesthandler/perform(_:)

- **Claim:** `VNImageRequestHandler.init(data:)` accepts compressed image data
  (e.g., JPEG) directly; the handler defers to the system image decoder stack.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `init(data imageData: Data, options: [VNImageOption :
    Any] = [:])` - "Creates a handler to use for performing requests on an image
    in a data object. Image content is immutable." Discussion: compressed images
    and network downloads (JPEG from a website or cloud). Common compressed
    formats (JPEG) are accepted and the Effective-Content image representation
    bytes can be fed straight to Vision without an intermediate CGImage/ImageIO
    decode in the commit interval. The exact decodable UTI set (HEIC,
    animated-GIF, TIFF) is NOT enumerated; the handler defers to the system image
    decoder (ImageIO/CGImageSource). `E1-PLATFORM-UTI` remains OPEN on the exact
    set (fixture/runtime probe required), but the §2.1 "ImageIO-decodable" hedge
    is supported by the compressed-image intent statement.
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnimagerequesthandler/init(data:options:)

### Security and delivery (cycle 2)

- **Claim (`E1-SECURITY-1`):** on-device `VNRecognizeTextRequest` on macOS 26
  requires no additional TCC permission, privacy-usage string, or entitlement.
  - **Verdict:** OPEN (strengthened, not fully closed).
  - **Correct statement:** Three sub-findings substantiate it: (a) on-device
    processing VERIFIED ("all of Vision's processing happens on the user's
    device"); (b) `VNImageRequestHandler(data:)` processes image bytes already
    in memory and accesses no TCC-protected device resource (camera
    `AVCaptureDevice`, photo library `PHPhotoLibrary`); per WWDC23 "Integrate
    privacy into your development process", purpose strings are required for
    permission prompts to access device resources, and in-memory bytes are not a
    device resource; (c) `VNRecognizeTextRequest` is NOT a Privacy Manifest
    Required Reason API: the "Describing use of required reason API" article
    defines Required Reason APIs as APIs "misused to access device signals to try
    to identify the device or user, also known as fingerprinting"; on-device ML
    inference on in-memory image data is not a device-signal/fingerprinting API.
    The "Privacy manifest files" article states required-reason reporting applies
    "on iOS, iPadOS, tvOS, visionOS, and watchOS" - NOT macOS - so a macOS app is
    not in the required-reason reporting scope. No Apple document EXPLICITLY
    states the absence of a TCC prompt for on-device OCR, so `E1-SECURITY-1`
    (confirm against `PrivacyInfo.xcprivacy` on macOS 26) is retained, but the
    residual narrows to the explicit-absence statement.
  - **sourceUrl:** https://developer.apple.com/documentation/BundleResources/describing-use-of-required-reason-api

- **Claim:** The Privacy Manifest required-reason API category reporting
  requirement does not apply on macOS; it is documented for iOS, iPadOS, tvOS,
  visionOS, and watchOS only.
  - **Verdict:** VERIFIED.
  - **Correct statement:** The "Describing use of required reason API" article
    states the required-reason API reporting (`NSPrivacyAccessedAPITypes` in the
    privacy manifest) is required "on iOS, iPadOS, tvOS, visionOS, or watchOS" -
    macOS is NOT listed. The categories cover APIs "misused to access device
    signals to try to identify the device or user" (fingerprinting prevention).
    `VNRecognizeTextRequest` is an on-device OCR API processing provided image
    `Data` (`VNImageRequestHandler(data:)`) and accesses no protected device
    resource; it is not a fingerprinting/device-signal API. On macOS 26, on-device
    OCR requires no required-reason API reporting and no TCC permission for
    in-process image bytes. Advances `E1-SECURITY-1` from "OPEN, strongly
    implied" (cycle 1) to "CONFIRMED for the required-reason/TCC dimension";
    residual narrows to a build-time check that no macOS-specific usage
    string/entitlement is declared in `PrivacyInfo.xcprivacy`.
  - **sourceUrl:** https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api

- **Claim (`AsyncThrowingStream`):** `AsyncThrowingStream.Continuation.yield(_:)`
  is synchronous and returns to the caller immediately without blocking, like
  `AsyncStream.Continuation.yield`.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `@discardableResult func yield(_ value: sending Element)
    -> AsyncThrowingStream<Element, Failure>.Continuation.YieldResult` - "This can
    be called more than once and returns to the caller immediately without
    blocking for any awaiting consumption from the iteration." macOS 10.15+,
    iOS 13.0+. This DIRECTLY verifies (cycle 1 only INFERRED it from the
    `AsyncStream` variant) the `AsyncThrowingStream` variant that V2-01's
    synthetic re-query yield into the `EnrichmentScheduler`'s `inbox` stream uses.
    Resolves the `E1-PERF-4` inference gap: registering the scheduler as an
    additional post-commit continuation adds exactly one more non-blocking yield
    and NO `await` to the Authority's post-commit phase (`05` §11 "without
    suspension"). (Note: cycle 2 removed the synthetic observer re-query
    invalidation from V2-01; this non-blocking yield fact still governs the inbox
    yield to the scheduler.)
  - **sourceUrl:** https://developer.apple.com/documentation/swift/asyncthrowingstream/continuation/yield(_:)

- **Claim (`E1-PLATFORM-UTI`):** the eligible image UTI set that
  `VNImageRequestHandler(data:)` decodes on macOS 26 (including HEIC and
  animated-GIF handling).
  - **Verdict:** OPEN (strengthened).
  - **Correct statement:** The data initializer accepts "compressed image data ...
    held in memory" broadly (VERIFIED via `init(data:options:)` discussion and the
    Detecting-Objects-in-Still-Images sample), not JPEG-only. The specific
    decodable UTI set is NOT enumerated in any accessible Vision doc; Vision
    decodes via ImageIO/CGImageSource (which "reads most image file formats"), so
    the decodable set equals ImageIO's set, and the §2.1 "ImageIO-decodable" hedge
    is accurate. The proof gate `E1-PLATFORM-UTI` is retained to fixture-lock the
    verified set on macOS 26 (especially HEIC and animated-GIF frame handling).
  - **sourceUrl:** https://developer.apple.com/documentation/vision/vnimagerequesthandler/init(data:options:)

### SwiftData schema migration (cycle 2)

- **Claim:** `SchemaMigrationPlan` protocol describes schema evolution and
  migration between versions, and `ModelContainer.init(for:migrationPlan:configurations:)`
  opens a store with a migration plan.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `protocol SchemaMigrationPlan : SendableMetatype`
    (macOS 14.0+, iOS 17.0+) is "An interface for describing the evolution of a
    schema and how to migrate between specific versions." Its See Also lists three
    `ModelContainer.init(for:migrationPlan:configurations:)` overloads; the
    migration-plan initializer therefore exists and accepts a plan. NEW vs cycle
    1: cycle 1 only inferred the plan/init from `MigrationStage`; this directly
    fetches the protocol + confirms the container initializer.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/schemamigrationplan

- **Claim:** SwiftData performs automatic (lightweight) migrations of persisted
  data to keep it consistent with the model classes; a `SchemaMigrationPlan` is
  supplied only when changes exceed automatic-migration capabilities.
  - **Verdict:** VERIFIED.
  - **Correct statement:** The `ModelContainer` Overview states: "As your app's
    schema evolves, the container performs automatic migrations of the persisted
    model data so it remains consistent with the app's model classes. If the
    aggregate changes between two versions of your schema exceed the capabilities
    of automatic migrations, provide the container with a `SchemaMigrationPlan`
    to participate in those migrations." This is the behavioral prose (absent
    from the `MigrationStage` API page) confirming lightweight migration preserves
    existing persisted data; a purely additive new-`@Model`-table change
    (V2-01's `EnrichmentRow`/`EnrichmentConfigRow`) is within automatic/lightweight
    capabilities. Advances `E1-PLATFORM-4`: cycle 1 had API existence only with "NO
    behavioral prose confirming existing rows are preserved"; this is that
    behavioral prose.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/modelcontainer

- **Claim:** A SwiftData lightweight migration stage is the documented tool for
  additive schema changes and is intended to preserve the user's existing data.
  - **Verdict:** VERIFIED.
  - **Correct statement:** WWDC2025 session 291 ("SwiftData: Dive into inheritance
    and schema migration") demonstrates adding new model subclasses (an additive
    schema change) with a `MigrationStage.lightweight(fromVersion:toVersion:)`
    stage, and states the migration plan lets the app "migrate through the various
    iterations we shipped before, all while preserving the client's data." Custom
    (`MigrationStage.custom(fromVersion:toVersion:willMigrate:didMigrate:)`) stages
    are used ONLY for data transformation; the versioned-schema +
    `SchemaMigrationPlan` (ordered schemas in release order + ordered migration
    stages) pattern fed to the `ModelContainer` initializer is the documented
    migration path on iOS/macOS 26. Advances `E1-PLATFORM-4` from "API existence
    only" to "behavioral intent + API confirmed" for V2-01's additive case.
  - **sourceUrl:** https://developer.apple.com/videos/play/wwdc2025/291/

- **Claim:** `MigrationStage.lightweight` takes two `VersionedSchema`-conforming
  types; the sibling custom stage carries `willMigrate`/`didMigrate` blocks and is
  used for data transformation.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `case lightweight(fromVersion: any VersionedSchema.Type,
    toVersion: any VersionedSchema.Type)` (macOS 14.0+); sibling `case
    custom(fromVersion:toVersion:willMigrate:didMigrate:)`. Both arguments of the
    lightweight case must be `VersionedSchema`-conforming types. LOAD-BEARING for
    V2-01/M1: v1's `HistorySchemaV1` is a plain `Schema` *value* (`internal let
    v1Schema = Schema(...)`, `05` §3), NOT a `VersionedSchema` type, and is frozen.
    M1 therefore retrofits an additive `HistorySchemaV1: VersionedSchema` type
    (supplying `versionIdentifier` + the unchanged model set) to anchor the
    migration without modifying the frozen `v1Schema` value/rows - the WWDC
    session shows exactly this `versionIdentifier`+models pattern. Re-confirms
    cycle-1 fact 11 and adds the custom-stage sibling.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/migrationstage/lightweight(fromversion:toversion:)

- **Claim:** `VersionedSchema` is a `SendableMetatype` protocol requiring a
  version identifier and the model set, available macOS 14.0+.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `protocol VersionedSchema : SendableMetatype`
    (macOS 14.0+, iOS 17.0+, Swift 5.9+) - "An interface for describing a specific
    version of a schema, including the models it contains." Requires
    `versionIdentifier` (a `Schema.Version`) and the model set;
    `Schema.init(versionedSchema:)` builds a Schema from it. Re-confirms V2-facts.md
    fact 10 with the exact declaration; load-bearing for M1's additive
    `HistorySchemaV1: VersionedSchema` retrofit (`E1-PLATFORM-1`/Record 5).
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/versionedschema

### Summary of OPEN retained gates (cycle 2)

- `E1-SECURITY-1` - no TCC/entitlement for on-device OCR (OPEN; required-reason
  reporting confirmed NOT applicable on macOS, on-device VERIFIED; residual is the
  explicit-absence statement against `PrivacyInfo.xcprivacy`).
- `E1-COMPILE-3` - whether `import PDFKit` transitively links AppKit.framework at
  the binary level (OPEN; API-level AppKit-freeness VERIFIED).
- `E1-PLATFORM-4` - SwiftData additive-migration behavioral atomicity (OPEN;
  API existence + automatic-migration behavioral prose + WWDC2025/291
  lightweight-intent VERIFIED; scaffold proof retained).
- `E1-PLATFORM-UTI` - the decodable image UTI set `VNImageRequestHandler`
  accepts on macOS 26 (OPEN; `init(data:)` compressed-image-broad VERIFIED, exact
  UTI set not).

## Cycle 3 verified facts

Appended 2026-07-23 (IMPROVE cycle 3, V2-02 Retention Expansion). Each entry:
claim / verdict / correct statement / sourceUrl. Verdicts are VERIFIED
(MCP-fetched), REFUTED (MCP-fetched and corrected), or OPEN (could not fetch; V2
proof gate retained). Cycle 3 re-verified the SwiftData migration primitive that
V2-02's additive `RetentionExpansionConfigRow` depends on, and recorded the
V2-02-specific platform questions (byte-count fact loading, pruned-blob
integrity) as OPEN gates.

### SwiftData additive migration (cycle 3)

- **Claim:** `MigrationStage.lightweight(fromVersion:toVersion:)` is the additive
  schema-migration case and is available on macOS 26.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `case lightweight(fromVersion: any VersionedSchema.Type,
    toVersion: any VersionedSchema.Type)` - macOS 14.0+ (iOS 17.0+, iPadOS 17.0+,
    Mac Catalyst 17.0+, tvOS 17.0+, visionOS 1.0+, watchOS 10.0+, Swift 5.9+),
    so present on macOS 26. Both arguments must be `VersionedSchema`-conforming
    *types*. LOAD-BEARING for V2-02: adding `RetentionExpansionConfigRow` to
    `HistorySchemaV2` is a purely additive change (no v1 model gains a column;
    the v1 count policy stays on `LastChangePositionRow.maximumUnpinnedItems`,
    `05` §3.2), so the V1->V2 migration is a single lightweight stage with no v1
    row/column rewritten. Re-confirms cycle-1/2 facts with a fresh
    platform-availability citation; grounds V2-02 `RET-PLATFORM-1` (Record 5).
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/migrationstage/lightweight(fromversion:toversion:)

- **Claim:** A `MigrationStage.custom(fromVersion:toVersion:willMigrate:
  didMigrate:)` sibling exists for data transformation; V2-02 does not need it.
  - **Verdict:** VERIFIED (existence via See Also).
  - **Correct statement:** The `lightweight` page's See Also lists
    `custom(fromVersion:toVersion:willMigrate:didMigrate:)` (macOS 14.0+),
    used for data transformation. V2-02 uses **lightweight only**: the new
    `RetentionExpansionConfigRow` table is empty on a migrated v1 store and is
    bootstrapped (all policies disabled) by `SwiftDataHistory.open` (V2-02 §3.3)
    - no data transformation is required, so no custom stage. Recorded for
    completeness so a future V2-02 change that backfills byte-summary columns
    would know to add a custom stage.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/migrationstage/lightweight(fromversion:toversion:)

### Foundation age arithmetic (cycle 3)

- **Claim:** R1 age retention computes `lastCopiedAt < (now - maxAge)` using
  Foundation `Date` and `TimeInterval`, with no macOS-26-specific API.
  - **Verdict:** VERIFIED (Foundation, trivially available).
  - **Correct statement:** `Date` arithmetic uses `TimeInterval` (a `Double`
    typealias, seconds); `Date.addingTimeInterval(_:)` and `<` comparison are
    Foundation APIs available on every macOS version (v1 already uses `Date`
    throughout - `02` §3.1 `CopyOccurrence`, `03a` §4; `TimeInterval` is
    Foundation's `Double` typealias used implicitly by `Date` arithmetic, so no
    new framework import is required). R1 reads the `lastCopiedAt` already
    present in the v1 retention inventory (`02` §5.1 `RetainedItemSummary`) -
    R1 needs **no new fact data** and no new framework import. No proof gate
    required for the arithmetic itself; the clock-seam outcome (Storage supplies
    `now`, Domain mints no `Date()`, `02` §1) is stated in V2-02 §6.4.
  - **sourceUrl:** https://developer.apple.com/documentation/foundation/date
    (MCP-fetched: documents `Date` as "A specific point in time, independent of
    any calendar or time zone," with `TimeInterval` in its See Also and a
    Date-arithmetic API set covering `addingTimeInterval(_:)` and comparison.)

## OPEN questions added (cycle 3, V2-02)

1. **Byte-count fact loading without content decode (`RET-PLATFORM-2`).** R2
   needs per-item total bytes; `canonicalBytes` is cheap (sum of
   `SignatureBlobV1.entry.byteCount` over the inline `canonicalSignatureBlob`,
   `05` §4 - not `.externalStorage`, `05` §3.1). `revisionBytes`/`revisionCount`
   require reading the `.externalStorage` `revisionStateBlob`; whether SwiftData
   can provide the blob's byte length / revision count without faulting content
   is **not** guaranteed by documented API. No MCP source states the faulting
   behavior of `.externalStorage` `Data.count` / a fetch-attribute for blob size.
   Required OUTCOME (V2-02 §3.2, Record 3): a *complete* per-item byte summary
   on the planning path; a bounded per-item decode is acceptable (retention
   planning is a mutation-planning path, not a scalar read governed by Part VI
   §7.5). Assigned proof gate `RET-PLATFORM-2`.

2. **Pruned `RevisionStateBlobV1` round-trip integrity (`RET-PLATFORM-3`).** R3
   rewrites `revisionStateBlob` with a shorter revision list, same
   `activeRevisionID`, `formatVersion == 1`. The v1 codec (`05` §4) and Part VI
   §7.4 already prove `RevisionStateBlobV1` round trips and rejects corruption;
   the V2-02-specific confirmation is that a *pruned* blob (fewer revisions
   than were originally written) passes every decode check and preserves D3
   (active ID names a present revision). Not a new API question; a V2 scaffold
   proof. Assigned proof gate `RET-PLATFORM-3`.

### Summary of OPEN retained gates (cycle 3, V2-02)

- `RET-PLATFORM-2` - byte-count fact loading without Canonical/revision content
  decode on the retention planning path (OPEN; `canonicalBytes` cheap via
  signature blob VERIFIED; `revisionBytes`/`revisionCount` faulting behavior
  OPEN).
- `RET-PLATFORM-3` - pruned `RevisionStateBlobV1` round-trip + D3-preservation
  (OPEN; v1 codec proofs cover the un-pruned case; pruned-case scaffold proof
  retained).

## Cycle 3 verified facts — addendum (retention age/transaction primitives)

Appended 2026-07-23 (this cycle). A focused addendum to the cycle-3 V2-02 record,
filling MCP-verified facts the V2-02 doc depends on that the cycle-3 section
above did not fetch: the `Date` timezone-independence guarantee that grounds R1's
locale-independent age, the direct `Date.addingTimeInterval` citation, the
`Calendar` locale/timezone hazard that rules out calendar-day age, and the
`ModelContext.transaction(block:)` atomic-save re-verification that V2-02's
in-commit revision-blob rewrite (`RET-PLATFORM-3`, V2-02 §5.3/§6.3) relies on.
Append-only; does not modify the cycle-3 entries above.

### Foundation Date / Calendar (cycle 3 addendum)

- **Claim:** `Date` is timezone-independent, so R1 age computed from
  `Date.timeIntervalSince` / `Date` comparison is locale/timezone-independent and
  pure (D16, D9).
  - **Verdict:** VERIFIED.
  - **Correct statement:** `struct Date` is "A specific point in time,
    independent of any calendar or time zone" - "Date values represent a time
    interval relative to an absolute reference date." Cross-platform (iOS 8.0+,
    macOS 10.10+, …). LOAD-BEARING for V2-02 R1 (`now − maxAge` / age comparison):
    because `Date` is timezone-independent, R1 victim selection by
    `lastCopiedAt` age does not vary by the user's locale or timezone, and is a
    pure function of `(lastCopiedAt, evaluatedAt, maxAgeSeconds)`. `Date` is
    `Sendable` (v1 already treats it so: `CopyOccurrence: Sendable` holds `Date`
    fields, `02` §3.1), so `evaluatedAt: Date` crosses into the pure Domain.
  - **sourceUrl:** https://developer.apple.com/documentation/foundation/date

- **Claim:** `Date.addingTimeInterval(_:)` creates a date offset by seconds.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `func addingTimeInterval(_ timeInterval: TimeInterval)
    -> Date` - "Creates a new date value by adding a time interval to this
    date"; `timeInterval` is "in seconds." macOS 10.10+, cross-platform. Confirms
    the R1 `now − maxAge` computation primitive (`evaluatedAt.addingTimeInterval(
    -Double(maxAgeSeconds))`); `Date` comparison (`<`) handles the threshold test.
  - **sourceUrl:** https://developer.apple.com/documentation/foundation/date/addingtimeinterval(_:)

- **Claim:** `Calendar`-based day-age would be locale/timezone-dependent; R1
  deliberately uses monotone seconds to avoid this.
  - **Verdict:** VERIFIED (hazard documented).
  - **Correct statement:** `struct Calendar` "encapsulates information about
    systems of reckoning time" and provides calendrical computations via
    `DateComponents`/`TimeZone` (its See Also). Calendar-day-based age
    (`Calendar.dateComponents(...)`) is locale/timezone-dependent (the user's
    `Calendar.current`/`TimeZone.current` affect day boundaries), which would
    make R1 victim selection non-deterministic across locales - violating D16/D9
    (pure/deterministic planning). V2-02 R1 therefore uses monotone
    `TimeInterval`-second age against the timezone-independent `Date`, not
    calendar-day age. Records *why* V2-02 R1 is seconds-based (a design
    justification, not a new API claim).
  - **sourceUrl:** https://developer.apple.com/documentation/foundation/calendar

- **Claim:** `Date.timeIntervalSince(_:)` returns the seconds between two dates
  (the natural R1 age primitive).
  - **Verdict:** OPEN (direct URL 404; established Foundation).
  - **Correct statement:** The direct symbol URL
    `…/documentation/foundation/date/timeinterval(_:)` returned 404 (the method's
    docs path differs from the fetched form). `Date` is documented as providing
    "calculating the time interval between two dates" (overview), and the
    sibling API `addingTimeInterval(_:)` (VERIFIED above) takes a `TimeInterval`
    in seconds, so `Date.timeIntervalSince(_:) -> TimeInterval` (seconds between
    receiver and argument, positive when the receiver is later) is the
    established Foundation primitive. Treat as the R1 age primitive; a light
    compile gate (V2-02 `RET-COMPILE-1`) confirms the exact signature on the
    macOS 26 SDK. Not a behavioral risk (well-established Foundation).
  - **sourceUrl:** https://developer.apple.com/documentation/foundation/date

### SwiftData transaction atomic-save (cycle 3 addendum)

- **Claim:** `ModelContext.transaction(block:)` is the atomic save boundary V2-02
  relies on for in-commit revision-blob rewrite and projection writes.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `func transaction(block: () throws -> Void) throws` -
    "Runs the provided closure, and once it finishes, writes any pending
    inserts, changes, and deletes to the persistent storage." macOS 14.0+ (iOS
    17.0+, …), so present on macOS 26. LOAD-BEARING for V2-02: R3's
    `revisionStateBlob` shrink-rewrite (V2-02 §5.3/§6.3, `RET-PLATFORM-3`) and any
    in-commit retention/projection write occur inside this closure, so a closure
    failure commits nothing (`05` §10 "Closure failure commits nothing") and a
    closure success is the save boundary (no extra `save()`). Re-confirms v1's
    `05` §10/§18 transaction anchor with a fresh platform-availability citation;
    grounds V2-02 `RET-PLATFORM-3` (and the atomic-deletion security claim,
    V2-02 §9 `RET-SECURITY-1`).
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/modelcontext/transaction(block:)

### Summary of OPEN retained gates (cycle 3 addendum)

- `RET-PLATFORM-DATE` (new, light) - confirm `Date.timeIntervalSince(_:)` exact
  signature on the macOS 26 SDK (OPEN; direct URL 404, established Foundation;
  folded into V2-02 `RET-COMPILE-1` as a light compile check). No behavioral
  risk.
## Cycle 4 verified facts

Appended 2026-07-23 (IMPROVE cycle 4, V2-02 Retention Expansion). Each entry:
claim / verdict / correct statement / sourceUrl. Verdicts are VERIFIED
(MCP-fetched), REFUTED (MCP-fetched and corrected), or OPEN (could not fetch; V2
proof gate retained). Cycle 4 verified the SwiftData fetch/attribute/delete
surface V2-02 R2 byte-summary loading and R1/R2 retirement depend on, the
`@Attribute(.unique)` / `@Model` macro semantics, and the Foundation `Date.now`
/ `Date.timeIntervalSince(_:)` primitives V2-02 R1 relies on.

### SwiftData attribute and model macros (cycle 4)

- **Claim:** V2-02 §3.3 uses `@Attribute(.unique) var key: String` on
  `RetentionExpansionConfigRow` to enforce a singleton (always
  "retention-expansion"); `.unique` is a valid SwiftData attribute option
  available on macOS 26.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `@attached(peer) macro Attribute(_ options:
    Schema.Attribute.Option..., originalName: String? = nil, hashModifier:
    String? = nil)` (macOS 14.0+, iOS 17.0+, Swift 5.9+; present on macOS 26).
    The official example is `@Attribute(.unique) var sourceURL: URL`, and the
    framework-symbol search + the `externalStorage` See-Also confirm `static var
    unique: Schema.Attribute.Option` exists as a documented option. The
    `@Attribute` Overview states it is for specifying that "an attribute's value
    is unique across all instances of that model," so the singleton-enforcement
    intent is documented. Note: a SEPARATE, NEWER `#Unique<T>([PartialKeyPath<T>]...)`
    macro (model-level compound constraints, macOS 15.0+) also exists; V2-02
    correctly uses the older, broader-availability property-level
    `@Attribute(.unique)` form (macOS 14.0+). No V2 proof gate needed for the
    attribute itself; conflict-resolution semantics on a duplicate insert are
    sidestepped by the create-if-absent `open` pattern under the single-writer
    HistoryAuthority.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/attribute(_:originalname:hashmodifier:)

- **Claim:** V2-02 §3.2/RET-PLATFORM-2 reference the v1 `.externalStorage`
  `revisionStateBlob`; `.externalStorage` is a valid SwiftData attribute option
  available on macOS 26.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `static var externalStorage: Schema.Attribute.Option
    { get }` - "Stores the property's value as binary data adjacent to the model
    storage." macOS 14.0+ (iOS 17.0+, Swift 5.9+), present on macOS 26. Confirmed
    both via `search_framework_symbols` (direct hit) and the
    `Schema.Attribute.Option` related-APIs listing (siblings: allowsCloudEncryption,
    preserveValueOnDeletion, spotlight, unique, transformable(by:), ephemeral,
    codable). So the v1 `.externalStorage revisionStateBlob` and the V2-02 R3
    rewrite of that same column are backed by a real, documented attribute option.
    The FAULTING behavior (whether reading the blob's `.count` / byte length
    materializes the content) is NOT documented on this page and remains OPEN
    (RET-PLATFORM-2) - tightened by the propertiesToFetch finding below.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage

- **Claim:** V2-02 §3.3 `RetentionExpansionConfigRow` is an `@Model` class;
  §6.2 claims `SwiftDataHistory: Sendable` remains derived without
  `@unchecked Sendable` and that "No `@Model`, `ModelContext`, or
  `PersistentIdentifier` crosses an actor boundary (`01` §6 boundary rule)."
  - **Verdict:** VERIFIED.
  - **Correct statement:** `@attached(member, conformances: Observable,
    PersistentModel, Sendable, ...) @attached(extension, conformances:
    Observable, PersistentModel, Sendable) macro Model()` (macOS 14.0+, present
    on macOS 26). CRITICAL: the `@Model` macro CONFERs `Sendable` (listed
    explicitly in its attached-conformances declaration). Therefore @Model
    classes ARE Sendable at the compiler level, which means the V2-02 §6.2
    statement "No `@Model` ... crosses an actor boundary" is a v1 DESIGN
    discipline (`01` §6 no-model-leakage rule, `00` §3.4), NOT a Swift 6
    compiler-enforced Sendable constraint - the compiler would not block such a
    crossing. @Model classes carry mutable `Observable` state, so their nominal
    `Sendable` conformance is sound only under SwiftData's context-mediated access
    discipline, which is exactly why v1 confines @Model/ModelContext to
    HistoryStorage/HistoryAuthority and V2-02 passes only immutable `Sendable`
    fact values (RetainedItemSummary/RetentionExpansionFacts) across the
    boundary. The `SwiftDataHistory: Sendable`-derived claim holds because V2-02
    adds NO @Model stored field to `SwiftDataHistory`
    (RetentionExpansionConfigRow is fetched on demand inside the Authority
    interval, not held as a field). The doc's isolation reasoning is correct and
    necessary; this verification makes explicit that it is a design rule, not a
    compiler guarantee.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/model()

### SwiftData fetch surface (cycle 4)

- **Claim:** V2-02 §13 lists `FetchDescriptor.propertiesToFetch` as a "candidate
  scalar-projection mechanism for byte-summary fact loading (RET-PLATFORM-2)."
  - **Verdict:** CONFIRMED (existence); REFUTED as a size-without-content
    mechanism.
  - **Correct statement:** `var propertiesToFetch: [PartialKeyPath<T>]`
    (macOS 14.0+, iOS 17.0+, Swift 5.9+; present on macOS 26). Discussion: "When
    the fetch runs, it'll return values for only the specified key paths ... if
    you subsequently access a nonfetched attribute, you'll incur the additional
    overhead of fetching the corresponding value from the persistent storage."
    MECHANISM CORRECTION: this is an ATTRIBUTE-SUBSET mechanism (it fetches
    whole attribute VALUES for the specified key paths and lazily faults the
    rest on access), NOT a computed-scalar projection. It cannot deliver a blob
    byte-count or revision-count scalar without first materializing the
    `.externalStorage` `Data` blob (and `Data.count` requires the bytes). So the
    §13 "scalar-projection mechanism" framing is imprecise: propertiesToFetch
    can avoid loading UNRELATED attributes (e.g., fetch only revisionStateBlob,
    skip canonicalSignatureBlob), but it cannot yield a byte-length/revision-count
    scalar without materializing/decoding the blob. This TIGHTENS RET-PLATFORM-2:
    the doc's already-permitted "bounded per-item decode" path (§3.2/Record 3) is
    the REQUIRED mechanism for revisionBytes/revisionCount, not merely one
    option; propertiesToFetch alone does not achieve the no-blob-decode outcome.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/fetchdescriptor/propertiestofetch

- **Claim:** V2-02 §3.3 annotates `var storageMaxBytes: Int // Int64 on macOS;
  holds the 5,000 x 128 MiB worst case`, asserting SwiftData persists `Int` as
  64-bit so the budget field can represent up to 5,000 x 128 MiB.
  - **Verdict:** VERIFIED (`@Model` macro existence, MCP-fetched); the integer
    bit-width sub-claim is a design justification established by Swift/SQLite
    semantics, NOT MCP-fetched - the cited `@Model()` page documents macro
    conformance synthesis (`PersistentModel`/`Observable`/`Sendable`), not
    integer storage bit-width.
  - **Correct statement:** This is a Swift-language + SQLite guarantee, not a
    SwiftData-specific documented claim. On 64-bit macOS, Swift's `Int` is
    `Int64` (max ~9.2 x 10^18); SwiftData persists `Int` via SQLite `INTEGER`
    (64-bit). The worst case 5,000 x (128 MiB canonical + 256 MiB revisions) =
    ~1.83 TiB fits comfortably in Int64 but would OVERFLOW Int32 (max ~2.1 x
    10^9), so the 64-bit annotation is load-bearing for correctness and holds.
    No Apple document explicitly states SwiftData's integer storage bit-width;
    it is established by Swift/SQLite semantics. Low-risk; no V2 proof gate
    required, though the §3.3 comment's "Int64 on macOS" is more precisely "Int
    is Int64 on 64-bit macOS, persisted as SQLite INTEGER."
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/model()
    (establishes the `@Model` macro that backs `RetentionExpansionConfigRow`;
    the integer-storage bit-width is established by Swift/SQLite semantics,
    not by this page.)

- **Claim:** V2-02 §6.1 claims "No new framework import is required (V2-02 uses
  only Foundation + the SwiftData already imported in HistoryStorage, `01` §8);
  the import gate (`01` §9) is unchanged (contrast V2-01, which added
  Vision/PDFKit)."
  - **Verdict:** VERIFIED.
  - **Correct statement:** CONFIRMED by enumeration of every platform API V2-02
    touches: `@Model` (SwiftData), `@Attribute`/`Schema.Attribute.Option` incl.
    `.unique`/`.externalStorage` (SwiftData), `MigrationStage.lightweight`/`.custom`
    (SwiftData, VERIFIED cycles 1-3), `ModelContext.transaction(block:)`
    (SwiftData, VERIFIED cycle-3 addendum), `FetchDescriptor.propertiesToFetch`
    (SwiftData, VERIFIED this cycle), and Foundation `Date`/`addingTimeInterval`/
    `timeIntervalSince`/`Calendar`/`TimeInterval` (VERIFIED cycle-3 addendum +
    this cycle). All are within Foundation + SwiftData, both already imported per
    v1 `01` §8. No Vision/PDFKit/AppKit/CoreML import is introduced (contrast
    V2-01). The v1 import gate (`01` §9) is therefore unchanged. No gate needed
    beyond RET-COMPILE-1's compile/dependency check.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/model()

- **Claim:** Cycle-3 VERIFIED `ModelContext.transaction(block:)` (macOS 14.0+,
  "writes pending inserts/changes/deletes after closure") as the atomic-save
  boundary V2-02 relies on for in-commit revision-blob rewrite (RET-PLATFORM-3)
  and atomic deletion (RET-SECURITY-1).
  - **Verdict:** VERIFIED (re-affirmed).
  - **Correct statement:** Re-affirmed (not re-fetched): the cycle-3-addendum
    VERIFIED fact stands - `func transaction(block: () throws -> Void) throws`,
    macOS 14.0+, present on macOS 26, "Runs the provided closure, and once it
    finishes, writes any pending inserts, changes, and deletes to the persistent
    storage." This is load-bearing for V2-02 R3's `revisionStateBlob` shrink-
    rewrite (§5.3/§6.3, RET-PLATFORM-3) and the atomic-deletion security claim
    (§9, RET-SECURITY-1): closure failure commits nothing (v1 `05` §10), closure
    success is the save boundary (no extra `save()`). The propertiesToFetch
    lazy-fault-on-access semantics VERIFIED this cycle corroborate the broader
    SwiftData faulting model that RET-PLATFORM-2 rests on. No change to the gate
    status.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/modelcontext/transaction(block:)

- **Claim:** FetchDescriptor is the SwiftData fetch-criteria type carrying
  predicate, sort order, and limits; available on macOS 26.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `struct FetchDescriptor<T> where T : PersistentModel`
    - "describes the criteria, sort order, and any additional configuration to
    use when performing a fetch." macOS 14.0+ (iOS 17.0+, Swift 5.9+),
    cross-platform (7 platforms), so present on macOS 26. Configurable properties
    include `predicate: Predicate<T>?`, `sortBy: [SortDescriptor<T>]`,
    `fetchLimit: Int?`, `fetchOffset`, `includePendingChanges`,
    `propertiesToFetch: [PartialKeyPath<T>]`, and
    `relationshipKeyPathsForPrefetching`. LOAD-BEARING for V2-02: the
    RetentionExpansionFacts inventory loads "every retained item exactly once"
    via a FetchDescriptor on `HistoryItemRow` (v1's fact-load path, 05 §7.1);
    R1/R2 victim ordering (lastCopiedAt ascending, id ascending, 02 §12) maps to
    `sortBy`.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/fetchdescriptor

- **Claim:** FetchDescriptor.propertiesToFetch can project an external blob's
  byte length without materializing the blob content (the RET-PLATFORM-2
  candidate mechanism cited in V2-02 §13).
  - **Verdict:** REFUTED.
  - **Correct statement:** `var propertiesToFetch: [PartialKeyPath<T>]` - "The
    specific subset of attributes to fetch if you don't require them all."
    Discussion: "When the fetch runs, it'll return values for only the specified
    key paths... However, if you subsequently access a nonfetched attribute,
    you'll incur the additional overhead of fetching the corresponding value from
    the persistent storage." Default empty array. macOS 14.0+. propertiesToFetch
    fetches attribute VALUES (including a `Data` blob), not a derived size:
    including `\.revisionStateBlob` materializes the external blob; omitting it
    means any later `.count` access faults it. There is NO documented spelling
    that returns an `.externalStorage` blob's byte length without its content.
    The V2-02 §13 reference to propertiesToFetch as a "candidate scalar-projection
    mechanism for byte-summary fact loading" is therefore not a verified
    solution; RET-PLATFORM-2's required OUTCOME (complete per-item byte summary)
    falls back to a bounded per-item decode or a maintained projection.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/fetchdescriptor/propertiestofetch

- **Claim:** FetchDescriptor.fetchLimit / sortBy / predicate have the exact
  signatures V2-02 R1/R2 victim ordering and bounded fetch rely on.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `var fetchLimit: Int?` (default nil; "The maximum
    number of models the fetch can return"); `var sortBy: [SortDescriptor<T>]`
    ("The fetch applies the sort descriptors in the same order as they appear in
    the array"; default is the init argument); `var predicate: Predicate<T>?`
    (nil returns all models of the type). All macOS 14.0+, cross-platform.
    LOAD-BEARING for V2-02 §4: R1/R2 victim selection is oldest-first
    (`lastCopiedAt ascending, id ascending`, 02 §12) expressible as `sortBy`; the
    projected post-primary inventory (§3.2) is bounded by the v1 hard
    retained-item count (<=5,000, 06 §2) not by fetchLimit, but
    fetchLimit/fetchOffset remain available for the bounded R3 full-sweep "only
    items exceeding the threshold" (V2-02 §4.4, RET-PERF-2).
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/fetchdescriptor/fetchlimit

- **Claim:** ModelContext.fetch(_:) returns the array of hydrated models matching
  a descriptor (full attribute materialization).
  - **Verdict:** VERIFIED.
  - **Correct statement:** `func fetch<T>(_ descriptor: FetchDescriptor<T>)
    throws -> [T] where T : PersistentModel` - "Returns an array of typed models
    that match the criteria of the specified fetch descriptor." Empty array if
    none match. macOS 14.0+. LOAD-BEARING for RET-PLATFORM-2: a plain `fetch`
    hydrates each `HistoryItemRow` including its `.externalStorage`
    `canonicalBlob`/`revisionStateBlob` (05 §3.1) on attribute access; this is
    the full-materialization path and the cost ceiling for the R2 byte-summary
    load. v1's scalar read isolation (Part VI §7.5) already constrains this on
    the recent/search path; V2-02's planning path is a mutation-planning path
    (05 §7.1 candidate-decode analogue), not a scalar read governed by §7.5.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/modelcontext/fetch(_:)

- **Claim:** ModelContext.fetchCount(_:) returns a row count without fetching
  models; it cannot yield byte totals.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `func fetchCount<T>(_ descriptor: FetchDescriptor<T>)
    throws -> Int where T : PersistentModel` - "determine the number of models
    that match some criteria without the overhead of fetching the models
    themselves." macOS 14.0+. Substantiates RET-PLATFORM-2's OPEN status:
    fetchCount gives item COUNTS only (usable for R3 `revisionCount`? no - it
    counts rows of a model type, not revisions within a blob), never byte
    lengths. There is no SwiftData aggregate/sum fetch in the ModelContext API
    surface (overview lists fetch/fetchCount/fetchIdentifiers/enumerate only) -
    so no sum-of-byte-counts-without-materialization path exists either.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/modelcontext/fetchcount(_:)

- **Claim:** ModelContext.fetchIdentifiers(_:) returns persistent identifiers
  without the models' associated data; it cannot yield attribute values or byte
  lengths.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `func fetchIdentifiers<T>(_ descriptor:
    FetchDescriptor<T>) throws -> [PersistentIdentifier] where T :
    PersistentModel` - returns identifiers "where each identifier represents a
    single model that satisfies the criteria." ModelContext overview: use it when
    you "don't require all of the associated data." macOS 14.0+. Substantiates
    RET-PLATFORM-2: this is the lightest fetch (identifiers only, no attribute
    values), so it cannot supply `canonicalBytes`/`revisionBytes`. Combined with
    fetchCount (counts) and propertiesToFetch (materializes values), the three
    lightweight fetch primitives confirm no documented "blob size without
    content" API exists.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/modelcontext/fetchidentifiers(_:)

- **Claim:** ModelContext.enumerate(_:batchSize:allowEscapingMutations:block:) is
  the bounded per-model enumeration primitive for RET-PLATFORM-2's per-item
  decode fallback.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `func enumerate<T>(_ fetch: FetchDescriptor<T>,
    batchSize: Int = 5000, allowEscapingMutations: Bool = false, block: (T)
    throws -> Void) throws where T : PersistentModel` - "Runs a closure for each
    model that matches the criteria." Default `batchSize` is 5000 (exactly the v1
    hard retained-item bound, 06 §2). macOS 14.0+. LOAD-BEARING for
    RET-PLATFORM-2: the block receives a hydrated `T`, so accessing
    `revisionStateBlob` materializes that one item's external blob - the per-item
    decode cost is bounded and streaming (not all-at-once), matching V2-02 §4.4
    "decodes revision blobs only for items exceeding the threshold (bounded;
    typically few)." `allowEscapingMutations` defaults false, consistent with v1
    isolation (no mutation escapes the context, 01 §6). This is the natural
    primitive for the bounded-decode fallback.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/modelcontext/enumerate(_:batchsize:allowescapingmutations:block:)

- **Claim:** ModelContext.delete(_:) removes a model during the next save (atomic
  within a transaction).
  - **Verdict:** VERIFIED.
  - **Correct statement:** `func delete<T>(_ model: T) where T : PersistentModel`
    - "Removes the specified model from the persistent storage during the next
    save operation." Discussion: "When the context nexts commits its changes,
    SwiftData removes the model... If the model is new and in an unsaved state,
    the context simply discards it." macOS 14.0+. LOAD-BEARING for V2-02
    RET-SECURITY-1 / R1/R2 retirement: a delete is pending until the enclosing
    `ModelContext.transaction(block:)` closure completes (cycle-3 addendum
    verified transaction "writes pending inserts/changes/deletes after closure"),
    so R1/R2 item retirement is atomic with the History Commit - a receipt means
    the deletion is durable; closure failure commits nothing (05 §10).
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/modelcontext/delete(_:)

- **Claim:** ModelContext.delete(model:where:includeSubclasses:) is the batch-
  retirement primitive for R1/R2 multi-item retirement in one transaction.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `func delete<T>(model: T.Type, where predicate:
    Predicate<T>? = nil, includeSubclasses: Bool = true) throws where T :
    PersistentModel` - "Removes each model satisfying the given predicate from
    the persistent storage during the next save operation." macOS 14.0+.
    LOAD-BEARING for V2-02 §4: R1/R2 may retire multiple oldest eligible
    unpinned items in one commit; this batch delete (within the
    `transaction(block:)` closure) is the natural stamping primitive alongside
    v1's `.delete` stamping (05 §9). v1 already uses delete stamping, so this is
    v1-established, not a new V2-02 API; recorded so the V2-02 retirement path
    can reuse the batch form for multi-victim commits.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/modelcontext/delete(model:where:includesubclasses:)

- **Claim:** @Attribute(.externalStorage) stores a SwiftData model property's data
  externally (out-of-line in the store package); v1 applies it to canonicalBlob
  and revisionStateBlob but NOT to canonicalSignatureBlob.
  - **Verdict:** VERIFIED.
  - **Correct statement:** WWDC2023 "Build an app with SwiftData" (session 10154)
    transcript: "if you mark some properties of a SwiftData model with the
    externalStorage attribute, all the externally stored items will be a part of
    the document package." This confirms `.externalStorage` stores the property's
    data out-of-line (as a separate item in the store package), distinct from
    inline attribute storage. GROUNDED against v1 schema `05` §3.1
    `HistoryItemRow`: `@Attribute(.externalStorage) var canonicalBlob: Data` and
    `@Attribute(.externalStorage) var revisionStateBlob: Data`, while
    `var canonicalSignatureBlob: Data` has NO `.externalStorage` attribute
    (inline). This validates V2-02 §3.2's RET-PLATFORM-2 split: `canonicalBytes`
    is cheap (sum of `StoredSignatureEntryV1.byteCount` over the INLINE
    `canonicalSignatureBlob`, no external fault), whereas
    `revisionBytes`/`revisionCount` require the EXTERNAL `revisionStateBlob`.
    NOTE: the `@Attribute` macro's canonical documentation URL is unfetchable via
    MCP (both /swiftdata/attribute and /swiftdata/attribute(_:) return 404); the
    `.externalStorage` semantics are confirmed via the WWDC transcript + v1 schema
    usage, with the macro spelling a light compile check (RET-COMPILE-1).
  - **sourceUrl:** https://developer.apple.com/videos/play/wwdc2023/10154/

### RET-PLATFORM-2 resolution (cycle 4)

- **Claim:** RET-PLATFORM-2 (byte-count fact loading): SwiftData provides NO
  documented API to obtain an `.externalStorage` blob's byte length without
  materializing its content.
  - **Verdict:** OPEN (substantively resolved as "no such API documented").
  - **Correct statement:** Verified the complete lightweight-fetch surface:
    `fetch(_:)` hydrates (materializes blob Data); `fetchCount(_:)` returns row
    counts (not bytes); `fetchIdentifiers(_:)` returns identifiers only (no
    attribute values); `enumerate(_:batchSize:allowEscapingMutations:block:)`
    hydrates per model; `FetchDescriptor.propertiesToFetch` fetches attribute
    VALUES and explicitly faults non-fetched attributes on access ("you'll incur
    the additional overhead of fetching the corresponding value from the
    persistent storage"). No SwiftData aggregate/sum projection exists in the
    ModelContext API. Therefore the RET-PLATFORM-2 required OUTCOME (a complete
    per-item byte summary on the planning path, V2-02 §3.2 Record 3) cannot be
    met by a documented "size-only" API; the design's stated fallback - a bounded
    per-item decode of the external `revisionStateBlob` (a mutation-planning
    path, not a scalar read governed by Part VI §7.5) - is the verified path, OR
    a maintained in-commit byte projection (computed at stamp time from the
    already-in-memory blob `.count`) sidesteps the faulting question entirely.
    RET-PLATFORM-2 retained as the scaffold proof gate; the bounded-decode
    acceptability is grounded.
  - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/modelcontext

### Foundation Date / clock (cycle 4)

- **Claim:** V2-02 R1 age retention uses `Date.timeIntervalSince(_:)` as the
  natural age primitive (the cycle-3-addendum OPEN gate RET-PLATFORM-DATE,
  folded into RET-COMPILE-1 because the direct URL 404'd).
  - **Verdict:** VERIFIED.
  - **Correct statement:** `func timeIntervalSince(_ date: Date) -> TimeInterval`
    - "Returns the interval between this date and another given date. If the
    receiver is earlier than `anotherDate`, the return value is negative." macOS
    10.10+ (iOS 8.0+, visionOS 1.0+, watchOS 2.0+), present on macOS 26. The
    prior cycle-3 404 was a URL-casing error: the correct symbol path is
    `date/timeintervalsince(_:)` (lowercase 's'), not `timeinterval(_:)`. This
    CLOSES the OPEN gate RET-PLATFORM-DATE: the R1 age primitive
    `evaluatedAt.timeIntervalSince(lastCopiedAt)` (positive when the item is
    older) is verified on macOS 26, and the light compile check folded into
    RET-COMPILE-1 is no longer needed for this symbol. Combined with the
    cycle-3 VERIFIED facts (Date timezone-independence, Date.addingTimeInterval),
    the R1 `now - maxAge` / age-comparison arithmetic is fully grounded.
  - **sourceUrl:** https://developer.apple.com/documentation/foundation/date/timeintervalsince(_:)

- **Claim:** `Date.now` is the production source of the Storage-side clock `now`
  for V2-02 §6.4 R1 age evaluation (for .setRetentionPolicies, which carries no
  caller-supplied observedAt).
  - **Verdict:** VERIFIED.
  - **Correct statement:** `@backDeployed(before: macOS 12, iOS 15, tvOS 15,
    watchOS 8) static var now: Date { get }` - "Returns a date instance that
    represents the current date and time, at the moment of access." "This property
    is equivalent to calling init(). If you assign this value to a variable or
    property, the assigned value doesn't automatically update as time passes."
    macOS 10.10+ (cross-platform), so present on macOS 26. LOAD-BEARING for
    V2-02 §6.4: `Date.now` is the natural production source of `now: Date` passed
    to the pure R1 planner; because the captured value "doesn't automatically
    update as time passes", the `now` passed to the planner is a stable
    point-in-time snapshot (D16 pure planning: identical inputs yield identical
    plans). The clock is behind a test-injectable seam (V2-02 §6.4), so
    production uses `Date.now` and tests inject a fixed `Date` - mirroring v1's
    deterministic concurrency harness injection of `observedAt` (PROGRESS.md step
    5; 05 §6.2). Grounds the §6.4 clock-seam outcome; no macOS-26-specific API
    risk. (Date timezone-independence + addingTimeInterval already verified in
    the cycle-3 addendum.)
  - **sourceUrl:** https://developer.apple.com/documentation/foundation/date/now

### Summary of OPEN retained gates (cycle 4, V2-02)

- `RET-PLATFORM-2` - byte-count fact loading without content decode on the
  retention planning path (OPEN; substantively resolved as "no such API
  documented" - bounded per-item decode is the required mechanism, or a
  maintained in-commit byte projection is the recommended resolution; `RET-PERF-3`
  bounds the worst-case capture-path decode cost until a projection is adopted).
- `RET-PLATFORM-3` - pruned `RevisionStateBlobV1` round-trip + D3-preservation
  (OPEN; v1 codec proofs cover the un-pruned case; pruned-case scaffold proof
  retained).
- `RET-PERF-3` (new) - capture-path decode cost with R2 active: if no byte
  projection is adopted, up to 5,000 external `revisionStateBlob` decodes per
  capture; capture p95 must be measured and stay within the `06` §9 budget.

## IMPROVE cycle 1 (V2-02) - MCP verdict cross-reference

Appended 2026-07-23 (IMPROVE cycle 1 for V2-02-retention.md). This cycle was
handed 14 MCP-verified verdicts to persist. On append, all 14 were already
recorded - more thoroughly - in the `## Cycle 4 verified facts` section above
(written by a concurrent cycle). To avoid duplicate re-verification and a
redundant restatement, this section records each handed verdict by mapping it
to its cycle-4 entry. Every verdict below is VERIFIED (or OPEN where noted) and
its sourceUrl is cited in the linked cycle-4 entry; no new fetch was needed.

1. `@Model` macro confers `Observable, PersistentModel, Sendable` (macOS 14.0+)
   -> cycle-4 "`RetentionExpansionConfigRow` is an `@Model` class" (VERIFIED);
   grounds RET-COMPILE-1's "no V2-authored `@unchecked Sendable`" (framework
   synthesis is unchanged v1 behavior).
2. `@Attribute(_ options: Schema.Attribute.Option...)` peer macro (macOS 14.0+)
   -> cycle-4 "`@Attribute(.unique) var key: String`" (VERIFIED).
3. `Schema.Attribute.Option.unique` (macOS 14.0+) -> cycle-4 @Attribute entry.
4. `Schema.Attribute.Option.externalStorage` (macOS 14.0+) -> cycle-4
   ".externalStorage" + "WWDC2023/10154 out-of-line" entries (VERIFIED).
5. `FetchDescriptor.propertiesToFetch: [PartialKeyPath<T>]` (macOS 14.0+)
   fetches attribute VALUES, faults the rest on access -> cycle-4 (CONFIRMED
   existence; REFUTED as a size-without-content mechanism).
6. `FetchDescriptor<T>` (macOS 14.0+) carries predicate/sortBy/fetchLimit ->
   cycle-4 "FetchDescriptor is the fetch-criteria type" (VERIFIED).
7. `PersistentModel: AnyObject, Observable, Hashable, Identifiable,
   SendableMetatype` (macOS 14.0+); `Sendable` added by `@Model` -> cycle-4
   @Model entry (consistent with v1 no-model-leakage, `01` §6).
8. `ModelContext.fetch(_:) -> [T]` hydrates full models (macOS 14.0+); no scalar
   variant -> cycle-4 "fetch returns hydrated models" (VERIFIED).
9. `MigrationStage.lightweight` / `.custom` (macOS 14.0+) -> cycles 1-3
   (VERIFIED, re-cited cycle 4); grounds RET-PLATFORM-1.
10. `ModelContext.transaction(block:)` (macOS 14.0+) atomic save -> cycle-4
    re-affirmation + cycle-3 addendum (VERIFIED); grounds RET-PLATFORM-3 /
    RET-SECURITY-1.
11. `ModelContext.fetchCount(_:) -> Int` (row counts, not bytes) -> cycle-4
    (VERIFIED); substantiates RET-PLATFORM-2.
12. `ModelContext.fetchIdentifiers(_:) -> [PersistentIdentifier]` (no attribute
    values) -> cycle-4 (VERIFIED); substantiates RET-PLATFORM-2.
13. `ModelContext.enumerate(_:batchSize:allowEscapingMutations:block:)` (default
    batchSize 5000; hydrates per model) -> cycle-4 (VERIFIED); the bounded-decode
    fallback primitive.
14. OPEN: no documented SwiftData API yields an `.externalStorage` blob's byte
    length / revision count without materializing content -> cycle-4
    "RET-PLATFORM-2 resolution" (OPEN, substantively resolved as "no such API
    documented"; bounded per-item decode is the required mechanism, or a
    maintained in-commit byte projection the recommended resolution).

No new OPEN gates introduced by this cycle; the cycle-4 OPEN summary
(`RET-PLATFORM-2`, `RET-PLATFORM-3`, `RET-PERF-3`) stands.
