# XTX-only board gate (VermilionBoot b161, VermilionAccel 0.1.1, VermilionAudio 1.7.3)

Owner decision 2026-11-25 (decisions.md, "Release decisions"; release audit item G1): RX 7900 XTX only, drop the XT.
Branch `ownback/xtx-only`.

## What changed

- `src/vermilion-boot/PhxGpuId.h` (new, kernel-free, host test `tests/kext/gpu_id_test.cpp`): vendor `1002`, device
  `744c`, revision `0xC8` is the only board that starts. Revisions per libdrm `data/amdgpu.ids` (fetched 2026-11-25):
  `744C,C8` XTX, `744C,CC` XT, `744C,CE` GRE, `744C,CF` 7900M. `0xC8` was read on the XTX machine (Linux sysfs
  `revision`, System Information; `2026-11-23-linux-reference.md`). `0xCC` is upstream's reading only.
- VermilionBoot: `PhxBringup::probe/start` and `PhxFBSquatter::probe/start` call `phxGpuAllowed` (three PCI config
  reads). A refusal logs one line and returns nil / false before IOService::start, the bus-master / memory-enable bits,
  any BAR map, `phx-build`, or the squat arming in the firmware variables. The PCI `model` is fixed to "AMD Radeon RX
  7900 XTX".
- VermilionAccel: `NMXAccel::probe/start` (NMX_ACCEL build) refuse the same boards (second gate).
- VermilionAudio: the AppleGFXHDA patch needs the GPU's registry `revision-id` to be `0xC8`.
- VermilionTrust: nothing to gate (it never looks at the GPU).
- Kept (documented as left over, `docs/XTX.md`): Mesa 0016's `navi31_xt` profile and 0018's fallback. They are
  unreachable once the kexts refuse an XT, but removing them is a RADV rebuild = new cdhash = VermilionTrust + EFI, a
  separate boot.

## hw-safety-reviewer verdict: approve with conditions ("safe to build")

No register write, SMU / PSP / DAL message or PCI config write is added; the only new hardware access is three PCI
config reads (vendor 0x00, device 0x02, revision 0x08), which Linux's PCI core does at enumeration too. A refused board
gets nothing else: no BAR, no command-register change, no change to the firmware variables (the squatter checks the
board before it takes the arming), AppleGFXHDA untouched. The boot daemon on a refused board finds no `phx-build` and
takes its existing fallback (one reboot at most, `m2_fail`, then the GOP display). On the XTX the behaviour equals b160
apart from the three extra reads and the fixed model string (b160's switch gave the same string for `0xC8`). Not run on
hardware.

Conditions, from the review:

1. Mesa 0018's fallback to `navi31_xt` is now wrong by construction: make `navi31` the default with the next RADV
   rebuild (follow-up, own boot).
2. On the first b161 boot confirm `phx-build` reads 161, there is no `Vermilion: ... not an RX 7900 XTX` line, and
   `debug.phxaudio_stat` says the table was patched, not "skipped: the GPU is not an RX 7900 XTX". If the 744c
   function is not yet registered when AppleGFXHDA loads, audio is skipped (safe, but no DP audio): then read the
   revision another way.

Stale text left for a later pass (comments only): `PhxDpbRetrain.h:51,220` and `PhxP0Odm.h:34` still accept the XT's
GOP DMCUB build `0x07008742` (a firmware-version gate, not a write); `phx_globals.cpp:76` calls `GB_ADDR_CONFIG 0x545`
the XT's value (the XTX reads the same); `PhxDmub.h:6` says "20 GB".

## Unverified

Every refusal path on real hardware: there is no other card on the XTX machine. The match decision is covered by the
host test (every revision byte, other devices and vendors, a dead function). The audio kext's `revision-id` read is
untested on hardware.
