# The device info from the hardware (plan A4, A9, A11, A19), 2026-11-26

Branch `ownback/device-info`. Nothing here has run on hardware yet: every new value is (unverified) until the owner
boots it (section 8). No machine change was made for this work; no GPU access.

## 1. What changed

- **VermilionBoot b168** (ABI 1.13):
  - reads the IP discovery table and the GC harvest registers the way Linux amdgpu does (new `PhxDevInfo.h`,
    `phx_devinfo.cpp`);
  - sizes the hi VRAM pool from the VRAM the memory controller reports;
  - samples GPU busy time (new `PhxGpuStats.h`).
- **VermilionAccel 0.1.2:** NMXAccel's `PerformanceStatistics` gets `Device Utilization %` and `vramFreeBytes`, through
  an `IOAccelStatistics2` subclass (`nmx_stats.h`). Its numbers come from the kext's "phxGpuStats" platform function.
- **Plugin:** `MTLDevice.name` is the marketing name alone, "AMD Radeon RX 7900 XTX" (was "... (RADV NAVI31) (NVMTL
  over ...)").
- **Mesa, patches 0016-0020:**
  - `navi31_xt` and the revision switch are gone;
  - 0016 makes Mesa's `navi31` entry the default;
  - 0018 takes the device info from the kext when it offers ABI 1.13.

## 2. Where each value comes from

The kext reads `RCC_CONFIG_MEMSIZE` (0xDE3), then the discovery binary at the top of VRAM minus 64 KiB, at most
10 KiB. The read goes through the MM_INDEX / MM_DATA window (`mmIdxRead`), as `amdgpu_discovery_read_binary_from_mem`
does: the table lies above the CPU-visible BAR. The kext checks the binary as `amdgpu_discovery_init` does (signatures,
byte-sum checksums, bounds), then parses it.

The GC registers are read once GFX is up (`adoptQueue`), and only at the table's bases when those are this ASIC's known
ones (GC 0x1260 / 0xA000, NBIO 0xD20). The window's two index writes (MM_INDEX_HI, MM_INDEX) are the only register
writes; Linux makes them for the same read (section 7).

| `phxn_devinfo` field (RADV `drm_amdgpu_info_device`) | Source | Linux's source |
|---|---|---|
| `device_id`, `pci_rev` | PCI config space | the same |
| `chip_rev`, `external_rev` | NBIO revision strap 0xD36 bits 27:24; external = rev + 1 | `soc21_common_early_init` |
| `family`, `gc_ip` (HW_IP major / minor / `ip_discovery_version`) | discovery IP list | `amdgpu_discovery_reg_base_init` |
| `vcn_ip`, `vcn_config`, `umc_ip`, `num_umc` | discovery IP list, VCN info table, harvest table | the same |
| `num_se`, `num_sa_per_se`, `num_cu_per_sa`, `num_rb_pipes`, `num_tcc_blocks` | GC info table (v1.x / v2.x) | `amdgpu_discovery_get_gfx_info` |
| `num_gprs`, `max_gs_waves_per_vgt`, `gs_vgt_table_depth`, `gs_prim_buffer_depth`, `double_offchip_lds`, `wave_size` | GC info table | the same |
| `tcp_cache_kb`, `num_sqc_per_wgp`, `sqc_inst/data_cache_kb`, `gl1c_cache_kb`, `gl2c_cache_kb` | GC info table (gl1c = per instance x per SA, as `amdgpu_kms.c`) | the same |
| `mall_size` | MALL info table (v1: per-UMC size and `half_use`; v2: per UMC x count), minus harvested UMCs | `amdgpu_discovery_get_mall_info` |
| `sa_active_mask` | `CC_GC_SA_UNIT_DISABLE` / `GC_USER_SA_UNIT_DISABLE` | `gfx_v11_0_get_sa_active_bitmap` |
| `enabled_rb_pipes_mask` | `CC_RB_BACKEND_DISABLE` / `GC_USER_RB_BACKEND_DISABLE`, laid out as Linux 6.8 does | `gfx_v11_0_setup_rb` |
| `tcc_disabled_mask` | `CGTS_TCC_DISABLE` / `CGTS_USER_TCC_DISABLE` | `gfx_v11_0_get_tcc_info` |
| `gb_addr_config` (also RADV's `READ_MMR_REG 0x263E`) | `GB_ADDR_CONFIG`, live | the same |
| `cu_bitmap`, `cu_active_number` | the table's CUs in every active SA (flag `CU_PER_SA_FULL`, section 3) | per-SA WGP registers |
| `vram_type`, `vram_bit_width` | UMC 8.10: GDDR6, 16 bits per channel, 2 x 2 channels per UMC less the MALL half-use ones (flag `VRAM_FROM_UMC`) | VBIOS `vram_info` |
| `pcie_gen`, `pcie_num_lanes` | Link Capabilities of the GPU and of its upstream port, the lower of each | `amdgpu_device_partner_bandwidth` |
| `num_hw_gfx_contexts` | 8, a driver constant on Linux too | `gfx_v11_0_gpu_early_init` |
| `name` | `PhxGpuId.h` `marketingName` | Mesa's marketing-name table |
| `vram_mb`, IOReg `VRAM,totalMB` | `RCC_CONFIG_MEMSIZE` | the same register |
| IOReg `model` | `PhxGpuId.h` (same bytes as before, the refactor commit "the PCI model string from PhxGpuId") | |

RADV keeps only the values that are the driver's own on Linux too: the VA layout, page and fragment sizes,
`ids_flags`, the CE RAM and the gfx9 prim / pos buffers. The first DEV_INFO query logs how many values differ from
Mesa's entry and which ones (`radv-darwin: device info from the kext (flags 0x..): N values differ ...`).

## 3. What stays canned, and why

Each one is flagged in `phxn_devinfo.flags` and in `sysctl debug.phxdevinfo`:

- **Per-SA CU masks** (`CU_PER_SA_FULL`): Linux reads the WGP disable registers per SE / SA after a `GRBM_GFX_INDEX`
  select. That select is a register write, and our kext doesn't send it today, so every active SA gets the table's CU
  count. On a fully enabled XTX the result is the same (96 CUs). Follow-up: the select as `gfx_v11_0_get_cu_info` does
  it, through hw-safety.
- **VRAM type and width** (`VRAM_FROM_UMC`): Linux takes them from the VBIOS `vram_info` table. The kext has no VBIOS
  image at run time, and `PhxVbios.h` (the connector-table parser, not compiled into the kext) doesn't read that table.
  Follow-up: a read-only way to the image, then `vram_info` in `PhxVbios.h`.
- **Clocks and the timestamp clock** (`CLOCKS_DEFAULT`): Linux's values come from SMU DPM tables and the VBIOS, and
  firmware is their only source. The defaults are Mesa's `navi31` entry, a Linux dump of an XTX: sclk 500-2371 MHz,
  mclk 96-1249 MHz, counter 100 MHz.
- **CP firmware versions** (`FW_DEFAULT`): the `ucode_version` header fields of the pinned linux-firmware files
  (`tools/firmware/fw.lock`, `gc_11_0_0_me / pfp / mec.bin`): ME 2420, PFP 2580, MEC 2650, feature 29. Mesa's canned
  values were 1486 / 1525 / 494, and the Linux session on this machine reported 2540 / 2710 / 2790 (newer files).
  Follow-up: the daemon passes the headers of the files it actually loads.
- Still canned in Mesa: the VCN `HW_IP_INFO` version and the VCN firmware version, the plugin's `architecture` string
  (M12), and per-process GPU time (N1).

## 4. VRAM

- The hi pool is `fbSize - 512 MiB fixed regions - 112 MiB top reserve - 256 MiB visible`, which is 23696 MiB on 24 GiB
  (was a fixed 6144 MiB). `kHiTotal` remains only as the fallback when no VRAM size is known.
- Hi BOs that are still system memory (every process outside `debug.phxbo_vram_proc`) are capped together at a quarter
  of the RAM, `max_mem / 4` (8 GiB on 32 GB). Linux TTM allows half, but for pages it can swap; these are wired (finding
  1 of section 7). `vram_hi_free` reports the lower of the two limits.
- Metal's `recommendedMaxWorkingSetSize` is the Vulkan device-local heap on AMD (`nvmtl_vk_working_set`), and RADV
  sizes that heap from the kext's VRAM totals. With b168 it should read about 23.4 GiB instead of 6 GiB (unverified).
  OpenCL's global memory follows the same heap (A11).

## 5. GPU utilization (Activity Monitor)

No firmware message is involved. While the GFX or compute queue has unfenced work, a thread call runs every
`debug.phxgpu_busy_us` (default 2000 us, 0 = off). Each run reads the queues' fences in VRAM and credits the period as
busy when work was outstanding:

- sample and hold, at most 4 periods per sample;
- the sampler stops 250 ms after the last submit, once a sample sees the queues idle.

"phxGpuStats" returns busy time, the sample time and VRAM use. `Device Utilization %` is busy / elapsed since the
previous resetting read (at least 50 ms apart, so two readers share one value).

The other source is the PMFW's own GFX activity in its metrics table, which Linux reads with a
`TransferTableSmu2Dram` message (`smu_cmn_get_metrics_table`, cached for 1 ms; `smu_v13_0_0_get_gpu_metrics`). That
is a firmware message, so it is plan C5's. The design: the kernel sends that one message as Linux does, at most every
100 ms and only while someone reads `PerformanceStatistics`; `Device Utilization %` takes `AverageGfxActivity`; the
sampler stays the fallback when the PMFW is busy or refuses. It is not built.

## 6. Tests (hardware-free)

- `tests/kext/devinfo_test.cpp`, 107 checks. Synthetic discovery tables, made up in the test in the shape Linux's
  `discovery.h` defines (no dump from any machine):
  - every checksum and bounds failure;
  - GC info v1.2 / v2.0 / v2.1;
  - MALL v1 / v2;
  - UMC harvest;
  - SA, RB and TCC harvest;
  - the CU bitmap layout;
  - PCIe;
  - `format`.
- `tests/kext/gpu_stats_test.cpp`, 21 checks: the sampler's hold, cap and stop; utilization and its clamps.
- `tests/kext/gpu_id_test.cpp`: `marketingName`.
- These three run in CI (`.github/workflows/release.yml`).
- Mesa `src/amd/common/darwin/test/acd_devinfo_test.c`, 38 checks (the firmware-version answers too, VCN with and without the kext's record): the mapping keeps the driver's own fields, overlays
  the hardware's, keeps the template's PCIe / VRAM values when the kext has none, never overruns the names buffer, and
  refuses an unusable record.
- The Mesa series applies cleanly to `f5cb8ee0`, and RADV builds.
- `preflight.sh` passed for VermilionBoot b168 (`--opencore`; the link-gate note lists three symbols that fork/main's
  code imports too) and VermilionAccel 0.1.2 (`--auxkc`, all 999 imports exported).

## 7. Hardware-safety review

`hw-safety-reviewer` on the final code, 2026-11-26, against Linux v6.8: **safe to build, nothing unsafe.**

- The only writes are MM_INDEX / MM_INDEX_HI inside the existing `mmIdxRead`, with Linux's values
  (`amdgpu_device_mm_access`). At discovery time Linux uses that window too, because the aperture isn't mapped yet.
- The order (HI first) and the per-dword HI rewrite are latches that take effect only at the MM_DATA read. The helper
  has run on this hardware since b82.
- `RCC_CONFIG_MEMSIZE`, the discovery read (a prefix of Linux's 10 KiB at the same address, bounded by `fbSize`), the
  NBIO strap and the seven GC registers all match the Linux offsets and base indexes. Linux reads each of them in
  hw_init, and none needs a `GRBM_GFX_INDEX` select.
- The kext doesn't copy Linux's `GRBM_CNTL.READ_TIMEOUT` write, which is correct: no write is added.
- GFXOFF is never allowed on macOS (only the root debug selector sends AllowGfxOff), so GFX is powered when the kext
  reads.
- The sampler reads fence words inside BAR0 only. The PCI reads are the b161 gate's, and the link capabilities come
  from registry properties.
- `parse()` can't read outside its buffer, and the kext can't read VRAM outside `[0, fbSize)`.

Fixed after the review (kext b168, same build, not booted):

- The sampler's thread call is allocated with `THREAD_CALL_OPTIONS_ONCE`. A plain call's cancel-wait doesn't wait for
  a running tick when it cancelled a pending one.
- `busyStop` sets the stop flag under `gpuLock` and frees the call only once nothing is pending.
- `vram_bit_width` can't wrap on a malformed half-use mask (test added, 107 checks).

Open, not GPU programming (TODO "Device info follow-ups"):

1. **Medium, memory policy.** Hi BOs of processes not opted in to real VRAM are wired system memory. The global cap
   the review saw, `max_mem / 2`, allowed 16 GiB wired on 32 GB; before b168 it was 6 GiB per client, with no global cap. Linux TTM's 50%
   applies to pages it can swap, so it isn't the same limit. An app that sizes its pools from the ~23 GiB heap could
   put macOS under memory pressure (unverified). **Decided 2026-11-26, and in the code:** `max_mem / 4` (8 GiB on
   32 GB, above the old 6 GiB per client): an app that trusts the working set fails an allocation sooner, which harms one app; memory
   pressure from wired pages harms the whole system.
2. **Low.** The cap check and the counter update aren't one atomic step, so concurrent creates can overshoot the cap
   by their sizes.
3. **Low.** If GFXOFF is ever allowed, the lazy GC register read (from QueryInfo and the sysctl) needs Linux's
   `amdgpu_gfx_off_ctrl` bracket.

## 8. Deploy and owner checks

Deploy order is free: Mesa falls back to the `navi31` entry with a kext before ABI 1.13, and the 192-byte QueryInfo
call is unchanged.

1. VermilionBoot b168 on the EFI partition: one EFI change, with the rollback copy.
2. RADV and the plugin: `PHXTRUST_KEEP=1 sh scripts/build/trust.sh`, VermilionTrust plus EFI, one boot.
3. VermilionAccel 0.1.2: the AuxKC and the Allow click.

After the boot:

- `sysctl debug.phxdevinfo` shows `valid gc-regs`, 6 SE x 2 SA x 8 CU = 96, 24 RBs, 24 TCC, 384-bit, MALL 96 MiB,
  PCIe 4 x16 (or what the slot gives), name "AMD Radeon RX 7900 XTX".
- `log show --predicate 'eventMessage CONTAINS "radv-darwin: device info"' --last 5m` should say how many values
  differ from Mesa's entry. Expected: few or none, since Mesa's `navi31` entry is a Linux dump of an XTX.
- `ioreg -rc NMXAccel -k PerformanceStatistics` shows `Device Utilization %` rising under load, and `vramFreeBytes`.
- About This Mac and a Metal tool show "AMD Radeon RX 7900 XTX", with a working set of about 23 GiB.
- Activity Monitor's GPU History moves.

## 9. Unverified

Everything above on hardware:

- the discovery read and parse on the XTX machine;
- the register values;
- the pool size;
- the sampler's overhead and accuracy;
- the Activity Monitor display;
- RADV with the kext's record.

The sampler's cost (a 2 ms thread call only while work is queued) has not been measured.
