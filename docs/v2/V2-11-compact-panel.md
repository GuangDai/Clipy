# Compact panel and copy sources

User direction, 2026-09-09: Clipy is a small utility. Make content easy to
scan, move application icons and copy information into the expanded pane,
and use a coherent contemporary Apple visual style. Equal content from
different applications remains one history item; retain the applications'
individual copy times and show only a small multiple-source indicator in
the list.

## Information hierarchy

- Default browsing surface: 360 × 420 pt; minimum 360 × 420 pt.
  Existing explicit size preferences remain meaningful. The preview retains
  its independently adjustable 320 pt default width.
- Compact rows: 20 pt content/type slot, regular system body title, 2 pt vertical
  padding plus 2 pt list insets. Comfortable density uses a 28 pt slot.
  Search snippets appear only when they provide body-match evidence.
- Row accessories: multiple-source indicator and pin ordinal. Source icons,
  bundle identifiers, timestamps and occurrence counters leave the list.
- Search: one stable field and two 24 pt icon controls. Search mode remains
  available through the menu and Command-1/2/3; active filtering and nondefault
  search mode use the accent color. Counts remain in the footer.
- Expanded pane: content first, then latest application icon/name and total
  copies. The native information popover contains last-copy time and (for
  repeats) first-copy time. Multiple sources have a closed disclosure with
  per-application counts and first/last times; it scrolls within 140 pt. Full bundle identity and
  precise timestamps remain available in help.
- Native semantic colors and monochrome SF Symbols for controls. Application
  branding uses blue/pearl layered paper and a simple clip, without heavy
  metal texture. Menu-bar/control icons must remain legible as templates and
  at small sizes; they must not be raster reductions of a shaded app icon.

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

Implementation is in progress. This Linux workspace has no Swift/Xcode or
WindowServer; the native build, storage tests and running-app visual checks
have not run. The existing correctness workflow remains the validation lane.
Local checks covered actual source pagination SQL/index use, source
upsert/rollback/cascade SQL, and icon dimensions and alpha. Native validation
runs through the existing macOS correctness workflow; local checks are not
substitutes for Swift or running-app tests.

## Addendum — 2026-09-10

The in-window 320 pt preview column is superseded by a transient floating
340 pt pane beside the panel; the previewSide and preview-column-width
settings are removed. Panel height now fits the displayed content, with
the persisted height as the ceiling rather than a fixed size. Image rows
render 44/56 pt thumbnails (compact/comfortable).

The floating preview keeps a 420 pt minimum height independently of a short
history list, capped by the screen's visible height. It aligns to the main
panel's top edge when possible and stays inside the visible screen. This
keeps file actions, recovery and PDF controls usable with one retained item.
