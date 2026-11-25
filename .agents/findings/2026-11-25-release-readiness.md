<!-- SPDX-License-Identifier: MIT -->

# Release readiness: audit and plan (2026-11-25)

The owner's goal (2026-11-25): publish and promote `ownback/vermilion-xtx` to real users by about 2026-11-29, as a
clean installation that behaves as if Apple supported the RX 7900 XTX out of the box. This is the audit of how far the
repository is from that, and the plan.

How this was done: repository read only, on `fork/main` (`90726b8`) plus the megamind branch's
`.agents/PLAN-parity-week.md` and STATUS (`b32e6e9`, not on main yet). No machine changes, no `sysctl`, no
`scripts/dev/private-patterns.sh` (so the scan below uses generic patterns, not this machine's values). `gh repo view`
was the only network read. Nothing was built or booted. Hardware statements cite the XTX machine
([`docs/REFERENCE-MACHINES.md`](../../docs/REFERENCE-MACHINES.md)) through the findings they come from.

## Summary

- **Full parity is out of reach this week.** The kernel rows (B1 bring-up in the kernel, B2 own mode setting, B3
  Accel from OpenCore) are L-XL ([PLAN-parity-week](../PLAN-parity-week.md), on `ownback/megamind` until it merges). If something ships this week, it can only
  be an **experimental preview for the exact reference machine**, labelled as one. The new user docs say this.
- **Blockers that can close this week** (ranked below): the revision gate for other cards, the notices and licence
  wording, the Apple-code quotes in comments, the commit e-mail leak (from now on), the user docs and the support
  matrix, a tested clean install on the reference machine, the release scan. **Blockers that can't:** AMD firmware in
  a binary VermilionBoot (the C3 slice), the NullMoth-bundle LLVM, the decoder on the system volume (A6), the Apple
  byte patterns in VermilionAudio, and everything in track B.
- **The repository is already public** (`gh repo view`: `PUBLIC`). "Publish" here means releases and promotion, not
  visibility.
- **Found in this audit, not tracked before:**
  1. 423 of the fork's commits carry a non-noreply author address: 69 a personal e-mail, 286 a hostname that
     contains a first name, 68 an ISP router domain. Git has no `user.email` set in this checkout, so every new
     commit made here repeats it. The tree itself is clean (generic scan below).
  2. A binary VermilionBoot contains a slice of AMD's `dcn_3_2_0_dmcub.bin` (the C3 image, `PhxC3Load.h`). The tree
     ships none; a release binary would.
  3. The plugin's AIR reader (`air-runtime/libLLVM.dylib`) only exists inside NullMoth's bundle: no user can get it
     from this project.
  4. VermilionAudio carries 19 bytes of Apple machine code and a 44-byte Apple data table entry as its find/replace
     patterns (`src/vermilion-audio/VermilionAudio.cpp:115-134`). Three comments quoted Apple instructions
     (VermilionAudio, `IOGraphicsAccelerator2.h`, `phxrotate.h`): reworded on this branch.
  5. `CREDITS.md` said "Lilu is not used"; VermilionAudio is a Lilu plugin. `LICENSE` had no row for
     `src/vermilion-trust` and `src/vermilion-audio`. Fixed on this branch.
  6. The kext matches every `0x744c` revision (XT `0xCC`, XTX `0xC8`, GRE `0xCE`, 7900M `0xCF`), and nothing refuses
     the revisions nobody tested.

## 1. Install shape: today vs the target

Today (STATUS "Release shape", the media/system audit row, `docs/INSTALL.md`, `tools/phxctl/recovery_install.sh`):

| # | Part | Where it is today | What a Mac does / the target | Interim for a preview | Plan item |
|---|---|---|---|---|---|
| 1 | `VermilionBoot.kext` | OpenCore `Kernel > Add` | The one kext. Brings the GPU up in `start`, before WindowServer | as is | B1 |
| 2 | `VermilionTrust.kext` (fixed AMFI offsets, a cdhash list rebuilt for every user-space build) | OpenCore | A Mac has no such patch. The honest target: the slots found at boot, a clean refusal, the cdhash list as data from the release manifest. A non-Apple Metal driver can't load into WindowServer (a platform binary) without either this or AMFI relaxed: name it a known limit or keep it open (owner) | the release's cdhashes built in, so users never rebuild it | B4, TODO 06 item 2 |
| 3 | `VermilionAudio.kext` (a Lilu plugin: patches AppleGFXHDA's controller table and two factory masks, re-delivers a notification, sets framebuffer properties) | OpenCore, needs Lilu | AppleGFXHDA accepts the function as it accepts Navi 21's `ab28` on Apple's own hardware; PhxAMDFB publishes `connector-type`, `av-signal-type`, `AAPL,DisplayPipe`; the kernel programs DC audio | as is, with Lilu | B1 (kernel DC audio); new **A8**: audio without Lilu (below) |
| 4 | `VermilionAccel.kext` | `/Library/Extensions` (AuxKC), an "Allow" click in System Settings at every install or update | Loads without a click | as is; INSTALL.md explains the click | B3 |
| 5 | Root boot daemon `phxboot-navi31.sh` + `phxboot-pre.sh` | `~/gpu`, owned by the desktop user, run as root (any process of that user can get root: audit-display risk 6) | Nothing: the kext does it | root-owned system path (TODO 06 item 3) | B1; TODO 06 |
| 6 | Bring-up scripts, `phxctl`, `mesboot`, `vcn_up.sh`, helpers (`gfx_cg.sh`, `uclk.sh`, ...) | `~/gpu`, `/usr/local/sbin` | Nothing: the kext does it | system path | B1 |
| 7 | 21 `phxboot-*` flag files | `~/gpu` | Defaults inside the driver; user choices in System Settings; debug switches as boot-args | defaults written by the installer | B1; TODO 06 item 6 |
| 8 | AMD firmware (20 files of `tools/firmware/fw.lock`) | `~/gpu/fw/navi31`, fetched by `fetch_firmware.sh` | Firmware ships with the driver (Apple puts it in the kext) | fetched at install into a root-owned path (section 2.1) | B1; new **F1** |
| 9 | The C3 slice of `dcn_3_2_0_dmcub.bin` | compiled into VermilionBoot (`phx_c3_image.inc`, generated locally) | | none in a release binary (section 2.1) | new **F1** |
| 10 | NVMTLDriver, translator, RADV, the 3 decoder dylibs | `CoreTypes.bundle/Contents/Library/PhxGPU` (a firmlink into Data), symlinks in `/Library/GPUBundles` | `/Library/GPUBundles` is the path macOS gives third-party GPU bundles. The sandbox relocation stays only while sandboxed GPU processes need it | a package (section 4) | A2 (release build), installer |
| 11 | `air-runtime/libLLVM.dylib` + `libzstd` | from NullMoth's bundle (`air_runtime_install.sh`); no build of ours | built by this project from LLVM's source (Apache-2.0 with LLVM exception), notices shipped | **blocker** for strangers (section 2.6) | new **R1** |
| 12 | `spirv-val` | `/usr/local/bin`, from Homebrew or `build/spirv-val` | inside the bundle, built from SPIRV-Tools (Apache-2.0) | ship in the package with its notice | installer |
| 13 | `air-opt` (Apple binary, optional fallback) | `/Library/GPUBundles/nvmtl/air-opt`, copied from a Metal toolchain | not needed | never shipped; the plugin must work without it (unverified how often the fallback runs) | R1 |
| 14 | `PhxVideoDecoder.bundle` | `/System/Library/Video/Plug-Ins` on the system volume, seal broken, SIP `0x800` | AppleGVA loads `PhxVA.bundle` from `/Library/GPUBundles` | left out of a preview (decode is optional; Apple's software decoders run) | A6 |
| 15 | Metal allow list rewritten at each boot; the Dock / Spotlight / Photos deny list | `/Library/GPUBundles/nvmtl-allow.txt` | Every process gets Metal | `*` | STATUS item 8, B1 |
| 16 | `local.phxpassd` login agent | `~/Library/LaunchAgents` | passd starts at login on a T2 Mac | ryzentosh-sse | A7 |
| 17 | `phxfb-squat` NVRAM variable | set **from Linux** (macOS can't write NVRAM with `DisableVariableWrite`); Reset NVRAM deletes it; Recovery and Safe Mode squat too (D30, unverified: no picture) | The kext decides itself | OpenCore `NVRAM > Add` (TODO 06 item 4, unverified) | Phase 2 item 3 (#24 design) |
| 18 | Auto-login set by the daemon, a WindowServer restart, login rewrites; FileVault incompatible | daemon | No restart; FileVault works | documented as a limit of the preview | B1 |
| 19 | OpenCore config: the AGDP board-id kernel patch, `phxdebug=1`, `ipc_control_port_options=0`, `-v`, SIP `0x0A03`, `SecureBootModel Disabled`, `DisableVariableWrite`, `ResizeAppleGpuBars`, no `ResetNvramEntry.efi`, AMFIPass | `efi/machines/b650e-i-xtx.json` | A snippet: the kexts, the AGDP patch, the SIP bits something still needs; no `phxdebug`, no `-v`, no picker | the snippet in `INSTALL.md` | B1 (`phxdebug`), B3 (`0x1`, `0x200`), A6 (`0x800`), B4, B6 |
| 20 | macOS pinned to 25G241 | | known limit (ROADMAP) | documented with how to stop updates | Known limits |

**The target a user does, in the end:** (reference machine) download the ryzentosh EFI, add SMBIOS, copy it to the EFI
partition; (anyone else) copy the release's kexts into `EFI/OC/Kexts` and merge one config snippet. No script in the
home folder, no system-volume edit, no NVRAM step, no Allow click. With B1 and B3 done there is no package at all;
until then, one signed package for the user-space parts (section 4).

**New plan items found here** (to add to PLAN-parity-week by the megamind):

| # | Item | Size | Boots |
|---|---|---|---|
| A8 | DP audio without Lilu: test whether a `device-id` property of `0xab28` on the audio function (OpenCore `DeviceProperties`) makes AppleGFXHDA take the Navi 21 path with no patch (IOPCIFamily answers config reads of the device ID from that property, which is what GPU spoofing relies on; unverified on 26.7.1). If it works, the table and mask patches and their Apple bytes go | S | 1 (EFI) |
| F1 | No AMD bytes in any release binary: the C3 slice read at run time from the installed firmware, not compiled in. Same bytes, same writes: hw-safety review of the load path only | S-M | 1 |
| R1 | The AIR reader built by this project: LLVM 21.1.8 `libLLVM.dylib` from source in CI, its notices in the bundle; the plugin works without `air-opt` | M | 1 (trust + EFI) |
| G1 | Revision gate: VermilionBoot's bring-up and the daemon refuse a `0x744c` revision other than `0xC8` (verified here) and `0xCC` (verified upstream), with a log line; a boot-arg to override for testers | S | 1 |

## 2. Blockers to publish

### 2.1 AMD firmware (rule 4)

- The tree is clean: `tools/firmware/fetch_firmware.sh` downloads the 20 files from linux-firmware at the pinned
  commit (`add22516`, tag `20250917`) and checks each md5; `.gitignore` keeps `*.bin` and the generated
  `phx_c3_image.inc` out. `git ls-files` shows no `.bin`, `.rom` or EDID file (this audit).
- **A release binary is not clean.** `scripts/build/kext.sh` compiles a slice of `dcn_3_2_0_dmcub.bin` into
  VermilionBoot. AMD's licence allows redistribution of copies "in binary form only" with the notice; whether an
  extracted slice inside another binary is such a copy is not clear, so the project should not rely on it. Fix: F1.
- **How users get the firmware, legally:** the installer downloads it on the user's own machine, from linux-firmware
  (GitLab mirror, then git.kernel.org) at the pinned commit, and checks md5 plus a SHA-256 list (to add to `fw.lock`).
  Offline: the user points it at a linux-firmware checkout or a distribution's firmware package. The project never
  hosts a firmware file. Shipping the 20 unmodified files with AMD's notice is allowed by AMD's licence, but rule 4 and
  the project's line so far say no: the owner's call.
- With B1 the kernel needs the firmware before any user-space step. Design (unverified): the installer generates a
  small codeless firmware kext on the user's machine (the files as `OSData` in its `Info.plist`) that OpenCore
  injects next to VermilionBoot; the project ships only the generator. Open: OpenCore's and the kernel's limits on a
  ~5 MB `Info.plist`.

### 2.2 Licence audit

| Part | Licence | What a user may do |
|---|---|---|
| `src/vermilion-boot` (most), `src/vermilion-trust`, `src/vermilion-audio`, `src/video-*`, `tools/`, `scripts/`, `tests/`, `docs/`, `efi/` | MIT (nullarc-derived files MIT or GPL-2.0; Cobalt64 parts BSD-3; amdgpu-derived MIT-AMD) | anything, with the notice |
| `src/vermilion-accel`, `src/metal-plugin` (NullMoth-derived) | **PolyForm Noncommercial 1.0.0** | use, change, share, for noncommercial purposes only; keep the terms and the `Required Notice:` line |
| `src/translator` | LGPL-3.0-or-later | use; a binary must come with its source (or a written offer) and must stay replaceable (it is: the plugin dlopens it) |
| `patches/mesa`, `patches/ffmpeg` | MIT / LGPL-2.1-or-later | as their projects |

What the PolyForm parts mean for users, in plain words (the README now says this): personal use, hobby, study,
research, and use by charities, schools and public bodies is fine. **Not allowed:** selling it, selling machines with
it installed, paid installation services, using it for a company's work. Unclear and the owner's call to state:
donations or sponsorship for the project, and monetised videos about it (PolyForm's "noncommercial purposes" is about
use of the software; a disclaimer that the project grants nothing beyond the licence is the safe wording).

Consequences for the release:

- The "one kext" target merges VermilionBoot (MIT) and VermilionAccel (PolyForm NC): the merged kext is PolyForm NC as
  a whole, and nullarc's GPL-2.0 option can't be used for it (the MIT option can). Fine, but the release notes must
  say the kext is noncommercial.
- Only NullMoth can relicense the NullMoth-derived parts. Rewriting them from scratch (a clean-room PhxAMDFB/NMXAccel
  and plugin) is the only other way to an all-open release: not a this-week item.
- Notices a binary release must carry, beyond `LICENSE`/`NOTICE`/`LICENSES/`: the Rust crates linked into the
  translator (`THIRD_PARTY_NOTICES.md` lists them), Lilu (BSD-3, the VermilionAudio SDK), SPIRV-Tools (Apache-2.0,
  `spirv-val`), LLVM and zstd (Apache-2.0 with LLVM exception, BSD; R1), FFmpeg's LGPL with the source of the exact
  build (`patches/ffmpeg` + `scripts/build/ffmpeg.sh`), Mesa's MIT. Added to `THIRD_PARTY_NOTICES.md` on this branch.
- ROADMAP: tell leolivm before the public post. NullMoth: nothing is required beyond the notice; the README already
  says the project isn't NullMoth's and asks people not to contact them for support.
- macOS: Apple's licence allows macOS only on Apple-branded hardware. The project doesn't distribute macOS; the README
  says users are responsible for following Apple's terms. Wording about "a real Mac" must not suggest Apple endorses
  or supports anything (the README's disclaimer covers Apple).

### 2.3 Apple code check (rule 6)

| Where | What | State |
|---|---|---|
| `src/vermilion-accel/accel/re/IOGraphicsAccelerator2.h:18` | quoted an instruction from IOAcceleratorFamily2 (inherited from NullMoth) | **reworded on this branch** (comment only; the fact, 3544 bytes, stays) |
| `.agents/findings/2026-11-24-audit-accel.md:69` | quoted the same instruction | reworded on this branch |
| `src/vermilion-audio/VermilionAudio.cpp:127` | a disassembly quote in a comment | reworded on this branch (same line count) |
| `src/vermilion-accel/accel/phxrotate.h:156` | a CoreDisplay instruction quoted with its address (found by the new scan) | reworded on this branch (same line count). The addresses in that header's comments stay: they're references, not code |
| `src/vermilion-audio/VermilionAudio.cpp:115-134` | `kFind`/`kReplace`: a 44-byte entry of AppleGFXHDA's data table; `kFindMask`/`kReplaceMask`: 19 bytes of AppleGFXHDA machine code | **open, owner decision.** Find/replace patterns are how every Lilu patch works, but rule 6 as written ("no Apple code") covers them. A8 removes them if it works |
| `src/vermilion-accel/accel/tahoe_fwd.h` | naked trampolines that jump through Apple vtable slots by offset | our own code; the offsets are interoperability facts. No change |
| `src/vermilion-trust/VermilionTrust.cpp` | struct offsets from xnu's public headers | no Apple code |
| `src/vermilion-accel/accel/iofam`, `accel/re` | NullMoth's reconstructed class layouts and vtable orders | interoperability descriptions (THIRD_PARTY_NOTICES); a reviewer may still ask: say so in the README? (owner) |

Search used: AT&T mnemonics with operands in every tracked text file outside asm statements (now
`release-scan.sh`'s `apple-asm` check); "disassembl", "decompiled"; tracked RE databases (`.i64`, `.gzf`, `.bndb`,
`re/x86`): none tracked. After the rewording, `scripts/dev/release-scan.sh .` reports the tree clean.

### 2.4 Personal data (rule 5)

- **Tree:** generic patterns over every file (`release-scan.sh`): the MAC addresses and UUIDs in `tests/` are
  placeholders (a vendor prefix plus `aa:bb:cc` / `11:22:33`, zero groups); the e-mail addresses are third-party
  copyright notices (`LICENSES/`, metal2vulkan's `Cargo.toml`) or `example.invalid`; the UUIDs in the translator's
  LLVM fixtures are NullMoth's build-session ids; home paths only the mock users `alice`/`bob`. Each exception is
  listed with its reason in `scripts/dev/release-scan.allow`.
  `scripts/dev/private-patterns.sh` (this machine's own values) was not run (task rule); the guard runs it on commits.
- **History (the tree is public):** the author addresses above. They are already public. Rewriting history needs a
  force-push, which the guard blocks and the project's rules forbid: the owner decides whether to accept it. **From
  now on:** set `git config user.email <id>+ownback@users.noreply.github.com` in every checkout (owner), and turn on
  GitHub's "Block command line pushes that expose my email". This branch's commits use that noreply address.
- **Release binaries:** a kext built on the owner's Mac embeds build paths (`__FILE__` in asserts and logs; DWARF in
  dSYMs), and the home folder's name is in them. Build releases in CI or with `-ffile-prefix-map`, and scan them
  (`scripts/dev/release-scan.sh`, new on this branch).
- **Never in a release:** `build/efi/` (SMBIOS), `config.plist`, `~/.config/vermilion/`, monitor EDIDs (serial in
  bytes 12-15), boot logs (they hold the user name), `/var/log/phxboot.log`.

### 2.5 Hardware safety on other machines

What is verified only on the XTX machine (XFX MERC 310 XTX, VBIOS `113-31XFSHBS1.L04`, one LG 27GS95QE on DP) and
what the code does elsewhere:

| Situation | What the code does (code read; unverified on hardware unless stated) | Risk | Fix |
|---|---|---|---|
| RX 7900 XTX of another board partner (other VBIOS, power limits, connector order) | Power limits and fans come from the card's own SMU tables; Vermilion sends no power or fan messages (XTX.md). The connector table is hard-coded (`PhxDdc.h:213-219`); the replay plans need the GOP's DP B and DMCUB `0x07008742`/`0x07008748` (`PhxP0Odm.h:33-38`) and refuse otherwise: one mode, the GOP's | low for the GPU; display may stay on the GOP mode or dark | wanted: testers with other boards; G1 keeps the revision gate |
| RX 7900 XT (`0xCC`) | upstream's verified card; this fork keeps its values next to the XTX's but has not run on one since the fork | unknown regressions | label "upstream-verified, untested here" |
| RX 7900 GRE (`0xCE`), 7900M (`0xCF`) | matched by `0x744c1002`, named as an XT; the bring-up runs XT/XTX assumptions (20/24 GiB apertures in `mesboot.c:131`, the plans) | **unknown programming on an untested ASIC configuration** | **G1: refuse** |
| A second GPU, an iGPU as the boot display, VFIO later | the daemon and the squat assume the dGPU's GOP lights the monitor | no picture | documented requirement |
| A warm GPU (Windows or Linux restart into macOS) | `bringup_navi31.sh` refuses when the PSP sOS is alive (#22); a warm macOS restart reads cold (finding `2026-11-25-warm-restart-sos-cold.md`). Not tested after Windows | unknown after Windows | user docs: full power-off, always; Windows Fast Startup off (unverified whether needed) |
| Any other monitor | gets the GOP's mode, no rate change, no VRR/HDR (audit-display D12). A failed EDID read serves upstream's stored Acer EDID (D15) | wrong display identity; no damage expected | B2; D15 fix |
| HDMI | black (no plan) | | B2 |
| Reset NVRAM | deletes `phxfb-squat` | degraded boots | user docs: never; release profile hides the entry |
| Recovery, Safe Mode, installer | probably no picture (D30, unverified) | user can't reach Recovery's tools | #24 step 2; user docs: keep a second EFI without VermilionBoot |
| Sleep | disabled (`disablesleep 1`) | | B (phase 3) |

### 2.6 Things a stranger can't reproduce today

- No release artefacts, no CI. Every binary on the XTX machine was built there.
- The AIR reader (row 11), `spirv-val` (row 12), and the bundle skeleton (now written by `recovery_install.sh`).
- `phxfb-squat` from Linux (row 17); `efi/build.py` builds only the owner's board.
- **A clean install from zero has not been done since 2026-11-19** (finding `2026-11-19-install-phases.md`); every
  later part was installed by hand onto the running machine. A preview must be installed once onto a fresh 26.7.1
  volume on the reference machine, following only `INSTALL.md`, before anyone else tries (owner test, needs the
  machine).

### 2.7 Support matrix and the experimental statement

Written on this branch: [`SUPPORT.md`](../../SUPPORT.md) (matrix) and the README's "Experimental" box.

## 3. Blockers ranked

| Rank | Blocker | Closes this week? | How |
|---|---|---|---|
| 1 | Untested `0x744c` revisions run the bring-up (G1) | yes | S, refusal only (hw-safety pass), 1 boot |
| 2 | No tested clean install; no release artefacts | partly: one clean-install test on the reference machine (owner, a spare APFS volume), a CI build | owner test + CI |
| 3 | AMD bytes in a binary VermilionBoot (F1) | maybe | S-M, hw-safety of the load path, 1 boot. Without it: ship no VermilionBoot binary, or the owner accepts the slice under AMD's binary-redistribution grant |
| 4 | The AIR reader exists only in NullMoth's bundle (R1) | maybe | M: LLVM build in CI; without it a stranger gets no shaders |
| 5 | Apple byte patterns in VermilionAudio | owner decision this week; A8 is 1 boot | A8, or accept as the usual Lilu practice, or leave DP audio out of the preview |
| 6 | Commit e-mail leak | from now on yes; history no (force-push) | owner: `git config`, GitHub setting |
| 7 | Licence wording, notices | yes (this branch) | owner to confirm the wording |
| 8 | User docs, support matrix, experimental statement | yes (this branch) | owner review |
| 9 | Release engineering: versioning, CHANGELOG, signing, checksums, scan | design and scan yes (this branch); signing needs an Apple Developer ID (owner) | `docs/RELEASE.md` |
| 10 | The not-standard rows (B1-B6, A1-A7), HDR off, replug, sleep, display sleep, FileVault | no | the parity plan; the preview lists them as known issues |

## 4. Installer, uninstaller, the ryzentosh hand-off, the release

Designed in [`docs/RELEASE.md`](../../docs/RELEASE.md): two artefacts (an OpenCore zip with the kexts and the
snippet; a package for the user-space parts that shrinks to nothing with B1 and B3), a firmware fetch at install, an
uninstaller from the package's receipt, the hand-off to ryzentosh (it pins the release zip like any other kext), and
the release checklist.

## 5. Written on this branch

- `README.md`: rewritten for users (what it is, the experimental box, works / doesn't, hardware, limits, the licence
  in plain words, credits, disclaimers). The developer/agent links moved to the end.
- `INSTALL.md` (new, user guide): requirements, what changes on the system, install (the target route marked "not
  available yet"; the manual route that works today), the OpenCore snippet, first boot, update, uninstall, recovery,
  reporting a bug without personal data.
- `SUPPORT.md` (new): the support matrix and what "verified" means.
- `docs/RELEASE.md` (new): installer/uninstaller design, the ryzentosh hand-off, artefacts, versioning, signing, the
  release checklist.
- `CHANGELOG.md` (new): user-facing, "Unreleased" only.
- `scripts/dev/release-scan.sh` (new) and `tests/release/release_scan_test.sh`: a generic scan of a tree or release
  artefacts (and of commit addresses) for personal data, firmware, SMBIOS plists and Apple-instruction quotes.
- `LICENSE`, `CREDITS.md`, `THIRD_PARTY_NOTICES.md`: the missing rows (Trust, Audio, Lilu, SPIRV-Tools, LLVM).
- Comment-only: the three Apple-instruction quotes; the audit finding's quote. Same line counts; the byte-identical
  check is the Fable pass's.
- `docs/README.md`, `docs/INSTALL.md`: point users to the new guide; the old one is the expert reference.

Not touched: STATUS, TODO, PLAN-parity-week, decisions (the megamind's; they're on `ownback/megamind`, not main). The
megamind should add A8, F1, R1, G1 to the plan and the TODO, and the commit-address item to STATUS "Tooling and repo".

## 6. Owner decisions

1. **Ship a preview this week or wait.** Recommendation: a tagged `0.1.0-preview` for the exact reference machine
   only, after G1 and one clean-install test, announced as experimental; the broad promotion after B1 and B3.
2. **Licence wording:** confirm the plain-words summary; donations/sponsorship yes or no.
3. **Firmware:** fetch at install (recommended) or ship AMD's unmodified files; F1 or accept the slice.
4. **VermilionAudio's Apple bytes:** accept (Lilu practice), A8 first, or no DP audio in the preview.
5. **Naming:** the public name ("Vermilion" as upstream, or "Vermilion XTX"); the `org.vermilion.*` bundle ids
   (the project doesn't own a `vermilion` domain); the XT question (keep, drop, or "upstream-verified only").
6. **Visibility and timing:** the repo is already public; whether releases are public; tell leolivm first (ROADMAP).
7. **History addresses:** accept the exposed addresses (no rewrite) and fix forward.
8. **Signing:** an Apple Developer ID for a signed, notarised package (yearly fee), or unsigned with a Gatekeeper
   step in INSTALL.md.
9. **VermilionTrust:** a known limit ("a non-Apple Metal driver needs it") or keep it as open work.
