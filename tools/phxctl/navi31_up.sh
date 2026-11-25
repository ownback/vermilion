#!/bin/bash
# SPDX-License-Identifier: MIT
# One-shot Navi 31 bring-up on macOS, after a clean boot: GFX power-up, GART, MES, KIQ, MES scheduler and a
# compute queue — every step that works today. Stops at the first step that fails.
# The last line says how it ended: "navi31 up: ..." (the daemon claims the GPU only then) or "navi31 not up: <step>
# (<the bring-up watchdog's state>)". bringup_navi31.sh arms a 3-minute reboot watchdog before its first write and
# cancels it at its end; a failure inside it leaves the watchdog armed on purpose, a failure after it has none.
set -u
M(){ sudo -n /usr/local/sbin/mesboot "$@"; }
step(){ echo "== $1"; shift; out=$("$@" 2>&1); echo "$out" | tail -3; }
notup(){ echo "$1"; echo "navi31 not up: $1 ($2)"; exit 1; }   # <the failed step> <the watchdog's state>
WDOFF="the bring-up watchdog is cancelled: no restart"
cd ~/gpu/phxctl || notup "no ~/gpu/phxctl" "nothing written, no bring-up watchdog"
step "bring-up (PSP, SMU, RLC, RS64, doorbells, MEC)" bash bringup_navi31.sh
echo "$out" | grep -m1 '^sOS check:'   # the cold-GPU check's value (a refusal is in the last lines above)
if ! echo "$out" | grep -q "watchdog cancelled"; then
  if echo "$out" | grep -q '^== watchdog: reboot in 3 min'; then notup "bring-up failed" "the bring-up watchdog is still armed: a restart within 3 min"
  else notup "bring-up failed" "nothing written by the power-up, no bring-up watchdog"; fi
fi
step "gart" M gart mc
step "mes" M mes
step "kiq (SET_RESOURCES + ring test)" M kiqres mc
echo "$out" | grep -q "scratch0=0xdeadbeef" || notup "KIQ test failed" "$WDOFF"
step "MES scheduler (MAP_QUEUES, SET_HW_RESOURCES)" M schedkiq mc
echo "$out" | grep -q "QUERY_SCHED_STATUS.*OK" || notup "scheduler failed" "$WDOFF"
step "compute queue (ADD_QUEUE + WRITE_DATA), then hand it to the kext" M cs mc ADOPT
echo "$out" | grep -q "testbuf=0xfeedf00d" || notup "compute queue failed" "$WDOFF"
step "gfx queue (clear-state, ADD_QUEUE gfx, ring test), then hand it to the kext" M gfxq mc
echo "$out" | grep -q "testbuf=0x6f7a6f7a" || echo "WARNING: gfx ring test did not confirm (adopt may still have run)"
echo "navi31 up: compute + gfx queues ready"
