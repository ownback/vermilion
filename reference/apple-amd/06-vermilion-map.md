<!-- SPDX-License-Identifier: MIT -->

# 6. Apple function → what Vermilion has or lacks

Every row of [STATUS](../../.agents/STATUS.md) and every item of `PLAN-parity-week.md` (on `ownback/megamind`,
2026-11-25: A1-A7, B1-B6, C1-C7, N1-N8 from #33). "Apple" names functions in Apple's binaries (section links give
the evidence). Confidence: **[O]** observed in Apple's code, **[I]** inferred, **[?]** open. Vermilion's side is as
STATUS describes it on 2026-11-25; nothing here was tested on hardware.

## 6.1 Display and boot (STATUS)

| STATUS row | Apple does it with | Vermilion has | Lacks | Conf. |
|---|---|---|---|---|
| 1440p modes, VRR (replayed captures) | AMD DC + falcon_dm in the framebuffer kext: `AmdRadeonFramebuffer::setDisplayMode` → `programDisplayMode` → `AmdDalHelper::setDisplayMode`; DML bandwidth checks (`validate*TimingBandwidth`) ([02 §2.1, §2.3](02-display.md)) | Per-mode replay plans, `PhxDpLink`, `PhxVrrRamp` | Timings and link training computed from EDID/DPCD (B2): port DC `dcn32` with a thin DM, as Apple did for `dcn30` | O |
| Other sizes (CPU copy) | DCN scaler, `IOFBScalerInfo`, `isSoftwareScalerTiming`, `populateScalingCapabilities` | CPU copy | Scaled scan-out (B2) | O |
| Other / second monitor, HDMI, HiDPI | DC resource pool, MST manager (`AmdDalMstManager`, `MstManager/*`), HDMI FRL encoders (`dcn30_hpo_frl_*`), `ATY,MaxStreams` | Head 0 only | B2; a pipe allocator is DC's resource code | O |
| HDR (off) | DC colour module, `getPQGammaProperties`, `getDegammaProperties`, `getCscProperties`, HDR static metadata SDP (`processSdpInfoPacket`, AGDC `setSecondaryDataPacket`) | Replay HDR plans; widen path broken (item 4) | Colour pipe programmed per frame (`AmdFbPresenter` CSC/degamma transactions) | O |
| Replug / monitor power / input switch | `AmdHotplugInterrupt` → `AmdLink::detectLink` → `connectionChange` (drops `IOFBConfig`, re-probe), `isPostWakeProbeNeeded` | `phxhotplug.cpp` (broken, item 5) | Re-detect and re-train on HPD; drop the stale config | O |
| Night Shift, calibration | `AmdGammaTable` + `AmdFbPresenter::processGammaTransaction` at VUpdate | Head-1 table; head-0 regamma pending | Gamma as a per-frame transaction on head 0 | O |
| DDC/CI | `IOFBI2CInterfaceInfo` + `AmdRadeonFramebuffer::doI2CRequest` over DC DDC / AUX-I2C (`AmdDalAuxI2c`) | Not implemented | Implement both on PhxAMDFB (item 9) | O (the key), I (MonitorControl uses it) |
| EDID identity | DC detection; `getDDCBlock` | Serves another EDID on failure (D15) | Report "no EDID" | O |
| Boot picker, verbose, logo | n/a (EFI) | — | B6 | — |
| Boot to desktop via WindowServer restart | Bring-up in `start()`: `AMDHardware::init` (TTL / SWIP) and `AmdRadeonController::powerUp` before WindowServer ([01 §1.3](01-bringup.md)) | Daemon | B1 | O |
| GPU power-up by a daemon | Same | Daemon + `~/gpu` | B1; firmware loaded by the kext from its bundle | O |
| Cold boot | `establishBootDisplay` keeps the GOP stream; TTL init logs PSP bootloader version / POST / ready before PSP | Works | Early-boot record: copy Apple's pre-TTL log and failure diagnosis report | O |
| Warm restart, shutdown | No `systemWillShutdown` override; power-off through PM: `AMDHardware::powerOff` (`disableGfxOff`, `disableInterrupts`, `stopHWEngines`, `powerOffHWEngines`, `disableTransactions`) | No GPU quiesce (D5, D6) | B5: the same order, with Linux's SMU unload on Navi 31 | O (order), I (that PM calls it at restart) |
| After a freeze | Recovery inside the kernel (§6.2 GPU hang) | Manual repair (item 3) | — | O |
| System sleep | `systemWillSleep` / `internalWillSleep` / `powerOff`, then `powerUp` / `wake` (`BiosParser::powerUp`, `messageAccelerator(7)`, `(6)`) | `disablesleep 1` | Suspend / resume (phase 3) | O |
| Display sleep | `setOutputPowerState` → `AmdDalHelper::setDisplayPower`, `setDpSleepValue` | Broken (item 6) | DPMS through DC or Linux's sequence | O |
| Recovery / Safe Mode / installer | `validateTimingForSafeMode`; PowerPlay failure tolerated ("Safe-Mode?") | Unverified | Kext path must not depend on the daemon | O |

## 6.2 Acceleration (STATUS)

| STATUS row | Apple | Vermilion has | Lacks | Conf. |
|---|---|---|---|---|
| Metal for apps | Family `MTLIOAccel*` + `AMDMTLGFX10Device`; accelerator registered in `start()` | NVMTL over RADV; device after the daemon (A1) | Device at boot (B1) | O |
| Desktop compositing | `IOAccelDisplayPipe` transactions, `AmdFbPresenter` flip at VUpdate, DCC scan-out (`GPUDCCDisplayable`) | System-memory surfaces, flip from user space (A5) | VRAM scan-out of WindowServer's surfaces; flips as display-pipe transactions | O |
| OpenGL | `IOGLBundleName` = native GL driver | Apple's GL-over-Metal, late (A10) | Comes with B1 | O |
| OpenCL | `IOOCDBundleName` | Works, 6 GiB cap | Name key; working set from VRAM | O |
| MPS, Core ML | Tensile GEMM tables in the MTL driver | Broken in part (A12) | — | O |
| WebGL / WebGPU | Not driver-specific | — | — | — |
| GPU hang or lost GPU | 5 s progress timeout (`waitForGPUTimeoutSeconds`), `AMDAccelEventMachine::eventTimeout` blame, `AMDAccelChannel::resetHardwareAndReplay` (pause, prune, per-engine reset, full restart once, replay innocent buffers), per-app deny after 2 restarts in 1000 submissions, `GPURestartReport` ([03 §3.5](03-accelerator.md#35-timeouts-and-hang-recovery)) | None (item 7) | The whole ladder; reset steps from Linux amdgpu's Navi 31 queue reset (hw-safety) | O |
| GPU name, VRAM, Activity Monitor | `model` from `AsicInfo::getModelName`; `VRAM,totalMB`, `ATY,memsize`; `Device Utilization %`, `vramFreeBytes` from `AMDAccelStatistics::writeInternalStats` | Name with suffix; no utilization | A4 | O |
| Metal feature answers | `AMDMTLGFX10Device` (not dumped: needs a Navi 21) | Untested claims (A16) | N5 stays open | ? |
| RADV device info canned | `QkGetGpuInfo` (vendor selector 0x10e) hands user space the device info | Canned profile (A19) | Serve GC config from the kernel | O |
| VermilionAccel from the AuxKC | System KC | AuxKC + Allow click | B3 dropped by the owner | — |
| VermilionTrust | Apple's bundles are platform binaries | AMFI patch | B4 | — |
| Plugin build | One release driver | Logging build (A22) | A2 | — |

## 6.3 Video, audio, power, sensors (STATUS)

| STATUS row | Apple | Vermilion has | Lacks | Conf. |
|---|---|---|---|---|
| HEVC / AV1 decode | `IOGVACodec` `AMDVCN2`, `IODVDBundleName` `AMDRadeonVADriver2`, HEVC capability dictionaries; `AvdVAInterface` over IOAccel video contexts; VCN3 rings in the kernel | Decoder bundle on the system volume; keys set by `phx_sysctl.cpp` | A6 route; AV1 key unknown on Apple's side | O / ? |
| 4K YouTube stutter | Kernel VCN rings, `ScheduleAVDCommands` async | Synchronous (~13 ms/frame) | Async queue | O |
| H.264, VP9 | H.264 decode in VADriver2 (`AvdVcnAvcDecDataProcessor`); no `IOGVAVP9Decode` from AMD (VP9 in software on an AMD Mac) | Missing | H.264 only; VP9 software is Apple-parity | O / I |
| Hardware encode | `IOGVAHEVCEncode`, `IOGVAHEVCEncodeCapabilities`, `IOGVAH264EncodeCapabilities`; `Vcn3Encoder`, LLQ ring | Missing | N3 / C7 | O |
| DP audio | Framebuffer publishes `audio-codec-info` (`pin << 16 | 0x100`), `connector-type`, `av-signal-type` in `reportCapabilities_LinkInfo`; AppleGFXHDA pairs by these and the EDID's CEA block; DC enables the endpoint in the mode set ([04 §4.3](04-power-audio-video.md#43-audio)) | VermilionAudio sets the properties; daemon programs audio | Publish from PhxAMDFB; audio in the kernel mode set | O |
| DP audio sequencing | DC `dcn30_afmt`, `dce_audio` | Three order differences | Follow DC's order | I |
| GPU idle power | GfxOff (`enableGfxOff`), SMU DPM in HWLibs, `dpm` = 1 | Daemon flags | DPM in the kext | O |
| Temperature, fan, power | `publishPMStatistics`: `Core Clock(MHz)`, `Memory Clock(MHz)`, `GPU Activity(%)`, `Temperature(C)`, `Total Power(W)`, `Fan Speed(RPM)`, `Fan Speed(%)` | Missing | N2: these keys | O (keys), I (dictionary) |
| Release shape | One system-KC kext set, firmware in HWLibs | 4 kexts, daemon, flags, `~/gpu` | — | O |

## 6.4 PLAN-parity-week items

| Item | Apple reference | Vermilion action | Conf. |
|---|---|---|---|
| A1 compositing | Display-pipe transactions, VRAM / DCC scan-out | As above | O |
| A2 plugin build | One driver; bundle names set in `setDriverBundleNames` | Release config, own names | O |
| A3 Metal answers | `AMDMTLGFX10Device` | Not dumpable here | ? |
| A4 device info, VRAM, name, utilization | `model`, `VRAM,totalMB`, `Device Utilization %`, `vramFreeBytes`, `QkGetGpuInfo` | Publish the same keys | O |
| A5 WebGL cache | — | — | — |
| A6 decoder route | GVA keys + `IODVDBundleName` | `PhxVA` via the same keys | O |
| A7 passd | — | — | — |
| B1 bring-up in the kernel | `AMDHardware::init` order, SWIP table (BGM, GVM, PSP, SMU, GC, SDMA, MES, VCN, JPEG, DMCU), firmware from the kext | Follow the order with Linux's Navi 31 messages | O |
| B2 own mode setting | AMD DC + falcon_dm | DC `dcn32` port | O |
| B3 AuxKC | — (dropped) | — | — |
| B4 VermilionTrust | — | — | — |
| B5 warm restart | `AMDHardware::powerOff` order | Same order + SMU unload | O / I |
| B6 boot profile | — | — | — |
| C2 display parity | §6.1 rows HDR, replug, DPMS, DDC | `doI2CRequest`, `setOutputPowerState`, HPD path | O |
| C3 hang recovery | §6.2 GPU hang | The ladder | O |
| C5 / N1 per-client GPU time | Family `accumulatedGPUTime`, `lastSubmittedTime`; vendor `reportBusyTime` | Per proxy | O |
| C5 / N2 sensors | `publishPMStatistics` keys | Exact keys | O |
| C5 / N6 counters | `GPURawCounterBundleName` `AMDRawCounterPlugin`, class `AMDRawCounterSourceGroup`; `MetalStatisticsName` `GFX10Statistics`; common counter sets | A raw-counter plug-in | O |
| C5 / N8 power-policy node | AGPM: AMD entries on the Mac Pro board have `Heuristic ID -1`; no entry for `0x744c` or `0x73bf` | Not needed for parity; DPM in the kext | O (plist), I (meaning) |
| C6 / N4 ROM row | `ATY,Rom#` = `BiosParserHelper::getPartNumber` (else `NOT-DETECTED-???`) on the PCI device | Read the AtomBIOS part number (rule 3) | O (key), I (the row) |
| C6 / N7 bundle identity | `MetalPluginName` bundle name, `MetalPluginClassName` `AMDMTLGFX10Device` | Own id and class | O |
| C6 audio stray byte | AppleGFXHDA's EDID path (`edidIsValidForAudio`, `gfxMatchedHandler`) | Publish properties from the FB, valid CEA block | I |
| C7 / N3 encode | `IOGVAHEVCEncode(Capabilities)`, `IOGVAH264EncodeCapabilities`, VCN3 encoder | Keys + VCN encode via Vulkan Video | O |

## 6.5 The 10 Apple behaviours to adopt first

Ordered by user impact and risk, given what Vermilion already has.

1. **Bring-up in `start()` in the SWIP order** (BGM → GVM → PSP → SMU → GC → SDMA → MES → VCN → JPEG → DMCU), with
   firmware loaded by the kext and a PSP / SMU diagnosis report on failure (B1; [01](01-bringup.md)). Messages stay
   Linux amdgpu's for Navi 31 (hard rule 1).
2. **The hang-recovery ladder**: 5 s progress timeout, blame the channel that's actually stuck, reset that engine's
   queue, full restart at most once, replay the other channels, refuse the app after 2 restarts in 1000
   submissions, publish `recoveryCount` / `GPU Restart Count` (item 7; [03 §3.5](03-accelerator.md#35-timeouts-and-hang-recovery)).
3. **`Device Utilization %` and `vramFreeBytes`** in `PerformanceStatistics` (A4; Activity Monitor's GPU history).
4. **The SMU statistics keys** `Core Clock(MHz)`, `Memory Clock(MHz)`, `GPU Activity(%)`, `Temperature(C)`,
   `Total Power(W)`, `Fan Speed(RPM)`, `Fan Speed(%)` (N2), from the SMU metrics the daemon already reads.
5. **`IOFBI2CInterfaceInfo` + `doI2CRequest`** on PhxAMDFB over DP AUX-I2C (item 9: DDC/CI).
6. **The framebuffer publishes its own audio contract** (`audio-codec-info`, `connector-type`, `av-signal-type`,
   `display-type`, `port-number`) at link setup, before the 2nd `DidChange` (moves VermilionAudio's job into
   PhxAMDFB; item 8's audio name).
7. **Mode set as Apple does it**: black the gamma, commit, re-apply gamma, colour and flips as VUpdate transactions
   (a fix pattern for HDR item 4 and Night Shift D22, before full DC).
8. **HPD → detect → `connectionChange` drops the stale config → re-probe**, plus a re-probe after wake (item 5).
9. **Registry identity like Apple's**: `model` from the ROM, `ATY,Rom#` from the VBIOS part number (N4),
   `MetalPluginName` / `MetalPluginClassName` / `MetalStatisticsName` / `GPURawCounterBundleName` (N7, N6), GVA keys
   including encode (N3).
10. **Plan B2 as "AMD DC + a thin DM"**: Apple ships AMD's own DC for RDNA 2 inside the framebuffer kext; for Navi 31
    the same tree has `dcn32`. That replaces replayed captures with computed timings and link training at every size.
