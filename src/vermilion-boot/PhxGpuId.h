// SPDX-License-Identifier: MIT
// PhxGpuId.h: which board Vermilion starts on. Only an AMD Radeon RX 7900 XTX (PCI 1002:744c, revision 0xC8).
//
// Owner decision 2026-11-25: XTX only. The same device ID 0x744c is shared by four boards that differ in what is
// disabled on the die (CUs, memory channels, GL2 channels), so the device ID alone does not say which register plans,
// apertures and watermarks apply. The PCI revision tells them apart, the way Linux amdgpu's libdrm table does
// (data/amdgpu.ids, read 2026-11-25):
//     744C, C8  AMD Radeon RX 7900 XTX
//     744C, CC  AMD Radeon RX 7900 XT
//     744C, CE  AMD Radeon RX 7900 GRE
//     744C, CF  AMD Radeon RX 7900M
// 0xC8 was read on the XTX machine (XFX Speedster MERC 310, REFERENCE-MACHINES.md). The XT's 0xCC is upstream's
// reading, not ours; this fork has not run on it. Every other revision, and any other device, is refused.
//
// The decision reads three PCI config registers (vendor, device, revision) and nothing else: no BAR is mapped and no
// GPU register is touched before it. A config read of an absent or dead function returns all ones, which is refused.
//
// Kernel-free (the PCI object is a template parameter); used by VermilionBoot (PhxBringup, PhxFBSquatter),
// VermilionAccel (NMXAccel) and VermilionAudio; host test tests/kext/gpu_id_test.cpp.
#pragma once
#include <stdint.h>

namespace phxgpu {

constexpr uint16_t kVendorAmd = 0x1002;
constexpr uint16_t kDeviceNavi31 = 0x744c;
constexpr uint8_t kRevXtx = 0xc8;   // RX 7900 XTX: the only board Vermilion starts on
constexpr uint8_t kRevXt = 0xcc;    // RX 7900 XT: upstream's board, refused
constexpr uint8_t kRevGre = 0xce;   // RX 7900 GRE, refused
constexpr uint8_t kRevMobile = 0xcf;   // RX 7900M, refused

// PCI configuration space offsets (IOPCIDevice's kIOPCIConfigVendorID / DeviceID / RevisionID)
constexpr unsigned kCfgVendor = 0x00, kCfgDevice = 0x02, kCfgRevision = 0x08;

enum class Board {
    Xtx,            // 1002:744c rev C8: supported
    Xt,             // 1002:744c rev CC
    Gre,            // 1002:744c rev CE
    Mobile,         // 1002:744c rev CF
    OtherNavi31,    // 1002:744c, any other revision
    NotNavi31,      // any other vendor or device, or an unreadable function
};

inline Board classify(uint32_t vendor, uint32_t device, uint32_t revision) {
    if (vendor != kVendorAmd || device != kDeviceNavi31) return Board::NotNavi31;
    switch (revision & 0xff) {
        case kRevXtx: return Board::Xtx;
        case kRevXt: return Board::Xt;
        case kRevGre: return Board::Gre;
        case kRevMobile: return Board::Mobile;
        default: return Board::OtherNavi31;
    }
}

inline bool supported(Board b) { return b == Board::Xtx; }

inline const char *name(Board b) {
    switch (b) {
        case Board::Xtx: return "RX 7900 XTX";
        case Board::Xt: return "RX 7900 XT";
        case Board::Gre: return "RX 7900 GRE";
        case Board::Mobile: return "RX 7900M";
        case Board::OtherNavi31: return "an unknown Navi 31 board";
        default: return "not a Navi 31 board";
    }
}

// The board a PCI object (IOPCIDevice, or a test double with configRead16 / configRead8) is. Config reads only.
template <class Pci>
inline Board classifyPci(Pci *pci) {
    if (!pci) return Board::NotNavi31;
    return classify(pci->configRead16(kCfgVendor), pci->configRead16(kCfgDevice), pci->configRead8(kCfgRevision));
}

}  // namespace phxgpu
