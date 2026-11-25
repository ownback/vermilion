// SPDX-License-Identifier: MIT
/* test_pool_range.c - the range allocator of the plugin's buffer pools (src/metal-plugin/nvmtl_pool_range.h, used by
   pool_buffer_create_in in nvmtl_vk.c). Live ranges never overlap and stay inside their block, freed space is reused,
   a released Private range waits for the GPU, and Maps' workload of 2026-11-25 fits in a few kext BOs instead of 4095+.
   cc -I src/metal-plugin tests/plugin/test_pool_range.c -o /tmp/test_pool_range && /tmp/test_pool_range */
#include <stdio.h>
#include <string.h>
#include "nvmtl_pool_range.h"
static int fails;
static void arm(const char *w, int ok) { printf("%s  %s\n", ok ? "ok  " : "FAIL", w); if (!ok) fails++; }
static uint64_t rng = 0x9e3779b97f4a7c15ull;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)rng; }

#define CAP  (4u << 20)
#define AL   256u
#define NMAX 20000
#define MAPS_PEAK_LIVE 7632   /* the most buffers Maps had live at once (2026-11-25 log) */
typedef struct { size_t off, len; } live_t;
static live_t live[NMAX]; static uint32_t nlive;

/* every live range inside the block, none overlapping another: a byte map of the block */
static int ranges_sound(void)
{
    static uint8_t owner[CAP / AL];
    memset(owner, 0, sizeof owner);
    for (uint32_t i = 0; i < nlive; i++) {
        if (live[i].off % AL || live[i].len % AL || live[i].off + live[i].len > CAP) return 0;
        for (size_t u = live[i].off / AL; u < (live[i].off + live[i].len) / AL; u++) { if (owner[u]) return 0; owner[u] = 1; }
    }
    return 1;
}
static size_t len_of(uint32_t r)
{
    static const size_t maps[] = { 4, 12, 16, 96, 128, 512, 768, 798, 8008, 65536 };   // sizes Maps asked for (2026-11-25 log)
    size_t n = maps[r % (sizeof maps / sizeof maps[0])];
    return (n + AL - 1) / AL * AL;
}

int main(void)
{
    nvmtl_range_set s; memset(&s, 0, sizeof s);
    size_t a = 0, b = 0, c = 0, d = 0;
    arm("the first range starts at 0", nvmtl_range_take(&s, CAP, 256, &a) && a == 0);
    arm("the next ranges bump upward", nvmtl_range_take(&s, CAP, 512, &b) && b == 256 && nvmtl_range_take(&s, CAP, 256, &c) && c == 768);
    nvmtl_range_give(&s, b, 512, 2);
    arm("a freed middle range is reused first fit", nvmtl_range_take(&s, CAP, 256, &d) && d == 256);
    nvmtl_range_give(&s, c, 256, 2);
    arm("releasing the top range lowers the high-water mark", s.used == 768);
    arm("a range larger than the block is refused", !nvmtl_range_take(&s, CAP, CAP + AL, &d));
    free(s.fr); memset(&s, 0, sizeof s);

    // A Maps-like churn: tens of thousands of creates, a live window of thousands, random frees.
    nlive = 0; int sound = 1, refused = 0; uint64_t takes = 0;
    for (int step = 0; step < 200000; step++) {
        const int grow = nlive < 200 || (nlive < MAPS_PEAK_LIVE && rnd() % 100 < 55);
        if (grow) {
            size_t len = len_of(rnd()), off;
            if (!nvmtl_range_take(&s, CAP, len, &off)) { refused++; continue; }
            live[nlive++] = (live_t){ off, len }; takes++;
        } else if (nlive) {
            uint32_t k = rnd() % nlive; live_t g = live[k]; live[k] = live[--nlive];
            nvmtl_range_give(&s, g.off, g.len, nlive);
        }
        if ((step & 1023) == 0 && !ranges_sound()) sound = 0;
    }
    arm("200000 Maps-like steps: live ranges never overlap and stay in the block", sound && ranges_sound());
    printf("      %llu ranges taken, %d refused for room, %u live at the end, %u freed ranges recorded\n",
           (unsigned long long)takes, refused, nlive, s.nfr);
    while (nlive) { live_t g = live[--nlive]; nvmtl_range_give(&s, g.off, g.len, nlive); }
    size_t sum = 0; for (uint32_t i = 0; i < s.nfr; i++) sum += s.fr[i].len;
    arm("with every range back, the freed ranges cover the high-water mark", sum == s.used);
    free(s.fr); memset(&s, 0, sizeof s);

    // An emptied block starts over, also when the last range merged into a freed neighbour (it used to keep its
    // fragments, and a block-sized range no longer fit in an empty block).
    nvmtl_range_take(&s, CAP, 256, &a); nvmtl_range_take(&s, CAP, 256, &b); nvmtl_range_take(&s, CAP, 256, &c);
    nvmtl_range_give(&s, b, 256, 2); nvmtl_range_give(&s, a, 256, 1);   // a merges into b's freed range
    nvmtl_range_give(&s, c, 256, 0);
    arm("an emptied block starts over (no fragments, high-water 0)", s.used == 0 && s.nfr == 0);
    arm("an emptied block takes a block-sized range", nvmtl_range_take(&s, CAP, CAP, &d) && d == 0);
    s.nfr = 0; s.used = 0; nvmtl_range_take(&s, CAP, 256, &a); nvmtl_range_take(&s, CAP, 256, &b);
    nvmtl_range_give(&s, a, 256, 1); nvmtl_range_give(&s, b, 256, 0);
    arm("an emptied block starts over after a release below the top", s.used == 0 && s.nfr == 0);
    free(s.fr); memset(&s, 0, sizeof s);

    // The hold list: a range released while submission 7 may still run waits until 7 is done; order is kept.
    nvmtl_range_fifo f; memset(&f, 0, sizeof f); nvmtl_held_range h;
    int pushed = 1;
    for (uint32_t i = 0; i < 1000; i++) pushed &= nvmtl_fifo_push(&f, (nvmtl_held_range){ NULL, i * 256, 256, 7 + i / 100 }) == 0;
    arm("1000 held ranges pushed", pushed && nvmtl_fifo_len(&f) == 1000);
    arm("nothing comes back while submission 6 is the last one done", !nvmtl_fifo_pop_ready(&f, 6, &h));
    uint32_t got = 0; int ordered = 1;
    while (nvmtl_fifo_pop_ready(&f, 7, &h)) { ordered &= h.off == got * 256; got++; }
    arm("submission 7 done: exactly its 100 ranges come back, oldest first", got == 100 && ordered);
    for (uint32_t i = 0; i < 5000; i++) pushed &= nvmtl_fifo_push(&f, (nvmtl_held_range){ NULL, 0, 256, 100 }) == 0;   // reuses the drained head
    while (nvmtl_fifo_pop_ready(&f, 1000, &h)) got++;
    arm("everything comes back once the GPU is past the last seq, the list empties", pushed && got == 6000 && nvmtl_fifo_len(&f) == 0 && f.head == 0 && f.n == 0);
    free(f.q);

    // Maps on the XTX machine, 2026-11-25 17:12-17:13: ~65000 Managed buffers of 4..798 B, up to 7632 live at once,
    // each one's VRAM copy a kext BO; the kext refused the 4096th handle (debug.phxvm: cause 3, BOs 4095). The same
    // churn through the Private pool, with the GPU 3 submissions behind (a submission every 16 creates):
    enum { BLOCKS = 64 };
    nvmtl_range_set blk[BLOCKS]; uint32_t bl[BLOCKS]; memset(blk, 0, sizeof blk); memset(bl, 0, sizeof bl);
    typedef struct { uint32_t b; size_t off, len; } prange;
    static prange plive[NMAX]; uint32_t pn = 0, nblocks = 0, peak_blocks = 0, peak_live = 0;
    nvmtl_range_fifo held; memset(&held, 0, sizeof held);
    uint64_t sub = 0; int fit = 1, routed = 1;
    static const size_t msz[] = { 4, 12, 16, 96, 128, 512, 768, 798 };
    for (int step = 0; step < 300000; step++) {
        if ((step & 15) == 0) sub++;
        const uint64_t done = sub > 3 ? sub - 3 : 0;
        while (nvmtl_fifo_pop_ready(&held, done, &h)) { uint32_t k = (uint32_t)(uintptr_t)h.blk; bl[k]--; nvmtl_range_give(&blk[k], h.off, h.len, bl[k]); }
        const int grow = pn < MAPS_PEAK_LIVE && (pn < 1000 || rnd() % 100 < 52);
        if (grow) {
            const size_t want = msz[rnd() % (sizeof msz / sizeof msz[0])]; routed &= nvmtl_pool_private_fits(want, 0);
            const size_t len = (want + AL - 1) / AL * AL; size_t off = 0; uint32_t k = 0;
            while (k < nblocks && !nvmtl_range_take(&blk[k], NVMTL_PPOOL_BLOCK, len, &off)) k++;
            if (k == nblocks) { if (nblocks == BLOCKS) { fit = 0; break; } nblocks++; nvmtl_range_take(&blk[k], NVMTL_PPOOL_BLOCK, len, &off); }
            bl[k]++; plive[pn++] = (prange){ k, off, len };
        } else if (pn) {
            uint32_t i = rnd() % pn; prange g = plive[i]; plive[i] = plive[--pn];
            nvmtl_fifo_push(&held, (nvmtl_held_range){ (void *)(uintptr_t)g.b, g.off, g.len, sub });
        }
        if (nblocks > peak_blocks) peak_blocks = nblocks;
        if (pn > peak_live) peak_live = pn;
    }
    printf("      Maps-like churn: peak %u live buffers (each was a kext BO), peak %u pool blocks of %u MiB\n",
           peak_live, peak_blocks, NVMTL_PPOOL_BLOCK >> 20);
    arm("Maps' buffer sizes route to the Private pool; Shared and over-256 KiB ones do not",
        routed && !nvmtl_pool_private_fits(96, 1) && !nvmtl_pool_private_fits(96, 2) && !nvmtl_pool_private_fits(NVMTL_PPOOL_MAX + 1, 0)
        && nvmtl_pool_private_fits(NVMTL_PPOOL_MAX, 0) && !nvmtl_pool_private_fits(0, 0));
    arm("the old way needs more than the kext's 4095 handles for this churn", peak_live > 4095);
    arm("the Private pool holds it in at most 4 blocks (kext BOs)", fit && peak_blocks <= 4);
    free(held.q); for (uint32_t k = 0; k < BLOCKS; k++) free(blk[k].fr);
    printf(fails ? "FAILED (%d)\n" : "all passed\n", fails);
    return fails ? 1 : 0;
}
