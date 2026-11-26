// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
/* nvmtl_scan_direct.h: direct scan-out of WindowServer's display surfaces (kext b162, PHXN_SEL_SCAN_DIRECT), the
   decisions without Vulkan or IOKit, so tests/plugin/test_scan_direct.c drives the same code on a host.

   GPU present (nvmtl_scanout.c) copied each CoreDisplay display surface from its system pages into a VRAM slot before
   every flip: ~1 ms of copy + wait per present at 1440p (finding 2026-11-25-windowserver-composite-cost.md, row 3). In
   direct mode the two display surfaces are drawn in VRAM: the host import each one's texture is drawn through is bound
   to slot 0 or 1 (its GPU maps then reach the slot's VRAM), and a present is the flip alone. As on a Mac, WindowServer's
   framebuffer is in VRAM and the display scans it out.

   What this header decides:
   - the pair: the last two distinct display surfaces CoreDisplay's unwaited commits wrote (nvmtl_sd_note);
   - whether a start may bind them (nvmtl_sd_start): same size, pitch = HUBP0's, format = HUBP0's, both drawn on their
     own pages (a plain host import), and the kext says direct is allowed;
   - the write gate (nvmtl_sd_gate): nothing is submitted that writes a surface HUBP0 may still fetch (Linux's
     flip-complete test, the kext's PHXN_SCANSLOT_WRITABLE). If the surface on screen is to be written again and no other
     flip is coming, its VRAM is first copied to the third slot and HUBP0 flips there (the bounce);
   - when to give up for a while (nvmtl_sd_fail);
   - direct scan-out becoming wanted (ws-direct-off removed) while the copy path presents (nvmtl_sd_appeared_note: said
     once, takes effect at the next start). */
#pragma once
#include <stdint.h>
#include <stddef.h>

#define NVMTL_SD_CANDS 4u                    /* display surfaces remembered; the pair is the two newest */
#define NVMTL_SD_WAIT_PAIR_NS 2000000000ull  /* a start waits this long for the second display surface, then copies */
#define NVMTL_SD_BOUNCE_AFTER_US 50000ull    /* the front surface is written again: bounce at once, or after this if a flip may come */
#define NVMTL_SD_GATE_MAX_US 250000ull       /* the gate gives up (direct off, copy path) after this */
#define NVMTL_SD_COOLDOWN_NS 10000000000ull  /* after a failure, copy path for this long */
#define NVMTL_SD_MAX_FAILS 5u                /* then copy path for the life of the process */
#define NVMTL_SD_FMT8 8u                     /* PHXN_SCAN_FMT_ARGB8888: BGRA */
#define NVMTL_SD_FMT10 10u                   /* PHXN_SCAN_FMT_ARGB2101010: l10r */

typedef struct {
    uint32_t sid, w, h, pitch;
    int l10r;
    uint64_t seq;            /* note order: the newest has the highest */
    void *ref, *owner;       /* the IOSurface and the backing texture, retained by the caller while listed */
    void *base;              /* the surface's pages in this process */
    void *buf, *mem;         /* the VkBuffer / VkDeviceMemory of the host import its texture is drawn through */
} nvmtl_sd_cand;
typedef struct { nvmtl_sd_cand c[NVMTL_SD_CANDS]; uint64_t seq; } nvmtl_sd_table;

/* A display surface was written (CDCOPY's display set). Updates its entry, or takes a free one, or the oldest; the
   entry it replaced is copied to *evicted (ref / owner for the caller to release) and 1 returned; else 0. */
static inline int nvmtl_sd_note(nvmtl_sd_table *t, const nvmtl_sd_cand *in, nvmtl_sd_cand *evicted)
{
    unsigned slot = NVMTL_SD_CANDS, oldest = 0;
    for (unsigned i = 0; i < NVMTL_SD_CANDS; i++) {
        if (t->c[i].sid == in->sid && t->c[i].ref == in->ref) { slot = i; break; }
        if (t->c[i].seq < t->c[oldest].seq) oldest = i;
    }
    int out = 0;
    if (slot == NVMTL_SD_CANDS) {
        for (unsigned i = 0; i < NVMTL_SD_CANDS && slot == NVMTL_SD_CANDS; i++) if (!t->c[i].sid) slot = i;
        if (slot == NVMTL_SD_CANDS) slot = oldest;
        if (t->c[slot].sid) { if (evicted) *evicted = t->c[slot]; out = 1; }
    } else if (t->c[slot].owner != in->owner || t->c[slot].mem != in->mem) {
        /* the same surface, another backing (a new texture): the old one's references go */
        if (evicted) *evicted = t->c[slot]; out = 1;
    } else {
        t->c[slot].seq = ++t->seq;
        return 0;
    }
    t->c[slot] = *in;
    t->c[slot].seq = ++t->seq;
    return out;
}

/* The two newest entries of size w x h, row pitch `pitch`: their indices in *a (the newest) and *b. Returns how many (0-2). */
static inline int nvmtl_sd_pair(const nvmtl_sd_table *t, uint32_t w, uint32_t h, uint32_t pitch, unsigned *a, unsigned *b)
{
    int n = 0; unsigned i1 = 0, i2 = 0; uint64_t s1 = 0, s2 = 0;
    for (unsigned i = 0; i < NVMTL_SD_CANDS; i++) {
        const nvmtl_sd_cand *c = &t->c[i];
        if (!c->sid || c->w != w || c->h != h || c->pitch != pitch) continue;
        n++;
        if (c->seq > s1) { i2 = i1; s2 = s1; i1 = i; s1 = c->seq; }
        else if (c->seq > s2) { i2 = i; s2 = c->seq; }
    }
    if (a) *a = i1;
    if (b) *b = i2;
    return n > 2 ? 2 : n;
}

enum { NVMTL_SD_START_DIRECT = 0, NVMTL_SD_START_COPY = 1, NVMTL_SD_START_WAIT = 2 };
typedef struct {
    int wanted;          /* direct scan-out is on (no /Library/GPUBundles/nvmtl/ws-direct-off), not in a cooldown, not given up */
    int kextOk;          /* scan query flags PHXN_SCANQ_DIRECT_OK, and RADV has radv_darwin_n48n_call */
    int async;           /* async GPU present (no ws-gpu-present-async-off): presents run on the worker, never on a
                            thread the gate blocks */
    uint32_t hubpFormat; /* scan query hubp_format */
    uint32_t pitchPx;    /* scan query pitch_px */
    int pairs;           /* nvmtl_sd_pair's count for the shown surface's geometry */
    int shownInPair;     /* the surface being presented is one of the two */
    int pairL10r[2];     /* the two surfaces' formats */
    uint32_t pitch;      /* the shown surface's row bytes */
    uint64_t waitedNs;   /* since the first start that wanted direct and found no pair */
} nvmtl_sd_start_in;

static inline int nvmtl_sd_fmt_ok(int l10r, uint32_t hubpFormat)
{
    return l10r ? hubpFormat == NVMTL_SD_FMT10 : hubpFormat == NVMTL_SD_FMT8;
}

static inline int nvmtl_sd_start(const nvmtl_sd_start_in *s)
{
    if (!s->wanted || !s->kextOk || !s->async) return NVMTL_SD_START_COPY;
    if (s->pitch != s->pitchPx * 4u) return NVMTL_SD_START_COPY;
    if (s->pairs < 2 || !s->shownInPair) return s->waitedNs < NVMTL_SD_WAIT_PAIR_NS ? NVMTL_SD_START_WAIT : NVMTL_SD_START_COPY;
    if (!nvmtl_sd_fmt_ok(s->pairL10r[0], s->hubpFormat) || !nvmtl_sd_fmt_ok(s->pairL10r[1], s->hubpFormat)) return NVMTL_SD_START_COPY;
    return NVMTL_SD_START_DIRECT;
}

/* The write gate, once per poll. writable: the kext's PHXN_SCANSLOT_WRITABLE for the surface's slot; flipPending: some
   flip is programmed and not latched (it frees the front when it latches); partnerOut: the other display surface has a
   committed write not finished yet (its present will follow); bounceFree: the third slot is writable; bounced: this gate
   already bounced; waitedUs: since the gate started. */
enum { NVMTL_SD_GO = 0, NVMTL_SD_WAIT = 1, NVMTL_SD_BOUNCE = 2, NVMTL_SD_FAIL = 3 };
static inline int nvmtl_sd_gate(int writable, int flipPending, int partnerOut, int bounceFree, int bounced, uint64_t waitedUs)
{
    if (writable) return NVMTL_SD_GO;
    if (waitedUs >= NVMTL_SD_GATE_MAX_US) return NVMTL_SD_FAIL;
    if (!bounced && !flipPending && bounceFree && (!partnerOut || waitedUs >= NVMTL_SD_BOUNCE_AFTER_US)) return NVMTL_SD_BOUNCE;
    return NVMTL_SD_WAIT;
}

/* After a failure: copy path until *untilNs; after NVMTL_SD_MAX_FAILS, for good (*off = 1). */
static inline void nvmtl_sd_fail(unsigned *fails, uint64_t nowNs, uint64_t *untilNs, int *off)
{
    if (++*fails >= NVMTL_SD_MAX_FAILS) *off = 1;
    *untilNs = nowNs + NVMTL_SD_COOLDOWN_NS;
}

/* Direct scan-out became wanted (ws-direct-off removed) while the copy path presents. Turning it off works live (the
   next present copies back and releases); the switch-on does not: a move to direct would release the plane (the console
   shows for a gap, VRR drops and resumes), and the bind drains the queue, which during an animation is the normal state,
   so it is left to the next WindowServer start, where the direct choice is made anyway. The plugin says so once.
   wantedAtStart: the switch at the time this GPU present start chose; wantedNow: now; *said: set by the first call that
   returns 1. 1 = log the line.
   Host-tested only (tests/plugin/test_scan_direct.c); not run on hardware (unverified). */
static inline int nvmtl_sd_appeared_note(int wantedAtStart, int wantedNow, int *said)
{
    if (wantedAtStart || !wantedNow || *said) return 0;
    *said = 1;
    return 1;
}
