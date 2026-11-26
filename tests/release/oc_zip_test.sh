#!/bin/bash
# SPDX-License-Identifier: MIT
# oc_zip_test.sh: hardware-free test of scripts/release/make-oc-zip.sh and config-snippet.plist: the snippet holds the
# entries of INSTALL.md section 1 ("What the OpenCore snippet changes") and no machine identity, and the zip holds
# exactly what docs/RELEASE.md lists.
# Uses dummy kexts (tests/release/dummy.sh). Needs python3 and zip. Bash 3.2.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..
. "$HERE/dummy.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/oczip-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }   # check <name> <shell condition>
SNIP=$R/scripts/release/config-snippet.plist
VER=0.1.0-preview

# the snippet: well-formed, with the entries of INSTALL.md section 1 ("What the OpenCore snippet changes"), and nothing
# that names a machine
check "snippet lints" 'python3 -I -c "import plistlib,sys; plistlib.load(open(sys.argv[1],\"rb\"))" "$SNIP"'
python3 -I - "$SNIP" <<'EOF'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
errs = []
def need(c, m):
    if not c: errs.append(m)
add = [e["BundlePath"] for e in p["Kernel"]["Add"]]
need(add == ["Lilu.kext", "VermilionBoot.kext", "VermilionTrust.kext", "VermilionAudio.kext"], f"Kernel > Add order {add}")
for e in p["Kernel"]["Add"]:
    need(e["MinKernel"] == "25.0.0" or e["BundlePath"] == "Lilu.kext", f"MinKernel of {e['BundlePath']}")
    need(e["ExecutablePath"] == "Contents/MacOS/" + e["BundlePath"][:-5], f"ExecutablePath of {e['BundlePath']}")
pt = p["Kernel"]["Patch"]
need(len(pt) == 1, "one kernel patch")
need(pt[0]["Identifier"] == "com.apple.driver.AppleGraphicsDevicePolicy", "AGDP patch identifier")
need(pt[0]["Find"] == b"board-id" and pt[0]["Replace"] == b"board-ix" and pt[0]["Count"] == 0 and pt[0]["MinKernel"] == "25.0.0", "AGDP patch bytes")
g = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
need(p["NVRAM"]["Add"][g]["csr-active-config"] == bytes([3, 10, 0, 0]), "csr-active-config 030A0000")
ba = p["NVRAM"]["Add"][g]["boot-args"].split()
need(sorted(ba) == ["ipc_control_port_options=0", "phxdebug=1"], f"boot-args {ba}")
need(sorted(p["NVRAM"]["Delete"][g]) == ["boot-args", "csr-active-config"], "NVRAM Delete")
need(p["Misc"]["Security"]["SecureBootModel"] == "Disabled", "SecureBootModel")
need(p["Booter"]["Quirks"]["ResizeAppleGpuBars"] == 10, "ResizeAppleGpuBars")
need(set(p.keys()) == {"Booter", "Kernel", "Misc", "NVRAM"}, f"top-level sections {sorted(p.keys())}")
for e in errs: print("  " + e)
sys.exit(1 if errs else 0)
EOF
snip_rc=$?
check "snippet has the INSTALL.md section 1 entries" "[ $snip_rc = 0 ]"
check "snippet has no machine identity" 'python3 -I "$R/scripts/release/check-snippet.py" "$SNIP"'

# the guard itself: a snippet that carries SMBIOS is refused, at any depth
python3 -I - "$T" <<'EOF'
import plistlib, sys
for name, d in {"serial": {"PlatformInfo": {"Generic": {"SystemSerialNumber": "X"}}}, "mlb": {"Kernel": {"x": [{"MLB": "y"}]}}, "rom": {"NVRAM": {"ROM": b"abc"}}}.items():
    plistlib.dump(d, open(f"{sys.argv[1]}/bad-{name}.plist", "wb"))
EOF
for n in serial mlb rom; do check "snippet check refuses $n" '! python3 -I "$R/scripts/release/check-snippet.py" "$T/bad-$n.plist" 2>/dev/null'; done

# the zip
dummy_kexts "$T/kexts" "$VER"
out=$(sh "$R/scripts/release/make-oc-zip.sh" --version "$VER" --kexts "$T/kexts" --out "$T/out" 2>&1); rc=$?
check "zip builds" '[ $rc = 0 ] && [ -f "$T/out/Vermilion-$VER-OpenCore.zip" ]'
if [ -f "$T/out/Vermilion-$VER-OpenCore.zip" ]; then
  L=$(unzip -Z1 "$T/out/Vermilion-$VER-OpenCore.zip")
  for f in Kexts/VermilionBoot.kext/Contents/MacOS/VermilionBoot Kexts/VermilionTrust.kext/Contents/Info.plist \
           Kexts/VermilionAudio.kext/Contents/MacOS/VermilionAudio config-snippet.plist README.txt NOTICE; do
    check "zip holds $f" 'printf "%s\n" "$L" | grep -qx "$f"'
  done
  check "zip holds LICENSES/" 'printf "%s\n" "$L" | grep -q "^LICENSES/"'
  check "zip holds exactly 3 kexts" '[ "$(printf "%s\n" "$L" | grep -c "^Kexts/[A-Za-z]*\.kext/\$")" = 3 ]'
  check "zip holds no config.plist, firmware or EFI folder" '! printf "%s\n" "$L" | grep -E "(^|/)config\.plist|\.bin\$|^EFI/|\.rom\$"'
  unzip -p "$T/out/Vermilion-$VER-OpenCore.zip" README.txt >"$T/readme"
  check "README carries the version" 'grep -q "Vermilion $VER" "$T/readme"'
  check "zip's snippet is the repository's" 'unzip -p "$T/out/Vermilion-$VER-OpenCore.zip" config-snippet.plist | cmp -s - "$SNIP"'
fi

# refusals
out=$(sh "$R/scripts/release/make-oc-zip.sh" --version 0.2.0 --kexts "$T/kexts" --out "$T/out2" 2>&1); rc=$?
check "refuses a kext with another version" '[ $rc != 0 ] && printf "%s" "$out" | grep -q CFBundleShortVersionString'
rm -rf "$T/kexts/VermilionAudio.kext"
out=$(sh "$R/scripts/release/make-oc-zip.sh" --version "$VER" --kexts "$T/kexts" --out "$T/out3" 2>&1); rc=$?
check "refuses a missing kext" '[ $rc != 0 ] && printf "%s" "$out" | grep -q VermilionAudio'
dummy_kexts "$T/kexts" "$VER"
out=$(sh "$R/scripts/release/make-oc-zip.sh" --version "$VER" --kexts "$T/kexts" --out "$T/out4" --snippet "$T/bad-serial.plist" 2>&1); rc=$?
check "refuses a snippet with SMBIOS" '[ $rc != 0 ] && printf "%s" "$out" | grep -q "machine identity"'
out=$(sh "$R/scripts/release/make-oc-zip.sh" --version "x.y" --kexts "$T/kexts" --out "$T/out5" 2>&1); rc=$?
check "refuses a malformed version" '[ $rc = 2 ]'

# SHA256SUMS
mkdir -p "$T/sums"; echo a >"$T/sums/a.zip"; echo b >"$T/sums/b.pkg"
sh "$R/scripts/release/make-sums.sh" "$T/sums" a.zip b.pkg >/dev/null
check "SHA256SUMS verifies" '(cd "$T/sums" && { shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 || sha256sum -c SHA256SUMS >/dev/null 2>&1; })'
check "SHA256SUMS lists names, not paths" '[ "$(wc -l <"$T/sums/SHA256SUMS" | tr -d " ")" = 2 ] && ! grep -q / "$T/sums/SHA256SUMS"'
check "make-sums refuses a missing file" '! sh "$R/scripts/release/make-sums.sh" "$T/sums" nope.zip 2>/dev/null'

echo "oc_zip_test: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
