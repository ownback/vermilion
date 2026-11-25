// SPDX-License-Identifier: MIT
/* test_pool_range.c - the range allocator of the plugin's buffer pools (src/metal-plugin/nvmtl_pool_range.h, used by
   pool_buffer_create_in in nvmtl_vk.c). Live ranges never overlap and stay inside their block, freed space is reused.
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
        const int grow = nlive < 200 || (nlive < 7632 && rnd() % 100 < 55);
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
    free(s.fr);
    printf(fails ? "FAILED (%d)\n" : "all passed\n", fails);
    return fails ? 1 : 0;
}
