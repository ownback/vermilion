#!/bin/bash
# SPDX-License-Identifier: MIT
# release_scan_test.sh: hardware-free test of scripts/dev/release-scan.sh. Each case plants one kind of value in its
# own temporary directory and checks the exit code and the reported kind. The planted values are put together at run
# time, so this file itself scans clean. Bash 3.2.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCAN=$HERE/../../scripts/dev/release-scan.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/rscan-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
export RELEASE_SCAN_ALLOW=/dev/null RELEASE_SCAN_FWLOCK=$T/fw.lock
: > "$T/fw.lock"
PASS=0 FAIL=0
C=":"; AT="@"; D="-"; U=/Users   # joined at run time

# check <name> <expected rc> <expected kind or "clean"> <dir or args...>
check() {
  local name=$1 want=$2 kind=$3; shift 3
  out=$(bash "$SCAN" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -q -- "$( [ "$kind" = clean ] && echo 'release-scan: clean' || echo "release-scan: $kind ")"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL $name: rc=$rc (want $want), output:"; printf '%s\n' "$out" | sed 's/^/  /'
  fi
}
case_dir() { mkdir -p "$T/$1"; echo "$T/$1"; }

d=$(case_dir clean); echo "nothing to see" > "$d/a.txt"
check clean 0 clean "$d"

d=$(case_dir mac); echo "ether 3a${C}9f${C}41${C}7c${C}d2${C}e8" > "$d/a.txt"
check mac 1 mac "$d"
d=$(case_dir mac-placeholder); echo "ether a4${C}5e${C}60${C}aa${C}bb${C}cc" > "$d/a.txt"
check mac_placeholder 0 clean "$d"

d=$(case_dir email); echo "contact jane.doe${AT}mail.test" > "$d/a.txt"
check email 1 email "$d"
d=$(case_dir email-noreply); echo "Co-Authored-By: x <1+x${AT}users.noreply.github.com>" > "$d/a.txt"
check email_noreply 0 clean "$d"

d=$(case_dir home); echo "path $U/jdoe/Projects/x" > "$d/a.txt"
check home 1 home "$d"
d=$(case_dir home-test); echo "path /Users/alice/gpu" > "$d/a.txt"
check home_test_user 0 clean "$d"

d=$(case_dir uuid); echo "id 9f1c2d3e${D}4b5a${D}4c6d${D}8e7f${D}a1b2c3d4e5f6" > "$d/a.txt"
check uuid 1 uuid "$d"
d=$(case_dir uuid-apple); echo "7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args" > "$d/a.txt"
check uuid_apple_guid 0 clean "$d"

d=$(case_dir smbios)
printf '<plist><dict>\n<key>SystemSerialNumber</key>\n<string>%s</string>\n</dict></plist>\n' "Q$(printf 'X%.0s' 1 2 3 4 5 6 7 8 9 10 11)" > "$d/config.plist"
check smbios 1 smbios "$d"
d=$(case_dir smbios-empty)
printf '<plist><dict>\n<key>SystemSerialNumber</key>\n<string></string>\n</dict></plist>\n' > "$d/config.plist"
check smbios_empty 0 clean "$d"

d=$(case_dir firmware); printf 'not really firmware\n' > "$d/gc.bin"
m=$( (md5 -q "$d/gc.bin" 2>/dev/null || md5sum "$d/gc.bin" | awk '{print $1}') )
echo "gc_11_0_0_me.bin $m $(wc -c < "$d/gc.bin" | tr -d ' ')" > "$T/fw.lock"
check firmware 1 firmware "$d"
: > "$T/fw.lock"

edid() {  # edid <file> <serial hex, 8 digits> [<13 text bytes>]: one 128-byte EDID block between NUL padding; with
          # a third argument, its first descriptor (byte 54) is a 0xFF serial-string descriptor holding that text
  local s=$2
  { printf '\000\001\002'; printf '\000\377\377\377\377\377\377\000'; printf '\036\155\001\002'
    printf "\\$(printf '%03o' 0x${s:0:2})\\$(printf '%03o' 0x${s:2:2})\\$(printf '%03o' 0x${s:4:2})\\$(printf '%03o' 0x${s:6:2})"
    if [ $# -ge 3 ]; then
      head -c 38 /dev/zero; printf '\000\000\000\377\000%s' "$3"; head -c 56 /dev/zero
    else
      head -c 112 /dev/zero
    fi; printf '\000\000'; } > "$1"
}
d=$(case_dir edid-serial); edid "$d/k.bin" 0a0b0c0d
check edid_serial 1 edid-serial "$d"
d=$(case_dir edid-clean); edid "$d/k.bin" 00000000
check edid_no_serial 0 clean "$d"
d=$(case_dir edid-desc-serial); edid "$d/k.bin" 00000000 'ABC123456789
'
check edid_descriptor_serial 1 edid-serial "$d"
# the fallback EDIDs' shape (docs/EDID.md): an emptied serial descriptor, 0x0A and space padding
d=$(case_dir edid-desc-empty); edid "$d/k.bin" 00000000 '
            '
check edid_descriptor_empty 0 clean "$d"

d=$(case_dir asm); printf '// quoted: %s $0x1, %%eax\n' "movl" > "$d/a.c"
check apple_asm 1 apple-asm "$d"
d=$(case_dir asm-own); printf '__asm__("%s $0x1, %%eax");\n' "movl" > "$d/a.c"
check own_asm 0 clean "$d"

d=$(case_dir masked); echo "contact jane.doe${AT}mail.test" > "$d/a.txt"
out=$(bash "$SCAN" "$d" 2>&1)
if printf '%s' "$out" | grep -q "jane.doe"; then FAIL=$((FAIL+1)); echo "FAIL masked: value printed without -v"; else PASS=$((PASS+1)); fi
out=$(bash "$SCAN" -v "$d" 2>&1)
if printf '%s' "$out" | grep -q "jane.doe${AT}mail.test"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL verbose: value not printed"; fi

d=$(case_dir allowed); echo "contact jane.doe${AT}mail.test" > "$d/NOTICE.txt"
echo 'email NOTICE\.txt:1$' > "$T/allow"
RELEASE_SCAN_ALLOW=$T/allow check allow_file 0 clean "$d"

d=$(case_dir zip); echo "path $U/jdoe/x" > "$d/a.txt"
if command -v zip >/dev/null 2>&1; then
  (cd "$d" && zip -q ../art.zip a.txt)
  check zip 1 home "$T/art.zip"
fi

r=$T/repo; git init -q "$r"
git -C "$r" -c user.name=t -c user.email="1+t${AT}users.noreply.github.com" commit -q --allow-empty -m ok
(cd "$r" && bash "$SCAN" --commits HEAD >/dev/null 2>&1); rc=$?
if [ $rc = 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL commits_noreply: rc=$rc"; fi
git -C "$r" -c user.name=t -c user.email="t${AT}host.example-isp.test" commit -q --allow-empty -m leak
out=$(cd "$r" && bash "$SCAN" --commits HEAD~1..HEAD 2>&1); rc=$?
if [ $rc = 1 ] && printf '%s' "$out" | grep -q 'release-scan: commit-email '; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL commits_personal: rc=$rc $out"; fi

echo "release_scan_test: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
