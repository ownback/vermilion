#!/bin/sh
# SPDX-License-Identifier: MIT
# esp_stage.sh <dest> [fw dir]: lay out the Recovery install payload (tools/phxctl/recovery_install.sh) in <dest>,
# usually <EFI partition>/vermilion. Runs on Linux or macOS. Inputs: the build outputs in $VERMILION_OUT (default
# <repo>/build; docs/BUILD.md, plus build/spirv-val from SPIRV-Tools) and the firmware of tools/firmware/fw.lock
# (default ~/gpu/fw/navi31), whose md5s are checked here. The firmware is AMD's and is never committed (CLAUDE.md).
#
#   <dest>/install.sh          recovery_install.sh
#   <dest>/payload/build/      the binaries and VermilionAccel.kext
#   <dest>/payload/tools/phxctl/
#   <dest>/payload/fw/navi31/
#   <dest>/flags/              left empty: esp_flags.sh (the boot daemon's pre-hook) takes flag files from here
#
# FAT has no owners or modes; recovery_install.sh sets them on the target.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEST=${1:?usage: esp_stage.sh <dest> [fw dir]}; FW=${2:-$HOME/gpu/fw/navi31}; OUT=${VERMILION_OUT:-$ROOT/build}
md5of() { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi; }
for f in NVMTLDriver libnvmtl_translate.dylib libvulkan_radeon.dylib VermilionAccel.kext phxctl mesboot metaltest spirv-val phxaudio; do
  [ -e "$OUT/$f" ] || { echo "esp_stage: $OUT/$f missing (docs/BUILD.md)" >&2; exit 1; }
done
grep -v '^#' "$ROOT/tools/firmware/fw.lock" | while read -r f sum size; do
  [ -n "$f" ] || continue
  [ -f "$FW/$f" ] && [ "$(md5of "$FW/$f")" = "$sum" ] || { echo "esp_stage: $FW/$f missing or not the fw.lock revision" >&2; exit 1; }
done
rm -rf "$DEST/payload.new"; mkdir -p "$DEST/payload.new/build" "$DEST/payload.new/tools/phxctl" "$DEST/payload.new/fw/navi31" "$DEST/flags"
for f in NVMTLDriver libnvmtl_translate.dylib libvulkan_radeon.dylib VermilionAccel.kext phxctl mesboot metaltest spirv-val phxaudio; do
  cp -R "$OUT/$f" "$DEST/payload.new/build/"
done
cp "$ROOT"/tools/phxctl/*.sh "$ROOT"/tools/phxctl/*.py "$ROOT/tools/phxctl/local.phxboot.plist.in" "$DEST/payload.new/tools/phxctl/"
grep -v '^#' "$ROOT/tools/firmware/fw.lock" | while read -r f sum size; do [ -n "$f" ] && cp "$FW/$f" "$DEST/payload.new/fw/navi31/"; done
rm -rf "$DEST/payload"; mv "$DEST/payload.new" "$DEST/payload"
cp "$ROOT/tools/phxctl/recovery_install.sh" "$DEST/install.sh"
( cd "$DEST" && find payload install.sh -type f | sort | while read -r f; do printf '%s  %s\n' "$(md5of "$f")" "$f"; done ) >"$DEST/MD5SUMS"
echo "staged $(wc -l <"$DEST/MD5SUMS" | tr -d ' ') files in $DEST ($(du -sh "$DEST" | cut -f1))"
