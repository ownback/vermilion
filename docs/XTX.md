# RX 7900 XTX support

Status of running Vermilion on an RX 7900 XTX (Navi 31, PCI `1002:744c`, revision `0xC8`), the only board this fork
supports. Upstream was built and tested only on an RX 7900 XT (revision `0xCC`); the XT was dropped on 2026-11-25
(owner decision, [decisions.md](../.agents/decisions.md)). This page lists what is the same as upstream's XT, what
differs and what needs doing, after the section that says which boards start. The audit behind it: [`.agents/findings/2026-11-18-xtx-port-audit.md`](../.agents/findings/2026-11-18-xtx-port-audit.md).

**Status (2026-11-22):** macOS runs accelerated on the XTX machine ([REFERENCE-MACHINES.md](REFERENCE-MACHINES.md)); its
2560x1440 monitor works fully (every rate to 240 Hz, Adaptive Sync, HDR; section "A 1440p monitor"). The table of
differences below is from the source audit of 2026-11-18 and was not re-checked when this status was written.

## Supported board

`1002:744c` is one device ID for four boards (libdrm `amdgpu.ids`): the PCI revision says which.

| Revision | Board | Vermilion |
|---|---|---|
| `0xC8` | RX 7900 XTX | **starts.** Read on the XTX machine (XFX Speedster MERC 310, [REFERENCE-MACHINES.md](REFERENCE-MACHINES.md)) |
| `0xCC` | RX 7900 XT | refused. Upstream's board; this fork has never run on one |
| `0xCE` | RX 7900 GRE | refused (untested) |
| `0xCF` | RX 7900M | refused (untested) |
| any other revision, any other device | | refused |

How it is enforced (VermilionBoot b161, VermilionAccel 0.1.1, VermilionAudio 1.7.3; one header,
`src/vermilion-boot/PhxGpuId.h`, host test `tests/kext/gpu_id_test.cpp`):

- `PhxBringup::probe`/`start` and `PhxFBSquatter::probe`/`start` read the PCI vendor, device and revision, and start
  only on `1002:744c` rev `0xC8`. Otherwise they log one line (`Vermilion: 1002:744c rev cc is RX 7900 XT, not an RX
  7900 XTX ...`) and return nil / false. Before that point no BAR is mapped, the bus-master and memory-enable bits are
  untouched and `phxfb-squat` stays in NVRAM, so the card keeps the firmware's display and macOS's own driver.
- `NMXAccel::probe`/`start` repeat the check (the second gate). VermilionAudio patches AppleGFXHDA only when the GPU's
  registry `revision-id` is `0xC8`. VermilionTrust never looks at the GPU.
- On a refused board the boot daemon finds no `phx-build` property and takes its existing fallback after its wait
  (it never writes a register without the kext).
- Not verified: every refusal path except the XTX's start. There is no other card on the XTX machine; the match
  decision is covered by the host test (every revision byte, other devices and vendors, a dead function).

## Same as the XT (no change needed)

The XTX is the same die with nothing disabled. These were checked against the XTX under Linux:

- IP versions (GC 11.0.0, PSP/SMU 13.0.0, DCN 3.2, VCN 4.0.0) and IP-discovery register bases.
- `GB_ADDR_CONFIG = 0x545` (asserted by `vcn_up.sh`).
- Firmware: the same non-kicker files. Linux picks kicker firmware only for other device/revision pairs.
- PSP TMR size `0x1300000` and VRAM base `0x80_0000_0000`.
- VRAM size: the kext reads it from the memory controller, so 24560 MiB is picked up automatically.
- Connector table: the XTX VBIOS has the same four paths as the hardcoded table in `PhxDdc.h`.
- Power limits and fan curves come from the card's own firmware. Vermilion sends no power-limit or fan messages.
- The kext matches `0x744c1002` and (since build 161) starts only on revision `0xC8`; it names the card "AMD Radeon RX
  7900 XTX" (see "Supported board").

## Differences that need code changes

| # | What | Where | Fix | Impact if left |
|---|---|---|---|---|
| 1 | RADV canned profile is the XT's: 84 CU, 320-bit, 4 of 24 cache channels off | `patches/mesa/0016` | **Done in `0018` (thread 02):** revision `0xC8` took Mesa's own `navi31` entry (96 CU, 384-bit, no GL2 channel off). Side-loaded on the XTX machine 2026-11-23: `metalbench render 2000` 4.86 -> 3.93 ms per frame. **Then (2026-11-26, branch `ownback/device-info`, not on hardware yet):** `navi31_xt` and the revision switch are gone (0016 adds only `navi31`), and with VermilionBoot b168 (ABI 1.13) RADV takes the device info from the kext, which reads the IP discovery table and the GC harvest registers as Linux does ([finding](../.agents/findings/2026-11-26-device-info.md)). With an older kext the `navi31` entry answers | Works, but extra cache flushes (`tcc_rb_non_coherent`), the GPU reports 84 cores |
| 2 | Two shims compare the profile name to `"navi31_xt"` exactly | `patches/mesa/0017` (`acd_vcn`), `0016` (marketing name) | **Done:** the VCN shim matches `navi31` (`0017`); the name is the kext's (`PhxGpuId.h` `marketingName`, "AMD Radeon RX 7900 XTX", patch `0018`), and the plugin's `MTLDevice.name` is that name alone (2026-11-26, not on hardware yet) | With another profile: no video decode, wrong name ("RX 9070 XT") |
| 3 | GFXHUB `SYSTEM_APERTURE_HIGH` hardcoded for 20 GiB (`0x00213fbf`) | `tools/phxctl/mesboot.c:131` | `0x00217fbf` for 24 GiB, better: derive from `FB_LOCATION_TOP` | Latent: nothing uses VRAM above 20 GiB today |
| 4 | HUBP1 aperture in pipe-1 plans (`0x00213fff`) | `phx_s2_plan_*.inc` | `0x00217fff`, or derive | Latent; pipe 1 is the second-monitor path |
| 5 | Metal core count 84 | `src/metal-plugin/nvmtl_corecount.c` | **Done:** `gpuCoreCount` is RADV's `activeComputeUnitCount` (`VK_AMD_shader_core_properties2`), 96 with the `navi31` entry; with b168 it is the kext's `cu_active_number` (unverified on hardware) | Cosmetic |
| 6 | Docs said revision `0xCC` only | `README.md`, `docs/INSTALL.md`, `bringup_navi31.sh` | **Done (2026-11-25):** the docs name the XTX only; the XT is refused | Cosmetic |

## A 1440p monitor (LG ULTRAGEAR+, 2560x1440 at up to 240 Hz)

Upstream's display code is built around two 1080p monitors. On the XTX machine, with one 2560x1440 DisplayPort monitor
(LG 27GS95QE, an OLED), all of this works from System Settings > Displays. Verified on the XTX machine, 2026-11-20 to
2026-11-22, with VermilionBoot b150; nothing here has run on another card or monitor.

| At 2560x1440 | State |
|---|---|
| 60, 120, 144 and 240 Hz, in any order | works |
| Variable (60-240 Hz): Adaptive Sync | works; some flicker is left near the low end (the panel's, see below) |
| High Dynamic Range at 60, 120, 144 and 240 Hz, drawn in 10 bits per colour | works |
| Variable with High Dynamic Range on | works |
| The login screen at the saved rate | works |

The other modes the monitor lists (1920x1080 at 60 and 120 Hz, 1280x1024, 1024x768, 800x600, 640x480) work at their
fixed rates and the desktop resizes. They have no Variable and no HDR: the owner of the machine uses only 2560x1440
([decisions.md](../.agents/decisions.md), 2026-11-22).

How each part works:

- **The rates.** 240 Hz runs HBR3 with FEC, DSC and ODM 2:1, as Linux drives it. VermilionBoot's replay engine
  (`PhxP0Odm.h`, `phx_p0odm.cpp`) replays Linux's own mode sets, captured on the same card and monitor
  (`tools/capture/linux_display_capture.py`) and turned into plans by `tools/capture/p0odm_from_trace.py`. Every switch
  goes through Linux's 144 Hz and retrains the link at the rate Linux used for the mode. The plans hold only what Linux
  wrote on this ASIC; a switch that fails its checks goes back to 144 Hz with the mode's own return plan.
- **The other sizes.** PhxAccel reports each mode's own geometry with Linux's 256-pixel pitch and the desktop resizes.
- **GPU present** (the Metal plugin flips the display itself) draws 2560x1440 at every rate. It runs only at the size
  it started at; the other sizes are drawn by the CPU copy. A size change gives the plane back first.
- **Adaptive Sync.** PhxAccel publishes the timing range with Apple's VRR flag and a variable twin of the 240 Hz mode,
  so System Settings offers "Variable (60-240 Hz)" next to the fixed rates. Picking it turns on OTG0's V_TOTAL range
  the way Linux's DCN 3.2 code does on a firmware without fw-assisted mclk switching (which the GOP's DMCUB build is),
  double buffered as on Linux, and each flip fires Linux's manual trigger. The trigger comes from GPU present, so
  Variable exists only at 2560x1440.
- **The floor and the ramp.** The LG flickers when the frame length jumps (an OLED's brightness follows it; the same
  monitor does it on Windows and Linux). Two things reduce it. The floor: Variable goes down to 60 Hz, not to the
  EDID's 48. The ramp (`PhxVrrRamp.h`): from one flip to the next the frame length may change by at most 5 %. Some
  flicker is left.
- **HDR.** PhxAccel lists an HDR10 twin of each 1440p rate (and one of Variable); System Settings then shows "High
  Dynamic Range". The twins switch to Linux's HDR mode sets: 10 bpc on the link, BT.2020, the PQ mastering infoframe,
  and a 10-bit scan-out (ARGB2101010). WindowServer's 10-bit surfaces reach the screen without being narrowed to 8
  bits, by GPU present and by the CPU copy. HDR is offered only together with Adaptive Sync's timing range.

### Display settings

Everything is on by default when the monitor and the installed kexts support it. The files live in `~/gpu` and are
read by the boot daemon at the next restart ([INSTALL.md](INSTALL.md), 7.3); the sysctls take effect at once and
last until the restart.

| Knob | What it does |
|---|---|
| `~/gpu/phxboot-p0modes` (present) | needed for all of the above: head 0 lists the monitor's modes instead of one |
| `~/gpu/phxboot-vrrmin` (value: Hz) | Variable's lowest rate: `0` = the EDID's minimum (48 on the LG), or 24-240. Without the file: 60. A new value makes macOS treat the monitor as a new display (below) |
| `~/gpu/phxboot-novrr` (present) | no Variable in System Settings. HDR goes with it |
| `~/gpu/phxboot-nohdr` (present) | no High Dynamic Range in System Settings |
| `sudo sysctl -w debug.phxvrr_ramp=N` | the ramp in % per flip: 1-50, default 5; `0` = no ramp (the full range at once). On the LG, 5 flickered least; 10 and 20 flickered more |
| `sudo sysctl -w debug.phxvrr_floor=N` | the floor in Hz, live (24-255), for trying values. The next mode switch puts back the boot value, and the label in System Settings does not change |
| `sysctl debug.phxvrr_stat` | Adaptive Sync's state: on / off and why, OTG0's range registers, the ramp's window, the floor, the measured rate |
| `sysctl debug.phxp0odm_stat` | the replay engine's last run: result, the mode now, the last failure, every link window's training (`train_wN`), the recoveries and re-switches (`recovery:`), the trainers' DPCD retries (`dpcd_aux:`) |
| `sysctl debug.phxfb0_scan10` | 1 while the scan-out is 10-bit (HDR on) |

Things to know:

- **A floor change resets the display's settings in macOS.** System Settings names "Variable (N-240 Hz)" after the
  EDID's minimum rate, so PhxAccel serves macOS an EDID with the floor in it. macOS identifies a display by its EDID:
  with a new floor it sees a new display and starts over with the colour profile and the per-display settings. Seen
  on the XTX machine. Leave the floor alone and nothing resets.
- **Colour profiles.** macOS keeps one colour profile per display, not one for SDR and one for HDR. The XTX machine's
  owner switches between two profiles with a small Swift script, `~/gpu/tools/colorprofile.swift` (`hdr`, `sdr`, or no
  argument to show the current one). It is not part of this repository.
- **After a PhxAccel update, click Allow** in System Settings > Privacy & Security before restarting. Without it macOS
  does not rebuild the Auxiliary Kernel Collection and the old PhxAccel keeps loading
  ([findings](../.agents/findings/2026-11-22-vrr-underflow-and-auxkc.md)).

Background: what macOS needs for Adaptive Sync
([findings](../.agents/findings/2026-11-20-adaptive-sync-research.md)), HDR
([findings](../.agents/findings/2026-11-21-hdr.md)), the underflow that came with un-buffered range writes
([findings](../.agents/findings/2026-11-22-vrr-underflow-and-auxkc.md)), and the install and test log
([findings](../.agents/findings/2026-11-22-display-polish-log.md)).

**NVRAM:** `DisableVariableWrite` stays on (the installer hangs on this board without it), so macOS can't clear
`phxfb-squat`. A failed accelerated boot used to reboot in a loop; since 2026-11-20 the boot daemon notices that the
squat survived its reboot and brings up a safe desktop instead (`~/gpu/phxboot-nvstuck`)
([findings/2026-11-20-b138-freeze-and-squat-loop.md](../.agents/findings/2026-11-20-b138-freeze-and-squat-loop.md)).
The squat is the intended state: `phxfb-squat` is set from Linux, and every OpenCore boot is a squat boot.

**Never Reset NVRAM** (hard rule 1). It deletes `phxfb-squat`, macOS can't set it again, and every later boot runs on
the firmware display with a phantom display. For that reason the EFI builder leaves the picker's Reset NVRAM entry out
of the live stage (`vermilion-trust-bar1g-audio`; not booted yet, unverified). Recovery after a failed boot instead:
- **Safe desktop after a failure:** nothing to do. The daemon keeps the failure record in `/var/db/phxboot.fails` and
  tries the full desktop again after one clean safe-desktop boot (after 3 failures in a row, after 3), and says why in
  one notification after login (since 2026-11-25, phase 2 item 3 step 1; mock-tested, unverified on hardware).
- **Dark screen** (the safe desktop didn't finish the boot before): ssh still reaches the machine. Restart once and the
  next boot tries the safe desktop again.
- **A bad change:** boot-arg `-phxbringupoff` for one boot, the kill switch (`touch ~/gpu/phxboot-off`, or from Linux
  `touch /boot/vermilion/flags/phxboot-off`), or the previous EFI (`EFI/OC.prev`,
  [runbooks](../.agents/runbooks.md)).
- **Linux to macOS:** always a full power-off. If the boot log says `warm GPU: bring-up refused`, shut down, power on
  and boot macOS again. The refusal writes nothing to the GPU and doesn't count as a failed attempt: the daemon doesn't
  restart the machine, and the next cold boot runs the full desktop. On a squat boot (every boot here) the screen stays
  dark until the power-off: the kext can't hand the display back yet (plan step 3). From the daemon's code and the
  mocks; unverified on hardware.

## First boot on the XTX

Use upstream's guide ([INSTALL.md](INSTALL.md)) with these differences:

- Flags: only `phxboot-sdma`, `phxboot-cg`, `phxboot-uclk` (`456`). No `phxboot-m7*`, `phxboot-aoc*`, `phxboot-b15*`.
- Power off fully when coming from Linux.
- First boot without desktop arm (apps get Metal, the GOP keeps the screen), then the squat boot.
- Watch GPU temperature and power for the first minutes. Without clock gating the idle card runs hot.
- On the XTX machine the desktop without a driver is too slow to type in, so the files go in from Recovery:
  `tools/phxctl/esp_stage.sh` (Linux) puts them on the EFI partition and `tools/phxctl/recovery_install.sh` installs
  them; later flags come through `<EFI>/vermilion/flags/` (`tools/phxctl/esp_flags.sh`). Steps:
  [`.agents/runbooks.md`](../.agents/runbooks.md).
