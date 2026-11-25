// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
/* The range allocator of the plugin's buffer pools (nvmtl_vk.c, pool_buffer_create_in): many small MTLBuffers share one
   VkDeviceMemory block, so they share one kext BO handle and one GPU VA map. First fit in the freed ranges, else a bump
   from the block's high-water mark. Pure (no Vulkan, no locks: the caller holds
   g_pool_lock), so a host test can run it (tests/plugin/test_pool_range.c). */
#ifndef NVMTL_POOL_RANGE_H
#define NVMTL_POOL_RANGE_H
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct { size_t off, len; } pool_range;
typedef struct {
    size_t used;               /* high-water mark: [0, used) has been handed out at least once */
    pool_range *fr;            /* freed ranges below used */
    uint32_t nfr, cfr;
} nvmtl_range_set;

/* A range of len bytes in a block of cap bytes: 1 and *off, or 0 when it does not fit. */
static inline int nvmtl_range_take(nvmtl_range_set *s, size_t cap, size_t len, size_t *off)
{
    for (uint32_t i = 0; i < s->nfr; i++) {
        if (s->fr[i].len >= len) {
            *off = s->fr[i].off; s->fr[i].off += len; s->fr[i].len -= len;
            if (!s->fr[i].len) s->fr[i] = s->fr[--s->nfr];
            return 1;
        }
    }
    if (s->used + len <= cap) { *off = s->used; s->used += len; return 1; }
    return 0;
}

/* [off, off + len) is free again; nlive is the block's live range count after this release. */
static inline void nvmtl_range_give(nvmtl_range_set *s, size_t off, size_t len, uint32_t nlive)
{
    if (off + len == s->used) { s->used = off; }
    else {
        for (uint32_t i = 0; i < s->nfr; i++) {
            if (s->fr[i].off + s->fr[i].len == off) { s->fr[i].len += len; return; }
            if (off + len == s->fr[i].off) { s->fr[i].off = off; s->fr[i].len += len; return; }
        }
        if (s->nfr == s->cfr) { uint32_t c = s->cfr ? s->cfr * 2 : 64; pool_range *n = (pool_range *)realloc(s->fr, c * sizeof *n); if (!n) return; s->fr = n; s->cfr = c; }
        s->fr[s->nfr].off = off; s->fr[s->nfr].len = len; s->nfr++;
    }
    if (!nlive) { s->used = 0; s->nfr = 0; }
}
#endif
