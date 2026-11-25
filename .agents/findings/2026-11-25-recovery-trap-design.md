<!-- SPDX-License-Identifier: MIT -->

# The recovery trap and the GOP fallback: research and design (2026-11-25)

Phase 2 item 3 (STATUS rows D7, D30, D risk 3; the Fable-pass open points under item 1). Research only: code read
on `fork/main` (`0368354`), the XTX machine read without changes (`nvram -p` names only, `ioreg`, `sysctl`,
`/var/log/phxboot.log`, `log show`), and the public OpenCore, IOGraphics and XNU sources. Nothing here was built or
booted. A statement about the machine names the XTX machine (macOS 26.7.1 25G241, EFI change 34, VermilionBoot b160,
VermilionAccel `03c1e47d`). Everything not tested on hardware is marked (unverified).

## Summary

- The squat is decided by the NVRAM variable `phxfb-squat`. The variable was set from Linux and can't be cleared from
  macOS: OpenCore's `DisableVariableWrite` rejects every non-volatile write and has no exception for a vendor GUID.
  So every boot on this machine is a squat boot. The daemon's `~/gpu/phxboot-nvstuck` latch says "stuck" at every
  boot. Every failure therefore ends in the safe desktop or in a dark screen, never in the firmware (GOP) display.
- Recovery, Safe Mode and the installer squat too: VermilionBoot has `OSBundleRequired Root`, OpenCore injects it
  into every macOS boot, and nothing in those boots lights PhxAMDFB (unverified on hardware: likely no picture, D30).
- A squat can't be released in the running boot. Terminating `PhxFBSquatter` on the GPU's function 0 marks the nub
  for a hardware reset at the next match (IOPCIFamily, finding `2026-11-24-gfxhda-detach-gpu-hot-reset.md`; hard
  rule 1).
- **Design:** the kernel holds the framebuffer slot without attaching anything. The squatter's probe puts
  IOGraphics' own opt-out key `AAPL,iokit-ignore-ndrv` on the GPU's IOPCIDevice and returns no driver. The kext
  decides by itself: no hold in Safe Mode, in an image-boot root (Recovery, the installer) or with `-phxbringupoff`,
  and the hold lapses when no daemon checks in. The daemon keeps the failure record in files, as now, and gets the
  GOP picture *in the same boot* by asking the kext to release (remove the key, register the nub again): no reboot,
  no NVRAM, no terminate. After a failure it tries the full desktop again on its own after clean boots, and it tells
  the user in one plain sentence.
- **Plan:** (1) a daemon-only fix of the Fable points and the latches (no EFI change); (2) a VermilionBoot boot-mode
  check (EFI change); (3) the hold and in-boot release (EFI change, hw-safety review); (4) cleanup:
  `phxfb-squat` gone, Reset NVRAM harmless (owner decision).

## 1. How the squat is decided today

### Kernel (VermilionBoot, Boot KC)

- `PhxFBSquatter` (`src/vermilion-boot/phx_classes.cpp:415-460`, personality `src/vermilion-boot/Info.plist:40-55`:
  `IOProviderClass IOPCIDevice`, `IONameMatch display`, `IOPCIPrimaryMatch 0x744c1002`, `IOMatchCategory
  IOFramebuffer`, score 30000). It beats IONDRVFramebuffer (score 20000, System KC, so it probes later) for the
  IOFramebuffer category of the GPU's function 0. While the category is held, PhxAMDFB (on the PhxDisplay nub) is
  the only framebuffer. Without the squat, IONDRV takes the GOP framebuffer and PhxAMDFB is a second, "phantom"
  display for the same monitor.
- `takeSquatArming()` (`:428-447`): squat when `/options` has `phxfb-squat`. It removes the property, forces a commit
  (`IONVRAM-FORCESYNCNOW-PROPERTY`) and reads it back. When the read-back still finds it, it calls the variable
  "stuck" and doesn't squat. `probe()` (`:449-454`) returns no driver with `-phxbringupoff`.
- Why the stuck check never fires: the removal only edits IODTNVRAM's copy in memory, which then reads "absent".
  The firmware write is refused later, out of sight. On the next boot the firmware still has the variable. The
  daemon's `rearm` (`tools/phxctl/phxboot-navi31.sh:265`) writes the same copy in memory and reads it back, so its
  "read-back ok" proves nothing across a reboot. Today `nvram phxfb-squat` reads `1`: that is the in-memory value the
  11:42 SUCCESS re-armed, not proof of a firmware write.
- The kext has no Safe Mode, Recovery or installer check. Its `OSBundleRequired` is `Root`
  (`src/vermilion-boot/Info.plist`), so it loads in Safe Mode and Recovery. VermilionAccel has none, and it loads from
  the AuxKC, which neither of them loads (unverified for this build).
- PhxAMDFB's `phxfb-boot` (`src/vermilion-accel/accel/phxfb.cpp:1382-1414`) has the same one-shot pattern. The
  daemon sets it in the same boot (`:320`), so it works as a same-boot handshake, but its "removed and committed" is
  just as unreal across a reboot.

### OpenCore

- `efi/machines/b650e-i-xtx.json:38-39`: `DisableVariableWrite true`, set against the Ryzen 7000 installer hang
  (2026-11-19). OpenRuntime's `WrapSetVariable` (`Platform/OpenRuntime/UefiRuntimeServices.c`, OpenCorePkg master,
  read 2026-11-25) starts with `if (WriteProtection && (Attributes & EFI_VARIABLE_NON_VOLATILE)) return
  EFI_SECURITY_VIOLATION;`. That check comes before any GUID or name test, so no vendor GUID gets through. Only
  volatile writes pass, and they don't survive a reboot. `RestrictedVariables` only guards OpenCore's own read-only
  GUID.
- `phxfb-squat` lives in the firmware under the Apple NVRAM GUID `7C436110-AB2A-4BBB-A880-FE41995C9F82`, written
  from Linux through efivarfs (bring-up log, 2026-11-20).
- The NVRAM write test (stage `vermilion-trust-nvram`, `efi/machines/b650e-i-xtx.json:112-116`, EFI change 12) is
  still inconclusive (PROJECT_KNOWLEDGE, change 12).

### Daemon (`tools/phxctl/phxboot-navi31.sh`)

| What | Where | Meaning |
|---|---|---|
| `SQUAT` | `:200-205` | 1 when `PhxFBSquatter` shows in `ioreg` within 60 s |
| `MARK` `/var/db/phxboot.pending` | `:26`, set `:598`, cleared `:699`, `:130`, TERM trap `:601` | a desktop attempt in progress; set only after the claim |
| `OFF` `~/gpu/phxboot-off` | `:27`, set by the daemon itself on an unfinished attempt `:297` | kill switch; removed only by hand |
| `FAILF` `~/gpu/phxboot-failed` | `:30`, set `:129`, `:842`, cleared only by a full SUCCESS `:701` | the last accelerated attempt failed |
| `NVSTUCK` `~/gpu/phxboot-nvstuck` | `:280-288` | `pending` after a reboot meant to clear the squat; `stuck` when the next boot still squats; removed only by a boot without the squat |
| `SAFEF` `~/gpu/phxboot-safe` | `:280`, `:305-310` | a safe-desktop attempt started; a second unfinished one goes headless |
| `squat_reboot` | `:288` | write `pending`, `nvram -d`, reboot; returns 1 without a reboot when stuck |
| `headless` | `:289` | exit with a dark screen (ssh and T3 still reach the machine) |
| `m2_fail` | `:129-133` | `b21_on`, touch `FAILF`, `apps_only`, `debug.phxagdc=0`, `nvram -d`, then `squat_reboot` or (when stuck) stay up |
| SAFE decision | `:291-310` | kill switch, unfinished attempt, or stuck + `FAILF`: CPU copy at the boot mode, no GPU present, mode list, flip, M7, b15, VCN |
| warm refusal (#22) | `:328-331` | on a desktop boot `m2_fail`, else firmware display |
| claim | `:586` | runs whatever the bring-up returned |

On the XTX machine, `nvstuck: still a squat boot` appears at every boot in `/var/log/phxboot.log`, from 2026-11-24
00:17:56 through 2026-11-25 11:40 (all 26 boots). `NVSTUCK` holds `stuck` for good, because no boot without the
squat comes to remove it. So `STUCK=1` at every boot.

## 2. Every state the machine can end up in

On the XTX machine (squat at every boot, `STUCK=1`), from the code above and the 2026-11-24 log.

| Event | What the daemon does | Screen this boot | Next boots | Way out today |
|---|---|---|---|---|
| Clean boot | full attempt, SUCCESS, re-arm (no effect) | full desktop | the same | - |
| Restart or shutdown during the attempt | TERM trap `:601` clears `MARK` | - | full desktop | - |
| Freeze or forced power-off during the attempt (after the claim) | next boot: `:296-301` touch `OFF`; `squat_reboot` returns 1 (stuck) | safe desktop | safe desktop at every boot (`OFF` is never removed) | `rm ~/gpu/phxboot-off ~/gpu/phxboot-failed` |
| The same with `NVSTUCK` absent (first time, or a new machine) | `squat_reboot`: one reboot, then as above | none (reboots) | as above | as above. Seen 2026-11-24 00:17:00 then 00:17:56 (log lines 4492-4536) |
| The safe desktop freezes too | next boot: `HUNG` + `SAFEF`: `headless` `:307` | dark | alternates: safe desktop, headless, ... | the `rm`, after a safe desktop boot |
| Freeze after SUCCESS (e.g. the HDR freeze) | nothing is recorded (`MARK` cleared at `:699`) | - | full desktop | - (as a Mac does) |
| `m2_fail` after the claim (no Metal device, AGDC, 3 WindowServer crashes, a user logged in) | `FAILF`, `apps_only`, `debug.phxagdc=0`; stuck: `release; exit 0` (`:132`) | whatever the first WindowServer shows on PhxAMDFB (unverified: likely a desktop without acceleration, or dark) | safe desktop at every boot (stuck + `FAILF`, `:302`) | the `rm` |
| `watch_hangs`: 2 hangs after SUCCESS | `FAILF`; stuck: stay up `:843` | the hung desktop | safe desktop at every boot | the `rm` |
| Warm GPU refusal (#22) on a squat boot | `m2_fail`: `FAILF`, `apps_only`, `debug.phxagdc=0`; stuck: stay up | **dark** (squat, no PhxAMDFB without a claim) | after a power-off: safe desktop at every boot (`FAILF`) | power off, then the `rm` |
| The same with `NVSTUCK` absent | `squat_reboot`: a warm reboot | none | the reboot comes back as a stuck squat: refusal again (if still warm), dark; or the safe desktop | as above |
| Bring-up fails before its end (sOS doesn't start, autoload) | no case for it: claim `:586` on a GPU that isn't up | unknown (claim on a half-up GPU) | bring-up's 3-min watchdog reboots, warm; `MARK` was never set, so the next boot is a full attempt again (possible loop, unverified) | - |
| A later check fails (KIQ, scheduler, compute queue; `navi31_up.sh:15-19`) | claim `:586` anyway, the watchdog already cancelled | unknown | - | - |
| Bring-up hangs (no `MARK` yet) | the watchdog reboots after 3 min | console text, then a reboot | a full attempt again (unverified) | - |
| Display latched dark (`disp_check`) | one restart (`DARKF`), then stay up | dark, then restart | full desktop; a second dark boot stays up | - |
| Recovery, installer | no daemon, no AuxKC | **no picture** (unverified; D30) | - | hold power; `-phxbringupoff` needs an EFI change |
| Safe Mode (Shift) | daemon: unknown whether third-party LaunchDaemons run (unverified); VermilionAccel doesn't load | **likely no picture** (unverified) | - | as above |
| `-phxbringupoff` | not a squat boot: IONDRV, GOP + Metal for apps | GOP | - | it is an EFI change (boot-args from the config) |

Two smaller facts from the log: `previous shutdown cause` reads 5 on today's boots. The early-boot kernel lines of
2026-11-24 00:16 (the boot after the 00:14 freeze) are no longer in the unified log. So whether VirtualSMC reports
a different cause after a freeze is unknown. It isn't used below.

## 3. The Fable-pass open points (item 1) in detail

1. **A warm refusal on a squat boot.** On this machine (`STUCK=1`) it doesn't reboot a second time: `m2_fail`'s
   `squat_reboot` returns 1 and the daemon stays up, dark. The second warm reboot happens only when `NVSTUCK` is
   absent. In both cases the refusal sets `FAILF`, so after the power-off that the refusal asks for, every boot is
   the safe desktop until the `rm`. A refusal is not a driver failure. It must not set `FAILF`, call `m2_fail` or
   reboot.
2. **`m2_fail` after a refusal** runs `apps_only` (writes the allow list), `b21_on` (loginwindow keys), and
   `sysctl -w debug.phxagdc=0`. PhxAMDFB registers that oid only at the end of its start (`:627-630`), and it doesn't
   start without a claim, so the write fails and reaches no hardware (code reading; unverified on hardware).
   Harmless, but none of it belongs on a GPU that nothing touched.
3. **A bring-up failure that isn't the warm refusal still claims the GPU.** `:328` matches only `refused: warm GPU`.
   For any other `navi31_up.sh` failure, the daemon goes on to `aoc_modes`, `p0modes`, the VRR and HDR writes and
   `"$MB" claim` (`:586`). Then NMXAccel and PhxAMDFB start on a GPU without working queues. Fix: only a result
   with `navi31 up:` may claim; anything else is a failure before the display was touched.

## 4. Options

| Option | OpenCore change | Failure fallback | Recovery / Safe Mode | Verdict |
|---|---|---|---|---|
| A. The kext holds IOFramebuffer through `AAPL,iokit-ignore-ndrv` and decides by itself; in-boot release on request or timeout (section 5) | none for the mechanism (the kext is an EFI change) | GOP in the same boot, no reboot | no hold there | **recommended** |
| B. `DisableVariableWrite` off (stage `vermilion-trust-nvram` exists) | Booter quirk off; a separate install profile with it on | the one-shot works as upstream designed: the next boot is GOP | still squats: a Recovery boot after a normal boot takes the armed squat, so no picture, and the next normal boot is GOP | worth its own test (panic reports, D29); not enough alone |
| C. OpenCore sets `phxfb-squat` each boot: `NVRAM > Add` + `Delete`, `WriteFlash false` | Add/Delete under the Apple GUID | none: armed again every boot, the failure path can't clear it | still squats | rejected (decisions.md 2026-11-19); obsolete with A |
| D. Emulated NVRAM (`OpenVariableRuntimeDxe`, `LegacySchema`, `nvram.plist` saved by a launch daemon) | driver + `LegacySchema` for the Apple GUID | only after a clean save: a freeze keeps the old plist | still squats | rejected: meant for boards without NVRAM, not standard |
| E. A vendor GUID that stays writable | not possible: `WrapSetVariable` has no GUID exception | - | - | would need an OpenRuntime fork; against "stock OpenCore" |
| F. The kext terminates the squatter to fall back | none | would hot-reset the GPU (IOPCIFamily marks the nub for reset on a detach) | - | forbidden (hard rule 1) |
| G. A failure record in the kernel without NVRAM (GPU scratch registers, CMOS, previous shutdown cause) | none | scratch registers are a register write Linux's order doesn't have (rule 1) and don't survive the power-off a freeze needs; CMOS isn't standard; the shutdown cause is unverified | - | rejected; the record stays in the daemon's files, and A doesn't need it in the kernel |

What a real Mac does: NVRAM is writable, and no arming variable exists. The GPU's own framebuffer driver
outscores IONDRV at boot, so it never needs a squat. Safe Mode (Shift) loads only the kexts the boot needs. When
the GPU driver isn't among them, the display runs on IONDRV's generic framebuffer at the firmware mode (unverified
for every Mac model). Recovery has its own copy of the drivers. After a panic the next boot shows "your computer
restarted because of a problem" and saves a report from NVRAM. Apple silicon Macs also start recoveryOS by
themselves after failed boots (unverified detail). A has the same shape: the driver decides at boot, the user's
escape hatches (Shift, Recovery) show a picture, and a failed start costs one boot, not a manual repair.

## 5. Design

### 5.1 The hold, without a squatter

IOGraphics' `IONDRVFramebuffer::probe` starts with `if (provider->getProperty(kIONDRVIgnoreKey)) return NULL;`, and
`kIONDRVIgnoreKey` is `"AAPL,iokit-ignore-ndrv"` (`IONDRVSupport/IOKit/ndrvsupport/IONDRVSupport.h:33`,
apple-oss-distributions/IOGraphics main, read 2026-11-25). The boot framebuffer it would otherwise use is the
`PE_Video` console found inside one of the device's BARs (`IOBootNDRV::fromRegistryEntry`).

- `PhxFBSquatter::probe` keeps its personality and its place (Boot KC, before IONDRV). It no longer reads
  `phxfb-squat`. It decides the hold (5.2). When holding, it sets `AAPL,iokit-ignore-ndrv` on the provider and
  always returns no driver. Nothing attaches to the IOFramebuffer category, so nothing ever has to be detached.
- **Release** (one-way, once per boot): remove the property, then `registerService()` on the IOPCIDevice. IOKit
  matches the nub's unclaimed categories again, IONDRV's probe passes, and IONDRV starts on the GOP framebuffer.
  PhxBringup keeps its own category. IOPCIFamily resets a nub only after a detach, and there is none
  (unverified: needs the IOPCIFamily read and a test). The release is refused after the claim. From then on
  PhxAMDFB may have reprogrammed the display, so the GOP framebuffer may no longer be scanned. After the claim the
  fallback stays a reboot.
- **Interface** (names per `docs/NAMING.md`): `debug.phxfb_owner` (read) answers `held`, `gop: safe boot`,
  `gop: image boot`, `gop: -phxbringupoff`, `gop: released (<why>)` or `gop: no daemon`. `debug.phxfb_gop` (write,
  root): `0` = the daemon checked in (keep the hold), `1` = release, refused with EBUSY after the claim. PhxBringup
  also refuses the claim after a release, so PhxAMDFB can't become a second display next to IONDRV.
- **Timeout:** with no check-in within 90 s of the hold, or no claim within 180 s of the check-in, the kext releases
  by itself (`gop: no daemon`). This covers a Recovery or installer boot that 5.2 doesn't recognise, a removed
  daemon and a daemon that died before the claim. The numbers are starting points: today the daemon starts 4-14 s
  after the kernel and claims about 10 s later (log).
- The first WindowServer already copes with a framebuffer that appears late: on today's squat boots PhxAMDFB
  appears at the claim, ~14 s after the kernel, and WindowServer shows the login on it (audit D2). The same for
  IONDRV is (unverified).

### 5.2 The kext decides the hold at boot

No hold, and so IONDRV at once:
- `-phxbringupoff` (as today);
- Safe Mode: boot-arg `-x`, which XNU itself reads for safe boot (`OSKext::initialize`, `sSafeBoot =
  PE_parse_boot_argn("-x", ...)`). OpenCore's picker adds it with Shift+Enter (unverified on this machine);
- an image-boot root, as Recovery and the installer use (BaseSystem): XNU's `imageboot_desired()` reads `rp0`,
  `rp`, `arp0` and the `IMAGEBOOT_ROOT_ARG` / `IMAGEBOOT_AUTHROOT_ARG` boot-args (`bsd/kern/imageboot.c`). Which
  one boot.efi passes for an APFS Recovery boot, and whether it passes it as a boot-arg or in `/chosen`, is
  (unverified): the first Recovery test records it. A normal boot here has none of them in `kern.bootargs`
  (checked today). The timeout covers a miss.

### 5.3 The daemon: record, fallback, return, notice

- **Check-in first.** Before the pre-start hook and the bring-up: `debug.phxfb_gop=0`, and the in-progress mark,
  so a hang in the bring-up counts as an unfinished attempt (today the mark is set only after the claim).
- **Record:** `/var/db/phxboot.pending` (as now) and `/var/db/phxboot.fails` (consecutive failed or unfinished full
  attempts), both root-owned. They replace the daemon's own use of `OFF`, `FAILF`, `SAFEF` and `NVSTUCK`. The
  kill switch `~/gpu/phxboot-off` goes back to being the owner's alone: the daemon never creates it.
- **Decision at start:**
  - Safe Mode (`kern.safeboot` 1): exit. No bring-up, no `kmutil load`.
  - The kext already says `gop: ...`: as today's GOP boot (Metal for apps after a cold bring-up), never in Safe Mode.
  - An unfinished attempt (`pending`), or `fails` > 0 with no clean GOP boot since: `fails`+1 if it was unfinished,
    release (`debug.phxfb_gop=1`, `why=last startup didn't finish`), **no bring-up this boot** (the GPU untouched,
    so the fallback can't fail the same way), notice.
  - Otherwise a full attempt.
- **During the attempt:**
  - warm refusal: release, notice "shut down fully". `fails` unchanged, no `m2_fail`, no `FAILF`, no reboot.
  - any other bring-up failure: no claim. `fails`+1, clear `pending`, release. A bring-up watchdog that is still
    armed stays armed (rule 1: keep the watchdog), and its reboot then counts as a failure already recorded.
  - failure after the claim (`m2_fail`, `watch_hangs`): `fails`+1, reboot as today. The next boot is a GOP boot
    through the release.
  - SUCCESS: `fails`=0.
- **Return:** a GOP fallback boot that ends with a clean shutdown or restart (the TERM trap) counts as clean. After
  one clean fallback boot the next boot tries the full desktop again. After 3 failures in a row it waits 3 clean
  fallback boots between tries. Nothing to `rm`. The safe desktop (CPU copy on PhxAMDFB) is no longer needed and
  goes in step 4.
- **Notice:** one sentence in `/var/db/phxboot.notice`, shown once after login as a user notification. For example
  through `launchctl asuser <uid> osascript -e 'display notification ...'` from the daemon, or a small LaunchAgent
  (the shape is an open choice). Wording:
  - "Graphics acceleration is off for this startup because the last startup didn't finish. Your Mac will try
    again the next time it starts up."
  - "The graphics card was still running from another operating system. Shut down (don't restart), then turn the
    computer on again to get graphics acceleration back."
  - "Graphics acceleration failed to start 3 times in a row. It will try again after 3 more startups."
- **Compatibility:** a daemon that finds no `debug.phxfb_owner` keeps today's logic, so the new daemon can go
  first. A new kext with today's daemon gives GOP boots: that daemon finds neither the squatter nor a framebuffer,
  arms nothing, and the timeout releases at 90 s. Never ship the kext before the daemon.

### 5.4 Hard rules

The design adds no register write and no SMU, PSP or DAL message. It terminates no driver on the GPU's functions.
It keeps the kill switch, the pending mark, the bring-up watchdog and the dark-display restart. It makes the GOP
revert real instead of a reboot into the same squat. Reset NVRAM becomes harmless: nothing depends on
`phxfb-squat` any more. Bringing it back, and rewording hard rule 1, is the owner's decision.

## 6. Ranked plan

Each step is its own branch and PR. Every PR gets the Fable pass.

| # | Change | Reviews | Machine change | Check | Rollback |
|---|---|---|---|---|---|
| 1 | **Daemon only, today's kext.** The warm refusal gets its own path: no `m2_fail`, `FAILF`, `apps_only`, `debug.phxagdc=0` or reboot; stay up and log. Only a result with `navi31 up:` may claim; other failures are recorded as failures without a claim. The in-progress mark goes before the bring-up. Safe Mode exits. The daemon stops creating `OFF`. After one clean safe-desktop boot the next boot tries the full desktop (`/var/db/phxboot.fails`). The notice. On a squat boot a refusal or a bring-up failure is still dark until step 3, but it no longer latches the safe desktop | mock scenarios (`tests/mock/run.sh`: refusal with `STUCK` 0 and 1, bring-up failure before and after the watchdog, hang in the bring-up, return after a clean safe boot, Safe Mode), `b15test.sh`; hw-safety not required (it removes GPU access, adds none) | `~/gpu/phxboot-navi31.sh` (machine lock) | next boot: `SUCCESS`, the same lines as today plus the check-in line; mocks green | `~/gpu/phxboot-navi31.sh.prev` (copy in `~/vermilion-rollback`) |
| 2 | **VermilionBoot b161: boot-mode check.** The squatter doesn't squat with `-x` or an image-boot root (5.2); `PHX_KEXT_BUILD` and CHANGELOG | preflight; no GPU programming (hw-safety not required; one read of the probe change is cheap) | EFI change (Boot KC kext) | a normal boot still squats (`squat boot ...: 1`); Safe Mode (Shift+Enter) shows a picture; Recovery shows a picture, and `kern.bootargs` plus the `/chosen` key names there are recorded; if Recovery stays dark, hold power and boot normally (no state is left behind) | `EFI/OC.prev` |
| 3 | **VermilionBoot b162 + daemon: the hold and the release** (5.1, 5.3): `AAPL,iokit-ignore-ndrv`, `debug.phxfb_owner` / `debug.phxfb_gop`, the timeout, the claim refused after a release; the daemon's check-in, in-boot fallback and return | **hw-safety-reviewer** (IONDRV starting on function 0 after a partial bring-up; its power management of the IOPCIDevice; IOPCIFamily's reset path without a detach) and an IOKit read of `registerService` re-matching; mocks; preflight | daemon first (it works with b160/b161), then an EFI change | normal boot: `held`, no `IONDRVFramebuffer` in `ioreg`, full desktop. A test flag forces the fallback: GOP picture, notice, no `sOS check:` line (GPU untouched); the next boot is full again. Recovery and Safe Mode: a picture (Recovery within 90 s at worst). A warm boot from Linux: GOP picture and the "shut down fully" notice | `EFI/OC.prev`; `phxboot-navi31.sh.prev` |
| 4 | **Cleanup.** Delete `phxfb-squat` (from Linux through the `linux-queue` skill, or `NVRAM > Delete` under the Apple GUID: an EFI change). Remove `NVSTUCK`, `SAFEF`, `squat_reboot`, `headless` and the safe desktop (a refactor commit, separate from any behaviour change). Docs: `docs/XTX.md`, PROJECT_KNOWLEDGE, runbooks, decisions (supersedes 2026-11-19 and 2026-11-20). Owner: Reset NVRAM entry back or not; hard rule 1's Reset NVRAM text | mocks; Fable | EFI change if done through OpenCore | `nvram -p` without `phxfb-squat`; a normal boot still `held` | `EFI/OC.prev`; re-set from Linux |
| 5 | **Separate, optional:** the NVRAM write test again (stage `vermilion-trust-nvram`), for panic reports (D29). Item 3 doesn't need it | - | EFI change | TODO 01 test | `EFI/OC.prev` |

No AuxKC change is needed. A later VermilionAccel change can replace `phxfb-boot` with a registry handshake, and
PhxAMDFB can refuse to start after a release (a second guard next to PhxBringup's refused claim). In phase 3 the
bring-up moves into the kernel. The kext then releases to the GOP on its own bring-up failure, and the daemon's
record shrinks to the cross-boot counter.

## 7. Open questions

- Does `registerService()` on an already registered IOPCIDevice re-match only its unclaimed categories, with no
  IOPCIFamily reset (step 3's hw-safety and IOKit read, then a test)? (unverified)
- Does IONDRV find the GOP framebuffer with the 1 GiB BAR (`ResizeAppleGpuBars 10`)? The last GOP boots on this
  machine predate the 1 GiB BAR (unverified).
- Does the first WindowServer take an IONDRV framebuffer that appears late, as it takes PhxAMDFB today? (unverified)
- Which boot-arg or `/chosen` property marks an APFS Recovery boot (step 2's test)?
- Do third-party LaunchDaemons run in Safe Mode on 26.7.1? (unverified; the daemon exits either way.)
- Does the GOP picture survive a bring-up that failed halfway (PSP, SMU firmware loaded)? Today's squat boots show
  the console text through the bring-up, which suggests yes (unverified).
- Not part of this item: the audit finding `2026-11-24-audit-display.md` still calls `debug.phxfb_kill_iondrv` live.
  It has been gone since 2026-11-25 07:01 (STATUS item 1).
