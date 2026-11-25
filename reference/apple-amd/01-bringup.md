<!-- SPDX-License-Identifier: MIT -->

# 1. Classes, match and bring-up

Tags: [O] observed in code/strings/plist, [I] inferred, [?] open ([README](README.md)).

## 1.1 The pieces

| Kext (bundle id) | Main classes | Role |
|---|---|---|
| `com.apple.kext.AMDSupport` | `AMDSupport`, `ATIController`, `ATIConnector`, `AtiDeviceControl`, `AtiGpuWrangler`, `Edid`, `DDCProxy`, `AuxChannelProxy`, `DPTrainingSettingsCalculator`, `AtiHdcp*` | Shared library for every AMD generation (pre-DC display code, EDID parser, HDCP). For Navi it only matches every AMD display-class PCI device (`IOPCIClassMatch 0x03000000&0xff000000`, `IOPCIMatch 0x00001002&0x0000ffff`, score 65050), sets `iofb_version` = `1.1.50` and registers [O]. |
| `com.apple.kext.AMDRadeonX6000Framebuffer` | `AMDRadeonX6000_AmdGpuWrangler`, `..._AmdRadeonController{Navi10,12,14,21,23}` (base `..._AmdRadeonController`, `...Navi`, `...Navi2`), `..._AmdRadeonFramebuffer`, `..._AmdDalHelper`, `..._AmdBiosParserHelper`, `..._AmdPowerPlayHelper`, `..._AmdLink`, `..._AmdFbPresenter`, `..._AmdAgdcServices`, `..._AmdHdcpProxy`, interrupts | Display: controller, framebuffers, AGDC services, and **AMD's DC compiled in** ([02-display.md](02-display.md)) [O] |
| `com.apple.kext.AMDRadeonX6000HWServices` | `..._AMDRadeonHWServicesAbstract` → `...SWIP` → `...Navi`; `..._AMDRadeonHWServicesInterface` | Matches the PCI device, picks the per-ASIC HWLibs plug-in, hands out the TTL interface [O] |
| `com.apple.kext.AMDRadeonX6{000,100,200,300,700,800,810}HWLibs` (plug-ins of HWServices) | `AMDRadeonX6800_AMDRadeonHWLibs{,SWIP,X6800}`, `AmdTtlServices`, `AtiPowerPlayServices`, `AtiAppleMcilServices`, `AMDFirmwareDirectory`; C code `ttl_*`, `Ipi*`, `psp_*`, `smu_*`, `gc_*`, `sdma_*`, `mes_*`, `vcn_*`, `PHM_*`/`PEM_*` (PowerPlay) | AMD's SWIP layer (the IP init library), PowerPlay, and **every firmware image** [O] |
| `com.apple.kext.AMDRadeonX6000` | `..._AMDNavi{10,12,14,21,23}GraphicsAccelerator` (base `..._AMDGFX10GraphicsAccelerator` → `..._AMDGraphicsAccelerator` → `IOGraphicsAccelerator2`), `..._AMDNavi21Hardware` (→ `AMDGFX10Hardware` → `AMDRTHardware` → `AMDHardware`), PM4 engines, SDMA, VCN, VM, user clients | Accelerator ([03-accelerator.md](03-accelerator.md)) [O] |
| `com.apple.kext.AMDRadeonServiceManager` | `AMDRadeonServiceManager`, `AMDRadeonPowerService`, `AMDRadeonPowerDomainController` | Power budget service between GPUs (and XGMI hives) [O] ([04](04-power-audio-video.md)) |

Class hierarchy of the accelerator's hardware object (from vtables) [O]:

```
AMDRadeonX6000_AMDHardware                 // MCIL callbacks, engines, doorbells, PM statistics, timers
  └ AMDRadeonX6000_AMDRTHardware           // TTL (SWIP) client: initializeTtl, GfxOff, reserved VRAM for SWIP
      └ AMDRadeonX6000_AMDGFX10Hardware    // GFX10: VM hubs, GART, PM4 utility, hang diagnosis, perf counters
          └ AMDRadeonX6000_AMDNavi21Hardware // Navi21 specifics: PSP runtime DB, XGMI, STB postcodes, clocks
```

## 1.2 Match chain

Everything matches the same `IOPCIDevice` (the GPU's function 0). The order is set by properties on that device:

```
IOPCIDevice 1002:73xx
 ├─ AMDSupport                      (score 65050; always)
 ├─ AMDRadeonX6000_AmdGpuWrangler   (IOMatchCategory IOFramebuffer, score 60000; no property gate)
 │    start(): registerService; sets "AMDRadeonLoadSvcMgr"=1 on the provider     [O]
 │    AppleGPUWrangler / AGDC later calls vendor_doDeviceAttribute(3, mask):     [O]
 │        mask & 2 → provider "LoadHWServices"=1, registerService
 │        mask & 1 → provider "LoadController"=1
 │        mask & 2 → provider "LoadAccelerator"=1
 │        mask & 3 → provider registerService  (re-runs matching)
 ├─ AMDRadeonX6000_AMDRadeonHWServicesNavi  (IOPropertyMatch LoadHWServices, score 65051)
 │    └─ AMDRadeonX6800_AMDRadeonHWLibsX6800 (provider = HWServicesInterface, IOPropertyMatch LoadPlugIn = "Load6800")
 ├─ AMDRadeonX6000_AmdRadeonControllerNavi21 (IOMatchCategory ATIFramebuffer, score 1000, IOPCIUseDeviceMapper)
 │    plist IOPropertyMatch present but empty in the dump; gated by LoadController [I]
 └─ AMDRadeonX6000_AMDNavi21GraphicsAccelerator (IOMatchCategory IOAccelerator, IOPropertyMatch LoadAccelerator)
```

Correction to #33's finding: `LoadAccelerator` is set by the AMD wrangler on a request from Apple's GPU wrangler,
not by `AMDSupport` [O] (`AMDSupport::start` sets only `iofb_version`).

How HWServices picks the plug-in [O] (`HWServicesAbstract::start`, `HWServicesNavi::getMatchProperty`):

```c
start(provider):
    pci = OSDynamicCast(IOPCIDevice, provider)
    populateDeviceInfo()        // config reads: vendor 0x00, device 0x02, revision 0x08, subsys 0x2c/0x2e
    projectName = readProjectName()   // an EFI/ROM-supplied property on the PCI device (OSString or OSData)
    setProperty("LoadPlugIn", getMatchProperty())
    registerService(2)          // the HWLibs plug-in matches on LoadPlugIn
    plugIn = findPlugIn()       // client with IOMatchCategory "AMDRadeonHWLibs"
  SWIP::start: ttl = plugIn->callPlatformFunction("AmdTtlInterfaceKey", ..., pci, &ttl)

getMatchProperty():
    prop = "Load6000"                                   // default: the X6000 HWLibs
    if boot-arg -amd_simnow: prop = "Load6000Sim"
    for (name, load) in ProjectNameTable[9]:            // ATY,Henbury→Load6810, ATY,Belknap→Load6800,
        if projectName == name: prop = load             // ATY,Sunbeam→Load6300, ATY,Ikaheka→Load6200,
    return prop                                         // ATY,Python→Load6700, ATY,Boa→Load6100, ...
```

The project names are Apple board codenames that come from the card's Apple ROM / EFI driver [I]. A PC card without
them gets `Load6000` [O for the default; I for what X6000HWLibs does with a Navi 21].

## 1.3 Who brings the GPU up

Both the controller (display) and the accelerator use the same TTL instance from HWServices. The TTL (`ttl_initialize`
in HWLibs) runs AMD's SWIP sequence.

### Accelerator `start` (Navi 21) [O]

```c
AMDGraphicsAccelerator::start(provider):
    event logs "Sleep/Wake", "AccelTask"
    IOGraphicsAccelerator2::start(provider)      // family start; calls configureDevice → createHWInterface
    loadSlotNumber()
    svcMgr = findIOServiceClient("AMDRadeonServiceManager")
    if svcMgr and provider has PM_PWR_GEMINI_BGT or PM_PWR_SINGLE_BGT:
        svcMgr.setProperty("AMDRadeonLoadPowerService", 1); svcMgr.registerService()
        findAndRegisterPowerService()
    acceleratorDidLock()
    hw = this->hw (AMDNavi21Hardware); hw->swTimestampCallback = swTimestampCallback
    if !hw->acceleratorDidStart(): "Failed to init HW Acelerator resources"
    createAccelChannels(true)
    mask out disabled channels from numeric properties
    setDriverBundleNames()                       // MetalPluginName, IOGLBundleName, ... (03)
    setProperty("IOVARendererID", 0x1020000 | n)
    VCE fallback: IOGVACodec/IOGVAEncoderRestricted = "VCE" on some families
    newCPContext(); registerService()
    GPUDCCDisplayable, ZeroFillPattern, GPUTaskSingleChannel from the personality
    acceleratorWillUnlock()
    "=== AMD Graphics Accelerator successfully started ==="

configureDevice(pci):                            // called from the family start
    find the ATIFramebuffer controller client
    createStatisticsManager(); createHWHandler(); hw = createHWInterface(pci)
    setProperty ATY,intrev, ATY,cbits; pci: ATY,SurfInfo, ATY,PageFlipEnable
    AccelNativeDMARowByteAlignment = 0x100, dpm = 1
    setDeviceType(pci)
    MM_EnableHEVCDecode / MM_EnableHEVCEncode → IOGVAHEVCDecode/Encode + capability dictionaries (04)
    XGMI: InfinityFabricLinks, XGMI_Enabled
```

### `AMDHardware::init` (hardware object, the real bring-up) [O]

Order as the code calls it (`AMDRadeonX6000_AMDHardware::init`):

1. `setupAndInitializeConstantHWCapabilities`; `IOPCITunnelled` check.
2. `AMDSWScheduler::create`; `initializeExternalInterfaces` (finds HWServices, gets TTL / PowerPlay / MCIL).
3. `GPUKernelPipelineStats` flag; `getATIChipConfigBit`.
4. `allocateAMDHWRegisters` (MMIO map), `allocatePM4CommandsUtility`, `allocateSML`.
5. `mapDoorbellMemory` (BAR2 doorbells).
6. **`AMDRTHardware::initializeTtl(gartParams)`**: hands TTL the doorbell base and aperture size, VRAM
   allocate/release callbacks (`accelGmmCbAllocateVram`, `accelGmmCbReleaseVram`) and an event-log callback,
   logs the PSP bootloader version / POST code / ready flag (`queryBootLoaderVersion`, `...PostCode`,
   `...Ready`), calls `TTL::initialize()`, then `initPspRuntimeDB`. On failure it writes a PSP, RSMU-timeout and
   STB (smart trace buffer) diagnosis report and the SWIP error log, then fails start. Then `getReservedVRAMForSwip`.
7. `configureRegisterBases` (IP discovery bases), `readChipRevFromRegister`, `initializeHWWorkarounds`,
   `refreshXgmiInfo`.
8. `allocateAMDHWMemory`, `allocateAMDHWGart`, `allocateAndInitAMDHWVMHubs`, `allocateAMDHWVMM`, `setVMRegisters`.
9. `amd_gpu_debug_policy` boot-arg → `GpuDebugPolicy`.
10. `initializeFamilyType`, `initializeGFXEngine`, `setupAndInitializeHWCapabilities`.
11. `allocateHWEngines` (GFX, compute, SDMA, VCN, ...), `initializeHWEngines`.
12. `allocateAMDHWDisplay`, `initMaskSettings`, `initHWInfo`, `setupAlignManager`.
13. Timers: `HWPerfPollIntervalUS`, `StableClockCheckInterval` (03).

`AMDHardware::powerUp` (called on start and wake) [O]: `disableGfxOff` → `setupInternalSpace` →
`enableTransactions` → `powerUpHWEngines` (per engine; "Failed to powerUp engine %u") → `startHWEngines` ("Failed
to start SDMA%u") → `initHWInfo`. `AMDNavi21Hardware::powerUp` adds an XGMI check (logs "configuration has changed
since boot").

### Controller `start` and `powerUp` [O]

```c
AmdRadeonController::start(pci):
    FB_Boot_ControllerStarted = 0; pci->open(this)
    logger, feature manager
    createControllerCoreServices():  RegisterAccess, AsicInfoNavi21, BiosParserHelper (AtomBIOS)
    initialize reserved VRAM
    createControllerServices():      PipeInterruptHelper, UnderflowTracker (CFG_UFL_DLY),
                                     PowerPlayHelper, DalHelper, cursor, HDCP, interrupt manager, ...
    createFbStubs():                 one AmdRadeonFramebuffer per connector, name "ATY,RadeonFramebuffer",
                                     device_type "display"
    FB_Boot_ControllerStarted = 1

AmdRadeonController::powerUp():       // first open / wake [I for the caller]
    FB_Boot_ControllerEnabled = 0
    if !isPoweredUp():
        if bios->isFastVRAMTrainingSupported(): restoreBistTrainingParameters()
        bios->powerUp()                              // AtomBIOS ASIC init through TTL, readFirmwareInfo
        bios->initializeDmcuB(fbSize)                // DMCUB region at the top of VRAM (default 64 KiB)
    if fast VRAM training: saveBistTrainingParameters()
    bios->initializeDisplayController()             // AtomBIOS command table 7
    setupBootWatermarks()
    asicInfo->refresh()
    pp->powerUp()                                    // SMU; failure is tolerated ("Safe-Mode?"), sets SMC_VERSION
    clamshell state → DalClamshellClosedState
    dal->powerUp()                                   // DC create (02)
    pp->completeInit()
    setupCursors(); setupLinks(); setupHdcpServices()
    interrupt manager enable
    reportControllerProperties(); messageAccelerator(6)      // tells the accelerator the display is up
    detectAllDisplays(); establishBootDisplay()               // keeps the EFI GOP mode on its link
    projectFeatures->populateExternalFeatures(); createAgdc()
    bios->removeBiosFromRegistry()
    FB_Boot_ControllerEnabled = 1
```

Properties a real Navi 21 Mac would show from this path [O]: `FB_Boot_ControllerStarted`,
`FB_Boot_ControllerEnabled`, `FB_Boot_PPInitialized`, `FB_Boot_PPCompleteInit`, `PPLIB_VERSION`, `SMC_VERSION`,
`ATY,EFIVersion` (read from the PCI device).

## 1.4 SWIP: the IP init order

`ttl_initialize` [O]:

```c
ttl_initialize(cfg, out):
    if !ttlIsSupportedDevice(cfg.pciIds) return 1
    ttl_sw_init(cfg)        // device info, FB aperture, ZFB, nonlocal mem limit, attributes, overrides,
                            // cgs (register/memory callbacks), PowerPlay ODM check, IpiSwInit, TlsSwInit
    ttl_hw_init()           // TlsHwInit → TlsExecuteIpEntrySeq(stage=hw_init)
    TtlSetRts(...)          // runtime services
    out.flags: device state bit 4, SR-IOV PF
```

`TlsSwInit` validates the topology against IP discovery and builds the device's SWIP list from a static per-ASIC
table. `TlsExecuteIpEntrySeq(stage)` walks the list forward for stages {0, 1, 5, 7} and backward for
{2, 3, 4, 6, 8} (bit masks `0xa3` and `0x158`) [O]; the stage meanings are [I] (0 sw_init, 1 hw_init, others
suspend/resume/fini). A failed IP is recorded in a failed-client bitmap and reported ("SWIP init/power-up failed").

**Navi 21 sequence** (`_swipInfoNavi21`, entries `{swip id, instance count, hwip map}`) [O]:

| # | SWIP id | IP | Linux amdgpu block for comparison [I] |
|---|---|---|---|
| 1 | 3 | BGM (base: VBIOS, PCIe, NBIO) | `soc21`/`nv` common, `nbio` |
| 2 | 5 | GVM (GMC/MMHUB/GFXHUB, GART) | `gmc_v10` |
| 3 | 6 | PSP | `psp` |
| 4 | 8 | SMU | `smu` |
| 5 | 7 | GC (GFX, RLC, CP) | `gfx_v10` |
| 6 | 2 | SDMA | `sdma_v5_2` |
| 7 | 14 | MES | `mes` |
| 8 | 9 | VCN | `vcn_v3` |
| 9 | 15 | JPEG | `jpeg_v3` |
| 10 | 10 | DMCU (DMCUB) | `dm` (Linux runs DM before GFX) |

There is no separate IH (interrupt handler) SWIP: the accelerator programs the IH ring itself [I]. Linux's order for
Navi 21 is common, gmc, ih, psp, smu, dm, gfx, sdma, vcn, jpeg, mes [I]. Apple's moves the display micro-controller
last and MES before VCN.

### PSP [O]

`psp_hardware_initialization` logs, in order: `psp_bootloader_load_sysdrv`, `psp_bootloader_load_sos (tos)`,
"finished loading PSP FWs", then TAs: ASD, DTM, XGMI, RAP, WSPE resume, HDCP resume. `psp_np_fw_load` loads each
non-PSP firmware ("load single non-psp fw", "copy single psp fw to fb"), and checks RLC auto-load ("rlc auto load has
failed"). The ring (`psp_ring_init`, `psp_ring_km_submit`), TMR (`psp_tmr_init/load`) and the command path
(`psp_cmd_km_*`) match the shape of Linux's `psp_v11_0` [I].

### Firmware [O]

All firmware is compiled into the HWLibs kext as constant arrays; nothing is read from disk at run time. In
X6800HWLibs: `_psp_sys_drv_bin_navi21` (128880 B), `_psp_sos_bin_navi21` (82780 B), `_psp_tos_spl_bin_navi21`,
`_psp_key_database_bin_navi21`, `_psp_asd_bin`, `navi21_smc_firmware` (242176 B), CP `_aF32_{ME,PFP,CE,MEC}_Ucode`,
MES `_aRS64_MES_P0_UCODE`, `_atidmcub_instruction_dcn30`, VCN `aucVcn3v0_Firmware` (547200 B). Some are registered by
name in `AMDFirmwareDirectory` (`populateFirmwareDirectory`: `ativvaxy_vcn3.dat`, `PP_SMC_UCODE_SBIN` with the
`SMU_FalconEnableSideLoading` key). `psp_get_external_fw` returns 2 (none): there is no external-firmware path [O].

## 1.5 What this means for Vermilion

- Apple brings the GPU up in kernel `start()`, with firmware inside the kext, before WindowServer. Vermilion's
  daemon-driven bring-up (STATUS D3, plan B1) is the main gap. The order to copy is the SWIP table above, which agrees
  with Linux amdgpu's block order except for DMCU. Our hard rule (no SMU/PSP message Linux doesn't send on Navi 31)
  stands: Apple's order is the reference for structure, Linux amdgpu's Navi 31 sequence for the exact messages.
- Apple's start fails cleanly and writes a PSP / RSMU / STB diagnosis report when TTL init fails. Our bring-up
  watchdog should do the same in the kernel (log the PSP bootloader version, POST code, ready flag before PSP init).
- The two-step match (wrangler sets `Load*` properties, then `registerService`) is Apple's pattern; ours sets
  `nmxgpu-claimed` from user space (#33 K2). In the kernel version, `PhxBringup` would set the property itself after
  bring-up succeeds, the same shape.
- Firmware in the kext is what Apple ships. For us the owner decided: not shipped, fetched by a post-install script
  (decisions, 2026-11-25). The kext should then load it from its own bundle at `start()` (an `AMDFirmwareDirectory`
  equivalent keyed by name), not from `~/gpu`.

Full mapping: [06-vermilion-map.md](06-vermilion-map.md).
