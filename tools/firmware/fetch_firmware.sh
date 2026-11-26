#!/bin/sh
# SPDX-License-Identifier: MIT
# fetch_firmware.sh [--from <dir>] [dest]: download the AMD Navi 31 microcode listed in fw.lock from linux-firmware
# (amdgpu/) and check each file's md5 and SHA-256 against fw.lock. Default dest: $HOME/gpu/fw/navi31, the directory
# the box scripts read; the release package's post-install script passes its own (docs/RELEASE.md).
# The files are AMD's, redistributable in binary form under LICENSE.amdgpu (LICENSES/LICENSE.amdgpu.txt); this
# repository does not ship them. The files come from the linux-firmware commit pinned in fw.lock
# (`linux-firmware-commit:`); LINUX_FIRMWARE_REF overrides it with another commit. A file whose md5 or SHA-256 differs
# from fw.lock is rejected, since the bring-up offsets and sizes were measured on those revisions.
# --from <dir>: take the files from <dir> (a linux-firmware checkout's amdgpu/ directory, or a directory that holds the
# files) instead of the network; the same checks apply. An fw.lock line without a SHA-256 column is checked by md5 only.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FROM=
if [ "${1:-}" = --from ]; then FROM=${2:?--from needs a directory}; shift 2; fi
DEST=${1:-$HOME/gpu/fw/navi31}
PIN=$(sed -n 's/^# linux-firmware-commit: *\([0-9a-f]\{40\}\).*/\1/p' "$HERE/fw.lock")
REF=${LINUX_FIRMWARE_REF:-$PIN}
[ -n "$REF" ] || { echo "fw.lock has no linux-firmware-commit line" >&2; exit 1; }
BASES=${LINUX_FIRMWARE_URL:-"https://gitlab.com/kernel-firmware/linux-firmware/-/raw/$REF/amdgpu https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amdgpu?id=$REF"}
md5of() { if command -v md5 >/dev/null 2>&1; then md5 -q "$1"; else md5sum "$1" | cut -d' ' -f1; fi; }
sha256of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }
good() {   # good <file> <md5> <sha256 or empty>
  [ "$(md5of "$1")" = "$2" ] && { [ -z "$3" ] || [ "$(sha256of "$1")" = "$3" ]; }
}
mkdir -p "$DEST"
grep -v '^#' "$HERE/fw.lock" | while read -r f sum size sha; do
  [ -n "$f" ] || continue
  if [ -f "$DEST/$f" ] && good "$DEST/$f" "$sum" "${sha:-}"; then echo "ok      $f"; continue; fi
  got=0
  if [ -n "$FROM" ]; then
    for c in "$FROM/$f" "$FROM/amdgpu/$f"; do
      if [ -f "$c" ] && good "$c" "$sum" "${sha:-}"; then
        cp "$c" "$DEST/$f.tmp" && mv "$DEST/$f.tmp" "$DEST/$f"; echo "copied  $f"; got=1; break
      fi
    done
    [ $got = 1 ] || { echo "FAILED  $f: not in $FROM with SHA-256 ${sha:-(fw.lock has none: md5 $sum)}" >&2; exit 1; }
    continue
  fi
  for b in $BASES; do
    case $b in *\?id=*) url="${b%%\?id=*}/$f?id=${b#*\?id=}";; *) url="$b/$f";; esac
    if curl -fsSL --retry 3 -o "$DEST/$f.tmp" "$url" && good "$DEST/$f.tmp" "$sum" "${sha:-}"; then
      mv "$DEST/$f.tmp" "$DEST/$f"; echo "fetched $f"; got=1; break
    fi
    rm -f "$DEST/$f.tmp"
  done
  [ $got = 1 ] || { echo "FAILED  $f: no copy with md5 $sum at ref $REF (the pinned commit is in fw.lock)" >&2; exit 1; }
done
echo "firmware in $DEST matches fw.lock"
