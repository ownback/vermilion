# Runbooks

Step-by-step procedures for the XTX machine. Anything not done yet is marked *(unverified)*. Replace that marker
with the date once a procedure has worked.

## Booting between Linux and macOS

- **Linux -> macOS: shut down fully, then power on** and pick OpenCore. Never use restart: Vermilion's bring-up needs
  a cold GPU (the SMU firmware may be loaded only once per power cycle).
- **macOS -> Linux:** wait until `/var/log/phxboot.log` says `done`, then shut down or restart normally
  ([INSTALL.md 8.3](../docs/INSTALL.md)).
- **Bad boot:** boot-arg `-phxbringupoff` (or `-phxacceloff`) for one boot, or `touch ~/gpu/phxboot-off`, or disable
  `VermilionBoot.kext` in OpenCore.
- **One EFI change per boot.** Keep the previous EFI folder (`EFI/OC.prev`) until the new one has booted several
  times.

## BIOS settings for macOS (ASUS B650E-I, BIOS 4005) *(unverified: menu names from ASUS AM5 boards)*

Press F2 or Del at power-on, then F7 for Advanced Mode.

| Setting | Value | Where |
|---|---|---|
| CSM | Disabled | Boot > CSM (Compatibility Support Module) > Launch CSM |
| Secure Boot | off (OS Type: Other OS) | Boot > Secure Boot (already off) |
| Above 4G Decoding | Enabled | Advanced > PCI Subsystem Settings |
| Re-Size BAR Support | Enabled (OpenCore gives macOS 256 MiB BARs) | Advanced > PCI Subsystem Settings |
| Primary video device | the dGPU (PCIe), so its GOP lights the monitor | Advanced > NB Configuration (name varies) |
| Fast Boot | Disabled (reliable F8 menu and USB at boot) | Boot > Boot Configuration |
| SVM, IOMMU | leave on (Linux VFIO later; macOS ignores AMD-Vi) | Advanced > AMD CBS |

## Booting Linux

Start Linux the normal way (Limine is first in the firmware boot order), **not** from OpenCore's picker. Linux started
by OpenCore gets OpenCore's Mac identity and ACPI tables, and `efibootmgr` then shows OpenCore's private (empty) boot
list instead of the real one.

## First boot of OpenCore

1. Power off fully, then power on and press **F8**: the firmware boot menu. Pick **OpenCore** (Limine stays the
   default, so a normal boot still starts Linux).
2. In the OpenCore picker, pick the installer volume (**Install macOS Tahoe**).
3. Verbose boot (`-v`): if it stops, take a photo of the last lines. The OpenCore log is on the EFI partition
   (`/boot/opencore-*.txt` under Linux).
4. In the installer: Disk Utility > View > Show All Devices. Erase **only the `MACOS` volume** (78 GiB, exFAT) as
   APFS, name it `Macintosh HD`, then install onto it.

## Reading the macOS disk from Linux (root, read-only)

Logs from macOS boots that never reached a desktop (2026-11-19, works). `apfs-fuse` is read-only. Build it once:

```sh
git clone --recursive https://github.com/sgan81/apfs-fuse.git && mkdir apfs-fuse/build && cd apfs-fuse/build
cmake -DUSE_FUSE3=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="-include cstdint" .. && make -j8
```

Mount one volume at a time. On p3: `-v 0` Data, `1` Preboot, `2` Recovery, `3` System, `4` Update. Files are under
`<mnt>/root`:

```sh
sudo ./apfs-fuse -o ro,allow_other -v 0 /dev/nvme0n1p3 /mnt/mac   # Data volume
sudo tail -100 /mnt/mac/root/private/var/log/install.log           # installer phases, "Triggering reboot"
sudo ls /mnt/mac/root/Library/Logs/DiagnosticReports               # panic reports
sudo umount /mnt/mac
```

The OpenCore log of every boot (`/boot/opencore-*.txt`) shows the boot.efi path and kernel flags
(`grep -a 'LIMG:FP\|MBA:OUT\|EXITBS'`). Together these tell you which installer phase a boot was in.

## Reading the XTX from Linux (no root)

[`tools/capture/gpuinfo.c`](../tools/capture/gpuinfo.c) (libdrm `AMDGPU_INFO_DEV_INFO`, `VRAM_GTT`, firmware
versions; 2026-11-18, works):

```sh
cc -Wall -I/usr/include/libdrm -o /tmp/gpuinfo tools/capture/gpuinfo.c -ldrm_amdgpu && /tmp/gpuinfo /dev/dri/renderD128
```

The dGPU is `renderD128` / `card1` (PCI `03:00.0`); the iGPU is `renderD129` / `card0` (`0e:00.0`). Check with
`readlink -f /sys/class/drm/renderD*/device`, because the numbering can change.

## Register captures from Linux (root) *(unverified)*

Read-only, while amdgpu drives the monitor in the mode being captured:

```sh
D=/sys/kernel/debug/dri/0000:03:00.0                          # dGPU (or dri/<minor>, check `ls`)
sudo cat $D/amdgpu_dm_dtn_log                                 # DCN state: watermarks, DLG/TTU, pipes
# one dword at a time: byte offset = dword index * 4
sudo dd if=$D/amdgpu_regs bs=4 skip=$((0x4FEA)) count=1 2>/dev/null | xxd
sudo dd if=/dev/drm_dp_aux2 bs=1 count=16 2>/dev/null | xxd   # DPCD of DP-3 (card1-DP-3 owns drm_dp_aux2)
```

Linux connectors on the XTX (sysfs, 2026-11-18): DP-1 = `drm_dp_aux0`, DP-2 = `drm_dp_aux1`, DP-3 (the monitor) =
`drm_dp_aux2`. Which VBIOS path / DIG each of these is (DP A/B/E) is not settled yet, because Linux's AUX bus
numbers differ from the VBIOS's.

Never write to `amdgpu_regs`. Captures go to a local directory outside git, unless they contain no serials and are
turned into plans.

## Building on the Mac itself (since 2026-11-22, works)

The kexts, the plugin and VermilionTrust build on the XTX machine's own macOS (Command Line Tools, x86_64), without
the macbox VM. MacKernelSDK and Vulkan-Headers are in `~/src/vermilion/deps/`. RADV needs a Mesa checkout at
`f5cb8ee0` with the patches: `~/src/vermilion/deps/mesa` since 2026-11-23 (set-up below).

```sh
export MKSDK=$HOME/src/vermilion/deps/MacKernelSDK VULKAN_HEADERS=$HOME/src/vermilion/deps/Vulkan-Headers/include
sh scripts/build/kext.sh          # VermilionBoot; also accel.sh, plugin.sh, translator.sh, tools.sh, metaltest.sh
PHXTRUST_KEEP=1 sh scripts/build/trust.sh        # last: it lists the cdhashes of the installed code (see below)
```

Checked 2026-11-23 on `fork/main` `46bfd53`: `kext.sh` and `trust.sh` (with the list kept) rebuild VermilionBoot b150
and VermilionTrust 1.0.3 byte for byte.

RADV on the Mac (thread 02, 2026-11-23; ~3 minutes, the Mesa checkout ~560 MB and the build ~1 GB: check `df -h` first,
the Data volume ran full once):

```sh
curl -LsSf https://astral.sh/uv/install.sh | sh -s -- --no-modify-path    # the system Python is 3.9, meson needs >= 3.10
~/.local/bin/uv python install 3.12 && ~/.local/bin/uv venv -p 3.12 ~/src/venv
~/.local/bin/uv pip install -p ~/src/venv/bin/python meson ninja mako pyyaml markupsafe packaging
# glslang: the macOS release of KhronosGroup/glslang (gh release download 16.5.0 -p '*macos-universal-release.tar.gz'),
# unpacked to ~/src/tools/glslang, plus a link bin/glslangValidator -> glslang
mkdir -p ~/src/vermilion/deps/mesa && cd ~/src/vermilion/deps/mesa && git init -q \
  && git remote add origin https://gitlab.freedesktop.org/mesa/mesa.git \
  && git fetch --depth 1 origin f5cb8ee032adabef599ae892ec4e42d796b84da9 && git checkout -q FETCH_HEAD
git -C ~/src/vermilion/deps/mesa am <checkout>/patches/mesa/*.patch       # an absolute path
PATH=$HOME/src/tools/glslang/bin:$HOME/src/venv/bin:$PATH MESA_DIR=$HOME/src/vermilion/deps/mesa sh scripts/build/radv.sh
```

With 0001-0017 this rebuilt the then-installed RADV (`8054fbe4`) apart from the Mach-O UUID and the git id in the version
string (36 bytes). Before installing a RADV build, measure it side-loaded: `VKBENCH_DRIVER=<dylib> vkbench ...`,
`NVMTL_ICD_LIB=<dylib> metalbench ...` (the plugin's override; works in unhardened processes only).

## Build host (macOS VM via macbox) (2026-11-19, works; superseded by the Mac itself)

The macbox VM runs macOS 26.7.3 (x86_64) with Xcode. Set up once (everything in `~/src` on the guest):

```sh
macbox up && ssh macbox
git clone https://github.com/ownback/vermilion-xtx.git ~/src/vermilion
cd ~/src/vermilion/deps && git clone --depth 1 https://github.com/acidanthera/MacKernelSDK.git \
  && git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git
curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-host x86_64-apple-darwin
curl -LsSf https://astral.sh/uv/install.sh | sh                     # Mesa's meson needs Python >= 3.10; the system has 3.9
~/.local/bin/uv python install 3.12 && ~/.local/bin/uv venv -p 3.12 ~/src/venv
~/.local/bin/uv pip install -p ~/src/venv/bin/python meson ninja mako pyyaml markupsafe packaging cmake
# glslangValidator: the macOS release binary of KhronosGroup/glslang 16.6.0, unpacked to ~/src/tools/glslang
# Mesa at f5cb8ee0 (a shallow fetch of the one commit), then the patches with an ABSOLUTE path:
mkdir ~/src/mesa && cd ~/src/mesa && git init -q && git remote add origin https://gitlab.freedesktop.org/mesa/mesa.git \
  && git fetch --depth 1 origin f5cb8ee032adabef599ae892ec4e42d796b84da9 && git checkout FETCH_HEAD
git -C ~/src/mesa am ~/src/vermilion/patches/mesa/*.patch          # `radv.sh apply` passes a relative path, which fails
                                                                   # under `git -C`
```

Build (about 10 minutes, most of it RADV):

```sh
cd ~/src/vermilion && export PATH=$HOME/src/tools/glslang/bin:$HOME/.cargo/bin:$HOME/src/venv/bin:$PATH
export MKSDK=$PWD/deps/MacKernelSDK MESA_DIR=$HOME/src/mesa
tools/firmware/fetch_firmware.sh
for s in kext accel tools metaltest plugin translator radv; do sh scripts/build/$s.sh; done
```

`spirv-val` (the translator runs it; Vermilion doesn't ship it): SPIRV-Tools v2025.4, `python3 utils/git-sync-deps`,
then `cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 -DSPIRV_SKIP_TESTS=ON
-DBUILD_SHARED_LIBS=OFF` and `ninja spirv-val`. Copy it to `build/spirv-val` and sign it with `codesign -fs -`.

Copy `build/` to the Linux checkout with `rsync -a macbox:src/vermilion/build/ build/`. Stop the VM afterwards
(`macbox down`): it uses 8 CPUs and 15 GB. The VM has no AMD GPU, so it only builds; all driver testing happens on
bare metal. The mock suites run there too (`bash tests/mock/run.sh`, `b15test.sh`, `espflags_test.sh`,
`recovery_install_test.sh`); the guest has passwordless sudo, so `recovery_install.sh` can also be run as root
against a fake Data volume.

## Installing Vermilion without the desktop (XTX machine, 2026-11-19)

*Historical: the first install, before macOS had an accelerated desktop. `esp_stage.sh` leaves a payload of
binaries on the ESP; delete `vermilion/payload/`, `install.sh` and `MD5SUMS` once the install has worked (thread 00
did on 2026-11-23). The everyday paths are "Deploying a plugin, translator or RADV build" and "Building and installing
the EFI on the Mac itself".*

From Linux (root):

```sh
sh tools/phxctl/esp_stage.sh /boot/vermilion ~/.cache/vermilion/fw/navi31   # payload + install.sh, MD5SUMS
efi/build.py build --stage vermilion && efi/build.py install --esp /boot --stage vermilion   # keeps EFI/OC.prev
```

Then power off, F8 > OpenCore > Reset NVRAM > OpenCore > the Recovery entry > Utilities > Terminal (the Reset NVRAM
step was the first install only, before `phxfb-squat` existed: never do it now, hard rule 1; the live stage's picker
has no such entry once phase 2 item 1 (b) has booted):

```sh
mkdir -p /tmp/efi && diskutil mount -mountPoint /tmp/efi disk2s1 && sh /tmp/efi/vermilion/install.sh
```

In Recovery, `disk0`/`disk1` are Recovery's own disk image (2026-11-19: `diskutil mount disk0s1` refused, "APFS
Physical Store"); the NVMe was `disk2`, its EFI partition `disk2s1` (TYPE `EFI`, name `NO NAME`, so it would mount
as `/Volumes/NO NAME`, hence the fixed mount point). Check with `diskutil list` if the numbering changes. Then
restart into Macintosh HD.

Flags for the next boot, from Linux, without macOS: `touch /boot/vermilion/flags/phxboot-desktop` (one desktop-arm
attempt), `touch /boot/vermilion/flags/phxboot-off` (kill switch), `touch /boot/vermilion/flags/phxboot-off.rm`
(remove it). The daemon's pre-hook takes them at the next boot and logs one `esp-flags:` line each in
`/var/log/phxboot.log`. Read that log from Linux with `apfs-fuse` (above). Roll the EFI back with
`mv /boot/EFI/OC /boot/EFI/OC.vermilion && mv /boot/EFI/OC.prev /boot/EFI/OC`.

## Measuring a boot from Linux (2026-11-19, tested on macbox)

`tools/phxctl/perflog.sh` writes the display path's counters (frames/s, CPU copy time, flips, GPU-present skips,
frame pacing, `debug.phxscan_layout`) every 10 s for 10 min to `/var/log/vermilion-perf-<date>.log`, starting when
the daemon armed the desktop. It reads only named sysctls. Start it for one boot from a `run-once.sh`:

```sh
sudo mkdir -p /boot/vermilion/perf && sudo cp tools/phxctl/perflog.sh tools/phxctl/perflog_install.sh /boot/vermilion/perf/
# run-once.sh: bash "$1/perf/perflog_install.sh" "$1/perf/perflog.sh" 600 10
```

`perflog_install.sh` copies the logger to `/var/db/vermilion` and starts it with `launchctl bootstrap` from a plist in
that directory, so it runs once and never again at a later boot. Read the log afterwards with apfs-fuse
(`/mnt/mac/root/private/var/log/vermilion-perf-*.log`).

## OpenCore EFI install from Linux (2026-11-18, first install)

Superseded for everyday changes by "Building and installing the EFI on the Mac itself" below. From Linux, the
`efi/build.py install --esp /boot --stage <stage>` step does step 1. The EFI partition is shared with Limine (`/boot` on Linux). Steps:

1. Copy the EFI to `/boot/EFI/OC`. Never touch `EFI/BOOT/BOOTX64.EFI` (Limine's fallback) or `EFI/limine`.
2. Add a firmware boot entry, without changing the boot order:
   `sudo efibootmgr --create --disk /dev/nvme0n1 --part 1 --label "OpenCore" --loader '\EFI\OC\OpenCore.efi'`.
3. Pick OpenCore from the firmware boot menu (F8 on ASUS) until it is proven; only then consider a Limine entry or
   reordering.

## Logging the Wi-Fi state of one boot (2026-11-19, tested on macbox)

`tools/phxctl/wifilog.sh` writes one status line a minute (kext loaded, Wi-Fi port, power, link, IPv4 yes/no) plus
the card's `system_profiler` fields and the driver's `MtkDebugLog` at the start and the end, MAC addresses masked.
Stage it with the same installer as perflog, under its own name:

```sh
sudo mkdir -p /boot/vermilion/wifi && sudo cp tools/phxctl/wifilog.sh tools/phxctl/perflog_install.sh /boot/vermilion/wifi/
# run-once.sh: PERF_NAME=wifi bash "$1/wifi/perflog_install.sh" "$1/wifi/wifilog.sh" 1200 60
```

Read `/mnt/mac/root/private/var/log/vermilion-wifi-*.log` with apfs-fuse. The driver's ring may name networks:
quote it redacted.

## Booting straight into macOS (2026-11-19)

Firmware boot order: OpenCore first. OpenCore's default entry: in the picker, select Macintosh HD and press
Ctrl+Enter (`AllowSetDefault`; OpenCore writes it before macOS starts, so `DisableVariableWrite` doesn't block it;
unverified that it sticks). The Linux side keeps the cold-GPU rule with a reboot guard: a Linux reboot sets
BootNext=Limine, a power-off doesn't. Install on Linux (root):

```sh
install -m 755 tools/linux/reboot_to_linux.sh /usr/local/sbin/vermilion-reboot-to-linux
install -m 644 tools/linux/vermilion-reboot-to-linux.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable vermilion-reboot-to-linux.service
```

To make Limine the default again: `efibootmgr --bootorder 0000,0006,0001,0002`.

## Building and installing the EFI on the Mac itself (2026-11-19, works)

```sh
sudo mkdir -p /private/tmp/efi && sudo diskutil mount -mountPoint /private/tmp/efi disk0s1   # the NVMe's EFI partition
# once: the machine config (serials, ACPI dump; never into git) and iasl 20251212 (same as Linux: identical AML)
# ~/.config/vermilion comes from Linux (efi/build.py smbios + acpi-dump). Carry it over once on a USB stick or by
# scp, never by leaving it on the ESP (FAT: any OS reads it), then: chmod -R go-rwx ~/.config/vermilion
git clone https://github.com/acpica/acpica.git ~/.local/src/acpica && git -C ~/.local/src/acpica checkout 446be4382 \
  && make -C ~/.local/src/acpica -j8 iasl && cp ~/.local/src/acpica/generate/unix/bin/iasl ~/.local/bin/
sh scripts/build/kext.sh && PHXTRUST_KEEP=1 sh scripts/build/trust.sh                    # build/VermilionBoot.kext, VermilionTrust.kext
PATH=$HOME/.local/bin:$PATH python3 efi/build.py build --stage vermilion-trust             # --stage is required; the everyday stage
sudo diff -rq /private/tmp/efi/EFI/OC build/efi/b650e-i-xtx-vermilion-trust/EFI/OC           # only the intended files
sudo python3 efi/build.py install --esp /private/tmp/efi --stage vermilion-trust            # keeps EFI/OC.prev
```

`config.plist` always differs from a `--placeholder-smbios` build in `PlatformInfo` only. `build/efi/` contains the
serials: delete it when done, never copy or commit it.

Rollback from the Mac: `sudo mv /private/tmp/efi/EFI/OC /private/tmp/efi/EFI/OC.bad && sudo mv /private/tmp/efi/EFI/OC.prev /private/tmp/efi/EFI/OC`.
In zsh, use `/usr/bin/log` (zsh has its own `log` builtin).

## Deploying a plugin, translator or RADV build (2026-11-23)

AMFI enforces library validation (stage `vermilion-trust`): WindowServer maps only the cdhashes compiled into
VermilionTrust. **A new NVMTLDriver, `libnvmtl_translate.dylib`, `libvulkan_radeon.dylib` (or LLVM / zstd, the video
decoder) has a new cdhash, so every install of one is also a VermilionTrust and EFI change:**

1. Build the new binary and keep the old one: `~/vermilion-rollback/<name>-<date>/`.
2. Install it into `/Library/GPUBundles/...` (as before; on the reference machine those paths are symlinks into
   `CoreTypes.bundle/Contents/Library/PhxGPU` since 2026-11-23, and the install lands there).
3. `PHXTRUST_KEEP=1 sh scripts/build/trust.sh`: the new list holds the installed files (the video decoder's dylibs
   and bundle included, when installed; `PHXTRUST_ADD` for files not installed yet) **and** the cdhashes of the
   current list (marked `-previous`), so the kext accepts the old and the new build and the plugin install and the
   EFI don't have to land in the same boot.
4. Rebuild and install the EFI ("Building and installing the EFI on the Mac itself"): `diff -rq` must show only
   `Kexts/VermilionTrust.kext` (and `config.plist`, if anything else changed on purpose). One EFI change: write the
   check and rollback into TODO first.
5. Restart. Check `sysctl debug.phxtrust_stat` (`mode=enforce`, `denied_unlisted=0`) and `sysctl
   debug.phxtrust_files` (the new file listed with overrides), plus an accelerated desktop.
6. Rollback: the old binary back from `~/vermilion-rollback/` (the kext trusts it as `-previous`), or `EFI/OC.prev`.
   An `OC.prev` built before the new list doesn't trust the new binary: restore the old binary first.
7. Once the old build is gone for good, drop its `-previous` entry: rebuild without `PHXTRUST_KEEP`.

Without step 3 AMFI refuses the new build in every platform process and the desktop loses acceleration.

## Linux sessions (one-off captures)

A Linux boot of the XTX machine collects what macOS can't: reference numbers, register traces, firmware tables. The
current plan for the next one: [HANDOFF-LINUX-REFERENCE.md](HANDOFF-LINUX-REFERENCE.md). The rules for every one:

- Read-only: lspci, sysfs, debugfs, tracepoints, `dmesg`. No `setpci` writes, no `umr -w`, nothing written under
  `/sys` except what a capture tool documents (amdgpu-mediated mode sets, link preferences), no amdgpu reload, no
  kernel parameter change, no VBIOS access.
- No EFI install, no `efibootmgr`, no EFI variable change, nothing under `/boot/EFI` or
  `/boot/vermilion/{run-once.sh,flags}`. Don't remove the reboot guard (`vermilion-reboot-to-linux.service`).
- Root: the password through T3's `request_secret` with file delivery, `sudo -S -p '' ... < "$file"`, never in chat.
- Captures go outside git (`~/vermilion-captures/`, or the ESP only for the trip to macOS, deleted after). Only a
  findings note goes into git: no serials, MACs, EDIDs with serials, register dumps.
- End: **shut down Linux (power off, not restart), power on, macOS**.

Done so far, with their tools:

| Date | Capture | Tool | Result |
|---|---|---|---|
| 2026-11-19 | PCI view of the chipset path (Wi-Fi / I225-V not answering in macOS) | `tools/capture/linux_pci_capture.sh <dir>` (lspci, sysfs, dmesg; MACs masked; mock test `tests/mock/linux_pci_capture_test.sh`) | Common Clock set on every link under Linux; the cause turned out to be 10-bit tags ([finding](findings/2026-11-19-wifi-mt7922.md)) |
| 2026-11-20 / 21 | Display mode sets of the LG, v1-v4: 60-240 Hz, HBR2, HDR, every EDID mode, VRR, HDR pairs | `tools/capture/linux_display_capture.py <dir> [--steps ...] [--all-modes] [--hdr-pairs]` (Hyprland mode sets; `amdgpu_dc_wreg` tracepoint, DMUB command kprobe, DTN log, DPCD; `--dry-run` lists the steps) | the replay plans (`tools/capture/p0odm_from_trace.py`); captures in `~/vermilion-captures/capture/` ([refresh / HDR](findings/2026-11-19-refresh-and-hdr.md), [HDR](findings/2026-11-21-hdr.md)) |

Display capture notes: it needs debugfs and the `amdgpu_dm/amdgpu_dc_wreg` tracepoint (stop if missing; don't patch
the kernel); the screen switches modes and may go black for seconds per step; a forced HBR2 link (`--steps hbr2-*`)
stays forced until power-off, so run it last; `edid-noserial.bin` must show zeros at bytes 12-15.
