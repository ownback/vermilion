# Glossary

The terms used across the code, the docs and the changelog. AMD block names follow Linux amdgpu.

## AMD GPU blocks

| Term | Meaning |
|---|---|
| **Navi 31** | The RDNA 3 GPU die in the RX 7900 XTX, XT and GRE (PCI device `0x744c`). The PCI revision tells the boards apart: `0xC8` XTX, `0xCC` XT, `0xCE` GRE, `0xCF` 7900M. Vermilion starts only on `0xC8` |
| **GC 11.0.0** | Graphics core IP version of Navi 31. The firmware files are named after it (`gc_11_0_0_*.bin`) |
| **SE / SA / WGP / CU** | Shader engine, shader array, workgroup processor, compute unit. Navi 31 has 6 SE x 2 SA. The XTX has all 96 CUs enabled; the XT has 84 (one WGP disabled per SE) |
| **Harvest** | Units fused off at the factory (the XT's missing WGPs and cache channels) |
| **PSP** (MP0 13.0.0) | Platform Security Processor. It loads and authenticates every other firmware. The bring-up talks to it through a ring in VRAM |
| **sOS / TOC / TMR** | PSP secure OS; table of contents of a firmware bundle; Trusted Memory Region (VRAM the PSP reserves, 0x1300000 bytes on Navi 31) |
| **SMU / PMFW** (MP1 13.0.0) | System Management Unit and its firmware: clocks, voltages, power, fans, temperature limits. The PPTable (power table) comes from the card's VBIOS |
| **RLC** | Run List Controller: GFX power and clock gating, context save/restore |
| **IMU** | Starts the RLC on GC 11 at power-up |
| **CP / ME / PFP / MEC** | Command processor (gfx micro engine, pre-fetch parser, compute micro engine). RS64 is GC 11's CP core |
| **MES / KIQ** | Micro Engine Scheduler (hardware queue scheduler) and Kernel Interface Queue (driver-to-CP control queue). Set up by `mesboot` |
| **SDMA** | System DMA engines (copies). Must idle for clock gating |
| **GART / GPUVM / VMID** | GPU page tables. Vermilion uses VMID 8 for user work |
| **GFXHUB / MMHUB** | Memory hubs of the GFX block and of the other clients (display, VCN). `SYSTEM_APERTURE` is the VRAM window in MC address space |
| **MC address** | The GPU's internal address of VRAM. Navi 31's VRAM starts at `0x80_0000_0000` |
| **UMC / MCD** | Memory controller channel / memory cache die. XTX: 6 MCDs, 384-bit, 96 MB Infinity Cache. XT: 5 MCDs, 320-bit, 80 MB |
| **MALL** | Memory-attached last-level cache (Infinity Cache) |
| **TCC / GL2** | Level-2 cache channels. The XT disables 4 of 24 (`tcc_disabled_mask 0xc03`) |
| **VCN 4.0.0** | Video codec engine (HEVC/AV1 decode) |
| **GB_ADDR_CONFIG** | Register describing the memory tiling layout, needed by RADV. `0x545` on both XT and XTX |
| **BACO / Mode1 / FLR** | GPU reset types: bus-active-chip-off, full ASIC reset, PCIe function-level reset. They matter for VFIO |
| **Kicker firmware** | Alternative firmware for some board revisions (`*_kicker.bin`). Neither the XT (`0xCC`) nor the XTX (`0xC8`) uses it |

## Display (DCN 3.2)

| Term | Meaning |
|---|---|
| **DCN** | Display Core Next, the display engine. 3.2 on Navi 31 |
| **OTG** | Output timing generator: one per active display; holds the H/V totals, sync and blank of a mode |
| **HUBP / DCHUBBUB** | Display hub pipe (fetches the framebuffer from memory) and the hub that arbitrates them |
| **DET / COMPBUF** | Display engine buffer split between pipes; compressed buffer |
| **Watermarks (A-D)** | Latency deadlines for memory requests; wrong values cause underflow (flicker, black lines) |
| **DLG / TTU** | HUBP request scheduling parameters (delivery per line, time-to-urgent) |
| **DML** | Linux's Display Mode Library, which computes watermarks/DLG/DET. Vermilion has no DML: it replays captured values |
| **DIG / PHY** | Digital encoder and physical transmitter per connector. Reference board: DP A=DIG0, DP B=DIG1, HDMI D=DIG3, DP E=DIG4 |
| **DMUB / DMCUB** | Display microcontroller and its firmware. The kext talks to it through a ring (`PhxDmub.h`). Vermilion expects the GOP's DMCUB version `0x07008742` |
| **DAL** | Display abstraction layer messages from the driver to the SMU (display clocks, watermark tables) |
| **DENTIST / DTO / DISPCLK / DPPCLK** | Display clock dividers and the pixel-clock generator |
| **AUX / DPCD / EDID / E-DDC** | DP sideband channel; DP configuration registers on the monitor; monitor identity and modes; the I2C segment pointer needed to read EDID blocks above 1 |
| **HBR / HBR2 / HBR3 / DSC** | DP link rates of 2.7 / 5.4 / 8.1 Gbit/s per lane; Display Stream Compression |
| **HPD** | Hot-plug detect |
| **Plan** | Vermilion's captured register list for one mode (`phx_*_plan_*.inc`) |
| **Pipe 0 / pipe 2 / head** | Vermilion's pipes: pipe 0 is the GOP-lit monitor; the second-monitor engine uses a further pipe. A "head" is one macOS framebuffer (`PhxAMDFB` instance) |

## macOS and boot

| Term | Meaning |
|---|---|
| **GOP** | The UEFI Graphics Output Protocol driver in the card's VBIOS. It lights one monitor at power-on. "GOP boot" = macOS stays on that firmware framebuffer |
| **Squat boot** | A boot with NVRAM `phxfb-squat` set: `PhxFBSquatter` keeps macOS's generic framebuffer driver off, so Vermilion's framebuffer is the only one |
| **Desktop arm** | The daemon path that moves WindowServer onto the GPU (one restart) |
| **AuxKC** | Auxiliary Kernel Collection: where third-party kexts from `/Library/Extensions` are linked; needs approval once |
| **AMFI / AMFIPass** | Apple Mobile File Integrity, and the Lilu plugin that lets `amfi=0x80` work on modern macOS |
| **SIP / `csr-active-config`** | System Integrity Protection and its OpenCore NVRAM setting |
| **IOAccelerator / IOFramebuffer** | The IOKit families WindowServer uses for GPU work and displays |
| **AGDC** | Apple Graphics Device Control |
| **Metal plugin / GPUBundle** | A vendor's Metal driver bundle under `/Library/GPUBundles` |
| **AIR / SPIR-V** | Apple's shader IR inside `.metallib`; Vulkan's shader IR |
| **N48N** | The user-client connection type RADV opens (name inherited from Cobalt64's Navi 48 work) |
| **OpenCore / OC** | The bootloader that boots macOS on PC hardware, injects kexts and patches ACPI and the kernel |
| **AMD_Vanilla** | OpenCore kernel patches that make macOS run on AMD CPUs |
| **SMBIOS** | The Mac model identity OpenCore presents (MacPro7,1 here). Serials must be generated per machine and never shared |

## Project words

| Term | Meaning |
|---|---|
| **Reference machine** | The box a value was measured on. Upstream: leolivm's RX 7900 XT (not supported here). This fork: the XTX machine in [REFERENCE-MACHINES.md](REFERENCE-MACHINES.md) |
| **Canned profile** | RADV's hardcoded device description (`patches/mesa/0016`) used instead of Linux's hardware queries |
| **Flag file** | A file in `~/gpu` that switches a daemon step on ([INSTALL.md](INSTALL.md) section 7.3) |
| **`b15`, `m7`, `wm144`, `c3`...** | Internal work-package names from upstream's history; the changelog and the scripts' headers explain each |
