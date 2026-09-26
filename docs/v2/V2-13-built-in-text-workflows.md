# Built-in workflows

User direction, 2026-09-14: run reusable text formatting inside the application,
without launching a terminal, script, external process or service.

## User path

Open **Edit Content**, load the text representation to edit, then open **Text
workflows**. The sidebar keeps multiple workflows visible in execution order. Add a blank
workflow or a preset; select, enable, remove or drag steps between explicit
If / Then / Otherwise branches. Definitions and temporary test inputs survive
switching workflows while this editor is open. **Preview result** runs that exact source and step sequence. **Apply to
draft** returns the complete result to the existing editor. **Save Revision**
remains the sole History write, preserving its expected ContentVersion,
original representation encoding, immutable lineage and typed failure handling.
Cancelling, invalid JSON, a limit failure, or closing the workflow leaves the
editor draft untouched. Editing the workflow invalidates its preview. Applying
an empty result is unavailable because an empty replacement is not a valid
editor revision. Other kept representations retain their existing decisions.

Settings > Automation offers the same workflow editor with temporary test text.
Named workflows persist only step definitions in application preferences; source
and output never enter those preferences. Saving an existing named workflow
updates it. Deleting the selected definition selects another workflow or a new
blank definition. Unsaved status is visible, and only Save enables automatic
runs for an edited definition.
Malformed persisted workflow data remains untouched and visibly blocks writes
until the user explicitly resets saved workflows.

## Operations and bounds

The ordered operations are trim text, trim each line, remove empty lines, remove
duplicate lines, sort lines, uppercase, lowercase, format JSON, compact JSON and
literal case-sensitive find/replace. Line operations normalize CRLF/CR to LF;
deduplication compares exact UTF-8 bytes and preserves first occurrence; sorting
uses UTF-8 lexical order. JSON is validated, then formatted without rewriting
number spellings, repeated keys, string escapes, or key order. The literal replacement step treats replacement text literally. Separate regex
conditions, extraction and capture-template replacement are defined below.

One preview accepts at most 1 MiB of UTF-8 source and output, 32 steps and 50,000
lines for line operations. Output expansion is checked while constructing JSON
and replacement results. Named workflows are limited to 50, names to 200 UTF-8
bytes and each saved find/replacement field to 16 KiB. Execution runs away from
the main actor, checks cancellation between steps and during JSON/replacement,
and rejects late results using a per-preview identity. A result additionally
must match the exact source and step snapshot before Apply is enabled. Native
Foundation calls within a step are synchronous and complete within the bounded
input; cancellation does not claim to preempt those calls.

Before and After use the same native text view with equal column widths, fonts,
insets, top-left alignment and wrapping; After is read-only and selectable.
The complete bounded result is available for comparison and Apply. Current
clipboard and History runs return their actual source alongside the first result.
There are no Read Clipboard or Choose Image buttons: configured sources are read
when Preview or Run is requested. Standard controls, semantic system colors,
keyboard actions and explicit step controls support native macOS use.

## Conditional workflows (2026-09-15 user direction)

Each saved workflow chooses manual, new-copy automatic, or both triggers.
Automatic runs process only newly observed, successfully admitted copies;
opening the app and saving/enabling a workflow do not scan existing History.
Manual scope chooses provided text, the current clipboard, or a bounded
History range (1–1,000 items in History order). Source application bundle IDs
and copy-time filters (any, last hour, today, last seven days, custom interval)
restrict automatic captures and historical rows by their recorded source/time.
Unknown manual provenance never satisfies a source/time restriction.

Conditions appear as explicit If blocks with Then and Otherwise branches.
Each selected branch receives the current value and passes its result to the
following steps. Nested conditions are supported. A nonmatching condition with
no Otherwise actions skips only that block; subsequent actions still execute.
The 32-step bound includes all branches and nesting. Previously saved flat type
and text guards retain their stop-on-nonmatch semantics and are labeled as such. Regex replacement supports capture templates and extraction joins
full matches with LF. Matching checks progress for cancellation and a two-second
deadline; output stays within the existing 1 MiB limit. Image input (PNG/JPEG/
TIFF/HEIC) is limited to 32 MiB and 16 million pixels. App-owned Apple Vision OCR
recognizes text locally before subsequent text conditions/transforms; ImageIO
reads only image headers for admission, not a second History rendering owner.

Notifications belong inside conditional branches, and are emitted only after
the selected branch and the remaining workflow complete successfully. In older
flat definitions all guards must still pass before any deferred notification. Preview never requests notification
permission or sends a notification. Manual runs over multiple matching History
items emit one notification and display the first result plus the match count;
Copy Result copies only that displayed result. Neither manual nor automatic
execution authors History revisions. Explicit editor Apply and Save retain the
existing immutable-revision path. Automatic runs never replace the clipboard.

## Execution order and concurrency

Saved sidebar order is automatic execution priority. Every new committed copy
freezes that ordered definition list when processing begins; all workflows in
that batch receive the same original copy, never a previous workflow's output.
Reordering affects subsequent batches and does not preempt active native work.
A failed or nonmatching workflow does not prevent later workflows from running.

Accepted copies retain FIFO arrival order: at most eight waiting copies and
64 MiB of waiting representation bytes. Overflow publishes a visible failure;
it never replaces an earlier accepted copy. Manual and automatic computations
share one app-owned execution queue, with at most 32 waiting requests and 64 MiB
of admitted input bytes. Settings and panel editors receive that same queue.
Waiting and running are separate UI states. Cancelled queued requests are
removed; an active cancelled OCR operation retains the slot until native work
actually finishes, so cancellation cannot start overlapping computations.
Notifications occupy that same execution slot. Current-clipboard manual input
is read at the user request boundary, before waiting in the queue.

Stop/pause cancels automatic work. An edited/deleted definition is checked again
before sending an in-flight automatic notification. All inputs/outputs are
transient; preferences retain definitions, scope and order only.

## Workflow management and editing

The library supports name search and all/manual/automatic/unsaved filters.
Filtering never changes priority or discards the selected draft. Reordering is
available in the unfiltered list, where the complete execution order is visible.
Rows distinguish saved automatic definitions from drafts waiting to be saved;
compact rows are an optional appearance preference.

Duplicate creates an independent manual workflow, including fresh IDs for every
nested step. Save All validates changed definitions together and writes them in
one preference update, retaining unrelated definitions changed in another window.
Saving edits to an existing definition preserves the current saved order; saving
new definitions places them according to this window's visible order.
Unchanged placeholder definitions do not block saving or closing. Closing with
edited definitions offers Save All, Discard, or Keep Editing. Deleting a saved or
edited definition requires confirmation. Revert restores the saved definition;
temporary test input remains separate from definition persistence.

Step choices are grouped by task: text, lines, structured data, regular
expressions, images, and notifications. Parameters show their literal or template
semantics and validation near the field. Conditions have collapsible Then and
Otherwise branches. Duplicating a condition duplicates the entire subtree with
fresh IDs and respects the same 32-step total limit as execution and saving.

The preview offers equal-width comparison, input-only and result-only display
modes. Preview completion, unchanged output, cancellation, no match, failure and
queueing are explicit states. Notification failure retains the computed result
for Copy or Apply while explaining the failed effect. Editing or starting another
request clears stale operation feedback. Command-R previews; Command-S saves.
Source and time filters expand separately from the basic trigger and input
controls, with active-filter feedback and an explanation when untracked manual
input cannot match them.
