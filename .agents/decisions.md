# Decisions

Append-only log of choices that shape the work. Each entry has a date, the decision, why, and what would make us
revisit it. Newest at the bottom.

## 2026-11-18: Fork, keep upstream's XT working

**Decision:** work in `ownback/vermilion` (git remote `fork`). `origin` stays leolivm's upstream, read-only for us.
XTX support is added next to the XT values and chosen by detected hardware; no XT value is replaced.
**Why:** upstream is the only Navi 31 macOS driver, it was last updated 2026-11-10, and its XT path is known to work.
Detection keeps our changes usable upstream.
**Revisit:** if upstream becomes active again, rebase onto it and send PRs early.

## 2026-11-18: Bare metal first, VFIO second

**Decision:** get macOS stable on bare metal with the dGPU as the boot display first. Only then build the passthrough
VM.
**Why:** the driver depends on the GOP having lit the monitor and on a cold GPU. Both are easiest to guarantee on bare
metal, and a VM adds reset and OVMF problems on top of driver problems.
**Revisit:** never for ordering. The BIOS primary display changes to the iGPU in Phase 5.

## 2026-11-18: macOS Tahoe 26.7.1, pinned

**Decision:** install exactly 26.7.1 and block updates. Get it as Apple's full installer (build 25G241, still served on
2026-11-18), not through recovery, which installs the newest version (26.7.3).
**Why:** the Metal plugin uses private interfaces of that build (upstream).
**Revisit:** when the plugin is verified on a newer build.

## 2026-11-18: macOS on a 100 GiB partition of the existing NVMe

**Decision:** shrink the Linux LUKS/btrfs partition by 100 GiB and use the space for macOS (p3, exFAT placeholder,
erased as APFS by the installer). The partition table and LUKS header from before are backed up outside the repo.
**Why:** the owner accepted the risk; no second drive yet; 100 GiB is enough to prove the install.
**Revisit:** when macOS becomes a daily system, or for the VFIO VM (a whole disk passed through is simpler).

## 2026-11-18: One monitor at 1440p is the target

**Decision:** target one 2560x1440 DP monitor (60 Hz first, then 120/144/165/240 Hz). Upstream's second-monitor
paths stay untouched but unused.
**Why:** that's the machine's monitor. The second cable goes to the iGPU for the Linux host.

## 2026-11-18: Wi-Fi via AirportMtkWlan first

**Decision:** try Arxusion/AirportMtkWlan (Tahoe build) first for the MT7922, then the alternatives in
[findings](findings/2026-11-18-macos-hardware-kexts.md).
**Why:** the only candidate that is native (Wi-Fi menu), Tahoe-ready, lists `14c3:0616` and is actively maintained.
**Revisit:** if it is unstable, or if a card swap becomes an option.

## 2026-11-18: Docs and agent workspace

**Decision:** `docs/` is for humans and LLMs (public, stable). `.agents/` is the agents' working area (TODO,
findings, decisions, runbooks). `CLAUDE.md` holds the rules, and `AGENTS.md` is a symlink to it for other agents.

## 2026-11-18: The EFI is generated, not hand-edited

**Decision:** `efi/build.py` builds the EFI from pinned, hashed downloads, OpenCore's own `Sample.plist` and a
machine JSON with stages (`install` -> `base` -> `vermilion`). SMBIOS serials live in `~/.config/vermilion` only.
Codeless kexts are kept as plist source in the repo.
**Why:** reviewable diffs, reproducible builds, one-change-per-boot stages, and no secrets in git. Other machines get
their own JSON.

## 2026-11-18: `ResizeAppleGpuBars = 0`, Resizable BAR stays on

**Decision:** keep ReBAR on in the BIOS (Linux uses the 32 GB BAR). OpenCore makes macOS see the default BAR sizes.
**Why:** Vermilion maps BAR0 as its VRAM window and was validated with 256 MiB. OpenCore 1.0.8 accepts only -1 or 0.
**Revisit:** if macOS hangs at PCI configuration, turn ReBAR off as a test.

## 2026-11-18: Fix the DSDT from the machine's own dump, at build time

**Decision:** replace the firmware DSDT with a fixed copy that `efi/build.py` makes from the machine's own dump
(`acpi-dump`) using `efi/acpi/fix_dsdt.py`, with `RebaseRegions` on. The dump stays in `~/.config/vermilion`.
**Why:** an SSDT can't help when macOS rejects the DSDT itself. A DSDT is ASUS's copyrighted table and is tied to one BIOS
version, so the repo keeps the generic fixer, not the table. The fixer is generic, so other AM5 boards with the same
firmware pattern can use it.
**Revisit:** after a BIOS update (dump again), or if OpenCore gains a quirk for deferred module-level code.

## 2026-11-19: GPU before the rest of Phase 1; install Vermilion from Recovery via the EFI partition

**Decision:** the owner put Phase 2 (Vermilion) ahead of Wi-Fi, Ethernet, Bluetooth and the USB map, because the
desktop without a GPU driver is unusable (WindowServer's software compositor at 30 Hz,
[findings](findings/2026-11-19-first-desktop-logs.md)). The files reach the macOS Data volume without the desktop:
Linux stages them on the EFI partition (`tools/phxctl/esp_stage.sh`), and one command in Recovery's Terminal installs
them (`tools/phxctl/recovery_install.sh`). Flags for later boots come the same way: the boot daemon got a generic
pre-start hook (`~/gpu/phxboot-pre.sh`), and on this machine that hook is `tools/phxctl/esp_flags.sh`, which takes
`phxboot-*` files from `<EFI>/vermilion/flags/`. The `vermilion` EFI stage inherits `install`, not `base`, so the
first Vermilion boot doesn't also bring in the untested Wi-Fi kext.
**Why:** Linux can't write APFS, and Recovery can (it has every tool the script uses, checked in BaseSystem.dmg). The
hook keeps the daemon unchanged when absent (169/169 mock scenarios, plus 3 new ones), and lets Linux arm a desktop
boot or set a kill switch between boots without anyone typing in macOS.
**Revisit:** once the accelerated desktop works, flags can be set in macOS directly again; the hook stays useful for
soak tests from Linux.

## 2026-11-19: Desktop-arm boots by file, not by NVRAM, while DisableVariableWrite is on

**Decision:** arm the accelerated desktop with `~/gpu/phxboot-desktop` (staged through the EFI partition), not with
`nvram phxfb-squat=1`. Never inject `phxfb-squat` through OpenCore's `NVRAM > Add`.
**Why:** `DisableVariableWrite` (needed for the installer on this board) blocks macOS's NVRAM writes to the firmware,
so a squat request set in macOS does not survive the reboot (unverified whether it even reads back in the same boot).
An OpenCore-injected `phxfb-squat` would come back at every boot, and the daemon's failure path, which clears it and
reboots onto the firmware framebuffer, would loop. The file-based arm is a supported daemon path (`DESK=1` without
`SQUAT`); `phxfb-boot`, which the daemon sets in the same boot, is the open question for the first desktop-arm boot.
**Revisit:** test whether macOS runs stable with `DisableVariableWrite` off after the install; then the squat path and
`phxboot-auto` work as upstream documents.

## 2026-11-19: GPU-present slots for frames over 8 MiB go above BAR0 (256 MiB), chosen by frame size

**Decision:** VermilionBoot b126 keeps b44's three 8 MiB slots at 24/32/40 MiB for frames up to 8 MiB and gives
larger frames (up to 32 MiB) three 32 MiB slots at 256/288/320 MiB, only when the VRAM and the display's FB window
(DCN_VM_FB_LOCATION_TOP, as the GOP left it) reach 352 MiB (`PhxScanLayout.h`).
**Why:** three 14.06 MiB slots fit no hole inside the 256 MiB BAR without moving the PSP ring, the TMR, mesboot or the
page-table pool, which the XT's working layout relies on. A slot needs no CPU view (the GPU writes it through the
client's PTEs, HUBP0 reads it by MC address), and nothing in Vermilion uses VRAM between 240 MiB and the firmware's
regions at the top. Choosing by frame size leaves the XT at 1080p exactly as before (detect, don't overwrite).
**Cost:** `debug.phxshot` can't read a large slot through the BAR (it returns EINVAL while GPU present shows one).
**Revisit:** if the GOP's DCN window turns out smaller than 352 MiB, program DCN_VM_FB_LOCATION_TOP as Linux's
`hubbub3_init_dchub_sys_ctx` does, or fit the slots below 256 MiB by shrinking the page-table pool.

## 2026-11-19: The `vermilion` stage inherits `base`; AirportMtkWlan 2.1.6 with MaxKernel 25.99.99

**Decision:** re-parent the `vermilion` EFI stage from `install` onto `base`, so the booted EFI gains exactly one
kext, AirportMtkWlan 2.1.6 (Tahoe build), pinned to kernel 25.x (`max_kernel` in `components.json`, now honoured by
`build.py`). Use 2.1.6, not the 2.2.x that the kext's README describes. Its Bluetooth companion is a separate,
later step.
**Why:** the owner wants Wi-Fi first; `base` exists exactly for this, and the stage chain keeps the one-change-per-
boot rule visible in the diff. 2.2.x was pulled by its maintainer after panics; the Tahoe build is not meant for
other kernels.
**Revisit:** if Wi-Fi destabilises the GPU path (then `vermilion` back onto `install`), or when a newer release is
recommended.

## 2026-11-19: Work moves to macOS; boot straight into it, with a Linux reboot guard

**Decision:** the owner works in macOS from now on. Firmware boot order OpenCore first, default OpenCore entry
Macintosh HD, auto-login and T3 Code at login (set by the owner in macOS). A systemd unit on Linux sets
BootNext=Limine on every Linux reboot. Sleep is turned off by `pmset` from a run-once.
**Why:** faster iteration without the Linux round trip. With OpenCore first, a warm Linux reboot would otherwise
start macOS on a GPU amdgpu left initialised (hard rule 1); the guard keeps a reboot in Linux and leaves a power-off
alone. No GPU resume path, so no sleep.
**Revisit:** when the VFIO phase starts (the iGPU becomes the host display), or if the firmware ignores BootOrder.

## 2026-11-19: Wi-Fi driver: MtkWirelessWifi 1.1.1 after AirportMtkWlan 2.1.6 didn't attach

**Decision:** the `base` stage adds Dino-VN/MtkWireless's `MtkWirelessWifi` 1.1.1 instead of AirportMtkWlan 2.1.6.
The boot that tries it also captures the IORegistry of the card's port, so a second failure is diagnosable.
**Why:** AirportMtkWlan loaded but never attached on boot 1, and an injected kext leaves no readable text in the
unified log. MtkWireless is the only candidate tested on this exact macOS build and SMBIOS. The alternative fix on
the table, AMD_Vanilla's `IOPCIIsHotplugPort`, changes PCI enumeration for the GPU too and needs evidence first.
**Revisit:** if MtkWireless doesn't attach either (then the IORegistry decides), or once AirportMtkWlan reports an
RZ616 working on 26.7.1.

## 2026-11-19: `pci=0x8000000` on this machine: macOS keeps the firmware's PCIe tag settings

**Decision:** the `base` stage boots with `pci=0x8000000` (`kIOPCIConfiguratorDefaultETF`), and Wi-Fi uses
MtkWirelessWifi 1.1.1.
**Why:** IOPCIFamily otherwise sets 10-Bit Tag Requester Enable on the chipset root port (GPP7); the MT7922 and the
I225-V can't complete 10-bit tags and stop answering. Linux leaves that bit off. AMD_Vanilla's binary patch for the
same thing is enabled but didn't keep the bit off on 26.7.1. A boot-arg that uses Apple's own switch is simpler than
fixing a byte pattern. Verified: Wi-Fi at 802.11ax, Vermilion unaffected.
**Revisit:** if a future IOPCIFamily drops the flag, or if the GPU path turns out to want 10-bit tags (then a
per-device fix instead). Other AM5 boards with these two chips likely need the same; worth upstreaming as a note.

## 2026-11-19: GPU present uses E3 (CoreDisplay's display surfaces) on this machine, behind a daemon flag

**Decision:** the XTX machine runs GPU present with `ws-gpu-present-async` and `NVMTL_WS_PRESENT_CDCOPY=1`. The boot
daemon sets the variable from the flag `~/gpu/phxboot-wscdcopy` before its WindowServer restart. The plugin default
stays as it is, so the upstream XT keeps its behaviour.
**Why:** the default mode presents SkyLight's composite targets, which only have the changed regions redrawn: those
regions flickered (verified, 1440p60). E3 fixed it on the first boot it ran
([findings](findings/2026-11-19-gpu-present-flicker-heat.md)). A flag was the smallest change that survives reboots:
`launchctl setenv` is how the daemon already passes `CI_USE_MTL_DAG_FOR_CIKL_SRC`, and the plugin needs no rebuild.
**Revisit:** when the plugin is rebuilt: a file switch next to the other `ws-*` switches would replace the variable,
and E3 may deserve to be the default for GPU present on every card (needs a test on the XT).

## 2026-11-19: the fence wait's timed step is 200 us on the XTX machine, behind a daemon flag

**Decision:** the boot daemon sets `debug.phxwait_step_us` from the flag `~/gpu/phxboot-waitstep` (its content, empty
= 200, 20-1000 accepted) before its WindowServer restart. The XTX machine uses 200. The kext's default stays 50, so
the upstream XT keeps its behaviour.
**Why:** with IRQ waits off, every fence wait longer than 20 us sleeps in timed steps; at 50 us WindowServer woke
640-2500 times/s. 200 cut that 5-15x and was not worse than 50 in a blind A/B on the XTX machine
([findings](findings/2026-11-19-gpu-present-flicker-heat.md), live tests 3-4). It costs ~240 us more per waited
fence. A flag is the smallest change that survives reboots, with no kext rebuild. Its effect on heat is unverified
(no CPU temperature reading yet).
**Revisit:** once CPU temperature or package power is readable, or if the IRQ wait path is verified on the XTX
(then the step only matters as its fallback); growing steps in the kext (50, 100, 200) if a lower latency is wanted.


## 2026-11-19: the full EDID read is a separate sysctl first (b127), the served EDID stays 256 bytes

**Decision:** VermilionBoot b127 reads EDID blocks 2-3 only in a new root sysctl `debug.phxedid_full`. `readEdid`,
`debug.phxedid` and the 256-byte EDID PhxAMDFB serves (`phxEdidRead`) are unchanged.
**Why:** serving 384 bytes changes the PhxBringup/PhxAccel interface (`phx_head1_hotplug.edid[256]`, PhxAMDFB's buffer),
so both kexts would have to change in the same boot (EFI and AuxKC: two changes in one boot). The first goal is only
to see the LG's block 2 (the 240 Hz timing), and a sysctl does that with one kext and no change at boot.
**Revisit:** once the segment read works on hardware and the 240 Hz work starts (macOS then needs block 2 to list the mode).

## 2026-11-20: 1440p high refresh on the XTX: 120/144 Hz first on the firmware's HBR2 link, then 240 Hz

**Decision:** b128 adds 1440p 60/120/144 pipe-0 plans (firmware DTO convention, Linux's timing / DLG values from the
2026-11-20 capture, depth 12 -> 10 / 8 bpc), and the pipe-0 engine sends the two DAL hard minimums Linux sends for them
(DISPCLK and DPPCLK `SetHardMinByFreq`, 505 / 614 MHz; owner's OK 2026-11-20), never lowered, nothing else from Linux's DAL
list (0x14 stays blocked). 240 Hz (HBR3 retraining of DP B + DSC) is the next, separate step on top.
**Why:** 120/144 fit the HBR2 x4 link the firmware trains, so they need no link training, the riskiest part. Every piece
(plans, clock step, DET step, mode list) is also needed at 240 Hz.
**Revisit:** if the engine's underflow check fails at 144 with the firmware's watermarks (then Linux's watermark sets A-D).

## 2026-11-20: 240 Hz uses Linux's exact configuration (HBR3 + FEC + DSC + ODM 2:1)

A single pipe without DSC would fit the link at 8 bpc (inferred) but needs a DPPCLK minimum and HUBP values Linux never
used on this card, and gives no HDR at 240. Linux's configuration is fully captured (registers + DMUB commands), covers
10 bpc, and keeps the rule "nothing Linux doesn't send". The link work is staged: retrain at HBR2 first, then HBR3 at
144, then 240. Details: `.agents/findings/2026-11-20-240hz-plan.md`.

## 2026-11-20: every 1440p rate is a Linux replay through Linux's 144 (b135)

The 1 ppc pipe-0 plans (b128) and the Linux replay (b131-b134) left pipe 0 in two different setups that neither could
leave. b135 makes Linux's own 144 the hub: each rate is Linux's switch from 144 and back (capture v3), so every transition is
two recorded Linux mode sets and no start state is guessed. macOS's own state keeps the b128 plans until the first 240 (the
only entry, b133's verified plan). Other resolutions, VRR and HDR join the same set from the same capture.

## 2026-11-20: A squat boot that can't leave the squat runs a safe desktop, never another reboot

**Decision:** when a reboot meant to clear `phxfb-squat` comes back squatting (`~/gpu/phxboot-nvstuck`), the daemon
stops rebooting. With the kill switch, an unfinished attempt or a failure marker, it runs a safe desktop on the squat
(CPU copy at the boot mode; no pipe-0 mode list, GPU present, flip, M7, b15, VCN). If that attempt doesn't finish, the
next boot stays headless (no attempt, no reboot). `DisableVariableWrite` stays on (owner's choice).
**Why:** with `DisableVariableWrite` macOS can't delete the variable, so every recovery reboot came back to the same
squat: three reboots in a row on 2026-11-20 until Linux deleted it. A squat boot has no display except PhxAMDFB, so a
plain PhxAMDFB desktop is the only way to a picture without leaving macOS.
**Revisit:** if `DisableVariableWrite` goes off, the first recovery reboot clears the squat as upstream designed and the
safe desktop never runs.

## 2026-11-20: Adaptive Sync through Linux's OTG register path, offered by default

**Decision:** VRR on the XTX machine uses Linux's DCN 3.2 register path (OTG_V_TOTAL_MAX, MIN, CONTROL, and
OTG_TRIGA_MANUAL_TRIG per flip), never the DMUB FAMS command, and PhxAccel offers "Variable" by default when the monitor
and PhxBringup support it (opt-out `~/gpu/phxboot-novrr`).
**Why:** Linux on this card used the DMUB FAMS command, but only because its own firmware reports fw-assisted mclk
switching. The GOP's DMCUB build that runs on macOS reports none (`debug.phxdmub_caps`), so Linux's code would take the
register path on it, and PhxDmub.h forbids FAMS commands to that firmware. Box-verified 2026-11-20 (OTG0 52-188 Hz with the
content). Default on: the offer needs the LG's 240 Hz DisplayID timing, which the XT's monitors don't have.
**Revisit:** if Linux's firmware ever runs on macOS, or for the CPU-copy sizes (no per-flip trigger there yet).

## 2026-11-22: Adaptive Sync floor 60 Hz by default, configurable

The LG flickers in Variable near its EDID minimum of 48 Hz (owner; the same on Windows and Linux, so the monitor's VRR:
brightness swings between long and short frames). The common fix on any OS is a higher floor (owner's reading, findings
2026-11-20-adaptive-sync-research.md). PhxAccel's `debug.phxfb0_vrrmin` (default 60) sets System Settings' range, the
twin's verticalBlankingExtension and, through "phxVrrSet" io bits 8-15 (PhxBringup b146+), OTG0's V_TOTAL_MAX: the menu,
macOS's pacing and the hardware agree. With an older PhxBringup the EDID's minimum stays everywhere (the menu must match
what OTG0 does). The boot daemon's `~/gpu/phxboot-vrrmin` changes it (0 = the EDID's).

## 2026-11-22: the DRR double buffer is on only while Adaptive Sync's range is on

Linux runs every OTG with `OTG_DRR_TIMING_DBUF_UPDATE_MODE` = 2 from driver load; the GOP leaves 0, and the mid-frame
window changes that follow raised HUBP0's underflow sticky (findings 2026-11-22-vrr-underflow-and-auxkc.md). b150 sets
Linux's 2 when the range goes on and puts the boot value back when it goes off, after the off values have latched.
Not chosen: mode 2 for the whole boot, as Linux has it. The replay plans were captured on Linux under mode 2 but have only
ever run here under mode 0 (their V_TOTAL / H_TOTAL writes would latch at a frame start instead of at once, around an OTG
that the plans stop and start), and a plan that goes wrong blacks the owner's only screen. **Revisit:** if a plan is ever
shown to need the double buffer, or once a plan run under mode 2 has been tried on the box.

The replay engine's failed latch stays (one failed run = nothing more until reboot: no plan knows the state). What changed
is what counts as failed: an underflow sticky from before the run is cleared and not held against it, and a sticky raised
during the switch gets one clear and one more full post check.

## 2026-11-22: no VRR / HDR below 1440p; the other resolutions stay as fixed rates

The owner runs only 2560x1440, where every rate, Variable (60-240 Hz, ramp), 10-bit HDR and Variable + HDR work on the box.
VRR and HDR at the other sizes would need a CPU-copy trigger, per-size twins and a Linux capture per HDR mode: dropped.
The other resolutions are left on (fixed rates): they work, cost nothing at 1440p and serve other machines.

## 2026-11-22: the pre-merge clean-up is proven by identical binaries; the 10-bit pixel helper stays in two places

The clean-up of `ownback/gpu-refresh-hdr` was held to "no behaviour change" by a check, not by review: both kexts and
the Metal plugin build reproducibly, so each cleaned source had to produce the sha256 of the binary installed on the
XTX machine (VermilionBoot b150 3806555e..., VermilionAccel c6341e87..., NVMTLDriver 7f46d89b...). A tidy-up that moved
the machine code was taken back (a hoisted condition in `scanPresent`, a hoisted assignment in `PhxAMDFB::start`).
Consequence: sysctl description strings, log texts and non-static names were left as they are, also where a better
name exists (`phxVrrOids` registers four sysctls now). `PHX_KEXT_BUILD` stays 150 and nothing was reinstalled.

`bgraTo2101010` exists twice: `phxhead::bgraTo2101010` (PhxAccel, C++) and `nvmtl_bgra_to_2101010` (Metal plugin, C).
Both are PolyForm Noncommercial, so the licence would allow one shared header. They stay apart because the plugin is
built without any kext header and mirrors the kernel ABI by hand already; one four-line function does not justify the
first include across that line. Both comments name the other copy. **Revisit:** when the plugin gets a shared ABI header.

## 2026-11-22: USB map with USBToolBox, kept as a codeless kext source in `efi/kexts/`

**Decision:** map USB with USBToolBox 1.2.0 and a hand-written `UTBMap.kext` (`efi/kexts/UTBMap.kext`, matched by
the controllers' ACPI names), in the `base` stage. Keep every rear port, the internal audio and Bluetooth ports and
the unknown internal port 17; leave out the front-panel headers (no front panel) and the AURA LED controller.
**Why:** the firmware's `_UPC` marks the audio and Bluetooth ports not connectable, so macOS never created them;
USBToolBox detaches the ACPI ports and takes the ports from the map alone. A codeless kext in the repo keeps the map
reviewable and reproducible like the rest of the EFI (no tool-generated binary). Verified on the XTX machine
2026-11-22 ([findings](findings/2026-11-22-usb-map.md)).
**Revisit:** if a front panel is added (ports 2-4 / 7-9 / 13-14), if a USB 3 device shows a wrong pairing, or after
a BIOS update (port numbers can change).

## 2026-11-22: CPU sensors with SMCProcessorAMD; no AMDRyzenCPUPowerManagement

**Decision:** read the CPU's temperature and package power with macos86/SMCProcessorAMD 1.0.1 (a VirtualSMC
plugin, `base` stage). Leave CPU power management as it is (`DummyPowerManagement`, the CPU's firmware decides
clocks and idle).
**Why:** AMDRyzenCPUPowerManagement, the usual recommendation, replaces the kernel's CPU power-management dispatch
and rewrites the P1 P-state definition MSR at load with a formula for older Ryzen parts; its Tahoe fork also reads
and writes the GPU's registers on a timer, which would race Vermilion. SMCProcessorAMD only reads (binary
disassembled: no `wrmsr`, no port I/O, one SMN index write as Linux `k10temp` does). Verified on the XTX machine
([findings](findings/2026-11-22-cpu-sensors.md)).
**Revisit:** if OS-level P-state control is ever wanted (then a Zen 4-correct implementation, tested on its own
boot), or if per-core clocks are needed.

## 2026-11-22: Bluetooth with MtkWirelessBT (same package as the Wi-Fi driver)

**Decision:** MT7922 Bluetooth through Dino-VN/MtkWireless's `MtkWirelessBT` 1.1.1 + acidanthera BlueToolFixup
2.7.2 + the two NVRAM variables it documents; `efi/build.py` gained `nvram_add` per stage for those.
**Why:** it ships in the MtkWireless release already pinned for Wi-Fi, lists this board's USB ID, and documents
26.7.1 25G241 x86_64 as tested; the alternatives were pulled (AirportMtkWlan's companion) or older and would need the
ID added by hand (SimpleMtkBtFw). Verified on the XTX machine: AirPods pair and play
([findings](findings/2026-11-22-bluetooth.md)).
**Revisit:** after any macOS update (it patches bluetoothd by signature), or if bluetoothd starts crash-looping.

## 2026-11-22: Security posture target = a real Mac; replace `amfi=0x80` with a scoped allowlist

**Decision:** the owner's bar (2026-11-22) is that the machine behaves like a fully supported Mac, so every security
relaxation is a bug to remove, not a documented cost. Thread 05's order: (1) security data updates on
(`ConfigDataInstall = 1`, done 2026-11-22), with macOS and Rapid Security Responses still pinned (`CriticalUpdateInstall = 0`);
(2) replace the global `amfi=0x80` with a small kext of our own that allows library validation **only for the cdhashes
of Vermilion's own code** (plugin, translator, RADV, decoder) and leaves AMFI on for everything else; (3) with thread 00,
inject `VermilionAccel` from OpenCore instead of the AuxKC, so SIP's kext bits can go; (4) SIP back towards `0x0`
and authenticated root on; (5) then Apple Secure Boot (`SecureBootModel`) and FileVault, each on its own boot.
**Why:** `amfi=0x80` is AMFI's `ALLOW_EVERYTHING`: every process skips library validation and accepts invalid
signatures, tccd treats third-party apps as platform binaries (no camera / mic prompts), and FairPlay refuses.
AMFIPass doesn't help Vermilion: it trusts only code signed with Dortania's key (OCLP), and our plugin is ad-hoc
signed, which is why upstream added `amfi=0x80` on top. A cdhash allowlist keeps the property a real Mac has, that
root can't load unsigned code into platform processes, and Vermilion stays loadable.
**How (proposed, unverified):** a Lilu plugin routes XNU's `mac_file_check_library_validation` (public XNU source,
symbol in the kernel's linkedit, which `DisableLinkeditJettison` keeps). If the mapped file's cdhash is in a list
fixed at boot (the kext's Info.plist or an OpenCore NVRAM variable, never writable from a running system), it
returns 0, else it calls the original. First a log-only boot with `amfi=0x80` still set, to show that the hook
fires and the list is complete. Then one boot without `amfi=0x80` (rollback: `EFI/OC.prev`). A `-phxtrustoff` boot-arg
turns it off.
**Revisit:** if Apple's AMFI on 26.7.1 enforces library validation somewhere the MAC hook doesn't see, or if Vermilion
gets a real signing identity.
**Result (2026-11-22 23:45, XTX machine):** implemented as `src/vermilion-trust` (it wraps AMFI's own
`file_check_library_validation` / `file_check_mmap` / `file_check_mmap_downgrade` entries in its MAC operation vector,
not XNU's MAC framework functions, so other policies such as Sandbox keep their say). Booted without `amfi=0x80`:
accelerated desktop works, AMFI enforces, third-party apps lose `CS_PLATFORM_BINARY`. Cost: the cdhash list must be
rebuilt with every plugin / translator / RADV build.

## 2026-11-23: One source of truth per kind of fact; `vermilion-trust` is the default stage

**Decision (thread 00, Housekeeping):** `ROADMAP.md` holds the thread series, the rules and the known limits;
`.agents/TODO.md` only open tasks grouped by series thread; `docs/PROJECT_KNOWLEDGE.md` only the current state, the
known-good configuration and the performance record; `.agents/OWNER-TESTS.md` the owner's test list. The old TODO
(daily logs, done items, the Phase plan) is frozen as a finding. The machine profile gets `default_stage:
vermilion-trust`, and `efi/build.py` builds it when `--stage` is not given.

**Why:** six threads appended to the same files in turn on 2026-11-22/23 and nobody reconciled them: the knowledge
file said the everyday EFI was `vermilion` with `amfi=0x80` while the machine booted `vermilion-trust`. A default
stage of `install` made an accidental `build` / `install` without `--stage` the installer EFI.

**Correction to 2026-11-22 "Security posture target":** its "FairPlay refuses" under `amfi=0x80` is unproven (Music's
failure was `en0`; TV's is the missing protected decoder), and the VermilionTrust sanity check does not make a shifted
AMFI layout fail safe (the old thread 05's final report): no macOS update before thread 09's layout check.

**Rename (same day, owner's OK):** `ownback/vermilion` became **`ownback/vermilion-xtx`** (`gh repo rename`; GitHub
redirects the old URLs; the `fork` remote points at the new name). It is the GPU driver fork and still supports the
XT; the EFI generator moves to `ownback/ryzentosh` in thread 10. Kext, class, sysctl and path names don't change
(docs/NAMING.md).

## 2026-11-23: A failed DP link is retried as Linux does; a failed fall-back runs once more; the daemon restarts once on a dark display

**Decision (thread 01):** VermilionBoot b151's replay engine trains every link window with Linux's own retry rule for a
PHY endpoint (4 attempts at the plan's link, link off and 100 / 150 / 200 ms between: `perform_link_training_with_retries`,
findings 2026-11-23-gpu-stability.md section 2), and runs a from plan that failed (the fall-back, or the leg to the hub)
once more, at most twice per boot (`kMaxRecoveries`). Only a from plan that fails again, a halt or a DMUB timeout latch
the engine. The boot daemon reads the engines' latches during its crash watch: a latched engine is `DARK`, not
`SUCCESS`; it saves the engines' state and restarts once (`/var/db/phxboot.darkrestart`); a second dark boot in a row
stays up and reports.

**Why:** one failed login switch (2026-11-22 20:19) left the only screen black until the owner restarted by hand, and
the daemon said `SUCCESS`. Linux would have retried the training three more times before giving up; the engine tried
once. A from plan is Linux's full sequence into the hub, so running it again from a half-done state sends nothing Linux
doesn't send. A restart is the one recovery that works from any state, and at the login switch nothing is lost.

**Not chosen:** a lower link rate on failure (Linux doesn't fall back for a conventional DP link at mode set, and the
plans need their rate); unlocking the engine without a plan that knows the state (no plan does); a restart loop (the
record stops it); a restart on a fall-back to 144 (the picture is there).
**Revisit:** if the restart ever hits a session in use (a switch inside the 2-minute watch after login), or the same
plan fails at every login.

## 2026-11-23: The NVRAM test is its own stage; `phxboot-auto` before it

**Decision (thread 01):** `efi/build.py` stages can override booter quirks; `vermilion-trust-nvram` is `vermilion-trust`
with `DisableVariableWrite` off. One boot tests it (a test variable written and read back, a restart). Before that boot
`~/gpu/phxboot-auto` is created, so the daemon re-arms `phxfb-squat` after the squatter's (then real) delete.

**Why:** the quirk is the reason no panic report is ever saved, and it is why `phxfb-squat` can't be cleared from
macOS. It went in against the macOS installer's hang on Ryzen 7000 boards, which says nothing about small runtime
writes. Without `phxboot-auto` the boot after the test would be a GOP boot without acceleration
(findings 2026-11-23-gpu-stability.md section 4).
**Revisit:** if writes hang or the firmware misbehaves: back to `vermilion-trust` and photos of the panic screen.

## 2026-11-23: the VRR floor stays in the EDID PhxAccel serves (label "Variable (60-240 Hz)")

**Decision (owner, thread 01):** keep PhxAccel's floor patch, so System Settings names the range with the real floor.
The cost: macOS identifies a display by its EDID, so a floor change makes it a new display (colour profile and
per-display settings start over; [XTX.md](../docs/XTX.md)). The floor is fixed at 60 now, so this only happens when
someone changes `~/gpu/phxboot-vrrmin`. Not chosen: drop the patch (identity never changes, but the menu would say
48-240 while the floor stays 60). **Revisit:** if the floor has to change often.

## 2026-11-23: a switch whose last link window needed a retry runs again; DPCD accesses retry as drm does

**Decision (thread 01):** b154 runs a switch once more from the target when its last link window trained only after a
retry (once per run, at most 4 per boot), because the LG once kept a black picture on a locked, in-sync link after such
a retry and a new mode set brought it back (finding 2026-11-23-gpu-stability.md section 8). Nothing on the GPU side
tells that black state apart, so the rule acts on the retry itself. b155 gives the trainers' DPCD accesses drm's
32-try rule (Linux's DC path), which should make the retries themselves rarer (unverified until the b155 boot;
afterwards: it did not, the LG NACKed all 32 tries at one boot, finding section 11).
Not chosen: detecting the black picture (no readable signal for it), or a fixed redo after every HDR switch (an extra
~1.5 s blank each time). **Revisit:** if a later build removes the first-attempt AUX misses, b154's redo becomes a rare fallback;
keep it.

## 2026-11-23: the RX 7900 XTX runs Mesa's own `navi31` profile, chosen by PCI revision

**Decision (thread 02):** patch 0018 reads the `revision-id` of the PCI device under NMXAccel (or PhxBringup) and takes
Mesa's `navi31` entry for 0xC8; every other revision, and an unreadable one, keeps `navi31_xt`. A new hand-made
`navi31_xtx` entry was the plan in XTX.md, but Mesa's `navi31` already is an XTX, and a field diff shows it differs from
`navi31_xt` only in the harvest (the XT entry was made from it). Linux's `gpuinfo` from this card checks the harvest
fields (handoff 1c). Measured side-loaded: pixel shading 19 % faster, nothing slower (finding 2026-11-23-perf-power.md
section 5). Not chosen: `RADV_DARWIN_CANNED=navi31` from the daemon (the VCN shim's exact-name check; and a launchd
variable would reach every process, including the ones that must not change). **Revisit:** a third Navi 31 board
(another revision) gets its own entry next to these.

## 2026-11-23: interrupt fence waits stay off for now

**Decision (thread 02):** the IH ring, the MSI and `debug.phxwait_irq` work on the XTX (live test, 1.19 M interrupts,
no storm), and the median waited short job halves, but the 99th percentile got 1.5-4 ms worse and the second test set
was spoiled by a video app. They stay off at boot until an interleaved A/B on an idle desktop explains the tail. Not
chosen: a daemon flag now. **Revisit:** with the owner's OK for a quiet GPU test; the tail's likely cause is a waiter
re-sleeping a full deadline after an EOP of another submission.

**Superseded the same day:** the quiet interleaved A/B (06:25-06:30) showed the interrupt wait better in median and
p99 in every row, the worse tail having come with the second GPU client. They are a daemon flag now
(`phxboot-irqwait`, `irqwait_boot`), on at boot on the XTX machine since 07:51. Evidence:
[perf finding](findings/2026-11-23-perf-power.md) section 4.

## 2026-11-23: VRAM-backed buffer objects, opt-in per process first

**Decision (thread 02):** the design in findings/2026-11-23-vram-bo-design.md: a VRAM pool from 512 MiB to below
Linux's reserved regions, only for `NO_CPU_ACCESS` BOs, cleared by the GPU before use, behind `debug.phxbo_vram` that
first admits only named test processes. Not chosen: a big-bang switch for WindowServer (a bug there is a black
desktop), CPU-visible VRAM (BAR0 is 256 MiB with `ResizeAppleGpuBars = 0`). **Revisit:** after the Linux bandwidth
number and the VRAM reservations.

## 2026-11-23: a plugin/RADV EFI change rides on the cold boot back from Linux

**Decision (thread 02):** the owner wants few restarts. The trust list of 1.0.4 is built from the new files in the
build folder plus the installed list (`PHXTRUST_KEEP=1`), so the files and the EFI can go in together minutes before the
owner shuts down for the Linux run; the boot back from Linux (a power-off, so a cold GPU) is change 15's one boot. The
Linux boot itself goes through Limine (F8), not OpenCore, so it is not an OpenCore boot of either change.

## 2026-11-23: no `_CST` CPU idle kext (thread 02)

Linux on the same machine and BIOS (all C-state / CPPC / PBO settings Auto, owner's photos) tops out at 5.16 GHz on the
frequency CCD and idles at 37.8 W package with CC6 98 % of the time; macOS reaches 5.02-5.12 GHz and idles at
39.5-41.3 W. A kernel extension that enters CC6 through the firmware's `_CST` would gain ~2-3 W and adds a new
kernel component in the idle path. Not built; revisit only if a later measurement shows a bigger gap (for example at
sleep, thread 05). Evidence: [perf finding](findings/2026-11-23-perf-power.md) section 8.

## 2026-11-23: idle clocks free on one display, under a watchdog (thread 02)

The daemon's UCLK pin at 456 MHz (upstream's mitigation for a UCLK switch underflowing the display without the DAL
hand-off) costs ~30 W at idle on the XTX machine. With the hand-off Linux does (the DAL watermark table, then UCLK
unpinned, the FCLK switch allowed, DCFCLK 199 / deep sleep / one display), 20 minutes at 1440p240 HDR showed no underflow
and 53.5 -> 23.5 W socket; under load nothing got slower. `idle_dpm.sh` (flag `phxboot-idledpm`) applies it once the
desktop settled and keeps upstream's watchdog for the whole boot: the first underflow re-pins 456 for the rest of the
boot. Not combined with `b15` (the XT's own recipe) and not after a pipe-1 boot. Every message is one Linux sends on this
card. Evidence: [perf finding](findings/2026-11-23-perf-power.md) section 9.

## 2026-11-23: GPU work targets Linux parity in every workload, not single apps

**Decision:** thread 02 part C and later GPU work rank fixes by how many apps they speed up: the present path (app
frames in system memory, WindowServer's composite), per-submission overhead in the plugin, VRAM BOs for every
process (M3), the 6 GiB heap and working set, CPU-visible VRAM (Resizable BAR), OpenGL / OpenCL on the GPU.
Cross-platform workloads with a Linux twin (Horizon's `horizon-ctl bench`, vkbench / metalbench, later browser
WebGL / WebGPU and others) are the measuring sticks.
**Why:** the owner wants macOS "just as performant as Linux in any game, application, workload" (2026-11-23); Horizon
was installed only to compare (160 fps on macOS vs 4370 on Linux, same view).
**Revisit:** when a measuring stick disagrees with the others (a cause that only one app hits).

## 2026-11-23: BAR0 1 GiB for macOS (`ResizeAppleGpuBars` 10), replacing 0

**Decision:** a stage `vermilion-trust-bar1g` resizes the GPU's BAR0 to 1 GiB for macOS (OpenCore Booter quirk
`ResizeAppleGpuBars` 10), first with the kext unchanged (one boot to prove macOS takes it), then the kext places
CPU-visible client BOs in real VRAM inside the window ([256 MiB, 1 GiB) minus the scan slots), instead of system
memory behind a 256 MiB budget as today (`kVisTotal`, "E1 backs every BO with system memory").
**Why:** the owner wants Linux parity in every workload (decision above). On Linux, Resizable BAR (on in the BIOS)
makes all 24 GiB CPU-visible and RADV puts mappable buffers in VRAM; on macOS every CPU-written buffer is read over
PCIe (Horizon's main pass: 2.35 ms against Linux's 0.22 ms frame). Apple's PCI support stops at 1 GiB (OpenCore docs),
so 1 GiB is the most macOS can get: 4x today, not 24 GiB. ocvalidate flags any value but 0 as "unstable with macOS
sleep-wake"; this machine has no sleep resume path, so the stage accepts that one message (`ocvalidate_accept`
in efi/build.py; any other error still fails the build).
**Replaces:** "2026-11-18: `ResizeAppleGpuBars = 0`, Resizable BAR stays on" for the vermilion-trust-bar1g stage; the
default stage stays at 0 until the stage is verified.
**Revisit:** if macOS fails PCI configuration or the desktop with 1 GiB; when sleep gets a resume path.

## 2026-11-23: thread 02 part C merges in milestones
**Choice:** one PR per systemic fix, merged once it is measured against a Linux twin (C1: GPU timing, aperture, BAR0
1 GiB, CPU-visible VRAM BOs; then e.g. shader / translator cost, the present path, per-submit overhead). After each,
ROADMAP row 02 says what is left, so it is clear when 03 can start. Translator shader-quality work stays in 02 while
it is the top cause. Each branch is pushed to `fork` under its own name (`git push -u fork <branch>`), never left local.
**Why:** coordination thread, 2026-11-23: one long branch is hard to review and loses work if the machine fails.
**Revisit:** if a fix can't be measured on its own.

## 2026-11-23: thread 02 ends at EFI change 22; the rest of performance becomes thread 13
**Choice:** no new fixes in 02 after the MoltenVK drawable fix (EFI change 22, booted). The remaining GPU, CPU and
per-app performance work is a ranked backlog in TODO, "13 Performance parity (after 09)", run as thread 13 after 09
and before 10 (series 03 → 04 → 05 → 06 → 07 → 09 → 13 → 10 → 11 → 12). 03 keeps the API-level work (Zink / OpenGL /
OpenCL on the GPU, VCN decode, WebGL). The per-draw / multi-draw plugin fix found with Minecraft is not built in 02.
**Why:** owner, via the coordination thread, 2026-11-23: the GPU phase should move on to the missing APIs and
features; doing performance last, before ryzentosh, lets ryzentosh pin the final driver.
**Revisit:** if a later thread is blocked by a performance gap (then that one item moves forward).

## 2026-11-23: the video decoder bundle goes onto the system volume

**Decision:** `PhxVideoDecoder.bundle` is installed into `/System/Library/Video/Plug-Ins` with `sysvol_install.sh`
(a new boot snapshot; Apple's sealed snapshot is kept), and `phxdec-av1` is set.
**Why:** the plugin's own registration runs when a process creates its Metal device, after VideoToolbox has chosen a
decoder: `VTDecoderXPCService` registered ours and still decoded with Apple's (thread 03, measured). Only a bundle
VideoToolbox reads at registry time is picked, and `/Library/Video/Plug-Ins` drops ad-hoc bundles. With the bundle,
an AV1 session our decoder refuses fails instead of falling back, so AV1 stays on (bit-exact on the AOM vectors).
**Cost:** the system volume is no longer sealed: macOS offers only full updates and an update removes the bundle
(thread 09 owns the update policy; ROADMAP rule 12 already blocks updates). Owner's OK, 2026-11-23.
**Revisit:** if a way to load an ad-hoc decoder from the Data volume early enough turns up (thread 09's sealed-system
goal), or once the bundle can be signed.

## 2026-11-23: the unsealed system volume is a 09 blocker; system-volume changes need the owner's OK

**Decision:** keep `PhxVideoDecoder.bundle` on the system volume for now (system-wide hardware decode is a Mac
feature), and record the unsealed volume as a blocker for thread 09 (ROADMAP row 09, TODO 09). From now on every
change to the system volume is asked for first; it is no longer a routine reversible step.
**Why:** the seal was broken because only a bundle VideoToolbox reads at registry time is used, and the one location
that keeps the seal, `/Library/Video/Plug-Ins`, drops ad-hoc bundles (decision above). That collides with 09's goals
(sealed system, SIP towards `0x0`, Apple Secure Boot) and the update path.
**Cost:** macOS offers only full updates (no delta updates) and the Mac no longer boots a sealed snapshot; an update
also removes the bundle. **Undo:** `sudo bless --mount / --last-sealed-snapshot` and a restart (Apple's sealed
snapshot `com.apple.os.update-590AC978...` is kept); set `phxdec-off` first, or AV1 sessions fail.
**Revisit:** when 09 finds a seal-keeping route (TODO 09 lists the candidates).

## 2026-11-23: the plugin lives under CoreTypes.bundle (firmlink), symlinked from /Library/GPUBundles

**Decision:** `relocate_gpubundle.sh` on the reference machine: `NVMTLDriver.bundle` and `nvmtl/` in
`/System/Library/CoreServices/CoreTypes.bundle/Contents/Library/PhxGPU`, symlinks in `/Library/GPUBundles`.
**Why:** Safari's WebKit GPU process may map executables only from system paths; from `/Library/GPUBundles` the
sandbox blocked the plugin, so Safari had no WebGL / WebGPU (measured). That directory is a firmlink into the Data
volume (`/usr/share/firmlinks`): no seal change, no `csr` bit. Every existing path keeps working through the symlinks.
**Revisit:** thread 06 (fresh-install path) installs there directly.

## 2026-11-23: the app-facing Vulkan stack is opt-in, outside the standard paths

**Decision:** the Vulkan loader and the RADV ICD with the window surface (patch 0020) go to `/usr/local/lib/vermilion`
and `/usr/local/share/vermilion/vulkan/icd.d`, used only with `VK_DRIVER_FILES`; not to `/usr/local/lib`, not to the
standard ICD folders, not to `/Library/GPUBundles/nvmtl/`.
**Why:** an app that finds a system loader would switch from its bundled MoltenVK to RADV, a behaviour change for
apps that work today; that switch, and the swapchain's speed (a host copy plus a Metal blit per frame), are thread
13's (TODO 13 item 6). The plugin looks for `libvulkan.dylib` / `radeon_icd.json` in `nvmtl/`, so nothing goes there.
Patch 0020 is under `VK_USE_PLATFORM_METAL_EXT`, so the plugin's RADV build stays the same code.

## 2026-11-23: OpenGL through Apple's OpenGL-over-Metal renderer, behind a daemon flag; Zink not pursued

**Decision:** OpenGL apps use `AppleMetalOpenGLRenderer.bundle` (shipped with macOS 26.7.1, x86_64 slice) on our
Metal device: VermilionAccel publishes `IOGLBundleName` when `debug.phxgl=1`, and the boot daemon sets it with the flag
`~/gpu/phxboot-gl` (set on the reference machine). Zink stays unbuilt.
**Why:** it is what a real Mac does (OpenGL on Apple silicon is this renderer), every OpenGL app gets it with no
per-app setup, and it worked on the first try: correct pixels, ~190x the software renderer on a small draw test,
Minecraft 26.3 playable (thread 03 finding section 8). Mesa's Zink has no CGL / NSOpenGL front end on macOS.
**Cost:** OpenGL speed and correctness now depend on our Metal plugin (its gaps show up in OpenGL apps too).
**Undo:** `sudo sysctl -w debug.phxgl=0` (new processes) and `rm ~/gpu/phxboot-gl` (from the next boot).

## 2026-11-24: DP audio merged with three sequencing differences from Linux

**Decision:** merge `ownback/dp-hdmi-audio` as it runs on the reference machine (EFI change 33) and fix the order in
follow-up work (TODO 04, "hw-safety review 2026-11-24").
**Why:** the hw-safety review found no wrong value, register instance or offset (the 90 writes equal Linux 7.2.15's
trace for the LG at 1440p240) and nothing that detaches a driver on the GPU's PCI functions. It found three
sequencing differences: the audio packet enables in `DP1_DP_SEC_CNTL` are set by the mode-set plans before the audio
setup, without Linux's audio-off steps; audio stays on through later pipe-0 mode sets, where Linux turns it off and
on around each stream change; `phxaudio apply` can race a p0odm mode set (not seen). The first two come from the
replayed display plans on main, which phase 3 replaces with the driver's own mode setting. Merging makes main match the
machine; holding it back leaves the live daemon unrecorded.
**Not sent, on purpose:** Linux's `DALSMC_MSG_BacoAudioD3PME` before the endpoint enable (no new SMU message).
**Revisit:** when VermilionBoot does its own mode set (phase 3), it does the audio off / on around each stream change.

## 2026-11-24: A warm GPU is refused, not reset

**Decision:** `bringup_navi31.sh` reads C2PMSG_81 before any write. If the PSP sOS is running, or the value can't be
read, it refuses: nothing is written and no watchdog is armed. The daemon then takes its fallback (the GOP revert on
a desktop boot) before the claim.
**Why:** the power-up is the cold-boot sequence, and on a warm GPU it loaded the SMU firmware into a running SMU, which
Linux never does (hard rule 1). On a warm GPU, Linux resets the ASIC at init instead: `soc21_need_reset_on_init` reads
the same register, then a Mode1 reset (an SMU message and PCI config writes; hw-safety-reviewer, 2026-11-24).
Refusing is the part of that we can do without adding a message.
**Revisit:** if a warm macOS restart turns out to leave the sOS running (the daemon logs `sOS check:` at every boot).
Then the warm restart needs Linux's Mode1 reset path, with its own hw-safety review.

## 2026-11-25: The daemon returns to the full desktop by itself (phase 2 item 3 step 1)

**Decision:** the boot daemon keeps its failure record in `/var/db/phxboot.fails` (root-owned, written only by it) and
no longer creates the kill switch or `~/gpu/phxboot-failed`. After a failed or unfinished attempt the next boots are
fallback boots (the safe desktop on a stuck squat, GOP elsewhere) until N of them finished, then the full desktop is
tried again. N = 1, and 3 once 3 attempts in a row failed. A fallback boot counts as clean at the next boot's start
when it left no in-progress mark, not at its TERM: a dark boot the owner powers off would never count, and the
daemon of a failed stuck-squat boot exits early. The warm refusal is not a failure. A bring-up without `navi31 up:`
claims nothing; after 2 failed bring-ups in a row one boot skips the bring-up (no watchdog, no restart), the next
tries again. One notification after login says why the desktop is in basic mode.
**Why:** one freeze cost a degraded machine until a manual `rm` (STATUS D7). One clean boot shows that the machine and
the plain path work, and the failures seen so far (the 2026-11-24 freeze, the HDR freeze) did not repeat on the next
attempt. A failure that repeats costs every second boot, after 3 in a row every fourth: never every boot, never a
manual repair, and never more than 2 restarts in a row by themselves. Design:
`findings/2026-11-25-recovery-trap-design.md`.
**Revisit:** with plan step 3 (the kext hands the display back in the same boot) the fallback becomes a GOP boot and
the safe desktop goes (step 4). If a failure repeats on hardware more often than the backoff allows for, raise N.

## 2026-11-25: The recovery daemon's edge cases (the Fable pass of #26)

**Decision:** a fallback boot counts as clean only if it ended without a failure: a safe desktop that fails, or a GOP
boot whose NMXAccel didn't start or without PhxBringup, records `last=skip`. A TERM in the first 60 s of the bring-up
(`PHXBOOT_UP_HANG`; it takes about 10 s) is a clean shutdown and isn't counted; a later one, such as the bring-up
watchdog's restart at 3 min, counts as a hung bring-up. A failed bring-up uses up `~/gpu/phxboot-desktop`, as `m2_fail`
does; the warm refusal keeps it. A restart after a failure leaves one sentence for the next boot
(`/var/db/phxboot.notice-next`), shown after login unless that boot has its own notice. Safe Mode on a squat boot
stays dark until VermilionBoot stops squatting with `-x` (design plan step 2); the daemon only logs it and leaves a
notice for the next boot.
**Why:** each of these either tried the full desktop too soon, counted a plain shutdown as a failure, repeated an
attempt the owner armed once, or left the user without an explanation. A refusal is no attempt, and the cold boot
after the power-off should get the desktop that was asked for. In Safe Mode nothing in the running boot can give the
screen back without terminating the squatter, which hot-resets the GPU (hard rule 1).
**Revisit:** the 60 s threshold if a bring-up on hardware ever takes longer than about 30 s. Safe Mode with plan step 2.

**Known limits, accepted (Megamind 2, 2026-11-25; from the second Fable pass on #26, code reading, unverified):** the
daemon is replaced by the bring-up in the kernel in phase 3, so these stay as they are unless one shows up on
hardware:
- a fallback boot stopped during the bring-up still counts as a clean fallback (`last` is saved before it): the next
  boot tries the full desktop one boot early;
- a carried notice is lost when a boot exits through a squat reboot without a sentence, `headless`, a TERM trap or
  the dark-display restart: the user misses one explanation;
- a bring-up that takes over 60 s and succeeds, then a shutdown, counts as a hang: one boot falls back;
- the 60 s test uses the wall clock (`date +%s`): a clock step of over a minute during the bring-up can swap a hang
  and a shutdown.
Fixed instead (one line): the warm-refusal notice says "restarted because acceleration failed" only when the carried
sentence is that one (`[ "$CARRY" = "$RESTARTED" ]`), not for any carried sentence.

## 2026-11-25: replaceRegion uploads without a GPU wait, by default

**Decision:** `-[NVMTLTexture replaceRegion:]` submits its copy without waiting for the GPU in every process except
WindowServer (`NVMTL_ASYNC_TEX_UPLOAD`, existing code, now on by default). Pending uploads share the async surface
copy-in's table: at most 64 uploads and 128 MiB of staging, reaped at each new upload; a full table takes the
synchronous path. The async copy is ordered after earlier GPU work on the image. `NVMTL_ASYNC_TEX_UPLOAD=0` or the
file `/Library/GPUBundles/nvmtl/async-tex-upload-off` turns it off; `=1` also turns it on in WindowServer.
**Why:** Maps' main thread spent 10 % of a fullscreen capture waiting there (finding
`2026-11-25-maps-fullscreen-perf.md`). The copy is behind every queued frame, so each wait drains the queue. On a Mac
`replaceRegion:` is a CPU write and never waits for the GPU. The old flag was off because nothing bounded the pending
staging memory; the table bounds it. WindowServer stays synchronous until the path has been seen working in apps,
because a fault there takes the session down.
**Revisit:** WindowServer, after a week without texture faults in apps. A second upload to the same image still waits
for the first (one handle per image); a chain of handles would remove that wait.
