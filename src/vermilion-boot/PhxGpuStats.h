// SPDX-License-Identifier: MIT
// PhxGpuStats.h (b168, plan A4): the GPU's busy time and VRAM use for the statistics Activity Monitor reads.
//
// VermilionBoot answers the platform function "phxGpuStats" (param1 = phx_gpu_stats *, in: version and size). Its
// accelerator's statistics (VermilionAccel, NMXAccelStatistics::writeInternalStats) turn the answer into the keys
// Apple's AMD driver publishes in the accelerator's PerformanceStatistics: "Device Utilization %" and "vramFreeBytes"
// (reference/apple-amd/03-accelerator.md 3.6).
//
// The busy time is sampled, not read from firmware: Linux's gpu_busy_percent comes from the SMU's metrics table (a
// firmware message), so here a timer looks at the kext's own GFX and compute queues every period while they have
// work, and counts the time a sample finds a submission the GPU has not fenced yet. The fence read is a VRAM read
// through BAR0 (no register access). Sampling runs only while the GPU is in use: it starts at a submission and stops
// once a sample finds both queues idle and nothing was submitted for kIdleStopNs. Kernel-free:
// tests/kext/gpu_stats_test.cpp.
#pragma once
#include <stdint.h>

#define PHX_GPU_STATS_FN "phxGpuStats"
#define PHX_GPU_STATS_VERSION 1u
struct phx_gpu_stats {
    uint32_t version, size;   // in: PHX_GPU_STATS_VERSION and sizeof(phx_gpu_stats); out: the kext's
    uint64_t now_ns;          // the kext's monotonic clock (mach_absolute_time in ns)
    uint64_t busy_ns;         // GFX + compute busy time since the kext started (sampled)
    uint64_t samples, busy_samples;
    uint64_t vram_total;      // the device-local memory RADV is offered (from the VRAM size the hardware reports)
    uint64_t vram_used;       // what every client holds of it now
};
static_assert(sizeof(phx_gpu_stats) == 56, "phx_gpu_stats is 56 B");

namespace phxbusy {

constexpr uint64_t kDefPeriodUs = 2000;          // debug.phxgpu_busy_us default: one sample every 2 ms while in use
constexpr uint64_t kIdleStopNs = 250000000ull;   // sampling stops 250 ms after the last submission (with the GPU idle)
constexpr uint64_t kMaxCreditPeriods = 4;        // a late sample credits at most 4 periods (a stalled timer adds no busy time)

// The sampler. tick() runs at each sample with the state it saw; a busy sample credits the time since the previous
// sample (sample-and-hold), capped. Returns whether to keep sampling.
struct Sampler {
    uint64_t busyNs, samples, busySamples;
    uint64_t lastSampleNs;   // the previous sample (or the start of sampling)
    uint64_t lastSubmitNs;   // the last submission (written by the submit path)
    void start(uint64_t now) { lastSampleNs = now; }
    bool tick(bool busy, uint64_t now, uint64_t periodNs) {
        const uint64_t dt = now > lastSampleNs ? now - lastSampleNs : 0;
        const uint64_t cap = periodNs * kMaxCreditPeriods;
        lastSampleNs = now;
        samples++;
        if (busy) {
            busySamples++;
            busyNs += dt < cap ? dt : cap;
            return true;
        }
        return now < lastSubmitNs + kIdleStopNs;
    }
};

// Utilization in percent (0..100) over [prev, cur] from two phx_gpu_stats answers; -1 when the interval is shorter
// than minNs (the caller keeps its previous value: two readers a few ms apart would otherwise see noise).
inline int utilization(uint64_t prevBusyNs, uint64_t prevNowNs, uint64_t busyNs, uint64_t nowNs, uint64_t minNs) {
    if (nowNs <= prevNowNs || nowNs - prevNowNs < minNs) return -1;
    const uint64_t dt = nowNs - prevNowNs;
    const uint64_t db = busyNs > prevBusyNs ? busyNs - prevBusyNs : 0;
    const uint64_t pct = (db * 100 + dt / 2) / dt;
    return pct > 100 ? 100 : static_cast<int>(pct);
}

inline uint64_t vramFree(const phx_gpu_stats &s) { return s.vram_total > s.vram_used ? s.vram_total - s.vram_used : 0; }

}  // namespace phxbusy
