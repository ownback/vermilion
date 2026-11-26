// SPDX-License-Identifier: MIT
/* test_feature_answers.m - the Metal device answers that are fixed in the plugin (no Vulkan behind them), as
   .agents/findings/2026-11-26-metal-feature-answers.md lists them: GPU families, feature sets, argument buffer and
   read-write texture tiers, the flags an RDNA 2 Mac (Mac2) answers. The device object is made without init, so no
   accelerator, no Vulkan instance and no GPU is touched. Needs a logging build (the release build forgets the
   NVMTL_TEST_BACKEND_DOWN switch the plugin reads at load):
     PLUGIN_CONFIG=logging sh scripts/build/plugin.sh
     clang -framework Foundation -framework Metal tests/plugin/test_feature_answers.m -o /tmp/test_feature_answers
     /tmp/test_feature_answers build/NVMTLDriver */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdlib.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int fails;
static void arm(const char *w, int ok) { printf("%s  %s\n", ok ? "ok  " : "FAIL", w); if (!ok) fails++; }
int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <path to NVMTLDriver>\n", argv[0]); return 2; }
    setvbuf(stdout, NULL, _IONBF, 0);
    char logp[] = "/tmp/test_feature_answers.XXXXXX"; int fd = mkstemp(logp); if (fd >= 0) close(fd);
    setenv("NVMTL_TEST_BACKEND_DOWN", "1", 1);
    setenv("NVMTL_LOG_PATH", logp, 1);
    if (!dlopen(argv[1], RTLD_NOW)) { printf("FAIL  dlopen %s: %s\n", argv[1], dlerror()); return 1; }
    @autoreleasepool {
        Class D = objc_getClass("NVMTLDevice");
        arm("the plugin's NVMTLDevice class is there", D != Nil);
        if (!D) return 1;
        id<MTLDevice> d = (id<MTLDevice>)class_createInstance(D, 0);   // manual reference counting: never released, it was not init'ed
        arm("GPU families: Common1-3, Mac1, Mac2, Metal3",
            [d supportsFamily:MTLGPUFamilyCommon1] && [d supportsFamily:MTLGPUFamilyCommon2] &&
            [d supportsFamily:MTLGPUFamilyCommon3] && [d supportsFamily:MTLGPUFamilyMac1] &&
            [d supportsFamily:MTLGPUFamilyMac2] && [d supportsFamily:MTLGPUFamilyMetal3]);
        arm("GPU families: Mac Catalyst 1 and 2 (an RDNA 2 Mac answers YES to both)",
            [d supportsFamily:MTLGPUFamilyMacCatalyst1] && [d supportsFamily:MTLGPUFamilyMacCatalyst2]);
        arm("GPU families: no Apple1-9, no Metal 4",
            ![d supportsFamily:MTLGPUFamilyApple1] && ![d supportsFamily:MTLGPUFamilyApple4] &&
            ![d supportsFamily:MTLGPUFamilyApple7] && ![d supportsFamily:MTLGPUFamilyApple9] &&
            ![d supportsFamily:(MTLGPUFamily)1010] && ![d supportsFamily:(MTLGPUFamily)5002]);
        arm("feature sets: macOS GPUFamily1_v1 .. GPUFamily2_v1 (10000-10005) yes, 9999 and 10006 no",
            [d supportsFeatureSet:(MTLFeatureSet)10000] && [d supportsFeatureSet:(MTLFeatureSet)10005] &&
            ![d supportsFeatureSet:(MTLFeatureSet)9999] && ![d supportsFeatureSet:(MTLFeatureSet)10006]);
        arm("argument buffers tier 2, read-write textures tier 2",
            d.argumentBuffersSupport == MTLArgumentBuffersTier2 && d.readWriteTextureSupport == MTLReadWriteTextureTier2);
        arm("a discrete GPU: not low power, not removable, no unified memory",
            !d.isLowPower && !d.isRemovable && !d.hasUnifiedMemory);
        arm("BC compression, depth24-stencil8, function pointers, dynamic libraries",
            d.supportsBCTextureCompression && d.isDepth24Stencil8PixelFormatSupported && d.supportsFunctionPointers && d.supportsDynamicLibraries);
        arm("no primitive motion blur", !d.supportsPrimitiveMotionBlur);
        arm("counter sampling: draw, dispatch and blit boundaries, not stage or tile (as AMD Macs)",
            [d supportsCounterSampling:MTLCounterSamplingPointAtDrawBoundary] &&
            [d supportsCounterSampling:MTLCounterSamplingPointAtDispatchBoundary] &&
            [d supportsCounterSampling:MTLCounterSamplingPointAtBlitBoundary] &&
            ![d supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary] &&
            ![d supportsCounterSampling:MTLCounterSamplingPointAtTileDispatchBoundary]);
    }
    printf(fails ? "FAILED %d\n" : "all passed\n", fails);
    return fails ? 1 : 0;
}
