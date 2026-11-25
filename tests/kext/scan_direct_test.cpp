// SPDX-License-Identifier: MIT
// scan_direct_test.cpp: host test of src/vermilion-boot/PhxScanDirect.h (direct scan-out of the display surfaces, kext b162).
//   c++ -std=c++17 -Wall -Wextra -Werror -I src/vermilion-boot -o /tmp/scan_direct_test tests/kext/scan_direct_test.cpp && /tmp/scan_direct_test
#include "PhxScanDirect.h"
#include "PhxScanLayout.h"
#include "PhxNativeABI.h"
#include <cstdio>

using namespace phxscandirect;

static int fails, checks;
#define CHECK(c) do { checks++; if (!(c)) { fails++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static constexpr uint64_t kGiB = 1ull << 30;
static constexpr uint64_t kFrame1440 = 2560ull * 4 * 1440;   // 14.06 MiB
static constexpr uint64_t kSurf1440 = 0xE10000;              // the IOSurface's allocation, page-rounded

// the XTX machine at 2560x1440, BAR0 1 GiB, acquired, nothing bound
static Live live() {
    Live l{};
    l.on = true; l.owner = true; l.layKind = phxscanlay::kLarge; l.stride = phxscanlay::kLargeStride;
    l.barBytes = kGiB; l.aperBytes = kGiB; l.pitchPx = 2560; l.planeH = 1440;
    l.hubpFormat = kFmtArgb8888; l.swMode = 0; l.surfCtl = 0; l.vmid = 0;
    return l;
}
static Req req(uint32_t slot, uint32_t fmt = kFmtArgb8888) { return Req{slot, 0, 2560 * 4, 2560, 1440, fmt, 0}; }
static Bo hostBo(uint64_t size = kSurf1440) { return Bo{true, false, false, size}; }

int main() {
    // the ABI and the layout agree with this header
    CHECK(kSlotsEnd == phxscanlay::kLargeEnd);
    CHECK(kSlots == PHXN_SCAN_DIRECT_SLOTS && kSlots < PHXN_SCAN_MAX_SLOTS);
    CHECK(kFmtArgb8888 == PHXN_SCAN_FMT_ARGB8888 && kFmtArgb2101010 == PHXN_SCAN_FMT_ARGB2101010);
    CHECK(PHXN_SEL_SCAN_DIRECT == 22);   // inside RADV's radv_darwin_n48n_call range 22..26
    CHECK((PHXN_SCANQ_DIRECT_OK & (PHXN_SCANQ_LIT | PHXN_SCANQ_NATIVE | PHXN_SCANQ_ACQUIRED | PHXN_SCANQ_GEOM_OK)) == 0);
    CHECK((PHXN_SCANQ_DIRECT_OK & ((1u << 4) | (1u << 5) | (1u << 6))) == 0);   // Cobalt64's DTO_VALID / M6 / M6FLIP
    CHECK(((PHXN_SCANSLOT_DIRECT | PHXN_SCANSLOT_WRITABLE) & (PHXN_SCANSLOT_PENDING | PHXN_SCANSLOT_INUSE | PHXN_SCANSLOT_REUSABLE)) == 0);
    CHECK(PHXN_SCANSLOT_DIRECT != PHXN_SCANSLOT_WRITABLE);

    // condition 2: BAR0 over the slots, as assigned and as mapped
    CHECK(barCoversSlots(kGiB, kGiB));
    CHECK(barCoversSlots(352ull << 20, 352ull << 20));
    CHECK(!barCoversSlots(256ull << 20, 256ull << 20));   // no EFI BAR stage: copy path
    CHECK(!barCoversSlots(kGiB, 256ull << 20));           // the kernel maps less than the slots
    CHECK(!barCoversSlots(352ull << 20, (352ull << 20) - 4096));

    // the live case binds both slots
    Live l = live();
    CHECK(bindCheck(req(0), hostBo(), l) == kOk);
    CHECK(bindCheck(req(1), hostBo(), l) == kOk);
    CHECK(bindCheck(req(0, kFmtArgb2101010), hostBo(), [] { Live x = live(); x.hubpFormat = kFmtArgb2101010; return x; }()) == kOk);   // HDR
    CHECK(bindCheck(req(0), Bo{true, false, false, kFrame1440}, l) == kOk);    // exactly a frame
    CHECK(bindCheck(req(0), Bo{true, false, false, phxscanlay::kLargeStride}, l) == kOk);   // exactly a slot

    // condition 1: slots 0 and 1 of the large layout only
    CHECK(bindCheck(req(2), hostBo(), l) == kErrSlot);
    CHECK(bindCheck(req(7), hostBo(), l) == kErrSlot);
    { Live x = l; x.layKind = phxscanlay::kSmall; x.stride = phxscanlay::kSmallStride; CHECK(bindCheck(req(0), hostBo(), x) == kErrLayout); }
    { Live x = l; x.slotUsed[0] = true; CHECK(bindCheck(req(0), hostBo(), x) == kErrSlotUsed); CHECK(bindCheck(req(1), hostBo(), x) == kOk); }

    // condition 2 in the bind
    { Live x = l; x.barBytes = x.aperBytes = 256ull << 20; CHECK(bindCheck(req(0), hostBo(), x) == kErrBar); }

    // switch and owner first
    { Live x = l; x.on = false; CHECK(bindCheck(req(0), hostBo(), x) == kErrOff); }
    { Live x = l; x.owner = false; CHECK(bindCheck(req(0), hostBo(), x) == kErrNotOwner); }

    // geometry is HUBP0's plane, offset 0
    { Req r = req(0); r.offset = 4096; CHECK(bindCheck(r, hostBo(), l) == kErrGeom); }
    { Req r = req(0); r.reserved0 = 1; CHECK(bindCheck(r, hostBo(), l) == kErrGeom); }
    { Req r = req(0); r.pitchBytes = 2560 * 4 + 256; CHECK(bindCheck(r, hostBo(), l) == kErrGeom); }
    { Req r = req(0); r.width = 2048; CHECK(bindCheck(r, hostBo(), l) == kErrGeom); }
    { Req r = req(0); r.height = 1080; CHECK(bindCheck(r, hostBo(), l) == kErrGeom); }
    { Req r = req(0); r.height = 0; Live x = l; x.planeH = 0; CHECK(bindCheck(r, hostBo(), x) == kErrGeom); }
    { Live x = l; x.pitchPx = 0; CHECK(bindCheck(req(0), hostBo(), x) == kErrGeom); }

    // format = HUBP0's live format; only the two scan-out formats
    CHECK(bindCheck(req(0, kFmtArgb2101010), hostBo(), l) == kErrFormat);   // l10r surface, 8-bit scan-out: copy path narrows
    { Live x = l; x.hubpFormat = kFmtArgb2101010; CHECK(bindCheck(req(0), hostBo(), x) == kErrFormat); }   // BGRA on 10-bit
    CHECK(bindCheck(req(0, 3), hostBo(), [] { Live x = live(); x.hubpFormat = 3; return x; }()) == kErrFormat);

    // HUBP0 as Linux leaves a linear surface
    { Live x = l; x.swMode = 1; CHECK(bindCheck(req(0), hostBo(), x) == kErrPlane); }
    { Live x = l; x.surfCtl = kSurfCtlDcc; CHECK(bindCheck(req(0), hostBo(), x) == kErrPlane); }
    { Live x = l; x.surfCtl = kSurfCtlTmz; CHECK(bindCheck(req(0), hostBo(), x) == kErrPlane); }
    { Live x = l; x.surfCtl = 1u << 8; CHECK(bindCheck(req(0), hostBo(), x) == kOk); }   // secondary TMZ: not the primary surface
    { Live x = l; x.vmid = 3; CHECK(bindCheck(req(0), hostBo(), x) == kErrPlane); }
    { Live x = l; x.vmid = 0x10; CHECK(bindCheck(req(0), hostBo(), x) == kOk); }   // above VMID [3:0]

    // the BO: a system or host BO between a frame and a slot
    CHECK(bindCheck(req(0), Bo{false, false, false, kSurf1440}, l) == kErrBo);
    CHECK(bindCheck(req(0), Bo{true, false, true, kSurf1440}, l) == kErrBo);     // already rebound
    CHECK(bindCheck(req(0), Bo{true, true, false, kSurf1440}, l) == kErrBoVram);
    CHECK(bindCheck(req(0), Bo{true, false, false, kFrame1440 - 4096}, l) == kErrBoSize);
    CHECK(bindCheck(req(0), Bo{true, false, false, phxscanlay::kLargeStride + 4096}, l) == kErrBoSize);   // PTEs into the next slot

    // a bound BO's PTEs stay inside its slot, and both slots inside [256, 352) MiB
    for (uint32_t k = 0; k < kSlots; k++) {
        const phxscanlay::Layout lay{phxscanlay::kLargeBase, phxscanlay::kLargeStride, phxscanlay::kLarge};
        const uint64_t off = phxscanlay::slotOff(lay, k);
        CHECK(off >= phxscanlay::kLargeBase && off + phxscanlay::kLargeStride <= kSlotsEnd);
        CHECK(off + phxscanlay::kLargeStride <= phxscanlay::slotOff(lay, k + 1));
    }
    CHECK(phxscanlay::slotOff(phxscanlay::Layout{phxscanlay::kLargeBase, phxscanlay::kLargeStride, phxscanlay::kLarge}, 0) == 256ull << 20);
    CHECK(phxscanlay::slotOff(phxscanlay::Layout{phxscanlay::kLargeBase, phxscanlay::kLargeStride, phxscanlay::kLarge}, 1) == 288ull << 20);

    // condition 4: Linux's flip-complete test
    CHECK(writable(false, false, false));
    CHECK(!writable(true, false, false));    // a flip to it is programmed
    CHECK(!writable(false, true, false));    // EARLIEST_INUSE: HUBP0 still fetches it
    CHECK(!writable(false, false, true));    // the latched front (b74: FLIP_PENDING clear, EARLIEST_INUSE not there yet)
    CHECK(!writable(true, true, true));

    // condition 3: the BAR overlap test
    const uint64_t bar0 = 0xd000000000ull;
    CHECK(overlaps(bar0, 4096, bar0, kGiB));
    CHECK(overlaps(bar0 + kGiB - 4096, 4096, bar0, kGiB));
    CHECK(!overlaps(bar0 + kGiB, 4096, bar0, kGiB));
    CHECK(!overlaps(bar0 - 4096, 4096, bar0, kGiB));
    CHECK(overlaps(bar0 - 4096, 8192, bar0, kGiB));          // a segment straddling the start
    CHECK(overlaps(bar0 + 4096, 4096 * 2, bar0, kGiB));
    CHECK(!overlaps(bar0, 0, bar0, kGiB));
    CHECK(!overlaps(bar0, 4096, bar0, 0));
    CHECK(!overlaps(0x100000000ull, 64ull << 20, bar0, kGiB));   // ordinary system pages

    // every code has a name
    for (int r = kOk; r >= kErrBoSize; r--) CHECK(name(r)[0] != '?');
    CHECK(name(1)[0] == '?');

    std::printf("scan_direct_test: %d/%d checks passed\n", checks - fails, checks);
    return fails ? 1 : 0;
}
