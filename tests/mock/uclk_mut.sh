#!/bin/bash
# SPDX-License-Identifier: MIT
# uclk_mut.sh: mutations of tools/phxctl/uclk.sh (U1); each one must make uclk_test.sh fail (CAUGHT). A mutation the sed
# doesn't change is NOOP, one the tests pass is MISSED. Exit 0 iff every mutation is CAUGHT.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HERE/../../tools/phxctl/uclk.sh
. "$HERE/lib/portable.sh"
S=$(mktemp -d "$MOCKTMP/uclkmut.XXXXXX"); caught=0; missed=0
mut() {   # mut <name> <sed expression>
  sed "$2" "$SRC" >"$S/$1.sh"
  if cmp -s "$S/$1.sh" "$SRC"; then echo "NOOP    $1"; missed=$((missed + 1)); return; fi
  if UCLK_SRC=$S/$1.sh bash "$HERE/uclk_test.sh" >"$S/$1.out" 2>&1; then echo "MISSED  $1"; missed=$((missed + 1))
  else echo "CAUGHT  $1"; caught=$((caught + 1)); fi
}
mut driver_mailbox 's/smu \$((0x10000 | \$1))/smu $1/'
mut pin_low 's/hardmin "\$TOP" top/hardmin "$LOW" top/'
mut unpin_top 's/hardmin "\$LOW" "level 0"/hardmin "$TOP" "level 0"/'
mut no_status 's/if \[ "\$V" -lt \$((0x4E6A00)) \]/if true/'
mut status_bits 's/OUT \& 0x24 )) = \$((0x24))/OUT \& 0x20 )) = $((0x20))/'
mut no_busy_retry 's/kr 0xe00002d5/kr 0xNEVER/'
mut ok_on_fail 's/not acknowledged: \$L"; return 1;/not acknowledged (OK)"; return 0;/'
mut no_ver_check 's/dal 0x2 0 || {/dal 0x2 0 || true; false \&\& {/'
mut no_fine 's/then n=2; else/then n=$(( OUT \& 0xFF )); else/'
mut zero_ok 's/\[ "\$f" -gt 0 \] ||/true ||/'
mut count_cap 's/-le 16 \]/-le 99999 ] \&\& [ "$n" -ge 0 ]/'
mut uclk_clk 's/(2 << 16) | \$1/(3 << 16) | $1/'
mut status_fail_polls 's/st="read not answered (stopped, as Linux)"; break;/st="read not answered (stopped, as Linux)";/'
echo "RESULT: caught $caught, missed $missed"; [ $missed = 0 ] && rm -rf "$S"; [ $missed = 0 ]
