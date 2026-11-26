// SPDX-License-Identifier: MIT
// PhxDevInfo.h: the GPU's device info from the hardware, the way Linux amdgpu gets it (b168, plan A4 / A19).
//
// Kernel-free: tests/kext/devinfo_test.cpp builds synthetic IP discovery tables and register values on a host.
//
// Sources. Every access is a read, except that the MM_INDEX / MM_DATA window needs its two index writes (MM_INDEX_HI,
// MM_INDEX), which Linux makes for the same read. No other register write, no SMU, PSP or DAL message:
//   - the IP discovery table: 10 KiB at the top of VRAM minus 64 KiB, where the firmware leaves it at power-on. Linux
//     reads it there at probe (amdgpu_discovery_read_binary_from_mem: pos = (RCC_CONFIG_MEMSIZE << 20) - 64 KiB,
//     DISCOVERY_TMR_SIZE 10 KiB) through amdgpu_device_mm_access, the MM_INDEX / MM_DATA window the kext already reads
//     VRAM beyond BAR0 with (PhxBringup::mmIdxRead, b82). It gives the IP versions and register bases, the GC config
//     (SE, SA, CU, RB, TCC, GPRs, wave limits, caches), the UMC count and the MALL size.
//   - GC harvest registers, after the GFX bring-up (Linux reads them in gfx_v11_0_hw_init after the RLC autoload:
//     get_gb_addr_config, and gfx_v11_0_setup_rb / gfx_v11_0_get_tcc_info from gfx_v11_0_constants_init):
//     CC_GC_SA_UNIT_DISABLE / GC_USER_SA_UNIT_DISABLE, CC_RB_BACKEND_DISABLE / GC_USER_RB_BACKEND_DISABLE,
//     CGTS_TCC_DISABLE / CGTS_USER_TCC_DISABLE and GB_ADDR_CONFIG; NBIO's RCC_CONFIG_MEMSIZE and the revision strap
//     (soc21_common_early_init, nbio_v4_3_get_rev_id).
//   - PCI config space through the registry (device, revision; PCIe link capabilities as IOPCIFamily publishes them).
// What has no read-only source here (each value says so in PHXN_DEV_* flags; the fields hold Linux's documented values
// for this ASIC so RADV keeps working):
//   - the per-SA WGP masks: Linux selects each SE / SA with GRBM_GFX_INDEX (a register write) before reading
//     CC_GC_SHADER_ARRAY_CONFIG. Here every active SA has the discovery table's CUs (PHXN_DEV_CU_PER_SA_FULL);
//   - VRAM type and bus width: Linux reads the VBIOS's vram_info table; the kext has no VBIOS image (no ROM BAR enable,
//     no ROM_INDEX writes, no ACPI VFCT on macOS). Width: the UMC 8.10 channel layout (2 UMCs x 2 channels per UMC
//     node, 16-bit GDDR6 channels, umc_v8_10.h) over the discovery table's UMC count; type: GDDR6 for UMC 8.10
//     (PHXN_DEV_VRAM_FROM_UMC);
//   - clocks: Linux asks the SMU's DPM tables (firmware messages) -> PHXN_DEV_CLOCKS_DEFAULT;
//   - the timestamp clock: Linux reads the VBIOS's reference clock (100 MHz on Navi 31) -> the same flag;
//   - CP firmware versions: Linux reads the headers of the files it loads; the boot daemon loads them here ->
//     PHXN_DEV_FW_DEFAULT (the versions of the pinned linux-firmware files, tools/firmware/fw.lock).
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifndef KERNEL
#include <stdio.h>   // snprintf (the kernel has its own)
#endif

#include "PhxNativeABI.h"

namespace phxdev {

// discovery.h (Linux 6.8)
constexpr uint32_t kBinarySignature = 0x28211407u;
constexpr uint32_t kDiscoveryTableSignature = 0x53445049u;   // "IPDS"
constexpr uint32_t kGcTableId = 0x4347u;                     // "GC"
constexpr uint32_t kHarvestTableSignature = 0x56524148u;     // "HARV"
constexpr uint32_t kVcnInfoTableId = 0x004E4356u;            // "VCN"
constexpr uint32_t kMallInfoTableId = 0x4C4C414Du;           // "MALL"
enum : unsigned { kTabIpDiscovery = 0, kTabGc = 1, kTabHarvest = 2, kTabVcn = 3, kTabMall = 4, kTables = 6 };
// Sizes in bytes of discovery.h's packed structs
constexpr size_t kBinaryPrefixBytes = 12;   // binary_header up to its table list: signature, version, checksum, size
constexpr unsigned kIpHeaderBytes = 80;     // ip_discovery_header with die_info[16] and the v4 flags byte
constexpr unsigned kInfoHeaderBytes = 12;   // gpu_info_header / the VCN and MALL table headers: id, version, size
constexpr unsigned kHarvestEntries = 32;    // harvest_table: an 8-byte header, then 32 x {hw_id, instance, reserved}
constexpr unsigned kHarvestBytes = 8 + kHarvestEntries * 4;
// amdgpu_discovery.h
constexpr uint64_t kTmrOffset = 64u << 10;   // DISCOVERY_TMR_OFFSET: the table starts this far below the top of VRAM
constexpr uint32_t kTmrSize = 10u << 10;     // DISCOVERY_TMR_SIZE: what Linux reads
constexpr unsigned kHwIdMax = 300, kHwipMaxInstance = 44;   // amdgpu_discovery_validate_ip
// soc15_hw_ip.h (the ids the parser reads, and MMHUB / DMU for the host test's tables)
constexpr uint16_t kHwGc = 11, kHwVcn = 12, kHwMmhub = 34, kHwNbif = 108, kHwUmc = 150, kHwDmu = 271;

// Register offsets (dwords) on GC 11.0.0 / NBIO 4.3.0: Linux's gc_11_0_0_offset.h, nbio_4_3_0_offset.h, with the
// segment the offset belongs to. The absolute address is the discovery table's base for that segment plus the offset.
struct Reg { uint16_t hw; uint8_t seg; uint32_t off; };
constexpr Reg kGbAddrConfig{kHwGc, 0, 0x13de};
constexpr Reg kCcSaUnitDisable{kHwGc, 0, 0x0fe9};
constexpr Reg kUserSaUnitDisable{kHwGc, 1, 0x5b92};
constexpr Reg kCcRbBackendDisable{kHwGc, 0, 0x13dd};
constexpr Reg kUserRbBackendDisable{kHwGc, 1, 0x5b94};
constexpr Reg kCgtsTccDisable{kHwGc, 1, 0x5006};
constexpr Reg kCgtsUserTccDisable{kHwGc, 1, 0x5b96};
constexpr Reg kRccConfigMemsize{kHwNbif, 2, 0x00c3};
constexpr Reg kRccStrap0{kHwNbif, 2, 0x0016};   // regRCC_STRAP0_RCC_DEV0_EPF0_STRAP0: ATI_REV_ID in bits 27:24
// The same registers at the absolute dwords the rest of the kext uses for this ASIC (GC segments 0x1260 / 0xA000,
// NBIO segment 2 = 0xD20). The discovery bases must give exactly these, or no GC / NBIO register is read: a register
// read lands where it is known to land, never where a bad table points.
constexpr uint32_t kGcSeg0 = 0x1260, kGcSeg1 = 0xA000, kNbioSeg2 = 0xD20;
constexpr uint32_t kRccConfigMemsizeAbs = kNbioSeg2 + 0x00c3;   // 0xDE3, read before the table (the table's position)

// Linux's AMDGPU_FAMILY_* and AMDGPU_VRAM_TYPE_* (amdgpu_drm.h)
constexpr uint32_t kFamilyGc1100 = 145, kVramTypeGddr6 = 9;

enum Err : int32_t {
    kOk = 0,
    kErrShort = -1,        // fewer bytes than the header or a table needs
    kErrSignature = -2,    // binary signature
    kErrChecksum = -3,     // binary checksum
    kErrIpTable = -4,      // IP discovery table signature, checksum or layout
    kErrGcTable = -5,      // GC table id, checksum or version
    kErrHarvest = -6,      // harvest table signature or checksum
    kErrVcnTable = -7,     // VCN info table id or checksum
    kErrNoGc = -8,         // no GC IP entry
    kErrDie = -9,          // die id or count
};

// What the discovery table says (the parts the device info needs).
struct Discovery {
    int32_t err;
    uint16_t versionMajor, versionMinor, binarySize;
    uint8_t gcMajor, gcMinor, gcRev;
    uint8_t umcMajor, umcMinor, umcRev;
    uint8_t vcnMajor, vcnMinor, vcnRev;
    uint8_t vcnConfig;                  // VCN0 revision bits 7:6 (0b10 encode off, 0b01 decode off)
    uint32_t gcBase[4], nbioBase[4];    // instance 0, the first four segments
    uint32_t numUmc, umcHarvest;        // UMC entries, and UMCs the harvest table removes
    uint32_t vcnHarvest;                // VCN instances the harvest table removes
    // GC info (v1.x: Navi 3x; v2.x: the CU-per-SH layout)
    uint16_t gcInfoMajor, gcInfoMinor;
    uint32_t numSe, numSaPerSe, maxCuPerSa, numRbPerSe, numGl2c, numGprs, maxGsThreads, gsTableDepth, gsPrimBuffDepth,
        doubleOffchipLds, waveSize, maxWavesPerSimd, maxScratchSlotsPerCu, ldsSize, numScPerSa, numPackerPerSc;
    uint32_t tcpL1Kb, numSqcPerWgp, sqcInstKb, sqcDataKb, gl1cPerSa, gl1cKb, gl2cKb;   // v1.2 / v2.1 (0 when absent)
    uint32_t mallMajor, mallSizePerUmc, mallSPresent, mallHalfUse;   // MALL info (mallMajor 0 = none)
    uint64_t mallBytes;
};

inline uint16_t rd16(const uint8_t *b, size_t o) { return static_cast<uint16_t>(b[o] | (b[o + 1] << 8)); }
inline uint32_t rd32(const uint8_t *b, size_t o) {
    return static_cast<uint32_t>(b[o]) | (static_cast<uint32_t>(b[o + 1]) << 8) | (static_cast<uint32_t>(b[o + 2]) << 16) |
           (static_cast<uint32_t>(b[o + 3]) << 24);
}
// amdgpu_discovery_calculate_checksum: the byte sum, 16 bits
inline uint16_t checksum(const uint8_t *b, size_t n) {
    uint16_t s = 0;
    for (size_t i = 0; i < n; i++) s = static_cast<uint16_t>(s + b[i]);
    return s;
}
inline bool fits(size_t len, size_t off, size_t n) { return off <= len && n <= len - off; }

// The binary's own size from its first 12 bytes (0 = not a discovery binary): how much the kext reads after the header.
inline uint32_t binarySize(const uint8_t *b, size_t len) {
    if (!b || len < kBinaryPrefixBytes || rd32(b, 0) != kBinarySignature) return 0;
    return rd16(b, 10);
}

// Parses a discovery binary the way amdgpu_discovery_init / _reg_base_init / _get_gfx_info / _get_mall_info do, with
// every offset bounds-checked against len (the image comes from VRAM: a bad one gives an error, never a fault).
inline int32_t parse(const uint8_t *b, size_t len, Discovery *d) {
    *d = Discovery{};
    d->err = kErrShort;
    // binary_header: signature, version, checksum, size, then 6 x {offset, checksum, size, padding}
    constexpr size_t kHdr = kBinaryPrefixBytes + kTables * 8;
    if (!b || len < kHdr) return d->err;
    if (rd32(b, 0) != kBinarySignature) return d->err = kErrSignature;
    d->versionMajor = rd16(b, 4);
    d->versionMinor = rd16(b, 6);
    const uint16_t binSum = rd16(b, 8);
    d->binarySize = rd16(b, 10);
    if (d->binarySize < kHdr || d->binarySize > len) return d->err = kErrShort;
    if (checksum(b + 10, d->binarySize - 10u) != binSum) return d->err = kErrChecksum;
    auto tabOff = [&](unsigned t) { return rd16(b, 12 + t * 8); };
    auto tabSum = [&](unsigned t) { return rd16(b, 12 + t * 8 + 2); };
    const size_t n = d->binarySize;

    // IP discovery table: header (signature, version, size, id, num_dies, die_info[16] at 14, then the
    // v4 flags byte at 78: base_addr_64_bit) = 80 bytes (discovery.h is packed)
    const size_t ip = tabOff(kTabIpDiscovery);
    if (!ip || !fits(n, ip, kIpHeaderBytes)) return d->err = kErrIpTable;
    if (rd32(b, ip) != kDiscoveryTableSignature) return d->err = kErrIpTable;
    const uint16_t ipVersion = rd16(b, ip + 4), ipSize = rd16(b, ip + 6);
    if (!fits(n, ip, ipSize) || checksum(b + ip, ipSize) != tabSum(kTabIpDiscovery)) return d->err = kErrIpTable;
    const unsigned numDies = rd16(b, ip + 12);
    const bool base64 = ipVersion >= 4 && (b[ip + 78] & 1);
    if (!numDies || numDies > 16) return d->err = kErrDie;
    bool haveGc = false;
    for (unsigned die = 0; die < numDies; die++) {
        const size_t dieOff = rd16(b, ip + 14 + die * 4 + 2);
        if (!fits(n, dieOff, 4) || rd16(b, dieOff) != die) return d->err = kErrDie;
        const unsigned numIps = rd16(b, dieOff + 2);
        size_t p = dieOff + 4;
        for (unsigned j = 0; j < numIps; j++) {
            if (!fits(n, p, 8)) return d->err = kErrIpTable;
            const uint16_t hw = rd16(b, p);
            const uint8_t inst = b[p + 2], nb = b[p + 3], maj = b[p + 4], min = b[p + 5], rev = b[p + 6];
            const size_t step = 8u + static_cast<size_t>(nb) * (base64 ? 8u : 4u);
            if (!fits(n, p, step)) return d->err = kErrIpTable;
            if (inst < kHwipMaxInstance && hw < kHwIdMax) {   // amdgpu_discovery_validate_ip: skip the rest
                auto base = [&](unsigned k) {
                    return base64 ? rd32(b, p + 8 + k * 8) & 0x3FFFFFFFu : rd32(b, p + 8 + k * 4);
                };
                if (hw == kHwGc && inst == 0) {
                    haveGc = true;
                    d->gcMajor = maj; d->gcMinor = min; d->gcRev = rev;
                    for (unsigned k = 0; k < nb && k < 4; k++) d->gcBase[k] = base(k);
                }
                if (hw == kHwNbif && inst == 0)
                    for (unsigned k = 0; k < nb && k < 4; k++) d->nbioBase[k] = base(k);
                if (hw == kHwUmc) {
                    if (!d->numUmc) { d->umcMajor = maj; d->umcMinor = min; d->umcRev = rev; }
                    d->numUmc++;
                }
                if (hw == kHwVcn && inst == 0) {
                    d->vcnConfig = rev & 0xc0;
                    d->vcnMajor = maj; d->vcnMinor = min; d->vcnRev = static_cast<uint8_t>(rev & ~0xc0);
                }
            }
            p += step;
        }
    }
    if (!haveGc) return d->err = kErrNoGc;

    // Harvest table: UMC and VCN instances fused off
    if (const size_t h = tabOff(kTabHarvest)) {
        if (!fits(n, h, kHarvestBytes) || rd32(b, h) != kHarvestTableSignature || checksum(b + h, kHarvestBytes) != tabSum(kTabHarvest))
            return d->err = kErrHarvest;
        for (unsigned i = 0; i < kHarvestEntries; i++) {
            const uint16_t hw = rd16(b, h + 8 + i * 4);
            if (!hw) break;
            if (hw == kHwUmc) d->umcHarvest++;
            if (hw == kHwVcn) d->vcnHarvest++;
        }
        if (d->umcHarvest < d->numUmc) d->numUmc -= d->umcHarvest;
    }
    // VCN info: only its id and checksum (Linux checks both; the fuse bits are not needed here)
    if (const size_t v = tabOff(kTabVcn)) {
        if (!fits(n, v, kInfoHeaderBytes) || rd32(b, v) != kVcnInfoTableId) return d->err = kErrVcnTable;
        const uint32_t vs = rd32(b, v + 8);
        if (!fits(n, v, vs) || checksum(b + v, vs) != tabSum(kTabVcn)) return d->err = kErrVcnTable;
    }

    // GC info: gpu_info_header (id, major, minor, size) then the fields (amdgpu_discovery_get_gfx_info)
    const size_t g = tabOff(kTabGc);
    if (!g || !fits(n, g, kInfoHeaderBytes) || rd32(b, g) != kGcTableId) return d->err = kErrGcTable;
    const uint32_t gsize = rd32(b, g + 8);
    if (!fits(n, g, gsize) || checksum(b + g, gsize) != tabSum(kTabGc)) return d->err = kErrGcTable;
    d->gcInfoMajor = rd16(b, g + 4);
    d->gcInfoMinor = rd16(b, g + 6);
    // field i: the i-th dword after the header (0 when the table is too short to hold it)
    auto f = [&](unsigned i) -> uint32_t {
        return kInfoHeaderBytes + (i + 1) * 4 <= gsize ? rd32(b, g + kInfoHeaderBytes + i * 4) : 0;
    };
    if (d->gcInfoMajor == 1) {
        if (gsize < kInfoHeaderBytes + 19 * 4) return d->err = kErrGcTable;   // through field 18
        d->numSe = f(0);
        d->maxCuPerSa = 2 * (f(1) + f(2));   // 2 x (WGP0 + WGP1 per SA)
        d->numRbPerSe = f(3); d->numGl2c = f(4); d->numGprs = f(5); d->maxGsThreads = f(6);
        d->gsTableDepth = f(7); d->gsPrimBuffDepth = f(8); /* f(9) parameter cache depth */ d->doubleOffchipLds = f(10);
        d->waveSize = f(11); d->maxWavesPerSimd = f(12); d->maxScratchSlotsPerCu = f(13); d->ldsSize = f(14);
        d->numSaPerSe = f(16);
        d->numScPerSa = d->numSaPerSe ? f(15) / d->numSaPerSe : 0;
        d->numPackerPerSc = f(17);
        if (d->gcInfoMinor >= 2) {   // v1.2: 22 tcp_per_wpg, 23 tcp_l1_size ... 29 gl2c_per_gpu
            d->tcpL1Kb = f(23); d->numSqcPerWgp = f(24); d->sqcInstKb = f(25); d->sqcDataKb = f(26);
            d->gl1cPerSa = f(27); d->gl1cKb = f(28); d->gl2cKb = f(29);
        }
    } else if (d->gcInfoMajor == 2) {
        if (gsize < kInfoHeaderBytes + 17 * 4) return d->err = kErrGcTable;   // through field 16
        d->numSe = f(0); d->maxCuPerSa = f(1); d->numSaPerSe = f(2); d->numRbPerSe = f(3); d->numGl2c = f(4);
        d->numGprs = f(5); d->maxGsThreads = f(6); d->gsTableDepth = f(7); d->gsPrimBuffDepth = f(8);
        d->doubleOffchipLds = f(10); d->waveSize = f(11); d->maxWavesPerSimd = f(12); d->maxScratchSlotsPerCu = f(13);
        d->ldsSize = f(14);
        d->numScPerSa = d->numSaPerSe ? f(15) / d->numSaPerSe : 0;
        d->numPackerPerSc = f(16);
        if (d->gcInfoMinor == 1) {   // v2.1: 21 icache, 22 dcache per SQC (Linux sets no gc_tcp_l1_size from v2)
            d->sqcInstKb = f(21); d->sqcDataKb = f(22);
        }
    } else {
        return d->err = kErrGcTable;
    }
    if (!d->numSe || !d->numSaPerSe || !d->maxCuPerSa || d->numSe > 8 || d->numSaPerSe > 2 || d->maxCuPerSa > 32)
        return d->err = kErrGcTable;

    // MALL info (Linux does not check its checksum: amdgpu_discovery_init's "if (0 && offset)")
    if (const size_t m = tabOff(kTabMall)) {
        if (fits(n, m, kInfoHeaderBytes + 9 * 4) && rd32(b, m) == kMallInfoTableId) {
            d->mallMajor = rd16(b, m + 4);
            if (d->mallMajor == 1) {
                d->mallSizePerUmc = rd32(b, m + 12); d->mallSPresent = rd32(b, m + 16); d->mallHalfUse = rd32(b, m + 20);
                for (uint32_t u = 0; u < d->numUmc && u < 32; u++)
                    d->mallBytes += (d->mallSPresent & (1u << u)) ? 2ull * d->mallSizePerUmc
                                  : (d->mallHalfUse & (1u << u)) ? d->mallSizePerUmc / 2 : d->mallSizePerUmc;
            } else if (d->mallMajor == 2) {
                d->mallSizePerUmc = rd32(b, m + 12);
                d->mallBytes = static_cast<uint64_t>(d->mallSizePerUmc) * d->numUmc;
            }
        }
    }
    return d->err = kOk;
}

// The absolute dword of a register from the discovery bases, or 0 when the base does not match the known one.
inline uint32_t regAbs(const Discovery &d, const Reg &r) {
    const uint32_t *bases = r.hw == kHwGc ? d.gcBase : d.nbioBase;
    const uint32_t known = r.hw == kHwGc ? (r.seg == 0 ? kGcSeg0 : r.seg == 1 ? kGcSeg1 : 0) : (r.seg == 2 ? kNbioSeg2 : 0);
    if (r.seg >= 4 || !known || bases[r.seg] != known) return 0;
    return bases[r.seg] + r.off;
}
// The discovery says GC 11.0.0 at the bases the kext's register tables use: the only layout the reads are made on.
inline bool basesKnown(const Discovery &d) {
    return d.err == kOk && d.gcMajor == 11 && d.gcMinor == 0 && d.gcRev == 0 && d.gcBase[0] == kGcSeg0 &&
           d.gcBase[1] == kGcSeg1 && d.nbioBase[2] == kNbioSeg2;
}

// The GC registers, read once the GFX block is up (raw values; 0 when not read).
struct GcRegs {
    bool read;
    uint32_t gbAddrConfig, ccSaDisable, userSaDisable, ccRbDisable, userRbDisable, tccDisable, userTccDisable;
};
// The early NBIO / PCI side, read at start.
struct Early {
    uint32_t vramMb;        // RCC_CONFIG_MEMSIZE
    uint32_t revStrap;      // RCC_STRAP0 (ATI_REV_ID in 27:24)
    uint16_t deviceId;
    uint8_t pciRev;
    uint32_t linkCap;       // PCIe Link Capabilities (max speed 3:0, max width 9:4) of the GPU
    uint32_t partnerLinkCap;   // the same of the first non-AMD port above it (Linux's partner); 0 = unknown
};

inline uint32_t bitmask(uint32_t bits) { return bits >= 32 ? 0xffffffffu : (1u << bits) - 1u; }
inline uint32_t popcount(uint64_t v) { uint32_t n = 0; for (; v; v &= v - 1) n++; return n; }

// The defaults of what no read-only path gives (see the header). Linux's values for an RX 7900 XTX: Mesa's navi31
// entry (amdgpu_devices.c, a Linux dump of an XTX) for the clocks and the timestamp clock; the CP firmware versions
// of the pinned linux-firmware files (tools/firmware/fw.lock: gc_11_0_0_me/pfp/mec.bin header ucode_version, feature 29).
constexpr uint32_t kDefGpuCounterKhz = 100000;
constexpr uint32_t kDefMaxSclkKhz = 2371000, kDefMinSclkKhz = 500000, kDefMaxMclkKhz = 1249000, kDefMinMclkKhz = 96000;
constexpr uint32_t kDefFwMe = 2420, kDefFwPfp = 2580, kDefFwMec = 2650, kDefFwFeature = 29;

// Linux's amdgpu_kms.c AMDGPU_INFO_DEV_INFO answer, from the parsed table, the early reads and the GC registers.
// Returns false (and leaves PHXN_DEV_VALID clear) when the table did not parse.
inline bool build(const Discovery &d, const Early &e, const GcRegs &r, phxn_devinfo *o, const char *marketingName) {
    *o = phxn_devinfo{};
    o->version = PHXN_DEVINFO_VERSION;
    o->size = sizeof(phxn_devinfo);
    o->discovery_err = d.err;
    o->device_id = e.deviceId;
    o->pci_rev = e.pciRev;
    if (marketingName)
        for (unsigned i = 0; i + 1 < sizeof o->name && marketingName[i]; i++) o->name[i] = marketingName[i];
    o->vram_mb = e.vramMb;
    if (d.err != kOk) return false;

    uint32_t fl = PHXN_DEV_VALID;
    o->discovery_version = static_cast<uint32_t>(d.versionMajor) << 16 | d.versionMinor;
    o->gc_ip = static_cast<uint32_t>(d.gcMajor) << 16 | static_cast<uint32_t>(d.gcMinor) << 8 | d.gcRev;
    o->vcn_ip = static_cast<uint32_t>(d.vcnMajor) << 16 | static_cast<uint32_t>(d.vcnMinor) << 8 | d.vcnRev;
    o->vcn_config = d.vcnConfig;
    o->umc_ip = static_cast<uint32_t>(d.umcMajor) << 16 | static_cast<uint32_t>(d.umcMinor) << 8 | d.umcRev;
    o->num_umc = d.numUmc;
    o->family = (d.gcMajor == 11 && d.gcMinor == 0) ? kFamilyGc1100 : 0;
    // soc21_common_early_init: GC 11.0.0's external revision is the strap's revision + 1
    o->chip_rev = (e.revStrap >> 24) & 0xf;
    o->external_rev = o->chip_rev + 1;
    o->num_se = d.numSe;
    o->num_sa_per_se = d.numSaPerSe;
    o->num_cu_per_sa = d.maxCuPerSa;
    o->num_rb_pipes = d.numRbPerSe * d.numSe;
    o->num_tcc_blocks = d.numGl2c;
    o->num_gprs = d.numGprs;
    o->max_gs_waves_per_vgt = d.maxGsThreads;
    o->gs_vgt_table_depth = d.gsTableDepth;
    o->gs_prim_buffer_depth = d.gsPrimBuffDepth;
    o->double_offchip_lds = d.doubleOffchipLds;
    o->wave_size = d.waveSize;
    o->max_waves_per_simd = d.maxWavesPerSimd;
    o->max_scratch_slots_per_cu = d.maxScratchSlotsPerCu;
    o->lds_size = d.ldsSize;
    o->num_sc_per_sa = d.numScPerSa;
    o->num_packer_per_sc = d.numPackerPerSc;
    o->tcp_cache_kb = d.tcpL1Kb;
    o->num_sqc_per_wgp = d.numSqcPerWgp;
    o->sqc_inst_cache_kb = d.sqcInstKb;
    o->sqc_data_cache_kb = d.sqcDataKb;
    o->gl1c_cache_kb = d.gl1cKb * d.gl1cPerSa;   // amdgpu_kms.c: size per instance x per SA
    o->gl2c_cache_kb = d.gl2cKb;
    o->mall_size = d.mallBytes;
    o->num_hw_gfx_contexts = 8;   // gfx_v11_0_gpu_early_init (GC 11.0.0): a driver constant, not a hardware value

    // SA, RB, TCC masks: gfx_v11_0_get_sa_active_bitmap, _get_rb_active_bitmap, _setup_rb, _get_tcc_info
    const uint32_t maxSa = d.numSe * d.numSaPerSe;
    uint32_t saActive = bitmask(maxSa);
    if (r.read) {
        fl |= PHXN_DEV_GC_REGS;
        o->gb_addr_config = r.gbAddrConfig;
        const uint32_t saOff = ((r.ccSaDisable >> 8) & 0xffff) | ((r.userSaDisable >> 8) & 0xffff);
        saActive &= ~saOff;
        const uint32_t rbOff = (r.ccRbDisable >> 4) | (r.userRbDisable >> 4);
        const uint32_t rbGlobal = bitmask(d.numRbPerSe * d.numSe) & ~rbOff;
        const uint32_t rbPerSa = d.numSaPerSe ? d.numRbPerSe / d.numSaPerSe : 0;
        uint32_t rb = 0;
        for (uint32_t i = 0; i < maxSa && i * rbPerSa < 31; i++)
            if (saActive & (1u << i)) rb |= 0x3u << (i * rbPerSa);   // Linux's 0x3 (two RBs per SA on GC 11)
        rb |= rbGlobal;   // Linux 6.8 ORs the global mask in
        o->enabled_rb_pipes_mask = rb;
        const uint32_t tcc = r.tccDisable | r.userTccDisable;
        o->tcc_disabled_mask = ((tcc >> 16) & 0xffff) | (((tcc >> 8) & 0xff) << 16);
    } else {
        o->enabled_rb_pipes_mask = bitmask(o->num_rb_pipes);
    }
    o->sa_active_mask = saActive;
    // CU masks: every active SA has the table's CUs (the per-SA WGP read needs a GRBM_GFX_INDEX select). Linux's
    // layout of the 4 x 4 bitmap: SE0-3 in rows 0-3, columns 0-1; SE4-7 in rows 0-3, columns 2-3.
    fl |= PHXN_DEV_CU_PER_SA_FULL;
    uint32_t cus = 0;
    for (uint32_t se = 0; se < d.numSe; se++)
        for (uint32_t sa = 0; sa < d.numSaPerSe; sa++)
            if (saActive & (1u << (se * d.numSaPerSe + sa))) {
                o->cu_bitmap[se % 4][sa + (se / 4) * 2] = bitmask(d.maxCuPerSa);
                cus += d.maxCuPerSa;
            }
    o->cu_active_number = cus;

    // VRAM: Linux's vram_info (VBIOS) is not reachable; UMC 8.10: 2 UMCs x 2 channels per node, 16-bit GDDR6 channels
    // (a half-use mask with more bits than the UMCs have channels gives no width: a malformed table, not a wrap)
    const uint32_t allChannels = 2 * 2 * d.numUmc, halfChannels = popcount(d.mallHalfUse) * 2;
    if (d.umcMajor == 8 && d.umcMinor == 10 && d.numUmc && halfChannels < allChannels) {
        fl |= PHXN_DEV_VRAM_FROM_UMC;
        o->vram_type = kVramTypeGddr6;
        o->vram_bit_width = (allChannels - halfChannels) * 16;
    }
    // PCIe: the GPU's own link capabilities and its partner's (amdgpu_device_partner_bandwidth), the lower of each
    const uint32_t cap = e.linkCap, pcap = e.partnerLinkCap ? e.partnerLinkCap : e.linkCap;
    const uint32_t gen = cap & 0xf, pgen = pcap & 0xf, w = (cap >> 4) & 0x3f, pw = (pcap >> 4) & 0x3f;
    o->pcie_gen = gen < pgen ? gen : pgen;
    o->pcie_num_lanes = w < pw ? w : pw;

    fl |= PHXN_DEV_CLOCKS_DEFAULT | PHXN_DEV_FW_DEFAULT;
    o->gpu_counter_khz = kDefGpuCounterKhz;
    o->max_engine_khz = kDefMaxSclkKhz;
    o->min_engine_khz = kDefMinSclkKhz;
    o->max_memory_khz = kDefMaxMclkKhz;
    o->min_memory_khz = kDefMinMclkKhz;
    o->fw_me = kDefFwMe;
    o->fw_pfp = kDefFwPfp;
    o->fw_mec = kDefFwMec;
    o->fw_me_feature = o->fw_pfp_feature = o->fw_mec_feature = kDefFwFeature;
    o->flags = fl;
    return true;
}

// The record as text (debug.phxdevinfo); returns the length written (< n), always NUL-terminated.
inline size_t format(const phxn_devinfo &d, char *b, size_t n) {
    if (!n) return 0;
    size_t o = 0;
    auto put = [&](int r) { if (r > 0) o += static_cast<size_t>(r); if (o >= n) o = n - 1; };
    auto ip = [](uint32_t v, unsigned s) { return (v >> s) & 0xff; };
    put(snprintf(b + o, n - o, "devinfo v%u flags 0x%x%s%s%s%s%s%s discovery %d (table v%u.%u)\n", d.version, d.flags,
                 (d.flags & PHXN_DEV_VALID) ? " valid" : " INVALID", (d.flags & PHXN_DEV_GC_REGS) ? " gc-regs" : " no-gc-regs",
                 (d.flags & PHXN_DEV_CU_PER_SA_FULL) ? " cu-per-sa-full" : "", (d.flags & PHXN_DEV_VRAM_FROM_UMC) ? " vram-from-umc" : "",
                 (d.flags & PHXN_DEV_CLOCKS_DEFAULT) ? " clocks-default" : "", (d.flags & PHXN_DEV_FW_DEFAULT) ? " fw-default" : "",
                 d.discovery_err, d.discovery_version >> 16, d.discovery_version & 0xffff));
    put(snprintf(b + o, n - o, "name \"%s\" 1002:%04x rev %02x chip_rev %u external_rev %u family %u\n", d.name, d.device_id,
                 d.pci_rev, d.chip_rev, d.external_rev, d.family));
    put(snprintf(b + o, n - o, "ip GC %u.%u.%u VCN %u.%u.%u (config 0x%x) UMC %u.%u.%u x%u\n", ip(d.gc_ip, 16), ip(d.gc_ip, 8),
                 ip(d.gc_ip, 0), ip(d.vcn_ip, 16), ip(d.vcn_ip, 8), ip(d.vcn_ip, 0), d.vcn_config, ip(d.umc_ip, 16), ip(d.umc_ip, 8),
                 ip(d.umc_ip, 0), d.num_umc));
    put(snprintf(b + o, n - o, "gc %u SE x %u SA x %u CU, %u active (SA mask 0x%x), RB %u mask 0x%llx, TCC %u disabled 0x%llx, "
                 "GB_ADDR_CONFIG 0x%08x\n", d.num_se, d.num_sa_per_se, d.num_cu_per_sa, d.cu_active_number, d.sa_active_mask,
                 d.num_rb_pipes, static_cast<unsigned long long>(d.enabled_rb_pipes_mask), d.num_tcc_blocks,
                 static_cast<unsigned long long>(d.tcc_disabled_mask), d.gb_addr_config));
    put(snprintf(b + o, n - o, "gc vgprs %u gs waves %u vgt depth %u prim depth %u double lds %u wave %u waves/simd %u "
                 "scratch %u lds %u sc/sa %u packer/sc %u hw contexts %u\n", d.num_gprs, d.max_gs_waves_per_vgt,
                 d.gs_vgt_table_depth, d.gs_prim_buffer_depth, d.double_offchip_lds, d.wave_size, d.max_waves_per_simd,
                 d.max_scratch_slots_per_cu, d.lds_size, d.num_sc_per_sa, d.num_packer_per_sc, d.num_hw_gfx_contexts));
    put(snprintf(b + o, n - o, "cache KiB tcp %u sqc %u inst %u data %u gl1c %u gl2c %u, MALL %llu MiB\n", d.tcp_cache_kb,
                 d.num_sqc_per_wgp, d.sqc_inst_cache_kb, d.sqc_data_cache_kb, d.gl1c_cache_kb, d.gl2c_cache_kb,
                 static_cast<unsigned long long>(d.mall_size >> 20)));
    put(snprintf(b + o, n - o, "vram %u MiB type %u %u-bit, PCIe gen %u x%u\n", d.vram_mb, d.vram_type, d.vram_bit_width,
                 d.pcie_gen, d.pcie_num_lanes));
    put(snprintf(b + o, n - o, "defaults sclk %llu-%llu kHz mclk %llu-%llu kHz counter %u kHz; CP fw me %u pfp %u mec %u "
                 "(feature %u)\n", static_cast<unsigned long long>(d.min_engine_khz), static_cast<unsigned long long>(d.max_engine_khz),
                 static_cast<unsigned long long>(d.min_memory_khz), static_cast<unsigned long long>(d.max_memory_khz),
                 d.gpu_counter_khz, d.fw_me, d.fw_pfp, d.fw_mec, d.fw_me_feature));
    for (unsigned r = 0; r < 4; r++)
        put(snprintf(b + o, n - o, "cu_bitmap[%u] 0x%x 0x%x 0x%x 0x%x\n", r, d.cu_bitmap[r][0], d.cu_bitmap[r][1],
                     d.cu_bitmap[r][2], d.cu_bitmap[r][3]));
    b[o] = 0;
    return o;
}

}  // namespace phxdev
