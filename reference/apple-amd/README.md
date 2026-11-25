<!-- SPDX-License-Identifier: MIT -->

# Apple's AMD driver stack (RDNA 2), as a reference implementation

Reverse-engineered on the XTX machine (macOS 26.7.1 25G241), read-only, 2026-11-25. The owner's release decision
(`.agents/decisions.md`, "Release decisions (owner, 2026-11-25 evening)") makes Apple's own AMD stack the reference for
Vermilion and allows reusing Apple's code. The pseudo-code excerpts here were condensed from Ghidra output. They
explain behaviour; they are not compilable source.

This follows [#33's comparison](../../.agents/findings/2026-11-25-apple-amd-comparison.md), which covered only what
Apple publishes (plists, ioreg). These files cover how Apple's code does it.

## Files

| File | Covers |
|---|---|
| [01-bringup.md](01-bringup.md) | Classes, IOKit personalities, the match chain, `start()` order, the SWIP IP init order (PSP, SMU, GC, SDMA, MES, VCN, DMCU), firmware |
| [02-display.md](02-display.md) | Framebuffer and controller: AMD DC inside the kext, controller power-up, mode set, link training, hotplug, DPMS, gamma, HDR, VRR, DDC/AUX, AGDC |
| [03-accelerator.md](03-accelerator.md) | IOAccelerator subclass, user clients, command submission, memory (VRAM/GART/VM), timeouts and hang recovery, PerformanceStatistics |
| [04-power-audio-video.md](04-power-audio-video.md) | PowerPlay, AGPM and the power service, DP/HDMI audio, VCN decode/encode and the GVA keys |
| [05-metal-plugin.md](05-metal-plugin.md) | The Metal/GL user-space drivers and what they call in the kernel |
| [06-vermilion-map.md](06-vermilion-map.md) | Apple function → what Vermilion has or lacks, per STATUS row and PLAN-parity-week item; the top items to adopt |
| [tools/](tools/) | The extraction and annotation scripts (reproduce below) |

## Binaries analysed

On disk the kexts and bundles are `Info.plist` stubs. The code is in `SystemKernelExtensions.kc` (kexts) and the
dyld shared cache (bundles). Extracted with `ipsw` 3.1.750 into a scratch folder outside git.

| Binary | From | SHA-256 (first 16) | C++ symbols |
|---|---|---|---|
| `com.apple.kext.AMDRadeonX6000` (accelerator) | System KC | `c917d7b58f9587eb` | yes |
| `com.apple.kext.AMDRadeonX6000Framebuffer` (controller, FB, AMD DC) | System KC | `be56977ca7bc4270` | C++ glue only; DC is unnamed C |
| `com.apple.kext.AMDRadeonX6000HWServices` | System KC | `f32b9eeff55c0c4d` | yes |
| `com.apple.kext.AMDRadeonX6800HWLibs` (Navi 21 SWIP, PowerPlay, firmware) | System KC | `7a929820292cb83b` | yes (C names) |
| `com.apple.kext.AMDRadeonX6810HWLibs` (Navi 23) | System KC | `2f0ac4498e65d861` | yes (not decompiled) |
| `com.apple.kext.AMDSupport` | System KC | `703adee9c8fed572` | yes |
| `com.apple.kext.AMDFramebuffer`, `AMD10000Controller` (pre-Navi), `AMDRadeonServiceManager` | System KC | see tools | yes |
| `com.apple.driver.AGPM`, `com.apple.driver.AppleGFXHDA`, `com.apple.iokit.IOAcceleratorFamily2` | System KC | see tools | yes |
| `AMDRadeonX6000MTLDriver`, `AMDRadeonX6000Shared`, `AMDShared`, `AMDRadeonVADriver2`, `AppleGVA` | dyld cache | see tools | yes |

Not on this system: `AMDRadeonX6000GLDriver`'s main binary (only `ATIRadeonX6000SCLib.dylib` is in the cache) and
an AMD VideoToolbox encoder bundle separate from `AMDRadeonVADriver2`.

## Confidence tags

Every claim carries one:

- **[O]**: observed in the decompiled code, a string, a symbol or a plist of the binaries above. High confidence for
  what the code does. It is not proof that a path runs on a real RDNA 2 Mac: static analysis only, nothing ran.
- **[I]**: inferred from names, call order or AMD's public Linux code. Medium confidence.
- **[?]**: open. Not established.

Nothing here was seen running: there is no RDNA 2 GPU in this machine, and Apple's X6000 kexts don't load on it. (On
the XTX machine only `AMDSupport` is loaded.)

## Reproduce

All read-only. Scripts in [tools/](tools/) (MIT, ours). They read the work folder from `REA_WORK` (it holds `kc/`,
`dsc/`, `syms/` and `decomp/`); the commands below run inside it.

1. `ipsw kernel extract <SystemKernelExtensions.kc> <bundle-id> --imports -o kc/` for each kext above;
   `ipsw kernel extract <BootKernelExtensions.kc> com.apple.kernel -o bootkc/` for xnu's symbols.
2. `ipsw dyld extract <dyld_shared_cache_x86_64h> <image> -o dsc/` for the bundles.
3. `nm --defined-only -n <bin> | c++filt > syms/<bin>.txt` per binary and for the kernel (`syms/kernel.txt`).
4. REA `open_binary` + `decompile_all` (Ghidra 12.2) per binary into `decomp/<name>/`; `tools/mkidx.py` writes the
   name index.
5. `tools/vtables.py <bin>` decodes every `vtable for X` (KC chained fixups: low 30 bits are the target, bits 30-31
   the collection; boot-KC targets are `target + 0xffffff8000100000`). `tools/ann.py` then names virtual calls on
   `this` and, with `FAM=<class family>`, on member objects whose type it infers from `X::createX` assignments.
6. `tools/flow.sh <decomp> <regex> <class>` prints a function's call flow; `tools/srch.py <regex>` finds functions;
   `tools/show.sh` prints a function's decompiled text, `tools/vt.sh` the method at a vtable offset, `tools/rd.py`
   qwords of a binary with the fixups decoded.

The decompiled output, the extracted binaries and the firmware blobs inside HWLibs stay outside git (hard rule 4:
no AMD firmware in the repo).

## Not covered yet

- The Metal and GL drivers were read by symbols and imports only (not decompiled): the Metal feature answers of
  `AMDMTLGFX10Device` (A3 / N5), MPS / Tensile tables, the counter plug-in `AMDRawCounterPlugin`.
- DC itself (unnamed C in the framebuffer kext) was identified by its source paths, not walked function by function:
  link-training policy, DSC, PSR and MST details are taken to be AMD's public DC behaviour [I].
- The unnamed TTL suspend/resume entries and the exact SWIP stage meanings (stages 2-8).
- `AMDRadeonX6000HWLibs` (the default `Load6000` plug-in a PC card would get) and X6810HWLibs (Navi 23) were not
  decompiled; only X6800 (Navi 21).
- Pre-Navi `AMD10000Controller` / `AMDFramebuffer` / `AMDSupport` display code (Vega and older), the HDCP stacks,
  `AMDRadeonServiceManager` internals, `AMDShared` / `AMDRadeonX6000Shared` (compiler runtime).
- Anything at run time: there is no RDNA 2 GPU here.
