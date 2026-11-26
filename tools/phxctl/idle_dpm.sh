#!/bin/sh
# SPDX-License-Identifier: MIT
# idle_dpm.sh (boot daemon `idledpm_boot`, root, after `done`; flag ~/gpu/phxboot-idledpm): memory and fabric clocks free
# to drop at idle on a one-display desktop, the messages Linux amdgpu sends the PMFW for it, under an underflow watchdog
# that lives for the whole boot. The one-display counterpart of b15_boot.sh step 6 (upstream's XT, two 1080p displays).
#   1 wait for a logged-in user and a settled display (the replay engine's state line and OTG0's H_TOTAL unchanged for $IDPM_SETTLE s)
#   2 underflow stickies cleared, then $IDPM_BASE s with UCLK still pinned: any underflow there = stop, stay pinned
#   3 dalwm.sh (the DAL watermark table), uclk.sh unpin, SetFclkSwitchAllow 1 (b15 step 6; Linux dcn32_update_clocks)
#   4 with ~/gpu/phxboot-idledpm-dcf only: SetHardMinByFreq DCFCLK 199 MHz, SetMinDeepSleepDcfclk for the refresh rate
#     (18 / 36 / 43 / 72 MHz at 60 / 120 / 144 / 240 Hz), NumOfDisplays 1: what Linux sends after every mode set on
#     this card (its 2026-11-20 mode-set traces)
# Watchdog, every $IDPM_POLL s: OPTC0 (0x4F8A bit 10) and HUBP0 (0x3AB3 bits 30:28). A hit while the display is settled =
# UCLK pinned again (U1: `uclk.sh pin`, the top level through the DAL mailbox, as Linux holds it when the mode can't take
# a UCLK switch), SetFclkSwitchAllow 0, exit: pinned for the rest of the boot. `uclk.sh unpin` is the DAL hard minimum at
# level 0, what Linux sends after every mode set on this card (finding 2026-11-26-u1-uclk-dal.md). A mode switch (the
# state line changes) clears the stickies once it settles and is not counted (an underflow inside a switch's blank is not
# seen). Measured live 2026-11-23 on the XTX machine at 1440p240 HDR (steps 2-3 by hand, the driver-mailbox pin of then):
# socket 51 -> 20-24 W at idle, board 64 -> 28-33 W, UCLK 456 -> 96, FCLK 2301 -> 1000, no underflow in 10 min
# (findings 2026-11-23-perf-power.md).
# Rollback: rm ~/gpu/phxboot-idledpm (next boot = pinned); live: `sudo sh ~/gpu/uclk.sh pin` + kill this.
# Exit codes: 1 nothing freed (a helper missing, no settled desktop, dalwm.sh failed) or the unpin / FCLK switch was
# refused and UCLK pinned again; 2 an underflow in the baseline, nothing sent; 3 the watchdog pinned UCLK again.
G=${PHXBOOT_G:-$HOME/gpu}; P=${PHXCTL:-$G/phxctl.bin}; export PHXCTL=$P
SETTLE=${IDPM_SETTLE:-60}; BASE=${IDPM_BASE:-30}; POLL=${IDPM_POLL:-2}; WAITMAX=${IDPM_WAITMAX:-1800}
r() { "$P" regs "$1" | awk '{print $NF}'; }
w() { "$P" wreg "$1" "$2" >/dev/null; }
say() { echo "idledpm: $(date '+%T') $*"; }
st() { x=$(sysctl -n debug.phxp0odm_stat 2>/dev/null | sed -n 's/^state: //p'); [ -n "$x" ] && echo "$x otg0_htotal=$(r 0x4FEA)"; }
clr() { w 0x4F8A 0x1000; h=$(r 0x3AB3); w 0x3AB3 $(printf 0x%X $(( (h & 0x0FFFFFFF) | 0x80000000 ))); w 0x3AB3 $(printf 0x%X $(( h & 0x0FFFFFFF ))); }
hit() { v=$(r 0x4F8A); h=$(r 0x3AB3); k=""
  [ $(( v & 0x400 )) -ne 0 ] && k=optc0; [ $(( (h >> 28) & 7 )) -ne 0 ] && k="${k:+$k+}hubp0"; [ -n "$k" ]; }
pin() { say "$1: $(sh "$G/uclk.sh" pin 2>&1 | tail -1 | cut -c1-90); $(sh "$G/dal.sh" SetFclkSwitchAllow 0 2>&1 | tail -1 | cut -c1-90)"; }
dal() { out=$(sh "$G/dal.sh" "$@" 2>&1); echo "$out" | grep -q '(OK)' || { say "dal $*: $(echo "$out" | tail -1 | cut -c1-100)"; return 1; }; }
dsleep() { case "${1##*@}" in 60\ *) echo 0x12;; 120\ *) echo 0x24;; 144\ *) echo 0x2B;; 240\ *) echo 0x48;; *) echo "";; esac; }
dcf() { [ -e "$G/phxboot-idledpm-dcf" ] || return 0; m=$(echo "$1" | sed -n 's/.*now=\([^ ]*\).*/\1/p'); d=$(dsleep "$m ")
  [ -n "$d" ] || { say "dcf: no deep-sleep value for '$m': DCFCLK messages skipped"; return 0; }
  dal SetHardMinByFreq $(( (11 << 16) | 199 )) && dal SetMinDeepSleepDcfclk $d && dal NumOfDisplays 1 && say "dcf: DCFCLK hard min 199, deep sleep $(( d )) MHz ($m), 1 display"; }
for f in uclk.sh dal.sh dalwm.sh; do [ -e "$G/$f" ] || { say "$G/$f missing: UCLK stays pinned"; exit 1; }; done
# 1 settle
t=0; last=""; same=0
while [ $same -lt "$SETTLE" ]; do
  [ $t -ge "$WAITMAX" ] && { say "no settled desktop after $WAITMAX s: UCLK stays pinned"; exit 1; }
  s=$(st); if who | grep -q console && [ -n "$s" ] && [ "$s" = "$last" ]; then same=$((same + POLL)); else same=0; fi
  last=$s; sleep "$POLL"; t=$((t + POLL)); done
say "settled: $last"
# 2 baseline with UCLK pinned
clr; t=0; while [ $t -lt "$BASE" ]; do
  hit && { say "$k underflow with UCLK pinned (baseline): nothing changed"; exit 2; }; sleep "$POLL"; t=$((t + POLL)); done
# 3 + 4
sh "$G/dalwm.sh" >/dev/null 2>&1 || { say "dalwm.sh failed: UCLK stays pinned"; exit 1; }
out=$(sh "$G/uclk.sh" unpin 2>&1); echo "$out" | grep -q '(OK)' || { pin "unpin answered '$(echo "$out" | tail -1 | cut -c1-80)'"; exit 1; }
dal SetFclkSwitchAllow 1 || { pin "FCLK switch refused"; exit 1; }
dcf "$last"; say "on: UCLK unpinned, FCLK switch allowed, DAL watermarks sent"
# watchdog
while :; do
  sleep "$POLL"; s=$(st)
  if [ "$s" != "$last" ]; then   # a mode switch: wait until it settles, then clear what it left
    same=0; while [ $same -lt 10 ]; do sleep "$POLL"; n=$(st); [ "$n" = "$s" ] && same=$((same + POLL)) || { same=0; s=$n; }; done
    clr; last=$s; say "mode switch settled: $last"; dcf "$last"; continue; fi
  hit && { pin "$k underflow"; exit 3; }
done
