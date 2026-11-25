# CLAUDE.md: working on Vermilion

For coding agents (`AGENTS.md` is a link to this file). Humans start at [`docs/README.md`](docs/README.md).

Vermilion is a macOS Tahoe 26.7.1 driver for the AMD Radeon RX 7900 XTX (Navi 31, RDNA 3): display, Metal on Mesa
RADV, Vulkan, video decode, DP audio. The standard is a PC that behaves 1:1 like a real Mac, built the way Apple would
have built it ([`ROADMAP.md`](ROADMAP.md), "The standard"). It's a fork of
[leolivm/vermilion](https://github.com/leolivm/vermilion); this repo is
[ownback/vermilion-xtx](https://github.com/ownback/vermilion-xtx). The reference machine is described in
[`docs/REFERENCE-MACHINES.md`](docs/REFERENCE-MACHINES.md).

## Start here

1. [`.agents/STATUS.md`](.agents/STATUS.md): what works, what's broken, what's next (the megamind keeps it).
2. [`ROADMAP.md`](ROADMAP.md): repos, phases, the rules every agent follows.
3. [`docs/PROJECT_KNOWLEDGE.md`](docs/PROJECT_KNOWLEDGE.md): machine state, the known-good EFI, the performance record.
4. Then only what the task needs:
   - the stack: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/GLOSSARY.md`](docs/GLOSSARY.md);
   - anything XTX-specific: [`docs/XTX.md`](docs/XTX.md), [`.agents/findings/`](.agents/findings/);
   - builds: [`docs/BUILD.md`](docs/BUILD.md);
   - deploying: [`.agents/runbooks.md`](.agents/runbooks.md), [`efi/README.md`](efi/README.md);
   - names: [`docs/NAMING.md`](docs/NAMING.md);
   - design choices: [`.agents/decisions.md`](.agents/decisions.md);
   - agent tools: [`docs/AGENT-TOOLING.md`](docs/AGENT-TOOLING.md).

## Layout

| Path | What | License |
|---|---|---|
| `src/vermilion-boot/` | `VermilionBoot.kext` (OpenCore): register access, bring-up, DCN display pipes, DMUB, GPU VM, the `N48N` user client RADV talks to | MIT (nullarc files: MIT or GPL-2.0) |
| `src/vermilion-accel/` | `VermilionAccel.kext` (AuxKC): `PhxAMDFB` framebuffer, `NMXAccel` accelerator, `PhxAGDC` | **PolyForm Noncommercial** |
| `src/vermilion-trust/` | `VermilionTrust.kext` (OpenCore, after Lilu): lets only Vermilion's cdhashes past library validation | MIT |
| `src/vermilion-audio/` | `VermilionAudio.kext`: DP audio on the GPU's HDA function | MIT |
| `src/metal-plugin/` | `NVMTLDriver`: the Metal driver, Metal on Vulkan | **PolyForm Noncommercial** |
| `src/translator/` | `libnvmtl_translate.dylib`: Metal AIR to SPIR-V (Rust) | LGPL-3.0-or-later |
| `src/video-decoder/`, `src/video-accel/` | HEVC/AV1 decode (VCN via FFmpeg Vulkan) and its VideoToolbox bundle | MIT / LGPL deps |
| `patches/mesa/` | RADV Darwin backend, on Mesa `f5cb8ee0` | MIT |
| `tools/phxctl/` | the boot daemon `phxboot-navi31.sh`, bring-up and display scripts, `phxctl`, `mesboot` | MIT |
| `tools/capture/`, `tools/linux/` | Linux-side capture tools and replay-plan generators; the Linux reboot guard | MIT |
| `tools/metaltest/`, `tools/sensors/`, `tools/validation/`, ... | measurement and probe tools (`bootcheck.sh`: the per-boot report) | MIT |
| `scripts/build/` | one build script per component | MIT |
| `scripts/dev/` | agent and developer tools: `preflight.sh`, `compile-commands.sh`, `private-patterns.sh` | MIT |
| `efi/` | the reproducible OpenCore EFI builder (moves to `ownback/ryzentosh`) | MIT |
| `tests/` | hardware-free tests: `mock/` (daemon, scripts), `kext/`, `plugin/`, `hooks/` (the guard) | MIT |
| `.claude/` | the guard hook, the machine lock, agents (`hw-safety-reviewer`, `fable-cleanup`), skills (`boot-cycle`, `linux-queue`, `megamind-clone`) | MIT |
| `.agents/` | STATUS, TODO, findings, decisions, runbooks, owner tests | |

## Building and testing

- **Builds need macOS** with the Command Line Tools (x86_64). They run on the XTX machine itself. Linux can't
  build the kexts; `efi/build.py` runs on both.
- **A plugin, translator, RADV or decoder install is also a VermilionTrust + EFI change** (new cdhashes):
  `PHXTRUST_KEEP=1 sh scripts/build/trust.sh`, then rebuild and install the EFI, one boot.
- **Before deploying a daemon or script change:** `bash tests/mock/run.sh` and `bash tests/mock/b15test.sh`.
  Hook changes: `sh tests/hooks/guard_test.sh`.
- **After a kext change:**
  - bump `PHX_KEXT_BUILD` (`src/vermilion-boot/PhxBringup.cpp`) and add a line at the top of
    `src/vermilion-boot/CHANGELOG.md`;
  - run `sh scripts/dev/preflight.sh <kext>` before it goes on the EFI partition.
- **Code navigation:** `sh scripts/dev/compile-commands.sh` (with `MKSDK`, `LILU`) writes `compile_commands.json`
  for clangd and Serena.
- **On Linux,** the XTX runs under amdgpu. Read-only queries are fine. Root work goes through the `linux-queue`
  skill.

## Hard rules

1. **Hardware safety.**
   - Linux to macOS is always a full power-off, never a warm reboot: the bring-up assumes a cold GPU.
   - Never add an SMU, PSP or DAL message, or a register write, that Linux amdgpu doesn't send on this ASIC. Changes
     to GPU programming go through the `hw-safety-reviewer` agent.
   - Never flash or write the VBIOS. Never Reset NVRAM: it removes `phxfb-squat`.
   - Keep the bring-up watchdog and the boot daemon's fallbacks (kill switch, pending mark, GOP revert).
   - One EFI change per boot, with a rollback copy of every replaced binary.
   - Never detach or terminate a driver on the GPU's PCI functions in a running boot (AppleGFXHDA included): IOPCIFamily
     hot-resets the whole GPU (seen on the XTX machine; finding `2026-11-24-gfxhda-detach-gpu-hot-reset.md`).
2. **One machine owner.** Changes to the EFI partition, the system volume, `~/gpu`, kexts and restarts need the
   machine lock (`.claude/hooks/machine-lock acquire "<reason>"`). Ask the owner before any change to the system
   volume.
3. **Detect, don't overwrite.** Board-specific values (monitor timings, VRAM size, XT vs XTX) come from what the
   hardware reports: PCI revision, registers, VBIOS tables, EDID.
4. **No AMD firmware, VBIOS dumps, register captures with serials, EDIDs with serials, or `config.plist` with SMBIOS
   data in git.** A built EFI (`build/efi/`) contains the machine's serials: never commit or publish it.
5. **No personal data in commits, docs or logs:** serials, MLB, ROM, UUIDs, MAC addresses, e-mail, disk or partition
   UUIDs. The guard blocks commits that contain this machine's values (run `sh scripts/dev/private-patterns.sh` once
   per machine).
6. **Licence boundaries.** NullMoth-derived code stays PolyForm Noncommercial; translator changes stay LGPL; new
   files start with an SPDX header (MIT unless derived). Apple's own AMD drivers (the RX 6800/6900 XT stack in this
   macOS) are the reference implementation: reverse engineer them with the `reverse-engineer-anything` (REA) tools,
   and reusing Apple's code is allowed by the owner (decisions.md, 2026-11-25); reference material lives under
   `reference/apple-amd/`.
7. **Keep the `phx`/`nv`/`nmx` names** of classes, sysctls, NVRAM variables, paths and the ABI ([`docs/NAMING.md`](docs/NAMING.md)).
8. **Say what is verified.** Plain statements. Anything not tested on hardware is marked `(unverified)`, and a
   claim about hardware names the machine it was seen on.

## How we work

- Branches `ownback/<topic>` from `fork/main`. Remotes: `fork` = ownback/vermilion-xtx (PRs go here), `origin` =
  leolivm upstream (read-only). Branches are deleted on merge.
- Every PR gets the `fable-cleanup` pass before the owner's OK and the merge.
- A refactor and a behaviour change go in separate commits.
- **Commit or push only when the work calls for it.** Never force-push, and never push to main: the guard blocks
  both.
- When you finish or find something, record it:
  - STATUS and TODO items;
  - a dated note in `.agents/findings/` for an investigation;
  - design choices in `.agents/decisions.md`.
