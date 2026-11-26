// SPDX-License-Identifier: MIT
// gpu_id_test.cpp: host test of src/vermilion-boot/PhxGpuId.h (which board Vermilion starts on: RX 7900 XTX only).
//   c++ -std=c++17 -Wall -Wextra -Werror -I src/vermilion-boot -o /tmp/gpu_id_test tests/kext/gpu_id_test.cpp && /tmp/gpu_id_test
#include "PhxGpuId.h"
#include <cstdio>
#include <cstring>
static int gN, gF;
#define CHECK(c) do { gN++; if (!(c)) { gF++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)
using namespace phxgpu;

// A PCI device double: the config space as three reads, and a count of every access.
struct FakePci {
    uint16_t vendor, device;
    uint8_t revision;
    mutable int reads = 0;
    uint16_t configRead16(unsigned off) const { reads++; return off == kCfgVendor ? vendor : off == kCfgDevice ? device : 0xffff; }
    uint8_t configRead8(unsigned off) const { reads++; return off == kCfgRevision ? revision : 0xff; }
};

static bool starts(uint16_t v, uint16_t d, uint8_t r) { return supported(classify(v, d, r)); }

int main() {
    // the one board
    CHECK(starts(0x1002, 0x744c, 0xc8));
    CHECK(classify(0x1002, 0x744c, 0xc8) == Board::Xtx);
    // the other 0x744c boards by name, all refused
    CHECK(classify(0x1002, 0x744c, 0xcc) == Board::Xt && !starts(0x1002, 0x744c, 0xcc));
    CHECK(classify(0x1002, 0x744c, 0xce) == Board::Gre && !starts(0x1002, 0x744c, 0xce));
    CHECK(classify(0x1002, 0x744c, 0xcf) == Board::Mobile && !starts(0x1002, 0x744c, 0xcf));
    // every other revision of 0x744c is refused (an unknown variant), 0x00..0xff
    int accepted = 0;
    for (unsigned r = 0; r < 256; r++) {
        if (starts(0x1002, 0x744c, static_cast<uint8_t>(r))) accepted++;
        if (r != 0xc8 && r != 0xcc && r != 0xce && r != 0xcf) CHECK(classify(0x1002, 0x744c, r) == Board::OtherNavi31);
    }
    CHECK(accepted == 1);
    // only the low byte of a register value counts (the audio kext reads a 4-byte revision-id property)
    CHECK(starts(0x1002, 0x744c, 0x000000c8));
    CHECK(classify(0x1002, 0x744c, 0xffffffffu) == Board::OtherNavi31);
    // another device or vendor is never a Navi 31 board, whatever its revision
    for (unsigned r = 0; r < 256; r++) {
        CHECK(!starts(0x1002, 0x7480, static_cast<uint8_t>(r)));   // Navi 33
        CHECK(!starts(0x1002, 0x73bf, static_cast<uint8_t>(r)));   // Navi 21
        CHECK(!starts(0x1002, 0x164e, static_cast<uint8_t>(r)));   // Raphael iGPU
        CHECK(!starts(0x10de, 0x744c, static_cast<uint8_t>(r)));   // wrong vendor
        CHECK(!starts(0x8086, 0x744c, static_cast<uint8_t>(r)));
    }
    CHECK(classify(0x1002, 0xab30, 0xc8) == Board::NotNavi31);   // the HDA function is not the GPU
    // an absent or dead function reads all ones
    CHECK(classify(0xffff, 0xffff, 0xff) == Board::NotNavi31 && !starts(0xffff, 0xffff, 0xff));
    // through a PCI object: three reads, and only config reads
    FakePci xtx{0x1002, 0x744c, 0xc8}, xt{0x1002, 0x744c, 0xcc}, dead{0xffff, 0xffff, 0xff};
    CHECK(classifyPci(&xtx) == Board::Xtx && xtx.reads == 3);
    CHECK(classifyPci(&xt) == Board::Xt && xt.reads == 3);
    CHECK(classifyPci(&dead) == Board::NotNavi31);
    CHECK(classifyPci(static_cast<FakePci *>(nullptr)) == Board::NotNavi31);   // a provider that is not a PCI device
    // names: the log line names the board, the XTX is the one that says XTX
    CHECK(std::strcmp(name(Board::Xtx), "RX 7900 XTX") == 0 && std::strcmp(name(Board::Xt), "RX 7900 XT") == 0);
    CHECK(std::strcmp(name(Board::Gre), "RX 7900 GRE") == 0 && std::strcmp(name(Board::Mobile), "RX 7900M") == 0);
    CHECK(std::strlen(name(Board::OtherNavi31)) > 0 && std::strlen(name(Board::NotNavi31)) > 0);
    // b168: the PCI device's "model" and the device info's name, as amdgpu.ids spells them
    CHECK(std::strcmp(marketingName(Board::Xtx), "AMD Radeon RX 7900 XTX") == 0);
    CHECK(std::strcmp(marketingName(Board::Xt), "AMD Radeon RX 7900 XT") == 0);
    CHECK(std::strcmp(marketingName(Board::NotNavi31), "AMD Radeon Graphics") == 0);
    // the constants the kexts' Info.plists match on
    CHECK(kVendorAmd == 0x1002 && kDeviceNavi31 == 0x744c && kRevXtx == 0xc8);
    std::printf("gpu_id_test: %d/%d checks passed\n", gN - gF, gN);
    return gF ? 1 : 0;
}
