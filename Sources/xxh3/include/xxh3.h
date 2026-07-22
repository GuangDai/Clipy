#ifndef CLIPY_XXH3_H
#define CLIPY_XXH3_H

#include <stddef.h>
#include <stdint.h>

/*
 * Step-0 PLACEHOLDER for the vendored, pinned xxHash XXH3 implementation.
 *
 * This header (and its companion source) exists so the package target graph
 * matches docs/01-architecture.md §1 from day one. The real pinned xxHash
 * source replaces these files at roadmap step 3 (docs/roadmap/README.md §3);
 * HistoryStorage first consumes it at step 5 (docs/05-authority-kernel.md
 * §6.1, IngestPreparationActor). Only this single entry point's ABI is relied
 * upon, so the swap is source-local to this target.
 */

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Computes a 64-bit representation fingerprint of `input`.
 * PLACEHOLDER: the step-0 implementation is deterministic FNV-1a, NOT XXH3;
 * values it produces must never be persisted across the step-3 swap.
 */
uint64_t clipy_xxh3_64bits(const void *input, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* CLIPY_XXH3_H */
