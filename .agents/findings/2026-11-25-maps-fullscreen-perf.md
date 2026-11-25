<!-- SPDX-License-Identifier: MIT -->

# Maps fullscreen is slow: what the captures measured, the fix, the capture that is still missing (2026-11-25)

Phase 2 item 2 follow-up. Since #29 (NVMTLDriver `327a082e`, live since the boot of 2026-11-25 17:52 on the XTX
machine, macOS 26.7.1 25G241, 2560x1440 at 240 Hz, HDR off) Apple Maps no longer crashes. The owner reports that Maps
in fullscreen is "really slow".

The megamind ran three captures with `tools/validation/appcapture.sh` (section 8) while the owner panned and zoomed
over a city: `~/vermilion-captures/2026-11-25-appcap/` `window-184800`, `fullscreen-185213` and
`fullscreen-vram-185339` (Maps in `debug.phxbo_vram_proc`). Each has per-second frames and CPU, the SMU's activity
and clocks, a 1 ms CPU sample of Maps and of WindowServer, the plugin log and the kext counters. Raw data stays
outside git (Maps' log has places in it). The analysis scripts are described in section 7.

Short version:

- **The GPU limit is a 3D-view phase that no CPU sample covers.** After the 3D city shaders load (`Sky`, `DaVinci::
  ground_*`), the GPU runs at 92-95 % busy and 2.9 GHz, about 7.5 ms of GPU per shown frame, at 123-130 frames/s,
  while Maps uses only 63-84 % CPU. Which pass takes those 7.5 ms is **not measured**: section 5 is the capture.
- **"VRAM gave only 7 %" compared different phases.** The VRAM run never reached a steady 3D phase. In the
  tile-loading phase, both runs cost the same GPU per frame. Whether VRAM placement helps the 3D phase is open.
- **Maps' CPU**: half of it (52-60 % of its busy samples) is under our plugin and RADV in the tile-loading phase,
  mostly VideoToolbox's per-tile transfer sessions. Maps' main thread waited 10 % of the capture for the GPU inside
  `replaceRegion:`. A Mac never waits there. This branch removes that wait (section 4; unverified on hardware).

## 1. Two phases, from the per-second data

GPU cycles per shown frame = the SMU's average GFX clock (it reads 30-60 MHz when idle, so it already folds in the
busy time) divided by the frames WindowServer showed that second.

| Phase (seconds of the capture) | Frames/s | Maps CPU | WindowServer CPU | GPU busy, avg clock | Mcycles/frame (≈ ms at 3.1 GHz) |
|---|---|---|---|---|---|
| A, tiles loading, fullscreen (t5-t9) | 138-182 | 180-404 % | 59-72 % | 57-72 %, 1.1-1.9 GHz | 7.6-11.9 (2.5-3.8 ms) |
| A, tiles loading, fullscreen-vram (t2-t11, t15-t20) | 99-189 | 188-409 % | 53-82 % | 44-85 %, 1.1-2.6 GHz | 6.3-22.2, median ~11 |
| **B, 3D view, fullscreen (t15-t20)** | 123-130 | 63-84 % | 49-63 % | **92-95 %, 2.9 GHz** | **22.1-24.2 (7.1-7.8 ms)** |
| B?, window (t15-t20) | 69-125 | 64-172 % | 36-64 % | 86-98 %, 2.7-3.1 GHz | 21-42 (7-14 ms) |

Phase B starts right after the log shows the 3D city's pipelines being made (18:52:22-18:52:25: `G11 load-action
render pass variant`, `Sky::sky_*`, `DaVinci::ground_*` with 64 function constants, `custom_effect_fragment` linked
with `distanceGradient_v1`). From then on the buffer census stops: Maps makes few new buffers. The window run looks the
same as phase B (GPU pegged at full clock), with more GPU per frame. A window adds the desktop, the shadows and the
menu bar to every composite.

In phase A the two fullscreen runs cost the same GPU per frame (median ~10-11 Mcycles), with and without VRAM. The
VRAM run's mean was higher (144 against 135 frames/s) because more of it was phase A. **The VRAM run has no steady
phase B**: its t12-t13 (115 and 60 frames/s, 20-39 Mcycles) is a pause in the panning. So the VRAM experiment tested
the tile-loading phase only.

All three CPU samples start 2 s into the capture and last ~11-14 s (`sample` ends early): window 18:48:02.9-18:48:16.6
(2.5 s of panning), fullscreen 18:52:15.4-18:52:27, vram 18:53:41.6-18:53:52.9. **No sample covers phase B.**

## 2. GPU: what can and cannot saturate it (ranking, confidence)

What the captures measure: the GPU is the limit in phase B (busy 92-98 % at full clock, Maps' CPU low). How the
~7.5 ms per frame divide is not measured. Ranked by what the data supports:

1. **Maps' own 3D-view passes** (likely; medium confidence). They are the only work that starts with phase B: the
   DaVinci ground shaders (64 function constants), the sky, 4x MSAA passes (`par1 resolve-shape ... 4 samples` at
   launch) with colour LOAD + depth clear render pass variants. Inside them, the candidates are the shader code our
   translator makes, the MSAA targets in system memory (Maps isn't in `phxbo_vram_proc`), and the drawable's tiled
   copy (14.7 MB per frame, ~0.6 ms estimated). Section 5 tells them apart.
2. **WindowServer's composite** (likely a large share; medium confidence). Horizon measured ~2.1-2.2 ms of GPU per
   1440p composite from system memory (`2026-11-23-horizon-present-cost.md`). At 125 frames/s that would be
   25-30 % of the GPU (unverified for Maps). A window costs more per frame than fullscreen (21-42 against 22-24
   Mcycles), which fits the composite growing with the number of layers. On a Mac a fullscreen app's frame goes to
   the display without a composite (TODO performance item 1).
3. **VideoToolbox's transfers and the per-submit prologues** (unlikely in phase B; medium confidence). ~470 transfers
   per second (YUV 512x512 to RGB, a compute pass plus a surface copy-in and copy-out each), ~21000 Managed uploads
   and ~17000 zero fills per second in prologues (VRAM run, 18:53:44-18:53:57: 4096 prologues carried 259223 uploads
   and 210815 fills, 340 MB). All of these are phase-A work. In phase B the buffer census shows almost no new
   buffers.
4. **Clear-only or redundant full-screen passes, shader variants compiled per frame** (no evidence). The log shows
   no per-frame pipeline creation in phase B. Two `fc cache: miss` (~30 ms each) and one `refl cache: miss` at
   18:52:23-24, then nothing. Clear-only passes can't be seen without the per-pass timer.

## 3. CPU: where Maps' time goes (measured, phase A)

Busy 1 ms samples of all Maps threads (idle waits excluded), grouped by the first matching frame in the stack. The
percentages are of all busy samples.

| | fullscreen | fullscreen-vram | window (mostly idle) |
|---|---|---|---|
| busy samples | 19528 | 28585 | 5455 |
| under NVMTLDriver / RADV / translator | **52 %** | **60 %** | 13 % |
| VideoToolbox transfer sessions: pipeline creation, function setup, `NSNumber stringValue` for 242 constants, frees | 14.3 % | 16.2 % | 0 |
| JSON cache keys over the 242 function constants: reflection (`nvmtl_embedded_bindings`), `fc1` key, `variant1` key | 11.6 % | 12.3 % | 0 |
| `newLibraryWithURL:` re-reads VideoToolbox's 2.4 MB metallib and SHA-256s 128 KB of it per session | 5.7 % | 7.0 % | 0 |
| render encoding (Maps' main thread) | 3.1 % | 4.3 % | 2.6 % |
| buffer free, `pool_block_give` (Resource Destruction queue) | 2.6 % | 3.0 % | 0.6 % |
| surface-in CPU copies (`nvmtlSurfaceIn`) | 2.5 % | 3.1 % | 0 |
| IOSurface texture wrapper: `nvmtl_surface_keep` enumerates a dictionary | 2.4 % | 3.2 % | 0 |
| everything else under the plugin (workers, buffer creation, readback CPU, other) | 9.8 % | 10.9 % | 9.8 % |
| Apple's code (VectorKit, AppleJPEG, vImage, malloc, objc outside our frames) | 48 % | 40 % | 87 % |

The VideoToolbox rows come from each tile's transfer session (`VTPixelTransferSession`). Each one makes a new
`MTLCommandQueue`, loads VideoToolbox's default library, specializes `VTMTSComputeFunction` with 242 constants and
makes its compute pipeline (4096 of each logged by 18:33:36 in the earlier session, ~56/s). All of it hits our caches.
The cost is computing the cache keys: `NSJSONSerialization` with sorted keys over the 242 constants, three times per
session, plus a JSON parse of the reflection. `utimes` runs on every hit, several times per session (~1.5-2.5 %). A
Mac's driver keys its caches on binary hashes and doesn't touch files on a hit.

Waits (idle samples, so not in the table above):

- **Maps' main thread waited 1202 ms of 11.6 s (10 %)** in `-[NVMTLTexture replaceRegion:]` ->
  `nvmtl_vk_image_write_region_level_layer` -> `nvmtl_vk_submit_wait` (fullscreen; 446 ms of 11.3 s in the VRAM run).
  The upload's copy is behind everything already queued, so each wait drains Maps' queued frames. At
  ~35 calls/s (VRAM run's submit census: 114 `image_write_region` per 4096 submissions in 3.3 s) that is about 3 ms
  per call. In the window run the tile decode threads waited there instead (~120-190 ms each). On a Mac,
  `replaceRegion:` is a CPU write and never waits for the GPU. **Changed on this branch** (section 4; unverified on
  hardware).
- **`nvmtl.execution`, the serial worker that retires command buffers**, waited 3.7-3.8 s of ~11.5 s: 1.3-2.2 s in
  the surface-out readback (`nvmtl_vk_image_read`, a waited submit per VideoToolbox transfer) and 1.5-2.5 s
  retiring. While it waits in a readback it retires nothing else: TODO "Music write-back as Apple does" (#23 fix 2)
  removes that readback.
- The tile decode threads each waited ~90-190 ms in the surface copy-in (`nvmtl_vk_image_write`, synchronous unless
  `NVMTL_ASYNC_SURFACE_IN=1`).

WindowServer: 714-2492 busy samples under the plugin (49 % / 43 % of its busy CPU), mostly CoreAnimation's draws
(`drawIndexedPrimitives`, `setRenderPipelineState`, render pass begin) and the plugin's worker. Nothing stands out
per call.

## 4. What this branch changes (plugin only, built, host tests pass, not installed)

1. **`replaceRegion:` no longer waits for the GPU** (`nvmtl_vk_image_write_region_level_layer`, `nvmtl_vk.c`). The
   async path behind `NVMTL_ASYNC_TEX_UPLOAD` already existed, default off and unbounded: each pending upload kept
   its own staging buffer until something used the image again. Now:
   - pending uploads go in the async surface copy-in's table and are reaped at each new upload (fence polled, never
     waited), so they are bounded (64 uploads, 128 MiB of staging); a full table takes the synchronous path;
   - the async copy is ordered after earlier GPU work on the image (ALL_COMMANDS, MEMORY_WRITE), as
     `NVMTL_SURFIN_ORDERED` does for the surface copy-in. The synchronous path keeps its old barrier;
   - **on by default outside WindowServer.** `NVMTL_ASYNC_TEX_UPLOAD=0` turns it off, `=1` turns it on in
     WindowServer too. The file `/Library/GPUBundles/nvmtl/async-tex-upload-off` turns it off for every process
     started after it exists (rollback without a restart: create it, relaunch the app);
   - the reaping never clears a newer upload's handle on the same image (two threads uploading at once).

   The invariants (destroy, readback, migration and re-upload finish a pending upload first) are the existing guard
   (`nvmtl_vk_image_upload_barrier`). `tests/plugin/test_tex_upload.c` covers the decision logic and the table's
   bounds.

   Fixed after the clean-up review of #31 (read from the code, not seen on hardware; one commit each):
   - a recyclable heap or buffer texture parked its image with the pending handle still on it, and the table kept a
     pointer into the freed texture: `-[NVMTLTexture dealloc]` now takes the upload barrier before parking;
   - the take unlisted the image's first table entry, not the taken handle's, so two threads uploading to one texture
     left a freed handle in the table and an upload never finished: the table unlists by handle, and a listing is
     refused (that upload waited for) while the image has a pending upload, so an image has at most one entry;
   - buffer textures (`newTextureWithDescriptor:offset:bytesPerRow:`) stay synchronous: the app can read their bytes
     through the buffer's `-contents` right after `replaceRegion:` returns (`placed = NVK_PLACED_IN_BUFFER`);
   - the async upload's ALL_COMMANDS barrier is emitted also when the image is already in TRANSFER_DST;
   - the listing rechecks the 128 MiB byte bound under the lock, not only the count;
   - the counters are atomic and the log reads the table's fill under the lock;
   - `appcapture.sh` turns `debug.phxgpu_time_on` back off on an interrupt.

   The table's code moved into `nvmtl_tex_upload.h` (`nvmtl_uptab_*`, a separate refactor commit) so the host test
   runs it instead of a model; it has arms for the park, two threads on one texture and the byte recheck, built with
   AddressSanitizer (the old park order is a heap-use-after-free there). The dealloc itself is not host-tested.

   Expected (unverified): Maps' main thread loses the ~10 % wait in phase A, so frames are encoded on time. This
   doesn't make the GPU faster.
2. **A cache hit touches its file at most once a minute** (`nvmtl_cache_touch`, `NVMTLLibraryLoad.m`). It was
   several `utimes` calls per VideoToolbox session in Maps, 1.5-2.5 % of its CPU and a metadata write each. The
   trimmer runs once per process and orders by last use, so a minute's resolution keeps its order.

Not done here (design, plugin, S-M each):

- **Binary cache keys instead of JSON** for `fc1` / `refl1` / `variant1` (11-12 % of Maps' CPU). Hash the constants
  from the packed `idx` / `sizes` / `payloads` the caller already has, and the reflection result parsed once per
  (AIR, stage, constants) instead of per function object. Interning equal constant dictionaries makes the per-function
  caches (`nvmtl_embedded_plan`, `nvmtl_static_samplers`) hit across VideoToolbox's sessions. The disk entries' names
  must stay the same digests, or a translator-tag bump.
- **Library reload without re-reading**: keep the last NSData and key per path while `stat` and the 2x64 KiB edges
  match (compare the edges with `pread` + `memcmp` instead of hashing them), 5.7-7 %.
- **`nvmtl_surface_keep`** enumerates a whole dictionary for each new IOSurface texture (2.4-3.2 %): index it.
- The surface-out readback on `nvmtl.execution` (TODO "Music write-back as Apple does").

## 5. The capture that decides the GPU ranking (megamind with the owner; before this branch's plugin is installed)

The owner keeps Maps in the 3D view the whole time: fullscreen, tilted over a city with buildings, the sky visible,
panning steadily. Check in the summary that the SMU shows ~94 % at ~2.9 GHz (phase B); otherwise repeat.

1. GPU time per process, phase B, fullscreen: `sudo GPUTIME=1 bash tools/validation/appcapture.sh Maps fs3d-gpu 30`.
   It adds two timestamp packets per submission while on (b157), the megamind's call. `gputime.txt` splits Maps,
   WindowServer, `com.apple.WebKit.GPU` and the others.
2. (Done 2026-11-25; since the follow-up branch one touch arms every process once and the file is not unlinked:
   [`2026-11-25-windowserver-composite-cost.md`](2026-11-25-windowserver-composite-cost.md) section 6.) Per-pass GPU
   time in the same phase: during run 1, at about t=10 s, `touch /tmp/nvmtl-passtime-request`. The first
   process to see it (each polls every 250 ms while it begins render passes) times its next 400 passes and logs
   `passtime: ARMED`. Check which process took it:
   `log show --last 15s --predicate 'subsystem == "org.vermilion.nvmtl" AND eventMessage CONTAINS "passtime"'`.
   Touch again until both Maps and WindowServer have armed once. The results are `nvmtl-passtime-<pid>.log` in each
   process's `$TMPDIR`: `sudo find /private/var/folders ~/Library/Containers/com.apple.Maps -name 'nvmtl-passtime-*'
   -mmin -10`. Each line: pass, size, format, `gpu_us`, `gap_us` (GPU time between passes: copies, dispatches, the
   prologue) and the fragment shaders it used. If Maps never logs `ARMED`, its sandbox refuses `/tmp`. Say so and
   use run 1's split only (a plugin change can move the trigger).
3. The same in a window: `... Maps w3d-gpu 30`, with the passtime touch.
4. Phase B with Maps' memory in VRAM: `sudo sysctl debug.phxbo_vram_proc=horizon-client,java,Maps`, quit and reopen
   Maps, the 3D view, `... Maps fs3d-vram-gpu 30` with the passtime touch. Then quit Maps and
   `sudo sysctl debug.phxbo_vram_proc=horizon-client,java`.

How to read it: if WindowServer's share is about 2 ms per frame, the composite (TODO performance item 1) is next. If
Maps' passes dominate and drop a lot in run 4, the placement is the cause (VRAM by default, TODO performance item 3,
kext + daemon, `hw-safety-reviewer`). If one Maps pass dominates in both runs 1 and 4, the shader code or that pass's
attachments are the cause: its `fs` hashes name the shaders. The GPU load is normal Maps use, no benchmark.

## 6. Ruled out or minor (from the first look, still true)

- `debug.phxvm` "VRAM placed as GTT (vis full) 150" is accounting only. For a process outside `phxbo_vram_proc`
  every BO is system memory either way. No BO was refused in this boot.
- `nvlog` limits every call site to 8 lines, then every 4096th. The census lines that are already emitted once per
  4096 events are therefore limited twice, and Maps' last `buffer census` in the earlier session is from 18:32:47. A
  log-quality fix (S), no behaviour change.
- WindowServer used ~20-25 % of a core on a quiet desktop (18:44). Not looked into.
- During the first look, `sysctl -a` read every `debug.*` OID once (18:36). `debug.phxedid` refused (not root).
  `debug.phxshot` read the scanned-out frame through BAR0 (reads only). The display stayed normal. Named OIDs only
  from now on (perflog.sh's rule).

## 7. Method

The `sample` call graphs were parsed into a tree. Each node's self samples are its count minus its children's. Idle
leaves (`mach_msg2_trap`, `__psynch_cvwait`, `__workq_kernreturn`, semaphore and kevent waits) count as waits, not CPU.
A sample is "under the plugin" if any frame in its stack is in NVMTLDriver, `libvulkan_radeon.dylib` or
`libnvmtl_translate.dylib`. Its group is the first frame from a fixed list, specific frames first. Waits are grouped
by the nearest NVMTL frame above `acd_kext_wait_seq`. The scripts were throwaway (session scratchpad). The method
fits in one Python file if it is needed again (a candidate for `tools/validation/`).

## 8. The tool

`tools/validation/appcapture.sh` (this branch) records:

- every second: frames WindowServer showed (`debug.nvaccel_iop_ok`) and the CPU time of the app and WindowServer;
- a 1 ms CPU `sample` of the app and of WindowServer;
- the plugin's log;
- named kext counters before and after;
- the SMU's GPU activity and clocks (`~/gpu/smumetrics.py`);
- optionally (`GPUTIME=1`) GPU time per process (`debug.phxgpu_time_on`, b157).

The samples start 2 s in and run for the duration minus 4 s, but `sample` ended after 11-14 s in all three runs. For
a 30 s run, read the sample's `Date/Time` and its length before attributing it to a phase.

## 9. Unverified

- The GPU split in phase B (section 2): no GPU timing of Maps exists. The ~2.1 ms composite is Horizon's figure.
- The effect of this branch's changes on hardware: built and host-tested only, the review fixes included. Whether the
  async upload is correct in every app (texture contents, IOSurface textures) is checked by the deploy steps, not by
  a test on the GPU.
- The rates in section 2 point 3 come from log census lines over 3-13 s windows, not a profiler.
