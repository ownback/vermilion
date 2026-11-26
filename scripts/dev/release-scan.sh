#!/bin/bash
# SPDX-License-Identifier: MIT
# release-scan.sh [-v] [--commits <rev-range>] [path ...]: scan a tree or unpacked release artefacts for what must never
# be published (CLAUDE.md hard rules 4-6, docs/RELEASE.md). Generic patterns only: it knows no machine's values, so it
# complements the guard's private-patterns check (scripts/dev/private-patterns.sh), it doesn't replace it.
#
# Findings (exit 1):
#   mac          a MAC address
#   uuid         a UUID that isn't one of the public Apple / UEFI / OpenCore GUIDs below
#   email        an e-mail address that isn't a noreply address or an example
#   home         a home path (/Users/<name>, /home/<name>) other than the test users below
#   smbios       a plist with a filled SystemSerialNumber, MLB, ROM or SystemUUID
#   firmware     a file whose md5 is one of tools/firmware/fw.lock's AMD firmware files, or a Mach-O that defines
#                the C3 firmware slice (kPhxC3Image; gone since kext b163, which holds no firmware: kept as a regression check)
#   edid-serial  an EDID block (in a binary file) with a serial number (bytes 12-15, or a 0xFF descriptor with text)
#   apple-asm    an AT&T x86 instruction with operands in a text file, outside an asm statement (rule 6: no Apple
#                disassembly; our own asm is in __asm__ / asm())
#   commit-email (--commits) a commit whose author or committer address isn't a GitHub / Anthropic noreply address
# Text files are searched as they are, binary files through `strings`. .zip and .tar.gz paths are unpacked into a
# temporary directory first, .pkg paths too where pkgutil exists. .git directories are skipped.
# Documented exceptions (third-party attributions, generated test data) are in release-scan.allow next to this
# script: one "<kind> <ERE on the reported location>" per line; RELEASE_SCAN_ALLOW=<file> picks another (or /dev/null).
# Values are masked in the output; -v prints them (never in a public CI log). Bash 3.2.
set -u
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
FWLOCK=${RELEASE_SCAN_FWLOCK:-$ROOT/tools/firmware/fw.lock}
ALLOWF=${RELEASE_SCAN_ALLOW:-$HERE/release-scan.allow}
VERBOSE=0 RANGE=""
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -v) VERBOSE=1 ;;
    --commits) RANGE=${2:?--commits needs a range}; shift ;;
    -h|--help) sed -n '3,/^set -u/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PATHS+=("$1") ;;
  esac
  shift
done
[ ${#PATHS[@]} -gt 0 ] || [ -n "$RANGE" ] || PATHS=(.)

# Public identifiers that may appear anywhere: Apple's NVRAM GUID, the UEFI global variable GUID, OpenCore's GUIDs.
ALLOW_UUID='7C436110-AB2A-4BBB-A880-FE41995C9F82|8BE4DF61-93CA-11D2-AA0D-00E098032B8C|4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14|4D1FDA02-38C7-4A6A-9CC6-4BCCA8B38C14'
# Placeholders in tests and examples: a MAC ending in a counting or letter pattern, a UUID with zero or counting groups.
ALLOW_MAC='(aa:bb:cc|dd:ee:ff|11:22:33|22:33:44|33:44:55|44:55:66|00:00:00|ff:ff:ff)$'
ALLOW_UUID="$ALLOW_UUID|-0000-0000-0000-0{12}$|^12345678-|^00000000-0000-0000-0000-"
ALLOW_EMAIL='noreply@anthropic\.com|users\.noreply\.github\.com|noreply@github\.com|@example\.(com|org|net|invalid)$|\.invalid$'
ALLOW_HOME='/(Users|home)/(Shared|alice|bob|gpu|runner|user|name|you|me)([^A-Za-z0-9._-]|$)|/(Users|home)/<'

TMP=$(mktemp -d "${TMPDIR:-/tmp}/release-scan.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT

mask() { if [ $VERBOSE = 1 ]; then printf '%s' "$1"; else printf '%s***' "$(printf '%s' "$1" | cut -c1-2)"; fi; }
allowed() {  # allowed <kind> <location>: listed in the allow file
  [ -r "$ALLOWF" ] || return 1
  grep -vE '^[[:space:]]*(#|$)' "$ALLOWF" | while read -r k re; do
    [ "$k" = "$1" ] && printf '%s' "$2" | grep -qE "$re" && echo y && break
  done | grep -q y
}
report() { allowed "$1" "$2" && return 0; echo "release-scan: $1 $2${3:+ ($(mask "$3"))}"; }

# grep_text <kind> <pattern> <allow-pattern or ""> <file...>: text files, with line numbers.
grep_text() {
  local kind=$1 pat=$2 allow=$3; shift 3
  grep -rHnIoE --exclude-dir=.git --exclude=.git "$pat" "$@" 2>/dev/null | while IFS= read -r line; do
    val=${line#*:*:}
    [ -n "$allow" ] && printf '%s' "$val" | grep -qiE "$allow" && continue
    report "$kind" "${line%:"$val"}" "$val"
  done
}

# grep_strings <kind> <pattern> <allow> <file>: one binary file through strings.
grep_strings() {
  local kind=$1 pat=$2 allow=$3 f=$4
  strings -a "$f" 2>/dev/null | grep -oE "$pat" | sort -u | while IFS= read -r val; do
    [ -n "$allow" ] && printf '%s' "$val" | grep -qiE "$allow" && continue
    report "$kind" "$f" "$val"
  done
}

PAT_MAC='([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'
PAT_UUID='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
PAT_EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
PAT_HOME='/(Users|home)/[A-Za-z0-9<._-]+'
PAT_ASM='(movl|movq|leal|leaq|cmpl|cmpq|testl|testq|callq|jmpq|btl|xorl|addl|subl)[[:space:]]+[$%-][^ ]*,'

# EDIDs with a serial, in one binary file: hex-dump it, find each 8-byte header whose 128-byte block sums to 0 mod 256
# (the EDID checksum; code and tables in a kext hold the 8 header bytes too, seen 38 times in VermilionBoot b163), and
# look at the serial bytes (12-15) and the four 18-byte descriptors (bytes 54-125) for a "00 00 00 ff" serial-string
# descriptor with text in it (an emptied one, 0x0A then space padding as in docs/EDID.md, or all spaces or NULs, is no
# serial).
edid_serials() {
  od -An -v -tx1 "$1" | tr -d ' \n' | awk -v f="$1" '
  function byte_sum(hex,   k, sum) {  # the sum of the bytes in a string of lower-case hex digit pairs
    for (k = 1; k < length(hex); k += 2) sum += hx[substr(hex, k, 2)]
    return sum
  }
  BEGIN { for (n = 0; n < 256; n++) hx[sprintf("%02x", n)] = n }
  {
    s = $0; off = 0
    while ((i = index(s, "00ffffffffffff00")) > 0) {
      b = substr(s, i, 256)
      if (length(b) == 256 && (off + i - 1) % 2 == 0 && byte_sum(b) % 256 == 0) {
        bad = substr(b, 25, 8) != "00000000"
        for (d = 0; d < 4; d++)
          if (substr(b, 109 + d * 36, 8) == "000000ff" && substr(b, 119 + d * 36, 26) !~ /^(0a)?(20|00)*$/) bad = 1
        if (bad) print f ": EDID at byte " (off + i - 1) / 2
      }
      off += i + 15; s = substr(s, i + 16)
    }
  }'
}

scan_dir() {
  local d=$1
  grep_text mac "$PAT_MAC" "$ALLOW_MAC" "$d"
  grep_text uuid "$PAT_UUID" "$ALLOW_UUID" "$d"
  grep_text email "$PAT_EMAIL" "$ALLOW_EMAIL" "$d"
  grep_text home "$PAT_HOME" "$ALLOW_HOME" "$d"
  grep -rHnIE --exclude-dir=.git --exclude=.git "$PAT_ASM" "$d" 2>/dev/null | grep -vE '__asm__|asm\(|asm volatile' |
    while IFS= read -r line; do report apple-asm "$(printf '%s' "$line" | cut -d: -f1-2)"; done
  grep -rlIE --exclude-dir=.git --include='*.plist' '<key>(SystemSerialNumber|MLB|ROM|SystemUUID)</key>' "$d" 2>/dev/null |
    while IFS= read -r f; do
      # A filled value: the key followed by a non-empty <string> or <data> (placeholders are empty or all zeros).
      if tr -d '\n\t ' < "$f" | grep -qE '<key>(SystemSerialNumber|MLB|SystemUUID)</key><string>[^<0]+</string>|<key>ROM</key><data>[^<A]+</data>'; then
        report smbios "$f"
      fi
    done
  # AMD firmware: only files of a size fw.lock lists get an md5.
  local sums sizes
  sums=$(grep -vE '^#|^$' "$FWLOCK" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
  sizes=$(grep -vE '^#|^$' "$FWLOCK" 2>/dev/null | awk '{print $3}' | sort -u)
  for n in $sizes; do
    find "$d" -type f ! -path '*/.git/*' ! -name .git -size "${n}c" | while IFS= read -r f; do
      m=$( (md5 -q "$f" 2>/dev/null || md5sum "$f" 2>/dev/null | awk '{print $1}') | head -1)
      case " $sums " in *" $m "*) report firmware "$f" ;; esac
    done
  done
  # Binary files: every non-empty file minus the ones grep -I reads as text (BSD grep -I skips binary files, so -L
  # can't list them).
  find "$d" -type f ! -path '*/.git/*' ! -name .git -size +0 | sort > "$TMP/all"
  grep -rlI --exclude-dir=.git --exclude=.git '' "$d" 2>/dev/null | sort > "$TMP/text"
  comm -23 "$TMP/all" "$TMP/text" | while IFS= read -r f; do
    grep_strings mac "$PAT_MAC" "$ALLOW_MAC" "$f"
    grep_strings uuid "$PAT_UUID" "$ALLOW_UUID" "$f"
    grep_strings email "$PAT_EMAIL" "$ALLOW_EMAIL" "$f"
    grep_strings home "$PAT_HOME" "$ALLOW_HOME" "$f"
    edid_serials "$f" | while IFS= read -r e; do report edid-serial "$e"; done
    if command -v nm >/dev/null 2>&1 && nm "$f" 2>/dev/null | grep -q 'kPhxC3Image'; then report firmware "$f: kPhxC3Image"; fi
  done
}

for p in ${PATHS[@]+"${PATHS[@]}"}; do
  case "$p" in
    *.zip)    u="$TMP/$(basename "$p").d"; mkdir -p "$u"; unzip -q "$p" -d "$u" || { echo "release-scan: can't unpack $p" >&2; exit 2; }; scan_dir "$u" ;;
    *.tar.gz|*.tgz) u="$TMP/$(basename "$p").d"; mkdir -p "$u"; tar -xzf "$p" -C "$u" || { echo "release-scan: can't unpack $p" >&2; exit 2; }; scan_dir "$u" ;;
    *.pkg)    command -v pkgutil >/dev/null || { echo "release-scan: $p needs pkgutil (macOS)" >&2; exit 2; }
              u="$TMP/$(basename "$p").d"; pkgutil --expand-full "$p" "$u" >/dev/null || exit 2; scan_dir "$u" ;;
    *)        [ -e "$p" ] || { echo "release-scan: no such path: $p" >&2; exit 2; }; scan_dir "$p" ;;
  esac
done > "$TMP/out"

if [ -n "$RANGE" ]; then
  git log --format='%h %ae%n%h %ce' "$RANGE" 2>/dev/null | sort -u | while read -r h a; do
    printf '%s' "$a" | grep -qE '(^|[+.@])users\.noreply\.github\.com$|^noreply@github\.com$|^noreply@anthropic\.com$' && continue
    report commit-email "$h" "$a"
  done >> "$TMP/out"
fi

if [ -s "$TMP/out" ]; then
  cat "$TMP/out"
  echo "release-scan: $(wc -l < "$TMP/out" | tr -d ' ') finding(s)"
  exit 1
fi
echo "release-scan: clean"
