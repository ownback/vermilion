#!/bin/sh
# SPDX-License-Identifier: MIT
# uclk.sh pin | unpin | levels | show [n]  (on the box, kext >= b75; run with sudo or sudo -n inside): the memory
# clock (PPCLK_UCLK = 2) hard minimum through the DAL mailbox, the way Linux's display code sets it on Navi 31 / DCN 3.2
# (U1, .agents/findings/2026-11-26-u1-uclk-dal.md). A UCLK switch the display can't take underflows it; Linux then holds
# UCLK at its top level, and lets it go once the mode can take a switch.
#   pin     hard min = the top UCLK level (1249 MHz on the XTX machine): dcn32_update_clocks "to disable P-State
#           switching, set UCLK min = max" (dcn32_clk_mgr.c, v6.8 :688). Takes no MHz: a value after `pin` is not used.
#   unpin   hard min = level 0 (96 MHz on the XTX machine): what dcn32_update_clocks sends after every mode set on this
#           card (dramclk_khz, v6.8 :720; the last UCLK hard min is 96 in all 72 of the 78 Linux mode-set traces of
#           2026-11-20 / 21 that send one).
#   levels  the UCLK DPM table.   show  SMU metrics clocks (smumetrics.py, n samples).
# Every message is a DAL message (the kext's selector, msg 0x10000 | DALSMC id), in Linux's order (dcn32 and dcn30
# clk_mgr_smu_msg.c): GetSmuVersion (2); GetDpmFreqByIndex (0xB) for UCLK, index 0xFF (the level count; bit 31 =
# fine-grained, 2 levels) then each index, as dcn32_init_single_clock reads it; SetHardMinByFreq (9), argument
# (2 << 16) | MHz; then, on a PMFW of 0x4E6A00 (78.106.0) or later, ReturnHardMinStatus (0x15) until the answer has the
# UCLK and DPREFCLK bits (0x24), ~2 s at most (dcn32_smu_wait_get_hard_min_status). The kext answering busy (another DAL
# message in flight) = again in 10 ms, ~2 s at most (Linux waits for the mailbox before it writes). Never the driver
# mailbox: Linux sends no driver-mailbox SetHardMinByFreq (0x1B) on SMU 13.0.0, and kext b167 refuses it.
# pin / unpin print one line, with "(OK)" in it only when the PMFW acknowledged the hard minimum (idle_dpm.sh and the
# boot daemon read it). Exit 0 sent; 1 refused or not answered, or no DPM table (then no hard minimum is sent); 2 usage.
# PHXCTL overrides the phxctl path; UCLK_BUSY_TRIES / UCLK_STATUS_TRIES the two bounds (200 x 10 ms each).
P=${PHXCTL:-$HOME/gpu/phxctl.bin}
BUSY_TRIES=${UCLK_BUSY_TRIES:-200}; STATUS_TRIES=${UCLK_STATUS_TRIES:-200}
# dal <DALSMC id> <arg>: one DAL message. L = phxctl's line, OUT = its out word (the argument register afterwards).
dal() {
  t=0
  while :; do
    L=$(sudo -n "$P" smu $((0x10000 | $1)) "$2" 2>&1)
    case "$L" in *"kr 0xe00002d5"*) if [ $t -lt "$BUSY_TRIES" ]; then t=$((t + 1)); sleep 0.01; continue; fi ;; esac
    break
  done
  OUT=$(printf '%s\n' "$L" | sed -n 's/.* out \(0x[0-9a-fA-F]*\).*/\1/p' | tail -1)
  case "$L" in *"(OK)"*) OUT=${OUT:-0}; return 0 ;; esac
  return 1
}
# table: V = the PMFW version, LV = the UCLK levels in MHz (lowest first), TOP / LOW = the last / first. 1 = unreadable.
table() {
  dal 0x2 0 || { echo "DAL GetSmuVersion not answered (Linux then sends the PMFW nothing): $L"; return 1; }
  V=$((OUT))
  dal 0xB $(( (2 << 16) | 0xFF )) || { echo "DAL GetDpmFreqByIndex UCLK count not answered: $L"; return 1; }
  if [ $(( (OUT >> 31) & 1 )) = 1 ]; then n=2; else n=$(( OUT & 0xFF )); fi
  [ "$n" -ge 1 ] && [ "$n" -le 16 ] || { echo "the PMFW reports $n UCLK levels ($OUT): no table"; return 1; }
  LV=""; i=0
  while [ $i -lt "$n" ]; do
    dal 0xB $(( (2 << 16) | i )) || { echo "DAL GetDpmFreqByIndex UCLK $i not answered: $L"; return 1; }
    f=$(( OUT & 0xFFFF )); [ "$f" -gt 0 ] || { echo "UCLK level $i reads 0 MHz: no table"; return 1; }
    LV="${LV:+$LV }$f"; [ $i = 0 ] && LOW=$f; TOP=$f; i=$((i + 1))
  done
}
# hardmin <MHz> <what>: SetHardMinByFreq UCLK, then the hard-min status as Linux reads it.
hardmin() {
  dal 0x9 $(( (2 << 16) | $1 )) || { echo "DAL hard min UCLK $1 MHz ($2; levels $LV) not acknowledged: $L"; return 1; }
  if [ "$V" -lt $((0x4E6A00)) ]; then st="not asked (PMFW $(printf 0x%X "$V") < 0x4E6A00)"
  else
    k=0; st="not confirmed in ~2 s"
    while [ $k -lt "$STATUS_TRIES" ]; do
      if dal 0x15 0 && [ $(( OUT & 0x24 )) = $((0x24)) ]; then st="$(printf 0x%X $((OUT))) done"; break; fi
      k=$((k + 1)); sleep 0.01
    done
  fi
  echo "DAL hard min UCLK $1 MHz ($2; levels $LV): (OK), status $st"
}
case "${1:-}" in
  pin)
    [ -n "${2:-}" ] && echo "uclk.sh: pin takes no MHz since U1: '$2' not used (the top level, as Linux)" >&2
    table || exit 1; hardmin "$TOP" top || exit 1 ;;
  unpin) table || exit 1; hardmin "$LOW" "level 0" || exit 1 ;;
  levels) table || exit 1; echo "UCLK levels (DAL GetDpmFreqByIndex): $LV; PMFW $(printf 0x%X "$V")" ;;
  show) SMU_CLOCKS=1 sudo -n -E python3 "$HOME/gpu/smumetrics.py" "${2:-4}" 0.5 ;;
  *) echo "usage: uclk.sh pin | unpin | levels | show [n]" >&2; exit 2 ;;
esac
