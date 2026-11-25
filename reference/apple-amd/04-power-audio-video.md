<!-- SPDX-License-Identifier: MIT -->

# 4. Power, audio, video

Tags: [O] observed, [I] inferred, [?] open.

## 4.1 Power: PowerPlay in the kernel

- **SMU and DPM live in HWLibs** (`AtiPowerPlayServices`, C `PHM_*`, `PEM_*`, `PECI_*`, `PhwNavi21_*`; SMU firmware
  `navi21_smc_firmware`) and are driven from the framebuffer's `AmdPowerPlayHelper` [O]: `powerUp` (publishes
  `SMC_VERSION`, `PPLIB_VERSION`, `FB_Boot_PPInitialized`), `completeInit` (`FB_Boot_PPCompleteInit`),
  `gfxOffControl`, `notifyGfxOffChange`, `dfCStateControl`, `getPowerLimit` / `setPowerLimit`,
  `initializePowerTuneParameters`, `generatePowerTuneTable` / `validatePowerTuneTable` /
  `readOverridePowerTuneTable`, `handleCriticalError`, `sleep` / `wake`, `cwddepm` (the PowerPlay escape interface).
  PowerPlay knobs come from the controller personality (`PP_*`, `SMU_DisallowedFeatures`, #33).
- **Accelerator side** [O]: `AMDRTHardware::enableGfxOff` / `disableGfxOff` / `isGfxOffSupported`,
  `AMDHardware::requestStablePState` (profiling), `getStableClockMode`, `samplePMStatistics` (SMU metrics into the
  statistics, [03](03-accelerator.md#36-performancestatistics-and-ioreport)), `sendPMCommand`,
  `sendRequestToPowerManager`, `reportEventToPowerManager`, `dpm` = 1 on the accelerator.
- **Sleep / wake / power off** [O]: `AMDHardware::powerOff` = `disableGfxOff` → `disableInterrupts` →
  `stopHWEngines` → `powerOffHWEngines` → (TTL suspend, unnamed) → `disableTransactions`. `powerUp` is the reverse
  ([01](01-bringup.md)). The controller's `sleep` / `wake` re-run `BiosParser::powerUp` and message the accelerator
  (`messageAccelerator(7)`, then `(6)`). Neither kext overrides `IOService::systemWillShutdown` (not in their
  vtables) [O]: a restart reaches the GPU through power management taking the device to its off state [I].
- **Power budget service** [O]: `AMDRadeonServiceManager` → `AMDRadeonPowerService` and
  `AMDRadeonPowerDomainController` (`calculateGPUUtilization`, `redistributePower`, `sendPowerLimitToIOFB`,
  `pwrDomainTimerHandler`). It starts only when the PCI device has `PM_PWR_GEMINI_BGT` or `PM_PWR_SINGLE_BGT`
  (dual-GPU or single-GPU board budget, Apple MPX boards), polled every `PM_PWR_POLLING_MS`. A PC card has neither
  [I].

### AGPM

`AGPM` (`com.apple.driver.AGPM`, `AGPMController` on `IOPlatformPluginDevice`) has per-board, per-GPU entries [O].
For the 2019 Mac Pro (`Mac-27AD2F918AE68F61`, the reference machine's SMBIOS model) the AMD entries are
`Vendor1002Device{66a3,66a7,67df,6867,686d,686e,7310,7340,73a2,73ab,73e0}`, each `AGDCEnabled` 1,
`Heuristic` `{ID -1}`, `control-id` 17, `min-power-state` 0, `max-power-state` 15; plus `SlotControl` 1. Neither
`0x744c` nor the consumer `0x73bf` is listed.

`Heuristic ID -1` means no AGPM heuristic runs for these GPUs [I]: the AMD driver does its own DPM in the SMU, and
AGPM only reaches the GPU through AGDC (power limits, thermal: "setAttribute to FB driver with kIOAGPMThermal").
For Vermilion this downgrades #33's N8 ("power-policy node"): a missing AGPM entry is what a Mac Pro with a 6900 XT
has too.

## 4.2 Video

- **Kernel** [O]: VCN engines `AMDVCN3HWEngine` (Navi 21), `AMDVCN2HWEngine`; rings `AMDVCN3UnifiedRing`,
  `AMDVCN2DecRing`, `AMDVCN2EncRing`, `AMDVCN2EncLLQRing` (low latency); contexts `AMDAccelVideoContext`,
  `AMDAccelVCNContext`, `AMDAccelPspContext` (protected content), `AMDPspDecAppInterface`. Vendor selectors
  `CreateVcnContext` (0x107) / `RemoveVcnContext` (0x108). VCN firmware `aucVcn3v0_Firmware` from HWLibs
  (`ativvaxy_vcn3.dat`, PSP-loaded unless `EnableSwVCNFWLoading`).
- **Registry keys the accelerator publishes** (`configureDevice`, `start`, personality) [O]: `IOGVACodec` =
  `AMDVCN2`, `IODVDBundleName` = `AMDRadeonVADriver2`, `IOVARendererID` = `0x1020000 | n`, `IOGVAHEVCDecode` /
  `IOGVAHEVCEncode` = "1" (gated by `MM_EnableHEVCDecode` / `MM_EnableHEVCEncode`), `IOGVAHEVCDecodeCapabilities`
  (`VTSupportedProfileArray` [1, 2, 3], `VTPerProfileDetails` with `VTMaxDecodeLevel`), `IOGVAHEVCEncodeCapabilities`
  (`VTRating` 350, `VTQualityRating` 50, profiles [1], `VTMaxEncodeLevel`), `IOGVAH264EncodeCapabilities`.
  Fallback on some families: `IOGVACodec` / `IOGVAEncoderRestricted` = `VCE`.
- **AppleGVA reads** [O]: `IOGVACodec`, `IODVDBundleName`, `IOGVAHEVCDecode(Capabilities)`,
  `IOGVAVP9Decode(Capabilities)`, `IOGVAScaler`, `IOVARendererID`, `IOVARendererSubID`. AMD publishes no VP9 key: a
  Mac with an RDNA 2 GPU decodes VP9 in software [I].
- **User space** `AMDRadeonVADriver2` [O]: GVA vendor interface `AvdVAInterface` (`CreateDriver`, `CreateContexts`,
  `ScheduleAVDCommands`, `QueryAVDCommandStatus`, bitstream / pixel buffer pools), `AvdCapability`. Decoders:
  `AvdAvcDecDataProcessor` / `AvdVcnAvcDecDataProcessor` (H.264), `AvdHevcDecDataProcessor` (HEVC),
  `AvdVcnAv1DecDataProcessor` (AV1); encoders: `VAAvcEncoder`, `VAHevcEncoder`, `Vcn2Encoder`, `Vcn3Encoder`,
  `AVDVcn3HevcEncDataProcessor`, `AVDVcn3AvcEncDataProcessor`, header encoders. Post-processing on GFX
  (`Gfx10GraphicsCommand`, `Gfx10ShaderManager`, `VADynamicContrastEnhancer`). Kernel access only through the
  IOAccelerator framework (`IOAccelVideoContextCreate`, `...SubmitDataBuffers`, `...GetSidebandBuffer`,
  `IOAccelResourceCreate`) and `IOConnectCallMethod` [O].
- AV1: the decode processor exists in the bundle, but no AV1 key is published by the X6000 personalities [O]; whether
  AppleGVA offers AV1 on this path is [?].

## 4.3 Audio

DP/HDMI audio on Apple's stack is AppleGFXHDA (`com.apple.driver.AppleGFXHDA`, about 2861 functions analysed) driven
by the framebuffer's published properties [O]:

1. The framebuffer publishes `connector-type`, `av-signal-type`, `display-type`, `port-number` and
   **`audio-codec-info`** (`pin NID << 16 | 0x100`, by transmitter) in `reportCapabilities_LinkInfo`
   ([02](02-display.md#properties-published-all-o)). AppleGFXHDA asserts that `av-signal-type` is present by the
   2nd `kIOFBNotifyDisplayModeDidChange` ("Graphics vendor supplied 'av-signal-type' property not published...").
2. `AppleGFXHDAController::framebufferEventHandler` tracks every IOFramebuffer notification (mode will/did change,
   sleep, wake, power on/off, speed change) and records it as `IOFBEvent` [O].
3. `findValidDisplayCodec` walks framebuffers (`AAPL,DisplayPipe`, `audio-codec-info`) to pair a pin with a display
   [O]. `gfxMatchedHandler` reads `IODisplayEDID` from the `IODisplay` and names the endpoint `dp%X%X` [O].
4. `edidIsValidForAudio` requires a CEA extension (tag 2, revision ≥ 3, basic-audio flag) and honours
   `DPAudioDeviceExclusion` [O]. Valid → `handleValidEDID` (ELD to the codec, stream allocation, AFG power state);
   invalid → `handleInvalidEDID` [O].
5. No AMD-specific audio programming happens in the AMD kexts: the GPU side (AZ endpoint enable, DTO, infoframe) is
   DC's `dcn30_afmt` / `dce_audio` running inside the framebuffer kext during the mode set [I from the DC file list].

For Vermilion: VermilionAudio sets `connector-type`, `av-signal-type`, `AAPL,DisplayPipe`, `audio-codec-info` on
PhxAMDFB from outside, and the daemon programs DC audio. Apple's order is: the framebuffer publishes these itself at
link setup, and DC enables the audio endpoint in the same mode set. The placeholder device strings and the stray byte
(#33 K15, STATUS item 8) come from the EDID path above; a framebuffer that publishes the properties before the 2nd
`DidChange` and serves a valid CEA block is the Apple path [I].
