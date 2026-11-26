// SPDX-License-Identifier: MIT
// phx_devinfo.cpp (b168, plan A4 / A19): the device info from the hardware (PhxDevInfo.h), the VRAM budgets sized
// from the VRAM the hardware reports, and the GPU busy sampler behind the "phxGpuStats" platform function
// (PhxGpuStats.h) that VermilionAccel's PerformanceStatistics read.
// Part of the PhxBringup.cpp translation unit (included there, in order); not compiled on its own.
//
// Every access here is a read: the discovery table through the MM_INDEX / MM_DATA window Linux reads it through
// (mmIdxRead, under gMmIdxLock, inside the VRAM size), NBIO and GC registers Linux reads at probe and at GFX init
// (each at the absolute dword the discovery table's base gives, and only when that base is the one this ASIC has),
// fence words in VRAM through BAR0, and the registry.

// The PCIe Link Capabilities dword IOPCIFamily publishes on a PCI device (max speed 3:0, max width 9:4); 0 = none.
static uint32_t phxLinkCap(IORegistryEntry *e) {
    const OSNumber *n = e ? OSDynamicCast(OSNumber, e->getProperty("IOPCIExpressLinkCapabilities")) : nullptr;
    return n ? n->unsigned32BitValue() : 0;
}
static uint32_t phxRegVendor(IORegistryEntry *e) {
    const OSData *d = e ? OSDynamicCast(OSData, e->getProperty("vendor-id")) : nullptr;
    if (!d || d->getLength() < 2) return 0;
    const uint8_t *b = static_cast<const uint8_t *>(d->getBytesNoCopy());
    return static_cast<uint32_t>(b[0] | (b[1] << 8));
}
// Linux's amdgpu_device_partner_bandwidth: the first bridge above the GPU that is not one of the card's own (ATI)
// switch ports.
static uint32_t phxPartnerLinkCap(IOPCIDevice *gpu) {
    IORegistryEntry *e = gpu;
    for (int depth = 0; depth < 16 && e; depth++) {
        e = e->getParentEntry(gIOServicePlane);
        IOPCIDevice *p = OSDynamicCast(IOPCIDevice, e);
        if (!p) continue;
        if (phxRegVendor(p) == phxgpu::kVendorAmd) continue;
        return phxLinkCap(p);
    }
    return 0;
}

void PhxBringup::devInfoEarly() {
    devEarly = phxdev::Early{};
    devDisc = phxdev::Discovery{};
    devDisc.err = phxdev::kErrShort;
    devGc = phxdev::GcRegs{};
    if (!pci) return;
    devEarly.deviceId = pci->configRead16(phxgpu::kCfgDevice);
    devEarly.pciRev = pci->configRead8(phxgpu::kCfgRevision);
    devEarly.linkCap = phxLinkCap(pci);
    devEarly.partnerLinkCap = phxPartnerLinkCap(pci);
    if (!mmio) return;
    if (!gMmIdxLock) gMmIdxLock = IOSimpleLockAlloc();   // mmIdxRead refuses without it (newUserClient makes it otherwise)
    // amdgpu_discovery_read_binary_from_mem: (RCC_CONFIG_MEMSIZE << 20) - DISCOVERY_TMR_OFFSET, DISCOVERY_TMR_SIZE bytes
    devEarly.vramMb = rreg(phxdev::kRccConfigMemsizeAbs);
    const uint64_t vram = static_cast<uint64_t>(devEarly.vramMb) << 20;
    if (!gMmIdxLock || vram < phxdev::kTmrOffset || vram > fbSize || !fbSize) {
        devDisc.err = phxdev::kErrShort;
        IOLog("PhxBringup: device info: RCC_CONFIG_MEMSIZE %u MiB, VRAM %llu MiB: no discovery read\n", devEarly.vramMb,
              static_cast<unsigned long long>(fbSize >> 20));
        return;
    }
    const uint64_t pos = vram - phxdev::kTmrOffset;
    uint8_t *bin = static_cast<uint8_t *>(IOMallocZero(phxdev::kTmrSize));
    if (!bin) return;
    uint32_t got = 0;
    for (uint32_t i = 0; i < 12; i += 4, got += 4) {   // the header first: signature and size say how much follows
        const uint32_t v = mmIdxRead(pos + i);
        memcpy(bin + i, &v, 4);
    }
    const uint32_t want = phxdev::binarySize(bin, got);
    if (want && want <= phxdev::kTmrSize)
        for (; got < want; got += 4) {
            const uint32_t v = mmIdxRead(pos + got);
            memcpy(bin + got, &v, 4);
        }
    phxdev::parse(bin, got, &devDisc);
    IOFree(bin, phxdev::kTmrSize);
    // The NBIO revision strap, at the base the table gives (only the known one: phxdev::regAbs)
    if (const uint32_t r = phxdev::regAbs(devDisc, phxdev::kRccStrap0))
        devEarly.revStrap = rreg(r);
    IOLog("PhxBringup: device info: discovery %s (%d), %u bytes at VRAM +0x%llx; GC %u.%u.%u, %u SE x %u SA x %u CU, "
          "%u UMC, MALL %llu MiB\n", devDisc.err ? "FAILED" : "ok", devDisc.err, got, static_cast<unsigned long long>(pos),
          devDisc.gcMajor, devDisc.gcMinor, devDisc.gcRev, devDisc.numSe, devDisc.numSaPerSe, devDisc.maxCuPerSa,
          devDisc.numUmc, static_cast<unsigned long long>(devDisc.mallBytes >> 20));
}

// The GC harvest registers and GB_ADDR_CONFIG, once the GFX block is up (gfx_v11_0_gpu_early_init / _setup_rb /
// _get_tcc_info read them; none needs an SE / SA select). Only on the layout the discovery table confirmed.
void PhxBringup::devInfoGc() {
    if (devGc.read || !mmio || !gpuReady() || !phxdev::basesKnown(devDisc)) return;
    phxdev::GcRegs g{};
    g.gbAddrConfig = rreg(phxdev::regAbs(devDisc, phxdev::kGbAddrConfig));
    g.ccSaDisable = rreg(phxdev::regAbs(devDisc, phxdev::kCcSaUnitDisable));
    g.userSaDisable = rreg(phxdev::regAbs(devDisc, phxdev::kUserSaUnitDisable));
    g.ccRbDisable = rreg(phxdev::regAbs(devDisc, phxdev::kCcRbBackendDisable));
    g.userRbDisable = rreg(phxdev::regAbs(devDisc, phxdev::kUserRbBackendDisable));
    g.tccDisable = rreg(phxdev::regAbs(devDisc, phxdev::kCgtsTccDisable));
    g.userTccDisable = rreg(phxdev::regAbs(devDisc, phxdev::kCgtsUserTccDisable));
    if (g.gbAddrConfig == 0xffffffffu || g.ccSaDisable == 0xffffffffu) return;   // not powered: try again later
    g.read = true;
    devGc = g;
    IOLog("PhxBringup: device info: GB_ADDR_CONFIG 0x%08x, SA disable 0x%08x/0x%08x, RB disable 0x%08x/0x%08x, "
          "TCC disable 0x%08x/0x%08x\n", g.gbAddrConfig, g.ccSaDisable, g.userSaDisable, g.ccRbDisable, g.userRbDisable,
          g.tccDisable, g.userTccDisable);
}

void PhxBringup::devInfo(phxn_devinfo *out) {
    devInfoGc();
    const phxgpu::Board b = phxgpu::classify(phxgpu::kVendorAmd, devEarly.deviceId, devEarly.pciRev);
    phxdev::build(devDisc, devEarly, devGc, out, phxgpu::marketingName(b));
}

// GB_ADDR_CONFIG and the GC version for phxn_info (ABI 1.0): the hardware's once known, else this ASIC's (the values
// Linux reads on Navi 31; RADV checks them against its own).
uint32_t PhxBringup::devGbAddrConfig() {
    devInfoGc();
    return devGc.read ? devGc.gbAddrConfig : kGbAddrConfig;
}
uint32_t PhxBringup::devGcVersion() const {
    return devDisc.err == phxdev::kOk ? (static_cast<uint32_t>(devDisc.gcMajor) << 16 | static_cast<uint32_t>(devDisc.gcMinor) << 8 | devDisc.gcRev)
                                      : kGcVersion;
}

// The device-local memory RADV is offered (visible + hi), from the VRAM size the memory controller reports (the
// "VRAM,totalMB" readFbLayout publishes): the VRAM between the kext's fixed regions (below PHX_VRAM_POOL_BASE) and its
// top reserve (kVramTopReserve: the firmware's TMR and the discovery table). Before b168 the hi pool was a fixed 6 GiB.
uint64_t PhxBringup::vramDevTotal() const {
    const uint64_t fixed = static_cast<uint64_t>(PHX_VRAM_POOL_BASE) + kVramTopReserve;
    return fbSize > fixed + kVisTotal + (1024ull << 20) ? fbSize - fixed : kVisTotal + kHiTotal;
}
uint64_t PhxBringup::vramHiTotal() const { return vramDevTotal() - kVisTotal; }
// The hi pool is system memory unless a process is opted into real VRAM (debug.phxbo_vram_proc): all clients together
// may hold at most half the RAM in it, the limit Linux's TTM puts on system pages (ttm_tt page limit).
uint64_t PhxBringup::hiSysCap() const { return max_mem / 2; }

// ---- the busy sampler (PhxGpuStats.h) ---------------------------------------------------------------------------------
static int gGpuBusyUs = static_cast<int>(phxbusy::kDefPeriodUs);
static int phxGpuBusySysctl SYSCTL_HANDLER_ARGS {
    (void)oidp; (void)arg1; (void)arg2;
    int v = gGpuBusyUs;
    const int e = sysctl_handle_int(oidp, &v, 0, req);
    if (e || !req->newptr) return e;
    if (v != 0 && (v < 500 || v > 100000)) return EINVAL;
    gGpuBusyUs = v;
    return 0;
}
SYSCTL_PROC(_debug, OID_AUTO, phxgpu_busy_us, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_LOCKED, nullptr, 0, phxGpuBusySysctl, "I",
            "b168: GPU busy sampling period in us while the GPU has work (500..100000, default 2000), 0 = off (utilization 0)");

static uint64_t phxAbsNs(uint64_t abs) {
    uint64_t ns = 0;
    absolutetime_to_nanoseconds(abs, &ns);
    return ns;
}

// Whether the GFX or compute queue holds a submission the GPU has not fenced yet. Lock-free, as gpuRetiredMask: an
// entry is written before tail moves past it.
bool PhxBringup::busyNow() const {
    if (!fbAper) return false;
    for (uint32_t qi = 0; qi < 2; qi++) {
        const GpuQueue &q = gq[qi];
        if (!q.ready || q.vcn) continue;
        const uint32_t tail = q.tail;
        if (tail != q.head && q.fseq[(tail - 1) & 63] > queueFence(q)) return true;
    }
    return false;
}

static void phxBusyTick(thread_call_param_t p0, thread_call_param_t) { static_cast<PhxBringup *>(p0)->busyTick(); }

// gpuSubmit, under gpuLock, after the entry is queued: note the time and start sampling if it is off.
void PhxBringup::busyKick() {
    const uint64_t now = mach_absolute_time();
    busySampler.lastSubmitNs = phxAbsNs(now);
    if (!busyCall || busyStopping || gGpuBusyUs <= 0) return;
    if (!OSCompareAndSwap(0, 1, &busyArmed)) return;
    busySampler.start(busySampler.lastSubmitNs);
    uint64_t period = 0;
    nanoseconds_to_absolutetime(static_cast<uint64_t>(gGpuBusyUs) * 1000, &period);
    busyNextAbs = now + period;
    thread_call_enter_delayed(busyCall, busyNextAbs);
}

void PhxBringup::busyTick() {
    const int us = gGpuBusyUs;
    const uint64_t now = mach_absolute_time();
    if (busyStopping || us <= 0) { busyArmed = 0; return; }
    const bool more = busySampler.tick(busyNow(), phxAbsNs(now), static_cast<uint64_t>(us) * 1000);
    uint64_t period = 0;
    nanoseconds_to_absolutetime(static_cast<uint64_t>(us) * 1000, &period);
    if (more) {
        busyNextAbs += period;   // a fixed rate, so the samples fall at any phase of the frames
        if (busyNextAbs <= now) busyNextAbs = now + period;
        thread_call_enter_delayed(busyCall, busyNextAbs);
        return;
    }
    busyArmed = 0;
    __asm__ __volatile__("mfence" ::: "memory");
    // a submission between the idle sample and the disarm found the sampler still armed: pick it up here
    if (phxAbsNs(now) < busySampler.lastSubmitNs + phxbusy::kIdleStopNs && OSCompareAndSwap(0, 1, &busyArmed)) {
        busyNextAbs = now + period;
        thread_call_enter_delayed(busyCall, busyNextAbs);
    }
}

void PhxBringup::busyStop() {
    busyStopping = 1;
    if (busyCall) {
        thread_call_cancel_wait(busyCall);
        thread_call_free(busyCall);
        busyCall = nullptr;
    }
}

void PhxBringup::gpuStats(phx_gpu_stats *s) {
    s->version = PHX_GPU_STATS_VERSION;
    s->size = sizeof(*s);
    s->now_ns = phxAbsNs(mach_absolute_time());
    s->busy_ns = busySampler.busyNs;
    s->samples = busySampler.samples;
    s->busy_samples = busySampler.busySamples;
    s->vram_total = vramDevTotal();
    const SInt64 used = gBoBytes[0] + gBoBytes[1];
    s->vram_used = used > 0 ? static_cast<uint64_t>(used) : 0;
}

// debug.phxdevinfo: the device info as RADV receives it, and where each group of values came from
static int phxDevInfoSysctl SYSCTL_HANDLER_ARGS {
    (void)oidp; (void)arg1; (void)arg2;
    if (req->newptr) return EPERM;
    if (!gPhx) return ENXIO;
    static constexpr size_t kN = 2048;
    char *b = static_cast<char *>(IOMallocZero(kN));
    phxn_devinfo *d = static_cast<phxn_devinfo *>(IOMallocZero(sizeof(phxn_devinfo)));
    int e = ENOMEM;
    if (b && d) {
        gPhx->devInfo(d);
        size_t len = phxdev::format(*d, b, kN);
        e = SYSCTL_OUT(req, b, len + 1);
    }
    if (b) IOFree(b, kN);
    if (d) IOFree(d, sizeof(phxn_devinfo));
    return e;
}
SYSCTL_PROC(_debug, OID_AUTO, phxdevinfo, CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_LOCKED, nullptr, 0, phxDevInfoSysctl, "A",
            "b168: the device info RADV receives (ABI 1.13): the IP discovery table, the GC harvest registers, and the flagged defaults");
