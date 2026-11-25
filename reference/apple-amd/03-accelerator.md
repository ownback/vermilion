<!-- SPDX-License-Identifier: MIT -->

# 3. Accelerator: user clients, submission, memory, recovery, statistics

Binaries: `com.apple.kext.AMDRadeonX6000` (10541 functions) on top of Apple's `com.apple.iokit.IOAcceleratorFamily2`
(3893 functions; both analysed). Tags: [O] observed, [I] inferred, [?] open.

## 3.1 Shape

The AMD kext is a vendor plug-in of Apple's accelerator family: almost every user-visible behaviour (Metal command
queues, fences, residency, GPU restart policy, `PerformanceStatistics`, display pipe transactions) is family code,
and the vendor supplies hardware objects and overrides [O].

| Family class (IOAcceleratorFamily2) | AMD subclass | Role |
|---|---|---|
| `IOGraphicsAccelerator2` | `AMDGraphicsAccelerator` → `AMDGFX10GraphicsAccelerator` → `AMDNavi21GraphicsAccelerator` | The IOAccelerator service |
| `IOAccelSharedUserClient2` | `AMDAccelSharedUserClient` | Resource create/delete, vendor methods 0x100-0x117 |
| `IOAccelCommandQueue` | `AMDAccelCommandQueue` | Metal command buffer → segments → channels |
| `IOAccelContext2`, `IOAccelGLContext2`, `IOAccel2DContext2` | `AMDAccelCPContext`, `AMDGFX10GLContext`, `AMDGFX10CLContext`, `AMDAccel2DContext`, `AMDAccelVideoContext`, `AMDAccelVCNContext`, `AMDAccelPspContext` | Per-API contexts |
| `IOAccelFIFOChannel2` | `AMDAccelChannel` | A submission channel; `restart()` |
| `IOAccelEventMachineFast2` | `AMDAccelEventMachine` | Stamps, `eventTimeout`, busy time |
| `IOAccelResource2`, `IOAccelVidMemory`, `IOAccelSysMemory` | `AMDAccelResource` (`Addr1`, `Addr2` tiling), `AMDAccelVidMemory`, `AMDAccelSysMemory` | Buffers, textures, IOSurfaces |
| `IOAccelStatistics2` | `AMDAccelStatistics` | `PerformanceStatistics`, IOReport channels |
| `IOAccelDisplayPipe` | `AMDAccelDisplayPipe` | Flip / swap transactions to the framebuffer |
| `IOAccelDevice2`, `IOAccelShared2`, `IOAccelMemoryMap`, `IOAccelTask` | `AMDAccelDevice`, `AMDAccelShared`, `AMDAccelMemoryMap`, `AMDAccelTask` | Per process |

Hardware side (no family counterpart): `AMDNavi21Hardware` (see [01](01-bringup.md)), `AMDSWScheduler`,
`AMDHWChannel` / `AMDPM4HWChannel` / `AMDGFX10KIQHWChannel` / `AMDGFX10HIQHWChannel`, rings
(`AMDGFX10GraphicsRing`, `ComputeRing`, `SDMARing`, `AMDVCN2DecRing`, `EncRing`, `EncLLQRing`, `AMDVCN3UnifiedRing`),
engines (`AMDGFX10PM4Engine`, `AMDSDMAEngine_GC_10_3_0`, `AMDVCN3HWEngine`), MES user queues
(`AMDGFX10UserQueueManager`, `AMDUserQueue`), memory (`AMDHWMemory`, `AMDHWGart`, `AMDHWVMM`, `AMDHWVMContext`,
`AMDGCHub_10_3_0`, `AMDMMHub_2_1_0`), blits (`AMDBltMgr`, `AMDAtomicBlitManager`), `AMDStatisticsManager`,
`AMDChannelProfiler`, `AMDEventLogManager` [O].

## 3.2 User clients

The family's user clients carry the standard Metal/GL selectors; the AMD shared user client adds **24 vendor
selectors, 0x100-0x117** (`getTargetAndMethodForIndex`: `sel - 0x118 >= -0x18`, table of `IOExternalMethod` at
`0xbf1bb40 + sel*0x30`) [O]:

| Sel | Method | In / out bytes |
|---|---|---|
| 0x100 | `MSAATextureReadWrite` | 0x28 / 0 |
| 0x101 | `SurfaceCopy` | struct / 0x18 |
| 0x102 | `getIOSurfaceInfo` | scalar 1 / 0x38 |
| 0x103 | `ExpandDcc` | scalar 1 / 0 |
| 0x104 / 0x105 / 0x106 | `AndXorByteFlag` / `RsrcAndXorByteFlag` / `RsrcReleaseCondFlag` | GPU-visible condition flags |
| 0x107 / 0x108 | `CreateVcnContext` / `RemoveVcnContext` | video (04) |
| 0x109 | `SetProfilingMode` | 8 / 0x10 |
| 0x10a | `QkGetInfo` | scalar / 0x10 |
| 0x10b | `SetStableClockMode` | 4 / 0x10 (profiling: fixed clocks) |
| 0x10c | `PowerFeaturesControl` | 4 / 4 |
| 0x10d | `LockVMIDForCapture` | 4 / 0 (GPU capture) |
| 0x10e | `QkGetGpuInfo` | 0 / 0x178 (device info for user space) |
| 0x10f / 0x110 | `QkChannelSubmit` / `QkChannelCheckStamp` | 0xa8 / 8, 0x10 / 8: a direct "quick" submit path |
| 0x111-0x114 | `QkMemoryAlloc`, `QkMemoryFree`, `QkMemoryMapForCPU`, `QkMemoryUnmapForCPU` | |
| 0x115-0x117 | `QkCreateResourceList`, `QkAddResourcesToList`, `QkDestroyResourceList` | |

The `Qk*` set is a small allocate / submit / wait interface beside the Metal command-queue path [O for the names; I
that tools and the OpenCL/compute runtime use it].

## 3.3 Command submission

[O for the methods; I for the order between them]

```
user space (Metal driver)               family                              AMD
MTLCommandBuffer commit ──► IOAccelCommandQueue::submit_command_buffers
                              └─ processCommandBuffer ─────────────► AMDAccelCommandQueue::processCommandBuffer
                                                                       parseSegmentList: per segment
                                                                         process_SubmitCommand   (PM4 IB)
                                                                         process_UpdateFence / WaitForFence
                                                                         process_CondExec, AndXorFlag
                                                                         process_GlobalRsrcList, RsrcAndXorFlag
                                                                         process_SetSegmentChannel, ISAILHash
                                                                       addRsrcListToChannel (residency)
                                                                     AMDAccelChannel::submitCommands / submitBuffer
                                                                       waitForRingBufferSpace
                                                                     AMDSWScheduler::submitCommandBuffer
                                                                       per HW channel queue, timestamps,
                                                                       preempt / checkPreemption / userQueueSwitch
                                                                     AMDHWChannel → ring write + doorbell
                                                                       or MES user queue (AMDUserQueue,
                                                                       AMDGFX10UserQueueManager run list)
GPU EOP interrupt / stamp ──► IOAccelEventMachineFast2 ◄──────────── AMDAccelEventMachine (stamps advance)
                              retireCommandBuffer → completion handlers
```

- Each submission ends with a timestamp ("stamp") write; completion is stamp-based (`checkForTimestamp`,
  `waitForTimestamp`, `swTimestampUpdated`, `timestampUpdated`) [O].
- KIQ submission has its own stamp timeout ("Stamp Timeout for KIQ Submission!") [O].
- The scheduler is software (`AMDSWScheduler`) over hardware rings, with MES-managed user queues for some
  queues (`addUserQueue`, `populateRunListBuffer`, `hwsTimerCallback`, `preemptionTimerCallback`) [O].
- `GPUTaskSingleChannel` (personality) and `AMDAccelTask` bind work to channels [O].

## 3.4 Memory

- **VRAM / GART** [O]: `AMDHWMemory` (VRAM heap: `allocateNonContiguous`, `reserve`, memory descriptors),
  `AMDHWGart` (`fillGartParameters`, `allocateAMDHWGart`), `AMDGraphicsAccelerator::calcMaxGPUPhysicalMemoryBytes`,
  `reduceVRAM`, `tmpTotalVRAM`, `totalTextureMemory` (the `IOAccelerator` "VRAM" answer).
- **GPU VM** [O]: `AMDHWVMM` assigns a VMID per context (`assignVMID`, `releaseVMID`, `waitForVMID`), page tables
  updated in batches (`beginVMPTUpdate` / `endVMPTUpdate`, `clearWithDMA` through SDMA), TLB invalidation
  (`invalidateVM`, `encodeInvalidationRange`). VM faults: `vmFaultInterruptCallback` → `vmFaultDeferredCallback` →
  `fillFaultAccelInfo` and a diagnosis report; "Hang on VM Fault policy" is a debug policy.
- **Residency and paging** [O]: `AMDAccelResource` has `getPagingChannel`, `getPagingTask`,
  `getPagingSysMemMapOptions`, `fallback` (to system memory), `BatchPrepare` / `BatchPrepareMappings`; the family
  evicts under pressure (`vramEvictionWaitTime`, `texturePageOutBytes` counters).
- **Tiling / DCC** [O]: `AMDAccelResourceAddr2` (GFX10 swizzle), `fillUBMSurfaceInfo*` (AMD's UBM surface
  descriptor), `ExpandDcc`, `GPUDCCDisplayable` (DCC surfaces can scan out on Navi 12-23).
- `ResNoAllocPaging` (Navi 21 personality) and `ZeroFillPattern` tune allocation [O].

## 3.5 Timeouts and hang recovery

This is the part STATUS item 7 needs. [O unless tagged]

1. **Detection.** The family arms a GPU progress timeout of `waitForGPUTimeoutSeconds` × 1000 ms
   (`IOGraphicsAccelerator2::createEventMachine`). The default is **5 s** (`initializeConfigStructure`, config word
   at `+0xcf0`); `validateConfigStructure` refuses 0; AMD's `populateAccelConfig` doesn't change it.
   `IOAccelEventMachineFast2::checkGPUProgress` compares stamp progress with it.
2. **Blame.** `AMDAccelEventMachine::eventTimeout(channel)` calls `AMDSWScheduler::checkTimestamps`, then decides
   per hardware channel: "is advancing" (no action), "is moving, last stamp update N ms ago", "busy", "occupied by
   channel N", "Blame channel %u with idle HW", "blocked by HW stamp from unknown channel", or "channel %u is hung!".
   Only a hung channel restarts; otherwise "channel %u is not hung, keep running".
3. **Report.** `AMDAccelChannel::getHardwareDiagnosisReport` / `writeDiagnosisReport` (pending commands, blocked
   channel, wait info), `AMDHardware::dumpASICHangState`, `AMDGFX10Hardware::checkASICHangState`,
   `asicHangLogDumpMeStateQueues`, `writeVMProtectionFaultDiagnosisReport`. The family publishes it as a
   `GPURestartReport` (`IOAccelGPURestartReport2` nub, user client for the crash reporter). "Skip duplicated GPU
   hang report collection".
4. **Reset.** `AMDAccelChannel::resetHardwareAndReplay`: `AMDSWScheduler::pause` → `pruneRingBuffer` →
   `AMDHardware::resetHardware` (per engine first: `AMDHWEngine::reset` resets the engine queue, "Failed to reset
   engine queue!"; if that fails a full GPU restart; "GPU restart previously failed and will not be attempted
   again") → `resetSwQueue` for the guilty queue → `AMDSWScheduler::resume` → `replayBuffers` re-submits the other
   channels' pending command buffers ("CB replay failed"). If the reset fails: "Hardware could not be reset.
   Further submissions will not be accepted."
5. **Policy on the app** (family, `IOAccelCommandQueue::retireCommandBuffer`): each queue counts GPU restarts over
   its last 1000 submissions. At the 2nd restart: "Deny Submissions/ignore app[...]" (its submissions are refused),
   unless it holds `com.apple.private.graphics-restart-no-kill` / `noIgnoreOnGPURestart` ("Immunity for"). After
   1000 clean submissions: "Clean slate".
6. **Debug knobs**: boot-args `panic_on_gpu_hang=1`, `panic_on_display_hang=1`, `amd_gpu_debug_policy`
   (`GpuDebugPolicy`: `DBX_SLEEP_BEFORE_GPU_RESTART`, `DBX_SLEEP_AFTER_GPU_RESTART`); `GPU Restart Count` and
   `recoveryCount` in the statistics.

Display pipe transactions have their own watchdog (`IOAccelDisplayPipe::transaction_timeout_timer_fired`,
"transaction_wait_gated Timeout (%d millisec). last VBL was %llu millisec ago") [O].

## 3.6 PerformanceStatistics and IOReport

[O] Keys written into the accelerator's `PerformanceStatistics` dictionary:

- Family (`IOAccelStatistics2::writePerformanceStats`): `hardwareWaitTime`, `finishGLWaitTime`,
  `finishCLWaitTime`, `freeToAllocGPUAddressWaitTime`, `vramEvictionWaitTime`, `recoveryCount`, `textureCount`,
  `contextGLCount`, `contextCLCount`, `gartUsedBytes`, `gartMapInBytesPerSample`, `gartMapOutBytesPerSample`,
  `clientSharedAllocatedBytes`, `stdTextureCreationBytes`, `oolTextureCreationBytes`, `iosurfaceTextureCreationBytes`,
  `agpTextureCreationBytes`, `agprefTextureCreationBytes`, `stdTexturePageInBytes`, `oolTexturePageInBytes`,
  `texturePageOutBytes`, `textureReadOutBytes`, `textureVolunteerUnloadBytes`, `surfaceBufferPageInBytes`,
  `surfaceBufferPageOutBytes`, `surfaceBufferReadOutBytes`, `ioSurfacePageInBytes`, `ioSurfacePageOutBytes`,
  `ioSurfaceReadOutBytes`.
- AMD (`AMDAccelStatistics::writeInternalStats`, read in its assembly since Ghidra truncated it): **`Device
  Utilization %`** and **`vramFreeBytes`** (OSNumber 64-bit). Utilization comes from
  `AMDRTHardware::getGPUUtilization` → `AMDAccelStatistics::getChannelBusyCounters` [I].
- AMD (`AMDHardware::publishPMStatistics(OSDictionary*, bool)`, same signature as the statistics writers):
  **`Core Clock(MHz)`, `Memory Clock(MHz)`, `GPU Activity(%)`, `Temperature(C)`, `Total Power(W)`, `Fan
  Speed(RPM)`, `Fan Speed(%)`**, sampled from the SMU by `samplePMStatistics` [O for keys; I that they land in
  `PerformanceStatistics`].
- Per-client GPU time: the family keeps `accumulatedGPUTime` and `lastSubmittedTime` on each command queue / context
  (strings in IOAcceleratorFamily2) [O]; the vendor feeds busy time through `AMDAccelEventMachine::reportBusyTime` [O].
- IOReport channels (`AMDAccelStatistics::setupChannels`): `Overall GPU Busy`, `3d Busy`, `Compute Busy`,
  `DMA Busy`, `Video Busy`, `PM4 Busy`, each with a "total time" twin [O].
- Timers: `HWPerfPollIntervalUS`, `PerfBusyPollIntervalUS`, `PerfBusyMaxIdleTimeMS`, `StableClockCheckInterval` [O].

## 3.7 Vermilion today vs this

| Apple | Vermilion (`NMXAccel`, `N48N` client, RADV) | Gap |
|---|---|---|
| Family command queues + vendor segment parser; stamps; event machine | RADV submits through our own user client (`phx_queue.cpp`, `PhxCpDma.h`); NVIDIA-derived NMX classes | Different model; fine for Metal-on-Vulkan, but no family event machine, so no family timeout |
| 5 s progress timeout, blame, per-engine reset, replay, per-app deny policy, `GPURestartReport` | None (STATUS A6, item 7) | Build the same ladder for Navi 31 with Linux's ring/queue reset (hw-safety) |
| `Device Utilization %`, `vramFreeBytes` | Absent (#33 K8, K9) | Publish both (A4) |
| `Core Clock(MHz)`, `Memory Clock(MHz)`, `GPU Activity(%)`, `Temperature(C)`, `Total Power(W)`, `Fan Speed(RPM)`, `Fan Speed(%)` | Absent; the daemon reads SMU metrics (`smumetrics.py`) | N2: publish these exact keys |
| `accumulatedGPUTime` per client | Only on `NMX2DContext` (#33 K10) | N1 |
| `recoveryCount`, `GPU Restart Count` | `recoveryCount` key only | With item 7 |
| VMID per context, PT updates by SDMA, VM fault report | `phx_vm.cpp`, `PhxVmTables.h` | Fault reporting / diagnosis |
| `QkGetGpuInfo` gives user space the device info | RADV canned device info (A19) | Serve GC config from the kernel (A4) |
