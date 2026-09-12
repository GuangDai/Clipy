# Compact panel and copy sources

User direction, 2026-09-09: Clipy is a small utility. Make content easy to
scan, move application icons and copy information into the expanded pane,
and use a coherent contemporary Apple visual style. Equal content from
different applications remains one history item; retain the applications'
individual copy times and show only a small multiple-source indicator in
the list.

## Information hierarchy

- Default browsing width: 360 pt, user-resizable with no forced minimum.
  The default 420 pt height is a ceiling, never a minimum. Both the list and
  the independent 340 pt floating preview fit their own content.
- Compact rows: 16 pt content/type slot, 13 pt system title, 2 pt vertical
  padding plus 2 pt list insets: 24 pt total. Comfortable density uses a 24 pt slot.
  Search snippets appear only when they provide body-match evidence.
- Row accessories: multiple-source indicator and pin ordinal. Source icons,
  bundle identifiers, timestamps and occurrence counters leave the list.
- Search: one stable field and two 24 pt icon controls. Search mode remains
  available through the menu and Command-1/2/3; active filtering and nondefault
  search mode use the accent color. Counts and infrequent actions live in More.
- Expanded pane: content first, then latest application icon/name, repeat
  count when greater than one, and direct Copy/Pin controls. The native
  information popover contains last-copy time and (for
  repeats) first-copy time. Multiple sources have a closed disclosure with
  per-application counts and first/last times; it scrolls within 140 pt. Full bundle identity and
  precise timestamps remain available in help.
- Details and editing replace the list search toolbar with their own compact
  navigation; its empty background remains a window drag surface. Returning to
  the list restores search focus. Quick Look retains the exact item's type and
  title above the content. An unedited item's Details omits the empty revision
  disclosure; saved revisions expose the existing history and restore actions.
  Search and the list share the navigation root so Back resolves focus within
  that root. A single-format editor allocates its remaining viewport after
  measuring metadata; resizing keeps the same native text editor and its
  selection/undo state. Short windows retain outer scrolling for all controls.
- Native semantic colors and monochrome SF Symbols for controls. Application
  branding uses blue/pearl layered paper and a simple clip, without heavy
  metal texture. Menu-bar/control icons must remain legible as templates and
  at small sizes; they must not be raster reductions of a shaded app icon.

## Preview responsiveness and preferences

The preview gap defaults to 2 pt and can be changed in Appearance, including
zero for touching edges. The saved preference has no arbitrary upper bound;
placement reduces it to fit the available screen space and applies changes
while the preview is open. Advanced Preview controls the optional text length
independently from copying and search. Switching to complete text preserves
the previous custom count for later reuse. Complete text may require more
memory and preparation time; source-format resource limits still apply.

`PreviewTextConfiguration` owns the renderer's text defaults and work-unit
parameters. `PreviewTextSettings` owns their app preferences, and
`PanelGeometry` owns window dimensions and gap preferences. Text segmentation
is prepared off the main actor; the view renders a lazy sequence of bounded
segments, sharing the immutable source buffer. No global full-document height
measurement is required to open the pane. Only changes to the actual viewport
height publish geometry state; unchanged selectable segments reuse their view
leaves. The timing tests use the actual
AppKit-hosted preview body; passing decoder tests alone is not rendering proof.

Dwell starts the prospective preview read before opening the floating window.
Opening joins that exact preparation instead of rereading the representation.
Only the visible loader and one prospective loader are retained; supersession,
panel close, purge and critical memory pressure retire prospective work. Text
preferences and explicit Retry still start a fresh exact-reference load.
Floating and Quick Look loaders share the browsing session's ContentPreview
actor so rapid retargets do not create independent native decoder pools.
The renderer also prepares system-font fallback for at most the first two
segments before publication, including content after a short prefix segment.
Core Text layout objects remain inside that background operation;
the UI receives only the same immutable text. This targets the measured cold
CJK cost separately from per-segment layout. Preparation duration and actual
native presentation duration are recorded separately by the layout test.

## Copy behavior

Existing byte-exact Canonical containment and lineage confirmation continue
to choose the retained item (02 §9). Repeated same-source copies and copies
of the same content from other applications update occurrence metadata,
preserving ID, ContentVersion, pin position and immutable revisions.

SQLite `copy_sources` stores one summary per item and observed application:
first timestamp, most recent timestamp, UInt64 copy count. Unknown provenance
has its own key, distinct from an empty observed string. Source keys follow
Swift String canonical equivalence, while the first observed spelling stays
available for display. Out-of-order observations widen the source's time
range without moving its most recent timestamp backwards.

The source upsert and `history_items.sourceCount` update run in the same
History/Gateway transaction as capture, before ChangePosition publication.
Deletion cascades with the owning item. Browse/search read only sourceCount;
ordinary details and preview-content reads do not read the application list.
The separate `ClipboardHistory.copySources(for:expectedCopyCount:offset:)`
read returns 32 summaries plus a next offset, using the per-item recency index.
A changed copy count throws `snapshotExpired` before reading source rows.
The UI creates this reader only while the disclosure is expanded, retains
one page, and resets it when observation changes the item's copy count.
Source readback remains independent of the renderer's ContentVersion lifetime.

This extends the current greenfield SQLite layout. Per V2-09, older stores
are neither migrated nor automatically removed. Source records cannot be
reconstructed from the old first/last-source aggregates.

## Design references

The local Maccy implementation was read directly: `Views/HistoryRowLayout`
uses 24 pt base rows on macOS 26; `ListItemView` keeps a stable content row;
`PreviewItemView` puts application identity and first/last times below content;
`HeaderView` keeps search and preview controls compact. Clipy retains its
own search, immutable-revision and observation semantics.

[Apple app icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
describe a simple recognizable layered identity.
[Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
adds system-controlled material and appearance behavior; a generated flattened
PNG is a design master, not evidence of a native multilayer icon.

The [final transparent AppIcon](../design/clipy-icons/clipy-appicon.png) uses
this blue/white direction. The user authorized ImageMagick edge cleanup after
the generated alpha had artifacts. All ten macOS asset slots are installed;
the [size review](../design/clipy-icons/size-review.png) covers real 16–256 px
on light/dark backgrounds. This is a static raster icon, not a native
multilayer Icon Composer asset.

UI code follows the current app-owned layout under `ClipyApp/Sources/UI`;
the native drag bridge, adaptive settings, removable filter summary and
preview information dismissal behavior from master are retained.

This Linux workspace has no Swift/Xcode or WindowServer. Native validation
runs through the existing macOS correctness workflow, including real
short/long-content geometry and direct-action journeys. Test screenshots are
exported with the existing application artifacts for visual inspection.

## Addendum — 2026-09-10

The in-window 320 pt preview column is superseded by a transient floating
340 pt pane beside the panel; the previewSide and preview-column-width
settings are removed. Panel height now fits the displayed content, with
the persisted height as the ceiling rather than a fixed size. Image rows
render 44/56 pt thumbnails (compact/comfortable).

User correction, 2026-09-10: no minimum panel or preview height, and no forced
minimum browsing width. The saved size is a ceiling; the content determines
the footprint. The floating preview measures its rendered content separately
from the main list. Short text, unavailable states and small images shrink;
long text and references scroll only when they reach the saved/screen ceiling.
Metadata and frequently used Copy/Pin actions stay in a compact footer.
Dragging only the window's width preserves the saved height ceiling; a short
content-fitted height must never silently become a new user preference.

The local Maccy `HistoryRowLayout`, `ListItemView`, `HeaderView`,
`PreviewItemView`, `ToolbarView`, `ContentView` and `Popup` informed this pass:
compact 24 pt text rows, stable thumbnail geometry, short control strips and
secondary information revealed on demand. Maccy's percentage-height floor is
intentionally not adopted. A single list section has no redundant heading;
Pinned/Recent headings appear only when they distinguish two visible groups.
The search field and adjacent controls share a 24 pt line. Empty/error states
use compact messages, not large placeholder illustrations.
Keyboard selection and explicit row clicks update an open preview immediately. Hover selection
dwells before switching content; entering the preview cancels a crossed row's
pending demand and restores selection to the previewed item. Copy, Pin and
Information therefore operate on the content the user approached.
