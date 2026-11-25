// SPDX-License-Identifier: MIT
/* test_tex_upload.c - the ordering and lifetime decisions of asynchronous texture uploads (src/metal-plugin/
   nvmtl_tex_upload.h, used by nvmtl_vk_image_write_region_level_layer and the async surface copy-in in nvmtl_vk.c).
   Hardware-free: a model of the plugin's pending-upload table drives the header's decisions with fake fences.
   Arms: the synchronous path leaves nothing pending; a second upload to an image finishes the first; destroy and
   readback finish a pending upload first; a sampling draw finishes nothing; the table bounds what is pending (count
   and bytes) and a full table takes the synchronous path; reaping a done upload never clears a newer handle.
   cc -I src/metal-plugin tests/plugin/test_tex_upload.c -o /tmp/test_tex_upload && /tmp/test_tex_upload */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "nvmtl_tex_upload.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

// A fake in-flight upload: its fence, whether it was finished (waited for and its staging freed).
typedef struct { int signalled, finished, waited; size_t bytes; } upload;
enum { TABLE_N = 64 };
static const size_t TABLE_CAP = 128u << 20;
typedef struct { nvmtl_up_state st; int freed; } image;
static struct { image *img; upload *u; } table[TABLE_N];
static unsigned table_n; static size_t table_bytes; static unsigned sync_uploads;

static void finish(uint64_t h) { if (!h) return; upload *u = (upload *)(uintptr_t)h; if (!u->signalled) u->waited = 1; u->signalled = 1; u->finished = 1; }
static void unlist(image *img) {
    for (unsigned i = 0; i < table_n; i++) if (table[i].img == img) { table_bytes -= table[i].u->bytes; table[i] = table[--table_n]; return; }
}
static uint64_t take(image *img) { const uint64_t h = nvmtl_up_before_consume(&img->st); nvmtl_up_clear(&img->st); if (h) unlist(img); return h; }
static void reap(void) {
    for (unsigned i = 0; i < table_n;) {
        upload *u = table[i].u;
        if (u->signalled) {
            if (table[i].img->st.infl == (uint64_t)(uintptr_t)u) nvmtl_up_clear(&table[i].img->st);
            table_bytes -= u->bytes; finish((uint64_t)(uintptr_t)u); table[i] = table[--table_n];
        } else i++;
    }
}
// One upload as nvmtl_vk_image_write_region_level_layer makes it. Returns 1 if it was left pending.
static int upload_to(image *img, upload *u, int async_flag) {
    uint64_t first = 0;
    const nvmtl_up_submit mode = nvmtl_up_before_upload(&img->st, async_flag, &first);
    if (mode != NVMTL_UP_SUBMIT_ASYNC) { u->signalled = 1; u->finished = 1; u->waited = 1; sync_uploads++; return 0; }
    reap();
    if (first) finish(take(img));
    if (!(table_n < TABLE_N && table_bytes + u->bytes <= TABLE_CAP)) { u->signalled = 1; u->finished = 1; u->waited = 1; sync_uploads++; return 0; }
    nvmtl_up_set(&img->st, (uint64_t)(uintptr_t)u);
    table[table_n].img = img; table[table_n].u = u; table_n++; table_bytes += u->bytes;
    return 1;
}
static void destroy(image *img) { finish(take(img)); img->freed = 1; }

int main(void) {
    // synchronous path: nothing pending, the consumers' guard finds nothing
    { image a = {0}; upload u = { .bytes = 4096 };
      CHECK(!upload_to(&a, &u, 0) && u.finished && a.st.infl == 0 && nvmtl_up_before_consume(&a.st) == 0, "sync upload left something pending"); }
    // async: pending until consumed; a sampling draw needs no finish (queue order + barrier)
    { image a = {0}; upload u = { .bytes = 4096 };
      CHECK(upload_to(&a, &u, 1) && !u.finished && a.st.infl == (uint64_t)(uintptr_t)&u, "async upload not pending");
      // a draw that samples the image: nothing is taken
      CHECK(!u.finished && table_n == 1, "a sampling draw finished the upload");
      // a second upload to the same image finishes the first before overwriting
      upload v = { .bytes = 4096 };
      CHECK(upload_to(&a, &v, 1) && u.finished && !v.finished && table_n == 1, "second upload did not finish the first");
      // destroy finishes the pending upload before the memory goes
      destroy(&a);
      CHECK(v.finished && a.freed && table_n == 0 && table_bytes == 0, "destroy did not finish the pending upload"); }
    // readback finishes first
    { image a = {0}; upload u = { .bytes = 1 << 20 };
      upload_to(&a, &u, 1); finish(take(&a));
      CHECK(u.finished && a.st.infl == 0 && table_n == 0, "readback did not finish the pending upload"); }
    // the table bounds pending uploads by count; completed ones are reaped at the next upload, never waited for
    { static image imgs[TABLE_N + 8]; static upload ups[TABLE_N + 8]; memset(imgs, 0, sizeof imgs); memset(ups, 0, sizeof ups);
      sync_uploads = 0;
      for (unsigned i = 0; i < TABLE_N + 8; i++) { ups[i].bytes = 4096; upload_to(&imgs[i], &ups[i], 1); }
      CHECK(table_n == TABLE_N && sync_uploads == 8, "count bound: %u pending, %u sync", table_n, sync_uploads);
      for (unsigned i = 0; i < TABLE_N; i++) ups[i].signalled = 1;   // the GPU finished them
      upload late = { .bytes = 4096 }; image li = {0};
      CHECK(upload_to(&li, &late, 1) && table_n == 1, "done uploads were not reaped (%u pending)", table_n);
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
      nvmtl_up_set(&a.st, (uint64_t)(uintptr_t)&u); table[0].img = &a; table[0].u = &u; table_n = 1; table_bytes = 64;
      nvmtl_up_set(&a.st, (uint64_t)(uintptr_t)&v);   // the other thread's newer upload, its table entry not yet added
      reap();
      CHECK(a.st.infl == (uint64_t)(uintptr_t)&v && u.finished, "reap cleared the newer handle");
      table_n = 0; table_bytes = 0; }
    printf(fails ? "test_tex_upload: %d FAILED\n" : "test_tex_upload: all passed\n", fails);
    return fails != 0;
}
