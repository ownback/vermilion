<!-- SPDX-License-Identifier: MIT -->

# Plugin crashes: root causes (Phase 2 item 2, 2026-11-25)

Rows A7 (Music), A8 (Maps) and A6 (nil command buffer) of the [accel audit](2026-11-24-audit-accel.md). Read-only
research on the XTX machine (macOS 26.7.1 25G241). Sources: the crash reports in `~/Library/Logs/DiagnosticReports`
and `/Library/Logs/DiagnosticReports`, `log show`, and `otool` on the installed plugin. The installed plugin is
`NVMTLDriver` UUID `B42521DC` (cdhash `344c621f`), in
`/System/Library/CoreServices/CoreTypes.bundle/Contents/Library/PhxGPU/`, which `/Library/GPUBundles` links to. No
dSYM exists for it. Its symbols are not stripped, so the frames were matched to source by disassembling the installed
binary. Line numbers are `fork/main` at `0368354`. The functions involved have the same shape in the installed build
(checked in the disassembly). No app was opened and nothing was installed. No Music or Maps crash is newer than the
ones below.

## 1. Music: `nvmtl_vk_image_read` writes into memory freed during the GPU wait (A7)

**Reports:** `Music-2026-11-24-184731.ips`, `Music-2026-11-24-193227.ips`. Both show `EXC_BAD_ACCESS` /
`KERN_INVALID_ADDRESS` on the `nvmtl.execution` queue:

```
_platform_memmove < nvmtl_vk_image_read+736 < -[NVMTLTexture nvmtlSurfaceOutDirtied:]+1169
  < -[NVMTLCommandBuffer(EventSubmission) nvmtlAdvancePart]+1260 < __nvmtl_pump_buffers_block_invoke_2
```

**What the registers say** (both reports alike):

- The return address `+0x30070` is the first `memcpy` of the row loop in `nvmtl_vk_image_read`
  (`src/metal-plugin/nvmtl_vk.c:6604`). The compiler unrolled the loop by two.
- `rbx` = 0 is the row counter, `r13` = the destination row, `r15` = 2400 B per row.
- The fault address equals `r13` (`0x1583ac000`, `0x14e520000`). It is page-aligned and "not in any region". The
  previous region is a 128 KiB "CoreMedia memory pool" in the first report and an 84 KiB read-only "mapped file" in the
  second. Then comes a gap of 2.6 MiB and 2 MiB, enough for a 1.44 MB plane.
- So the copy failed on its **first byte, row 0**. The whole destination plane was gone when the CPU wrote it.
- The surface is 600x600 BGRA with 2400 B rows: Music's album artwork. The log names the same size for the surfaces
  that Music reads back.

**Why the guard didn't stop it.** `nvmtl_plane_mapped` (`NVMTLObjects.m:1341`) is called with `VM_PROT_WRITE` at
`NVMTLObjects.m:1454`, after `IOSurfaceLock`. The installed binary calls it at `+0x2fb21` with `ecx = 2` and branches
past `nvmtl_vk_image_read` when it returns NO. Here it returned YES: the plane was mapped and writable when it was
checked. Between the check and the copy, `nvmtl_vk_image_read` does the following:

- finishes any pending upload;
- takes a staging buffer;
- records a layout barrier and `vkCmdCopyImageToBuffer`;
- submits and **waits for the GPU**.

Today's surface-outs in Music took 0.26-1.13 ms (log, 19:28-19:32). In that window another thread in Music freed the
memory, and the CPU copy ran into the hole. The guard is a check-then-use: it can narrow the window but never close
it, because the memory belongs to another framework and can go at any moment, even in the middle of the copy loop.

The same process had already logged the guard's other outcome 18 s before the first crash:
`G13 surface 129 plane 0 NOT synced: readback 600x600 bpp 4, 600 rows of 2400 B from 0x14f5e0000; 0x14f5e0000 is not
mapped in this process`. On 2026-11-23 the plane was gone before the check, and the guard caught it. On 2026-11-24 it
went during the GPU wait. So PROJECT_KNOWLEDGE's "Music crash fixed (plugin `33b9a186`)" covers only the first case.

**Why the CPU copies at all.** The 2400 B pitch is not a multiple of RADV's 256 B linear pitch alignment, so
`nvmtl_vk_surface_pitch_ok` (`nvmtl_pitch_align.c:57`, called from `NVMTLDevice.m:1073`) refuses the host import. The
surface becomes a private image. Its pixels then go in and out through the CPU at the IOSurface's base address in the
app (`nvmtlSurfaceIn` / `nvmtlSurfaceOutDirtied:`). The surface-out runs after the GPU part completes and before the
command buffer reports completion (`NVMTLEventSync.m:796-804`).

**Whose memory it is** *(unverified)*: the neighbouring regions are CoreMedia's and ImageIO's, not "IOSurface"
regions. The plugin's texture holds a retain on the IOSurface (`NVMTLDevice.m:1275`), and an IOSurface's own mapping
stays as long as the surface lives. So the leading explanation, as on 2026-11-23, is an IOSurface built around another
framework's memory, which that framework frees on its own schedule. Not proven: no allocation history was recorded.

**On a real AMD Mac** the driver never touches the IOSurface's user address. The GPU reads and writes the surface's
pages through the kernel's handle on its memory, so a freed user mapping can't fault anything. Metal's contract: a
texture made with `newTextureWithDescriptor:iosurface:plane:` aliases the surface's memory, and a GPU write lands in
the surface when the command buffer completes. No CPU step exists that could fault.

**Proposed fix**

1. **Stop the crash (S).** Make the write fault-proof:
   - check the mapping again right before the copy, inside `nvmtl_vk_image_read` after the GPU wait;
   - write with a kernel-mediated copy (`mach_vm_write` / `mach_vm_copy` into our own task), which returns
     `KERN_INVALID_ADDRESS` instead of raising SIGSEGV; one call per plane when the rows are packed (2400 = 600 x 4
     here), else one per row.

   A destination that has vanished should count as published-and-dropped (logged), not fail the command buffer.
   Today a refused surface-out finishes the command buffer with "Could not publish event segment writes"
   (`NVMTLEventSync.m:803-808`). Apple's driver would complete it normally.

   Risk: low. It touches only the copy path. Cost *(unverified)*: the kernel copy may be slower than `memcpy` for
   1.44 MB; measure it on the readback path before shipping.
2. **Do it as Apple does (M, TODO 01 "Music's skipped readbacks").** No CPU copy through the app's address:
   - Import the IOSurface's pages into the GPU's address space when the texture is made, while they are mapped, and
     keep them referenced for the texture's life. Better: have the kext take them by IOSurface ID, from the surface's
     own memory, with no dependence on the process's mapping.
   - For pitches RADV can't alias (2400 B), keep the private image. Write it back with a GPU copy
     (`vkCmdCopyImageToBuffer`, `bufferRowLength` 600) into the imported pages, at the end of the command buffer that
     wrote it.
   - The multi-plane path already does this in one direction (`_planeHost`, `NVMTLDevice.m:1055-1058`, filled by
     `nvmtl_surface_in_for_cb`). Extend it to single-plane surfaces with an unaligned pitch, both ways.

   Risk: medium. It needs page pinning and memory accounting for pages the app has freed, and the base must be on the
   import alignment. It touches the GPU VM mapping in the kext (existing import path, no new register writes).
   Test: Music, "Drake - Jaded" and a scroll through the album grid, with no "NOT synced" lines and the art drawn.

## 2. Maps: `newTexture` gets nil and VectorKit aborts (A8)

**Reports:** five, all on 2026-11-23 (07:37:42, 07:37:50, 08:08:58, 17:46:26 x2). Each is `SIGABRT` on the main thread
in `ggl::MetalResourceManager::newTexture(ggl::Texture const*)+1381` (`abort_with_reason`), reached from
`MetalResourceManager::upload(Texture2DLoadItem)` (one report) or `prepareTexture` (four), inside
`MetalRenderer::frame`. The Fault-level log line just before each is `(VectorKit) Metal returned null texture.`
Maps had run 8-50 s each time, so the device worked and earlier textures had been made. The first three reports ran
plugin `5366c3b1`, the last two the installed `B42521DC`. Maps hasn't been tried since 2026-11-23 17:46.

**Root cause: not established.** No plugin log exists for any of the Maps runs:

- `log show` for Maps has no `NVMTL` line at all in those windows, not even the device creation lines that every other
  process logs;
- `/tmp/nvmtl.log` is out of Maps' sandbox, and the fallback, the container's `tmp/nvmtl.log`, is empty now (other
  apps' containers have one).

So which descriptor was refused, and on which path, is unknown. VectorKit treats nil as fatal. Metal's contract:
`newTextureWithDescriptor:` returns nil only for an invalid descriptor or when memory really can't be had, and VectorKit
picks its formats from the device's feature answers. On a real AMD Mac those textures exist.

**Every way the plugin's texture creation returns nil** (`NVMTLDevice.m:877-920`; heap and buffer textures
have their own paths, `NVMTLObjects.m:866`):

| Path | Line | Logged? | Fits Maps? |
|---|---|---|---|
| `nvmtl_alloc_blocked()`: after 32 failed allocations in a row, **every** texture and buffer is nil for 250 ms | `NVMTLDevice.m:887`, `:117-126` | only the "ALLOCATION FAILING" summary | best candidate *(unverified)*: map tiles allocate in bursts, and the kext's pools are constants (6 GiB / 2 GiB, row A3) |
| `nvmtl_vk_image_create_typed` refused (a format, type and usage combination RADV won't make) | `:912`, `:910` | "newTextureWithDescriptor: FAILED" | possible |
| pixel format not in `nvmtl_pixfmt` | `:904`, table `:739-815` | once per format | possible: e.g. `GBGR422` / `BGRG422` are missing, and Mac2 GPUs have them *(from Apple's feature tables, unverified)* |
| depth texture refused | `:896-898` | yes | unlikely |
| texture-buffer type with texel buffers off | `:882-883` | yes | unlikely |
| Vulkan down (`nvmtl_vk_init`) | `:878` | no | unlikely (frames were drawn first) |

**Proposed fix**

1. **Make the plugin log reach every process (S).** Use `os_log` instead of `syslog()` plus a file (`nvlog`,
   `NVMTLDevice.m:100-114`). Every nil texture logs its descriptor (type, format, size, mips, array, usage, storage
   mode) and its path. Risk: none to behaviour, only log volume.
2. **Then reproduce once** (below) and fix the path it names. Whatever it is, the fix is the Metal contract: nil only
   for an invalid descriptor. For memory pressure, evict, fall back to system memory or wait, as macOS's GPU memory
   manager does; never fail a whole 250 ms window. That ties in with sizing the pools from the hardware (row A3,
   item 8). Risk: medium if it is the allocation path (memory accounting), low for a missing format.

**Reproduction wanted (needs the megamind's OK):** with plugin logging reachable (fix 1 installed, or the current build
as is):

1. Open Maps, pan and zoom over a city in Explore, then switch to Satellite and 3D, until it crashes or 2 minutes pass.
2. Right after:
   - `cp ~/Library/Containers/com.apple.Maps/Data/tmp/nvmtl.log ~/maps-nvmtl.log`;
   - `log show --last 5m --predicate 'process == "Maps"' > ~/maps-log.txt`;
   - note the new `Maps-*.ips`.

It is a GPU load only as large as normal Maps use (no benchmark).

## 3. WindowServer gets a nil command buffer (A6)

**Report:** `/Library/Logs/DiagnosticReports/WindowServer-2026-11-24-075530.ips`, the crash after the AppleGFXHDA hot
reset at 07:55 (finding `2026-11-24-gfxhda-detach-gpu-hot-reset.md`). It shows `EXC_BAD_ACCESS` in the stack guard of
the main thread:

```
nvlog < nvmtl_vk_cmd_begin+125 < -[NVMTLCommandQueue commandBuffer]+380
  < MetalContext::RenderCommandBuffer < MetalContext::RenderEncoder < MetalContext::SetScissor
  < MetalContext::RenderEncoder < MetalContext::SetScissor < ... (repeats) < MetalContext::SetPipelineState
  < MetalTiledBacking::RenderToDestination < CompositorMetal::composite < ... < CGXUpdateDisplay
```

The WindowServer started at 07:55:24 already logged `vk: dummy zero-fill did not complete — vkWaitForFences -> 2`
(07:55:26): the GPU wasn't completing work. Its backend was then disabled (audit row 6). From then on every
`-commandBuffer` returned nil. SkyLight doesn't check for nil: `RenderEncoder` gets nil, `SetScissor` asks for the
encoder again, and the two recurse until the stack overflows. The next WindowServer hung, and the watchdog report
(`WindowServer-2026-11-24-075611.ips`) followed.

**Every nil from command-buffer creation:**

| Where | Line | When |
|---|---|---|
| `-[NVMTLCommandQueue commandBuffer]`, `nvmtl_vk_cmd_begin` fails | `NVMTLObjects.m:5640-5647` | the backend is down (`g_state = -1`: a failed submit `nvmtl_vk.c:6093`, a failed fence wait `:6139`, a missing completion witness `:6145`; never transient, so no retry), or a pool, allocation or begin refusal still failing after 40 retries (~1 s, `nvmtl_vk.c:4978-4990`) |
| same, `[NVMTLCommandBuffer new]` nil | `NVMTLObjects.m:5632` | out of memory only |
| `commandBufferWithUnretainedReferences`, `commandBufferWithDescriptor:` | `NVMTLObjects.m:5650-5651` | forward to the above |
| `-newCommandQueue` / `newCommandQueueWithMaxCommandBufferCount:` | `NVMTLDevice.m:666`, `:670` | backend down, or no command pool: a nil queue, so every later command buffer is nil |
| encoder SPI `-commandBuffer` of a parallel sub-encoder | `NVMTLObjects.m:5860` | its owner is gone |

The encoders themselves never return nil (`NVMTLObjects.m:5367-5540`). The plugin's own internal users
(`NVMTLObjects.m:853`, `:1218`, `:3862`) message a possible nil and drop the work silently.

**Metal's contract and a real Mac.** `-[MTLCommandQueue commandBuffer]` doesn't fail on a working device. At
`maxCommandBufferCount` it blocks until one is free, which the plugin's semaphore already does (`NVMTLObjects.m:5626-5630`).
When the GPU hangs on an AMD Mac, the kernel restarts the GPU. The command buffers in flight complete with
`MTLCommandBufferStatusError` (e.g. `MTLCommandBufferErrorTimeout`), new ones work, and the desktop stays. When the
device really goes away, the command buffers complete with `MTLCommandBufferErrorDeviceRemoved` *(error codes from
Apple's documentation; AMD-Mac behaviour not checked here)*. WindowServer is written for errored command buffers, not
for nil. CoreDisplay asserts "Failed to get a MTLCommandBuffer" (the 2026-10-26 login crashes, `nvmtl_vk.c:4973`), and
SkyLight recurses.

**Proposed fix**

1. **Never return nil (S-M):**
   - A transient refusal waits and retries without a limit (with backoff), the same way the queue already blocks on
     capacity.
   - With the backend down, `-commandBuffer` returns a **dead command buffer**: a real `NVMTLCommandBuffer` whose
     encoders record nothing, whose `commit` completes it at once with `MTLCommandBufferStatusError` and an
     `MTLCommandBufferErrorDeviceRemoved` error, and which runs its scheduled and completed handlers and wakes
     `waitUntilCompleted`.
   - `newCommandQueue` with the backend down returns a queue that hands out dead command buffers.
   - The internal users get the same objects, so they no longer drop work silently.

   Risk: WindowServer may then spin, drawing into errored command buffers on a dead GPU (a frozen desktop instead of a
   crash). That is no worse than today, where the next WindowServer hangs anyway, but it doesn't bring the desktop
   back.
2. **Recover (L, Phase 2 item 7).** With the kext's GPU recovery (per-submission timeout and amdgpu's Navi 31 queue
   reset, through `hw-safety-reviewer`), the plugin rebuilds its Vulkan device after a reset instead of staying at
   `g_state = -1`. Command buffers made after the recovery work again, and only those in flight error out, as on a Mac.
   Risk: high (GPU programming, hard rule 1). Fix 1 is the part that can land now.

## Summary

| Row | Faulting path | Trigger | Established? | First fix | Size |
|---|---|---|---|---|---|
| A7 Music | `nvmtl_vk.c:6604` (`memcpy` row 0) via `NVMTLObjects.m:1455` | 600x600, 2400 B-pitch artwork surface, private image; its memory freed during the GPU wait after the guard at `:1454` passed | yes (registers, binary, log) | fault-proof copy, re-check after the wait; then GPU write-back into imported pages | S, then M |
| A8 Maps | a nil from `newTextureWithDescriptor:` (`NVMTLDevice.m:877-920`) | unknown: no plugin log in Maps | no | `os_log` logging, one reproduction, then the named path | S + S-M |
| A6 nil command buffer | `NVMTLObjects.m:5640-5647` | backend disabled after the 07:55 hot reset; SkyLight recursion | yes (report, code) | dead command buffer instead of nil; unlimited retry for transient refusals | S-M |
