#!/bin/bash
# SPDX-License-Identifier: MIT
# recovery_install_test.sh: tools/phxctl/recovery_install.sh against a fake Data volume (no root, no chown). Runs on
# macOS (PlistBuddy, plutil), or Linux with the lib/bin shims. Uses a stub payload, so it needs no build.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); R=$HERE/../..; S=$R/tools/phxctl/recovery_install.sh
. "$HERE/lib/portable.sh"   # MOCKTMP, mock_sedi, MOCK_PB; off macOS the shims in lib/bin (tests/mock/README.md)
T=$(mktemp -d "${TMPDIR:-/tmp}/rinst.XXXXXX"); PASSN=0; FAILN=0; PB=$MOCK_PB
payload() { P=$T/payload; mkdir -p "$P/build/VermilionAccel.kext/Contents/MacOS" "$P/tools/phxctl" "$P/fw/navi31"
  for f in NVMTLDriver libnvmtl_translate.dylib libvulkan_radeon.dylib phxctl mesboot metaltest spirv-val phxaudio; do echo "$f" >"$P/build/$f"; done
  echo kext >"$P/build/VermilionAccel.kext/Contents/MacOS/VermilionAccel"; echo fw >"$P/fw/navi31/smu_13_0_0.bin"
  cp "$R"/tools/phxctl/*.sh "$R"/tools/phxctl/*.py "$R/tools/phxctl/local.phxboot.plist.in" "$P/tools/phxctl/"; }
data() {   # data <user>...: a fake Data volume with those users (uid 501, 502, ...)
  D=$T/data; rm -rf "$D"; mkdir -p "$D/private/var/db/dslocal/nodes/Default/users" "$D/Library/Preferences" "$D/Users/Shared"
  local u id=501
  for u in "$@"; do
    "$PB" -c "Add :uid array" -c "Add :uid:0 string $id" -c "Add :gid array" -c "Add :gid:0 string 20" -c "Add :home array" \
          -c "Add :home:0 string /Users/$u" "$D/private/var/db/dslocal/nodes/Default/users/$u.plist" >/dev/null
    mkdir -p "$D/Users/$u"; id=$((id+1)); done
  "$PB" -c "Add :uid array" -c "Add :uid:0 string 0" "$D/private/var/db/dslocal/nodes/Default/users/root.plist" >/dev/null; }
run() { VERMILION_PAYLOAD="$T/payload" VERMILION_DATA="$T/data" VERMILION_NOCHOWN=1 VERMILION_PLISTBUDDY="$PB" "$@" sh "$S" >"$T/out" 2>&1; echo $? >"$T/rc"; }
check() { local name=$1 ok=1 c; shift
  for c in "$@"; do eval "$c" || { ok=0; echo "    failed: $c"; }; done
  if [ $ok = 1 ]; then PASSN=$((PASSN+1)); echo "PASS  $name"; else FAILN=$((FAILN+1)); echo "FAIL  $name"; sed 's/^/    /' "$T/out"; fi; }

payload; data alice; run env
D=$T/data; G=$D/Users/alice/gpu; GB=$D/Library/GPUBundles
check fresh '[ "$(cat "$T/rc")" = 0 ]' '[ -f "$GB/NVMTLDriver.bundle/Contents/Info.plist" ]' 'plutil -lint "$GB/NVMTLDriver.bundle/Contents/Info.plist" >/dev/null' \
  '[ "$(cat "$GB/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver")" = NVMTLDriver ]' '[ -f "$GB/nvmtl/libvulkan_radeon.dylib" ]' '[ -d "$GB/nvmtl/aircache" ]' \
  '[ "$(cat "$GB/nvmtl-allow.txt")" = "*" ]' '[ -f "$D/Library/Extensions/VermilionAccel.kext/Contents/MacOS/VermilionAccel" ]' \
  '[ -x "$D/usr/local/sbin/mesboot" ]' '[ -x "$D/usr/local/bin/spirv-val" ]' '[ -x "$G/phxboot-navi31.sh" ]' '[ -x "$G/phxctl/navi31_up.sh" ]' \
  '[ -x "$G/phxctl/bringup_navi31.sh" ]' '[ -x "$G/phxaudio" ] && [ -x "$G/audio_match.sh" ]' 'cmp -s "$G/phxboot-pre.sh" "$R/tools/phxctl/esp_flags.sh"' '[ -f "$G/fw/navi31/smu_13_0_0.bin" ]' \
  '[ ! -e "$G/phxboot-sdma" ] && [ ! -e "$G/phxboot-cg" ] && [ ! -e "$G/phxboot-uclk" ]' '[ ! -e "$G/phxboot-desktop" ] && [ ! -e "$G/phxboot-auto" ]' \
  'grep -q "<string>/Users/alice/gpu/phxboot-navi31.sh</string>" "$D/Library/LaunchDaemons/local.phxboot.plist"' \
  'grep -q "<key>PHX_USER</key><string>alice</string>" "$D/Library/LaunchDaemons/local.phxboot.plist"' \
  '[ "$($PB -c "Print :AutomaticDownload" "$D/Library/Preferences/com.apple.SoftwareUpdate.plist")" = false ]' \
  '[ "$($PB -c "Print :AutomaticallyInstallMacOSUpdates" "$D/Library/Preferences/com.apple.SoftwareUpdate.plist")" = false ]' \
  '[ ! -d "$D/Users/alice/vermilion-rollback" ]'

echo old >"$GB/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver"; echo cached >"$GB/nvmtl/spvcache/x"; run env
check reinstall_keeps_rollback '[ "$(cat "$T/rc")" = 0 ]' 'ls "$D"/Users/alice/vermilion-rollback/*/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver >/dev/null 2>&1' \
  'grep -q old "$D"/Users/alice/vermilion-rollback/*/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver' '[ "$(cat "$GB/nvmtl/spvcache/x")" = cached ]'

data alice bob; run env
check two_users_refused '[ "$(cat "$T/rc")" != 0 ]' 'grep -q "several users" "$T/out"' '[ ! -e "$T/data/Library/GPUBundles" ]'
data alice bob; run env VERMILION_USER=bob
check two_users_pick '[ "$(cat "$T/rc")" = 0 ]' '[ -x "$T/data/Users/bob/gpu/phxboot-navi31.sh" ]' 'grep -q "<string>bob</string>" "$T/data/Library/LaunchDaemons/local.phxboot.plist"'
data; run env
check no_user '[ "$(cat "$T/rc")" != 0 ]' 'grep -q "no user with uid >= 501" "$T/out"'
data alice; rm "$T/payload/build/spirv-val"; run env
check payload_incomplete '[ "$(cat "$T/rc")" != 0 ]' 'grep -q "payload incomplete" "$T/out"' '[ ! -e "$T/data/Library/GPUBundles" ]'

echo "RESULT: $PASSN passed, $FAILN failed"; rm -rf "$T"; [ $FAILN = 0 ]
