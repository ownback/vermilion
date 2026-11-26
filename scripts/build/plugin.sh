#!/bin/sh
# SPDX-License-Identifier: MIT
# plugin.sh: the Metal driver plugin NVMTLDriver (src/metal-plugin; NVMTLDevice.m includes the rest) -> $VERMILION_OUT,
# ad-hoc signed (WindowServer refuses an unsigned plugin and falls back to the firmware framebuffer).
# Deployment target 26.0 (macOS Tahoe 26.7.1); an API newer than 26 used without @available is a build error.
# The default is the release driver: a quiet log (failures and errors only, at error level, in the unified log under
# subsystem org.vermilion.nvmtl), no developer switches read from the environment or /tmp request files.
#   PLUGIN_CONFIG=logging  the logging build for a debugging session (NVMTL_RELEASE=0: every line, /tmp/nvmtl.log, env knobs)
#   PLUGIN_CONFIG=diag     logging plus the measurement code (NVMTL_DIAG: E0 trace, holder census, MEMCENSUS)
# PLUGIN_DEFS: extra -D flags on top.
case "${PLUGIN_CONFIG:-release}" in
  release) CFG_DEFS= ;;
  logging) CFG_DEFS=-DNVMTL_RELEASE=0 ;;
  diag)    CFG_DEFS="-DNVMTL_RELEASE=0 -DNVMTL_DIAG" ;;
  *) echo "plugin.sh: PLUGIN_CONFIG must be release, logging or diag" >&2; exit 2 ;;
esac
. "$(dirname "$0")/lib.sh"
VKH=${VULKAN_HEADERS:-$ROOT/deps/Vulkan-Headers/include}
S="$ROOT/src/metal-plugin"
(cd "$S" && xcrun clang -arch x86_64 -mmacosx-version-min=26.0 -Werror=unguarded-availability-new -bundle -fobjc-arc -O2 $PFX \
  -Wno-protocol -Wno-incomplete-implementation $CFG_DEFS ${PLUGIN_DEFS:-} -I "$VKH" -o "$OUT/NVMTLDriver" NVMTLDevice.m \
  -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation)
sign "$OUT/NVMTLDriver"; homecheck "$OUT/NVMTLDriver"
echo "built $OUT/NVMTLDriver"
