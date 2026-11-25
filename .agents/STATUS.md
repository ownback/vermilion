# Status

Kept by the megamind ([ROADMAP.md](../ROADMAP.md), "How the work runs"). Last audit: 2026-11-24 (phase 1), on the
XTX machine (macOS 26.7.1 25G241, EFI change 33, VermilionBoot b160, VermilionAudio 1.7.2, HDR off by flag).

The evidence for every row is in the audit findings, by row number:
[display](findings/2026-11-24-audit-display.md) (D), [acceleration and APIs](findings/2026-11-24-audit-accel.md) (A),
[media and system](findings/2026-11-24-audit-media-system.md) (M), and the
[last threads' state](findings/2026-11-24-audit-thread-handover.md). States: **works**, **broken**, **missing**,
**not standard** (works, but not as Apple would ship it). Size: S about a day, M days, L weeks.

## Phase 2 order: stabilise

Ranked by what a Mac user notices, safety first. Each item is a branch and a PR.

| # | Item | Why now | Size | Refs |
|---|---|---|---|---|
| 1 | **Safety fixes. Done 2026-11-25** (#22, deploy steps a-c live and passed; open: the owner's picker check). Remove `debug.phxfb_kill_iondrv` (terminates a driver on the GPU's PCI function); `bringup_navi31.sh` refuses a warm GPU (PSP sOS alive) instead of loading SMU firmware; no "Reset NVRAM" advice in the daemon log and `docs/XTX.md`, the picker entry hidden; OWNER-TESTS 04 sleep test marked blocked; read the 00:05 replug logs for an ab30 detach before any replug test | Hard rule 1 | S | D risks 1-4, M risks |
| 2 | **App crashes in the plugin.** Music's readback (`nvmtl_vk_image_read`, twice today with the guard in place); Maps' null texture; never hand WindowServer a nil command buffer | Apps crash daily | S-M | A7, A8, A6 |
| 3 | **The recovery trap and the GOP fallback.** After a freeze every boot is a safe desktop until an `rm`; the GOP revert can't run because `phxfb-squat` can't be cleared (`DisableVariableWrite`). The kext decides the squat itself; the daemon returns to the full desktop after clean boots and tells the user | One freeze costs a degraded machine; hard rule 1 (keep the fallbacks) | M | D7, D30, D risk 3 |
| 4 | **HDR back on.** The plugin's widen path shows stale frames when WindowServer composites BGRA | HDR is off on an HDR OLED | M | D16, M |
| 5 | **Replug, monitor power, input switch.** Black until a restart; then audio after a replug | Every monitor power-cycle needs a restart | L | D18, M |
| 6 | **Display sleep** (DPMS off / on from the Linux capture) | The OLED never goes to standby | M | D9, TODO 05 |
| 7 | **GPU hang recovery.** Per-submission timeout and amdgpu's queue recovery for Navi 31 (hw-safety); covers the clpeak MPS hang | One stuck shader ends the session | L | A6, A12 |
| 8 | **Small visible fixes:** GPU name without "(RADV NAVI31) (NVMTL over ...)"; OpenGL on from NMXAccel's start; VRAM working set from the hardware, not 6 GiB (rule 3); Activity Monitor GPU utilization; DP audio name's stray byte; the Dock / Spotlight / Photos deny list tested and removed | The GPU looks wrong in the system | S each | A2, A3, A4, A9, A10, M |
| 9 | **DDC/CI over DP AUX** (MonitorControl, BetterDisplay: brightness and volume) | Owner requirement; a known limit that must work | M | D21 |
| 10 | **Video:** 4K AV1 frames in flight; WebGPU render bundles (Safari GPU process crash); H.264 decode; AV1 fallback | YouTube 4K stutters; WebGPU crashes take every tab's video | M-L | M, A15, TODO 13 items 11-13 |

Item 1 is merged (#22). A warm macOS restart leaves the sOS stopped (C2PMSG_81 = 0, one probe, 2026-11-25:
[finding](findings/2026-11-25-warm-restart-sos-cold.md)), so the warm refusal doesn't fire on a restart. Deploy step
(a) (daemon + `navi31_up.sh` + `bringup_navi31.sh` in `~/gpu`, rollback in `~/vermilion-rollback/safety-fixes-a`)
is live since 2026-11-25 06:47 and passed on a warm restart: `sOS check: C2PMSG_81=0x00000000 (cold)`, `navi31 up:`,
`SUCCESS at 06:50:12`, 240 Hz, the new `nvstuck:` wording. Note: that boot logged `nvstuck: still a squat boot`
(the stuck-squat state of item 3 is live on this machine). The cold-boot check of (a) waits for the owner's next
power-on. Step (b), EFI change 34 (stage `vermilion-trust-bar1g-audio` without `ResetNvramEntry.efi`, the live
kexts reused, `config.plist` differs only by that driver entry), live since 2026-11-25 06:56; `EFI/OC.prev` = change 33,
copies of 33 and 32 in `~/vermilion-rollback/EFI-OC.change3{3,2}-20261125`. Passed: `squat boot ...: 1`,
`SUCCESS at 06:58:58`, `debug.phxtrust_stat` `mode=enforce` `denied_unlisted=0`, `debug.phxaudio_stat` patched and
matched. Open: the owner confirms by eye that the picker has no Reset NVRAM entry. Rollback: swap `EFI/OC` and
`EFI/OC.prev`. Step (c): VermilionAccel from main (`03c1e47d`, UUID `6FDD9916`) live since 2026-11-25 07:01 and passed:
`debug.phxfb_kill_iondrv` unknown oid, `debug.phxgl` answers, the loaded UUID matches, `NMXAccel up`, `PhxAMDFB on panel`,
`SUCCESS at 07:03:57`. Rollback copy (`2578b185`) in `~/vermilion-rollback/VermilionAccel.kext.pre-killiondrv`. Seen by the item 1 agent, not fixed: after a bring-up failure that isn't the warm refusal, the daemon
still claims the GPU (part of item 3). Seen by the Fable pass on #22 (`8a663b0`), open (its stderr point is fixed in `71f87e9`):
- a warm refusal on a squat boot (every boot here) goes `m2_fail` → `squat_reboot` → a second warm reboot → a stuck,
  dark squat boot; after a power-off the safe desktop until the `rm` (item 3 territory);
- `m2_fail` after a refusal still runs `debug.phxagdc=0` and `apps_only` on the untouched GPU: unreviewed;
- the audit finding (`2026-11-24-audit-display.md`) still calls `debug.phxfb_kill_iondrv` live; it is gone since 07:01.

Item 2: a read-only root-cause agent started 2026-11-25 07:05 and was stopped at 07:10 for the owner's shutdown;
restart it with the same brief (finding `2026-11-25-plugin-crashes-root-cause.md`, branch `ownback/plugin-crash-rca`).
Step (a)'s cold-boot check passed 2026-11-25 11:40 (power-off, `sOS check: C2PMSG_81=0x00000000 (cold)`, `SUCCESS at
11:42:43`).

System sleep, HDMI, a second monitor and the release shape need the phase 3 work first (bring-up in the kernel, own
mode setting).

## Display and boot

| Part | State | Next step | Ref |
|---|---|---|---|
| 2560x1440 at 60 / 120 / 144 / 240 Hz, VRR 60-240 | works, not standard (replayed Linux captures, always through 144 Hz) | Own mode setting and link training (phase 3) | D10, D14 |
| Other sizes of the LG | works, not standard (fixed rates, CPU copy) | GPU present at every size | D11 |
| Other monitors, a second monitor, HDMI, HiDPI modes | missing | After own mode setting; pipe allocator; HDMI capture | D12, D13, D19, D20 |
| HDR | broken (off by `phxboot-nohdr`) | Phase 2 item 4 | D16 |
| Replug / monitor power / input switch | broken | Phase 2 item 5 | D18 |
| Night Shift, calibration (head-0 gamma) | broken (gamma dropped; effect unverified by eye) | Owner eye test, then head-0 regamma (hw-safety) | D22, A23 |
| DDC/CI brightness and volume | missing | Phase 2 item 9 | D21 |
| EDID and display identity | works (a failed read serves another monitor's EDID) | Report no EDID instead | D15 |
| Boot picker, verbose text, no Apple logo | not standard | Release profile (ryzentosh) | D1 |
| Boot to desktop (WindowServer restart, login rewrites, auto-login by the daemon) | not standard | Bring-up in the kernel (phase 3) | D2, D28 |
| GPU power-up by a user-space daemon | not standard (ROADMAP list) | Bring-up in `PhxBringup::start` (phase 3, hw-safety) | D3 |
| Cold boot | works (two boots stopped with no log, 2026-11-23) | Panic / early-boot record (NVRAM write test) | D4, D29 |
| Warm restart, shutdown | works (no GPU quiesce at restart; stall reports) | Linux's SMU unload at restart (hw-safety) | D5, D6 |
| After a freeze | broken (manual repair) | Phase 2 item 3 | D7 |
| System sleep | missing (`disablesleep 1`) | GPU suspend / resume (phase 3) | D8 |
| Display sleep | broken (black, no standby) | Phase 2 item 6 | D9 |
| Recovery, Safe Mode, installer | unverified (likely no picture: the squat stays armed) | Kext skips the squat there; owner test | D30 |

## Acceleration and graphics APIs

| Part | State | Next step | Ref |
|---|---|---|---|
| Metal for apps (Metal 3, Mac2 family) | works | Device at boot, not after the daemon (phase 3) | A1 |
| Desktop compositing | works, not standard (system-memory surfaces, flip from user space, ~15x below Linux in Horizon) | Phase 4 | A5 |
| Core Image, Core Animation | works | Speed only | A13 |
| OpenGL 4.1 (Apple's renderer over our Metal) | works, not standard (on ~2 min after login) | Phase 2 item 8 | A10 |
| OpenCL | works (6 GiB cap) | Phase 2 item 8 | A11 |
| MPS, Core ML | broken in part (clpeak hang) | Phase 2 item 7 | A12 |
| WebGL in Safari | works, not standard (shader cache can't be stored) | Writable cache path | A14 |
| WebGPU in Safari | broken (20 of 43 samples; render bundles crash the GPU process) | Phase 2 item 10 | A15 |
| Vulkan for apps | works (opt-in loader) | Phase 4 | A18 |
| Games | slow (Horizon 292 vs 4370 fps on Linux) | Phase 4 | A17 |
| Music, Maps | broken (plugin crashes) | Phase 2 item 2 | A7, A8 |
| GPU hang or lost GPU | missing recovery | Phase 2 item 7 | A6 |
| GPU name, VRAM size, Activity Monitor GPU history | broken / missing | Phase 2 item 8 | A2-A4 |
| Metal feature answers vs a real AMD Mac | not standard (untested claims, some wrong answers) | Conformance pass | A16 |
| RADV device info (canned profile, constants) | not standard (rule 3) | Read GC config from the hardware | A19 |
| VermilionAccel from the AuxKC (Allow click) | not standard (ROADMAP list) | Load from OpenCore (L; dependencies outside the Boot KC) | A20 |
| VermilionTrust (fixed AMFI offsets) | works, not standard (ROADMAP list) | Find the slots at boot, refuse cleanly; cdhashes as data | A21 |
| Plugin build (logging build daily, NVIDIA paths) | not standard | Release configuration; remove NVIDIA code (refactor) | A22 |

## Video, audio, power, sensors

| Part | State | Next step | Ref |
|---|---|---|---|
| HEVC and AV1 decode | works, not standard (bundle on the system volume, seal broken) | AppleGVA route (`PhxVA.bundle` from `/Library/GPUBundles`; TODO 09) | M |
| 4K YouTube | broken (stutters; ~13.3 ms per frame, synchronous) | Phase 2 item 10 | M |
| H.264, VP9 decode | missing | Phase 2 item 10 (VP9 after checking what a real Mac does) | M |
| Hardware encode (FaceTime, exports, AirPlay sender) | missing (not in TODO before this audit) | VCN encode via RADV Vulkan Video (hw-safety), phase 3 | M |
| DP audio to the LG | works (owner-tested), not standard (set up by the daemon, a Lilu patch); merged in #20 | PhxAMDFB publishes the audio properties, the kernel programs DC audio | M, thread handover |
| DP audio sequencing vs Linux | works, three order differences (hw-safety review 2026-11-24) | TODO 04 follow-ups; decision on the branch | decisions.md |
| GPU idle power | works, not standard (daemon flags) | DPM in the kext (phase 3) | M |
| GPU temperature, fan, power in Mac apps | missing | Publish SMU metrics in PerformanceStatistics | M |
| Release shape (one kext + config snippet) | missing (4 kexts, daemon, 21 flag files, firmware in `~/gpu`, decoder on the system volume) | TODO 06 order, then bring-up in the kext | M |

## Tooling and repo

- `machine-lock` didn't parse since #18 (missing `esac`): fixed on `ownback/megamind`, `guard_test` runs it.
- The guard blocked read-only SIP status reads: fixed on `ownback/megamind`.
- The guard blocks a Bash command as "changes the machine" when its text only mentions the rollback folder or the
  ESP mount path (seen 2026-11-24 in two docs edits): a false positive to fix in `guard.py`.
- `efi/build.py build` without `--stage` builds the 256 MiB BAR stage, not the live `vermilion-trust-bar1g`: one clear
  default needed (thread 02).
- The link gate passed a kext that can't load from OpenCore (IOGraphicsFamily is in the System KC) (thread 04).
- `~/gpu/phxboot-navi31.sh` and `phxboot-pre.sh` belong to the desktop user but run as root (TODO 06).
- `src/vermilion-accel/accel/re/IOGraphicsAccelerator2.h:18` quotes an instruction from Apple's binary (rule 6,
  inherited): review.
- Local branches `worktree-agent-a264…`, `worktree-agent-a98b…` are old and not in main; delete with the owner's OK.

## Open decisions

- The XT question (keep the detection code, drop it, rename): the owner's.
- HDMI output: after phase 2, before ryzentosh (owner, 2026-11-24).
