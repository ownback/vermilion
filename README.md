<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/vermilion-logo-dark.svg">
    <img alt="Vermilion" src="assets/brand/vermilion-logo-light.svg" width="480">
  </picture>
</p>

# Vermilion for the RX 7900 XTX

**A macOS driver for the AMD Radeon RX 7900 XTX (Navi 31, RDNA 3) on macOS Tahoe 26.7.1:** display, Metal, Vulkan,
hardware video decode and DisplayPort audio. The goal is a PC that behaves like a Mac Apple had shipped with this
card: the driver Apple would have written, installed the way Apple would have done it.

This is [ownback/vermilion-xtx](https://github.com/ownback/vermilion-xtx), a fork of
[leolivm/vermilion](https://github.com/leolivm/vermilion) (which targets the RX 7900 XT). This fork supports the
RX 7900 XTX only (PCI `1002:744c`, revision `0xC8`): on any other board, the XT included, the kexts log one line and
do not start ([docs/XTX.md](docs/XTX.md), "Supported board"). Its first release will be `0.1.0-preview`, for the
reference machine; no release has been made yet.

> [!CAUTION]
> **Experimental. Not ready for everyday use, and not yet installable without expert work.**
> It has run on **one machine** ([the reference machine](docs/REFERENCE-MACHINES.md)): one XFX RX 7900 XTX, one LG
> 27GS95QE monitor on DisplayPort. Any other card, board or monitor is untested ([SUPPORT.md](SUPPORT.md)). Today it
> installs by hand, it needs a root script at every boot, and it changes system security settings
> ([INSTALL.md](INSTALL.md)). Expect to recover a machine that doesn't boot to a picture. Don't use it on a machine
> you depend on.

## What works, what doesn't

State on the reference machine, 2026-11-25. The full list, row by row, is in [`.agents/STATUS.md`](.agents/STATUS.md).

| | |
|---|---|
| **Works** | Accelerated desktop (WindowServer composites on the GPU) · Metal 3 for apps · Core Animation, Core Image · OpenGL 4.1 (on about 2 minutes after login) · OpenCL · Vulkan for apps · WebGL in Safari · 2560x1440 at 60 / 120 / 144 / 240 Hz with Variable refresh (60-240 Hz) on the LG · HEVC and AV1 hardware decode · DisplayPort audio to the monitor · cold boot, restart, shutdown |
| **Works, slowly or not as a Mac does it** | Games and heavy apps run well below the same card under Linux · Maps fullscreen is choppy · 4K YouTube stutters · the GPU is powered up by a script after the login window, which restarts once · the boot shows the OpenCore picker and verbose text instead of the Apple logo |
| **Broken or missing** | A GPU job that hangs ends the session (no GPU recovery; seen with one MPS benchmark) · WebGPU in Safari (in part) · the GPU's Metal name and VRAM size look wrong to apps · HDR (switched off) · unplugging or power-cycling the monitor needs a restart · system sleep · display sleep (the screen blanks, the monitor stays on) · any other monitor (one mode only), a second monitor, HDMI · hardware encode (FaceTime, exports) · H.264 / VP9 decode · GPU temperature and fan in Mac apps · recovery after a freeze · FileVault · Recovery and Safe Mode probably show no picture |

### Known limits

The only differences from a real Mac the project accepts. Everything else is meant to work as on a Mac; until it
does, it's a bug.

- macOS stays on **26.7.1** (build 25G241): the Metal driver uses private interfaces of exactly this build. Don't update
  macOS.
- One **Allow** click in System Settings > Privacy & Security for `VermilionAccel.kext`, at the install and after
  every update of that kext ([INSTALL.md](INSTALL.md)).
- No Apple TV films or Safari FairPlay video (Apple Music works).
- Blender Cycles renders on the CPU, as on a real Intel Mac with an AMD GPU.
- No Hypervisor.framework on AMD CPUs: no Docker Desktop, accelerated UTM, Parallels or VMware.
- Touch ID, Apple Pay, iPhone Mirroring and Apple Intelligence need Apple silicon or a T2.
- External monitor brightness only through DDC apps (MonitorControl, BetterDisplay), as on a real Mac with a
  non-Apple monitor (DDC/CI itself is still missing).

## Hardware

| | Status |
|---|---|
| RX 7900 XTX (PCI `1002:744c`, revision `0xC8`) | verified on one XFX MERC 310 card; other boards untested |
| RX 7900 XT (revision `0xCC`) | not supported by this fork; it is upstream's card ([leolivm/vermilion](https://github.com/leolivm/vermilion)) |
| RX 7900 GRE, RX 7900M, other RDNA 3 cards | not supported |
| Monitor | the LG 27GS95QE over DisplayPort is fully supported; any other monitor gets one mode |

The full matrix (macOS, boards, CPUs, monitors, other operating systems on the same disk): [SUPPORT.md](SUPPORT.md).

## Install

[INSTALL.md](INSTALL.md): requirements, what changes on your system, install, update, uninstall and recovery. The
release install (copy the kexts into OpenCore, merge one config snippet, run one package) is not available yet. The
package will be unsigned, so macOS asks you to confirm that you want to open it.

## Licence: what you may do

Vermilion combines several licences ([LICENSE](LICENSE), [NOTICE](NOTICE),
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [LICENSES/](LICENSES)):

- Two parts are derived from NullMoth's macOS driver and are under the **PolyForm Noncommercial License 1.0.0**: the
  accelerator kext `VermilionAccel` and the Metal driver `NVMTLDriver`. So **the driver as a whole is for
  noncommercial use only.**
  - **Fine:** personal use, hobby, study, research, testing, and use by charities, schools and public bodies. You may
    change it and share it, with the licence terms and the `Required Notice:` line.
  - **Not allowed:** selling it, selling machines with it installed, paid installation services, using it for a
    company's work.
- Everything written for Vermilion is MIT. The shader translator is LGPL-3.0-or-later. The Mesa and FFmpeg patches
  follow their projects.
- **No AMD firmware, VBIOS or Apple software** is in this repository, and none will be in a release. A script that runs in macOS after the install downloads AMD's
  GPU firmware from [linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware) onto your machine
  ([docs/FIRMWARE.md](docs/FIRMWARE.md); today that script is `tools/firmware/fetch_firmware.sh`).
- Apple's licence for macOS allows it only on Apple-branded hardware. This project doesn't distribute macOS; you are
  responsible for following Apple's terms.

This summary is not legal advice; the licence texts decide.

## Credits

Vermilion is built on NullMoth's macOS driver and its shader translator (metal2vulkan), nullarc, Cobalt64,
RX4Darwin, RedNavi, Linux amdgpu, Mesa, FFmpeg, Lilu and Acidanthera's tools: [CREDITS.md](CREDITS.md) says what came
from each.

> [!WARNING]
> Vermilion is independent and unofficial. It is **not affiliated with, reviewed, endorsed or supported by** Apple,
> AMD, NullMoth Systems, luuumi-dev (nullarc) or any other project named in [CREDITS.md](CREDITS.md). Please don't ask
> them for support with it. "Mac" and "macOS" are Apple's trademarks; "Radeon" is AMD's.

## For developers

| | |
|---|---|
| How it works | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/GLOSSARY.md](docs/GLOSSARY.md) |
| The XTX port | [docs/XTX.md](docs/XTX.md) |
| Building | [docs/BUILD.md](docs/BUILD.md) |
| Every part installed by hand (the expert reference) | [docs/INSTALL.md](docs/INSTALL.md) |
| Releases | [docs/RELEASE.md](docs/RELEASE.md), [CHANGELOG.md](CHANGELOG.md) |
| The plan | [ROADMAP.md](ROADMAP.md) |
| All documentation | [docs/README.md](docs/README.md) |
| Coding agents | [CLAUDE.md](CLAUDE.md) |

| Component | What it does | Source |
|---|---|---|
| `VermilionBoot.kext` | Injected by OpenCore. Starts the GPU (AMD firmware, power management, engines, GPU memory), drives the outputs, and gives the Vulkan driver its access to the card | [`src/vermilion-boot`](src/vermilion-boot) |
| `VermilionAccel.kext` | The part macOS sees as the graphics card: framebuffers, the accelerator, display control | [`src/vermilion-accel`](src/vermilion-accel) |
| `VermilionTrust.kext` | Lets only Vermilion's own code past library validation, so the Metal driver loads into WindowServer | [`src/vermilion-trust`](src/vermilion-trust) |
| `VermilionAudio.kext` | DisplayPort audio through Apple's AppleGFXHDA (a Lilu plugin) | [`src/vermilion-audio`](src/vermilion-audio) |
| `NVMTLDriver` | The Metal driver: Metal on Vulkan | [`src/metal-plugin`](src/metal-plugin) |
| `libnvmtl_translate.dylib` | Metal shaders to SPIR-V | [`src/translator`](src/translator) |
| RADV | Mesa's AMD Vulkan driver with a macOS backend | [`patches/mesa`](patches/mesa) |
| Video decoder | HEVC / AV1 through VCN for VideoToolbox | [`src/video-decoder`](src/video-decoder), [`src/video-accel`](src/video-accel) |
| Boot daemon and tools | Powers the GPU up at every boot (until the kext does it), with fallbacks | [`tools/phxctl`](tools/phxctl) |
| OpenCore EFI builder | The reference machine's EFI, reproducible (moving to ryzentosh) | [`efi/`](efi) |
