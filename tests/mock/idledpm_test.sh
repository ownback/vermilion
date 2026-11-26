#!/bin/bash
# SPDX-License-Identifier: MIT
# idledpm_test.sh: tools/phxctl/idle_dpm.sh against stand-ins (phxctl.bin, uclk.sh, dal.sh, dalwm.sh, sysctl, who,
# sleep). No hardware. Each scenario: what was sent to the PMFW, in which order, and how the script ended.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); SRC=$HERE/../../tools/phxctl/idle_dpm.sh
. "$HERE/lib/portable.sh"
SCR=$(mktemp -d "$MOCKTMP/idledpm.XXXXXX"); PASSN=0; FAILN=0
setup() {   # setup <name>: a fresh world in $W
  W=$SCR/$1; mkdir -p "$W/gpu" "$W/bin"; : >"$W/sent.log"; echo 0 >"$W/n"
  cat >"$W/gpu/phxctl.bin" <<'EOF'
#!/bin/bash
W=$(dirname "$0")/..
case "$1" in
  regs) n=$(cat "$W/n"); [ "$2" = 0x4F8A ] && { n=$((n + 1)); echo $n >"$W/n"; }
        v=0x00000000; [ "$2" = 0x3AB3 ] && v=0x000e0000; [ "$2" = 0x4FEA ] && v=0x00000a9f
        if [ "$2" = 0x4F8A ] && [ -n "${UF_AT:-}" ] && [ $n -ge "$UF_AT" ]; then v=0x00000400; fi
        echo "0x0$2: $v";;
  wreg) echo "wreg $2 $3" >>"$W/sent.log";;
esac
EOF
  printf '#!/bin/sh\necho "uclk $*" >>"%s/sent.log"; echo "msg (OK)"\n' "$W" >"$W/gpu/uclk.sh"
  printf '#!/bin/sh\necho "dal $*" >>"%s/sent.log"; echo "msg (OK)"\n' "$W" >"$W/gpu/dal.sh"
  printf '#!/bin/sh\necho "dalwm" >>"%s/sent.log"\n' "$W" >"$W/gpu/dalwm.sh"
  cat >"$W/bin/sysctl" <<'EOF'
#!/bin/bash
W=$(dirname "$0")/..; n=$(cat "$W/n"); mode="2560x1440@240 (key 1440240)"
[ -n "${SWITCH_AT:-}" ] && [ $n -ge "$SWITCH_AT" ] && mode="2560x1440@60 (key 1440060)"
printf 'result=DONE\nstate: where=linux now=%s failed=0 attempts=1 dones=1\n' "$mode"
EOF
  printf '#!/bin/sh\necho "user console Nov 23 07:00"\n' >"$W/bin/who"
  printf '#!/bin/sh\nexit 0\n' >"$W/bin/sleep"
  chmod +x "$W/gpu/"* "$W/bin/"*
}
run() {   # run: idle_dpm.sh in $W, at most 20 s; output in $W/out, exit code in RC
  PATH="$W/bin:$PATH" HOME=$W PHXBOOT_G=$W/gpu IDPM_SETTLE=2 IDPM_BASE=4 IDPM_POLL=1 IDPM_WAITMAX=50 \
    sh "$SRC" >"$W/out" 2>&1 & local pid=$! i=0
  while kill -0 $pid 2>/dev/null && [ $i -lt 200 ]; do /bin/sleep 0.1; i=$((i + 1)); done
  if kill -0 $pid 2>/dev/null; then kill $pid; wait $pid 2>/dev/null; RC=124; else wait $pid; RC=$?; fi; }
check() {   # check <name> <ok-condition...>
  local name=$1; shift
  if "$@"; then PASSN=$((PASSN + 1)); echo "PASS  $name"; else FAILN=$((FAILN + 1)); echo "FAIL  $name (rc $RC)"; sed 's/^/        /' "$W/out" "$W/sent.log"; fi; }
has() { grep -q -- "$1" "$W/$2"; }
exact() { grep -qx -- "$1" "$W/$2"; }   # U1: `uclk.sh pin` takes no MHz (the top level, through the DAL mailbox)
order() { awk -v a="$1" -v b="$2" 'index($0,a)&&!x{x=NR} index($0,b)&&!y{y=NR} END{exit !(x&&y&&x<y)}' "$W/sent.log"; }

# a steady-state underflow after the unpin: re-pinned, FCLK switch withdrawn, exit 3
setup steady; UF_AT=20 run
check steady_repin eval '[ $RC = 3 ] && has "dalwm" sent.log && has "uclk unpin" sent.log && has "dal SetFclkSwitchAllow 1" sent.log && exact "uclk pin" sent.log && has "dal SetFclkSwitchAllow 0" sent.log && order "uclk unpin" "uclk pin" && order "dalwm" "uclk unpin" && has "optc0 underflow" out && ! has "SetHardMinByFreq" sent.log'
# an underflow while UCLK is still pinned (baseline): nothing sent at all, exit 2
setup base; UF_AT=4 run
check baseline_stop eval '[ $RC = 2 ] && ! has "uclk" sent.log && ! has "dal" sent.log && has "baseline" out'
# the dcf flag: DCFCLK hard min 199 (11 << 16 | 199 = 721095), deep sleep 0x48 at 240 Hz, one display, after the FCLK switch
setup dcf; touch "$W/gpu/phxboot-idledpm-dcf"; UF_AT=20 run
check dcf_messages eval 'has "dal SetHardMinByFreq 721095" sent.log && has "dal SetMinDeepSleepDcfclk 0x48" sent.log && has "dal NumOfDisplays 1" sent.log && order "SetFclkSwitchAllow 1" "SetHardMinByFreq"'
# a mode switch to 60 Hz: the stickies cleared once it settles, the deep sleep re-sent for 60 Hz (0x12), no re-pin
setup switch; touch "$W/gpu/phxboot-idledpm-dcf"; SWITCH_AT=16 UF_AT=40 run
check switch_settles eval 'has "mode switch settled: .*@60" out && has "dal SetMinDeepSleepDcfclk 0x12" sent.log && order "SetMinDeepSleepDcfclk 0x48" "SetMinDeepSleepDcfclk 0x12"'
# a refused unpin: pinned again, exit 1, no FCLK switch
setup refused; UF_AT=999; printf '#!/bin/sh\necho "uclk $*" >>"%s/sent.log"; [ "$1" = unpin ] && { echo "msg (FAIL)"; exit 0; }; echo "msg (OK)"\n' "$W" >"$W/gpu/uclk.sh"; run
check unpin_refused eval '[ $RC = 1 ] && exact "uclk pin" sent.log && ! has "SetFclkSwitchAllow 1" sent.log'
# no console user: never leaves the pinned state
setup nouser; printf '#!/bin/sh\nexit 0\n' >"$W/bin/who"; run
check no_user eval '[ $RC = 1 ] && ! has "uclk" sent.log && has "no settled desktop" out'
# a helper missing: exit 1 before anything
setup missing; rm "$W/gpu/dalwm.sh"; run
check helper_missing eval '[ $RC = 1 ] && [ ! -s "$W/sent.log" ] && has "dalwm.sh missing" out'

echo "RESULT: $PASSN passed, $FAILN failed"; [ $FAILN = 0 ] && rm -rf "$SCR"; [ $FAILN = 0 ]
