# Building Vermilion

All builds are x86_64 and run on macOS with the Command Line Tools (`xcrun clang`). The scripts in
[`../scripts/build`](../scripts/build) take every outside path from the environment and write to `build/`
(`VERMILION_OUT` to change it); none of them knows a user name, host or home directory. Every compile line carries
`-ffile-prefix-map` / `-fdebug-prefix-map` for the checkout and `$HOME`, and each script fails if a binary still names
either (`homecheck` in `scripts/build/lib.sh`).

Dependencies may sit in `deps/`, which git ignores: `deps/MacKernelSDK` (pass it as `MKSDK`), `deps/Vulkan-Headers` and `deps/ffmpeg-lib/prefix`.

| Script | Builds | Needs |
|---|---|---|
| `kext.sh` | `VermilionBoot.kext` | `MKSDK` (https://github.com/acidanthera/MacKernelSDK), the firmware of [FIRMWARE.md](FIRMWARE.md) (`PHX_FW`, default `~/gpu/fw/navi31`) for the generated `phx_c3_hash.inc` (hashes of the C3 slice; no firmware in the kext) |
| `accel.sh` | `VermilionAccel.kext` (ad-hoc signed) | `MKSDK`; optional link gate with export lists from `linkgate_exports.sh` (needs `ipsw` and the target's KernelCollections) |
| `plugin.sh` | `NVMTLDriver` (Metal plugin, ad-hoc signed) | `VULKAN_HEADERS` (Vulkan-Headers include dir) |
| `translator.sh` | `libnvmtl_translate.dylib` (shader translator, x86_64, ad-hoc signed) | Rust 1.87+ (`cargo`) with the `x86_64-apple-darwin` target; network for the first crate fetch (or `CARGO_NET_OFFLINE=true` with a filled cache); `TRANSLATOR_TEST=1` runs the wrapper tests ([`../src/translator/README.md`](../src/translator/README.md)) |
| `radv.sh apply` / `radv.sh` | `libvulkan_radeon.dylib` (`RADV_PLATFORMS=macos`: the app-facing build with the Metal window surface, patch 0020, in its own build dir) | `MESA_DIR` = Mesa checkout at f5cb8ee0; meson, ninja, glslangValidator, python3 with mako, pyyaml, markupsafe, packaging |
| `llvm.sh` | `build/air-runtime/` (`libLLVM.dylib`, `libzstd.1.dylib`, `MD5SUMS`, `LICENSES/`): the plugin's AIR bitcode reader, LLVM 21.1.8 + zstd 1.5.7 from the pinned release tarballs (x86_64, macOS 14 minimum) | `cmake`, `ninja`, `python3`, the Command Line Tools, about 12 GB of disk, 30 to 90 minutes; network for the two tarballs. Installed with `tools/phxctl/air_runtime_install.sh`; CI: `.github/workflows/air-reader.yml` |
| `ffmpeg.sh` | `libavcodec_phx.61.dylib`, `libavutil_phx.59.dylib` into `FFMPEG_PREFIX` (default `deps/ffmpeg-lib/prefix`) | network for the first clone (FFmpeg n7.1), `VULKAN_HEADERS` |
| `phxdec.sh` | `libphxdec_hevc.dylib` | `FFMPEG_PREFIX` = FFmpeg n7.1 + `patches/ffmpeg` built as shared `libavcodec_phx` / `libavutil_phx` (LGPL, no GPL parts); `VULKAN_HEADERS` |
| `audio.sh` | `VermilionAudio.kext` (a Lilu plugin: DP audio through Apple's AppleGFXHDA) | `MKSDK`; the Lilu SDK from Lilu's DEBUG release (fetched and checked by sha256, or `LILU_SDK`); the same optional link gate as `accel.sh` |
| `tools.sh` | `phxctl`, `mesboot`, `vcn_write_test`, `submit_test`, `phxaudio` | - |
| `spirv-val.sh` | `spirv-val` (static, x86_64, ad-hoc signed) and `spirv-val.LICENSE`, from SPIRV-Tools v2025.5 at a pinned commit (the translator runs it; the release package installs it) | `git`, `cmake`, `ninja`, the Command Line Tools; a few minutes, network for the two checkouts |
| `metaltest.sh` | `metaltest` (the boot daemon's Metal-device probe, `tools/metaltest/metaltest.m`) | - |

The release files (OpenCore zip, package, `SHA256SUMS`) are made from these outputs by `scripts/release/`
([RELEASE.md](RELEASE.md), "Building a release"); their tests are `bash tests/release/run.sh`.

Plugins, dylibs and kexts must be ad-hoc signed (`codesign -fs -`): WindowServer falls back to the firmware
framebuffer with an unsigned plugin. The scripts do it.

## Tests (no hardware)

```sh
bash tests/mock/run.sh            # boot daemon (tools/phxctl/phxboot-navi31.sh)
bash tests/mock/b15test.sh        # display power recipe and watchdog (tools/phxctl/b15_boot.sh)
bash tests/mock/m7test.sh         # second monitor at boot (m7_boot.sh, m7_phase.sh)
bash tests/mock/dettest.sh        # det.sh
bash tests/mock/bringup_warm_test.sh   # bringup_navi31.sh refuses a warm GPU
bash tests/mock/audio_match_test.sh   # audio_match.sh (one AppleGFXHDA attach per boot, no detach)
bash tests/mock/phxctl_serve_test.sh
```
The mutation runners (`*_mut.sh`, `hotplug0_mut.py`) check that the suites catch broken variants; see
[`../tests/mock/README.md`](../tests/mock/README.md). `p0prefetch_test.sh` needs a register dump of the target
(`P0PF_DUMP`) and is skipped without one.
