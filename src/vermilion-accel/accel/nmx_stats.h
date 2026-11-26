// SPDX-License-Identifier: MIT
// nmx_stats.h (VermilionAccel 0.1.2, plan A4): the accelerator's statistics object, as Apple's AMD driver has one.
//
// IOGraphicsAccelerator2::start makes the object through newStatistics() (NMXAccel returns this class) and its init
// publishes PerformanceStatistics. Each read of that property runs writePerformanceStats and writeInternalStats on a
// fresh dictionary; this class adds, after the family's keys, the two keys Apple's AMDAccelStatistics adds there
// (reference/apple-amd/03-accelerator.md 3.6), which Activity Monitor's GPU History and free-VRAM readers use:
//   "Device Utilization %"  GFX + compute busy share since the previous resetting read (at least 50 ms apart)
//   "vramFreeBytes"         the device-local memory RADV is offered minus what every client holds of it
// Both come from VermilionBoot's "phxGpuStats" platform function (PhxGpuStats.h, b168): a busy sampler on the kext's
// own queues, no firmware message. With an older VermilionBoot (no phx-gpu-stats-fn property) the keys are absent,
// as before. Included by nvrm-accel.cpp (one translation unit).
#pragma once
#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/c++/OSSymbol.h>

#include "iofam/IOAccelStatistics2.h"
#include "../../vermilion-boot/PhxGpuStats.h"

class NMXAccelStatistics : public IOAccelStatistics2 {
    OSDeclareDefaultStructors(NMXAccelStatistics)
public:
    static constexpr uint64_t kMinIntervalNs = 50000000ull;   // two readers 50 ms apart share one value

    // bringup: VermilionBoot's PhxBringup (retained), found by the accelerator before the family's start
    static NMXAccelStatistics *make(IOService *bringup) {
        NMXAccelStatistics *s = OSTypeAlloc(NMXAccelStatistics);
        if (!s) return nullptr;
        s->fLock = IOLockAlloc();
        s->fFn = OSSymbol::withCString(PHX_GPU_STATS_FN);
        if (bringup && bringup->getProperty("phx-gpu-stats-fn") == kOSBooleanTrue) { s->fBringup = bringup; bringup->retain(); }
        return s;
    }

    void writeInternalStats(OSDictionary *d, bool reset) APPLE_KEXT_OVERRIDE {
        IOAccelStatistics2::writeInternalStats(d, reset);
        if (!d || !fBringup || !fFn || !fLock) return;
        phx_gpu_stats st{};
        st.version = PHX_GPU_STATS_VERSION;
        st.size = sizeof(st);
        if (fBringup->callPlatformFunction(fFn, false, &st, nullptr, nullptr, nullptr) != kIOReturnSuccess) return;
        IOLockLock(fLock);
        if (!fPrevNow) {   // the first read is the baseline
            fPrevBusy = st.busy_ns;
            fPrevNow = st.now_ns;
        } else {
            const int u = phxbusy::utilization(fPrevBusy, fPrevNow, st.busy_ns, st.now_ns, kMinIntervalNs);
            if (u >= 0) {
                fUtil = static_cast<uint64_t>(u);
                if (reset) { fPrevBusy = st.busy_ns; fPrevNow = st.now_ns; }
            }
        }
        const uint64_t util = fUtil;
        IOLockUnlock(fLock);
        put(d, "Device Utilization %", util);
        put(d, "vramFreeBytes", phxbusy::vramFree(st));
    }

    void free() APPLE_KEXT_OVERRIDE {
        if (fBringup) { fBringup->release(); fBringup = nullptr; }
        if (fFn) { fFn->release(); fFn = nullptr; }
        if (fLock) { IOLockFree(fLock); fLock = nullptr; }
        IOAccelStatistics2::free();
    }

private:
    static void put(OSDictionary *d, const char *key, uint64_t v) {
        if (OSNumber *n = OSNumber::withNumber(v, 64)) { d->setObject(key, n); n->release(); }
    }
    IOService *fBringup = nullptr;
    const OSSymbol *fFn = nullptr;
    IOLock *fLock = nullptr;
    uint64_t fPrevBusy = 0, fPrevNow = 0, fUtil = 0;
};
OSDefineMetaClassAndStructors(NMXAccelStatistics, IOAccelStatistics2)
