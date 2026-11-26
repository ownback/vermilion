<!-- SPDX-License-Identifier: MIT -->

# WindowServer's GPU time behind fullscreen Maps: what each frame costs (2026-11-25)

Follow-up to [`2026-11-25-maps-fullscreen-perf.md`](2026-11-25-maps-fullscreen-perf.md), section 5. XTX machine, macOS
26.7.1 25G241, 2560x1440 at 240 Hz, VRR on, HDR off, NVMTLDriver `327a082e`, GPU present on with
`ws-gpu-present-async` and `NVMTL_WS_PRESENT_CDCOPY=1` (boot flag `phxboot-wscdcopy`). The owner panned Maps in the 3D
city view, in fullscreen. Captures: `~/vermilion-captures/2026-11-25-appcap/fs3d-gpu-194945/` and `run2-gpu-195127/`,
with `GPUTIME=1` and the per-pass timer (`/tmp/nvmtl-passtime-request`) armed in both processes.

Short version:

- **Maps drew about 35 new frames per second. WindowServer composited 119.** Maps' main pass took 6.1 ms of GPU
  (passtime, 2314 frames). WindowServer took ~3.1 ms per shown frame. That is about 10 ms of WindowServer GPU time per
  Maps frame, more than Maps' own frame.
- **Per composite, the cost is the frame moving through system memory, not the drawing.** WindowServer samples Maps'
  14.7 MB drawable from its system-memory pages and writes SkyLight's linear system-memory target. CoreDisplay copies
  that target into a system-memory display surface. GPU present then reads the whole display surface back into a
  VRAM slot. On a Mac every one of these surfaces is in VRAM, and the display scans out WindowServer's framebuffer
  directly.
- **Full clears are not the cost.** `begin_render: fullclear 2560x1441` and `encoder: clear-only pass` happen at
  WindowServer start, not per frame.
- **This branch adds measurement only** (section 5): the timer arms once per touch in every process, its lines carry
  wall time, and the present copy is timed on the GPU. The fixes need the kext (section 4).

## 1. The numbers

From `gputime.txt` and `per-second.txt`:

| Run | Frames shown | WindowServer gfx | Maps gfx | GPU (SMU) |
|---|---|---|---|---|
| fs3d-gpu-194945 | 3583 in 30 s (119/s) | 11.55 s = 36.5 % of 31.6 s, 18241 submissions (5.1 per shown frame) | 7.54 s = 23.8 %, 29967 submissions | 25-81 % busy, average clock 0.6-2.5 GHz |
| run2-gpu-195127 | 143/s | 41.7 % | 16.8 % | |

WindowServer: ~3.1 ms (fs3d) and ~2.9 ms (run2) of GPU per shown frame. **This is not phase B:** the SMU never showed
92-95 % at 2.9 GHz. The GPU was 60 % busy, at a low clock that stretches every pass.

GPU time per context counts how long a context holds the gfx queue, waits inside its IBs included (`PhxGpuTime.h`).

## 2. WindowServer, pass by pass

WindowServer's log, `nvmtl-passtime-1106.log` in `/private/var/folders/zz/<_windowserver's folder>/T/WindowServer/`,
has 198400 passes in 17125 command buffers. It was read at 19:53. The machine restarted at ~19:57 (not caused by
this work: every command here was read-only), and the restart cleared that directory. What is left is what was
analysed before the restart: the aggregate over the whole log and the frame sequences below. The aggregate spans
both runs and the time between them, because WindowServer re-armed every 250 ms (section 5).

Each pass's `gpu_us` runs from a BOTTOM_OF_PIPE stamp before `vkCmdBeginRenderPass` to one after
`vkCmdEndRenderPass`, so it includes the pass's entry and exit barriers. Work outside render passes (copies,
dispatches, GPU present) is not in it.

**One shown frame is three command buffers** (sequence at ~19:50:07, fs3d, cbs 1534-1543):

| Command buffer | Passes | GPU | What (inferred) |
|---|---|---|---|
| A: SkyLight's composite | 29-40 | **1.5 ms** (short) / **~3.9 ms** (long) | the Maps layer, the glass and material passes, the controls |
| B: one full-screen pass, fs `f1c2052c` | 1 | 94-101 us | CoreDisplay: the unchanged rects into the next SkyLight target (E1) |
| C: one full-screen pass, fs `bc904a2a` | 1 | 21-101 us | CoreDisplay: the frame into a display surface (E3, what GPU present shows) |

The roles of B and C come from the commit structure in `NVMTLWSPresent.m` (E1, E3). The log has no queue labels, so
they are unverified.

Inside A, by share of all of WindowServer's pass time (12.40 s):

| Share | Passes | Avg | Pass (render area, fragment shaders) | Reading |
|---|---|---|---|---|
| **27.7 %** | 3406 | 1007 us | 2560x1440, `82efb555 17a83d4e 4b313970` | **the Maps layer**: 463 us in a short frame, 2776 us in a long one |
| 4.7 % + 3.6 % + 0.7 % | 493 + 135 + 48 | 1.2-3.3 ms | 2560x1440, `82efb555` + other shaders | the same layer in other states (window or transitions) |
| 4.9 % | 3007 | 201 us | 2560x1440, `62500d49 6ced560a` | glass / material over the map |
| 2.8 % + 0.8 % + ... | ~3200 each | 40-110 us | 2560x1440, `ff9e82c7 6ced560a ...` | more glass layers |
| ~10 % together | ~30 per frame | 12-95 us | 173x427 → 320x576 → 160x288 → ... → 10x18, `dfbdd435` / `5bbc4057` / `806dea10` | blur pyramids of the material backdrops, plus icons 16x16-83x83 |
| 12.2 % | 4523 | 334 us | cb B | |
| 10.3 % | 6517 | 195 us | cb C | |

Readings:

- **The Maps layer pass has two costs.** If ~24 % of frames are long ones, the 1007 us average follows
  (463 + 0.24 x 2313). That is ~28 per second at 119 shown, about the rate at which Maps draws (section 3). So a
  long frame is a new Maps drawable composited whole: 14.7 MB sampled from its system-memory pages in 2.8 ms
  (~5 GB/s, the PCIe read rate Horizon showed, ~7 GB/s at b158). A short frame redraws part of the layer under
  changing glass. (Estimate: the mix comes from an aggregate over several phases.)
- **Every pass costs at least ~12-14 us**, even at 16x16, plus ~4 us between passes. A frame's ~30 small passes cost
  ~0.4-0.5 ms for this floor alone. Every render pass is created with an entry and an exit dependency
  ALL_COMMANDS / MEMORY_WRITE -> MEMORY_READ | MEMORY_WRITE without an image (`nvmtl_vk.c`, the two `deps` arrays).
  RADV turns a global barrier like that into a full drain and, most likely, an L2 write-back and invalidate
  (unverified: read from RADV's barrier code, not measured). The timer's own BOTTOM_OF_PIPE stamp also drains.
- **The glass is real Apple work.** Tahoe's Liquid Glass controls over Maps (search field, zoom, compass) need their
  backdrop blurred again whenever the map under them changes. A Mac does that too, but in VRAM and at tiled speed.
- **Clears:** WindowServer logged `begin_render: fullclear 2560x1441 render area — Clear attachments 0x1 are larger and
  were cleared WHOLE` 7 times in 25 ms right after its start (19:58:20, next boot), and `encoder: clear-only pass` 8
  times. No clear-only (no fragment shader) or 2560x1441 pass is among the costly passes of the Maps run. Not a
  per-frame cost (medium-high confidence: the nvlog limit hides later occurrences, but they would show in the
  passtime log).

**The present copy** (outside the passes): `ws gpu present split: copy+wait 925-1053 us` average per present
(WindowServer log, next boot, 19:59-20:00, desktop load, same 14.7 MB copy). This is the CPU's view: the copy's GPU
time plus its wait behind the work queued ahead of it. `nvmtl_vk_scanout_present` copies the whole display surface
(`vkCmdCopyBuffer`, pitch x height) from its host-imported pages into a VRAM slot every present, whatever changed. The
GPU part is not measured. This branch measures it (section 5).

## 3. Maps, from its passtime log (`~/Library/Containers/com.apple.Maps/Data/tmp/nvmtl-passtime-88981.log`)

7558 passes in 2564 command buffers:

| Share | Passes | Avg | Pass |
|---|---|---|---|
| 79.7 % | 2314 | **6072 us** | 2560x1440 BGRA8 sRGB (fmt 50), fs `940466fa 69f1b1aa 24402eb6`: the 3D map |
| 13.2 % + 1.4 % | 218 + 28 | 9.1-10.6 ms | the same with `ad66a9de` |
| 4.9 % | 2561 | 339 us (118 us gap before it) | 2560x1440, `5b29d0e4`: a full-screen pass after the map |
| <1 % | | 15-70 us | overlays |

Maps' GPU per frame ≈ 6.5-7 ms. With 7.54 s of GPU in 31.6 s, that is **~35 frames per second** (estimate: the
passtime log has no timestamps and spans more than one run). WindowServer presented 119/s, so **~3.4 composites per
Maps frame** and ~10 ms of WindowServer GPU per Maps frame. On the one gfx queue, Maps' next frame waits behind them.

Why WindowServer composites more often than Maps draws is not known. Candidates: Maps' Core Animation commits (labels,
controls) at the display rate, glass animation, or our present path. The E0 trace (`NVMTL_E0_TRACE=1` for
WindowServer) would tell, but needs a WindowServer restart.

## 4. Ranking, and the fix as a Mac does it

WindowServer's GPU time per shown frame (~3.1 ms, fs3d):

| # | Cost | Per frame | Confidence |
|---|---|---|---|
| 1 | The Maps layer sampled from system memory into a system-memory target | ~1.0 ms average, 2.8 ms with a new Maps frame | number high, cause medium |
| 2 | Glass, material and UI passes, of which the per-pass floor is ~0.4-0.5 ms | ~0.7-0.9 ms | number medium, floor's cause low-medium |
| 3 | GPU present: the whole display surface read back over PCIe into a VRAM slot | 0.93-1.05 ms copy+wait (CPU); GPU part not measured | medium-low |
| 4 | CoreDisplay's two full-screen passes (B, C) | 0.12-0.5 ms | medium |
| - | Full clears, clear-only passes | ~0 per frame | medium-high |

The multiplier on all of it: ~3.4 composites per Maps frame (medium-low). Across the board: the GPU clock stays low at
60 % load.

**What a Mac does:** CoreAnimation and WindowServer still composite Maps every frame. The glass controls need it, so
direct scan-out of Maps' surface does not apply while they are on screen (from Apple's documented direct-to-display
behaviour; unverified for Tahoe's Maps). But the composite reads the app's drawable from VRAM and writes WindowServer's
framebuffer in VRAM, tiled, and the display scans out that framebuffer: there is no copy after the composite. For a
fullscreen opaque layer with nothing over it (games, Horizon), the app's surface goes to the display without a
composite.

Fixes, by gain for Maps (none fits in the plugin alone; design only):

1. **Scan out CoreDisplay's display surfaces** (removes row 3, and makes C a VRAM write; kext + plugin, L). The plugin
   already knows the two display surfaces (`nvmtl_ws_note_display`, CDCOPY). PhxAccel backs those IOSurfaces with the
   kext's two large scan-out slots (VRAM 256 and 288 MiB, `PhxScanLayout.h`, CPU-visible in the live 1 GiB BAR0), and
   GPU present flips HUBP0 to the surface itself instead of copying into a slot. **`hw-safety-reviewer` (2026-11-25):
   not OK as first written. OK once these changes are in:**
   - The flip stays today's three writes (`HUBPREQ0_DCSURF_FLIP_CONTROL`, then `PRIMARY_SURFACE_ADDRESS_HIGH` and
     `PRIMARY_SURFACE_ADDRESS`, `phx_scan.cpp`), a subset of Linux's `hubp3_program_surface_flip_and_addr`. On the
     large slots, even the addresses are today's. No `SURFACE_CONFIG`, pitch, tiling, DCC, MALL, DMUB, SMU or PSP
     write. Read the live `VMID_SETTINGS_0` and TMZ bits once to confirm they are Linux's 0.
   - The register selector can't take client memory: it rebinds onto its own slots and refuses VRAM BOs
     (`phx_scan_client.cpp`). Use the fixed large slots, or a new path that registers a pinned range and validates
     it: inside VRAM and the `DCN_VM_FB_LOCATION` window, pitch = HUBP0's live pitch (10240 at 1440p; other modes
     keep the copy), 256 B pitch and offset alignment, 2 MiB address alignment, format = HUBP0's.
   - BAR0 is 1 GiB (EFI stage `vermilion-trust-bar1g`), and [0, 256 MiB) is all fixed regions. Read the BAR size;
     with a 256 MiB BAR0, stay on the copy.
   - **The GPU must never reach its own BAR through a host import.** Today GPU present and RADV import the surface's
     pages (`doBoImportHost` doesn't check for BAR pages). The kext must refuse host imports of pages inside BAR0,
     and the GPU reaches VRAM-backed surfaces only through local-VRAM PTEs. Linux's userptr refuses such mappings.
   - Two surfaces, not three slots. CoreDisplay's write (pass C) into a surface waits until that surface is not
     pending, not `EARLIEST_INUSE` and not front: Linux's flip-complete test, covering b74's taken-flip case. Expect
     up to one vblank of waiting.
   - Flip away before free. Before PhxAccel frees or reuses a scanned-out surface (BGRA-to-l10r swap, HDR toggle,
     mode change, WindowServer exit), the kext flips away and verifies it. PhxAccel and VermilionBoot need an
     explicit handshake for this. Console surface A stays the restore target.
   - CPU readers (flicker probe, PhxAMDFB's CPU copy, screenshots) then read write-combined BAR memory: turn the probe
     off for VRAM-backed surfaces.
2. **GPU-used IOSurfaces in VRAM, shared across processes** (TODO 13 item 2, L): Maps' drawable written and
   WindowServer's composite read in VRAM. Row 1 goes from 2.8 ms towards Horizon's tiled figure (12.5x faster at
   C2), and Maps loses its per-frame tiled-to-pages copy. Kext (cross-process BO import for IOSurfaces: "NVK import
   ABSENT" today, each process gets its own copy) + plugin.
3. **Narrow render-pass dependencies** (plugin, S-M, after a measurement). Replace the image-less ALL_COMMANDS /
   MEMORY_* entry and exit dependencies by what Metal's hazard tracking needs, so RADV doesn't flush L2 at every pass.
   It touches GPU sync in every app, so first: a counter of RADV's flush bits per pass, or an A/B with upstream's
   `NVMTL_RP_K1=1` (entry dependency off). RADV may merge the two dependencies of a pass boundary into one flush,
   which would make K1 alone worth nothing.
4. **Interim, plugin only (TODO 13 item 1's redo, M):** SkyLight's targets and the display surfaces drawn tiled in VRAM,
   GPU present copying VRAM to VRAM, and one page write per frame for CPU readers. Smaller gain than 1 and 2, and the
   flicker history of this path (findings 2026-11-19, E0-E3) means hardware A/B first.
5. **Later:** direct scan-out of a fullscreen opaque app drawable (games, Horizon). `hw-safety-reviewer`: not OK
   yet. App drawables are tiled, and acquire requires HUBP0 linear with DCC off. A tiled flip needs
   `DCSURF_TILING_CONFIG`, meta address and format writes, and there is no Linux capture of such a flip on this card.
   So: capture one on Linux first (KMS direct scan-out with a GFX11 modifier), or limit it to linear drawables of
   matching format and size, where only the address changes as in 1. It also needs a cross-process VRAM BO import and
   fix 1's lifetime rules for an app that can quit or crash while its drawable is on screen.

## 5. What this branch changes (plugin, measurement only; built, host test, not installed)

- **One touch arms every rendering process once** (`nvmtl_passtime.h`, `nvmtl_pt_armed`). Before, the first process to
  see `/tmp/nvmtl-passtime-request` unlinked it. WindowServer (as `_windowserver`) cannot unlink the owner's file in the
  sticky `/tmp`, so it re-armed every 250 ms while the file existed: 496 windows, ~2 minutes of timestamps in the Maps
  capture, and a log that mixed both runs. Now nobody unlinks the file. A process arms when it sees an inode or mtime
  it hasn't armed for, at most 15 s old. Touch it again for another window. `tests/plugin/test_passtime.c`.
- **Every pass line ends with `t <unix ms> arm <n>`** (wall time at the command buffer's retirement, and the window), so
  passes map to the capture's seconds and Maps' frame rate can be counted. The fields before them are unchanged.
- **The GPU present copy is timed on the GPU while the timer is armed**: a line `present sid <id> slot <k> copy|narrow|
  widen-cpu gpu_us <x> copy_wait_us <y> bytes <n> t <ms> arm <n>` in WindowServer's passtime log. `gpu_us` covers the
  barrier and the copy. `copy_wait_us - gpu_us` is the recording, the submit, the time it queued behind other work and
  the fence wake-up (for `widen-cpu` also the CPU widening). Two timestamps in the present command buffer, nothing
  else in that path changes, and while the timer is off the present path only tests one counter. Presents don't
  count against the 400 passes: every present is logged until the process has drawn its 400 render passes.
- The log file is opened once per process (`pthread_once`). A failed open is logged once.
- Limits found in the review (TODO, "Passtime: review notes"): the arm counter and the poll state have no lock, so
  two threads can arm twice for one touch; `arm <n>` counts per process, so a process that was idle for a touch is
  one behind; while armed, the line is written inside the present's flicker-probe time (`probeUs`).

Build: `sh scripts/build/plugin.sh` (with `VULKAN_HEADERS`), no new warnings against `fork/main`. Host tests:
`test_passtime` (new), `test_tex_upload`, `test_copy_compat`, `test_pool_range`, `test_safe_copy` pass.

## 6. Deploy and check (megamind with the owner)

A plugin install is a VermilionTrust + EFI change, one boot (`PHXTRUST_KEEP=1 sh scripts/build/trust.sh`, EFI rebuild).
Rollback: the previous NVMTLDriver (`327a082e` or whatever is installed then) and its trust list.

After the boot, the capture that is still missing (phase B, fullscreen):

1. Maps fullscreen, 3D city, panning. `sudo GPUTIME=1 bash tools/validation/appcapture.sh Maps fs3d-gpu 30`. Check in
   `smu.txt` that the GPU shows ~92-95 % at ~2.9 GHz (phase B), else repeat.
2. At t≈10 s: `touch /tmp/nvmtl-passtime-request` **once**. Both Maps and WindowServer log `passtime: ARMED for 400
   passes (arm 1)`. Touch again at t≈20 s (arm 2).
3. **Copy WindowServer's log before anything restarts**:
   `sudo find /private/var/folders -name 'nvmtl-passtime-*' -path '*WindowServer*' -mmin -10 -exec cp {} <capture dir>/ \;`
   and Maps' `~/Library/Containers/com.apple.Maps/Data/tmp/nvmtl-passtime-<pid>.log`.
4. Read: the `present` lines' `gpu_us` (row 3), the Maps-layer pass per second with `t` (row 1, long vs short), Maps'
   main passes per second (its real frame rate), and the ratio of WindowServer presents to Maps frames.

Expected: `present` gpu_us 0.5-0.9 ms (unverified). If it is near 1 ms, fix 1 is worth as much as fix 2 for Maps.

## 7. Unverified

- The roles of cbs B and C (CoreDisplay's two copies) and of the glass passes: inferred from the commit structure
  and the pass sizes, not from queue labels or shaders. WindowServer cannot write its SPIR-V to `pstat` (home
  `/var/empty`), so the hashes have no files.
- Maps' frame rate (~35/s) and the 24 % long-frame share: estimates from aggregates without timestamps.
- The cause of the ~13 us per-pass floor (RADV's L2 flush on image-less barriers): from reading the code, not measured.
- The GPU part of the present copy: only the CPU's copy+wait is measured, and in the next boot under desktop load.
- The effect of fixes 1-5: none built. This branch's change is built and host-tested only. `hw-safety-reviewer`
  passed the plugin diff (only timestamp packets RADV also emits on Linux; flip and latch unchanged).

## 8. Fix 1 built (2026-11-25, branch `ownback/ws-vram-scanout`)

Built and host-tested only. Nothing installed, nothing booted. Everything below about hardware behaviour is
(unverified).

**What it does.** With CDCOPY on and the switch file `/Library/GPUBundles/nvmtl/ws-direct` present, GPU present stops
copying CoreDisplay's display surface into a slot. The two display surfaces ("CoreDisplay Scanout" IOSurfaces) are
drawn straight into slots 0 and 1 of the kext's large layout (VRAM 256 and 288 MiB, `PhxScanLayout.h`), and the
present flips HUBP0 to the surface's slot. Slot 2 is the bounce, for when CoreDisplay must write the surface that is
still on screen.

**How it differs from the section 4 sketch.** The IOSurfaces keep their host pages, and PhxAccel is unchanged.
VermilionBoot b162's new selector `PHXN_SEL_SCAN_DIRECT` (22) rebinds the GPU PTEs of the plugin's own host import
of a surface onto the slot's VRAM. It uses local-VRAM PTEs (`vmMapVram`), the mechanism `SCAN_REGISTER` already uses
for the slots. So the GPU reads and writes the surface in VRAM, and the CPU-side pages go stale while it is bound.
`scanUnbind` puts the PTEs back onto the pages. This needs no RADV rebuild, no VermilionAccel change and no new
register write. The kext adds 7 register reads and no writes.

| Condition (section 4 review) | Where |
|---|---|
| 1. The two fixed large slots | `scanDirectSlot` (`phx_scan.cpp`) binds slot 0 or 1 of the caller's own large acquisition only. Pitch, size, format and offset must equal the slot's (`PhxScanDirect.h` `bindCheck`, every branch in `tests/kext/scan_direct_test.cpp`). |
| 2. BAR size at runtime | `barCoversSlots`: BAR0 as assigned *and* the mapped aperture must reach 352 MiB. With BAR0 at 256 MiB, `PHXN_SCANQ_DIRECT_OK` stays clear and the plugin keeps the copy. The same gate requires the large layout, no TMZ or DCC and VMID 0 on HUBP0, and on HUBP1 under ODM 2:1 (reads only). |
| 3. No host imports of BAR pages | `doBoImportHost` walks the prepared segments and refuses with `kIOReturnNotPermitted` any that touch BAR0, BAR2 or BAR5 (`physInOwnBars`). Linux's userptr refuses them too: `amdgpu_ttm_tt_get_user_pages` → `hmm_range_fault` → `hmm_vma_walk_test` refuses VM_IO and VM_PFNMAP. |
| 4. Linux's flip-complete test before a write | The kext's `PHXN_SCANSLOT_WRITABLE` is `writable(pending, inuse, front)`: Linux's `hubp2_is_flip_pending` (FLIP_PENDING, EARLIEST_INUSE against the slot), the latched front counting as on screen, and HUBP1 ORed in under ODM 2:1 (Linux `dc_plane_get_status` over every pipe). The plugin gates every command buffer that writes a bound surface (`nvmtl_vk_scanout_write_gate`, from `nvmtlSubmitWithEvents`). The gate takes all of the command buffer's surfaces at once and holds until all are writable. A blocked surface bounces to slot 2 at once, or after 50 ms if a pending flip may still free it. After 250 ms the gate falls out to the copy path. Writes committed before the bind are counted (`g_sd_ungated`), and no flip happens while any are unfinished. |
| 5. Flip away before free | While bound, the plugin holds a reference on each surface and its texture, so CoreDisplay can't free the pages or the BO. A new pair (BGRA/l10r swap, HDR toggle, mode change), the switch file removed, a fault or a timeout all end direct mode the same way: drain (an empty submit's fence, 1 s limit), copy each slot back onto its pages, then `release`. `release` flips HUBP0 back to console A and verifies it, then rebinds the PTEs, and only then are the references dropped. A process exit takes the existing `scanRelease` on client close. The kext's watchdog restores the console if `debug.phxscan_direct=0` is set while a slot is bound. |

**Linux functions mirrored.** The flip is today's three writes (`scanFlipLocked`: `FLIP_CONTROL`,
`PRIMARY_SURFACE_ADDRESS_HIGH`, `PRIMARY_SURFACE_ADDRESS`), a subset of `hubp3_program_surface_flip_and_addr`. Under
ODM 2:1 it also writes HUBPREQ1, as since b131. The latch and the writable test follow `hubp2_is_flip_pending` and
`dc_plane_get_status` / `dcn10_update_pending_status`.

**hw-safety-reviewer.**
1. First pass, on the first two commits: "OK with changes", no hardware hazard. The changes:
   - HUBP1 in the flip test under ODM;
   - HUBP1's TMZ, DCC and VMID;
   - the count dropped before the present;
   - no flip while a newer write runs;
   - the hmm citation.

   It also noted that `vkDeviceWaitIdle` had no limit. All of this is in `d3e7aba`.
2. Re-check: **OK**. Its notes:
   - The CHANGELOG over-claimed REUSABLE. Fixed: the copy path's REUSABLE still ignores HUBPREQ1's EARLIEST_INUSE, as
     since b131.
   - A command buffer writing both surfaces could hold itself up. Fixed in `c9d9131`: one gate per command buffer.
   - Quarantined command-buffer parts (-2) lower the counts early. Accepted: the 250 ms fallback bounds it, and it
     only affects the display.

**Kill switches.** Remove the file (the next present copies back and releases), or set `sysctl
debug.phxscan_direct=0` (the kext refuses new binds, and the watchdog gives the console back). Either way the copy
path is what runs.

**Known costs (display only).**
- While bound, the IOSurface pages are stale for CPU readers: screenshots, the flicker probe, PhxAMDFB's CPU copy, and
  the console after a watchdog restore. PhxAccel's copy into console A is already skipped while HUBP0 scans a
  GPU-present slot.
- A start may hold the first frames while the pair is found (2 s at most).
- Writes at 10-bit (l10r) go through the same slots. The format must match HUBP0's, or it stays on the copy.

**Binaries.**
- VermilionBoot b162 (b161, the XTX board gate on main, plus this). SHA-256
  `86d2c3b27ed3a2eea16c66bdd13d4c747e8c684a4b6b903ce3d4e6826f32fd9c`.
- NVMTLDriver cdhash `1c15df79e4492aebecd1fbad37fd32a434b1f551`.

Both are host builds at `d98b5f0`. Preflight passed, with the link gate informational for OpenCore kexts and its 3
symbols already on main. Tests: `scan_direct_test` 81/81, `test_scan_direct` 51/51, and the other kext and plugin
host tests pass.

**Deploy (megamind with the owner; one EFI change per boot).**
1. Boot 1: an EFI change with VermilionBoot b162 alone, `OC.prev` as the rollback, from the stage the machine boots
   (`vermilion-trust-bar1g`, BAR0 1 GiB). Check:
   - `sysctl debug.phxscan_layout` ends in `direct: switch 1, allowed 1, BAR0 1024 MiB ...`;
   - the desktop behaves as before;
   - b161's board gate passes.

   The installed plugin doesn't call selector 22, so nothing else changes.
2. Boot 2: install NVMTLDriver (the runbook's "Deploying a plugin ...": old binary to `~/vermilion-rollback/`), then
   `PHXTRUST_KEEP=1 sh scripts/build/trust.sh`, then an EFI change with only `Kexts/VermilionTrust.kext`, one boot.
   Without the switch file the plugin runs today's copy path: check that nothing changed.
3. No restart: `sudo touch /Library/GPUBundles/nvmtl/ws-direct`. WindowServer's plugin reads it within 1 s, but only the
   next WindowServer start (restart or logout) chooses direct; the plugin logs that once (section 9).

**Owner test.**
1. Desktop: the log shows `ws gpu present: direct: ...` bind lines. The `direct:` part of `sysctl
   debug.phxscan_layout` shows slots bound and binds > 0.
2. Move windows and scroll: no tearing, no flicker, no stale frame.
3. Maps fullscreen 3D, then the section 6 capture: the `present` copy+wait (0.93-1.05 ms) should be gone (unverified).
4. Screenshot (Cmd-Shift-3) of a still desktop: should be current (section 9, the idle page sync; (unverified));
   during an animation it may be older.
5. An HDR toggle and a mode change: the log shows `direct scan-out ends ... copied back`, then the copy path or a new
   bind, with no black screen.
6. `rm` the file: copy path again, desktop current.

**Rollback.**
- Remove `ws-direct`, or `sysctl debug.phxscan_direct=0`. Both apply live.
- The old NVMTLDriver from `~/vermilion-rollback/`: the kept list trusts it as `-previous`.
- `EFI/OC.prev` for the kext or trust change.

**Still unverified.**
- All of the hardware behaviour:
  - that the flip to a slot holding CoreDisplay's frame shows correctly at 1440p, at 240 Hz and with VRR;
  - the gate's wait time (expected under a vblank);
  - the bounce rate;
  - the HUBP1 path under ODM 2:1;
  - the BAR refusal not hitting any import used today (none should touch BAR pages);
  - the Maps gain.
- The plugin's handling of a WindowServer crash while bound: the kext's close path is the existing one, but it has not
  been exercised with direct slots.

## 9. Direct scan-out follow-ups (2026-11-26, branch `ownback/scanout-live-on`)

Host-tested only (`tests/plugin/test_scan_direct.c`); nothing installed. Everything this section says about hardware
behaviour is (unverified). What it starts from was seen on the XTX machine, boot of 2026-11-26 00:42: `ws-direct`
created while WindowServer ran did nothing, and after a restart with the file present both surfaces were drawn in VRAM
slots 0 and 1 with no copy.

**Switch-on is at the next WindowServer start (decided, not built live).** A first version moved the copy path to direct
at a frame boundary. The clean-up pass read these risks from the code, and the move was dropped (a real Mac has no such
toggle; direct scan-out is to be the default, so the file only matters at a start):
- the start's acquire is refused while the release's console flip is pending; with no plane loss yet that sets
  `state = -1`, GPU present off for the life of WindowServer;
- the three tries were never given back, and nothing was logged when they were used up;
- the quiet wait for no write in flight would mostly end in its 2 s fallback during an animation;
- the release replaces the last flip with the console, whose CPU copy can show a frame the GPU is still drawing;
- the kext drops the Adaptive Sync range at the release and restores it at the acquire (VRR off and on once).

Now, when `ws-direct` appears while the copy path presents and it was not there at the start, the plugin logs once
`ws-direct appeared: takes effect at the next WindowServer start` and does nothing else (`nvmtl_sd_appeared_note`).
Removing the file still ends direct at the next present (copy back, release).

**Writes that waited for a flip (16 %, 1.7 ms average).** The cause, from reading the code (the new counter is there
to confirm it on the machine), is two surfaces, not a bug: CoreDisplay's next frame is written to the surface that is
still on screen until the flip to the other one latches at the next vblank (average half a period; 1.7 ms is about
0.4 of a 240 Hz period). The gate cannot let it through (HUBP0 may still fetch it) and the bounce is no help while a
flip is pending (a second flip would replace the first). A third slot has no surface to hold: CoreDisplay draws into
two. An earlier flip is not possible: the present runs when the GPU has finished the frame. So it is left as it is;
the log line says how many of the waits found a flip still to latch at their first blocked poll (`dgatePend`). No
register write is involved.

**Stale screenshots.** The cause is the documented one (section 8, known costs): while bound, a surface's pages are not
drawn into (the GPU writes the slot), so `screencapture` read the frame from the bind. Fix in the plugin, the idle
page sync (`nvmtl_scan_sync_*`, `nvmtl_sd_sync` in `nvmtl_scan_direct.h`):
- When: nothing presented for 100 ms, no write to the surface in flight, and the surface's token changed. The token
  moves when a write to it finishes (`nvmtl_vk_scanout_write_note(sid, -1)`) or it is flipped, so a finished write
  whose present was held still counts.
- The scan-out lock is not held across the fence wait. The copy runs on its own command buffer and fence: the tick
  submits it (a bounded step) and marks the surface; the write gate holds writes to a marked surface (as for a flip to
  latch, no bounce) and reaps a finished copy on each poll; the keepalive tick and the ways out (drain, teardown) reap
  too. A present never waits for the copy.
- The pages are written under `IOSurfaceLock` (write), held from the submit to the reap, so the surface's seed moves
  when the copy is done and a reader that locks sees the old frame or the new one.
- The surface is clean only after a successful copy, and only at the token the copy started with: a write that
  finished meanwhile keeps it dirty. A failed copy is retried at the next tick (the log line is limited to four).
- The keepalive ticks four times a second only while direct is bound, once a second otherwise (as before).
- A screenshot of a still desktop is current within about 350 ms. One taken during an animation can still read an
  older frame (not fixed). Counted as `idle syncs` in the 3000-present line. Whether holding the IOSurface lock in
  WindowServer's own process across the copy upsets anything is (unverified).
