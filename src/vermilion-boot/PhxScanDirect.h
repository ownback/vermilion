// SPDX-License-Identifier: MIT
// PhxScanDirect.h (b162): direct scan-out of WindowServer's display surfaces, the kernel-free rules. Pure (no kernel
// headers), so tests/kext/scan_direct_test.cpp builds it on a host.
//
// GPU present (phx_scan.cpp) copies each display surface from its system pages into a VRAM slot and flips HUBP0 to the
// slot. Direct scan-out binds the display surface itself to a slot instead: the BO the plugin draws the surface through
// (a host import of the IOSurface's pages, or a system BO) gets local-VRAM PTEs onto the slot (vmMapVram, the same
// rebinding PHXN_SEL_SCAN_REGISTER does for the copy slots), so CoreDisplay's pass writes VRAM and HUBP0 scans it with
// no copy. The flip stays today's three writes (scanFlipLocked: a subset of Linux's hubp3_program_surface_flip_and_addr
// at the same large-slot addresses); nothing else on the display side is written.
//
// hw-safety review of 2026-11-25 (finding 2026-11-25-windowserver-composite-cost.md, section 4, fix 1), its five
// conditions as they appear here:
//   1. the kext's fixed large slots, two of them: a direct bind takes slot 0 or 1 (VRAM 256 / 288 MiB), never a new
//      VRAM range (bindCheck: kErrSlot, kErrLayout);
//   2. BAR0 covers the slots, else the copy path (barCoversSlots; live BAR0 1 GiB, 256 MiB without the EFI stage);
//   3. the GPU never reaches its own BAR through a host import (overlaps: doBoImportHost refuses such pages);
//   4. nothing writes a surface HUBP0 may be fetching: slot k is writable only when it is not pending, not
//      EARLIEST_INUSE and not the latched front (writable(): Linux's flip-complete test, hubp2_is_flip_pending as
//      dcn32_hubp.c uses it, plus the b74 taken-flip case);
//   5. flip away before free: a slot BO's free restores the console first (doBoFree), so does the release.
#pragma once
#include <stdint.h>

namespace phxscandirect {

constexpr uint64_t kMiB = 1ull << 20;
constexpr uint32_t kSlots = 2;                       // condition 1: slots 0 and 1 of the large layout
constexpr uint64_t kSlotsEnd = 352 * kMiB;           // PhxScanLayout.h kLargeEnd: the large slots end here
constexpr int kLayLarge = 1;                         // PhxScanLayout.h phxscanlay::kLarge (not included: Live.layKind)
constexpr uint32_t kFmtArgb8888 = 8, kFmtArgb2101010 = 10;   // PHXN_SCAN_FMT_*
// HUBPREQ0_DCSURF_SURFACE_CONTROL (dcn_3_2_0_sh_mask.h): bit 0 PRIMARY_SURFACE_TMZ, bit 1 PRIMARY_SURFACE_DCC_EN
constexpr uint32_t kSurfCtlTmz = 1u << 0, kSurfCtlDcc = 1u << 1;
constexpr uint32_t kVmidMask = 0xfu;                 // HUBPREQ0_VMID_SETTINGS_0 VMID [3:0]

enum : int {
    kOk = 0,
    kErrOff = -1,         // debug.phxscan_direct = 0
    kErrNotOwner = -2,    // not acquired by this client
    kErrLayout = -3,      // not the large layout (the small slots sit below every other region, no CPU view needed there)
    kErrBar = -4,         // BAR0 (or the kernel's view of it) ends before 352 MiB: copy path (condition 2)
    kErrSlot = -5,        // slot not 0 or 1
    kErrSlotUsed = -6,    // that slot is already registered or bound
    kErrGeom = -7,        // offset, pitch, width or height differ from HUBP0's live plane
    kErrFormat = -8,      // the surface's format is not HUBP0's live format
    kErrPlane = -9,       // HUBP0 not linear, DCC or TMZ on, or a VMID set: not Linux's state for this surface
    kErrBo = -10,         // no such BO, or it is freed, or already bound
    kErrBoVram = -11,     // a VRAM-pool BO (b156): its own VRAM range, never rebound
    kErrBoSize = -12,     // smaller than the frame, or larger than a slot (its PTEs would reach the next slot)
};

struct Req { uint32_t slot, reserved0, pitchBytes, width, height, format; uint64_t offset; };
struct Bo { bool found, vram, bound; uint64_t size; };
struct Live {
    bool on, owner;            // debug.phxscan_direct; acquired by this client
    int layKind;               // phxscanlay::kSmall / kLarge of this acquisition
    uint64_t stride;           // slot stride of this acquisition
    uint64_t barBytes, aperBytes;   // BAR0 as assigned, and the part the kernel maps
    uint32_t pitchPx, planeH;  // the acquisition's plane
    uint32_t hubpFormat, swMode, surfCtl, vmid;   // HUBP0 live: SURFACE_CONFIG [6:0], TILING_CONFIG [4:0], SURFACE_CONTROL, VMID
    bool slotUsed[kSlots];
};

// condition 2: the slots are inside BAR0 and inside the kernel's mapping of it
constexpr bool barCoversSlots(uint64_t barBytes, uint64_t aperBytes) { return barBytes >= kSlotsEnd && aperBytes >= kSlotsEnd; }

inline int bindCheck(const Req &r, const Bo &b, const Live &l) {
    if (!l.on) return kErrOff;
    if (!l.owner) return kErrNotOwner;
    if (l.layKind != kLayLarge) return kErrLayout;
    if (!barCoversSlots(l.barBytes, l.aperBytes)) return kErrBar;
    if (r.slot >= kSlots) return kErrSlot;
    if (l.slotUsed[r.slot]) return kErrSlotUsed;
    if (r.reserved0 || r.offset || !l.pitchPx || r.pitchBytes != l.pitchPx * 4 || r.width != l.pitchPx || r.height != l.planeH || !r.height)
        return kErrGeom;
    if ((r.format != kFmtArgb8888 && r.format != kFmtArgb2101010) || r.format != l.hubpFormat) return kErrFormat;
    if (l.swMode || (l.surfCtl & (kSurfCtlTmz | kSurfCtlDcc)) || (l.vmid & kVmidMask)) return kErrPlane;
    if (!b.found || b.bound) return kErrBo;
    if (b.vram) return kErrBoVram;
    const uint64_t frame = static_cast<uint64_t>(r.pitchBytes) * r.height;
    if (b.size < frame || b.size > l.stride) return kErrBoSize;
    return kOk;
}

// condition 4: the flip-complete test for slot k. pending / front: the kernel's flip bookkeeping (scanPollLocked);
// inuse: HUBP0's SURFACE_EARLIEST_INUSE is this slot's address.
constexpr bool writable(bool pending, bool inuse, bool front) { return !pending && !inuse && !front; }

// condition 3: [a, a + alen) and [b, b + blen) share a byte (empty ranges share nothing)
constexpr bool overlaps(uint64_t a, uint64_t alen, uint64_t b, uint64_t blen) {
    return alen && blen && a < b + blen && b < a + alen;
}

inline const char *name(int r) {
    switch (r) {
        case kOk: return "bound";
        case kErrOff: return "refused: debug.phxscan_direct=0";
        case kErrNotOwner: return "refused: not acquired by this client";
        case kErrLayout: return "refused: not the large slot layout";
        case kErrBar: return "refused: BAR0 ends below 352 MiB (copy path)";
        case kErrSlot: return "refused: slot not 0 or 1";
        case kErrSlotUsed: return "refused: slot in use";
        case kErrGeom: return "refused: geometry differs from HUBP0's plane";
        case kErrFormat: return "refused: format is not HUBP0's";
        case kErrPlane: return "refused: HUBP0 tiled, DCC, TMZ or VMID set";
        case kErrBo: return "refused: no such BO, or already bound";
        case kErrBoVram: return "refused: VRAM-pool BO";
        case kErrBoSize: return "refused: BO smaller than the frame or larger than a slot";
        default: return "?";
    }
}

}  // namespace phxscandirect
