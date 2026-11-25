// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
/* The range allocator of the plugin's buffer pools (nvmtl_vk.c, pool_buffer_create_in): many small MTLBuffers share one
   VkDeviceMemory block, so they share one kext BO handle and one GPU VA map. First fit in the freed ranges, else a bump
   from the block's high-water mark; a block whose last range comes back starts over. Pure (no Vulkan, no locks: the
   caller holds g_pool_lock), so a host test can run it (tests/plugin/test_pool_range.c).
   The kext gives each process 4095 BO handles (PHXN_MAX_BOS) and 4096 VA maps: one BO per small device-local buffer
   (Managed buffers' VRAM copies, 4 to 800 B) ran Maps out of handles with 6 GB of VRAM free (finding
   2026-11-25-maps-allocation-limit.md). */
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
    if (!nlive) { s->used = 0; s->nfr = 0; return; }
    if (off + len == s->used) { s->used = off; return; }
    for (uint32_t i = 0; i < s->nfr; i++) {
        if (s->fr[i].off + s->fr[i].len == off) { s->fr[i].len += len; return; }
        if (off + len == s->fr[i].off) { s->fr[i].off = off; s->fr[i].len += len; return; }
    }
    if (s->nfr == s->cfr) {   // no memory for the list: the range stays unused until the block empties
        uint32_t c = s->cfr ? s->cfr * 2 : 64; pool_range *n = (pool_range *)realloc(s->fr, c * sizeof *n);
        if (!n) return;
        s->fr = n; s->cfr = c; }
    s->fr[s->nfr].off = off; s->fr[s->nfr].len = len; s->nfr++;
}

/* The Private pool (Vermilion): device-local buffers up to NVMTL_PPOOL_MAX (Private buffers and the VRAM copy of a
   Managed one: nvmtl_vk_buffer_create with host_visible 0) share blocks of NVMTL_PPOOL_BLOCK, as Shared buffers share
   the system-RAM pool. Larger ones keep their own memory (and res3's stable address from 1 MiB). */
#define NVMTL_PPOOL_MAX   (256u << 10)
#define NVMTL_PPOOL_BLOCK (4u << 20)
enum { NVMTL_POOL_SYS = 0, NVMTL_POOL_BAR1 = 1, NVMTL_POOL_PRIVATE = 2 };
static inline int nvmtl_pool_private_fits(size_t size, int host_visible) { return !host_visible && size && size <= NVMTL_PPOOL_MAX; }

/* A released Private range waits here until the GPU completed every submission made before its release (seq = the last
   submission then): the guarantee the kext gave a dedicated BO, whose free it defers until the client's work retired. */
typedef struct { void *blk; size_t off, len; uint64_t seq; } nvmtl_held_range;
typedef struct { nvmtl_held_range *q; uint32_t head, n, cap; } nvmtl_range_fifo;
static inline int nvmtl_fifo_push(nvmtl_range_fifo *f, nvmtl_held_range r)
{
    if (f->n == f->cap && f->head) {
        for (uint32_t i = f->head; i < f->n; i++) f->q[i - f->head] = f->q[i];
        f->n -= f->head; f->head = 0; }
    if (f->n == f->cap) {
        uint32_t c = f->cap ? f->cap * 2 : 256; nvmtl_held_range *q = (nvmtl_held_range *)realloc(f->q, c * sizeof *q);
        if (!q) return -1;
        f->q = q; f->cap = c; }
    f->q[f->n++] = r;
    return 0;
}
/* The oldest held range once the GPU completed submission `done`: 1 and *out, else 0. */
static inline int nvmtl_fifo_pop_ready(nvmtl_range_fifo *f, uint64_t done, nvmtl_held_range *out)
{
    if (f->head == f->n || f->q[f->head].seq > done) return 0;
    *out = f->q[f->head++];
    if (f->head == f->n) f->head = f->n = 0;
    return 1;
}
static inline uint32_t nvmtl_fifo_len(const nvmtl_range_fifo *f) { return f->n - f->head; }
#endif
