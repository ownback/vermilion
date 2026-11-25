<!-- SPDX-License-Identifier: MIT -->

# Maps fullscreen is slow: what the log shows, what it rules out, the capture that decides (2026-11-25)

Phase 2 item 2 follow-up. Since #29 (NVMTLDriver `327a082e`, live since the boot of 2026-11-25 17:52 on the XTX
machine, macOS 26.7.1 25G241, 2560x1440 at 240 Hz, HDR off) Apple Maps no longer crashes. The owner reports that Maps
in fullscreen is "really slow". Read-only research: the plugin's unified log for Maps (pid 33412, 18:32:23-18:37:36,
the owner's fullscreen use at 18:33:16-18:33:43), `sysctl debug.phxvm` and other named counters, and the source on
`fork/main` at `513c1aa`. Maps exited before a CPU sample could be taken, so **the dominant cost per frame is not
measured yet**. Section 5 is the capture that measures it. Raw logs stay outside git (Maps' log has places in it).

## 1. Ruled out: "VRAM placed as GTT (vis full) 150"

`debug.phxvm` read `BO create refused: vis 0 hi 0 gtt 0 handles 0 pages 0; VRAM placed as GTT (vis full) 150`. This is
accounting only. In `doBoCreate` (`src/vermilion-boot/phx_client.cpp`, b70 branch) a VRAM BO whose client's 256 MiB
"visible" budget is full gets domain 2 instead of 4. For a process that isn't in `debug.phxbo_vram_proc`, both are the
same system pages ("every BO is system memory here, so the bytes are the same"). No BO was refused in this boot, and
Maps' log has no `REFUSED`, `FAILED`, `nil` or `ALLOCATION FAILING` line. #29's pool works: 17 Private blocks for
~10200 pooled buffers at 18:32:47.

## 2. Structural: all of Maps' GPU memory is system memory

`debug.phxbo_vram_proc` is `horizon-client,java` (daemon flag `bovram`). Real VRAM (b156, b159) is given only to those
processes (`phxBoVramWanted`, `phx_vram.cpp`). For Maps, every BO is an `IOBufferMemoryDescriptor` in system memory,
which the GPU reaches over PCIe at ~44 GB/s instead of ~840 GB/s (performance record, "VRAM BOs off vs on"). That
covers:

- its render targets and depth;
- its 4x MSAA passes (`resolve-shape render pass made (... 4 samples ...)`);
- the tiled image the 2560x1440 drawable is drawn into (`surface 32 2560x1440 ... drawn TILED, copied to its pages at
  present`; the tiled image helps only when it is in VRAM);
- its textures and the #29 pool blocks.

Then WindowServer composites the 14.7 MB drawable from system memory. That costs ~2.1-2.2 ms of GPU per frame at 1440p
(Horizon, `2026-11-23-horizon-present-cost.md`). Fullscreen has 4.7x the pixels of the 1024x768 window Maps opened in.
So the fullscreen-specific part of the slowdown fits a GPU limited by PCIe (unverified: no GPU timing of Maps exists).
On Horizon, the same placement cost 1.7-1.9x of the frame rate.

## 3. Per-second work in the plugin while the owner panned (from the log's counters)

| What | Rate in Maps (18:33:09-18:33:43) | Where | Cost per item |
|---|---|---|---|
| `newBufferWithLength:` Managed (16-798 B) | ~30000/s (counter 307200 at :14.6 to 614400 at :24.0); 1.25 M in 85 s | `NVMTLDevice.m` `newBufferWithLength:options:`: a pooled VRAM-copy range, a pooled shadow range, a GPU zero fill, objc objects, `nvlog`'s global mutex | not timed |
| Managed uploads carried by submit prologues | ~28000/s (1556667 to 1983164 at :23.3 to :38.4) | `nvmtl_vk_pre_copy`, one `vkCmdCopyBuffer` each | GPU: a tiny copy each, behind one barrier per prologue |
| GPU zero fills in prologues | ~23000/s (571581 to 922806) | `nvmtl_vk_pre_fill` | the Managed VRAM copy cleared, then overwritten by its upload |
| VideoToolbox transfers (YUV tiles to RGB) | ~255/s surface-in and ~255/s surface-out (submit census: 2431 to 6598 at :14.7 to :30.9) | `nvmtlSurfaceIn` (CPU copy of each plane), `nvmtl_vk_image_read` (a waited GPU submit, then a CPU copy) | 0.11-2.48 ms per surface-out (log) |
| New `MTLCommandQueue` plus a new `VTMTSComputeFunction` pipeline | ~56/s (4096 of each by 18:33:36) | VideoToolbox's transfer session; `newComputePipelineStateWithFunction:` (94 KB of SPIR-V, cache hits) | consecutive creations ~1 ms apart in the log |
| `newSamplerStateWithDescriptor:` | ~1250/s (16384 at :20.1 to 45056 at :43.2) | a new `VkSampler` each (`nvmtl_vk_sampler_create_desc`, no cache) | small |
| Submissions | ~760/s | | |

Two points about the threads:

- **Maps' main thread (`1ace7`)** makes the buffers, so their cost goes straight into Maps' frame time.
- **`nvmtl.execution`, the plugin's single serial worker per process** (`NVMTLEventSync.m`, `nvmtl_pump_buffers`), runs
  each tile's surface-out, `nvmtl_vk_image_read`. That is a submit and a fence wait on the same in-order queue as
  Maps' frames, plus a CPU copy, before the worker can retire the next command buffer and publish its drawable.

Whether this serialisation delays presents depends on how full the queue is. It is not measured.

Each of these is a real cost that a Mac doesn't have. AMD Macs suballocate small buffers, keep Managed copies with
DMA, run VideoToolbox's transfers on the GPU with no CPU round trip, and cache samplers. Which of them matters at
240 Hz isn't known without a sample.

## 4. What each outcome means, and the fix as Apple's driver would do it

| The capture shows | Cause | Fix (Apple-like) | Where, size |
|---|---|---|---|
| GPU busy (SMU activity high), few frames shown, Maps' CPU low; better with Maps' BOs in VRAM (run 3) | section 2: system-memory render targets and composite | VRAM BOs for every process by default (TODO performance item 3, M3: the clear first, then the default); drawables and WindowServer surfaces in VRAM (item 2) | kext + daemon, M; `hw-safety-reviewer` (VM map, VRAM clear) |
| Maps' main thread busy in `newBufferWithLength:` / `nvmtl_zero_new_buffer` / pool or `nvlog` frames | section 3, buffer creation | a lock-free per-size free list for pooled Managed ranges; no GPU zero fill for a Managed VRAM copy whose whole range is uploaded before first use (the upload overwrites it); `nvlog`'s drop check without the global mutex | plugin, S-M |
| `nvmtl.execution` mostly in `vkWaitForFences` under `nvmtl_vk_image_read` / `nvmtlSurfaceOut` | section 3, tile readbacks serialise presents | write the private image back with a GPU copy into the surface's imported pages in the command buffer that wrote it, with no CPU wait (#23, Music fix 2); until then at least not on the worker that publishes drawables | plugin + kext import, M |
| WindowServer's CPU or GPU time dominates | composite | TODO performance item 1 (one copy per frame, or the fullscreen app's frame straight to the display) | plugin, M |

Nothing is implemented on this branch: no single cause is proven, and the likeliest one is in the kext's placement
policy (item 3), not in the plugin.

## 5. The capture (read-only; it needs the owner with Maps open)

Tool: `tools/validation/appcapture.sh` (this branch). It records:

- every second: frames WindowServer showed (`debug.nvaccel_iop_ok`) and the CPU time of Maps and WindowServer;
- a 1 ms CPU `sample` of Maps and of WindowServer;
- the plugin's log;
- named kext counters before and after;
- the SMU's GPU activity and clocks (`~/gpu/smumetrics.py`);
- optionally (`GPUTIME=1`) GPU time per process (`debug.phxgpu_time_on`, b157). It adds two timestamp packets per
  submission while on, so it isn't a pure read: the megamind decides.

It was checked against Finder for 6 s (SMU off).

Runs, each 20 s, the owner panning and zooming over a city the whole time:

1. Maps in a normal window: `sudo bash tools/validation/appcapture.sh Maps window 20`.
2. Maps fullscreen: `sudo bash tools/validation/appcapture.sh Maps fullscreen 20`.
3. (Megamind's call: it changes where Maps' new BOs are placed. Same b156-b160 path as Horizon, self-test passed this
   boot.) `sudo sysctl debug.phxbo_vram_proc=horizon-client,java,Maps`, quit and reopen Maps, fullscreen:
   `sudo bash tools/validation/appcapture.sh Maps fullscreen-vram 20`. Then quit Maps and
   `sudo sysctl debug.phxbo_vram_proc=horizon-client,java`.

Also ask the owner: is "slow" a low frame rate while panning, input lag, or tiles that take long to appear?
Output: `~/vermilion-captures/<date>-appcap/<label>-<time>/summary.txt` (plus the samples). The GPU load is normal
Maps use, no benchmark.

## 6. Smaller things seen

- `nvlog` limits every call site to 8 lines, then every 4096th. The census lines that are already emitted once per
  4096 events (`buffer census`, `submit census`) are therefore limited twice. After their eighth line only one in 4096
  reaches the log: Maps' last `buffer census` is from 18:32:47. A log-quality fix (S), no behaviour change.
- WindowServer used ~20-25 % of a core on a quiet desktop during the tool check (18:44, 30-60 frames shown per
  second). Earlier record: 123-127 ms/s on 2026-11-22. Not looked into.
- During this research, `sysctl -a` read every `debug.*` OID once (18:36). Of the two OIDs that act when read,
  `debug.phxedid` refused (root only, it was not root). `debug.phxshot` read the scanned-out frame through BAR0
  (register reads and a CPU read of VRAM, no write). The display stayed normal. Read named OIDs only from now on
  (perflog.sh's rule).

## 7. Unverified

Everything about which cost dominates. The ~2.2 ms composite is Horizon's figure, not Maps'. The rates in section 3
come from log counters over ~10-15 s windows, not a profiler.
