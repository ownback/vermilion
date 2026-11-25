// SPDX-License-Identifier: MIT
/* test_passtime.c - when a process arms the per-pass GPU timer (src/metal-plugin/nvmtl_passtime.h, used by
   nvmtl_pt_armed in nvmtl_vk.c). Hardware-free.
   Arms: no file arms nothing; a fresh touch arms once and not again; a second touch (new mtime) or a new file (new
   inode) arms again; a touch older than the age limit arms nothing (a process started long after it); a stale touch
   does not consume the request, so a later touch still arms.
   cc -fsanitize=address,undefined -I src/metal-plugin tests/plugin/test_passtime.c -o /tmp/test_passtime && /tmp/test_passtime */
#include <stdio.h>
#include <stdint.h>
#include "nvmtl_passtime.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(void)
{
    const uint64_t s = 1000000000ull, t0 = 1764100000ull * s;
    nvmtl_pt_req last = {0};
    CHECK(!nvmtl_pt_should_arm(0, 0, 0, t0, &last), "no request file arms nothing");
    CHECK(!nvmtl_pt_should_arm(1, 7, t0, t0, NULL), "no state arms nothing");
    CHECK(nvmtl_pt_should_arm(1, 7, t0, t0 + s / 4, &last), "a fresh touch arms");
    CHECK(!nvmtl_pt_should_arm(1, 7, t0, t0 + s / 2, &last), "the same touch does not arm again (WindowServer cannot unlink it)");
    CHECK(!nvmtl_pt_should_arm(1, 7, t0, t0 + 10 * s, &last), "still the same touch 10 s later");
    CHECK(nvmtl_pt_should_arm(1, 7, t0 + 20 * s, t0 + 20 * s + s / 4, &last), "a second touch (new mtime) arms again");
    CHECK(nvmtl_pt_should_arm(1, 9, t0 + 20 * s, t0 + 21 * s, &last), "a new file with the same mtime (new inode) arms");
    nvmtl_pt_req late = {0};
    CHECK(!nvmtl_pt_should_arm(1, 9, t0 + 20 * s, t0 + 20 * s + NVMTL_PT_MAX_AGE_NS + 1, &late), "a touch older than the limit does not arm a late process");
    CHECK(late.ino == 0 && late.mtime_ns == 0, "a stale touch leaves the state as it was");
    CHECK(nvmtl_pt_should_arm(1, 9, t0 + 60 * s, t0 + 60 * s + 1, &late), "the next touch arms the late process");
    CHECK(nvmtl_pt_should_arm(1, 9, t0 + 20 * s, t0 + 20 * s + NVMTL_PT_MAX_AGE_NS, &(nvmtl_pt_req){0}), "exactly at the limit still arms");
    printf("%s (%d failed)\n", fails ? "FAIL" : "ok", fails);
    return fails != 0;
}
