# Built-in workflows

User direction, 2026-09-14: run reusable text formatting inside the application,
without launching a terminal, script, external process or service.

## User path

Open **Edit Content**, load the text representation to edit, then open **Text
workflows**. Choose a preset or a saved workflow; add, enable, remove or move
steps. **Preview result** runs that exact source and step sequence. **Apply to
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
updates it; deleting it leaves its currently loaded steps available until closed.
Malformed persisted workflow data remains untouched and visibly blocks writes
until the user explicitly resets saved workflows.

## Operations and bounds

The ordered operations are trim text, trim each line, remove empty lines, remove
duplicate lines, sort lines, uppercase, lowercase, format JSON, compact JSON and
literal case-sensitive find/replace. Line operations normalize CRLF/CR to LF;
deduplication compares exact UTF-8 bytes and preserves first occurrence; sorting
uses UTF-8 lexical order. JSON is validated, then formatted without rewriting
number spellings, repeated keys, string escapes, or key order. Replacement text
is literal, with no regular expressions, interpolation or executable language.

One preview accepts at most 1 MiB of UTF-8 source and output, 32 steps and 50,000
lines for line operations. Output expansion is checked while constructing JSON
and replacement results. Named workflows are limited to 50, names to 200 UTF-8
bytes and each saved find/replacement field to 16 KiB. Execution runs away from
the main actor, checks cancellation between steps and during JSON/replacement,
and rejects late results using a per-preview identity. A result additionally
must match the exact source and step snapshot before Apply is enabled. Native
Foundation calls within a step are synchronous and complete within the bounded
input; cancellation does not claim to preempt those calls.

The screen shows the first 12,000 characters of source/result with a truncation
notice; Apply uses the entire result. Standard controls, semantic system colors,
keyboard actions and explicit accessible step controls support native macOS use.

## Conditional workflows (2026-09-15 user direction)

Each saved workflow chooses manual, new-copy automatic, or both triggers.
Automatic runs process only newly observed, successfully admitted copies;
opening the app and saving/enabling a workflow do not scan existing History.
Manual scope chooses provided text/image, the current clipboard, or a bounded
History range (1–1,000 items in History order). Source application bundle IDs
and copy-time filters (any, last hour, today, last seven days, custom interval)
restrict automatic captures and historical rows by their recorded source/time.
Unknown manual provenance never satisfies a source/time restriction.

Type conditions, literal text conditions and ICU regex conditions short-circuit
on nonmatch. Regex replacement supports capture templates and extraction joins
full matches with LF. Matching checks progress for cancellation and a two-second
deadline; output stays within the existing 1 MiB limit. Image input (PNG/JPEG/
TIFF/HEIC) is limited to 32 MiB and 16 million pixels. App-owned Apple Vision OCR
recognizes text locally before subsequent text conditions/transforms; ImageIO
reads only image headers for admission, not a second History rendering owner.

A notification requires an enabled condition, and is emitted only after every
enabled condition and transform succeeds. Preview never requests notification
permission or sends a notification. Manual runs over multiple matching History
items emit one notification and display the first result plus the match count;
Copy Result copies only that displayed result. Neither manual nor automatic
execution authors History revisions. Explicit editor Apply and Save retain the
existing immutable-revision path. Automatic runs never replace the clipboard.

One active automatic computation and one latest pending copy bound retained
clipboard content while OCR works. A newer pending copy replaces its predecessor,
matching the app's existing best-effort capture behavior. Stop/pause cancels work;
an edited/deleted workflow is rechecked before sending an in-flight notification.
All inputs/outputs are transient; preferences retain definitions and scope only.
