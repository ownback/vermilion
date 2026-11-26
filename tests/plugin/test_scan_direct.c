// SPDX-License-Identifier: MIT
/* test_scan_direct.c - the decisions of direct scan-out (src/metal-plugin/nvmtl_scan_direct.h, used by nvmtl_scanout.c):
   the display-surface pair, the start, the write gate (Linux's flip-complete test, the bounce, the timeout), the
   failure cooldown, the ws-direct-appeared note. Also a model of two display surfaces flipping at
   vblank, driven through the gate, that checks no write is ever let through to a surface HUBP0 may fetch and that the
   gate never stalls for good.
   cc -Wall -Wextra -Werror -I src/metal-plugin tests/plugin/test_scan_direct.c -o /tmp/test_scan_direct && /tmp/test_scan_direct */
#include <stdio.h>
#include <string.h>
#include "nvmtl_scan_direct.h"
static int fails, checks;
static void arm(const char *w, int ok) { checks++; if (!ok) { printf("FAIL  %s\n", w); fails++; } }

static char R[8], O[8], M[8];   /* stand-ins for IOSurfaces, textures, memories */
static nvmtl_sd_cand cand(uint32_t sid, int ri, int oi, int mi, int l10r)
{
    nvmtl_sd_cand c; memset(&c, 0, sizeof c);
    c.sid = sid; c.w = 2560; c.h = 1440; c.pitch = 10240; c.l10r = l10r;
    c.ref = &R[ri]; c.owner = &O[oi]; c.base = &R[ri]; c.buf = &M[mi]; c.mem = &M[mi];
    return c;
}

/* ---- the model: HUBP0 with two surfaces and the bounce slot; a programmed flip latches at the next vblank ---- */
enum { S0 = 0, S1 = 1, BOUNCE = 2, NONE = 9 };
typedef struct { int front, pending; uint64_t t_us, period_us; } hubp;
static void hubp_tick(hubp *h, uint64_t us)
{
    const uint64_t to = h->t_us + us;
    if (h->pending != NONE && to / h->period_us > h->t_us / h->period_us) { h->front = h->pending; h->pending = NONE; }
    h->t_us = to;
}
static int hubp_writable(const hubp *h, int k) { return h->front != k && h->pending != k; }   /* the kext's WRITABLE */
/* a write of surface k through the gate, 200 us per poll as nvmtl_vk_scanout_write_gate; *torn = 1 if it was let through
   while HUBP0 could fetch k */
static int gate_write(hubp *h, int k, int partnerOut, int *torn, uint64_t *waited, int *bounces)
{
    int bounced = 0; uint64_t us = 0;
    for (;;) {
        const int act = nvmtl_sd_gate(hubp_writable(h, k), h->pending != NONE, partnerOut, hubp_writable(h, BOUNCE), bounced, us);
        if (act == NVMTL_SD_GO) { if (!hubp_writable(h, k)) *torn = 1; *waited = us; return act; }
        if (act == NVMTL_SD_FAIL) { *waited = us; return act; }
        if (act == NVMTL_SD_BOUNCE) { bounced = 1; (*bounces)++; h->pending = BOUNCE; }   /* copy k there, flip there */
        hubp_tick(h, 200); us += 200;
    }
}

int main(void)
{
    /* ---- the pair ---- */
    nvmtl_sd_table t; memset(&t, 0, sizeof t);
    nvmtl_sd_cand ev, c;
    unsigned a = 0, b = 0;
    c = cand(11, 1, 1, 1, 0); arm("first surface: nothing evicted", nvmtl_sd_note(&t, &c, &ev) == 0);
    arm("one surface is no pair", nvmtl_sd_pair(&t, 2560, 1440, 10240, &a, &b) == 1);
    c = cand(12, 2, 2, 2, 0); arm("second surface: nothing evicted", nvmtl_sd_note(&t, &c, &ev) == 0);
    arm("two surfaces: a pair, newest first", nvmtl_sd_pair(&t, 2560, 1440, 10240, &a, &b) == 2 && t.c[a].sid == 12 && t.c[b].sid == 11);
    c = cand(11, 1, 1, 1, 0); arm("the same surface again: nothing evicted", nvmtl_sd_note(&t, &c, &ev) == 0);
    arm("the pair follows the last write", nvmtl_sd_pair(&t, 2560, 1440, 10240, &a, &b) == 2 && t.c[a].sid == 11 && t.c[b].sid == 12);
    arm("another size: no pair", nvmtl_sd_pair(&t, 1920, 1080, 7680, &a, &b) == 0);
    arm("another pitch: no pair", nvmtl_sd_pair(&t, 2560, 1440, 10496, &a, &b) == 0);
    /* the same surface through a new texture: the old entry's references go back to the caller */
    c = cand(11, 1, 3, 3, 0);
    arm("a new backing evicts the old one", nvmtl_sd_note(&t, &c, &ev) == 1 && ev.sid == 11 && ev.owner == &O[1] && ev.mem == &M[1]);
    arm("and the entry has the new backing", nvmtl_sd_pair(&t, 2560, 1440, 10240, &a, &b) == 2 && t.c[a].mem == &M[3]);
    /* the same id, another IOSurface (freed and reused): a new entry */
    c = cand(12, 4, 4, 4, 1);
    arm("a reused id is a new surface", nvmtl_sd_note(&t, &c, &ev) == 0);
    arm("the pair is the two newest", nvmtl_sd_pair(&t, 2560, 1440, 10240, &a, &b) == 2 && t.c[a].ref == &R[4] && t.c[b].sid == 11);
    /* full: the oldest goes */
    c = cand(13, 5, 5, 5, 0); (void)nvmtl_sd_note(&t, &c, &ev);
    c = cand(14, 6, 6, 6, 0);
    arm("full table: the oldest is evicted", nvmtl_sd_note(&t, &c, &ev) == 1 && ev.sid == 12 && ev.ref == &R[2]);
    { int live = 0; for (unsigned i = 0; i < NVMTL_SD_CANDS; i++) live += t.c[i].sid != 0; arm("the table stays bounded", live == (int)NVMTL_SD_CANDS); }

    /* ---- the start ---- */
    nvmtl_sd_start_in s; memset(&s, 0, sizeof s);
    s.wanted = 1; s.kextOk = 1; s.async = 1; s.hubpFormat = NVMTL_SD_FMT8; s.pitchPx = 2560; s.pitch = 10240; s.pairs = 2; s.shownInPair = 1;
    arm("the live case starts direct", nvmtl_sd_start(&s) == NVMTL_SD_START_DIRECT);
    { nvmtl_sd_start_in x = s; x.wanted = 0; arm("switch off: copy", nvmtl_sd_start(&x) == NVMTL_SD_START_COPY); }
    { nvmtl_sd_start_in x = s; x.kextOk = 0; arm("kext refuses (old kext, 256 MiB BAR): copy", nvmtl_sd_start(&x) == NVMTL_SD_START_COPY); }
    { nvmtl_sd_start_in x = s; x.async = 0; arm("presents on the committing thread: copy", nvmtl_sd_start(&x) == NVMTL_SD_START_COPY); }
    { nvmtl_sd_start_in x = s; x.pitch = 10496; arm("pitch is not HUBP0's: copy", nvmtl_sd_start(&x) == NVMTL_SD_START_COPY); }
    { nvmtl_sd_start_in x = s; x.pairs = 1; arm("one surface known: wait", nvmtl_sd_start(&x) == NVMTL_SD_START_WAIT); }
    { nvmtl_sd_start_in x = s; x.pairs = 1; x.waitedNs = NVMTL_SD_WAIT_PAIR_NS; arm("one surface for 2 s: copy", nvmtl_sd_start(&x) == NVMTL_SD_START_COPY); }
    { nvmtl_sd_start_in x = s; x.shownInPair = 0; arm("the shown surface is not in the pair: wait", nvmtl_sd_start(&x) == NVMTL_SD_START_WAIT); }
    { nvmtl_sd_start_in x = s; x.pairL10r[1] = 1; arm("l10r on the 8-bit scan-out: copy (it narrows)", nvmtl_sd_start(&x) == NVMTL_SD_START_COPY); }
    { nvmtl_sd_start_in x = s; x.hubpFormat = NVMTL_SD_FMT10; arm("BGRA on the 10-bit scan-out: copy (it widens)", nvmtl_sd_start(&x) == NVMTL_SD_START_COPY); }
    { nvmtl_sd_start_in x = s; x.hubpFormat = NVMTL_SD_FMT10; x.pairL10r[0] = x.pairL10r[1] = 1; arm("HDR: l10r on 10-bit starts direct", nvmtl_sd_start(&x) == NVMTL_SD_START_DIRECT); }
    { nvmtl_sd_start_in x = s; x.hubpFormat = 3; arm("another HUBP0 format: copy", nvmtl_sd_start(&x) == NVMTL_SD_START_COPY); }

    /* ---- the gate, one poll ---- */
    arm("writable: go", nvmtl_sd_gate(1, 1, 1, 0, 0, 0) == NVMTL_SD_GO);
    arm("writable after the limit still goes", nvmtl_sd_gate(1, 0, 0, 0, 0, NVMTL_SD_GATE_MAX_US + 1) == NVMTL_SD_GO);
    arm("a flip pending: wait for its latch", nvmtl_sd_gate(0, 1, 0, 1, 0, 0) == NVMTL_SD_WAIT);
    arm("front, the partner's write coming: wait", nvmtl_sd_gate(0, 0, 1, 1, 0, 1000) == NVMTL_SD_WAIT);
    arm("front, nothing coming: bounce", nvmtl_sd_gate(0, 0, 0, 1, 0, 0) == NVMTL_SD_BOUNCE);
    arm("front, the partner late: bounce", nvmtl_sd_gate(0, 0, 1, 1, 0, NVMTL_SD_BOUNCE_AFTER_US) == NVMTL_SD_BOUNCE);
    arm("the bounce slot busy: wait", nvmtl_sd_gate(0, 0, 0, 0, 0, 0) == NVMTL_SD_WAIT);
    arm("bounced once: wait for that flip", nvmtl_sd_gate(0, 0, 0, 1, 1, 0) == NVMTL_SD_WAIT);
    arm("never writable: fail at the limit", nvmtl_sd_gate(0, 1, 1, 1, 1, NVMTL_SD_GATE_MAX_US) == NVMTL_SD_FAIL);

    /* ---- the model: CoreDisplay's patterns at 240 / 144 / 60 Hz ---- */
    const uint64_t periods[3] = { 4167, 6944, 16667 };
    for (int pi = 0; pi < 3; pi++) {
        hubp h = { S0, NONE, 0, periods[pi] };
        int torn = 0, failed = 0, bounces = 0; uint64_t waited = 0, maxWait = 0;
        /* alternate S0 / S1, presenting each after its write; every 7th frame the surface just presented is written
           again (CoreDisplay's waited follow-up commit, E0 2026-10-28) with no other write coming */
        int k = S1;
        for (int f = 0; f < 5000; f++) {
            if (gate_write(&h, k, 0, &torn, &waited, &bounces) != NVMTL_SD_GO) failed++;
            if (waited > maxWait) maxWait = waited;
            hubp_tick(&h, 300 + (uint64_t)(f % 5) * 400);   /* the GPU draws it */
            h.pending = k;                                  /* the present */
            if (f % 7 == 3) {                               /* the same surface again */
                if (gate_write(&h, k, 0, &torn, &waited, &bounces) != NVMTL_SD_GO) failed++;
                if (waited > maxWait) maxWait = waited;
                hubp_tick(&h, 200);
                h.pending = k;
            }
            k = k == S0 ? S1 : S0;
            hubp_tick(&h, (uint64_t)(f % 3) * 1500);
        }
        char w[160];
        snprintf(w, sizeof w, "%llu us frames: no write to a fetched surface (torn %d)", (unsigned long long)periods[pi], torn);
        arm(w, torn == 0);
        snprintf(w, sizeof w, "%llu us frames: no gate gave up (%d)", (unsigned long long)periods[pi], failed);
        arm(w, failed == 0);
        snprintf(w, sizeof w, "%llu us frames: the longest wait %llu us is about two vblanks", (unsigned long long)periods[pi], (unsigned long long)maxWait);
        arm(w, maxWait <= 2 * periods[pi] + 400);
        snprintf(w, sizeof w, "%llu us frames: the repeated writes bounced (%d)", (unsigned long long)periods[pi], bounces);
        arm(w, bounces > 0 && bounces <= 5000 / 7 + 1);
    }
    /* a present that never comes (the head gate dropped it) with the partner counted as coming: the bounce after
       NVMTL_SD_BOUNCE_AFTER_US, not the failure */
    {
        hubp h = { S0, NONE, 0, 4167 };
        int torn = 0, bounces = 0; uint64_t waited = 0;
        const int r = gate_write(&h, S0, 1, &torn, &waited, &bounces);
        arm("partner counted but no flip: bounce after the wait, then go", r == NVMTL_SD_GO && bounces == 1 && waited >= NVMTL_SD_BOUNCE_AFTER_US && !torn);
    }
    /* HUBP0 never latches (a stuck flip): the gate gives up instead of holding WindowServer */
    {
        hubp h = { S0, S0, 0, 1ull << 62 };
        int torn = 0, bounces = 0; uint64_t waited = 0;
        arm("a flip that never latches: fail at the limit", gate_write(&h, S0, 0, &torn, &waited, &bounces) == NVMTL_SD_FAIL &&
                                                            waited >= NVMTL_SD_GATE_MAX_US && waited < NVMTL_SD_GATE_MAX_US + 1000 && !torn);
    }

    /* ---- ws-direct appearing while the copy path presents: said once, nothing else ---- */
    {
        int said = 0;
        arm("appeared: not wanted: nothing", !nvmtl_sd_appeared_note(0, 0, &said) && !said);
        arm("appeared: wanted at the start (the start chose): nothing", !nvmtl_sd_appeared_note(1, 1, &said) && !said);
        arm("appeared: wanted at the start, since removed: nothing", !nvmtl_sd_appeared_note(1, 0, &said) && !said);
        arm("appeared: the file is new: say it", nvmtl_sd_appeared_note(0, 1, &said) == 1 && said);
        arm("appeared: said once, not again", !nvmtl_sd_appeared_note(0, 1, &said) && !nvmtl_sd_appeared_note(0, 1, &said));
        said = 0;
        for (int f = 0; f < 3000; f++) { (void)nvmtl_sd_appeared_note(0, f >= 100, &said); }
        arm("appeared: over many frames the line comes once", said == 1);
    }
    /* ---- the cooldown ---- */
    unsigned nf = 0; uint64_t until = 0; int off = 0;
    nvmtl_sd_fail(&nf, 1000, &until, &off);
    arm("a failure: 10 s of copy path", until == 1000 + NVMTL_SD_COOLDOWN_NS && !off);
    for (unsigned i = 1; i < NVMTL_SD_MAX_FAILS; i++) nvmtl_sd_fail(&nf, 2000, &until, &off);
    arm("five failures: off for the process", off == 1 && nf == NVMTL_SD_MAX_FAILS);

    printf("test_scan_direct: %d/%d checks passed\n", checks - fails, checks);
    return fails ? 1 : 0;
}
