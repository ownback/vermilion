#!/bin/sh
# SPDX-License-Identifier: MIT
# air_runtime_install.sh [<src dir> [root]]: install the plugin's in-memory AIR bitcode reader, <src>/libLLVM.dylib and
# <src>/libzstd.1.dylib (+ their notices: <src>/LICENSES/*, <src>/*LICENSE*, <src>/*COPYING*), into
# <root>/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime (notices in Contents/Resources/air-runtime).
# NVMTLDriver dlopens air-runtime/libLLVM.dylib next to itself (src/metal-plugin/NVMTLLibraryLoad.m). Without it,
# and without air-opt, it cannot read any metallib: WindowServer's Metal compositor gets no shaders from QuartzCore's
# default.metallib and aborts (XTX machine, 2026-11-19).
# Without <src dir> the source is this project's own build: scripts/build/llvm.sh -> $VERMILION_OUT/air-runtime
# (default build/air-runtime). NullMoth's copy (docs/INSTALL.md 5.2) is only a fallback: with no <src dir> and no build
# of ours, a copy already in the bundle is kept (and the script says so); with none at all it fails.
# <src>/MD5SUMS (md5 path), when present, is checked first. Exit 0 only when both libraries are in place.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
R=${2:-}
B=$R/Library/GPUBundles/NVMTLDriver.bundle/Contents
if [ -n "${1:-}" ]; then S=$1
else
  S=${VERMILION_OUT:-$HERE/../../build}/air-runtime
  if [ ! -f "$S/libLLVM.dylib" ]; then
    if [ -f "$B/MacOS/air-runtime/libLLVM.dylib" ] && [ -f "$B/MacOS/air-runtime/libzstd.1.dylib" ]; then
      echo "air-runtime: no build of ours at $S (scripts/build/llvm.sh): keeping the copy already in the bundle (NullMoth's fallback, not built by Vermilion)"
      exit 0
    fi
    echo "air-runtime: no build of ours at $S: run scripts/build/llvm.sh, or pass a directory with libLLVM.dylib and libzstd.1.dylib"; exit 1
  fi
fi
[ -f "$S/libLLVM.dylib" ] && [ -f "$S/libzstd.1.dylib" ] || { echo "air-runtime: $S lacks libLLVM.dylib or libzstd.1.dylib"; exit 1; }
[ -d "$B/MacOS" ] || { echo "air-runtime: $B/MacOS missing (install the plugin first)"; exit 1; }
md5of() { if command -v md5 >/dev/null 2>&1; then md5 -q "$1"; else md5sum "$1" | cut -d' ' -f1; fi; }
if [ -f "$S/MD5SUMS" ]; then
  while read -r sum f; do [ -n "$f" ] || continue
    [ "$(md5of "$S/$f")" = "$sum" ] || { echo "air-runtime: $f does not match MD5SUMS: not installed"; exit 1; }
  done <"$S/MD5SUMS"
fi
mkdir -p "$B/MacOS/air-runtime" "$B/Resources/air-runtime"
for f in libLLVM.dylib libzstd.1.dylib; do
  cp "$S/$f" "$B/MacOS/air-runtime/.$f.new"; chmod 755 "$B/MacOS/air-runtime/.$f.new"
  [ "${VERMILION_NOCHOWN:-0}" = 1 ] || chown 0:0 "$B/MacOS/air-runtime/.$f.new"
  mv "$B/MacOS/air-runtime/.$f.new" "$B/MacOS/air-runtime/$f"
done
for f in "$S"/LICENSES/* "$S"/*LICENSE* "$S"/*COPYING*; do [ -f "$f" ] && cp "$f" "$B/Resources/air-runtime/" && chmod 644 "$B/Resources/air-runtime/${f##*/}"; done
[ "${VERMILION_NOCHOWN:-0}" = 1 ] || chown -R 0:0 "$B/MacOS/air-runtime" "$B/Resources/air-runtime"
chmod 755 "$B/MacOS/air-runtime" "$B/Resources/air-runtime"
echo "air-runtime: installed $(ls "$B/MacOS/air-runtime" | tr '\n' ' ')into $B/MacOS/air-runtime"
