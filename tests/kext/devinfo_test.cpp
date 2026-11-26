// SPDX-License-Identifier: MIT
// devinfo_test.cpp: host test of PhxDevInfo.h (b168), the IP discovery parser and the device info builder.
// c++ -std=c++17 -Wall -Wextra -Werror -I src/vermilion-boot -o /tmp/devinfo_test tests/kext/devinfo_test.cpp
//
// The discovery binaries here are built by the test in Linux's discovery.h layout (binary header, IP discovery table
// with one die, GC info v1.2 / v2.0, harvest, VCN and MALL tables) with made-up contents shaped like a Navi 31: no
// table read from a machine (CLAUDE.md rule 4). The expected device info is Mesa's "navi31" entry
// (src/amd/common/amdgpu_devices.c, a Linux AMDGPU_INFO_DEV_INFO answer of an RX 7900 XTX).
#include <cstdio>
#include <cstring>
#include <vector>

#include "PhxDevInfo.h"

using namespace phxdev;

static int gN, gF;
#define CHECK(c) do { gN++; if (!(c)) { gF++; std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

struct Blob {
    std::vector<uint8_t> b;
    void w8(size_t o, uint8_t v) { if (b.size() < o + 1) b.resize(o + 1); b[o] = v; }
    void w16(size_t o, uint16_t v) { w8(o, v & 0xff); w8(o + 1, v >> 8); }
    void w32(size_t o, uint32_t v) { w16(o, v & 0xffff); w16(o + 2, v >> 16); }
    uint16_t sum(size_t o, size_t n) const { uint16_t s = 0; for (size_t i = 0; i < n; i++) s = uint16_t(s + b[o + i]); return s; }
};

struct Ip { uint16_t hw; uint8_t inst, maj, min, rev; std::vector<uint32_t> base; };

struct Spec {
    uint16_t ipVersion = 4;
    bool base64 = false;
    std::vector<Ip> ips;
    int gcMajor = 1, gcMinor = 2;
    std::vector<uint32_t> gc;   // the GC info fields after its header
    std::vector<std::pair<uint16_t, uint8_t>> harvest;   // {hw id, instance}
    bool withHarvest = true, withVcn = true;
    int mallMajor = 2;
    uint32_t mallPerUmc = 16u << 20, mallSPresent = 0, mallHalfUse = 0;
};

// A Navi 31-shaped spec: GC 11.0.0 at 0x1260 / 0xA000, NBIO 4.3.0 with segment 2 at 0xD20, six UMC 8.10, VCN 4.0.0.
static Spec navi31() {
    Spec s;
    s.ips = {
        {kHwGc, 0, 11, 0, 0, {0x1260, 0xA000, 0x1A000, 0x1E000, 0x2DC00}},
        {kHwNbif, 0, 4, 3, 0, {0x0, 0x14, 0xD20, 0x10400, 0x241B000}},
        {kHwMmhub, 0, 3, 0, 0, {0x1A000, 0x2408800}},
        {kHwVcn, 0, 4, 0, 0, {0x7800, 0x7E00, 0x2403000}},
        {kHwDmu, 0, 3, 2, 0, {0x12, 0xC0, 0x34C0, 0x9000, 0x2403C00}},
    };
    for (uint8_t u = 0; u < 6; u++) s.ips.push_back({kHwUmc, u, 8, 10, 0, {0x14000u + u * 0x1000u}});
    // gc_info_v1_2: se, wgp0, wgp1, rb/se, gl2c, gprs, gs thds, gs table, gsprim, param cache, double lds, wave,
    // waves/simd, scratch, lds, sc/se, sa/se, packer/sc, gl2a, tcp/sa, sdp, tcps, tcp/wgp, tcp l1, sqc/wgp, l1 inst,
    // l1 data, gl1c/sa, gl1c size, gl2c/gpu
    s.gc = {6, 4, 0, 4, 24, 1536, 32, 32, 1792, 1024, 1, 32, 16, 32, 64, 4, 2, 4, 4, 8, 16, 96, 2, 32, 1, 32, 16, 1, 256, 6144};
    return s;
}

static Blob make(const Spec &s) {
    Blob x;
    const size_t ipOff = 0x40;
    // IP discovery header (80 B) + die header + IPs
    x.w32(ipOff + 0, kDiscoveryTableSignature);
    x.w16(ipOff + 4, s.ipVersion);
    x.w32(ipOff + 8, 0);
    x.w16(ipOff + 12, 1);   // one die
    const size_t dieOff = ipOff + 80;
    x.w16(ipOff + 14, 0);
    x.w16(ipOff + 16, uint16_t(dieOff));
    x.w8(ipOff + 78, s.base64 ? 1 : 0);
    x.w8(ipOff + 79, 0);
    x.w16(dieOff, 0);
    x.w16(dieOff + 2, uint16_t(s.ips.size()));
    size_t p = dieOff + 4;
    for (const Ip &ip : s.ips) {
        x.w16(p, ip.hw);
        x.w8(p + 2, ip.inst);
        x.w8(p + 3, uint8_t(ip.base.size()));
        x.w8(p + 4, ip.maj); x.w8(p + 5, ip.min); x.w8(p + 6, ip.rev); x.w8(p + 7, 0);
        p += 8;
        for (uint32_t base : ip.base) {
            if (s.base64) { x.w32(p, base | 0x40000000u); x.w32(p + 4, 0x12); p += 8; }   // bits above 30 dropped
            else { x.w32(p, base); p += 4; }
        }
    }
    const size_t ipSize = p - ipOff;
    x.w16(ipOff + 6, uint16_t(ipSize));
    // GC info
    const size_t gcOff = (p + 15) & ~size_t(15);
    x.w32(gcOff, kGcTableId);
    x.w16(gcOff + 4, uint16_t(s.gcMajor));
    x.w16(gcOff + 6, uint16_t(s.gcMinor));
    const uint32_t gcSize = uint32_t(12 + s.gc.size() * 4);
    x.w32(gcOff + 8, gcSize);
    for (size_t i = 0; i < s.gc.size(); i++) x.w32(gcOff + 12 + i * 4, s.gc[i]);
    size_t end = gcOff + gcSize;
    // harvest (8 + 32 x 4)
    size_t hOff = 0;
    if (s.withHarvest) {
        hOff = (end + 15) & ~size_t(15);
        x.w32(hOff, kHarvestTableSignature);
        x.w32(hOff + 4, 0);
        for (size_t i = 0; i < 32; i++) {
            x.w16(hOff + 8 + i * 4, i < s.harvest.size() ? s.harvest[i].first : 0);
            x.w8(hOff + 8 + i * 4 + 2, i < s.harvest.size() ? s.harvest[i].second : 0);
            x.w8(hOff + 8 + i * 4 + 3, 0);
        }
        end = hOff + 8 + 32 * 4;
    }
    // VCN info: header (12 B) + 16 bytes of body
    size_t vOff = 0;
    if (s.withVcn) {
        vOff = (end + 15) & ~size_t(15);
        x.w32(vOff, kVcnInfoTableId);
        x.w16(vOff + 4, 1); x.w16(vOff + 6, 0);
        x.w32(vOff + 8, 28);
        for (size_t i = 12; i < 28; i += 4) x.w32(vOff + i, 0x11);
        end = vOff + 28;
    }
    // MALL info (header + 9 dwords)
    size_t mOff = 0;
    if (s.mallMajor) {
        mOff = (end + 15) & ~size_t(15);
        x.w32(mOff, kMallInfoTableId);
        x.w16(mOff + 4, uint16_t(s.mallMajor)); x.w16(mOff + 6, 0);
        x.w32(mOff + 8, 48);
        x.w32(mOff + 12, s.mallPerUmc);
        x.w32(mOff + 16, s.mallMajor == 1 ? s.mallSPresent : 0);
        x.w32(mOff + 20, s.mallMajor == 1 ? s.mallHalfUse : 0);
        for (size_t i = 24; i < 48; i += 4) x.w32(mOff + i, 0);
        end = mOff + 48;
    }
    // binary header: signature, version 1.0, checksum, size, table list
    x.w32(0, kBinarySignature);
    x.w16(4, 1); x.w16(6, 0);
    x.w16(10, uint16_t(end));
    const size_t offs[kTables] = {ipOff, gcOff, hOff, vOff, mOff, 0};
    const size_t sizes[kTables] = {ipSize, gcSize, hOff ? size_t(8 + 32 * 4) : 0, vOff ? size_t(28) : 0, mOff ? size_t(48) : 0, 0};
    for (unsigned t = 0; t < kTables; t++) {
        x.w16(12 + t * 8, uint16_t(offs[t]));
        x.w16(12 + t * 8 + 2, offs[t] && t != kTabMall ? x.sum(offs[t], sizes[t]) : 0x5a5a);   // Linux ignores MALL's
        x.w16(12 + t * 8 + 4, uint16_t(sizes[t]));
        x.w16(12 + t * 8 + 6, 0);
    }
    x.b.resize(end);
    x.w16(8, x.sum(10, end - 10));
    return x;
}
static void resum(Blob &x) { x.w16(8, x.sum(10, x.b.size() - 10)); }

static Early early() {
    Early e{};
    e.vramMb = 24576;
    e.revStrap = 0x00000000;   // ATI_REV_ID 0
    e.deviceId = 0x744c;
    e.pciRev = 0xc8;
    e.linkCap = 0x447904;      // Gen4 x16 (what IOPCIFamily publishes on the GPU function)
    e.partnerLinkCap = 0;
    return e;
}
static GcRegs regsXtx() {
    GcRegs r{};
    r.read = true;
    r.gbAddrConfig = 0x00000545;
    return r;
}

static void testXtx() {
    const Blob x = make(navi31());
    CHECK(binarySize(x.b.data(), x.b.size()) == x.b.size());
    Discovery d;
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk);
    CHECK(d.gcMajor == 11 && d.gcMinor == 0 && d.gcRev == 0);
    CHECK(d.gcBase[0] == 0x1260 && d.gcBase[1] == 0xA000 && d.nbioBase[2] == 0xD20);
    CHECK(basesKnown(d));
    CHECK(regAbs(d, kGbAddrConfig) == 0x263E && regAbs(d, kCcSaUnitDisable) == 0x2249);
    CHECK(regAbs(d, kUserSaUnitDisable) == 0xFB92 && regAbs(d, kCcRbBackendDisable) == 0x263D);
    CHECK(regAbs(d, kUserRbBackendDisable) == 0xFB94 && regAbs(d, kCgtsTccDisable) == 0xF006);
    CHECK(regAbs(d, kCgtsUserTccDisable) == 0xFB96 && regAbs(d, kRccStrap0) == 0xD36);
    CHECK(regAbs(d, kRccConfigMemsize) == kRccConfigMemsizeAbs && kRccConfigMemsizeAbs == 0xDE3);
    CHECK(d.numUmc == 6 && d.umcMajor == 8 && d.umcMinor == 10);
    CHECK(d.vcnMajor == 4 && d.vcnMinor == 0 && d.vcnConfig == 0);
    CHECK(d.numSe == 6 && d.numSaPerSe == 2 && d.maxCuPerSa == 8 && d.numRbPerSe == 4 && d.numGl2c == 24);
    CHECK(d.numScPerSa == 2 && d.numPackerPerSc == 4);
    CHECK(d.mallBytes == 96ull << 20);

    phxn_devinfo o;
    CHECK(build(d, early(), regsXtx(), &o, "AMD Radeon RX 7900 XTX"));
    CHECK(o.version == PHXN_DEVINFO_VERSION && o.size == sizeof(phxn_devinfo));
    CHECK(o.flags == (PHXN_DEV_VALID | PHXN_DEV_GC_REGS | PHXN_DEV_CU_PER_SA_FULL | PHXN_DEV_VRAM_FROM_UMC |
                      PHXN_DEV_CLOCKS_DEFAULT | PHXN_DEV_FW_DEFAULT));
    CHECK(std::strcmp(o.name, "AMD Radeon RX 7900 XTX") == 0);
    // Mesa's navi31 entry (a Linux XTX): every field the table and registers give
    CHECK(o.device_id == 0x744c && o.pci_rev == 0xc8 && o.chip_rev == 0 && o.external_rev == 1);
    CHECK(o.family == kFamilyGc1100 && o.gc_ip == 0xb0000);
    CHECK(o.num_se == 6 && o.num_sa_per_se == 2 && o.num_cu_per_sa == 8);
    CHECK(o.cu_active_number == 96 && o.sa_active_mask == 0xfff);
    CHECK(o.num_rb_pipes == 24 && o.enabled_rb_pipes_mask == 0xffffff);
    CHECK(o.num_tcc_blocks == 24 && o.tcc_disabled_mask == 0);
    CHECK(o.num_gprs == 1536 && o.gs_vgt_table_depth == 32 && o.gs_prim_buffer_depth == 1792 && o.max_gs_waves_per_vgt == 32);
    CHECK(o.wave_size == 32 && o.num_hw_gfx_contexts == 8);
    CHECK(o.tcp_cache_kb == 32 && o.num_sqc_per_wgp == 1 && o.sqc_data_cache_kb == 16 && o.sqc_inst_cache_kb == 32);
    CHECK(o.gl1c_cache_kb == 256 && o.gl2c_cache_kb == 6144 && o.mall_size == 100663296ull);
    CHECK(o.vram_type == kVramTypeGddr6 && o.vram_bit_width == 384 && o.vram_mb == 24576);
    CHECK(o.pcie_gen == 4 && o.pcie_num_lanes == 16);
    CHECK(o.gb_addr_config == 0x545);
    CHECK(o.gpu_counter_khz == 100000 && o.max_engine_khz == 2371000 && o.max_memory_khz == 1249000);
    CHECK(o.min_engine_khz == 500000 && o.min_memory_khz == 96000);
    CHECK(o.fw_me == 2420 && o.fw_pfp == 2580 && o.fw_mec == 2650 && o.fw_pfp_feature == 29);
    // cu_bitmap: SE0-3 rows 0-3 columns 0-1, SE4-5 rows 0-1 columns 2-3
    for (unsigned r = 0; r < 4; r++) {
        CHECK(o.cu_bitmap[r][0] == 0xff && o.cu_bitmap[r][1] == 0xff);
        CHECK(o.cu_bitmap[r][2] == (r < 2 ? 0xffu : 0u) && o.cu_bitmap[r][3] == (r < 2 ? 0xffu : 0u));
    }
    // the revision strap: ATI_REV_ID in 27:24, external = + 1 on GC 11.0.0
    Early e = early();
    e.revStrap = 0x01000000;
    CHECK(build(d, e, regsXtx(), &o, nullptr) && o.chip_rev == 1 && o.external_rev == 2 && o.name[0] == 0);
    // the text form
    char buf[2048];
    build(d, early(), regsXtx(), &o, "AMD Radeon RX 7900 XTX");
    const size_t len = format(o, buf, sizeof buf);
    CHECK(len > 0 && len < sizeof buf && std::strlen(buf) == len);
    CHECK(std::strstr(buf, "\"AMD Radeon RX 7900 XTX\"") && std::strstr(buf, "GC 11.0.0") && std::strstr(buf, "384-bit"));
    CHECK(std::strstr(buf, "96 active") && std::strstr(buf, "valid gc-regs"));
    char tiny[16];
    CHECK(format(o, tiny, sizeof tiny) == sizeof tiny - 1 && tiny[sizeof tiny - 1] == 0);
}

static void testRegisters() {
    const Blob x = make(navi31());
    Discovery d;
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk);
    phxn_devinfo o;
    // before the GFX block is up: no harvest read, everything the table allows
    GcRegs none{};
    CHECK(build(d, early(), none, &o, nullptr));
    CHECK(!(o.flags & PHXN_DEV_GC_REGS) && o.cu_active_number == 96 && o.enabled_rb_pipes_mask == 0xffffff && o.gb_addr_config == 0);
    // SA 11 (SE5 SA1) fused off, SA 3 disabled by the driver's user register: 80 CUs, their RBs gone unless global
    GcRegs r = regsXtx();
    r.ccSaDisable = (1u << 11) << 8;
    r.userSaDisable = (1u << 3) << 8;
    r.ccRbDisable = 0xfffff000u;   // RBs 8..27 off in the global mask (bits 31:4 = RB 0..27)
    build(d, early(), r, &o, nullptr);
    CHECK(o.sa_active_mask == (0xfffu & ~((1u << 11) | (1u << 3))));
    CHECK(o.cu_active_number == 80);
    CHECK(o.cu_bitmap[1][1] == 0 && o.cu_bitmap[1][3] == 0 && o.cu_bitmap[1][2] == 0xff && o.cu_bitmap[3][1] == 0xff);   // SE1 SA1, SE5 SA1
    // gfx_v11_0_setup_rb: 0x3 per active SA, ORed with the global mask (RB 0..7 here)
    uint32_t want = 0;
    for (unsigned i = 0; i < 12; i++) if (o.sa_active_mask & (1u << i)) want |= 0x3u << (i * 2);
    want |= 0xffu;
    CHECK(o.enabled_rb_pipes_mask == want);
    // gfx_v11_0_get_tcc_info: TCC_DISABLE 31:16 | HI_TCC_DISABLE 15:8 << 16, over both registers
    r = regsXtx();
    r.tccDisable = 0x0c030000u;
    r.userTccDisable = 0x00000100u;
    build(d, early(), r, &o, nullptr);
    CHECK(o.tcc_disabled_mask == (0x0c03ull | (0x1ull << 16)));
    // PCIe: the lower of the GPU's and its partner's capabilities
    Early e = early();
    e.partnerLinkCap = 0x3 | (8u << 4);   // Gen3 x8
    build(d, e, regsXtx(), &o, nullptr);
    CHECK(o.pcie_gen == 3 && o.pcie_num_lanes == 8);
    e.partnerLinkCap = 0x5 | (16u << 4);   // Gen5 x16
    build(d, e, regsXtx(), &o, nullptr);
    CHECK(o.pcie_gen == 4 && o.pcie_num_lanes == 16);
}

static void testLayouts() {
    // 64-bit base addresses (ip v4 flag): bits above 30 are dropped, the entries are 8 bytes each
    Spec s = navi31();
    s.base64 = true;
    Blob x = make(s);
    Discovery d;
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk && basesKnown(d) && d.numUmc == 6 && d.gcBase[1] == 0xA000);
    // the 64-bit flag only counts from table version 4
    s.ipVersion = 3;
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) != kOk || !basesKnown(d));
    // harvest: two UMCs and the VCN fused off: 4 UMCs, 256-bit, 64 MiB of MALL
    s = navi31();
    s.harvest = {{kHwUmc, 4}, {kHwUmc, 5}, {kHwVcn, 1}};
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk && d.numUmc == 4 && d.umcHarvest == 2 && d.vcnHarvest == 1);
    CHECK(d.mallBytes == 64ull << 20);
    phxn_devinfo o;
    build(d, early(), regsXtx(), &o, nullptr);
    CHECK(o.vram_bit_width == 256 && o.num_umc == 4);
    // MALL v1: per-UMC size, doubled where m_s_present, halved where half_use (which also halves channels)
    s = navi31();
    s.mallMajor = 1;
    s.mallSPresent = 1u << 0;
    s.mallHalfUse = (1u << 1) | (1u << 2);
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk);
    CHECK(d.mallBytes == (2 + 0.5 + 0.5 + 1 + 1 + 1) * (16u << 20));
    build(d, early(), regsXtx(), &o, nullptr);
    CHECK(o.vram_bit_width == (24 - 4) * 16);
    // a half-use mask with more bits than there are channels: no VRAM type / width (never a wrapped width)
    s.mallHalfUse = 0xffffffffu;
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk);
    build(d, early(), regsXtx(), &o, nullptr);
    CHECK(o.vram_bit_width == 0 && o.vram_type == 0 && !(o.flags & PHXN_DEV_VRAM_FROM_UMC) && (o.flags & PHXN_DEV_VALID));
    // no MALL table: 0
    s = navi31();
    s.mallMajor = 0;
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk && d.mallBytes == 0);
    // GC info v2.0: CUs per SH directly, no v1.2 caches
    s = navi31();
    s.gcMajor = 2;
    s.gcMinor = 0;
    s.gc = {6, 8, 2, 4, 24, 1536, 32, 32, 1792, 1024, 0, 32, 16, 32, 64, 4, 4};
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk);
    CHECK(d.numSe == 6 && d.maxCuPerSa == 8 && d.numSaPerSe == 2 && d.numScPerSa == 2 && d.numPackerPerSc == 4);
    CHECK(d.tcpL1Kb == 0 && d.gl2cKb == 0);
    // GC info v1.0 (no caches)
    s = navi31();
    s.gcMinor = 0;
    s.gc.resize(19);
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk && d.maxCuPerSa == 8 && d.tcpL1Kb == 0);
    // an invalid entry (instance >= 44, hw id >= 300) is skipped, as amdgpu_discovery_validate_ip does
    s = navi31();
    s.ips.push_back({kHwUmc, 44, 8, 10, 0, {1}});
    s.ips.push_back({301, 0, 1, 0, 0, {1}});
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk && d.numUmc == 6);
    // VCN capability bits ride in the revision's top two bits
    s = navi31();
    s.ips[3].rev = 0x80;
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk && d.vcnConfig == 0x80 && d.vcnRev == 0);
    // another layout: no register is read where the table points
    s = navi31();
    s.ips[0].base[0] = 0x1261;
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk && !basesKnown(d) && regAbs(d, kGbAddrConfig) == 0);
    s = navi31();
    s.ips[1].base[2] = 0xD24;
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk && !basesKnown(d) && regAbs(d, kRccStrap0) == 0);
    s = navi31();
    s.ips[0].rev = 1;   // GC 11.0.1 (Phoenix): not the ASIC the register tables are for
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk && !basesKnown(d));
}

static void testCorrupt() {
    const Blob good = make(navi31());
    Discovery d;
    // nothing, a short buffer, a truncated image
    CHECK(parse(nullptr, 0, &d) == kErrShort);
    CHECK(parse(good.b.data(), 30, &d) == kErrShort);
    CHECK(parse(good.b.data(), good.b.size() - 1, &d) == kErrShort);
    CHECK(binarySize(good.b.data(), 8) == 0);
    // signature
    Blob x = good;
    x.w32(0, 0x12345678);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrSignature && binarySize(x.b.data(), x.b.size()) == 0);
    // a flipped byte anywhere after the binary checksum
    for (size_t at : {size_t(12), size_t(0x40 + 20), good.b.size() - 1}) {
        x = good;
        x.b[at] ^= 0x10;
        CHECK(parse(x.b.data(), x.b.size(), &d) == kErrChecksum);
    }
    // a table's own checksum (binary checksum made right again)
    x = good;
    x.b[0x40 + 90] ^= 1;
    resum(x);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrIpTable);
    // the IP table's size beyond the image
    x = good;
    x.w16(0x40 + 6, 0xfff0);
    resum(x);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrIpTable);
    // die count 0 and 17, a die id that is not its index
    for (uint16_t n : {uint16_t(0), uint16_t(17)}) {
        x = good;
        x.w16(0x40 + 12, n);
        x.w16(12 + 2, x.sum(0x40, x.b[0x40 + 6] | (x.b[0x40 + 7] << 8)));
        resum(x);
        CHECK(parse(x.b.data(), x.b.size(), &d) == kErrDie);
    }
    x = good;
    x.w16(0x40 + 80, 1);
    x.w16(12 + 2, x.sum(0x40, x.b[0x40 + 6] | (x.b[0x40 + 7] << 8)));
    resum(x);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrDie);
    // an IP count that runs past the image
    x = good;
    x.w16(0x40 + 82, 0x7fff);
    x.w16(12 + 2, x.sum(0x40, x.b[0x40 + 6] | (x.b[0x40 + 7] << 8)));
    resum(x);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrIpTable);
    // no GC entry
    Spec s = navi31();
    s.ips.erase(s.ips.begin());
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrNoGc);
    // GC table: wrong id, unknown major, too small, absurd counts
    const size_t gcOff = good.b[12 + 8] | (good.b[12 + 9] << 8);
    x = good;
    x.w32(gcOff, 0x1234);
    resum(x);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrGcTable);
    s = navi31();
    s.gcMajor = 3;
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrGcTable);
    s = navi31();
    s.gc.resize(10);
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrGcTable);
    s = navi31();
    s.gc[0] = 0;
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrGcTable);
    s = navi31();
    s.gc[0] = 9;
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrGcTable);
    s = navi31();
    s.gc[16] = 0;   // no SAs: the division Linux would do by zero
    x = make(s);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrGcTable);
    // harvest and VCN tables
    const size_t hOff = good.b[12 + 16] | (good.b[12 + 17] << 8);
    x = good;
    x.w32(hOff, 0);
    resum(x);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrHarvest);
    const size_t vOff = good.b[12 + 24] | (good.b[12 + 25] << 8);
    x = good;
    x.b[vOff + 20] ^= 4;
    resum(x);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kErrVcnTable);
    // a bad MALL table is ignored (Linux does not check it either): no MALL size, the rest stands
    const size_t mOff = good.b[12 + 32] | (good.b[12 + 33] << 8);
    x = good;
    x.w32(mOff, 0);
    resum(x);
    CHECK(parse(x.b.data(), x.b.size(), &d) == kOk && d.mallBytes == 0);
    // an invalid table: build says so, keeps the identity and the VRAM size, no device values
    x = good;
    x.w32(0, 0);
    parse(x.b.data(), x.b.size(), &d);
    phxn_devinfo o;
    CHECK(!build(d, early(), regsXtx(), &o, "AMD Radeon RX 7900 XTX"));
    CHECK(!(o.flags & PHXN_DEV_VALID) && o.discovery_err == kErrSignature && o.num_se == 0 && o.vram_mb == 24576);
    CHECK(o.device_id == 0x744c && std::strcmp(o.name, "AMD Radeon RX 7900 XTX") == 0);
    CHECK(!basesKnown(d) && regAbs(d, kGbAddrConfig) == 0);
    // random damage with the binary checksum made right again: never a read outside the image (run under ASan), and
    // the result is either a parse or one of the errors
    uint32_t seed = 12345;
    auto rnd = [&seed]() { seed = seed * 1103515245u + 12345u; return seed >> 8; };
    int parsed = 0;
    for (int i = 0; i < 20000; i++) {
        x = good;
        for (unsigned k = 0, n = 1 + rnd() % 4; k < n; k++) x.b[12 + rnd() % (x.b.size() - 12)] = uint8_t(rnd());
        resum(x);
        const int32_t r = parse(x.b.data(), x.b.size(), &d);
        parsed += r == kOk;
        if (r != kOk && (r > kOk || r < kErrDie)) { CHECK(false); break; }
        if (r == kOk) build(d, early(), regsXtx(), &o, nullptr);
    }
    CHECK(parsed > 0 && parsed < 20000);
}

int main() {
    static_assert(sizeof(phxn_devinfo) == 512, "devinfo");
    static_assert(sizeof(phxn_info_dev) == 704, "info_dev");
    testXtx();
    testRegisters();
    testLayouts();
    testCorrupt();
    std::printf("devinfo_test: %d/%d checks passed\n", gN - gF, gN);
    return gF ? 1 : 0;
}
