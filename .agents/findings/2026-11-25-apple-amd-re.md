<!-- SPDX-License-Identifier: MIT -->

# Apple's AMD stack, reverse engineered (2026-11-25)

Read-only REA / Ghidra pass over Apple's RDNA 2 kexts and bundles on the XTX machine (macOS 26.7.1 25G241), per the
owner's release decision to use Apple's stack as the reference. The reference is in
[`reference/apple-amd/`](../../reference/apple-amd/README.md); the mapping to STATUS and the plan is
[`06-vermilion-map.md`](../../reference/apple-amd/06-vermilion-map.md). No machine change, no GPU work.

Main results:

- Apple's framebuffer kext compiles AMD's own Display Core (`dal/dc`, `dcn30`, `dml`, `dmub`) plus a C++ display
  manager ("falcon_dm"). For plan B2 the Apple route is DC + a thin DM; Navi 31's DC is `dcn32`.
- Bring-up happens in `start()`: HWServices picks a per-ASIC HWLibs plug-in, whose TTL runs AMD's SWIP sequence
  (Navi 21: BGM, GVM, PSP, SMU, GC, SDMA, MES, VCN, JPEG, DMCU). All firmware is compiled into HWLibs.
- Hang recovery: 5 s progress timeout (family default), blame, per-engine queue reset, full restart at most once,
  replay of innocent channels, deny an app after 2 restarts in 1000 submissions.
- `PerformanceStatistics`: `Device Utilization %`, `vramFreeBytes`, and `Core Clock(MHz)`, `Memory Clock(MHz)`,
  `GPU Activity(%)`, `Temperature(C)`, `Total Power(W)`, `Fan Speed(RPM)`, `Fan Speed(%)`.
- DDC/CI on an AMD Mac goes through `IOFBI2CInterfaceInfo` + `doI2CRequest` on the framebuffer.
- The framebuffer publishes `audio-codec-info` (`pin << 16 | 0x100`) and the other properties AppleGFXHDA needs;
  `ATY,Rom#` (System Information's ROM row) is the VBIOS part number.

Corrections to [#33's comparison](2026-11-25-apple-amd-comparison.md):

- `LoadAccelerator` / `LoadController` / `LoadHWServices` are set by the AMD GPU wrangler
  (`AmdGpuWrangler::vendor_doDeviceAttribute`, on a request from AppleGPUWrangler), not by `AMDSupport`.
- `MetalPluginClassName` is `AMDMTLGFX10Device`; `GFX10_MtlDevice` is an internal class.
- N8 (AGPM node): on the Mac Pro board AGPM's AMD entries have no heuristic (`ID -1`) and there is no entry for
  `0x744c` or `0x73bf`; DPM belongs in the kext, an AGPM node is not a parity gap.

Rule 6 note: these files quote condensed pseudo-code from Apple's binaries, allowed by the owner's decision of
2026-11-25. Firmware blobs, the extracted binaries and the full decompiled output stay outside git (rule 4).
