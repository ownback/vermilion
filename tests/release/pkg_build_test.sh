#!/bin/bash
# SPDX-License-Identifier: MIT
# pkg_build_test.sh: builds Vermilion-<ver>.pkg from dummy components (tests/release/dummy.sh) with
# scripts/release/make-pkg.sh and inspects it: what the payload holds and does not hold, the scripts, the version, the
# release scan over the expanded package. macOS only (pkgbuild, productbuild, pkgutil); prints SKIP elsewhere.
# The package is never opened by the Installer and nothing is installed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
if [ "$(uname -s)" != Darwin ] || ! command -v pkgbuild >/dev/null; then echo "pkg_build_test: SKIP (needs macOS pkgbuild)"; exit 0; fi
. "$HERE/dummy.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/pkgbuild-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL $1"; fi; }
VER=0.1.0-preview
dummy_build "$T/build" t1; dummy_air "$T/air" t1
out=$(sh "$R/scripts/release/make-pkg.sh" --version "$VER" --build "$T/build" --air-runtime "$T/air" --out "$T/out" 2>&1); rc=$?
check "pkg builds" '[ $rc = 0 ] && [ -f "$T/out/Vermilion-$VER.pkg" ]'
[ -f "$T/out/Vermilion-$VER.pkg" ] || { echo "$out"; echo "pkg_build_test: $PASS passed, $FAIL failed"; exit 1; }
pkgutil --expand-full "$T/out/Vermilion-$VER.pkg" "$T/x" >/dev/null
P=$T/x/vermilion-component.pkg
pkgutil --payload-files "$T/out/Vermilion-$VER.pkg" 2>/dev/null | sed 's|^\./||' >"$T/files"
check "payload: the Metal driver bundle with Info.plist, executable, translator, licences" 'for f in Library/GPUBundles/NVMTLDriver.bundle/Contents/Info.plist Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/libnvmtl_translate.dylib Library/GPUBundles/NVMTLDriver.bundle/Contents/Resources/LICENSE Library/GPUBundles/NVMTLDriver.bundle/Contents/Resources/NOTICE; do grep -qx "$f" "$T/files" || { echo "  missing $f"; exit 1; }; done'
check "payload: RADV, allow list, VermilionAccel, tools, spirv-val" 'for f in Library/GPUBundles/nvmtl/libvulkan_radeon.dylib Library/GPUBundles/nvmtl-allow.txt Library/Extensions/VermilionAccel.kext/Contents/MacOS/VermilionAccel usr/local/sbin/phxctl usr/local/sbin/mesboot usr/local/sbin/vermilion-uninstall usr/local/sbin/vermilion-firmware usr/local/bin/spirv-val; do grep -qx "$f" "$T/files" || { echo "  missing $f"; exit 1; }; done'
check "payload: the daemon, the AIR reader source, fetch_firmware.sh and fw.lock" 'for f in usr/local/libexec/vermilion/gpu/phxboot-navi31.sh usr/local/libexec/vermilion/gpu/phxctl/navi31_up.sh usr/local/libexec/vermilion/air-runtime-src/libLLVM.dylib usr/local/libexec/vermilion/firmware/fetch_firmware.sh usr/local/libexec/vermilion/firmware/fw.lock usr/local/libexec/vermilion/lib.sh usr/local/libexec/vermilion/VERSION; do grep -qx "$f" "$T/files" || { echo "  missing $f"; exit 1; }; done'
check "payload: no firmware, no EFI, no config.plist, no system-volume path, no home path" '! grep -E "\.bin$|\.rom$|(^|/)config\.plist|^EFI|^System/|^Users/|^private/var/db|phxboot-pre\.sh|esp_flags" "$T/files" | grep -v "phxctl\.bin$"'
check "payload: every path is under Library/GPUBundles, Library/Extensions, usr/local" '! grep -vE "^(Library/GPUBundles|Library/Extensions|usr/local)(/|$)|^(Library|usr)$|^Library/$|^usr/$|^\.$" "$T/files"'
check "scripts: preinstall, postinstall, lib.sh, units-payload.txt, executable" '[ -x "$P/Scripts/preinstall" ] && [ -x "$P/Scripts/postinstall" ] && [ -f "$P/Scripts/lib.sh" ] && [ -f "$P/Scripts/units-payload.txt" ]'
check "scripts: valid shell" 'sh -n "$P/Scripts/preinstall" && sh -n "$P/Scripts/postinstall" && sh -n "$P/Scripts/lib.sh" && sh -n "$R/scripts/release/pkg/vermilion-uninstall" && sh -n "$R/scripts/release/pkg/vermilion-firmware"'
check "units-payload lists the paths the payload installs" 'while read -r u; do [ -z "$u" ] || grep -qx "${u#/}" "$T/files" || { echo "  $u not in the payload"; exit 1; }; done <"$P/Scripts/units-payload.txt"'
check "the package id and version" 'grep -q "identifier=\"org.vermilion.pkg\"" "$P/PackageInfo" && grep -q "version=\"$VER\"" "$P/PackageInfo" && grep -q "<title>Vermilion $VER</title>" "$T/x/Distribution"'
check "the bundle is not relocatable" 'grep -q "<relocate/>" "$P/PackageInfo"'
check "x86_64 hosts and the system volume only" 'grep -q "hostArchitectures=\"x86_64\"" "$T/x/Distribution" && grep -q "enable_localSystem=\"true\"" "$T/x/Distribution" && grep -q "enable_currentUserHome=\"false\"" "$T/x/Distribution"'
check "the package is unsigned" '! pkgutil --check-signature "$T/out/Vermilion-$VER.pkg" 2>&1 | grep -q "signed by"'
check "release scan on the package is clean" 'bash "$R/scripts/dev/release-scan.sh" "$T/out/Vermilion-$VER.pkg" >/dev/null 2>&1'
for bad in 1.0 v1.0.0 "0.1.0 x"; do
  check "refuses the version '$bad'" '! sh "$R/scripts/release/make-pkg.sh" --version "$bad" --build "$T/build" --air-runtime "$T/air" --out "$T/o2" >/dev/null 2>&1'
done
rm "$T/build/spirv-val"
check "refuses a missing component" '! sh "$R/scripts/release/make-pkg.sh" --version "$VER" --build "$T/build" --air-runtime "$T/air" --out "$T/o3" >/dev/null 2>&1'
echo "pkg_build_test: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
