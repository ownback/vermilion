// SPDX-License-Identifier: MIT
// DCN 3.2 (Navi31) display registers the kext touches, as absolute dword offsets: DCN BASE_IDX 2 base 0x34C0 + the
// register offset from Linux dcn_3_2_0_offset.h. Instance 0 only (HUBP0 / OTG0 / ODM0).
#pragma once
#include <stdint.h>
static constexpr uint32_t kDcnVmFbLocationBase          = 0x3935;   // DCN_VM_FB_LOCATION_BASE
static constexpr uint32_t kDcnVmFbLocationTop           = 0x3936;   // DCN_VM_FB_LOCATION_TOP (16 MiB units, inclusive; Linux on the XTX: 0x85ff)
static constexpr uint32_t kHubp0SurfaceConfig           = 0x3aa5;   // HUBP0_DCSURF_SURFACE_CONFIG
static constexpr uint32_t kHubp0TilingConfig            = 0x3aa7;   // HUBP0_DCSURF_TILING_CONFIG
static constexpr uint32_t kHubp0DchubpCntl              = 0x3ab3;   // HUBP0_DCHUBP_CNTL (underflow status 30:28, clear 31)
static constexpr uint32_t kHubpreq0SurfacePitch         = 0x3ac7;   // HUBPREQ0_DCSURF_SURFACE_PITCH
static constexpr uint32_t kHubp0PriViewportDim          = 0x3aaa;   // HUBP0_DCSURF_PRI_VIEWPORT_DIMENSION (b138: width [13:0])
// Adaptive Sync's per-flip writes (phx_scan.cpp). The kernel-free PhxP0Odm.h names the first two again as
// phxodm::kOtg0VMin / kOtg0VMax, for its own range writes and the host test.
static constexpr uint32_t kOtg0VTotalMin = 0x04FF0, kOtg0VTotalMax = 0x04FF1;   // OTG0_OTG_V_TOTAL_MIN / MAX (the ramp's window)
static constexpr uint32_t kOtg0TrigAManualTrig = 0x04FFA;   // OTG0_OTG_TRIGA_MANUAL_TRIG (Linux optc2_program_manual_trigger)
static constexpr uint32_t kHubpreq0PrimaryAddr          = 0x3aca;   // HUBPREQ0_DCSURF_PRIMARY_SURFACE_ADDRESS
static constexpr uint32_t kHubpreq0PrimaryAddrHigh      = 0x3acb;   // HUBPREQ0_DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH
static constexpr uint32_t kHubpreq0VmidSettings0        = 0x3ac9;   // HUBPREQ0_VMID_SETTINGS_0 (VMID [3:0]; b161 reads it, Linux's 0)
static constexpr uint32_t kHubpreq0SurfaceControl       = 0x3ada;   // HUBPREQ0_DCSURF_SURFACE_CONTROL (dcn_3_2_0_sh_mask.h: bit 0 PRIMARY_SURFACE_TMZ, bit 1 DCC_EN)
static constexpr uint32_t kHubpreq0FlipControl          = 0x3adb;   // HUBPREQ0_DCSURF_FLIP_CONTROL (bit 1 immediate, bit 8 update pending)
static constexpr uint32_t kHubpreq0SurfaceInuse         = 0x3ae0;   // HUBPREQ0_DCSURF_SURFACE_INUSE
static constexpr uint32_t kHubpreq0SurfaceInuseHigh     = 0x3ae1;   // HUBPREQ0_DCSURF_SURFACE_INUSE_HIGH
static constexpr uint32_t kHubpreq0EarliestInuse        = 0x3ae4;   // HUBPREQ0_DCSURF_SURFACE_EARLIEST_INUSE
static constexpr uint32_t kHubpreq0EarliestInuseHigh    = 0x3ae5;   // HUBPREQ0_DCSURF_SURFACE_EARLIEST_INUSE_HIGH
// HUBPREQ1 = HUBPREQ0 + 0xDC (dcn_3_2_0_offset.h: VMID_SETTINGS_0 0x6e5, SURFACE_CONTROL 0x6f6, FLIP_CONTROL 0x6f7,
// EARLIEST_INUSE 0x700 / 0x701 against HUBPREQ0's 0x609 / 0x61a / 0x61b / 0x624 / 0x625): HUBP1 under ODM 2:1 (b131)
static constexpr uint32_t kHubpreq1Delta                = 0xDC;
static constexpr uint32_t kOdm0OptcInputGlobalControl   = 0x4f8a;   // ODM0_OPTC_INPUT_GLOBAL_CONTROL (underflow occurred 10, clear 12)
static constexpr uint32_t kOtg0HTotal                   = 0x4fea;   // OTG0_OTG_H_TOTAL
static constexpr uint32_t kOtg0VTotal                   = 0x4fef;   // OTG0_OTG_V_TOTAL
static constexpr uint32_t kOtg0VBlankStartEnd           = 0x4ff6;   // OTG0_OTG_V_BLANK_START_END
static constexpr uint32_t kOtg0Control                  = 0x5001;   // OTG0_OTG_CONTROL (bit 0 master enable)
static constexpr uint32_t kOtg0StatusFrameCount         = 0x500c;   // OTG0_OTG_STATUS_FRAME_COUNT
