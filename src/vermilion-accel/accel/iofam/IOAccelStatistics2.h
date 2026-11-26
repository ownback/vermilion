// SPDX-License-Identifier: MIT
// IOAccelStatistics2: reconstructed from IOAcceleratorFamily2 (macOS 26.7.1, x86_64); Apple ships no header.
//
// Read 2026-11-26 from the extracted family kext (ipsw kernel extract, otool, nm):
//   - size 0x68: IOGraphicsAccelerator2::newStatistics() is `operator new(0x68)` + `IOAccelStatistics2()`;
//   - IOGraphicsAccelerator2::start stores newStatistics() at +0x388 and calls its init(this) (vtable +0x118), which
//     publishes the OSSerializer properties PerformanceStatistics (serialize_performance_stats_reset),
//     PerformanceStatisticsAccum (noreset), InternalStatistics, InternalStatisticsAccm, SurfaceList and AGCInfo;
//   - serialize_performance_stats makes an OSDictionary, calls writePerformanceStats (+0x120) then writeInternalStats
//     (+0x128) on it (their return values are not used), serializes it and releases it;
//   - vtable __ZTV18IOAccelStatistics2 after OSObject's slots (which end at +0x110): +0x118 init, +0x120
//     writePerformanceStats, +0x128 writeInternalStats, +0x130 setupIOReporters, +0x138 setupChannels, +0x140
//     configureReport, +0x148 updateReport, +0x150..+0x178 _RESERVEDIOAccelStatistics0-5.
// Apple's AMD driver subclasses it (AMDAccelStatistics) and adds "Device Utilization %" and "vramFreeBytes" in
// writeInternalStats (reference/apple-amd/03-accelerator.md 3.6). The declarations below are in vtable order; only
// writeInternalStats is overridden here (NMXAccelStatistics, nmx_stats.h).
#pragma once
#include <libkern/c++/OSObject.h>
#include <IOKit/IOReportTypes.h>

class OSDictionary;
class IOGraphicsAccelerator2;

enum { kIOAccelStatistics2Size = 0x68 };
class IOAccelStatistics2 : public OSObject {
    OSDeclareDefaultStructors(IOAccelStatistics2);
public:
    virtual bool init(IOGraphicsAccelerator2 *);
    virtual void writePerformanceStats(OSDictionary *, bool);
    virtual void writeInternalStats(OSDictionary *, bool);
    virtual int setupIOReporters();
    virtual int setupChannels();
    virtual int configureReport(IOReportChannelList *, unsigned int, void *, void *);
    virtual int updateReport(IOReportChannelList *, unsigned int, void *, void *);
    virtual void _RESERVEDIOAccelStatistics0();
    virtual void _RESERVEDIOAccelStatistics1();
    virtual void _RESERVEDIOAccelStatistics2();
    virtual void _RESERVEDIOAccelStatistics3();
    virtual void _RESERVEDIOAccelStatistics4();
    virtual void _RESERVEDIOAccelStatistics5();
private:
    uint8_t _opaque[kIOAccelStatistics2Size - sizeof(OSObject)];
};
static_assert(sizeof(IOAccelStatistics2) == kIOAccelStatistics2Size, "IOAccelStatistics2 must be 0x68 bytes");
