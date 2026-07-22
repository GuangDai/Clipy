#ifndef CLIPY_XXH3_H
#define CLIPY_XXH3_H

#include <stddef.h>
#include <stdint.h>

/*
 * Public entry point of the package-internal xxh3 target, backed by the
 * vendored, pinned xxHash v0.8.3 single-file sources (xxhash.h/xxhash.c in
 * this target; see VENDORED.md for the exact upstream revision and hashes).
 *
 * This header exists so the package target graph matches
 * docs/01-architecture.md §1 and only this single entry point's ABI is relied
 * upon; HistoryStorage first consumes it at roadmap step 5
 * (docs/05-authority-kernel.md §6.1, IngestPreparationActor).
 */

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Computes the 64-bit XXH3 hash of `input` (the representation fingerprint of
 * docs/02-domain.md §2.2). Evidence only — never identity, never sufficient
 * for Copy Coalescing (D7); equal fingerprints still require byte
 * confirmation (docs/06-cross-cutting.md §7.6).
 */
uint64_t clipy_xxh3_64bits(const void *input, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* CLIPY_XXH3_H */
