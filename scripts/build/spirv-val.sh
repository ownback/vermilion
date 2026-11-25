#!/bin/sh
# SPDX-License-Identifier: MIT
# spirv-val.sh: spirv-val (SPIRV-Tools, Apache-2.0) -> $VERMILION_OUT/spirv-val, x86_64, static, ad-hoc signed, with
# its licence as $VERMILION_OUT/spirv-val.LICENSE. The shader translator runs it on every SPIR-V module it makes
# (src/translator/README.md); the release package installs it as /usr/local/bin/spirv-val.
# Pinned: SPIRV-Tools v2025.5 and the SPIRV-Headers revision its DEPS file names (checked out by commit, not by branch).
#   SPIRV_DL      checkout dir (default $VERMILION_OUT/spirv-dl); SPIRV_JOBS parallel jobs (default: all cores)
# Needs git, cmake (>= 3.20), ninja, the Command Line Tools; a few minutes and about 1 GB of disk.
. "$(dirname "$0")/lib.sh"
TOOLS_REV=262bdab48146c937467f826699a40da0fdfc0f1a    # v2025.5
HEADERS_REV=b824a462d4256d720bebb40e78b9eb8f78bbb305  # spirv_headers_revision of SPIRV-Tools v2025.5 DEPS
DL=${SPIRV_DL:-$OUT/spirv-dl}
fetch() {   # fetch <url> <dir> <commit>
  if [ ! -d "$2/.git" ]; then mkdir -p "$2"; git -C "$2" init -q; git -C "$2" remote add origin "$1"; fi
  [ "$(git -C "$2" rev-parse HEAD 2>/dev/null || true)" = "$3" ] || { git -C "$2" fetch -q --depth 1 origin "$3"; git -C "$2" checkout -q --detach "$3"; }
  [ "$(git -C "$2" rev-parse HEAD)" = "$3" ] || { echo "spirv-val.sh: $2 is not at $3" >&2; exit 1; }
}
fetch https://github.com/KhronosGroup/SPIRV-Tools.git "$DL/SPIRV-Tools" "$TOOLS_REV"
fetch https://github.com/KhronosGroup/SPIRV-Headers.git "$DL/SPIRV-Headers" "$HEADERS_REV"
B=$DL/build
cmake -S "$DL/SPIRV-Tools" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DSPIRV-Headers_SOURCE_DIR="$DL/SPIRV-Headers" -DSPIRV_SKIP_TESTS=ON \
  -DSPIRV_WERROR=OFF -DSPIRV_TOOLS_BUILD_STATIC=ON -DBUILD_SHARED_LIBS=OFF -DSPIRV_BUILD_FUZZER=OFF \
  -DCMAKE_C_FLAGS="$PFX" -DCMAKE_CXX_FLAGS="$PFX" >/dev/null
cmake --build "$B" --target spirv-val ${SPIRV_JOBS:+-j "$SPIRV_JOBS"} >/dev/null
cp "$B/tools/spirv-val" "$OUT/spirv-val"; strip -x "$OUT/spirv-val" 2>/dev/null || true
cp "$DL/SPIRV-Tools/LICENSE" "$OUT/spirv-val.LICENSE"
sign "$OUT/spirv-val"
lipo -archs "$OUT/spirv-val" | grep -qx x86_64 || { echo "spirv-val.sh: not a thin x86_64 binary" >&2; exit 1; }
otool -L "$OUT/spirv-val" | tail -n +2 | grep -v -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/' && { echo "spirv-val.sh: links a non-system library" >&2; exit 1; }
homecheck "$OUT/spirv-val"
echo "built $OUT/spirv-val"
