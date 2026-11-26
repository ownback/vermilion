<!-- SPDX-License-Identifier: MIT -->

# Support matrix

What Vermilion has been seen working on, and what it hasn't. As of 2026-11-25.

> [!IMPORTANT]
> **Vermilion is experimental.** It doesn't reach parity with a real Mac yet: the GPU is powered up by a script after
> the login window, display modes are replays of what Linux sent on one card and one monitor, sleep is off, and several
> parts need relaxed security settings ([README](README.md#what-works-what-doesnt)). Until that work is done, every
> release is a preview, for people who can recover a machine that doesn't boot to a picture. The first one is
> `0.1.0-preview`, for the RX 7900 XTX only.

**What the words mean.** *Verified:* seen working on the named machine, by a person or a logged test. *Untested:*
nobody has run it; it may work, fail, or show no picture. *Not supported:* the driver should refuse it (marked where it
doesn't yet). *Refused by the code* and *from the code* are what the source says, not a hardware test.

## GPU

| Card | PCI | State |
|---|---|---|
| RX 7900 XTX, XFX Speedster MERC 310, VBIOS `113-31XFSHBS1.L04` | `1002:744c` rev `0xC8` | **verified** (the [reference machine](docs/REFERENCE-MACHINES.md)) |
| RX 7900 XTX, other board partners or VBIOS versions | `1002:744c` rev `0xC8` | untested. From the code: the card's own firmware sets power limits and fans (Vermilion sends no power or fan messages); the connector table is the reference board's; the display replays refuse a different firmware display build (one mode only) |
| RX 7900 XT | `1002:744c` rev `0xCC` | not supported by this fork (it is upstream's card: [leolivm/vermilion](https://github.com/leolivm/vermilion)). **The kext still matches it today;** the refusal comes before the first release |
| RX 7900 GRE, RX 7900M | `1002:744c` rev `0xCE`, `0xCF` | not supported. **The kext still matches them today;** the refusal comes before the first release |
| Other Navi 31 (W7900, W7800), Navi 32/33, RDNA 2, RDNA 4 | other IDs | not supported (not matched) |
| A second GPU next to it; an iGPU as the boot display | | untested; the RX 7900 XTX must be the boot display |

## Monitor and outputs

| | State |
|---|---|
| LG 27GS95QE-B on DisplayPort: 2560x1440 at 60 / 120 / 144 / 240 Hz, Variable 60-240 Hz | **verified** |
| The same monitor: HDR | broken (switched off) |
| The same monitor: other sizes (1920x1080, 1280x1024, ...) | verified at fixed rates (drawn by the CPU) |
| Any other DisplayPort monitor | from the code: one mode, the firmware's; no rate change, Variable or HDR. Untested |
| HDMI | doesn't work (black) |
| Two or more monitors | not available on the RX 7900 XTX yet (upstream's two-monitor setup is for its XT and its two 1080p monitors) |
| Unplug / power-cycle / input switch | broken (black until a restart) |
| DisplayPort audio to the monitor | verified (LG) |

## macOS

| | State |
|---|---|
| macOS Tahoe 26.7.1 (25G241) | **verified**; the only build that works |
| Any other macOS version or build | not supported (the Metal driver uses private interfaces of 25G241) |
| Recovery, Safe Mode, the macOS installer | probably no picture with VermilionBoot loaded *(unverified)*; boot an EFI copy without it |
| FileVault | not supported today (the boot daemon logs in automatically once per boot) |
| System sleep | not supported (keep it off) |
| SIP | relaxed (`0x0A03`) |
| Kext approval | one **Allow** click for VermilionAccel at the install and after each update of it: a known step ([INSTALL.md](INSTALL.md#34-the-allow-click)) |
| Gatekeeper | the release package is unsigned: **Open Anyway** in System Settings > Privacy & Security ([INSTALL.md](INSTALL.md#33-open-the-package-gatekeeper)) |

## Machine

| | State |
|---|---|
| ASUS ROG STRIX B650E-I, Ryzen 9 7900X3D, OpenCore 1.0.8, the SMBIOS model of [`efi/machines/`](efi/machines/) | **verified** (the reference machine; its EFI is [`efi/`](efi/README.md), moving to ryzentosh) |
| Other AM5 boards, other AMD or Intel CPUs | untested. Vermilion itself doesn't depend on the CPU or board; your OpenCore setup does |
| Linux on the same disk | verified (Limine on the shared EFI partition). **Always power off fully before booting macOS** |
| Windows on the same disk | untested. Power off fully before booting macOS (Fast Startup off is recommended, *unverified*) |
| VFIO passthrough (macOS in a VM with this card) | untested, planned |

## Report a result

A report from another card, board or monitor helps most, working or not: see [INSTALL.md](INSTALL.md#9-reporting-a-problem)
(and remove personal data first).
