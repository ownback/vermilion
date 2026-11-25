# Roadmap

Where this project is going, how the work is organised, and the rules every agent follows. What works and what's
broken right now: [`.agents/STATUS.md`](.agents/STATUS.md), kept by the megamind. Machine state and the performance
record: [`docs/PROJECT_KNOWLEDGE.md`](docs/PROJECT_KNOWLEDGE.md). Open tasks: [`.agents/TODO.md`](.agents/TODO.md).

Rewritten 2026-11-24 after the owner's restructure. It replaces the numbered 00-13 thread series of 2026-11-23,
whose history is in git (PRs #9-#17) and in `.agents/findings/`.

## The standard

The PC behaves 1:1 like a real Mac, built professionally:

- What a real Mac can do, this build does just as well.
- What a real Mac can't do, this build doesn't do either. A macOS bug is a macOS bug, not an OpenCore or driver
  bug.
- No workarounds where a proper implementation is possible. Every part is built the way Apple would have shipped
  it. The accepted base layer is OpenCore with the standard Acidanthera kexts.
- Documentation is part of done. No test leftovers in the repos.

A part that works today but doesn't meet the standard is open work, not a finished feature. Known examples:
- replayed Linux display captures instead of the driver's own link training and mode setting;
- the GPU powered up by a user-space daemon instead of by the driver;
- VermilionTrust's fixed-offset kernel hooks;
- the decoder bundle that breaks the system volume's seal;
- VermilionAccel's AuxKC "Allow" click.

## Repositories

| Repo | What | Release |
|---|---|---|
| [`ownback/vermilion-xtx`](https://github.com/ownback/vermilion-xtx) (this one) | The RX 7900 XTX driver: display, Metal, Vulkan, video, DP audio. The goal is the driver Apple would have shipped for this card | One kext (drop into `EFI/OC/Kexts`, one config snippet), plus a post-installer later if user-space parts can't live in the kext |
| `ownback/ryzentosh-airdrop` | Fork of MtkWireless (GPL): Wi-Fi and Bluetooth with AirDrop and every Continuity feature | Kexts |
| `ownback/ryzentosh` | The owner's public EFI for the exact parts of the reference machine (ASUS ROG STRIX B650E-I, Ryzen 9 7900X3D, RX 7900 XTX, Corsair MP700 Pro, Corsair Vengeance DDR5-6000 CL30). It works like dotfiles: OpenCanopy theme, release OpenCore without debug output, SMBIOS git-ignored | The EFI folder |

The RX 7900 XT (upstream's card) is not supported: the kexts start only on the XTX, PCI `1002:744c` revision `0xC8`
(owner decision 2026-11-25; [`docs/XTX.md`](docs/XTX.md), "Supported board").

Order: vermilion-xtx to a stable release first, then ryzentosh-airdrop, then ryzentosh. Research for the later repos
may run earlier.

## How the work runs

- **One megamind.** A single Opus 5.5 coordinator thread owns the plan, the STATUS file and the machine. It sends
  agents to research, find root causes and write fixes. Machine changes go through it one at a time. Fable 5.2
  cleans up every branch before the merge. When its context gets long, it hands over to a successor with the
  `megamind-clone` skill.
- **Phases for vermilion-xtx:**
  1. **Audit.** Ask the last threads for their state, read all the code, test the machine, and write STATUS.md.
     Make main match the machine (merge the DP audio branch, `ownback/dp-hdmi-audio`).
  2. **Stabilise.** Fix what's broken, ranked by how much a Mac user would notice it.
  3. **Do it properly.** Replace each part that doesn't meet the standard, using Linux amdgpu as the hardware
     reference and Apple's own AMD drivers (AMDRadeonX6000, AMDMTLBronzeDriver) as the reference for how macOS
     expects a GPU driver to behave.
  4. **Performance.** Match Linux in every app and workload (the ranked backlog in TODO, "Performance").
  5. **Parity check.** Agents open apps and check every feature against a real Mac. Then the release.
- **Branches:** `ownback/<topic>` from `fork/main`, one PR each, Fable clean-up, the owner's OK, merge. The branch is
  deleted on merge (the repo setting is on).
- **Reverse engineering:** we study how Apple's drivers behave and build our own implementation of that result. No
  Apple code or disassembly goes into the repo (REA, Ghidra: [`docs/AGENT-TOOLING.md`](docs/AGENT-TOOLING.md)).

## Rules for every agent

1. **CLAUDE.md's hard rules** come first: hardware safety, detect don't overwrite, no firmware or personal data in
   git, licence boundaries, the `phx`/`nv`/`nmx` names, say what is verified. The PreToolUse guard
   (`.claude/hooks/guard.py`) enforces the ones a machine can check.
2. **One machine owner.** Only the session holding the machine lock changes the EFI partition, the system volume,
   `~/gpu`, the kexts or restarts the machine (`.claude/hooks/machine-lock`).
3. **One EFI change per boot,** with the check and rollback written in the TODO before it's installed, and a rollback
   copy of every replaced binary. Restarts follow the `boot-cycle` skill.
4. **Every kext passes `scripts/dev/preflight.sh`** before it goes on the EFI partition. Every GPU programming change
   passes the `hw-safety-reviewer` agent.
5. **Linux work goes through the `linux-queue` skill:** one Linux session for many jobs. Linux to macOS is always a
   full power-off.
6. **Ask the owner** before a change to the system volume, a GPU load (benchmarks, stress tests) and a restart
   while they may be at the PC. Decide routine, reversible steps yourself and report afterwards.
7. **Measure before and after,** under the same conditions, and record baselines in PROJECT_KNOWLEDGE.
8. **No macOS update.** The Metal plugin and VermilionTrust depend on build 25G241 (26.7.1).

## Known limits: the only accepted differences from a real Mac

Each one goes into the README as it is. Everything not listed here is meant to work like on a Mac; until it does, it
is an open bug, not a limit.

| Limit | Why |
|---|---|
| macOS stays on 26.7.1 | The Metal plugin uses private interfaces of exactly this build; Tahoe is the last Intel macOS |
| No Apple TV films or Safari FairPlay video (Apple Music works) | Needs Apple's protected hardware decode path plus HDCP; not realistic, legally risky |
| Blender Cycles renders on the CPU | Blender 4.2+ accepts only Apple-silicon GPUs for Cycles on macOS (its device check wants "Apple" in the name and unified memory), as on a real Intel Mac with an AMD GPU |
| No Hypervisor.framework: no Docker Desktop, UTM (accelerated), Parallels, VMware | Apple's hypervisor implements Intel VT-x only, not AMD SVM. Use containers on Linux over SSH |
| No native AMD CPU power management, no CCD-aware scheduling on X3D parts | Apple never shipped it; custom kexts only |
| Touch ID, Apple Pay, iPhone Mirroring, Apple Intelligence | Need Apple silicon or a T2 |
| External monitor brightness only through DDC apps (MonitorControl, BetterDisplay) | The same on a real Mac with a non-Apple monitor; the driver must make DDC/CI work over DisplayPort |
| Remaining VRR flicker on OLED | The panel's own behaviour, the same on Windows and Linux |

## Upstream and credits

Vermilion is a fork of [leolivm/vermilion](https://github.com/leolivm/vermilion) (and, through it, NullMoth's
code, which is PolyForm Noncommercial). Credit both clearly, offer fixes that help the XT upstream as separate PRs,
and tell leolivm before the public post. MtkWireless's authors are credited in ryzentosh-airdrop.
