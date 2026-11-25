#!/bin/sh
# SPDX-License-Identifier: MIT
# llvm.sh: the AIR bitcode reader the Metal plugin dlopens (NVMTLDriver.bundle/Contents/MacOS/air-runtime/libLLVM.dylib,
# src/metal-plugin/NVMTLLibraryLoad.m) and the zstd it links, built from the release source of LLVM 21.1.8
# (Apache-2.0 WITH LLVM-exception) and zstd 1.5.7 (BSD-3-Clause, dual GPL-2.0), x86_64, macOS 14.0 minimum.
# -> $VERMILION_OUT/air-runtime/{libLLVM.dylib,libzstd.1.dylib,MD5SUMS,LICENSES/}
# The plugin uses only LLVM's C API (Core, BitReader, the new-PM pass builder), so the build is a shared libLLVM with
# the X86 target (the AIR module has its own triple; the plugin passes no target machine), no tools, tests, docs,
# libxml2, libedit or libffi. Install names are @loader_path/..., so both libraries work from the folder they are
# copied into, like the copy NullMoth's bundle carries (Homebrew LLVM 21.1.8: same version, same install-name scheme).
# Both source tarballs are pinned by SHA-256 below (they match the digests GitHub shows for the releases).
#   LLVM_DL     download dir (default $VERMILION_OUT/llvm-dl); LLVM_WORK build dir (default $VERMILION_OUT/llvm-work)
#   LLVM_JOBS   parallel jobs (default: all cores); LLVM_LAUNCHER a compiler launcher such as ccache (CI)
# Needs cmake (>= 3.20), ninja, python3, the Command Line Tools; about 12 GB of disk and 30 to 90 minutes.
. "$(dirname "$0")/lib.sh"
LLVM_VER=21.1.8
LLVM_SHA256=4633a23617fa31a3ea51242586ea7fb1da7140e426bd62fc164261fe036aa142
LLVM_URL=https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VER/llvm-project-$LLVM_VER.src.tar.xz
ZSTD_VER=1.5.7
ZSTD_SHA256=eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3
ZSTD_URL=https://github.com/facebook/zstd/releases/download/v$ZSTD_VER/zstd-$ZSTD_VER.tar.gz
MINOS=14.0
DL=${LLVM_DL:-$OUT/llvm-dl}
W=${LLVM_WORK:-$OUT/llvm-work}
JOBS=${LLVM_JOBS:-$(sysctl -n hw.ncpu)}
for t in cmake ninja python3 xcrun; do command -v "$t" >/dev/null 2>&1 || { echo "llvm.sh: $t not found" >&2; exit 1; }; done
mkdir -p "$DL" "$W"
DL=$(cd "$DL" && pwd); W=$(cd "$W" && pwd)
sha256of() { shasum -a 256 "$1" | cut -d' ' -f1; }
fetch() { # fetch <url> <sha256> -> $DL/<file>, verified
  f=$DL/${1##*/}
  [ -f "$f" ] && [ "$(sha256of "$f")" = "$2" ] || { rm -f "$f"; curl -fsSL -o "$f" "$1"; }
  [ "$(sha256of "$f")" = "$2" ] || { echo "llvm.sh: $f does not match its pinned SHA-256" >&2; rm -f "$f"; exit 1; }
}
fetch "$ZSTD_URL" "$ZSTD_SHA256"
fetch "$LLVM_URL" "$LLVM_SHA256"
ZSRC=$W/zstd-$ZSTD_VER; LSRC=$W/llvm-project-$LLVM_VER.src
[ -f "$ZSRC/LICENSE" ] || { rm -rf "$ZSRC"; tar -xzf "$DL/zstd-$ZSTD_VER.tar.gz" -C "$W"; }
[ -f "$LSRC/llvm/LICENSE.TXT" ] || { rm -rf "$LSRC"; tar -xJf "$DL/llvm-project-$LLVM_VER.src.tar.xz" -C "$W"; }

# Reproducible: no build or home path in the binaries. The SDK is the active one; only the minimum macOS is pinned.
SDK=$(xcrun --sdk macosx --show-sdk-path)   # zlib from the SDK, never a MacPorts or Homebrew copy that the user may not have
MAPS="-ffile-prefix-map=$HOME=/build -fdebug-prefix-map=$HOME=/build -ffile-prefix-map=$W=/llvm-build -fdebug-prefix-map=$W=/llvm-build"   # the last matching map wins: widest first
COMMON="-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MINOS"
STAGE=$W/air-runtime
rm -rf "$STAGE"; mkdir -p "$STAGE/LICENSES"

# 1. zstd, shared only
cmake -S "$ZSRC/build/cmake" -B "$W/zstd-build" -G Ninja $COMMON -DCMAKE_C_FLAGS="$MAPS -g0" \
  -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_CONTRIB=OFF -DZSTD_BUILD_STATIC=OFF -DZSTD_BUILD_SHARED=ON \
  -DZSTD_LEGACY_SUPPORT=OFF
ninja -C "$W/zstd-build" -j"$JOBS"
# The build tree's copy (id @rpath/libzstd.1.dylib) is what LLVM and its tools link and run against while building;
# the staged copy gets the final install name, and libLLVM's reference to it is rewritten below.
cp "$W/zstd-build/lib/libzstd.$ZSTD_VER.dylib" "$STAGE/libzstd.1.dylib"
chmod 755 "$STAGE/libzstd.1.dylib"
install_name_tool -id @loader_path/libzstd.1.dylib "$STAGE/libzstd.1.dylib"

# 2. libLLVM.dylib: only the shared-library target
cmake -S "$LSRC/llvm" -B "$W/llvm-build" -G Ninja $COMMON \
  -DCMAKE_C_FLAGS="$MAPS -g0" -DCMAKE_CXX_FLAGS="$MAPS -g0" \
  ${LLVM_LAUNCHER:+-DCMAKE_C_COMPILER_LAUNCHER=$LLVM_LAUNCHER -DCMAKE_CXX_COMPILER_LAUNCHER=$LLVM_LAUNCHER} \
  "-DCMAKE_IGNORE_PREFIX_PATH=/opt/local;/opt/homebrew;/usr/local" -DCMAKE_BUILD_RPATH="$W/zstd-build/lib" \
  -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=OFF -DLLVM_TARGETS_TO_BUILD=X86 -DLLVM_OPTIMIZED_TABLEGEN=ON \
  -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_PLUGINS=OFF -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_ENABLE_ZLIB=FORCE_ON -DZLIB_LIBRARY="$SDK/usr/lib/libz.tbd" -DZLIB_LIBRARY_RELEASE="$SDK/usr/lib/libz.tbd" -DZLIB_INCLUDE_DIR="$SDK/usr/include" -DLLVM_ENABLE_ZSTD=FORCE_ON -DLLVM_USE_STATIC_ZSTD=OFF \
  -Dzstd_INCLUDE_DIR="$ZSRC/lib" -Dzstd_LIBRARY="$W/zstd-build/lib/libzstd.$ZSTD_VER.dylib" \
  -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_FFI=OFF -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_HTTPLIB=OFF -DLLVM_APPEND_VC_REV=OFF
ninja -C "$W/llvm-build" -j"$JOBS" LLVM
L=$(find "$W/llvm-build/lib" -maxdepth 1 -name 'libLLVM*.dylib' -type f | head -1)
[ -n "$L" ] || { echo "llvm.sh: libLLVM dylib not found in $W/llvm-build/lib" >&2; exit 1; }
cp "$L" "$STAGE/libLLVM.dylib"; chmod 755 "$STAGE/libLLVM.dylib"
install_name_tool -id @loader_path/libLLVM.dylib "$STAGE/libLLVM.dylib"
for r in $(otool -l "$STAGE/libLLVM.dylib" | awk '/cmd LC_RPATH/{getline; getline; print $2}'); do
  install_name_tool -delete_rpath "$r" "$STAGE/libLLVM.dylib"
done
ZREF=$(otool -L "$STAGE/libLLVM.dylib" | awk '/libzstd/{print $1}')
[ -n "$ZREF" ] || { echo "llvm.sh: libLLVM.dylib does not link zstd" >&2; exit 1; }
install_name_tool -change "$ZREF" @loader_path/libzstd.1.dylib "$STAGE/libLLVM.dylib"
strip -x "$STAGE/libLLVM.dylib" "$STAGE/libzstd.1.dylib"   # local symbols only; every exported symbol stays
sign "$STAGE/libLLVM.dylib" "$STAGE/libzstd.1.dylib"

# 3. the notices the bundle ships (docs/INSTALL.md 5.2) and the checksum list air_runtime_install.sh verifies
cp "$LSRC/llvm/LICENSE.TXT" "$STAGE/LICENSES/LLVM-LICENSE.txt"
cp "$ZSRC/LICENSE" "$STAGE/LICENSES/ZSTD-LICENSE.txt"
cp "$ZSRC/COPYING" "$STAGE/LICENSES/ZSTD-COPYING.txt"
printf 'LLVM %s (SHA-256 %s)\nzstd %s (SHA-256 %s)\nSource: %s\n        %s\nBuilt by scripts/build/llvm.sh of Vermilion.\n' \
  "$LLVM_VER" "$LLVM_SHA256" "$ZSTD_VER" "$ZSTD_SHA256" "$LLVM_URL" "$ZSTD_URL" >"$STAGE/LICENSES/SOURCES.txt"
( cd "$STAGE" && for f in libLLVM.dylib libzstd.1.dylib; do echo "$(md5 -q "$f")  $f"; done >MD5SUMS )

# 4. checks: no build path, x86_64, every symbol the plugin resolves, the dependencies
homecheck "$STAGE/libLLVM.dylib" "$W"
homecheck "$STAGE/libzstd.1.dylib" "$W"
file "$STAGE/libLLVM.dylib" | grep -q x86_64 || { echo "llvm.sh: libLLVM.dylib is not x86_64" >&2; exit 1; }
nm -gU "$STAGE/libLLVM.dylib" | awk '{print $3}' | sed 's/^_//' | sort -u >"$W/exports.txt"
for s in LLVMContextCreate LLVMContextDispose LLVMContextSetDiagnosticHandler LLVMCreateMemoryBufferWithMemoryRangeCopy \
  LLVMDisposeMemoryBuffer LLVMParseBitcodeInContext2 LLVMPrintModuleToString LLVMDisposeModule LLVMDisposeMessage \
  LLVMGetDiagInfoDescription LLVMGetDiagInfoSeverity LLVMRunPasses LLVMCreatePassBuilderOptions LLVMDisposePassBuilderOptions \
  LLVMGetErrorMessage LLVMDisposeErrorMessage LLVMGetFirstGlobal LLVMGetNextGlobal LLVMGlobalGetValueType LLVMGetFirstUse \
  LLVMGetNextUse LLVMGetUser LLVMIsAConstantExpr LLVMGetConstOpcode LLVMGetGEPSourceElementType LLVMGetNumOperands \
  LLVMGetOperand LLVMIsAConstantInt LLVMConstIntGetSExtValue LLVMGetTypeKind LLVMGetIntTypeWidth LLVMGetElementType \
  LLVMGetArrayLength2 LLVMGetModuleContext LLVMInt64TypeInContext LLVMConstInt LLVMConstInBoundsGEP2 LLVMReplaceAllUsesWith; do
  grep -qx "$s" "$W/exports.txt" || { echo "llvm.sh: libLLVM.dylib lacks $s, which the plugin uses" >&2; exit 1; }
done
for f in libLLVM.dylib libzstd.1.dylib; do   # only the system and the sibling may be needed
  otool -L "$STAGE/$f" | tail -n +2 | awk -v f="$f" '{print f " needs " $1}'
  bad=$(otool -L "$STAGE/$f" | tail -n +2 | awk '{print $1}' | grep -v -e '^@loader_path/' -e '^/usr/lib/' -e '^/System/' || true)
  [ -z "$bad" ] || { echo "llvm.sh: $f depends on a library outside the system: $bad" >&2; exit 1; }
done

rm -rf "$OUT/air-runtime"; cp -R "$STAGE" "$OUT/air-runtime"
ls -l "$OUT/air-runtime" "$OUT/air-runtime/LICENSES"
echo "built $OUT/air-runtime (LLVM $LLVM_VER, zstd $ZSTD_VER); install it with tools/phxctl/air_runtime_install.sh $OUT/air-runtime"
