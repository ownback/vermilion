#!/bin/sh
# SPDX-License-Identifier: MIT
# make-oc-zip.sh --version <ver> --kexts <dir> --out <dir> [--snippet <plist>]
# Build Vermilion-<ver>-OpenCore.zip (docs/RELEASE.md, "Artefacts of a release"): VermilionBoot.kext, VermilionTrust.kext
# and VermilionAudio.kext from <dir> (a scripts/build output folder), config-snippet.plist, README.txt, LICENSES/ and
# NOTICE. It builds nothing. Refuses when a kext is missing, when a kext's CFBundleShortVersionString is not <ver>
# (docs/RELEASE.md checklist), or when config-snippet.plist holds an SMBIOS key (tests/release/oc_zip_test.sh checks
# the same).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
VERSION="" KEXTS="" OUT="" SNIPPET=$HERE/config-snippet.plist
while [ $# -gt 0 ]; do
  case $1 in
    --version) VERSION=${2:?}; shift ;;
    --kexts) KEXTS=${2:?}; shift ;;
    --out) OUT=${2:?}; shift ;;
    --snippet) SNIPPET=${2:?}; shift ;;
    *) echo "make-oc-zip: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$VERSION" ] && [ -n "$KEXTS" ] && [ -n "$OUT" ] || { sed -n '3,/^set -eu/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 2; }
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$' || { echo "make-oc-zip: version '$VERSION' is not <major>.<minor>.<patch>[-suffix]" >&2; exit 2; }
command -v zip >/dev/null || { echo "make-oc-zip: zip not found" >&2; exit 1; }

for k in VermilionBoot VermilionTrust VermilionAudio; do
  [ -f "$KEXTS/$k.kext/Contents/Info.plist" ] && [ -f "$KEXTS/$k.kext/Contents/MacOS/$k" ] || { echo "make-oc-zip: $KEXTS/$k.kext missing or incomplete (docs/BUILD.md)" >&2; exit 1; }
  have=$(python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb")).get("CFBundleShortVersionString",""))' "$KEXTS/$k.kext/Contents/Info.plist")
  # the version of a pre-release (0.1.0-preview) is not a valid bundle version: its numeric part must match
  [ "$have" = "$VERSION" ] || [ "$have" = "${VERSION%%-*}" ] || { echo "make-oc-zip: $k.kext has CFBundleShortVersionString '$have', the release is '$VERSION'" >&2; exit 1; }
done

# no SMBIOS or machine identity in the snippet
python3 -I "$HERE/check-snippet.py" "$SNIPPET" || { echo "make-oc-zip: $SNIPPET holds a machine identity key" >&2; exit 1; }

mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/vermilion-oczip.XXXXXX"); trap 'rm -rf "$W"' EXIT
Z=$W/Vermilion-$VERSION-OpenCore
mkdir -p "$Z/Kexts"
for k in VermilionBoot VermilionTrust VermilionAudio; do cp -R "$KEXTS/$k.kext" "$Z/Kexts/"; done
cp "$SNIPPET" "$Z/config-snippet.plist"
sed "s|@VERSION@|$VERSION|g" "$HERE/OpenCore-README.txt" >"$Z/README.txt"
cp "$ROOT/NOTICE" "$Z/NOTICE"
cp -R "$ROOT/LICENSES" "$Z/LICENSES"
rm -f "$OUT/Vermilion-$VERSION-OpenCore.zip"
( cd "$Z" && zip -X -r -q "$OUT/Vermilion-$VERSION-OpenCore.zip" . )
echo "built $OUT/Vermilion-$VERSION-OpenCore.zip"
