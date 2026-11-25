<!-- SPDX-License-Identifier: MIT -->

# Maps: the kext's 4095 BO handles per process, not VRAM (Phase 2 item 2, 2026-11-25)

Apple Maps still crashed on the XTX machine (macOS 26.7.1 25G241) after #25 (NVMTLDriver cdhash `15204728`, live since
the boot of 2026-11-25 17:04). This finding says where the allocation failures come from and what the fix on
`ownback/maps-alloc-limit` changes. Sources: the unified log of `org.vermilion.nvmtl` since 17:04, the Maps process log
of 17:13-17:14 and `Maps-2026-11-25-171401.ips`. They are saved outside git (they hold the owner's location data).
One read-only `sysctl debug.phxvm` was run on the same boot. No app was opened, nothing was installed.

## 1. What failed, in order

Maps' log at 17:13:40.297 to .730 (thread `81c1`, the main thread):

1. `radv-darwin: Maps bo create failed: handle 0 size 4096 ... -> -12`, 64 times in 5 ms.
2. Between them: `vk: private buffer of 96 bytes REFUSED VRAM (RM refused it) -> -2: 6144 MB free, 1024 MB headroom,
   heapUsage 0 of budget 6144 MB (measured), 7625 buffers live`, then `newBufferWithLength:96 private: VRAM refused -
   placing it in system memory`. Eight of these (4 to 128 B). The buffers in system memory were made: their memory is
   a range in an existing Shared pool block, so it needed no new BO.
3. `visibility: query allocation failed at offset 2064 - pass refused` (8 render passes).
4. `buffer park: VRAM wall refused - drained 32 parked Private buffers`.
5. `vk: colour image: VRAM full and no system-memory type takes it (bits 0x7ad) -> -2`, then `texture nil:
   newTextureWithDescriptor: in Maps: image create FAILED (Vulkan format 37, storage 0) | type 2 format 70 256x256x1
   ... storage 2`. Both the VRAM and the system-memory allocation of the image needed a new BO.
6. VectorKit: `Metal returned null texture.` (fault), the abort in the `.ips`.

`sysctl debug.phxvm` on the same boot, afterwards:

```
BO create refused: vis 0 hi 0 gtt 0 handles 2469 pages 0; ...
last: pid <Maps> Maps: 256 KiB domains 0x2 flags 0xc5 cause 3 (client vis 141/256 MiB, hi 0 MiB, gtt 128 MiB, BOs 4095)
```

`cause 3` with `BOs 4095`: the handle table was full. 2469 creates were refused for that reason in this boot. The
last one was the image's 256 KiB system-memory BO (domain 2 = GTT). No budget was full (`vis 141/256`, `gtt 128 MiB`).

## 2. Where -12 and -2 come from

- **The kext** (`src/vermilion-boot/phx_client.cpp`, `doBoCreate`): every client has `bos[PHXN_MAX_BOS]`, with
  `PHXN_MAX_BOS` = 4096 (`PhxNativeABI.h`), so handles run from 1 to 4095. When no handle is free:
  `boRefused(3, ...)`, which returns `kIOReturnNoResources`. Next to it, `maps[kMaxMaps]` (`phx_globals.cpp`,
  4096) holds the client's GPU VA maps, one per mapped BO, so that table fills at the same count. A freed BO keeps its
  handle until the GPU retired the client's last submission (b52's deferred free, `reap()`).
- **RADV's Darwin backend** (`patches/mesa`, `ac_darwin_kext.c`): `acd_kr_to_errno` maps `kIOReturnNoResources`
  and `kIOReturnNoMemory` to `-ENOMEM` (-12), and `acd_bo_alloc` logs `bo create failed` (its "handle 0" is the
  handle not yet assigned). RADV returns `VK_ERROR_OUT_OF_DEVICE_MEMORY` (-2) from `vkAllocateMemory`.
- **The plugin** (`src/metal-plugin/nvmtl_vk.c`): `nvmtl_vk_buffer_create_body` gave every device-local buffer
  (`host_visible` 0) its own `VkDeviceMemory`, so its own BO. Only Shared buffers were sub-allocated (the 32 MiB
  system-RAM pool and the BAR1 pool). "RM refused it" and "VRAM full" in the log lines meant only "the allocation
  returned -2".

## 3. What held the handles: Managed buffers, not a leak

The buffers Maps makes are `storage 1`, **Managed**: `newBufferWithLength:96 storage 1 -> ... VRAM` (96, 128, 768,
512, 798, 4, 12 B are the logged sizes). A Managed buffer is two plugin buffers: the VRAM copy (`host_visible` 0, its
own BO) and the CPU shadow (a range in the Shared pool). The plugin's census lines (Maps, 17:12:49 to 17:13:34):

| time | made | gone | live | pooled live |
|---|---|---|---|---|
| 17:12:49 | 4096 | 627 | 3469 | 1748 |
| 17:13:05 | 12288 | 8336 | 3952 | 1996 |
| 17:13:15 | 16384 | 13018 | 3366 | 1703 |
| 17:13:29 | 20480 | 19463 | 1017 | 525 |
| 17:13:31 | 36864 | 35454 | 1410 | 720 |
| 17:13:34 | 57344 | 54973 | 2371 | 1176 |
| 17:13:40 | | | 7625 (REFUSED line) | |

About half the live buffers are pooled (the shadows) and half have their own BO (the VRAM copies). The live count
goes up and down: it fell from 3952 to 1017 and rose again while the owner panned and zoomed. Maps made about 65000
buffers in 54 s and released almost all of them. That is churn during a gesture, not a leak in the plugin's counters.
At 17:13:40, 7625 live buffers are about 3800 Managed buffers, so about 3800 BOs, plus images, RADV's own BOs and the
pool blocks: 4095. Whether VectorKit would have released them again later is not known (the crash came first).

## 4. What a Mac does, and the fix

A Mac's Metal doesn't fail a 96-byte buffer or a 256 KiB texture while gigabytes are free (the standard; not
measured on a Mac here). The fix places small buffers inside larger GPU allocations, so the kext's object count no
longer grows with each one. The plugin already did this for Shared buffers. On the branch it does it for the
device-local ones too:

- **The Private pool** (`nvmtl_vk.c`, `pool_buffer_create_in(NVMTL_POOL_PRIVATE, ...)`): Private buffers and Managed
  VRAM copies up to 256 KiB (`NVMTL_PPOOL_MAX`) get a range in a 4 MiB device-local block (`NVMTL_PPOOL_BLOCK`),
  placed with `vkBindBufferMemory` at an offset, as the Shared pool does. One block is one BO and one VA map. The same
  memory type as the dedicated path (`memtype(bits, DEVICE_LOCAL)`), the same budget charge. The block allocation
  passes `nvmtl_vk_vram_wall0` first. If the pool can't place it (the wall, or RADV refuses the block), the buffer takes
  the old dedicated path, and from there the old system-memory fallback. Larger buffers keep their own memory (res3's
  stable address starts at 1 MiB). `NVMTL_PRIVATE_POOL=0` turns the pool off.
- **Held ranges:** a dedicated BO's free waited in the kext until the GPU retired the client's work. A pool range is
  plugin memory, so the plugin now keeps the same guarantee itself. Submissions of `nvmtl_vk_submit_begin_at` get a
  number in queue order, and `nvmtl_vk_submit_finish` records the highest finished one. A fence signal on a queue
  covers every earlier submission there. A Private range released while work is in flight waits in a FIFO
  (`nvmtl_range_fifo`) until that work is done, and only then goes back to its block. Its block can't be freed
  meanwhile (the held range counts as live).
- **Block reset:** a block whose last range came back kept its fragments when that range merged into a freed neighbour
  (`pool_block_give` returned before the reset). Now an empty block always starts over. This affects the Shared pools
  too.
- **Wording:** the image failure line now says that the kext's BO handles may be the cause, and names
  `debug.phxvm`.

The allocator moved to `src/metal-plugin/nvmtl_pool_range.h` (refactor commit, no behaviour change), so it can be
tested without a GPU.

## 5. Tests

- `tests/plugin/test_pool_range.c` (host, no GPU): ranges never overlap and stay in the block over 200000 Maps-like
  steps. An emptied block starts over. The FIFO returns a range only once its submission is done, oldest first. Maps'
  churn (sizes 4 to 798 B, up to 7632 live, the GPU 3 submissions behind) needs **7632 BOs the old way and 1 pool
  block now**.
- The four existing plugin tests pass against the branch build (`test_copy_compat`, `test_safe_copy`,
  `test_dead_cmdbuf`, `test_texture_nil_log`).
- `tests/plugin/test_private_pool_gpu.m` (**on the GPU, after the deploy**, with the owner's OK): 12000 live Managed
  buffers of 96 B and 4000 Private ones of 128 B through `MTLCreateSystemDefaultDevice`, then a 256x256 Private texture
  (nil before the fix), blits that check each pooled buffer keeps its own bytes, and a second round that checks reused
  ranges read as zeros.

The plugin builds with `scripts/build/plugin.sh` with the same 329 warnings as main. Main's build reproduces the
installed binary exactly (cdhash `15204728`), so the branch's build is reproducible: **cdhash `06fd1ac9`** (UUID
`F2CEDBC0`).

## 6. What stays open

- The kext's limit itself stays: 4095 BOs and 4096 VA maps per process. Every image, every buffer over 256 KiB and
  every RADV-internal BO still takes one. A process with more than ~4000 live textures (a game, a large photo grid)
  will hit it as Maps did. A Mac has no such limit in this range. Two ways, not decided: place small images in pooled
  heaps in the plugin as for buffers, or make the kext's tables grow (the `bos` and `maps` arrays and their linear
  scans in `doBoCreate`, `reap`, `settleOverlaps`; RADV's `bos[N48N_MAX_BOS]` and its `>= N48N_MAX_BOS` check, so an
  ABI minor). The kext way touches the GPU VM map table: it goes through `hw-safety-reviewer`. TODO item under "Staged now".
- The Shared pool releases a range at once, with no hold (unchanged). Metal requires the app to keep a buffer alive
  until the GPU is done with it (retained references do this for it). The hold above covers apps that break that rule
  with unretained references, for Private memory only.
- (unverified) Everything in section 4 on hardware: Maps on the new plugin, the GPU test, the BO count in
  `debug.phxvm` during Maps.
