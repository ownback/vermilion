#!/bin/sh
# SPDX-License-Identifier: MIT
# make-pkg.sh --version <ver> --build <dir> --air-runtime <dir> --out <dir> [--identifier <id>]
# Build Vermilion-<ver>.pkg (docs/RELEASE.md, "The package") from components that are already built; this script
# builds nothing and takes every path as an argument. macOS only (pkgbuild, productbuild).
#   --build        a scripts/build output folder ($VERMILION_OUT): NVMTLDriver, libnvmtl_translate.dylib,
#                  libvulkan_radeon.dylib, VermilionAccel.kext, phxctl, mesboot, metaltest, spirv-val
#   --air-runtime  scripts/build/llvm.sh's output: libLLVM.dylib, libzstd.1.dylib, MD5SUMS, LICENSES/
#   --out          where Vermilion-<ver>.pkg goes
# The package holds no AMD firmware, no EFI file and nothing for the system volume. Scripts: pkg/preinstall (checks,
# rollback copies), pkg/postinstall (the daemon files, firmware fetch, AIR reader), pkg/vermilion-uninstall.
# The package is unsigned (owner decision 2026-11-25).
# Every script it ships goes through strip-hooks.sh first: the test hooks (VERMILION_TEST, _ROOT, _NOCHOWN, ...) are
# not in the installed copies, so the caller's environment cannot steer them. The Installer's own check
# (pkg/install-check.sh, run by distribution.xml) goes in the package's resources.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$HERE/common.sh"
VERSION="" BUILD="" AIR="" OUT="" ID=org.vermilion.pkg
while [ $# -gt 0 ]; do
  case $1 in
    --version) VERSION=${2:?}; shift ;;
    --build) BUILD=${2:?}; shift ;;
    --air-runtime) AIR=${2:?}; shift ;;
    --out) OUT=${2:?}; shift ;;
    --identifier) ID=${2:?}; shift ;;
    *) echo "make-pkg: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$VERSION" ] && [ -n "$BUILD" ] && [ -n "$AIR" ] && [ -n "$OUT" ] || usage
check_version make-pkg "$VERSION"
for f in NVMTLDriver libnvmtl_translate.dylib libvulkan_radeon.dylib VermilionAccel.kext phxctl mesboot metaltest spirv-val; do
  [ -e "$BUILD/$f" ] || { echo "make-pkg: $BUILD/$f missing (docs/BUILD.md)" >&2; exit 1; }
done
for f in libLLVM.dylib libzstd.1.dylib; do
  [ -f "$AIR/$f" ] || { echo "make-pkg: $AIR/$f missing (scripts/build/llvm.sh)" >&2; exit 1; }
done
[ -d "$AIR/LICENSES" ] || { echo "make-pkg: $AIR/LICENSES missing: the AIR reader must ship with its notices" >&2; exit 1; }
command -v pkgbuild >/dev/null && command -v productbuild >/dev/null || { echo "make-pkg: pkgbuild and productbuild are macOS tools" >&2; exit 1; }
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
ship() { sh "$HERE/strip-hooks.sh" "$1" "$2"; }   # ship <source script> <destination>: the copy without the test hooks

W=$(mktemp -d "${TMPDIR:-/tmp}/vermilion-pkg.XXXXXX"); trap 'rm -rf "$W"' EXIT
P=$W/root
GB=$P/Library/GPUBundles; B=$GB/NVMTLDriver.bundle/Contents
LX=$P/usr/local/libexec/vermilion
mkdir -p "$B/MacOS" "$B/Resources" "$GB/nvmtl" "$P/Library/Extensions" "$P/usr/local/sbin" "$P/usr/local/bin" \
         "$LX/gpu/phxctl" "$LX/firmware" "$LX/tools"

# The Metal driver bundle, with the licence files; the AIR reader goes in at install time (air_runtime_install.sh)
cp "$HERE/pkg/NVMTLDriver.Info.plist" "$B/Info.plist"
cp "$BUILD/NVMTLDriver" "$BUILD/libnvmtl_translate.dylib" "$B/MacOS/"
for f in LICENSE NOTICE THIRD_PARTY_NOTICES.md CREDITS.md; do cp "$ROOT/$f" "$B/Resources/"; done
cp -R "$ROOT/LICENSES" "$B/Resources/LICENSES"
# spirv-val's licence, when scripts/build/spirv-val.sh left it next to the binary
[ ! -f "$BUILD/spirv-val.LICENSE" ] || cp "$BUILD/spirv-val.LICENSE" "$B/Resources/spirv-val.LICENSE"

cp "$BUILD/libvulkan_radeon.dylib" "$GB/nvmtl/"
printf '*\n' >"$GB/nvmtl-allow.txt"
cp -R "$BUILD/VermilionAccel.kext" "$P/Library/Extensions/"
cp "$BUILD/phxctl" "$BUILD/mesboot" "$P/usr/local/sbin/"
cp "$BUILD/spirv-val" "$P/usr/local/bin/"
ship "$HERE/pkg/vermilion-uninstall" "$P/usr/local/sbin/vermilion-uninstall"
ship "$HERE/pkg/vermilion-firmware" "$P/usr/local/sbin/vermilion-firmware"

# /usr/local/libexec/vermilion: what the post-install script copies into ~/gpu, the firmware fetcher, the AIR reader
T=$ROOT/tools/phxctl
for f in phxboot-navi31.sh gfx_cg.sh sdma_idle.sh uclk.sh smumetrics.py ptwalk.sh m7_boot.sh m7_phase.sh dispovr.sh \
         b15_boot.sh wm144.sh det.sh dalwm.sh dal.sh hubp_dlg.sh p0prefetch.sh; do cp "$T/$f" "$LX/gpu/$f"; done
cp "$T/navi31_up.sh" "$T/bringup_navi31.sh" "$LX/gpu/phxctl/"
cp "$BUILD/phxctl" "$LX/gpu/phxctl.bin"
cp "$BUILD/metaltest" "$LX/gpu/metaltest"
cp "$T/local.phxboot.plist.in" "$LX/"
cp "$ROOT/tools/firmware/fetch_firmware.sh" "$ROOT/tools/firmware/fw.lock" "$LX/firmware/"
ship "$T/air_runtime_install.sh" "$LX/tools/air_runtime_install.sh"
ship "$HERE/pkg/lib.sh" "$LX/lib.sh"
printf '%s\n' "$VERSION" >"$LX/VERSION"
mkdir -p "$LX/air-runtime-src"; cp -R "$AIR"/. "$LX/air-runtime-src/"
chmod -R go-w,a+rX "$P"
chmod 755 "$P/usr/local/sbin/"* "$P/usr/local/bin/"* "$LX/gpu/"*.sh "$LX/gpu/phxctl/"*.sh "$LX/gpu/phxctl.bin" \
          "$LX/gpu/metaltest" "$LX/firmware/fetch_firmware.sh" "$LX/tools/air_runtime_install.sh"

# The scripts, and the list of paths the payload replaces (the preinstall script copies each away first)
S=$W/scripts; mkdir -p "$S"
for f in preinstall postinstall lib.sh; do ship "$HERE/pkg/$f" "$S/$f"; done
chmod 755 "$S/preinstall" "$S/postinstall"
cat >"$S/units-payload.txt" <<'EOF'
/Library/GPUBundles/NVMTLDriver.bundle
/Library/GPUBundles/nvmtl/libvulkan_radeon.dylib
/Library/GPUBundles/nvmtl-allow.txt
/Library/Extensions/VermilionAccel.kext
/usr/local/sbin/phxctl
/usr/local/sbin/mesboot
/usr/local/sbin/vermilion-uninstall
/usr/local/sbin/vermilion-firmware
/usr/local/bin/spirv-val
/usr/local/libexec/vermilion
EOF

# Component plist: bundles are not relocatable and not version-checked (an install over an older or the same version
# must replace the files; a relocated bundle would leave the driver where macOS doesn't look)
pkgbuild --analyze --root "$P" "$W/component.plist" >/dev/null
python3 -I - "$W/component.plist" <<'EOF'
import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f: comps = plistlib.load(f)
for c in comps:
    c["BundleIsRelocatable"] = False
    c["BundleIsVersionChecked"] = False
    c["BundleHasStrictIdentifier"] = False
with open(p, "wb") as f: plistlib.dump(comps, f)
EOF
pkgbuild --root "$P" --component-plist "$W/component.plist" --identifier "$ID" --version "$VERSION" \
         --install-location / --ownership recommended --scripts "$S" "$W/vermilion-component.pkg" >/dev/null

# The product archive: title, welcome and conclusion pages, x86_64 only, installs on the system volume only, and the
# Installer's own check (installCheck() in distribution.xml runs install-check.sh, which reads lib.sh).
# productbuild copies only the pages the distribution names into the archive's Resources, so the two scripts are added
# to the expanded archive, which is flattened again (the package is unsigned, so nothing is invalidated).
EXPECT=$(sed -n 's/^EXPECT_BUILD=//p' "$HERE/pkg/lib.sh")
sed -e "s|@VERSION@|$VERSION|g" -e "s|@IDENTIFIER@|$ID|g" -e "s|@BUILD@|$EXPECT|g" "$HERE/pkg/distribution.xml.in" >"$W/distribution.xml"
productbuild --distribution "$W/distribution.xml" --resources "$HERE/pkg/resources" --package-path "$W" "$W/product.pkg" >/dev/null
pkgutil --expand "$W/product.pkg" "$W/product"
chmod 755 "$W/product/Resources"
ship "$HERE/pkg/install-check.sh" "$W/product/Resources/install-check.sh"; chmod 755 "$W/product/Resources/install-check.sh"
ship "$HERE/pkg/lib.sh" "$W/product/Resources/lib.sh"; chmod 644 "$W/product/Resources/lib.sh"
pkgutil --flatten "$W/product" "$OUT/Vermilion-$VERSION.pkg"
echo "built $OUT/Vermilion-$VERSION.pkg"
