/*
 * Step-0 PLACEHOLDER implementation of clipy_xxh3_64bits.
 *
 * This is NOT xxHash. It is a deterministic FNV-1a over the input bytes so the
 * package links and tests run before the pinned xxHash source lands at roadmap
 * step 3 (docs/roadmap/README.md §3). Hashes produced here are valid only
 * inside step-0 scaffolding and must never be persisted across the swap.
 */

#include "xxh3.h"

uint64_t clipy_xxh3_64bits(const void *input, size_t length) {
    const unsigned char *bytes = (const unsigned char *)input;
    uint64_t hash = UINT64_C(14695981039346656037); /* FNV-1a offset basis */
    size_t i;

    if (input == NULL) {
        return 0;
    }
    for (i = 0; i < length; i++) {
        hash ^= (uint64_t)bytes[i];
        hash *= UINT64_C(1099511628211); /* FNV-1a prime */
    }
    return hash;
}
