// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Vermilion contributors
//
// mtlq: read-only Metal device query (name, registry ID, families, limits, feature flags, counter sets). No queue,
// buffer or pipeline is created, so it puts no load on the GPU. Used for finding 2026-11-25-apple-amd-comparison.
// Build: xcrun clang -arch x86_64 -fobjc-arc -O0 -Wno-deprecated-declarations -o mtlq tools/metaltest/mtlq.m \
//        -framework Foundation -framework Metal
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
int main(void) { @autoreleasepool {
  NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
  id<MTLDevice> def = MTLCreateSystemDefaultDevice();
  printf("MTLCopyAllDevices: %lu; default: %s\n", (unsigned long)all.count, def.name.UTF8String ?: "(nil)");
  for (id<MTLDevice> d in all) {
    printf("name '%s'\n", d.name.UTF8String);
    printf("registryID 0x%llx location %ld locationNumber %lu peerGroupID %llu peerIndex %u peerCount %u\n", d.registryID, (long)d.location, (unsigned long)d.locationNumber, d.peerGroupID, d.peerIndex, d.peerCount);
    printf("lowPower %d headless %d removable %d unified %d\n", d.isLowPower, d.isHeadless, d.isRemovable, d.hasUnifiedMemory);
    printf("recommendedMaxWorkingSetSize %llu MiB, maxBufferLength %lu MiB, maxTransferRate %llu, currentAllocatedSize %lu\n", d.recommendedMaxWorkingSetSize >> 20, (unsigned long)(d.maxBufferLength >> 20), d.maxTransferRate, (unsigned long)d.currentAllocatedSize);
    printf("maxThreadgroupMemoryLength %lu, maxThreadsPerThreadgroup %lux%lux%lu\n", (unsigned long)d.maxThreadgroupMemoryLength, (unsigned long)d.maxThreadsPerThreadgroup.width, (unsigned long)d.maxThreadsPerThreadgroup.height, (unsigned long)d.maxThreadsPerThreadgroup.depth);
    if ([d respondsToSelector:@selector(architecture)]) printf("architecture '%s'\n", d.architecture.name.UTF8String);
    printf("families: common1 %d common2 %d common3 %d mac1 %d mac2 %d metal3 %d apple1 %d apple7 %d apple9 %d metal4(5002) %d\n",
      [d supportsFamily:MTLGPUFamilyCommon1], [d supportsFamily:MTLGPUFamilyCommon2], [d supportsFamily:MTLGPUFamilyCommon3], [d supportsFamily:MTLGPUFamilyMac1], [d supportsFamily:MTLGPUFamilyMac2], [d supportsFamily:MTLGPUFamilyMetal3], [d supportsFamily:MTLGPUFamilyApple1], [d supportsFamily:MTLGPUFamilyApple7], [d supportsFamily:MTLGPUFamilyApple9], [d supportsFamily:(MTLGPUFamily)5002]);
    printf("raytracing %d fromRender %d functionPointers %d fpFromRender %d dynamicLibraries %d renderDynLibs %d primitiveMotionBlur %d\n", d.supportsRaytracing, d.supportsRaytracingFromRender, d.supportsFunctionPointers, d.supportsFunctionPointersFromRender, d.supportsDynamicLibraries, d.supportsRenderDynamicLibraries, d.supportsPrimitiveMotionBlur);
    printf("BC %d d24s8 %d 32bMSAA %d 32bFloatFilter %d queryLOD %d pullModel %d barycentric %d\n", d.supportsBCTextureCompression, d.isDepth24Stencil8PixelFormatSupported, d.supports32BitMSAA, d.supports32BitFloatFiltering, d.supportsQueryTextureLOD, d.supportsPullModelInterpolation, d.supportsShaderBarycentricCoordinates);
    printf("argBuffers tier %lu readWriteTexture tier %lu rasterOrderGroups %d progSamplePos %d\n", (unsigned long)d.argumentBuffersSupport, (unsigned long)d.readWriteTextureSupport, d.areRasterOrderGroupsSupported, d.areProgrammableSamplePositionsSupported);
    printf("barycentricCoord %d sparseTileSize %ld samples 2/4/8/16: %d %d %d %d\n", d.areBarycentricCoordsSupported, (long)d.sparseTileSizeInBytes, [d supportsTextureSampleCount:2], [d supportsTextureSampleCount:4], [d supportsTextureSampleCount:8], [d supportsTextureSampleCount:16]);
    printf("counterSets: %s\n", [[d.counterSets valueForKey:@"name"] componentsJoinedByString:@","].UTF8String ?: "none");
    printf("supportsCounterSampling stage/draw/dispatch/blit/tile: %d %d %d %d %d\n", [d supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary], [d supportsCounterSampling:MTLCounterSamplingPointAtDrawBoundary], [d supportsCounterSampling:MTLCounterSamplingPointAtDispatchBoundary], [d supportsCounterSampling:MTLCounterSamplingPointAtBlitBoundary], [d supportsCounterSampling:MTLCounterSamplingPointAtTileDispatchBoundary]);
    printf("supportsVertexAmplificationCount 2 %d, supportsRasterizationRateMap %d, supportsPlacementHeaps? n/a\n", [d supportsVertexAmplificationCount:2], [d supportsRasterizationRateMapWithLayerCount:1]);
    if ([d respondsToSelector:@selector(isRemovable)]) printf("busy-state check skipped\n");
  }
}
return 0; }
