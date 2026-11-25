// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// nvmtl_tex_upload.h: ordering and lifetime decisions for asynchronous texture uploads.
//
// On the synchronous path, replaceRegion and IOSurface uploads submit a copy and wait for the GPU before returning
// (nvmtl_vk_image_write*), so an app that uploads many textures per frame stalls once per upload. An
// earlier attempt (community PR #96) deferred the wait but was reverted: nvmtl_vk_image_destroy frees the
// image and its memory at once, and IOSurface-backed textures are uploaded then destroyed, so a deferred
// copy could land in freed GPU memory.
//
// This is the decision logic for doing it safely (NVMTL_ASYNC_TEX_UPLOAD, on by default outside WindowServer;
// NVMTL_ASYNC_SURFACE_IN for the surface copy-in, default off). One async upload may be in flight per image;
// its in-flight handle is recorded on the image. Before anything that would overwrite,
// read back, CPU-map or free that image's memory, the pending upload is finished (fence waited) first. Pure,
// so the invariants are unit-tested without a GPU; the plugin supplies the fence primitives.
//
// Invariants (each an arm of tests/plugin/test_tex_upload.c):
//   - synchronous path (flag off): a new upload submits-and-waits; nothing is ever left pending, so the
//     destroy/readback guard finds nothing to finish and is a no-op (this is what keeps the synchronous path
//     byte-for-byte the same);
//   - a second upload to the same image finishes the first (it would otherwise overwrite a texture, or reuse
//     staging bytes, while the GPU is still copying);
//   - destroy, readback, CPU map and surface-out finish a pending upload first (no use-after-free: this is
//     the #96 regression this guard exists to prevent);
//   - a draw that merely SAMPLES the image needs no CPU finish: the upload's command buffer was submitted, so
//     queue order plus the image's TRANSFER->SHADER_READ barrier already order the copy before the sample.

#ifndef NVMTL_TEX_UPLOAD_H
#define NVMTL_TEX_UPLOAD_H

#include <stddef.h>
#include <stdint.h>

// Per-image async-upload bookkeeping. `infl` is an opaque handle to the in-flight submission (the plugin
// stores an nvmtl_asyncup pointer, cast to uint64_t); 0 means no async upload is in flight for this image.
typedef struct { uint64_t infl; } nvmtl_up_state;

typedef enum {
    NVMTL_UP_SUBMIT_WAIT  = 0,   // submit the copy and wait now (the synchronous path)
    NVMTL_UP_SUBMIT_ASYNC = 1,   // submit without waiting; the caller records the handle with nvmtl_up_set
} nvmtl_up_submit;

// Decide how to submit a new upload to an image. If a previous async upload to THIS image is still in
// flight, it must be finished first: its handle is returned through *finish_first (0 means none). The submit
// mode is async only when the flag is on.
static inline nvmtl_up_submit nvmtl_up_before_upload(const nvmtl_up_state *s, int async_flag,
                                                     uint64_t *finish_first)
{
    *finish_first = s ? s->infl : 0;
    return async_flag ? NVMTL_UP_SUBMIT_ASYNC : NVMTL_UP_SUBMIT_WAIT;
}

// What a consumer (destroy, readback, CPU map, surface-out) must finish before touching the image's memory:
// the pending in-flight handle, or 0 for nothing. On the synchronous path `infl` is never set, so this
// returns 0 and the consumer proceeds exactly as it does today.
static inline uint64_t nvmtl_up_before_consume(const nvmtl_up_state *s)
{
    return s ? s->infl : 0;
}

// Record the in-flight handle after an async submit; clear it after the upload has been finished (waited).
static inline void nvmtl_up_set(nvmtl_up_state *s, uint64_t infl) { if (s) s->infl = infl; }
static inline void nvmtl_up_clear(nvmtl_up_state *s) { if (s) s->infl = 0; }

// The pending-upload table: every async upload left in flight, listed so the staging memory they hold is bounded and
// completed ones are reaped (fence polled, never waited). The plugin keeps one, under g_asyncup_mutex
// (nvmtl_async_surfin.c); `tok` points at the image's handle (nvk_image.up_token), `h` is the upload's handle.
#define NVMTL_UPTAB_N 64
#define NVMTL_UPTAB_CAP (128ull << 20)
typedef struct { uint64_t *tok; uint64_t h; size_t bytes; } nvmtl_uptab_entry;
typedef struct { nvmtl_uptab_entry e[NVMTL_UPTAB_N]; unsigned n; size_t bytes; } nvmtl_uptab;

// Room in the table for one more upload of `bytes` staging bytes?
static inline int nvmtl_uptab_room(const nvmtl_uptab *t, size_t bytes)
{
    return t->n < NVMTL_UPTAB_N && t->bytes + bytes <= NVMTL_UPTAB_CAP;
}

// Lists upload `h` of `bytes` staging bytes on the image whose handle is *tok. Returns 0 (nothing changed) if the
// table is full or the image already has a pending upload (another thread uploaded to it at the same time): the caller
// then finishes `h` itself. So an image has at most one entry, and it is the handle on the image.
static inline int nvmtl_uptab_list(nvmtl_uptab *t, uint64_t *tok, uint64_t h, size_t bytes)
{
    if (t->n >= NVMTL_UPTAB_N || *tok) return 0;
    nvmtl_up_state s = { *tok };
    nvmtl_up_set(&s, h);
    *tok = s.infl;
    t->e[t->n].tok = tok; t->e[t->n].h = h; t->e[t->n].bytes = bytes;
    t->n++; t->bytes += bytes;
    return 1;
}

// Removes upload h's entry from the table.
static inline void nvmtl_uptab_unlist(nvmtl_uptab *t, uint64_t h)
{
    for (unsigned i = 0; i < t->n; i++)
        if (t->e[i].h == h) { t->bytes -= t->e[i].bytes; t->e[i] = t->e[--t->n]; return; }
}

// Reads and clears the image's handle and removes its entry: the caller finishes the returned handle (0 for none).
static inline uint64_t nvmtl_uptab_take(nvmtl_uptab *t, uint64_t *tok)
{
    nvmtl_up_state s = { *tok };
    const uint64_t h = nvmtl_up_before_consume(&s);
    *tok = 0;
    if (h) nvmtl_uptab_unlist(t, h);
    return h;
}

// Removes the uploads whose fence has signalled (done(h, ctx) != 0) and writes their handles to out[] (room for
// NVMTL_UPTAB_N); the caller finishes them. An image's handle is cleared only if it is still the reaped upload's.
static inline unsigned nvmtl_uptab_reap(nvmtl_uptab *t, int (*done)(uint64_t h, void *ctx), void *ctx, uint64_t *out)
{
    unsigned nd = 0;
    for (unsigned i = 0; i < t->n;) {
        const uint64_t h = t->e[i].h;
        if (done(h, ctx)) {
            if (*t->e[i].tok == h) *t->e[i].tok = 0;   // not a newer upload's handle
            out[nd++] = h;
            t->bytes -= t->e[i].bytes; t->e[i] = t->e[--t->n];
        } else i++;
    }
    return nd;
}

#endif
