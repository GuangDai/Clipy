# Vendored xxHash

This target vendors the [xxHash](https://github.com/Cyan4973/xxHash) single-file
sources (`xxhash.h`, `xxhash.c`) at the recorded version below. `xxhash.c` follows the
header's own single-file build guidance (`#define XXH_STATIC_LINKING_ONLY` +
`#define XXH_IMPLEMENTATION` before `#include "xxhash.h"`); XXH3 is included in
the single-file build. SwiftPM defines `XXH_INLINE_ALL` for both C translation
units, making upstream implementations translation-unit-local; the only
global entry point is `clipy_xxh3_64bits` (`include/xxh3.h`). The vendored
headers stay target-private (not under `include/`).

## Recorded source version

- **Upstream repository:** https://github.com/Cyan4973/xxHash
- **Tag:** `v0.8.3`
- **Commit:** `e626a72bc2321cd320e953a0ccf1584cad60f363`
  - Lightweight tag (no annotated-tag object): `git ls-remote
    https://github.com/Cyan4973/xxHash.git refs/tags/v0.8.3` reports a single
    line and no `refs/tags/v0.8.3^{}` peeled line, so the tag names the commit
    above directly.
- **Retrieved:** 2026-07-22, from
  `https://codeload.github.com/Cyan4973/xxHash/tar.gz/refs/tags/v0.8.3`.

xxHash is distributed under the BSD 2-Clause License; the copyright/license
headers are retained verbatim in the vendored sources.

## Update policy

xxh3 is the external dependency introduced at roadmap step 3
(docs/roadmap/07-external-deps.md). When its vendored sources change, record
the new tag/commit and retrieval date, then run the XXH3-64 behavior tests.
The fixtures cover
empty input, `a`, `abc`, and `Clipy` through the production wrapper on the
macOS arm64 runner.
