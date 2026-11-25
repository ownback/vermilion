<!-- SPDX-License-Identifier: MIT -->

# Installing Vermilion

For people who want to run Vermilion on their own machine. Read the whole page before you start.

> [!CAUTION]
> **There is no finished installer yet.** Parts marked **(not available yet)** describe the first release this
> project is building, `0.1.0-preview` ([docs/RELEASE.md](docs/RELEASE.md)). What works today is the manual install, which only the
> [reference machine](docs/REFERENCE-MACHINES.md) has run, last done from scratch on 2026-11-19. Use it only if you can
> recover a Mac that doesn't boot to a picture.

## 1. Before you start

### What you need

| | |
|---|---|
| GPU | AMD Radeon RX 7900 XTX (PCI `1002:744c`, revision `0xC8`) as the **only** display GPU, monitor on DisplayPort. No other card: not the RX 7900 XT, GRE or 7900M. See [SUPPORT.md](SUPPORT.md) for what has been tested |
| Monitor | the LG 27GS95QE gets every mode; any other monitor gets one mode only, the one the card's firmware picked at power-on |
| macOS | **Tahoe 26.7.1 (25G241)**, installed and booting with OpenCore. Never update macOS while Vermilion is installed |
| OpenCore | booting this macOS already, on the card's firmware display without acceleration. The reference machine runs OpenCore 1.0.8 |
| BIOS | Above 4G decoding on, CSM off, the RX 7900 XTX as the boot display |
| A way back | a copy of your working `EFI` folder, and a second way to boot (a USB stick with your old EFI, or another OS) |

### What Vermilion changes on your system

Today, unlike a driver Apple ships, it:

- adds 4 kexts to OpenCore (VermilionBoot, VermilionTrust, VermilionAudio, plus Lilu if you don't have it) and one
  to `/Library/Extensions` (VermilionAccel), which needs an **Allow** click (a known step that stays: section 2.3);
- relaxes System Integrity Protection (`csr-active-config` `0x0A03`) and turns off OpenCore's Secure Boot model;
- installs a Metal driver and its libraries under `/Library/GPUBundles`;
- installs a **root LaunchDaemon** that runs scripts from `~/gpu` at every boot, loads AMD's firmware into the GPU,
  restarts the login window once and turns on automatic login for one boot;
- keeps the NVRAM variable `phxfb-squat` set, and needs you to **never reset NVRAM**;
- turns off automatic macOS updates;
- needs system sleep kept off (`pmset`, [docs/INSTALL.md](docs/INSTALL.md) section 10) and FileVault off.

Each of these except the Allow click goes away as the driver work lands ([ROADMAP.md](ROADMAP.md)); the release
target is "copy the kexts, merge one config snippet, run one package".

### Rules that protect your GPU and your install

- **From Linux or Windows to macOS, always shut down fully and power on again. Never restart into macOS.** The
  bring-up expects a cold GPU. It refuses a warm one and you get the basic display.
  Turning off Windows' Fast Startup is recommended *(unverified whether it matters)*.
- **Never Reset NVRAM** (OpenCore's picker entry, or holding keys at boot). It deletes `phxfb-squat`.
- **Never update macOS.** The Metal driver depends on exactly 26.7.1.
- **One change per boot,** with the previous file kept, so you always know what broke.
- **Wait until the boot has finished** (about 2.5 minutes, until the log says `done`) before you restart.

## 2. Install

### 2.1 The release route (not available yet)

The first release is `0.1.0-preview`, for the RX 7900 XTX only.

1. Download the release's `Vermilion-<version>-OpenCore.zip` and `Vermilion-<version>.pkg` from GitHub Releases and
   check them against `SHA256SUMS`.
2. Copy the kexts from the zip into `EFI/OC/Kexts` and merge the zip's `config-snippet.plist` (section 3) into your
   `config.plist`. Run `ocvalidate`.
3. Open the package. It is not signed with an Apple Developer ID, so Gatekeeper blocks it the first time: open
   System Settings > Privacy & Security, scroll to Security, and click **Open Anyway** next to the package's name
   (*unverified* on 26.7.1 with this package: it isn't built yet). Do this only after the `SHA256SUMS` check of
   step 1: the checksum is what tells you the package is the project's.
4. The package checks your macOS build and GPU and installs the Metal driver and VermilionAccel. No AMD firmware is
   in it: its post-install script runs in macOS and downloads the firmware from linux-firmware (you need a network
   connection, or point it at a linux-firmware copy), and checks every file.
5. Approve VermilionAccel (the Allow click, section 2.3), then restart.

On the reference machine's exact parts, the [ryzentosh](https://github.com/ownback) EFI will contain all of step 2
*(not available yet)*.

### 2.2 The manual route (works today, expert)

1. Build everything on a Mac with the Command Line Tools: [docs/BUILD.md](docs/BUILD.md). The firmware comes from
   `tools/firmware/fetch_firmware.sh`, which downloads it from linux-firmware and checks every file.
2. Build the AIR reader (`libLLVM.dylib` + `libzstd.1.dylib`): `sh scripts/build/llvm.sh` (LLVM 21.1.8 from source,
   30 to 90 minutes, `build/air-runtime/`). After step 4 has installed the Metal driver, run
   `sudo sh tools/phxctl/air_runtime_install.sh` to put it into the bundle ([docs/INSTALL.md](docs/INSTALL.md) 5.2;
   wiring it into `esp_stage.sh` is TODO). NullMoth's copy is only a fallback.
3. Lay out the install payload: `sh tools/phxctl/esp_stage.sh <EFI partition>/vermilion`.
4. From Recovery's Terminal (or with `sudo` on the running system), run `sh <EFI partition>/vermilion/install.sh`. It
   installs the Metal driver, VermilionAccel, the tools, the daemon and the firmware, keeps a copy of every replaced
   file in `~/vermilion-rollback/<time>/`, and never touches the system volume, NVRAM or the EFI partition.
5. Add the OpenCore entries of section 3 and copy the kexts into `EFI/OC/Kexts`. One EFI change per boot.
6. Approve VermilionAccel, restart, then follow [docs/INSTALL.md](docs/INSTALL.md) section 8: the first boot gives
   apps Metal on the basic display; the next turns on the accelerated desktop (`touch ~/gpu/phxboot-auto` and
   `sudo nvram phxfb-squat=1`).

Every file, permission and flag is described in [docs/INSTALL.md](docs/INSTALL.md), the expert reference.

### 2.3 The Allow click (a known step)

`VermilionAccel.kext` sits in `/Library/Extensions`, and macOS loads a kext from there only after you approve it. After
the install, and again after every update that changes this kext:

1. Open System Settings > Privacy & Security and scroll to Security.
2. Next to the message about blocked system software, click **Allow** and enter your password.
3. Restart when macOS asks.

Until you do, the kext doesn't load and you get the basic display. This step stays: it is one of the project's
[known limits](README.md#known-limits).

## 3. The OpenCore snippet

What Vermilion needs in `config.plist`. The reference machine's full configuration is generated by
[`efi/build.py`](efi/README.md) (stage `vermilion-trust-bar1g-audio`); take only these entries into yours.

| Section | Entry | Why |
|---|---|---|
| `Kernel > Add`, in this order | `Lilu.kext` (if not there), `VermilionBoot.kext`, `VermilionTrust.kext` (after Lilu), `VermilionAudio.kext` (after Lilu); `MinKernel` `25.0.0` | the driver, library validation for its code only, DP audio |
| `Kernel > Patch` | `com.apple.driver.AppleGraphicsDevicePolicy`: find `626f6172642d6964` ("board-id"), replace `626f6172642d6978` ("board-ix"), `MinKernel` `25.0.0`, `Count` 0 | the same as `agdpmod=pikera`: Navi cards hang without it, and WhateverGreen doesn't work on macOS 26 |
| `NVRAM > Add > 7C436110-AB2A-4BBB-A880-FE41995C9F82` | `csr-active-config` = `030A0000` (data); `boot-args` += `phxdebug=1 ipc_control_port_options=0` | SIP bits for the AuxKC kext and the optional decoder; the bring-up's debug interface (goes away with the kernel bring-up) |
| `NVRAM > Delete > 7C436110-...` | `csr-active-config`, `boot-args` | so the values above take effect |
| `Misc > Security > SecureBootModel` | `Disabled` | the injected kexts are unsigned |
| `UEFI > Drivers` | no `ResetNvramEntry.efi` | hides Reset NVRAM from the picker |
| `Booter > Quirks > ResizeAppleGpuBars` | `10` on the reference machine (BAR0 1 GiB); `0` (256 MiB) also ran | the driver places more in CPU-visible VRAM with 1 GiB |
| `Kernel > Add` | AMFIPass (after Lilu): the reference machine still loads it | whether anything needs it with VermilionTrust is open *(unverified)* |

Not part of Vermilion but needed on AMD desktop boards, as for any macOS install: your board's ACPI fixes, the
AMD_Vanilla kernel patches, SMBIOS (make your own; never reuse someone else's serial, MLB, ROM or UUID).

## 4. First boot: what you'll see

- OpenCore's picker and verbose text instead of the Apple logo (the reference machine's debug configuration).
- The login window on the basic display, then a dark screen for a few seconds and the login window again: the
  daemon has powered the GPU up and moved the desktop onto it. **Don't log in until the login window has come back.**
- About 2.5 minutes after boot, DisplayPort audio appears.
- The boot log: `tail /var/log/phxboot.log`. A good boot ends with `SUCCESS at <time>` and `done`.
- For a bug report: `bash tools/validation/bootcheck.sh` prints the per-boot report.

## 5. Update

- **macOS: never** (see the known limits in the [README](README.md#known-limits)).
- **Vermilion:** the kexts in OpenCore and the Metal driver must come from the same version: VermilionTrust holds the
  exact fingerprints (cdhashes) of the Metal driver, the translator and RADV it lets load. Update both, then restart
  once. Keep the previous `EFI/OC` folder (for example as `EFI/OC.prev`) until the new version has run for a few boots.
- The release package will check the versions and refuse a mismatch *(not available yet)*.

## 6. Uninstall

The release package will install `vermilion-uninstall` *(not available yet)*. Today, in this order
([docs/INSTALL.md](docs/INSTALL.md) section 9 has every command):

1. Stop the boot daemon: remove `/Library/LaunchDaemons/local.phxboot.plist`, `/var/db/phxboot.pending` and the NVRAM
   variables `phxfb-squat` and `phxfb-boot` (`sudo nvram -d ...`; on boards where macOS can't write NVRAM, from the
   OS that set them).
2. Put the login-window value back (docs/INSTALL.md 9, step 2).
3. Remove `/Library/Extensions/VermilionAccel.kext` and rebuild the Auxiliary Kernel Collection without it
   (`sudo kmutil install --update-all`, then `sudo kmutil clear-staging`; *unverified* on 26.7.1). Meanwhile the
   boot-arg `-phxacceloff` keeps it from starting.
4. Remove the Metal driver (`/Library/GPUBundles/NVMTLDriver.bundle`, `/Library/GPUBundles/nvmtl`,
   `/Library/GPUBundles/nvmtl-allow.txt`, and the relocated copy under
   `/System/Library/CoreServices/CoreTypes.bundle/Contents/Library/PhxGPU` if you used the relocation).
5. If you installed the video decoder on the system volume:
   `sudo sh tools/phxctl/sysvol_install.sh --remove /System/Library/Video/Plug-Ins/PhxVideoDecoder.bundle`, then
   restart.
6. Remove the display overrides `dispovr.sh` wrote (docs/INSTALL.md 9, step 3).
7. Remove the OpenCore entries of section 3 and the kexts from `EFI/OC/Kexts`. Restart.
8. Remove `/usr/local/sbin/phxctl`, `/usr/local/sbin/mesboot`, `~/gpu` and, once you're sure, `~/vermilion-rollback`.

## 7. When something goes wrong

| What you see | What to do |
|---|---|
| The basic display (name and password fields instead of avatars, no high refresh) | The daemon fell back on purpose. `tail -50 /var/log/phxboot.log` says why. It tries the full desktop again by itself after one clean boot |
| A dark screen that stays dark | Wait 3 minutes (the watchdog). Then hold the power button, power on again, and wait for the basic display. If it repeats: boot with `-phxbringupoff` (below) |
| No boot at all, or a kernel panic | Boot your EFI copy (USB stick, or rename `EFI/OC.prev` to `EFI/OC` from another OS), or add `-phxbringupoff` to `boot-args` for one boot. That stops VermilionBoot; the firmware display stays |
| Turn the GPU path off without uninstalling | `touch ~/gpu/phxboot-off` (from Terminal, over SSH, or in Recovery under `/Volumes/<Data>/Users/<you>/gpu/`), restart |
| Recovery or Safe Mode shows no picture | Expected today *(unverified)*: VermilionBoot also loads there. Boot an EFI copy without VermilionBoot to reach Recovery |
| After a freeze, every boot is the basic display | It returns to the full desktop after clean boots on its own; [docs/INSTALL.md](docs/INSTALL.md) 8.5 |

Never Reset NVRAM to fix a boot problem.

## 8. Reporting a problem

Open an issue on [ownback/vermilion-xtx](https://github.com/ownback/vermilion-xtx/issues) with your card (board
partner, `system_profiler SPDisplaysDataType` without serials), monitor model, the last boot's section of
`/var/log/phxboot.log`, and the `bootcheck.sh` output. **Remove personal data first:** serial numbers, MLB, ROM, UUIDs,
MAC addresses, your user name, and your monitor's serial (in EDID dumps). Never post your `config.plist` or EFI folder.
