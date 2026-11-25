<!-- SPDX-License-Identifier: MIT -->

# Apple's AMD stack vs ours: what a Mac user can see (2026-11-25)

Goal: every visible difference between how our RX 7900 XTX stack presents itself and how Apple's own AMD driver stack
(RDNA 2, the newest AMD GPUs Apple supports) presents itself becomes a parity item. Read-only research on the XTX
machine (macOS 26.7.1 25G241, VermilionBoot b160, VermilionAudio 1.7.2). Nothing was installed,
loaded or restarted; no GPU work ran.

## How it was checked, and the limits

| Source | Used for | Strength |
|---|---|---|
| `Info.plist` files of Apple's AMD kexts and bundles in `/System/Library/Extensions` (key names and short values only) | What Apple's personalities match and publish | Verified on this machine |
| `kmutil showloaded --list-only` | Which Apple pieces are loaded here | Verified |
| `ioreg -l -w0` of the live stack (dump kept outside git: it holds serials) | What we publish | Verified |
| `system_profiler SPDisplaysDataType` (text and JSON), `SPAudioDataType` | What System Information shows | Verified |
| `tools/metaltest/mtlq.m`, a read-only Metal query (`MTLCopyAllDevices`, property getters; no queue, buffer or pipeline) | What our Metal device answers | Verified |
| Apple's Metal Feature Set Tables PDF, dated 2026-10-23 (text extracted with PDFKit) | Reference for Metal answers | Verified (see row M10) |
| Public ioreg dumps of older AMD Macs (the Chockenberry gist), Apple's PerformanceStatistics glossary | Runtime keys a real AMD Mac publishes | Older GPU generations, so `(public)` |

**There is no RDNA 2 Mac here, so Apple's runtime values (what ioreg shows once its kext runs, what Activity Monitor
reads) are not measured.** They come from the plists (what the kext is built to publish) and public sources, and every
such cell is tagged `(public)` or `(unverified)`. The comparison reference closest to our machine is Apple's 2019
tower Mac with an MPX module (RX 6800-class Navi 21); our SMBIOS identity is the same model.

Rule 6: no Apple code or disassembly is quoted. Plist content is limited to key names and short values. The kexts'
binaries and the kernel collection were not disassembled. Strings from the collection were not usable as key names (the
runtime keys are not stored as plain strings), so no runtime key name below rests on them.

## What Apple ships for AMD on this system

- **Navi 31 (device `0x744c`) is in no Apple personality.** The `AMDRadeonX6000*` set covers Navi 10, 12, 14, 21 and 23
  (device IDs `0x7310`-`0x73ff`). Five accelerator personalities (`AMDNavi{10,12,14,21,23}GraphicsAccelerator`), five
  controller personalities, one wrangler. There is nothing to extend: the RDNA 3 presentation has to be built.
- **Apple's kexts are Info.plist stubs on disk.** `AMDRadeonX6000.kext`, `...Framebuffer.kext`, `...HWServices.kext`,
  `AMDSupport.kext` have no `Contents/MacOS`; the code lives in `SystemKernelExtensions.kc`. Their plists, all bundle version
  7.0.1 (short version string 7.1.8, SDK 26.7): `com.apple.kext.AMDRadeonX6000`, `...Framebuffer`, `...HWServices` (with seven
  per-ASIC `HWLibs` plug-ins, X6000 to X6810), `com.apple.kext.AMDSupport`, `...AMDRadeonServiceManager` (hive and
  power services).
- **On this machine only `AMDSupport` is loaded** (from the system collection; `org.vermilion.boot` and the accelerator
  kext sit on top of it). Nothing else of Apple's AMD kernel code runs: no X6000 accelerator, framebuffer or HW
  services.
- **User-space bundles:** `AMDRadeonX6000MTLDriver.bundle` (name "AMD GFX10 Metal Driver", principal class
  `GFX10_MtlDevice`, resources: GPU counter plists and JS for Instruments, `MPSPlugin_GFX10.dict`, Tensile GEMM
  kernels), `AMDRadeonX6000GLDriver.bundle` (native OpenGL driver), `AMDRadeonX6000Shared.bundle` and
  `AMDShared.bundle` (shader-compiler runtime, a plug-in dylib), `AMDRadeonVADriver2.bundle` (video), `AMDRawCounterPlugin`.
- **Match mechanism:** accelerator and controller personalities match PCI IDs and also a property
  (`LoadAccelerator` / `LoadController`) that `AMDSupport` sets when it starts. So a two-step claim is how Apple's
  stack works too; ours differs in who sets the property (a user-space daemon, not a kext in `start`).

## Install layout

| Piece | Apple AMD (RDNA 2 Mac) | Ours | Gap | Item |
|---|---|---|---|---|
| Kernel code, bring-up | Sealed system volume, system kernel collection; one OS update replaces it | `VermilionBoot` injected by OpenCore (EFI partition); GPU powered up afterwards by `~/gpu` scripts and a launch daemon | Daemon, scripts, flag files outside the OS | B1 |
| Accelerator, framebuffer | Same collection | `VermilionAccel.kext` in `/Library/Extensions`, auxiliary collection, Allow click | Approval prompt, boot-time approval state | B3 |
| Library-validation exception | None | `VermilionTrust` in EFI, fixed AMFI offsets, 17 cdhashes | Patch plus a list to keep in step with every plugin build | B4 |
| Metal driver | `/System/Library/Extensions/AMDRadeonX6000MTLDriver.bundle` | `NVMTLDriver.bundle` in `CoreTypes.bundle/Contents/Library/PhxGPU`, reached by symlinks from `/Library/GPUBundles`; the accelerator names it by a `../../../Library/GPUBundles/NVMTLDriver` path | Non-standard location and path trick (Safari's sandbox) | A2, A5 |
| Plugin bundle identity | `com.apple.AMDRadeonX6000MTLDriver`, 7.x, principal class set | `com.nullmoth.NVMTLDriver`, 0.1, no principal class | Name, id and version a crash report or `system_profiler` shows are NullMoth's | **N7** |
| OpenGL | Native `AMDRadeonX6000GLDriver.bundle` | Apple's GL-over-Metal renderer on our Metal device, up about 2 minutes after login | Different renderer, late | B1 (A10) |
| Video decode | Accelerator publishes the codec keys; AppleGVA loads `AMDRadeonVADriver2` | `PhxVideoDecoder.bundle` in `/System/Library/Video/Plug-Ins` (system volume unsealed); no `IOGVA*` or `IODVDBundleName` key published (0 hits in ioreg) | Seal broken; the planned `PhxVA` route is not live | A6 |
| Firmware | Inside the kexts / HWLibs | Read by the daemon from `~/gpu` (rule 4: not in git) | Firmware path outside the OS | B1, release shape |
| Compiler runtime, MPS tables | In the Shared and MTL bundles | Plugin's own `air-runtime`; MPS broken in part | See M11 | A12 (not in plan) |

## Property and behaviour table

"Ours" is what the live stack answers. `(public)`: from public sources on older AMD Macs. `(unverified)`: not measured
here. Apple cells without a tag in the registry table are plist content (verified on this machine).

### Registry and kernel side

| # | Property / behaviour | Apple AMD (RDNA 2 Mac) | Ours | Gap | Parity item |
|---|---|---|---|---|---|
| K1 | Accelerator class | `AMDRadeonX6000_AMDNavi21GraphicsAccelerator` (per-ASIC class), `IOMatchCategory` `IOAccelerator` | `NMXAccel`, same match category | Class name differs. Tools that match `IOAccelerator` work; tools that key on an "AMD" class name or bundle id (`com.apple.kext.AMDRadeonX6000`) would not (unverified) | None. Rename is a rule-7 question; leave |
| K2 | Accelerator match | PCI IDs plus `IOPropertyMatch` `LoadAccelerator` (set by `AMDSupport`) | `IOPropertyMatch` `nmxgpu-claimed` (set by `mesboot claim` after the daemon) | Same shape, but the accelerator appears only after the daemon | B1 (A1) |
| K3 | Framebuffer tree | Wrangler (`IOFramebuffer` category, score 60000) -> controller (`ATIFramebuffer`) -> per-connector framebuffer | `PhxFBSquatter` (`IOFramebuffer`, 30000) -> `PhxDisplay` -> `PhxAMDFB` (1000) -> `display0` -> `AppleDisplay` | Tree shape differs; no user-visible effect found | B2 |
| K4 | AGDC / wrangler | `AppleGPUWrangler`, `AGDCPluginDisplayMetrics` `(unverified)`; an AGDC user client on the controller (plist) | Same Apple classes loaded; our `PhxDeviceControl` publishes `AppleGraphicsDeviceControlClient` (WindowServer connected) | Match | none |
| K5 | GPU power management | Power service (`AMDRadeonServiceManager`: `AMDRadeonPowerService`), PowerPlay knobs in the controller personalities (`PP_*`, `SMU_DisallowedFeatures`); AGPM / device-policy nodes `(public)` | No AGPM or device-policy node in our ioreg dump; idle power by daemon flags | Power policy owned by a script, not the OS's power manager | B1 (idle power). AGPM node is **N8** |
| K6 | Video codec keys on the accelerator | `IOGVACodec` `AMDVCN2`, `IODVDBundleName` `AMDRadeonVADriver2`, `IOGVAHEVCDecode`, `IOGVAHEVCEncode`, `IOGVAH264EncodeCapabilities` and HEVC capability dictionaries (quality/rating, supported profiles), `IOVARendererID` | None of them (0 hits for `IOGVA*`, `IODVDBundleName`, `IOVARendererID`) | AppleGVA / VideoToolbox can't learn capabilities from the registry; encode isn't advertised | A6 for decode. Encode: **N3** |
| K7 | Metal plugin keys | `MetalPluginName` = the MTL bundle, class `GFX10_MtlDevice` `(public pattern)`; `IOGLBundleName` AMD GL bundle, `IOOCDBundleName` `(public)` | `MetalPluginName` = relative path to `NVMTLDriver`, `MetalPluginClassName` `NVMTLDevice`, `IOGLBundleName` `AppleMetalOpenGLRenderer`; no `IOOCDBundleName` | NVIDIA-derived names; OpenCL bundle name absent | A2 |
| K8 | `PerformanceStatistics` utilization | `Device Utilization %` `(public)`; Activity Monitor's GPU history reads it | **No** utilization key (key list checked: only memory and wait-time counters) | No GPU history in Activity Monitor, widgets or iStat | A4 |
| K9 | `PerformanceStatistics` VRAM | `vramFreeBytes`, `inUseVidMemoryBytes`, `inUseSysMemoryBytes`, `gartSizeBytes` `(public)` | `inUseVidMemoryBytes` 44 MB, `inUseSysMemoryBytes` 0, `gartSizeBytes` 16 GiB; **no `vramFreeBytes`** | Free-VRAM readouts show nothing | A4 |
| K10 | Per-process GPU time | Accelerator clients publish `accumulatedGPUTime` / usage `(public)`; Activity Monitor's % GPU and GPU Time columns read it | Only `NMX2DContext` carries `accumulatedGPUTime` (0, WindowServer's); Metal clients (`IOAccelNMXNativeProxy`) have none | Activity Monitor can't attribute GPU time to Safari, Maps or a game | **N1** |
| K11 | Sensors | Temperature, fan, power, clock from the SMC or accelerator `(unverified; the public older-Mac dumps show none in `PerformanceStatistics`)` | None published. STATUS: "missing". `SMCProcessorAMD` is CPU-only | iStat / Stats show no GPU temperature, fan or power | **N2** |
| K12 | Accelerator capability keys | `GPUDCCDisplayable` true for Navi 12-23, `GPUTaskSingleChannel`, `IOPCITunnelCompatible` | `AccelCaps` 15, `IOAccelRevision` 2, `IOAccelDisplayPipeCapabilities`; no DCC | DCC scan-out is a bandwidth feature; compositing cost row A1 | A1 (indirect) |
| K13 | GPU recovery | `recoveryCount` in the statistics; the driver resets the engine on a hang `(public)` | Key present; recovery missing (STATUS item 7) | A stuck shader ends the session | STATUS item 7 (not in the plan) |
| K14 | PCI node | `model`, `IOName` `display`, `ATY,*` ROM properties `(public)`, `VRAM,totalMB` | `model` "AMD Radeon RX 7900 XTX", `VRAM,totalMB` 24576, `IOName` `display`; no `ATY,*` | Name and VRAM match; ROM revision absent (S4) | S4 |
| K15 | Audio device | `AppleGFXHDA` on the GPU's HDA function; engine named after the display `(unverified)` | Same Apple classes, matched by a Lilu patch for `1002:ab30`; device name/short name/manufacturer strings are placeholders (`DeviceN`, `DeviceS`, `ManufacturerName`); `System Information` > Audio lists "LG ULTRAGEAR+?" with a stray byte | Name defect visible in the Sound settings and System Information. Matching by patch, audio programmed by the daemon (~2.5 min after boot) | B1; stray byte is STATUS item 8 |
| K16 | Framebuffer properties | `IOFBConfig` modes from the controller `(unverified)` | Present (`IOFBConfig`, `IOFBTimingRange`, EDID in `phx-edid`) plus `phx-*` debug properties on `PhxBringup` and the framebuffer (about 25 keys) | Debug keys in the registry | A2 / release shape |

### System Information, About This Mac

| # | Property | Apple AMD (RDNA 2 Mac) | Ours | Gap | Parity item |
|---|---|---|---|---|---|
| S1 | Chipset model, type, bus | Name, `Type: GPU`, `Bus: PCIe`, lane width `(unverified)` | "AMD Radeon RX 7900 XTX", GPU, PCIe, x16 | Match | none |
| S2 | VRAM | e.g. "32 GB" `(unverified)` | "24 GB" (from `VRAM,totalMB`, read from the memory controller) | Match | none |
| S3 | Vendor, device, revision | `AMD (0x1002)`, device and revision IDs `(unverified)` | `0x1002`, `0x744c`, `0x00c8` | Match | none |
| S4 | ROM Revision, Slot | ROM revision from the card's Apple ROM; `Slot` on slot-based GPUs `(public, unverified for our case)` | Neither row | Rows missing. A PC card has no Apple ROM; the VBIOS version string is readable from the VBIOS tables (rule 3) | **N4** |
| S5 | Metal Support | `Metal 3` (RDNA 2 on macOS 26) `(unverified)` | `Metal 3` (`spdisplays_metal3`) | Match | none |
| S6 | Display entry | Name, resolution, "UI Looks like", depth, main, mirror, online, rotation `(unverified)` | All present for the LG at 2560x1440 @ 240 Hz. Text report's depth line reads 24-bit ARGB8888 | HDR is off (D16); depth reflects that | HDR: STATUS item 4 (not in plan). Connection type row `(unverified)` |
| S7 | Audio device | Output device named after the display, transport DisplayPort `(unverified)` | Output present, 8 channels, DisplayPort, name ends with a stray `?` | Cosmetic defect | STATUS item 8 |

### Metal device answers (our values measured by the query tool)

| # | Property | Apple AMD (RDNA 2 Mac) | Ours | Gap | Parity item |
|---|---|---|---|---|---|
| M1 | `name` | "AMD Radeon RX 6800 XT" style, no suffix `(unverified)` | "AMD Radeon RX 7900 XTX (RADV NAVI31) (NVMTL over AMD Radeon RX 7900 XTX (RADV NAVI31))" | Every app showing the GPU name (Blender, games, benchmarks, Xcode) shows the suffix | A4 |
| M2 | `recommendedMaxWorkingSetSize` | About the VRAM size `(public, unverified)` | 6144 MiB (24 GB card) | Apps size caches and models by it; 6 GiB on a 24 GB GPU | A4 (A11) |
| M3 | `maxBufferLength` | At least 256 MB by contract; AMD value `(unverified)` | 4095 MiB | Below 4 GiB; a big-model or large-texture app may refuse | A3 (check) |
| M4 | `registryID` | The accelerator's registry ID `(unverified)` | `0x1000006a4`, which is `NMXAccel`'s ID | Match | none |
| M5 | `location`, `isLowPower`, `isHeadless`, `isRemovable`, `hasUnifiedMemory` | Built-in or slot-based dGPU `(unverified)`; low power no; unified no | built-in (0), 0, 0, 0, 0 | Plausible; `location` unverified | A3 (check) |
| M6 | GPU families | Common1-3, Mac1, Mac2, Metal3; no Apple1-9; no Metal4 `(unverified)` | Common1-3, Mac1, Mac2, Metal3 yes; Apple1/7/9 no; 5002 (Metal 4) no | Match | none |
| M7 | Feature flags | Raytracing, function pointers, dynamic libraries yes; BC, 32-bit MSAA, 32-bit float filtering yes `(unverified)` | All yes; primitive motion blur no; pull-model interpolation no; programmable sample positions no; raster-order groups no | Cannot judge, see M10 | A3 |
| M8 | Argument buffers, read-write textures | Tier 2 for argument buffers on AMD `(public, unverified)`; read-write tier 2 | Argument buffers **tier 1**, read-write tier 2 | Possibly wrong tier; apps with Tier 2 paths take a slow path or refuse | A3 |
| M9 | Counters | A timestamp set and a statistics set `(public, unverified; the MTL bundle ships GFX10 statistics counter plists)` | Only `timestamp`; sampling at stage boundary no, draw/dispatch/blit yes | No GPU counters in Instruments or Xcode's GPU tools | **N6** |
| M10 | The reference for these answers | Apple's published Metal feature tables | The 2026-10-23 tables list only Apple2-Apple11 families. No Mac2, AMD or Intel column exists in them (checked: the text has no "Mac2", "AMD", "Radeon" or "Common") | A3 as written ("conformance against Apple's feature tables for an AMD Mac") has no current Apple table to check against | A3 needs another reference (**N5**) |
| M11 | MPS / Core ML kernels | `MPSPlugin_GFX10.dict` and Tensile GEMM kernel tables in the MTL bundle | Our plugin has none; MPS broken in part (the clpeak hang) | MPS and Core ML paths slow or hang | STATUS item 7 / A12 (not in plan) |
| M12 | Architecture string | AMD's name for the family `(unverified)` | `nvk_amd_radeon_rx_7900_xtx_radv_navi31_` | Leaks the plugin's origin; Xcode and `MTLArchitecture` readers see it | A2 / A4 |

## Gaps ranked by what a user sees

1. GPU name in every app and the Metal log (M1; A4, **covered**).
2. Activity Monitor: no GPU history (K8; A4, **covered**) and no per-process GPU time (K10; **new N1**).
3. The 6 GiB working set on a 24 GB GPU (M2; A4, **covered**); `maxBufferLength` under 4 GiB (M3; A3 check).
4. Boot: picker, verbose text, no Apple logo (B6, **covered**); GPU power-up and desktop by a daemon, Metal, OpenGL and
   audio minutes after login (K2, K15; B1, **covered**).
5. The Allow click for `VermilionAccel` (B3, **covered**).
6. No GPU temperature, fan or power in iStat / Stats (K11; **new N2**).
7. No hardware video encode, and no H.264 or VP9 decode (K6; STATUS M, phase 3; **new N3** in the plan).
8. System volume unsealed for the video decoder; the registry doesn't advertise codecs (K6; A6, **covered**).
9. Display audio name with a stray byte, placeholder device strings (K15, S7; STATUS item 8, **covered**, not in the plan).
10. Metal argument buffers tier and other feature answers, with no current Apple table to check against (M8, M10;
    A3 **covered**, reference problem **new N5**).
11. No GPU counters / Instruments / Xcode GPU tools (M9; **new N6**).
12. MPS and Core ML kernel tables missing, hang in `clpeak` (M11; STATUS item 7, **not in the plan**).
13. GPU hang recovery (K13; STATUS item 7, **not in the plan**).
14. System Information has no ROM Revision / Slot rows (S4; **new N4**).
15. Plugin bundle identity and architecture string show NullMoth's name and `nvk_` (M12, install layout; A2 for the
    release build, bundle id and version **new N7**).

Not in the top 15, covered: OpenGL late and over Metal (B1), WebGL cache (A5), compositing speed (A1), library
validation patch (B4), mode setting from replayed captures (B2), warm restart (B5). AGPM-style power policy: **new N8**.

## New items (not in `PLAN-parity-week.md`)

| # | Item | What a Mac does | Fix | Size | Boots | Owner test |
|---|---|---|---|---|---|---|
| N1 | Per-client GPU time (K10) | Every GPU client carries `accumulatedGPUTime` / usage; Activity Monitor's GPU columns fill | Account submission time per client in `NMXAccel` and publish it on each native proxy | M | 1 (kext) | Activity Monitor % GPU while Maps renders |
| N2 | GPU sensors (K11) | Temperature, fan, power, clocks visible to monitors | Publish SMU metrics already read for the daemon (read-only, hw-safety review of anything new) to `PerformanceStatistics` and the sensor interface | M | 1 (kext) | iStat shows GPU temperature and power |
| N3 | Hardware encode and codec keys (K6) | Accelerator advertises H.264 and HEVC encode; VideoToolbox, QuickTime, FaceTime and screen recording use VCN | Publish the `IOGVA*` keys; VCN encode through Vulkan Video or the kernel (hw-safety); decode H.264, VP9 | L | several | Export a video, record the screen |
| N4 | ROM revision and slot rows (S4) | System Information shows ROM Revision | Read the VBIOS version string (VBIOS tables, rule 3) and publish it with the PCI properties `system_profiler` reads | S | 1 | System Information > Graphics |
| N5 | Metal answers reference (M10) | Answers match the real GPU family | Apple's 2026 tables have no Mac2 column. Use Apple's own AMD Metal driver as reference: the plist and bundle resources here, plus a 2019 tower Mac with an RDNA 2 MPX module, `MTLDevice` dump if the owner can supply one (the query tool is `tools/metaltest/mtlq.m`) | S | 0 | none |
| N6 | GPU counters (M9) | A statistics counter set; Instruments and Xcode GPU tools work | Counter sets from RADV performance counters; Apple's `GFX10Statistics-*` plists show the shape (names only) | L | 1+ | Instruments GPU counters |
| N7 | Plugin bundle identity (install layout) | `com.apple.*` driver id, 7.x, principal class | Own id (`org.vermilion.nvmtl`), version, `NSPrincipalClass`; remember the trust cdhash and the sandbox path | S | 1 (trust + EFI) | none |
| N8 | Power policy node (K5) | The power manager owns GPU states | Check what a 2019 tower Mac with an MPX module publishes (`AGPM`, device policy), then publish the equivalent from the kext when DPM moves in | M | with B1 | none |

Items in STATUS but not in the plan, seen again here: GPU hang recovery (item 7), HDR (item 4), display sleep (item 6),
replug (item 5), DDC/CI (item 9). They are phase 2, so they are outside the "not standard" rows of the plan. They show up in
the user-visible list above and should keep their STATUS order.

## Reproduce

- `python3 -I` over each `Info.plist` with `plistlib` (the script prints key names and scalar values; dictionaries as key lists).
- `ioreg -l -w0 > <scratch>`, then grep the accelerator, framebuffer and HDA subtrees. The dump holds serials: keep it out of git.
- `system_profiler SPDisplaysDataType -json`. Its display block carries the monitor's serial: not copied here.
- The Metal query: `xcrun clang -arch x86_64 -fobjc-arc -O0 -Wno-deprecated-declarations -o mtlq tools/metaltest/mtlq.m -framework Foundation -framework Metal`
  (the build line in the file's header). It calls
  `MTLCopyAllDevices`, reads properties and `supportsFamily:` / `supportsCounterSampling:`; no queue, no buffer.
  (The checked-in `tools/metaltest/apiprobe.m` does similar work but also opens CGL, OpenCL and Core Image contexts, which
  this research left out.)
- Apple's Metal Feature Set Tables PDF, text extracted with PDFKit; searched for `Mac2`, `AMD`, `Intel`, `Radeon`, `Common`.

## Not covered (needs a real RDNA 2 Mac or the owner)

- Apple's runtime registry for the X6000 stack, its `PerformanceStatistics` key list, the Metal answers of a Navi 21,
  the GL renderer strings and the About This Mac text. An owner-supplied `ioreg -r -c IOAccelerator -w0`, the output of
  `mtlq` and `system_profiler SPDisplaysDataType` from a 2019 tower Mac with a W6800X would turn every `(public)` and
  `(unverified)` cell above into a measured one.
- Our OpenGL renderer strings and OpenCL device (need CGL / OpenCL contexts: left out as GPU work).
