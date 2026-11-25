#!/bin/sh
# SPDX-License-Identifier: MIT
# make-sums.sh <dir> <file>...: write <dir>/SHA256SUMS with the SHA-256 of each named file in <dir> (names only, no
# paths, so `shasum -a 256 -c SHA256SUMS` works in the folder a user downloaded into). Refuses a missing file.
set -eu
D=${1:?usage: make-sums.sh <dir> <file>...}; shift
[ $# -gt 0 ] || { echo "make-sums: no files named" >&2; exit 2; }
cd "$D"
: >SHA256SUMS
for f in "$@"; do
  case $f in */*) echo "make-sums: $f: give names inside $D, not paths" >&2; exit 2 ;; esac
  [ -f "$f" ] || { echo "make-sums: $D/$f missing" >&2; exit 1; }
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$f" >>SHA256SUMS; else sha256sum "$f" >>SHA256SUMS; fi
done
echo "wrote $D/SHA256SUMS ($# files)"
