<!-- SPDX-License-Identifier: MIT -->

# GPU bring-up in the kernel: design (B1, 2026-11-26)

Parity week item B1 ([PLAN-parity-week.md](../PLAN-parity-week.md); STATUS rows D2, D3, D28, A1, A10, M "DP audio",
M "GPU idle power", M "Release shape"). Design only: nothing here was built, installed or booted. Code read on
`fork/main` (`ccfd909`, VermilionBoot b162). Measured read-only on the XTX machine (macOS 26.7.1 25G241, VermilionBoot
b162 live), from `/var/log/phxboot.log`, the unified log and `ps` of the boot of 2026-11-26 00:51. Anything
not tested on hardware is marked (unverified). Linux function names are from the amdgpu tree the repo's traces came
from (6.8 for the PSP log, taken on upstream's XT; 7.2.15 for the display traces, taken on the XTX).

**Earlier B1 work.** `git ls-remote fork 'refs/heads/ownback/kernel-bringup*'` found nothing. A local branch
`ownback/kernel-bringup-design` (no commits of its own) has an uncommitted, unreviewed draft
`2026-11-25-kernel-bringup-design.md` in worktree `ownback-8587cbab`. This note supersedes it. It keeps the draft's
inventory method, failure rules and flag table, and changes three things: the firmware is no longer compiled in
(decision F1, #43), the engine is organised as Apple's SWIP block table, and a timing measurement (1.1) shows that the
AuxKC, not the bring-up, decides when Metal can exist.

## Summary

- **Goal.** As on a real Mac, VermilionBoot brings the GPU up itself, structured as Apple's AMD driver is (the SWIP
  blocks BGM, GVM, PSP, SMU, GC, SDMA, MES, VCN, JPEG, DMCU; [01-bringup.md](../../reference/apple-amd/01-bringup.md)
  1.4), with exactly the writes and messages the daemon sends today (verified on the XTX machine) and that Linux amdgpu
  sends on Navi 31. Where Apple's block order and Linux's position of a write differ, Linux's position wins (the
  review: the GFXHUB can't be programmed before the RLC autoload). The daemon shrinks to a go/no-go (owner decision
  D-K).
- **A live problem the review found** (section 7, A): today's UCLK pin (`uclk.sh`, flag `uclk`, every boot) sends
  the driver-mailbox `SetHardMinByFreq` (0x1B), which Linux never sends on SMU 13.0.0. Linux sets the UCLK hard
  minimum through the DAL mailbox from DC. That breaks hard rule 1 now, independent of B1: item U1.
- **The measurement that shapes the plan** (1.1): the first WindowServer starts 2.6 s after boot, kernelmanagerd loads
  the AuxKC at 3.2 s, and VermilionAccel becomes loadable at 6.8 s. With VermilionAccel in the AuxKC (B3 dropped),
  NMXAccel can never exist before the first WindowServer, however fast the kernel brings the GPU up. So "no
  WindowServer restart" depends on the first WindowServer adopting a Metal device that appears late. SkyLight imports
  `MTLCopyAllDevicesWithObserver` and Metal exports `MTLDeviceWasAddedNotification` (the eGPU path; `dyld_info` on the
  XTX machine), so it may. A daemon-only test (T1) decides it before any kernel step depends on it.
- **Firmware** reaches the kext at `start()` through `VermilionFirmware.kext`: a codeless kext that the installer
  generates on the user's machine from the fetched linux-firmware files and that OpenCore injects next to
  VermilionBoot. No AMD byte in any release binary (F1). VermilionBoot checks each file's size and SHA-256 against a
  table generated from `fw.lock`. A root sysctl, the generalised #43 handover, is the second source.
- **Fallbacks survive.** Under D-K option a (the only one the review accepts under hard rule 1), the kernel brings
  the GPU up only after the daemon's go, which
  the daemon gives after reading the kill switch, the pending mark and the record, as today. That costs nothing at
  login, because the AuxKC is later than the daemon (1.1). The 3-minute watchdog stays with the daemon. The GOP
  revert before the claim moves into the kernel with recovery-trap step 3.
- **Steps:** 14 (K1-K14), one EFI change per boot (18-20 boots), plus the daemon-only test T1 and the
  UCLK fix U1. The first two write nothing to the GPU (K1 a write trace and timestamps, K2 the firmware store); K3
  moves today's writes into the kernel, in today's order, started by the daemon and proven equal by the trace. The
  hw-safety review
  cleared K1-K3 for implementation with conditions and sent the order moves back for redefinition; they are
  redefined here (section 7).
- **Biggest risk:** T1. If the first WindowServer doesn't adopt the late Metal device, the restart stays until
  VermilionAccel loads before WindowServer (B3, dropped by the owner) or WindowServer is found to wait for something
  the kernel controls.

## 1. Today's boot, step by step

### 1.1 Timeline of the 2026-11-26 00:51 boot (XTX machine)

Times from the unified log and `ps`, relative to boot (t0 from IOPCIFamily's own stamp on the PhxBringup line,
`[PCIe:0 569306448 ns]`, at 00:51:01.57; log clock, about ±0.1 s):

| t (s) | Event | Source |
|---|---|---|
| 0.57 | PhxBringup published on the GPU's function 0 (VermilionBoot `start` done) | kernel (IOPCIFamily) |
| 2.0 | kernelmanagerd starts | `ps` |
| 2.6 | first WindowServer (pid 204) spawned "because ipc (mach)", "Server is starting up" 0.1 s later | launchd, SkyLight |
| 3.2 | kernelmanagerd: "loaded collection: auxiliary kext collection" | kernelmanagerd |
| 4.0 | boot daemon header (`local.phxboot`) | `/var/log/phxboot.log` |
| 6.8 | "AuxKC bundle org.vermilion.accel marked as loadable" | kernel |
| 8.3 | the bring-up's `sudo` calls | unified log |
| 10.3 | NMXAccel probe and start (after `mesboot claim`) | kernel (VermilionAccel) |
| 15 | display pipe armed, `killall -9 WindowServer`; WindowServer pid 1106 | daemon log, `ps` |
| 22 | loginwindow of the accelerated WindowServer | `ps` |
| 144 | `SUCCESS`, `done`; then VCN, clock gating and UCLK again, idle DPM watcher, VRAM BOs, OpenGL, DP audio | daemon log |
| 241 | idle DPM on (UCLK free, FCLK switch allowed, DCFCLK messages) | daemon log |

The scripted bring-up from the daemon's start to the claim took about 6 s. Linux's waits on the same sequence add up
to about 1 s (EnableAllSmuFeatures ~135 ms, the RLC autoload ~745 ms; PSP log). The kernel's duration is (unverified)
until K3 measures it.

### 1.2 Every step

From `tools/phxctl/phxboot-navi31.sh` (the daemon), `navi31_up.sh`, `bringup_navi31.sh`, `mesboot.c` and the flag
scripts. Live flags on the XTX machine: `audio auto autologin bovram cg gl idledpm idledpm-dcf irqwait nohdr nvstuck
p0modes sdma uclk vcn vrrmin waitstep wscdcopy` and `phxboot-pre.sh`. "Kernel piece" names what VermilionBoot already
has for the step.

| # | Step (where) | Touches | Kernel piece today |
|---|---|---|---|
| 1 | Pre-start hook `~/gpu/phxboot-pre.sh` (daemon `:43`) | ESP flag files staged from Linux, `~/gpu` | none needed (goes with the flags) |
| 2 | Login-window guard on, auto-login off (`:266`) | `/Library/Preferences/com.apple.loginwindow` `SHOWFULLNAME`, `autoLoginUser` | none needed (goes with the restart) |
| 3 | Squat detection, 60 s poll (`:274`) | `ioreg` reads; NVRAM `phxfb-squat` (set from Linux, read by PhxFBSquatter) | `PhxFBSquatter` (recovery-trap steps 2-3 replace it with the hold) |
| 4 | Safe Mode exit (`:288`), notice carry (`:295`), stuck-squat state (`:376`) | `kern.safeboot`, `/var/db/phxboot.notice-next`, `~/gpu/phxboot-nvstuck`, `-safe` | none |
| 5 | Record, pending mark, kill switch, loop guard (`:388-428`) | `/var/db/phxboot.fails`, `/var/db/phxboot.pending`, `~/gpu/phxboot-off` | none (cross-boot state on the Data volume) |
| 6 | Desktop-arm decision, wait for `phx-build` (`:443-451`) | `~/gpu/phxboot-desktop`, `ioreg` | `phx-build` property |
| 7 | `nvram phxfb-boot=1`; `kmutil load -p VermilionAccel` if missing (`:455-457`) | NVRAM (runtime only: `DisableVariableWrite`), AuxKC | none |
| 8 | Mark `bringup`; `navi31_up.sh` in the background (`:462-482`) | `/var/db/phxboot.pending` | none |
| 9 | Cold check (`bringup_navi31.sh:66-89`) | reads C2PMSG_81 `0x16091`, C2PMSG_58 `0x1607a`, C2PMSG_35 `0x16063`; refuses a running sOS | `readRegs` (selector 2) |
| 10 | Watchdog `shutdown -r +3` (`:91`) | sudoers rule, a pending restart | none (user space) |
| 11 | PSP bootloader: KDB, SPL, SYS_DRV, SOS from `psp_13_0_0_sos.bin`, each staged at fw_buf (VRAM 128 MiB), C2PMSG_36 = address, C2PMSG_35 = command; `bl_wait` 300 × 10 ms; sOS wait 200 × 10 ms (`:104-112`) | registers, VRAM, firmware | `fwStage` (104), `writeReg` (108) |
| 12 | KM ring at VRAM 48 MiB; `LOAD_TOC` (GPCOM 0x20); `LOAD_IP_FW` SMC; `SETUP_TMR` 0x1300000 at 96 MiB (`:117-127`) | PSP GPCOM, `smu_13_0_0.bin` | `pspRing` (101), `pspRaw` (107), `loadIpFw` (105) |
| 13 | 26 × `LOAD_IP_FW`: SDMA TH0/TH1, CP RS64 PFP/ME/MEC + 9 stacks, MES + data, MES1 (KIQ) + data, IMU I/D, 7 RLC (`:139-165`) | PSP GPCOM, 8 firmware files | `fwStage`, `loadIpFw` |
| 14 | `AUTOLOAD_RLC` (`:168`) | PSP GPCOM | `pspCtl(2)` (106) |
| 15 | SMU init, 11 messages: GetDriverIfVersion, GetSmuVersion, Set{Driver,Tools}DramAddr{High,Low} (VRAM 144/145 MiB), TransferTableSmu2Dram(COMBO_PPTABLE), RunDcBtc, EnableAllSmuFeatures, GetRunningSmuFeatures{High,Low} (`:175-185`) | SMU mailbox | `smuMessage` + the debug allow-list (100) |
| 16 | Wait CP_STAT `0x21a0` = 0 and RLC_RLCS_BOOTLOAD_STATUS `0xee82` bit 31, 50 × 100 ms (`:187-197`) | reads | `readRegs` |
| 17 | RS64 program counters, 33 writes (`gfx_v11_0_config_gfx_rs64`; `:199-232`) | GC registers | `writeReg` |
| 18 | Doorbells: RCC DOORBELL_APER_EN `0xde0`, 6 indirect S2A routing writes through PCIE_INDEX2/DATA2, CP MEC/RB doorbell ranges (`:234-242`) | NBIO, GC | `writeReg` |
| 19 | MEC (4 pipes) and ME unhalt; watchdog cancelled (`:244-252`) | GC; `killall shutdown` | `writeReg` |
| 20 | `mesboot gart mc`: GART PTEs in VRAM, GFXHUB page table base, system aperture from FB_LOCATION, default page, L2, contexts 0-15, invalidation engines, SH_MEM_CONFIG/BASES per VMID, CP_DEBUG (`mesboot.c:119`) | GC/GFXHUB registers, VRAM | `writeReg`, `vramWrite` (109) |
| 21 | `mesboot mes`: CP_MES_CNTL reset, start address per pipe, active (`:182`) | GC | `writeReg` |
| 22 | `mesboot kiqres`, `schedkiq`: KIQ HQD and SET_RESOURCES with a ring test; the MES scheduler (MAP_QUEUES, SET_HW_RESOURCES, QUERY_SCHED_STATUS) | GC, VRAM, doorbells | `writeReg`, `vramWrite`, `doorbell` (110) |
| 23 | `mesboot cs`, `gfxq`: ADD_QUEUE compute and gfx (clear state from `csb_gfx11.h`), ring tests, hand-over | VRAM, doorbells | `adoptQueue` (112) |
| 24 | Result parsing, refusal and failure paths (record, notice, squat reboot) (`:483-537`) | `/var/db/phxboot.*`, NVRAM, restart | none |
| 25 | SDMA0/1 queue 0 started idle (`sdma_idle.sh`, flag `sdma`) | ~20 SDMA registers each, VRAM | `writeReg`, `vramWrite` |
| 26 | GFX and SDMA clock gating inside RLC safe mode (`gfx_cg.sh on`, flag `cg`) | 8 registers | `writeReg` |
| 27 | UCLK hard min 456 MHz (`uclk.sh pin`, flag `uclk`) | SMU SetHardMinByFreq | `smuMessage` |
| 28 | Display knobs before the claim: `debug.phxpipe0_enable/modes`, `debug.phxfb0_vrrmin`, `debug.phxfb0_hdr` (`:746-792`) | sysctls (VermilionBoot, VermilionAccel) | sysctls |
| 29 | Claim: `mesboot claim` → `nmxgpu-claimed` + `registerService`; NMXAccel, PhxAMDFB (`:794`) | PCI property, IOKit matching | `claimAccel` (113) |
| 30 | Desktop attempt: mark `desktop`, wait PhxAMDFB, `metaltest` until "Metal devices: 1", Metal allow list, `launchctl setenv CI_USE_MTL_DAG_FOR_CIKL_SRC 0`, no user logged in, AGDC and display pipe arm (`debug.phxagdc`, `debug.nvaccel_iop`, `debug.nvaccelfb`) (`:805-856`) | `/Library/GPUBundles/nvmtl-allow.txt`, launchd environment, sysctls | sysctls |
| 31 | Before the restart: `debug.phxscan=1`, `NVMTL_WS_PRESENT_CDCOPY`, `debug.phxwait_step_us=200`, IRQ waits (`debug.phxih_vram`, `phxih`, `phxeopirq`, `phxirq`, `phxwait_irq`), offer gate `debug.phxfb0_offer=1`, guard off, auto-login on (deletes loginwindow's first-run marker) (`:864-881`) | sysctls (IH ring, MSI), launchd env, loginwindow prefs | `phx_ih_irq.cpp`, `phx_scan.cpp` |
| 32 | `killall -9 WindowServer` (`:883`) | WindowServer | none |
| 33 | Flip setup, 120 s crash watch, display check, `SUCCESS`, `phxfb-squat` re-armed (`:889-913`) | sysctls, DiagnosticReports, NVRAM | sysctls |
| 34 | VCN: `vcn_up.sh --run` (PowerUpVcn, VCN firmware, DPG sequence), `debug.phxvcn=1`, `debug.phxmmvm=1` (flag `vcn`, after `done`) | SMU, PSP, VCN and MMHUB registers, `vcn_4_0_0.bin` | `phx_vcn_mmhub.cpp` (adopt, MMHUB) |
| 35 | Clock gating and UCLK pin again (`:956-961`) | as 26-27 | as 26-27 |
| 36 | Idle DPM (`idle_dpm.sh`, flags `idledpm`, `-dcf`): after login and 60 s settled: DAL watermark table, UCLK unpin, SetFclkSwitchAllow, DCFCLK hard min, deep-sleep DCFCLK, NumOfDisplays; underflow watchdog for the boot | DAL and SMU mailboxes, OPTC0/HUBP0 underflow stickies | `dalMessage`, `smuMessage` |
| 37 | VRAM BOs for listed processes (flag `bovram`), OpenGL on (`debug.phxgl=1`, flag `gl`) | GPU fills (self-test), sysctls | `phx_vram.cpp`; VermilionAccel |
| 38 | DP audio: `phxaudio apply` (90 DC audio writes for DIG1 from the EDID), `audio_match.sh on` (AppleGFXHDA attach through VermilionAudio) (flag `audio`) | DCN audio registers, IOKit | `writeReg`; VermilionAudio |
| 39 | WindowServer hang watch for the boot; TERM trap at shutdown (guard on, re-arm) (`:1042`) | logs, NVRAM, restart | none |

Two observations from the log, read-only:
- `sdma_idle.sh` prints `RLC_RLCS_SDMA_INT_STAT 0x00000300` on all 145 boots in `/var/log/phxboot.log`; its own
  comment says `0x3` means both engines idle. So the check has never passed on this machine, although idle power
  is as measured (28-33 W with idle DPM). The review: the register holds REQ_IDLE_HIST in bits 7:0 and REQ_BUSY_HIST
  in bits 15:8 (`gc_11_0_0_sh_mask.h`), so 0x300 records past busy requests, not the current state, and Linux never
  reads it (the HIST meaning is unverified). K4 logs it only and gates on Linux's `sdma_v6_0_is_idle` instead.
- Step 27 (and `idle_dpm.sh`'s unpin and re-pin) sends the driver-mailbox SetHardMinByFreq. Linux never sends it on
  SMU 13.0.0 (review A): U1.
- The daemon and its scripts run as root from the desktop user's `~/gpu` (TODO 06 item 3).

## 2. The target

### 2.1 The engine in Apple's blocks, at Linux's positions

Apple's `AMDHardware::init` calls `initializeTtl`, which runs AMD's SWIP list per ASIC, forward for hw_init
(01-bringup.md 1.4). The kernel engine has the same blocks; each holds today's sub-steps with their values. The
Linux column was checked by the hw-safety review against amdgpu v6.8 and master (line numbers v6.8); 7.2.15 itself
was not read.

| # | SWIP block (Apple, Navi 21) | Today's sub-steps (inventory #) | Where Linux amdgpu does it on Navi 31 | Today vs Linux |
|---|---|---|---|---|
| 1 | **BGM** (base: NBIO, PCIe) | RCC DOORBELL_APER_EN `0xde0` (18) | `soc21_common_hw_init` (`soc21.c:800`), before GMC and the PSP | late: after the RLC autoload |
| 2 | **GVM** (MMHUB, GART) | MMHUB VM for VCN (34) | `gmc_v11_0_gart_enable` enables **only the MMHUB** (`gmc_v11_0.c:881`), before the PSP | late: after `done` |
| 3 | **PSP** | bootloader (11), ring, TOC, SMC, TMR (12), 26 LOAD_IP_FW (13), AUTOLOAD_RLC (14) | `psp_hw_start` (`psp_v13_0_bootloader_load_kdb/_spl/_sysdrv/_sos`, `psp_ring_create`, `psp_tmr_init`, `psp_load_toc`, `psp_load_smu_fw`, `psp_tmr_load`), `psp_load_non_psp_fw`, `psp_rlc_autoload_start` | same; DMCUB and the TAs are not loaded (as today) |
| 4 | **SMU** | 11 init messages (15) | `smu_hw_init` → `smu_smc_hw_setup` | same |
| 5 | **GC** | RLC autoload wait (16), RS64 PCs (17), **GFXHUB GART**, system aperture, L2, contexts, invalidation engines (20), SH_MEM per VMID and CP_DEBUG (from 20), S2A ENTRY_0 and ENTRY_3 and the CP doorbell ranges (18), CP unhalt (19), clear state (23), GFX clock gating (26) | `gfx_v11_0_hw_init`: autoload wait, `config_gfx_rs64`, then the GFXHUB GART (:4313, :4327, :4329), `constants_init`, `gc_doorbell_init` (:4355), `cp_resume` (with `mes_v11_0_kiq_hw_init` at :4149), `cp_gfx_start`; clock gating in `amdgpu_device_ip_late_init` | GFXHUB late (after the CP unhalt); spread over three tools |
| 6 | **SDMA** | queue 0 of both engines idle (25), S2A ENTRY_2 (18), SDMA clock gating (in 26) | `sdma_v6_0_hw_init` → `sdma_v6_0_start`, ENTRY_2 there (`sdma_v6_0.c:510-513`) | after the MES queues, as Linux master (below) |
| 7 | **MES** | MES start (21), KIQ and scheduler (22), compute and gfx queues (23) | 6.8: MES enable and KIQ from GFX `cp_resume` (before SDMA), the scheduler and SET_HW_RESOURCES after SDMA (`mes_v11_0.c:1116-1206`); master with MES firmware sched_version ≥ 0x47: all of MES before SDMA | today = master |
| 8 | **VCN** | PowerUpVcn, VCN firmware, DPG sequence, ring adopt, S2A ENTRY_4/5 (34, 18) | `vcn_v4_0_hw_init` (ENTRY_4/5 at :281); start on first use (`vcn_v4_0_start_dpg_mode`), idle work powers it down | after login (+144 s) |
| 9 | **JPEG** | nothing | `jpeg_v4_0_hw_init` | not brought up (no consumer on macOS known; unverified) |
| 10 | **DMCU** / display | nothing at bring-up: the GOP's DMCUB keeps running; DC audio (38) and DPM (36) after the stream is up; the UCLK hard minimum belongs here (U1) | DM `hw_init` loads DMCUB through the PSP, before GFX; DC audio at each stream enable; `dcn32_update_clocks` (UCLK, DCFCLK, deep sleep, displays through the DAL mailbox) at each mode set | display last, as Apple; UCLK through the wrong mailbox today (U1) |
| - | IH (no SWIP block: Apple's accelerator does it) | IH ring in VRAM, EOP interrupt, MSI (31); S2A ENTRY_1 | `ih_v6_0_hw_init`, phase 1 (ENTRY_1 at `nbio_v4_3.c:182`) | after the claim, as Apple |

K3 walks these sub-steps in today's order, which is proven on the XTX machine. Two moves bring the walk to Linux's
positions inside Apple's blocks: DOORBELL_APER_EN before the PSP (K5), the GFXHUB right after the RS64 PCs (K6). A
third puts the MMHUB GART before the PSP, where `gmc_v11_0_gart_enable` has it (K7). Each is its own reviewed step,
because each changes the order the hardware has seen work here. Not moved: the S2A writes stay with the blocks that
own them; SDMA stays after MES (today matches Linux master; a move needs L1 on 7.2.15 and the MES firmware's version);
IH stays with the accelerator, where Apple has it. VCN moves in K12.

### 2.2 What `start()` does

`PhxBringup::start` stays short (today: gate, BAR maps, locks, `readFbLayout`, properties, `registerService`, done at
0.57 s). It adds:
1. **A read-only PSP look before anything else** (K1), as Apple's `initializeTtl` logs the PSP bootloader version,
   POST code and ready flag before TTL init: C2PMSG_81, C2PMSG_58, C2PMSG_35 into `phx-psp-boot`. These are the reads
   the daemon's cold check makes today, ~8 s later, and the ones Linux makes in `psp_v13_0.c` (:134, :274, :177).
   They are for information only: the refusal re-reads C2PMSG_81 right before the first write, and `0xFFFFFFFF`
   counts as unreadable.
2. **From K8, the engine on a `thread_call`** (`THREAD_CALL_PRIORITY_KERNEL`, once), so the IOKit matching thread
   never waits seconds; `stop()` cancels and waits for it.

The engine thread, `PhxBringup::kupRun()`:
1. **Policy:** nothing with `-phxbringupoff` (the whole kext), `-phxkupoff`, Safe Mode (`-x`) or an image-boot root
   (recovery-trap 5.2). Under D-K option a, wait up to 60 s for the daemon's answer on `debug.phxkup_go`; no answer
   is a no-go (a Recovery or installer boot, a missing daemon: nothing touches the GPU).
2. **Firmware:** wait up to 10 s for the store (`PhxFirmware`, 2.4) to read `ok`; otherwise refuse before any write.
3. **Refusals before the first write:** the board (`PhxGpuId.h`); the GPU in D0 (a PMCSR config read, from K8); the
   layout today's constants assume: fbMcBase `0x80_0000_0000`, fbPhys 0, a BAR0 map of at least ~165 MiB, and a boot
   framebuffer that ends below 48 MiB (a 5K or 6K boot mode would overlap the PSP ring); a cold PSP (C2PMSG_81 = 0,
   as #22); the firmware. A refusal writes nothing and releases the screen to the GOP (from R3 on).
4. **Blocks** in the walk order (2.1). Every poll is bounded by time, at least as long as today's (count × interval),
   never by a bare count (`gfx_cg.sh:12` does 1000 reads with no sleep; Linux uses `usec_timeout`, ~100 ms). The
   millisecond gaps between the scripts' processes disappear, so the engine adds what Linux has there: `mdelay(20)`
   after LOAD_SOSDRV before polling C2PMSG_81 (`psp_v13_0.c:308`), and a read-back of the last staged dword through
   BAR0 before each C2PMSG_36/35 bootloader command (a read, not a new HDP flush). Every fixed sleep of `mesboot` and
   `sdma_idle.sh` stays. Deadline 30 s for the whole walk, checked at step boundaries. Failure rules: a PSP fence
   timeout or a non-zero PSP status stops (as `psp_cmd_submit_buf`; today's `L()` checks nothing); an SMU response
   other than 1 stops; the gfx ring test is a warning, as today.
5. **Late init:** SDMA queues idle, GFX and SDMA clock gating (K4). The UCLK hard minimum is not here (U1).
6. **Claim:** `claimAccel()` as today; the kernel's defaults for IRQ waits and the fence step (K8).
7. **After the claim:** DC audio once head 0's stream is up (K9), DPM after the first settled mode (K11), VCN (K12).
   Every kernel DAL or SMU sender (the pipe-0 replay, DPM, VCN) waits for the engine's `up`: no DAL message may reach
   the PMFW around LOAD_IP_FW SMC or before EnableAllSmuFeatures. The daemon's "no SMU message after pipe 1 was lit
   unaligned" guard (`phxboot-navi31.sh:944-961`) carries over to K4, K11 and K12.

From K8 the engine also holds a sleep assertion for the walk, never holds a spinlock across a poll, and stops at a
step boundary at shutdown and in `stop()`.

State: `phx-kup-state` on the PCI device and `debug.phxkup_stat`: `idle`, `waiting <what>`, `running <block>.<step>`,
`up <ms>`, `refused: warm GPU (C2PMSG_81=…)`, `refused: no firmware`, `failed <block>.<step>: <values>`, `hung
<block>.<step>`. On a failure, `phx-kup-report` holds what Apple's failure report holds, in our registers: C2PMSG_35,
58, 64, 81, the last GPCOM status, the SMU response and argument, RLC_RLCS_BOOTLOAD_STATUS, CP_STAT, GRBM_STATUS, the
IMU version register. Reads only.

The engine doesn't use the debug selectors. A release then boots without `phxdebug=1`, which closes the root
register-write interface a Mac doesn't have. While the engine runs, every writing debug selector answers
`kIOReturnBusy`, so no tool interleaves writes.

### 2.3 Watchdog and fallbacks

Hard rule 1 keeps the bring-up watchdog and the daemon's fallbacks. Each one in the kernel world:

| Fallback | Today | K3-K7 (the daemon triggers the engine) | K8-K13 (the kernel starts, D-K option a) | K14 |
|---|---|---|---|---|
| Kill switch `~/gpu/phxboot-off` | the daemon does nothing | the daemon doesn't trigger | the daemon answers no-go; also `-phxkupoff` and Safe Mode at the picker, which need no file | owner D-K |
| Pending mark `/var/db/phxboot.pending` | an unfinished attempt → the next boot falls back | same | the daemon answers no-go after an unfinished attempt, as today | owner D-K |
| Record `/var/db/phxboot.fails`, loop guard, notice | daemon | daemon, from `phx-kup-state` | daemon | owner D-K |
| Bring-up watchdog (`shutdown -r +3`) | `bringup_navi31.sh`; stays armed after a failure between the PSP and the CP unhalt, cancelled for a failure from GART on (`navi31_up.sh:5-28`) | `navi31_up.sh` arms it before the go; the same rule by where the failure is; cancelled at `up` and on a refusal (before any fall-back to the script path) | the daemon arms it before its go, same rule; the kernel's bounded waits and deadline end in `failed` or `hung` | kept (D-K a) |
| GOP revert before the claim | daemon reboot (squat boot) | same | in the same boot: the kernel releases the hold (recovery-trap step 3) | kernel |
| GOP revert after the claim | `m2_fail` reboot, hang watch | same | same | kernel hang recovery (phase 2 item 7, C3) |

A single MMIO read that never returns can't be interrupted by any software; a PCIe completion timeout ends it with
all-ones, which every poll treats as "stopped answering". The kernel can't restart the machine cleanly (no KPI for a
clean restart; `PEHaltRestart` skips the shutdown), so the watchdog's restart stays in user space for as long as it
exists. Linux and Apple's driver leave a failed device as it is and don't restart.

**Owner decision D-K, before K8.**
- **a (recommended for 0.1.x):** the kernel waits for a go. The daemon becomes a small root LaunchDaemon in a
  root-owned path (no `~/gpu`, no GPU access, no `phxdebug`): read the kill switch, the mark and the record, answer
  go or no-go, arm and cancel the watchdog, show the notice. It costs nothing at login: the go comes at ~4 s and
  VermilionAccel can't load before ~6.8 s (1.1).
- **b (Mac-like, later):** no gate. The engine starts at once; the escape for a bring-up that freezes every boot is
  Safe Mode or `-phxkupoff` at the picker, or removing `VermilionFirmware.kext` from the EFI. The kernel can't keep a
  cross-boot record before the Data volume is mounted, and NVRAM writes don't reach this board's firmware
  (`DisableVariableWrite`). **The review: b leaves no watchdog and no pending mark, which breaks hard rule 1 unless
  the owner changes the rule.** So b is only possible after an owner decision on rule 1 itself.

Sleep and wake need the kernel path without user space in either option (D8): the gate applies only at boot.

### 2.4 Firmware before WindowServer

The kernel loads 12 linux-firmware files: the 10 of the bring-up (2,340,676 B), `vcn_4_0_0.bin` and the whole
`dcn_3_2_0_dmcub.bin` (the C3 slice now; B2's DMCUB later): 3,028,964 B in all (`fw.lock` sizes).

What Apple does: every firmware image is a constant array inside the HWLibs kext; nothing is read from disk, and
`psp_get_external_fw` reports no external path. `AMDFirmwareDirectory` registers some images by name (01-bringup.md
1.4). The firmware is there when `start()` runs. We can't compile it in (F1, rule 4).

| Option | Ready at | Apple analogue | Cost and risk | Verdict |
|---|---|---|---|---|
| **A. `VermilionFirmware.kext`**, generated on the user's machine by `vermilion-firmware --kext` from the fetched files (`plutil`, no compiler): a codeless kext whose personality (`IOClass PhxFirmware`, `IOProviderClass IOResources`, bundle `org.vermilion.boot`) carries the files as `<data>`. OpenCore injects it before VermilionBoot | `start()` (0.57 s), no user space | the closest: firmware loaded with the driver, an `AMDFirmwareDirectory` keyed by name | ~3 MB wired for the boot (needed again at wake, D8); a ~4.1 MB `Info.plist` through OpenCore and the kernel's prelink parser (unverified); firmware on the user's ESP (their machine; never published); a firmware update is an EFI change, as a VermilionBoot hash update is anyway | **recommended** |
| B. `OSKextRequestResource` from a codeless bundle in `/Library/Extensions`, served by kernelmanagerd | ~2 s (kernelmanagerd) | Apple's KPI for a kext's on-disk resources (exported by the 25G241 kernel, `nm`) | whether kernelmanagerd still serves it on 26.7.1, and for an OpenCore-injected requester, is (unverified); whether a codeless bundle needs approval (unverified) | fallback if A fails; one REA read and one test |
| C. VermilionBoot reads files with `vnode_open`/`vn_rdwr` after the Data volume mounts | ~3 s, polled | none (Linux's `request_firmware`) | kernel file I/O in a driver, an unsupported KPI, a mount race | rejected |
| D. A LaunchDaemon hands the bytes over through a root sysctl (#43's `debug.phxc3_image`, for all files) | ~4 s (daemon) | none | our daemon stays; after WindowServer | kept as the second source: K3-K7 and a missing firmware kext |
| E. Compiled in | `start()` | Apple's way | AMD bytes in a release binary | rejected (F1) |
| F. OpenCore `DeviceProperties` or a UEFI driver | `start()` | none | firmware inside `config.plist` (which carries SMBIOS), or a custom OpenCore driver | rejected |

**The store** (`PhxFirmware`, K2): checks each file's size and SHA-256 against `phx_fw_table.inc`, generated at build
from `tools/firmware/fw.lock` (hashes only; `fw.lock` is already in git), retains the `OSData`, removes the
property from its registry entry (so `ioreg -l` never carries AMD bytes), publishes `phx-fw-state` (`ok 12/12
<bytes> from <source> at <ms>`, or the first refusal) and serves files by name. The ucode offsets inside each file
are fixed (`bringup_navi31.sh:95-150`) and valid only for the `fw.lock` revision, so a hash mismatch is a refusal,
never a guess; the data stays retained for the whole walk (and the boot). The C3 slice comes from the store's
`dcn_3_2_0_dmcub.bin` with #43's check, so `phxctl c3image` becomes optional. The installer generates the kext after
the firmware fetch; the release ships only the generator. A firmware update means a new `fw.lock`, a new VermilionBoot
(its table) and a regenerated firmware kext: one EFI change.

## 3. Step plan

Every step: its own branch and PR, the Fable pass, the hw-safety review where it touches GPU programming,
`preflight.sh`, `PHX_KEXT_BUILD` and CHANGELOG, a rollback copy of every replaced binary, check and rollback in TODO
before the install, one boot. The script path stays usable until K8 (remove a flag); after that, `EFI/OC.prev`.

**Prerequisites:** #43 (F1) merged; recovery-trap steps 2 and 3 (the boot-mode check, the hold and in-boot release:
[finding](2026-11-25-recovery-trap-design.md) section 6) before K8; T1 before K10. Build numbers below assume #43 is
b163.

**T1 (daemon only, no EFI change; owner test, before K10).** Flag `~/gpu/phxboot-norestart`: the daemon does everything
as today except `killall WindowServer`; the login-window guard stays on, auto-login stays off. Check: the plugin's
os_log shows WindowServer (pid of the first) creating its `NVMTLDevice` after NMXAccel appears; `debug.nvaccel_iop_ok`
counts presents; the owner sees GPU-smooth animation at the login. Worst case: the first WindowServer keeps software
compositing until the next boot, or crashes and launchd starts a new one, which is today's outcome. Rollback: `rm` the
flag. Before T1, a short REA read of SkyLight's `MTLCopyAllDevicesWithObserver` handler predicts the result (study
only, nothing copied).

**U1 (today's daemon, before K4 and K11; owner's call how soon).** The UCLK hard minimum through the DAL mailbox, as
Linux's DC does (`dcn32_clk_mgr.c:685/688/720`: DAL SetHardMinByFreq(PPCLK_UCLK); the DAL allow-list already lets
UCLK through), instead of the driver-mailbox 0x1B that `uclk.sh` and `idle_dpm.sh` send: on SMU 13.0.0 Linux wires
neither `display_clock_voltage_request` nor `set_hard_freq_limited_range` (`smu_v13_0_0_ppt.c`, v6.8 and master), so
the only sender of that message (`smu_v13_0.c:1685`) is unreachable there. The values follow DC too (raise before a
mode set, lower to the requested memory clock after it; review condition 15); 456 MHz is not a value Linux sends.
Its own branch, hw-safety review and boot; then the driver-mailbox 0x19-0x1F entries leave the debug allow-list
(`phx_debug.cpp:66-71`). Until U1 the daemon's pin stays as it is: it has run on every boot without a visible fault,
and removing it brings back the display underflows it was added for.

| Step | Change | GPU programming / review | Machine change | Check | Rollback |
|---|---|---|---|---|---|
| **K1** | Write trace, timestamps, pre-PSP read (details below) | reads only (3 PSP mailbox reads at `start`, the ones Linux makes): review cleared, conditions 1-2 | EFI (VermilionBoot b164) | a script-path boot leaves a complete trace; `phx-psp-boot` `sos=0x00000000` on a cold boot; timestamps; the LOAD_TOC response's TMR size logged | `EFI/OC.prev` |
| **K2** | Firmware store and `VermilionFirmware.kext` (details below) | none (the C3 slice byte-equal, #43's test): review cleared, condition 3 | EFI (VermilionBoot b165 + the generated kext + a `Kernel > Add` entry) | `phx-fw-state: ok 12/12`; no firmware in `ioreg -l`; start time as in K1; the boot as before | `EFI/OC.prev`; from Linux if OpenCore stops (runbooks) |
| **K3** | The engine, started by the daemon, today's walk (details below) | **yes**: the step table against Linux and against K1's trace; review cleared the design, conditions 1, 4-9 | EFI (b166) + daemon (`navi31_up.sh`) + flag | the K3 trace equals K1's; `up <ms>`; `navi31 up:`, `SUCCESS`, 240 Hz | `rm ~/gpu/phxboot-kup`, or `EFI/OC.prev` |
| K4 | Late init in the engine: SDMA queues idle, GFX and SDMA clock gating in RLC safe mode (the writes of `sdma_idle.sh` and `gfx_cg.sh on`); only the early run moves, the re-run after VCN stays in the daemon until K12; no UCLK (U1) | **yes** (same writes, new place). Check gated on `sdma_v6_0_is_idle` (STATUS_REG bit 0 at `0x1285`, `0x1885`) and the RB_ENABLE and F32 HALT=0 read-backs; `0xEEF5` logged only | EFI | the trace equals the scripts' writes; RLC_CGCG_CGLS_CTRL reads back; GFX activity in the SMU metrics, idle board power, temperature and fan as today | `EFI/OC.prev`; the flags work with the old kext |
| K5 | BGM: only RCC DOORBELL_APER_EN before the PSP (`soc21_common_hw_init`); the S2A writes and CP ranges stay with their blocks | **yes**, with L1 (Linux's order on the XTX) | EFI | `up`; the doorbell registers read back as today; `SUCCESS` | `EFI/OC.prev`; flag back to the script path |
| K6 | GC: the GFXHUB GART right after the RS64 PCs, before `constants_init` (SH_MEM, CP_DEBUG) and the doorbells, where `gfx_v11_0_hw_init` has it | **yes**, with L1 | EFI | `up`; `gart: ack17` as today; Metal apps; no VM faults (`debug.phxvm`) | as K5 |
| K7 | GVM: the MMHUB GART before the PSP, where `gmc_v11_0_gart_enable` has it (today it comes with VCN, after login) | **yes**, with L1; the MMHUB writes of `phx_vcn_mmhub.cpp` against `mmhub_v3_0` | EFI | `up`; `debug.phxmmvm_stat` as today; VCN decode after K12 | as K5 |
| K8 | The engine starts from `start()` (D-K option a only): thread, go/no-go, firmware wait, refusals (D0 included), the kernel's claim, the in-boot GOP release on a failure before the claim (R3), IRQ waits and the fence step as kext defaults; the daemon drops its bring-up, arms the watchdog and answers go | **yes**: the start-time context (2.2), conditions 10-12; R3's review covers an IONDRV release after a partial bring-up; MSI and the IH at the claim get their own review against `ih_v6_0` | EFI + daemon | `up` before the daemon's log says go+2 s; no `navi31_up.sh` line; `SUCCESS`. Owner: power-off cold boot, restart, Safe Mode (GOP, no engine), `-phxkupoff` boot, a forced refusal (GOP picture in the same boot) | `EFI/OC.prev` + the daemon from `~/vermilion-rollback` |
| K9 | DC audio in the kernel: `phxaudio_plan.h`'s writes once head 0's stream is up; around each mode set audio off (plan steps 1-2) before the stream change and on (steps 3-7) after it, serialized with the replay engine (Linux's order, decisions 2026-11-24); `phx-audio-ready` makes VermilionAudio attach AppleGFXHDA itself; AppleGFXHDA is never detached; BacoAudioD3PME stays unsent | **yes**, condition 14 | EFI (VermilionBoot + VermilionAudio) | `debug.phxaudio_stat` matched at the login window; the same 90 writes as `phxaudio apply` | `EFI/OC.prev` |
| K10 | The first WindowServer is the accelerated one (only if T1 passed): VermilionAccel defaults (GL on, the pipe-0 mode list, VRR floor 60 with a boot-arg for another, HDR as the release decides, AGDC and the display pipe at start, the offer gate's need re-checked), a static Metal allow list, the plugin's WindowServer defaults (`NVMTL_WS_PRESENT_CDCOPY` behaviour); the daemon drops 28-33 | none new (defaults move into the kexts); review that nothing new is written | AuxKC (Allow click) + plugin (trust + EFI) + daemon: 2 boots | one WindowServer pid for the boot; the plugin log shows its Metal device; no guard or auto-login lines | previous kexts and daemon from `~/vermilion-rollback` |
| K11 | DPM in the kext, after U1, as `dcn32_update_clocks` does it: raise before each mode set (UCLK up, FCLK switch disallowed; today's switches run unpinned, which Linux doesn't do), lower after it (UCLK to the requested memory clock, 96 MHz in the traces; DCFCLK, deep sleep, NumOfDisplays); the DAL watermark table; the underflow watchdog as a kernel timer (reads), pinned again on an underflow | **yes**, conditions A and 15 | EFI | idle board power 28-33 W, UCLK 96, no underflow in 10 min, mode switches clean | `EFI/OC.prev` |
| K12 | VCN in the kext, Linux's flow: S2A ENTRY_4/5 at hw_init, PowerUpVcn per instance (argument `inst << 16`) before the DPG start, DPG with the indirect SRAM loaded through the PSP, ring adopt; MMHUB first (K7) (a); then on first use, and after the idle timeout stop DPG, then PowerDownVcn, as Linux's idle work (b) | **yes**, each, condition 16 | EFI each: 2 boots | decode works; (b) PowerDownVcn at idle | `EFI/OC.prev` |
| K13 | Quiesce at restart and shutdown (B5), Linux's order where it differs from Apple's: MP1 state UNLOAD, then the blocks suspended in reverse (display, MES, VCN, SDMA, GFX, SMU with PrepareMp1ForUnload, PSP last; `amdgpu_pci_shutdown`, `amdgpu_drv.c:2369-2386`); nothing sent to a GPU that never came up | **yes** (B5's own design), condition 17, L3 | EFI | no stall reports at restart; 5 restarts and a shutdown | `EFI/OC.prev` |
| K14 | The daemon's bring-up path, `mesboot` use at boot, the flags and `~/gpu/fw` go (a refactor commit apart from the behaviour commit); `phxdebug=1` out of the release config; what's left per D-K | none | daemon + docs (+ EFI for the boot-args) | no bring-up lines from the daemon; a week of normal use | the K13 daemon from `~/vermilion-rollback` |

Boots if every step passes first time:

| Step | K1 | K2 | K3 | K4 | K5 | K6 | K7 | K8 | K9 | K10 | K11 | K12 | K13 | K14 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Boots | 1 | 1 | 3 (normal, `stop=sos`, `stop=smu`) | 1 | 1 | 1 | 1 | 1-2 | 1 | 2 | 1 | 2 | 1-2 | 1 |

**18-20 boots**, plus T1 (1, daemon only), U1 (1) and the recovery-trap steps 2-3 (2-3). A failed step adds its
retries. K5-K7 can wait without blocking K8-K13. K9 and K11 need only K3 and the claim (K11 also U1) and can move
earlier if the owner wants sound sooner.

### 3.1 K1: write trace, timestamps, pre-PSP read (VermilionBoot b164, no new GPU write)

- `src/vermilion-boot/PhxKupTrace.h` (new, kernel-free, host test `tests/kext/kup_trace_test.cpp`): a ring of
  fixed records `{seq, kind, a, b, c, t_ns}`. Kinds: `WREG reg val`, `VRAMW off val`, `DB off lo hi`, `STAGE dst
  len crc32` (never bytes), `PSP_RING op off`, `PSP_CMD cmd w0..w5 status tmr_size`, `SMU msg arg resp`, `DAL msg
  arg resp`, `ADOPT queue ring dw`, `CLAIM`. Runs of consecutive writes coalesce into `{first, count, crc32}`:
  `mesboot gart()` alone makes 131,072 VRAM writes (`mesboot.c:121-125`) and the 4 KiB stages ~1,600 more
  (`phxctl.c:278-292`), which 32768 plain records would not hold. Allocated at `start`, frozen at the first claim,
  freed by `debug.phxkup_trace_on=0`.
- The hook sits **in the shared primitives**, not in the selectors: `writeReg`, `vramWrite`, the doorbell write,
  `fwStage`, `pspRing`, `pspRunCmd` (every PSP command with its status and `resp.tmr_size` at +16,
  `psp_gfx_if.h:403`, which `pspRunCmd` doesn't return today, `phx_psp_smu.cpp:150-153`), `smuMessage`,
  `dalMessage`, `adoptQueue`, `claimAccel`. So K3's engine is traced by the same code and doesn't report on itself.
- `src/vermilion-boot/phx_sysctl.cpp`: `debug.phxkup_trace` (root, read: the text dump), `debug.phxkup_trace_on`.
- `src/vermilion-boot/phx_core.cpp` `PhxBringup::start`: `phx-t` (start, first debug call, claim; ns since boot) and
  `phx-psp-boot` from three reads of `0x16091`, `0x1607a`, `0x16063` after the BAR map.
- `tools/phxctl/kup_trace_check.py` (new): turns `bringup_navi31.sh` and `mesboot`'s fixed values into the expected op
  list and compares a trace with it.
- Check: after the boot, the trace saved to `~/vermilion-captures/` (outside git); its op list equals the scripts'
  expectation (counts per kind, the PSP and SMU commands in order); `phx-psp-boot` read before the daemon; the TMR
  size the LOAD_TOC response asks for. This trace is K3's reference. The TMR size becomes a gate only after the XTX
  is seen to answer 0x1300000 (section 5, item 10).

### 3.2 K2: firmware store (VermilionBoot b165 + `VermilionFirmware.kext`, no new GPU write)

- `tools/firmware/fw_kext.sh <fw dir> <out dir>` (new, `plutil` only): checks md5 and SHA-256 against `fw.lock`,
  writes `VermilionFirmware.kext/Contents/Info.plist` (bundle `org.vermilion.firmware`, `OSBundleRequired Root`, no
  executable, the personality of 2.4 with one `<data>` per file). `vermilion-firmware --kext` calls it after the
  fetch. `efi/build.py` adds the `Kernel > Add` entry before VermilionBoot only when a generated kext is present
  (`build/` is git-ignored; never published).
- `src/vermilion-boot/PhxFwStore.h` (new, kernel-free, host test `tests/kext/fw_store_test.cpp`: a flipped bit, a
  wrong size, a missing file, a file twice) and `phx_fw_table.inc` generated from `fw.lock` by
  `tools/firmware/fw_table.py`; SHA-256 from #43's `PhxSha256.h`.
- `src/vermilion-boot/phx_fw.cpp` (new, included after `phx_classes.cpp`): class `PhxFirmware : IOService`, `start()`
  verifies, retains, removes `phx-fw`, sets `gPhxFw`, publishes `phx-fw-state`, `registerService()`; the second
  source `debug.phxfw_load` (root, one file per write, the same checks); `debug.phxfw_stat`. `Info.plist` of
  VermilionBoot needs no change (the personality lives in the firmware kext).
- `src/vermilion-boot/phx_pipe2.cpp` `c3Load`: the slice from the store when no #43 image was written.
- Check: `phx-fw-state: ok 12/12 3028964 B from VermilionFirmware`; `ioreg -lw0 | grep -c phx-fw` shows only the
  state line; PhxBringup's start time as in K1; wired memory up by about 3 MB, not more (the IOCatalogue keeps the
  personality too: measured, not assumed); the daemon's boot unchanged (`SUCCESS`, 240 Hz). If OpenCore or the kernel
  refuses the plist, `phx-fw-state: none` and the rest boots as before: then B (or a data-only executable) is next.

### 3.3 K3: the engine, started by the daemon (VermilionBoot b166 + daemon, today's walk)

- `src/vermilion-boot/PhxKup.h` (new, kernel-free, host test `tests/kext/kup_test.cpp` against K1's saved trace): the
  10 blocks of 2.1, each an op list with today's values (the same op kinds as the trace), an `Io` interface (as
  `PhxDpRun.h`), and the walk `kTodayWalk`: PSP bootloader, PSP ring/TOC/SMC/TMR, PSP IP firmware, AUTOLOAD_RLC, SMU
  init, GC autoload wait, GC RS64, BGM doorbells and GC doorbell ranges, GC unhalt, GVM GFXHUB with GC SH_MEM, MES
  start, KIQ, scheduler, compute queue, gfx queue. Every wait is bounded by time, at least as long as its script's,
  with the timing additions of 2.2.
- `src/vermilion-boot/phx_kup.cpp` (new, included after `phx_psp_smu.cpp`): `PhxBringup::kupStart()` (the sysctl
  handler: refused unless `phx-fw-state ok`, refused after **any GPU-writing debug selector** this boot, once per
  boot), `kupRun()` on a `thread_call`, and the `Io` binding to **today's primitives, so the trace argument holds**:
  `writeReg` (write, mfence, read-back; `phx_core.cpp:279-291`), never a bare `wreg`; `fwStage` from the store;
  `pspRing`; `pspRaw` with the script's own words for LOAD_TOC and SETUP_TMR (`bringup_navi31.sh:109`, `:114`), not
  `pspCtl(1)`; `loadIpFw`; `pspCtl(2)` for AUTOLOAD_RLC; `smuMessage` with a compiled-in list of exactly the 11 init
  messages and arguments; `vramWrite`; the doorbell write with mesboot's HDP flush before each one
  (`mesboot.c:65-69`); `adoptQueue`. Each PCIE_INDEX2/DATA2 (`0xe`/`0xf`) pair under one lock, as
  `amdgpu_device_indirect_wreg` does (`gMmIdxLock` covers only dwords 0-6 today). Then the ports of `mesboot.c`
  `gart()`, `mes_start()`, `kiqres_test()`, `schedkiq_test()`, `cs`, `gfxq` as `kupGart()`, `kupMesStart()`,
  `kupKiq()`, `kupSched()`, `kupComputeQ()`, `kupGfxQ()`, with only the branches the daemon runs (sudo drops the
  environment): PTE flags 0x71, L2_PROTECTION_FAULT_CNTL 0x2, MC addresses, ADOPT, ADOPT_GFX.
  `mes_v11_api_def.h` and `csb_gfx11.h` move to `src/vermilion-boot/` first, in a refactor commit; `mesboot` includes
  them from there.
- `debug.phxkup` (root, write 1), `debug.phxkup_stat`, `phx-kup-state`; the engine logs its ops into K1's trace.
- `tools/phxctl/navi31_up.sh`: when `~/gpu/phxboot-kup` exists and `debug.phxkup` answers: arm `shutdown -r +3`
  (the same sudoers rule), write the go, poll the state, and handle the watchdog by where a failure is, as today:
  armed after a failure between the PSP and the CP unhalt, cancelled for a failure from GART on, cancelled at `up`
  and on a refusal. It prints the same last lines the daemon parses (`navi31 up:`, `navi31 not up:`, `refused: warm
  GPU (`). `refused: no firmware` cancels the watchdog, then runs the script path in the same boot (nothing was
  written). `tests/mock` cases for each outcome.
- Check: the K3 trace equals K1's op for op (stages by size and CRC; a run-time BO address, if any, listed);
  `up <ms>` with each block's time; `navi31 up:`, `SUCCESS`, 240 Hz; a day of normal use. Two more boots run the stop
  tests, one each: `phxboot-kup` holding `stop=sos` (the engine stops with the sOS up), then `stop=smu` (stops after
  SMU init; K8's in-boot GOP release depends on the GOP picture surviving it). The daemon takes the failure path each
  time; this answers whether the GOP picture survives a half bring-up.

## 4. What changes for the user

- **No WindowServer restart, no login rewrites, no auto-login by the daemon** (K10, if T1 passes). The login window
  appears once, accelerated, with the account picture. Automatic login is the System Settings option a Mac has; the
  daemon never writes `autoLoginUser`, `SHOWFULLNAME` or deletes loginwindow's first-run marker again, and
  `/etc/kcpassword` is the system's own.
- **Metal, OpenGL and DP audio at the login window:** Metal when NMXAccel starts (bounded by the AuxKC, ~7 s after
  boot instead of ~10 s and a restart at 15 s); OpenGL from NMXAccel's start instead of ~2.5 min (K10); sound to the
  monitor at the login window instead of ~2.5 min (K9); video decode from the bring-up (K12); idle power from the
  bring-up instead of after login (K4, K11).
- **Nothing in `~/gpu`:** no flag files, no firmware folder, no root scripts in a user folder (TODO 06 item 3), no
  `phxdebug=1` (K14).
- **Failures:** a refused or failed bring-up before the claim gives the firmware display in the same boot and one
  notification (K8 with R3); no reboot loops; Safe Mode at the picker always skips the engine. Recovery and the
  installer never touch the GPU.
- **Release shape:** OpenCore: VermilionBoot, VermilionTrust, VermilionAudio and the locally generated
  VermilionFirmware, with a config snippet; AuxKC: VermilionAccel (the Allow click stays, B3 dropped);
  `/Library/GPUBundles`: the plugin; the package: user-space parts, the firmware fetch and the firmware-kext generator,
  and under D-K a the small go/no-go agent. No daemon programs the GPU.

## 5. Risks and open questions

1. **T1, the first WindowServer and a late Metal device** (unverified). For: SkyLight imports `MTLCopyAllDevices` and
   `MTLCopyAllDevicesWithObserver`; Metal imports `IOServiceAddMatchingNotification` and exports
   `MTLDeviceWasAddedNotification` (`dyld_info`, XTX machine, 25G241). Against: the daemon's long-standing note
   (from Cobalt64's work) that the first WindowServer never adopts the device; not re-tested with today's stack. If T1
   fails: REA on SkyLight for what it waits for, and whether NMXAccel registering before PhxAMDFB changes it; else the
   restart stays (it already happens before anyone logs in) until B3.
2. **A ~4.1 MB `Info.plist` through OpenCore and the kernel** (K2, unverified). Fallbacks: B, a generated data-only
   executable, D.
3. **The start-time context** (K8, unverified): the engine would run ~1 s after boot instead of ~8 s, while other
   drivers still match. Nothing known breaks it; nothing tested it. Under D-K a, the go comes at ~4 s, which keeps the
   context close to today's.
4. **Timing** (K3): the kernel writes microseconds apart where the scripts were milliseconds apart (a process per
   write). The review named the places where the scripts' gaps hid a wait Linux has (2.2: the 20 ms after
   LOAD_SOSDRV, the staged-data read-back, time-bounded polls). The trace proves the writes, not the timing; the
   remaining gaps are (unverified) until K3 runs.
5. **Order moves** (K5-K7): the PSP-side sequence comes from a Linux 6.8 log on upstream's XT; the XTX has no full
   Linux init trace in the repo, and the review read 6.8 and master, not 7.2.15. L1 confirms Linux's order on this
   board before each move. The first version of this plan had all three moves wrong (section 7, B-D).
6. **mesboot** was built from traces and tests, not from one end-to-end Linux trace. K3 ports it as it is; the review
   of K3's step table may find writes to question, which are existing differences and separate changes.
7. **UCLK** (U1): today's pin is a message Linux doesn't send on this SMU, live on every boot. The fix moves it to the
   DAL mailbox with DC's values; until then the pin stays.
8. **Which SMU messages around `smu_smc_hw_setup` we don't send**, and the MES firmware's sched_version (which decides
   Linux master's MES order) (L1).
9. **Memory:** ~3 MB of firmware wired for the boot, plus whatever the IOCatalogue keeps of the personality (K2
   measures it).
10. **TMR size:** `SETUP_TMR` uses the constant 0x1300000 (Linux's value on the XT). Linux sizes the TMR from the
    `LOAD_TOC` response (`amdgpu_psp.c:767`, :808, :817). The review agrees with a stop before the SMU firmware on a
    mismatch (never a new value): K1 logs the response, the gate comes only after the XTX is seen to answer 0x1300000.
    The check also proves the TMR (96 MiB + size) ends at or below `fw_buf` at 128 MiB.
11. **The boot framebuffer's size:** today's VRAM layout puts the PSP ring at 48 MiB; a 5K or 6K boot mode would
    overlap it. The engine refuses then (2.2); a monitor like that needs a layout from the hardware (rule 3).

**Linux captures** (one session through the `linux-queue` skill):
- **L1** (before K3's review, needed for K5-K7): amdgpu's cold init on the XTX with every MMIO write and read
  (`amdgpu:amdgpu_device_wreg`/`_rreg` trace events from the kernel command line) and the PSP and SMU commands
  (dynamic debug on `amdgpu_psp.c`, `smu_cmn.c`), with timestamps, and the MES firmware's sched_version from dmesg.
  Gives the block order on 7.2.15, the waits' real durations and the SMU messages we don't send. The same session can
  record the DAL UCLK messages around a mode set for U1 and K11 (the 2026-11-20 mode-set traces may already have them).
- **L2** (K9, only if the 2026-11-24 traces have no mode switch with audio on): DC audio around a mode switch.
- **L3** (K13): `amdgpu_pci_shutdown` and a reboot on the XTX (B5's messages).

## 6. B2 direction, and room for it

Apple ships AMD's Display Core inside the framebuffer kext, with a thin display manager (`falcon_dm`) between IOKit
and DC ([02-display.md](../../reference/apple-amd/02-display.md) 2.1; 06-vermilion-map.md item 10). B2 should do the
same for Navi 31: port DC with the `dcn32` resource and DML, under a thin layer in VermilionBoot that PhxAMDFB and
PhxAGDC call. Timings, link training, DSC, MST and audio are then computed from EDID and DPCD instead of replayed
from captures.

How B1 leaves room for it:
- **Display is the last block**, as in Apple's order. B1 doesn't touch the display: the GOP's DMCUB keeps running and
  the replay engine stays. The DMCU block is empty in B1, and B2 fills it: `dc_create` and `dmub_srv`, and the
  decision whether to load Linux's DMCUB through the PSP as Linux does (which would also give the firmware-assisted
  memory clock switching the GOP's DMCUB reports as missing).
- **The store already holds `dcn_3_2_0_dmcub.bin`** whole, for that load.
- **K9's audio and K11's clock steps sit behind small interfaces** (`phxdc::audio`, `phxdc::clocks`) that DC's
  `dce_audio`/stream encoder audio and `clk_mgr` dcn32 replace, with the same SMU and DAL messages (the DAL mailbox
  and its allow-list exist).
- **Nothing in B1's engine depends on the replay plans**, so B2 can replace them without touching the bring-up.

## 7. hw-safety review

The `hw-safety-reviewer` agent reviewed the first version of this design (2026-11-26) against Linux amdgpu v6.8 and
master, read in a scratch folder outside git (7.2.15 not read). Its verdict:

> K1-K3 can go to implementation once the conditions below are met. K4, K5, K6 and K7 are UNSAFE as written: Linux
> either sends a different message or does the step at a different point. They need to be redefined before their own
> reviews. K8 is acceptable under D-K option a only.

Per step: T1 safe; K1 safe with conditions 1-2; K2 safe with condition 3; K3 safe with conditions 1 and 4-9; K4, K5,
K6, K7 unsafe as first written; K8 safe with conditions 10-12, option a only; K9 safe with condition 14; K10 safe with
condition 12 if only defaults move; K11 needs A and 15; K12 safe with 16; K13 safe with 17 and L3; K14 safe.

**The four unsafe findings, and what this version does with them:**

| | Finding | Now |
|---|---|---|
| A | `uclk.sh` sends driver-mailbox SetHardMinByFreq (0x1B); SMU 13.0.0 never sends it in Linux (the ppt table wires no hard-limit setter; checked again for this note in the review's v6.8 and master copies); Linux sets UCLK through the DAL mailbox from DC (`dcn32_clk_mgr.c:685/688/720`) | U1 (a fix of today's daemon); K4 carries no UCLK; K11 after U1, with DC's values |
| B | Only DOORBELL_APER_EN is in `soc21_common_hw_init`; the six S2A writes belong to GC (ENTRY_0, 3), IH (1), SDMA (2), VCN (4, 5) | K5 moves APER_EN only; the table in 2.1 assigns each S2A write to its block |
| C | `gmc_v11_0_gart_enable` enables only the MMHUB; the GFXHUB GART is in `gfx_v11_0_hw_init` after the autoload wait and `config_gfx_rs64` (checked again for this note) | K6 puts the GFXHUB after the RS64 PCs; the MMHUB before the PSP is K7 |
| D | SDMA doesn't come before MES in Linux (6.8: MES enable and KIQ before SDMA, the scheduler after; master with sched_version ≥ 0x47: all MES before SDMA) | the SDMA move is dropped; today's order matches master |

**Conditions** (folded into 2.2, 2.3, 2.4 and 3.1-3.3; numbers as the review gave them):
1. K1's trace coalesces runs and hooks the shared primitives, so the engine is traced by the same code; every PSP
   status and `resp.tmr_size` recorded.
2. K1's reads are information; the refusal re-reads C2PMSG_81 before the first write; `0xFFFFFFFF` is unreadable.
3. K2: the fixed ucode offsets are tied to the `fw.lock` hashes; the C3 slice's SHA-256 equals #43's; the data stays
   retained for the walk.
4. K3 uses today's primitives (`writeReg` with its read-back, `pspRaw` with the script's words, the HDP flush before
   each doorbell, the indirect pair under one lock).
5. Timing: Linux's 20 ms after LOAD_SOSDRV, a staged-data read-back before each bootloader command, time-bounded
   polls, every fixed sleep kept.
6. Refuse unless the layout matches today's constants (fbMcBase, fbPhys, BAR0 ≥ ~165 MiB, boot framebuffer below
   48 MiB); port only mesboot's default branches.
7. Failure rules: PSP fence timeout or non-zero status stops; SMU response other than 1 stops; the gfx ring test
   warns.
8. The watchdog by where the failure is, as `navi31_up.sh` does; cancelled before any fall-back to the script path.
9. `kupStart` refused after any GPU-writing debug selector; the `stop=smu` test besides `stop=sos`.
10. Option a: no run without a fresh go; no answer in 60 s is a no-go; the daemon arms the watchdog before the go.
11. K8 context: D0 check, a sleep assertion, no spinlock across a poll, abort at a step boundary at shutdown and in
    `stop()`; R3's review covers an IONDRV release after a partial bring-up; MSI and IH at the claim reviewed against
    `ih_v6_0`.
12. Every kernel DAL or SMU sender waits for `up`; no DAL message around LOAD_IP_FW SMC or before
    EnableAllSmuFeatures; the pipe-1 "no SMU message" guard carries over.
13. K4 replaces only the early run; the re-run after VCN stays until K12.
14. K9: audio off before a stream change, on after it, serialized with the replay engine; never detach AppleGFXHDA;
    BacoAudioD3PME unsent.
15. K11 follows `dcn32_update_clocks` (raise before a mode set, lower after it).
16. K12 follows Linux's VCN flow (ENTRY_4/5 at hw_init, PowerUpVcn per instance before DPG, indirect SRAM through the
    PSP, stop DPG then PowerDownVcn at idle, MMHUB first).
17. K13 follows `amdgpu_pci_shutdown`'s order; nothing sent to a GPU that never came up.
18. The TMR check is fine as a stop (section 5, item 10).
19. K4's SDMA check: `sdma_v6_0_is_idle` plus the RB_ENABLE and F32 HALT read-backs; `0xEEF5` logged only.

**Open points the review leaves** (unverified until done):
- L1 on 7.2.15 for K5-K7 and the MES firmware's version; L3 for K13.
- K3's actual step table gets its own review when the code exists (this review covered the design).
- U1 needs its own design and review (the DAL message's arguments and DC's raise/lower rule), and the owner's word on
  how soon, since it changes a message the live daemon sends every boot.
- The meaning of `RLC_RLCS_SDMA_INT_STAT`'s HIST bits.
- Whether the GOP picture survives `stop=sos` and `stop=smu` (K3's stop tests), which K8's in-boot release relies on.
- D-K option b is only possible if the owner changes hard rule 1.
