<!-- SPDX-License-Identifier: MIT -->

# 2. Display: controller, framebuffer, AMD DC

Binary: `com.apple.kext.AMDRadeonX6000Framebuffer` (9399 functions; about 2800 named C++ functions, the rest unnamed
C). Tags: [O] observed, [I] inferred, [?] open.

## 2.1 The key fact: Apple ships AMD's DC

The unnamed C in the framebuffer kext is AMD's Display Core, the same code tree Linux amdgpu builds as
`drivers/gpu/drm/amd/display` [O]. Build paths left in assert strings:

```
.../ampc/trunk/ampc/SunburstE/dal/dc/core/dc_link.c, dc_link_dp.c, dc_link_hwss.c
.../dal/dc/dc_dmub_srv.c, dal/dmub/src/dmub_srv.c, dal/dc/dce/dmub_psr.c
.../dal/dc/dcn10, dcn20, dcn21, dcn30, dcn302 (resource, hwseq, optc, dccg, dio_stream_encoder, vpg, afmt,
     hpo_frl_link_encoder, hpo_frl_stream_encoder), dce, dce110, calcs, clk_mgr/dcn10, clk_mgr/dcn21
.../dal/dc/dml/dcn20, dcn21, dcn30 (display_mode_vba_30.c, display_rq_dlg_calc_30.c), dc/bios
.../dal/modules/color, modules/power, modules/ddc_service
.../dal/falcon_dm/falcon_dm/Source/*.cpp  ← AMD's macOS display manager (the "amdgpu_dm" of this driver)
```

`falcon_dm` sources [O]: `AmdDalServices`, `AmdDalDisplay`, `AmdDalStream`, `AmdDalPlane`, `AmdDalFbTranslator`,
`AmdDalDmcubService`, `AmdDalPsrService`, `AmdDalPowerPlayIri`, `AmdDalI2c`, `AmdDalAuxI2c`, `AmdDalMstManager`,
`MstManager/*` (MST topology, sideband messages), `EDIDParser/*` (`DisplayID`, `DisplayID2`, `EdidExtCea`,
`ModeList`, `TimingServiceHelpers`), `falcon_dm_services`, `falcon_dm_i2c_aux`, `falcon_dm_pp_smu`.

The layers [O for the classes, I for the boundary]:

```
IOFramebuffer API ── AMDRadeonX6000_AmdRadeonFramebuffer (one per connector, "ATY,RadeonFramebuffer")
                       │  mode list, setDisplayMode, gamma, cursor, DDC/I2C, power, interrupts
AGDC API ─────────── AMDRadeonX6000_AmdAgdcServices (commit/testConfiguration, link/stream state, DP config)
                       │
                     AMDRadeonX6000_AmdRadeonController (one per GPU) ── AmdLink (one per connector)
                       │                                                └ AmdFbPresenter (flip/gamma/CSC/VRR
                       │                                                  transactions at VUpdate/VBlank)
                     AMDRadeonX6000_AmdDalHelper ── falcon_dm (C++) ── dc_* / dcn30_* / dml (C, AMD DC)
                       │                                                └ dmub_srv (DMCUB firmware)
                     AmdBiosParserHelper (AtomBIOS), AmdPowerPlayHelper (SMU via HWLibs), AmdRegisterAccess
```

Consequence for Vermilion [I]: the route Apple took for RDNA 2 is "AMD's DC + a thin macOS DM". For Navi 31 the
same DC tree has `dcn32` (Linux, MIT-licensed). Vermilion's own mode setting (plan B2) can follow that shape instead
of replaying captures.

## 2.2 Controller power-up

See [01-bringup.md §1.3](01-bringup.md#controller-start-and-powerup-o) for the full order. Display-specific steps [O]:
`BiosParserHelper::initializeDmcuB(fbSize)` (DMCUB window at the end of VRAM, 64 KiB default),
`initializeDisplayController()` (AtomBIOS command table 7), `setupBootWatermarks()`, `DalHelper::powerUp()`,
`setupCursors()`, `setupLinks()` (`AmdLink::initializeLink` per connector), `setupHdcpServices()`,
`detectAllDisplays()`, `establishBootDisplay()` (keeps the stream the EFI GOP lit, so there is no black flash),
`createAgdc()`.

`DalHelper::powerUp` [O]: reads two ASIC capability flags and the clamshell state, initialises DAL with them
(`dal->init(flags)`), fetches the DC capabilities into the helper (`getDcCapabilities`), reads the DC version.
`reportControllerProperties` then publishes `DC_VERSION`, `DMCU_B_VERSION`, `DMCU_B_VBL_VERSION`.

### Properties published (all [O])

| On | Keys |
|---|---|
| PCI device (controller's `this+0x98`) | `name` = `ATY_GPU`, `device_type` = `gpu-controller`, `model` (from `AsicInfo::getModelName`, parsed from the EFI ROM: `parseModelNameFromEfi`), `ATY,FamilyName`, `ATY,DeviceName`, `ATY,memsize`, `VRAM,totalMB`, `ATY,vram_base`, `AAPL,aux-power-connected`, `ATY,RefCLK`, `ATY,MaxStreams`, **`ATY,Rom#`** (VBIOS part number from `BiosParserHelper::getPartNumber`, else `NOT-DETECTED-???`), `DC_VERSION`, `DMCU_B_VERSION`, `DMCU_B_VBL_VERSION` |
| Controller | `FB_Boot_ControllerStarted`, `FB_Boot_ControllerEnabled`, `DalClamshellClosedState`, `iofb_no_regptr` |
| Each framebuffer | `FramebufferStarted`, `FramebufferEnabled`, `IOFBConfig`, `IOFBTimingRange`, `IOFBDetailedTimings`, `IOFBScalerInfo`, `IOFBGammaCount`, `IOFBGammaWidth`, `IOFBGammaHeaderSize`, `IOFBI2CInterfaceInfo`, `IOFBProbeOptions`, `IOFBDependentID`, `IOFBDependentIndex`, `IOPMIsPowerManaged`, `ATY,fb_offset`, `ATY,fb_size`, `ATY,fb_linebytes`, `ATY,fb_minVTotal`, `ATY,fb_maxVTotal` (VRR range), `ATY,fb_maxstretch`, `ATY,fb_maxshrink`, `display-connect-flags`, `device_type`, `name`, and from `reportCapabilities_LinkInfo`: `connector-type`, `display-type` (`LCD`/`CRT`/`NONE`), `av-signal-type`, `port-number`, **`audio-codec-info`** |

System Information's "ROM Revision" row reads `ATY,Rom#` [I]: that is row S4 / item N4 of #33.

`audio-codec-info` [O]: a 10-entry table indexed by the link's transmitter (`AmdLink::getTransmitter`):
`0x00030100, 0x00050100, 0x00070100, 0x00090100, 0x000b0100, 0x000d0100, 0, 0, 0, 0x000f0100`, i.e. HDA pin node
`(3 + 2·n) << 16 | 0x100` (function group 1, codec 0). AppleGFXHDA matches the audio pin to the framebuffer with it
([04](04-power-audio-video.md#43-audio)).

## 2.3 Mode set

`AmdRadeonFramebuffer::setDisplayMode(mode, depth)` [O]:

```c
setDisplayMode(mode, depth):
    pix = getPixelInformation(mode, depth)              // "Couldn't find Pixel Information" on failure
    validate the mode against the display path ("Invalid display mode")
    setProperty ATY,fb_offset / ATY,fb_size / ATY,fb_linebytes
    refresh ATY,fb_maxstretch / maxshrink, ATY,fb_minVTotal / maxVTotal (VRR range for the new timing)
    programDisplayMode()                                 // "Failed: programDisplayMode - displayMode %#x, depth %u"
    gamma->invalidateGamma()                             // the gamma table is re-applied on the next update

programDisplayMode():
    if !AmdTimingUtilities::hasPathChanged(path) return
    presenter->disable transactions while switching
    IOP "WillChange" notification
    if clamshell closed for this link: refuse ("Mode %#x cannot be set for offline framebuffer")
    gamma->setFlatGamma(black)                           // "Blacking Gamma": hides the switch
    dal->setDisplayMode(stream params, surface params)   // DC commit: timing, link training, stream enable
    on failure: "Setting offline" (framebuffer goes offline, not a panic)
    clearPathChangeFlags(); IOP "DidChange"; gamma->invalidateGamma()
```

Timing validation [O]: `validateDetailedTiming`, `validateNativeTimingBandwidth`, `validateDirtyDisplayPathTimingBandwidth`
(bandwidth checked before the mode is offered); `isSoftwareScalerTiming` and `populateScalingCapabilities` (scaled
modes through the DCN scaler, `IOFBScalerInfo`); `getTimingInfoForDisplayMode` / `getInformationForDisplayMode` from
the DC-validated timing list (`AmdTimingList`, `AmdValidatedTimingList`).

Underflow tracking [O]: `AmdUnderflowTracker` per display path (`CFG_UFL_DLY`), `AmdFbPresenter::handleLineBufferHang`.

## 2.4 Link training

Inside DC (`dc_link_dp.c`) [O by path]. The macOS side [O]:

- `AmdLink::trainingBegin` / `trainAttempt` / `trainingEnd`; `trainAttempt` refuses with `not_ready_for_lt`,
  `pattern_not_supported: TPS:%u`, `bit_rate_not_supported` (rate check against the link's capability).
- `AmdLink::setDpLinkConfig` / `getDpLinkConfig`, `auxReadDpcd` / `auxWriteDpcd`, `auxTransactionsAllowed`,
  `setPconParameters` (DP-to-HDMI PCON), `isVRRSupported`.
- AGDC is told about every training: `AmdAgdcServices::trainingBegin/trainingAttempt/trainingEnd`,
  `printDisplayPortTrainingResults`, `translateAmdTrainingResults`. AppleGPUWrangler / AGDC can set the link config
  (`setDPLinkConfigForFB`, `setDPLinkConfigForStream`, `setMultiLinkConfig`) and commit it.
- DSC: `getDscCapability`; DPCD DSC caps parsed in DC ("DPCD DSC bits-per-pixel increment not recognized").

## 2.5 Hotplug

- `AmdHotplugInterrupt` and `AmdHpdRxInterrupt` (short pulse) per link, through `AmdInterruptManager` [O].
  `deferredInterruptHandler` runs on the work loop, `delayedInterruptHandler` after a debounce timer [I from names].
- On HPD: `AmdLink::detectLink` → DC detection (EDID, DPCD) → `AmdRadeonFramebuffer::connectionChange`, which removes
  `IOFBConfig`, `ATY,fb_maxVTotal/minVTotal/maxstretch/maxshrink` and the detailed timings when the sink changed, then
  IOFramebuffer re-probes [O].
- `AmdRadeonController::isPostWakeProbeNeeded`, `requestProbe`, `probeAction` [O]: a re-probe after wake.
- AGDC: `notifyLinkChange`, `injectFbEvent`, `notifyFramebufferReady` [O].

## 2.6 DPMS (display sleep)

`AmdRadeonFramebuffer::setOutputPowerState` [O] logs `[DOZE][IOP] WillSleep` / `DidSleep` notifications and drives
`AmdDalHelper::setDisplayPower` (DC stream/link off, then on). Other paths: `doDoze`, `doSleep`, `doWake`,
`setSystemPowerState`, `powerStateForDomainState`, `registerPowerManagementCapabilities` [O].
`AmdAgdcServices::notifyDisplaySleep`, `setDpSleepValue` (DP sink D3 through DPCD 0x600) [O / I].

## 2.7 Gamma, colour, HDR

- `AmdGammaTable` [O]: `createGamma`, `updateGamma`, `setLinearGamma`, `setFlatGamma` (black during mode set),
  `getColorEntryFromIOPGammaTable`, `convertColorBits`, `invalidateGamma`. `setGammaTable` from IOFramebuffer queues a
  gamma transaction on `AmdFbPresenter` (not a direct register write) unless the path is a special type (0x3000).
- `AmdFbPresenter` [O] holds per-head queues of transactions: flip, gamma, de-gamma, CSC, post-CSC gamma, timing update.
  `processTransactions1stPass`, `processTransactionsVbl`, `transactionVUpdateHandler`, `transactionVBlankHandler`,
  `handleStuckQueue`, `deferredTransactionComplete`. Everything visible changes at VUpdate, atomically per frame.
- AGDC capability queries for the colour pipe [O]: `getFbCapabilityForGamma`, `...ForDegamma`, `...ForCsc`,
  `...ForScaler`, `...ForCursor`, `...ForRotation`, `getFbCapabilityPixelFormats`.
- HDR [O]: `getPQGammaProperties`, `getDegammaProperties`, `getCscProperties` (falcon_dm), CEA HDR static metadata
  ("HDR Static Meta Data", "Dynamic Range - SDR, HDR10, Dolby, Traditional Gamma"), `processSdpInfoPacket`,
  `setSecondaryDataPacket` (AGDC) for the infoframe, `dal/modules/color`.

## 2.8 VRR (Adaptive Sync)

[O]: `setDisplayPathVariableRefreshSupport`, `AmdLink::isVRRSupported`, `AmdFbPresenter::prepareVRR`,
`getMinVTotal`/`getMaxVTotal`, `setLinkAdaptiveSyncSupport`, `composeFalconAdaptiveSyncGenericSDPPacket`,
`composeFalconAdaptiveSyncCustomInfoFrameSDPPacket`, `AmdAgdcServices::getVrrCapability`, `CFG_USE_VRR`,
`ATY,fb_minVTotal`/`ATY,fb_maxVTotal` on the framebuffer. PSR: `AmdDalPsrService` (`CFG_USE_PSR`,
`DalPSRAllowSMUOptimizations`).

## 2.9 DDC, I2C, AUX

- IOFramebuffer DDC [O]: `hasDDCConnect`, `getDDCBlock` (EDID), `setDDCClock`/`setDDCData`/`readDDCClock`/`readDDCData`.
- **IOFramebuffer I2C** [O]: `IOFBI2CInterfaceInfo` on each framebuffer and `doI2CRequest`. IOGraphics builds an
  `IOFramebufferI2CInterface` from these, which is what DDC/CI tools (MonitorControl, BetterDisplay) use on AMD Macs
  [I]. The I2C goes over DC's DDC or AUX-I2C (`AmdDalI2c`, `AmdDalAuxI2c`, `falcon_dm_i2c_aux`).
- AGDC: `i2cStreamAccess`, `i2cTransferHelper`, `auxStreamTransfer`, `getI2cCapabilities` [O].

## 2.10 AGDC services

`AMDRadeonX6000_AmdAgdcServices` (about 155 methods) is the vendor side of AppleGraphicsDeviceControl [O]. The policy
side (AppleGPUWrangler, AGDCPluginDisplayMetrics, WindowServer) queries and sets: port/stream state
(`getPortStatus`, `setStreamState`, `setPortEnableStatus`), link config, scan-out resource config
(`getScanoutResourceConfig`, `testConfiguration`, `commitConfiguration`, `releaseConfiguration`), audio association
(`getAudioAssociation`, `setAudioAssociation`), power (`getPmInfo`, `getPmLimit`, `setPmLimit`,
`setAGDCPowerAdjustment`), test patterns, diagnostics. It also loads the driver: `vendor_doDeviceAttribute(3, ...)`
([01](01-bringup.md#12-match-chain)).

## 2.11 Vermilion today vs this

| Apple | Vermilion | Gap |
|---|---|---|
| AMD DC + falcon_dm computes every timing, trains every link | Replayed Linux captures per mode (`phx_p0odm_*.inc`, `phx_s2_plan_*.inc`) and `PhxDpLink`/`PhxDpRun`/`PhxDpbRetrain` | Own DC-based mode setting (plan B2) |
| `establishBootDisplay` keeps the GOP stream | Squatter / GOP takeover by the daemon | Kernel bring-up (B1) |
| Mode set blacks gamma, commits, re-applies gamma at VUpdate | `phxgamma` head-1 table, head-0 regamma pending (STATUS D22) | Gamma transactions per frame |
| `connectionChange` + DC detect on HPD; re-probe after wake | `phxhotplug.cpp` (connect interrupt), replug broken (STATUS item 5) | Re-detect and re-train on HPD |
| `setOutputPowerState` → DC `setDisplayPower` | Display sleep broken (item 6) | DC power path or Linux's DPMS sequence |
| `IOFBI2CInterfaceInfo` + `doI2CRequest` | Not implemented in `phxfb.cpp` | DDC/CI (item 9): implement both on PhxAMDFB over DP AUX-I2C |
| `audio-codec-info`, `connector-type`, `av-signal-type` from the framebuffer | Set by VermilionAudio on PhxAMDFB | Publish from PhxAMDFB itself |
| `ATY,Rom#` from the VBIOS part number | Absent | N4: read the AtomBIOS part number string (rule 3) |
| HDR: PQ/degamma/CSC through DC colour module, HDR static metadata SDP | Replay HDR modes, widen path, off by flag (item 4) | DC colour pipe for HDR |
| VRR: `ATY,fb_minVTotal/maxVTotal`, Adaptive-Sync SDP | `PhxVrrRamp`, timing range | Comparable; publish the `ATY,fb_*VTotal` keys |
