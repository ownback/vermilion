<!-- SPDX-License-Identifier: MIT -->

# Handoff: Megamind 2 to Megamind 3 (2026-11-25, ~21:00)

**Why:** Megamind 2's context is exhausted. Many delegates are running. They were started from Megamind 2's thread,
so their completion notices land there, not with you. Check their PRs by branch: `gh pr list --repo
ownback/vermilion-xtx --state all`, or `git ls-remote fork 'refs/heads/ownback/*'`.

**Owner's goal** (/goal, 2026-11-25): the repo publishable for real users by about 2026-11-29. That means a clean
install, 1:1 parity with a real Mac, and no workarounds. See memory `release-week-goal`. How to work with the owner:
- start any message that needs them with **PING!**;
- answer a yes/no question with yes or no;
- keep replies short;
- size each subagent's model to its task: Haiku for small work, Sonnet for medium, Opus for hard or GPU-safety work,
  Fable for the clean-up pass.

The plan is [PLAN-parity-week.md](PLAN-parity-week.md).

## Next three steps
1. Collect the delegates' PRs as they land. Each gets the `fable-cleanup` pass (Fable model), then a merge.
   Small review findings you fix yourself. Larger ones go back to a new delegate.
2. Install plugin and kext results one EFI change per boot, the same way as #25, #29 and #31:
   - a rollback copy of the live NVMTLDriver;
   - install as `.new` + `mv` into `/System/Library/CoreServices/CoreTypes.bundle/Contents/Library/PhxGPU/NVMTLDriver.bundle/Contents/MacOS/`
     (a firmlink into the Data volume, not the sealed snapshot);
   - `PHXTRUST_KEEP=1 sh scripts/build/trust.sh`;
   - build the EFI with `VERMILION_KEXT_DIR` set to a folder holding copies of the live VermilionBoot and
     VermilionAudio plus the new VermilionTrust, and `--stage vermilion-trust-bar1g-audio`;
   - `diff -rq` must show only VermilionTrust; then `install`;
   - follow the boot-cycle skill.

   #34 (passtime measurement) is merged but not installed: put it in the next plugin install. First candidate is
   `ownback/ws-vram-scanout` (composite fix 1). It needs its hw-safety verdict, then the owner's Maps test.
3. PR #32 (guard) must not merge until the fail-closed fix is in: delegate on branch `ownback/tooling-guard-efi`,
   which must block every bypass string from its review.

## Machine state
- **EFI change 37** is live: VermilionTrust 1.0.4 with 17 cdhashes. `EFI/OC.prev` is change 36.
- **EFI rollback copies:** `~/vermilion-rollback/EFI-OC.change34-20261125`, `EFI-OC.change35-20261125` and
  `EFI-OC.change36-20261125`.
- **NVMTLDriver** `62f86c5d` (#31) is live. Older builds are kept in `~/vermilion-rollback/NVMTLDriver.pre-crashfix-*`,
  `pre-allocfix-*` and `pre-asyncup-20261125`; all are still in the trust list as `-previous`.
- **Daemon:** #26 is live (record file `/var/db/phxboot.fails`; rollback in `~/vermilion-rollback/recovery-daemon-1`).
- **passd:** the `~/Library/LaunchAgents/local.phxpassd.plist` login agent starts passd at login. Remove it once the
  ryzentosh-sse kext lands.
- **The trust list** (`src/vermilion-trust/phxtrust_list.inc`, gitignored) exists in Megamind 2's worktree only. In a
  new checkout, seed it from the live `sysctl -n debug.phxtrust_files` before using `PHXTRUST_KEEP=1`; otherwise
  older entries are lost.
- **Lock and auto-login:** the machine lock is free, and auto-login is on.
- **Shell:** in zsh, `log` is a builtin; use `/usr/bin/log`.
- **sudo:** see memory `sudo-access`.

## Running delegates
| Branch | Scope |
|---|---|
| `plugin-release-parity` | A2 + A3: release build, NVIDIA removal, Metal feature answers |
| `device-info-parity` | A4: device info, VRAM size, GPU name, Activity Monitor |
| `webgl-cache-gva` | A5 + A6: WebGL cache, decoder via AppleGVA |
| `kernel-bringup-design` | B1 |
| `own-modeset-design` | B2 |
| `accel-trust-parity` | B3 + B4 (the owner dropped B3 afterwards: see [decisions.md](decisions.md), release decisions) |
| `release-readiness` | C1 |
| `display-parity` | C2 |
| `hang-video-parity` | C3 |
| `gpu-stats-parity` | C5 |
| `sysinfo-identity` | C6 |
| `video-encode-parity` | C7 |
| `ws-vram-scanout` | composite fix 1 |
| `tooling-guard-efi` | #32 fix |

Every branch above has the `ownback/` prefix. Separate thread: `ryzentosh-sse`, a private repo, building the honest
"no SSE" kext; it hands the kext to the megamind for an EFI change.

## Don't yet
- Merge #32 before its fail-closed fix.
- Install two plugin builds in one boot without combining them into one build.
- Change the system volume (the decoder's AppleGVA move) without the owner's OK.
- Run GPU load without the owner's OK.
