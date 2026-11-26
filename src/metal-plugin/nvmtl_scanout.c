// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
/* Our code (Vermilion, RX 7900 XT): WindowServer GPU present through the PhxBringup scanout selectors. Included at the end
   of nvmtl_vk.c (one translation unit with it: uses g_dev, g_queue, the pvk* table, nvmtl_submit_mutex, memtype,
   g_host_align). Diagnostics live in nvmtl_scan_diag.c, included in the middle so the order of definitions is unchanged. */
/*
 * WindowServer GPU present (PhxBringup scanout selectors 9..14, through RADV's radv_darwin_scanout_* exports).
 * The display pipe copied each WindowServer frame on the CPU, and could read one the GPU was still drawing: Apple's
 * family waits for a plane surface's last GPU write before its performTransaction, which never fires on our stack
 * (RE'd 2026-10-25). Here, once WindowServer's swap-preceding command buffer has finished on the GPU, its display
 * surface is copied on the GPU into one of three VRAM slots and HUBP0 flips to that slot at the next vblank, as
 * Cobalt64 does. The display pipe's own copies keep going to the console surface, which is off screen meanwhile.
 * Any failure gives the plane back and leaves this process on the CPU copy for good.
 *
 * Direct scan-out (kext b162, nvmtl_scan_direct.h; /Library/GPUBundles/nvmtl/ws-direct): with CDCOPY, the two display
 * surfaces' own GPU memory is bound to VRAM slots 0 and 1, so CoreDisplay draws them in VRAM and a present is the flip
 * alone, no copy. Slot 2 only takes the bounce (the surface on screen written again with no other flip coming). Before
 * a command buffer that writes a bound surface is submitted, nvmtl_vk_scanout_write_gate waits until HUBP0 cannot be
 * fetching it (the kext's flip-complete test). Every way out (a lost plane, another surface, the switch, a failure)
 * waits for the GPU, copies both surfaces back onto their pages and releases (the kext flips to the console and checks
 * it), with the submit lock held so nothing writes them in between; the copy path then runs as before.
 *
 * The switch works live in both directions. Removed: the next present ends direct. Created while the copy path presents:
 * at the end of a present (a frame boundary, its fence waited) the copy path asks what a start would choose now, and if
 * that is direct it releases the plane and the next present starts again, binding the pair under the start's own drain
 * (nvmtl_scan_direct_live_locked). A surface written when no start has bound it yet is not lost: the bind seeds each
 * slot from the surface's pages. While bound, a surface's pages are not drawn into; once nothing is presented for 100 ms
 * (NVMTL_SD_SYNC_IDLE_NS) the keepalive copies each flipped surface's VRAM onto its pages so a screenshot reads the
 * current frame. The live switch-on and the page sync are host-tested only (unverified on hardware).
 */
#include "scan_l10r_spv.h"   /* glslangValidator -V --vn scan_l10r_spv scan_l10r.comp -o scan_l10r_spv.h */
struct nvmtl_scan_query { uint32_t h_active, v_active, h_total, v_total, pitch_px, hubp_format, sw_mode, otg, refresh_mhz, pix_clk_khz, dcc_en, flags;
                          uint64_t frame_count, console_mc, plane_mc, earliest_mc; uint32_t acquired, plane_w, plane_h, reserved; };
struct nvmtl_scan_slot { uint64_t mc, latched_frame; uint32_t used, flags, presents, latches; };
#define NVMTL_SCANST_FMT10 (1u << 1)   /* kext b149+ (PHXN_SCANST_FMT10): HUBP0 scans ARGB2101010 (10-bit HDR) */
/* An 8-bit BGRA pixel on the 10-bit scan-out: each channel's 8 bits on top of its 10, the top two repeated below, alpha 3.
   PhxAccel has the same function as phxhead::bgraTo2101010 (src/vermilion-accel/accel/phxhead.h) for its CPU copy. Two
   copies on purpose: this plugin is a C unit built without any kext header (it mirrors the kernel ABI above the same
   way), and phxhead.h is C++. Not a licence boundary (both sides are PolyForm Noncommercial). Change both together. */
static inline uint32_t nvmtl_bgra_to_2101010(uint32_t v)
{
    return 0xC0000000u | (((v >> 16) & 0xffu) << 22) | (((v >> 22) & 0x3u) << 20) | (((v >> 8) & 0xffu) << 12) |
           (((v >> 14) & 0x3u) << 10) | ((v & 0xffu) << 2) | ((v >> 6) & 0x3u);
}
struct nvmtl_scan_status { uint32_t acquired, flags, front_slot, pending_slot; uint64_t frame_count, console_mc, plane_mc, earliest_mc;
                           uint64_t presents, latched, replaced, repeats, vupdates, latch_irq, latch_poll, refused, first_latch_ns, last_latch_ns;
                           uint64_t idle_ms, watchdog_restores, storm_trips, geom_refused; struct nvmtl_scan_slot slot[3]; };
#include "nvmtl_scan_direct.h"
/* kext b162 (PhxNativeABI.h): selector 22 PHXN_SEL_SCAN_DIRECT, reached through RADV's radv_darwin_n48n_call */
#define NVMTL_SEL_SCAN_DIRECT    22u
#define NVMTL_SCANQ_DIRECT_OK    (1u << 8)   /* PHXN_SCANQ_DIRECT_OK */
#define NVMTL_SCANSLOT_WRITABLE  (1u << 4)   /* PHXN_SCANSLOT_WRITABLE: not pending, not EARLIEST_INUSE, not the latched front */
#define NVMTL_SCAN_NO_SLOT       0xFFFFFFFFu
struct nvmtl_scan_reg { uint32_t handle, reserved0; uint64_t offset; uint32_t pitch_bytes, height, width, format; };
typedef struct {   /* a display surface bound to a slot */
    void *ref, *owner, *base;        /* retained IOSurface and backing texture; the surface's pages */
    uint32_t sid, slotId; int l10r, bound;
    int dirty;                       /* flipped since its pages were last brought up to date (nvmtl_scan_direct_sync_locked) */
    VkBuffer buf; VkDeviceMemory mem; /* its texture's host import, now reaching the slot's VRAM */
    nvk_buffer pages;                 /* a second import of its pages: the seed copy in, the copy back out */
} nvmtl_scan_dsurf;
static struct {
    int state;                                   /* 0 untried (or retrying), 1 presenting, -1 off for this process */
    int restarts; uint64_t retryAt;              /* restarts after the kernel took the plane back; no try before retryAt (ns) */
    int (*query)(VkDevice, struct nvmtl_scan_query *);
    int (*acquire)(VkDevice, uint64_t *, uint64_t *);
    int (*reg)(VkDevice, VkDeviceMemory, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t *, uint64_t *);
    int (*present)(VkDevice, uint32_t, uint64_t[3]);
    int (*status)(VkDevice, struct nvmtl_scan_status *);
    int (*release)(VkDevice, uint64_t[2]);
    uint32_t w, h, pitch, next, slotId[3];
    VkBuffer slot[3]; VkDeviceMemory slotMem[3];
    VkCommandPool pool; VkCommandBuffer cb; VkFence fence;
    VkQueryPool tq;                              /* the copy's two GPU timestamps, made on the first present while passtime is armed */
    VkDescriptorSetLayout dsl; VkPipelineLayout pl; VkPipeline conv; VkDescriptorPool dp; VkDescriptorSet ds;   /* l10r -> 8-bit */
    struct { const void *ref; uint32_t sid; void *base; nvk_buffer buf; } src[8];
    unsigned srcNext;
    uint64_t presents, drops, copyUs;
    uint64_t waitUs, probeUs, flipUs, lastT, gapBin[5];   /* present split + present-to-present interval buckets (<8, <16, <33, <100, >=100 ms) */
    dispatch_source_t keepalive;
    int direct, nslots;                          /* b162: 1 = direct scan-out (slots 0/1 bound, slot[0] the bounce); slot BOs made */
    int (*n48n)(VkDevice, uint32_t, const uint64_t *, uint32_t, const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);
    int (*bohandle)(VkDevice, VkDeviceMemory, uint32_t *);
    nvmtl_scan_dsurf dsurf[2];
    uint64_t dpresents, dbounces, dgates, dgateWaits, dgateUs, dgatePend, dsyncs;
} g_scan;
static pthread_mutex_t g_scan_lock = PTHREAD_MUTEX_INITIALIZER;
/* The keepalive timer (nvmtl_scan_keepalive) ticks at 4 Hz for the page sync. Status goes out on the first tick that is
   NVMTL_SCAN_STATUS_MIN_NS or more after the last one: once a second (the fourth tick, with room for the leeway). */
#define NVMTL_SCAN_KEEPALIVE_NS        (NSEC_PER_SEC / 4)
#define NVMTL_SCAN_KEEPALIVE_LEEWAY_NS (NVMTL_SCAN_KEEPALIVE_NS / 10)
#define NVMTL_SCAN_STATUS_MIN_NS       900000000ull

/* the plane did not match the display surface (a resolution change): retrying, not counted as a loss */
static int g_scan_geom_wait;
/* The size GPU present first ran at (the boot mode). GPU present runs only at this size; every other size is drawn by the
   CPU copy. Why: the XTX machine froze ~0.5 s after a switch to 1280x1024, the one place where GPU present could restart
   at another size (Linux's pitch equals the width there) and the first use of the small slot layout on that card. The
   cause is not known (.agents/findings/2026-11-20-b138-freeze-and-squat-loop.md); lift this only with that understood. */
static uint32_t g_scan_first_w, g_scan_first_h;

/* b162 direct scan-out state outside g_scan. g_sd (the display surfaces CoreDisplay wrote, nvmtl_scan_direct.h) is fed
   from the commit path, under the class lock, so it has its own lock and never releases there: entries it drops wait in
   g_sd_dead until the next present releases them. */
static pthread_mutex_t g_sd_lock = PTHREAD_MUTEX_INITIALIZER;
static nvmtl_sd_table g_sd;
static nvmtl_sd_cand g_sd_dead[16];
static unsigned g_sd_ndead;
static _Atomic int g_sd_on;                 /* = g_scan.direct, for the write gate's lock-free first test */
static _Atomic uint32_t g_sd_out[64];       /* writes the gate let through to a bound surface (id & 63), until they finished */
static _Atomic uint32_t g_sd_ungated;       /* full-screen writes committed without the gate (direct was off) and not finished */
static unsigned g_sd_fails, g_sd_flaps; static int g_sd_off; static uint64_t g_sd_until, g_sd_wait0, g_sd_flap0;
static nvmtl_sd_live g_sd_live; static uint64_t g_sd_live_checked;   /* live switch-on (nvmtl_scan_direct_live_locked), under g_scan_lock */
/* /Library/GPUBundles/nvmtl/ws-direct (re-read every second): the switch, both ways while WindowServer runs. Absent: the
   copy path (a bound pair is copied back and released at the next present). Appearing: the copy path moves to direct at
   a frame boundary (nvmtl_scan_direct_live_locked, nvmtl_sd_live_on in nvmtl_scan_direct.h). */
static int nvmtl_sd_wanted(void)
{
    static _Atomic int on = 0; static _Atomic uint64_t checked;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - atomic_load(&checked) > 1000000000ull) {
        struct stat st; const int v = stat("/Library/GPUBundles/nvmtl/ws-direct", &st) == 0;
        if (v != atomic_exchange(&on, v)) nvlog("ws gpu present: direct scan-out %s (ws-direct)", v ? "wanted" : "off");
        atomic_store(&checked, now);
    }
    return atomic_load(&on) == 1;
}
/* ws-gpu-present-async (NVMTLWSPresent.m reads the same file): presents run on the execution worker, never on the
   committing thread the write gate may hold, so the flip that frees a surface cannot wait behind its own gate. */
static int nvmtl_sd_async_file(void)
{
    struct stat st;
    return stat("/Library/GPUBundles/nvmtl/ws-gpu-present-async", &st) == 0;
}
int nvmtl_vk_scanout_direct_wanted(void) { return nvmtl_sd_wanted() && !g_sd_off; }
int nvmtl_vk_scanout_direct_on(void) { return atomic_load(&g_sd_on); }
void nvmtl_vk_scanout_write_note(uint32_t sid, int delta)
{
    if (delta > 0) atomic_fetch_add(&g_sd_out[sid & 63], 1);
    else { uint32_t v = atomic_load(&g_sd_out[sid & 63]);
           while (v && !atomic_compare_exchange_weak(&g_sd_out[sid & 63], &v, v - 1)) {} }
}
/* A full-screen write is being committed: 1 = gated (direct is on: call nvmtl_vk_scanout_write_gate), 0 = ungated, counted
   until nvmtl_vk_scanout_write_end_ungated. The count goes up before the test, so a write that read "off" is always seen
   by a direct present that started after it (seq_cst): no flip while a write that skipped the gate can still land. */
int nvmtl_vk_scanout_write_begin(void)
{
    atomic_fetch_add(&g_sd_ungated, 1);
    if (atomic_load(&g_sd_on)) { atomic_fetch_sub(&g_sd_ungated, 1); return 1; }
    return 0;
}
void nvmtl_vk_scanout_write_end_ungated(void)
{
    uint32_t v = atomic_load(&g_sd_ungated);
    while (v && !atomic_compare_exchange_weak(&g_sd_ungated, &v, v - 1)) {}
}
/* The commit path: a display surface CoreDisplay wrote, with the host import its texture is drawn through. */
void nvmtl_vk_scanout_direct_note(const void *ref, const void *owner, uint32_t sid, void *base, uint32_t w, uint32_t h, uint32_t pitch,
                                  int l10r, void *buf, void *mem)
{
    if (!ref || !owner || !base || !buf || !mem || !sid) return;
    nvmtl_sd_cand c = { sid, w, h, pitch, l10r, 0, (void *)ref, (void *)owner, base, buf, mem }, old;
    pthread_mutex_lock(&g_sd_lock);
    for (unsigned i = 0; i < NVMTL_SD_CANDS; i++)   /* already listed as it is: nothing to retain */
        if (g_sd.c[i].sid == sid && g_sd.c[i].ref == ref && g_sd.c[i].owner == owner && g_sd.c[i].mem == mem) {
            (void)nvmtl_sd_note(&g_sd, &c, NULL); pthread_mutex_unlock(&g_sd_lock); return; }
    if (g_sd_ndead >= sizeof g_sd_dead / sizeof g_sd_dead[0]) { pthread_mutex_unlock(&g_sd_lock); return; }   /* no present for a while */
    CFRetain(ref); CFRetain(owner);
    if (nvmtl_sd_note(&g_sd, &c, &old)) g_sd_dead[g_sd_ndead++] = old;
    pthread_mutex_unlock(&g_sd_lock);
}
/* What g_sd dropped, released here (a present: never under the class lock). */
static void nvmtl_sd_reap(void)
{
    nvmtl_sd_cand d[16]; unsigned n;
    pthread_mutex_lock(&g_sd_lock);
    n = g_sd_ndead; memcpy(d, g_sd_dead, n * sizeof d[0]); g_sd_ndead = 0;
    pthread_mutex_unlock(&g_sd_lock);
    for (unsigned i = 0; i < n; i++) { CFRelease(d[i].owner); CFRelease(d[i].ref); }
}
/* One GPU buffer copy on the present command buffer, waited for (submitted under the submit lock, which is recursive). */
static int nvmtl_scan_copy_wait_locked(VkBuffer src, VkBuffer dst, VkDeviceSize bytes)
{
    if (g_scan.cb) pvkFreeCommandBuffers(g_dev, g_scan.pool, 1, &g_scan.cb);
    g_scan.cb = VK_NULL_HANDLE;
    VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, g_scan.pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
    if (!g_scan.pool || !g_scan.fence || pvkAllocateCommandBuffers(g_dev, &cbai, &g_scan.cb) != VK_SUCCESS) { g_scan.cb = VK_NULL_HANDLE; return -1; }
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL };
    pvkBeginCommandBuffer(g_scan.cb, &bi);
    VkMemoryBarrier before = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT };
    pvkCmdPipelineBarrier(g_scan.cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &before, 0, NULL, 0, NULL);
    VkBufferCopy rg = { 0, 0, bytes };
    pvkCmdCopyBuffer(g_scan.cb, src, dst, 1, &rg);
    VkMemoryBarrier after = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT };
    pvkCmdPipelineBarrier(g_scan.cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &after, 0, NULL, 0, NULL);
    pvkEndCommandBuffer(g_scan.cb);
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &g_scan.cb, 0, NULL };
    pvkResetFences(g_dev, 1, &g_scan.fence);
    pthread_mutex_lock(&nvmtl_submit_mutex);
    VkResult sr = g_state == 1 ? pvkQueueSubmit(g_queue, 1, &si, g_scan.fence) : VK_ERROR_DEVICE_LOST;
    pthread_mutex_unlock(&nvmtl_submit_mutex);
    return sr == VK_SUCCESS && pvkWaitForFences(g_dev, 1, &g_scan.fence, VK_TRUE, 1000000000ull) == VK_SUCCESS ? 0 : -1;
}
/* Every submission this process made to its queue (the plugin's only one) has finished: an empty submit's fence, which
   signals once all work submitted before it has completed. 1 s at most (not vkDeviceWaitIdle: no limit). */
static int nvmtl_scan_drain_locked(void)
{
    if (g_state != 1 || !g_scan.fence) return -1;
    pvkResetFences(g_dev, 1, &g_scan.fence);
    pthread_mutex_lock(&nvmtl_submit_mutex);
    const VkResult r = pvkQueueSubmit(g_queue, 0, NULL, g_scan.fence);
    pthread_mutex_unlock(&nvmtl_submit_mutex);
    return r == VK_SUCCESS && pvkWaitForFences(g_dev, 1, &g_scan.fence, VK_TRUE, 1000000000ull) == VK_SUCCESS ? 0 : -1;
}
/* Before the release: the GPU idle (nothing in flight writes a bound surface) and each bound surface copied from its
   slot back onto its pages, so the CPU copy, every reader of the pages and the copy path see the last frame. Called with
   the submit lock held, which the caller keeps until the release has rebound the BOs onto their pages. */
static void nvmtl_scan_direct_copyback_locked(void)
{
    const int idle = !nvmtl_scan_drain_locked();
    int copied = 0;
    for (int i = 0; i < 2; i++) {
        nvmtl_scan_dsurf *d = &g_scan.dsurf[i];
        if (!idle || !d->bound || !d->pages.buf) continue;
        if (!nvmtl_scan_copy_wait_locked(d->buf, (VkBuffer)d->pages.buf, (VkDeviceSize)g_scan.pitch * g_scan.h)) copied++;
    }
    nvlog("ws gpu present: direct scan-out ends - GPU %s, %d surface(s) copied back to their pages; %llu presents, %llu bounces, %llu of %llu writes waited (%llu us average)",
          idle ? "idle" : "NOT idle", copied, (unsigned long long)g_scan.dpresents, (unsigned long long)g_scan.dbounces,
          (unsigned long long)g_scan.dgateWaits, (unsigned long long)g_scan.dgates,
          (unsigned long long)(g_scan.dgateWaits ? g_scan.dgateUs / g_scan.dgateWaits : 0));
}
static void nvmtl_scan_off_locked(const char *why)
{
    const int direct = g_scan.direct;
    if (direct) { atomic_store(&g_sd_on, 0); pthread_mutex_lock(&nvmtl_submit_mutex); nvmtl_scan_direct_copyback_locked(); }
    if (g_scan.state == 1 && g_scan.release) { uint64_t o[2] = { 0, 0 }; g_scan.release(g_dev, o);
        nvlog("ws gpu present: OFF (%s) - plane back on the console (restore %s), %llu presents, %llu dropped", why, o[0] ? "verified" : "NOT verified",
              (unsigned long long)g_scan.presents, (unsigned long long)g_scan.drops); }
    else nvlog("ws gpu present: OFF (%s)", why);
    if (g_scan.keepalive) { dispatch_source_cancel(g_scan.keepalive); g_scan.keepalive = NULL; }
    g_scan.state = -1;
    if (direct) { g_scan.direct = 0; pthread_mutex_unlock(&nvmtl_submit_mutex); }
}

/* Everything nvmtl_scan_start_locked made, after the plane was given back: the slot BOs must be freed before the next
   acquire (freeing a slot BO while a new acquisition holds the plane would release that one). The last copy has finished
   (each present waits for its fence). */
static void nvmtl_scan_teardown_locked(void)
{
    if (g_scan.cb) pvkFreeCommandBuffers(g_dev, g_scan.pool, 1, &g_scan.cb);
    if (g_scan.pool) pvkDestroyCommandPool(g_dev, g_scan.pool, NULL);
    if (g_scan.fence) pvkDestroyFence(g_dev, g_scan.fence, NULL);
    if (g_scan.tq) pvkDestroyQueryPool(g_dev, g_scan.tq, NULL);
    if (g_scan.conv) pvkDestroyPipeline(g_dev, g_scan.conv, NULL);
    if (g_scan.pl) pvkDestroyPipelineLayout(g_dev, g_scan.pl, NULL);
    if (g_scan.dp) pvkDestroyDescriptorPool(g_dev, g_scan.dp, NULL);
    if (g_scan.dsl) pvkDestroyDescriptorSetLayout(g_dev, g_scan.dsl, NULL);
    for (int k = 0; k < 3; k++) {
        if (g_scan.slot[k]) pvkDestroyBuffer(g_dev, g_scan.slot[k], NULL);
        if (g_scan.slotMem[k]) pvkFreeMemory(g_dev, g_scan.slotMem[k], NULL);
        g_scan.slot[k] = VK_NULL_HANDLE; g_scan.slotMem[k] = VK_NULL_HANDLE; g_scan.slotId[k] = 0;
    }
    for (int i = 0; i < 2; i++) {   /* b162: released, so their BOs are on their own pages again */
        nvmtl_scan_dsurf *d = &g_scan.dsurf[i];
        if (d->pages.buf) nvmtl_vk_buffer_destroy(&d->pages);
        if (d->owner) CFRelease(d->owner);
        if (d->ref) CFRelease(d->ref);
        memset(d, 0, sizeof *d);
    }
    g_scan.direct = 0; g_scan.nslots = 0;
    for (int i = 0; i < 8; i++) {
        if (g_scan.src[i].buf.buf) nvmtl_vk_buffer_destroy(&g_scan.src[i].buf);
        if (g_scan.src[i].ref) CFRelease(g_scan.src[i].ref);
        memset(&g_scan.src[i], 0, sizeof g_scan.src[i]);
    }
    g_scan.cb = VK_NULL_HANDLE; g_scan.pool = VK_NULL_HANDLE; g_scan.fence = VK_NULL_HANDLE; g_scan.conv = VK_NULL_HANDLE; g_scan.tq = VK_NULL_HANDLE;
    g_scan.pl = VK_NULL_HANDLE; g_scan.dp = VK_NULL_HANDLE; g_scan.ds = VK_NULL_HANDLE; g_scan.dsl = VK_NULL_HANDLE;
    g_scan.next = 0; g_scan.lastT = 0;
}
/* The kernel gave the plane back to the console (its watchdog: HUBP0 pointed elsewhere, as at the login-session switch,
   or 5 s without a call). That used to end GPU present for the life of WindowServer, so after login the desktop ran on
   the CPU copy (2026-10-26). Now everything is torn down and acquired again 2 s later, up to 50 times per process. */
static void nvmtl_scan_lost_locked(const char *why, const struct nvmtl_scan_status *st)
{
    if (st) nvlog("ws gpu present: plane lost (%s) - kernel: acquired %u, watchdog restores %llu, idle %llu ms, plane 0x%llx console 0x%llx, refused %llu",
                  why, st->acquired, (unsigned long long)st->watchdog_restores, (unsigned long long)st->idle_ms,
                  (unsigned long long)st->plane_mc, (unsigned long long)st->console_mc, (unsigned long long)st->refused);
    nvmtl_scan_off_locked(why);
    nvmtl_scan_teardown_locked();
    if (g_scan.restarts < 50) { g_scan.state = 0; g_scan.retryAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 2000000000ull; }
}

/* b162: out of direct scan-out (copied back, released, torn down); GPU present starts again in 0.5 s. fail = a failure
   (cooldown, then off for the process: nvmtl_sd_fail), else an ordinary change (new surfaces, a format, the switch). */
static void nvmtl_scan_direct_out_locked(const char *why, int fail)
{
    nvmtl_scan_off_locked(why);
    nvmtl_scan_teardown_locked();
    if (fail) { nvmtl_sd_fail(&g_sd_fails, clock_gettime_nsec_np(CLOCK_UPTIME_RAW), &g_sd_until, &g_sd_off);
                nvlog("ws gpu present: direct scan-out failed (%s): copy path for %s", why, g_sd_off ? "the life of this process" : "10 s"); }
    g_scan_geom_wait = 1;   /* not a plane loss */
    g_scan.state = 0; g_scan.retryAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 500000000ull;
}

/* Stale pages: a bound surface's pages are not drawn into, so a CPU reader (screencapture) sees the frame from the bind.
   Once nothing has been presented for NVMTL_SD_SYNC_IDLE_NS, each surface flipped since its last sync has its VRAM copied
   onto its pages (the copy only reads the slot). With g_scan_lock held no write can pass the gate meanwhile, and one that
   already passed (g_sd_out) or skipped it (g_sd_ungated) postpones the copy. */
static void nvmtl_scan_direct_sync_locked(uint64_t now)
{
    if (!g_scan.direct || g_scan.state != 1 || !g_scan.lastT) return;
    for (int i = 0; i < 2; i++) {
        nvmtl_scan_dsurf *d = &g_scan.dsurf[i];
        const int writeInFlight = atomic_load(&g_sd_ungated) != 0 || atomic_load(&g_sd_out[d->sid & 63]) != 0;
        if (!d->bound || !d->pages.buf || !nvmtl_sd_sync_due(d->dirty, writeInFlight, now - g_scan.lastT)) continue;
        d->dirty = 0;   /* before the copy: one that fails is not tried again until the surface's next present */
        if (nvmtl_scan_copy_wait_locked(d->buf, (VkBuffer)d->pages.buf, (VkDeviceSize)g_scan.pitch * g_scan.h)) {
            static unsigned said; if (said++ < 4) nvlog("ws gpu present: direct: surface %u's pages could not be brought up to date", d->sid); }
        else g_scan.dsyncs++;
    }
}
/* The kernel restores the console after 5 s without a call: an idle desktop presents nothing, so Status keeps it (once a
   second, NVMTL_SCAN_STATUS_MIN_NS; the timer ticks four times a second for the page sync). lastStatus is kept across
   restarts of GPU present. */
static void nvmtl_scan_keepalive(void *ctx)
{
    (void)ctx;
    static uint64_t lastStatus;
    pthread_mutex_lock(&g_scan_lock);
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (g_scan.state == 1 && now - lastStatus >= NVMTL_SCAN_STATUS_MIN_NS) { struct nvmtl_scan_status st; memset(&st, 0, sizeof st); lastStatus = now;
        if (g_scan.status(g_dev, &st) || !st.acquired) nvmtl_scan_lost_locked("the plane was taken back", &st); }
    nvmtl_scan_direct_sync_locked(now);
    pthread_mutex_unlock(&g_scan_lock);
}

/* b162: bind the pair to slots 0 and 1 (PHXN_SEL_SCAN_DIRECT). With the submit lock held and the GPU idle, so no write
   is in flight while a BO's maps move from its pages to the slot's VRAM; then each slot gets the surface's current
   pages (one copy each, the last one this path makes). The release undoes the binding. */
static int nvmtl_scan_direct_bind_locked(const nvmtl_sd_cand *c0, const nvmtl_sd_cand *c1, uint32_t w, uint32_t h, uint32_t pitch, uint32_t fmt)
{
    const nvmtl_sd_cand *c[2] = { c0, c1 };
    const VkDeviceSize bytes = (VkDeviceSize)pitch * h;
    pthread_mutex_lock(&nvmtl_submit_mutex);
    int ok = !nvmtl_scan_drain_locked();
    for (int i = 0; i < 2 && ok; i++) {
        nvmtl_scan_dsurf *d = &g_scan.dsurf[i];
        d->ref = c[i]->ref; CFRetain(d->ref); d->owner = c[i]->owner; CFRetain(d->owner);
        d->base = c[i]->base; d->sid = c[i]->sid; d->l10r = c[i]->l10r;
        d->buf = (VkBuffer)c[i]->buf; d->mem = (VkDeviceMemory)c[i]->mem;
        const size_t span = ((size_t)bytes + g_host_align - 1) & ~(size_t)(g_host_align - 1);
        uint32_t handle = 0;
        if (nvmtl_vk_buffer_import_host(d->base, span, &d->pages)) { memset(&d->pages, 0, sizeof d->pages); nvlog("ws gpu present: direct: surface %u's pages would not import", d->sid); ok = 0; break; }
        if (g_scan.bohandle(g_dev, d->mem, &handle) || !handle) { nvlog("ws gpu present: direct: surface %u has no kext BO", d->sid); ok = 0; break; }
        const struct nvmtl_scan_reg reg = { handle, 0, 0, pitch, h, pitch / 4, fmt };
        const uint64_t sin[1] = { (uint64_t)i };
        uint64_t sout[2] = { 0, 0 }; uint32_t nout = 2;
        const int r = g_scan.n48n(g_dev, NVMTL_SEL_SCAN_DIRECT, sin, 1, &reg, sizeof reg, sout, &nout, NULL, NULL);
        if (r || nout != 2 || sout[0] != (uint64_t)i) { nvlog("ws gpu present: direct: binding surface %u (BO %u) to slot %d -> %d (sysctl debug.phxscan_layout says why)", d->sid, handle, i, r); ok = 0; break; }
        d->slotId = (uint32_t)sout[0]; d->bound = 1;
        if (nvmtl_scan_copy_wait_locked((VkBuffer)d->pages.buf, d->buf, bytes)) { nvlog("ws gpu present: direct: surface %u's seed copy failed", d->sid); ok = 0; break; }
        nvlog("ws gpu present: direct: surface %u %ux%u %s drawn in VRAM slot %u (MC 0x%llx), scanned out with no copy", d->sid, w, h,
              d->l10r ? "l10r" : "BGRA", d->slotId, (unsigned long long)sout[1]);
    }
    if (ok) { g_scan.direct = 1; atomic_store(&g_sd_on, 1); }
    pthread_mutex_unlock(&nvmtl_submit_mutex);
    return ok ? 0 : -1;
}

/* The inputs of nvmtl_sd_start for the shown surface (all but waitedNs, left 0 for the caller), and the pair it would
   bind: *c0 / *c1 are set only when in->pairs is 2. Used by the start (nvmtl_scan_direct_choose_locked) and by the live
   switch-on, so both decide on the same inputs. Looks up RADV's two N48N exports on first use. */
static void nvmtl_scan_direct_input_locked(uint32_t sid, uint32_t w, uint32_t h, uint32_t pitch, const struct nvmtl_scan_query *q,
                                           nvmtl_sd_start_in *in, nvmtl_sd_cand *c0, nvmtl_sd_cand *c1, uint64_t now)
{
    if (!g_scan.n48n) g_scan.n48n = dlsym(g_lib, "radv_darwin_n48n_call");
    if (!g_scan.bohandle) g_scan.bohandle = dlsym(g_lib, "radv_darwin_n48n_bo_handle");
    memset(in, 0, sizeof *in);
    in->wanted = nvmtl_sd_wanted() && !g_sd_off && now >= g_sd_until;
    in->kextOk = (q->flags & NVMTL_SCANQ_DIRECT_OK) && g_scan.n48n && g_scan.bohandle;
    in->async = nvmtl_sd_async_file();
    in->hubpFormat = q->hubp_format; in->pitchPx = q->pitch_px; in->pitch = pitch;
    unsigned a = 0, b = 0;
    pthread_mutex_lock(&g_sd_lock);
    in->pairs = nvmtl_sd_pair(&g_sd, w, h, pitch, &a, &b);
    if (in->pairs >= 2) { *c0 = g_sd.c[a]; *c1 = g_sd.c[b]; in->shownInPair = c0->sid == sid || c1->sid == sid;
                          in->pairL10r[0] = c0->l10r; in->pairL10r[1] = c1->l10r; }
    pthread_mutex_unlock(&g_sd_lock);
}
/* b162: whether this start binds the display surfaces (nvmtl_sd_start). 1 direct (*c0 / *c1 the pair), 0 copy, -1 wait
   for the second display surface (the CPU copy keeps the panel meanwhile). */
static int nvmtl_scan_direct_choose_locked(uint32_t sid, uint32_t w, uint32_t h, uint32_t pitch, const struct nvmtl_scan_query *q,
                                           nvmtl_sd_cand *c0, nvmtl_sd_cand *c1)
{
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    nvmtl_sd_start_in in;
    nvmtl_scan_direct_input_locked(sid, w, h, pitch, q, &in, c0, c1, now);
    if (!g_sd_wait0) g_sd_wait0 = now;
    in.waitedNs = now - g_sd_wait0;
    const int d = nvmtl_sd_start(&in);
    if (d != NVMTL_SD_START_WAIT) g_sd_wait0 = 0;
    if (in.wanted) { static unsigned said; if (said++ < 8 || d == NVMTL_SD_START_DIRECT)
        nvlog("ws gpu present: direct scan-out %s (kext %s, async %d, HUBP0 format %u pitch %u px, %d display surface(s) of %ux%u%s)",
              d == NVMTL_SD_START_DIRECT ? "starts" : d == NVMTL_SD_START_WAIT ? "waits for the second display surface" : "not possible: copy path",
              in.kextOk ? "allows it" : "refuses it (old kext, BAR0 under 352 MiB, debug.phxscan_direct=0, or no radv_darwin_n48n_call)",
              in.async, q->hubp_format, q->pitch_px, in.pairs, w, h, in.pairs >= 2 && !in.shownInPair ? ", the shown one not among them" : ""); }
    return d == NVMTL_SD_START_DIRECT ? 1 : d == NVMTL_SD_START_WAIT ? -1 : 0;
}
/* Live switch-on: called at the end of a copy-path present (the frame boundary: this present's copy has finished and its
   flip is made). If ws-direct is there and a start now would choose direct, the plane is released and torn down, and the
   next present starts again (the start binds under its own drain). Returns 1 if it moved. Quiet when nothing to do:
   checked at most every NVMTL_SD_LIVE_CHECK_NS, and only while the switch is on. */
static int nvmtl_scan_direct_live_locked(uint32_t sid, uint32_t w, uint32_t h, uint32_t pitch)
{
    const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (g_scan.direct || g_scan.state != 1 || now - g_sd_live_checked < NVMTL_SD_LIVE_CHECK_NS) return 0;
    g_sd_live_checked = now;
    if (!nvmtl_sd_wanted() || g_sd_off || now < g_sd_until || !g_scan.query) { g_sd_live.eligibleNs = 0; return 0; }
    struct nvmtl_scan_query q;
    memset(&q, 0, sizeof q);
    if (g_scan.query(g_dev, &q) || q.plane_w != w || q.plane_h != h || q.pitch_px * 4 != pitch) { g_sd_live.eligibleNs = 0; return 0; }
    nvmtl_sd_start_in in; nvmtl_sd_cand c0, c1;
    nvmtl_scan_direct_input_locked(sid, w, h, pitch, &q, &in, &c0, &c1, now);
    uint32_t writesInFlight = atomic_load(&g_sd_ungated);   /* full-screen writes committed and not finished */
    for (unsigned i = 0; i < 64; i++) writesInFlight += atomic_load(&g_sd_out[i]);
    if (!nvmtl_sd_live_on(&in, writesInFlight != 0, &g_sd_live, now)) return 0;
    g_sd_live.tries++; g_sd_live.lastTryNs = now;
    nvlog("ws gpu present: ws-direct appeared: direct scan-out engages at this frame boundary (try %u, %d display surfaces of %ux%u)", g_sd_live.tries, in.pairs, w, h);
    nvmtl_scan_off_locked("ws-direct appeared");
    nvmtl_scan_teardown_locked();
    g_scan_geom_wait = 1;   /* not a plane loss */
    g_scan.state = 0; g_scan.retryAt = 0;   /* the next present starts (the other ways out wait 0.5 s) */
    return 1;
}

static int nvmtl_scan_start_locked(uint32_t sid, uint32_t w, uint32_t h, uint32_t pitch)
{
    g_scan.query = dlsym(g_lib, "radv_darwin_scanout_query"); g_scan.acquire = dlsym(g_lib, "radv_darwin_scanout_acquire");
    g_scan.reg = dlsym(g_lib, "radv_darwin_scanout_register"); g_scan.present = dlsym(g_lib, "radv_darwin_scanout_present");
    g_scan.status = dlsym(g_lib, "radv_darwin_scanout_status"); g_scan.release = dlsym(g_lib, "radv_darwin_scanout_release");
    if (!g_scan.query || !g_scan.acquire || !g_scan.reg || !g_scan.present || !g_scan.status || !g_scan.release) { nvmtl_scan_off_locked("no scanout exports in the ICD"); return -1; }
    struct nvmtl_scan_query q;
    int r = g_scan.query(g_dev, &q);
    if (r || q.plane_w != w || q.plane_h != h || q.pitch_px * 4 != pitch) {
        /* The plane may follow later (a resolution change: the kext's pitch is Linux's, wider than WindowServer's rows
           below 1440p, so those modes run on the CPU copy). Not off for the session: query again in 2 s (cheap). */
        static unsigned said; if (said++ < 8) nvlog("ws gpu present: plane %ux%u pitch %u vs surface %ux%u pitch %u (query %d) - CPU copy, trying again in 2 s",
                                                    q.plane_w, q.plane_h, q.pitch_px * 4, w, h, pitch, r);
        g_scan_geom_wait = 1;   /* these retries are not plane losses: they do not count toward the 50 restarts */
        g_scan.state = 0; g_scan.retryAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 2000000000ull; return -1; }
    if (g_scan_first_w && (w != g_scan_first_w || h != g_scan_first_h)) {
        static unsigned saidSize; if (saidSize++ < 8) nvlog("ws gpu present: surface %ux%u is not the first size %ux%u - CPU copy (b139: GPU present only at the first size)",
                                                            w, h, g_scan_first_w, g_scan_first_h);
        g_scan_geom_wait = 1;
        g_scan.state = 0; g_scan.retryAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 2000000000ull; return -1; }
    nvmtl_sd_cand dc0, dc1;
    const int direct = nvmtl_scan_direct_choose_locked(sid, w, h, pitch, &q, &dc0, &dc1);
    if (direct < 0) { g_scan_geom_wait = 1; g_scan.state = 0; g_scan.retryAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 50000000ull; return -1; }
    g_scan_geom_wait = 0;
    uint64_t console = 0, frame = 0;
    if ((r = g_scan.acquire(g_dev, &console, &frame))) { nvlog("ws gpu present: acquire -> %d (debug.phxscan=1 and debug.phxfb_flip=0 needed)", r);
        /* a restart may find the console still busy (a flip pending): try again later */
        if (g_scan.restarts && g_scan.restarts < 50) { g_scan.restarts++; g_scan.retryAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 2000000000ull; return -1; }
        g_scan.state = -1; return -1; }
    g_scan.state = 1;
    if (!g_scan_first_w) { g_scan_first_w = w; g_scan_first_h = h; }
    VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, g_qfam };
    VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, VK_NULL_HANDLE, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
    VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, 0 };
    if (pvkCreateCommandPool(g_dev, &cpci, NULL, &g_scan.pool) != VK_SUCCESS) { nvmtl_scan_off_locked("command pool failed"); return -1; }
    cbai.commandPool = g_scan.pool;
    if (pvkAllocateCommandBuffers(g_dev, &cbai, &g_scan.cb) != VK_SUCCESS || pvkCreateFence(g_dev, &fci, NULL, &g_scan.fence) != VK_SUCCESS) {
        nvmtl_scan_off_locked("command buffer failed"); return -1; }
    {   /* the l10r conversion pipeline: two storage buffers (surface, slot) and the pixel count / format as push constants */
        VkShaderModuleCreateInfo smci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0, sizeof scan_l10r_spv, scan_l10r_spv };
        VkShaderModule sm = VK_NULL_HANDLE;
        VkDescriptorSetLayoutBinding b[2] = { { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL },
                                              { 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL } };
        VkDescriptorSetLayoutCreateInfo dslci = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0, 2, b };
        VkPushConstantRange pcr = { VK_SHADER_STAGE_COMPUTE_BIT, 0, 8 };
        VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2 };
        VkDescriptorPoolCreateInfo dpci = { VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 1, &ps };
        int ok = pvkCreateShaderModule(g_dev, &smci, NULL, &sm) == VK_SUCCESS && pvkCreateDescriptorSetLayout(g_dev, &dslci, NULL, &g_scan.dsl) == VK_SUCCESS;
        if (ok) { VkPipelineLayoutCreateInfo plci = { VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0, 1, &g_scan.dsl, 1, &pcr };
                  ok = pvkCreatePipelineLayout(g_dev, &plci, NULL, &g_scan.pl) == VK_SUCCESS; }
        if (ok) { VkComputePipelineCreateInfo cpci = { VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, NULL, 0,
                      { VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_COMPUTE_BIT, sm, "main", NULL }, g_scan.pl, VK_NULL_HANDLE, 0 };
                  ok = pvkCreateComputePipelines(g_dev, VK_NULL_HANDLE, 1, &cpci, NULL, &g_scan.conv) == VK_SUCCESS; }
        if (ok) ok = pvkCreateDescriptorPool(g_dev, &dpci, NULL, &g_scan.dp) == VK_SUCCESS;
        if (ok) { VkDescriptorSetAllocateInfo dsai = { VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, g_scan.dp, 1, &g_scan.dsl };
                  ok = pvkAllocateDescriptorSets(g_dev, &dsai, &g_scan.ds) == VK_SUCCESS; }
        if (sm) pvkDestroyShaderModule(g_dev, sm, NULL);
        if (!ok) { nvmtl_scan_off_locked("the l10r conversion pipeline would not build"); return -1; }
    }
    g_scan.w = w; g_scan.h = h; g_scan.pitch = pitch;
    /* b162: direct binds slots 0 and 1 first, so the one slot BO made below (the bounce) is registered into slot 2 */
    g_scan.nslots = 3;
    if (direct == 1) {
        if (nvmtl_scan_direct_bind_locked(&dc0, &dc1, w, h, pitch, q.hubp_format)) { nvmtl_scan_direct_out_locked("the binding failed", 1); return -1; }
        g_scan.nslots = 1;
    }
    const VkDeviceSize size = (VkDeviceSize)pitch * h;
    for (int k = 0; k < g_scan.nslots; k++) {
        VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0, size, VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                                   VK_SHARING_MODE_EXCLUSIVE, 0, NULL };
        if (pvkCreateBuffer(g_dev, &bci, NULL, &g_scan.slot[k]) != VK_SUCCESS) { if (g_scan.direct) nvmtl_scan_direct_out_locked("the bounce slot: slot vkCreateBuffer failed", 1); else nvmtl_scan_off_locked("slot vkCreateBuffer failed"); return -1; }
        VkMemoryRequirements mr; pvkGetBufferMemoryRequirements(g_dev, g_scan.slot[k], &mr);
        const int mt = memtype(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT | VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
        VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, mr.size, (uint32_t)(mt < 0 ? 0 : mt) };
        if (mt < 0 || pvkAllocateMemory(g_dev, &mai, NULL, &g_scan.slotMem[k]) != VK_SUCCESS || pvkBindBufferMemory(g_dev, g_scan.slot[k], g_scan.slotMem[k], 0) != VK_SUCCESS) {
            if (g_scan.direct) nvmtl_scan_direct_out_locked("the bounce slot: slot memory failed", 1); else nvmtl_scan_off_locked("slot memory failed"); return -1; }
        uint64_t mc = 0;
        if ((r = g_scan.reg(g_dev, g_scan.slotMem[k], 0, pitch, w, h, &g_scan.slotId[k], &mc))) { nvlog("ws gpu present: register %d -> %d", k, r);
            if (g_scan.direct) nvmtl_scan_direct_out_locked("the bounce slot: slot register failed", 1); else nvmtl_scan_off_locked("slot register failed"); return -1; }
    }
    g_scan.keepalive = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (g_scan.keepalive) { dispatch_source_set_timer(g_scan.keepalive, dispatch_time(DISPATCH_TIME_NOW, NVMTL_SCAN_KEEPALIVE_NS), NVMTL_SCAN_KEEPALIVE_NS, NVMTL_SCAN_KEEPALIVE_LEEWAY_NS);
        dispatch_set_context(g_scan.keepalive, NULL); dispatch_source_set_event_handler_f(g_scan.keepalive, nvmtl_scan_keepalive); dispatch_resume(g_scan.keepalive); }
    nvlog("ws gpu present: ON - %ux%u, console MC 0x%llx, %s", w, h, (unsigned long long)console,
          g_scan.direct ? "direct scan-out (display surfaces in slots 0 and 1, the bounce in slot 2)" : "three VRAM slots registered");
    return 0;
}

/* b162: the bounce. The surface on screen is to be written again and no other flip is coming: its VRAM is copied into the
   third slot (VRAM to VRAM) and HUBP0 flips there; the write then waits for that flip as for any other. */
static int nvmtl_scan_direct_bounce_locked(const nvmtl_scan_dsurf *d)
{
    if (g_scan.nslots < 1 || !g_scan.slot[0]) return -1;
    if (nvmtl_scan_copy_wait_locked(d->buf, g_scan.slot[0], (VkDeviceSize)g_scan.pitch * g_scan.h)) return -1;
    uint64_t o[3];
    if (g_scan.present(g_dev, g_scan.slotId[0], o)) return -1;
    g_scan.dbounces++;
    nvmtl_e0("B sid %u bounced to slot %u", d->sid, g_scan.slotId[0]);
    return 0;
}
/* b162: a present in direct scan-out: the flip to the surface's own slot. 0 presented, 1 held (a write to the surface
   is still in flight: counted as a drop), -1 out of direct (the next present starts again: the copy path or a new pair). */
static int nvmtl_scan_direct_present_locked(const void *ref, uint32_t sid, int l10r)
{
    nvmtl_scan_dsurf *d = NULL;
    for (int i = 0; i < 2; i++) if (g_scan.dsurf[i].bound && g_scan.dsurf[i].sid == sid && g_scan.dsurf[i].ref == ref) d = &g_scan.dsurf[i];
    if (!nvmtl_sd_wanted()) { nvmtl_scan_direct_out_locked("ws-direct removed", 0); return -1; }
    if (!d) {
        /* new display surfaces (HDR on / off, a format or size change) or a third one in the rotation: a flap guard turns
           three of these within 5 s into a failure */
        const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (!g_sd_flap0 || now - g_sd_flap0 > 5000000000ull) { g_sd_flap0 = now; g_sd_flaps = 0; }
        nvmtl_scan_direct_out_locked("a display surface outside the bound pair", ++g_sd_flaps >= 3);
        return -1;
    }
    if (d->l10r != l10r) { nvmtl_scan_direct_out_locked("the surface changed format", 0); return -1; }
    struct nvmtl_scan_status st;
    memset(&st, 0, sizeof st);
    if (g_scan.status(g_dev, &st) || !st.acquired) { nvmtl_scan_lost_locked("the plane was taken back", &st); return -1; }
    if (((st.flags & NVMTL_SCANST_FMT10) != 0) != (d->l10r != 0)) { nvmtl_scan_direct_out_locked("the scan-out format changed", 0); return -1; }
    /* No flip while a write may still draw into this surface: one committed before the binding (it skipped the gate:
       only the first frames after a start), or a newer one the gate let through (its own present shows the frame;
       hw-safety review of b162, item 4). HUBP0 stays where it is meanwhile. A hold that lasts (a count that never comes
       down) must not freeze the panel: the copy path after NVMTL_SD_GATE_MAX_US. */
    { static uint64_t heldSince;
      const int ungated = atomic_load(&g_sd_ungated) != 0, newer = atomic_load(&g_sd_out[sid & 63]) != 0;
      if (ungated || newer) {
          const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
          if (!heldSince) heldSince = now;
          if (now - heldSince > NVMTL_SD_GATE_MAX_US * 1000ull) { heldSince = 0;
              nvmtl_scan_direct_out_locked(ungated ? "a write that skipped the gate never finished" : "a surface's writes never settled", 1); return -1; }
          g_scan.drops++; nvmtl_e0("D sid %u held: %s", sid, ungated ? "an ungated write in flight" : "a newer write in flight"); return 1; }
      heldSince = 0; }
    const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t o[3];
    if (g_scan.present(g_dev, d->slotId, o)) { struct nvmtl_scan_status ls; memset(&ls, 0, sizeof ls); g_scan.status(g_dev, &ls);
        nvmtl_scan_lost_locked("present refused", &ls); return -1; }
    const uint64_t t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (g_scan.lastT) { const uint64_t gap = (t1 - g_scan.lastT) / 1000000;
        g_scan.gapBin[gap < 8 ? 0 : gap < 16 ? 1 : gap < 33 ? 2 : gap < 100 ? 3 : 4]++; }
    g_scan.lastT = t1; g_scan.flipUs += (t1 - t0) / 1000;
    d->dirty = 1;   /* its pages are now older than its VRAM */
    nvmtl_e0("Q sid %u flipped its own slot %u (direct)", sid, d->slotId);
    if (++g_scan.dpresents % 3000 == 0)
        nvlog("ws gpu present: direct: %llu presents (flip %llu us average, no copy), %llu bounces, %llu of %llu display writes waited for a flip (%llu us average, %llu of them behind a flip still to latch); %llu idle syncs of the pages; present gaps <8ms %llu, <16 %llu, <33 %llu, <100 %llu, longer %llu",
              (unsigned long long)g_scan.dpresents, (unsigned long long)(g_scan.flipUs / g_scan.dpresents), (unsigned long long)g_scan.dbounces,
              (unsigned long long)g_scan.dgateWaits, (unsigned long long)g_scan.dgates,
              (unsigned long long)(g_scan.dgateWaits ? g_scan.dgateUs / g_scan.dgateWaits : 0), (unsigned long long)g_scan.dgatePend,
              (unsigned long long)g_scan.dsyncs, (unsigned long long)g_scan.gapBin[0],
              (unsigned long long)g_scan.gapBin[1], (unsigned long long)g_scan.gapBin[2], (unsigned long long)g_scan.gapBin[3],
              (unsigned long long)g_scan.gapBin[4]);
    return 0;
}
/* b162, the write gate: called by the commit path (outside the class lock) before a command buffer that writes the
   full-screen surfaces sid[0..n) through memories mem[0..n) can be submitted. Returns once HUBP0 cannot be fetching any
   bound one of them (the kext's PHXN_SCANSLOT_WRITABLE: Linux's flip-complete test), so CoreDisplay never draws into the
   frame being scanned out. The bound ones are counted as in flight (g_sd_out) in the same g_scan_lock section that saw
   them writable, all at once: a flip of one of them after that sees the count and waits, and the command buffer's own
   writes never hold the flip it waits for. *let: a bit per bound surface let through (nvmtl_vk_scanout_write_note(sid, -1)
   each once the command buffer has finished, before its present). 0 go (direct), 1 none bound here, -1 direct ended here
   (copied back and released: go, the writes land on the pages). Polls every 200 us without g_scan_lock held between. */
int nvmtl_vk_scanout_write_gate(uint32_t n, const uint32_t *sid, const void *const *mem, uint32_t *let)
{
    *let = 0;
    if (!atomic_load(&g_sd_on) || !n) return 1;
    if (n > 8) n = 8;
    const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    int bounced = 0, waited = 0, behindFlip = 0, ret = 1;
    for (;;) {
        pthread_mutex_lock(&g_scan_lock);
        const nvmtl_scan_dsurf *d[8] = { NULL };
        int nb = 0, mine[2] = { 0, 0 };   /* bound surfaces this command buffer writes; which of the two */
        if (g_scan.direct && g_scan.state == 1)
            for (uint32_t j = 0; j < n; j++)
                for (int i = 0; i < 2; i++) if (g_scan.dsurf[i].bound && g_scan.dsurf[i].sid == sid[j]) { d[j] = &g_scan.dsurf[i]; mine[i] = 1; nb++; }
        if (!nb) { pthread_mutex_unlock(&g_scan_lock); ret = 1; break; }
        int foreign = 0;
        for (uint32_t j = 0; j < n; j++) if (d[j] && mem[j] != (const void *)d[j]->mem) foreign = 1;
        if (foreign) {   /* written through another texture: that write would miss the slot */
            nvmtl_scan_direct_out_locked("a display surface written through another backing", 1);
            pthread_mutex_unlock(&g_scan_lock); ret = -1; break; }
        struct nvmtl_scan_status st;
        memset(&st, 0, sizeof st);
        if (g_scan.status(g_dev, &st) || !st.acquired) { nvmtl_scan_lost_locked("the plane was taken back", &st); pthread_mutex_unlock(&g_scan_lock); ret = -1; break; }
        const uint64_t us = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000;
        const nvmtl_scan_dsurf *blocked = NULL;
        for (uint32_t j = 0; j < n && !blocked; j++)
            if (d[j] && !(st.slot[d[j]->slotId].flags & NVMTL_SCANSLOT_WRITABLE)) blocked = d[j];
        if (!blocked) {
            for (uint32_t j = 0; j < n; j++) if (d[j]) { atomic_fetch_add(&g_sd_out[sid[j] & 63], 1); *let |= 1u << j; }
            g_scan.dgates++;
            if (waited) { g_scan.dgateWaits++; g_scan.dgateUs += us; if (behindFlip) g_scan.dgatePend++; }
            pthread_mutex_unlock(&g_scan_lock); ret = 0; break; }
        /* the partner's flip frees the front only if this command buffer does not write the partner itself */
        const int bi = blocked == &g_scan.dsurf[0] ? 0 : 1;
        const int partnerOut = !mine[1 - bi] && atomic_load(&g_sd_out[g_scan.dsurf[1 - bi].sid & 63]) != 0;
        const int bounceFree = g_scan.nslots >= 1 && (st.slot[g_scan.slotId[0]].flags & NVMTL_SCANSLOT_WRITABLE) != 0;
        const int act = nvmtl_sd_gate(0, st.pending_slot != NVMTL_SCAN_NO_SLOT, partnerOut, bounceFree, bounced, us);
        if (act == NVMTL_SD_FAIL) {
            nvlog("ws gpu present: direct: surface %u (slot %u) still not writable after %llu us (flags 0x%x, front %u, pending %u)", blocked->sid,
                  blocked->slotId, (unsigned long long)us, st.slot[blocked->slotId].flags, st.front_slot, st.pending_slot);
            nvmtl_scan_direct_out_locked("the flip-complete wait timed out", 1);
            pthread_mutex_unlock(&g_scan_lock); ret = -1; break; }
        if (act == NVMTL_SD_BOUNCE) {
            bounced = 1;
            if (nvmtl_scan_direct_bounce_locked(blocked)) { nvmtl_scan_direct_out_locked("the bounce failed", 1); pthread_mutex_unlock(&g_scan_lock); ret = -1; break; }
        }
        if (!waited) behindFlip = st.pending_slot != NVMTL_SCAN_NO_SLOT;   /* the first blocked poll found a flip still to latch (the other surface's); st is from before a bounce made just above */
        waited = 1;
        pthread_mutex_unlock(&g_scan_lock);
        usleep(200);
    }
    return ret;
}

#include "nvmtl_scan_diag.c"
/* `base` is the display surface's own pages (WindowServer's process), `sid` its IOSurface id, `ref` the IOSurfaceRef (the
   cache retains it); call once the GPU work that
   drew the frame has finished. 0 presented, 1 dropped (no free slot), -1 off (the caller keeps the CPU copy's safeguards). */
int nvmtl_vk_scanout_present(const void *ref, uint32_t sid, void *base, uint32_t w, uint32_t h, uint32_t pitch, int l10r)
{
    if (nvmtl_vk_init() || !g_lib) return -1;
    nvmtl_sd_reap();   /* b162: display surfaces the commit path dropped, released outside the class lock */
    pthread_mutex_lock(&g_scan_lock);
    int ret = -1;
    /* M7 S4b head gate (nvmtl_headmap_gate.c), before the start and geometry checks: another head's surface must never
       start the plane or trip "the display surface changed size" */
    { const int g = nvmtl_hm_gate_present(sid);
      if (g < 0) { nvmtl_scan_off_locked("head map stall"); goto out; }
      if (g == 0) { ret = 1; goto out; } }
    if (g_scan.state == 0 && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= g_scan.retryAt) {
        if (g_scan.retryAt && !g_scan_geom_wait) { g_scan.restarts++; nvlog("ws gpu present: restart %d after the plane was lost", g_scan.restarts); }
        nvmtl_scan_start_locked(sid, w, h, pitch);
    }
    if (g_scan.state != 1) goto out;
    if (w != g_scan.w || h != g_scan.h || pitch != g_scan.pitch) {
        /* A resolution change (PhxAccel resizes head 0): give the plane back, free the slots and start again in 0.5 s, so
           GPU present comes back when the desktop returns to its first size */
        nvmtl_scan_off_locked("the display surface changed size");
        nvmtl_scan_teardown_locked();
        g_scan_geom_wait = 1;
        g_scan.state = 0; g_scan.retryAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 500000000ull;
        goto out; }
    if (g_scan.direct) { ret = nvmtl_scan_direct_present_locked(ref, sid, l10r); goto out; }
    nvk_buffer *src = NULL;
    /* WindowServer frees its BGRA display surfaces and makes l10r ones that can get the same id at the same address.
       An entry matched by id and address alone then kept the old import: the freed surface's pages, still wired, so
       the slot showed its last BGRA frame read as l10r (red bands, 2026-10-25 14:05). The cache holds a reference to
       each surface, so none of them is freed (and its id or address reused) while its import is cached. */
    for (unsigned i = 0; i < 8; i++) {
        if (!g_scan.src[i].buf.buf || g_scan.src[i].sid != sid || g_scan.src[i].base != base) continue;
        if (g_scan.src[i].ref == ref) { src = &g_scan.src[i].buf; break; }
        static unsigned said; if (said++ < 8) nvlog("ws gpu present: surface %u at %p is a NEW surface with a cached id and address - old import dropped", sid, base);
        nvmtl_vk_buffer_destroy(&g_scan.src[i].buf);
        if (g_scan.src[i].ref) CFRelease(g_scan.src[i].ref);
        memset(&g_scan.src[i], 0, sizeof g_scan.src[i]);
    }
    if (!src) {
        const unsigned i = g_scan.srcNext++ % 8;
        if (g_scan.src[i].buf.buf) nvmtl_vk_buffer_destroy(&g_scan.src[i].buf);
        if (g_scan.src[i].ref) CFRelease(g_scan.src[i].ref);
        memset(&g_scan.src[i], 0, sizeof g_scan.src[i]);
        const size_t bytes = ((size_t)pitch * h + g_host_align - 1) & ~(size_t)(g_host_align - 1);
        if (nvmtl_vk_buffer_import_host(base, bytes, &g_scan.src[i].buf)) { nvmtl_scan_off_locked("the display surface would not import"); goto out; }
        g_scan.src[i].sid = sid; g_scan.src[i].base = base; g_scan.src[i].ref = ref ? CFRetain(ref) : NULL;
        src = &g_scan.src[i].buf;
    }
    struct nvmtl_scan_status st;
    memset(&st, 0, sizeof st);
    if (g_scan.status(g_dev, &st) || !st.acquired) { nvmtl_scan_lost_locked("the plane was taken back", &st); goto out; }
    /* 10-bit HDR: with HUBP0 on ARGB2101010 an l10r surface goes to the slot as it is (MPCC0 blends with global alpha:
       l10r's top two bits are not used) and a BGRA one is widened; the 8-bit scan-out narrows l10r (scan_l10r.comp) */
    const int fmt10 = (st.flags & NVMTL_SCANST_FMT10) != 0;
    { static int lastFmt10 = -1;
      if (fmt10 != lastFmt10) { nvlog("ws gpu present: scan-out %s, surface %s", fmt10 ? "ARGB2101010 (10-bit HDR)" : "ARGB8888",
                                      l10r ? "l10r" : "BGRA"); lastFmt10 = fmt10; } }
    uint32_t k = UINT32_MAX;
    for (uint32_t n = 0; n < 3 && k == UINT32_MAX; n++) { const uint32_t c = (g_scan.next + n) % 3; if (st.slot[g_scan.slotId[c]].flags & 4u) k = c; }
    if (k == UINT32_MAX) { g_scan.drops++; nvmtl_e0("D sid %u dropped", sid); ret = 1; goto out; }
    const uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    nvmtl_e0("P sid %u present %llu slot %u", sid, (unsigned long long)g_scan.presents, k);
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL };
    /* a fresh command buffer per frame (the loader table has no vkResetCommandBuffer); the last one is done by now */
    if (g_scan.cb) pvkFreeCommandBuffers(g_dev, g_scan.pool, 1, &g_scan.cb);
    g_scan.cb = VK_NULL_HANDLE;
    { VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, g_scan.pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
      if (pvkAllocateCommandBuffers(g_dev, &cbai, &g_scan.cb) != VK_SUCCESS) { g_scan.cb = VK_NULL_HANDLE; nvmtl_scan_off_locked("command buffer failed"); goto out; } }
    pvkBeginCommandBuffer(g_scan.cb, &bi);
    /* While passtime is armed in this process, the copy (with its barriers) is timed on the GPU and logged next to the
       passes. copy_wait (the CPU's view, t0 to t1) minus this is the recording, the submit, the time the copy queued
       behind other work and the fence wake-up; for widen-cpu also the CPU widening. A present doesn't count against
       the armed passes: every present is logged until this process has drawn its NVMTL_PT_PASSES render passes. */
    int timed = 0;
    if (g_pt_left > 0 && g_timestamp_bits) {
        if (!g_scan.tq) { VkQueryPoolCreateInfo qi = { VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, NULL, 0, VK_QUERY_TYPE_TIMESTAMP, 2, 0 };
            if (pvkCreateQueryPool(g_dev, &qi, NULL, &g_scan.tq) != VK_SUCCESS) g_scan.tq = VK_NULL_HANDLE; }
        if (g_scan.tq) { pvkCmdResetQueryPool(g_scan.cb, g_scan.tq, 0, 2); pvkCmdWriteTimestamp(g_scan.cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, g_scan.tq, 0); timed = 1; }
    }
    VkMemoryBarrier before = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_MEMORY_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT };
    pvkCmdPipelineBarrier(g_scan.cb, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &before, 0, NULL, 0, NULL);
    if (fmt10 && !l10r) {
        /* BGRA on the 10-bit scan-out: widened on the CPU into the slot (host-visible VRAM). Rare: WindowServer draws l10r
           once colour management is up; no 10-bit variant of scan_l10r.comp is built for it */
        void *dp = NULL;
        if (pvkMapMemory(g_dev, g_scan.slotMem[k], 0, VK_WHOLE_SIZE, 0, &dp) != VK_SUCCESS || !dp) {
            pvkEndCommandBuffer(g_scan.cb); nvmtl_scan_off_locked("slot map failed (10-bit widen)"); goto out; }
        const uint32_t *sp = (const uint32_t *)base; uint32_t *wp = (uint32_t *)dp;
        for (size_t i = 0, n = (size_t)pitch / 4 * h; i < n; i++) wp[i] = nvmtl_bgra_to_2101010(sp[i]);
        pvkUnmapMemory(g_dev, g_scan.slotMem[k]);
        { static unsigned saidWiden; if (saidWiden++ < 4) nvlog("ws gpu present: BGRA surface %u widened to 10 bits on the CPU", sid); }
    } else if (l10r && !fmt10) {
        VkDescriptorBufferInfo dbi[2] = { { (VkBuffer)src->buf, 0, (VkDeviceSize)pitch * h }, { g_scan.slot[k], 0, (VkDeviceSize)pitch * h } };
        VkWriteDescriptorSet wds[2] = { { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, g_scan.ds, 0, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &dbi[0], NULL },
                                        { VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, g_scan.ds, 1, 0, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &dbi[1], NULL } };
        pvkUpdateDescriptorSets(g_dev, 2, wds, 0, NULL);   /* the last frame's command buffer has finished: the set is free */
        const uint32_t pc[2] = { pitch / 4 * h, 1 };
        pvkCmdBindPipeline(g_scan.cb, VK_PIPELINE_BIND_POINT_COMPUTE, g_scan.conv);
        pvkCmdBindDescriptorSets(g_scan.cb, VK_PIPELINE_BIND_POINT_COMPUTE, g_scan.pl, 0, 1, &g_scan.ds, 0, NULL);
        pvkCmdPushConstants(g_scan.cb, g_scan.pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof pc, pc);
        pvkCmdDispatch(g_scan.cb, (pc[0] + 255) / 256, 1, 1);
        VkMemoryBarrier after = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_MEMORY_READ_BIT };
        pvkCmdPipelineBarrier(g_scan.cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 1, &after, 0, NULL, 0, NULL);
    } else {
        VkBufferCopy rg = { 0, 0, (VkDeviceSize)pitch * h };
        pvkCmdCopyBuffer(g_scan.cb, (VkBuffer)src->buf, g_scan.slot[k], 1, &rg);
        VkMemoryBarrier after = { VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_MEMORY_READ_BIT };
        pvkCmdPipelineBarrier(g_scan.cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 1, &after, 0, NULL, 0, NULL);
    }
    if (timed) pvkCmdWriteTimestamp(g_scan.cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, g_scan.tq, 1);
    pvkEndCommandBuffer(g_scan.cb);
    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL, NULL, 1, &g_scan.cb, 0, NULL };
    pvkResetFences(g_dev, 1, &g_scan.fence);
    pthread_mutex_lock(&nvmtl_submit_mutex);
    VkResult sr = g_state == 1 ? pvkQueueSubmit(g_queue, 1, &si, g_scan.fence) : VK_ERROR_DEVICE_LOST;
    pthread_mutex_unlock(&nvmtl_submit_mutex);
    if (sr != VK_SUCCESS || pvkWaitForFences(g_dev, 1, &g_scan.fence, VK_TRUE, 1000000000ull) != VK_SUCCESS) { nvmtl_scan_off_locked("the copy did not complete"); goto out; }
    uint64_t o[3];
    const uint64_t t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (timed) {   /* after t1: reading the queries and writing the line count as flicker-probe time (probeUs) */
        uint64_t r[2] = {0}; FILE *pf = nvmtl_pt_file();
        if (pf && pvkGetQueryPoolResults(g_dev, g_scan.tq, 0, 2, sizeof r, r, 8, VK_QUERY_RESULT_64_BIT) == VK_SUCCESS) {
            const uint64_t mask = g_timestamp_bits >= 64 ? ~0ull : ((1ull << g_timestamp_bits) - 1);
            fprintf(pf, "present sid %u slot %u %s gpu_us %.1f copy_wait_us %.1f bytes %zu t %llu arm %llu\n", sid, k,
                    fmt10 && !l10r ? "widen-cpu" : l10r && !fmt10 ? "narrow" : "copy", (double)((r[1] - r[0]) & mask) * (g_lim.timestampPeriod / 1000.0),
                    (double)(t1 - t0) / 1000.0, (size_t)pitch * h, (unsigned long long)(clock_gettime_nsec_np(CLOCK_REALTIME) / 1000000ull),
                    (unsigned long long)g_pt_arms);
            fflush(pf);
        }
    }
    nvmtl_flick_probe(sid, base, w, h, pitch, l10r);
    const uint64_t t2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (g_scan.present(g_dev, g_scan.slotId[k], o)) { struct nvmtl_scan_status ls; memset(&ls, 0, sizeof ls); g_scan.status(g_dev, &ls);
        nvmtl_scan_lost_locked("present refused", &ls); goto out; }
    { const uint64_t t3 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
      g_scan.waitUs += (t1 - t0) / 1000; g_scan.probeUs += (t2 - t1) / 1000; g_scan.flipUs += (t3 - t2) / 1000;
      if (g_scan.lastT) { const uint64_t gap = (t3 - g_scan.lastT) / 1000000;
          g_scan.gapBin[gap < 8 ? 0 : gap < 16 ? 1 : gap < 33 ? 2 : gap < 100 ? 3 : 4]++; }
      g_scan.lastT = t3; }
    nvmtl_e0("Q sid %u flipped slot %u", sid, k);
    g_scan.next = k + 1;
    g_scan.copyUs += (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000;
    if (++g_scan.presents % 3000 == 0)
        nvlog("ws gpu present: %llu presents, %llu dropped, copy+present %llu us average", (unsigned long long)g_scan.presents,
              (unsigned long long)g_scan.drops, (unsigned long long)(g_scan.copyUs / g_scan.presents)),
        nvlog("ws gpu present split: copy+wait %llu us, flicker probe %llu us, flip %llu us average; present gaps <8ms %llu, <16 %llu, <33 %llu, <100 %llu, longer %llu",
              (unsigned long long)(g_scan.waitUs / g_scan.presents), (unsigned long long)(g_scan.probeUs / g_scan.presents),
              (unsigned long long)(g_scan.flipUs / g_scan.presents), (unsigned long long)g_scan.gapBin[0], (unsigned long long)g_scan.gapBin[1],
              (unsigned long long)g_scan.gapBin[2], (unsigned long long)g_scan.gapBin[3], (unsigned long long)g_scan.gapBin[4]);
    ret = 0;
    (void)nvmtl_scan_direct_live_locked(sid, w, h, pitch);   /* ws-direct created while this process runs */
out:
    pthread_mutex_unlock(&g_scan_lock);
    return ret;
}
void nvmtl_vk_scanout_stop(const char *why)
{
    pthread_mutex_lock(&g_scan_lock);
    if (g_scan.state == 1) nvmtl_scan_off_locked(why);
    pthread_mutex_unlock(&g_scan_lock);
}
int nvmtl_vk_scanout_on(void) { return g_scan.state == 1; }
