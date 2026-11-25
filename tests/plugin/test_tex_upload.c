// SPDX-License-Identifier: MIT
/* test_tex_upload.c - the ordering and lifetime decisions of asynchronous texture uploads (src/metal-plugin/
   nvmtl_tex_upload.h, used by nvmtl_vk_image_write_region_level_layer and the async surface copy-in in nvmtl_vk.c).
   Hardware-free: the plugin's pending-upload table (the nvmtl_uptab_* code of the header) and the header's decisions,
   driven with fake fences; the plugin's lock and Vulkan calls around them are left out.
   Arms: the synchronous path leaves nothing pending; a second upload to an image finishes the first; destroy and
   readback finish a pending upload first; a sampling draw finishes nothing; the table bounds what is pending (count
   and bytes) and a full table takes the synchronous path; reaping a done upload never clears a newer handle; a parked
   (recycled) texture carries no pending upload.
   cc -fsanitize=address,undefined -I src/metal-plugin tests/plugin/test_tex_upload.c -o /tmp/test_tex_upload && /tmp/test_tex_upload */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "nvmtl_tex_upload.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// A fake in-flight upload: its fence, whether it was finished (waited for and its staging freed).
typedef struct { int signalled, finished, waited; size_t bytes; } upload;
enum { TABLE_N = NVMTL_UPTAB_N };
static const size_t TABLE_CAP = NVMTL_UPTAB_CAP;
typedef struct { nvmtl_up_state st; int freed; } image;
static nvmtl_uptab tab;   // the plugin's table code (nvmtl_tex_upload.h), driven with fake fences
static unsigned sync_uploads;
#define H(u) ((uint64_t)(uintptr_t)(u))

static void finish(uint64_t h) {
    if (!h) return; upload *u = (upload *)(uintptr_t)h;
    CHECK(!u->finished, "an upload was finished twice (its handle freed twice)");
    if (!u->signalled) u->waited = 1; u->signalled = 1; u->finished = 1;
}
static int fence_done(uint64_t h, void *ctx) { (void)ctx; return ((upload *)(uintptr_t)h)->signalled; }
// nvmtl_asyncup_take + nvmtl_asyncup_finish (nvmtl_vk_image_upload_barrier)
static uint64_t take(image *img) { return nvmtl_uptab_take(&tab, &img->st.infl); }
// nvmtl_surfin_reap
static void reap(void) {
    uint64_t done[NVMTL_UPTAB_N]; const unsigned nd = nvmtl_uptab_reap(&tab, fence_done, NULL, done);
    for (unsigned i = 0; i < nd; i++) finish(done[i]);
}
// nvmtl_asyncup_list: a refused listing is finished (waited for) by the caller
static int list(image *img, upload *u) {
    if (nvmtl_uptab_list(&tab, &img->st.infl, H(u), u->bytes)) return 1;
    finish(H(u)); sync_uploads++; return 0;
}
// One upload as nvmtl_vk_image_write_region_level_layer makes it. Returns 1 if it was left pending.
static int upload_to(image *img, upload *u, int async_flag) {
    uint64_t first = 0;
    const nvmtl_up_submit mode = nvmtl_up_before_upload(&img->st, async_flag, &first);
    if (mode != NVMTL_UP_SUBMIT_ASYNC) { u->signalled = 1; u->finished = 1; u->waited = 1; sync_uploads++; return 0; }
    reap();
    if (first) finish(take(img));
    if (!nvmtl_uptab_room(&tab, u->bytes)) { u->signalled = 1; u->finished = 1; u->waited = 1; sync_uploads++; return 0; }
    return list(img, u);
}
static void destroy(image *img) { finish(take(img)); img->freed = 1; }
// -[NVMTLTexture dealloc] of a recyclable heap or buffer texture: the upload barrier, then nvmtl_heap_park /
// nvmtl_bpark_put copy the image into the park and zero it, then the texture object is freed.
static void park(image *img, image *parked) { finish(take(img)); *parked = *img; memset(img, 0, sizeof *img); }

int main(void) {
    // synchronous path: nothing pending, the consumers' guard finds nothing
    { image a = {0}; upload u = { .bytes = 4096 };
      CHECK(!upload_to(&a, &u, 0) && u.finished && a.st.infl == 0 && nvmtl_up_before_consume(&a.st) == 0, "sync upload left something pending"); }
    // async: pending until consumed; a sampling draw needs no finish (queue order + barrier)
    { image a = {0}; upload u = { .bytes = 4096 };
      CHECK(upload_to(&a, &u, 1) && !u.finished && a.st.infl == (uint64_t)(uintptr_t)&u, "async upload not pending");
      // a draw that samples the image: nothing is taken
      CHECK(!u.finished && tab.n == 1, "a sampling draw finished the upload");
      // a second upload to the same image finishes the first before overwriting
      upload v = { .bytes = 4096 };
      CHECK(upload_to(&a, &v, 1) && u.finished && !v.finished && tab.n == 1, "second upload did not finish the first");
      // destroy finishes the pending upload before the memory goes
      destroy(&a);
      CHECK(v.finished && a.freed && tab.n == 0 && tab.bytes == 0, "destroy did not finish the pending upload"); }
    // readback finishes first
    { image a = {0}; upload u = { .bytes = 1 << 20 };
      upload_to(&a, &u, 1); finish(take(&a));
      CHECK(u.finished && a.st.infl == 0 && tab.n == 0, "readback did not finish the pending upload"); }
    // the table bounds pending uploads by count; completed ones are reaped at the next upload, never waited for
    { static image imgs[TABLE_N + 8]; static upload ups[TABLE_N + 8]; memset(imgs, 0, sizeof imgs); memset(ups, 0, sizeof ups);
      sync_uploads = 0;
      for (unsigned i = 0; i < TABLE_N + 8; i++) { ups[i].bytes = 4096; upload_to(&imgs[i], &ups[i], 1); }
      CHECK(tab.n == TABLE_N && sync_uploads == 8, "count bound: %u pending, %u sync", tab.n, sync_uploads);
      for (unsigned i = 0; i < TABLE_N; i++) ups[i].signalled = 1;   // the GPU finished them
      upload late = { .bytes = 4096 }; image li = {0};
      CHECK(upload_to(&li, &late, 1) && tab.n == 1, "done uploads were not reaped (%u pending)", tab.n);
      int waited = 0; for (unsigned i = 0; i < TABLE_N; i++) waited |= ups[i].waited;
      CHECK(!waited, "reaping waited on a fence");
      for (unsigned i = 0; i < TABLE_N; i++) CHECK(imgs[i].st.infl == 0, "reaped image %u keeps a handle", i);
      destroy(&li); }
    // the table bounds pending staging bytes
    { image a = {0}, b = {0}; upload u = { .bytes = TABLE_CAP - 4096 }, v = { .bytes = 8192 };
      sync_uploads = 0;
      CHECK(upload_to(&a, &u, 1) && !upload_to(&b, &v, 1) && sync_uploads == 1 && v.finished, "byte bound not kept");
      destroy(&a); destroy(&b); }
    // reaping a done upload never clears a newer upload's handle on the same image (two threads uploading at once)
    { image a = {0}; upload u = { .bytes = 64, .signalled = 1 }, v = { .bytes = 64 };
      nvmtl_uptab_list(&tab, &a.st.infl, H(&u), u.bytes);
      nvmtl_up_set(&a.st, H(&v));   // the other thread's newer upload, its table entry not yet added
      reap();
      CHECK(a.st.infl == (uint64_t)(uintptr_t)&v && u.finished, "reap cleared the newer handle");
      tab.n = 0; tab.bytes = 0; }
    // a parked texture carries no pending handle and the table keeps no pointer into the freed texture object
    // (built with -fsanitize=address, a reap that reads the freed texture fails the run)
    { image *a = calloc(1, sizeof *a), parked = {0}; upload u = { .bytes = 4096 }, v = { .bytes = 4096 };
      CHECK(upload_to(a, &u, 1), "async upload not pending");
      park(a, &parked); free(a);
      CHECK(u.finished && parked.st.infl == 0 && tab.n == 0 && tab.bytes == 0, "park left the pending upload on the parked copy or in the table");
      u.signalled = 1; reap();   // the GPU finished it: a table entry left for it would make the reap read the freed texture
      image *r = calloc(1, sizeof *r); *r = parked;   // the next texture recycles the parked image
      CHECK(upload_to(r, &v, 1) && !v.finished, "upload to the recycled image not pending");
      destroy(r); free(r);
      CHECK(v.finished && tab.n == 0, "recycled image's upload not finished at destroy"); }
    printf(fails ? "test_tex_upload: %d FAILED\n" : "test_tex_upload: all passed\n", fails);
    return fails != 0;
}
