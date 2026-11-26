#!/bin/sh
# SPDX-License-Identifier: MIT
# test_switch_files.sh: the Metal plugin's display switches are opt-outs (2026-11-26). GPU present, async GPU present and
# direct scan-out are on by default; the files are ws-gpu-present-off, ws-gpu-present-async-off and ws-direct-off, read
# as "on unless the file exists" (stat() != 0). The old opt-in files must not be read any more. Source check, no hardware:
#   sh tests/plugin/test_switch_files.sh
S=$(cd "$(dirname "$0")/../../src/metal-plugin" && pwd)
fails=0; checks=0
ck() { checks=$((checks+1)); if ! eval "$2"; then echo "FAIL  $1"; fails=$((fails+1)); fi; }
stats() { cat "$S"/*.m "$S"/*.c "$S"/*.h | grep -E 'stat\("/Library/GPUBundles/nvmtl/'; }
for f in ws-gpu-present-off ws-gpu-present-async-off ws-direct-off; do
  ck "$f is read, and the default is on (stat != 0)" "stats | grep -F \"nvmtl/$f\\\"\" | grep -q '!= 0'"
  ck "$f is read" "[ \$(stats | grep -cF \"nvmtl/$f\\\"\") -ge 1 ]"
done
for f in ws-gpu-present ws-gpu-present-async ws-direct; do
  ck "the old opt-in file $f is not stat()ed" "! stats | grep -qF \"nvmtl/$f\\\"\""
done
ck "no stat() of a switch file means 'present = on'" "! stats | grep -E 'ws-(gpu-present|direct)' | grep -v -- '-off' | grep -q ."
echo "test_switch_files: $((checks-fails))/$checks checks passed"
[ $fails = 0 ]
