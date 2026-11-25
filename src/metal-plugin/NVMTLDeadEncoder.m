// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
/* Our code (Vermilion, phase 2 item 2, audit row A6): dead command buffers and their encoders. Imported by NVMTLDevice.m
   after NVMTLForward.m (one translation unit).

   -[MTLCommandQueue commandBuffer] never returns nil on a Mac. When the GPU is gone the command buffers still exist and
   complete with MTLCommandBufferStatusError, and WindowServer is written for that, not for nil: SkyLight recursed until
   its stack overflowed after the 2026-11-24 GPU hot reset, and CoreDisplay asserts "Failed to get a MTLCommandBuffer"
   (finding 2026-11-25-plugin-crashes-root-cause.md). So when the backend is down, or a command buffer can't be begun
   after the retries, the caller gets a dead one:
   - it is a real NVMTLCommandBuffer with no Vulkan recording and _dead set;
   - its encoders are NVMTLDeadEncoder objects: they answer every selector of the encoder they stand for, record
     nothing and return zero;
   - its commit goes through the queue like any other, so the queue's order holds, and completes at once with the error
     it was made with (nvmtlAdvancePart): the scheduled and completed handlers run, waitUntilScheduled and
     waitUntilCompleted return;
   - its event signals and waits are dropped (no GPU work to order), and its drawables are not presented.
   Bringing the GPU back (a reset, a new Vulkan device) is phase 2 item 7. */

@interface NVMTLDeadEncoder : NSObject { @public Class _real; NVMTLCommandBuffer *_cb; NSString *_label; } @end
@implementation NVMTLDeadEncoder
- (id<MTLDevice>)device { id d = _cb ? [_cb device] : nil; return d ?: (id<MTLDevice>)gNVMTLMainDevice; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)l { _label = [l copy]; }
- (void)endEncoding {}
- (id<MTLCommandBuffer>)commandBuffer { return _cb; }   // SPI on encoders
// MTLParallelRenderCommandEncoder: its sub-encoders are dead render encoders
- (id<MTLRenderCommandEncoder>)renderCommandEncoder { return nvmtl_dead_encoder([NVMTLRenderCommandEncoder class], _cb); }
- (BOOL)conformsToProtocol:(Protocol *)p { return [_real conformsToProtocol:p] || [super conformsToProtocol:p]; }
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [_real instancesRespondToSelector:s]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s {
    NSMethodSignature *m = [super methodSignatureForSelector:s];
    if (!m) m = [_real instanceMethodSignatureForSelector:s];
    if (!m) { const char *e = nvfwd_counterpart_encoding(_real, s); if (e) m = [NSMethodSignature signatureWithObjCTypes:e]; }
    return m ?: nvfwd_synthesize(s);
}
- (void)forwardInvocation:(NSInvocation *)inv {
    const NSUInteger len = inv.methodSignature.methodReturnLength;
    if (!len) return;
    void *zero = calloc(1, len);
    if (zero) { [inv setReturnValue:zero]; free(zero); }
}
- (NSString *)description { return [NSString stringWithFormat:@"<NVMTLDeadEncoder %p for %s>", (__bridge void *)self, class_getName(_real)]; }
@end

static id nvmtl_dead_encoder(Class real, NVMTLCommandBuffer *cb) {
    NVMTLDeadEncoder *e = [NVMTLDeadEncoder new];
    if (!e) return nil;
    e->_real = real; e->_cb = cb;
    return e;
}

// Marks cb dead with the error its commit will complete with. Called before anything is recorded into it.
static void nvmtl_cb_make_dead(NVMTLCommandBuffer *cb, NSInteger code, const char *why) {
    cb->_dead = YES;
    memset(&cb->_c, 0, sizeof cb->_c);
    NSString *text = [NSString stringWithFormat:@"The GPU is unavailable in this process (%s)", why];
    [cb nvmtlRecordEncodingError:[NSError errorWithDomain:MTLCommandBufferErrorDomain code:code
                                                 userInfo:@{NSLocalizedDescriptionKey: text}]];
    static _Atomic unsigned long made;
    const unsigned long n = atomic_fetch_add(&made, 1) + 1;
    if (n <= 8 || !(n & (n - 1)))
        nvlog("queue: dead command buffer #%lu in %s (%s): it completes with error %ld at commit, its encoders record nothing",
              n, getprogname(), why, (long)code);
}
