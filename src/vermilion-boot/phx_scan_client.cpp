// SPDX-License-Identifier: MIT
// phx_scan_client.cpp: scanout selectors (9..14, b162 22), user-client side.
// Part of the PhxBringup.cpp translation unit (included there, in order); not compiled on its own.

// ---- scanout selectors (9..14, 22), see PhxBringup::scanAcquire ------------------------------------------------
void IOAccelPhxNativeClient::scanUnbind() {
    for (uint32_t h = 1; h < PHXN_MAX_BOS; h++) {
        if (!bos[h].scanSlot) continue;
        for (int i = 0; i < kMaxMaps; i++)
            if (maps[i].used && maps[i].handle == h && vmid)
                owner->vmMap(vmid, maps[i].va, bos[h].md, maps[i].off, maps[i].size);
        bos[h].scanSlot = 0;
        bos[h].scanVram = 0;
        bos[h].scanDirect = false;
    }
}

IOReturn IOAccelPhxNativeClient::doScan(uint32_t selector, IOExternalMethodArguments *a) {
    if (!scanAllowed())
        return kIOReturnNotPrivileged;
    switch (selector) {
    case PHXN_SEL_SCAN_QUERY:
        if (!shape(a, 0, 0, 0, sizeof(phxn_scan_query)))
            return kIOReturnBadArgument;
        owner->scanQuery(static_cast<phxn_scan_query *>(a->structureOutput));
        return kIOReturnSuccess;
    case PHXN_SEL_SCAN_ACQUIRE: {
        if (!shape(a, 1, 2, 0, 0) || a->scalarInput[0])
            return kIOReturnBadArgument;
        if (!owner->scanHeldBy(this)) scanUnbind();   // left over from a watchdog restore
        uint64_t out[2] = {0, 0};
        const IOReturn r = owner->scanAcquire(this, out);
        a->scalarOutput[0] = out[0]; a->scalarOutput[1] = out[1];
        return r;
    }
    case PHXN_SEL_SCAN_REGISTER: {
        if (!shape(a, 0, 2, sizeof(phxn_scan_reg), 0))
            return kIOReturnBadArgument;
        phxn_scan_reg reg;
        bcopy(a->structureInput, &reg, sizeof(reg));
        Bo *b = findBo(reg.handle);
        if (b && b->vram) { OSIncrementAtomic64(&gVramScanRefused); return kIOReturnBadArgument; }   // b156
        if (!b || b->host || b->scanSlot || reg.offset + static_cast<uint64_t>(reg.pitch_bytes) * reg.height > b->size)
            return kIOReturnBadArgument;
        uint32_t slot = 0; uint64_t mc = 0, vramOff = 0;
        IOReturn r = owner->scanAllocSlot(this, &reg, &slot, &mc, &vramOff);
        if (r != kIOReturnSuccess)
            return r;
        b->scanSlot = slot + 1;
        b->scanVram = vramOff;
        // what is already mapped of this BO now reaches the slot's VRAM; later maps take the same path (doGemVa)
        for (int i = 0; i < kMaxMaps && r == kIOReturnSuccess; i++)
            if (maps[i].used && maps[i].handle == reg.handle && vmid)
                r = owner->vmMapVram(vmid, maps[i].va, vramOff + maps[i].off, maps[i].size);
        IOLog("PhxBringup: scanout slot %u = BO %u (%llu bytes) at VRAM 0x%llx, MC 0x%llx%s\n", slot, reg.handle, b->size, vramOff, mc,
              r == kIOReturnSuccess ? "" : " - REMAP FAILED");
        a->scalarOutput[0] = slot; a->scalarOutput[1] = mc;
        return r;
    }
    case PHXN_SEL_SCAN_DIRECT: {
        // b162: a display surface's own BO onto slot 0 or 1 (PhxScanDirect.h); the same rebinding as REGISTER below, for
        // a host import too (the IOSurface's pages stay wired and untouched; the GPU reaches the slot instead)
        if (!shape(a, 1, 2, sizeof(phxn_scan_reg), 0))
            return kIOReturnBadArgument;
        phxn_scan_reg reg;
        bcopy(a->structureInput, &reg, sizeof(reg));
        Bo *b = findBo(reg.handle);
        const uint64_t slotIn = a->scalarInput[0];
        uint64_t mc = 0, vramOff = 0;
        int err = phxscandirect::kErrBo;
        IOReturn r = b && slotIn < phxscandirect::kSlots
                         ? owner->scanDirectSlot(this, static_cast<uint32_t>(slotIn), &reg, b->size, b->vram != 0, b->scanSlot != 0, &mc, &vramOff, &err)
                         : kIOReturnBadArgument;
        if (r != kIOReturnSuccess) {
            if (!b || slotIn >= phxscandirect::kSlots) { OSIncrementAtomic64(&gScanDirectRefused); gScanDirectLastErr = b ? phxscandirect::kErrSlot : phxscandirect::kErrBo; }
            return r;
        }
        const uint32_t slot = static_cast<uint32_t>(slotIn);
        b->scanSlot = slot + 1;
        b->scanVram = vramOff;
        b->scanDirect = true;
        for (int i = 0; i < kMaxMaps && r == kIOReturnSuccess; i++)
            if (maps[i].used && maps[i].handle == reg.handle && vmid)
                r = owner->vmMapVram(vmid, maps[i].va, vramOff + maps[i].off, maps[i].size);
        IOLog("PhxBringup: direct scan-out slot %u = BO %u (%s, %llu bytes) at VRAM 0x%llx, MC 0x%llx%s\n", slot, reg.handle, b->host ? "host" : "system",
              b->size, vramOff, mc, r == kIOReturnSuccess ? "" : " - REMAP FAILED");
        a->scalarOutput[0] = slot; a->scalarOutput[1] = mc;
        return r;
    }
    case PHXN_SEL_SCAN_PRESENT: {
        if (!shape(a, 2, 3, 0, 0) || a->scalarInput[1] || a->scalarInput[0] >= PHXN_SCAN_MAX_SLOTS)
            return kIOReturnBadArgument;
        uint64_t out[3] = {0, 0, 0};
        const IOReturn r = owner->scanPresent(this, static_cast<uint32_t>(a->scalarInput[0]), out);
        a->scalarOutput[0] = out[0]; a->scalarOutput[1] = out[1]; a->scalarOutput[2] = out[2];
        return r;
    }
    case PHXN_SEL_SCAN_STATUS:
        if (!shape(a, 0, 0, 0, sizeof(phxn_scan_status)))
            return kIOReturnBadArgument;
        return owner->scanStatus(this, static_cast<phxn_scan_status *>(a->structureOutput));
    case PHXN_SEL_SCAN_RELEASE: {
        if (!shape(a, 0, 2, 0, 0))
            return kIOReturnBadArgument;
        uint64_t out[2] = {0, 0};
        owner->scanRelease(this, out);
        scanUnbind();
        a->scalarOutput[0] = out[0]; a->scalarOutput[1] = out[1];
        return kIOReturnSuccess;
    }
    }
    return kIOReturnUnsupported;
}
