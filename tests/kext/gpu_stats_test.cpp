// SPDX-License-Identifier: MIT
// gpu_stats_test.cpp: host test of PhxGpuStats.h (b168), the busy sampler and the utilization VermilionAccel publishes.
// c++ -std=c++17 -Wall -Wextra -Werror -I src/vermilion-boot -o /tmp/gpu_stats_test tests/kext/gpu_stats_test.cpp
#include <cstdio>

#include "PhxGpuStats.h"

using namespace phxbusy;

static int gN, gF;
#define CHECK(c) do { gN++; if (!(c)) { gF++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static constexpr uint64_t kMs = 1000000;

// A GPU busy for `busyMs` out of every `frameMs` (from frame start), sampled every `periodMs` at a phase that does not
// line up with the frames: the measured share is the real one within a few percent.
static int simulate(double busyMs, double frameMs, uint64_t periodUs, double seconds) {
    Sampler s{};
    const uint64_t period = periodUs * 1000;
    uint64_t t = 1000 * kMs + 333333;   // an arbitrary start
    s.lastSubmitNs = t;
    s.start(t);
    const uint64_t end = t + static_cast<uint64_t>(seconds * 1e9);
    const uint64_t frame = static_cast<uint64_t>(frameMs * kMs), work = static_cast<uint64_t>(busyMs * kMs);
    while (t < end) {
        t += period;
        const uint64_t inFrame = (t - 1000 * kMs) % frame;
        s.lastSubmitNs = t - inFrame;   // each frame submits at its start
        if (!s.tick(inFrame < work, t, period)) break;
    }
    return utilization(0, 0, s.busyNs, end - (1000 * kMs + 333333), 1);
}

int main() {
    static_assert(sizeof(phx_gpu_stats) == 56, "stats");
    // tick: a busy sample credits the time since the previous one, capped at 4 periods; an idle one credits nothing
    Sampler s{};
    s.start(100 * kMs);
    s.lastSubmitNs = 100 * kMs;
    CHECK(s.tick(true, 102 * kMs, 2 * kMs) && s.busyNs == 2 * kMs && s.samples == 1 && s.busySamples == 1);
    CHECK(s.tick(true, 120 * kMs, 2 * kMs) && s.busyNs == 10 * kMs);   // 18 ms late: 4 x 2 ms
    CHECK(s.tick(false, 122 * kMs, 2 * kMs) && s.busyNs == 10 * kMs && s.samples == 3 && s.busySamples == 2);
    // sampling continues while a submission is recent, stops 250 ms after the last one once a sample is idle
    CHECK(s.tick(false, 100 * kMs + kIdleStopNs - 1, 2 * kMs));
    CHECK(!s.tick(false, 100 * kMs + kIdleStopNs, 2 * kMs));
    CHECK(s.tick(true, 100 * kMs + kIdleStopNs + 10 * kMs, 2 * kMs));   // still busy: keeps going whatever the time
    // a clock that went backwards credits nothing
    Sampler b{};
    b.start(50 * kMs);
    CHECK(b.tick(true, 40 * kMs, 2 * kMs) && b.busyNs == 0);

    // utilization: rounded percent, clamped, -1 for a short interval or no time
    CHECK(utilization(0, 0, 500 * kMs, 1000 * kMs, 50 * kMs) == 50);
    CHECK(utilization(100 * kMs, 1000 * kMs, 100 * kMs, 2000 * kMs, 50 * kMs) == 0);
    CHECK(utilization(0, 0, 2000 * kMs, 1000 * kMs, 50 * kMs) == 100);
    CHECK(utilization(0, 0, 5 * kMs, 1000 * kMs, 50 * kMs) == 1);   // 0.5 % rounds up
    CHECK(utilization(0, 1000 * kMs, 10 * kMs, 1040 * kMs, 50 * kMs) == -1);
    CHECK(utilization(0, 1000 * kMs, 10 * kMs, 1000 * kMs, 0) == -1);
    CHECK(utilization(0, 1000 * kMs, 10 * kMs, 900 * kMs, 0) == -1);
    CHECK(utilization(50 * kMs, 0, 10 * kMs, 1000 * kMs, 50 * kMs) == 0);   // busy went down (a reset): 0, not a wrap

    // the sampled share against the real one (2 ms sampling, as the default)
    const int u60 = simulate(4.0, 16.667, kDefPeriodUs, 10);    // 24 %
    const int u240 = simulate(3.0, 4.1667, kDefPeriodUs, 10);   // 72 %
    const int ufull = simulate(10.0, 10.0, kDefPeriodUs, 5);    // 100 %
    const int ulow = simulate(0.5, 16.667, kDefPeriodUs, 20);   // 3 %
    std::printf("simulated: 24%% -> %d, 72%% -> %d, 100%% -> %d, 3%% -> %d\n", u60, u240, ufull, ulow);
    CHECK(u60 >= 21 && u60 <= 27);
    CHECK(u240 >= 68 && u240 <= 76);
    CHECK(ufull == 100);
    CHECK(ulow >= 1 && ulow <= 5);

    // vramFree never wraps
    phx_gpu_stats st{};
    st.vram_total = 100; st.vram_used = 30;
    CHECK(vramFree(st) == 70);
    st.vram_used = 130;
    CHECK(vramFree(st) == 0);

    std::printf("gpu_stats_test: %d/%d checks passed\n", gN - gF, gN);
    return gF ? 1 : 0;
}
