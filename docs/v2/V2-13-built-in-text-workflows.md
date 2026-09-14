# Built-in text workflows

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
