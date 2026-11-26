<!-- SPDX-License-Identifier: MIT -->

# T1: does the first WindowServer adopt a Metal device that appears late? (REA, 2026-11-26)

Item T1 of the B1 design ([2026-11-26-kernel-bringup-design.md](2026-11-26-kernel-bringup-design.md), section 3 "T1"
and section 5, risk 1). Read-only static analysis with REA (Ghidra 12.2 through the REA MCP) of the XTX machine's own
binaries, macOS 26.7.1 (25G241), x86_64h dyld shared cache, extracted with `ipsw` into the scratchpad: `SkyLight`
(WindowServer's code), `Metal`, `CoreDisplay`, `GPUWrangler`, `IOAccelerator`. Nothing was run, loaded, restarted or
written outside the worktree and the scratchpad. Addresses are the shared-cache addresses of those images (25G241
only). Nothing here was tested on hardware (unverified).

Strength tags: **[O]** observed in decompiled code or strings of the shipped binary, or in this repo's source;
**[I]** inferred from [O] facts; **[R]** recorded in this repo by earlier hardware work (not re-tested); **[U]**
unverified.

## Answer

**Probably not, as T1 is currently written (skip `killall WindowServer`, nothing else). Confidence about 70% that the
first WindowServer stays in software compositing.** The design's lead (SkyLight's `MTLCopyAllDevicesWithObserver`)
does not hold, but Metal itself does pick up a late device:

- SkyLight's `MTLCopyAllDevicesWithObserver` is only a *removal* workaround, and on this macOS it is not armed (1). It
  never adopts a device that was added.
- Metal keeps a live device array. A Metal device that appears later (Vermilion's `NVMTLDevice`, created when
  `NMXAccel` publishes) is appended to the array in the same process, and a later `MTLCopyAllDevices` returns it (2).
  The daemon comment "Metal caches an empty device list per process" is **not** what Metal's code does.
- The blockers are two **once-only** decisions made early in the first WindowServer, plus the order of the GPUWrangler
  publish (3, 4). Each runs the first time something needs it and is never redone for that process or GPU object. If
  they run before `NMXAccel` exists, the first WindowServer keeps software compositing until it restarts.

T1 therefore passes only if those decisions happen *after* the Metal device exists. Nothing in the first
WindowServer's code makes them wait for `NMXAccel`: it waits for IOKit to go quiet, at most 60 s (3b). The claim that
creates `NMXAccel` comes at about +10 s, in a boot where IOKit is plausibly quiet earlier (not measured, 3b). The plan
below tests it cheaply and falls back to today's restart. If it fails, the log lines say which decision failed. The
next step is then a kernel-side hold that keeps the GPUWrangler publish (Apple's own gating) behind `NMXAccel`, not a
restart.

## 1. Does SkyLight register a device-added observer? No.

- [O] SkyLight imports `MTLCopyAllDevices`, `MTLCopyAllDevicesWithObserver` and **only**
  `MTLDeviceWasRemovedNotification` (`nm`). It does not import `MTLDeviceWasAddedNotification`,
  `MTLRemoveDeviceObserver` or any "added" selector. (The earlier note that SkyLight "may use the added notification"
  came from `MTLCopyAllDevicesWithObserver` being imported; the handler below shows what it is for.)
- [O] The single caller of `MTLCopyAllDevicesWithObserver` is
  `___ZL43rdar_34729318_war_init_device_notificationsv_block_invoke`
  (SkyLight `0x7ff80945229e`, call at `0x7ff8094522b0`). Its observer block (`..._block_invoke_2`, `0x7ff8094522bf`)
  compares the notification name with a global string, takes the device's `registryID` and schedules
  `rdar_34729318_war_local_callback` (`0x7ff80945233a`), which calls `process_accelerator_removal`
  (`0x7ff8093a589d`). That function looks the accelerator up in the compositor map, calls the compositor's virtual
  teardown (vtable `+0xc8`, `+0x18`), clears the shadow cache and erases the map entry. It is teardown only.
  [I] The global string is the one imported name, `MTLDeviceWasRemovedNotification`; the comparison target was not
  resolved.
- [O] It is a workaround, and conditional. `init_egpu_removal_notifications` (`0x7ff809452164`) `dlopen`s CoreDisplay
  and `dlsym`s `CoreDisplay_Display_GetAcceleratorRegistryID`. If that symbol exists (it does in 25G241 CoreDisplay,
  `0x7ff80538628e`) and CoreDisplay exports `ReportsSLXServerGPUAddedRemovedNotifications` = 1, SkyLight registers a
  WindowServer notification callback `egpu_ws_notification_callback` for type `0x712` (GPU added/removed reported by
  CoreDisplay's GPUWrangler client) and never calls the Metal observer. Only when the symbol is missing does it take
  the `rdar_34729318` path. [I] On Tahoe the observer is not armed.
- [O] `init_egpu_removal_notifications` itself is a `dispatch_once` run from `CompositorMetal::new_compositor`
  (`0x7ff809451324`), that is, only when a Metal compositor is first built.
- [O] No SkyLight code path "adopts a new device for compositing" from a notification. The eGPU add path is in
  CoreDisplay's GPUWrangler event handler (3c).

So the premise "SkyLight adopts a device that is added later through the Metal observer" is false. eGPU hot-plug works
through GPUWrangler events handled in CoreDisplay.

## 2. Metal: a device added later does appear

- [O] `MTLCopyAllDevices` (Metal `0x7ff80f46a632`) calls `MTLDeviceArrayInitialize()` (`0x7ff80f59790a`, once) and then
  returns a copy of the global `_deviceArray` (block `0x7ff80f471711`), under `_deviceArrayQueue`.
- [O] `MTLDeviceArrayInitialize` ends in `_MTLRegisterDevices`, which builds `MTLIOAccelServiceGlobalContext`
  (`-init`, `0x7ff80f641be6`). That context calls `IOServiceAddMatchingNotification` with `"IOServicePublish"`,
  `IOServiceMatching("IOAccelerator")` and the callback `__mtlIOAccelDeviceMatched` (kept for the life of the process)
  and walks the current iterator.
- [O] For every `IOAccelerator` service published, now or later, the chain is `__mtlIOAccelDeviceMatched`
  (`0x7ff80f641ae0`) -> `registerService:deviceClass:` (`0x7ff80f641e92`) -> `_getMetalPluginClassForService`
  (`0x7ff80f641947`). The last one reads the service's `MetalPluginName` (a string) and `MetalPluginClassName`,
  resolves the bundle with `gpu_bundle_find_trusted` (the GPUBundles trust check) and checks that the class is a
  subclass of `_MTLDevice`. Then `MTLIOAccelService initWithAcceleratorPort:deviceClass:` (`0x7ff80f6422e1`) does
  `alloc` + `initWithAcceleratorPort:` of that class and calls `MTLAddDevice` (`0x7ff80f46b3b0`).
  `___MTLAddDevice_block_invoke` (`0x7ff80f471455`) appends the device to `_deviceArray` (unless
  `_allowedDeviceArray`/`ALLOWED_GPU_IDS` excludes its `registryID`) and posts the "added" to `_mtlDeviceNotifiers`
  (the `MTLCopyAllDevicesWithObserver` clients; SkyLight has none on Tahoe).
- [O] `MTLIOAccelService init` skips a service that has a `Removable` property when `_mtlAvoidRemovable()` is on.
  `isRemovable` on the device and `GPUWranglerGPUIsRemovable` are separate.
- [I] Consequence: a process that called `MTLCopyAllDevices` early and got `[]` sees the device on a later call, as
  long as the accelerator's `IOServicePublish` happens after (or before) the context exists. Metal does not cache an
  empty list. [R] The repo's 2026-10-24 record (`src/vermilion-accel/accel/phxfb.cpp:1418-1419`: a gate inside
  `PhxAMDFB::start()` held the IOKit matching thread, a deadlock, then "Metal device never came up") fits this: the
  device depends on the publish, not on the age of the process.
- [I] The daemon comment at `tools/phxctl/phxboot-navi31.sh:869-870` ("Metal caches an empty device list per process
  ... WindowServer ... never sees our device until it restarts fresh") is therefore the wrong explanation of a real
  observation. The real causes are in 3 and 4 below. The comment should be corrected when the daemon is next changed.

## 3. What decides which device WindowServer composites on

### 3a. Which Metal device (SkyLight)

- [O] `WSGetCompositorMetal(accelerator)` (`0x7ff8093a4574`): `accelerator == 0` means "the main display's
  compositor"; otherwise it finds the accelerator in `metal_compositor_map()` (`0x7ff8093a4688`) or calls
  `CompositorMetal::new_compositor(accelerator)` (`0x7ff809451324`) and caches it on success. A failure is not cached,
  so it retries on the next call.
- [O] `new_compositor` calls `MTLCopyAllDevices()` **afresh** and picks the device whose `acceleratorPort` (selector at
  `0x7ff822ae90d8`, 32-bit) equals the accelerator argument. No match returns 0 (no Metal compositor). So the mapping
  display -> `CGXAcceleratorForDisplayDevice` -> accelerator port -> `MTLDevice.acceleratorPort` is evaluated each time
  the compositor is requested and finds a late device.
- [O] Per-accelerator events: `kCGSDisplayAcceleratorChanged` -> `displayAcceleratorChangedProc` (`0x7ff8091fbb78`)
  invalidates display info and re-posts display notifications; `CGXUpdateSurfaceAcceleratorChange`
  (`0x7ff8092fd096`) moves surfaces. `kSLXServerDisplayAcceleratorOffline/Deactivate` exist for removal.
- [O] **Gate 1, once per process.** `WSSystemCanCompositeWithMetal` (`___WSSystemCanCompositeWithMetal_block_invoke`,
  `0x7ff8094511df`, `dispatch_once`): first `WSWaitForIOKitReady` (3b), then it walks `MTLCopyAllDevices` and sets
  `metal_lovin = 1` if **any** device answers `isHeadless == NO` (selector `0x7ff822af30a5`). If none does at that
  moment, `metal_lovin` stays 0 for the life of the process. `WSGetCompositorMetal`,
  `HaveMetalCompositorForAccelerator` (`0x7ff8093a4b3d`) and `WSMetalCompositorEnabled` (`0x7ff8093a5681`) all gate on
  it.
- [O] `src/metal-plugin/NVMTLDevice.m` already reports `isHeadless` = NO only while `debug.nmxaccel_headless` reads 0
  (AMD-panel mode: `nvmtl_is_amd_panel`, `:261`; `isHeadless`, `:2112`). Gate 1 sees a non-headless device only if
  that sysctl is already 0 and the device exists when gate 1 runs.

### 3b. When gate 1 runs, and the IOKit wait

- [O] `WSWaitForIOKitReady` (`___WSWaitForIOKitReady_block_invoke`, `0x7ff8092de148`) is
  `IOKitWaitQuiet(masterPort, timeout 60 s)` (240 s on an installer disk). On timeout it only logs
  `IOKitWaitQuiet: %s`.
- [I] So gate 1 is delayed until the IORegistry is quiet or 60 s pass, whichever comes first. That is the only existing
  hook that could hold the first WindowServer until `NMXAccel` exists: a registry that stays busy until the Metal
  device is published. The `PhxFB` busy hold in `phxagdc.cpp:238-290` (`debug.phxfb_hold`, a timer release) is such a
  hold; it is off by default (only with the boot-arg `-phxfbhold`, `phxfb.cpp:1586`) and not used on the XTX
  machine's boots (`debug.phxfb_hold` reads 0, 2026-11-26).
- [U] When gate 1 first runs (display setup of the first WindowServer, near +2.7 s) and whether the registry is quiet
  then are not measured. The AuxKC arrives at +3.2 s and `VermilionAccel` at +6.8 s, but `NMXAccel` only matches after
  the daemon's claim (+10 s), so a quiet registry between +4 and +10 s would let gate 1 run with no device.

### 3c. Which device each display uses (CoreDisplay)

- [O] CoreDisplay does not use the Metal observer. It uses `GPUWrangler.framework` (`GPUWranglerOpen`,
  `GPUWranglerWaitForPublish`, `GPUWranglerRegisterEventBlock`, `GPUWranglerGPUGetFramebufferAccelIndex`,
  `GPUWranglerGPUIsRemovable`), which talks to the kernel service **`AppleGPUWrangler`** (strings in GPUWrangler:
  `AppleGPUWrangler`, events `GpuAdded`, `GpuRemoved`, `GpuEject*`, `GpuTerminated`, `GPUCAdded`, `AgdpPublished`,
  properties `published`, `hasGPUC`, `IOPCITunnelled`). `CoreDisplay_Display_GetAcceleratorRegistryID`
  (`0x7ff80538628e`) is built on it.
- [O] `CoreDisplay::GPUController` event block (`____ZN11CoreDisplay13GPUControllerC2Ev_block_invoke`,
  `0x7ff8053cfb27`), case 1 `ProcessGPUAdded`: builds a `CoreDisplay::GPU` from the wrangler GPU, rebuilds the mapped
  display list (`RebuildMappedDisplayList`), and for each display of that GPU calls
  `CoreDisplay::CreateMetalDevice(accelerator)` and stores it in the display; then
  `CGXIncrementDisplayMappingChangedSeed` and `CGXMappedDisplaySetFramebuffersAttribute`. This is the real eGPU
  hot-plug adoption path: it is keyed on a **GPUWrangler `GpuAdded` event**, not on Metal.
- [O] **Gate 2, once per GPU object.** `CoreDisplay::GPU::UpdateAcceleratorForMetal` is a `std::call_once`
  (`0x7ff8053bbfe4`): if the GPU's registry entry has an MTL device (`MTLCopyDeviceForRegistryID`) it keeps its
  accelerator; otherwise it calls `FindAcceleratorWithMTLDevice` (`0x7ff805429058`: from `MTLCopyAllDevices`, first a
  device that is `isLowPower` and not `isRemovable`, else the first non-removable) and writes that accelerator into
  every framebuffer of the GPU (`Framebuffer` `+0x18`, `InitializeMPPrivAccelerator`). If it finds no device, the
  framebuffers keep accelerator 0 ("System has no accelerator" and the software path) and the `call_once` is spent.
  [I] It does not retry for that GPU object.
- [R] This is what the repo already saw on 2026-10-20 (`src/vermilion-accel/accel/phxagdc.cpp:238`):
  `GPUWranglerGPUGetFramebufferAccelIndex` was 0 for `PhxFB` when the accelerator came up after the wrangler probed the
  GPU, and CoreDisplay composited in software "however the accelerator came up later". [I] Gate 2 explains it.
- [O] `PostAcceleratorChangeNotification` (`0x7ff8053bc5b8`: display-mapping changed events `0x70c`, CD notifications
  `0x19`/`0x13`, `CGXPostDisplayChangedEvent(0x2030)`) is called only from the GPU eject and eject-cancel cases of that
  event block. Nothing re-runs gate 2 when a framebuffer or accelerator appears on an existing GPU.
- [O] `CoreDisplay::Display::AcceleratorChanged` (`0x7ff80539b428`) and `kCGXDisplayAcceleratorChanged` exist for
  changes CoreDisplay itself makes. [U] Their triggers were not traced (not decompiled beyond the entry).

### 3d. What the framebuffer must look like

- [O] `PhxAMDFB` arrives with `VermilionAccel` (after the firmware framebuffer).
- [R] CoreDisplay's accelerator for a framebuffer comes from the wrangler's per-framebuffer `IOAccelIndex` record (the
  repo note: IOAcceleratorFamily publishes it when it probes). It is taken when the wrangler publishes the GPU, not
  when a framebuffer registers later.
- [I] Nothing in CoreDisplay's `GpuAdded` path re-reads it for a framebuffer added afterwards.

## 4. What the first WindowServer needs, in order

For the first WindowServer to composite on the GPU, all of these must hold when the matching once-only step runs:

1. The Metal device exists (`IOAccelerator` published with `MetalPluginName`/`MetalPluginClassName`; plugin
   allow-listed for WindowServer) and answers `isHeadless == NO`, `isRemovable == NO` before **gate 1** (3a) and
   **gate 2** (3c).
2. `AppleGPUWrangler` has published the GPU (`GpuAdded` reaches CoreDisplay) *after* (1), or CoreDisplay's GPU object
   is created after (1). This is Apple's own order: on a real Mac the AMD wrangler sets `LoadAccelerator` when
   `AppleGPUWrangler` asks ([`reference/apple-amd/01-bringup.md`](../../reference/apple-amd/01-bringup.md) 1.2), so
   the accelerator appears *behind* the wrangler publish, and WindowServer waits in `GPUWranglerWaitForPublish`. [I]
   The late-device case on Apple's stack is handled by waiting for the publish, not by adopting a device after it.
3. The framebuffer is the one the wrangler records for that GPU (the AGDC list `0x980`, `PhxAGDC`).

## 5. Properties Vermilion's accelerator and framebuffer would need (compare with Apple's AMD stack)

What the code reads, and what Vermilion publishes today (`src/vermilion-accel/Info.plist`,
`src/metal-plugin/NVMTLDevice.m`):

| Property or behaviour | Read by | Vermilion | Gap |
|---|---|---|---|
| `IOAccelerator` match category, service published | Metal `IOServicePublish("IOAccelerator")` [O] | `PhxAccel`: `IOMatchCategory IOAccelerator`, `IOPropertyMatch nmxgpu-claimed` | none, but it only exists after `mesboot claim` (+10 s) |
| `MetalPluginName` (string, relative `../../../Library/GPUBundles/...`), `MetalPluginClassName` | `_getMetalPluginClassForService` [O] | both set, class `NVMTLDevice` | none; Apple's is `AMDRadeonX6000MTLDriver` / `AMDMTLGFX10Device` (`reference/apple-amd/05-metal-plugin.md`) |
| bundle trusted by `gpu_bundle_find_trusted` | same [O] | VermilionTrust cdhashes | any plugin change is a new cdhash (CLAUDE.md) |
| `Removable` property absent | `MTLIOAccelService init` when `_mtlAvoidRemovable` [O] | absent | none |
| `MTLDevice.isHeadless` NO, `isRemovable` NO, `isLowPower` YES for the display GPU | gate 1; `FindAcceleratorWithMTLDevice` [O] | `isHeadless` NO only when `debug.nmxaccel_headless == 0`; `isRemovable` NO; `isLowPower` **NO** | `isLowPower` NO sends `FindAcceleratorWithMTLDevice` to its second pass (first non-removable): fine with one GPU; unverified with two |
| `MTLDevice.acceleratorPort` == the display's accelerator | `new_compositor` [O] | inherited from `MTLIOAccelDevice` | none expected |
| `registryID` allowed by `ALLOWED_GPU_IDS` | `MTLAddDevice` [O] | not set | none |
| `AppleGPUWrangler` publishes the GPU after the accelerator; AGDC per-framebuffer accel index | CoreDisplay gate 2 [O/R] | `PhxAGDC` (`debug.phxagdc`) arms from the daemon; the 2026-10-20 busy hold (`debug.phxfb_hold`) did this; since 2026-10-24 it is opt-in (`-phxfbhold`), after a gate inside `start()` deadlocked the matching thread [R] | the open one: see section 6 |

[U] Not compared in this pass: Apple's `AMDRadeonX6000` accelerator and `AMDFramebuffer` property dump for
`IOAccelIndex`, `IOAccelRevision`, `IOAccelTypes`, `IOGPUIsRemovable`-like keys. [O] No `IOGPUIsRemovable` string was
found in SkyLight, Metal or CoreDisplay; removability is `Removable`/`isRemovable`/the wrangler's own attribute.

## 6. Why the 2026-10-24 attempt failed is the open question

- [R] The busy hold on `PhxFB` (2026-10-20, `phxagdc.cpp:238`) kept the PCI device busy so that `AppleGPUWrangler`
  would publish only after the GPU was up. On 2026-10-24 a gate inside `PhxAMDFB::start()` held the IOKit matching
  thread and starved the accelerator ("Metal device never came up", `phxfb.cpp:1418-1419`); since then `PhxAMDFB`
  matches only after the daemon's `phxfb-go`, and the hold is opt-in (`-phxfbhold`). [U] Whether the hold alone (a
  busy count, not a blocked `start()`) also keeps the Metal device from coming up was not separated. Candidates, none
  tested: the wrangler's publish gates `IOAccelerator` matching on this stack; or the hold also blocks `NMXAccel`'s
  start/publish; or the trust check. `AppleGraphicsDeviceControl`/`AppleGPUWrangler` is in the System KC and was not
  decompiled here. Next REA step if T1 fails: `AppleGPUWrangler` publish conditions in AppleGraphicsControl.
- [I] `IOKitWaitQuiet` (3b) gives a second, lighter lever that does not touch the wrangler: keep any IOService busy
  until `NMXAccel` is registered, below 60 s. It only protects gate 1, not gate 2.

## 7. T1 test plan (one boot, daemon only, no EFI or kext change)

Purpose: find out whether gates 1 and 2 were passed by the first WindowServer on the unchanged kernel, and fail safely.

Pre-conditions: machine lock, owner agrees to one boot; no user logged in at the arm (today's guard).

**What the daemon does differently** (flag `~/gpu/phxboot-norestart`, off by default):

1. Everything as today up to and including the arm (`phxboot-navi31.sh` steps 1-4b: claim, `NMXAccel` up, Metal device
   probe, `debug.phxagdc=1`, `nvaccel_iop`, `nvaccelfb`). `all_apps` allow-list (Metal for WindowServer) written before
   the check, as today.
2. Instead of `killall -9 WindowServer` (`:893`), keep the first WindowServer (`WS0`) and run a **verification window**
   of at most 20 s (`PHXBOOT_T1_WAIT`), polling every 1 s, read-only:
   - `ps -p $WS0` still alive (a crash starts a new one: record and fall back);
   - plugin log: a line `NVMTLDevice +load in pid $WS0` / `initWithAcceleratorPort ... in WindowServer` with `$WS0`
     (the plugin's `nvlog`, which goes to `os_log`). The release plugin (#49) logs errors only, so this check needs
     the logging build (`PLUGIN_CONFIG=logging`) for the T1 boot, or is dropped in favour of the `vmmap` check;
   - `vmmap $WS0 | grep -c NVMTLDriver` (the plugin image is mapped only if Metal created the device in `WS0`);
   - `sysctl debug.nvaccel_iop_ok` increasing across two reads 2 s apart (presents counted on the GPU path);
   - a 1 s `sample $WS0 1 -mayDie` grep for `CompositorMetal` or the queue label `com.apple.SkyLight.mtl_submit`
     (software compositing never creates it; gate 1 is open if and only if it exists).
3. **Success**: `NVMTLDriver` mapped in `WS0`, and the plugin pid line, and `nvaccel_iop_ok` rising, and the
   `mtl_submit` queue present, all within the window. Then skip the restart, log `T1 PASS`, continue the rest of the
   boot as today (flip setup, 120 s crash watch, display check, `SUCCESS`), and keep the flag.
4. **Fallback** (any check missing at the end of the window, or `WS0` died): log `T1 FAIL: <which checks>`, then run
   **today's path unchanged**: the existing `killall -9 WindowServer`, flip/offer/guard steps and crash watch. Worst
   case is a 20 s delay over today. Rollback of the test: `rm ~/gpu/phxboot-norestart`. The kill switch, pending mark
   and GOP revert are untouched (hard rule 1).

**What to log** (to `/var/log/phxboot.log`, and one line per item):

- `T1: WS0 pid, start time (ps lstart), t since boot`, and the time of the `NMXAccel up` line;
- `ioreg -rc IOAccelerator -d0` (publish present), `ioreg -l -w0 | grep -E 'busyState|AppleGPUWrangler'` for the GPU and
  the wrangler (the quiet/busy state), once at the arm;
- the unified log of `WS0` since its start, filtered, read-only, and the same from `com.apple.CoreDisplay`:

  ```
  log show --start <WS0 start> --predicate 'process == "WindowServer"' ...
      CONTAINS "accelerator" OR "IOKitWaitQuiet" OR "GPUWrangler" OR "MetalDevice"
  ```

  The strings to look for are `System has no accelerator`, `GPUWrangler Add event: Begin/Done`,
  `Display 0x%x yields null accelerator`, `Failed to create MetalDevice for accelerator`,
  `MetalDevice for accelerator(0x%x)`, `IOKitWaitQuiet: %s`;
- the five checks in 2 with their raw outputs.

The log answers the decisive timing question (3b/3c): `GPUWrangler Add event: Done` and `System has no accelerator`
before or after the `NMXAccel up` time identify which gate failed. [O] Those strings exist in CoreDisplay/SkyLight.
[U] Whether the Tahoe log level emits them without `log config` is not known (the daemon must not change log
settings; if they do not show, the five checks still decide).

**What success looks like for the owner**: the login window animates GPU-smooth from the first WindowServer, no black
flash from the restart, the login-window guard unchanged.

**Interpretation and next step**

- PASS: the restart can go (B1 K10). Then check the unchanged behaviours that the restart hides: VRR floor/HDR knobs
  that WindowServer reads at start (`com.apple.windowserver`; the daemon's `disp_ovr`/`offer_open` run today before
  the WindowServer that ends up accelerated starts, and would then run only after it) [U].
- FAIL, `System has no accelerator` before `NMXAccel up` (gate 2) or no `mtl_submit` (gate 1): the restart stays until
  the kernel publishes in Apple's order. Follow-up T1b (needs a kext/EFI change, one boot): keep the registry busy
  until `NMXAccel` registers, below 60 s (3b); if gate 2 still fails, re-do the 2026-10-20 busy hold on a root-cause basis
  (section 6) so `AppleGPUWrangler` publishes the GPU after the accelerator.
- FAIL with `WS0` dead: launchd starts a new WindowServer, which is today's outcome.

## 8. What was not done

- `CoreDisplay::GPU::GPU` and the callers of `UpdateAcceleratorForMetal` were not traced: when gate 2 first runs after
  `GpuAdded` is inferred from the `call_once` and the repo note, not observed.
- The first call of `WSSystemCanCompositeWithMetal` was not traced to a caller.
- `AppleGPUWrangler` (kernel) and Apple's AMD property dump were not read.
- No log of a first WindowServer exists on the XTX machine (the unified log of the 00:51 boot returned no WindowServer
  accelerator lines at the info level), so no timing was measured.
- Quoted code was limited to function names, selectors and one-line paraphrases. REA evidence ids are in the session
  only; the images used are the 25G241 dyld cache copies, extraction recipe in
  [`reference/apple-amd/README.md`](../../reference/apple-amd/README.md)
  (its recipe: `ipsw dyld extract <dyld_shared_cache_x86_64h> <image> -o dsc/`; this pass added `--slide --stubs`).
