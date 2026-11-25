// SPDX-License-Identifier: MIT
/* test_texture_nil_log.m - the plugin logs to the unified log (subsystem org.vermilion.nvmtl), and every nil from
   texture creation says why there, with its descriptor, rate-limited (audit row A8: Maps had no plugin log at all).
   Loads a built plugin with its backend down (NVMTL_TEST_BACKEND_DOWN=1: no GPU is touched), asks for textures, and
   reads this process's own log entries back with OSLogStore. The plugin's file log goes to a temporary file.
     sh scripts/build/plugin.sh
     clang -fobjc-arc -framework Foundation -framework Metal -framework OSLog tests/plugin/test_texture_nil_log.m -o /tmp/test_texture_nil_log
     /tmp/test_texture_nil_log build/NVMTLDriver */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <OSLog/OSLog.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>
#pragma clang diagnostic ignored "-Wnonnull"   // a NULL surface on purpose
static int fails;
static void arm(const char *w, int ok) { printf("%s  %s\n", ok ? "ok  " : "FAIL", w); if (!ok) fails++; }
static NSUInteger count_of(NSString *hay, NSString *needle) {
    NSUInteger n = 0; NSRange r = NSMakeRange(0, hay.length);
    for (;;) { NSRange f = [hay rangeOfString:needle options:0 range:r]; if (f.location == NSNotFound) return n;
               n++; r = NSMakeRange(NSMaxRange(f), hay.length - NSMaxRange(f)); }
}
int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <path to NVMTLDriver>\n", argv[0]); return 2; }
    char logp[] = "/tmp/test_texture_nil_log.XXXXXX"; int fd = mkstemp(logp); if (fd >= 0) close(fd);
    setenv("NVMTL_TEST_BACKEND_DOWN", "1", 1);
    setenv("NVMTL_LOG_PATH", logp, 1);
    NSDate *start = [NSDate date];
    if (!dlopen(argv[1], RTLD_NOW)) { printf("FAIL  dlopen %s: %s\n", argv[1], dlerror()); return 1; }
    @autoreleasepool {
        Class D = objc_getClass("NVMTLDevice");
        arm("the plugin's NVMTLDevice class is there", D != Nil);
        if (!D) return 1;
        id dev = [D alloc];   // not initialised: texture creation stops at the backend check first
        CFBridgingRetain(dev);
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:600 height:600 mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        int nils = 0;
        for (int i = 0; i < 20; i++) if (![dev newTextureWithDescriptor:d]) nils++;
        arm("backend down: newTextureWithDescriptor: returns nil (20 asks)", nils == 20);
        arm("newTextureWithDescriptor:iosurface:plane: too", [dev newTextureWithDescriptor:d iosurface:NULL plane:0] == nil);
    }
    NSString *file = [NSString stringWithContentsOfFile:@(logp) encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *want = @"texture nil: newTextureWithDescriptor: in ";
    arm("the file log names the path, the reason and the descriptor",
        [file containsString:want] && [file containsString:@"the Vulkan backend is down | type 2 format 80 600x600x1 mips 1 array 1 samples 1 usage 0x5 storage"]);
    arm("rate-limited: the same reason is logged 8 times of 20, not 20", count_of(file, want) == 8);
    arm("the iosurface path logs its own reason", [file containsString:@"texture nil: newTextureWithDescriptor:iosurface:plane: in "]);

    NSError *err = nil;
    OSLogStore *store = [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier error:&err];
    OSLogPosition *pos = [store positionWithDate:[start dateByAddingTimeInterval:-1]];
    NSPredicate *pred = [NSPredicate predicateWithFormat:@"subsystem == %@", @"org.vermilion.nvmtl"];
    OSLogEnumerator *en = store ? [store entriesEnumeratorWithOptions:0 position:pos predicate:pred error:&err] : nil;
    NSUInteger all = 0, texnil = 0, dflt = 0;
    for (OSLogEntryLog *e in en) {
        if (![e isKindOfClass:[OSLogEntryLog class]]) continue;
        all++;
        if ([e.composedMessage containsString:want]) { texnil++; if (e.level == OSLogEntryLogLevelNotice) dflt++; }
    }
    arm("the unified log has the plugin's lines under subsystem org.vermilion.nvmtl", store && all > 0);
    arm("there, the texture-nil line appears 8 times, at default level", texnil == 8 && dflt == 8);
    if (!store || !all) printf("info  OSLogStore: %s\n", err ? err.localizedDescription.UTF8String : "no entries");
    unlink(logp);
    printf("%s (%d failed)\n", fails ? "FAILED" : "ALL ARMS HOLD", fails);
    return fails != 0;
}
