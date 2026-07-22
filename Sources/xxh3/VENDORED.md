# Vendored xxHash

This target vendors the [xxHash](https://github.com/Cyan4973/xxHash) single-file
sources (`xxhash.h`, `xxhash.c`) at a pinned revision. `xxhash.c` follows the
header's own single-file build guidance (`#define XXH_STATIC_LINKING_ONLY` +
`#define XXH_IMPLEMENTATION` before `#include "xxhash.h"`); XXH3 is included in
the single-file build. The only entry point exposed outside this target is
`clipy_xxh3_64bits` (`include/xxh3.h`), so the vendored files stay
target-private (not under `include/`).

## Pinned revision

- **Upstream repository:** https://github.com/Cyan4973/xxHash
- **Tag:** `v0.8.3`
- **Commit:** `e626a72bc2321cd320e953a0ccf1584cad60f363`
  - Lightweight tag (no annotated-tag object): `git ls-remote
    https://github.com/Cyan4973/xxHash.git refs/tags/v0.8.3` reports a single
    line and no `refs/tags/v0.8.3^{}` peeled line, so the tag names the commit
    above directly.
- **Retrieved:** 2026-07-22, from
  `https://codeload.github.com/Cyan4973/xxHash/tar.gz/refs/tags/v0.8.3`
  (tarball sha256 `aae608dfe8213dfd05d909a57718ef82f30722c392344583d3f39050c7f29a80`).

## File integrity (sha256)

| File | sha256 |
|---|---|
| `xxhash.h` | `17973c0dc49d9854ca26caa191f0e12f7a424b68858d9a78de3860d959d85e4b` |
| `xxhash.c` | `5c3591fe6e6c86a619eb26760e9520e37a6fd5152882ab5ad93f912e2a855966` |

Both files are byte-identical to the upstream tag (verify with
`sha256sum xxhash.h xxhash.c` against the table above). xxHash is distributed
under the BSD 2-Clause License; the copyright/license headers are retained
verbatim in the vendored sources.

## Update policy

xxh3 is an external dependency pinned at roadmap step 3
(docs/roadmap/07-external-deps.md). Any update of the vendored sources or the
pin is a **reviewed dependency change**: re-record the tag/commit, retrieval
date, and file hashes here, and re-verify the XXH3-64 known-answer vectors
(e.g. empty input → `0x2D06800538D394C2`) before landing.
