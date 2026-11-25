# OpenCore EFI

A reproducible OpenCore EFI for running macOS Tahoe on the machines in [`machines/`](machines/). Today that's only
the XTX machine from [docs/REFERENCE-MACHINES.md](../docs/REFERENCE-MACHINES.md). Nothing here is a hand-edited
`config.plist`:

| File | What |
|---|---|
| [`components.json`](components.json) | Every downloaded input (OpenCore, kexts, drivers, AMD patches), pinned by URL and SHA-256 |
| [`machines/<id>.json`](machines/) | One machine: CPU cores, SMBIOS model, ACPI tables, the settings that differ from OpenCore's `Sample.plist`, and the **stages** |
| [`acpi/`](acpi/) | SSDT sources (`.dsl`), compiled with `iasl` at build time. Each one says which DSDT it was written against |
| [`acpi/fix_dsdt.py`](acpi/fix_dsdt.py) | Rewrites a firmware DSDT so macOS can load it (`resolve`). Not used by the XTX machine since 2026-11-19 (`dsdt_fix: false`): in-place DSDT patches replaced it, see below |
| [`kexts/`](kexts/) | Codeless kexts kept as source (plists): `AppleMCEReporterDisabler`, `UTBMap` (the USB map) |
| [`build.py`](build.py) | Fetches, verifies, assembles `EFI/`, generates `config.plist` from `Sample.plist` + the machine file, runs `ocvalidate` |

SMBIOS serials (serial, MLB, UUID, ROM) are generated once per machine with OpenCore's `macserial`. They live in
`~/.config/vermilion/smbios-<machine>.json` (mode 0600) and are never written into the repository. The generated
`config.plist` contains them, so `build/` is git-ignored. **Never publish a built EFI.**

## Build

Needs `python3` (stdlib only) and `iasl` (Arch: `pacman -S acpica`, macOS: `brew install acpica`). Works on Linux and
macOS.

```sh
efi/build.py smbios                      # once per machine: ~/.config/vermilion/smbios-b650e-i-xtx.json
sudo efi/build.py acpi-dump              # once per BIOS version, on the machine, Linux booted directly (not via OpenCore):
                                         #   DSDT + the live ACPI namespace, in ~/.config/vermilion/acpi/<machine>/
efi/build.py stages                      # what each stage contains; "(default)" marks the profile's default_stage
efi/build.py build --stage vermilion-trust   # the everyday stage -> build/efi/b650e-i-xtx-vermilion-trust/EFI/{BOOT,OC}
efi/build.py build --stage install           # any other stage by name; `build` and `install` refuse to run without --stage
efi/build.py build --stage install --placeholder-smbios  # test build with dummy serials (never boot it)
```

The DSDT patches are byte patterns for one BIOS version (`acpi_patches_bios` in the machine file, 4005 here).
`build.py` refuses a DSDT dump of another version and, under Linux booted directly, a firmware that differs from the
dump. From macOS the live BIOS version can't be read (OpenCore's SMBIOS hides it): after a BIOS update, dump again
under Linux before building. Building on a Linux machine other than the target (a second PC, CI): set
`VERMILION_EFI_OTHER_HOST=1`, so the live firmware isn't compared.

## Stages

One machine, several configurations. Each stage builds on the previous one, so a problem can be traced to the one
change that caused it:

| Stage | For | Adds |
|---|---|---|
| `install` | First boot and the macOS installer | Lilu, VirtualSMC, NVMeFix, RestrictEvents, AppleMCEReporterDisabler; `-v keepsyms=1 debug=0x100`; SIP on |
| `base` | The installed system | + MtkWirelessWifi (Wi-Fi), `pci=0x8000000` and `amtk_awdl_offchan=0` (AWDL stays on the router's channel); USBToolBox + UTBMap (USB map); SMCProcessorAMD (CPU temperature and power); BlueToolFixup + MtkWirelessBT and two NVRAM variables (Bluetooth) |
| `vermilion` | GPU acceleration with AMFI relaxed ([docs/INSTALL.md](../docs/INSTALL.md)); the fallback | + AMFIPass, `VermilionBoot.kext` (from `build/`); `amfi=0x80 ipc_control_port_options=0 phxdebug=1`; SIP `0x0A03` |
| `vermilion-trustlog` | One diagnostic boot of VermilionTrust | `vermilion` + `VermilionTrust.kext` (from `build/`) + `-phxtrustlog`: the kext only reports, `amfi=0x80` stays |
| **`vermilion-trust`** | **The everyday stage (`default_stage`); the XTX machine boots it since 2026-11-22 (EFI change 7, VermilionTrust 1.0.3 since change 8)** | `vermilion` + `VermilionTrust.kext`, **without `amfi=0x80`**: AMFI enforces library validation, VermilionTrust lets only the cdhashes of the installed Vermilion code through ([src/vermilion-trust/](../src/vermilion-trust/)). Rebuild it and the EFI after every plugin, translator or RADV install ([runbooks](../.agents/runbooks.md#deploying-a-plugin-translator-or-radv-build-2026-11-23)) |
| `vermilion-trust-nvram` | A test: NVRAM writes from macOS (thread 01, 2026-11-23; result inconclusive, not in use) | `vermilion-trust` with the booter quirk `DisableVariableWrite` off, nothing else |
| `vermilion-pcilog` | One diagnostic boot | + IOPCIFamily logging (`pci_log_mode`, `pci_log`), no behaviour change |

Resolved boot-args of `vermilion-trust`: `-v keepsyms=1 debug=0x100 pci=0x8000000 amtk_awdl_offchan=0
ipc_control_port_options=0 phxdebug=1` (`efi/build.py stages` prints every stage).

A stage can add kexts (`kexts_add`), add or remove boot-args (`boot_args_add`, `boot_args_remove`), add Apple-GUID
NVRAM variables (`nvram_add`, hex data, written by OpenCore at every boot), set `csr_active_config`, override the
machine's booter quirks (`booter_quirks`) and drop some of the machine's UEFI drivers (`uefi_drivers_remove`). Each
change is tested on its own boot; the dated reasons sit next to each entry in the machine file (`_comment` keys) and
in [`.agents/`](../.agents/).

## Install onto the EFI partition

The EFI partition on the XTX machine is shared with Linux's Limine (`/boot`). `install` only writes `EFI/OC` and keeps
the previous one as `EFI/OC.prev`. It never touches `EFI/BOOT/BOOTX64.EFI` (Limine's fallback) unless
`--with-fallback` is given, which is meant for USB sticks.

```sh
sudo efi/build.py install --esp /boot --stage install     # the first boot; --stage is always required (later: vermilion-trust)
sudo efibootmgr --create --disk /dev/nvme0n1 --part 1 --label OpenCore --loader '\EFI\OC\OpenCore.efi'
```

From macOS on the same machine the EFI partition is `disk0s1` (`sudo diskutil mount disk0s1`, it mounts at
`/Volumes/NO NAME`), then `sudo efi/build.py install --esp "/Volumes/NO NAME" --stage <stage>`. The macOS build steps (iasl, the
machine config, `build/VermilionBoot.kext`, `build/VermilionTrust.kext`) are in
[`.agents/runbooks.md`](../.agents/runbooks.md#building-and-installing-the-efi-on-the-mac-itself-2026-11-19-works).
Before installing, compare the build with the live EFI (`diff -rq`): only the intended files may differ.

`efibootmgr --create` puts the new entry first in the boot order. To keep Limine as the default, restore the old
order with `efibootmgr --bootorder ...`, then choose OpenCore once from the firmware boot menu (F8 on ASUS).

## The macOS installer without a USB stick

Recovery images always install the newest macOS, but Vermilion is pinned to 26.7.1. The full installer (18.4 GB)
doesn't fit on a small stick, so it goes onto a partition of the internal disk instead:

```sh
efi/installer/macos_catalog.py --version 26.7.1 --url        # Apple's download URL for that version
# on a Mac (the macbox VM): download it, then
efi/installer/make-installer-image.sh InstallAssistant.pkg Installer-26.7.1.dmg 21g
# on Linux: a partition with the GPT name "macOS Installer" (Apple HFS+ type, 22 GiB), then
efi/installer/write-installer-partition.sh macbox Installer-26.7.1.dmg /dev/nvme0n1p4 --yes
```

`make-installer-image.sh` checks Apple's signature, runs `createinstallmedia` onto a bare HFS+ image (no partition
map), and the writer streams it over SSH and compares SHA-256 on both sides. OpenCore lists the partition as
**Install macOS Tahoe**. After the install it can stay as a 26.7.1 reinstall path (the XTX machine keeps it for now,
owner 2026-11-22), or be deleted and the APFS container grown into the space (`diskutil apfs resizeContainer disk0s3 0`
from macOS). Which one is the default is open (TODO, thread 10).

## Why these settings (XTX machine)

- **AMD CPU:** AMD_Vanilla kernel patches with the core count set to the physical cores (`0x0C`), including the
  Zen 4 PAT patch and the IOPCIFamily 10-bit-tag patch; `ProvideCurrentCpuInfo`; `DummyPowerManagement` (no OS P-state control: the CPU's firmware
  handles clocks and idle). CPU temperature and package power come from SMCProcessorAMD, which only reads.
  AMDRyzenCPUPowerManagement is deliberately not used: it replaces the kernel's CPU power management and rewrites
  a P-state MSR ([findings](../.agents/findings/2026-11-22-cpu-sensors.md)).
- **Booter quirks:** as the ASUS B650E-F config (same chipset family) uses them, including `SetupVirtualMap` and
  `DevirtualiseMmio`. `DisableVariableWrite`: the installer froze while writing NVRAM on this board; side effect,
  macOS can't write NVRAM at all (no startup-disk change, no panic log in NVRAM).
- **`ResizeAppleGpuBars = 0`** (stage `vermilion-trust-bar1g`: 10, BAR0 1 GiB, decisions 2026-11-23): Resizable BAR stays on for Linux. macOS sees the default BAR sizes (BAR0 256 MiB),
  which is what Vermilion was validated with.
- **ACPI:**
  - **DSDT patches in place.** BIOS 4005 creates the whole chipset (`GPP7.UP00`: its USB, SATA, LAN, Wi-Fi)
    inside module-level `If (G002 ... G000 ...)` blocks, and macOS hung after `CoreAnalyticsHub` (same as ASUS AM5
    boards in nullmoth/1401 issue 21). Five `ACPI > Patch` entries replace those `If` headers with NOPs, so the
    blocks run as they do on Linux; `build.py` checks that each pattern occurs exactly once in the dumped DSDT and
    that the dump is from the BIOS version the patches were derived for. (A recompiled, resolved DSDT from
    `fix_dsdt.py` loaded but still hung; it is no longer used.) Re-derive the patches after a BIOS update.
  - **`SSDT-CPUR-B650EI`:** the firmware declares the CPUs only as `ACPI0007` devices; macOS needs `Processor ()`
    objects (24, from the MADT).
  - **`SSDT-EC-USBX-B650EI`:** hides the desktop EC from macOS, adds the fake `EC` and the USB power properties.
  - Nothing else is needed (audited 2026-11-19): the RTC is the legacy one (no AWAC), and PLUG / PMCR / MCHC /
    SBUS are Intel-only.
- **USB map:** macOS didn't create the internal ports of the USB audio and the Bluetooth module. The cause is
  unproven: the firmware's `_UPC` marks them not connectable, or the chipset controller's 17 ports exceed macOS's 15.
  USBToolBox drops the ACPI ports and takes them from `kexts/UTBMap.kext`: the 8 rear ports and the internal audio /
  Bluetooth ports ([findings](../.agents/findings/2026-11-22-usb-map.md)).
- **`pci=0x8000000`:** macOS keeps the firmware's PCIe tag settings. Otherwise it enables 10-bit tags on the
  chipset root port and the Wi-Fi card and the I225-V stop answering.
- **`amtk_awdl_offchan=0`:** MtkWireless keeps AWDL on the router's channel. Without it the radio left the channel
  for ~400 ms every ~1 s (router ping max 456 ms; 4 ms with it). Cost: AirDrop fails while the router is on a channel
  AWDL doesn't use (DFS 52 here).
- **VermilionTrust instead of `amfi=0x80`:** the ad-hoc signed Metal plugin must load into WindowServer and other
  platform processes. `amfi=0x80` turned library validation off for every process (and made every app a platform
  binary, which broke privacy prompts); VermilionTrust lets only Vermilion's own cdhashes through. AMFIPass is still
  in the stage; whether anything needs it now is open (thread 09).
- **AGDP board-id patch** (`agdpmod=pikera` as a kernel patch): Navi cards hang when the graphics stack takes over
  without it, and WhateverGreen doesn't work on macOS 26.
- **SMBIOS `MacPro7,1`:** upstream's choice for Vermilion. RestrictEvents silences its memory-slot warnings, and
  AppleMCEReporterDisabler stops its MCE reporter from panicking on AMD.
- **`SecureBootModel = Disabled`:** Vermilion's injected kexts are unsigned.
- **Debug:** verbose boot and an OpenCore log file on the EFI partition (`Target = 67`) during bring-up (still on).
  The partition collected one log per boot until 2026-11-22 23:20; none since, for reasons unknown. Delete old logs
  now and then (keep the newest few).
- **`ResetNvramEntry.efi --preserve-boot`:** the picker's Reset NVRAM keeps the firmware boot entries. The live stage
  `vermilion-trust-bar1g-audio` drops the driver (`uefi_drivers_remove`), so its picker has no Reset NVRAM entry:
  Reset NVRAM deletes `phxfb-squat`, which macOS can't set again (CLAUDE.md hard rule 1). OpenCore 1.0.8 has no other
  NVRAM reset (unverified).
- **Don't boot Linux through OpenCore.** It would get OpenCore's SMBIOS and ACPI tables, and `efibootmgr` would see
  OpenCore's private boot variables instead of the firmware's. Start Linux from the firmware (Limine is the default).

## Updating a pin

Change `url` and `sha256` together in `components.json` (`sha256sum` of the new file), rebuild, and note the reason in
the commit. `build.py` refuses any file whose hash differs from its pin.
