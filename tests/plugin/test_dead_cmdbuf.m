// SPDX-License-Identifier: MIT
/* test_dead_cmdbuf.m - with the GPU backend down, the plugin hands out dead command buffers, never nil
   (src/metal-plugin/NVMTLDeadEncoder.m, audit row A6). Loads a built plugin, keeps its backend down with
   NVMTL_TEST_BACKEND_DOWN=1 (set before anything opens a GPU or loads RADV) and drives the public Metal API on its
   command queue. No GPU is touched. The plugin's log goes to a temporary file, not /tmp/nvmtl.log.
     PLUGIN_CONFIG=logging sh scripts/build/plugin.sh   (the release build forgets NVMTL_TEST_BACKEND_DOWN at load)
     clang -fobjc-arc -framework Foundation -framework Metal tests/plugin/test_dead_cmdbuf.m -o /tmp/test_dead_cmdbuf
     /tmp/test_dead_cmdbuf build/NVMTLDriver */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>
#pragma clang diagnostic ignored "-Wnonnull"   // nil arguments on purpose: a dead encoder must take anything
static int fails;
static void arm(const char *w, int ok) { printf("%s  %s\n", ok ? "ok  " : "FAIL", w); if (!ok) fails++; }
static void hung(int sig) { (void)sig; printf("FAIL  a dead command buffer hung (no completion in 20 s)\nFAILED\n"); _exit(1); }
static BOOL dead_error(id<MTLCommandBuffer> cb, NSInteger code) {
    return cb.status == MTLCommandBufferStatusError && [cb.error.domain isEqualToString:MTLCommandBufferErrorDomain] && cb.error.code == code;
}
int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <path to NVMTLDriver>\n", argv[0]); return 2; }
    char logp[] = "/tmp/test_dead_cmdbuf.XXXXXX"; int fd = mkstemp(logp); if (fd >= 0) close(fd);
    setenv("NVMTL_TEST_BACKEND_DOWN", "1", 1);
    setenv("NVMTL_LOG_PATH", logp, 1);
    if (!dlopen(argv[1], RTLD_NOW)) { printf("FAIL  dlopen %s: %s\n", argv[1], dlerror()); return 1; }
    signal(SIGALRM, hung); alarm(20);
    @autoreleasepool {
        Class Q = objc_getClass("NVMTLCommandQueue");
        arm("the plugin's NVMTLCommandQueue class is there", Q != Nil);
        if (!Q) return 1;
        id<MTLCommandQueue> q = [Q new];

        id<MTLCommandBuffer> cb = [q commandBuffer];
        arm("backend down: -commandBuffer returns a command buffer, not nil", cb != nil);
        arm("commandBufferWithUnretainedReferences and commandBufferWithDescriptor: too",
            [q commandBufferWithUnretainedReferences] != nil && [q commandBufferWithDescriptor:[MTLCommandBufferDescriptor new]] != nil);

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
        arm("its render encoder is not nil and is an MTLRenderCommandEncoder",
            re != nil && [re conformsToProtocol:@protocol(MTLRenderCommandEncoder)] && [re respondsToSelector:@selector(setVertexBytes:length:atIndex:)]);
        MTLViewport vp = { 0, 0, 100, 100, 0, 1 }; MTLScissorRect sr = { 0, 0, 10, 10 };
        [re setViewport:vp]; [re setScissorRect:sr]; [re setVertexBytes:&vp length:sizeof vp atIndex:0];
        [re setRenderPipelineState:nil]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        re.label = @"dead"; [re pushDebugGroup:@"g"]; [re popDebugGroup];
        arm("recording into it does nothing and keeps the label; its command buffer is the dead one",
            [re.label isEqualToString:@"dead"] && [(id)re commandBuffer] == cb);
        [re endEncoding];

        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
        [ce setComputePipelineState:nil];
        [ce dispatchThreadgroups:MTLSizeMake(4, 4, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        arm("compute encoder (with a dispatch type): not nil, records nothing, answers zero",
            ce != nil && [ce conformsToProtocol:@protocol(MTLComputeCommandEncoder)] && ce.dispatchType == 0);
        [ce endEncoding];
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromBuffer:nil sourceOffset:0 toBuffer:nil destinationOffset:0 size:16];
        [be fillBuffer:nil range:NSMakeRange(0, 16) value:0];
        arm("blit encoder: not nil, conforms, records nothing", be != nil && [be conformsToProtocol:@protocol(MTLBlitCommandEncoder)]);
        [be endEncoding];
        id<MTLParallelRenderCommandEncoder> pe = [cb parallelRenderCommandEncoderWithDescriptor:rp];
        id<MTLRenderCommandEncoder> sub = [pe renderCommandEncoder];
        [sub drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:1]; [sub endEncoding];
        arm("parallel encoder and its sub-encoder: not nil", pe != nil && sub != nil && [sub conformsToProtocol:@protocol(MTLRenderCommandEncoder)]);
        [pe endEncoding];
        arm("acceleration structure encoder: not nil", [cb accelerationStructureCommandEncoder] != nil);
        [cb encodeSignalEvent:(id<MTLEvent>)[NSObject new] value:1];
        [cb encodeWaitForEvent:(id<MTLEvent>)[NSObject new] value:1];

        __block int scheduled = 0, completed = 0; __block MTLCommandBufferStatus seen = MTLCommandBufferStatusNotEnqueued;
        [cb addScheduledHandler:^(id<MTLCommandBuffer> b) { (void)b; scheduled++; }];
        [cb addCompletedHandler:^(id<MTLCommandBuffer> b) { seen = b.status; completed++; }];
        [cb commit];
        [cb waitUntilScheduled];
        [cb waitUntilCompleted];
        arm("commit completes it at once with status error", cb.status == MTLCommandBufferStatusError);
        arm("its error is MTLCommandBufferErrorDomain / MTLCommandBufferErrorDeviceRemoved", dead_error(cb, MTLCommandBufferErrorDeviceRemoved));
        arm("its scheduled handler ran once", scheduled == 1);
        arm("its completed handler ran once and saw status error", completed == 1 && seen == MTLCommandBufferStatusError);

        int all = 1;
        for (int i = 0; i < 200; i++) {   // more than the queue's 64 in flight: each one gives its slot back
            id<MTLCommandBuffer> b = [q commandBuffer];
            if (!b) { all = 0; break; }
            [[b blitCommandEncoder] endEncoding];
            [b commit]; [b waitUntilCompleted];
            if (!dead_error(b, MTLCommandBufferErrorDeviceRemoved)) { all = 0; break; }
        }
        arm("200 dead command buffers in a row: none nil, none hangs on the queue's capacity, all fail with device removed", all);

        id<MTLCommandBuffer> never = [q commandBuffer];
        arm("a dead command buffer never committed is released without trouble", never != nil);
        never = nil;

        Class D = objc_getClass("NVMTLDevice");
        id dev = D ? [D alloc] : nil;   // not initialised: newCommandQueue only needs the backend state
        id<MTLCommandQueue> dq = [dev newCommandQueue];
        id<MTLCommandBuffer> db = [dq commandBuffer];
        [db commit]; [db waitUntilCompleted];
        arm("newCommandQueue with the backend down: a queue (not nil) whose command buffers fail with device removed",
            dq != nil && db != nil && dead_error(db, MTLCommandBufferErrorDeviceRemoved));
        if (dev) CFBridgingRetain(dev);   // never dealloc an uninitialised device
    }
    alarm(0);
    NSString *log = [NSString stringWithContentsOfFile:@(logp) encoding:NSUTF8StringEncoding error:nil];
    arm("the plugin logged that the backend stayed down and that it made dead command buffers",
        [log containsString:@"NVMTL_TEST_BACKEND_DOWN set"] && [log containsString:@"dead command buffer #1"]);
    unlink(logp);
    printf("%s (%d failed)\n", fails ? "FAILED" : "ALL ARMS HOLD", fails);
    return fails != 0;
}
