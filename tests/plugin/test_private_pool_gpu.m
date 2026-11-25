// SPDX-License-Identifier: MIT
/* test_private_pool_gpu.m - Maps' allocation pattern (finding 2026-11-25-maps-allocation-limit.md) through the public
   Metal API, against the INSTALLED plugin. NOT hardware-free: it runs on the GPU (a few MB, a few blits; ask the owner
   first, as for any GPU run). 12000 live Managed buffers of 96 B and 4000 Private ones of 128 B (each was a kext BO; the
   kext allows 4095 per process), then the 256x256 Private texture Maps died on, then blits that prove pooled ranges keep
   their own bytes and that a reused range reads as zeros. With the old plugin the texture comes back nil.
     clang -fobjc-arc -framework Foundation -framework Metal tests/plugin/test_private_pool_gpu.m -o /tmp/test_private_pool_gpu
     /tmp/test_private_pool_gpu
   Then: log show --last 5m --predicate 'subsystem == "org.vermilion.nvmtl" && process == "test_private_pool_gpu"' | grep -E "buffer pool|REFUSED"
   and sysctl debug.phxvm (no new "BO create refused ... handles"). */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <string.h>
static int fails;
static void arm(const char *w, int ok) { printf("%s  %s\n", ok ? "ok  " : "FAIL", w); if (!ok) fails++; }
enum { NMAN = 12000, NPRIV = 4000, MLEN = 96, PLEN = 128, NCHECK = 64 };

static NSMutableArray *make_managed(id<MTLDevice> dev, uint32_t seed, int *made)
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:NMAN]; *made = 0;
    for (uint32_t i = 0; i < NMAN; i++) {
        id<MTLBuffer> b = [dev newBufferWithLength:MLEN options:MTLResourceStorageModeManaged];
        if (!b) break;
        uint32_t *w = b.contents; for (uint32_t k = 0; k < MLEN / 4; k++) w[k] = (seed << 24) ^ (i << 8) ^ k;
        [b didModifyRange:NSMakeRange(0, MLEN)];
        [a addObject:b]; (*made)++;
    }
    return a;
}
static NSMutableArray *make_private(id<MTLDevice> dev, int *made)
{
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:NPRIV]; *made = 0;
    for (uint32_t i = 0; i < NPRIV; i++) {
        id<MTLBuffer> b = [dev newBufferWithLength:PLEN options:MTLResourceStorageModePrivate];
        if (!b) break;
        [a addObject:b]; (*made)++;
    }
    return a;
}
/* Managed[i] -> Private[j] -> readback, for NCHECK pairs spread over the arrays; and NCHECK untouched Private buffers
   straight to the readback (they must read as zeros). */
static int round_trip(id<MTLDevice> dev, id<MTLCommandQueue> q, NSArray *man, NSArray *priv, uint32_t seed, int *zeros_ok)
{
    id<MTLBuffer> rb = [dev newBufferWithLength:2 * NCHECK * PLEN options:MTLResourceStorageModeShared];
    memset(rb.contents, 0xA5, rb.length);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    for (uint32_t c = 0; c < NCHECK; c++) {
        const uint32_t i = c * (NMAN / NCHECK) + 7, j = c * (NPRIV / NCHECK);
        [be copyFromBuffer:man[i] sourceOffset:0 toBuffer:priv[j] destinationOffset:0 size:MLEN];
        [be copyFromBuffer:priv[j] sourceOffset:0 toBuffer:rb destinationOffset:c * PLEN size:MLEN];
        [be copyFromBuffer:priv[j + 1] sourceOffset:0 toBuffer:rb destinationOffset:(NCHECK + c) * PLEN size:PLEN];
    }
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("      command buffer status %ld error %s\n", (long)cb.status, cb.error.description.UTF8String); return 0; }
    int ok = 1; *zeros_ok = 1;
    const uint8_t *r = rb.contents;
    for (uint32_t c = 0; c < NCHECK; c++) {
        const uint32_t i = c * (NMAN / NCHECK) + 7; const uint32_t *w = (const uint32_t *)(r + c * PLEN);
        for (uint32_t k = 0; k < MLEN / 4; k++) if (w[k] != ((seed << 24) ^ (i << 8) ^ k)) ok = 0;
        for (uint32_t k = 0; k < PLEN; k++) if (r[(NCHECK + c) * PLEN + k]) *zeros_ok = 0;
    }
    return ok;
}

int main(void)
{
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        arm("a Metal device", dev != nil);
        if (!dev) return 1;
        printf("      device: %s\n", dev.name.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        int nm = 0, np = 0, zeros = 0;
        NSMutableArray *man = make_managed(dev, 1, &nm), *priv = make_private(dev, &np);
        arm("12000 live Managed buffers of 96 B", nm == NMAN);
        arm("4000 live Private buffers of 128 B", np == NPRIV);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
        td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        arm("then a 256x256 Private texture (Maps' nil texture)", t != nil);
        arm("Managed -> Private -> Shared blits keep every pooled buffer's own bytes", nm == NMAN && np == NPRIV && round_trip(dev, q, man, priv, 1, &zeros));
        arm("untouched Private buffers read as zeros", zeros);
        [man removeAllObjects]; [priv removeAllObjects]; man = priv = nil; t = nil;
        // the released ranges come back (after the GPU is past them) and are cleared for their next owner
        NSMutableArray *man2 = make_managed(dev, 2, &nm), *priv2 = make_private(dev, &np);
        arm("a second round of 12000 + 4000 buffers after the first was released", nm == NMAN && np == NPRIV);
        arm("second round: bytes kept, reused Private ranges read as zeros", nm == NMAN && np == NPRIV && round_trip(dev, q, man2, priv2, 2, &zeros) && zeros);
    }
    printf(fails ? "FAILED (%d)\n" : "all passed\n", fails);
    return fails ? 1 : 0;
}
