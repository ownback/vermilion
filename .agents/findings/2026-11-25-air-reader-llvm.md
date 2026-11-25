<!-- SPDX-License-Identifier: MIT -->

# The AIR reader built by this project (R1)

2026-11-25. Release-readiness row 11 / R1. Seen on the XTX machine (x86_64, macOS 26.7.1), nothing installed.

## What the plugin needs from `air-runtime/libLLVM.dylib`

- Loaded by `NVMTLLibraryLoad.m` with `dlopen(<MacOS dir>/air-runtime/libLLVM.dylib)`, then 38 LLVM C API symbols by
  `dlsym` (Core, BitReader `LLVMParseBitcodeInContext2`, `LLVMPrintModuleToString`, the new-PM `LLVMRunPasses` and
  pass-builder options, the IR walk of the byte-GEP retype). The translator (Rust) does not link LLVM: it reads the
  IR text the plugin prints. `air-opt` is only the out-of-process fallback when the reader is missing or rejects a blob.
- NullMoth's copy, read from the machine: Homebrew LLVM 21.1.8 (`strings`: "Homebrew LLVM version 21.1.8"), x86_64,
  139 MB, all targets, install name `@loader_path/libLLVM.dylib`, minos 14.0, depends on `@loader_path/libzstd.1.dylib`
  (zstd 1.5.7), system libz, libxml2, libedit, libffi, libc++.
- Ours (`scripts/build/llvm.sh`): LLVM 21.1.8 and zstd 1.5.7 from the release tarballs (SHA-256 pinned), shared libLLVM
  with the X86 target only, no tools, no libxml2/libedit/libffi, system libz from the SDK, same install names, minos
  14.0. 56 MB. It depends on the system libraries and `@loader_path/libzstd.1.dylib` only (the script fails otherwise).

## Equivalence (this Mac, nothing installed)

Harness: the plugin's in-memory read (`nvmtl_air_in_memory`: parse the `0x0B17C0DE` wrapper, the unroll pipeline for
`air.simdgroup_matrix_8x8` modules, print) over every metallib under `/System/Library` and `/Applications` larger than
8 KB (317 files), once per dylib; then the installed `libnvmtl_translate.dylib` on every 25th blob that has a stage.

- 70,053 bitcode blobs (111 of them through the unroll pipeline): the printed IR is byte-identical (SHA-256 per blob
  equal, length equal).
- 1,093 blobs translated: 818 SPIR-V modules and 275 translator errors (the same errors on both sides), identical
  SHA-256 each.
- Not exercised: the plugin's byte-GEP retype code after the unroll pass (the 22 symbols it needs are exported, checked
  by the script), and a live Metal app against the installed dylib (needs an install and a boot).

Reproducibility, bit for bit across two builds of the script, is (unverified).
