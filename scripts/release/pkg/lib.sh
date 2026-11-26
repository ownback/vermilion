# SPDX-License-Identifier: MIT
# lib.sh: shared by the package's preinstall and postinstall scripts and by vermilion-uninstall (sourced; POSIX sh).
# make-pkg.sh puts one copy next to the scripts and one in /usr/local/libexec/vermilion (docs/RELEASE.md).
#
#@test-hooks-begin (strip-hooks.sh drops these lines, and every hook below, from the copies make-pkg.sh ships)
# Test hooks (tests/release/pkg_scripts_test.sh): VERMILION_TEST=1 keeps the caller's PATH, so a test can put fake
# `sw_vers`, `ioreg`, `dscl` and `pkgutil` first; VERMILION_ROOT=<dir> prefixes every system path; VERMILION_NOCHOWN=1
# skips chown; VERMILION_USER / VERMILION_UHOME name the desktop user and the home folder without `dscl`.
#@test-hooks-end

[ "${VERMILION_TEST:-0}" = 1 ] || PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# What this release runs on. VENDOR/DEVICE/REV are src/vermilion-boot/PhxGpuId.h (kVendorAmd, kDeviceNavi31, kRevXtx);
# tests/release/pkg_scripts_test.sh compares them with the header.
EXPECT_BUILD=25G241
GPU_VENDOR=1002
GPU_DEVICE=744c
GPU_REV=c8

R=${VERMILION_ROOT:-}
LIBEXEC=$R/usr/local/libexec/vermilion
SUPPORT="$R/Library/Application Support/Vermilion"

say() { echo "Vermilion: $*"; }
refuse() {
  echo "Vermilion cannot be installed: $*" >&2
  echo "Nothing was changed." >&2
  exit 1
}
fail() { echo "Vermilion: ERROR: $*" >&2; exit 1; }

# Names of the boards that share 1002:744c (PhxGpuId.h), for the refusal message.
board_name() {
  case $1 in
    c8) echo "RX 7900 XTX" ;;
    cc) echo "RX 7900 XT" ;;
    ce) echo "RX 7900 GRE" ;;
    cf) echo "RX 7900M" ;;
    *) echo "an unknown Navi 31 board" ;;
  esac
}

# gpu_list: one line "<vendor> <device> <revision>" (lowercase hex, no 0x) per PCI device that ioreg shows with all
# three properties. ioreg prints each as a little-endian data value, e.g. "vendor-id" = <02100000>.
gpu_list() {
  ioreg -r -c IOPCIDevice -l 2>/dev/null | awk '
    function le16(h) { return substr(h, 3, 2) substr(h, 1, 2) }
    function emit() { if (v != "" && d != "" && r != "" && !done) { print v, d, r; done = 1 } }
    /\+-o / { v = ""; d = ""; r = ""; done = 0 }
    /"vendor-id" = </   { match($0, /<[0-9a-fA-F]+>/); v = le16(tolower(substr($0, RSTART + 1, 4))); emit() }
    /"device-id" = </   { match($0, /<[0-9a-fA-F]+>/); d = le16(tolower(substr($0, RSTART + 1, 4))); emit() }
    /"revision-id" = </ { match($0, /<[0-9a-fA-F]+>/); r = tolower(substr($0, RSTART + 1, 2)); emit() }'
}

# check_gpu: refuse unless an RX 7900 XTX is present and no other 1002:744c board is. GPU_FAIL (other | none) tells a
# refuse() that wants a code which case it is (resources/install-check.sh).
check_gpu() {
  found=0 other=""
  list=$(gpu_list)
  while read -r v d r; do
    [ "$v" = "$GPU_VENDOR" ] && [ "$d" = "$GPU_DEVICE" ] || continue
    if [ "$r" = "$GPU_REV" ]; then found=1; else other="$other $(board_name "$r") (revision 0x$r)"; fi
  done <<EOF
$list
EOF
  [ -z "$other" ] || { GPU_FAIL=other; refuse "found${other}. Vermilion starts only on the AMD Radeon RX 7900 XTX (PCI $GPU_VENDOR:$GPU_DEVICE, revision 0x$GPU_REV), and it must be the only 7900-series card."; }
  [ $found = 1 ] || { GPU_FAIL=none; refuse "no AMD Radeon RX 7900 XTX (PCI $GPU_VENDOR:$GPU_DEVICE, revision 0x$GPU_REV) was found in the I/O registry. Vermilion supports no other card. If you have one, the revision could not be read: report it (SUPPORT.md)."; }
}

# console_user: the desktop user to install for: the test user, else the user at the console, else the only account
# with a user id of 501 or more.
console_user() {
  u=${VERMILION_USER:-}
  [ -n "$u" ] || u=$(stat -f %Su /dev/console 2>/dev/null || echo "")
  case $u in root|loginwindow|"") u=""
    n=0
    for c in $(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 501 { print $1 }'); do u=$c; n=$((n+1)); done
    [ $n = 1 ] || u="" ;;
  esac
  echo "$u"
}
user_home() {   # user_home <user>
  [ -z "${VERMILION_UHOME:-}" ] || { echo "$VERMILION_UHOME"; return; }
  dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{ print $2 }'
}

# Rollback: $RB is one folder per install attempt. MANIFEST has one line per path the install may replace:
#   E <path>   it existed before, and its copy is at $RB/files<path>
#   N <path>   it did not exist
# vermilion-uninstall reads the folders oldest first: the first line that names a path says what was there before the
# first install, so an update never makes a Vermilion file look like the user's own.
rb_current() { cat "$SUPPORT/.rollback-current" 2>/dev/null; }
rb_new() {
  RB=$SUPPORT/rollback/$(date +%Y%m%d-%H%M%S)
  mkdir -p "$RB/files"; : >"$RB/MANIFEST"
  printf '%s\n' "$RB" >"$SUPPORT/.rollback-current"
}
rb_keep() {   # rb_keep <absolute path>: record it and copy it away when it exists
  p=$1
  if [ -e "$p" ] || [ -L "$p" ]; then
    printf 'E %s\n' "$p" >>"$RB/MANIFEST"
    mkdir -p "$RB/files$(dirname "$p")"; cp -Rp "$p" "$RB/files$p"
  else
    printf 'N %s\n' "$p" >>"$RB/MANIFEST"
  fi
}
