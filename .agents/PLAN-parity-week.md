<!-- SPDX-License-Identifier: MIT -->

# Parity week (from 2026-11-25)

The owner's goal (2026-11-25): every "not standard" row in [STATUS](STATUS.md) at 1:1 parity with a real Mac this
week, no workarounds. The hard rules still hold: hw-safety review for GPU programming, one EFI change per boot with a
rollback copy, machine changes by the megamind only. Agents design and build in parallel; the megamind installs one
change per boot.

**What fits this week, honestly:** the plugin, RADV and userspace rows (track A) and the designs of the kernel rows
(track B). The kernel rows (bring-up in the kernel, own mode setting, compositing at Linux speed) are L-XL and need
several reviewed boots each; they start this week and may not finish.

## Track A: no kernel change (agents start now)

| # | Row (STATUS ref) | What a Mac does | Fix | Size | Boots | Owner test |
|---|---|---|---|---|---|---|
| A1 | Desktop compositing slow (A5) | WindowServer's composite of a fullscreen app is near-free (direct scanout or one blit) | Agent on `ownback/ws-composite-cost` (running) | L | 1 per plugin build | Maps fullscreen smooth |
| A2 | Plugin build: logging build, NVIDIA paths (A22) | One release driver, quiet log | Release configuration (`NVMTL_DIAG` only on request); remove NVIDIA code (refactor, byte-checks per step) | M | 1 | none |
| A3 | Metal feature answers (A16) | Answers match the real GPU family (Mac2, AMD) | Conformance pass against Apple's feature tables for an AMD Mac; fix wrong answers | M | 1 | apps that probe features |
| A4 | RADV device info canned (A19), VRAM 6 GiB cap (A11), GPU name, VRAM size, Activity Monitor (item 8) | Values from the hardware; `PerformanceStatistics` with utilization | Read GC config and VRAM size from the hardware (read-only registers / VBIOS tables, rule 3); GPU name from the device; publish utilization | M | 1-2 (RADV = trust + EFI) | About This Mac, Activity Monitor |
| A5 | WebGL shader cache can't be stored (A14) | Safari's GPU process caches in its container | Cache path the sandbox allows | S | 1 | WebGL page loads twice, fast |
| A6 | Video decoder on the system volume (M, TODO 09) | Decoders load through AppleGVA from a normal bundle path | `PhxVA.bundle` route from `/Library/GPUBundles`; then restore the sealed snapshot (owner's OK: system volume) | M | 2 | YouTube HEVC/AV1 |
| A7 | passd started by a login agent | T2 Mac: service exists, passd starts at login | `ryzentosh-sse` kext (own thread), then remove `local.phxpassd` | S | 1 (EFI) | Music opens fast at once after login |

## Track B: kernel and display (designs now, hw-safety, boots later)

| # | Row (STATUS ref) | What a Mac does | Fix | Size | Boots | Owner test |
|---|---|---|---|---|---|---|
| B1 | GPU power-up by a user-space daemon (D3); boot to desktop via WindowServer restart, login rewrites, auto-login by the daemon (D2, D28); Metal device after the daemon (A1); OpenGL ~2 min after login (A10); DP audio set up by the daemon ~2.5 min after boot (M); idle power by daemon flags (M); release shape (M) | The kext brings the GPU up in `start`, before WindowServer; Metal, GL and audio exist at login | Bring-up in `PhxBringup::start` from Linux amdgpu's sequence (hw-safety at every step), DC audio programmed by the kernel with the display, DPM in the kext; the daemon shrinks to nothing | XL | many, one step per boot | cold boot to an accelerated login with sound |
| B2 | Mode setting from replayed Linux captures (D10, D14); other sizes by CPU copy (D11); a failed EDID read serves another EDID (D15) | The driver computes timings and trains the link itself from EDID/DPCD | Own DCN mode setting and link training (hw-safety), GPU present at every size, report "no EDID" | XL | many | every mode, every size |
| B3 | VermilionAccel from the AuxKC with an Allow click (A20) | Kexts load without a user click | Load from OpenCore (dependencies outside the Boot KC) | L | 1-2 | no Allow prompt |
| B4 | VermilionTrust with fixed AMFI offsets (A21) | No library-validation patch at all on a Mac | Find the slots at boot and refuse cleanly; cdhashes as data. Long term: signing that needs no patch | M | 1 | none |
| B5 | Warm restart without the SMU unload (D5, D6) | Driver quiesces the GPU before restart | Linux's SMU unload at restart (hw-safety) | M | 2 | restarts, no stall reports |
| B6 | Boot picker, verbose text, no Apple logo (D1) | Apple logo, no picker | Release profile in ryzentosh (EFI change) | S | 1 | boot looks like a Mac |

## Track C: release and the rest of phase 2 (agents started 2026-11-25 ~20:15)

The owner's target widened the same evening: publishable for real users by the end of the week, clean install.

| # | Item | Agent branch |
|---|---|---|
| C1 | Release readiness: install shape, firmware sourcing, licence audit, Apple-code and personal-data scan, other-machine safety, user docs, installer, release checklist | `ownback/release-readiness` |
| C2 | HDR (item 4), replug / monitor power / input switch (5), display sleep (6), DDC/CI (9), Night Shift / calibration (D22) | `ownback/display-parity` |
| C3 | GPU hang recovery (7), 4K video async decode, H.264, AV1 fallback, WebGPU render bundles (10) | `ownback/hang-video-parity` |
| C4 | Comparison with Apple's own AMD driver stack on this macOS (ioreg, Metal answers, PerformanceStatistics, install layout) | `ownback/apple-amd-comparison` |
| C5 | From the comparison (#33): per-process GPU time (N1), GPU sensors (N2), GPU counters for Instruments (N6), power-policy node (N8) | `ownback/gpu-stats-parity` |
| C6 | System Information ROM / Slot rows (N4), plugin bundle identity (N7), DP audio name's stray byte | `ownback/sysinfo-identity` |
| C7 | Hardware encode and IOGVA codec keys (N3) | `ownback/video-encode-parity` |

Apple ships no Navi 31 support (#33): the reference for parity is Apple's RDNA 2 (Navi 21/23) stack on this macOS.
Owner contact: a message that needs the owner starts with **PING!**. Subagents get a model sized to the task.

## Order

1. Now: agents on A2+A3, A4, A5+A6, B1 design, B2 design, B3+B4 design (A1 and A7 already running).
2. Installs, one per boot: A1 when ready, then A5, A2/A3 together only if one plugin build, A4, A7, A6.
3. B1 steps as the hw-safety review clears each one; B5 with B1; B3, B4, B6 after.
