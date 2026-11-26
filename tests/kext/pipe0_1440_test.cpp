// SPDX-License-Identifier: MIT
// pipe0_1440_test.cpp: host test of the b128 1440p pipe-0 path (src/vermilion-boot/PhxPipe0.h + the 1440p plans) against
// a register model of pipe 0 on the XTX machine: the GOP's 1440p60 state (macOS reads 2026-11-19/20), OTG / stream / FIFO /
// lock status bits that follow their enables, a frame counter driven by the model's clock, DP_VID_M from the DTO, DET
// SIZE_CURRENT following SIZE, and a DAL callback that moves DENTIST as the PMFW does.
//   c++ -std=c++17 -Wall -Wextra -Werror -I src/vermilion-boot -o /tmp/pipe0_1440_test tests/kext/pipe0_1440_test.cpp && /tmp/pipe0_1440_test
#include "PhxPipe0.h"
#include "phx_p0_plan_1080p60.inc"
#include "phx_p0_plan_1080p144.inc"
#include "phx_p0_plan_1080p144a60.inc"
#include "phx_p0_plan_1080p144a165.inc"
#include "phx_p0_plan_1440p60.inc"
#include "phx_p0_plan_1440p120.inc"
#include "phx_p0_plan_1440p144.inc"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <vector>

static int fails, checks;
#define CHECK(c) do { checks++; if (!(c)) { fails++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)
#define N(a) (sizeof a / sizeof a[0])

static const uint32_t kDal120[2] = {0x000801f9, 0x000901f9}, kDal144[2] = {0x00080266, 0x00090266};
static const phxp0::Plan P60 = {kPhxP0_1440p60, N(kPhxP0_1440p60), kPhxP0_1440p60Info, 0, nullptr, phxp0::kOptStickyClear};
static const phxp0::Plan P120 = {kPhxP0_1440p120, N(kPhxP0_1440p120), kPhxP0_1440p120Info, 4, kDal120, phxp0::kOptStickyClear};
static const phxp0::Plan P144 = {kPhxP0_1440p144, N(kPhxP0_1440p144), kPhxP0_1440p144Info, 4, kDal144, phxp0::kOptStickyClear};
static const phxp0::Plan *const kFam[] = {&P60, &P120, &P144};
static const phxp0::Plan X60 = {kPhxP0_1080p60, N(kPhxP0_1080p60), kPhxP0_1080p60Info, 0, nullptr, 0};
static const phxp0::Plan X144 = {kPhxP0_1080p144, N(kPhxP0_1080p144), kPhxP0_1080p144Info, 0, nullptr, 0};
static const phxp0::Plan X144a60 = {kPhxP0_1080p144a60, N(kPhxP0_1080p144a60), kPhxP0_1080p144a60Info, 0, nullptr, 0};
static const phxp0::Plan X144a165 = {kPhxP0_1080p144a165, N(kPhxP0_1080p144a165), kPhxP0_1080p144a165Info, 0, nullptr, 0};
static const phxp0::Plan *const kXt[] = {&X60, &X144, &X144a60, &X144a165};

struct Hw {
    std::map<uint32_t, uint32_t> r;
    uint64_t t = 0;
    double frac = 0;
    uint32_t frames = 0x1000;
    std::vector<std::pair<uint32_t, uint32_t>> writes;
    std::vector<uint32_t> dal, dalIds;   // every DAL message's argument and DALSMC id, in order
    uint32_t dalAnswer = 1, uclkAnswer = 1, reads = 0;
    double linkScale = 1.0;       // DP_VID_M x this (1.0 = the GOP's HBR2 link)
    uint32_t underflowAtVt = 0;   // HUBP0 underflow whenever OTG0 runs this V_TOTAL (0 = never)
    bool otgOn() { return r[0x05001] & 1; }
    double pclk() { return r[0x00141]; }   // firmware DTO convention: phase = pixel clock in Hz
    void advance(uint32_t us) {
        t += us;
        if (!otgOn()) return;
        const double rate = pclk() / ((double)((r[0x04FEA] & 0x7fff) + 1) * ((r[0x04FEF] & 0x7fff) + 1));
        frac += us * 1e-6 * rate;
        const double whole = std::floor(frac);
        frames += static_cast<uint32_t>(whole);
        frac -= whole;
    }
    uint32_t rd(uint32_t a) {
        reads++;
        const uint32_t v = r[a];
        switch (a) {
        case 0x05001: return (v & ~0x10000u) | ((v & 1u) << 16);
        case 0x05045: return (v & ~0x10000u) | (otgOn() ? 0x10000u : 0u);
        case 0x0504A: return (v & ~0x100u) | ((v & 1u) << 8);
        case 0x0500C: return frames & 0xffffff;
        case 0x056CC: return (v & ~0x10000u) | ((v & 1u) && otgOn() ? 0x10000u : 0u);
        case 0x05651: return (v & ~0x100000u) | ((v & 2u) << 19);
        case 0x056D2: return static_cast<uint32_t>(std::lround(0x395e * pclk() / 241500000.0 * linkScale));
        case 0x0397B: case 0x0397C: case 0x0397D: case 0x0397E: return (v & ~0x1f00u) | ((v & 0x1fu) << 8);
        case 0x03AB3: return v | 2u | (underflowAtVt && otgOn() && (r[0x04FEF] & 0x7fff) == underflowAtVt ? 0x10000000u : 0u);
        default: return v;
        }
    }
    void wr(uint32_t a, uint32_t v) {
        writes.push_back({a, v});
        if (a == 0x04F8A) { if (v & 0x1000u) v &= ~0x400u; v &= ~0x1000u; }   // OPTC_UNDERFLOW_CLEAR clears the sticky
        r[a] = v;
    }
    uint32_t dalMsg(uint32_t msg, uint32_t arg) {
        dal.push_back(arg);
        dalIds.push_back(msg);
        if (msg == 9 && (arg >> 16) == 2) return uclkAnswer;   // UCLK: no DENTIST change
        if (msg != 9 || dalAnswer != 1) return dalAnswer;
        const uint32_t clk = arg >> 16, mhz = arg & 0xffff, did = mhz >= 614 ? 0x1c : mhz >= 505 ? 0x22 : 0x40;
        uint32_t &d = r[0x00124];
        if (clk == 8) d = (d & ~0x7f7fu) | did | (did << 8);
        if (clk == 9) d = (d & ~0x7f000000u) | (did << 24);
        return 1;
    }
};
static Hw *gHw;
static phxp0::Env env(Hw &h, int enable = 1) {
    gHw = &h;
    phxp0::Env e{};
    e.io = {&h, [](void *c, uint32_t a) { return static_cast<Hw *>(c)->rd(a); }, [](void *c, uint32_t a, uint32_t v) { static_cast<Hw *>(c)->wr(a, v); },
            [](void *, uint64_t) { return 0u; }, [](void *, uint64_t, uint32_t) {}, [](void *c, uint32_t us) { static_cast<Hw *>(c)->advance(us); }};
    e.enable = enable;
    e.nowUs = [](void *c) { return static_cast<Hw *>(c)->t; };
    e.dal =[](void *c, uint32_t m, uint32_t a) { return static_cast<Hw *>(c)->dalMsg(m, a); };
    e.pmfwIdle = [](void *) { return 1; };
    e.live = 1;
    return e;
}
// The GOP's 1440p60 on the XTX machine: every 1440p60 plan register (the plan is that read) plus the rest of pipe 0.
static void gop(Hw &h) {
    for (const auto &s : kPhxP0_1440p60) h.r[s.reg] = s.val;
    const std::pair<uint32_t, uint32_t> rest[] = {
        {0x00124, 0x40194040}, {0x00142, 0x2ab7772b}, {0x0397A, 0x00040202}, {0x0397B, 0x00000303}, {0x0397C, 0x00000003},
        {0x0397D, 0x00000003}, {0x0397E, 0x00000003}, {0x039BC, 0x00001002}, {0x05001, 0x00011201}, {0x05045, 0x00010101},
        {0x039EE, 0x85c60000}, {0x03AB3, 0x000f0002}, {0x03B90, 0x00500000}, {0x03C6C, 0x00500000}, {0x03D48, 0x00500000},
        {0x04D14, 0x00000030}, {0x04F8A, 0x00000400}, {0x05081, 0x00000200}, {0x05651, 0x0000001d}, {0x0564B, 0x01000000},
        {0x056CD, 0x3f000000}, {0x056C8, 0x00000110}, {0x056CB, 0x00000003}, {0x056D1, 0x00008000}, {0x056CC, 0x00010201},
        {0x039BE, 0x000001fe}, {0x039C3, 0x00004ee8}};
    for (const auto &x : rest) h.r[x.first] = x.second;
}
static std::set<uint32_t> allowedWrites() {
    std::set<uint32_t> a = {0x03AB3, 0x04D14, 0x04D17, 0x04D18, 0x04D19, 0x04F8A, 0x05001, 0x0504A, 0x039EE, 0x05651, 0x056CC, 0x056CD,
                            0x0397B, 0x0397C, 0x0397D, 0x0397E, 0x039BC};
    for (const phxp0::Plan *p : kFam) for (unsigned i = 0; i < p->n; i++) a.insert(p->s[i].reg);
    return a;
}
static bool writesOk(const Hw &h) {
    const std::set<uint32_t> a = allowedWrites();
    for (const auto &w : h.writes) if (!a.count(w.first)) { std::printf("  unexpected write 0x%05X = 0x%08x\n", w.first, w.second); return false; }
    return true;
}
static bool planEquals(Hw &h, const phxp0::Plan &p) {
    for (unsigned i = 0; i < p.n; i++) if ((h.r[p.s[i].reg] ^ p.s[i].val) & p.s[i].mask) { std::printf("  0x%05X = 0x%08x, plan %s 0x%08x\n", p.s[i].reg, h.r[p.s[i].reg], p.info.name, p.s[i].val); return false; }
    return true;
}
// b167: the glue's debug.phxpipe0_uclk, 0 = no UCLK hard minimum (Linux sends none at these switches; the knob takes only 0)
static int mac(Hw &h, phxp0::State &st, const phxp0::Plan &tg, phxp0::MacOut *o, uint32_t uclkMhz = 0) {
    const phxp0::Env e = env(h);
    const int r = phxp0::macSet(e, st, kFam, N(kFam), tg, uclkMhz, o);
    if (r != phxp0::kDone) std::printf("  macSet %s: %s\n", tg.info.name, st.why);
    return r;
}

int main() {
    const char *w = nullptr;
    // ---- static: every plan passes, both families consistent, the 1440p values are what the capture says
    for (const phxp0::Plan *p : kFam) { w = nullptr; CHECK(phxp0::staticCheck(*p, &w)); if (w) std::printf("  %s: %s\n", p->info.name, w); }
    for (const phxp0::Plan *p : kXt) { w = nullptr; CHECK(phxp0::staticCheck(*p, &w)); if (w) std::printf("  %s: %s\n", p->info.name, w); }
    CHECK(phxp0::sameTimingConsistent(kFam, N(kFam), &w) && phxp0::sameTimingConsistent(kXt, N(kXt), &w));
    CHECK(P120.info.hTotal == 0xa9f && P120.info.vTotal == 0x5f4 && P144.info.vTotal == 0x5eb && P60.info.vTotal == 0x5c8);
    CHECK(kPhxP0_1440p120[0].reg == 0x00141 && kPhxP0_1440p120[0].val == 497750000u && kPhxP0_1440p144[0].val == 593750000u);
    CHECK(kPhxP0_1440p60[0].val == 241500000u);   // the GOP's own DTO phase: the firmware convention

    {   // gate off: refused, not one register read
        Hw h; gop(h); phxp0::State st{}; phxp0::MacOut o{};
        const phxp0::Env e = env(h, 0);
        CHECK(phxp0::macSet(e, st, kFam, N(kFam), P120, 456, &o) == phxp0::kRefused && h.reads == 0 && h.writes.empty());
    }
    {   // the family follows OTG0: the GOP's 1440p60 is the 1440p family's 60 plan, no 1080p plan
        Hw h; gop(h);
        const phxp0::Env e = env(h);
        CHECK(phxp0::identify(e, kFam, N(kFam)) == &P60 && phxp0::identify(e, kXt, N(kXt)) == nullptr);
        CHECK(phxp0::equalCount(e, P60) == P60.n);   // so the round trip at 60 passes
    }
    {   // 60 -> 120 -> 144 -> 60 on one boot
        Hw h; gop(h); phxp0::State st{}; phxp0::MacOut o{};
        CHECK(mac(h, st, P120, &o) == phxp0::kDone);
        CHECK(o.flags & phxp0::kMacRoundTrip);
        CHECK(h.dal.size() == 2 && h.dal[0] == 0x000801f9 && h.dal[1] == 0x000901f9);
        CHECK((h.r[0x0397B] & 0x1f) == 4 && !(h.r[0x0397C] & 0x1f) && !(h.r[0x0397D] & 0x1f) && !(h.r[0x0397E] & 0x1f));
        CHECK(st.odmPreClears == 1 && !(h.r[0x04F8A] & 0x400));
        CHECK(planEquals(h, P120) && (h.r[0x056C9] & 0x07000000) == 0x02000000 && h.r[0x04D01] == 0xd100 && (h.r[0x056CA] >> 24) == 0x40);
        CHECK((h.r[0x056C9] & 0x40000000) == 0 && h.r[0x056C8] == 0x110 && h.r[0x056CB] == 3);   // 1 pixel per cycle, link untouched
        CHECK(st.otg0Frames >= 118 && st.otg0Frames <= 122);
        CHECK(writesOk(h));
        CHECK(mac(h, st, P144, &o) == phxp0::kDone);
        CHECK(h.dal.size() == 4 && h.dal[2] == 0x00080266 && h.dal[3] == 0x00090266);
        CHECK(planEquals(h, P144) && (h.r[0x056C9] & 0x07000000) == 0x01000000 && h.r[0x04D01] == 0xc900 && (h.r[0x056CA] >> 24) == 0x20);
        CHECK(st.otg0Frames >= 142 && st.otg0Frames <= 146);
        CHECK(mac(h, st, P60, &o) == phxp0::kDone);
        CHECK(h.dal.size() == 4);                                       // never lowered, no message for 60
        CHECK(planEquals(h, P60) && (h.r[0x056C9] & 0x07000000) == 0x03000000 && h.r[0x04D01] == 0);   // the GOP's state, 12 bpc
        CHECK((h.r[0x0397B] & 0x1f) == 4);                              // DET stays
        CHECK(st.otg0Frames >= 58 && st.otg0Frames <= 62);
        CHECK(mac(h, st, P60, &o) == phxp0::kSame);
        CHECK(writesOk(h) && !st.dark && !st.halted);
        bool noForbidden = true;
        for (const auto &x : h.writes) if (x.first == 0x00124 || x.first == 0x056C8 || x.first == 0x056CB || x.first == 0x0397A || (x.first >= 0x039BE && x.first <= 0x039E5)) noForbidden = false;
        CHECK(noForbidden);   // DENTIST, the link, COMPBUF and the watermarks are never written
    }
    {   // b167 (U1): the glue's 0 sends no UCLK message; macSet given a UCLK MHz sends it through the DAL mailbox only
        Hw h; gop(h); phxp0::State st{}; phxp0::MacOut o{};
        CHECK(mac(h, st, P120, &o) == phxp0::kDone && !(o.flags & phxp0::kMacUclkPin) && st.uclkPins == 0);
        bool uclk = false;
        for (size_t i = 0; i < h.dal.size(); i++) if (h.dalIds[i] == 9 && (h.dal[i] >> 16) == 2) uclk = true;
        CHECK(!uclk && h.dal.size() == 2);
        const size_t n0 = h.dal.size();   // 120 -> 144 with 456 MHz asked: DISPCLK, DPPCLK, then DAL SetHardMinByFreq UCLK 456
        CHECK(mac(h, st, P144, &o, 456) == phxp0::kDone && (o.flags & phxp0::kMacUclkPin) && st.uclkPins == 1);
        CHECK(h.dal.size() == n0 + 3 && h.dalIds[n0 + 2] == 9 && h.dal[n0 + 2] == 0x000201c8);
        const size_t n1 = h.dal.size();   // 144 -> 60, a lower rate: no UCLK message
        CHECK(mac(h, st, P60, &o, 456) == phxp0::kDone && h.dal.size() == n1 && st.uclkPins == 1);
    }
    {   // the PMFW refuses the UCLK hard minimum: refused before the round trip and the set, nothing of the plan written
        Hw h; gop(h); h.uclkAnswer = 0xFF; phxp0::State st{}; phxp0::MacOut o{};
        CHECK(mac(h, st, P120, &o, 456) == phxp0::kRefused && std::strstr(st.why, "UCLK") && h.r[0x04FEF] == 0x5c8);
        CHECK(h.dal.size() == 3 && h.dalIds[2] == 9 && h.dal[2] == 0x000201c8 && st.uclkPins == 1);
        bool planWritten = false;
        for (const auto &x : h.writes) for (unsigned i = 0; i < P120.n; i++) if (x.first == P120.s[i].reg) planWritten = true;
        CHECK(!planWritten);
    }
    {   // no DAL path: a UCLK hard minimum asked is refused, the set not run (there is no driver-mailbox fallback)
        Hw h; gop(h); phxp0::State st{}; phxp0::MacOut o{};
        phxp0::Env e = env(h);
        e.pmfwIdle = nullptr;
        CHECK(phxp0::macSet(e, st, kFam, N(kFam), P60, 456, &o) == phxp0::kSame);   // same mode: nothing asked
        CHECK(h.dal.empty() && st.uclkPins == 0);
    }
    {   // the PMFW refuses a hard minimum: refused before any plan register is written
        Hw h; gop(h); h.dalAnswer = 0; phxp0::State st{}; phxp0::MacOut o{};
        CHECK(mac(h, st, P120, &o) == phxp0::kRefused);
        CHECK(h.r[0x04FEF] == 0x5c8 && planEquals(h, P60));
        bool planWritten = false;
        for (const auto &x : h.writes) for (unsigned i = 0; i < P120.n; i++) if (x.first == P120.s[i].reg) planWritten = true;
        CHECK(!planWritten);
    }
    {   // the PMFW does not move DENTIST: refused, nothing of the plan written
        Hw h; gop(h); phxp0::State st{}; phxp0::MacOut o{};
        const phxp0::Env e0 = env(h);
        phxp0::Env e = e0;
        e.dal = [](void *c, uint32_t, uint32_t a) { static_cast<Hw *>(c)->dal.push_back(a); return 1u; };
        CHECK(phxp0::macSet(e, st, kFam, N(kFam), P120, 456, &o) == phxp0::kRefused && h.r[0x04FEF] == 0x5c8);
    }
    {   // a link at neither HBR nor HBR2: refused at the survey, before DET or DAL
        Hw h; gop(h); h.linkScale = 0.75; phxp0::State st{}; phxp0::MacOut o{};
        CHECK(mac(h, st, P120, &o) == phxp0::kRefused && h.dal.empty() && (h.r[0x0397B] & 0x1f) == 3);
    }
    {   // an underflow at 120: the engine falls back to the GOP's 60 by itself
        Hw h; gop(h); h.underflowAtVt = 0x5f4; phxp0::State st{}; phxp0::MacOut o{};
        CHECK(mac(h, st, P120, &o) == phxp0::kFellBack);
        CHECK(h.r[0x04FEF] == 0x5c8 && planEquals(h, P60) && !st.dark);
    }
    {   // OTG1 lit (a second display): the DET step refuses, nothing written
        Hw h; gop(h); h.r[0x05081] = 0x00010001; h.r[0x0506A] = 0x897; h.r[0x0506F] = 0x464; phxp0::State st{}; phxp0::MacOut o{};
        CHECK(mac(h, st, P120, &o) == phxp0::kRefused && (h.r[0x0397B] & 0x1f) == 3 && h.dal.empty());
    }
    {   // upstream's XT: the HBR M check still passes at the AOC's 1080p60 (0x468b at 148.5 MHz)
        Hw h;
        for (const auto &s : kPhxP0_1080p60) h.r[s.reg] = s.val;
        h.r[0x05001] = 0x00011201; h.r[0x039EE] |= 0x80000000u; h.r[0x056C8] = 0x110; h.r[0x056CB] = 3; h.r[0x056CC] = 0x10201;
        h.r[0x05651] = 0x1d; h.r[0x039BC] = 0x1002; h.r[0x0564B] = 0x01000000;
        // the model's M is 0x395e x pclk / 241.5 MHz x linkScale: scaled to the XT's HBR M at the plan's DTO phase
        h.linkScale = (double)0x468b / (0x395e * (h.r[0x00141] / 1e6) / 241.5);
        phxp0::State st{};
        const phxp0::Plan *cur = nullptr;
        const phxp0::Env e = env(h);
        CHECK(phxp0::survey(e, st, kXt, N(kXt), X60, &cur) == phxp0::kDone && cur == &X60);
        h.linkScale *= 0.75;   // and an unknown link rate there is still refused
        CHECK(phxp0::survey(e, st, kXt, N(kXt), X60, &cur) == phxp0::kRefused && std::strstr(st.why, "DP_VID_M"));
    }
    std::printf("pipe0_1440_test: %d/%d checks passed\n", checks - fails, checks);
    return fails ? 1 : 0;
}
