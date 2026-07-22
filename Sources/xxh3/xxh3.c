/*
 * Implementation of clipy_xxh3_64bits on top of the vendored, pinned xxHash
 * v0.8.3 single-file sources (see VENDORED.md).
 *
 * The implementation is compiled in the sibling xxhash.c translation unit,
 * which follows the header's own single-file build guidance:
 *
 *     #define XXH_STATIC_LINKING_ONLY
 *     #define XXH_IMPLEMENTATION
 *     #include "xxhash.h"
 *
 * so this file only needs the plain public declarations of XXH3_64bits.
 */

#include "xxh3.h"

#include "xxhash.h"

uint64_t clipy_xxh3_64bits(const void *input, size_t length) {
    return (uint64_t)XXH3_64bits(input, length);
}
