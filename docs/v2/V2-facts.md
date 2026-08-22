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

## Cycle 5 verified facts (2026-08-15, multi-round V2 document review)

Appended 2026-08-15 during the 审查–调查–批评 review pass over the V2 docs.
Each entry: claim / verdict / correct statement / sourceUrl. Verdicts are
VERIFIED (fetched), OPEN (URL unresolvable; proof gate retained), or LOCATED
(external primary source found for a previously uncited claim). This cycle
advances DC-1 (durable promotion) for the V2-05 App Intents, V2-06 P2 string,
V2-04 C2 file, and V2-01 executor platform claims.

### App Intents dependency injection (V2-05 X1)

- **Claim (V2-05 §6.5 / roadmap gate maintenance):** `AppDependencyManager` is a
  real App Intents type with a `.shared` singleton and registration methods, so
  the single sanctioned framework-owned `.shared` registration in ClipyApp is
  possible.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `final class AppDependencyManager` in **AppIntents**
    — "An object that manages the registration and initialization of an app
    intent's dependencies." macOS 13.0+ (iOS 16.0+), so present on macOS 26.
    Lists a type property `shared` and three `add(key:dependency:)` overloads;
    `init()` is documented for dependency injection during testing. The
    `@Dependency` property wrapper is not described on this page (OPEN below).
  - **sourceUrl:** https://sosumi.ai/documentation/appintents/appdependencymanager
    (Apple original: https://developer.apple.com/documentation/appintents/appdependencymanager)

- **Claim (V2-05 §6.5, "Swift 6 strict-concurrency risk"):** a Swift Forums
  report documents a known crash against `AppDependencyManager` /
  `@Dependency` in Swift 6 mode.
  - **Verdict:** LOCATED (primary source found; previously uncited).
  - **Correct statement:** Swift Forums thread "AppDependencyManager and
    @Dependency usage crashes in Swift 6 mode" (Nov 2024, tagged swift6):
    Swift 6 mode causes a runtime crash from a queue assertion if any
    `@Dependency` is used in an `AppIntent`. This is the report V2-05 §6.5
    relies on; `X-COMPILE-2` must still confirm crash-free resolution on
    macOS 26 (compilation alone is insufficient — the report is a runtime
    queue-assertion crash).
  - **sourceUrl:** https://forums.swift.org/t/appdependencymanager-and-dependency-usage-crashes-in-swift-6-mode/73226

- **Claim:** the `@Dependency` property wrapper's exact declaration/availability.
  - **Verdict:** OPEN.
  - **Correct statement:** The symbol URL
    `…/documentation/appintents/dependency` returned 404 via Sosumi; the
    wrapper is exercised by every V2-05 §6.6 App Intent. `X-COMPILE-2`
    (cold/warm `@Dependency` order, Swift 6 crash-freedom) retains it.

### Foundation string search (V2-06 P2)

- **Claim (V2-06 §4 query-time branch):** `NSString.range(of:options:range:locale:)`
  is the locale-parameterized exact-match primitive.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `func range(of searchString: String, options mask:
    NSString.CompareOptions = [], range rangeOfReceiverToSearch: NSRange,
    locale: Locale?) -> NSRange` — macOS 10.5+ (iOS 2.0+), present on macOS 26.
    Passing `nil` uses the system locale; `Locale.current` is the user's
    locale; the locale influences equality checking (Apple's example: Turkish
    case-insensitive "I"/"ı"). Returns `{NSNotFound, 0}` when not found.
  - **sourceUrl:** https://sosumi.ai/documentation/foundation/nsstring/range(of:options:range:locale:)

- **Claim (V2-06 §4 CJK width folding):** a width-insensitive compare option
  exists for East-Asian width folding.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `struct CompareOptions` (`NSString.CompareOptions`,
    an OptionSet) includes `widthInsensitive` ("ignores full-width vs
    half-width character differences, as found in East Asian scripts") and
    `diacriticInsensitive` ("Search ignores diacritic marks"), alongside
    `caseInsensitive`, `literal`, `backwards`, `anchored`, `numeric`,
    `forcedOrdering`, `regularExpression`. macOS 10.0+. Grounds P2's
    `.widthInsensitive` insertion for Japanese language codes and the
    diacritic-insensitive default the localizedStandard family already
    provides.
  - **sourceUrl:** https://sosumi.ai/documentation/foundation/nsstring/compareoptions

### Foundation backup exclusion (V2-04 C2)

- **Claim (V2-04 §6.6 / roadmap C.6 "backup-exclusion reassertion"):** a
  documented URL resource key excludes cache files from backups and must be
  reapplied on every write.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `static let isExcludedFromBackupKey: URLResourceKey`
    — "A key for indicating whether the system excludes the resource from all
    backups of app data"; the value is a read-write Boolean `NSNumber`;
    macOS 10.8+. Load-bearing caveat, quoted: "Set this property each time you
    save a file because some common file operations cause this property to
    reset to `false`." This is precisely why C2's atomic temp-write + replace
    must reassert the flag on every file replacement, not only at directory
    creation (V2-04 §6.6 already specifies reassertion; the fact grounds it).
  - **sourceUrl:** https://sosumi.ai/documentation/foundation/urlresourcekey/isexcludedfrombackupkey

### Swift custom actor executors (V2-01 EnrichmentWorker)

- **Claim (V2-01 §6.2 "custom non-cooperative executor"):** an actor can pin
    its execution to a custom serial executor so a blocking body never occupies
    the default cooperative executor.
  - **Verdict:** VERIFIED.
  - **Correct statement:** `nonisolated var unownedExecutor:
    UnownedSerialExecutor { get }` on `actor` — macOS 10.15+; "This property
    must always evaluate to the same executor for a given actor instance, and
    holding on to the actor must keep the executor alive." Implicitly accessed
    when work is scheduled onto the actor (side effects discouraged). The
    customization mechanism is SE-0392 (Swift 5.9+), which also permits
    bridging a dispatch queue as a serial executor. Grounds V2-01's decision
    to run blocking `VNImageRequestHandler.perform(_:)` on the worker actor
    with a custom executor (E1-PERF-6) instead of a detached Task.
  - **sourceUrl:** https://sosumi.ai/documentation/swift/actor/unownedexecutor
    (proposal: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md)

### Summary of OPEN retained gates (cycle 5)

- `@Dependency` property-wrapper exact declaration — OPEN; retained under
  `X-COMPILE-2` (V2-05).
- `Locale.Language.LanguageCode` direct symbol URL — OPEN (404 via Sosumi);
  the V2-06 §4 code comment now cites this cycle; retained under `P2-COMPILE-1`.

## Cycle 6 — V2-05 App Intents/audit promotion + loop-R3 verified facts (2026-08-15)

Appended in loop R3 (the 审查→调查→批评 platform-claims loop). §6.1 promotes
the `.tmp/v2-research/V2-05-facts.md` sidecar verbatim (DC-1 durable
promotion): V2-05 cites these as "`V2-facts.md` cycle 6, fact/OPEN N".
§6.2/§6.3 hold the loop-R3 sosumi/web verifications. Verdicts: VERIFIED,
REFUTED, UNDOCUMENTED, LOCATED (external primary source found), OPEN.

### 6.1 V2-05 App Intents / audit platform facts (promoted from .tmp sidecar)

### fact 1 — AppIntent protocol
- Claim: V2-05's intents conform to `AppIntent`; `perform()` is async.
- Verdict: VERIFIED.
- Correct statement: `protocol AppIntent : PersistentlyIdentifiable,
  _SupportsAppDependencies, Sendable` — it IS `Sendable`. macOS 13.0+
  (present on macOS 26). Entry point `func perform() async throws -> some
  IntentResult` — async, composes with the actor-based `HistoryAuthority`.
  Input via `@Parameter` ("the system resolves any parameters ... before
  calling your `perform()` method"); app data via `@Dependency`.
- sourceUrl: https://developer.apple.com/documentation/appintents/appintent

### fact 2 — AppDependencyManager (the @Dependency resolution registry)
- Claim: the `.shared` registration in ClipyApp is a real framework API.
- Verdict: VERIFIED.
- Correct statement: `final class AppDependencyManager` — "An object that
  manages the registration and initialization of an app intent's
  dependencies." macOS 13.0+. `static let shared: AppDependencyManager`.
  Three `add` overloads, all `key: AnyHashable?`; the `add(key:dependency:)`
  overload is declared `final func add<Dependency>(key: AnyHashable? = nil,
  dependency dependencyProvider: @autoclosure @escaping () -> @Sendable ()
  throws -> Dependency) where Dependency : Sendable` — the `= nil` default
  is what makes V2-05 §6.6's keyless `add(dependency: facade)` call
  well-formed. Resolution errors are `AppDependencyManager.Error`
  (`failedToLoadDependency`, `failedToRetrieveDependency`,
  `incorrectDependencyType`). The §6.5 carve-out stands: `@Dependency`
  resolves through `.shared` — a framework-owned DI seam with no app-level
  alternative (App Intents are system-constructed); the Authority itself is
  never registered.
- sourceUrl: https://developer.apple.com/documentation/appintents/appdependencymanager
  , https://sosumi.ai/documentation/appintents/appdependencymanager/add(key:dependency:)-1hqkg

### fact 3 — AppShortcutsProvider
- Claim: `ClipboardShortcuts` surfaces intents to Shortcuts/Siri.
- Verdict: VERIFIED.
- Correct statement: `protocol AppShortcutsProvider : Sendable` — macOS
  13.0+, `Sendable`. `static var appShortcuts: [AppShortcut] { get }`;
  `AppShortcutsBuilder` is the result builder. Loop R3 confirmed not
  deprecated on macOS 26 (only the `AppShortcutsProvider.Title` typealias
  is).
- sourceUrl: https://developer.apple.com/documentation/appintents/appshortcutsprovider

### fact 4 — @Dependency is the established App Intents DI pattern
- Claim: injecting app data via `@Dependency` is Apple-sanctioned.
- Verdict: VERIFIED.
- Correct statement: WWDC24 "Bring your app to Siri" transcript — an
  `OpenAssetIntent` example declares `@Dependency` for app dependencies
  ("such as my app's Navigation Manager"). Canonical pattern: app data
  injected via `@Dependency`, not an app-invented locator.
- sourceUrl: WWDC24 transcript (search_wwdc_content "App intents").

### fact 5 — SecItemAdd(_:_:)
- Claim: Keychain writes are available macOS 10.6+ and block the caller.
- Verdict: VERIFIED.
- Correct statement: `func SecItemAdd(_ attributes: CFDictionary, _ result:
  UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus` — macOS 10.6+ (present on
  macOS 26). Blocks the calling thread ("can cause your app's UI to hang if
  called from the main thread") → V2-05 confines SecItem calls to the
  `CredentialStore` actor (reserved, unbuilt — DC-22).
- sourceUrl: https://developer.apple.com/documentation/security/secitemadd(_:_:)

### fact 6 — SecItemCopyMatching(_:_:)
- Claim: Keychain reads share the same platform profile.
- Verdict: VERIFIED.
- Correct statement: `func SecItemCopyMatching(_ query: CFDictionary, _
  result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus` — macOS 10.6+,
  blocks the calling thread; returns the first match by default
  (`kSecMatchLimit` controls batch size).
- sourceUrl: https://developer.apple.com/documentation/security/secitemcopymatching(_:_:)

### fact 7 — SecItemDelete / SecItemUpdate exist in the same family
- Claim: the full C-keychain CRUD surface exists.
- Verdict: VERIFIED.
- Correct statement: `SecItemDelete(_:)` and `SecItemUpdate(_:_:)` are in
  the "Keychain items" API collection alongside Add/CopyMatching; macOS
  10.6+ by family (modern `SecItem*`, not the legacy deprecated
  `SecKeychainItem*`).
- sourceUrl: https://developer.apple.com/documentation/security/keychain-items

### OPEN 1 — App Intents in-process / entitlement / TCC behavior (X-SECURITY-1)
- Question: does a main-app-target `AppIntent` invoked by Siri/Shortcuts/
  Spotlight on macOS 26 run in the app's process, inheriting sandbox
  entitlements and TCC grants? Not stated on the AppIntent/
  AppShortcutsProvider pages; retrieved WWDC transcripts are silent.
- Required OUTCOME (V2-05 §8/Record 6): in-process, inheriting the app's
  entitlements/TCC; an App Intents extension target is post-V2. Gate
  `X-SECURITY-1` confirms on macOS 26.

### OPEN 2 — @Dependency registration timing + Swift 6 isolation (X-COMPILE-2)
- Question: must `AppDependencyManager.shared.add(...)` complete before the
  system first resolves an intent's `@Dependency`, and is the resolved
  `Sendable` facade safe under Swift 6 complete strict concurrency?
- Required OUTCOME (V2-05 §6.5): registration at launch before any intent
  performs; unresolved dependency surfaces as
  `ExternalFailure.temporarilyUnavailable(.storeLocked)`. Gate
  `X-COMPILE-2` (cold/warm) — including the forums-73226 queue-assertion
  crash class (cycle 5).

### OPEN 3 — Capability-scoped subset expressibility
- Resolved by design (V2-05 §3.2/§7): a closed, deliberately smaller
  request set; no App Intent can spell capture/revise/clear/policy.

### OPEN 4 — Audit hash-chain non-repudiation bound (X-SECURITY-2)
- Resolved (V2-05 §4.4/Record 6): the forward SHA-256 chain detects
  accidental corruption and naive tampering without claiming
  non-repudiation; HMAC-with-Keychain-key hardening (facts 5–7) recorded as
  a future option. Gate `X-SECURITY-2`.

### 6.2 Loop-R3 verified facts (V2-05 / V2-06 / V2-07)

### fact 8 — CryptoKit SHA256
- Verdict: VERIFIED. `struct SHA256: HashFunction`, macOS 10.15+; one-shot
  `hash(data:)` or incremental `update`+`finalize`. Same-input determinism
  follows from the SHA-2 spec, not an Apple-doc sentence; V2-05's
  `hasherVersion` field pins the algorithm.
- sourceUrl: https://sosumi.ai/documentation/cryptokit/sha256

### fact 9 — DispatchTime.uptimeNanoseconds monotonicity (OPEN)
- Verdict: OPEN. `uptimeNanoseconds` is "nanoseconds since boot, excluding
  any time the system spent asleep" (epoch defined; monotonicity NOT
  documented by Apple). The V2-05 bucket's defense is the clamp
  (elapsed = max(0, now − last), refill capped at capacity), not the
  adjective.
- sourceUrl: https://sosumi.ai/documentation/dispatch/dispatchtime/uptimenanoseconds

### fact 10 — localizedStandard* search semantics
- Verdict: VERIFIED. `localizedStandardContains(_:)` — "a case and
  diacritic insensitive, locale-aware search", macOS 10.11+;
  `localizedStandardRange(of:)` returns the first occurrence or
  `{NSNotFound, 0}`. Neither page mentions width folding — confirming
  V2-06's "folds case + diacritics only" reading.
- sourceUrl: https://sosumi.ai/documentation/foundation/nsstring/localizedstandardcontains(_:)

### fact 11 — FileHandle.bytes
- Verdict: VERIFIED. `var bytes: FileHandle.AsyncBytes { get }`,
  `AsyncSequence<UInt8>`, `.prefix/.characters/.lines`; macOS 12.0+.
  `URL.resourceBytes` with a file:// URL is the documented equivalent.
- sourceUrl: https://sosumi.ai/documentation/foundation/filehandle/bytes

### fact 12 — FileHandle.read(upToCount:)
- Verdict: VERIFIED. `func read(upToCount count: Int) throws -> Data?` —
  reads up to count bytes, empty `Data` at EOF; macOS 10.15.4+.
- sourceUrl: https://sosumi.ai/documentation/foundation/filehandle/read(uptocount:)

### fact 13 — FileHandle.synchronize()
- Verdict: VERIFIED. `func synchronize() throws` — flushes in-memory data
  and attributes to permanent storage, blocking until flushed; macOS
  10.15+.
- sourceUrl: https://sosumi.ai/documentation/foundation/filehandle/synchronize()

### fact 14 — Exclusive blob creation (O_CREAT|O_EXCL)
- Verdict: VERIFIED (POSIX primary source; Foundation offers NO exclusive
  create). `open(2)` with `O_CREAT|O_EXCL` fails with `EEXIST` on collision
  — atomic check-and-create. `FileManager.createFile` OVERWRITES and even
  returns true when the file exists (`O_CREAT|O_TRUNC`-shaped, never
  exclusive); `FileHandle(forWritingTo:)` does not create.
- sourceUrl: https://pubs.opengroup.org/onlinepubs/7908799/xsh/open.html
  , https://sosumi.ai/documentation/foundation/filemanager/createfile(atpath:contents:attributes:)

### fact 15 — unlink preserves an open descriptor's inode
- Verdict: LOCATED (POSIX; no Apple reference page documents fd/inode
  semantics). unlink removes a name; data is deallocated only when no
  links remain AND no process holds it open. Does NOT prove
  `FileHandle.AsyncBytes` never re-validates mid-stream — P3-PLATFORM-2/5
  stay load-bearing for the Foundation iterator layer.
- sourceUrl: https://pubs.opengroup.org/onlinepubs/9699919799/functions/unlink.html

### fact 16 — Locale.Language.languageCode
- Verdict: VERIFIED via the parent property page (the LanguageCode struct's
  own page still 404s — non-load-bearing). `var languageCode:
  Locale.LanguageCode? { get }` on `Locale.Language` — "The language code
  that identifies this language"; macOS 13.0+.
- sourceUrl: https://sosumi.ai/documentation/foundation/locale/language-swift.struct/languagecode

### fact 17 — Locale.current snapshot vs autoupdatingCurrent
- Verdict: VERIFIED. `Locale.current` — "the user's region settings at the
  time the property is read" (snapshot; does not change when settings
  change); `autoupdatingCurrent` reflects the latest configuration. A
  once-per-query captured Locale value is stable for that query — supports
  V2-06's determinism argument.
- sourceUrl: https://sosumi.ai/documentation/foundation/locale/current

### fact 18 — Observation @Observable
- Verdict: VERIFIED. `protocol Observable`, macOS 14.0+; docs direct you to
  always use the `Observable()` macro (bare conformance adds nothing).
- sourceUrl: https://sosumi.ai/documentation/observation/observable

### fact 19 — LocalizedStringResource
- Verdict: VERIFIED. `struct LocalizedStringResource`, macOS 13.0+,
  Sendable; defers resolution to `String(localized:)` — matches V2-07's
  cross-process rationale.
- sourceUrl: https://sosumi.ai/documentation/foundation/localizedstringresource

### 6.3 Loop-R3 verified facts (V2-01 / V2-02 / V2-04)

### fact 20 — VNRecognizedTextObservation.topCandidates(_:)
- Verdict: REFUTED (throws) / VERIFIED (empty risk). `func
  topCandidates(_ maxCandidateCount: Int) -> [VNRecognizedText]` does NOT
  throw; it "returns no more than n candidates, but it may return fewer
  than n" — possibly zero. `topCandidates(1)[0]` traps on an empty result;
  use `.first` with a guard (no candidates → no text, confidence 0.0).
- sourceUrl: https://sosumi.ai/documentation/vision/vnrecognizedtextobservation/topcandidates(_:)

### fact 21 — AsyncThrowingStream .unbounded buffering
- Verdict: VERIFIED. "By default, the buffer limit is `Int.max`, which
  means it's unbounded"; dropping occurs only under
  `.bufferingOldest`/`.bufferingNewest` on exhaustion. V2-01 §6.3's
  `.unbounded` inbox cannot lose an itemID by buffering; the backlog scan
  is defense-in-depth only.
- sourceUrl: https://sosumi.ai/documentation/swift/asyncthrowingstream

### fact 22 — SE-0192 cross-module enum exhaustiveness
- Verdict: REFUTED as commonly stated. Imported enums are non-exhaustive
  only when the defining library is built with library evolution (Apple
  SDK modules); in ordinary builds every enum is frozen and cross-module
  exhaustive switches compile — and break when a case is added. V2-02's
  safety rests on `RET-COMPILE-2` compiling v1 callers, not on default
  non-exhaustiveness.
- sourceUrl: https://github.com/apple/swift-evolution/blob/main/proposals/0192-non-exhaustive-enums.md

### fact 23 — FileManager replaceItem / ItemReplacementOptions
- Verdict: SPLIT. `replaceItem(at:withItemAt:backupItemName:options:
  resultingItemURL:) throws`, macOS 10.6+ (Swift variant `replaceItemAt`
  → URL?, 10.10+) — VERIFIED, "in a manner that ensures no data loss
  occurs", same-volume. `.ifExistingAtomicReplace` does NOT exist:
  `ItemReplacementOptions` has exactly `.usingNewMetadataOnly` and
  `.withoutDeletingBackupItem`. Absent-destination behavior is
  UNDOCUMENTED (community: `NSFileNoSuchFileError`); documented
  no-clobber first write: `moveItem(at:to:)` fails if the destination
  exists.
- sourceUrl: https://sosumi.ai/documentation/foundation/filemanager/replaceitem(at:withitemat:backupitemname:options:resultingitemurl:)
  , https://sosumi.ai/documentation/foundation/filemanager/itemreplacementoptions

### fact 24 — NSFileCoordinator coordinated accessors
- Verdict: VERIFIED. `coordinate(readingItemAt:options:error:byAccessor:)`
  / `coordinate(writingItemAt:options:error:byAccessor:)`, macOS 10.7+.
  NOT Swift-throws: errors via `NSErrorPointer`; the accessor block is NOT
  executed on failure (sentinel-in-block pattern). Both execute
  synchronously. Do not nest coordinator calls inside the block (reading
  inside a write block is the sole sanctioned exception).
- sourceUrl: https://sosumi.ai/documentation/foundation/nsfilecoordinator/coordinate(readingItemAt:options:error:byaccessor:)

### fact 25 — FileManager.url(for:in:appropriateFor:create:)
- Verdict: VERIFIED. `func url(for:in:appropriateFor:create:) throws ->
  URL` — explicitly "marked with the `throws` keyword"; macOS 10.6+.
- sourceUrl: https://sosumi.ai/documentation/foundation/filemanager/url(for:in:appropriatefor:create:)

### fact 26 — Cheap directory sizing
- Verdict: VERIFIED. `contentsOfDirectory(at:includingPropertiesForKeys:
  [.fileSizeKey, ...])` — "the specified properties are fetched and cached
  in the NSURL object"; then `url.resourceValues(forKeys:)` returns the
  cached values. `attributesOfItem(atPath:)` is one throwing call per
  file; `contentsOfDirectory(atPath:)` returns bare names.
- sourceUrl: https://sosumi.ai/documentation/foundation/filemanager/contentsofdirectory(at:includingpropertiesforkeys:options:)

### fact 27 — File coordination is cooperative
- Verdict: VERIFIED with caveat. The class "coordinates the reading and
  writing of files and directories among multiple processes and objects in
  the same process" — but via opt-in participation (registered presenters
  + coordinating writers). A non-participating writer using raw
  FileManager/POSIX calls is not blocked.
- sourceUrl: https://sosumi.ai/documentation/foundation/nsfilecoordinator

### fact 28 — Caches directory and backups
- Verdict: VERIFIED (device backup) with platform hedge. "The system
  doesn't back up either the temporary directory or the caches directory."
  No Apple doc covers macOS Time Machine (its exclusion list is
  undocumented); the system may purge Caches at any time.
  `isExcludedFromBackupKey` (cycle 5) remains the load-bearing defense.
- sourceUrl: https://developer.apple.com/documentation/foundation/using-the-file-system-effectively

### fact 29 — CGImageDestination non-Sendable
- Verdict: VERIFIED (no Sendable conformance documented; conformances are
  Equatable/Hashable only). Treat as confined like `CGImageSource`.
- sourceUrl: https://sosumi.ai/documentation/imageio/cgimagedestination

### OPEN 5 — MigrationStage.custom willMigrate/didMigrate timing
- Question: do the custom-stage closures run synchronously during
  `ModelContainer` init, before `open` returns? No discussion on the API
  page; WWDC2025/291 has no timing statements.
- Owner: V2-02's RET-PLATFORM-1b item (d) must keep asserting
  completion-before-open-returns at runtime, not cite Apple docs.
- sourceUrl: https://sosumi.ai/documentation/swiftdata/migrationstage/custom(fromversion:toversion:willmigrate:didmigrate:)

### OPEN 6 — VNRequest.results ordering
- Question: Apple documents NO ordering for `VNRequest.results`. D9
  determinism pins V2-01's concat order to observation-index order only;
  any bounding-box sort is a fixture-gated tie-break under E1-PLATFORM-3.
- sourceUrl: https://sosumi.ai/documentation/vision/vnrequest/results

## Cycle 7 — V2-03/V2-04/V2-06/V2-07 fact-sidecar promotion (2026-08-15)

Appended 2026-08-15, closing roadmap §4 DC-01 (durable promotion of the
remaining `.tmp/v2-research` fact sidecars). §7.1–§7.4 promote the
V2-03/V2-04/V2-06/V2-07 sidecars verbatim: the owning docs cite these as
"`V2-facts.md` cycle 7 §7.X, fact/OPEN N" with the sidecars' own numbering
unchanged (verbatim promotion). Inside the promoted blocks, each sidecar's
per-turn "Cycle N" labels are that sidecar's improve-cycle numbering, not
V2-facts.md cycle numbering, and each sidecar's header note that it "lives
only in `.tmp/v2-research/`" is retained verbatim as a record of origin —
the promoted copies below are the durable record; `.tmp/` remains untracked
scratch. Cross-references inside a promoted block to sibling sidecars that
were not promoted (`V2-01-facts.md`, `orchestrator-verified-facts.md`) are
likewise retained verbatim as provenance; their load-bearing content is
carried by the facts of the promoting subsection and by cycles 1–6.

### 7.1 V2-03 change-journal / reconnect platform facts (promoted from .tmp sidecar)

> Promoted verbatim from the former `.tmp/v2-research/V2-03-facts.md` sidecar
> (2026-08-15), closing DC-01. Only the sidecar's top-level `#` title was
> dropped and its `##`/`###` headings demoted to nest under this subsection;
> every fact, OPEN item, table, and cross-reference is the sidecar's own
> text, unchanged.

> MCP-verified platform facts and OPEN questions for the V2-03 design
> (`docs/v2/V2-03-change-journal.md`). Each fact's verdict is either **VERIFIED**
> (MCP-fetched, sourceUrl cited) or **OPEN** (could not fetch; assigned a V2 proof
> gate in the owning doc). This file is NOT a v1 doc; it lives only in
> `.tmp/v2-research/` and owns no spec semantics. Facts here are the cycle-5
> contribution; the shared `docs/v2/V2-facts.md` carries the cross-cycle
> Vision/PDFKit/SwiftData-migration/transaction/fetch facts cited by reference.

#### Verified platform facts

##### SwiftData native History (the §3 decision substrate)

1. **Claim:** SwiftData exposes a native History API usable to fetch
   chronological change transactions.
   - **Verdict:** VERIFIED.
   - **Correct statement:** `struct HistoryDescriptor<TransactionType> where
     TransactionType : HistoryTransaction` — "A type that describes the
     criteria, and, optionally, sort order, to use when fetching history data."
     macOS 15.0+ (iOS 18.0+, iPadOS 18.0+, Mac Catalyst 18.0+, tvOS 18.0+,
     visionOS 2.0+, watchOS 11.0+), Swift 5.9+. Present on macOS 26. Fetched via
     a `ModelContext`. This is the SwiftData analogue of Core Data's
     `NSPersistentHistoryChangeRequest` (which has no SwiftData-portable
     equivalent — `NSPersistentHistoryChangeRequest` itself returned 0 results in
     `search_apple_docs`, confirming it is a Core Data / CoreData-framework
     symbol, not a SwiftData one).
   - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/historydescriptor

2. **Claim:** A SwiftData History transaction is an ordered, `Sendable`,
   `Identifiable` grouping of inserts/updates/deletes.
   - **Verdict:** VERIFIED.
   - **Correct statement:** `protocol HistoryTransaction : Hashable, Identifiable,
     Sendable` (macOS 15.0+). Its See Also lists `HistoryChange`,
     `HistoryDelete`, `HistoryInsert`, `HistoryUpdate`, `HistoryToken`,
     `HistoryTombstone`, plus `DefaultHistoryInsert`/`DefaultHistoryUpdate`/
     `DefaultHistoryDelete`/`DefaultHistoryToken`/`DefaultHistoryTransaction`.
     So a transaction exposes **row-level diffs** (insert/update/delete on
     `@Model` rows), not Domain-semantic change kinds. This is the basis for
     V2-03 §3 reason 2 (semantic-kind vs row-level diff): native History carries
     storage-row diffs, coupling any consumer to the storage schema.
   - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/historytransaction

3. **Claim:** SwiftData History provides an opaque, `Codable & Comparable`
   resumable cursor (the HistoryToken).
   - **Verdict:** VERIFIED.
   - **Correct statement:** The article "Fetching and filtering time-based model
     changes" states: "Tokens are opaque objects that conform to the `Comparable`
     and `Codable` protocols, enabling you to store the most recent token on-disk
     and use it in the next fetch to receive only newer changes." `HistoryToken`
     is listed in `HistoryTransaction`'s See Also. This meets the brief's
     criterion (c) "a resumable cursor." However, the article does NOT document
     what `fetch(historyDescriptor)` returns/throws when the token's
     transactions were compacted (predicate-deleted) — see OPEN 1. The
     token-expiry failure semantics are undocumented, which is V2-03 §3 reason 3
     for the custom HCR.
   - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes

4. **Claim:** SwiftData History meets the brief's minimum criteria (a)-(d) but
   is an open, heterogeneous, multi-process-aware stream.
   - **Verdict:** VERIFIED.
   - **Correct statement:** The article states: "The data store organizes
     changes as a series of chronological transactions, where each transaction
     contains information about one or more persisted changes" (criterion a:
     per-commit ordered records). "Transactions group together one or more
     changes that occur on a specific boundary — such as when a model context
     writes pending changes to the store" (criterion b: atomicity with item
     mutations at the save boundary). "Tokens are opaque objects that conform to
     the `Comparable` and `Codable` protocols" (criterion c). macOS 15.0+
     availability (criterion d). The article ALSO states the stream is **open and
     heterogeneous**: "transactions aren't bound to a specific model type. When
     you fetch them from a data store, the results will likely contain
     transactions, and changes within those transactions, that are unrelated to
     the current view or task. Filter each transaction's changes and identify
     only those that are relevant." And multi-process-aware: "your app may need
     to determine changes made by another process such as a Widget or App Intent
     and reflect those changes." This is the basis for V2-03 §3 reasons 1 and 4
     (closed-vs-open stream; scope mismatch with V2's excluded multi-process
     writers): SwiftData History records every store write, not only
     `HistoryAuthority` History Commits.
   - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/fetching-and-filtering-time-based-model-changes

##### Transaction atomicity (re-verified this cycle)

5. **Claim:** `ModelContext.transaction(block:)` is the atomic save boundary
   that makes the HCR row + item mutations + singleton position commit
   atomically (D25).
   - **Verdict:** VERIFIED (re-verified this cycle; originally cycle-3 addendum
     + cycle 4 of `V2-facts.md`).
   - **Correct statement:** `func transaction(block: () throws -> Void) throws`
     — "Runs the provided closure, and once it finishes, writes any pending
     inserts, changes, and deletes to the persistent storage." macOS 14.0+ (iOS
     17.0+, iPadOS 17.0+, Mac Catalyst 17.0+, tvOS 17.0+, visionOS 1.0+, watchOS
     10.0+), Swift 5.9+. Parameters: `block` — "The closure to run before
     performing a save operation." See Also: `autosaveEnabled`, `save()`,
     `rollback()`. v1 already relies on this exact primitive as its sole commit
     boundary (`05` §10); V2-03 appends one more `context.insert(row)` in the
     same closure, so the HCR row shares the commit's atomic save boundary
     (closure failure commits nothing; closure success is the save boundary).
     This is the D25 platform anchor.
   - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/modelcontext/transaction(block:)
   - **Cross-ref:** `docs/v2/V2-facts.md` cycle-3 addendum (line ~815) and cycle
     4 (line ~975) verified the same signature and "writes pending
     inserts/changes/deletes after closure" semantics for V2-02's multi-row
     retirement.

##### FetchDescriptor range predicate (re-verified this cycle)

6. **Claim:** `FetchDescriptor` is the SwiftData fetch-criteria type carrying
   predicate, sort order, and limits, available on macOS 26.
   - **Verdict:** VERIFIED (re-verified this cycle; originally cycle 4 of
     `V2-facts.md`).
   - **Correct statement:** `struct FetchDescriptor<T> where T : PersistentModel`
     — "A type that describes the criteria, sort order, and any additional
     configuration to use when performing a fetch." macOS 14.0+ (iOS 17.0+, etc.),
     Swift 5.9+. Overview confirms `#Predicate { ... }` attribute filters
     (example: `predicate: #Predicate { $0.isFavorite == true }`), `sortBy:
     [SortDescriptor<T>]`, and `fetchLimit`. So
     `FetchDescriptor<HistoryChangeRecordRow>(predicate: #Predicate {
     $0.sequence > cursor.sequence }, sortBy: [.init(\.sequence)])` with a
     `fetchLimit` is the journal range-query path. This is V2-03 §6.2 / §10.3
     `journalChanges(since:)`.
   - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/fetchdescriptor
   - **Cross-ref:** `docs/v2/V2-facts.md` cycle 4 (line ~994) verified the same
     type, predicate/sortBy/fetchLimit surface.

7. **Claim:** A `#Predicate` over a `UInt64` attribute supports `>` range
   comparisons for the journal's "sequence > cursor.sequence" fetch.
   - **Verdict:** VERIFIED (by direct FetchDescriptor example + standard Swift
     `Predicate` semantics).
   - **Correct statement:** The FetchDescriptor Overview example uses
     `#Predicate { $0.isFavorite == true }` (an equality predicate over a Bool
     attribute). Swift's `Predicate` macro supports the standard comparison
     operators (`==`, `!=`, `<`, `<=`, `>`, `>=`) over `Comparable` attributes;
     `UInt64` is `Comparable`. So `#Predicate<HistoryChangeRecordRow> {
     $0.sequence > cursor.sequence }` is a valid range predicate. The
     SwiftData-specific limitation (no documented way to project an
     `.externalStorage` blob's byte length without materializing content,
     `V2-facts.md` cycle 4 / V2-02 `RET-PLATFORM-2`) does NOT apply here: the
     HCR's `sequence` is a plain `UInt64` scalar column (not `.externalStorage`),
     so a range predicate over it is a standard scalar fetch.
   - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/fetchdescriptor

##### Non-blocking yield (re-verified this cycle)

8. **Claim:** `AsyncThrowingStream.Continuation.yield` / `AsyncStream.
   Continuation.yield` is synchronous and non-blocking — the primitive for the
   collection-cache inbox wake.
   - **Verdict:** VERIFIED (re-cited this cycle; originally cycles 1-2 of
     `V2-facts.md`).
   - **Correct statement:** `@discardableResult func yield(_ value: sending
     Element) -> AsyncThrowingStream<Element, Failure>.Continuation.YieldResult`
     — "This can return right away to the caller without blocking for any
     awaiting consumption." macOS 13.0+ / iOS 13.0+. `AsyncStream.Continuation.
     yield` shares this non-blocking semantics. This is the primitive v1
     invalidation yield is built on (`05` §11 step 2; `04` §4); V2-03's
     collection-cache inbox wake is one more non-blocking yield into the cache's
     own `AsyncThrowingStream` continuation in post-commit step 2, adding no
     `await` to the Authority's post-commit phase (`05` §11 "without
     suspension"). Mirrors V2-01's `EnrichmentScheduler` inbox yield
     (`V2-01` §6.3).
   - **sourceUrl:** https://developer.apple.com/documentation/swift/asyncthrowingstream/continuation/yield(_:)
   - **Cross-ref:** `docs/v2/V2-facts.md` cycle 1 (line ~333) and cycle 2 (line
     ~533) verified both the `AsyncStream` and `AsyncThrowingStream` variants.

##### Schema migration (re-cited this cycle)

9. **Claim:** `MigrationStage.lightweight(fromVersion:toVersion:)` is the
   additive schema-migration stage; both arguments are `VersionedSchema`-
   conforming types.
   - **Verdict:** VERIFIED (re-cited; cycles 1-3 of `V2-facts.md`).
   - **Correct statement:** `case lightweight(fromVersion: any
     VersionedSchema.Type, toVersion: any VersionedSchema.Type)` — macOS 14.0+,
     `Sendable`. Sibling is `.custom(...)`. V2-03's `HistoryChangeRecordRow` /
     `JournalConfigRow` are additive to `HistorySchemaV2`; the migration is a
     purely-additive lightweight stage reusing V2-01's `HistorySchemaV1:
     VersionedSchema` retrofit (`V2-01` §10 `E1-PLATFORM-1`).
   - **sourceUrl:** https://developer.apple.com/documentation/swiftdata/migrationstage/lightweight(fromversion:toversion:)
   - **Cross-ref:** `docs/v2/V2-facts.md` cycles 1-3.

#### OPEN questions

1. **SwiftData History token-expiry failure semantics.** What does
   `ModelContext.fetch(historyDescriptor:)` return or throw when the
   `HistoryToken` carried by the descriptor references transactions that were
   compacted via a predicate-delete ("delete all transactions that occur before
   a given token," per the article)? The article documents the compaction
   primitive but NOT the fetch behavior against a compacted token (empty array?
   thrown error? silent advance to the next-available transaction?). This is
   V2-03 §3 reason 3: native History cannot provide the typed reject D26
   requires. The custom HCR owns the reject path instead. **Resolution: design-
   time** — the custom-HCR decision (§3) makes this OPEN moot for V2-03; it
   remains OPEN for any future post-V2 graft that adopts native History (e.g.,
   a Widget-extension write path). No proof gate required for V2-03 (the custom
   HCR does not depend on this behavior); `J1-PLATFORM-4` proves the custom-HCR
   reject path instead.

2. **HCR/position post-crash consistency on the macOS 26 runtime.** D25
   asserts `max(HistoryChangeRecordRow.sequence) == LastChangePositionRow.rawValue`
   after every crash, because both are written in the same
   `ModelContext.transaction` closure (fact 5). The SwiftData runtime's exact
   crash-recovery semantics for a multi-insert closure (does an interrupted
   closure leave ZERO of the inserts durable, guaranteed?) is the platform
   behavior `05` §10 already flags as a Part VI scaffold gate. V2-03 inherits
   v1's reliance on this. **Resolution: proof gate `J1-PLATFORM-1`** (confirm
   on macOS 26 that appending one extra `@Model` insert in the closure
   preserves closure-success-is-save-boundary semantics).

3. **Journal-rebase behavior at open.** The §9.2 rebase (delete all HCR rows,
   bump `generation`, leave durable history intact, writes enabled) is the
   recovery path for an HCR/position divergence. Whether `SwiftDataHistory.open`
   can reliably detect the divergence (max-sequence fetch vs singleton read in
   one interval) and perform the rebase atomically before publishing the facade
   is a startup-path platform behavior. **Resolution: proof gate
   `J1-PLATFORM-2`** (confirm the divergence detection + rebase on the macOS 26
   runner; `V2-WS-J1-6` fixture).

4. **`@Attribute(.unique)` enforcement on `UInt64 sequence`.** The HCR's
   `sequence` column is `@Attribute(.unique)` (one row per commit). SwiftData's
   enforcement of `.unique` is a documented behavior (used by v1
   `HistoryItemRow.id` / `LastChangePositionRow.key`, `05` §3.1/§3.2, and V2-01
   `EnrichmentRow.itemID`, `V2-01` §3.2). Since the HCR is written only inside
   the serialized Authority transaction with `sequence == plan.position.rawValue`
   (a checked successor that is monotone by D6), uniqueness holds by
   construction; `.unique` is a defensive backstop. **Resolution: no dedicated
   proof gate** (inherits v1's `.unique` evidence; the construction-time
   monotonicity guarantee is stronger than the runtime `.unique` check). If a
   future multi-row-per-commit evolution is taken, a dedicated gate is added.

5. **SwiftData native History enablement model.** Is SwiftData History always
   available (every store) or must it be explicitly enabled at
   `ModelContainer.init`? The article describes fetching/deleting transactions
   but does not show an enablement flag at container creation. This affects only
   the rejected native-History path (§3), not the custom HCR (which needs no
   enablement — it is a plain V2 table). **Resolution: not needed for V2-03**
   (custom HCR chosen); remains OPEN for future native-History grafts.

#### Summary of OPEN retained gates

| OPEN | Resolution | Gate |
|---|---|---|
| 1 (native History token-expiry) | custom-HCR decision moots it for V2-03 | none (J1-PLATFORM-4 covers the custom reject path) |
| 2 (multi-insert closure crash consistency) | proof gate | J1-PLATFORM-1 |
| 3 (rebase at open) | proof gate | J1-PLATFORM-2 |
| 4 (`.unique` on sequence) | inherited v1 evidence | none |
| 5 (native History enablement) | not needed (custom HCR) | none |

#### Cycle 5 (V2-03) fact inventory

Newly verified this cycle: facts 1-4 (SwiftData native History surface —
`HistoryDescriptor`/`HistoryTransaction`/`HistoryToken`/article), fact 5
(transaction atomicity re-verified with fresh citation), facts 6-7
(FetchDescriptor range predicate), fact 8 (non-blocking yield re-cited), fact 9
(migration re-cited). The SwiftData History surface (facts 1-4) is the load-
bearing new evidence: it confirms native History EXISTS and meets the brief's
minimum (a)-(d), forcing the §3 decision to justify the custom HCR on
semantic-fit grounds (closed-vs-open stream, semantic-kind vs row-diff, typed
reject vs undocumented token-expiry) rather than on native-History absence.

#### Improve-stage (turn 5) verified v1 anchors

The improve stage applied confirmed fixes from the consolidated findings. These
fixes rest on v1 doc anchors (not new MCP platform claims); each was verified by
direct read of the frozen v1 docs (`00`–`06`). They are recorded here so the
fixes are traceable; they add no platform fact and need no proof gate beyond
those already in §15.

1. **v1 `HistoryPageCursor` carries a process-instance/schema marker — VERIFIED.**
   `04` §6 (line 98): "`HistoryPageCursor` encodes, opaquely: ... a process-
   instance/schema marker." And line 105: "the cursor belongs to this
   process/schema generation." This is the basis for M2: a `ReconnectCursor`
   needs the **durable** analogue (a per-store UUID on `JournalConfigRow`,
   surviving restart) because the v1 process-local marker is useless cross-
   restart. The `storeInstance: UUID` field + `.storeMismatch` reject (§6.1,
   §6.3, D26) is the cross-restart-correct design.

2. **v1 `04` §12 cache-law wording — VERIFIED.** `04` §12 (line 192): "Any
   future item cache key must contain History Item ID, the relevant authoritative
   version, complete normalized parameters, and a structural materializer schema
   version. Any future collection cache requires a durable change journal **or
   another proved completeness mechanism**; the transient v1 invalidation stream
   is insufficient." The "**or another proved completeness mechanism**" escape
   clause is the basis for the §7.3 two-floor model (m3/m9/m10): the shipped
   position-fence floor is itself a proved completeness mechanism (every entry
   behind current is invalidated), satisfying §12 without HCR content; the HCR
   is the stronger substrate for the optional finer floor (J1-PERF-3) + reconnect.
   The "transient stream is insufficient" clause applies to delta-application
   completeness, which the shipped floor avoids by invalidating unconditionally.

3. **v1 `04` §6 first-page-only observation scope — VERIFIED.** `04` §6 (line
   110): "Observation is limited to the first page. Additional pages are explicit
   one-shot browse calls and restart from page one after expiration." This is the
   basis for M8 (first-page-only cache scope): the cache mirrors v1's first-page
   observation scope, avoiding the page-offset key collision without an extra key
   dimension.

4. **v1 `05` §3.2 singleton + §13 step 3 — VERIFIED.** `05` §3.2 (lines 141–151):
   `LastChangePositionRow` singleton pattern; line 151: "The singleton is not a
   journal." `05` §13 step 3 (line 557): "create the singleton at position 0 if
   this is a new store." This is the basis for the §4.6 `JournalConfigRow`
   bootstrap total order (m3) and the `storeInstance` mint-at-first-open rule.

5. **v1 `06` §8 WS13 injection point — VERIFIED.** `06` §8 WS13 (line 212):
   "Inject failure after row mutation but before singleton update inside the
   transaction." The V2-03 HCR append runs in that same window (§5.1). This is
   the basis for m6: under `05` §10 atomicity (closure failure commits nothing),
   a failure at either sub-point (before or after the HCR append) leaves no HCR
   row; V2-WS-J1-5 extends WS13 to assert "no HCR row" at both.

6. **v1 `03b` §10 failure vocabulary — VERIFIED.** `03b` §10 (lines 240–291):
   `HistoryFailure` enum with `.snapshotExpired(current:)` (line 249) and
   `.persistence(PersistenceFailure)` (line 252); `PersistenceFailure` cases
   `.corruptStoredValue` / `.invariantViolation` (lines 290–291). This is the
   basis for the sibling `ReconnectFailure` design (§6.3, leaves `HistoryFailure`
   untouched) and the fail-closed decode vocabulary (§4.1 unknown-`changeKindRaw`,
   §4.4 blob validation, §4.6 `configSchemaVersion` contract).

7. **v1 `05` §9/§10 ChangePosition successor semantics — VERIFIED.** `05` (line
   469): "the current singleton position must have a checked successor; the same
   successor is used for the whole plan." Line 506: "The singleton position is
   written last inside the same transaction." This is the basis for the Record 5
   sequence-prose fix (review-minor-3): the first post-migration HCR row's
   `sequence == N+1` (the checked successor of the existing position N), not N.

No new platform claims were introduced by the improve stage; every behavioral
claim that depends on macOS 26 runtime behavior (compactionFloor persistence +
reject determinism, storeInstance cross-store reject, the §7.1 fence under
concurrent invalidation, rebase) is already covered by the existing §15 proof
gates (J1-PLATFORM-1/2/4, J1-PERF-1/2/3/4/5) or is a pure-design consequence of
v1 anchors 1–7 above.

#### Cycle-2 improve (turn 8) verified v1 anchors + fixes applied

The cycle-2 improve stage applied the cycle-2 review + critique findings (the
cycle-1 findings were already applied in the prior improve stage and were NOT
re-applied). Each fix rests on a v1 doc anchor verified by direct read of the
frozen v1 docs; none introduces a new MCP platform claim. The one new proof gate
(`J1-PLATFORM-5`) states the required outcome and assigns an implementation-time
proof, exactly as `00` §5 requires where a platform behavior is not guaranteed.

##### v1 anchors verified this cycle (cycle-2)

8. **`RetirementReason.clear` is scope-less — VERIFIED (C2-M1).** `02` §7 line
   370: `case clear` (no associated value). `PlannedOutcome.cleared(count: Int)`
   (`02` §7 line 385) is likewise scope-less. The `.all` / `.unpinned`
   distinction enters the Domain ONLY as the planner input `planClear(scope:
   ClearScope)` (`02` §7 line 441) sourced from the originating
   `HistoryAction.clear(ClearScope)` (`03a` §5 line 176; `ClearScope` defined
   `03a` line 187) — it NEVER reaches `StampedMutation` /
   `RetirementReason` / `PlannedOutcome` / `StampedCommitPlan`. This is the basis
   for the §5.2 clear-scope-input fix: the stamping stage threads the originating
   action's `ClearScope` as a documented additional input (a read of the `05` §8
   dispatch context, not a v1-type modification), so `.clear(.all)` → `.clearAll`
   and `.clear(.unpinned)` → `.clearUnpinned`. NOT a v1-law violation (no v1 type
   redefined); the inputs are widened in the V2-03 stamping derivation only.

9. **itemID non-reuse pinpoint — VERIFIED (C2-m1).** `02` §7 line 408 (plan
   invariant 9: "No plan redirects, merges, or reuses History Item IDs") + D1
   (`02` §14 line 585: "deletion never redirects or reuses it") + `05` §17 line
   663 ("reuse removed IDs" forbidden in migration stance). `02` §12 is
   "Retention and hard capacity" (line 546) — NOT non-reuse. The V2-03 §4.1 cite
   was repointed from `02` §12 to plan-invariant-9 + D1 + `05` §17. **OPEN
   (out of V2-03 scope):** `V2-01` §3.2 carries the SAME imprecise `02` §12 cite
   and is NOT editable from this stage (V2-03 owns only its own doc); flagged for
   a V2-01 improve pass.

10. **Clock seam is the stamping/transaction stage — VERIFIED (C2-m6).** `05`
    §9 ("From Domain plan to stamped commit plan", line 381) and §10 ("Atomic
    transaction", line 473) are where the serialized interval's work (stamping +
    the transaction closure) runs; §11 ("Post-commit order", line 512) is the
    post-commit yield phase. The HCR `createdAt` is captured during stamping/
    transaction (§9/§10), NOT post-commit (§11). The §6.4 cite was corrected from
    `05` §11 to `05` §9/§10.

##### Fixes applied this cycle (cycle-2) and their evidence basis

| Finding | Fix location | Evidence basis |
|---|---|---|
| C2-M1 (.clear derivation gap) | §5.1 diagram, §5.2 derivation + table + clear-scope-input note, §5.3 D18, V2-WS-J1-1 | v1 anchor 8 above (scope-less `RetirementReason.clear`) |
| C2-M2 (type-bridge gap) | §6.2 internal position-based reader + snapshot paragraph, §7.3 finer-floor call site, §10.2 actor + §10.3 Authority method | pure design; rests on the existing `05` §5 single-context-creator + §6.2 reject gate |
| C2-M3 (shipped-cache vs G2 gating) | §7.3 honest-hit-rate paragraph, J1-PERF-2 | pure design (read/write-ratio re-check); no platform claim |
| C2-M4 (wake contradiction) | §10.2 `invalidateDelta` prose, §14 V2-01 interaction | v1 anchors: `04` §4 observer continuations, `05` §11 single yield |
| C2-M5 (§4.4 JournalConfigRow factual error) | §4.4 `.policySet` bullet | v1: `JournalConfigRow` has no policy field (this doc §4.6); V2-02 `RetentionExpansionConfigRow` (`V2-02` §3.3) owns V2 policy |
| C2-M6 (transient I/O mislabel) | §6.3 `.temporarilyUnavailable` + `.persistence` cases | v1 `05` §16 corruption-class intent |
| C2-M7 (single-snapshot + J1-PLATFORM-5) | §6.2 single-snapshot paragraph, §15 J1-PLATFORM-5 | NEW proof gate (required outcome stated; platform snapshot-consistency not guaranteed → gate) |
| C2-M8 (policy-kind symmetry) | §5.2 v1 `.setRetentionPolicy` rows, §4.4, V2-WS-J1-1a | pure design symmetry (retire = membership-affecting primary) |
| C2-m1 (non-reuse cite) | §4.1 | v1 anchor 9 above |
| C2-m2 (changePositionRaw consumer) | §9.1 (reads max of both columns) | gives the §4.1/§4.3 "defensive duplicate" its stated consumer |
| C2-m3 (byte counter) | §4.5 byte-bound rule, §4.6 `journalBytes` field | pure design (O(1) trigger); no platform claim |
| C2-m4 (D18 framing) | §5.2 derivation prose | v1 D18 (`02` §14) |
| C2-m5 (empty-batch + mid-pagination) | §6.2 step 7 + reject note | pure design (D26 protocol-level completeness) |
| C2-m6 (clock cite) | §6.4 | v1 anchor 10 above |
| C2-m7 (checked successor) | §7.3 finer-floor contiguity check | v1 D5/D6 checked-successor discipline |
| C2-m8 (wall-clock trigger) | §8 Trigger + wall-clock-bound bullets | pure design (process-lifetime timer); J1-PERF-5 budgets it |
| C2-m9 (recently-removed caveat) | §13 surface bullet | §4.3 primary-kind-only contract |
| C2-m10 (downgrade policy) | §4.6 step 4 | pure design (fail-closed refuse); J1-PLATFORM-2 covers open-path detection |
| C2-n1 (status-line ambiguity) | status line (conditional removed) | resolved by the C2-n5 rename |
| C2-n2 (step-1 pseudocode type) | §6.2 step 1 | returns `ReconnectBatch` |
| C2-n3 (drop uncited clause) | §3 reason 1 | removed "SwiftData-internal bookkeeping" (uncited) |
| C2-n4 (Int16 raw map) | §4.2 enum `: Int16` + raw values + fail-closed | pure Swift (RawRepresentable); versioned by `configSchemaVersion` |
| C2-n5 (rename → JournalEntryKind) | §1, §3, §4.1, §4.2 (renamed + Naming note), §5.2, §6.3, §10.1, §14, §16, status line | pre-emptive rename (V2-01 `SourceStamp` precedent); drops the `V2-00` §8 carve-out dependency |
| C2-n6 (Codable envelope) | §6.1 decode-failure semantics | pure design; D26 typed-reject holds across decode failure |

##### Cycle-2 OPEN items retained / out of scope

- **V2-01 §3.2 `02` §12 cite (twin of C2-m1).** Out of scope for V2-03 (only the
  V2-03 doc + this sidecar are editable from this stage). Flagged for a V2-01
  improve pass; no V2-03 gate needed.
- **J1-PLATFORM-5 (NEW this cycle).** SwiftData multi-`fetch` snapshot
  consistency on a single operation-local read context (the §6.2 reject-gate
  reads + range fetch sharing one snapshot, uninterrupted by a concurrent
  compaction commit) is the one platform behavior the cycle-2 fixes depend on
  that is NOT MCP-verifiable from the SwiftData article. It is assigned the new
  `J1-PLATFORM-5` proof gate (§15); V2-03 states the required outcome (no
  interleaved partial replay) rather than assuming the platform guarantees it
  (`00` §5).

No new MCP platform facts were added this cycle (the SwiftData History surface,
transaction atomicity, FetchDescriptor predicate, non-blocking yield, and
migration primitives remain as verified in the cycle-5 facts above). Every
cycle-2 fix is either a pure-design consequence of v1 anchors 1–10 or a stated-
  outcome proof gate (`J1-PLATFORM-5`).

#### Cycle-3 improve (turn 10) — FINAL POLISH

The cycle-3 improve stage applied the "Cycle-3 REVIEW findings (turn 9) — FINAL
POLISH" section of `V2-03-findings.md`. Both review lenses PASSED (consolidate-
ready); these are narrow correctness/polish fixes, NOT new capabilities. No new
MCP platform claims were introduced; every fix is either a pure-design
consequence of v1 anchors already verified (1–10 above) or an internal-
consistency correction. No new proof gate was added (the existing
`J1-PLATFORM-1..5`, `J1-PERF-1..5`, `J1-COMPILE-1..2`, `J1-SECURITY-1` cover
every behavioral claim).

##### Fixes applied (with finding ID + evidence basis)

| Finding | Fix location | Evidence basis |
|---|---|---|
| **C3-M1** (ReconnectBatch.currentPosition false invariant) | §6.3 `currentPosition` comment + §6.2 step 7 `currentPosition` definition | pure-design arithmetic: `nextCursor.sequence = max(rows.sequence)` (resume) vs head; equal only when `isCaughtUp` |
| **C3-M2** (ReconnectCursor Codable envelope) | §6.1 `ReconnectCursor` — added stored `cursorSchemaVersion: UInt16 == 1` 5th field + custom `init(from:)`/`encode(to:)` that throw on an unknown version; restated the §6.1 decode-failure paragraph; "four fields" → "five stored fields" | pure Swift: synthesized `Codable` ignores unknown keys (would zero-fill new fields); custom decoder closes the forward-compat hole. Encoder named = `JSONEncoder` (keyed decoding basis); `PropertyListEncoder` explicitly NOT used |
| **C3-m1** (Record 4 vs §7.3/D27 framing) | Record 4 restated: cache satisfies `04` §12 via the shipped position-fence floor (proved mechanism independent of HCR content); HCR is the canonical durable journal `04` §12 names (reconnect + optional finer floor), not the sole shipped-cache lawfulness dependency | aligns Record 4 with the already-correct §7.3 (m10) + D27; `04` §12 escape clause ("or another proved completeness mechanism") verified in v1 anchor 2 |
| **C3-m2** (§9.1 changePositionRaw cross-check power) | §9.1 step 11 softened: the max-aggregate detects max-`sequence` row's `changePositionRaw` divergence OR a runaway, but NOT mid-row divergence; per-row scan not budgeted in `J1-PERF-4` | pure-design: `max()` over a column cannot detect non-maximal per-row divergence |
| **C3-m3** (D28 JournalConfigRow writer enumeration) | D28 writer list extended: compaction (§8) + rebase (§9.2) + `setJournalConfig`/`bumpMaterializerVersion` (§10.3) | reconciles D28 with §10.3 (the writer methods were already specified; D28's enumeration omitted them) |
| **C3-m4** (HistoryChangeRecord DTO redundant `sequence`) | §6.3 `HistoryChangeRecord` — dropped public `sequence` field (consumers use `changePosition`, v1 vocabulary); internal `HistoryChangeRecordRow`/`HistoryChangeRecordPayload` keep both columns | D25 (`sequence == changePosition`); the DTO projection collapses the two to the one v1-spelled value. Verified no other doc text references `HistoryChangeRecord.sequence` as a public field |
| **C3-m5** (§5.2 derivation prose outcome-designated-primary overclaim) | §5.2 derivation restated as TWO rules: (a) item-reference outcomes designate primary directly; (b) policy outcomes + multi-effect plans use the explicit membership-outranks-revision tie-break | `02` §7: `.retentionPolicySet(removedCount:)` carries a count not a mutation ref; V2-02 R1/R2+R3 mixed plans need an explicit tie-break. D18 preserved (explicit payloads + explicit tie-break, no hidden-domain inference) |
| **C3-m6** (NormalizedQueryShape/NormalizedBrowseRequest conformances) | §7.1 — added `internal struct NormalizedQueryShape: Hashable, Sendable` + `internal struct NormalizedBrowseRequest: Sendable` declarations | `J1-COMPILE-1` depends on both being `Sendable`; `CollectionCacheKey: Hashable, Sendable` (already declared) requires `NormalizedQueryShape: Hashable, Sendable` |
| **C3-m7** (materializerVersion UInt16 overflow) | §4.6 `materializerVersion` comment — set by absolute value via `bumpMaterializerVersion(to:)` (not incremented); compiled-in version is a compile-time constant (no runtime overflow on the open-path compare-and-set); caller-computed successor uses checked arithmetic per `02` §13 | reconciles with §10.3's `bumpMaterializerVersion(to newVersion:)` signature (absolute value, not increment); `02` §13 checked-arithmetic discipline |
| **C3-n1** (imprecise "D9-friendly" cite) | §5.2 — two `affectedItemIDs` ordering citations repointed from "D9-friendly / `02` §12" to "deterministic total order by HistoryItemID raw bytes ascending, independent of D9's dedup-winner tie-break and `02` §12's eviction order" | D9 (`02` §14) is the dedup-winner tie-break; `02` §12 is retention/capacity eviction — neither governs the `affectedItemIDs` array order |
| **C3-n2** (bare "M7" label) | V2-WS-J1-7 — replaced "(M7 tie-break)" with the inline rule "(membership-outranks-revision tie-break of §5.2 rule (b))" | the rule was already stated inline in the §5.2 table; the fixture now names it on its own terms instead of by finding-label |
| **C3-n3** (journalBytes "whole-journal footprint cap" overstated) | §4.5 `maxJournalBytes` — reframed as "whole-journal **payload-bytes** cap / approximation"; noted actual SQLite footprint is larger (B-tree headers, `@Attribute(.unique) sequence` + `key` indexes, WAL); `fixedRowOverhead` approximates the row-header share only | pure-design honesty: the `JournalConfigRow.journalBytes` counter (§4.5/§4.6) tracks `blob.count + fixedRowOverhead`, not SQLite page overhead |
| **C3-n4** ("monotonic Date.now" misnomer) | §6.4 — dropped "monotonic"; added "wall-clock is NOT monotonic — `Date.now` can move backwards across NTP adjustments; a backwards move UNDER-compacts age-bounded rows (safe direction); count/byte bounds apply regardless; injectable in tests" | `Date.now` is wall-clock by definition; `Date` is not monotonic. The under-compact direction is safe (rows linger, no cursor broken) |
| **C3-n5** (D25 vs compaction post-condition) | D25 — added explicit clause: compaction preserves `max(sequence) == LastChangePositionRow.rawValue` (the newest row always survives — `deleteFloor < max(sequence)`); the sole exception is the empty-bootstrap case (§9.1); a compaction bug deleting the newest row is caught by the §9.1 startup invariant check → rebase | `deleteFloor` is an age/count floor below the head by construction (§8); §9.1 already detects `max(sequence)` drops |

##### No new platform facts / no new proof gates

The cycle-3 fixes introduce NO new MCP platform claim and NO new proof gate.
The one platform-adjacent statement (custom `Codable` throwing on an unknown
`cursorSchemaVersion`) is pure Swift stdlib behavior (`DecodingError`), not a
SwiftData/macOS-26 runtime claim. Every behavioral claim that depends on the
macOS 26 runtime remains covered by the existing §15 proof gates
(`J1-PLATFORM-1..5`) or is a pure-design consequence of v1 anchors 1–10.

##### Cycle-3 OPEN items retained / out of scope

- **Per-row `sequence != changePositionRaw` scan (C3-m2).** The §9.1 max-aggregate
  does NOT catch mid-row divergence below the maxima. A per-row O(rows) scan is
  deliberately NOT budgeted in `J1-PERF-4` and is deferred to a future hardening
  if a real corruption class demands it. No proof gate added (the aggregate is a
  cheap runaway/max-row guard; the primary D25 guard is the journal-vs-singleton
  equality).
- **V2-01 §3.2 `02` §12 cite (twin of C2-m1).** Still out of scope for V2-03
  (only the V2-03 doc + this sidecar are editable from this stage). Flagged for a
  V2-01 improve pass; no V2-03 gate needed.

The V2-03 doc is cycle-3 clean (both review lenses PASS); it is design-
consolidated, scaffold proof pending, with no remaining open V2-03-owned issues
from the cycle-1/2/3 review+critique+improve loop.

### 7.2 V2-04 materialization-cache platform facts (promoted from .tmp sidecar)

> Promoted verbatim from the former `.tmp/v2-research/V2-04-facts.md` sidecar
> (2026-08-15), closing DC-01. Only the sidecar's top-level `#` title was
> dropped and its `##`/`###` headings demoted to nest under this subsection;
> every fact, OPEN item, table, and cross-reference is the sidecar's own
> text, unchanged.

> MCP-verified platform facts and OPEN questions for the V2-04 design
> (`docs/v2/V2-04-materialization.md`). Each fact's verdict is either **VERIFIED**
> (MCP-fetched, sourceUrl cited) or **OPEN** (could not fetch; assigned a V2 proof
> gate in the owning doc). This file is NOT a v1 doc; it lives only in
> `.tmp/v2-research/` and owns no spec semantics. Facts here are the cycle-6
> contribution; the shared `docs/v2/V2-facts.md` carries the cross-cycle
> Vision/PDFKit/SwiftData-migration/transaction/fetch/yield facts cited by
> reference, and `.tmp/v2-research/orchestrator-verified-facts.md` carries the
> orchestrator's independent cross-check (NSFileCoordinator/FileHandle
> non-Sendability, App Intents, VersionedSchema).

#### Verified platform facts

##### File coordination (the C2 disk-cache substrate)

1. **Claim:** `NSFileCoordinator` is the class that coordinates reading/writing
   of files and directories among file presenters, available on macOS 26.
   - **Verdict:** VERIFIED.
   - **Correct statement:** `class NSFileCoordinator` coordinates "the reading
     and writing of files and directories among multiple processes and objects
     in the same process." It is an Objective-C `class` (NOT a struct), so it is
     NOT `Sendable` by synthesis → under Swift 6 complete strict concurrency it
     must be **created, used, and released entirely within one actor** (mirrors
     v1's non-`Sendable` Fuse matcher confinement in `SearchWorker`, `01` §6;
     and `V2-01`'s `VNRecognizeTextRequest` confinement, `V2-01` §6.2).
     macOS 10.7+ (iOS 5.0+, iPadOS 5.0+, Mac Catalyst 13.1+, tvOS 9.0+,
     visionOS 1.0+, watchOS 2.0+); present on macOS 26. **Per-file-operation
     usage:** "Instances of `NSFileCoordinator` are meant to be used on a
     per-file-operation basis … There is no benefit to keeping a file
     coordinator object past the length of the planned operation." **Single-
     thread:** "Each file coordinator object you create should be used on a
     single thread only." An actor's serialized executor satisfies both. This
     grounds V2-04 §6.1: a fresh `NSFileCoordinator` per coordinated operation,
     confined to the `DiskThumbnailCache` actor, released when the accessor
     closure returns; no `@unchecked Sendable`.
   - **sourceUrl:** https://developer.apple.com/documentation/foundation/nsfilecoordinator

2. **Claim:** `NSFileCoordinator` is initialized with an optional
   `NSFilePresenter`.
   - **Verdict:** VERIFIED.
   - **Correct statement:** `init(filePresenter filePresenterOrNil: (any NSFilePresenter)?)`
     — "Initializes and returns a file coordinator object using the specified
     file presenter." The presenter "is assumed to be performing the relevant
     file or directory operations and therefore does not receive notifications
     about those operations from the returned file coordinator object." macOS
     10.7+. V2-04 passes `nil` (it registers NO presenter, because V2-04 admits
     no second writer — `V2-00` §3.1; a future extension that writes the cache
     would register the presenter). This is consistent: V2-04 uses
     `NSFileCoordinator` for its documented atomic-coordination semantics +
     coordinated-write/atomic-rename crash-safety, not for inter-process
     presenter notification.
   - **sourceUrl:** https://developer.apple.com/documentation/foundation/nsfilecoordinator/init(filepresenter:)

##### File handle (the low-level disk-I/O primitive, available if needed)

3. **Claim:** `FileHandle` is a file-descriptor wrapper available on macOS 26.
   - **Verdict:** VERIFIED.
   - **Correct statement:** `class FileHandle` — "An object-oriented wrapper
     for a file descriptor." It is an Objective-C `class` (NOT `Sendable`), so
     any use must be actor-confined (same posture as `NSFileCoordinator`,
     `VNRecognizeTextRequest`). macOS 10.0+ (present on macOS 26). "Most
     creation methods for `FileHandle` cause the file handle object to take
     ownership of the associated file descriptor." Async read ops require an
     active run loop ("you must initiate the corresponding operations from a
     thread with an active run loop"). V2-04's primary disk path is `Data` +
     coordinated `FileManager` write/`replaceItem` (atomic), so `FileHandle` is
     a fallback low-level primitive, not the main path; recorded here so the
     actor-confinement posture applies if V2-06 P3 or a future optimization
     uses it.
   - **sourceUrl:** https://developer.apple.com/documentation/foundation/filehandle

##### ImageIO (the v1 thumbnail decode primitive, reused)

4. **Claim:** `CGImageSource` is the ImageIO type that reads image data,
   available on macOS 26.
   - **Verdict:** VERIFIED.
   - **Correct statement:** `class CGImageSource` — "An opaque type that you
     use to read image data from a URL, data object, or data consumer." It
     manages "the data buffers needed to load the image data and performs any
     operations on that data to turn it into a usable image. For example, it
     decompresses data stored in a compressed format. You can also use an image
     source to fetch or create thumbnail images and access metadata stored with
     the image." macOS 10.8+ (iOS 4.0+, present on macOS 26). This is the v1
     thumbnail decode/downsample primitive (`05` §14.5 "ImageIO decode occurs
     only after all SwiftData objects and context have been released"; `04` §9
     step 6 "Decode/downsample on `ThumbnailWorker`"). V2-04 reuses it
     **unchanged** — no new ImageIO dependency; the cache stores the *completed
     PNG output* of this decode, it does not change the decode. ImageIO is
     already imported in `HistoryStorage` (`01` §4), so V2-04 adds **no new
     framework import** (contrast `V2-01` which added `Vision`/`PDFKit`).
   - **sourceUrl:** https://developer.apple.com/documentation/imageio/cgimagesource

##### Cross-cycle facts reused by reference (not re-verified this cycle)

- **`ModelContext.transaction(block:)`** — the atomic-commit primitive; VERIFIED
  in `V2-03-facts.md` fact 5. V2-04's `setThumbnailCacheConfig` and
  `bumpMaterializerVersion` Authority methods use this primitive in their own
  transactions (separate from History Commits, advancing no `ChangePosition`).
- **`MigrationStage.lightweight(fromVersion:toVersion:)` + `VersionedSchema`** —
  VERIFIED in `V2-01-facts.md` / `V2-03-facts.md` and the orchestrator track.
  V2-04 adds `ThumbnailCacheConfigRow` to `HistorySchemaV2` via the same
  additive lightweight migration; it reuses the `HistorySchemaV1: VersionedSchema`
  retrofit `V2-01` established (it does not re-retrofit).
- **`AsyncStream.Continuation.yield` / `AsyncThrowingStream.Continuation.yield`**
  — non-blocking yield; VERIFIED in `V2-01-facts.md` / `V2-03-facts.md` fact 8.
  V2-04 **does NOT consume** the transient `HistoryInvalidation` yield for C1
  (the prior cycle wording that said it did is stale and corrected here): C1
  retirement is LRU-lazy (V2-04 §5.4), and v1's `HistoryInvalidation` carries
  only `latestPosition` — no `itemID` (`05` §11 step 2) — so there is no per-
  item retire signal to consume. V2-04 adds no new yield and no new suspension
  on the Authority's post-commit phase (contrast `V2-03`'s `CollectionCache`,
  which does consume the position yield).
- **xxh3 as the v1 fingerprint primitive** — established v1 (`01` §4, `05` §1).
  `ThumbnailSourceFingerprint` (xxh3-64) reuses it; no new hash. D7
  (fingerprint-is-evidence, `02` §2.2/§14) applies as it does to every v1
  fingerprint and to `V2-01`'s `EnrichmentSourceFingerprint`.
- **NSFileCoordinator / FileHandle non-Sendability + actor-confinement pattern**
  — independently cross-checked in `orchestrator-verified-facts.md` §"File
  coordination + streaming (V2-04 disk cache, V2-06 P3)," which agrees with
  facts 1 and 3 here (non-`Sendable` `class` → actor confinement, mirroring v1
  Fuse). Two-track merge: concordant.

#### OPEN questions (each assigned a V2 proof gate in V2-04 §13)

##### OPEN 1 — `NSFileCoordinator` coordinated read/write accessor signatures (C2-PLATFORM-1)

- **Question:** What are the exact Swift signatures of the `NSFileCoordinator`
  coordinated-read and coordinated-write accessors on the macOS 26 SDK, and do
  they serialize correctly under Swift 6 complete strict concurrency when
  confined to the `DiskThumbnailCache` actor?
- **What was verified:** the class (`NSFileCoordinator`), its non-`Sendability`,
  its per-file-operation/single-thread guidance, and `init(filePresenter:)`
  (facts 1, 2). The Apple-docs MCP returned 404 for the specific Swift
  method-name URLs (`coordinate(readingItemAt:options:error:byaccessor:)` /
  `coordinate(writingItemAt:options:error:byaccessor:)` and variants), and
  `search_apple_docs` returned 0 results for the method query (the search index
  is unreliable, `V2-01-facts.md` / orchestrator MCP note). The class overview
  confirms "You use instances of this class as is to read from, write to,
  modify the attributes of, change the location of, or delete a file or
  directory," establishing that coordinated read/write accessors exist.
- **Required outcome (V2-04 §6.1/§6.3):** the disk cache's read path
  (coordinated read accessor → decode `ThumbnailDiskBlobV1` → return PNG or
  miss) and write path (encode → coordinated write to temp →
  `FileManager.replaceItem` atomic rename) compile and run under Swift 6
  complete strict concurrency with the coordinator confined to the actor; no
  `@unchecked Sendable`. The accessor's `byaccessor` closure is the
  coordination boundary; the actor's executor is the single thread.
- **Proof gate:** `C2-PLATFORM-1` (V2-04 §13 Record 3). Also folds in
  crash-safety confirmation for the coordinated-write + `FileManager.replaceItem`
  atomic-rename pattern (no visible torn file on macOS 26).

##### OPEN 2 — TCC / entitlement for the app's own Caches subdirectory (C2-SECURITY-1)

- **Question:** Does reading/writing the app's own per-user Caches
  subdirectory (`<Caches>/ThumbnailCache/`) require any privacy-usage string,
  TCC permission, or entitlement on macOS 26?
- **What was verified:** nothing directly (the Apple-docs MCP does not surface
  a "no permission required" article for one's own container). The expected
  answer is **none** (it is the app's own container, like the SwiftData store
  URL v1 already uses, `05` §2/§13), but per `00` §5 the explicit-absence is
  not assumed.
- **Required outcome (V2-04 §11):** no privacy-usage string or entitlement is
  required for the disk cache directory; the disk cache works in the standard
  app sandbox without prompting.
- **Proof gate:** `C2-SECURITY-1` (V2-04 §13 Record 3 / §11).

##### OPEN 3 — iCloud backup exclusion for the disk cache directory (C2-SECURITY-2)

- **Question:** Should the disk cache directory carry
  `URLResourceKey.isExcludedFromBackupKey` (or is the Caches directory excluded
  from iCloud backup by default)?
- **What was verified:** nothing directly. The Caches directory is excluded
  from iCloud backup by Apple's default convention, but V2-04 should confirm
  for the chosen path and decide whether to set the flag explicitly (defense in
  depth for the new durable derived-preview exposure, §11).
- **Required outcome (V2-04 §11):** a documented decision — either rely on the
  Caches-default exclusion (confirmed) or set `isExcludedFromBackupKey`
  explicitly. Either way, derived thumbnail previews do not silently enter
  iCloud backup.
- **Proof gate:** `C2-SECURITY-2` (V2-04 §13 Record 3 / §11).

##### OPEN 4 — ImageIO downsample + PNG-encode byte-determinism across restarts (C2-PLATFORM-3)

- **Question:** Is ImageIO's downsample + PNG-encode byte-deterministic for
  identical source bytes + pixel size + materializer version on macOS 26,
  including across process restarts (so a C2 entry written in one launch is
  byte-identical to a fresh decode in a later launch)?
- **What was verified:** `CGImageSource` exists and is the decode primitive
  (fact 4). Byte-determinism of the *encode* output is the cache-law
  underpinning (V2-04 §5.2: "by materializer determinism, ImageIO produces
  byte-identical output for identical source bytes + pixels + materializer
  version") and is NOT documented at the byte-exact level by Apple (PNG encode
  may include nondeterministic metadata/timestamps unless explicitly
  controlled).
- **Required outcome (V2-04 §5.2/§13 Record 4):** either (a) confirm the
  pinned encoder settings produce byte-deterministic output across restarts, or
  (b) if they do not, weaken the cache-law identity claim to "semantically
  identical PNG (visually equivalent)" and record the deviation (the cache
  would serve a visually-equivalent-but-not-byte-identical PNG; still
  cache-law-faithful in the visual-preview sense). The materializer-schema-
  version mechanism (§4) scopes the determinism claim to a version.
- **Proof gate:** `C2-PLATFORM-3` (V2-04 §13 Record 3).

##### OPEN 5 — `NSFilePresenter` registration need (deferred to a future multi-writer graft)

- **Question:** Does any V2-04 path need the app to register as an
  `NSFilePresenter` for its cache directory?
- **What was verified:** `NSFilePresenter` is the presenter protocol
  coordinated by `NSFileCoordinator` (fact 1 See Also). V2-04's design answer
  is **no** — V2-04 admits no second writer (`V2-00` §3.1), so there is no
  in-process presenter to coordinate against, and no extension shares the
  container in V2. This is a design decision, not a platform-behavior gap; no
  proof gate beyond `C2-PLATFORM-1` (which confirms the no-presenter path
  compiles and serializes correctly).
- **Recorded as:** V2-04 §6.1 ("V2-04 does not register an `NSFilePresenter`…
  If a future graft admits an extension that writes the cache, that graft
  registers the presenter"). Not an OPEN that blocks V2-04; recorded for the
  future graft.

#### Summary of fact provenance

- **Directly VERIFIED this cycle (4 facts):** `NSFileCoordinator` (class,
  non-`Sendable`, macOS 10.7+, per-operation/single-thread), `NSFileCoordinator.init(filePresenter:)`,
  `FileHandle` (class, non-`Sendable`, macOS 10.0+), `CGImageSource` (class,
  macOS 10.8+).
- **Reused by reference (cross-cycle):** `ModelContext.transaction`,
  `MigrationStage.lightweight`/`VersionedSchema`, `AsyncStream.Continuation.yield`,
  xxh3, the NSFileCoordinator/FileHandle non-Sendability pattern
  (`orchestrator-verified-facts.md`).
- **OPEN (5):** `NSFileCoordinator` accessor signatures (C2-PLATFORM-1); TCC
  explicit-absence (C2-SECURITY-1); backup exclusion (C2-SECURITY-2); ImageIO
  byte-determinism (C2-PLATFORM-3); NSFilePresenter registration need
  (design decision, no gate). Each OPEN that could block V2-04 is assigned a
  proof gate in V2-04 §13; V2-04 makes no concrete platform claim without
  either a citation or a proof gate (`00` §5).

#### Verified cross-doc citations (cycle-7 / turn-14 improve pass)

The turn-14 improve pass applied design-decision fixes (the C1–C9 + R + C-m +
C-n findings in `V2-04-findings.md`); it added **no new platform facts**. The
reframes it made rest on six cross-doc citations that were re-verified by
reading the authoritative v1/V2 docs in the repo (VERIFIED = exact-text read;
these are doc citations, not MCP platform fetches). They are recorded here so
the reframes are auditable against source.

5. **Claim (C1 tag-only reframe — the caller-side discard arbiter):** v1 `04` §9
   states the off-Authority decode result is "still correctly tagged with the
   verified old reference, and the caller applies it only if its row still
   carries that reference," and a request whose reference was already stale
   before step 2 "fails there with `.staleContent`; current bytes are never
   returned under an old key."
   - **Verdict:** VERIFIED (exact text). This is the v1 caller-side contract
     V2-04 §7.1/§7.3/D31 now cite as the **sole delivery arbiter** under the
     tag-only C3 reframe (C1/R-M1): C3 tags `.superseded` and returns the
     payload tagged; it does not prevent delivery. The v1 contract governs
     application, unchanged.
   - **sourceUrl:** `docs/04-coherence.md` §9 (thumbnail version fence).

6. **Claim (G1/G3 lift substrate — completed bytes not retained):** v1 `04` §9
   step 7 states "Completed bytes are not retained by `HistoryStorage`."
   - **Verdict:** VERIFIED (exact text). This is the absence V2-04 §1.2 lifts
     (C1 retains the completed bytes the publish-fence-tagged path produces,
     including `.superseded` produces — the cache-insertion-hygiene value,
     §7.1 point 2).
   - **sourceUrl:** `docs/04-coherence.md` §9 step 7.

7. **Claim (C3 — no per-item retire signal on the post-commit yield):** v1 `05`
   §11 step 2 states the Authority's post-commit phase "synchronously yield[s]
   `HistoryInvalidation(latestPosition:)` to registered continuations."
   - **Verdict:** VERIFIED (exact text). The yield carries only `latestPosition`
     (a position fence), **not** an `itemID` — so V2-04 §5.4's drop of eager
     per-item retire-invalidation is forced: there is no per-item retire signal
     to consume (C3). C1 retirement is LRU-lazy; V2-04 adds no consumer of this
     yield (contrast `V2-03`'s position-fenced `CollectionCache`).
   - **sourceUrl:** `docs/05-authority-kernel.md` §11 step 2.

8. **Claim (C9 — the cache law V2-04 takes a bounded exception to):** v1 `04`
   §12 states: *"For the same authoritative source state and request, cache hit,
   cache miss, eviction, disabled cache, and process restart produce
   semantically identical values and failures; only latency and resource use may
   differ,"* and "Any future item cache key must contain History Item ID, the
   relevant authoritative version, complete normalized parameters, and a
   structural materializer schema version."
   - **Verdict:** VERIFIED (exact text). V2-04 §3.2/§13 Record 4 now cite this
     verbatim as one of the two statements the xxh3-64 stamp-collision residual
     is a bounded, recorded EXCEPTION to (C9) — not a re-reading of "wrong."
   - **sourceUrl:** `docs/04-coherence.md` §12.

9. **Claim (C9 — decision 15 V2-04 takes a bounded exception to + flags for
   amendment):** `V2-00` §5 decision 15 states: "Every cache obeys the v1 cache
   law and is fenced by authoritative version. C1/C2/C3 caches are
   indistinguishable from a miss; a cache key contains `HistoryItemID` + the
   relevant authoritative version + complete normalized params + a structural
   materializer schema version. A stale or evicted cache degrades to a miss,
   never to wrong bytes."
   - **Verdict:** VERIFIED (exact text). The "never to wrong bytes" clause
     admits no collision carve-out as written; V2-04 §3.2/§13 Record 4 take the
     stamp-collision residual as an explicit exception and **FLAG a `V2-00`
     amendment** (out of V2-04 scope to apply) to scope decision 15 to
     non-collision inputs (C9). Until the amendment lands, V2-04 owns the
     exception (D30) rather than claiming strict compliance.
   - **sourceUrl:** `docs/v2/V2-00-overview.md` §5 decision 15.

10. **Claim (C8/C-m11 — V2-01/V2-03 keep a collision-free serve arbiter; V2-04
    does not):** `V2-03` §7.2 states the collection cache serves "only on an
    exact three-tuple match **and** after the §7.1 fence confirms the build
    position is still current. A stale (`changePosition` behind current) … entry
    is a miss (the cache degrades to refetch, never to wrong bytes — D27),"
    i.e. `ChangePosition` is the collision-free serve arbiter. `V2-01` §5.1
    (cross-cycle, `V2-01-facts.md`) confines the enrichment D7 residual to the
    write/drain path with `ContentVersion` as the read arbiter.
    - **Verdict:** VERIFIED (`V2-03` §7.2 exact text this cycle; `V2-01` §5.1 by
      cross-cycle reference). This grounds V2-04 §3.2 point (e) + §13 Record 2
      + Record 4 contrast (C8/C-m11): V2-04 is the **only** V2 cache without a
      collision-free serve arbiter (the stamp *is* the serve identity), so its
      D7 residual lands on the read/serve path — the intentional cost of the S1
      benefit. V2-04 does **not** "mirror V2-01 exactly" (the prior claim was
      struck, C8).
    - **sourceUrl:** `docs/v2/V2-03-change-journal.md` §7.2; `docs/v2/V2-01-enrichment.md`
      §5.1 (via `V2-01-facts.md`).

##### Cycle-7 provenance addendum

- **Directly VERIFIED this cycle by doc read (6 citations):** v1 `04` §9 (caller-
  side discard contract + step-7 non-retention), v1 `05` §11 step 2
  (`HistoryInvalidation(latestPosition:)` — no itemID), v1 `04` §12 (cache law),
  `V2-00` §5 decision 15 ("never to wrong bytes"), `V2-03` §7.2 (collision-free
  serve arbiter), `V2-01` §5.1 (cross-cycle, write/drain residual).
- **No new MCP platform facts this cycle.** The OPEN set (facts 1–4 of OPEN 1–5)
  is unchanged; the improve pass did not resolve them. The design-level
  reframes (C1 tag-only, C3 LRU-lazy retirement, C7 lazy bump, C4 independent
  sweep, C5 `builtAt` anchor, C6 visually-equivalent weakening, C8/C9 exception
  framing) are recorded in `V2-04-materialization.md` §3.2/§5.4/§6/§7/§10/§11/
  §13/§14 and rest on the six citations above, not on new platform behavior.

#### Cycle-8 (turn-15 improve pass) — cycle-2 REVIEW findings applied

The turn-15 improve pass applied the "Cycle-2 REVIEW findings (turn 15)" section
of `V2-04-findings.md` (Lens A minor/nit + Lens B 3 MAJOR + minor). It added
**no new MCP platform facts** — every fix is a design-level correction resting
on v1/V2 doc citations already verified above (the OPEN set is unchanged). The
applied corrections, with the citation each rests on:

- **C2-M1 (`.published` case).** The `ThumbnailMaterializationState` enum
  declared 5 cases but `.published` was referenced as a real terminal state
  (state diagram `ready → published (terminal)`, transitions, reap discipline,
  D31). The declaration now includes `case published`. Rests on the enum's own
  state diagram + D31 (`02` §14 peer; V2-04 §7.2/§14).
- **C2-M2 (§9.2 single-flight join + per-caller fence + fence-table keying).**
  The claim "single-flight lifecycle semantics preserved: identical-concurrent-
  request join" was false under the stamp-key substitution: the join predicate
  is the stamp-based `ThumbnailCacheKey`, so different-CV-same-image requests
  coalesce (broader than v1). §9.2 now states the broader stamp-equivalence
  join, specifies the **per-caller publish fence** (each joining caller carries
  its own `HistoryItemReference`; `publishIfCurrent` re-checks each caller's
  reference, so two same-flight callers can get different outcomes), and keys
  the fence table per call via a new `ThumbnailFenceKey` (callers sharing both
  cacheKey + reference share an outcome). §7.2 state-machine ownership, §7.2
  reap discipline, §7.3/§8 pseudocode registration, §9.2 Swift sketch, and the
  D31 reap bound were updated for the per-call keying. Rests on v1 `04` §9
  step 5/step 7 (single-flight machinery) and the §3.2 stamp-keying decision.
- **C2-M3 (`diskBytesUsed` ephemeral, not a `journalBytes` mirror).** The actor
  counter is in-memory only; it is rebuilt by the startup/periodic sweep and
  reports 0 (approximate) until the first post-restart sweep. §10 stops
  claiming it mirrors `V2-03`'s durable `@Model journalBytes` and records why
  (a durable counter would route every disk insert/delete through an Authority
  transaction, violating actor-owned disk-cache isolation, §9.3/D29). Rests on
  `V2-03` §4.5/§4.6 (journalBytes IS durable) and V2-04 §9.3/D29.
- **C2-n1 (Record 2 invariant label).** "D11/D18 (plan semantics)" →
  "D16/D17/D18 (pure planning / no framework leakage / semantic-plan
  completeness)." Verified against `02` §14: D11 is monotone-occurrence, D16
  pure-planning, D17 no-framework-leakage, D18 semantic-plan-completeness.
  §10.1 already used D16/D17/D18; Record 2 now agrees.
- **C2-n2 (D7 "partially transferred" → preserved).** D7 is a v1 invariant
  V2-04 does not modify; the stamp's cache role and its residual are governed
  by the new **D30** (§14), not by altering D7. Rests on `02` §14 D7 ("Byte-
  exact confirmation: fingerprint evidence never completes a dedup decision")
  and V2-04 §14 D30.
- **C2-m4 (declare `ThumbnailSourceSelection`).** Used in §7.3/§8/§9.4 but
  undeclared; now declared in §3.2 (`Sendable` by synthesis; carries `ref`,
  `sourceBytes`, `cacheKey`; returns `nil` for no supported representation, v1
  `04` §9 step 4).
- **C2-m5 (unused `contentVersion` field).** `ThumbnailCacheEntry.contentVersion`
  was claimed "used by the C3 publish fence"; the fence re-checks the request's
  own reference, not this field. §5.1 now states it is write-on-insert,
  read-only-by-diagnostics, not on the serve path.
- **C2-m6 (`builtAt` LRU labeling).** C1's `ThumbnailCacheEntry.builtAt` was
  labeled "for LRU" but C1 evicts by the `lru` last-access map (§5.3); C2's
  `ThumbnailDiskBlobV1.builtAt` is the durable LRU anchor and C2 eviction is
  oldest-BUILD-time (a wall-clock approximation of access-LRU, since disk
  reads do not rewrite the file). Both comments corrected.
- **C2-m7 (nil branch).** §7.3/§8 pseudocode now branch on
  `thumbnailSource` returning `nil` (no supported image representation) →
  `return nil`, preserving v1 `04` §9 step 4 (no cache consultation, no decode,
  no fence registration).
- **C2-m1 (sidecar stale bullet).** This sidecar's `AsyncStream.Continuation.yield`
  bullet previously said C1 consumes the `HistoryInvalidation` yield; rewritten
  to match the §5.4 design (V2-04 does NOT consume it for C1; retirement is
  LRU-lazy; the yield carries no `itemID`).
- **C2-m3 (C1-PERF-2 hit-path budget).** Gate restated to budget the **hit
  path** specifically (source fetch + stamp + cache lookup + serve vs the miss
  path, which adds decode), not just the decode a hit avoids. (Already largely
  covered by the cycle-1 C2 rewrite; this pass makes the hit-path labeling
  explicit.)
- **C2-m2 (`ThumbnailFlightKey` substitution sign-off — no doc change).** The
  `ThumbnailFlightKey` → `ThumbnailCacheKey` join-key substitution (§9.2) is the
  most aggressive v1-surface touch in V2-04: it changes a v1 *internal* type's
  keying (reference → stamp), so concurrent same-item requests at different CV
  but same image now coalesce. It is a substitution, not a pure addition, and
  is recorded as such in §9.2/§14. Explicit reviewer sign-off is recommended at
  consolidation (recorded here per the finding; the doc already flags it in the
  §14 self-review scan).

The pass introduced one new internal type name — **`ThumbnailFenceKey`** —
registered in the §14 self-review collision scan and the `C1-COMPILE-2`
`Sendable`-types list. It collides with no v1 name and is `Sendable` by
synthesis (all-`let` `Sendable` members: `ThumbnailCacheKey`,
`HistoryItemReference`). No v1 public type, `HistoryAction` case, schema
column, codec, invariant (D1–D19), or proof gate is redefined; no new platform
claim is made (OPEN set unchanged).

### 7.3 V2-06 platform-graft (P1/P2/P3) platform facts (promoted from .tmp sidecar)

> Promoted verbatim from the former `.tmp/v2-research/V2-06-facts.md` sidecar
> (2026-08-15), closing DC-01. Only the sidecar's top-level `#` title was
> dropped and its `##`/`###` headings demoted to nest under this subsection;
> every fact, OPEN item, table, and cross-reference is the sidecar's own
> text, unchanged.

> Independent verification track. Facts verified directly via Apple docs MCP
> (`get_apple_doc_content` direct URLs) and the DocC `.md` alternate endpoint
> reached through the web reader (`https://docs.developer.apple.com/tutorials/data/documentation/<framework>/<symbol>.md`).
> Append-only. Each fact cites its source URL. OPEN questions record where a
> platform behavior is undocumented and assigns a V2 proof gate (P1-/P2-/P3- *
> per `V2-00` §4 record 3); the doc states the required OUTCOME per v1 `00` §5.

#### Foundation — localized search (P2)

##### Fact 1 — `NSString.localizedStandardContains(_:)`
- `func localizedStandardContains(_ str: String) -> Bool` — "Returns a Boolean
  value indicating whether the string contains a given string by performing a
  **case and diacritic insensitive, locale-aware** search."
- macOS 10.11+ (✓ macOS 26). iOS 9.0+, iPadOS 9.0+, Mac Catalyst 13.1+,
  tvOS 9.0+, visionOS 1.0+, watchOS 2.0+.
- This is the documented behavior P2 exact-mode locale enhancement builds on:
  case + diacritic folding, locale-aware (the substrate of "Find" UIs Apple
  documents for `localizedStandard*`).
- Source: https://developer.apple.com/documentation/foundation/nsstring/localizedstandardcontains(_:)

##### Fact 2 — `NSString.localizedStandardRange(of:)`
- `func localizedStandardRange(of: String) -> NSRange` — "Finds and returns the
  range of the first occurrence of a given string within the string by
  performing a **case and diacritic insensitive, locale-aware** search."
- Returns `NSRange` (NSString is UTF-16; `NSRange.location`/`.length` are UTF-16
  code-unit offsets), which maps directly to v1 `UTF16TextRange(location:length:)`
  (`03b` §8 — "matched ranges use UTF-16 offsets into the returned snippet").
- macOS 10.11+.
- Source: https://developer.apple.com/documentation/foundation/nsstring/localizedstandardrange(of:)
  (title/description confirmed via web-reader metadata + framework symbol browse).

##### Fact 3 — `NSString.CompareOptions` (a.k.a. `String.CompareOptions`)
- `struct CompareOptions` — "These values represent the options available to
  many of the string classes' search and comparison methods." macOS 10.0+.
- Members (verified): `caseInsensitive`, `literal`, `backwards`, `anchored`,
  `numeric`, **`diacriticInsensitive`** ("Search ignores diacritic marks"),
  **`widthInsensitive`** ("Search ignores width differences in characters that
  have full-width and half-width forms, as occurs in East Asian character
  sets"), `forcedOrdering`, `regularExpression`.
- `localizedStandardContains`/`localizedStandardRange` already fold case +
  diacritics; `CompareOptions` is the lower-level `range(of:options:range:locale:)`
  substrate P2 may use where explicit option/locale control is required.
- Source: DocC `.md` alternate —
  https://docs.developer.apple.com/tutorials/data/documentation/foundation/nsstring/compareoptions.md

##### Fact 4 — Swift `String` overlay `localizedStandardContains(_:options:)` family (OPEN-verified bridge, signature OPEN)
- The Swift `String` overlay exposes
  `func localizedStandardContains<T>(_ other: T, options: String.CompareOptions = []) -> Bool where T : StringProtocol`
  and `func localizedStandardRange<T>(of string: T, options: String.CompareOptions = [], locale: Locale? = nil) -> Range<Index>?`
  — adding `options:` and `locale:` parameters over the NSString bridge
  (Facts 1–2). The NSString bridge behavior (case + diacritic insensitive,
  locale-aware) is **verified** (Facts 1–2); the Swift overlay's exact
  signature/parameter labels on macOS 26 are carried as **OPEN 3 → P2-PLATFORM-1**
  (the direct symbol URLs 404 and are not URL-verified here).
- Source (behavior): Facts 1–2. Source (overlay signature): OPEN 3.

#### Foundation — `FileHandle` streaming (P3)

##### Fact 5 — `FileHandle` class
- `class FileHandle` — "An object-oriented wrapper for a file descriptor."
  macOS 10.0+ (iOS 2.0+).
- Source: https://developer.apple.com/documentation/foundation/filehandle

##### Fact 6 — `FileHandle.bytes` and `FileHandle.AsyncBytes` (the streaming API)
- `var bytes: FileHandle.AsyncBytes { get }` — "The file's contents, as an
  **asynchronous sequence of bytes**." Use `for await byte in handle.bytes`;
  supports `.prefix(n)` to skip/take, plus `.characters`/`.unicodeScalars`/
  `.lines` for text. macOS **12.0+** (iOS 15.0+, tvOS 15.0+, watchOS 8.0+).
- `struct FileHandle.AsyncBytes` — conforms to `AsyncSequence` (Element `UInt8`).
  macOS 12.0+.
- This is the public, bounded-memory streaming primitive P3 reads large
  blob-store files through (zero full-`Data` materialization on the read path).
- Apple tip (verified, in the `bytes` doc): "Rather than creating a FileHandle
  to read a file asynchronously, you can instead use a `file://` URL in
  combination with the `URL.resourceBytes` property" — an equivalent streaming
  entry point P3 may use.
- Sources:
  - https://docs.developer.apple.com/tutorials/data/documentation/foundation/filehandle/bytes.md
  - https://docs.developer.apple.com/tutorials/data/documentation/foundation/filehandle/asyncbytes.md

##### Fact 7 — Synchronous `FileHandle` read/write (length-bounded)
- `func read(upToCount: Int) -> Data` — "Reads data synchronously up to the
  specified number of bytes."
- `func readToEnd() -> Data?` — "Reads the available data synchronously up to
  the end of file or maximum number of bytes."
- `func write(contentsOf: Data)` — "Writes the specified data synchronously to
  the file handle."
- `func seek(toOffset:)`, `func offset()`, `func synchronize()`,
  `func close()` — random access + fsync + close. (`readDataToEndOfFile()`,
  `readData(ofLength:)`, `write(_:)` are listed **Deprecated** — P3 uses the
  non-deprecated Swift spellings.)
- Source: https://docs.developer.apple.com/tutorials/data/documentation/foundation/filehandle.md

#### SwiftData / CoreData — store-change detection (P1) and `.externalStorage` (P3)

##### Fact 8 — SwiftData `Schema.Attribute.Option.externalStorage`
- `static var externalStorage: Schema.Attribute.Option { get }` — "**Stores the
  property's value as binary data adjacent to the model storage.**" macOS 14.0+
  (Swift 5.9+). iOS 17.0+.
- The documentation describes `.externalStorage` purely as a *storage-location
  hint* ("adjacent to the model storage"). It documents **no public API to
  obtain a file URL** for an externally-stored blob; the value is accessed only
  through the property's `Data`. This is consistent with v1's stance that
  `.externalStorage` "is an implementation hint. Correctness, byte limits, and
  read isolation do not depend on whether SwiftData stores a blob inline or
  externally" (`05` §3.1; `01` §10).
- **Implication for P3:** a true zero-materialization stream directly over an
  existing `.externalStorage` blob is **not available through public API** on
  macOS 26 (carried as OPEN 4 → `P3-PLATFORM-1` to confirm at the SDK). Meeting
  the G8 memory-budget OUTCOME therefore requires P3 to store large
  representations as **process-owned blob-store files** (referenced by a
  versioned handle) that `FileHandle.AsyncBytes` (Fact 6) can stream. This is a
  physical-medium change behind a versioned blob codec (M1 layer 2), **not** a
  logical-content / `ContentVersion` change — recorded honestly in the doc.
- Source: https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage

##### Fact 9 — `NSPersistentStoreCoordinator` store metadata (CoreData has it; SwiftData hides it)
- `class NSPersistentStoreCoordinator` — "Use a coordinator to add or remove
  persistent stores, change the type or location on-disk of those stores,
  **query the metadata of a specific store**, defer a store's migrations, …"
  macOS 10.4+. CoreData exposes per-store metadata
  (`metadata(for:)` / `setMetadata(_:for:)`) on the coordinator.
- **Implication for P1:** CoreData has a store-metadata/generation-token surface
  a "store unchanged since last open" checkpoint *could* in principle use, but
  SwiftData's `ModelContainer` does **not** publicly expose the underlying
  coordinator (carried as OPEN 1 → `P1-PLATFORM-1`). Reaching for it would be a
  private/fragile dependency. The clean, v1-faithful P1 unchanged-detector is
  the v1-owned **`ChangePosition`** singleton (`LastChangePositionRow`,
  `05` §3.2): one O(1) scalar read that advances on every History Commit. Since
  the Signature set changes only on create/delete and `ChangePosition` advances
  on every commit, `checkpointPosition == currentPosition` ⟹ no commit since
  checkpoint ⟹ Signature set identical ⟹ the checkpointed index is reusable.
  This avoids any CoreData-generation-token dependency entirely.
- Source: https://developer.apple.com/documentation/coredata/nspersistentstorecoordinator

---

#### OPEN questions (assign V2 proof gates; doc states the required OUTCOME)

##### OPEN 1 — SwiftData hides the CoreData coordinator / generation token (`P1-PLATFORM-1`)
- CoreData exposes store metadata + (in SQLite) an internal generation counter
  via `NSPersistentStoreCoordinator`; SwiftData's `ModelContainer` does not
  document a public accessor for either on macOS 26.
- Required OUTCOME (stated regardless): P1's fast-path unchanged-detector is
  the v1-owned `ChangePosition` (O(1) singleton scalar read), NOT a CoreData
  generation token. The checkpoint is a self-managed `StartupCheckpointRow`.
- Proof gate `P1-PLATFORM-1`: confirm on the macOS 26 SDK that no public
  SwiftData API exposes a store-generation token; the design does not depend on
  one either way.

##### OPEN 2 — Scalar read isolation for the checkpoint + position rows (`P1-PLATFORM-2`)
- The fast path reads exactly `StartupCheckpointRow` and
  `LastChangePositionRow` as scalars and must not fault Canonical / signature /
  checkpoint-index blobs except when reuse is decided (Part VI §7.5 / `05` §14).
- Proof gate `P1-PLATFORM-2`: `FetchDescriptor` reads the two singleton rows'
  scalar fields without blob faulting; the reused `indexBlob` is decoded only
  after the position equality check passes.

##### OPEN 3 — Swift `String` overlay `localizedStandardContains(_:options:)` / `localizedStandardRange(of:options:locale:)` signature (`P2-PLATFORM-1`)
- The NSString bridge behavior is verified (Facts 1–2). The Swift `String`
  overlay's exact parameter labels (`options:`, `locale:`) and return type
  (`Range<Index>?` vs `NSRange`) on macOS 26 are not URL-verified here (direct
  symbol URLs 404).
- Proof gate `P2-PLATFORM-1`: confirm the Swift overlay signatures P2 calls;
  if only the NSString bridge is available, P2 adapts through `NSString`/
  `NSString.localizedStandardRange(of:)` returning `NSRange`.

##### OPEN 4 — `.externalStorage` exposes no public file URL (`P3-PLATFORM-1`)
- Fact 8 documents `.externalStorage` as an opaque "adjacent to the model
  storage" hint with no documented file-URL accessor.
- Required OUTCOME (stated regardless): P3 stores large representations as
  process-owned blob-store files (referenced by a versioned handle) and streams
  them via `FileHandle.AsyncBytes` (Fact 6). A pure read-stream over existing
  `.externalStorage` is **not** the P3 design.
- Proof gate `P3-PLATFORM-1`: confirm on macOS 26 that no public SwiftData API
  yields a file URL for an `.externalStorage` blob; the blob-store-tier design
  is taken regardless.

##### OPEN 5 — `FileHandle.AsyncBytes` bounded-memory streaming over a blob file (`P3-PLATFORM-2`)
- `AsyncBytes` is an `AsyncSequence` of `UInt8` (Fact 6); bounded-memory chunked
  consumption via `.prefix(n)`/`reduce(into:)` is the documented pattern.
- Proof gate `P3-PLATFORM-2`: prove peak resident memory on a streamed read of a
  near-64 MiB blob file is bounded by the chunk size, not by the file size
  (i.e., the async iterator does not internally buffer the whole file).

##### OPEN 6 — `localizedStandardRange` UTF-16 offset stability into the excerpt (`P2-PLATFORM-2`)
- v1 `matchedRanges` are UTF-16 offsets into the returned snippet (`03b` §8).
  `localizedStandardRange` returns an `NSRange` over the searched NSString
  (UTF-16). P2 must translate that range through the `03b` §8 excerpt-windowing
  algorithm into the final snippet's UTF-16 space.
- Proof gate `P2-PLATFORM-2`: fixture-prove the range→snippet-offset
  translation is stable across the supported locales (no locale-dependent
  index drift between the `localizedStandardRange` result and the excerpt).

##### OPEN 7 — Performance gates (the G5/G7/G8 triggers, restated as proof)
- `P1-PERF-1`: **blocked by the V2-06 DATA-11 controlling amendment**. Any
  future checkpoint proof must preserve authoritative Canonical coverage on a
  hit and then show the admitted path clears the 250 ms G5 bar; the obsolete
  metadata-only reuse claim is not executable.
- `P2-PERF-1`: locale-sensitive exact search p95 and correctness across the
  supported locales within the v1 search cost model (`06` §9 — scan all bounded
  scalar projections, no cache).
- `P3-PERF-1`: peak capture-path and read-path memory within the G8 budget for
  a near-max-size representation workload; p95 copy cost not inflated by the
  blob-store write.

---

#### Cycle-3 verified facts + decisions (IMPROVE turn 27, appended)

> Appended by the IMPROVE (editor) pass that applied the turn-25/26 review and
> critique findings. MCP-verified facts first, then the design decisions made
> (each keyed to the finding it closes).

##### Fact 10 — `NSString.range(of:options:range:locale:)` (the verified locale+options substrate)
- Declaration (verified):
  `func range(of searchString: String, options mask: NSString.CompareOptions = [], range rangeOfReceiverToSearch: NSRange, locale: Locale?) -> NSRange`
- "Finds and returns the range of the first occurrence of a given string within a
  given range of the string, subject to given options, using the specified locale,
  if any."
- Returns `NSRange`; "Returns `{NSNotFound, 0}` if `aString` is not found or is
  empty (`""`)." The returned range is "relative to the start of the string, not
  to the passed-in range."
- Discussion: "NSString objects are compared by checking the Unicode canonical
  equivalence of their code point sequences."
- Platform availability (verified): macOS 10.5+, iOS 2.0+, iPadOS 2.0+, Mac
  Catalyst 13.1+, tvOS 9.0+, visionOS 1.0+, watchOS 2.0+.
- **Why this fact matters (closes C-M1, R-m5, Lens-A M2).** The Swift overlay
  `localizedStandardRange(of:options:locale:)` signature is OPEN (`P2-PLATFORM-1`,
  Fact 4). The verified locale+options-taking substrate is this NSString method,
  not the 1-arg `localizedStandardRange(of:)` (which takes no options and uses the
  system locale). P2's locale-folding exact predicate is therefore implementable
  entirely on verified API: `.caseInsensitive` + `.diacriticInsensitive` (baseline,
  matching the verified `localizedStandard*` default, Fact 1) + `.widthInsensitive`
  for CJK locales (Fact 3). Width folding for CJK is delivered by a verified
  `CompareOptions` member through a verified API — not an overclaim.
- Source: https://developer.apple.com/documentation/foundation/nsstring/range(of:options:range:locale:)
  (page + platform analysis fetched turn 27 via `get_apple_doc_content` with
  `includePlatformAnalysis=true`).

##### Fact 11 — `localizedStandard*` default folds case + diacritics ONLY (re-confirmed)
- Fact 1 already establishes the documented behavior of
  `localizedStandardContains(_:)` / `localizedStandardRange(of:)` is "case and
  diacritic insensitive, locale-aware" — nothing more. **Width is NOT part of the
  default**; `.widthInsensitive` is a separate `CompareOptions` member (Fact 3).
- Re-confirmed turn 27 because the prior doc draft (§4.1) overclaimed
  "case + diacritic + width folding (verified, §2)". The corrected claim
  (§4.1/§4.4/D38): case + diacritic folding is the verified default; CJK width
  folding is delivered by an explicit `.widthInsensitive` (verified member) for
  CJK locales. No width-folding behavior is presented as verified-by-default.
- Sources: Facts 1 and 3.

##### Decisions recorded this cycle (each keyed to its finding)

- **C-M1 → DECISION (option: `.widthInsensitive` for CJK).** P2 uses a
  fixture-locked per-locale `effectiveSearchOptions(_:)` set: baseline
  `[.caseInsensitive, .diacriticInsensitive]`, plus `.widthInsensitive` for CJK
  locales (`ja`). Implemented via the verified `NSString.range(of:options:range:locale:)`
  (Fact 10). Supported locales pinned to `["de", "en", "ja", "nb", "tr"]`
  (covers every locale named as a motivating case in §4.2: de ß/ss, ja CJK width,
  nb Scandinavian å, tr dotted-i, en baseline). No new OPEN gate (mechanism
  verified); P2-PLATFORM-1 now covers only the optional Swift overlay convenience.
- **C-M2 → DECISION (promote public).** `BlobStreamingHistory` + `BlobReadStream`
  are `public` in `HistoryCore` (Foundation-only), so V2-07 (PresentationUI) can
  consume them across the `01` §8 target boundary. `BlobStore`, V2 codecs, and
  `StoredBlobHandleV1` stay `internal` to `HistoryStorage`.
- **C-M3 → DECISION (streaming integrity window, documented residual).** xxh3 is
  a whole-file hash; `byteCount` is checked up-front (catches length-changing
  corruption pre-stream), but xxh3 is verifiable only at stream end. A
  length-preserving bit-flip is therefore detected only after a streaming
  consumer has received wrong bytes (the iterator throws
  `.corruptStoredValue` at stream end — fail-closed after the fact). The
  "first-chunk" phrasing is dropped. Consumers needing byte-identity before any
  byte is vended use the `Data` surface (eager xxh3).
- **C-M4 → DECISION (durability boundary disclosed).** P3 trades SwiftData-atomic
  `.externalStorage` for app-managed sidecar files under `<storeURL>.blobs/`
  (outside SwiftData txn control). Backup/restore/sync MUST capture `.blobs/`;
  single-blob loss degrades the item to `.corruptStoredValue` (D2, never silently
  substituted); no inline fallback exists for handle-backed reps after migration.
- **C-M5 → DECISION (option a — self-healing, preserves `04` §5).** Locale/
  enabling changes yield an internal **predicate-change signal** (a
  `HistoryInvalidation`-peer wake-up carrying the *current* `ChangePosition`,
  not advancing it). v1's observe loop keys re-broadcast on `position >` the page
  (`04` §5 step 6), so the same-position `HistoryInvalidation` channel alone would
  NOT self-heal a predicate change; P2 therefore extends the `observe(.search)`
  consumer (internal, `V2-00` §2.1) to honor the predicate-change signal as a
  distinct wake condition that re-queries under the new predicate at the current
  position. Non-search observers ignore it. No `ChangePosition` advance; D5/D6
  preserved; `04` §5 race-free contract preserved for corpus changes.
- **M3 (lazy→eager) → DECISION (eager at M1).** A lazy P3 migration would force
  the read path to dispatch on `formatVersion` and decode either V1 or V2 codecs
  — that dual-decode is P3's read surface, not an M1-plan detail. P3 commits to
  **eager** migration: every row rewritten to V2 at M1, read path is V2-only,
  no read-side V1 fallback. Cost O(retained) (≤ 5,000 items, ≤ 64 MiB/rep, `06`
  §2). This also makes "no inline fallback post-migration" (C-M4) literally true.
- **R-m4 → D9 re-citation.** D9 (`02` §14) is the dedup *winner* tie-breaker
  (locale-independent); v1 search determinism lives in `04` §7. The doc now cites
  `04` §7 for search determinism (per locale) and reserves D9 for dedup, in §4.2,
  §4.7, D38, and P2 Record 2.
- **R-M1 → disclosed.** P3 blob files are a process-owned-file medium written by
  `IngestPreparationActor`/`RevisionPreparationActor` via `BlobStore` with no
  `ModelContext`/`HistoryItemRow` mutation/`ChangePosition` advance — not a v1
  "second writer" (the v1 single-writer rule is `ModelContext`-scoped). Commit-
  coupling is via the V2 codec row written inside the Authority's commit txn.

##### Open numbering alignment
- Doc §11 OPEN numbering is aligned to this sidecar: OPEN 3 = `P2-PLATFORM-1`,
  OPEN 4 = `P3-PLATFORM-1`, OPEN 5 = `P3-PLATFORM-2`, OPEN 6 = `P2-PLATFORM-2`
  (now also covering projection-input safety for locale folding), OPEN 7 = PERF.
  (Prior draft had OPEN 4/5/6 in a different order; the gate names were always
  consistent, only the serial numbers diverged.)

### 7.4 V2-07 UX platform facts (promoted from .tmp sidecar)

> Promoted verbatim from the former `.tmp/v2-research/V2-07-facts.md` sidecar
> (2026-08-15), closing DC-01. Only the sidecar's top-level `#` title was
> dropped and its `##`/`###` headings demoted to nest under this subsection;
> every fact, OPEN item, table, and cross-reference is the sidecar's own
> text, unchanged.

> Sidecar for `docs/v2/V2-07-ux.md`. Records MCP-verified platform facts and OPEN
> questions. V2-07 owns no graft and introduces no new public DTO, so the fact set
> is small: most of V2-07 is architecture/integration grounded in the v1 docs
> (`01` §6, `03b`, `04` §5, `06` §1 point 3) and the sibling V2 docs' finalized UX hooks
> (`V2-01` §12, `V2-02` §12, `V2-03` §13, `V2-04` §12, `V2-05` §13, `V2-06` §10).

#### Cycle 1 — Verified facts

##### Fact 1 — `@Observable` macro availability (VERIFIED)

**Source:** [Observable()](https://developer.apple.com/documentation/observation/observable())
via `mcp__apple-docs__get_apple_doc_content`.

- Macro: `@attached(member, ...) @attached(memberAttribute)
  @attached(extension, conformances: Observable) macro Observable()`.
- **Platform availability (declared on the doc):** iOS 17.0+, iPadOS 17.0+, Mac
  Catalyst 17.0+, **macOS 14.0+**, tvOS 17.0+, visionOS 1.0+, watchOS 10.0+.
- **Verdict:** present on macOS 26. Used by V2-07 §8.3 for main-actor presentation
  state (the Swift 6 evolution of v1's "observable presentation state," `01` §6).
- **Proof gate:** `UX-PLATFORM-1` (confirm on the macOS 26 runner SDK; the
  availability is declared, the gate is the runner confirmation).

##### Fact 2 — `LocalizedStringResource` availability (VERIFIED)

**Source:** [LocalizedStringResource](https://developer.apple.com/documentation/foundation/localizedstringresource)
via `mcp__apple-docs__get_platform_compatibility`.

- **Platform availability:** iOS 16.0+, iPadOS 16.0+, Mac Catalyst 16.0+,
  **macOS 13.0+**, tvOS 16.0+, visionOS 1.0+, watchOS 9.0+. Cross-platform: yes.
- **Verdict:** present on macOS 26. Used by V2-07 §10 as the backing type for
  every V2 user-facing string (state-3 localization acceptance, `06` §1 point 3).
- **Proof gate:** `UX-PLATFORM-1`.

##### Fact 3 — SwiftUI is the v1 PresentationUI framework (inherited, non-controversial)

**Source:** v1 `01` §4 (Dependency classification: "SwiftUI — Framework — Confined
to `PresentationUI`") and `01` §6 (Main actor: "SwiftUI views, observable
presentation state …").

- SwiftUI has been the PresentationUI framework since the v1 design; it is
  available macOS 11.0+ (long-established, not re-verified here).
- **Verdict:** present on macOS 26 by v1 assumption. V2-07 adds no new framework
  import to `PresentationUI` (`UX-COMPILE-1`).

#### OPEN questions (assigned to proof gates or recorded as sibling-doc couplings)

##### OPEN-1 — No OCR-completion notification stream in `EnrichmentHistory` (sibling-doc coupling)

**Where:** `V2-01` §12 ("V2-07 re-browses on OCR-completion notification and on
toggle") vs `V2-01` §8 (`EnrichmentHistory` public surface:
`enrichmentStatus(for:)`, `setEnrichmentEnabled(_:)` — no observation stream).

**Issue:** V2-01 §12 references an "OCR-completion notification" the UI re-browses
on, but `EnrichmentHistory` exposes no such stream. A push-based OCR-completion
notification would require a V2-01 protocol extension (e.g., an enrichment-status
observation stream, mirroring `ClipboardHistory.observe`). V2-07 does **not**
introduce one (it is V2-01's surface to own).

**V2-07 resolution (stated in §4.2/§5.1):** the UI re-browses on (a) the next real
History Commit (always reflects current enrichment state, since `browse(.search)`
re-captures the `SearchCorpusSnapshot` including any persisted enrichment text,
`V2-01` §4.1) and (b) explicit user action (toggle, open). A badge may read
`.pending` after OCR completed, until the next re-browse; the accessibility label
states "pending at last refresh." No polling loop is introduced (`UX-PERF-1`).

**Action:** surface back to V2-01 in the next review cycle — either (i) V2-01 §12
softens "OCR-completion notification" to "next History Commit or explicit
re-browse," or (ii) V2-01 adds an enrichment-status observation stream if
push-based freshness is product-required. Not a V2-07 blocker.

##### OPEN-2 — No public current-retained-bytes read in V2-02 (sibling-doc coupling)

**Where:** brief-V2-07.md "Live storage-usage indicator" vs `V2-02` §3.2
(`RetentionExpansionItemSummary.canonicalBytes`/`revisionBytes` are
`package`-internal Domain planning facts) and `V2-02` §12 (UX hooks list no
live-usage read).

**Issue:** V2-02 exposes the *budget* (`HistoryRetentionPolicies.storage.
maxTotalBytes`) and the `.retentionPoliciesSet(retiredItems:prunedRevisions:)`
receipt, but **no public current-retained-bytes read**. A live storage-usage
indicator (the brief's candidate) therefore has no DTO to sum.

**V2-07 resolution (stated in §5.2):** V2-07 does **not** invent a public read for
it (that would be V2-07 overstepping into V2-02's surface). The settings panel
shows the configured budget; a live usage readout requires a V2-02 protocol
extension (e.g., `RetentionPolicyHistory.retainedStorageUsage() -> RetainedBytes`
on a distinct-concern protocol), to be added by V2-02 if product-approved.

**Action:** surface back to V2-02 in the next review cycle if a live indicator is
product-required. Not a V2-07 blocker.

##### OPEN-3 — `EnrichmentHistory` panel-level config read (minor)

**Where:** V2-07 §8.3 example `EnrichmentSettingsViewModel.load()`.

**Issue:** `EnrichmentHistory` exposes `enrichmentStatus(for:)` (per-item) and
`setEnrichmentEnabled(_:)`, but no panel-level "is enrichment enabled?" read. The
settings panel's toggle state on panel-open needs the current `enabled` value.

**V2-07 resolution:** the panel obtains the current `enabled` state either by (i)
a per-item status read on a representative/sentinel item (awkward), or (ii) a
V2-01 protocol addition `enrichmentEnabled() async throws -> Bool`. The honest
statement is that V2-01's public surface under-serves the settings panel slightly;
V2-07 does not invent the read.

**Action:** minor; surface back to V2-01. The toggle still works (the user sets
it; the panel refreshes on next open via whatever read V2-01 exposes). Not a
V2-07 blocker.

##### OPEN-4 — Accessibility-modifier symbol availability on macOS 26 (proof gate)

**Where:** V2-07 §9/§12 `UX-PLATFORM-2`.

**Issue:** the SwiftUI View accessibility modifiers (`accessibilityLabel`,
`accessibilityHint`, `accessibilityValue`) are long-established SwiftUI surface
(macOS 11.0+, iOS 14.0+), but the exact Apple-docs symbol URLs did not resolve
under `mcp__apple-docs__get_apple_doc_content` / `get_platform_compatibility`
(404 / analysis failure), and `mcp__apple-docs__search_apple_docs` returned 0
results (the known MCP search gap the orchestrator warned about). WebFetch to
developer.apple.com was blocked by network policy.

**V2-07 resolution (stated in §12 `UX-PLATFORM-2`):** per `00` §5, the required
**OUTCOME** is stated regardless — every V2 status/indicator/control compiles
with an accessibility label on macOS 26 and is reachable/navigable by VoiceOver;
where a specific modifier is unavailable, an equivalent accessibility attribute is
applied so no V2 control is unlabeled. Confirmed at scaffold time on the macOS 26
runner.

**Action:** `UX-PLATFORM-2` confirms on the runner. No design dependency on the
unverified symbol spelling — the accessibility API surface is stable and
non-controversial; the gate is the runner confirmation.

##### OPEN-8 - V2-03 §13 "reconnect notification" wording defect (sibling-doc coupling, parallel to OPEN-1)

**Where:** `V2-03` §13 (line 2022) vs `V2-03` §6.3 (`ReconnectHistory` public
surface).

**Issue:** V2-03 §13 (line 2022) literally states "the view re-browses on reconnect
notification, it does not subscribe to a delta stream," but `ReconnectHistory`
(`V2-03` §6.3) exposes **no** push notification — only `changes(since:)` and
`currentReconnectAnchor()` (both pull reads). No "reconnect notification" ever
reaches the UI; the HCR does not enter the v1 observer's wake path (D28,
`V2-03` §16). This is structurally identical to OPEN-1 (V2-01 §12's "OCR-completion
notification" wording vs `EnrichmentHistory`'s no-stream surface).

**V2-07 resolution (stated in §5.3/§14):** V2-07's pull-only re-browse contract
(§5.3) is authoritative — the surface refreshes only on explicit user pull/re-open;
a stale "recently removed" list is expected until refresh (mirrors §4.2.3
pending-state honesty). No polling loop is introduced.

**Action:** surface back to V2-03 in the next review cycle — V2-03 §13 must amend
the "reconnect notification" phrasing (soften to "next History Commit or explicit
re-browse"), parallel to OPEN-1's V2-01 §12 amendment. Not a V2-07 blocker.

#### Summary

V2-07's platform surface is minimal: two verified facts (`@Observable` macOS
14.0+, `LocalizedStringResource` macOS 13.0+) plus the inherited SwiftUI framework
fact. The five OPEN items are either sibling-doc couplings (OPEN-1/2/3/8 — to
surface back to V2-01/V2-02 in the next review cycle, not V2-07 blockers) or a
runner-confirmation proof gate (OPEN-4 → `UX-PLATFORM-2`). V2-07 makes no concrete
platform claim without either a citation or a proof gate, exactly as v1 (`00` §5).

#### Cycle 2 - Verified facts (improve turn 32)

This cycle applied the confirmed review (turn 30) + critique (turn 31) findings
(Lens A curated C-M1/C-M2/C-m1-C-m5/C-n1, plus Lens B). Most curated fixes were
already present in the doc from cycle 1; this cycle's residual corrections and the
Lens B Major-4 part-2 addition (OPEN-8) were verified against the source docs
directly (MCP `get_apple_doc_content` having already covered the macro/localization
platform facts in cycle 1, so no new platform-fetch was needed):

##### Fact 4 - v1 state-3 acceptance location is `06` §1 point 3 (VERIFIED)

**Source:** `docs/06-cross-cutting.md` §1 ("Status boundary"), point 3: "Product
implementation complete: UI, pasteboard behavior, packaging, accessibility,
localization, and non-skeleton product tests pass." §11 is "Completion statement"
(unrelated to state-3 acceptance).

- **Verdict:** the sidecar's two `06` §11 citations (state-3 localization
  acceptance) were miscitations; corrected to `06` §1 point 3 (C-m5 sidecar). The
  main doc already cited `06` §1 point 3 throughout (the five C-m5 main-doc places
  were already correct; only the sidecar carried the error).

##### Fact 5 - `LocalizedSearchHistory`/`LocalizedSearchStatus` are at `V2-06` §4.5, not §4.6 (VERIFIED)

**Source:** `docs/v2/V2-06-platform-grafts.md` §4.5 ("Code model"), lines 671/677:
`public protocol LocalizedSearchHistory` and `public struct LocalizedSearchStatus`
are both declared in §4.5. §4.6 is "P2 proof gates" (line 729) — not where these
symbols live.

- **Verdict:** V2-07 §4.1 contrast-table and §7 references to `V2-06` §4.6 for
  these symbols were miscitations; corrected to §4.5 (C-n1). (V2-07 §5.6 was already
  §4.5; the §4.1-table and §7 references remained §4.6 and are now fixed.) The
  `V2-03` §10.3/§4.6 reference in V2-07 §5.3 is correct and unchanged: V2-03 §4.6
  is "JournalConfigRow (singleton)," where `JournalConfigRow` lives.

##### Fact 6 - V2-06 predicate-change signal is search-only (VERIFIED)

**Source:** `docs/v2/V2-06-platform-grafts.md` §4.5, lines 718-719: "A non-search
observer (`observe(.recent)`) ignores the predicate-change signal — its result does
not depend on the search predicate."

- **Verdict:** V2-07 §4.4's freshness-rule summary grouped `observe(.recent)` under
  clause (b) (P2 predicate/locale self-heal); that conflated the two observers.
  Corrected: clause (b) is scoped to `observe(.search)` only; `observe(.recent)` is
  predicate-independent and ignores the signal. (Lens A correctness finding,
  verified against the owning doc.)

##### Fact 7 - V2-02 §3.1 both-nil rule is revisions-only (VERIFIED)

**Source:** `docs/v2/V2-02-retention.md` §3.1, line 174: "A `RevisionRetention`
with **both** thresholds `nil` is normalized at the ..." — the both-nil
normalization applies to `RevisionRetention.maxRevisionsPerItem`/
`maxRevisionBytesPerItem` sub-thresholds only. Disabling the age or storage
dimension is the top-level `Optional` (`age == nil` / `storage == nil`); there is
no both-nil rule for those.

- **Verdict:** V2-07 §5.2's "Disabling a dimension sends `nil` (normalized per
  V2-02 §3.1 both-nil rule)" overstated the rule's scope to all three dimensions.
  Corrected: the both-nil rule is revisions-only. (Lens A correctness finding,
  verified against the owning doc.)

##### Fact 8 - V2-03 §13 "reconnect notification" wording is a defect (VERIFIED)

**Source:** `docs/v2/V2-03-change-journal.md` §13, line 2022: "the view re-browses
on reconnect notification, it does not subscribe to a delta stream." Vs `V2-03`
§6.3 (`ReconnectHistory`: `changes(since:)`/`currentReconnectAnchor()` only — pull
reads, no push) and §16/D28 (HCR does not enter the v1 observer's wake path).

- **Verdict:** no "reconnect notification" exists in `ReconnectHistory`'s public
  surface; the §13 wording is structurally identical to V2-01 §12's
  "OCR-completion notification" wording (OPEN-1). Recorded as OPEN-8 (parallel to
  OPEN-1): V2-07's pull-only re-browse contract (§5.3) is authoritative; V2-03 §13
  must amend the phrasing. (Lens B Major-4 part 2.)

##### Fact 9 - V2-01 §12 "OCR-completion notification" wording confirmed (VERIFIED)

**Source:** `docs/v2/V2-01-enrichment.md` §12, line 1512: "V2-07 re-browses on
OCR-completion notification and on toggle" (and line 502). Vs `V2-01` §8
(`EnrichmentHistory`: `enrichmentStatus(for:)`/`setEnrichmentEnabled` only — no
stream).

- **Verdict:** confirms OPEN-1's escalation (already in the main doc §14): the
  "OCR-completion notification" phrasing in V2-01 §12 is the defect V2-01 must
  amend; V2-07's re-browse contract (§4.2) is authoritative. No new action beyond
  what OPEN-1 already records.

##### Cycle-2 changes applied to the main doc

- C-m5 sidecar: two `06` §11 -> `06` §1 point 3 (Fact 4).
- C-n1 residual: V2-07 §4.1 table + §7 `V2-06` §4.6 -> §4.5 (Fact 5).
- §4.4: clause (b) scoped to `observe(.search)` only (Fact 6).
- §5.2 both-nil: revisions-only scope (Fact 7).
- §5.2 spurious-invalidation: user-visible list-refresh cost noted (Lens B nit).
- §5.3 + §14: OPEN-8 added (Fact 8).
- §6.1: consolidated V2 settings panel flagged as new V2-07 surface (Lens B minor).
- §6.3: count-vs-retention action split flagged as deliberate fragmentation point
  (Lens B minor).
- (Already present from cycle 1 and re-verified present this cycle: C-M1 OPEN-5
  journal-admin gating/§8.2 cast/§6.1-§6.2; C-M2 OPEN-6 + UX-PERF-1 rewrite; C-m1/
  C-m4 OPEN-3 write-only disclosure; C-m2 P3 out-of-scope + OPEN-7 seam; C-m3 §5.3
  pull-only contract; Lens B Major-1/2/3 + Major-4 part-1.)
