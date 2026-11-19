# TODO

The goal: a fully working, stable macOS Tahoe on the XTX machine ([docs/REFERENCE-MACHINES.md](../docs/REFERENCE-MACHINES.md)).
That means the GPU accelerated at 1440p high refresh, plus Wi-Fi, Bluetooth, Ethernet, audio and USB. After that, the
same install as a VFIO VM. Then clean up, document and hand over to the community.

Rules: tick items when done (with the date), add new ones where they belong, link findings. `[ ]` open, `[~]` in
progress, `[x]` done, `[-]` dropped (say why).

## Current state (2026-11-19, 10:05): Wi-Fi works; next Bluetooth

**Wi-Fi works on macOS** (MtkWirelessWifi 1.1.1 + boot-arg `pci=0x8000000`, [findings](findings/2026-11-19-wifi-mt7922.md)).
The cause was macOS setting 10-Bit Tag Requester Enable on the chipset root port, which the MT7922 and the I225-V
can't complete. EFI = `vermilion` stage (inherits `base`), built and installed from the Mac; `OC.prev` = the same
without `pci=0x8000000`. Next: Bluetooth (USB `0489:e0e2`), then Ethernet (its capability list is back).

## Earlier (09:00): on the Mac; Wi-Fi blocked by an empty PCI capability list

**Next: one Linux capture** ([HANDOFF-LINUX-CAPTURE.md](HANDOFF-LINUX-CAPTURE.md), for the Claude on Omarchy): the
owner boots Linux once, `tools/capture/linux_pci_capture.sh` writes `/boot/vermilion/capture/linux-pci-*.txt`,
then back to macOS, which reads it from the EFI partition. EFI for that macOS boot: `vermilion` stage (installed
2026-11-19 09:16 from the Mac), `OC.prev` = `vermilion-pcilog`.

Wi-Fi: both MediaTek drivers fail because macOS gives the card (and the I225-V) an empty PCI capability list
([findings](findings/2026-11-19-wifi-mt7922.md), boot 2). Boot 3 (`vermilion-pcilog`, logging only) is installed.
EFI builds now work on the Mac (`iasl` 20251212 in `~/.local/bin`, config in `~/.config/vermilion`).

## Earlier: work moves to macOS itself

**From here on the owner works in macOS on the XTX machine** (Claude Code + T3 Code installed there over Wi-Fi), not
from Linux. If you are that macOS session, start here:

1. **Wi-Fi boot 1 failed** (AirportMtkWlan loaded, never attached; [findings](findings/2026-11-19-wifi-mt7922.md)).
   **Boot 2** (staged 07:15): `MtkWirelessWifi` 1.1.1 instead, `run-once.sh` = `wifilog.sh` with deep snapshots to
   `/var/log/vermilion-wifi-*.log` and `*.log.ioreg`. Boot 1's `run-once.sh` turned **sleep off** (`pmset -a sleep 0 displaysleep 0
   disksleep 0 hibernatemode 0 standby 0 powernap 0 tcpkeepalive 0 womp 0`; result lines in `/var/log/phxboot.log`
   under `run-once:`; it stays off). On the Mac itself, `ioreg -l -w0 -r -n DP58` answers directly whether a driver
   attached to the card.
2. **The EFI partition from macOS:** `diskutil list` (the NVMe's EFI partition, under Recovery it was `disk2s1`),
   `sudo mkdir -p /tmp/efi && sudo diskutil mount -mountPoint /tmp/efi <diskXs1>`. On it: `EFI/OC` (live),
   `EFI/OC.prev` (rollback), `opencore-*.txt` (OpenCore log of every boot), `vermilion/` (payload, flags, run-once).
3. **EFI builds on the Mac** need what Linux kept outside git, now in `<EFI>/vermilion/handoff/config-vermilion/`:
   copy it to `~/.config/vermilion/` (mode 0700; the SMBIOS serials and the ACPI dump, which includes `VFCT.aml` =
   the VBIOS: **never commit or publish any of it**). `build/VermilionBoot.kext` (b126) = `<EFI>/EFI/OC/Kexts/
   VermilionBoot.kext`. `build.py` needs `python3` and `iasl` (Command Line Tools; acpica). Install with
   `sudo efi/build.py install --esp /tmp/efi --stage vermilion`; one EFI change per boot still.
4. **NVRAM:** `DisableVariableWrite` is on, so macOS can't change NVRAM or the startup disk. The default OpenCore
   entry is set in the picker (Ctrl+Enter on Macintosh HD, 2026-11-19, unverified that it sticks).
5. **Boot path:** firmware boot order is OpenCore first (`0006,0000,...`), so power-on boots macOS after the picker's
   10 s. A Linux **reboot** goes back to Linux (`tools/linux/vermilion-reboot-to-linux.service` sets BootNext=Limine
   on reboot only; tested by a real run and cleared, the reboot path itself unverified). Linux -> macOS is still a full
   power-off. macOS restarts are fine. Linux is still reachable with F8 > Limine.
6. **Next, in order:** Wi-Fi verified -> Bluetooth (`0489:e0e2`) -> Ethernet -> USB map -> audio -> AirDrop/Continuity
   -> sleep/wake (only with the driver off, `-phxbringupoff`, one boot, after asking the owner). Graphics stays paused.

The lines below predate this and describe the machine from Linux.

## Handoff (2026-11-19, late night)

**Graphics is paused here; the next thread works on everything else (Phase 1 rest: sleep, USB, Ethernet, Wi-Fi,
Bluetooth, AirDrop, audio), from a Claude Code / T3 Code install on the Mac itself.** Graphics state to come back to:
GPU present at 1440p60 works (b126; no CPU copy, median 40 frames/s) but flickers, shows occasional artifacts and the
CPU runs hotter ([findings](findings/2026-11-19-1440p-gpu-present.md), boot 2). Then 144/240 Hz (Phase 3).

Working on the Mac itself: the hard rules still hold (cold power-off from Linux, one EFI change per boot with a
rollback copy, no SMBIOS/serials in git). **Sleep:** Vermilion has no resume path (Phase 4); a real S3 sleep with the
driver up will most likely lose the GPU (unverified), so keep `pmset` sleep off and test ACPI sleep/wake only on a boot
with the driver off (`-phxbringupoff`, one boot). Builds on the Mac need the build-host setup of
[runbooks.md](runbooks.md) (Command Line Tools, MacKernelSDK, ...); installing a kext on the live system still goes
through the EFI (VermilionBoot) or the AuxKC (VermilionAccel), one change per boot.


- **The accelerated desktop runs on the XTX** (Vermilion, Metal compositor, one display at 2560x1440) on macOS 26.7.1
  bare metal. Every OpenCore boot is a squat boot and arms the desktop by itself
  ([findings](findings/2026-11-19-first-vermilion-boot.md)). The GPU bring-up needed no XTX change.
- **Boot routine:** Linux via Limine (default). macOS: full power-off, F8 > OpenCore > Macintosh HD. **No Reset
  NVRAM** any more: it deletes `phxfb-squat` (then the next boot is a non-squat boot with a phantom "UNKNOWN" IONDRV
  display). Reset NVRAM is the escape hatch back to the plain firmware display. A failed desktop attempt reboots, and
  the default entry is Limine, so it lands in Linux. Warm macOS restarts are fine on this card.
- **Machine state:**
  - EFI: `vermilion` stage with **VermilionBoot b126** on `/boot/EFI/OC` (2026-11-19 05:30; `OC.prev` = the same stage
    with b125, the last booted one; the `install` stage is backed up in `~/.cache/vermilion/efi-backup/`);
    `DisableVariableWrite` on, so macOS can't write firmware NVRAM.
  - GPU present is on (`/Library/GPUBundles/nvmtl/ws-gpu-present`, created by boot 2's run-once). Nothing is staged
    on the EFI partition (`/boot/vermilion/perf/` holds the logger for a later run-once).
  - `phxfb-squat` is set as an EFI variable from Linux
    (`/sys/firmware/efi/efivars/phxfb-squat-7c436110-ab2a-4bbb-a880-fe41995c9f82`, value "1").
  - `~/gpu` flags: `sdma`, `cg`, `uclk=456`.
  - `~/gpu/phxboot-pre.sh` = `tools/phxctl/esp_flags.sh` (takes `<EFI>/vermilion/flags/phxboot-*` and runs
    `<EFI>/vermilion/run-once.sh` once as root): **this is how files and flags reach macOS without a desktop**.
  - The AIR bitcode reader (`air-runtime/libLLVM.dylib`, from NullMoth 3.0) is installed.
- **Observability from Linux (no macOS shell needed):** `apfs-fuse` read-only mount of the Data volume
  (`~/.local/src/apfs-fuse`), `/var/log/phxboot.log`, crash reports, the unified log decoded with
  `~/.local/src/macos-UnifiedLogs` ([runbooks](runbooks.md)). Build host: macbox ([runbooks](runbooks.md)).
- **Next steps, in order:**
  1. **Input lag at 1440p** ([findings](findings/2026-11-19-1440p-gpu-present.md)): every frame (14.7 MB) is CPU-copied
     into phxfb's flip buffer B (B fits at 1440p; only the GPU-present slots were 8 MiB). b126 gives frames over 8 MiB
     three GPU-present slots at 256/288/320 MiB (past BAR0, GPU only), the XT's 1080p slots unchanged. Boot 1 done: no
     regression, layout `large`, baseline 10-12 ms copy + 15-20 ms flip wait per frame, ~30 frames/s cap. Boot 2
     (staged): `run-once.sh` creates `/Library/GPUBundles/nvmtl/ws-gpu-present`, same logger; read
     `/var/log/vermilion-perf-*.log` and the kernel's `scanout acquired` line.
  2. The monitor's refresh: **60 Hz** at 2560x1440 (OTG0 totals 2720x1481 in the kernel log, boot 7). 144/240 Hz
     needs mode switching + DP link training (Phase 3).
  3. Phase 1's rest: sleep off (`pmset`), delete p4 and grow the container, Wi-Fi, Ethernet (E1000 dext fails its
     entitlement check: I210 + `e1000=0` fallback), Bluetooth, USB map.
  4. Small fixes: `recovery_install.sh`'s Data-volume search (found 3 in Recovery), the reader in
     `esp_stage.sh`/`recovery_install.sh`, the canned profile still says "RX 7900 XT" / 84 CU (docs/XTX.md item 1).
- **Root:** never guess the password; T3's `request_secret` with file delivery.

## Phase 0: Housekeeping

- [x] 2026-11-18 Explore upstream and the machine; audit XT vs XTX ([findings](findings/2026-11-18-xtx-port-audit.md))
- [x] 2026-11-18 Fork to `ownback/vermilion` (remote `fork`; `origin` = leolivm upstream)
- [x] 2026-11-18 100 GiB partition for macOS on the NVMe (exFAT `MACOS`, to erase as APFS in the installer)
- [x] 2026-11-18 `CLAUDE.md`, `AGENTS.md`, `docs/README.md`, `docs/ARCHITECTURE.md`, `docs/GLOSSARY.md`,
      `docs/XTX.md`, `docs/REFERENCE-MACHINES.md`, this `.agents/` folder
- [ ] Make the mock tests run on Linux ([findings](findings/2026-11-18-mock-tests-on-linux.md)): `/private/tmp`
      becomes `${TMPDIR:-/tmp}`, then the BSD tool differences (`stat -f`, `date -j`, PlistBuddy, `sed -i ''`). Target:
      every suite green on both macOS and Linux
- [ ] CI: GitHub Actions running the mock tests (Linux runner), plus a macOS runner that builds the kexts, plugin
      and translator (no signing)
- [x] 2026-11-19 Set up the build host (macbox, macOS 26.7.3 + Xcode): MacKernelSDK, Rust, Python 3.12 via uv,
      meson/ninja, glslang, Mesa `f5cb8ee0`, SPIRV-Tools; every component built; steps in [runbooks.md](runbooks.md)

## Phase 1: Bare-metal macOS without GPU acceleration

Goal: macOS 26.7.1 boots from OpenCore on the GOP framebuffer, everything except GPU acceleration works.

- [ ] BIOS checklist for macOS (dGPU as boot display, Above 4G + ReBAR on, CSM off, Secure Boot off). Record the ASUS
      menu paths in [runbooks.md](runbooks.md)
- [x] 2026-11-18 Which macOS: Apple still serves the full 26.7.1 installer (build 25G241, catalog product
      `142-28081`); recovery would give the newest, 26.7.3 ([findings](findings/2026-11-18-efi-and-installer.md))
- [x] 2026-11-18 Installer media: macOS partition split into p3 78 GiB (`MACOS`) + p4 22 GiB (`macOS Installer`,
      HFS+ type). 26.7.1 (25G241) made in the macbox VM with `createinstallmedia` onto a bare HFS+ image, streamed onto p4
      and SHA-256 verified (`efi/installer/`)
- [ ] After the install: delete p4, grow the APFS container back to 100 GiB
- [x] 2026-11-18 Reproducible EFI builder: [`efi/`](../efi/README.md) (pinned + hashed inputs, config generated from
      `Sample.plist` + `efi/machines/b650e-i-xtx.json`, stages install/base/vermilion, `ocvalidate` clean)
  - [x] OpenCore 1.0.8, Lilu 1.7.2, VirtualSMC 1.3.8, NVMeFix 1.1.3, RestrictEvents 1.1.6, AppleMCEReporterDisabler
        (codeless, in repo), AMFIPass 1.4.1, AirportMtkWlan 2.1.6 (Tahoe), USBToolBox 1.2.0 (unused until a map exists)
  - [x] AMD_Vanilla `eaf52ef2` with core count `0x0C` and the Zen 4 IOPCIFamily patch
  - [x] `SSDT-EC-USBX-B650EI` written against this board's DSDT (EC0 at `\_SB.PCI0.SBRG.EC0`, no `_STA`)
  - [x] SMBIOS MacPro7,1 generated locally (`~/.config/vermilion/`, not in git)
  - [x] 2026-11-18 First boot of the `install` stage: the installer kernel started, then macOS rejected the DSDT
        (`GPP7.UP00.DP58` defined in a module-level `If`) ([findings](findings/2026-11-18-first-boot-acpi.md))
  - [x] 2026-11-18 DSDT fix: `efi/acpi/fix_dsdt.py` + `acpi-dump` + `RebaseRegions`; verified with `acpiexec`
  - [x] 2026-11-18 Second boot: the DSDT loaded (no ACPI errors) but it hung at the same line. Cause: the chipset
        devices are still conditional (nullmoth/1401 issue 21, same symptom on ASUS AM5)
  - [x] 2026-11-18 Fix v2: `fix_dsdt.py resolve` with the Linux namespace (unwrap active blocks, remove inactive ones)
  - [x] 2026-11-19 Then: in-place DSDT NOP patches, SSDT-CPUR, iGPU off, AGDP pikera patch, DisableVariableWrite.
        The installer ran to the end (see Current state)
  - [ ] USB map: the chipset controller `0c:00.0` has 17 ports (12 USB 2 + 5 USB 3), over macOS's 15 per controller.
        Map after the install (USBToolBox), or generate from Linux sysfs
- [x] 2026-11-18 `install` stage on the EFI partition (`/boot/EFI/OC`), firmware entry Boot0006 "OpenCore",
      boot order Limine (0000) first, OpenCore second (pick it with F8). `EFI/BOOT` untouched
- [ ] Optional: a Limine menu entry that chainloads OpenCore
- [x] 2026-11-19 macOS 26.7.1 installed on `Macintosh HD` (p3); all installer phases done, last one "Boot 1"
      ([findings](findings/2026-11-19-install-phases.md))
- [x] 2026-11-19 Read the macOS disk from Linux: `apfs-fuse` build steps in [runbooks.md](runbooks.md)
- [x] 2026-11-19 First normal boot of Macintosh HD: Setup Assistant drew on the GOP framebuffer, account created, desktop
      (slow, no acceleration) ([findings](findings/2026-11-19-install-phases.md))
- [ ] Post-install, one item at a time, each tested and logged:
  - [ ] Ethernet I225-V: try the built-in driver first. Fallback documented on Tahoe 26.7.1 with an I225-V:
        AppleIntelI210Ethernet 2.3.1 + `device-id 0x1533` + `e1000=0`
        ([GeekAudio/intel-i225-tahoe-fix](https://github.com/GeekAudio/intel-i225-tahoe-fix)); the B650E-F config
        uses the same kext + `e1000=0`
  - [x] 2026-11-19 Wi-Fi MT7922 (`14c3:0616`, subsystem `105b:e0cd`) ([findings](findings/2026-11-19-wifi-mt7922.md)):
    - [x] 2026-11-19 Boot 1: AirportMtkWlan 2.1.6 loaded but never attached (no driver object, no Wi-Fi port)
    - [x] 2026-11-19 Boot 2: MtkWirelessWifi 1.1.1 loaded, not attached either. Cause: the card's IOPCIDevice has
          an empty capability list (no MSI) because its config space didn't answer when IOPCIFamily published it;
          the I225-V has the same symptom. Hotplug ruled out
    - [x] 2026-11-19 Boot 3 (`vermilion-pcilog`) + live reads: the Wi-Fi and Ethernet endpoints stop answering
          config requests after the 0.5 s scan (reading them froze the machine); L1.2, default ASPM, BAR moves,
          ACPI power ruled out
    - [x] 2026-11-19 Linux-side capture ([handoff](HANDOFF-LINUX-CAPTURE.md)): under Linux every link on the path has
          Common Clock set on both ends (Link Control `0x0c42` on DP58, `0x0042` on the card); in macOS DP58 read
          `0x0002` (Common Clock clear) with retrain status bits set ([findings](findings/2026-11-19-wifi-mt7922.md))
    - [x] 2026-11-19 Nobody clears it in macOS: Common Clock was already clear at the 0.47 s scan on the whole chipset
          tree and no ACPI code writes link control; Linux sets CCC itself. Hypothesis: BIOS-enabled ASPM L1 with CCC
          clear, the endpoints never leave L1 in macOS ([findings](findings/2026-11-19-wifi-mt7922.md))
    - [x] 2026-11-19 BIOS PCIe ASPM off: no change (ASPM ruled out)
    - [x] 2026-11-19 Cause: macOS sets 10-Bit Tag Requester Enable on the GPP7 root port; MT7922 and I225-V can't
          complete 10-bit tags (Linux leaves the requester off)
    - [x] 2026-11-19 **Wi-Fi works** (boot 4): boot-arg `pci=0x8000000` in the `base` stage; MtkWirelessWifi 1.1.1,
          802.11ax 5 GHz 80 MHz, 780 Mbit/s, WPA2/WPA3; Vermilion unaffected
    - [ ] **Wi-Fi throughput drops periodically** (owner, 2026-11-19): fine for about 5 minutes, then very slow for
          about 30 seconds, repeating. Investigate later (owner's call). Leads, all unverified: background scans
          (Location Services, `airportd`), AWDL leaving the AP channel (MtkWireless boot-args `amtk_awdl=0`,
          `amtk_awdl_offchan=0`), in-driver roaming (`amtk_roam=0`), 802.11ax (`amtk_he=0`), power save. Measure
          first: a ping/throughput log over 15 min next to `log stream --predicate 'process == "airportd"'`, so
          the slow windows can be matched to an event; then one boot-arg per boot
    - [ ] Fix it (then Wi-Fi and probably Ethernet work)
  - [ ] AirDrop/Continuity over Wi-Fi: AirportMtkWlan's AWDL is off unless `-mtkawdl` (2.2.x AWDL builds panicked
        and were pulled); only after Wi-Fi is stable
  - [ ] Bluetooth MT7922 (USB **`0489:e0e2`** on this board, read 2026-11-19; not `0e8d:0616`): AirportMtkWlan's BT companion (announced, not in the v2.1.6 release)
        or SimpleMtkBtFw (add the USB ID if missing; only one loader). The companion 2.2.1 panicked or hung on Tahoe
        (AirportMtkWlan issues #14, #16)
  - [ ] USB audio (ASUS `0b05:1a5c`), front and rear USB ports (USB map), NVMe, CPU power management, shutdown/restart
  - [ ] Disable sleep for now (`pmset`, as in INSTALL.md section 10)
  - [ ] Back up the working EFI (outside git, without SMBIOS in any public place)

## Phase 2: Vermilion on the XTX, first light

Goal: an accelerated desktop at 1440p60 on the GOP mode, stable across many cold boots. Details:
[docs/XTX.md](../docs/XTX.md).

- [ ] Quick test before any rebuild: `RADV_DARWIN_CANNED=navi31` (upstream's XTX profile)
- [ ] `navi31_xtx` canned profile in a new Mesa patch; pick the profile by PCI revision (the kext reports it, e.g. in a
      spare `n48n_info.reserved[]` word); fix the exact-name checks in 0016/0017; marketing name "RX 7900 XTX"
- [ ] `mesboot.c`: derive `SYSTEM_APERTURE_HIGH` from `FB_LOCATION_TOP` instead of `0x00213fbf`
- [ ] Pipe-1 plans: HUBP1 aperture derived or per board (`0x00217fff` on the XTX)
- [ ] Metal core count from the profile (`nvmtl_corecount.c`)
- [ ] A boot log line (daemon or kext) with: PCI revision, DMCUB version (SCRATCH1), OTG0 totals, DP link
      rate/lanes, DPCD 0x100/0x101, `phx-bar0-len`, VRAM size
- [ ] Docs: name rev `0xC8` and `0xCC` in README, INSTALL, script headers
- [x] 2026-11-19 Build everything on the build host (macbox; [runbooks](runbooks.md))
- [x] 2026-11-19 Install path without a desktop: `esp_stage.sh` (Linux) + `recovery_install.sh` (Recovery), flags
      from Linux through `esp_flags.sh` (daemon pre-hook) ([findings](findings/2026-11-19-phase2-build-and-stage.md))
- [x] 2026-11-19 Install with flags `sdma`, `cg`, `uclk=456` only (Recovery, `VERMILION_DATA` override)
- [x] 2026-11-19 **First boot: the bring-up works on the XTX unchanged** (queues ready, SDMA idle, CG, UCLK pin)
      ([findings](findings/2026-11-19-first-vermilion-boot.md))
- [x] 2026-11-19 VermilionAccel into the AuxKC (one boot with a login; syspolicyd rebuilt it), `NMXAccel up`,
      Metal for apps ([findings](findings/2026-11-19-first-vermilion-boot.md))
- [x] 2026-11-19 First desktop-arm boot: arm path OK at 1440p, WindowServer aborted (no AIR bitcode reader)
- [x] 2026-11-19 **Accelerated desktop on the XTX: SUCCESS** (reader installed through run-once; Metal compositor)
- [x] 2026-11-19 Phantom "UNKNOWN" display fixed by squat boots: `phxfb-squat` written as an EFI variable from Linux
      (macOS can't write NVRAM here); it stays set, so every OpenCore boot is a squat boot. Delete it with Reset NVRAM
      or from Linux (`/sys/firmware/efi/efivars/phxfb-squat-7c436110-ab2a-4bbb-a880-fe41995c9f82`)
- [~] **Input lag at 1440p: frames are CPU-copied through the BAR** ([findings](findings/2026-11-19-1440p-gpu-present.md))
  - [x] 2026-11-19 VRAM layout audited (code + Linux read-only); flip B already fits 1440p; DCN FB TOP is `0x3936`
  - [x] 2026-11-19 VermilionBoot b126: GPU-present slots by frame size (large: 256/288/320 MiB), `debug.phxscan_layout`;
        host test 43/43, mock suites green on macbox, installed on the EFI (unverified on hardware)
  - [x] 2026-11-19 `tools/phxctl/perflog.sh` + `perflog_install.sh`: the display counters to a log, one boot only
  - [x] 2026-11-19 Boot 1: b126 + GPU present off: no regression; layout `large`, DCN window = all VRAM; baseline
        copy 10-12.6 ms/frame + 15-20 ms flip wait, ~20-33 frames/s (two refreshes per frame)
  - [x] 2026-11-19 Boot 2: GPU present on: large slots acquired, no CPU copy, median 40 / max 59.5 frames/s; owner:
        "way better" but flicker, occasional artifacts, CPU hotter
  - [ ] Flicker/artifacts with GPU present at 1440p (try `debug.phxscan_latchfix=1`, capture `phxscan_race_stat`)
  - [ ] CPU heat with GPU present (measure: `powermetrics`, WindowServer CPU; the plugin's per-present fence wait)
  - [ ] If it holds: make GPU present the default at 1440p (daemon or install), docs; consider `debug.phxscan_latchfix=1`
        (b74 UI-shake fix, default 0)
- [~] Refresh rate / input lag at 1440p: the GOP mode is 2560x1440 at 60 Hz (2026-11-19, OTG0 totals 2720x1481);
      frames go through the CPU copy into flip B (see the item above). DP link rate/lanes: not logged yet
- [ ] `recovery_install.sh` and `esp_stage.sh`: include the air-runtime reader (from NullMoth's package, md5-pinned)
- [ ] `recovery_install.sh`: its Data-volume search found 3 candidates in Recovery (the system volume shows the
      Data volume's folders through firmlinks); pick the APFS Data role (`diskutil apfs list`) or the volume whose
      users directory is on its own device; test on macbox
- [ ] First boot without desktop arm: bring-up log, `metaltest`, temperatures and power
- [ ] Squat boot: accelerated desktop at 1440p60
- [ ] Soak: 20 cold boots in a row reach `SUCCESS`; a day of normal use with no GPU hang (log every failure in
      findings)
- [ ] Decide GPU present vs CPU copy at 1440p after measuring (see Phase 3 scan slots)

## Phase 3: 1440p high refresh (120/144/165/240 Hz)

- [ ] Linux capture tooling (root, read-only), kept in `tools/capture/` without machine data in git:
  - [ ] DCN register dump script (register list in [docs/XTX.md](../docs/XTX.md)), output `.inc`-ready
  - [ ] `amdgpu_dm_dtn_log` per mode, DPCD dump from `/dev/drm_dp_aux*`, ftrace of `amdgpu_device_wreg` during mode
        changes
  - [ ] Install `umr` (optional)
- [ ] Captures at 1440p 60/120/144/165/240 on this card and monitor
- [ ] A plan generator (upstream's is not public): capture to `phx_p0_plan_*.inc`, with self-tests
- [x] 2026-11-19 Scan slots for 1440p and up (b126, `PhxScanLayout.h`: 32 MiB slots at 256 MiB, unverified on hardware)
- [ ] EDID: E-DDC segment pointer, serve all 384 bytes (`PhxDdc.h`, `PhxEdid.h`)
- [ ] Mode matching by EDID timings instead of the two fixed 1080p entries (`PhxPipe0.h`, `PhxPipe2.h`, the scripts)
- [ ] DP link retraining on the GOP connector (DP B / DIG1) to HBR2, later HBR3 (`PhxDpLink.h`)
- [ ] 240 Hz: HBR3 x4 or DSC (research: does DCN 3.2 DSC need DMUB support we don't have?)
- [ ] Watermarks/DET/DAL tables for each mode (re-captured on the 384-bit XTX)
- [ ] Display power recipe (`b15`) for one 1440p monitor, with its underflow watchdog
- [ ] Mock tests for every new engine path

## Phase 4: Stability and the gaps upstream left

- [ ] Idle power and temperature at parity with Linux (measure both)
- [ ] Sleep/wake: research a resume path (replay the bring-up from the kext, DMUB/DCN re-init) or a safe "display
      sleep only" mode
- [ ] DP audio (HDMI/DP audio is not implemented anywhere in the stack)
- [ ] VCN video decode on the XTX (`phxboot-vcn`, `vcn_up.sh` checks `GB_ADDR_CONFIG`)
- [ ] App compatibility list: Safari/WebKit, Chromium/Electron, VS Code, Blender, games; file and fix crashes
- [ ] macOS update policy (pinned to 26.7.1; what breaks on an update, how to roll back)
- [ ] Hot-plug of the DP monitor (`phxboot-hotplug0`) and input switching. In Phase 5 the monitor switches inputs
      all the time

## Phase 5: Virtualization (dGPU passthrough)

Goal: Linux runs on the iGPU, can use the dGPU (PRIME offload), and a `macos` command hands the dGPU to a macOS VM.
When the VM shuts down, the dGPU goes back to Linux.

- [ ] BIOS: iGPU as the primary display; check the dGPU GOP still runs in the VM (OVMF with the card's ROM)
- [ ] Linux display on the iGPU only (Hyprland: `AQ_DRM_DEVICES`), dGPU used via PRIME render offload
- [ ] Reset strategy for Navi 31: test unbind amdgpu, bind vfio-pci, VM, rebind (BACO/mode1/FLR). Vermilion needs
      a cold GPU, so check whether amdgpu's unload leaves the PSP/SMU in a state the bring-up accepts. If not:
      reserve the card for vfio-pci at boot, or add a "warm" bring-up path
- [ ] VM definition: QEMU + OVMF + OpenCore (reuse macbox's QEMU/OpenCore work), dGPU + its audio function
      passed through, CPU pinning for the 7900X3D (cache CCD), hugepages, USB controller or device passthrough for
      keyboard and mouse
- [ ] The `macos` launcher script (start/stop, rebind on exit, safety checks that nothing on the host uses the dGPU)
- [ ] Same macOS install bare-metal and in the VM? (a decision: share the APFS partition or use separate disks)

## Phase 6: Clean up and hand over

- [ ] Replace the hardcoded connector table with the VBIOS parser (`PhxVbios.h` already produces the same table)
- [ ] Split the remaining machine-specific values into per-board / per-monitor data files with detection
- [ ] Refactor the largest files where it makes reviews easier (`nvmtl_vk.c`, `NVMTLObjects.m`, `nvrm-accel.cpp`),
      behaviour unchanged, in separate commits
- [ ] Upstream PRs to leolivm: XTX profile and detection, derived apertures, portable tests, docs
- [ ] A public install guide for the XTX machine class, issue templates, CONTRIBUTING.md

## Open questions

- Is the XFX VBIOS's DMCUB `0x07008742`? (first macOS boot)
- Which link rate does the GOP train for 1440p60? (first macOS boot)
- Does CoreDisplay accept the truncated 256-byte EDID?
- Does the AM5 new-firmware hang hit BIOS 4005?
- Is the I225-V stable on Tahoe without a boot-arg?
