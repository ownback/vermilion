<!-- SPDX-License-Identifier: MIT -->

# 5. Metal and GL user-space drivers, and what they call in the kernel

Binaries: `AMDRadeonX6000MTLDriver` (dyld cache, about 20000 symbols), `AMDRadeonX6000Shared`, `AMDShared`.
Symbols and imports only; not decompiled. Tags: [O] observed, [I] inferred, [?] open.

## 5.1 How the bundles are found

The accelerator's `AMDGFX10GraphicsAccelerator::setDriverBundleNames` publishes [O]:

| Key | Value |
|---|---|
| `MetalPluginName` | `AMDRadeonX6000MTLDriver` |
| `MetalPluginClassName` | **`AMDMTLGFX10Device`** (#33 guessed `GFX10_MtlDevice`, that's the internal class) |
| `MetalStatisticsName` | `GFX10Statistics` |
| `GPURawCounterBundleName` | `AMDRawCounterPlugin` |
| `GPURawCounterPluginClassName` | `AMDRawCounterSourceGroup` |
| `IOGLBundleName` | `AMDRadeonX6000GLDriver` |
| `IOOCDBundleName` | `AMDRadeonX6000GLDriver` (OpenCL) |

Each is first set to `" "` and then to the value, so a reader never sees a stale name [O]. The raw-counter plug-in
pair is what Instruments' and Xcode's GPU counters load (#33 M9 / N6) [I].

## 5.2 The Metal driver's structure

- Built on Metal.framework's IOAccel base classes [O, imports]: `MTLIOAccelDevice`, `MTLIOAccelCommandQueue`,
  `MTLIOAccelCommandBuffer`, `MTLIOAccelRenderCommandEncoder`, `...ComputeCommandEncoder`, `...BlitCommandEncoder`,
  `MTLIOAccelBuffer`, `MTLIOAccelTexture`, `MTLIOAccelHeap`, `MTLIOAccelResourcePool`, `MTLIOAccelPooledResource`,
  `MTLIOAccelIndirectCommandBuffer`, `MTLIOAccelAccelerationStructure`, `MTLIOAccelIntersectionFunctionTable`,
  `MTLIOAccelVisibleFunctionTable`.
- AMD classes [O]: `GFX10_MtlDevice` / `GFXAAMD_MtlDevice`, `GFX10_MtlRenderCmdEncoder`, `GFX10_MtlComputeCmdEncoder`,
  `GFX10_MtlIndirectRenderCmd`, token encoders (`GFX10AmdMtlRenderCmdEncoderTokeniser`), `GFX10_MtlStatistics`,
  `Gfx10BltMgr` / `Gfx10BltDevice`, `Addr::` (AMD addrlib, the same library Mesa uses), `Tensile::` (GEMM kernels for
  MPS), `rocr::` (ROCm runtime pieces), RGP tooling (`AMD_cmd_buffer_sqtt`, `RgpSpmDataBase`), an API layer /
  interposer stack (`AMD_*_layer`, `AMD_*_interposer`), and ImGui / ImPlot (an internal HUD).
- Counters [O]: the `MTLCommonCounterSet{Timestamp,Statistic,StageUtilization}` sets with vertex, fragment,
  tessellation, compute, clipper, render-target-write, total cycles; "GPU utilization by the Vertex Stage", "by the
  Fragment Stage", "by the Texture Unit", "by the CP DMA block". Vermilion answers only `timestamp` (#33 M9).

## 5.3 What it calls in the kernel

Only through the IOAccelerator framework and `IOConnectCallMethod` [O, imports]:

| Call | Kernel side |
|---|---|
| `IOAccelDeviceGetConnect`, `IOAccelSharedGetConnect`, `IOAccelSharedSetupDirtyRing`, `IOAccelDeviceGetMaxResourceSize`, `IOAccelDeviceTraceEvent` | Family device / shared user clients |
| `IOAccelResourceGetClientShared`, `IOAccelResourceDirtyBufferRange`, `...DirtyFaceLevels`, `...DirtyVendorCommand`, `IOAccelResourceTestEvent` | `IOAccelResource2` / `AMDAccelResource` (`dirtyBufferRange`, `dirtyVendorCommand`) |
| `IOAccelResourceListAddResource(NoThreshold)` | Residency lists per command buffer (`addRsrcListToChannel`) |
| `MTLIOAccelCommandBufferStorage{BeginSegment,EndSegment,ResumeSegment,GrowSegmentList,GrowKernelCommandBuffer,AllocResourceAtIndex}` | Builds the segment list `AMDAccelCommandQueue::parseSegmentList` consumes ([03 §3.3](03-accelerator.md#33-command-submission)) |
| `IOConnectCallMethod` | Vendor selectors 0x100-0x117 ([03 §3.2](03-accelerator.md#32-user-clients)) |
| `IORegistryEntryCreateCFProperty`, `IORegistryEntryGetParentEntry` | Reads accelerator properties (device info) |
| `IOSurfaceLockPlane`, `IOSurfaceIsSysMemOnly`, plane getters | IOSurface interop |

The GL driver's main binary isn't in the dyld cache on 26.7.1 (only `ATIRadeonX6000SCLib.dylib`, the shader compiler
library) [O]; `IOGLBundleName` still names it.

## 5.4 Vermilion today vs this

| Apple | Vermilion | Gap |
|---|---|---|
| `MTLIOAccel*` subclasses, family command queue, segment lists | `NVMTLDriver`: Metal on Vulkan (RADV), its own submission through `N48N` | Architecture differs by design (Metal on Vulkan). Keep |
| `MetalPluginName` = bundle name, `MetalPluginClassName` set, no path trick | Relative path to `NVMTLDriver`, class `NVMTLDevice` (#33 K7) | A2 / N7: own bundle id and principal class |
| `MetalStatisticsName`, `GPURawCounterBundleName` + class | None | N6: a raw-counter plug-in over RADV perf counters |
| `IOOCDBundleName` | Absent | OpenCL bundle name (with A11) |
| Device info from the kernel (`QkGetGpuInfo`) | Canned in RADV (A19) | A4 |
| Tensile GEMM tables for MPS | None; MPS hang in part (A12) | Item 7 / A12 |
