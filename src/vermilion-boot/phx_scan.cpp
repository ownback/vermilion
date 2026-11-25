// SPDX-License-Identifier: MIT
// phx_scan.cpp: scanout (selectors 9..14, service side): VRAM slot mapping, HUBP0 flips, poll/watchdog, acquire/
// present/status/release.
// Part of the PhxBringup.cpp translation unit (included there, in order); not compiled on its own.

// A client's mapping of VRAM (a scanout slot) instead of system pages: local PTEs, as Linux writes them for VRAM
// (amdgpu_vm: address = VRAM offset + vram_base_offset, here fbPhys) with VALID|EXEC|READ|WRITE and no SYSTEM/SNOOPED.
IOReturn PhxBringup::vmMapVram(uint32_t handle, uint64_t va, uint64_t vramOff, uint64_t size) {
    if (!vmCtx(handle))
        return kIOReturnNotReady;
    VmCtx &c = vm[handle - 1];
    IOReturn r = kIOReturnSuccess;
    IOLockLock(gpuLock);
    PhxVmEnv e = vmEnv();   // b53 walk + b48 undo, phxvm::map (b77)
    bool noPage = false;
    const uint64_t base = fbPhys + vramOff;
    if (phxvm::map(e, c, va, size, [&](uint64_t p) -> uint64_t { return ((base + p) & kPtAddrMask) | 0x71ull; }, &noPage) < size) {
        r = kIOReturnNoMemory;
        OSIncrementAtomic(&gVmMapFails);
    }
    if (c.hw)
        vmFlushTlb(c.hw);
    IOLockUnlock(gpuLock);
    return r;
}

// ---- scanout (selectors 9..14) ----------------------------------------------------------------------------------
// The display pipe copies each WindowServer frame on the CPU, and that copy could read a frame the GPU was still
// drawing (the family's wait for the plane surface's last GPU write never fires on our stack, RE'd 2026-10-25).
// Cobalt64 instead has the frame copied on the GPU, at the end of the command buffer that drew it, into a VRAM slot,
// and flips HUBP0 to that slot once the GPU is done. These are its selectors, with its structs, so RADV's
// radv_darwin_scanout_* work unchanged. Slots live at fixed VRAM offsets, small or large by the plane's frame size
// (PhxScanLayout.h, b126; small = PHXN_SCAN_SLOT_VRAM as before); a client's BO is rebound onto one (its PTEs point at
// the slot's VRAM). The console surface A (VRAM 0) keeps receiving the display
// pipe's copies (debug.phxfb_flip must be 0 for Acquire), so a restore is a flip back to A. HUBP0 registers are
// absolute dwords (DCN 3.2 segment 0x34c0 + dcn_3_2_0_offset.h), the flip sequence is Linux's hubp3 one.
uint64_t PhxBringup::scanFrameLocked() {
    const uint32_t f = rreg(kOtg0StatusFrameCount) & 0xffffff;
    scan.frameExt += (f - scan.frameLast) & 0xffffff;
    scan.frameLast = f;
    return scan.frameExt;
}

void PhxBringup::scanFlipLocked(uint64_t mc, bool immediate) {
    const uint32_t fc = rreg(kHubpreq0FlipControl);
    wreg(kHubpreq0FlipControl, immediate ? (fc | 2u) : (fc & ~2u));
    wreg(kHubpreq0PrimaryAddrHigh, static_cast<uint32_t>(mc >> 32) & 0xffff);
    wreg(kHubpreq0PrimaryAddr, static_cast<uint32_t>(mc));   // the low half arms the latch
    if (gP0OdmActive) {   // b131: ODM 2:1, HUBP1 scans the right half of the same surface (HUBPREQ1 = HUBPREQ0 + 0xDC)
        const uint32_t fc1 = rreg(kHubpreq0FlipControl + 0xDC);
        wreg(kHubpreq0FlipControl + 0xDC, immediate ? (fc1 | 2u) : (fc1 & ~2u));
        wreg(kHubpreq0PrimaryAddrHigh + 0xDC, static_cast<uint32_t>(mc >> 32) & 0xffff);
        wreg(kHubpreq0PrimaryAddr + 0xDC, static_cast<uint32_t>(mc));
    }
}

void PhxBringup::scanPollLocked() {
    if (scan.pending == PHXN_SCAN_NO_SLOT)
        return;
    if (rreg(kHubpreq0FlipControl) & 0x100)
        return;
    if (scanEarliest() != scan.slotMc[scan.pending]) {   // b74: FLIP_PENDING cleared, EARLIEST_INUSE not there yet
        OSIncrementAtomic64(&gScanEarliestLag);
        if (!gScanLatchFix)
            return;
    }
    const uint32_t k = scan.pending;
    gScanGhost = 0xffffffffu;
    scan.front = k;
    scan.pending = PHXN_SCAN_NO_SLOT;
    scan.latched++;
    scan.slotLatches[k]++;
    scan.slotLatchedFrame[k] = scanFrameLocked();
    uint64_t ns; absolutetime_to_nanoseconds(mach_absolute_time(), &ns);
    if (!scan.firstLatchNs) scan.firstLatchNs = ns;
    scan.lastLatchNs = ns;
}

// Back to the console surface A. true once HUBP0 is scanning it.
bool PhxBringup::scanRestoreLocked() {
    if (!scan.acquired)
        return true;
    scanFlipLocked(scan.consoleMc, false);
    bool ok = false;
    for (int i = 0; i < 500 && !ok; i++) {
        ok = !(rreg(kHubpreq0FlipControl) & 0x100) && scanEarliest() == scan.consoleMc;
        if (!ok) IODelay(100);
    }
    if (!ok) {   // a vsync flip that never latched: put A up at once
        scanFlipLocked(scan.consoleMc, true);
        IODelay(1000);
        ok = scanEarliest() == scan.consoleMc;
    }
    scan.acquired = false;
    scan.front = scan.pending = PHXN_SCAN_NO_SLOT;
    scan.restores++;
    if (gVrrOn) phxVrrDropLocked();   // Adaptive Sync: no flips, no trigger, so the range goes off with GPU present
    IOLog("PhxBringup: scanout restored to the console (%s)\n", ok ? "verified" : "NOT verified");
    return ok;
}

void PhxBringup::scanWatchFire(thread_call_param_t p0, thread_call_param_t) {
    PhxBringup *me = static_cast<PhxBringup *>(p0);
    IOLockLock(me->scanLock);
    if (me->scan.acquired) {
        me->scanPollLocked();
        const uint64_t plane = me->scanPlane();
        bool known = plane == me->scan.consoleMc;
        for (uint32_t k = 0; k < PHXN_SCAN_MAX_SLOTS; k++) known |= me->scan.slotUsed[k] && plane == me->scan.slotMc[k];
        uint64_t idleNs; absolutetime_to_nanoseconds(mach_absolute_time() - me->scan.lastCallAbs, &idleNs);
        bool direct = false;   // b161: a display surface is bound to a slot (its kill switch is debug.phxscan_direct)
        for (uint32_t k = 0; k < PHXN_SCAN_MAX_SLOTS; k++) direct |= me->scan.slotDirect[k];
        const bool directOff = direct && !gScanDirectOn;
        if (!gScanOn || !known || idleNs > 5000000000ull || directOff) {
            IOLog("PhxBringup: scanout watchdog restores the console (%s)\n", !gScanOn ? "debug.phxscan=0" : !known ? "HUBP0 points elsewhere" :
                  directOff ? "debug.phxscan_direct=0" : "5 s without a call");
            me->scanRestoreLocked();
            me->scan.watchdogRestores++;
        }
    }
    const bool again = me->scan.acquired;
    IOLockUnlock(me->scanLock);
    if (again) {
        uint64_t d; clock_interval_to_deadline(50, kMillisecondScale, &d);
        thread_call_enter_delayed(me->scanWatch, d);
    }
}

void PhxBringup::scanQuery(phxn_scan_query *q) {
    bzero(q, sizeof(*q));
    if (!mmio) return;
    const uint32_t vb = rreg(kOtg0VBlankStartEnd), vbs = vb & 0x7fff, vbe = (vb >> 16) & 0x7fff;
    q->h_total = rreg(kOtg0HTotal) + 1;
    q->v_total = rreg(kOtg0VTotal) + 1;
    q->pitch_px = (rreg(kHubpreq0SurfacePitch) & 0x3fff) + 1;
    q->hubp_format = rreg(kHubp0SurfaceConfig) & 0x7f;
    q->sw_mode = rreg(kHubp0TilingConfig) & 0x1f;
    q->dcc_en = rreg(kHubpreq0SurfaceControl) & 1;
    // The visible width is HUBP0's viewport: the replay plans write Linux's pitch, wider than the mode below 1440p
    // (1920 -> 2048). Under ODM 2:1 (240 Hz, gP0OdmActive) HUBP0's viewport is the left half and HUBP1 scans the right
    // half of the same surface, so the plane is twice HUBP0's viewport.
    const uint32_t vpw = (rreg(kHubp0PriViewportDim) & 0x3fff) * (gP0OdmActive ? 2u : 1u);
    q->plane_w = q->h_active = vpw && vpw <= q->pitch_px ? vpw : q->pitch_px;
    q->plane_h = q->v_active = vbs > vbe ? vbs - vbe : 0;
    q->flags = ((rreg(kOtg0Control) & 1) ? PHXN_SCANQ_LIT : 0) | PHXN_SCANQ_NATIVE;
    const uint64_t bytes = static_cast<uint64_t>(q->pitch_px) * 4 * q->plane_h;
    // ARGB2101010 too (the HDR replay plans' 10-bit scan-out): the same 4 bytes per pixel, the plugin copies l10r raw
    const bool fmtOk = q->hubp_format == PHXN_SCAN_FMT_ARGB8888 || q->hubp_format == PHXN_SCAN_FMT_ARGB2101010;
    if (fmtOk && !q->sw_mode && !q->dcc_en && q->plane_h && scanLayoutFor(bytes, nullptr) >= 0)
        q->flags |= PHXN_SCANQ_GEOM_OK;
    // b161: direct scan-out would be allowed for this plane (PhxScanDirect.h): the large layout, BAR0 over the slots, and
    // HUBP0 as Linux leaves a linear surface: DCC_EN, PRIMARY_SURFACE_TMZ and the VMID 0. Register reads only.
    if ((q->flags & PHXN_SCANQ_GEOM_OK) && gScanDirectOn && scanLayoutFor(bytes, nullptr) == phxscanlay::kLarge &&
        phxscandirect::barCoversSlots(fbBarLen, fbAperLen) &&
        !(rreg(kHubpreq0SurfaceControl) & (phxscandirect::kSurfCtlTmz | phxscandirect::kSurfCtlDcc)) &&
        !(rreg(kHubpreq0VmidSettings0) & phxscandirect::kVmidMask))
        q->flags |= PHXN_SCANQ_DIRECT_OK;
    if (scanLock) IOLockLock(scanLock);
    q->frame_count = scanFrameLocked();
    q->acquired = scan.acquired;
    if (scan.acquired) q->flags |= PHXN_SCANQ_ACQUIRED;
    q->console_mc = scan.acquired ? scan.consoleMc : scanPlane();
    if (scanLock) IOLockUnlock(scanLock);
    q->plane_mc = scanPlane();
    q->earliest_mc = scanEarliest();
    q->otg = 0;
}

// Before a mode change to another size, with scanLock held: a GPU-present acquisition's slots have the old size, so
// HUBP0 goes back to the console surface A now (the same flip a release does) and the CPU copy draws the new mode.
// Without this the plugin, which never sees a frame at the new size, keeps the plane while the CPU copy skips every
// frame as foreign: a black screen (seen on the XTX machine with a saved 1280x1024 applied at login). A rate change at
// the same size keeps the acquisition (the slots stay valid). The owner keeps its handle; its next call is refused (not
// acquired) and the plugin treats that as a lost plane. true = a restore ran.
bool PhxBringup::scanYieldForModeLocked(uint32_t targetH) {
    if (!mmio || !scan.acquired || !targetH || targetH == scan.planeH)
        return false;
    IOLog("PhxBringup: scanout given back before a mode change (%ux%u -> height %u)\n", scan.pitchPx, scan.planeH, targetH);
    scanRestoreLocked();
    return true;
}

// b126: the slot layout for a frame of `bytes` (PhxScanLayout.h) against the VRAM size and the display's FB window as the
// registers read now. Register reads only.
int PhxBringup::scanLayoutFor(uint64_t bytes, phxscanlay::Layout *l) const {
    if (!mmio) return phxscanlay::kErrEmpty;
    return phxscanlay::choose(bytes, fbSize, rreg(kDcnVmFbLocationBase), rreg(kDcnVmFbLocationTop), l);
}

// b126: debug.phxscan_layout, what an acquire would get for the live plane, and the slots of the current acquisition.
int PhxBringup::scanLayoutStat(char *buf, size_t cap) {
    if (!mmio) return snprintf(buf, cap, "no MMIO");
    phxn_scan_query q;
    scanQuery(&q);
    const uint64_t bytes = static_cast<uint64_t>(q.pitch_px) * 4 * q.plane_h;
    phxscanlay::Layout l{};
    const int r = scanLayoutFor(bytes, &l);
    const uint32_t db = rreg(kDcnVmFbLocationBase) & 0xffffff, dt = rreg(kDcnVmFbLocationTop) & 0xffffff;
    int n = snprintf(buf, cap, "plane %ux%u pitch %u px fmt %u sw %u dcc %u lit %u: %llu bytes -> %s",
                     q.plane_w, q.plane_h, q.pitch_px, q.hubp_format, q.sw_mode, q.dcc_en, (q.flags & PHXN_SCANQ_LIT) ? 1u : 0u,
                     static_cast<unsigned long long>(bytes), phxscanlay::name(r));
    if (r >= 0 && n > 0 && static_cast<size_t>(n) < cap)
        n += snprintf(buf + n, cap - static_cast<size_t>(n), " at VRAM 0x%llx + k * 0x%llx", l.base, l.stride);
    if (n > 0 && static_cast<size_t>(n) < cap)
        n += snprintf(buf + n, cap - static_cast<size_t>(n), "; geom_ok %u; VRAM %llu MiB; DCN FB window 0x%x..0x%x (%llu MiB); acquired %u",
                      (q.flags & PHXN_SCANQ_GEOM_OK) ? 1u : 0u, static_cast<unsigned long long>(fbSize >> 20), db, dt,
                      dt >= db ? static_cast<unsigned long long>(dt - db + 1) * 16 : 0ull, q.acquired);
    if (q.acquired && n > 0 && static_cast<size_t>(n) < cap)
        n += snprintf(buf + n, cap - static_cast<size_t>(n), " (slots %s at VRAM 0x%llx + k * 0x%llx)", phxscanlay::name(scan.lay.kind), scan.lay.base,
                      scan.lay.stride);
    // b161: direct scan-out (PhxScanDirect.h)
    if (n > 0 && static_cast<size_t>(n) < cap)
        n += snprintf(buf + n, cap - static_cast<size_t>(n),
                      "; direct: switch %d, allowed %u, BAR0 %llu MiB (mapped %llu), slots bound %u%u, binds %lld, refused %lld (last: %s), "
                      "host imports of BAR pages refused %lld",
                      gScanDirectOn, (q.flags & PHXN_SCANQ_DIRECT_OK) ? 1u : 0u, static_cast<unsigned long long>(fbBarLen >> 20),
                      static_cast<unsigned long long>(fbAperLen >> 20), scan.slotDirect[0] ? 1u : 0u, scan.slotDirect[1] ? 1u : 0u,
                      gScanDirectBinds, gScanDirectRefused, phxscandirect::name(gScanDirectLastErr), gHostBarRefused);
    return n;
}

IOReturn PhxBringup::scanAcquire(const void *who, uint64_t out[2]) {
    if (!mmio || !fbAper || !gScanOn)
        return kIOReturnUnsupported;
    if (!scanLock) scanLock = IOLockAlloc();
    if (!scanWatch) scanWatch = thread_call_allocate(scanWatchFire, this);
    if (!scanLock || !scanWatch)
        return kIOReturnNoMemory;
    phxn_scan_query q;
    scanQuery(&q);
    IOLockLock(scanLock);
    IOReturn r = kIOReturnSuccess;
    const uint64_t fbBase = static_cast<uint64_t>(rreg(kDcnVmFbLocationBase) & 0xffffff) << 24;
    phxscanlay::Layout lay{};
    const int layR = scanLayoutFor(static_cast<uint64_t>(q.pitch_px) * 4 * q.plane_h, &lay);
    if (scan.acquired) {
        r = kIOReturnBusy;
    } else if (!(q.flags & PHXN_SCANQ_GEOM_OK) || !(q.flags & PHXN_SCANQ_LIT) || layR < 0) {
        r = kIOReturnUnsupported;
    } else if (q.plane_mc != fbBase || q.earliest_mc != fbBase || (rreg(kHubpreq0FlipControl) & 0x100)) {
        r = kIOReturnNotReady;   // the console surface A must be on screen and idle (debug.phxfb_flip=0)
    } else {
        const void *prev = scan.owner;
        bzero(&scan, sizeof(scan));
        scan.frameLast = rreg(kOtg0StatusFrameCount) & 0xffffff;
        scan.owner = who;
        scan.acquired = true;
        scan.consoleMc = q.plane_mc;
        scan.fbBase = fbBase;
        scan.pitchPx = q.pitch_px;
        scan.planeH = q.plane_h;
        scan.lay = lay;
        scan.front = scan.pending = PHXN_SCAN_NO_SLOT;
        scan.lastCallAbs = mach_absolute_time();
        out[0] = scan.consoleMc;
        out[1] = scanFrameLocked();
        if (gVrrWant) phxVrrResumeLocked();   // Adaptive Sync: System Settings' Variable, back with GPU present
        IOLog("PhxBringup: scanout acquired (console MC 0x%llx, %ux%u, slots %s at VRAM 0x%llx + k * 0x%llx)%s\n", scan.consoleMc,
              q.pitch_px, q.plane_h, phxscanlay::name(scan.lay.kind), scan.lay.base, scan.lay.stride, prev ? " (previous owner dropped)" : "");
    }
    IOLockUnlock(scanLock);
    if (r == kIOReturnSuccess) {
        uint64_t d; clock_interval_to_deadline(50, kMillisecondScale, &d);
        thread_call_enter_delayed(scanWatch, d);
    }
    return r;
}

IOReturn PhxBringup::scanAllocSlot(const void *who, const phxn_scan_reg *r, uint32_t *slot, uint64_t *mc, uint64_t *vramOff) {
    if (!scanLock || !gScanOn)
        return kIOReturnUnsupported;
    IOLockLock(scanLock);
    IOReturn ret = kIOReturnSuccess;
    if (!scan.acquired || scan.owner != who) {
        ret = kIOReturnNotPermitted;
    } else if (r->reserved0 || r->offset || r->format != PHXN_SCAN_FMT_ARGB8888 || r->pitch_bytes != scan.pitchPx * 4 ||
               r->width != scan.pitchPx || r->height != scan.planeH ||
               static_cast<uint64_t>(r->pitch_bytes) * r->height > scan.lay.stride) {
        ret = kIOReturnBadArgument;
    } else {
        uint32_t k = 0;
        while (k < PHXN_SCAN_MAX_SLOTS && scan.slotUsed[k]) k++;
        if (k == PHXN_SCAN_MAX_SLOTS) {
            ret = kIOReturnNoResources;
        } else {
            scan.slotUsed[k] = true;
            *vramOff = phxscanlay::slotOff(scan.lay, k);
            scan.slotMc[k] = scan.fbBase + *vramOff;
            *slot = k;
            *mc = scan.slotMc[k];
            scan.lastCallAbs = mach_absolute_time();
        }
    }
    IOLockUnlock(scanLock);
    return ret;
}

// b161: direct scan-out (PhxScanDirect.h). Slot 0 or 1 of this acquisition's large layout for the BO a display surface is
// drawn through; the caller (doScan) rebinds the BO's maps onto the slot's VRAM. The checks read HUBP0's live format,
// tiling, SURFACE_CONTROL and VMID_SETTINGS_0; nothing is written here. The flips to it are scanPresent's, unchanged.
IOReturn PhxBringup::scanDirectSlot(const void *who, uint32_t slot, const phxn_scan_reg *r, uint64_t boSize, bool boVram, bool boBound,
                                    uint64_t *mc, uint64_t *vramOff, int *err) {
    if (!scanLock || !gScanOn || !mmio)
        return kIOReturnUnsupported;
    IOLockLock(scanLock);
    phxscandirect::Live l{};
    l.on = gScanDirectOn != 0;
    l.owner = scan.acquired && scan.owner == who;
    l.layKind = scan.lay.kind;
    l.stride = scan.lay.stride;
    l.barBytes = fbBarLen;
    l.aperBytes = fbAperLen;
    l.pitchPx = scan.pitchPx;
    l.planeH = scan.planeH;
    l.hubpFormat = rreg(kHubp0SurfaceConfig) & 0x7f;
    l.swMode = rreg(kHubp0TilingConfig) & 0x1f;
    l.surfCtl = rreg(kHubpreq0SurfaceControl);
    l.vmid = rreg(kHubpreq0VmidSettings0);
    for (uint32_t k = 0; k < phxscandirect::kSlots; k++) l.slotUsed[k] = scan.slotUsed[k];
    const phxscandirect::Req q{slot, r->reserved0, r->pitch_bytes, r->width, r->height, r->format, r->offset};
    const phxscandirect::Bo b{true, boVram, boBound, boSize};
    const int e = phxscandirect::bindCheck(q, b, l);
    *err = e;
    IOReturn ret = kIOReturnSuccess;
    if (e != phxscandirect::kOk) {
        OSIncrementAtomic64(&gScanDirectRefused);
        gScanDirectLastErr = e;
        ret = e == phxscandirect::kErrOff ? kIOReturnUnsupported : e == phxscandirect::kErrNotOwner ? kIOReturnNotPermitted
            : e == phxscandirect::kErrSlotUsed ? kIOReturnNoResources : kIOReturnBadArgument;
    } else {
        scan.slotUsed[slot] = true;
        scan.slotDirect[slot] = true;
        *vramOff = phxscanlay::slotOff(scan.lay, slot);
        scan.slotMc[slot] = scan.fbBase + *vramOff;
        *mc = scan.slotMc[slot];
        scan.lastCallAbs = mach_absolute_time();
        OSIncrementAtomic64(&gScanDirectBinds);
    }
    IOLockUnlock(scanLock);
    return ret;
}

// b161: whether [pa, pa + len) touches one of the GPU's own BARs (0, 2, 5). doBoImportHost refuses such pages: the GPU
// must reach its VRAM through local-VRAM PTEs, never through a system-memory PTE pointing at its own BAR (Linux's
// amdgpu_ttm_tt_get_user_pages refuses VM_IO / VM_PFNMAP mappings for userptr the same way).
bool PhxBringup::physInOwnBars(uint64_t pa, uint64_t len) const {
    using phxscandirect::overlaps;
    if (fbAperPhys && overlaps(pa, len, fbAperPhys, fbBarLen > fbAperLen ? fbBarLen : fbAperLen)) return true;
    if (mmio && overlaps(pa, len, mmio->getPhysicalAddress(), mmio->getLength())) return true;
    if (doorbellMap && overlaps(pa, len, doorbellMap->getPhysicalAddress(), doorbellMap->getLength())) return true;
    return false;
}

IOReturn PhxBringup::scanPresent(const void *who, uint32_t slot, uint64_t out[3]) {
    if (!scanLock || !gScanOn)
        return kIOReturnUnsupported;
    IOLockLock(scanLock);
    IOReturn r = kIOReturnSuccess;
    if (!scan.acquired || scan.owner != who) {
        r = kIOReturnNotPermitted;
    } else if (slot >= PHXN_SCAN_MAX_SLOTS || !scan.slotUsed[slot]) {
        scan.refused++;
        r = kIOReturnBadArgument;
    } else {
        scanPollLocked();
        if (scan.pending != PHXN_SCAN_NO_SLOT) {
            scan.replaced++;   // a flip not latched yet: the newest one wins
            if (!(rreg(kHubpreq0FlipControl) & 0x100)) {   // b74: ...but the hardware already took it: that slot is on screen
                OSIncrementAtomic64(&gScanAcceptedForgotten);
                gScanGhost = scan.pending;
            }
        }
        scanFlipLocked(scan.slotMc[slot], false);
        if (gVrrOn) {
            // Adaptive Sync, per flip: the ramp's window for the next frames (PhxVrrRamp.h), then Linux's manual trigger,
            // which ends the stretched frame so this flip shows at once. OTG0's DRR double buffer is on (vrrOnLocked), so
            // a window written here latches at the next frame start, never mid-frame.
            if (gVrrRampPct <= 0 && gVrrRampVMax > gVrrRampVMin &&
                (gVrrRampLo != gVrrRampVMin || gVrrRampHi != gVrrRampVMax)) {
                // the ramp was turned off: the mode's full range back, or the last window would stay
                wreg(kOtg0VTotalMin, gVrrRampVMin); wreg(kOtg0VTotalMax, gVrrRampVMax);
                gVrrRampLo = gVrrRampVMin; gVrrRampHi = gVrrRampVMax; gVrrRampPrimed = false;
                OSIncrementAtomic64(&gVrrRampWrites);
            }
            if (gVrrRampPct > 0 && gVrrRampVMax > gVrrRampVMin) {
                // the frame length since the previous flip, from OTG0's frame counter and the clock, sets the window
                const uint64_t f = scanFrameLocked();
                uint64_t ns = 0;
                absolutetime_to_nanoseconds(mach_absolute_time(), &ns);
                if (gVrrRampPrimed && f > gVrrRampFrame && ns > gVrrRampNs) {
                    gVrrRampLines = phxvrr::linesFromPeriod((ns - gVrrRampNs) / (f - gVrrRampFrame), gVrrRampVMin, gVrrRampHz);
                    uint32_t lo, hi;
                    phxvrr::window(gVrrRampLines, gVrrRampVMin, gVrrRampVMax, static_cast<uint32_t>(gVrrRampPct), &lo, &hi);
                    if (lo != gVrrRampLo || hi != gVrrRampHi) {
                        if (phxvrr::maxFirst(lo, hi, gVrrRampLo)) { wreg(kOtg0VTotalMax, hi); wreg(kOtg0VTotalMin, lo); }
                        else { wreg(kOtg0VTotalMin, lo); wreg(kOtg0VTotalMax, hi); }
                        gVrrRampLo = lo; gVrrRampHi = hi;
                        OSIncrementAtomic64(&gVrrRampWrites);
                    }
                }
                if (f > gVrrRampFrame || !gVrrRampPrimed) { gVrrRampFrame = f; gVrrRampNs = ns; gVrrRampPrimed = true; }
            }
            wreg(kOtg0TrigAManualTrig, 1u); OSIncrementAtomic64(&gVrrTrigs);   // Linux's per-flip trigger
        }
        scan.pending = slot;
        scan.presents++;
        scan.slotPresents[slot]++;
        scan.lastCallAbs = mach_absolute_time();
        out[0] = scan.presents;
        out[1] = scanFrameLocked() + 1;
        out[2] = 0;
    }
    IOLockUnlock(scanLock);
    return r;
}

IOReturn PhxBringup::scanStatus(const void *who, phxn_scan_status *st) {
    bzero(st, sizeof(*st));
    if (!scanLock)
        return kIOReturnUnsupported;
    IOLockLock(scanLock);
    if (scan.owner == who) scan.lastCallAbs = mach_absolute_time();
    if (scan.acquired) scanPollLocked();
    const uint64_t earliest = scanEarliest();
    st->acquired = scan.acquired && scan.owner == who;
    // 10-bit HDR: tells the plugin to copy l10r as it is
    if (mmio && (rreg(kHubp0SurfaceConfig) & 0x7f) == PHXN_SCAN_FMT_ARGB2101010) st->flags |= PHXN_SCANST_FMT10;
    st->front_slot = scan.front;
    st->pending_slot = scan.pending;
    st->frame_count = scanFrameLocked();
    st->console_mc = scan.consoleMc;
    st->plane_mc = scanPlane();
    st->earliest_mc = earliest;
    st->presents = scan.presents; st->latched = scan.latched; st->replaced = scan.replaced; st->refused = scan.refused;
    st->latch_poll = scan.latched;
    st->first_latch_ns = scan.firstLatchNs; st->last_latch_ns = scan.lastLatchNs;
    st->watchdog_restores = scan.watchdogRestores;
    for (uint32_t k = 0; k < PHXN_SCAN_MAX_SLOTS; k++) {
        phxn_scan_slot &o = st->slot[k];
        o.mc = scan.slotMc[k];
        o.used = scan.slotUsed[k];
        o.presents = scan.slotPresents[k];
        o.latches = scan.slotLatches[k];
        o.latched_frame = scan.slotLatchedFrame[k];
        if (!scan.slotUsed[k]) continue;
        const bool pend = scan.acquired && scan.pending == k, inuse = earliest == scan.slotMc[k];
        const bool front = gScanLatchFix && scan.front == k;   // b74: the latched front is on screen until the next latch
        const bool reuse = !pend && !inuse && !front;
        if (reuse && k == gScanGhost)
            OSIncrementAtomic64(&gScanReusableGhost);
        // b161: Linux's flip-complete test whatever debug.phxscan_latchfix says: the latched front counts as on screen
        const bool writ = phxscandirect::writable(pend, inuse, scan.front == k);
        o.flags = (pend ? PHXN_SCANSLOT_PENDING : 0) | (inuse ? PHXN_SCANSLOT_INUSE : 0) | (reuse ? PHXN_SCANSLOT_REUSABLE : 0) |
                  (scan.slotDirect[k] ? PHXN_SCANSLOT_DIRECT : 0) | (writ ? PHXN_SCANSLOT_WRITABLE : 0);
    }
    IOLockUnlock(scanLock);
    return kIOReturnSuccess;
}

IOReturn PhxBringup::scanRelease(const void *who, uint64_t out[2]) {
    if (out) { out[0] = 1; out[1] = mmio ? scanPlane() : 0; }
    if (!scanLock)
        return kIOReturnSuccess;
    IOLockLock(scanLock);
    if (scan.owner == who) {
        const bool ok = scanRestoreLocked();
        if (out) { out[0] = ok; out[1] = scanPlane(); }
        scan.owner = nullptr;
        for (uint32_t k = 0; k < PHXN_SCAN_MAX_SLOTS; k++) scan.slotUsed[k] = scan.slotDirect[k] = false;
    }
    IOLockUnlock(scanLock);
    return kIOReturnSuccess;
}

