#!/bin/bash
# SPDX-License-Identifier: MIT
# espflags_test.sh: tools/phxctl/esp_flags.sh (the phxboot pre-hook that takes flags staged on the EFI partition)
# against a fake diskutil and fake EFI partitions. No root, no disks touched. macOS, or Linux through lib/portable.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); S=$HERE/../../tools/phxctl/esp_flags.sh
. "$HERE/lib/portable.sh"   # MOCKTMP, mock_sedi, MOCK_PB; off macOS the shims in lib/bin (tests/mock/README.md)
T=$(mktemp -d "${TMPDIR:-/tmp}/espflags.XXXXXX"); PASSN=0; FAILN=0
fake() {   # fake <mounted 0|1>: one EFI partition disk9s1, its contents in $T/esp; mount = a symlink
  mkdir -p "$T/bin" "$T/esp/vermilion/flags" "$T/gpu"; rm -f "$T/mounted" "$T/calls" "$T/mc" "$T/mfail"; [ "$1" = 1 ] && echo "$T/esp" >"$T/mounted"
  cat >"$T/bin/diskutil" <<EOF
#!/bin/bash
echo "\$*" >>"$T/calls"
case "\$1" in
  list) printf '   0:      GUID_partition_scheme                        *1.0 TB     disk9\n   1:                        EFI NO NAME                 2.1 GB     disk9s1\n   2:                 Apple_APFS Container disk10        83.8 GB    disk9s3\n';;
  info) [ -e "$T/mounted" ] && echo "   Mount Point:               \$(cat "$T/mounted")" || echo "   Mount Point:               "; ;;
  mount) echo x >>"$T/mc"; if [ -s "$T/mfail" ]; then m=\$(cat "$T/mfail"); echo \$((m-1)) >"$T/mfail"; [ \$m -le 0 ] || exit 1; fi
         [ "\$2" = -mountPoint ] && { rmdir "\$3" 2>/dev/null; ln -s "$T/esp" "\$3"; echo "\$3" >"$T/mounted"; };;
  unmount) rm -f "\$2" "$T/mounted";;
esac
EOF
  chmod +x "$T/bin/diskutil"; }
run() { ESPF_STAT="$MOCK_STAT" ESPF_DONE="$T/done" ESPF_TRIES=${ESPF_TRIES:-3} ESPF_DISKUTIL="$T/bin/diskutil" ESPF_MNT="$T/mnt" bash "$S" "$T/gpu" >"$T/out" 2>&1; }
check() {   # check <name> <cond> ...: every cond (a shell test) must hold
  local name=$1 ok=1 c; shift
  for c in "$@"; do eval "$c" || { ok=0; echo "    failed: $c"; }; done
  if [ $ok = 1 ]; then PASSN=$((PASSN+1)); echo "PASS  $name"; else FAILN=$((FAILN+1)); echo "FAIL  $name"; sed 's/^/    /' "$T/out"; fi
  rm -rf "$T/esp" "$T/gpu" "$T/mnt"; }

fake 0; : >"$T/esp/vermilion/flags/phxboot-desktop"; echo 456 >"$T/esp/vermilion/flags/phxboot-uclk"; run
check set_unmounted '[ -e "$T/gpu/phxboot-desktop" ]' '[ "$(cat "$T/gpu/phxboot-uclk")" = 456 ]' \
  '[ -z "$(ls "$T/esp/vermilion/flags")" ]' 'grep -q "set phxboot-uclk = 456" "$T/out"' 'grep -q "^unmount" "$T/calls"' '[ ! -e "$T/mnt" ]'

fake 1; touch "$T/gpu/phxboot-off"; : >"$T/esp/vermilion/flags/phxboot-off.rm"; run
check rm_mounted '[ ! -e "$T/gpu/phxboot-off" ]' 'grep -q "removed phxboot-off" "$T/out"' '! grep -q "^mount" "$T/calls"' '! grep -q "^unmount" "$T/calls"'

fake 0; : >"$T/esp/vermilion/flags/evil"; : >"$T/esp/vermilion/flags/phxboot-sdma"; run
check ignore_other '[ ! -e "$T/gpu/evil" ]' '[ -e "$T/esp/vermilion/flags/evil" ]' '[ -e "$T/gpu/phxboot-sdma" ]' 'grep -q "ignored evil" "$T/out"'

fake 0; rmdir "$T/esp/vermilion/flags"; run
check no_flags_dir 'grep -q "no vermilion/flags" "$T/out"' 'grep -q "^unmount" "$T/calls"' '[ -z "$(ls -A "$T/gpu")" ]'

# info prints a non-path Mount Point value for an unmounted partition: treated as unmounted
fake 0; mock_sedi 's|echo "   Mount Point:               "; ;;|echo "   Mount Point:               Not mounted"; ;;|' "$T/bin/diskutil"; : >"$T/esp/vermilion/flags/phxboot-desktop"; run
check notmounted_text '[ -e "$T/gpu/phxboot-desktop" ]' 'grep -q "^mount" "$T/calls"'

# the first two mounts fail (diskarbitrationd not up yet): retried
fake 0; echo 2 >"$T/mfail"; rm -f "$T/mc"; : >"$T/esp/vermilion/flags/phxboot-desktop"; run
check mount_retry '[ -e "$T/gpu/phxboot-desktop" ]' '[ "$(wc -l <"$T/mc" | tr -d " ")" = 3 ]'; rm -f "$T/mc" "$T/mfail"

# no EFI partition ever listed: gives up after ESPF_TRIES
fake 0; mock_sedi 's|  list) printf|  list) exit 0; printf|' "$T/bin/diskutil"; ESPF_TRIES=2 run
check no_efi_listed 'grep -q "no EFI partition listed after 2s" "$T/out"'

# run-once.sh: moved off the EFI partition, then run with the vermilion dir and <G>; it can set flags for this boot
fake 0; printf 'echo "ran with $1"; touch "$2/phxboot-desktop"; exit 4\n' >"$T/esp/vermilion/run-once.sh"; rm -rf "$T/done"; run
check run_once '[ ! -e "$T/esp/vermilion/run-once.sh" ]' 'ls "$T"/done/run-once-*.sh >/dev/null 2>&1' '[ -e "$T/gpu/phxboot-desktop" ]' \
  'grep -q "run-once: ran with $T/mnt/vermilion" "$T/out"' 'grep -q "run-once: exit 4" "$T/out"' 'grep -q "^unmount" "$T/calls"'

# air_runtime_install.sh against a fake root: md5 checked, files in place; a bad md5 installs nothing
A=$T/air; R=$T/root; mkdir -p "$A" "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS"; echo llvm >"$A/libLLVM.dylib"; echo zstd >"$A/libzstd.1.dylib"; echo lic >"$A/LLVM-LICENSE.txt"
( cd "$A" && md5 -r libLLVM.dylib libzstd.1.dylib | awk '{print $1"  "$2}' >MD5SUMS )
VERMILION_NOCHOWN=1 sh "$HERE/../../tools/phxctl/air_runtime_install.sh" "$A" "$R" >"$T/out" 2>&1; echo $? >"$T/rc"
check air_install '[ "$(cat "$T/rc")" = 0 ]' '[ "$(cat "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime/libLLVM.dylib")" = llvm ]' \
  '[ -f "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime/libzstd.1.dylib" ]' '[ -f "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/Resources/air-runtime/LLVM-LICENSE.txt" ]'
rm -rf "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime"; echo tampered >"$A/libLLVM.dylib"
VERMILION_NOCHOWN=1 sh "$HERE/../../tools/phxctl/air_runtime_install.sh" "$A" "$R" >"$T/out" 2>&1; echo $? >"$T/rc"
check air_badmd5 '[ "$(cat "$T/rc")" != 0 ]' 'grep -q "does not match MD5SUMS" "$T/out"' '[ ! -e "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime/libLLVM.dylib" ]'
# our build's layout (notices in LICENSES/) is the default source; with none, an existing copy stays as a fallback
echo llvm >"$A/libLLVM.dylib"; mkdir -p "$A/LICENSES"; echo apache >"$A/LICENSES/LLVM-LICENSE.txt"; echo bsd >"$A/LICENSES/ZSTD-LICENSE.txt"; rm -f "$A/LLVM-LICENSE.txt"
( cd "$A" && md5 -r libLLVM.dylib libzstd.1.dylib | awk '{print $1"  "$2}' >MD5SUMS )
mkdir -p "$T/out-ours"; cp -R "$A" "$T/out-ours/air-runtime"
VERMILION_OUT="$T/out-ours" VERMILION_NOCHOWN=1 sh "$HERE/../../tools/phxctl/air_runtime_install.sh" "" "$R" >"$T/out" 2>&1; echo $? >"$T/rc"
check air_default_ours '[ "$(cat "$T/rc")" = 0 ]' '[ "$(cat "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime/libLLVM.dylib")" = llvm ]' \
  '[ -f "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/Resources/air-runtime/ZSTD-LICENSE.txt" ]'
VERMILION_OUT="$T/nothing-here" VERMILION_NOCHOWN=1 sh "$HERE/../../tools/phxctl/air_runtime_install.sh" "" "$R" >"$T/out" 2>&1; echo $? >"$T/rc"
check air_fallback_kept '[ "$(cat "$T/rc")" = 0 ]' 'grep -q "fallback" "$T/out"'
rm -rf "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime"
VERMILION_OUT="$T/nothing-here" VERMILION_NOCHOWN=1 sh "$HERE/../../tools/phxctl/air_runtime_install.sh" "" "$R" >"$T/out" 2>&1; echo $? >"$T/rc"
check air_none '[ "$(cat "$T/rc")" != 0 ]' 'grep -q "scripts/build/llvm.sh" "$T/out"'

echo "RESULT: $PASSN passed, $FAILN failed"; rm -rf "$T"; [ $FAILN = 0 ]
