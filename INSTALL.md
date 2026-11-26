<!-- SPDX-License-Identifier: MIT -->

# Installing Vermilion 0.1.0-preview

Vermilion is a macOS driver for the AMD Radeon RX 7900 XTX. This page is for people who want to run the
`0.1.0-preview` release on their own PC. Read all of it before you start.

> [!CAUTION]
> **This is an experimental preview.** The release package and the OpenCore zip are built by scripts and CI
> ([docs/RELEASE.md](docs/RELEASE.md)). No release is published yet. Nobody has run the package on a real Mac, and
> nobody has followed this page on a clean machine *(unverified)*. The manual install has run on the
> [reference machine](docs/REFERENCE-MACHINES.md) only, last from scratch on 2026-11-19.
> Use it only if you can recover a Mac that does not boot to a picture.

Marks used here: **(unverified)** means not tested on hardware. A claim about hardware names the machine it was seen
on: the "reference machine" is one PC with an XFX RX 7900 XTX and an LG 27GS95QE monitor.

## 1. Requirements

| | |
|---|---|
| GPU | AMD Radeon RX 7900 XTX: PCI `1002:744c`, revision `0xC8`. It must be the **only** display GPU, with the monitor on DisplayPort. The RX 7900 XT, GRE and 7900M share the PCI ID and are refused, as is any other card. |
| macOS | **Tahoe 26.7.1, build 25G241**, no other. The Metal driver uses private interfaces of exactly this build. Never update macOS while Vermilion is installed. |
| OpenCore | A working OpenCore install that already boots this macOS (on the card's firmware display, without acceleration). The reference machine runs OpenCore 1.0.8. |
| Lilu | 1.7.2 or later, in your OpenCore. VermilionTrust and VermilionAudio load after it. Lilu is not part of this release. |
| SIP | `csr-active-config` = `030A0000` (data), which is `0x0A03`. The snippet sets it. |
| Secure Boot | `Misc > Security > SecureBootModel` = `Disabled`. The snippet sets it. The injected kexts are unsigned. |
| BIOS | Above 4G decoding on, CSM off, the RX 7900 XTX as the boot display. Resizable BAR on if your board has it. |
| Monitor | The LG 27GS95QE gets every mode. Any other monitor gets one mode only, the one the card's firmware picked at power-on *(other monitors: unverified)*. |
| A way back | A copy of your working `EFI` folder, and a second way to boot (section 2). |
| Your own SMBIOS and ACPI | Vermilion ships none. Make your own. Never reuse someone else's serial, MLB, ROM or UUID. |
| A network | Only during the package install, to download AMD's firmware. |

Set these two things yourself. The package changes neither:

- **Software Update must not install macOS by itself.** System Settings > General > Software Update > (i) next to
  Automatic Updates: turn off "Install macOS updates".
- **The Mac must not sleep.** System sleep does not work (section 5). Run
  `sudo pmset -a sleep 0 hibernatemode 0 disksleep 0` (the settings used on the reference machine). The reference
  machine's `pmset` does not offer `womp`, `powernap` or `tcpkeepalive`: set only what `pmset -g` lists on yours.
  Keep FileVault off *(FileVault is untested)*.

### What the OpenCore snippet changes

`config-snippet.plist` in the OpenCore zip holds these entries. Nothing else of your `config.plist` changes.

| Section | Entry | Why |
|---|---|---|
| `Kernel > Add`, in this order | `Lilu.kext` (skip it if you have it), `VermilionBoot.kext`, `VermilionTrust.kext`, `VermilionAudio.kext`; `MinKernel` `25.0.0` | the driver, library validation for Vermilion's own code only, DisplayPort audio |
| `Kernel > Patch` | `com.apple.driver.AppleGraphicsDevicePolicy`: find `board-id`, replace `board-ix` | the same as `agdpmod=pikera`: Navi cards hang without it |
| `NVRAM > Add > 7C436110-AB2A-4BBB-A880-FE41995C9F82` | `csr-active-config` = `030A0000`; `boot-args` gets `phxdebug=1 ipc_control_port_options=0` **added to your own boot-args** | SIP bits for the kext; the bring-up's debug interface |
| `NVRAM > Delete` (same GUID) | `csr-active-config`, `boot-args` | so the values above take effect |
| `Misc > Security > SecureBootModel` | `Disabled` | the kexts are unsigned |
| `Booter > Quirks > ResizeAppleGpuBars` | `10` (BAR0 of 1 GiB, the reference machine); `0` also ran | the driver places more in CPU-visible VRAM with 1 GiB |

Not in the snippet, by hand: keep `ResetNvramEntry.efi` out of `UEFI > Drivers` (section 6). The reference machine
also loads AMFIPass after Lilu; whether anything needs it with VermilionTrust is open *(unverified)*.

### What Vermilion changes on your system

Unlike a driver Apple ships, it:

- adds three kexts to OpenCore (VermilionBoot, VermilionTrust, VermilionAudio) and one to `/Library/Extensions`
  (VermilionAccel), which needs an **Allow** click (section 3.4);
- relaxes System Integrity Protection (`0x0A03`) and turns off OpenCore's Secure Boot model;
- installs a Metal driver and its libraries under `/Library/GPUBundles`;
- installs a **root LaunchDaemon** (`local.phxboot`) that runs scripts from your `~/gpu` at every boot, loads AMD's
  firmware into the GPU and restarts the login window once. Because you can write those scripts and root runs them,
  any program running as you can run code as root at boot;
- keeps the NVRAM variable `phxfb-squat` set, so you must **never reset NVRAM**.

## 2. Before you start

1. **Copy your working EFI.** Mount the EFI partition and copy the whole `EFI` folder to a USB stick, and to a second
   place outside the disk. (`diskutil list` shows the partition; `sudo diskutil mount <diskNs1>` mounts it.)
2. **Keep a second way to boot.** Make the stick bootable on its own: it holds your old `EFI` folder with
   `EFI/BOOT/BOOTX64.EFI` (OpenCore's). Another OS on another disk also counts.
3. **Know how to boot the backup.** OpenCore's picker lists macOS volumes, not other EFI folders, so you cannot pick
   a backup EFI from the picker. Open your board's firmware boot menu at power-on (often F8, F11 or F12: look it up
   for your board) and pick the stick, or the disk's own `OC.prev` entry if you set one up. Try this once now, while
   everything still works.
4. **Keep your previous `EFI/OC` as `EFI/OC.prev`** on the disk until the new one has booted a few times. To go back
   from another OS: rename `EFI/OC` to `EFI/OC.bad` and `EFI/OC.prev` to `EFI/OC`.
5. **Write down your current `boot-args`** (`nvram boot-args`).
6. **One EFI change per boot.** Make a single change to the EFI partition, restart, and check that it worked before the
   next one.

## 3. Install

The order: the OpenCore part first, one restart, then the package, the Allow click and a second restart. It is the
order of the package's welcome page ("needs the OpenCore part of the same release"), its closing text and the
OpenCore zip's notes (the zip and the package are a pair). *(Unverified: the order has not run on a clean machine.)*

### 3.1 Download and check

1. Download these files of one release from GitHub Releases: `Vermilion-0.1.0-preview-OpenCore.zip`,
   `Vermilion-0.1.0-preview.pkg` and `SHA256SUMS`.
2. In the download folder: `shasum -a 256 -c SHA256SUMS`. Every line must say `OK`. The package is not signed, so this
   check is how you know it is the project's. (`SHA256SUMS` itself has no signature yet.)
3. The zip and the package are a pair: VermilionTrust holds the exact fingerprints of the code the package installs.
   Never mix files of two releases.

### 3.2 The OpenCore part

1. Unzip the OpenCore zip. It holds `Kexts/` (VermilionBoot, VermilionTrust, VermilionAudio), `config-snippet.plist`,
   `README.txt`, `LICENSES/` and `NOTICE`.
2. Copy the three kexts into `EFI/OC/Kexts`. Take Lilu from its own release if you do not have it.
3. Merge `config-snippet.plist` into **your** `config.plist` by hand or with your own tooling (section 1 lists the
   entries). **Add** the two boot-args to the ones you have. Do not replace them.
4. Run `ocvalidate` on the result. Fix what it reports.
5. Restart. Confirm the machine still boots to the desktop on the basic display, and that the boot kext loaded:

   ```sh
   ioreg -l | grep phx-build
   ```

   This is the one EFI change of this boot. If the Mac does not boot, go to section 6.

### 3.3 Open the package (Gatekeeper)

The package is not signed with an Apple Developer ID and is not notarised, so macOS blocks it the first time. Do
this only after the `SHA256SUMS` check. Both ways are *(unverified)* on macOS 26.7.1: no package has been opened there.

- **In the Finder:** double-click the package. macOS refuses. Open System Settings > Privacy & Security, scroll to
  Security, click **Open Anyway** next to the package's name, and enter your password.
- **Or in Terminal:** `sudo installer -pkg Vermilion-0.1.0-preview.pkg -target /`. It should not show Gatekeeper's
  dialog.

What the package does:

1. The Installer first says the package runs a program to check whether it can be installed. It checks the macOS
   build (25G241) and the GPU (an RX 7900 XTX, revision `0xC8`, and no other `1002:744c` card). If a check fails it
   says why and changes nothing. The package checks again as root before it writes anything. If the installer window
   only says "the install failed", the reason is in `/var/log/install.log`.
2. It copies every file it is about to replace to `/Library/Application Support/Vermilion/rollback/<time>/`.
3. It installs the Metal driver (`/Library/GPUBundles`), VermilionAccel (`/Library/Extensions`), and `phxctl`,
   `mesboot`, `spirv-val`, `vermilion-uninstall` and `vermilion-firmware` (`/usr/local`).
4. It installs the boot daemon and its scripts into your `~/gpu`, and writes the LaunchDaemon `local.phxboot`. It
   creates no flag files: every proven feature is on by default (the table in section 6 turns one off). It does not
   start the daemon: it runs at the next boot.
5. **It downloads AMD's firmware.** No firmware is inside the package. The post-install script fetches the 20 files
   from linux-firmware (a GitLab mirror, then git.kernel.org) at one pinned commit into `~/gpu/fw/navi31`, and checks
   each file's MD5 and SHA-256 against the list in the package. A file that does not match is refused.
6. It installs the AIR reader (LLVM) into the Metal driver bundle.
7. It writes no flag files. The daemon arms the accelerated desktop by itself after a finished first boot, and HDR
   stays off (it is broken in this preview; `touch ~/gpu/phxboot-hdr` tries it). Automatic login and the second
   monitor stay off: they need their own file.

It never writes the system volume, NVRAM or the EFI partition, and it does not start the daemon.

**If the download fails** (no network, or a mismatch), the install still finishes with a warning, and the GPU stays on
the basic display. Run `sudo vermilion-firmware` with a network connection. Offline, use
`sudo vermilion-firmware --from <a linux-firmware checkout>`; the same checks apply.

### 3.4 The Allow click

`VermilionAccel.kext` sits in `/Library/Extensions`. macOS loads a kext from there only after you approve it. Do this
after the install, and again after every update that changes this kext:

1. Open System Settings > Privacy & Security and scroll to Security.
2. Next to the message about blocked system software, click **Allow** and enter your password.
3. Restart when macOS asks.

Until you do, the kext does not load and you stay on the basic display. This step stays in the project: it is one of
the [known limits](README.md#known-limits).

### 3.5 First boot after the install

*(Unverified: no stranger has done these two boots.)* There are two boots. The package does not arm the accelerated
desktop itself: the daemon does that at the end of a boot that went well, so the second boot only happens if the
first one had the firmware and VermilionAccel loaded.

**Boot 1 (after the Allow click): the basic display, with Metal for apps.**

1. **After the restart, do not log in for about 3 minutes.** The daemon brings the GPU up in that time.
2. Read the log: `tail -60 /var/log/phxboot.log`. Each boot starts with a line `== <date> <time> phxboot(navi31, ...)`.
   Read the last boot's section. A good first boot shows `navi31 up: compute + gfx queues ready`, `NMXAccel up`,
   `no desktop arm: GOP + Metal for apps`, then `phxfb-squat re-armed for the next boot (GOP boot, automatic desktop
   on; read-back ok)` and `done`.
3. **A notification says "Graphics acceleration is ready. Restart to turn on the accelerated desktop."** It appears
   after you log in. If it says "Graphics acceleration needs your approval", the Allow click (section 3.4) is still
   missing: do it and restart. In that case the daemon touched nothing on the GPU.
4. **Wait for `done`, then restart** (not a shutdown from another OS: a normal restart or shutdown and power-on).

**Boot 2: the accelerated desktop.**

1. The screen stays dark until the daemon arms the display, then the login window restarts once. **Do not log in
   until it has come back.** The daemon does not arm the display while a user is logged in.
2. After the login the log shows, in this order, `navi31 up: ...`, `NMXAccel up`, `Metal device ready`, `AGDC up`,
   `restarting WindowServer once`, and about 2 minutes later `SUCCESS at <time>` and `done`. About 2.5 minutes after
   boot, DisplayPort audio appears.
3. **Wait for `done` before you restart or shut down.** A boot that ends before `done` counts as a failed attempt
   (section 6).
4. **If boot 2 is still the basic display,** look in `/var/log/phxboot.log` for the `phxfb-squat re-armed` line of boot
   1. If it is missing, the daemon did not arm (no firmware, no Allow click, a failure: the log says which). If it says
   `read-back FAILED`, OpenCore does not let macOS write NVRAM: set the variable by hand (section 6, "Set `phxfb-squat`
   by hand"). A failed firmware download (section 3.3) also keeps boot 1 from arming: run `sudo vermilion-firmware`,
   then restart.

## 4. Check that it works

Everything here is read-only. Run it after the log says `done`.

| Check | Command | Good answer |
|---|---|---|
| macOS build | `sw_vers -buildVersion` | `25G241` |
| Boot kext loaded | `ioreg -l \| grep phx-build` | one line with the kext's build number |
| The boot log | `tail -60 /var/log/phxboot.log` | the last boot ends with `SUCCESS at <time>` and `done`; on boot 1 (no desktop arm yet), with `no desktop arm: GOP + Metal for apps` and `done` |
| VermilionTrust | `sysctl debug.phxtrust_stat` | `mode=enforce`, a `list=` count equal to the code the package installs, and `denied_unlisted=0` |
| Kernel side | `sysctl debug.phxvm` | prints the GPU virtual-memory counters |
| Metal | `~/gpu/metaltest` | `Metal devices: 1` |
| VermilionAccel loaded | `kmutil showloaded \| grep org.vermilion.accel` | one line (nothing means the Allow click or restart is missing) |
| Audio patch | `sysctl debug.phxaudio_stat` | reports the patch as applied |
| Frames drawn by the GPU | `sysctl debug.nvaccel_iop_ok` twice, a few seconds apart, while the screen changes | the number grows |
| All Vermilion values | `sysctl debug \| grep phx` | lists every one |

What you see on screen:

- **System Settings > Displays** offers 2560x1440 at 60, 120, 144 and 240 Hz and "Variable (60-240 Hz)" on the LG
  monitor (seen on the reference machine). HDR is off in this preview (section 5).
- **System Information > Graphics/Displays** shows the card as an AMD Radeon RX 7900 XTX. The name still carries extra
  text (`(RADV NAVI31) (NVMTL over ...)`), and the memory size it reports can be below the card's 24 GB (a known
  6 GiB cap in the Metal and OpenCL answers). These are cosmetic and known.
- **Apps:** Safari, Maps, Music and Core Image use the GPU. Games run slowly (section 5).

The basic display, a login window with name and password fields instead of avatars, and no high refresh rate mean
Vermilion fell back on purpose. `/var/log/phxboot.log` says why.

If someone asks you for a boot report, a repository checkout has `tools/validation/bootcheck.sh` (it is not in the
package).

## 5. Known limits of this preview

Everything not listed here is meant to work as on a Mac; until it does, it is a bug. From [STATUS](.agents/STATUS.md),
seen on the reference machine.

**Display**

- **HDR is off.** The plugin shows stale frames when WindowServer composites in HDR. It is switched off by a flag.
- **No recovery after a monitor power-cycle, a replug or an input switch.** The screen stays black until you restart.
  Audio comes back only after a restart too.
- **No display sleep.** The screen goes black but the monitor never goes to standby.
- **One monitor, on DisplayPort.** No second monitor, no HDMI, no HiDPI modes, no other monitor's own modes.
- Other sizes than 2560x1440 run at fixed rates, with a CPU copy and no Variable refresh rate.
- No DDC/CI: brightness and volume of the monitor do not work from MonitorControl or BetterDisplay yet.
- Night Shift and colour calibration do not work *(the effect is unverified by eye)*.

**System**

- **No system sleep.** The Mac must stay awake (section 1). Do not use Apple menu > Sleep, and do not press the power
  button briefly.
- **The boot is not a Mac boot.** The picker and verbose text show instead of the Apple logo, a user-space daemon
  brings the GPU up, the desktop restarts once, DisplayPort audio appears about 2.5 minutes after boot, and OpenGL
  is on about 2 minutes after login.
- **Linux or Windows to macOS needs a full power-off** (section 6).
- **After a freeze,** the next boots are the safe desktop (section 6).
- A GPU hang is not recovered: one stuck shader can end the session. MPS and Core ML can hang the GPU.
- **A macOS update breaks it.** Never update macOS.
- **The Allow click** at every update of VermilionAccel.
- **VermilionTrust** patches fixed offsets of macOS's code-signing check. It is built for exactly 25G241.

**Graphics and video**

- Games are slow (Horizon: 292 frames per second against 4370 on Linux on the same card).
- **WebGPU in Safari is partial:** 20 of 43 samples work, and render bundles crash the GPU process.
- WebGL works, but Safari cannot store its shader cache.
- OpenCL is capped at 6 GiB. Blender Cycles renders on the CPU, as on a real Intel Mac with an AMD GPU.
- HEVC and AV1 decode work through a bundle on the system volume. This preview's package does not install it, so
  hardware video decode is **not included** *(see docs/RELEASE.md, "The package")*. 4K YouTube stutters.
- **No hardware encode** (FaceTime, exports, AirPlay sending). No H.264 or VP9 hardware decode.
- The first login after a translator change is slow: about 1.5 minutes of heavy WindowServer CPU once.
- **Music takes about 30 seconds on its first launch after each boot** (passd waits for a service that only
  Macs with a T2 chip have). Section 8 has the optional fix, which is not released yet.
- Maps runs but is choppy fullscreen, and map tiles appear late.

**Platform limits** (a PC cannot do these, as on any Hackintosh)

- No Apple TV films or Safari FairPlay video (Apple Music works).
- No Hypervisor.framework on AMD CPUs: no Docker Desktop, accelerated UTM, Parallels or VMware.
- Touch ID, Apple Pay, iPhone Mirroring and Apple Intelligence need Apple silicon or a T2.

Recovery and Safe Mode may show no picture *(unverified)*: VermilionBoot also loads there. To reach Recovery, boot an
EFI copy without VermilionBoot.

## 6. Troubleshooting and recovery

Never Reset NVRAM to fix a boot problem. Never restart into macOS from Linux or Windows.

| What you see | What to do |
|---|---|
| The basic display: name and password fields instead of avatars, no high refresh | The daemon fell back on purpose. `tail -50 /var/log/phxboot.log` says why. It tries the full desktop again by itself (below). |
| A dark screen that stays dark | Wait 3 minutes (the bring-up watchdog restarts the machine). If it stays dark, hold the power button, power on, and wait for the basic display. If it repeats, boot with `-phxbringupoff` (below). |
| No boot at all, or a kernel panic | Boot your backup EFI (section 2), or add `-phxbringupoff` to `boot-args` for one boot. That stops VermilionBoot; the firmware display stays. |
| Turn the GPU path off without uninstalling | `touch ~/gpu/phxboot-off` (in Terminal, over SSH, or in Recovery under `/Volumes/<Data volume>/Users/<you>/gpu/`), then restart. `rm ~/gpu/phxboot-off` turns it on again. |
| Recovery or Safe Mode shows no picture | Expected *(unverified)*. Boot an EFI copy without VermilionBoot. |

### Turn one feature off

Every feature below is on by default. To turn one off, create an empty file with the name in the second column in
`~/gpu` (`touch ~/gpu/phxboot-cg-off`) and restart; `rm` the file to turn it on again. Leave the other features alone
unless the log points at one (`/var/log/phxboot.log`, one line per feature). An old `~/gpu/phxboot-<name>` file from an
earlier install does nothing now; the log says so in one `note:` line.

| Feature | Create this file to turn it off |
|---|---|
| Automatic arming of the accelerated desktop after a finished boot | `phxboot-auto-off` |
| SDMA idle (idle power) | `phxboot-sdma-off` |
| GFX clock gating (idle power and heat) | `phxboot-cg-off` |
| Memory clock pin | `phxboot-uclk-off` |
| Idle memory and fabric clocks | `phxboot-idledpm-off` (and `phxboot-idledpm-dcf-off` for the DCFCLK part only) |
| 1440p modes in System Settings | `phxboot-p0modes-off` |
| Fence waits by interrupt | `phxboot-irqwait-off` |
| Fence wait step | `phxboot-waitstep-off` (or a value 20-1000 in `phxboot-waitstep`) |
| CoreDisplay's surfaces for GPU present | `phxboot-wscdcopy-off` |
| Video decode engine (VCN) | `phxboot-vcn-off` |
| VRAM buffers for named apps | `phxboot-bovram-off` (or a comma-separated list in `phxboot-bovram`) |
| OpenGL over Metal | `phxboot-gl-off` |
| DisplayPort audio | `phxboot-audio-off` |
| Adaptive Sync ("Variable") | `phxboot-novrr` |
| GPU present, async present, direct scan-out | `/Library/GPUBundles/nvmtl/ws-gpu-present-off`, `ws-gpu-present-async-off`, `ws-direct-off` |

HDR is off by default (broken in this preview); `touch ~/gpu/phxboot-hdr` turns it on to try it. Automatic login
(`phxboot-autologin`, holding the user name), the second monitor (`phxboot-m7*`) and `touch ~/gpu/phxboot-off` (the
kill switch, above) are opt-in and stay off until you create their file. Details: [docs/INSTALL.md](docs/INSTALL.md), 7.3.

### Black screen after a failed boot

1. Power off fully (hold the power button), then power on.
2. If you changed the EFI, undo that one change. From another OS, rename `EFI/OC` to `EFI/OC.bad` and `EFI/OC.prev`
   to `EFI/OC`. Or boot your backup EFI from the firmware boot menu (section 2).
3. Or boot once with `-phxbringupoff` or `-phxacceloff` added to `boot-args`: the first stops VermilionBoot, the
   second keeps VermilionAccel from starting. Put the argument in `boot-args` in your `config.plist` (on the backup
   copy of the EFI if the Mac does not boot) and remove it again afterwards.
4. After the Mac boots, read `/var/log/phxboot.log`, fix the cause, and change the EFI once.

### The safe desktop and the squat loop

On the reference machine, every OpenCore boot is a **squat boot**: the NVRAM variable `phxfb-squat` makes VermilionBoot
hold the framebuffer slot, so the card's firmware display does not take it, and Vermilion's own framebuffer is the
only display. If the bring-up fails on such a boot, there is no firmware display to fall back on. The daemon then
brings up a **safe desktop** (the basic display on the CPU) instead of restarting in a loop.

- **A failed attempt** is any boot that ends between the start of the bring-up and `SUCCESS`: a hang, a power cut, a
  forced power-off. The next boot finds `/var/db/phxboot.pending`, logs `previous attempt did not finish -> GOP` and
  counts it in `/var/db/phxboot.fails`.
- **The way back is automatic.** After one clean boot on the safe desktop, the daemon tries the full desktop again.
  After three failures in a row it waits for three clean boots. The log's `record: fails=... clean=... last=...`
  line says where the count stands. You only need to restart once and wait for `done`. After login the daemon shows
  one notification *(unverified on hardware; mock-tested)*.
- **If it stays on the safe desktop:** fix what the log names, remove the kill switch if you set it
  (`rm -f ~/gpu/phxboot-off`), and restart once. `sudo nvram phxfb-squat=1` re-arms the next boot at once, where
  macOS can write NVRAM.
- **A stuck squat boot** (the daemon logs `stuck squat` or `nvstuck: still a squat boot`): the screen can stay dark
  until a power-off. ssh still reaches the machine. Power off, power on, and the next boot tries the safe desktop
  *(unverified on hardware)*.
- Do not restart before `done` on any boot: that can create the failed attempt.

### Never Reset NVRAM

Do not use OpenCore's "Reset NVRAM" picker entry, and do not hold keys at power-on to reset it. It deletes
`phxfb-squat`. OpenCore's `DisableVariableWrite` can stop macOS from setting it again (as on the reference machine), so
every later boot runs on the firmware display with a phantom display, and you cannot get the variable back from
macOS. Keep `ResetNvramEntry.efi` out of `UEFI > Drivers`. If it has already happened, set `phxfb-squat` from another
OS or from Recovery's Terminal with `nvram` where it can write *(unverified)*.

### Set `phxfb-squat` by hand

Needed if the log of boot 1 says `phxfb-squat re-armed ... read-back FAILED`, or boot 2 is still the basic display and
the log has no `re-armed` line for another reason you have fixed. From a Terminal in macOS, as an admin, try
`sudo nvram phxfb-squat=1`, then `nvram phxfb-squat` (it must print the value). If macOS cannot write NVRAM
(OpenCore's `DisableVariableWrite`, as on the reference machine), set it from Linux. VermilionBoot only checks that
the variable exists. This command writes the attributes (non-volatile, boot and run-time access) and the value `1`,
in Apple's NVRAM GUID:

```sh
printf '\007\000\000\000\061' | sudo tee /sys/firmware/efi/efivars/phxfb-squat-7c436110-ab2a-4bbb-a880-fe41995c9f82 >/dev/null
```

Then power off fully (not a restart) and boot macOS. The daemon re-arms the variable after each good boot (unless `~/gpu/phxboot-auto-off` exists).

**To delete `phxfb-squat` or `phxfb-boot` from Linux** (the uninstaller says so when macOS could not delete them): the
files are immutable. For each variable, in the same directory and GUID:

```sh
sudo chattr -i /sys/firmware/efi/efivars/phxfb-squat-7c436110-ab2a-4bbb-a880-fe41995c9f82
sudo rm /sys/firmware/efi/efivars/phxfb-squat-7c436110-ab2a-4bbb-a880-fe41995c9f82
```

and the same with `phxfb-boot-7c436110-ab2a-4bbb-a880-fe41995c9f82`. Linux's efivarfs refuses writes to some
variables, so check that the file is gone (`ls /sys/firmware/efi/efivars | grep phxfb`) *(unverified on hardware)*.

### Linux or Windows to macOS: power off fully

**Shut down, then power on. Never restart into macOS.** The bring-up assumes a cold GPU: it loads the SMU firmware once
per power cycle. It checks the GPU's state first, and if the GPU is warm it refuses (`warm GPU: bring-up refused` in
the log) and writes nothing to the card. On a squat boot the screen then stays dark until you power off and on again.
Turning off Windows' Fast Startup is recommended *(unverified whether it matters)*. A warm restart from macOS itself
is normal: the bring-up sees a cold state there (seen on the reference machine).

### Where the logs are

| Log | Where |
|---|---|
| The boot daemon | `/var/log/phxboot.log` (one section per boot) |
| Daemon state | `/var/db/phxboot.pending` (attempt in progress), `/var/db/phxboot.fails` (the failure record) |
| The package install | `/var/log/install.log` |
| Package rollback copies | `/Library/Application Support/Vermilion/rollback/<time>/` |
| GPU hang dumps | `/var/log/phxhang-<time>/` |
| Kernel side | `log show --last 5m --predicate 'eventMessage CONTAINS "Vermilion"'` (in zsh use `/usr/bin/log`) |
| Counters | `sysctl debug \| grep phx` |
| Crash reports | `/Library/Logs/DiagnosticReports` |

## 7. Update and uninstall

### Update

- **macOS: never.**
- **Vermilion:** the kexts of the OpenCore zip and the package must be from the same release. Update both, then
  restart once. The package does not yet check that the loaded VermilionTrust is the one of its own release
  *(not built)*, so do steps 1 to 4 before the restart. *(Unverified: the update has never run.)*

1. Keep your current `EFI/OC` as `EFI/OC.prev`.
2. Put the new zip's kexts into `EFI/OC/Kexts` and merge any new entries of its `config-snippet.plist`. This is the
   **one EFI change** of this boot.
3. Run the new package (section 3.3). It replaces files and keeps copies in the rollback folder.
4. Click Allow again if VermilionAccel changed (section 3.4).
5. Restart once.
6. Keep `EFI/OC.prev` until the new version has run for a few boots.

### Uninstall

Run this as root in Terminal. It never touches the EFI partition.

```sh
sudo vermilion-uninstall
```

It stops the daemon, deletes `/var/db/phxboot.pending` and `phxboot.fails`, deletes the NVRAM variables `phxfb-squat`
and `phxfb-boot` where macOS can, puts the login-window value and the display overrides back, removes the files the
package installed, restores the files it replaced from the rollback folders, and forgets the package. It keeps the
firmware, the rollback folders and the log. It prints what is left for you.

- `--purge` also removes the firmware (`~/gpu/fw/navi31`).
- `--rebuild-kc` also runs `kmutil install --update-all` and `kmutil clear-staging` to drop VermilionAccel from the
  Auxiliary Kernel Collection. Without it, the commands are only printed. *(Unverified on macOS 26.7.1.)* Afterwards
  `kmutil showloaded | grep org.vermilion.accel` must print nothing.
- Everything about the uninstaller is *(unverified)*: it passed its mock tests, and never ran on a real Mac.

Then remove the OpenCore part, **one EFI change per boot**:

1. Keep a copy of your EFI folder.
2. In `config.plist`, delete the `Kernel > Add` entries of VermilionBoot, VermilionTrust and VermilionAudio, and the
   `Kernel > Patch` entry for `AppleGraphicsDevicePolicy`. Take `phxdebug=1 ipc_control_port_options=0` out of
   `boot-args`. Put back your own `csr-active-config` and `SecureBootModel` if you changed them for Vermilion.
3. Delete the three kexts from `EFI/OC/Kexts`. Leave Lilu if you use it.
4. Restart. Check the Mac boots on the card's own firmware display.

If the Mac does not boot afterwards, boot your backup EFI. By hand, without the uninstaller, the order is in the
expert reference ([docs/INSTALL.md](docs/INSTALL.md) section 9).

## 8. Optional: ryzentosh-sse (release pending)

**Not released yet.** On a Mac without a T2 chip, Music's first launch after each boot waits about 30 seconds: passd
asks 60 times for a service (AppleSSE) that does not exist, and accountsd waits for it. `ryzentosh-sse` will be a
separate OpenCore kext from its own repository, `ownback/ryzentosh-sse`, that provides an honest "SSE not supported"
answer. It is not part of this release and has no download yet. When it is released:

1. Put its `.kext` into `EFI/OC/Kexts` and add its `Kernel > Add` entry (its release notes say where).
2. One EFI change per boot. Restart.
3. Open Music right after login. It should open at once *(unverified)*.

Until then a login agent (`local.phxpassd`) on the reference machine starts passd early. It is not in this package.

## 9. Reporting a problem

Open an issue on [ownback/vermilion-xtx](https://github.com/ownback/vermilion-xtx/issues) with your card (board
partner, `system_profiler SPDisplaysDataType` without serials), monitor model, the last boot's section of
`/var/log/phxboot.log`, and the output of `sysctl debug.phxtrust_stat`. **Remove personal data first:** serial numbers,
MLB, ROM, UUIDs, MAC addresses, your user name, and your monitor's serial (in EDID dumps). Never post your
`config.plist` or EFI folder. Support matrix: [SUPPORT.md](SUPPORT.md).

The expert reference, with every file, flag and script of the manual install, is [docs/INSTALL.md](docs/INSTALL.md).
