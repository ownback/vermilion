<!-- SPDX-License-Identifier: MIT -->

# Metal feature answers against Apple's RDNA 2 Mac (2026-11-26)

Plan item A3 (the conformance pass behind STATUS A16): what the plugin answers for `MTLDevice` features and limits,
compared with what Apple's own AMD driver (`AMDRadeonX6000MTLDriver`, class `AMDMTLGFX10Device`, a Mac2-family device)
answers on an RDNA 2 Mac. Where an answer claims something RADV on Navi 31 can't do, or differs from Apple's AMD
answer without a reason, it was changed; where this GPU genuinely does more or less, the honest answer stays.

## What was checked, and how far it can be trusted

- **Ours before:** `tools/metaltest/mtlq.m` on the XTX machine (macOS 26.7.1, plugin as installed on 2026-11-26),
  read-only: `MTLCopyAllDevices` and property getters, no queue, buffer or pipeline. Verified on this machine.
- **Ours after:** the plugin source, and `tests/plugin/test_feature_answers.m` (new), which asks the fixed answers of a
  device object made without init (no accelerator, no Vulkan, no GPU). The rows that depend on RADV's limits were not
  re-measured: the new build is not installed. `(unverified on hardware)`.
- **Apple AMD:** there is no RDNA 2 Mac here, so none of these answers was measured on Apple's driver. The sources are
  Apple's public Metal documentation for the Mac2 family (Mac GPU family 2: the AMD Radeon Pro 5000/6000 series and Vega
  Macs) and, for what the driver is built to do, `reference/apple-amd/05-metal-plugin.md`. Every Apple cell is
  `(public docs)`; a cell I could not pin down says `(unverified)`. Apple's own tables dated 2026-10-23 carry no
  Mac2/AMD column (finding `2026-11-25-apple-amd-comparison.md`, M10), so the older Mac2 tables and the API docs are the
  reference. An owner-supplied `mtlq` run from a 2019 Mac Pro with a W6800X would turn them into measured cells.
- **Correction to the comparison finding (M8):** it read "argument buffers tier 1" from `mtlq`, which prints the raw
  enum. `MTLArgumentBuffersTier1` is 0 and `Tier2` is 1, so the printed `1` is **Tier 2**, and the plugin has always
  answered Tier 2 (`-argumentBuffersSupport`). The row is not a gap. Read-write textures print `2` = `Tier2` (None 0,
  Tier1 1, Tier2 2): also Tier 2.

## The table

| Answer | Ours before | Ours after | Apple AMD | Source and reason |
|---|---|---|---|---|
| `supportsFamily:` Common1, Common2, Common3 | yes | yes | yes | `-supportsFamily:` switch (NVMTLDevice.m). Same |
| `supportsFamily:` Mac1 (2001, deprecated), Mac2 | yes | yes | yes | Same |
| `supportsFamily:` Metal3 (5001) | yes | yes | yes (RDNA 2 on macOS 26) | Same |
| `supportsFamily:` MacCatalyst1, MacCatalyst2 (4001, 4002) | **no** | **yes** | yes (both, public docs: a Catalyst app asks for these on any Mac with the Mac families) | **Changed.** No hardware reason to refuse: they are the Mac1/Mac2 contract. A Catalyst port that checks `.macCatalyst2` was told its GPU is too old. `test_feature_answers.m` fails on the old build, passes on the new one |
| `supportsFamily:` Apple1-9 | no | no | no | Same (Apple-silicon families) |
| `supportsFamily:` Metal4 (5002) | no | no | no (Metal 4 is Apple silicon only, public docs) | Same |
| `supportsFeatureSet:` macOS GPUFamily1_v1 .. GPUFamily2_v1 (10000-10005, includes ReadWriteTextureTier2 10002) | yes | yes | yes | Same |
| `argumentBuffersSupport` | Tier 2 | Tier 2 | Tier 2 | Same (see the correction above) |
| `readWriteTextureSupport` | Tier 2 | Tier 2 | Tier 2 | Same |
| `maxThreadsPerThreadgroup` | 1024 x 1024 x 1024 | same | 1024 x 1024 x 1024 | RADV workgroup size limits. Same |
| `maxThreadgroupMemoryLength` | 65536 | 65536 | 32768 (public docs: Mac2 table) | **Kept.** RDNA 3 has 64 KiB of LDS per workgroup and RADV reports it, so the GPU genuinely does more. An app that sizes from the device value gets more room; one that assumes 32 KiB is unaffected |
| `maxBufferLength` | 4095 MiB | 4095 MiB | not published; `(unverified)` | **Kept.** `min(maxStorageBufferRange, 3/4 of the working set)`: RADV caps a storage buffer range at 4 GiB - 1, and the working-set half is A4's (A11) |
| `supportsTextureSampleCount:` 2, 4, 8 / 16 | yes, yes, yes / no | same | 2, 4, 8 yes; 16 no | From RADV's colour and depth sample masks. Same |
| `supportsRaytracing`, `supportsRaytracingFromRender` | yes | yes | yes (public docs; Navi 21 has ray accelerators) `(unverified on this macOS)` | Follows `VK_KHR_acceleration_structure` + `VK_KHR_ray_query` on RADV (Navi 31 has them). Honest, and it follows the driver |
| `supportsPrimitiveMotionBlur` | no | no | no | Same |
| `supportsFunctionPointers`, `...FromRender`, `supportsDynamicLibraries`, `supportsRenderDynamicLibraries` | yes | yes | yes for compute; the render variants `(unverified)` | Plugin answers YES unconditionally (translator linking). Not re-qualified here; left as is |
| `supportsBCTextureCompression`, `isDepth24Stencil8PixelFormatSupported` | yes | yes | yes | RADV has BC on Navi 31; D24S8 exists on gfx11 |
| `supports32BitFloatFiltering`, `supports32BitMSAA`, `supportsQueryTextureLOD` | yes | yes | yes | Inherited from Metal.framework's table; not overridden |
| `supportsShaderBarycentricCoordinates`, `areBarycentricCoordsSupported` | yes | yes | yes | The translator emits `BaryCoordKHR`; RADV exposes `VK_KHR_fragment_shader_barycentric` on gfx10.3+. The plugin does not list the extension in its device extension request, which works because RADV decides on the device, not the enabled list `(unverified on hardware)` |
| `supportsPullModelInterpolation` | no | no | yes `(unverified)` | **Kept, a gap.** The plugin has no pull-model interpolation (`interpolate_at_*`); answering yes would be a false claim. Follow-up if the translator grows it |
| `areRasterOrderGroupsSupported` | no | no | yes (public docs: Mac2) | **Kept, a hardware reason.** RADV does not expose `VK_EXT_fragment_shader_interlock` (AMD hardware has no ROV-style ordering exposed through Mesa). Apps fall back to their non-ROG path |
| `areProgrammableSamplePositionsSupported` | no | no | yes (public docs: Mac2) | **Kept, a gap with a software reason.** RADV has `VK_EXT_sample_locations`, but the plugin turns the backend off unless the driver provides the NVK-only depth-contract hooks (`nvmtl_nvk_sample_depth_*`, see "NVIDIA code still there"). Needs a RADV qualification on hardware. Follow-up |
| `supportsVertexAmplificationCount:` (2) | no | no | yes, up to 2 `(public docs)` | **Kept, a gap.** Not implemented in the plugin; RADV has multiview, so it is possible. Follow-up |
| `supportsRasterizationRateMapWithLayerCount:` | no | no | `(unverified)` | Not implemented. Left |
| `supportsCounterSampling:` draw, dispatch, blit | yes | yes | yes | Same |
| `supportsCounterSampling:` stage, tile dispatch | no | no | no (AMD Macs: no stage boundary; tile is Apple silicon) | Same |
| `counterSets` | timestamp | timestamp | timestamp, statistic, stageUtilization (`reference/apple-amd/05-metal-plugin.md` 5.2) | **Gap, N6** (GPU counters), not part of this pass |
| `sparseTileSizeInBytes` | 16384 | 16384 | 65536 `(unverified)` | The plugin does not do hardware sparse textures on RADV (the sparse-bind probe is NVK-only), so the number is moot. Left |
| `isLowPower`, `isRemovable`, `hasUnifiedMemory` | no, no, no | no, no, no | no, no (no for a slot dGPU; the MPX module is not removable), no | Same |
| `isHeadless` | follows the AMD-panel signal (`debug.nmxaccel_headless`) | same | no on a display GPU | Same: no on the XTX machine |
| `supportsBufferlessClientStorageTexture` | no | no | no (Intel/AMD Macs) | Same; already conformant |
| `name` | `... (RADV NAVI31) (NVMTL over ...)` | unchanged | "AMD Radeon RX 6800 XT" style | **A4's** (GPU name). Not touched here to avoid colliding with that branch |
| `architecture.name` | `nvk_amd_radeon_rx_7900_xtx_radv_navi31_` | unchanged | an AMD family name `(unverified)` | The `nvk_` prefix is NVIDIA-fork residue. Not changed: without Apple's string there is nothing right to change it to. With A4 |
| `recommendedMaxWorkingSetSize` | 6144 MiB | unchanged | about the VRAM size | **A4's** (A11) |
| MPS: tables (`MPSPlugin_GFX10.dict`, Tensile kernels) | none | none | shipped in the MTL bundle | **Gap, A12/STATUS item 7**; not a feature answer |

## What changed in the code

- `-[NVMTLDevice supportsFamily:]` answers yes for `MTLGPUFamilyMacCatalyst1` and `...Catalyst2` (`src/metal-plugin/NVMTLDevice.m`).
  That is the only answer that moved. Nothing claims more than before besides it.
- `tests/plugin/test_feature_answers.m`: the fixed answers above, hardware-free, logging build.

## NVIDIA code still there (for the next refactor)

Removed in this branch: the SASS launcher and vendor compiler, NVDEC/NVENC registration, the ANGLE rule, the NVAccel and
0x10de vendor branches, the NVK file-descriptor shim. Left, because each is tied into residency or WindowServer paths
that other branches (A1) are editing, and is inert on RADV (the symbol is not in RADV, so the pointer is NULL):
`nvmtl_nvk_stage_import` (family VRAM for IOSurfaces, `nvmtl_vk_surface_vram`), `nvmtl_nvk_sparse_bind_v1` (res3/res2
residency, `g_sparse`), `nvmtl_nvk_sample_depth_contract_v1` / `..._image_v1` (the reason programmable sample
positions are off), `nvmtl_vk_accel_surface_wait` (asks for an `NVAccel` service that does not exist here), the
`nvrm610.conf` file and `NVRM_`/`NVK_` knob prefixes (names stay, NAMING.md), the GL renderer's "nvidia" profile patch in
`NVMTLGL.m`, and the NVIDIA SM-count fallback in `nvmtl_corecount.c`. `nvmtl_nvk_surface_dirty` is **not** NVIDIA-only:
RADV's Darwin patch exports it.

## Not verified on hardware

The new plugin was built and its fixed answers tested without a GPU; it was not installed or run. In particular
unverified: that the release configuration behaves on the XTX machine as the logging build did (WindowServer, Maps, Chrome,
the decode service); every Apple AMD cell above; the barycentric and ray-tracing answers on this RADV build.
