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
