// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
/* Our code (Vermilion, RX 7900 XT), included by nvmtl_vk.c right after nvmtl_vk_image_upload_barrier (one translation unit
   with the plugin; it uses the async-upload handle machinery defined just above it).

   NVMTL_ASYNC_SURFACE_IN=1 (every process) or =ws (WindowServer only; default off): the IOSurface copy-in (nvmtl_vk_image_write, called only by
   -[NVMTLTexture nvmtlSurfaceIn]) is submitted without waiting for the GPU. The synchronous path copied the surface into
   staging, submitted and waited on WindowServer's main thread for every new surface wrapper; in the Safari full-screen
   transition that was the largest share of the 50-100 ms present gaps (spindump,
   2026-10-29).

   Why it is safe: every MTLCommandQueue of the process submits to the one device queue (nvmtl_device_queue), and the
   command buffer that samples the image is submitted after this copy (at its commit), so queue order plus the
   TRANSFER->SHADER_READ barrier order the copy before the read, exactly as for the synchronous submit. The upload keeps
   its own staging buffer and its handle is stored on the image (img->up_token, the NVMTL_ASYNC_TEX_UPLOAD machinery): a
   readback, migration, destroy or the next upload of that image finishes it first (nvmtl_vk_image_upload_barrier).
   Completed uploads are reaped at each new one (fence polled, never waited) so the staging memory they hold is bounded:
   at most NVMTL_UPTAB_N uploads and NVMTL_UPTAB_CAP bytes pending (the table is nvmtl_tex_upload.h's); above that the upload takes the synchronous path.
   replaceRegion's async uploads (NVMTL_ASYNC_TEX_UPLOAD, on by default outside WindowServer) are listed in the same
   table and count against the same bounds. */
#define NVMTL_SURFIN_SYNC (-2)
static _Atomic uint64_t g_surfin_async, g_surfin_sync, g_surfin_reaped;   // counters for the log, from any thread
static int nvmtl_async_surface_in(void)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("NVMTL_ASYNC_SURFACE_IN");
        on = e && (e[0] == '1' || (!strcmp(e, "ws") && !strcmp(getprogname(), "WindowServer")));   // ws = WindowServer only
        nvlog("vk: async surface copy-in %s (NVMTL_ASYNC_SURFACE_IN)", on ? "ON" : "OFF (default)");
    }
    return on;
}
static int nvmtl_asyncup_done(uint64_t h, void *ctx)
{
    (void)ctx;
    return pvkWaitForFences(g_dev, 1, &((nvmtl_asyncup *)(uintptr_t)h)->infl.fence, VK_TRUE, 0) == VK_SUCCESS;
}
// Moves the handles of completed uploads off their images (under the lock) and finishes them (outside it: their fences
// have signalled, so the finish does not wait).
static void nvmtl_surfin_reap(void)
{
    uint64_t done[NVMTL_UPTAB_N];
    pthread_mutex_lock(&g_asyncup_mutex);
    const unsigned nd = nvmtl_uptab_reap(&g_uptab, nvmtl_asyncup_done, NULL, done);
    pthread_mutex_unlock(&g_asyncup_mutex);
    for (unsigned i = 0; i < nd; i++) nvmtl_asyncup_finish(done[i]);
    g_surfin_reaped += nd;
}
// The async region uploads of replaceRegion (NVMTL_ASYNC_TEX_UPLOAD, nvmtl_vk_image_write_region_level_layer) share this
// table, its bounds and its reaping; these count them.
static _Atomic uint64_t g_texup_async, g_texup_sync;
// Room in the table for one more upload of `bytes` staging bytes?
static int nvmtl_asyncup_room(size_t bytes)
{
    pthread_mutex_lock(&g_asyncup_mutex);
    const int room = nvmtl_uptab_room(&g_uptab, bytes);
    pthread_mutex_unlock(&g_asyncup_mutex);
    return room;
}
// Lists a submitted async upload on its image and in the table. Returns 0 if other threads' uploads took the table's
// room (count or bytes) since nvmtl_asyncup_room, or another thread listed its own upload to this image: the upload is
// then finished (waited for) here and nothing of it is left pending. *pending_n and *pending_bytes get the table's
// fill after it, read under the lock (for the log).
static int nvmtl_asyncup_list(nvk_image *img, nvmtl_asyncup *au, size_t bytes, unsigned *pending_n, size_t *pending_bytes)
{
    pthread_mutex_lock(&g_asyncup_mutex);
    const int listed = nvmtl_uptab_list(&g_uptab, &img->up_token, (uint64_t)(uintptr_t)au, bytes);
    *pending_n = g_uptab.n; *pending_bytes = g_uptab.bytes;
    pthread_mutex_unlock(&g_asyncup_mutex);
    if (!listed) nvmtl_asyncup_finish((uint64_t)(uintptr_t)au);
    return listed;
}
static int nvmtl_surfin_async(nvk_queue *q, nvk_image *img, const void *src, size_t row_bytes)
{
    if (!nvmtl_async_surface_in()) return NVMTL_SURFIN_SYNC;
    const size_t bpp = img->bpp ? img->bpp : 4;
    const uint32_t cols = nvmtl_blocks(img->w, img->bw), rows = nvmtl_blocks(img->h, img->bh);
    if (row_bytes < (size_t)cols * bpp) return NVMTL_SURFIN_SYNC;   // the synchronous path logs and refuses it
    const size_t tight = (size_t)cols * bpp, bytes = tight * (size_t)rows;
    nvmtl_surfin_reap();
    // the previous upload of this image must land before this one overwrites it (normally long done: no wait)
    nvmtl_asyncup_finish(nvmtl_asyncup_take(img));
    if (!nvmtl_asyncup_room(bytes)) { g_surfin_sync++; return NVMTL_SURFIN_SYNC; }
    nvmtl_asyncup *au = (nvmtl_asyncup *)calloc(1, sizeof *au);
    if (!au || nvmtl_vk_buffer_create(bytes, 1, &au->stage)) { free(au); g_surfin_sync++; return NVMTL_SURFIN_SYNC; }
    uint8_t *dst = (uint8_t *)au->stage.map;
    if (row_bytes == tight) nvmtl_copy_from_surface(dst, src, bytes);
    else for (uint32_t y = 0; y < rows; y++)
        nvmtl_copy_from_surface(dst + (size_t)y * tight, (const uint8_t *)src + (size_t)y * row_bytes, tight);
    nvk_cmdbuf *const c = &au->cb;
    if (nvmtl_vk_cmd_begin(q, c)) { nvmtl_vk_buffer_destroy(&au->stage); free(au); return -1; }
    // the same commands as the synchronous nvmtl_vk_image_write: the whole image is replaced, old contents discarded
    VkImageSubresourceRange range = { nvmtl_barrier_aspect(img), 0, 1, 0, 1 };
    VkImageMemoryBarrier toDst = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, nvmtl_surfin_ordered_on() ? (VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_SHADER_READ_BIT) : 0, VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, (VkImage)img->img, range };
    pvkCmdPipelineBarrier(c->cb, nvmtl_surfin_ordered_on() ? VK_PIPELINE_STAGE_ALL_COMMANDS_BIT : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &toDst);
    VkBufferImageCopy bic = { 0, 0, 0, { nvmtl_copy_aspect(img), 0, 0, 1 }, { 0, 0, 0 }, { img->w, img->h, 1 } };
    pvkCmdCopyBufferToImage(c->cb, (VkBuffer)au->stage.buf, (VkImage)img->img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bic);
    VkImageMemoryBarrier toRead = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
        VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, (VkImage)img->img, range };
    pvkCmdPipelineBarrier(c->cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, NULL, 0, NULL, 1, &toRead);
    img->layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    if (nvmtl_vk_submit_begin_at(c, &au->infl, "surface upload async")) { nvmtl_vk_buffer_destroy(&au->stage); free(au); return -1; }
    // another thread filled the table since the check: this one was waited for after all
    unsigned pend_n; size_t pend_bytes;
    if (!nvmtl_asyncup_list(img, au, bytes, &pend_n, &pend_bytes)) { g_surfin_sync++; return 0; }
    const uint64_t n = ++g_surfin_async;
    if (n <= 4 || n % 2000 == 0)
        nvlog("async surface-in #%llu: %ux%u submitted without a wait (%u pending, %zu KB; %llu reaped, %llu took the sync path)",
              (unsigned long long)n, img->w, img->h, pend_n, pend_bytes >> 10,
              (unsigned long long)g_surfin_reaped, (unsigned long long)g_surfin_sync);
    return 0;
}
