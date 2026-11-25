#!/bin/bash
# SPDX-License-Identifier: MIT
# run.sh — MOCK HARNESS for phxboot-navi31.sh. NO hardware, NO reboot, NO real box.
# Drives the REAL daemon logic against a fake root: every path is redirected (PHXBOOT_*), every external command is a
# shim on PATH driven by SIM_* scenario config, `sleep` is near-instant, `shutdown` is RECORDED not executed, and
# `killall` just flags state. One scenario per failure mode we actually hit (each cost a physical reboot before).
#
#   ./run.sh            run every scenario
#   ./run.sh -k         keep per-scenario work dirs (for debugging a FAIL)
#   ./run.sh name ...   run only the named scenarios
#   PAR=1 ./run.sh      serial (default PAR=2: two shards at once, the output still in scenario order)
#
# Exit 0 iff every scenario passes. Modelled on Cobalt64 tools/pc/m6-stage2-sim/run-scenarios.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/portable.sh"   # MOCKTMP, mock_sedi, MOCK_PB; off macOS the shims in lib/bin (tests/mock/README.md)
DAEMON=${DAEMON:-$HERE/../../tools/phxctl/phxboot-navi31.sh}
SCR=${SCR:-$(mktemp -d "$MOCKTMP/phxboot-mock.XXXXXX")}
BIN=$SCR/bin
KEEP=0; [ "${1:-}" = "-k" ] && { KEEP=1; shift; }
PASSN=0; FAILN=0; FAILED=""

# ---------------------------------------------------------------------------------------------- fake tools (generated once)
mkdir -p "$BIN"
make_fakes() {
  cat >"$BIN/ioreg" <<'EOF'
#!/bin/bash
rd(){ RV=$2; [ -r "$1" ] && IFS= read -r RV <"$1"; return 0; }   # = $(cat <file> 2>/dev/null || echo <default>) without a process
st="${SIM_STATE:-/tmp}"; claimed=0; [ -e "$st/claimed" ] && claimed=1; a="$*"
case "$a" in
  *PhxFBSquatter*) rd "$st/sqpolls" 0; n=$RV; echo $((n+1)) > "$st/sqpolls"
                   [ "${SIM_SQUAT:-0}" = 1 ] && [ "$n" -ge "${SIM_SQUAT_LATE:-0}" ] && echo '  +-o PhxFBSquatter  <class PhxFBSquatter, !registered, !matched, active>';;
  *IOFramebuffer*) [ "${SIM_FB:-1}" = 1 ] && echo '  +-o PhxAMDFB  <class IOFramebuffer, registered, matched, active>';;
  *NMXAccel*)      [ "$claimed" = 1 ] && [ "${SIM_NMXACCEL:-1}" = 1 ] && echo '  +-o NMXAccel  <class NMXAccel, registered, matched, active>';;
  *PhxAMDFB*)      [ "$claimed" = 1 ] && [ "${SIM_PHXFB:-1}" = 1 ] && echo '  +-o PhxAMDFB  <class PhxAMDFB, registered, matched, active>';;
  *-l*)            [ "${SIM_BRINGUP:-1}" = 1 ] && echo '    "phx-build" = "navi31-build-42"';;
esac
exit 0
EOF
  cat >"$BIN/metaltest" <<'EOF'
#!/bin/bash
st="${SIM_STATE:-/tmp}"; claimed=0; [ -e "$st/claimed" ] && claimed=1
# logs via stderr, exactly like the real NSLog-based metaltest (guards the 2>&1 vs 2>/dev/null bug)
if [ "$claimed" = 1 ] && [ "${SIM_METAL:-1}" = 1 ]; then
  echo "metaltest: Metal devices: 1" >&2; echo "metaltest: COMPUTE 4096/4096 correct" >&2
else
  echo "metaltest: Metal devices: 0" >&2
fi
exit 0
EOF
  cat >"$BIN/mesboot" <<'EOF'
#!/bin/bash
st="${SIM_STATE:-/tmp}"
case "${1:-}" in claim) [ "${SIM_CLAIM:-1}" = 1 ] && : >>"$st/claimed"; echo "claim: nmxgpu-claimed=Yes"
  grep -q "debug.phxpipe0_modes=1" "$st/sysctl.log" 2>/dev/null && echo "claim: phxpipe0_modes was set before the claim"
  # 11-03 PhxAccel offer gate (SIM_OFFER_GATE=1, kernel-offer-gate.patch): closed at the head-0 start with a mode list
  if [ "${SIM_OFFER_GATE:-0}" = 1 ]; then
    if grep -q "debug.phxpipe0_modes=1" "$st/sysctl.log" 2>/dev/null && [ "${SIM_HEAD0_SINGLE:-0}" != 1 ] && ! echo " ${SIM_BOOTARGS:-} " | grep -q " -phxfb0open "; then echo 0 >"$st/val.offer"; else echo 1 >"$st/val.offer"; fi
  fi;; *) echo "mesboot $*";; esac
exit 0
EOF
  cat >"$BIN/navi31_up.sh" <<'EOF'
#!/bin/bash
echo "== bring-up (PSP, SMU, RLC, RS64, doorbells, MEC)"; echo "sOS check: C2PMSG_81=0x00000000 (cold)"
echo "navi31 bring-up: PSP/SMU/RLC/MES/KIQ queues ok"; echo "navi31 up: compute + gfx queues ready"; exit 0
EOF
  cat >"$BIN/sysctl" <<'EOF'
#!/bin/bash
rd(){ RV=$2; [ -r "$1" ] && IFS= read -r RV <"$1"; return 0; }   # = $(cat <file> 2>/dev/null || echo <default>) without a process
st="${SIM_STATE:-/tmp}"
# SIM_AGDC_LATE=N: debug.phxagdc does not exist for the first N accesses (PhxAMDFB::start still running): a write then
# is lost, so the value reads 0 until a write lands after the oid appeared (the 10-29 m6ext race)
if [ -n "${SIM_AGDC_LATE:-}" ] && [ "${2:-}" = debug.phxagdc -o "${2%%=*}" = debug.phxagdc ]; then
  rd "$st/agdcn" 0; n=$((RV + 1)); echo $n >"$st/agdcn"
  [ $n -le "$SIM_AGDC_LATE" ] && { echo "sysctl: unknown oid 'debug.phxagdc'" >&2; exit 1; }
  case "$1" in -w) echo "$*" >>"$st/sysctl.log"; : >>"$st/agdc_armed"; exit 0;;
    -n) [ -e "$st/agdc_armed" ] && echo 1 || echo 0; exit 0;; esac
fi
# 11-03 offer gate: debug.phxfb0_offer / _opens exist only with SIM_OFFER_GATE=1; a write of 1 opens it (SIM_SYSCTL_FAIL
# refuses it), logged to stage.log with the boot state; a resync to another mode opens it too (the kernel's safety net)
# SIM_OFFER_LATE=N: the oids do not exist for the first N accesses (PhxAMDFB registers them at the end of its start,
# seconds after ioreg shows it)
if [ "${2%%=*}" = debug.phxfb0_offer ] || [ "${2:-}" = debug.phxfb0_offer_opens ]; then
  [ "${SIM_OFFER_GATE:-0}" = 1 ] || { echo "sysctl: unknown oid '${2%%=*}'" >&2; exit 1; }
  if [ -n "${SIM_OFFER_LATE:-}" ]; then rd "$st/offerlaten" 0; n=$((RV + 1)); echo $n >"$st/offerlaten"
    [ $n -le "$SIM_OFFER_LATE" ] && { echo "sysctl: unknown oid '${2%%=*}'" >&2; exit 1; }; fi
  case "$1" in
    -w) echo "$*" >>"$st/sysctl.log"; [ "${2%%=*}" = "${SIM_SYSCTL_FAIL:-}" ] && { echo "sysctl: $2: Operation not permitted" >&2; exit 1; }
        k=no; [ -e "$st/killed" ] && k=yes; echo "$2 killed=$k" >>"$st/stage.log"
        rd "$st/val.offer" "" && [ "$RV" = 0 ] && { echo 1 >"$st/val.offer"; rd "$st/val.opens" 0; echo $((RV + 1)) >"$st/val.opens"; }; exit 0;;
    -n) if [ "${2:-}" = debug.phxfb0_offer_opens ]; then rd "$st/val.opens" 0; echo "$RV"; else rd "$st/val.offer" 1; echo "$RV"; fi; exit 0;; esac
fi
# 11-02 boot rate: debug.phxfb_resync (PhxAccel; SIM_NO_RESYNC=1 = an older PhxAccel without it) answers SIM_RESYNC_ID (2)
# after a write, and the write is logged to stage.log like the boot flags; debug.phxfb_nmodes = SIM_NMODES (2)
if [ "${2:-}" = debug.phxfb_resync ] || [ "${2%%=*}" = debug.phxfb_resync ]; then
  [ "${SIM_NO_RESYNC:-0}" = 1 ] && { echo "sysctl: unknown oid 'debug.phxfb_resync'" >&2; exit 1; }
  case "$1" in -w) echo "$*" >>"$st/sysctl.log"; k=no; [ -e "$st/killed" ] && k=yes; b=no; [ -e "$st/bound" ] && b=yes
      echo "$2 killed=$k bound=$b" >>"$st/stage.log"; echo "${SIM_RESYNC_ID:-2}" >"$st/val.resync"
      if [ "${SIM_OFFER_GATE:-0}" = 1 ] && rd "$st/val.offer" "" && [ "$RV" = 0 ] && [ "${SIM_RESYNC_ID:-2}" -gt 1 ] 2>/dev/null; then
        echo 1 >"$st/val.offer"; rd "$st/val.opens" 0; echo $((RV + 1)) >"$st/val.opens"; fi; exit 0;;
    -n) rd "$st/val.resync" 0; echo "$RV"; exit 0;; esac
fi
[ "$1" = -n ] && [ "${2:-}" = debug.phxfb_nmodes ] && { echo "${SIM_NMODES:-2}"; exit 0; }
[ "${2:-}" = debug.phxpipe0_solo ] && [ "${SIM_NO_SOLO:-0}" = 1 ] && { echo "sysctl: unknown oid 'debug.phxpipe0_solo'" >&2; exit 1; }
[ "$1" = -n ] && [ "${2:-}" = debug.phxfb_refresh ] && { echo 144000; exit 0; }
# 11-01 boot flags: every debug.phxhotplug / debug.phxgamma write is also logged to stage.log with the boot state at that
# moment (WindowServer restarted? head 1 bound?); SIM_SYSCTL_FAIL=<oid> refuses that write (EPERM), SIM_GAMMA_BUSY=N answers
# the first N debug.phxgamma writes EBUSY (the kext's gP2Busy); a write that lands is read back by -n; SIM_BOOTARGS = kern.bootargs
# 11-03 first-WindowServer model (verified on the box 4/4 boots): the arm's
# debug.nvaccelfb=1 publishes the display pipe, the first WindowServer reconfigures and restores the stored one-display
# set; a set whose mode is not id 1 (head 0's boot mode) makes it call setDisplayMode, the refusal rebuilds the pipe
# resource and it dies (launchd respawns it as pid 1021). SIM_WSMODEL=1 turns the model on.
if [ "${SIM_WSMODEL:-0}" = 1 ] && [ "${1:-}" = -w ] && [ "${2:-}" = debug.nvaccelfb=1 ] && [ ! -e "$st/killed" ]; then
  pb=${MOCK_PB:-/usr/libexec/PlistBuddy}; f="$st/ws0-snapshot.plist"; i=0; hit=""
  while [ -e "$f" ] && "$pb" -c "Print :DisplayAnyUserSets:$i" "$f" >/dev/null 2>&1; do
    if ! "$pb" -c "Print :DisplayAnyUserSets:$i:1" "$f" >/dev/null 2>&1; then
      id=$("$pb" -c "Print :DisplayAnyUserSets:$i:0:Mode:IODisplayModeID" "$f" 2>/dev/null)
      rr=$("$pb" -c "Print :DisplayAnyUserSets:$i:0:RefreshRate16.16" "$f" 2>/dev/null)
      rf=$("$pb" -c "Print :DisplayAnyUserSets:$i:0:Mode:RefreshRate" "$f" 2>/dev/null); rf=${rf%%.*}
      # any of: mode id, 16.16 refresh, mode refresh away from id 1 / 60 lets CoreDisplay land on the 144 mode
      { [ -n "$id" ] && [ "$id" != 1 ]; } || { [ -n "$rr" ] && [ "$rr" != 3932160 ]; } || { [ -n "$rf" ] && [ "$rf" != 60 ]; } && { hit="set $i id $id rr $rr refresh $rf"; break; }
    fi; i=$((i+1)); done
  rd "$st/wspid" 12345; old=$RV
  # head 0 offers id 2 only with its mode list armed before the claim and the offer gate not closed (CoreDisplay matches the
  # stored mode against the OFFERED list, refresh included: CGXCopyDisplayModeByMatchingDictionary)
  if [ -n "$hit" ] && { ! grep -q "debug.phxpipe0_modes=1" "$st/sysctl.log" 2>/dev/null || [ "${SIM_HEAD0_SINGLE:-0}" = 1 ]; }; then hit=""; echo "first WS: no head-0 mode list, nothing to restore" >>"$st/model.log"; fi
  if [ -n "$hit" ] && [ "${SIM_OFFER_GATE:-0}" = 1 ] && rd "$st/val.offer" "" && [ "$RV" = 0 ]; then hit=""; echo "first WS: stored 144 matches no offered mode (gate closed)" >>"$st/model.log"; fi
  if [ -n "$hit" ]; then echo "$old" >>"$st/corpses"; echo 1021 >"$st/wspid"; echo "first WS $old restored $hit -> refused -> SIGSEGV" >>"$st/model.log"
  else echo "first WS $old restored nothing away from id 1" >>"$st/model.log"; fi
fi
# 11-03 S3: debug.phxdpwatch (SIM_DPW_NOOID=1 = a kext without it; SIM_DPW_L2_EINVAL=1 = a kext that refuses level 2) and
# debug.phxdpwatch_stat: the k-th read prints $st/dpwstat.k (or the newest one before it; dpw_stat writes them)
if [ "${2%%=*}" = debug.phxdpwatch ] || [ "${2:-}" = debug.phxdpwatch_stat ]; then
  [ "${SIM_DPW_NOOID:-0}" = 1 ] && { echo "sysctl: unknown oid '${2%%=*}'" >&2; exit 1; }
  case "${1:-}" in
    -w) echo "$*" >>"$st/sysctl.log"; v=${2#*=}
        [ "$v" = 2 ] && [ "${SIM_DPW_L2_EINVAL:-0}" = 1 ] && { echo "sysctl: debug.phxdpwatch=2: Invalid argument" >&2; exit 1; }
        k=no; [ -e "$st/killed" ] && k=yes; echo "$2 killed=$k" >>"$st/stage.log"; echo "$v" >"$st/val.dpw"; echo "debug.phxdpwatch: 0 -> $v"; exit 0;;
    -n) if [ "$2" = debug.phxdpwatch ]; then rd "$st/val.dpw" 0; echo "$RV"; exit 0; fi
        rd "$st/dpwn" 0; n=$((RV + 1)); echo $n >"$st/dpwn"; f=""
        for ((i=n; i>=1; i--)); do [ -e "$st/dpwstat.$i" ] && { f="$st/dpwstat.$i"; break; }; done
        if [ -n "$f" ]; then cat "$f"; else rd "$st/val.dpw" 0; echo "dpwatch v1 level=$RV samples=0 span_ms=0 events=0"; fi; exit 0;;
  esac
fi
# 11-23: SIM_BOVRAM_NOOID=1 = a VermilionBoot before b156; SIM_BOVRAM_ST = what the self-test reads after a run
[ "${2%%=*}" = debug.phxbo_vram_selftest ] && [ "${SIM_BOVRAM_NOOID:-0}" = 1 ] && { echo "sysctl: unknown oid 'debug.phxbo_vram_selftest'" >&2; exit 1; }
# 11-24 (thread 04): SIM_AUDIO_NOOID=1 = no VermilionAudio (debug.phxaudio_match unknown)
[ "${2%%=*}" = debug.phxaudio_match ] && [ "${SIM_AUDIO_NOOID:-0}" = 1 ] && { echo "sysctl: unknown oid 'debug.phxaudio_match'" >&2; exit 1; }
# 11-23 (thread 03): SIM_GL_NOOID=1 = a VermilionAccel without debug.phxgl
[ "${2%%=*}" = debug.phxgl ] && [ "${SIM_GL_NOOID:-0}" = 1 ] && { echo "sysctl: unknown oid 'debug.phxgl'" >&2; exit 1; }
# 11-23: SIM_IRQWAIT_NOOID=1 = a PhxBringup without debug.phxwait_irq
[ "${2%%=*}" = debug.phxwait_irq ] && [ "${SIM_IRQWAIT_NOOID:-0}" = 1 ] && { echo "sysctl: unknown oid 'debug.phxwait_irq'" >&2; exit 1; }
# 11-19: SIM_WAITSTEP_NOOID=1 = a PhxBringup without debug.phxwait_step_us
[ "${2%%=*}" = debug.phxwait_step_us ] && [ "${SIM_WAITSTEP_NOOID:-0}" = 1 ] && { echo "sysctl: unknown oid 'debug.phxwait_step_us'" >&2; exit 1; }
# 11-22: SIM_VRRMIN_NOOID=1 = a PhxAccel without debug.phxfb0_vrrmin
[ "${2%%=*}" = debug.phxfb0_vrrmin ] && [ "${SIM_VRRMIN_NOOID:-0}" = 1 ] && { echo "sysctl: unknown oid 'debug.phxfb0_vrrmin'" >&2; exit 1; }
# 11-04: debug.phxhotplug0 (PhxAccel hp1+; SIM_HP0_NOOID=1 = a PhxAccel without it)
[ "${2%%=*}" = debug.phxhotplug0 ] && [ "${SIM_HP0_NOOID:-0}" = 1 ] && { echo "sysctl: unknown oid 'debug.phxhotplug0'" >&2; exit 1; }
case "${1:-}" in
  -w) echo "$*" >>"$st/sysctl.log"; oid=${2%%=*}
      case "$oid" in debug.phxhotplug|debug.phxhotplug0|debug.phxgamma|debug.phxwait_step_us|debug.phxpipe0_enable|debug.phxpipe0_modes|debug.phxih_vram|debug.phxih|debug.phxeopirq|debug.phxirq|debug.phxwait_irq|debug.phxbo_vram|debug.phxbo_vram_proc|debug.phxbo_vram_selftest|debug.phxgl)
        k=no; [ -e "$st/killed" ] && k=yes; b=no; [ -e "$st/bound" ] && b=yes; echo "$2 killed=$k bound=$b" >>"$st/stage.log"
        if [ "$oid" = debug.phxgamma ] && [ -n "${SIM_GAMMA_BUSY:-}" ]; then
          rd "$st/gbusyn" 0; n=$((RV + 1)); echo $n >"$st/gbusyn"
          [ $n -le "$SIM_GAMMA_BUSY" ] && { echo "sysctl: $2: Resource busy" >&2; exit 1; }
        fi
        [ "$oid" = "${SIM_SYSCTL_FAIL:-}" ] && { echo "sysctl: $2: Operation not permitted" >&2; exit 1; }
        echo "${2#*=}" >"$st/val.$oid"; echo "$oid: 0 -> ${2#*=}";;
      esac; exit 0;;
  -n) case "${2:-}" in kern.safeboot) echo "${SIM_SAFEBOOT:-0}";; debug.phxagdc) echo "${SIM_AGDC:-1}";; debug.nvaccel_iop_ok) echo 128;; kern.bootargs) echo "${SIM_BOOTARGS:-keepsyms=1}";;
        debug.phxhotplug|debug.phxhotplug0|debug.phxgamma) rd "$st/val.$2" 0; echo "$RV";;
        debug.phxih_vram|debug.phxih|debug.phxeopirq|debug.phxirq|debug.phxwait_irq|debug.phxbo_vram|debug.phxbo_vram_proc|debug.phxgl) rd "$st/val.$2" 0; echo "$RV";;
        debug.phxbo_vram_selftest) if [ -e "$st/val.$2" ]; then echo "${SIM_BOVRAM_ST:-1}"; else echo 0; fi;; debug.phxwait_step_us) rd "$st/val.$2" 50; echo "$RV";;
        debug.phxpipe0_stat) if [ "${SIM_P0_OLD:-0}" = 1 ]; then echo "busy=0 gen=0 enable=0 why="; elif [ "${SIM_P0_DARK:-0}" = 1 ] && [ -e "$st/killed" ]; then echo "busy=0 gen=1 enable=1 mode=60 target=120 select=120 last=dark cmd=2 stage=revert dark=1 halted=0 dal_sent=0 det_writes=0 why=the revert went dark"; else echo "busy=0 gen=0 enable=0 dal_sent=0 det_writes=0 why="; fi;;
        # 11-23 thread 01: the replay engine's state (SIM_P0ODM: dark = latched once WindowServer restarted, fb = fell back)
        debug.phxp0odm_stat) case "${SIM_P0ODM:-}" in
            dark) if [ -e "$st/killed" ]; then printf 'result=FAILED target=1440060 phase=fall-back why=link training failed (every attempt) plans=1440p240-from,1440p60hdr-to fallback=1440p60hdr-from\nstate: where=linux now=2560x1440@144 (key 144) failed=1 attempts=2 dones=1 fell_backs=0 sames=0 refusals=0 last_refusal=-\n'
                  else printf 'result=DONE target=240 phase=post why=at the rate plans=1440p240-entry,- fallback=-\nstate: where=linux now=2560x1440@240 (key 240) failed=0 attempts=1 dones=1 fell_backs=0 sames=0 refusals=0 last_refusal=-\n'; fi;;
            fb) printf 'result=FELL-BACK-TO-144 target=1440060 phase=fall-back why=link training failed (every attempt) plans=-,1440p60hdr-to fallback=1440p60hdr-from\nstate: where=linux now=2560x1440@144 (key 144) failed=0 attempts=2 dones=1 fell_backs=1 sames=0 refusals=0 last_refusal=-\nlast_fail: target=1440060 plan=1440p60hdr-to step=181 line=423 op=7 why=link training failed (every attempt)\ntrain_w1: plan=1440p60hdr-to link 0x0a x4 tries=4 rc=clock-recovery,clock-recovery,clock-recovery,clock-recovery off_to_up_us=1200 train_us=650000 since_prev_us=0\nrecovery: recoveries=0/2 recovered=0 train_retried=0 retry_why=- redone=0 redos=0/4\n';;
            *) echo "never run (root: sysctl -w debug.phxp0odm=1 survey, or 60 / 120 / 144 / 240)";; esac;;
        *) echo 0;; esac; exit 0;;
esac
exit 0
EOF
  cat >"$BIN/who" <<'EOF'
#!/bin/bash
[ -n "${SIM_USERS:-}" ] && printf '%s\n' "$SIM_USERS"
# 2026-11-25: SIM_LOGIN_AFTER_KILL=<user> = that user logs in at the console once WindowServer restarted (the notice)
[ -n "${SIM_LOGIN_AFTER_KILL:-}" ] && [ -e "${SIM_STATE:-/tmp}/killed" ] && echo "$SIM_LOGIN_AFTER_KILL console  Nov 25 11:43"
exit 0
EOF
  cat >"$BIN/killall" <<'EOF'
#!/bin/bash
st="${SIM_STATE:-/tmp}"; echo "killall $*" >>"$st/killall.log"; : >>"$st/killed"; echo 23456 >"$st/wspid"
[ -e "$st/wsprefs.plist" ] && cp "$st/wsprefs.plist" "$st/prefs-at-kill.plist"; exit 0
EOF
  cat >"$BIN/pgrep" <<'EOF'
#!/bin/bash
rd(){ RV=$2; [ -r "$1" ] && IFS= read -r RV <"$1"; return 0; }   # = $(cat <file> 2>/dev/null || echo <default>) without a process
st="${SIM_STATE:-/tmp}"; name="${@: -1}"
if [ "$name" = WindowServer ]; then
  if [ "${SIM_WS_NORESTART:-0}" = 1 ] && [ -e "$st/killed" ]; then exit 1; fi
  case "${1:-}" in -q*) exit 0;; esac
  # 11-03: the WindowServer pid lives in $st/wspid (12345 = the first WindowServer, up since boot); killall, the
  # first-WS crash model (sysctl) and the silent-crash injector (sleep) change it
  rd "$st/wspid" 12345; echo "$RV"; exit 0
fi
exit 1
EOF
  # 11-03 (first-WindowServer fix): `defaults export|import <domain> <file>` on the fake system prefs $st/wsprefs.plist
  # (SIM_DEFAULTS_FAIL=export|import refuses that verb); every call is logged with the boot state at that moment
  cat >"$BIN/defaults" <<'EOF'
#!/bin/bash
st="${SIM_STATE:-/tmp}"; k=no; [ -e "$st/killed" ] && k=yes; c=no; [ -e "$st/claimed" ] && c=yes
# 11-04 login-window guard: read / write -bool / delete on the fake loginwindow domain (<domain>.plist via PlistBuddy, as cfprefsd
# would), logged to $st/lw.log with the boot state; SIM_LW_BROKEN_AT_TERM=1 = after launchd's TERM `defaults` no longer
# reaches cfprefsd (the v4 export at TERM returned no sets 3/3): read says absent, write returns 0 and changes nothing
case "${2:-}" in *com.apple.loginwindow)
  t=no; [ -e "$st/termed" ] && t=yes; echo "$1 ${3:-} ${4:-} ${5:-} killed=$k termed=$t" >>"$st/lw.log"; pb=${MOCK_PB:-/usr/libexec/PlistBuddy}; f="$2.plist"
  [ "${SIM_LW_BROKEN_AT_TERM:-0}" = 1 ] && [ $t = yes ] && { [ "$1" = read ] && { echo "The domain/default pair of ($2, $3) does not exist" >&2; exit 1; }; exit 0; }
  [ -n "${SIM_LW_FAIL:-}" ] && [ "$SIM_LW_FAIL" = "$1" ] && { echo "defaults: $1 failed (mock)" >&2; exit 1; }   # SIM_LW_FAIL=<verb>: that verb refused
  case "$1" in
    read)   v=$("$pb" -c "Print :$3" "$f" 2>/dev/null) || { echo "The domain/default pair of ($2, $3) does not exist" >&2; exit 1; }
            case "$v" in true) echo 1;; false) echo 0;; *) echo "$v";; esac;;
    write)  if [ "${4:-}" != -bool ]; then [ -n "${4:-}" ] || exit 1   # a string value (autoLoginUser)
              "$pb" -c "Set :$3 $4" "$f" >/dev/null 2>&1 || "$pb" -c "Add :$3 string $4" "$f" >/dev/null 2>&1; exit 0; fi
            case "${5:-}" in true|YES|yes|1) b=true;; *) b=false;; esac
            "$pb" -c "Set :$3 $b" "$f" >/dev/null 2>&1 || "$pb" -c "Add :$3 bool $b" "$f" >/dev/null 2>&1;;
    delete) "$pb" -c "Delete :$3" "$f" >/dev/null 2>&1 || { echo "Domain ($2) not found." >&2; exit 1; };;
    *) exit 1;;
  esac; exit 0;;
esac
echo "defaults $1 $2 claimed=$c killed=$k" >>"$st/defaults.log"
[ "${SIM_DEFAULTS_FAIL:-}" = "$1" ] && { echo "defaults: $1 failed (mock)" >&2; exit 1; }
case "$1" in
  export) [ -e "$st/wsprefs.plist" ] || { echo "Domain $2 does not exist" >&2; exit 1; }
          # SIM_WS_REWRITE=1: WindowServer rewrote the one-display set (id 7) after the claim, before the restore
          [ "${SIM_WS_REWRITE:-0}" = 1 ] && [ "$c" = yes ] && "${MOCK_PB:-/usr/libexec/PlistBuddy}" -c "Set :DisplayAnyUserSets:2:0:Mode:IODisplayModeID 7" "$st/wsprefs.plist" >/dev/null
          cp "$st/wsprefs.plist" "$3";;
  import) cp "$3" "$st/wsprefs.plist";;
  *) exit 1;;
esac
exit 0
EOF
  # 11-03: /usr/bin/log show ... -> the kernel "WindowServer[pid] Corpse allowed" lines the mocks recorded in $st/corpses
  cat >"$BIN/log" <<'EOF'
#!/bin/bash
st="${SIM_STATE:-/tmp}"; echo "log $*" >>"$st/logcmd.log"
[ "${1:-}" = show ] && [ -e "$st/corpses" ] && while read -r p; do
  echo "2026-11-03 02:19:50.091 Df kernel[0:f1c] WindowServer[$p] Corpse allowed 1 of 5"; done <"$st/corpses"
: >"$st/corpses.seen"; exit 0
EOF
  cat >"$BIN/nvram" <<'EOF'
#!/bin/bash
st="${SIM_STATE:-/tmp}"
case "${1:-}" in -d) echo "nvram -d $2" >>"$st/nvram.log"; exit 0;; *=*) echo "nvram set $1" >>"$st/nvram.log"; exit 0;; *) exit 1;; esac
EOF
  cat >"$BIN/kmutil" <<'EOF'
#!/bin/bash
st="${SIM_STATE:-/tmp}"
case "${1:-}" in showloaded) [ -e "$st/accel" ] && echo "  160 0 org.vermilion.accel (0.1)";; load) echo "kmutil $*" >>"$st/kmutil.log"; : >>"$st/accel";; esac
exit 0
EOF
  cat >"$BIN/id" <<'EOF'
#!/bin/bash
[ "${1:-}" = -u ] && [ -n "${2:-}" ] && { echo 501; exit 0; }
exec /usr/bin/id "$@"
EOF
  cat >"$BIN/phxctl" <<'EOF'
#!/bin/bash
echo "GRBM_STATUS 0x02004: 0xa0003028 (mock)"; exit 0
EOF
  cat >"$BIN/launchctl" <<'EOF'
#!/bin/bash
st="${SIM_STATE:-/tmp}"; echo "launchctl $*" >>"$st/launchctl.log"
[ "${SIM_LAUNCHCTL_FAIL:-0}" = 1 ] && [ "$1" = setenv ] && exit 1; exit 0
EOF
  cat >"$BIN/shutdown" <<'EOF'
#!/bin/bash
st="${SIM_STATE:-/tmp}"; echo "shutdown $* @ $(date +%s)" >>"$st/shutdown.log"
# SIM_SHUTDOWN_TERM=1: launchd's TERM reaches the daemon while its own `shutdown -r now` is still running (m2_fail)
[ "${SIM_SHUTDOWN_TERM:-0}" = 1 ] && kill -TERM "$PPID"; exit 0
EOF
  cat >"$BIN/sleep" <<'EOF'
#!/bin/bash
rd(){ RV=$2; [ -r "$1" ] && IFS= read -r RV <"$1"; return 0; }   # = $(cat <file> 2>/dev/null || echo <default>) without a process
st="${SIM_STATE:-/tmp}"; dr="${SIM_DR:-/tmp}"
if [ "${1:-}" = 5 ] && [ "${SIM_CRASH_PER_STEP:-0}" = 1 ] && [ -e "$st/killed" ]; then
  rd "$st/crashn" 0; n=$RV; n=$((n+1)); echo "$n" >"$st/crashn"; : >"$dr/WindowServer-mock-$n.ips"
fi
# 11-03 silent crashes (no .ips): SIM_WS_SILENT=N: from the restart on, each `sleep 5`
# (the 120 s watch) replaces the WindowServer pid, up to N times, with a kernel corpse line and NO .ips;
# SIM_WS_LATE_SILENT=N / SIM_WS_LATE_LOGOUT=N: the same on each `sleep 15` (watch_hangs after done), with / without a corpse
wsbump(){ rd "$st/wspid" 12345; o=$RV; echo $((o+1)) >"$st/wspid"; [ "$1" = corpse ] && echo "$o" >>"$st/corpses"; }
if [ "${1:-}" = 5 ] && [ -n "${SIM_WS_SILENT:-}" ] && [ -e "$st/killed" ]; then
  rd "$st/silentn" 0; n=$RV; [ $n -lt "$SIM_WS_SILENT" ] && { echo $((n+1)) >"$st/silentn"; wsbump corpse; }
fi
if [ "${1:-}" = 15 ] && { [ -n "${SIM_WS_LATE_SILENT:-}" ] || [ -n "${SIM_WS_LATE_LOGOUT:-}" ]; }; then
  rd "$st/laten" 0; n=$RV; echo $((n+1)) >"$st/laten"
  [ -n "${SIM_WS_LATE_SILENT:-}" ] && [ $n -lt "$SIM_WS_LATE_SILENT" ] && wsbump corpse
  [ -n "${SIM_WS_LATE_LOGOUT:-}" ] && [ $n -lt "$SIM_WS_LATE_LOGOUT" ] && wsbump none
fi
# SIM_SHUTDOWN_W15=1: the session's WindowServer wrote its own copy of the prefs back ($SIM_RESAVE), then launchd's
# shutdown TERM reaches the daemon in watch_hangs (the first `sleep 15`)
if [ "${1:-}" = 15 ] && [ "${SIM_SHUTDOWN_W15:-0}" = 1 ] && [ ! -e "$st/termed" ]; then
  : >"$st/termed"; [ -n "${SIM_RESAVE:-}" ] && cp "$SIM_RESAVE" "$st/wsprefs.plist"; kill -TERM "$PPID"; /bin/sleep 0.2; exit 0
fi
if [ "${1:-}" = 5 ] && [ "${SIM_TERM_IN_WATCH:-0}" = 1 ] && [ -e "$st/killed" ] && [ ! -e "$st/termed" ]; then
  : >"$st/termed"; kill -TERM "$PPID"
fi
# SIM_TERM_LATE=<n>: the first `sleep <n>` while the in-progress mark exists models launchd's clean-shutdown TERM landing
# early in that sleep: TERM to the daemon, then the sleep goes on for SIM_SLEEP_REST s (3) while a mock launchd SIGKILLs
# the daemon SIM_EXIT_TIMEOUT s (1) after the TERM (the box: 5 s default ExitTimeOut vs a 5 s sleep, seen 11-02)
if [ -n "${SIM_TERM_LATE:-}" ] && [ "${1:-}" = "$SIM_TERM_LATE" ] && [ -e "${SIM_MARK:-/nonexistent}" ] && [ ! -e "$st/termed" ]; then
  : >"$st/termed"; d=$PPID; kill -TERM "$d"
  ( /bin/sleep "${SIM_EXIT_TIMEOUT:-1}"; kill -0 "$d" 2>/dev/null && { echo "SIGKILL after the exit timeout" >>"$st/launchd.log"; kill -9 "$d"; } ) &
  /bin/sleep "${SIM_SLEEP_REST:-3}"; exit 0
fi
/bin/sleep 0.01 2>/dev/null; exit 0
EOF
  cat >"$BIN/sync" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$BIN"/*
}
# the empty fake root every world() starts from (dirs + copies of the stubs the daemon runs from ~/gpu and /usr/local/sbin)
TPL=$SCR/world.tpl
make_world_tpl() { local FR=$TPL/fr
  mkdir -p "$FR/gpu/phxctl" "$FR/var/db" "$FR/Library/GPUBundles" "$FR/Library/Logs/DiagnosticReports" "$FR/usr/local/sbin" "$TPL/state"
  cp "$BIN/metaltest" "$FR/gpu/metaltest"; cp "$BIN/navi31_up.sh" "$FR/gpu/phxctl/navi31_up.sh"; cp "$BIN/mesboot" "$FR/usr/local/sbin/mesboot"
  chmod +x "$FR/gpu/metaltest" "$FR/gpu/phxctl/navi31_up.sh" "$FR/usr/local/sbin/mesboot"
  # the loginwindow system prefs as on the box, without SHOWFULLNAME (login-window guard; a scenario sets the user's own value)
  mkdir -p "$FR/Library/Preferences"; "$MOCK_PB" -c "Add :lastUserName string user" -c "Add :GuestEnabled bool false" "$FR/Library/Preferences/com.apple.loginwindow.plist" >/dev/null; }

# ---------------------------------------------------------------------------------------------- scenario DSL
world() {   # world: a fresh fake root + default-healthy SIM_* config
  W=$(mktemp -d "$SCR/scen.XXXXXX"); FR=$W/fr; ST=$W/state
  cp -Rp "$TPL/." "$W/"   # the fake root's dirs and stub copies, made once by make_world_tpl
  LOGF=$W/phxboot.log
  # SIM defaults = a healthy desktop-arm boot
  SIM_BRINGUP=1 SIM_CLAIM=1 SIM_NMXACCEL=1 SIM_PHXFB=1 SIM_FB=1 SIM_METAL=1 SIM_AGDC=1 SIM_USERS="" SIM_CRASH_PER_STEP=0 SIM_WS_NORESTART=0 SIM_SQUAT=0 SIM_SQUAT_LATE=0 SIM_AGDC_LATE=
  DESK=1; AUTOF=0   # default: desktop arm requested
  X_RC=0; X_LOG=""; X_NOLOG=""; DISPOVR_WAIT=""; X_KILLALL=-1; X_REBOOT=-1; X_NVRAM=""; X_NONVRAM=""; X_WRITES=""; X_ORDER=""; X_STAGE=""
  SIM_BOOTARGS="keepsyms=1" SIM_SYSCTL_FAIL="" SIM_GAMMA_BUSY="" SIM_CDPREF=""
  SIM_NO_RESYNC=0 SIM_RESYNC_ID=2 SIM_NMODES=2 SIM_AOCBOOT_RC=0
  SIM_DPW_NOOID=0 SIM_DPW_L2_EINVAL=0   # 11-03 S3 dpwatch
  SIM_HP0_NOOID=0   # 11-04 hotplug0
  SIM_LW_BROKEN_AT_TERM=0 SIM_LW_FAIL=""   # 11-04 login-window guard
  SIM_LAUNCHCTL_FAIL=0   # 11-19 wscdcopy
  SIM_WAITSTEP_NOOID=0   # 11-19 waitstep
  SIM_IRQWAIT_NOOID=0    # 11-23 irqwait
  SIM_BOVRAM_NOOID=0; SIM_BOVRAM_ST=1   # 11-23 bovram
  SIM_GL_NOOID=0   # 11-23 gl (thread 03)
  SIM_AUDIO_NOOID=0   # 11-24 audio (thread 04)
  SIM_VRRMIN_NOOID=0     # 11-22 VRR floor
  SIM_P0_OLD=0           # 11-20 p0modes
  SIM_P0ODM="" SIM_P0_DARK=0   # 11-23 display check
  SIM_TERM_LATE="" SIM_SHUTDOWN_TERM=0
  SIM_SAFEBOOT=0 SIM_LOGIN_AFTER_KILL="" SIM_SLEEP_REST=""   # 2026-11-25 recovery without the manual rm
  UPHANG=""   # 2026-11-25 PHXBOOT_UP_HANG (empty: the daemon's 60 s)
  # 11-03 first-WindowServer fix: its model off, no silent crashes, the watch after `done` off
  SIM_WSMODEL=0 SIM_WS_SILENT="" SIM_WS_LATE_SILENT="" SIM_WS_LATE_LOGOUT="" SIM_DEFAULTS_FAIL="" SIM_WS_REWRITE=0 SIM_SHUTDOWN_W15=0 SIM_RESAVE="" SIM_OFFER_GATE=0 SIM_OFFER_LATE="" SIM_HEAD0_SINGLE=0 SIM_NO_SOLO=0 SIM_AOCBOOT1_RC=0; NOWATCH=1; WATCHMAX=""
  X_DEFAULTS=""; X_PREFS_ORIG=0; X_PREFS=""
}
# 11-03 first-WindowServer fix helpers
FIXT=$HERE/fixtures/wsprefs-aoc144.plist
prefs_world(){ world; cp "$FIXT" "$ST/wsprefs.plist"; SIM_WSMODEL=1; touch "$FR/gpu/phxboot-m7-aocmodes"; }   # the box prefs of 11-03 (AOC alone at id 2 / 144)
expect_defaults(){ X_DEFAULTS="$X_DEFAULTS
$1"; }                                      # expect_defaults <ERE>: a defaults.log line (verb domain claimed= killed=) matches
expect_prefs_original(){ X_PREFS_ORIG=1; }
expect_cmd(){ X_CMDS="${X_CMDS:-}
$1"; }                                      # expect_cmd <shell test>: must succeed after the run (W/FR/ST are set)
expect_stash_val(){ X_STASH="${X_STASH:-}
$1	$2"; }                                  # expect_stash_val <key> <value>: the AOC's stash file holds that value  # the fake system prefs end byte-for-byte equal (as JSON) to the fixture
expect_prefs(){ X_PREFS="$X_PREFS
$1	$2"; }                                  # expect_prefs <PlistBuddy key> <value>: the final fake prefs hold that value
expect_writes()  { X_WRITES="$X_WRITES
$2	$1"; }                                  # expect_writes <ERE> <n>: exactly n sysctl -w lines match
expect_order()   { X_ORDER="$X_ORDER
$1	$2"; }                                  # expect_order <ERE a> <ERE b>: a's first log line comes before b's
expect_stage()   { X_STAGE="$X_STAGE
$1"; }                                      # expect_stage <ERE>: a stage.log line (oid=value killed= bound=) matches
expect_nvram()   { X_NVRAM="$X_NVRAM
$1"; }
expect_nonvram() { X_NONVRAM="$X_NONVRAM
$1"; }
expect_rc()      { X_RC=$1; }
expect_file()    { X_FILE="$1"; }      # expect_file <path>: must exist after the run
expect_nofile()  { X_NOFILE="$1"; }    # expect_nofile <path>: must not exist after the run
expect_log()     { X_LOG="$X_LOG
$1"; }
expect_nolog()   { X_NOLOG="$X_NOLOG
$1"; }
expect_killall() { X_KILLALL=1; }      # killall -9 WindowServer MUST have been issued
expect_no_killall(){ X_KILLALL=0; }    # killall MUST NOT have been issued (safety)
expect_reboot()  { X_REBOOT=1; }       # m2_fail / watch issued shutdown -r
expect_no_reboot(){ X_REBOOT=0; }

# boot: one daemon run on the current world (go = boot + the checks). 11-03: the first WindowServer (pid 12345) reads the
# fake system prefs ONCE, before the daemon runs (SkyLight create_server_preferences): its copy
# is $ST/ws0-snapshot.plist, the one the first-WindowServer model in the sysctl shim uses
boot() {
  [ "$DESK" = 1 ] && : >>"$FR/gpu/phxboot-desktop"
  [ "$AUTOF" = 1 ] && : >>"$FR/gpu/phxboot-auto"
  rm -f "$ST/ws0-snapshot.plist"; [ -e "$ST/wsprefs.plist" ] && cp "$ST/wsprefs.plist" "$ST/ws0-snapshot.plist"
  ( export SIM_STATE=$ST SIM_DR=$FR/Library/Logs/DiagnosticReports \
           SIM_BRINGUP SIM_CLAIM SIM_NMXACCEL SIM_PHXFB SIM_FB SIM_METAL SIM_AGDC SIM_USERS SIM_CRASH_PER_STEP SIM_TERM_IN_WATCH SIM_WS_NORESTART SIM_SQUAT SIM_SQUAT_LATE SIM_AGDC_LATE \
           SIM_BOOTARGS SIM_SYSCTL_FAIL SIM_GAMMA_BUSY SIM_CDPREF SIM_NO_RESYNC SIM_RESYNC_ID SIM_NMODES SIM_AOCBOOT_RC \
           SIM_TERM_LATE SIM_SHUTDOWN_TERM SIM_MARK="$FR/var/db/phxboot.pending" SIM_SAFEBOOT SIM_LOGIN_AFTER_KILL SIM_SLEEP_REST \
           SIM_WSMODEL SIM_WS_SILENT SIM_WS_LATE_SILENT SIM_WS_LATE_LOGOUT SIM_DEFAULTS_FAIL SIM_WS_REWRITE SIM_SHUTDOWN_W15 SIM_RESAVE SIM_OFFER_GATE SIM_OFFER_LATE SIM_HEAD0_SINGLE SIM_NO_SOLO SIM_AOCBOOT1_RC SIM_DPW_NOOID SIM_DPW_L2_EINVAL SIM_HP0_NOOID SIM_LW_BROKEN_AT_TERM SIM_LW_FAIL SIM_LAUNCHCTL_FAIL SIM_WAITSTEP_NOOID SIM_IRQWAIT_NOOID SIM_BOVRAM_NOOID SIM_BOVRAM_ST SIM_GL_NOOID SIM_AUDIO_NOOID SIM_VRRMIN_NOOID SIM_P0_OLD SIM_P0ODM SIM_P0_DARK
    export PATH="$BIN:$MOCK_SHIMPATH$MOCK_SYSPATH"   # macOS: $BIN:/usr/bin:/bin:/usr/sbin:/sbin (lib/portable.sh)
    env PHXBOOT_G="$FR/gpu" PHXBOOT_HOME="$FR" PHXBOOT_LOG="$LOGF" PHXBOOT_MARK="$FR/var/db/phxboot.pending" \
        PHXBOOT_OFF="$FR/gpu/phxboot-off" PHXBOOT_DESKTOP="$FR/gpu/phxboot-desktop" \
        PHXBOOT_ALLOW="$FR/Library/GPUBundles/nvmtl-allow.txt" PHXBOOT_DR="$FR/Library/Logs/DiagnosticReports" \
        PHXBOOT_MB="$FR/usr/local/sbin/mesboot" PHXBOOT_NO_WATCH=$NOWATCH PHXBOOT_WATCH_MAX="$WATCHMAX" PHXBOOT_RUNAS="" \
        PHXBOOT_WSPTMP="$W" PHXBOOT_PLISTBUDDY="$MOCK_PB" PHXBOOT_LOGCMD="$BIN/log" PHXBOOT_DISPOVR_WAIT="${DISPOVR_WAIT:-10}" PHXBOOT_PHXCTL="$BIN/phxctl" PHXBOOT_FAILS="$FR/var/db/phxboot.fails" PHXBOOT_NOTICE="$FR/var/db/phxboot.notice" PHXBOOT_NOTICE_NEXT="$FR/var/db/phxboot.notice-next" PHXBOOT_NOTICE_FG=1 PHXBOOT_NOTICE_WAIT=6 PHXBOOT_UP_HANG="${UPHANG:-60}" PHXBOOT_HANGDIR="$W/hang" PHXBOOT_DARKF="$FR/var/db/phxboot.darkrestart" PHXBOOT_PTWALK="$W/none.sh" PHXBOOT_AUTO="$FR/gpu/phxboot-auto" PHXBOOT_LWDOM="$FR/Library/Preferences/com.apple.loginwindow" PHXBOOT_KCPASSWORD="$FR/etc/kcpassword" PHXBOOT_LWRAN="$FR/var/run/com.apple.loginwindow.didRunThisBoot" \
        PHXBOOT_GPUPRESENT="$FR/Library/GPUBundles/nvmtl/ws-gpu-present" PHXBOOT_WSASYNC="$FR/Library/GPUBundles/nvmtl/ws-gpu-present-async" \
        bash "$DAEMON" )
}
# reboot_world: the state a reboot resets (the WindowServer and kernel state), keeping the fake root (prefs, stash, flags)
reboot_world(){ rm -f "$ST/killed" "$ST/claimed" "$ST/wspid" "$ST/val.resync" "$ST/val.offer" "$ST/val.opens" "$ST/offerlaten" "$ST/sysctl.log" "$ST/stage.log" "$ST/silentn" "$ST/laten" "$ST/crashn" "$ST/corpses" "$ST/model.log" \
                      "$ST/killall.log" "$ST/shutdown.log" "$ST/defaults.log" "$ST/prefs-at-kill.plist" "$ST/termed" "$ST/lw.log"; }
# boot1: a first boot of a two-boot scenario (its log in $W/boot1.log, no checks), then the reboot
boot1(){ local l=$LOGF; LOGF=$W/boot1.log; boot; LOGF=$l; reboot_world; }
go() {   # go <name>
  local name=$1
  boot
  local rc=$?
  local ok=1 why=""
  [ "$rc" = "$X_RC" ] || { ok=0; why="$why rc $rc!=$X_RC;"; }
  local p
  while IFS= read -r p; do [ -n "$p" ] || continue; grep -Eq -- "$p" "$LOGF" || { ok=0; why="$why missing/$p/;"; }; done <<<"$X_LOG"
  while IFS= read -r p; do [ -n "$p" ] || continue; grep -Eq -- "$p" "$LOGF" && { ok=0; why="$why unexpected/$p/;"; }; done <<<"$X_NOLOG"
  if [ "$X_KILLALL" = 1 ]; then [ -e "$ST/killall.log" ] || { ok=0; why="$why killall NOT issued;"; }; fi
  if [ "$X_KILLALL" = 0 ]; then [ -e "$ST/killall.log" ] && { ok=0; why="$why killall WAS issued (unsafe!);"; }; fi
  if [ "$X_REBOOT" = 1 ]; then [ -e "$ST/shutdown.log" ] || { ok=0; why="$why reboot NOT issued;"; }; fi
  if [ "$X_REBOOT" = 0 ]; then [ -e "$ST/shutdown.log" ] && { ok=0; why="$why reboot WAS issued;"; }; fi
  : >>"$ST/nvram.log"
  while IFS= read -r p; do [ -n "$p" ] || continue; grep -Eq -- "$p" "$ST/nvram.log" || { ok=0; why="$why nvram missing/$p/;"; }; done <<<"$X_NVRAM"
  while IFS= read -r p; do [ -n "$p" ] || continue; grep -Eq -- "$p" "$ST/nvram.log" && { ok=0; why="$why nvram unexpected/$p/;"; }; done <<<"$X_NONVRAM"
  [ -n "${X_FILE:-}" ] && { [ -e "$X_FILE" ] || { ok=0; why="$why file missing $X_FILE;"; }; }; X_FILE=""
  [ -n "${X_NOFILE:-}" ] && { [ -e "$X_NOFILE" ] && { ok=0; why="$why file left $X_NOFILE;"; }; }; X_NOFILE=""
  [ -e "$ST/launchd.log" ] && { ok=0; why="$why SIGKILLed by the mock launchd (TERM trap too late);"; }
  [ "${X_NOMARK:-0}" = 1 ] && { [ -e "$FR/var/db/phxboot.pending" ] && { ok=0; why="$why in-progress mark left;"; }; }
  X_NOMARK=0
  : >>"$ST/sysctl.log"; : >>"$ST/stage.log"
  local n c a b la lb
  while IFS=$'\t' read -r n p; do [ -n "$p" ] || continue; c=$(grep -Ec -- "$p" "$ST/sysctl.log"); [ "$c" = "$n" ] || { ok=0; why="$why writes/$p/=$c!=$n;"; }; done <<<"$X_WRITES"
  while IFS=$'\t' read -r a b; do [ -n "$a" ] || continue
    la=$(grep -En -- "$a" "$LOGF" | head -1 | cut -d: -f1); lb=$(grep -En -- "$b" "$LOGF" | head -1 | cut -d: -f1)
    [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ] || { ok=0; why="$why order/$a/(${la:-none})</$b/(${lb:-none});"; }; done <<<"$X_ORDER"
  while IFS= read -r p; do [ -n "$p" ] || continue; grep -Eq -- "$p" "$ST/stage.log" || { ok=0; why="$why stage missing/$p/;"; }; done <<<"$X_STAGE"
  grep -Eq '^(set|delete)' "$ST/cdpref.log" 2>/dev/null && { ok=0; why="$why the daemon CHANGED the CoreDisplay pref;"; }
  [ "${X_KMLOAD:-0}" = 1 ] && { grep -q "kmutil load" "$ST/kmutil.log" 2>/dev/null || { ok=0; why="$why PhxAccel not loaded;"; }; }
  X_KMLOAD=0
  : >>"$ST/defaults.log"
  while IFS= read -r p; do [ -n "$p" ] || continue; grep -Eq -- "$p" "$ST/defaults.log" || { ok=0; why="$why defaults missing/$p/;"; }; done <<<"$X_DEFAULTS"
  if [ "${X_KILLPREFS:-0}" = 1 ]; then
    [ "$(plutil -convert json -o - "$ST/prefs-at-kill.plist" 2>&1)" = "$(plutil -convert json -o - "$FIXT")" ] || { ok=0; why="$why prefs at the killall NOT the original;"; }; fi
  X_KILLPREFS=0
  while IFS=$'\t' read -r a b; do [ -n "$a" ] || continue
    c=$(awk -F'\t' -v k="$a" '$1==k{print $2}' "$FR/gpu/phxboot-wsprefs.stash.d/2026439080" 2>/dev/null); [ "$c" = "$b" ] || { ok=0; why="$why stash $a=$c!=$b;"; }; done <<<"${X_STASH:-}"
  X_STASH=""
  while IFS= read -r p; do [ -n "$p" ] || continue; ( eval "$p" ) >/dev/null 2>&1 || { ok=0; why="$why cmd failed/$p/;"; }; done <<<"${X_CMDS:-}"
  X_CMDS=""
  if [ "$X_PREFS_ORIG" = 1 ]; then
    [ "$(plutil -convert json -o - "$ST/wsprefs.plist" 2>&1)" = "$(plutil -convert json -o - "$FIXT")" ] || { ok=0; why="$why prefs NOT back to the original;"; }; fi
  while IFS=$'\t' read -r a b; do [ -n "$a" ] || continue
    c=$("$MOCK_PB" -c "Print :$a" "$ST/wsprefs.plist" 2>&1); [ "$c" = "$b" ] || { ok=0; why="$why prefs $a=$c!=$b;"; }; done <<<"$X_PREFS"
  if [ $ok = 1 ]; then PASSN=$((PASSN+1)); printf 'PASS  %-26s rc=%s\n' "$name" "$rc"
  else FAILN=$((FAILN+1)); FAILED="$FAILED $name"; printf 'FAIL  %-26s rc=%s %s\n        (log: %s)\n' "$name" "$rc" "$why" "$LOGF"; KEEP=1; fi
  [ $KEEP = 1 ] || rm -rf "$W"
}

# ---------------------------------------------------------------------------------------------- scenarios
sc_happy() {            world; expect_rc 0; expect_log 'PhxAMDFB on panel'; expect_log 'Metal device ready'; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go happy; }
sc_metal_stderr_guard(){ world; expect_rc 0; expect_log 'Metal device ready after'; expect_log 'SUCCESS'; expect_nolog 'Metal device never came up'; expect_killall; go metal_stderr_guard; }   # proves the 2>&1 fix: metaltest logs only to stderr
sc_metal_fail() {       world; SIM_METAL=0; expect_rc 0; expect_log 'FAIL \(Metal device never came up\)'; expect_no_killall; expect_reboot; go metal_fail; }
sc_phxfb_fail() {       world; SIM_PHXFB=0; expect_rc 0; expect_log 'FAIL \(PhxAMDFB never took the panel'; expect_no_killall; expect_reboot; go phxfb_fail; }
sc_nmxaccel_fail() {    world; SIM_NMXACCEL=0; expect_rc 0; expect_log 'FAIL \(NMXAccel did not start\)'; expect_no_killall; expect_reboot; go nmxaccel_fail; }
sc_user_logged() {      world; SIM_USERS="user console 2026 Oct 24"; expect_rc 0; expect_log 'a user is logged in'; expect_no_killall; expect_reboot; go user_logged; }
sc_killswitch() {       world; touch "$FR/gpu/phxboot-off"; expect_rc 0; expect_log 'kill switch present'; expect_no_killall; expect_no_reboot; expect_nolog 'bring-up'; go killswitch; }
sc_mark_recovery() {    world; mkdir -p "$FR/var/db"; touch "$FR/var/db/phxboot.pending"; expect_rc 0; expect_log 'previous attempt did not finish'; expect_no_killall; expect_no_reboot; go mark_recovery; }
sc_not_desktop() {      world; DESK=0; expect_rc 0; expect_log 'no desktop arm: GOP'; expect_no_killall; expect_no_reboot; expect_nolog 'SUCCESS'; go not_desktop; }
sc_crash_loop() {       world; SIM_CRASH_PER_STEP=1; expect_rc 0; expect_log 'WindowServer crashed/hung'; expect_killall; expect_reboot; expect_nolog 'SUCCESS'; go crash_loop; }
sc_ws_norestart() {     world; SIM_WS_NORESTART=1; expect_rc 0; expect_log 'no WindowServer after the restart'; expect_killall; expect_reboot; go ws_norestart; }
sc_agdc_fail() {        world; SIM_AGDC=-6; expect_rc 0; expect_log 'AGDC failed to arm'; expect_no_killall; expect_reboot; expect_nolog 'SUCCESS'; go agdc_fail; }        # M2: silent AGDC failure must NOT false-SUCCESS
sc_agdc_late() {        world; SIM_AGDC_LATE=3; expect_rc 0; expect_log 'AGDC up after'; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go agdc_late; }   # oid appears late: the arm must be retried, not lost
sc_agdc_never() {       world; SIM_AGDC=0; expect_rc 0; expect_log 'AGDC never armed'; expect_no_killall; expect_reboot; expect_nolog 'SUCCESS'; go agdc_never; }
# squat mode: desktop-arm comes from PhxFBSquatter being present (no phxboot-desktop file)
sc_squat_happy() {      world; DESK=0; SIM_SQUAT=1; AUTOF=1; expect_log 'squat boot .*: 1'; expect_log 'SUCCESS'; expect_log 'phxfb-squat re-armed'; expect_nvram 'set phxfb-boot=1'; expect_nvram 'set phxfb-squat=1'; expect_killall; expect_no_reboot; X_KMLOAD=1; go squat_happy; }
sc_squat_noauto() {     world; DESK=0; SIM_SQUAT=1; expect_log 'SUCCESS'; expect_nolog 're-armed'; expect_nonvram 'set phxfb-squat'; expect_killall; expect_no_reboot; go squat_noauto; }
sc_squat_killswitch() { world; DESK=0; SIM_SQUAT=1; AUTOF=1; touch "$FR/gpu/phxboot-off"; expect_log 'rebooting onto IONDRV'; expect_nolog 'bring-up'; expect_no_killall; expect_reboot; go squat_killswitch; }
sc_squat_mark() {       world; DESK=0; SIM_SQUAT=1; AUTOF=1; touch "$FR/var/db/phxboot.pending"; expect_log 'previous attempt did not finish'; expect_log 'rebooting onto IONDRV'; expect_nvram '-d phxfb-squat'; expect_no_killall; expect_reboot; go squat_mark; }
sc_squat_metal_fail() { world; DESK=0; SIM_SQUAT=1; AUTOF=1; SIM_METAL=0; expect_log 'FAIL \(Metal device never came up\)'; expect_nvram '-d phxfb-squat'; expect_nonvram 'set phxfb-squat'; expect_no_killall; expect_reboot; go squat_metal_fail; }
sc_squat_user() {       world; DESK=0; SIM_SQUAT=1; AUTOF=1; SIM_USERS="user console"; expect_log 'a user is logged in'; expect_nonvram 'set phxfb-squat'; expect_no_killall; expect_reboot; go squat_user; }
sc_squat_crash() {      world; DESK=0; SIM_SQUAT=1; AUTOF=1; SIM_CRASH_PER_STEP=1; expect_log 'WindowServer crashed/hung'; expect_log 'GPU state .*GRBM_STATUS|GRBM_STATUS'; expect_nonvram 'set phxfb-squat'; expect_reboot; go squat_crash; }
vcn_stub(){ mkdir -p "$FR/gpu/vcnup"; printf '#!/bin/bash\necho "vcn_up stub"\nexit %s\n' "$1" > "$FR/gpu/vcnup/vcn_up.sh"; chmod +x "$FR/gpu/vcnup/vcn_up.sh"; }
sc_vcn_off() {          world; vcn_stub 0; expect_log 'SUCCESS'; expect_nolog 'vcn:'; expect_no_reboot; go vcn_off; }
sc_vcn_up() {           world; vcn_stub 0; touch "$FR/gpu/phxboot-vcn"; expect_log 'SUCCESS'; expect_log 'vcn: up, ring adopted, MMHUB VM on'; expect_no_reboot; go vcn_up; }
sc_vcn_fail() {         world; vcn_stub 1; touch "$FR/gpu/phxboot-vcn"; expect_log 'SUCCESS'; expect_log 'vcn: bring-up failed'; expect_nolog 'MMHUB VM on'; expect_no_reboot; go vcn_fail; }
b15_stub(){ printf '#!/bin/sh\necho "b15: stub ran"\n' > "$FR/gpu/b15_boot.sh"; }
sc_b15_off() {          world; b15_stub; expect_log 'SUCCESS'; expect_nolog 'b15:'; expect_no_reboot; go b15_off; }
sc_b15_on() {           world; b15_stub; touch "$FR/gpu/phxboot-b15"; expect_log 'SUCCESS'; expect_log 'b15: started'; expect_log 'b15: stub ran'; expect_no_reboot; go b15_on; }
sc_b15_missing() {      world; touch "$FR/gpu/phxboot-b15"; expect_log 'SUCCESS'; expect_log 'b15: .*b15_boot.sh missing'; expect_no_reboot; go b15_missing; }
sc_b15_nodesk() {       world; DESK=0; b15_stub; touch "$FR/gpu/phxboot-b15"; expect_log 'b15: not a desktop boot'; expect_nolog 'b15: stub ran'; expect_no_reboot; go b15_nodesk; }
# 11-23 idledpm: ~/gpu/phxboot-idledpm starts idle_dpm.sh in the background on a one-display desktop boot, never next to b15
idpm_stub(){ printf '#!/bin/sh\necho "idledpm: stub ran G=$PHXBOOT_G"\n' > "$FR/gpu/idle_dpm.sh"; }
sc_idledpm_off() {      world; idpm_stub; expect_log 'SUCCESS'; expect_nolog 'idledpm'; expect_no_reboot; go idledpm_off; }
sc_idledpm_on() {       world; idpm_stub; touch "$FR/gpu/phxboot-idledpm"; expect_log 'SUCCESS'; expect_log 'idledpm: started'; expect_log 'idledpm: stub ran G=.'; expect_no_reboot; go idledpm_on; }
sc_idledpm_missing() {  world; touch "$FR/gpu/phxboot-idledpm"; expect_log 'SUCCESS'; expect_log 'idledpm: .*idle_dpm.sh missing'; expect_no_reboot; go idledpm_missing; }
sc_idledpm_b15() {      world; idpm_stub; b15_stub; touch "$FR/gpu/phxboot-idledpm" "$FR/gpu/phxboot-b15"; expect_log 'idledpm: phxboot-b15 present'; expect_nolog 'idledpm: stub ran'; expect_log 'b15: stub ran'; expect_no_reboot; go idledpm_b15; }
sc_idledpm_nodesk() {   world; DESK=0; idpm_stub; touch "$FR/gpu/phxboot-idledpm"; expect_log 'idledpm: not a desktop boot'; expect_nolog 'idledpm: stub ran'; expect_no_reboot; go idledpm_nodesk; }
# 11-23 bovram: ~/gpu/phxboot-bovram -> the self-test, then debug.phxbo_vram_proc and debug.phxbo_vram=1
bv_flag(){ printf '%s' "$1" >"$FR/gpu/phxboot-bovram"; }
sc_bovram_off() {       world; expect_nolog 'bovram'; expect_writes 'phxbo_vram' 0; expect_log 'SUCCESS'; go bovram_off; }
sc_bovram_on() {        world; bv_flag 'vkbench,metalbench'; expect_writes '^-w debug.phxbo_vram_selftest=1$' 1; expect_writes '^-w debug.phxbo_vram_proc=vkbench,metalbench$' 1
                        expect_writes '^-w debug.phxbo_vram=1$' 1; expect_log 'bovram: on for vkbench,metalbench \(self-test 1\)'; expect_log 'SUCCESS'; go bovram_on; }
sc_bovram_stfail() {    world; bv_flag 'vkbench'; SIM_BOVRAM_ST=-7; expect_writes '^-w debug.phxbo_vram=1$' 0; expect_writes 'phxbo_vram_proc' 0
                        expect_log "bovram: self-test reads '-7', not 1"; expect_log 'SUCCESS'; go bovram_stfail; }
sc_bovram_ws() {        world; bv_flag 'vkbench,WindowServer'; expect_writes 'phxbo_vram' 0; expect_log 'bovram: WindowServer stays'; expect_log 'SUCCESS'; go bovram_ws; }
sc_bovram_bad() {       world; bv_flag 'a;rm -rf /'; expect_writes 'phxbo_vram' 0; expect_log 'bovram: .*not a list of process names'; expect_log 'SUCCESS'; go bovram_bad; }
sc_bovram_empty() {     world; bv_flag ''; expect_writes 'phxbo_vram' 0; expect_log 'bovram: .*not a list of process names'; go bovram_empty; }
sc_bovram_oldkext() {   world; bv_flag 'vkbench'; SIM_BOVRAM_NOOID=1; expect_writes 'phxbo_vram' 0; expect_log 'bovram: VermilionBoot before b156'; go bovram_oldkext; }
sc_bovram_nodesk() {    world; DESK=0; bv_flag 'vkbench'; expect_writes 'phxbo_vram' 0; expect_log 'bovram: not a desktop boot'; go bovram_nodesk; }
# 11-23 (thread 03) gl: ~/gpu/phxboot-gl -> debug.phxgl=1, read back
sc_gl_off() {           world; expect_nolog 'gl: '; expect_writes 'phxgl' 0; expect_log 'SUCCESS'; go gl_off; }
sc_gl_on() {            world; : >"$FR/gpu/phxboot-gl"; expect_writes '^-w debug.phxgl=1$' 1; expect_log 'gl: OpenGL over Metal on'; expect_log 'SUCCESS'; go gl_on; }
sc_gl_oldkext() {       world; : >"$FR/gpu/phxboot-gl"; SIM_GL_NOOID=1; expect_writes 'phxgl' 0; expect_log 'gl: VermilionAccel without debug.phxgl'; expect_log 'SUCCESS'; go gl_oldkext; }
sc_gl_fail() {          world; : >"$FR/gpu/phxboot-gl"; SIM_SYSCTL_FAIL=debug.phxgl; expect_log 'gl: debug.phxgl=1 refused: off'; expect_log 'SUCCESS'; go gl_fail; }
# 11-24 (thread 04) audio: ~/gpu/phxboot-audio -> phxaudio apply, then audio_match.sh on (each stub leaves a marker file)
audio_stub(){   # audio_stub <phxaudio rc>
  printf '#!/bin/bash\n: >"%s/audio.dc"\necho "phxaudio: 90 writes, end state %s"\nexit %s\n' "$FR" "$([ "$1" = 0 ] && echo ok || echo WRONG)" "$1" >"$FR/gpu/phxaudio"; chmod +x "$FR/gpu/phxaudio"
  printf '#!/bin/sh\n[ "$1" = on ] && : >"%s/audio.match"\necho "audio: DP audio engine up after 1 s"\n' "$FR" >"$FR/gpu/audio_match.sh"; }
sc_audio_off() {        world; audio_stub 0; expect_nolog 'audio: '; expect_nofile "$FR/audio.dc"; expect_log 'SUCCESS'; go audio_off; }
sc_audio_on() {         world; audio_stub 0; : >"$FR/gpu/phxboot-audio"; expect_log 'audio: display engine programmed \(90 writes, end state ok\)'
                        expect_order 'audio: display engine programmed' 'audio: DP audio engine up after 1 s'; expect_order 'SUCCESS' 'audio: display engine'
                        expect_file "$FR/audio.match"; go audio_on; }
sc_audio_dcfail() {     world; audio_stub 1; : >"$FR/gpu/phxboot-audio"; expect_log 'audio: display engine not programmed \(phxaudio: 90 writes, end state WRONG\): AppleGFXHDA not attached'
                        expect_nofile "$FR/audio.match"; expect_log 'SUCCESS'; go audio_dcfail; }
sc_audio_noplugin() {   world; audio_stub 0; : >"$FR/gpu/phxboot-audio"; SIM_AUDIO_NOOID=1; expect_log 'audio: VermilionAudio not loaded'; expect_nofile "$FR/audio.dc"; go audio_noplugin; }
sc_audio_missing() {    world; : >"$FR/gpu/phxboot-audio"; expect_log 'audio: .*phxaudio or .*audio_match.sh missing: off'; go audio_missing; }
sc_audio_nodesk() {     world; DESK=0; audio_stub 0; : >"$FR/gpu/phxboot-audio"; expect_log 'audio: not a desktop boot'; expect_nofile "$FR/audio.dc"; go audio_nodesk; }
sc_gl_nodesk() {        world; DESK=0; : >"$FR/gpu/phxboot-gl"; expect_writes 'phxgl' 0; expect_log 'gl: not a desktop boot'; go gl_nodesk; }
# M7 boot bring-up: the stub prints whether the AGDC was armed and WindowServer restarted when it ran (order proof)
m7_stub(){ printf '#!/bin/sh\nk=no; [ -e "$SIM_STATE/killed" ] && k=yes\na=no; grep -q "debug.phxagdc=1" "$SIM_STATE/sysctl.log" 2>/dev/null && a=yes\necho "m7: stub $1 agdc_written=$a killed=$k"\n[ "$1" = light ] && exit ${M7_LIGHT_RC:-0}\n[ "$1" = bind ] && { [ "${M7_BIND_RC:-0}" = 0 ] && touch "$SIM_STATE/bound"; exit ${M7_BIND_RC:-0}; }\nexit 0\n' > "$FR/gpu/m7_boot.sh"; }
sc_m7_off() {           world; m7_stub; expect_log 'SUCCESS'; expect_nolog 'm7:'; expect_killall; expect_no_reboot; go m7_off; }
sc_m7_on() {            world; m7_stub; touch "$FR/gpu/phxboot-m7"; expect_log 'm7: stub light agdc_written=no killed=no'; expect_log 'm7: stub bind agdc_written=yes killed=no'; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go m7_on; }
sc_m7_light_fail() {    world; m7_stub; touch "$FR/gpu/phxboot-m7"; export M7_LIGHT_RC=1; expect_log 'm7: stub light'; expect_nolog 'm7: stub bind'; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go m7_light_fail; unset M7_LIGHT_RC; }
sc_m7_bind_fail() {     world; m7_stub; touch "$FR/gpu/phxboot-m7"; export M7_BIND_RC=1; expect_log 'm7: stub bind'; expect_log 'm7: bind failed: one monitor'; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go m7_bind_fail; unset M7_BIND_RC; }
sc_m7_no_late_smu() {   world; m7_stub; vcn_stub 0; touch "$FR/gpu/phxboot-m7" "$FR/gpu/phxboot-vcn" "$FR/gpu/phxboot-uclk"; printf '#!/bin/sh\necho "uclk stub $*"\n' > "$FR/gpu/uclk.sh"; export M7_LIGHT_RC=3; expect_log 'm7: stub bind'; expect_log 'vcn: skipped: pipe 1 lit at boot'; expect_nolog 'vcn: up'; expect_log 'uclk: late pin skipped'; expect_log 'SUCCESS'; expect_no_reboot; go m7_no_late_smu; unset M7_LIGHT_RC; }
sc_m7_phase_ok_smu() {  world; m7_stub; vcn_stub 0; touch "$FR/gpu/phxboot-m7" "$FR/gpu/phxboot-vcn" "$FR/gpu/phxboot-uclk"; printf '#!/bin/sh\necho "uclk stub $*"\n' > "$FR/gpu/uclk.sh"; expect_log 'm7: stub bind'; expect_log 'vcn: up, ring adopted'; expect_nolog 'vcn: skipped'; expect_nolog 'late pin skipped'; expect_log 'SUCCESS'; expect_no_reboot; go m7_phase_ok_smu; }
sc_m7_light_fail_vcn() { world; m7_stub; vcn_stub 0; touch "$FR/gpu/phxboot-m7" "$FR/gpu/phxboot-vcn"; export M7_LIGHT_RC=1; expect_log 'vcn: up, ring adopted'; expect_nolog 'vcn: skipped'; expect_log 'SUCCESS'; expect_no_reboot; go m7_light_fail_vcn; unset M7_LIGHT_RC; }
sc_m7_missing() {       world; touch "$FR/gpu/phxboot-m7"; expect_log 'm7: .*m7_boot.sh missing'; expect_log 'SUCCESS'; expect_no_reboot; go m7_missing; }
# AOC at 144: the head-0 mode list flag goes to the kext before the claim (PhxAMDFB head 0 reads it when it starts there)
sc_aoc_off() {          world; expect_log 'SUCCESS'; expect_nolog 'aoc:'; expect_nolog 'phxpipe0_modes was set'; expect_no_reboot; go aoc_off; }
sc_aoc_modes() {        world; touch "$FR/gpu/phxboot-m7-aocmodes"; expect_log 'aoc: head-0 mode list armed'; expect_log 'claim: phxpipe0_modes was set before the claim'; expect_log 'SUCCESS'; expect_no_reboot; go aoc_modes; }
sc_aoc_144flag() {      world; touch "$FR/gpu/phxboot-m7-aoc144"; expect_log 'aoc: head-0 mode list armed'; expect_log 'claim: phxpipe0_modes was set before the claim'; expect_log 'SUCCESS'; expect_no_reboot; go aoc_144flag; }
# 11-01 boot flags: ~/gpu/phxboot-hotplug -> debug.phxhotplug=2 and
# ~/gpu/phxboot-gamma -> debug.phxgamma=1, each written once after `done` (WindowServer restarted, head 1 bound) and before
# b15_boot starts; boot-arg -phxhotplugoff, no head 1, not a desktop boot = no write; a refused write is logged, the boot goes on
cdpref_stub(){ printf '#!/bin/sh\necho "$*" >> "$SIM_STATE/cdpref.log"\ncase "${SIM_CDPREF:-false}" in false) echo "uid 0 useIOP_gamma_onAMD = false"; exit 0;; true) echo "uid 0 useIOP_gamma_onAMD = true"; exit 0;; *) echo "uid 0 useIOP_gamma_onAMD = (absent)"; exit 1;; esac\n' > "$FR/gpu/cdpref"; chmod +x "$FR/gpu/cdpref"; }
flags_world(){ world; m7_stub; b15_stub; touch "$FR/gpu/phxboot-m7" "$FR/gpu/phxboot-b15"; }   # two monitors, b15 on (order witness)
sc_hotplug_off() {      flags_world; expect_log 'SUCCESS'; expect_nolog 'hotplug:'; expect_writes 'debug.phxhotplug' 0; expect_no_reboot; go hotplug_off; }
sc_hotplug_on() {       flags_world; touch "$FR/gpu/phxboot-hotplug"; expect_writes '^-w debug.phxhotplug=2$' 1; expect_writes 'debug.phxhotplug' 1
                        expect_stage '^debug.phxhotplug=2 killed=yes bound=yes$'; expect_log 'hotplug: .*debug.phxhotplug=2 rc 0, reads 2'
                        expect_order '^SUCCESS' 'hotplug: '; expect_order '^done ' 'hotplug: '; expect_order 'hotplug: ' 'b15: started'
                        expect_nolog 'gamma:'; expect_writes 'debug.phxgamma' 0; expect_killall; expect_no_reboot; go hotplug_on; }
sc_hotplug_bootarg() {  flags_world; touch "$FR/gpu/phxboot-hotplug"; SIM_BOOTARGS="keepsyms=1 -phxhotplugoff -v"; expect_log 'hotplug: boot-arg -phxhotplugoff'; expect_writes 'debug.phxhotplug' 0; expect_log 'b15: started'; expect_no_reboot; go hotplug_bootarg; }
sc_hotplug_bootarg_like(){ flags_world; touch "$FR/gpu/phxboot-hotplug"; SIM_BOOTARGS="-phxhotplugoffx keepsyms=1"; expect_nolog 'boot-arg'; expect_writes '^-w debug.phxhotplug=2$' 1; go hotplug_bootarg_like; }
sc_hotplug_fail() {     flags_world; touch "$FR/gpu/phxboot-hotplug" "$FR/gpu/phxboot-gamma"; cdpref_stub; SIM_SYSCTL_FAIL=debug.phxhotplug
                        expect_writes 'debug.phxhotplug' 1; expect_log 'hotplug: .*debug.phxhotplug=2 rc 1, reads 0 \(sysctl: .*Operation not permitted\)'
                        expect_writes '^-w debug.phxgamma=1$' 1; expect_order 'hotplug: ' 'b15: started'; expect_log 'b15: stub ran'; expect_rc 0; expect_no_reboot; go hotplug_fail; }
sc_hotplug_nohead1() {  flags_world; touch "$FR/gpu/phxboot-hotplug"; export M7_BIND_RC=1; expect_log 'm7: bind failed'; expect_log 'hotplug: head 1 not up'; expect_writes 'debug.phxhotplug' 0; expect_log 'b15: started'; expect_no_reboot; go hotplug_nohead1; unset M7_BIND_RC; }
sc_hotplug_nom7() {     world; b15_stub; touch "$FR/gpu/phxboot-b15" "$FR/gpu/phxboot-hotplug"; expect_log 'hotplug: head 1 not up'; expect_writes 'debug.phxhotplug' 0; expect_no_reboot; go hotplug_nom7; }
sc_hotplug_nodesk() {   world; DESK=0; m7_stub; touch "$FR/gpu/phxboot-m7" "$FR/gpu/phxboot-hotplug"; expect_log 'no desktop arm'; expect_log 'hotplug: not a desktop boot'; expect_writes 'debug.phxhotplug' 0; expect_no_killall; expect_no_reboot; go hotplug_nodesk; }
sc_gamma_off() {        flags_world; cdpref_stub; expect_log 'SUCCESS'; expect_nolog 'gamma:'; expect_writes 'debug.phxgamma' 0; expect_no_reboot; go gamma_off; }
sc_gamma_on() {         flags_world; cdpref_stub; touch "$FR/gpu/phxboot-gamma"; expect_writes '^-w debug.phxgamma=1$' 1; expect_writes 'debug.phxgamma' 1
                        expect_stage '^debug.phxgamma=1 killed=yes bound=yes$'; expect_log 'gamma: CoreDisplay useIOP_gamma_onAMD = false: head-1 tables reach the kext'
                        expect_log 'gamma: .*debug.phxgamma=1 rc 0 after 1 write\(s\), reads 1'; expect_order '^done ' 'gamma: CoreDisplay'; expect_order 'gamma: .*debug.phxgamma=1' 'b15: started'
                        expect_nolog 'hotplug:'; expect_writes 'debug.phxhotplug' 0; expect_killall; expect_no_reboot; go gamma_on; }
sc_gamma_pref_true() {  flags_world; cdpref_stub; SIM_CDPREF=true; touch "$FR/gpu/phxboot-gamma"; expect_log 'gamma: CoreDisplay useIOP_gamma_onAMD is not false \(uid 0 useIOP_gamma_onAMD = true\)'; expect_writes '^-w debug.phxgamma=1$' 1; expect_no_reboot; go gamma_pref_true; }
sc_gamma_pref_absent(){ flags_world; cdpref_stub; SIM_CDPREF=absent; touch "$FR/gpu/phxboot-gamma"; expect_log 'gamma: CoreDisplay useIOP_gamma_onAMD is not false \(.*\(absent\)\)'; expect_writes '^-w debug.phxgamma=1$' 1; expect_no_reboot; go gamma_pref_absent; }
sc_gamma_nocdpref() {   flags_world; touch "$FR/gpu/phxboot-gamma"; expect_log 'gamma: .*cdpref missing: CoreDisplay useIOP_gamma_onAMD not checked'; expect_writes '^-w debug.phxgamma=1$' 1; expect_no_reboot; go gamma_nocdpref; }
sc_gamma_busy() {       flags_world; cdpref_stub; touch "$FR/gpu/phxboot-gamma"; SIM_GAMMA_BUSY=1; expect_writes '^-w debug.phxgamma=1$' 2; expect_log 'gamma: .*debug.phxgamma=1 rc 0 after 2 write\(s\), reads 1'; expect_no_reboot; go gamma_busy; }
sc_gamma_busy_stuck() { flags_world; cdpref_stub; touch "$FR/gpu/phxboot-gamma"; SIM_GAMMA_BUSY=9; expect_writes '^-w debug.phxgamma=1$' 3; expect_log 'gamma: .*debug.phxgamma=1 rc 1 after 3 write\(s\), reads 0 \(sysctl: .*Resource busy\)'; expect_log 'b15: started'; expect_rc 0; expect_no_reboot; go gamma_busy_stuck; }
sc_gamma_fail() {       flags_world; cdpref_stub; touch "$FR/gpu/phxboot-gamma"; SIM_SYSCTL_FAIL=debug.phxgamma; expect_writes '^-w debug.phxgamma=1$' 1; expect_log 'gamma: .*debug.phxgamma=1 rc 1 after 1 write\(s\), reads 0 \(sysctl: .*Operation not permitted\)'; expect_order 'gamma: .*debug.phxgamma=1' 'b15: started'; expect_log 'b15: stub ran'; expect_rc 0; expect_no_reboot; go gamma_fail; }
sc_gamma_nohead1() {    flags_world; cdpref_stub; touch "$FR/gpu/phxboot-gamma"; export M7_BIND_RC=1; expect_log 'gamma: head 1 not up'; expect_writes 'debug.phxgamma' 0; expect_nolog 'gamma: CoreDisplay'; expect_no_reboot; go gamma_nohead1; unset M7_BIND_RC; }
sc_gamma_nodesk() {     world; DESK=0; cdpref_stub; touch "$FR/gpu/phxboot-gamma"; expect_log 'gamma: not a desktop boot'; expect_writes 'debug.phxgamma' 0; expect_no_killall; expect_no_reboot; go gamma_nodesk; }
sc_flags_both() {       flags_world; cdpref_stub; touch "$FR/gpu/phxboot-hotplug" "$FR/gpu/phxboot-gamma"; expect_writes 'debug.phxhotplug' 1; expect_writes 'debug.phxgamma' 1
                        expect_order 'hotplug: ' 'gamma: CoreDisplay'; expect_order 'gamma: .*debug.phxgamma=1' 'b15: started'; expect_stage '^debug.phxgamma=1 killed=yes bound=yes$'; expect_stage '^debug.phxhotplug=2 killed=yes bound=yes$'; expect_no_reboot; go flags_both; }
sc_flags_term() {       flags_world; touch "$FR/gpu/phxboot-hotplug" "$FR/gpu/phxboot-gamma"; SIM_TERM_IN_WATCH=1; expect_log 'clean shutdown \(TERM\)'; expect_writes 'debug.phxhotplug' 0; expect_writes 'debug.phxgamma' 0; expect_no_reboot; X_NOMARK=1; go flags_term; SIM_TERM_IN_WATCH=0; }
sc_term_in_watch() {    world; SIM_TERM_IN_WATCH=1; expect_rc 0; expect_log 'clean shutdown \(TERM\)'; expect_nolog 'SUCCESS'; expect_nolog 'FAIL'; expect_killall; expect_no_reboot; X_NOMARK=1; go term_in_watch; SIM_TERM_IN_WATCH=0; }
sc_squat_term_in_watch(){ world; DESK=0; SIM_SQUAT=1; AUTOF=1; SIM_TERM_IN_WATCH=1; expect_log 'clean shutdown \(TERM\)'; expect_log 'phxfb-squat re-armed'; expect_nvram 'set phxfb-squat=1'; expect_nolog 'SUCCESS'; expect_no_reboot; X_NOMARK=1; go squat_term_in_watch; SIM_TERM_IN_WATCH=0; }
# 11-02: a GUI restart at 18:05:16 landed early in a watch `sleep 5`; bash ran the TERM
# trap only when that sleep ended, after launchd's 5 s exit timeout: no 'clean shutdown' line, mark left, next boot GOP.
# term_late_* = TERM early in each in-window sleep (arm, restart, watch) with a mock launchd SIGKILL 1 s later (sleep goes on 3 s).
sc_term_late_watch() {  world; SIM_TERM_LATE=5; expect_rc 0; expect_log 'clean shutdown \(TERM\)'; expect_nolog 'SUCCESS'; expect_nolog 'FAIL'; expect_killall; expect_no_reboot; X_NOMARK=1; go term_late_watch; }
sc_squat_term_late_watch(){ world; DESK=0; SIM_SQUAT=1; AUTOF=1; SIM_TERM_LATE=5; expect_rc 0; expect_log 'clean shutdown \(TERM\)'; expect_log 'phxfb-squat re-armed'; expect_nvram 'set phxfb-squat=1'; expect_nolog 'SUCCESS'; expect_no_reboot; X_NOMARK=1; go squat_term_late_watch; }
sc_term_late_restart(){ world; SIM_TERM_LATE=6; expect_rc 0; expect_log 'clean shutdown \(TERM\)'; expect_nolog 'watching 120s'; expect_killall; expect_no_reboot; X_NOMARK=1; go term_late_restart; }
sc_term_late_arm() {    world; SIM_TERM_LATE=2; expect_rc 0; expect_log 'clean shutdown \(TERM\)'; expect_nolog 'AGDC up after'; expect_no_killall; expect_no_reboot; X_NOMARK=1; go term_late_arm; }
# m2_fail's own reboot TERM must not run the clean-shutdown trap (it re-armed phxfb-squat after a crash loop)
sc_squat_crash_shutdown_term(){ world; DESK=0; SIM_SQUAT=1; AUTOF=1; SIM_CRASH_PER_STEP=1; SIM_SHUTDOWN_TERM=1; expect_rc 143; expect_log 'WindowServer crashed/hung'; expect_nolog 'clean shutdown'; expect_nonvram 'set phxfb-squat'; expect_nvram '-d phxfb-squat'; expect_reboot; X_NOMARK=1; go squat_crash_shutdown_term; }
# 11-02 boot rate: ~/gpu/phxboot-aoc-rate = 144 / last -> b15_boot.sh aocboot after
# m7_bind and before the WindowServer restart, then debug.phxfb_resync=1 (id 2 = done; else b15_boot.sh aocback); every gate
# (rate, mode-list flag, b15 two-display flags, head 1 bound + phase-aligned, b15 script, PhxAccel oid, 2 head-0 modes) skips it
aocb15_stub(){ printf '#!/bin/sh
k=no; [ -e "$SIM_STATE/killed" ] && k=yes
case "${1:-}" in aocboot) echo "b15: stub aocboot killed=$k"; exit ${SIM_AOCBOOT_RC:-0};; aocboot1) echo "b15: stub aocboot1 killed=$k"; exit ${SIM_AOCBOOT1_RC:-0};; aocback) echo "b15: stub aocback killed=$k"; exit 0;; esac
echo "b15: stub ran"
' > "$FR/gpu/b15_boot.sh"; }
rate_world(){ flags_world; aocb15_stub; touch "$FR/gpu/phxboot-b15-2pipe" "$FR/gpu/phxboot-m7-aocmodes"; echo "${1:-144}" > "$FR/gpu/phxboot-aoc-rate"; }
sc_aocrate_off() {      flags_world; aocb15_stub; touch "$FR/gpu/phxboot-b15-2pipe" "$FR/gpu/phxboot-m7-aocmodes"; expect_log 'SUCCESS'; expect_nolog 'aocboot'; expect_writes 'debug.phxfb_resync' 0; expect_no_reboot; go aocrate_off; }
sc_aocrate_144() {      rate_world 144; expect_log 'aocboot: .* boot rate 144 \(.*phxboot-aoc-rate\): the AOC to 144 before the WindowServer restart'; expect_log 'b15: stub aocboot killed=no'
                        expect_log 'aocboot: .* head 0 resynced: id 2, VBL 144000 mHz'; expect_writes '^-w debug.phxfb_resync=1$' 1; expect_stage '^debug.phxfb_resync=1 killed=no bound=yes$'
                        expect_order 'm7: stub bind' 'aocboot: .*boot rate 144'; expect_order 'head 0 resynced' 'restarting WindowServer once'; expect_order 'armed at ' 'aocboot: '
                        expect_nolog 'aocback'; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go aocrate_144; }
sc_aocrate_144_space(){ rate_world " 144 "; expect_log 'head 0 resynced: id 2'; expect_no_reboot; go aocrate_144_space; }
sc_aocrate_60() {       rate_world 60; expect_log "aocboot: boot rate '60' \(.*phxboot-aoc-rate\): the AOC stays at 60"; expect_nolog 'stub aocboot'; expect_writes 'debug.phxfb_resync' 0; expect_log 'SUCCESS'; expect_no_reboot; go aocrate_60; }
sc_aocrate_last_60() {  rate_world last; echo "aoc=60 acer=165 at 2026-11-02" > "$FR/gpu/phxboot-rate-last"; expect_log "aocboot: boot rate '60' \(remembered in .*phxboot-rate-last\)"; expect_nolog 'stub aocboot'; expect_writes 'debug.phxfb_resync' 0; expect_no_reboot; go aocrate_last_60; }
sc_aocrate_last_144() { rate_world last; echo "aoc=144 acer=165 at 2026-11-02" > "$FR/gpu/phxboot-rate-last"; expect_log 'aocboot: .* boot rate 144 \(remembered in '; expect_log 'head 0 resynced: id 2'; expect_no_reboot; go aocrate_last_144; }
sc_aocrate_last_none(){ rate_world last; expect_log 'aocboot: .* boot rate 144 \(no remembered rate in '; expect_log 'b15: stub aocboot'; expect_writes '^-w debug.phxfb_resync=1$' 1; expect_no_reboot; go aocrate_last_none; }
sc_aocrate_last_bad() { rate_world last; echo "aoc=165 acer=60" > "$FR/gpu/phxboot-rate-last"; expect_log 'boot rate 144 \(no remembered rate in '; expect_no_reboot; go aocrate_last_bad; }
sc_aocrate_nolist() {   rate_world 144; rm "$FR/gpu/phxboot-m7-aocmodes"; expect_log 'aocboot: no head-0 mode list flag'; expect_nolog 'stub aocboot'; expect_writes 'debug.phxfb_resync' 0; expect_log 'SUCCESS'; expect_no_reboot; go aocrate_nolist; }
sc_aocrate_aoc144flag(){ rate_world 144; rm "$FR/gpu/phxboot-m7-aocmodes"; touch "$FR/gpu/phxboot-m7-aoc144"; expect_log 'b15: stub aocboot'; expect_log 'head 0 resynced'; expect_no_reboot; go aocrate_aoc144flag; }
sc_aocrate_nob15flags(){ rate_world 144; rm "$FR/gpu/phxboot-b15-2pipe"; expect_log 'aocboot: b15 two-display flags missing'; expect_nolog 'stub aocboot'; expect_no_reboot; go aocrate_nob15flags; }
sc_aocrate_nohead1() {  rate_world 144; export M7_BIND_RC=1; expect_log 'm7: bind failed'; expect_log 'aocboot: head 1 not up and phase-aligned'; expect_nolog 'stub aocboot'; expect_writes 'debug.phxfb_resync' 0; expect_log 'SUCCESS'; expect_no_reboot; go aocrate_nohead1; unset M7_BIND_RC; }
sc_aocrate_unaligned(){ rate_world 144; export M7_LIGHT_RC=3; expect_log 'm7: stub bind'; expect_log 'aocboot: head 1 not up and phase-aligned'; expect_nolog 'stub aocboot'; expect_no_reboot; go aocrate_unaligned; unset M7_LIGHT_RC; }
sc_aocrate_nom7() {     world; aocb15_stub; touch "$FR/gpu/phxboot-b15" "$FR/gpu/phxboot-b15-2pipe" "$FR/gpu/phxboot-m7-aocmodes"; echo 144 > "$FR/gpu/phxboot-aoc-rate"; expect_log 'aocboot: one display: no ~/gpu/phxboot-m7'; expect_nolog 'stub aocboot'; expect_no_reboot; go aocrate_nom7; }
sc_aocrate_old_accel(){ rate_world 144; SIM_NO_RESYNC=1; expect_log 'aocboot: PhxAccel without debug.phxfb_resync'; expect_nolog 'stub aocboot'; expect_log 'SUCCESS'; expect_no_reboot; go aocrate_old_accel; }
sc_aocrate_nmodes() {   rate_world 144; SIM_NMODES=0; expect_log 'aocboot: head 0 has no 60/144 mode list \(debug.phxfb_nmodes 0\)'; expect_nolog 'stub aocboot'; expect_no_reboot; go aocrate_nmodes; }
sc_aocrate_b15_gone() { rate_world 144; rm "$FR/gpu/b15_boot.sh"; expect_log 'aocboot: .*b15_boot.sh missing: the AOC stays at 60'; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go aocrate_b15_gone; }
sc_aocrate_set_fail() { rate_world 144; SIM_AOCBOOT_RC=1; expect_log 'b15: stub aocboot'; expect_log 'aocboot: b15_boot.sh aocboot rc 1: the AOC stays at 60'; expect_writes 'debug.phxfb_resync' 0; expect_nolog 'aocback'; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go aocrate_set_fail; }
sc_aocrate_resync_bad(){ rate_world 144; SIM_RESYNC_ID=-3; expect_writes '^-w debug.phxfb_resync=1$' 1; expect_log "aocboot: head 0 resync answered '-3', not id 2: the AOC back to 60"; expect_log 'b15: stub aocback killed=no'; expect_order 'stub aocback' 'restarting WindowServer once'; expect_log 'SUCCESS'; expect_no_reboot; go aocrate_resync_bad; }
sc_aocrate_nodesk() {   rate_world 144; DESK=0; expect_log 'no desktop arm'; expect_nolog 'aocboot'; expect_writes 'debug.phxfb_resync' 0; expect_no_killall; expect_no_reboot; go aocrate_nodesk; }
sc_aocrate_user() {     rate_world 144; SIM_USERS="user console"; expect_log 'a user is logged in before arming'; expect_nolog 'stub aocboot'; expect_no_killall; expect_reboot; go aocrate_user; }
sc_nodesk_no_boot_arm(){ world; DESK=0; expect_log 'no desktop arm'; expect_nonvram 'set phxfb-boot'; expect_no_killall; expect_no_reboot; go nodesk_no_boot_arm; }

sc_nodesk_rearm() {     world; DESK=0; AUTOF=1; expect_log 'no desktop arm'; expect_log 're-armed for the next boot \(GOP boot'; expect_nvram 'set phxfb-squat=1'; expect_no_killall; expect_no_reboot; go nodesk_rearm; }
# 2026-11-25: the record decides, not ~/gpu/phxboot-failed: after 3 failures in a row a GOP boot re-arms only as the 3rd
# clean fallback boot (here the 2nd); after fewer, the first clean GOP boot re-arms (nodesk_failed_rearm)
sc_nodesk_failed() {    world; DESK=0; AUTOF=1; rec_set fails=3 clean=0 last=gop; expect_log 'NOT re-armed: the last accelerated attempt failed .*fails=3, this is clean fallback boot 2 of 3; it re-arms by itself after 1 more startup'
                        expect_nonvram 'set phxfb-squat'; expect_rec clean=1; expect_no_killall; expect_no_reboot; go nodesk_failed; }
sc_nodesk_failed_rearm(){ world; DESK=0; AUTOF=1; touch "$FR/gpu/phxboot-failed"; expect_log 'record: .*phxboot-failed of an earlier daemon taken over'
                        expect_log 're-armed for the next boot \(GOP boot, phxboot-auto present, clean fallback boot 1 of 1 after 1 failed attempt'; expect_nvram 'set phxfb-squat=1'
                        expect_nofile "$FR/gpu/phxboot-failed"; expect_rec fails=1; expect_rec last=gop; expect_no_reboot; go nodesk_failed_rearm; }
sc_nodesk_noauto() {    world; DESK=0; expect_log 'no desktop arm'; expect_nonvram 'set phxfb-squat'; expect_nolog 're-armed'; go nodesk_noauto; }
sc_fail_marks() {       world; DESK=0; SIM_SQUAT=1; AUTOF=1; SIM_METAL=0; expect_log 'FAIL'; expect_reboot; expect_nofile "$FR/gpu/phxboot-failed"; expect_rec fails=1; expect_rec clean=0; go fail_marks; }
sc_success_clears() {   world; DESK=0; SIM_SQUAT=1; AUTOF=1; touch "$FR/gpu/phxboot-failed"; expect_log 'SUCCESS'; expect_log 're-armed .*phxboot-auto present'; expect_nofile "$FR/gpu/phxboot-failed"; expect_rec fails=0; go success_clears; }
sc_squat_late() {       world; DESK=0; SIM_SQUAT=1; SIM_SQUAT_LATE=5; SIM_FB=0; AUTOF=1; expect_log 'squat boot .*: 1 \(decided by PhxFBSquatter after 5s\)'; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go squat_late; }
sc_fb_first() {         world; DESK=0; AUTOF=1; expect_log 'squat boot .*: 0 \(decided by IOFramebuffer after 0s\)'; expect_log 'no desktop arm'; go fb_first; }
sc_squat_neither() {    world; DESK=0; SIM_FB=0; expect_log 'squat boot .*: 0 \(decided by neither in 60s\)'; go squat_neither; }
# 11-03 first-WindowServer fix: the first WindowServer and the stored display sets
# (prefs_world = the box prefs of 11-03 + the first-WindowServer model in the sysctl shim, which reads the prefs as they were
# BEFORE the daemon ran and needs id 2 OFFERED by head 0), the kernel offer gate (SIM_OFFER_GATE=1), and the silent-crash
# watches. Two-boot scenarios run boot1 (log $W/boot1.log), then go = boot 2.
expect_kill_prefs_original(){ X_KILLPREFS=1; }   # the prefs the restarted WindowServer reads (at the killall) = the original
# v4 leftover: set 2 neutral on disk, its values in the stash (what daemon 04c751b1 left after a SUCCESS)
v4_leftover(){ local k v; mkdir -p "$FR/gpu/phxboot-wsprefs.stash.d"; : >"$FR/gpu/phxboot-wsprefs.stash.d/2026439080"
  for k in Mode:IODisplayModeID Mode:RefreshRate Mode:IOFlags UnmirroredMode:IODisplayModeID UnmirroredMode:RefreshRate UnmirroredMode:IOFlags IOFlags RefreshRate16.16; do
    v=$("$MOCK_PB" -c "Print :DisplayAnyUserSets:2:0:$k" "$FIXT"); printf '%s\t%s\n' "$k" "$v" >>"$FR/gpu/phxboot-wsprefs.stash.d/2026439080"
    case "$k" in *IODisplayModeID) v=1;; *RefreshRate) v=60;; *IOFlags) v=1048583;; RefreshRate16.16) v=3932160;; esac
    "$MOCK_PB" -c "Set :DisplayAnyUserSets:2:0:$k $v" "$ST/wsprefs.plist"; done; }
# a logged-in session's display change: SkyLight copies the user's DisplaySets (AOC alone at 144) into DisplayAnyUserSets
session_saves(){ cp "$FIXT" "$ST/wsprefs.plist"; }
sc_ws_crash_oldkext() { prefs_world; expect_log 'head-0 offer gate: absent after'; expect_log 'first WindowServer died before the restart \(pid 12345 -> 1021;'
                        expect_log 'SUCCESS'; expect_nolog 'wsprefs:'; expect_prefs_original; expect_killall; expect_no_reboot; go ws_crash_oldkext; }
# no resync this boot (prefs_world has no aocboot): the daemon itself must open the gate before the restart
sc_gate_fix() {         prefs_world; SIM_OFFER_GATE=1; expect_nolog 'offer gate: absent'; expect_log 'first WindowServer survived to the restart \(pid 12345\)'
                        expect_log 'head-0 offer gate open \(was closed; debug.phxfb0_offer=1'; expect_order 'offer gate open' 'restarting WindowServer once'
                        expect_stage '^debug.phxfb0_offer=1 killed=no$'; expect_prefs_original; expect_kill_prefs_original; expect_killall; expect_no_reboot; go gate_fix; }
# the v4 shutdown race: the session between the boots rewrote the AnyUser sets (id 2 again); the gate does not care
sc_gate_session_race(){ prefs_world; SIM_OFFER_GATE=1; boot1; session_saves; expect_log 'first WindowServer survived to the restart'; expect_log 'head-0 offer gate open'
                        expect_log 'SUCCESS'; expect_prefs_original; go gate_session_race; }
sc_gate_cold_twice(){   prefs_world; SIM_OFFER_GATE=1; boot1; expect_log 'first WindowServer survived'; expect_nolog 'died before the restart'; go gate_cold_twice; }
sc_gate_bootarg() {     prefs_world; SIM_OFFER_GATE=1; SIM_BOOTARGS="keepsyms=1 -phxfb0open"; expect_log 'first WindowServer died'
                        expect_log 'head-0 offer gate open \(verified; already opened before the restart: 0 opening'; expect_log 'SUCCESS'; go gate_bootarg; }
sc_gate_no_list() {     prefs_world; SIM_OFFER_GATE=1; rm -f "$FR/gpu/phxboot-m7-aocmodes"; expect_log 'head-0 offer gate open \(verified'; expect_log 'first WindowServer survived'; go gate_no_list; }
sc_gate_open_fails() {  prefs_world; SIM_OFFER_GATE=1; SIM_SYSCTL_FAIL=debug.phxfb0_offer; expect_log 'first WindowServer survived'
                        expect_log 'head-0 offer gate: debug.phxfb0_offer=1 FAILED'; expect_log 'SUCCESS'; go gate_open_fails; }
sc_gate_resync_opens(){ rate_world 144; cp "$FIXT" "$ST/wsprefs.plist"; SIM_WSMODEL=1; SIM_OFFER_GATE=1; expect_log 'head 0 resynced: id 2'; expect_log 'first WindowServer survived'
                        expect_log 'head-0 offer gate open \(verified; already opened before the restart: 1 opening'; expect_stage '^debug.phxfb0_offer=1 killed=no$'
                        expect_nolog 'debug.phxfb0_offer=1 FAILED'; go gate_resync_opens; }
# a late oid: it appears seconds after PhxAMDFB is up; the daemon waits for it before the restart and opens the gate
sc_gate_late_oid() {    prefs_world; SIM_OFFER_GATE=1; SIM_OFFER_LATE=4; expect_nolog 'offer gate: absent'; expect_log 'first WindowServer survived'
                        expect_log 'head-0 offer gate open \(was closed; debug.phxfb0_offer=1'; expect_stage '^debug.phxfb0_offer=1 killed=no$'; expect_log 'SUCCESS'; go gate_late_oid; }
# no resync and a late oid on a rate boot whose aocboot was refused (the AOC stays at 60): the daemon opens the gate itself
sc_gate_noresync_rate(){ rate_world 144; cp "$FIXT" "$ST/wsprefs.plist"; SIM_WSMODEL=1; SIM_OFFER_GATE=1; SIM_OFFER_LATE=2; SIM_AOCBOOT_RC=1
                        expect_log 'aocboot: b15_boot.sh aocboot rc 1'; expect_log 'first WindowServer survived'; expect_log 'head-0 offer gate open \(was closed'
                        expect_stage '^debug.phxfb0_offer=1 killed=no$'; go gate_noresync_rate; }
# the v4 shutdown race reproduced without the gate: the at-rest prefs trick of v4 is undone by any session save
sc_v4_race_repro(){     prefs_world; touch "$FR/gpu/phxboot-wsprefs"; boot1; session_saves; expect_log 'head-0 offer gate: absent'; expect_log 'first WindowServer died before the restart'; go v4_race_repro; }
sc_v4_leftover() {      prefs_world; SIM_OFFER_GATE=1; v4_leftover; touch "$FR/gpu/phxboot-wsprefs"; expect_log 'restored 1 set\(s\) \(v4 leftover'; expect_log 'is no longer used'
                        expect_nolog 'neutralized'; expect_kill_prefs_original; expect_prefs_original; expect_nofile "$FR/gpu/phxboot-wsprefs.stash.d"; expect_log 'SUCCESS'; go v4_leftover; }
sc_v4_leftover_import_fail(){ prefs_world; SIM_OFFER_GATE=1; v4_leftover; SIM_DEFAULTS_FAIL=import; expect_log 'restore \(v4 leftover, before the WindowServer restart\): import failed: values kept'
                        expect_file "$FR/gpu/phxboot-wsprefs.stash.d/2026439080"; expect_log 'SUCCESS'; go v4_leftover_import_fail; }
sc_v4_leftover_moved(){ prefs_world; SIM_OFFER_GATE=1; v4_leftover; SIM_WS_REWRITE=1; expect_log 'no live one-display set of display 2026439080 at id 1: left as is, values kept'
                        expect_file "$FR/gpu/phxboot-wsprefs.stash.d/2026439080"; expect_log 'SUCCESS'; go v4_leftover_moved; }
# 11-03 rotation rot15: disp_ovr runs
# ~/gpu/dispovr.sh once, after offer_open and before the one WindowServer restart, never blocking it. dispovr_real runs the
# real tool (tools/phxctl/dispovr.sh) against a fake ioreg (two displays) and a fake overrides dir holding a foreign
# override for one of them.
dispovr_stub(){ printf '#!/bin/sh\n%s\n' "$1" > "$FR/gpu/dispovr.sh"; chmod +x "$FR/gpu/dispovr.sh"; touch "$FR/gpu/phxboot-dispovr"; }
dispovr_real_world(){ prefs_world; SIM_OFFER_GATE=1; touch "$FR/gpu/phxboot-dispovr"; mkdir -p "$W/ovr/DisplayVendorID-472"
  printf '#!/bin/sh\nprintf %s\n' "'    \"DisplayVendorID\" = 1507\n    \"DisplayProductID\" = 9218\n    \"DisplayVendorID\" = 1138\n    \"DisplayProductID\" = 1869\n'" > "$W/fakeioreg"; chmod +x "$W/fakeioreg"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>DisplayProductID</key><integer>1869</integer><key>user</key><string>mine</string></dict></plist>\n' > "$W/ovr/DisplayVendorID-472/DisplayProductID-74d"
  md5 -q "$W/ovr/DisplayVendorID-472/DisplayProductID-74d" > "$W/foreign.md5"
  printf '#!/bin/sh\nPHX_OVR_DIR=%s PHX_OVR_IOREG=%s exec sh %s "$@"\n' "$W/ovr" "$W/fakeioreg" "$HERE/../../tools/phxctl/dispovr.sh" > "$FR/gpu/dispovr.sh"; chmod +x "$FR/gpu/dispovr.sh"; }
sc_dispovr_off() {      prefs_world; SIM_OFFER_GATE=1; dispovr_stub 'echo "dispovr: ran" > "$0.ran"'; rm "$FR/gpu/phxboot-dispovr"; expect_nolog 'dispovr:'; expect_nofile "$FR/gpu/dispovr.sh.ran"; expect_log 'SUCCESS'; go dispovr_off; }
sc_dispovr_on() {       prefs_world; SIM_OFFER_GATE=1; dispovr_stub 'echo "dispovr: 2 display(s), 2 written, 0 foreign override(s) left alone"'
                        expect_log '^  dispovr: 2 display\(s\), 2 written'; expect_order 'offer gate open' 'dispovr: 2 display'; expect_order 'dispovr: 2 display' 'restarting WindowServer once'
                        expect_log 'SUCCESS'; expect_log '^done'; expect_killall; go dispovr_on; }
sc_dispovr_missing() {  prefs_world; SIM_OFFER_GATE=1; touch "$FR/gpu/phxboot-dispovr"; expect_log 'dispovr: .*dispovr.sh missing \(flag set\)'; expect_log 'SUCCESS'; expect_killall; go dispovr_missing; }
sc_dispovr_fail() {     prefs_world; SIM_OFFER_GATE=1; dispovr_stub 'echo "dispovr: writing x FAILED"; exit 2'; expect_log '^  dispovr: writing x FAILED'
                        expect_log 'dispovr: .* exit 2: some overrides not written, the restart goes on'; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go dispovr_fail; }
sc_dispovr_hang() {     prefs_world; SIM_OFFER_GATE=1; DISPOVR_WAIT=3; dispovr_stub 'echo "dispovr: stuck"; /bin/sleep 30'; expect_log 'still running after 3s: killed, the restart goes on'
                        expect_order 'killed, the restart goes on' 'restarting WindowServer once'; expect_log 'SUCCESS'; expect_killall; go dispovr_hang; }
sc_dispovr_real() {     dispovr_real_world; expect_log '^  dispovr: .*DisplayVendorID-5e3/DisplayProductID-2402 written'; expect_log '^  dispovr: .*DisplayVendorID-472/DisplayProductID-74d exists and is not ours: left alone'
                        expect_log '^  dispovr: 2 display\(s\), 1 written, 1 foreign'; expect_cmd '[ "$(md5 -q "$W/ovr/DisplayVendorID-472/DisplayProductID-74d")" = "$(cat "$W/foreign.md5")" ]'
                        expect_cmd '[ "$(plutil -extract default-resolution raw -o - "$W/ovr/DisplayVendorID-5e3/DisplayProductID-2402")" = AAAAAAAAAAAA/wAA ]'
                        expect_cmd 'plutil -lint "$W/ovr/DisplayVendorID-5e3/DisplayProductID-2402"'; expect_cmd '! ls "$W/ovr"/*/*.new.* 2>/dev/null | grep -q .'; expect_log 'SUCCESS'; go dispovr_real; }
sc_dispovr_real_twice(){ dispovr_real_world; boot1; expect_log '^  dispovr: .*DisplayProductID-2402 current'; expect_log '^  dispovr: 2 display\(s\), 0 written, 1 foreign'
                        expect_cmd '[ "$(md5 -q "$W/ovr/DisplayVendorID-472/DisplayProductID-74d")" = "$(cat "$W/foreign.md5")" ]'; go dispovr_real_twice; }
# 11-03 single-monitor boots, daily flags (m7, aoc rate 144, b15):
# (a) only the AOC: m7 light refused (survey requirement HPD0 sense = the Acer's HDMI HPD) -> one monitor; no aocboot; the
#     stored AOC-alone 144 set cannot reach the first WindowServer (gate closed); the daemon opens the gate; SUCCESS
# (b) only the Acer, lit by the GOP on pipe 0: head 0 builds no list from its EDID (single mode), the gate never closes;
#     m7 refused (survey/C3: OTG0 is not at a known AOC mode); SUCCESS
# 11-03 p0solo: the AOC alone now goes to 144 before the restart (b15_boot.sh aocboot1; resync opens the offer gate)
sc_one_aoc() {          rate_world 144; AUTOF=1; cp "$FIXT" "$ST/wsprefs.plist"; SIM_WSMODEL=1; SIM_OFFER_GATE=1; export M7_LIGHT_RC=1
                        expect_log 'm7: stub light'; expect_nolog 'm7: stub bind'; expect_log 'aocboot: .* boot rate 144 .*: the AOC \(alone\) to 144 before the WindowServer restart'
                        expect_log 'b15: stub aocboot1 killed=no'; expect_nolog 'stub aocboot killed'; expect_stage '^debug.phxfb_resync=1 killed=no'; expect_log 'head 0 resynced: id 2'
                        expect_log 'first WindowServer survived'; expect_log 'head-0 offer gate open \(verified; already opened before the restart: 1 opening'
                        expect_order 'stub aocboot1' 'restarting WindowServer once'; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; expect_nvram 'set phxfb-squat=1'; go one_aoc; unset M7_LIGHT_RC; }
sc_one_aoc_m7off() {    rate_world 144; rm "$FR/gpu/phxboot-m7"; expect_nolog 'm7: stub'; expect_log 'aocboot: one display: no ~/gpu/phxboot-m7'; expect_nolog 'stub aocboot1'; expect_writes 'debug.phxfb_resync' 0; expect_log 'SUCCESS'; go one_aoc_m7off; }
sc_one_aoc_no_solo() {  rate_world 144; SIM_NO_SOLO=1; export M7_LIGHT_RC=1; expect_log 'aocboot: one display: PhxBringup without debug.phxpipe0_solo'; expect_nolog 'stub aocboot1'
                        expect_writes 'debug.phxfb_resync' 0; expect_log 'SUCCESS'; go one_aoc_no_solo; unset M7_LIGHT_RC; }
sc_one_aoc_refused() {  rate_world 144; SIM_AOCBOOT1_RC=1; export M7_LIGHT_RC=1; expect_log 'aocboot: b15_boot.sh aocboot1 rc 1: the AOC stays at 60'; expect_writes 'debug.phxfb_resync' 0
                        expect_log 'SUCCESS'; go one_aoc_refused; unset M7_LIGHT_RC; }
sc_one_aoc_noflag() {   rate_world 144; rm "$FR/gpu/phxboot-b15"; export M7_LIGHT_RC=1; expect_log 'aocboot: one display: no ~/gpu/phxboot-b15: the AOC stays at 60'; expect_nolog 'stub aocboot1'; go one_aoc_noflag; unset M7_LIGHT_RC; }
sc_one_aoc_resync_bad(){ rate_world 144; SIM_RESYNC_ID=-3; export M7_LIGHT_RC=1; expect_log 'stub aocboot1'; expect_log "head 0 resync answered '-3', not id 2: the AOC back to 60"; expect_log 'stub aocback'; go one_aoc_resync_bad; unset M7_LIGHT_RC; }
sc_two_unaligned_no_solo(){ rate_world 144; export M7_LIGHT_RC=3; expect_log 'aocboot: head 1 not up and phase-aligned'; expect_nolog 'stub aocboot1'; go two_unaligned_no_solo; unset M7_LIGHT_RC; }
sc_one_acer() {         rate_world 144; AUTOF=1; expect_nvram "set phxfb-squat=1"; cp "$FIXT" "$ST/wsprefs.plist"; SIM_WSMODEL=1; SIM_OFFER_GATE=1; SIM_HEAD0_SINGLE=1; SIM_NMODES=0; export M7_LIGHT_RC=1
                        expect_log 'aocboot: head 0 has no 60/144 mode list \(debug.phxfb_nmodes 0\): the AOC stays at 60'; expect_nolog 'stub aocboot1'; expect_log 'first WindowServer survived'; expect_log 'head-0 offer gate open \(verified; already opened before the restart: 0 opening'
                        expect_log 'SUCCESS'; expect_killall; expect_no_reboot; expect_prefs_original; go one_acer; unset M7_LIGHT_RC; }
sc_silent_crash_loop(){ world; SIM_WS_SILENT=5; expect_log 'watch: WindowServer pid 23456 -> 23457'; expect_log 'WindowServer crashed/hung 3 times'; expect_nolog 'SUCCESS'; expect_killall; expect_reboot; go silent_crash_loop; }
sc_silent_crash_once(){ world; SIM_WS_SILENT=1; expect_log 'watch: WindowServer pid 23456 -> 23457'; expect_log 'SUCCESS'; expect_no_reboot; go silent_crash_once; }
sc_late_silent() {      world; NOWATCH=0; WATCHMAX=4; SIM_WS_LATE_SILENT=2; expect_log 'WindowServer pid 23456 crashed \(kernel corpse'; expect_log 'WindowServer hung 2x on GPU: reverting to GOP'; expect_reboot; go late_silent; }
sc_late_logout() {      world; NOWATCH=0; WATCHMAX=4; SIM_WS_LATE_LOGOUT=2; expect_log 'WindowServer pid 23456 -> 23457 with no kernel corpse'; expect_nolog 'reverting to GOP'; expect_no_reboot; go late_logout; }
# 11-03 S3: ~/gpu/phxboot-dpwatch (level 1 / 2) after `done`, and watch_hangs'
# event lines. dpw_stat <read #> <DP-B STUCK> <recovered> <ended off> <fix ok> <fail> <refused> [<event kind>]: the stat text the
# kext prints (PhxDpWatch.h format), served from that read of debug.phxdpwatch_stat on
dpw_stat(){ { echo "dpwatch v1 level=2 samples=$((100 * $1)) span_ms=1 events=1 out0=0x0 out0_quiet_ms=0 (reads only, nothing acked)"
  echo "DP-B: hpd=1 on=1 status=1 stuck=0 plugs=1 unplugs=1 rx_int=0 starts=1 status_up=0 STUCK=$2 recovered=$3 stuck_ended_off=$4 lat_ms last=0 max=0 | be_en=0x101 link=0x110 vid=0x00010201 fe=0x01000000 fifo=0x0000001d be_cntl=0x20000200 hpd_st=0xff0ff012"
  echo "DP-B fix (level 2): tried_this_plug=1 runs=$(($5 + $6)) ok=$5 fail=$6 refused=$7 busy_skips=0 last_wait_us=3000"
  echo "DP-A: hpd=0 on=0 status=0 stuck=0 plugs=0 unplugs=0 rx_int=0 starts=0 status_up=0 STUCK=0 recovered=0 stuck_ended_off=0 lat_ms last=0 max=0 | be_en=0x100 link=0x0 vid=0x00100000 fe=0x00000000 fifo=0x0000001c be_cntl=0x00000000 hpd_st=0x000ff000"
  echo "DP-E: hpd=0 on=0 status=0 stuck=0 plugs=0 unplugs=0 rx_int=0 starts=0 status_up=0 STUCK=0 recovered=0 stuck_ended_off=0 lat_ms last=0 max=0 | be_en=0x100 link=0x0 vid=0x00100000 fe=0x00000000 fifo=0x0000001c be_cntl=0x00000000 hpd_st=0x000ff000"
  [ -n "${8:-}" ] && echo "ev t=-1200ms DP-B ${8} dt_ms=500 vid=0x00000201 be_en=0x101 link=0x110 fe=0x01000000 fifo=0x2000001d be_cntl=0x20000200 out0=0xbea0 out0_quiet_ms=900"
  } >"$ST/dpwstat.$1"; }
# 11-04 head-0 hot-plug flag: ~/gpu/phxboot-hotplug0 (1 / 2, empty = 1) -> debug.phxhotplug0 once after `done`, after the
# Acer's debug.phxhotplug and before b15; no flag / not a desktop boot / -phxhotplugoff / bad flag / no oid = no write
sc_hp0_off() {          flags_world; expect_log 'SUCCESS'; expect_nolog 'hotplug0:'; expect_writes 'debug.phxhotplug0' 0; expect_no_reboot; go hp0_off; }
sc_hp0_on() {           flags_world; touch "$FR/gpu/phxboot-hotplug" "$FR/gpu/phxboot-hotplug0"; expect_writes '^-w debug.phxhotplug0=1$' 1; expect_writes 'debug.phxhotplug0' 1
                        expect_stage '^debug.phxhotplug0=1 killed=yes bound=yes$'; expect_log 'hotplug0: .*debug.phxhotplug0=1 rc 0, reads 1'
                        expect_order '^done ' 'hotplug0: '; expect_order 'hotplug: ' 'hotplug0: '; expect_order 'hotplug0: ' 'b15: started'; expect_no_reboot; go hp0_on; }
sc_hp0_l2() {           flags_world; echo 2 >"$FR/gpu/phxboot-hotplug0"; expect_writes '^-w debug.phxhotplug0=2$' 1; expect_writes 'debug.phxhotplug0' 1; expect_writes '^-w debug.phxhotplug=' 0
                        expect_log 'hotplug0: .*debug.phxhotplug0=2 rc 0, reads 2'; expect_order 'hotplug0: ' 'b15: started'; expect_no_reboot; go hp0_l2; }
sc_hp0_badflag() {      flags_world; echo 3 >"$FR/gpu/phxboot-hotplug0"; expect_log "hotplug0: ~/gpu/phxboot-hotplug0 holds '3', not 1 or 2"; expect_writes 'debug.phxhotplug0' 0; expect_no_reboot; go hp0_badflag; }
sc_hp0_nooid() {        flags_world; echo 2 >"$FR/gpu/phxboot-hotplug0"; SIM_HP0_NOOID=1; expect_log 'hotplug0: PhxAccel without debug.phxhotplug0 \(hp1\+\): nothing armed'; expect_writes 'debug.phxhotplug0' 0; expect_log 'b15: started'; expect_no_reboot; go hp0_nooid; }
sc_hp0_bootarg() {      flags_world; touch "$FR/gpu/phxboot-hotplug"; echo 2 >"$FR/gpu/phxboot-hotplug0"; SIM_BOOTARGS="keepsyms=1 -phxhotplugoff"; expect_log 'hotplug0: boot-arg -phxhotplugoff'; expect_writes 'debug.phxhotplug0' 0; expect_writes 'debug.phxhotplug=' 0; expect_no_reboot; go hp0_bootarg; }
sc_hp0_nodesk() {       world; DESK=0; echo 2 >"$FR/gpu/phxboot-hotplug0"; expect_log 'hotplug0: not a desktop boot'; expect_writes 'debug.phxhotplug0' 0; expect_no_reboot; go hp0_nodesk; }
sc_hp0_fail() {         flags_world; echo 2 >"$FR/gpu/phxboot-hotplug0"; SIM_SYSCTL_FAIL=debug.phxhotplug0; expect_writes 'debug.phxhotplug0' 1
                        expect_log 'hotplug0: .*debug.phxhotplug0=2 rc 1, reads 0 \(sysctl: .*Operation not permitted\)'; expect_log 'b15: stub ran'; expect_rc 0; expect_no_reboot; go hp0_fail; }
sc_dpwatch_off() {      world; expect_log 'SUCCESS'; expect_nolog 'dpwatch:'; expect_writes 'debug.phxdpwatch' 0; expect_no_reboot; go dpwatch_off; }
sc_dpwatch_on() {       flags_world; echo 1 >"$FR/gpu/phxboot-dpwatch"; expect_writes '^-w debug.phxdpwatch=1$' 1; expect_writes 'debug.phxdpwatch' 1
                        expect_stage '^debug.phxdpwatch=1 killed=yes$'; expect_log 'dpwatch: .*debug.phxdpwatch=1 rc 0, reads 1'
                        expect_order '^SUCCESS' 'dpwatch: '; expect_order '^done ' 'dpwatch: '; expect_order 'dpwatch: ' 'b15: started'; expect_killall; expect_no_reboot; go dpwatch_on; }
sc_dpwatch_empty() {    flags_world; : >"$FR/gpu/phxboot-dpwatch"; expect_writes '^-w debug.phxdpwatch=1$' 1; expect_log 'dpwatch: .*debug.phxdpwatch=1 rc 0, reads 1'; expect_no_reboot; go dpwatch_empty; }
sc_dpwatch_l2() {       flags_world; echo 2 >"$FR/gpu/phxboot-dpwatch"; expect_writes '^-w debug.phxdpwatch=2$' 1; expect_writes 'debug.phxdpwatch' 1; expect_log 'dpwatch: .*debug.phxdpwatch=2 rc 0, reads 2'; expect_no_reboot; go dpwatch_l2; }
sc_dpwatch_l2_old() {   flags_world; echo 2 >"$FR/gpu/phxboot-dpwatch"; SIM_DPW_L2_EINVAL=1; expect_writes '^-w debug.phxdpwatch=2$' 1; expect_writes '^-w debug.phxdpwatch=1$' 1
                        expect_log 'dpwatch: level 2 refused \(sysctl: debug.phxdpwatch=2: Invalid argument\): a kext before b121\? level 1'; expect_log 'dpwatch: .*debug.phxdpwatch=1 rc 0, reads 1'; expect_log 'b15: started'; expect_no_reboot; go dpwatch_l2_old; }
sc_dpwatch_nooid() {    flags_world; echo 2 >"$FR/gpu/phxboot-dpwatch"; SIM_DPW_NOOID=1; expect_log 'dpwatch: PhxBringup without debug.phxdpwatch \(kext b120\+\): nothing armed'; expect_writes 'debug.phxdpwatch' 0; expect_log 'b15: started'; expect_no_reboot; go dpwatch_nooid; }
sc_dpwatch_badflag() {  flags_world; echo 7 >"$FR/gpu/phxboot-dpwatch"; expect_log "dpwatch: ~/gpu/phxboot-dpwatch holds '7', not 1 or 2"; expect_writes 'debug.phxdpwatch' 0; expect_no_reboot; go dpwatch_badflag; }
sc_dpwatch_bootarg() {  flags_world; echo 2 >"$FR/gpu/phxboot-dpwatch"; SIM_BOOTARGS="keepsyms=1 -phxdpwatchoff"; expect_log 'dpwatch: boot-arg -phxdpwatchoff'; expect_writes 'debug.phxdpwatch' 0; expect_no_reboot; go dpwatch_bootarg; }
sc_dpwatch_nodesk() {   world; DESK=0; echo 1 >"$FR/gpu/phxboot-dpwatch"; expect_log 'dpwatch: not a desktop boot'; expect_writes 'debug.phxdpwatch' 0; expect_no_killall; expect_no_reboot; go dpwatch_nodesk; }
sc_dpwatch_events() {   flags_world; echo 2 >"$FR/gpu/phxboot-dpwatch"; NOWATCH=0; WATCHMAX=4
                        dpw_stat 1 0 0 0 0 0 0; dpw_stat 2 1 0 0 0 0 0 STUCK; dpw_stat 3 1 1 0 1 0 0 FIX-OK; dpw_stat 4 1 1 0 1 0 0
                        expect_log 'dpwatch: .* DP-B STUCK 0 -> 1 \| ev t=-1200ms DP-B STUCK dt_ms=500 vid=0x00000201'; expect_log 'dpwatch: .* DP-B recovered 0 -> 1'
                        expect_log 'dpwatch: .* DP-B FIX-OK 0 -> 1 \| ev .* DP-B FIX-OK'; expect_nolog 'DP-B STUCK 1 -> '; expect_nolog 'DP-[AE] '; expect_nolog 'FIX-FAIL [0-9]'
                        expect_order 'DP-B STUCK 0 -> 1' 'DP-B FIX-OK 0 -> 1'; expect_no_reboot; go dpwatch_events; }
sc_dpwatch_fail_ev() {  flags_world; echo 2 >"$FR/gpu/phxboot-dpwatch"; NOWATCH=0; WATCHMAX=3
                        dpw_stat 1 1 0 0 0 1 0 FIX-FAIL; expect_log 'dpwatch: .* DP-B STUCK 0 -> 1'; expect_log 'dpwatch: .* DP-B FIX-FAIL 0 -> 1 \| ev .* DP-B FIX-FAIL'
                        expect_nolog 'recovered 0 -> '; expect_no_reboot; go dpwatch_fail_ev; }
sc_dpwatch_quiet() {    flags_world; echo 1 >"$FR/gpu/phxboot-dpwatch"; NOWATCH=0; WATCHMAX=4; dpw_stat 1 0 0 0 0 0 0
                        expect_log 'dpwatch: .*debug.phxdpwatch=1 rc 0'; expect_nolog 'dpwatch: [0-9-]+ [0-9:]+ DP-'; expect_no_reboot; go dpwatch_quiet; }
sc_dpwatch_unarmed_ev(){ flags_world; echo 2 >"$FR/gpu/phxboot-dpwatch"; SIM_DPW_NOOID=1; NOWATCH=0; WATCHMAX=3; dpw_stat 1 1 0 0 0 0 0 STUCK
                        expect_log 'nothing armed'; expect_nolog 'dpwatch: [0-9-]+ [0-9:]+ DP-'; expect_no_reboot; go dpwatch_unarmed_ev; }
# 11-04 login-window guard: SHOWFULLNAME true at the daemon start, at a shutdown TERM and at
# every revert to GOP; back to the user's value (absent = deleted, the user's own true / false kept) right before the Metal
# WindowServer restart; ~/gpu/phxboot-b21guard = 0: the key is never touched. The fake domain is $FR/Library/Preferences/
# com.apple.loginwindow.plist (no SHOWFULLNAME by default), the defaults calls on it are in $ST/lw.log
sfn(){ "$MOCK_PB" -c 'Print :SHOWFULLNAME' "$FR/Library/Preferences/com.apple.loginwindow.plist" 2>/dev/null || echo absent; }
sfn_set(){ "$MOCK_PB" -c "Add :SHOWFULLNAME bool $1" "$FR/Library/Preferences/com.apple.loginwindow.plist" >/dev/null; }   # the user's own value
expect_sfn(){ expect_cmd "[ \"\$(sfn)\" = $1 ]"; }                      # the key at the end: true / false / absent
expect_b21orig(){ expect_cmd "[ \"\$(cat \"\$FR/gpu/phxboot-b21guard.orig\" 2>/dev/null || echo none)\" = $1 ]"; }   # the recorded user value (none = no state file)
expect_lw(){ expect_cmd "grep -Eq -- '$1' \"\$ST/lw.log\""; }           # a defaults call on the domain (verb key -bool value killed= termed=)
expect_nolw(){ expect_cmd "! grep -Eq -- '$1' \"\$ST/lw.log\""; }
sc_b21_start() {        world; touch "$FR/gpu/phxboot-off"; expect_log "b21guard: .* ON \(daemon start\): SHOWFULLNAME was .absent., set true \(defaults rc 0\); the user.s value .absent. recorded now"
                        expect_order 'b21guard: .* ON \(daemon start\)' 'kill switch present'; expect_lw '^write SHOWFULLNAME -bool true killed=no termed=no'; expect_sfn true; expect_b21orig absent; expect_no_killall; expect_no_reboot; go b21_start; }
sc_b21_happy() {        world; expect_log 'ON \(daemon start\)'; expect_log "b21guard: .* OFF before the Metal WindowServer restart: SHOWFULLNAME back to the user.s .absent. \(rc 0, reads .absent.\)"
                        expect_order 'Metal device ready' 'b21guard: .* OFF before'; expect_order 'AGDC up after' 'b21guard: .* OFF before'; expect_order 'b21guard: .* OFF before' 'restarting WindowServer once'
                        expect_lw '^delete SHOWFULLNAME +killed=no'; expect_nolw 'killed=yes'; expect_nolog 'No such file'; expect_sfn absent; expect_b21orig none; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go b21_happy; }
sc_b21_user_true() {    world; sfn_set true; expect_log "the user.s value .1. recorded now"; expect_log "OFF before the Metal WindowServer restart: SHOWFULLNAME back to the user.s .1. \(rc 0, reads .1.\)"
                        expect_nolw '^delete'; expect_nolw 'false'; expect_sfn true; expect_b21orig none; expect_killall; go b21_user_true; }
sc_b21_user_false() {   world; sfn_set false; expect_log "SHOWFULLNAME was .0., set true"; expect_log "OFF before the Metal WindowServer restart: SHOWFULLNAME back to the user.s .0. \(rc 0, reads .0.\)"
                        expect_lw '^write SHOWFULLNAME -bool false killed=no'; expect_nolw '^delete'; expect_sfn false; expect_b21orig none; expect_killall; go b21_user_false; }
sc_b21_gop() {          world; DESK=0; expect_log 'no desktop arm: GOP'; expect_log 'ON \(daemon start\)'; expect_nolog 'b21guard: .* OFF'; expect_nolw '^delete'; expect_sfn true; expect_b21orig absent; expect_no_killall; go b21_gop; }
sc_b21_metal_fail() {   world; SIM_METAL=0; expect_log 'FAIL \(Metal device never came up\)'; expect_log 'ON \(FAIL: the next boot is GOP\)'; expect_nolog 'b21guard: .* OFF'; expect_nolw '^delete'
                        expect_sfn true; expect_b21orig absent; expect_no_killall; expect_reboot; go b21_metal_fail; }
sc_b21_crash_loop() {   world; SIM_CRASH_PER_STEP=1; expect_order 'b21guard: .* OFF before' 'restarting WindowServer once'; expect_order 'restarting WindowServer once' 'ON \(FAIL: the next boot is GOP\)'
                        expect_lw '^write SHOWFULLNAME -bool true killed=yes'; expect_log "ON \(FAIL: the next boot is GOP\): SHOWFULLNAME was .absent., set true .*recorded now"; expect_sfn true; expect_b21orig absent; expect_reboot; go b21_crash_loop; }
sc_b21_late_revert() {  world; NOWATCH=0; WATCHMAX=4; SIM_WS_LATE_SILENT=2; expect_log 'WindowServer hung 2x on GPU: reverting to GOP'; expect_order 'reverting to GOP' 'ON \(revert to GOP after the hangs\)'
                        expect_sfn true; expect_b21orig absent; expect_reboot; go b21_late_revert; }
sc_b21_shutdown() {     world; NOWATCH=0; WATCHMAX=4; SIM_SHUTDOWN_W15=1; expect_rc 143; expect_log 'SUCCESS'
                        expect_log "ON \(shutdown \(TERM\)\): SHOWFULLNAME was .absent., set true \(defaults rc 0\); the user.s value .absent. recorded now"
                        expect_lw '^write SHOWFULLNAME -bool true killed=yes termed=yes'; expect_sfn true; expect_b21orig absent; expect_no_reboot; go b21_shutdown; }
sc_b21_term_nocfp_false(){ world; sfn_set false; NOWATCH=0; WATCHMAX=4; SIM_SHUTDOWN_W15=1; SIM_LW_BROKEN_AT_TERM=1; expect_rc 143
                        expect_log "ON \(shutdown \(TERM\)\): SHOWFULLNAME was .absent., set true \(defaults rc 0, file was false: written directly, now true\); the user.s value .0. recorded now"
                        expect_sfn true; expect_b21orig 0; go b21_term_nocfp_false; }
sc_b21_term_nocfp_true(){ world; sfn_set true; NOWATCH=0; WATCHMAX=4; SIM_SHUTDOWN_W15=1; SIM_LW_BROKEN_AT_TERM=1; expect_rc 143
                        expect_log "ON \(shutdown \(TERM\)\): SHOWFULLNAME was .absent., set true \(defaults rc 0\); the user.s value .1. recorded now"; expect_sfn true; expect_b21orig 1; go b21_term_nocfp_true; }
sc_b21_attempt_term() { world; SIM_TERM_IN_WATCH=1; expect_log 'clean shutdown \(TERM\)'; expect_order 'b21guard: .* OFF before' 'ON \(shutdown \(TERM\) during the desktop attempt\)'
                        expect_lw '^write SHOWFULLNAME -bool true killed=yes termed=yes'; expect_sfn true; expect_b21orig absent; expect_no_reboot; X_NOMARK=1; go b21_attempt_term; SIM_TERM_IN_WATCH=0; }
sc_b21_flag_off() {     world; echo 0 >"$FR/gpu/phxboot-b21guard"; NOWATCH=0; WATCHMAX=4; SIM_SHUTDOWN_W15=1; expect_rc 143; expect_log 'b21guard: off \(~/gpu/phxboot-b21guard = 0\): SHOWFULLNAME not managed$'
                        expect_nolog 'b21guard: .* (ON|OFF)'; expect_cmd '[ ! -s "$ST/lw.log" ]'; expect_sfn absent; expect_b21orig none; expect_log 'SUCCESS'; expect_killall; go b21_flag_off; }
sc_b21_flag_off_left(){ world; DESK=0; boot1; echo 0 >"$FR/gpu/phxboot-b21guard"; DESK=1; expect_log "b21guard: off .*a guard ON left by an earlier boot stays: the user.s value .absent. is in"
                        expect_cmd '[ ! -s "$ST/lw.log" ]'; expect_sfn true; expect_b21orig absent; go b21_flag_off_left; }
sc_b21_two_boots() {    world; NOWATCH=0; WATCHMAX=4; SIM_SHUTDOWN_W15=1; boot1; NOWATCH=1; SIM_SHUTDOWN_W15=0
                        expect_cmd 'grep -q "b21guard: .* ON (shutdown (TERM)): SHOWFULLNAME was .absent., set true" "$W/boot1.log"'
                        expect_log "ON \(daemon start\): SHOWFULLNAME was .1., set true \(defaults rc 0\); the user.s value .absent. recorded earlier"
                        expect_log "OFF before the Metal WindowServer restart: SHOWFULLNAME back to the user.s .absent."; expect_sfn absent; expect_b21orig none; expect_killall; go b21_two_boots; }
sc_b21_off_fails() {    world; sfn_set true; echo absent >"$FR/gpu/phxboot-b21guard.orig"; SIM_LW_FAIL=delete
                        expect_log "OFF FAILED: SHOWFULLNAME reads .1., not the user.s .absent. \(rc 1\)"; expect_sfn true; expect_b21orig absent; expect_log 'SUCCESS'; expect_killall; go b21_off_fails; }
# 11-19 pre-start hook ($G/phxboot-pre.sh): it runs before the flags are read (a staged phxboot-desktop arms this boot); a
# failing or hanging hook is logged and the boot goes on as without it
prehook(){ printf '%s\n' "$1" >"$FR/gpu/phxboot-pre.sh"; }
sc_prehook_desktop() {  world; DESK=0; prehook 'touch "$1/phxboot-desktop"; echo "pre: staged phxboot-desktop"'
                        expect_log 'pre: staged phxboot-desktop'; expect_log 'desktop-arm: 1'; expect_order 'pre: staged' 'desktop-arm: 1'; expect_log 'SUCCESS'; expect_killall; go prehook_desktop; }
sc_prehook_fail() {     world; DESK=0; prehook 'echo "pre: broken"; exit 3'
                        expect_log 'pre-hook: .*phxboot-pre.sh exit 3'; expect_log 'no desktop arm: GOP'; expect_no_killall; expect_no_reboot; go prehook_fail; }
sc_prehook_hang() {     world; DESK=0; prehook 'exec /bin/sleep 30'; export PHXBOOT_PRE_WAIT=2
                        expect_log 'pre-hook: .* still running after 2s: killed'; expect_log 'no desktop arm: GOP'; expect_no_reboot; go prehook_hang; unset PHXBOOT_PRE_WAIT; }
# 11-19 wscdcopy (GPU present E3): launchd's environment for the restarted WindowServer, only with both GPU present switches
gp_world(){ world; mkdir -p "$FR/Library/GPUBundles/nvmtl"; touch "$FR/Library/GPUBundles/nvmtl/ws-gpu-present"; [ "${1:-}" = async ] && touch "$FR/Library/GPUBundles/nvmtl/ws-gpu-present-async"; true; }
lc_has(){ X_CMDS="${X_CMDS:-}
grep -q 'launchctl setenv NVMTL_WS_PRESENT_CDCOPY 1' '$ST/launchctl.log'"; }
lc_hasnt(){ X_CMDS="${X_CMDS:-}
! grep -q 'NVMTL_WS_PRESENT_CDCOPY' '$ST/launchctl.log'"; }
sc_cdcopy_off() {       gp_world async; expect_nolog 'wscdcopy'; expect_log 'SUCCESS'; expect_killall; lc_hasnt; go cdcopy_off; }
sc_cdcopy_on() {        gp_world async; touch "$FR/gpu/phxboot-wscdcopy"; expect_log 'wscdcopy: NVMTL_WS_PRESENT_CDCOPY=1'; expect_log 'gpu present allowed'
                        expect_order 'wscdcopy: NVMTL' 'restarting WindowServer once'; expect_log 'SUCCESS'; expect_killall; lc_has; go cdcopy_on; }
sc_cdcopy_noasync() {   gp_world; touch "$FR/gpu/phxboot-wscdcopy"; expect_log 'wscdcopy: needs .*ws-gpu-present-async: NVMTL_WS_PRESENT_CDCOPY not set'
                        expect_log 'SUCCESS'; expect_killall; lc_hasnt; go cdcopy_noasync; }
sc_cdcopy_nogp() {      world; touch "$FR/gpu/phxboot-wscdcopy"; expect_log 'wscdcopy: needs .*ws-gpu-present and'; expect_nolog 'gpu present allowed'
                        expect_log 'flip on'; expect_log 'SUCCESS'; expect_killall; lc_hasnt; go cdcopy_nogp; }
sc_cdcopy_lcfail() {    gp_world async; touch "$FR/gpu/phxboot-wscdcopy"; SIM_LAUNCHCTL_FAIL=1; expect_log 'wscdcopy: launchctl setenv failed'
                        expect_log 'SUCCESS'; expect_killall; go cdcopy_lcfail; }
sc_cdcopy_nodesk() {    gp_world async; DESK=0; touch "$FR/gpu/phxboot-wscdcopy"; expect_nolog 'wscdcopy'; expect_log 'no desktop arm: GOP'; expect_no_killall; lc_hasnt; go cdcopy_nodesk; }
# 11-23 wstiled: launchd's environment for the restarted WindowServer (its display surface drawn tiled); not on the safe desktop
lt_has(){ X_CMDS="${X_CMDS:-}
grep -q 'launchctl setenv NVMTL_WS_SCANOUT_TILED 1' '$ST/launchctl.log'"; }
lt_hasnt(){ X_CMDS="${X_CMDS:-}
! grep -q 'NVMTL_WS_SCANOUT_TILED' '$ST/launchctl.log'"; }
sc_wstiled_off() {      world; expect_nolog 'wstiled'; expect_log 'SUCCESS'; expect_killall; lt_hasnt; go wstiled_off; }
sc_wstiled_on() {       world; touch "$FR/gpu/phxboot-wstiled"; expect_log 'wstiled: NVMTL_WS_SCANOUT_TILED=1'
                        expect_order 'wstiled: NVMTL' 'restarting WindowServer once'; expect_log 'SUCCESS'; expect_killall; lt_has; go wstiled_on; }
sc_wstiled_lcfail() {   world; touch "$FR/gpu/phxboot-wstiled"; SIM_LAUNCHCTL_FAIL=1; expect_log 'wstiled: launchctl setenv failed'
                        expect_log 'SUCCESS'; expect_killall; go wstiled_lcfail; }
sc_wstiled_nodesk() {   world; DESK=0; touch "$FR/gpu/phxboot-wstiled"; expect_nolog 'wstiled'; expect_log 'no desktop arm: GOP'; expect_no_killall; lt_hasnt; go wstiled_nodesk; }
# 11-19 waitstep: debug.phxwait_step_us from ~/gpu/phxboot-waitstep before the WindowServer restart (desktop boots only)
ws_flag(){ printf '%s' "$1" >"$FR/gpu/phxboot-waitstep"; }
# 11-20 p0modes: ~/gpu/phxboot-p0modes arms the pipe-0 engine and the head-0 mode list before the claim (b128, 1440p)
sc_p0modes_off() {      world; expect_nolog 'p0modes'; expect_writes 'phxpipe0_enable' 0; expect_writes 'phxpipe0_modes' 0; expect_log 'SUCCESS'; go p0modes_off; }
alu(){ "$MOCK_PB" -c "Print :autoLoginUser" "$FR/Library/Preferences/com.apple.loginwindow.plist" 2>/dev/null || echo absent; }
expect_alu(){ expect_cmd "[ \"\$(alu)\" = $1 ]"; }
LWRAN_T(){ echo "$FR/var/run/com.apple.loginwindow.didRunThisBoot"; }   # loginwindow's first-run marker
lwran_world(){ mkdir -p "$FR/var/run"; : >"$(LWRAN_T)"; }               # the boot's first loginwindow ran
al_world(){ world; lwran_world; echo mockuser >"$FR/gpu/phxboot-autologin"; mkdir -p "$FR/etc"; echo x >"$FR/etc/kcpassword"; }
sc_al_off() {           world; lwran_world; expect_nolog 'autologin:'; expect_alu absent; expect_file "$(LWRAN_T)"; expect_log 'SUCCESS'; go al_off; }
sc_al_on() {            al_world; expect_log 'autologin: .* off \(daemon start\)'; expect_log "autologin: .* on for 'mockuser' before the Metal WindowServer restart \(reads 'mockuser'; first-run marker removed\)"
                        expect_order 'autologin: .* off \(daemon start\)' 'autologin: .* on for'; expect_order 'autologin: .* on for' 'restarting WindowServer once'
                        expect_alu mockuser; expect_nofile "$(LWRAN_T)"; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go al_on; }
# the marker can't be removed (here: a directory): the log says so, the run goes on as before
sc_al_marker_stuck() {  al_world; rm -f "$(LWRAN_T)"; mkdir -p "$(LWRAN_T)"; expect_log 'autologin: .* on for .*first-run marker STILL PRESENT'
                        expect_alu mockuser; expect_log 'SUCCESS'; expect_killall; expect_no_reboot; go al_marker_stuck; }
# no autologin armed: the marker stays (a user who is not auto-logged-in gets loginwindow's normal behaviour)
sc_al_user_marker() {   al_world; SIM_USERS="user console 2026 Nov 20"; expect_nolog 'autologin: .* on for'; expect_file "$(LWRAN_T)"; go al_user_marker; }
sc_al_user_in() {       al_world; SIM_USERS="user console 2026 Nov 20"; expect_log 'a user is logged in before arming'; expect_nolog 'autologin: .* on for'; expect_alu absent; go al_user_in; }
sc_al_nokc() {          world; echo mockuser >"$FR/gpu/phxboot-autologin"; expect_log 'autologin: .*kcpassword missing'; expect_alu absent; expect_log 'SUCCESS'; go al_nokc; }
sc_al_metal_fail() {    al_world; SIM_METAL=0; expect_log 'FAIL \(Metal device never came up\)'; expect_nolog 'autologin: .* on for'; expect_alu absent; expect_reboot; go al_metal_fail; }
sc_al_shutdown() {      al_world; NOWATCH=0; WATCHMAX=4; SIM_SHUTDOWN_W15=1; expect_rc 143; expect_log 'SUCCESS'; expect_log 'autologin: .* off \(shutdown \(TERM\)\)'
                        expect_alu absent; expect_no_reboot; go al_shutdown; }
sc_al_b21off() {        al_world; echo 0 >"$FR/gpu/phxboot-b21guard"; expect_log 'autologin: .* off \(daemon start\)'; expect_log 'autologin: .* on for'; expect_alu mockuser; go al_b21off; }
sc_p0modes_on() {       world; touch "$FR/gpu/phxboot-p0modes"; expect_writes '^-w debug.phxpipe0_enable=1$' 1; expect_writes '^-w debug.phxpipe0_modes=1$' 1
                        expect_log 'p0modes: pipe-0 engine on, head-0 mode list armed'; expect_log 'claim: phxpipe0_modes was set before the claim'
                        expect_order 'p0modes: pipe-0 engine on' 'restarting WindowServer once'; expect_log 'SUCCESS'; expect_no_reboot; go p0modes_on; }
sc_p0modes_oldkext() {  world; touch "$FR/gpu/phxboot-p0modes"; SIM_P0_OLD=1; expect_log 'p0modes: VermilionBoot before b128'; expect_writes 'phxpipe0_enable' 0
                        expect_writes 'phxpipe0_modes' 0; expect_log 'SUCCESS'; expect_no_reboot; go p0modes_oldkext; }
sc_p0modes_fail() {     world; touch "$FR/gpu/phxboot-p0modes"; SIM_SYSCTL_FAIL=debug.phxpipe0_modes; expect_log 'p0modes: enable rc 0, modes rc 1'
                        expect_log 'SUCCESS'; expect_no_reboot; go p0modes_fail; }
sc_waitstep_off() {     world; expect_nolog 'waitstep'; expect_writes 'phxwait_step_us' 0; expect_log 'SUCCESS'; go waitstep_off; }
sc_waitstep_on() {      world; ws_flag 200; expect_writes '^-w debug.phxwait_step_us=200$' 1; expect_log 'waitstep: debug.phxwait_step_us=200 rc 0, reads 200'
                        expect_order 'waitstep: debug' 'restarting WindowServer once'; expect_log 'SUCCESS'; expect_killall; go waitstep_on; }
sc_waitstep_empty() {   world; ws_flag ''; expect_writes '^-w debug.phxwait_step_us=200$' 1; expect_log 'waitstep: debug.phxwait_step_us=200 rc 0'; expect_log 'SUCCESS'; go waitstep_empty; }
sc_waitstep_space() {   world; ws_flag ' 100
'; expect_writes '^-w debug.phxwait_step_us=100$' 1; expect_log 'waitstep: debug.phxwait_step_us=100 rc 0, reads 100'; expect_log 'SUCCESS'; go waitstep_space; }
sc_waitstep_edges() {   world; ws_flag 1000; expect_writes '^-w debug.phxwait_step_us=1000$' 1; expect_log 'SUCCESS'; go waitstep_edges; }
sc_waitstep_low() {     world; ws_flag 19; expect_writes 'phxwait_step_us' 0; expect_log "waitstep: .*holds '19', not 20-1000"; expect_log 'SUCCESS'; go waitstep_low; }
sc_waitstep_high() {    world; ws_flag 1001; expect_writes 'phxwait_step_us' 0; expect_log "waitstep: .*holds '1001', not 20-1000"; expect_log 'SUCCESS'; go waitstep_high; }
sc_waitstep_bad() {     world; ws_flag 'abc'; expect_writes 'phxwait_step_us' 0; expect_log "waitstep: .*holds 'abc', not 20-1000"; expect_log 'SUCCESS'; go waitstep_bad; }
sc_waitstep_octal() {   world; ws_flag '0200'; expect_writes 'phxwait_step_us' 0; expect_log "waitstep: .*holds '0200', not 20-1000"; expect_log 'SUCCESS'; go waitstep_octal; }
sc_waitstep_huge() {    world; ws_flag '99999999999999999999'; expect_writes 'phxwait_step_us' 0; expect_log 'waitstep: .*not 20-1000'; expect_log 'SUCCESS'; go waitstep_huge; }
sc_waitstep_nooid() {   world; ws_flag 200; SIM_WAITSTEP_NOOID=1; expect_writes 'phxwait_step_us' 0; expect_log 'waitstep: PhxBringup without debug.phxwait_step_us'; expect_log 'SUCCESS'; go waitstep_nooid; }
sc_waitstep_fail() {    world; ws_flag 200; SIM_SYSCTL_FAIL=debug.phxwait_step_us; expect_writes '^-w debug.phxwait_step_us=200$' 1
                        expect_log 'waitstep: debug.phxwait_step_us=200 rc 1, reads 50 \(sysctl: .*Operation not permitted\)'; expect_log 'SUCCESS'; expect_killall; go waitstep_fail; }
sc_waitstep_nodesk() {  world; DESK=0; ws_flag 200; expect_nolog 'waitstep'; expect_writes 'phxwait_step_us' 0; expect_log 'no desktop arm: GOP'; go waitstep_nodesk; }
# 11-23 irqwait: the five interrupt-wait sysctls from ~/gpu/phxboot-irqwait before the WindowServer restart
sc_irqwait_off() {      world; expect_nolog 'irqwait'; expect_writes 'phxih|phxirq|phxeopirq|phxwait_irq' 0; expect_log 'SUCCESS'; go irqwait_off; }
sc_irqwait_on() {       world; touch "$FR/gpu/phxboot-irqwait"; expect_writes '^-w debug.phxih_vram=1$' 1; expect_writes '^-w debug.phxih=1$' 1
                        expect_writes '^-w debug.phxeopirq=1$' 1; expect_writes '^-w debug.phxirq=1$' 1; expect_writes '^-w debug.phxwait_irq=1$' 1
                        expect_writes '^-w debug.(phxwait_irq|phxirq|phxeopirq|phxih|phxih_vram)=0$' 0; expect_log 'irqwait: on \(debug.phxih_vram=1 debug.phxih=1 debug.phxeopirq=1 debug.phxirq=1 debug.phxwait_irq=1\)'
                        expect_order 'irqwait: on' 'restarting WindowServer once'; expect_log 'SUCCESS'; expect_killall; go irqwait_on; }
sc_irqwait_fail() {     world; touch "$FR/gpu/phxboot-irqwait"; SIM_SYSCTL_FAIL=debug.phxirq; expect_writes '^-w debug.phxwait_irq=1$' 0
                        expect_writes '^-w debug.(phxwait_irq|phxirq|phxeopirq|phxih|phxih_vram)=0$' 5; expect_log 'irqwait: debug.phxirq=1 rc 1, reads 0 .*all back to 0'
                        expect_log 'SUCCESS'; expect_killall; go irqwait_fail; }
sc_irqwait_nooid() {    world; touch "$FR/gpu/phxboot-irqwait"; SIM_IRQWAIT_NOOID=1; expect_writes 'phxih|phxirq|phxeopirq|phxwait_irq' 0
                        expect_log 'irqwait: PhxBringup without debug.phxwait_irq'; expect_log 'SUCCESS'; go irqwait_nooid; }
sc_irqwait_nodesk() {   world; DESK=0; touch "$FR/gpu/phxboot-irqwait"; expect_nolog 'irqwait'; expect_writes 'phxih|phxirq|phxeopirq|phxwait_irq' 0; expect_log 'no desktop arm: GOP'; go irqwait_nodesk; }
sc_waitstep_gp() {      gp_world async; touch "$FR/gpu/phxboot-wscdcopy"; ws_flag 200; expect_order 'wscdcopy: NVMTL' 'waitstep: debug.phxwait_step_us=200 rc 0'
                        expect_order 'waitstep: debug' 'restarting WindowServer once'; expect_log 'SUCCESS'; lc_has; go waitstep_gp; }
# 11-20 stuck squat: with OpenCore's DisableVariableWrite, macOS cannot clear phxfb-squat, so a reboot onto IONDRV came
# back squatting (three reboots in a row on the XTX machine). The second squat boot runs the safe desktop instead.
sc_squat_kill_pending(){ world; DESK=0; SIM_SQUAT=1; touch "$FR/gpu/phxboot-off"; expect_log 'rebooting onto IONDRV'; expect_reboot; expect_file "$FR/gpu/phxboot-nvstuck"; go squat_kill_pending; }
sc_stuck_loop() {       gp_world; DESK=0; SIM_SQUAT=1; touch "$FR/gpu/phxboot-p0modes" "$FR/var/db/phxboot.pending"; boot1
                        grep -q 'squat boot: rebooting onto IONDRV' "$W/boot1.log" || echo "FAIL  stuck_loop: boot 1 did not reboot"
                        expect_log 'nvstuck: still a squat boot'; expect_log 'safe desktop on the stuck squat'; expect_log 'SUCCESS'; expect_log 'safe desktop up'
                        expect_nolog 'rebooting onto IONDRV'; expect_writes 'phxscan' 0; expect_writes 'phxpipe0_enable' 0; expect_nolog 'flip on'
                        expect_killall; expect_no_reboot; go stuck_loop; }
sc_stuck_safe_hung() {  world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; touch "$FR/gpu/phxboot-off" "$FR/var/db/phxboot.pending" "$FR/gpu/phxboot-safe"
                        expect_log 'safe desktop did not finish last boot'; expect_nolog 'bring-up'; expect_no_killall; expect_no_reboot; go stuck_safe_hung; }
# the boot after the headless one (kill switch and phxboot-safe left, the mark gone): the safe desktop again, as the
# daemon's headless line tells the user
sc_stuck_after_headless() { world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; touch "$FR/gpu/phxboot-off" "$FR/gpu/phxboot-safe"
                        expect_nolog 'did not finish'; expect_log 'safe desktop on the stuck squat'; expect_log 'safe desktop up'; expect_no_reboot; go stuck_after_headless; }
sc_stuck_cleared() {    world; DESK=0; echo pending >"$FR/gpu/phxboot-nvstuck"; touch "$FR/gpu/phxboot-safe"; expect_log 'not a squat boot: phxfb-squat is clear'
                        expect_nofile "$FR/gpu/phxboot-nvstuck"; expect_no_reboot; go stuck_cleared; }
sc_stuck_metal_fail() { world; DESK=0; SIM_SQUAT=1; echo pending >"$FR/gpu/phxboot-nvstuck"; touch "$FR/gpu/phxboot-off"; SIM_METAL=0
                        expect_log 'FAIL \(Metal device never came up\)'; expect_log 'stuck squat: no reboot after the failure'; expect_no_reboot; go stuck_metal_fail; }
sc_stuck_crash() {      world; DESK=0; SIM_SQUAT=1; echo pending >"$FR/gpu/phxboot-nvstuck"; touch "$FR/gpu/phxboot-off"; SIM_CRASH_PER_STEP=1
                        expect_log 'WindowServer crashed/hung'; expect_log 'stuck squat: no reboot after the failure'; expect_no_reboot; go stuck_crash; }
sc_stuck_failf() {      world; DESK=0; SIM_SQUAT=1; echo pending >"$FR/gpu/phxboot-nvstuck"; touch "$FR/gpu/phxboot-failed"
                        expect_log 'stuck squat after a failed attempt \(fails=1, clean fallback boots 0 of 1\)'; expect_log 'safe desktop up .*the full desktop again at the next startup'
                        expect_nofile "$FR/gpu/phxboot-failed"; expect_rec fails=1; expect_rec last=safe; expect_no_reboot; go stuck_failf; }
sc_stuck_full() {       world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; touch "$FR/gpu/phxboot-safe"
                        expect_nolog 'safe desktop'; expect_log 'SUCCESS'; expect_nofile "$FR/gpu/phxboot-safe"; expect_no_reboot; go stuck_full; }
# 11-20 Adaptive Sync: on by default (no write); ~/gpu/phxboot-novrr and the safe desktop write debug.phxfb0_vrr=0 before the claim
sc_vrr_default() {      world; expect_nolog 'vrr: '; expect_writes 'phxfb0_vrr' 0; expect_log 'SUCCESS'; go vrr_default; }
sc_vrr_off() {          world; touch "$FR/gpu/phxboot-novrr"; expect_writes '^-w debug.phxfb0_vrr=0$' 1; expect_log 'vrr: off'
                        expect_order 'vrr: off' 'NMXAccel up'; expect_log 'SUCCESS'; go vrr_off; }
sc_vrr_safe() {         world; DESK=0; SIM_SQUAT=1; echo pending >"$FR/gpu/phxboot-nvstuck"; touch "$FR/gpu/phxboot-off"
                        expect_log 'safe desktop up'; expect_log 'vrr: off .*the safe desktop'; expect_writes '^-w debug.phxfb0_vrr=0$' 1; expect_no_reboot; go vrr_safe; }
# 11-22 VRR floor: PhxAccel's default 60 (no write); ~/gpu/phxboot-vrrmin (0 or 24-240) writes debug.phxfb0_vrrmin before the claim
vm_flag(){ printf '%s' "$1" >"$FR/gpu/phxboot-vrrmin"; }
sc_vrrmin_default() {   world; expect_writes 'phxfb0_vrrmin' 0; expect_nolog 'vrr: '; expect_log 'SUCCESS'; go vrrmin_default; }
sc_vrrmin_on() {        world; vm_flag 72; expect_writes '^-w debug.phxfb0_vrrmin=72$' 1; expect_log 'vrr: floor 72 Hz'
                        expect_order 'vrr: floor' 'NMXAccel up'; expect_log 'SUCCESS'; go vrrmin_on; }
sc_vrrmin_space() {     world; vm_flag ' 60
'; expect_writes '^-w debug.phxfb0_vrrmin=60$' 1; expect_log 'SUCCESS'; go vrrmin_space; }
sc_vrrmin_edid() {      world; vm_flag 0; expect_writes '^-w debug.phxfb0_vrrmin=0$' 1; expect_log 'vrr: floor 0 Hz'; go vrrmin_edid; }
sc_vrrmin_bad() {       world; vm_flag 'abc'; expect_writes 'phxfb0_vrrmin' 0; expect_log "vrr: .*holds 'abc', not 0 or 24-240"; expect_log 'SUCCESS'; go vrrmin_bad; }
sc_vrrmin_low() {       world; vm_flag 23; expect_writes 'phxfb0_vrrmin' 0; expect_log "holds '23'"; go vrrmin_low; }
sc_vrrmin_high() {      world; vm_flag 241; expect_writes 'phxfb0_vrrmin' 0; expect_log "holds '241'"; go vrrmin_high; }
sc_vrrmin_octal() {     world; vm_flag 060; expect_writes 'phxfb0_vrrmin' 0; expect_log "holds '060'"; go vrrmin_octal; }
sc_vrrmin_empty() {     world; vm_flag ''; expect_writes 'phxfb0_vrrmin' 0; expect_log "holds ''"; go vrrmin_empty; }
sc_vrrmin_nooid() {     world; vm_flag 60; SIM_VRRMIN_NOOID=1; expect_log 'vrr: no debug.phxfb0_vrrmin'; expect_log 'SUCCESS'; go vrrmin_nooid; }
sc_vrrmin_safe() {      world; DESK=0; SIM_SQUAT=1; echo pending >"$FR/gpu/phxboot-nvstuck"; touch "$FR/gpu/phxboot-off"; vm_flag 72
                        expect_log 'safe desktop up'; expect_writes 'phxfb0_vrrmin' 0; expect_no_reboot; go vrrmin_safe; }
# 11-21 HDR: on by default (no write); ~/gpu/phxboot-nohdr and the safe desktop write debug.phxfb0_hdr=0 before the claim
sc_hdr_default() {      world; expect_nolog 'hdr: '; expect_writes 'phxfb0_hdr' 0; expect_log 'SUCCESS'; go hdr_default; }
sc_hdr_off() {          world; touch "$FR/gpu/phxboot-nohdr"; expect_writes '^-w debug.phxfb0_hdr=0$' 1; expect_log 'hdr: off'
                        expect_order 'hdr: off' 'NMXAccel up'; expect_log 'SUCCESS'; go hdr_off; }
sc_hdr_safe() {         world; DESK=0; SIM_SQUAT=1; echo pending >"$FR/gpu/phxboot-nvstuck"; touch "$FR/gpu/phxboot-off"
                        expect_log 'safe desktop up'; expect_log 'hdr: off .*the safe desktop'; expect_writes '^-w debug.phxfb0_hdr=0$' 1; expect_no_reboot; go hdr_safe; }
# 2026-11-24 phase 2 item 1: a warm GPU (PSP sOS running). bringup_navi31.sh refuses and navi31_up.sh says so (this stub
# prints what the real pair prints, tests/mock/bringup_warm_test.sh checks the pair). The daemon claims nothing: a desktop
# boot reverts to GOP (m2_fail), a GOP boot stays on the firmware display, a stuck squat stays up without a reboot.
warm_stub(){ printf '#!/bin/bash\necho "== bring-up (PSP, SMU, RLC, RS64, doorbells, MEC)"\necho "== sOS alive? (C2PMSG_81 sign of life, C2PMSG_58 version) =="\necho "refused: warm GPU (PSP sOS running, C2PMSG_81=0x00000001): no firmware loaded, nothing written; shut the machine down fully (power off), then boot macOS"\necho "bring-up failed"\nexit 1\n' >"$FR/gpu/phxctl/navi31_up.sh"; chmod +x "$FR/gpu/phxctl/navi31_up.sh"; }
# 2026-11-25 (phase 2 item 3 step 1): the refusal is not a failed attempt: no m2_fail, no record change, no Metal allow
# list or debug.phxagdc write on the untouched GPU, no reboot (a restart keeps the GPU warm); one notice
sc_warm_desk() {        world; warm_stub; expect_log 'warm GPU: bring-up refused, no Metal this boot \(firmware display\).*not counted as a failed attempt, no reboot'
                        expect_nolog 'FAIL|claim: |NMXAccel up|SUCCESS'; expect_nvram '-d phxfb-boot'; expect_nonvram '-d phxfb-squat'; expect_writes 'debug.phxagdc' 0; no_allow
                        expect_log 'notice: The graphics card was still running from another operating system'; expect_rec fails=0; expect_rec last=skip
                        expect_nofile "$FR/gpu/phxboot-failed"; X_NOMARK=1; expect_no_killall; expect_no_reboot; go warm_desk; }
sc_warm_nodesk() {      world; DESK=0; warm_stub; expect_log 'warm GPU: bring-up refused, no Metal this boot'; expect_nolog 'claim: |NMXAccel|FAIL'
                        expect_no_killall; expect_no_reboot; go warm_nodesk; }
sc_warm_squat() {       world; DESK=0; SIM_SQUAT=1; AUTOF=1; warm_stub; expect_log 'warm GPU: bring-up refused, no Metal this boot \(a squat boot: no display without the claim'
                        expect_nolog 'FAIL|rebooting onto IONDRV|claim: |NMXAccel up'; expect_nonvram '-d phxfb-squat'; expect_nonvram 'set phxfb-squat'; expect_writes 'debug.phxagdc' 0; no_allow
                        expect_nofile "$FR/gpu/phxboot-nvstuck"; expect_rec fails=0; X_NOMARK=1; expect_no_killall; expect_no_reboot; go warm_squat; }
sc_warm_stuck() {       world; DESK=0; SIM_SQUAT=1; echo pending >"$FR/gpu/phxboot-nvstuck"; touch "$FR/gpu/phxboot-failed"; warm_stub
                        expect_log 'warm GPU: bring-up refused'; expect_nolog 'FAIL|claim: |NMXAccel up'; expect_writes 'debug.phxagdc' 0; no_allow
                        expect_rec fails=1; expect_rec clean=0; X_NOMARK=1; expect_no_reboot; go warm_stuck; }
# a cold GPU: the check's value is logged at every boot (does a warm macOS restart leave the sOS running?), nothing else changes
sc_sos_logged() {       world; expect_log '^sOS check: C2PMSG_81=0x00000000 \(cold\)$'; expect_nolog 'warm GPU'; expect_log 'SUCCESS'; go sos_logged; }
# 2026-11-25 phase 2 item 3 step 1: recovery without the manual rm. The record /var/db/phxboot.fails (fails, clean, bfail,
# skipped, last) replaces the daemon-made kill switch and ~/gpu/phxboot-failed; a bring-up that did not end with
# "navi31 up:" claims nothing; the in-progress mark is set before the bring-up; Safe Mode exits; one notice after login.
REC_T(){ echo "$FR/var/db/phxboot.fails"; }
rec_set(){ local kv; : >"$(REC_T)"; for kv in fails=0 clean=0 bfail=0 skipped=0 last=none "$@"; do echo "$kv" >>"$(REC_T)"; done
           awk -F= '{v[$1]=$2; if(!($1 in o)){o[$1]=n++; k[n-1]=$1}} END{for(i=0;i<n;i++) print k[i]"="v[k[i]]}' "$(REC_T)" >"$(REC_T).t" && mv "$(REC_T).t" "$(REC_T)"; }
expect_rec(){ expect_cmd "grep -qx '$1' \"\$FR/var/db/phxboot.fails\""; }   # expect_rec <key=value>: the record holds it after the run
no_allow(){ expect_cmd '[ ! -e "$FR/Library/GPUBundles/nvmtl-allow.txt" ]'; }   # the Metal allow list was not written
keep1(){ cp "$W/boot1.log" "$W/boot1.$1.log"; }   # keep a boot1 log under a number (boot1 overwrites it)
upfail_stub(){ printf '#!/bin/bash\necho "== bring-up (PSP, SMU, RLC, RS64, doorbells, MEC)"\necho "sOS check: C2PMSG_81=0x00000000 (cold)"\necho "%s"\necho "navi31 not up: %s (%s)"\nexit 1\n' "$1" "$1" "$2" >"$FR/gpu/phxctl/navi31_up.sh"; chmod +x "$FR/gpu/phxctl/navi31_up.sh"; }
up_ok_stub(){ cp "$BIN/navi31_up.sh" "$FR/gpu/phxctl/navi31_up.sh"; }
WDARM="the bring-up watchdog is still armed: a restart within 3 min"; WDOFF="the bring-up watchdog is cancelled: no restart"
# the kill switch stays the owner's: an unfinished attempt is counted in the record, no ~/gpu/phxboot-off is made
sc_rec_no_killswitch(){ world; touch "$FR/var/db/phxboot.pending"; expect_log 'previous attempt did not finish -> GOP \(one-shots cleared; counted in .*phxboot.fails, fails=1\)'
                        expect_nofile "$FR/gpu/phxboot-off"; expect_rec fails=1; expect_rec last=skip; X_NOMARK=1; expect_no_reboot; go rec_no_killswitch; }
# a freeze on a stuck squat: one safe desktop, then the full desktop again by itself (no rm)
sc_rec_return() {       world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; touch "$FR/var/db/phxboot.pending"; boot1; keep1 1
                        expect_cmd 'grep -q "safe desktop up" "$W/boot1.1.log"'; expect_cmd 'grep -q "the full desktop again at the next startup" "$W/boot1.1.log"'
                        expect_log 'record: .*clean=1 .*the last boot.s safe fallback finished'; expect_log 'record: 1 clean fallback boot\(s\) after 1 failed attempt\(s\): the full desktop again'
                        expect_nolog 'safe desktop|kill switch'; expect_log 'SUCCESS at'; expect_rec fails=0; expect_rec last=full; expect_nofile "$FR/gpu/phxboot-off"
                        expect_killall; expect_no_reboot; go rec_return; }
# after 3 failures in a row: 3 clean safe desktop boots, then the full desktop
sc_rec_backoff() {      world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; rec_set fails=3 last=full
                        boot1; keep1 1; boot1; keep1 2; boot1; keep1 3
                        expect_cmd 'grep -q "stuck squat after a failed attempt (fails=3, clean fallback boots 0 of 3)" "$W/boot1.1.log"'
                        expect_cmd 'grep -q "the full desktop again after 2 more startups" "$W/boot1.1.log"'
                        expect_cmd 'grep -q "clean fallback boots 1 of 3" "$W/boot1.2.log"'; expect_cmd 'grep -q "clean fallback boots 2 of 3" "$W/boot1.3.log"'
                        expect_cmd 'grep -q "the full desktop again at the next startup" "$W/boot1.3.log"'
                        expect_nolog 'safe desktop'; expect_log 'SUCCESS at'; expect_rec fails=0; expect_no_reboot; go rec_backoff; }
# the retry fails again: the safe desktop again, no reboot (a stuck squat stays up); then the return after one more clean boot
sc_rec_retry_fails() {  world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; rec_set fails=1 clean=0 last=safe; SIM_METAL=0; boot1; keep1 1; SIM_METAL=1
                        expect_cmd 'grep -q "FAIL (Metal device never came up)" "$W/boot1.1.log"'; expect_cmd 'grep -q "stuck squat: no reboot after the failure" "$W/boot1.1.log"'
                        expect_cmd 'grep -q "record: fails=2 clean=0 .*last=full (FAIL: Metal device never came up)" "$W/boot1.1.log"'
                        expect_log 'stuck squat after a failed attempt \(fails=2, clean fallback boots 0 of 1\)'; expect_log 'safe desktop up'; expect_rec fails=2; expect_rec last=safe
                        expect_no_reboot; go rec_retry_fails; }
# a safe desktop that fails (here at the Metal device) is no clean fallback boot: the next boot is the safe desktop
# again, not the full desktop (the record's last= is not "safe" after the failure)
sc_rec_safe_fails() {   world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; rec_set fails=1 last=full; SIM_METAL=0; boot1; keep1 1; SIM_METAL=1
                        expect_cmd 'grep -q "safe desktop on the stuck squat" "$W/boot1.1.log"'; expect_cmd 'grep -q "FAIL (Metal device never came up)" "$W/boot1.1.log"'
                        expect_cmd 'grep -q "record: fails=2 clean=0 .*last=skip (FAIL: Metal device never came up)" "$W/boot1.1.log"'
                        expect_nolog 'fallback finished|the full desktop again$'; expect_log 'stuck squat after a failed attempt \(fails=2, clean fallback boots 0 of 1\)'
                        expect_log 'safe desktop up'; expect_nolog 'record: .*\(SUCCESS\)'; expect_rec fails=2; expect_rec clean=0; expect_rec last=safe; expect_no_reboot; go rec_safe_fails; }
# a GOP fallback boot whose NMXAccel did not start (or without PhxBringup) is no clean fallback boot either: after 3
# failures the next GOP boot is clean fallback boot 1 of 3, not 2; the record's fails stay (no desktop attempt failed)
sc_rec_gop_nmx() {      world; DESK=0; AUTOF=1; rec_set fails=3 last=full; SIM_NMXACCEL=0; boot1; keep1 1; SIM_NMXACCEL=1
                        expect_cmd 'grep -q "NMXAccel did not start (apps-only this boot)" "$W/boot1.1.log"'; expect_cmd 'grep -q "record: fails=3 clean=0 .*last=skip (NMXAccel did not start" "$W/boot1.1.log"'
                        expect_nolog 'gop fallback finished'; expect_log 'NOT re-armed: .*fails=3, this is clean fallback boot 1 of 3'; expect_rec fails=3; expect_rec clean=0; expect_no_reboot; go rec_gop_nmx; }
sc_rec_gop_nobringup(){ world; DESK=0; AUTOF=1; rec_set fails=3 last=full; SIM_BRINGUP=0; boot1; keep1 1; SIM_BRINGUP=1
                        expect_cmd 'grep -q "record: fails=3 clean=0 .*last=skip (PhxBringup not loaded" "$W/boot1.1.log"'
                        expect_nolog 'gop fallback finished'; expect_log 'NOT re-armed: .*fails=3, this is clean fallback boot 1 of 3'; expect_rec clean=0; expect_no_reboot; go rec_gop_nobringup; }
# 11-25 an old ~/gpu/phxboot-failed is taken over into the record once and removed
sc_rec_oldfailf() {     world; DESK=0; SIM_SQUAT=1; touch "$FR/gpu/phxboot-failed"; SIM_METAL=0; expect_log 'record: fails=1 .*phxboot-failed of an earlier daemon taken over'
                        expect_rec fails=2; expect_nofile "$FR/gpu/phxboot-failed"; expect_reboot; go rec_oldfailf; }
# a bring-up that fails (not the refusal) claims nothing: no claim, no NMXAccel, no allow list, no debug.phxagdc
sc_upfail_desk() {      world; upfail_stub "KIQ test failed" "$WDOFF"; expect_log 'bring-up failed: no claim, no Metal this boot \(navi31 not up: KIQ test failed \(the bring-up watchdog is cancelled'
                        expect_nolog 'claim: |NMXAccel|SUCCESS|FAIL \('; expect_nvram '-d phxfb-boot'; expect_writes 'debug.phxagdc' 0; no_allow
                        expect_log 'notice: Graphics acceleration failed to start. Your Mac will try again at the next startup.'
                        expect_rec fails=1; expect_rec bfail=1; expect_rec last=skip; X_NOMARK=1; expect_no_killall; expect_no_reboot; go upfail_desk; }
sc_upfail_nodesk() {    world; DESK=0; upfail_stub "scheduler failed" "$WDOFF"; expect_log 'bring-up failed: no claim'; expect_nolog 'claim: |NMXAccel|no desktop arm'
                        expect_rec bfail=1; X_NOMARK=1; expect_no_reboot; go upfail_nodesk; }
sc_upfail_stuck() {     world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; upfail_stub "bring-up failed" "$WDARM"
                        expect_log 'navi31 not up: bring-up failed \(the bring-up watchdog is still armed'; expect_log 'stuck squat: no display this boot \(no claim\) and no reboot by the daemon'
                        expect_nolog 'claim: |NMXAccel'; expect_rec bfail=1; X_NOMARK=1; expect_no_killall; expect_no_reboot; go upfail_stuck; }
sc_upfail_squat() {     world; DESK=0; SIM_SQUAT=1; AUTOF=1; upfail_stub "compute queue failed" "$WDOFF"; expect_log 'squat boot: rebooting onto IONDRV after the failed bring-up'
                        expect_nvram '-d phxfb-squat'; expect_nolog 'claim: |NMXAccel'; expect_file "$FR/gpu/phxboot-nvstuck"; expect_rec fails=1; expect_reboot; go upfail_squat; }
# a failure inside bringup_navi31.sh (its watchdog still armed) on a non-stuck squat: the squat cleared, the watchdog's
# restart left to the watchdog (no restart by the daemon), so the PSP / SMU / RLC keep their 3 minutes
sc_upfail_squat_armed(){ world; DESK=0; SIM_SQUAT=1; AUTOF=1; upfail_stub "bring-up failed" "$WDARM"; expect_log 'squat boot: phxfb-squat cleared, no reboot by the daemon: the bring-up watchdog restarts'
                        expect_nvram '-d phxfb-squat'; expect_nolog 'claim: |NMXAccel|rebooting onto IONDRV'; expect_cmd 'grep -qx pending "$FR/gpu/phxboot-nvstuck"'; expect_rec bfail=1; X_NOMARK=1; expect_no_reboot; go upfail_squat_armed; }
# the other refusal (C2PMSG_81 unreadable: phxctl / PhxBringup don't answer) is a failed bring-up, not the warm one
sc_upfail_unreadable(){ world; printf '#!/bin/bash\necho "refused: warm GPU check failed: C2PMSG_81 unreadable (PhxBringup service not found): no firmware loaded, nothing written"\necho "bring-up failed"\necho "navi31 not up: bring-up failed (nothing written by the power-up, no bring-up watchdog)"\nexit 1\n' >"$FR/gpu/phxctl/navi31_up.sh"
                        expect_log 'bring-up failed: no claim'; expect_nolog 'warm GPU: bring-up refused|claim: |NMXAccel|notice: The graphics card'; expect_rec bfail=1; expect_rec fails=1; X_NOMARK=1; expect_no_reboot; go upfail_unreadable; }
# the loop guard: the bring-up failed twice (its watchdog restarted the machine): the third boot does not touch the GPU,
# the fourth tries again
sc_upfail_loop() {      world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; upfail_stub "bring-up failed" "$WDARM"; boot1; keep1 1; boot1; keep1 2
                        expect_cmd 'grep -q "record: .*bfail=2 .*bring-up failed" "$W/boot1.2.log"'; expect_cmd 'grep -q "failed to start again. Your Mac will restart by itself within 3 minutes" "$W/boot1.2.log"'
                        expect_log 'bring-up skipped: it failed on the last 2 startups .*no bring-up watchdog, no restart.*the screen stays dark'; expect_nolog '== bring-up|claim: '
                        expect_log 'notice: Graphics acceleration is off for this startup because it failed to start the last 2 times'
                        expect_rec skipped=1; expect_rec last=skip; expect_no_reboot; go upfail_loop; }
sc_upfail_retry() {     world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; rec_set fails=2 bfail=2 last=skip; boot1; keep1 1
                        expect_cmd 'grep -q "bring-up skipped" "$W/boot1.1.log"'; expect_cmd '! grep -q "== bring-up" "$W/boot1.1.log"'
                        expect_log '== bring-up \+ claim =='; expect_log 'record: .*bfail=0 .*\(bring-up up\)'; expect_log 'safe desktop up'; expect_rec skipped=0; expect_no_reboot; go upfail_retry; }
# ~/gpu/phxboot-desktop is one desktop attempt: a failed bring-up uses it up (as m2_fail does), so the next boot is a GOP
# boot, not the same attempt again; the warm refusal keeps it (nothing was attempted: the cold boot after the power-off
# gets the desktop that was asked for)
sc_upfail_desk_oneshot(){ world; upfail_stub "KIQ test failed" "$WDOFF"; boot1; keep1 1; DESK=0; up_ok_stub
                        expect_cmd 'grep -q "bring-up failed: no claim" "$W/boot1.1.log"'; expect_cmd 'grep -q "phxboot-desktop used up" "$W/boot1.1.log"'
                        expect_log 'desktop-arm: 0'; expect_log 'no desktop arm: GOP'; expect_nolog 'SUCCESS'; expect_no_killall; expect_no_reboot; go upfail_desk_oneshot; }
sc_warm_desk_keeps() {  world; warm_stub; expect_log 'warm GPU: bring-up refused'; expect_log 'phxboot-desktop kept for the next boot'; expect_file "$FR/gpu/phxboot-desktop"; expect_no_reboot; go warm_desk_keeps; }
# a hang in the bring-up (the mark says bringup): counted as unfinished and as a failed bring-up
sc_bringup_hang() {     world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; echo bringup >"$FR/var/db/phxboot.pending"
                        expect_log 'record: fails=1 clean=0 bfail=1 .*did not finish \(stage bringup\)'; expect_log 'safe desktop up'; expect_rec bfail=0; expect_rec fails=1; expect_no_reboot; go bringup_hang; }
# the mark is set before the bring-up (with its stage), and cleared by a clean shutdown before the desktop attempt
sc_mark_early() {       world; printf '#!/bin/bash\ncat "$SIM_MARK" >"$SIM_STATE/mark_at_up" 2>/dev/null\necho "sOS check: C2PMSG_81=0x00000000 (cold)"\necho "navi31 up: compute + gfx queues ready"\n' >"$FR/gpu/phxctl/navi31_up.sh"
                        expect_cmd '[ "$(cat "$ST/mark_at_up")" = bringup ]'; expect_log 'SUCCESS'; X_NOMARK=1; go mark_early; }
# the TERM between the bring-up and the desktop attempt on a desktop boot (here in the NMXAccel wait) takes phxfb-boot
# back: before the claim PhxAMDFB hasn't consumed it, and it would take the panel at a later boot's claim
sc_term_claim_desk(){ world; SIM_NMXACCEL=0; SIM_TERM_LATE=1; SIM_SLEEP_REST=0.1; expect_log 'clean shutdown \(TERM\) at .* before the desktop attempt'
                        expect_nvram '-d phxfb-boot'; X_NOMARK=1; expect_no_reboot; go term_claim_desk; }
sc_term_bringup() {     world; DESK=0; SIM_NMXACCEL=0; SIM_TERM_LATE=1; SIM_SLEEP_REST=0.1; expect_log 'clean shutdown \(TERM\) at .* before the desktop attempt: in-progress mark cleared'
                        expect_nolog 'NMXAccel did not start'; X_NOMARK=1; expect_no_reboot; go term_bringup; }
# launchd's shutdown TERM while navi31_up.sh still runs (it takes about 10 s; launchd SIGKILLs after its exit timeout).
# term_up_stub <launchd's exit timeout s> <the bring-up's remaining s>: the stub sends the TERM to the daemon itself (the
# topmost process with the daemon's argv: a $(...) subshell has the same argv), a mock launchd SIGKILLs the daemon after
# the timeout (logged to sigkill.log, not launchd.log: here a SIGKILL is expected), then the bring-up ends.
term_up_stub(){ rm -f "$FR/gpu/phxctl/navi31_up.sh"   # a new file: an earlier boot's stub may still be reading the old one
  printf '#!/bin/bash\necho "== bring-up (PSP, SMU, RLC, RS64, doorbells, MEC)"\necho "sOS check: C2PMSG_81=0x00000000 (cold)"\nd=$PPID; a=$(ps -o args= -p $d); p=$(ps -o ppid= -p $d | tr -d " "); [ "$(ps -o args= -p $p)" = "$a" ] && d=$p; kill -TERM $d\n( /bin/sleep %s; kill -0 $d 2>/dev/null && { echo "SIGKILL after the exit timeout" >>"$SIM_STATE/sigkill.log"; kill -9 $d; } ) >/dev/null 2>&1 &\n/bin/sleep %s\necho "navi31 up: compute + gfx queues ready"\n' "$1" "$2" >"$FR/gpu/phxctl/navi31_up.sh"; chmod +x "$FR/gpu/phxctl/navi31_up.sh"; }
# a shutdown or restart during the bring-up is not a failed one: the trap runs at once (not after navi31_up.sh returns),
# clears the mark, and the next boot counts nothing, even though launchd SIGKILLs the daemon before the bring-up ends
sc_term_upwait() {      world; term_up_stub 0.2 0.8; boot1; keep1 1; rm -f "$FR/gpu/phxctl/navi31_up.sh"; up_ok_stub
                        expect_cmd 'grep -q "clean shutdown (TERM) at .* during the bring-up ([0-9]*s in): in-progress mark cleared" "$W/boot1.1.log"'
                        expect_cmd '[ -e "$ST/sigkill.log" ]'; expect_cmd '! grep -q "claim: " "$W/boot1.1.log"'
                        expect_nolog 'did not finish'; expect_log 'SUCCESS'; expect_rec fails=0; expect_rec bfail=0; expect_no_reboot; go term_upwait; }
# the bring-up ends before launchd's SIGKILL: still no claim, the daemon exits
sc_term_upwait_done(){  world; term_up_stub 5 0.2; expect_log 'clean shutdown \(TERM\) at .* during the bring-up'; expect_log 'the bring-up ended after the shutdown.s TERM: no claim'
                        expect_nolog 'claim: |NMXAccel|bring-up failed'; expect_nvram '-d phxfb-boot'; expect_cmd '! ls "$W"/phxboot-up.* >/dev/null 2>&1'
                        X_NOMARK=1; expect_no_killall; expect_no_reboot; go term_upwait_done; }
# the hang detection stays: a TERM that comes PHXBOOT_UP_HANG s (60) or more into the bring-up is the bring-up
# watchdog's restart of a hung bring-up (here UPHANG=0: any TERM), the mark stays and the next boot counts it
sc_term_uphang() {      world; UPHANG=0; term_up_stub 0.2 0.8; boot1; keep1 1; rm -f "$FR/gpu/phxctl/navi31_up.sh"; up_ok_stub
                        expect_cmd 'grep -q "TERM at .* after [0-9]*s of the bring-up .*a hung bring-up.*the in-progress mark stays" "$W/boot1.1.log"'
                        expect_log 'record: fails=1 clean=0 bfail=1 .*did not finish \(stage bringup\)'; expect_log 'previous attempt did not finish'; expect_no_reboot; go term_uphang; }
# Safe Mode: nothing at all (no bring-up, no kmutil load), the mark left for the next normal boot
sc_safeboot() {         world; SIM_SAFEBOOT=1; touch "$FR/var/db/phxboot.pending"; expect_log 'safe mode \(kern.safeboot 1\): no bring-up'; expect_nolog '== bring-up|squat boot|record:'
                        expect_cmd '[ ! -e "$ST/kmutil.log" ]'; expect_file "$FR/var/db/phxboot.pending"; expect_no_killall; expect_no_reboot; go safeboot; }
# Safe Mode on a squat boot has no picture (the squatter holds the framebuffer, no PhxAMDFB in Safe Mode; plan step 2).
# The daemon still touches nothing; it logs why and leaves a notice that the next normal boot shows after login
sc_safeboot_squat() {   world; DESK=0; SIM_SQUAT=1; SIM_SAFEBOOT=1; boot1; keep1 1; SIM_SAFEBOOT=0; SIM_LOGIN_AFTER_KILL=mockuser
                        expect_cmd 'grep -q "safe mode (kern.safeboot 1): no bring-up, nothing armed this boot; PhxFBSquatter holds the framebuffer .*no picture this boot" "$W/boot1.1.log"'
                        expect_cmd '! grep -qE "== bring-up|record:|nvram" "$W/boot1.1.log"'; expect_cmd '[ "$(grep -c "kmutil load" "$ST/kmutil.log")" = 1 ]'
                        expect_log "^notice: Safe Mode can't show a picture on this Mac yet, so the screen stayed dark. Start up normally instead.$"
                        expect_log 'notice: .* shown to mockuser'; expect_log 'SUCCESS'; go safeboot_squat; }
# m2_fail before the claim (PhxBringup not loaded): no Metal allow list, no debug.phxagdc; after it both, as before
sc_m2fail_noclaim() {   world; SIM_BRINGUP=0; expect_log 'FAIL \(PhxBringup not loaded\)'; no_allow; expect_writes 'debug.phxagdc' 0; expect_rec fails=1; expect_reboot; go m2fail_noclaim; }
sc_m2fail_claimed() {   world; SIM_METAL=0; expect_log 'FAIL \(Metal device never came up\)'; expect_cmd 'grep -q "test tools only" "$FR/Library/GPUBundles/nvmtl-allow.txt"'
                        expect_writes '^-w debug.phxagdc=0$' 1; expect_rec fails=1; expect_reboot; go m2fail_claimed; }
# the notice: shown once to the console user after login (launchctl asuser + osascript), or kept when nobody logs in
sc_notice_safe() {      world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; touch "$FR/var/db/phxboot.pending"; SIM_LOGIN_AFTER_KILL=mockuser
                        expect_log "notice: The display is in basic mode because the last startup didn't finish. Your Mac will try the full mode again at the next startup."
                        expect_log 'notice: .* shown to mockuser'; expect_cmd 'grep -q "^launchctl asuser 501 sudo -u mockuser /usr/bin/osascript .*display notification .*the last startup didn.t finish" "$ST/launchctl.log"'
                        expect_nofile "$FR/var/db/phxboot.notice"; expect_order 'safe desktop up' 'notice: The display'; expect_no_reboot; go notice_safe; }
sc_notice_nologin() {   world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; rec_set fails=1 last=full
                        expect_log 'notice: The display is in basic mode because graphics failed to start fully last time'; expect_log 'notice: nobody logged in within 6s: not shown'
                        expect_file "$FR/var/db/phxboot.notice"; expect_cmd '! grep -q asuser "$ST/launchctl.log"'; go notice_nologin; }
sc_notice_none() {      world; SIM_LOGIN_AFTER_KILL=mockuser; expect_log 'SUCCESS'; expect_nolog 'notice:'; expect_cmd '! grep -q asuser "$ST/launchctl.log"'; go notice_none; }
# 2026-11-25: a restart after a failure keeps the notice. The bring-up watchdog's restart (a failure inside
# bringup_navi31.sh) and m2_fail's leave one sentence for the next boot, which shows it after login unless it has its own
NNEXT='$FR/var/db/phxboot.notice-next'
sc_notice_carry_wd() {  world; DESK=0; SIM_SQUAT=1; AUTOF=1; upfail_stub "bring-up failed" "$WDARM"; boot1; keep1 1
                        rm -f "$FR/gpu/phxctl/navi31_up.sh"; up_ok_stub; SIM_SQUAT=0; SIM_USERS="mockuser console"
                        expect_cmd 'grep -q "notice: Graphics acceleration failed to start. Your Mac will restart by itself within 3 minutes." "$W/boot1.1.log"'
                        expect_cmd 'grep -q "notice for the next boot: Your Mac restarted because graphics acceleration failed to start." "$W/boot1.1.log"'
                        expect_log 'notice: the last boot left one for this boot'; expect_log 'no desktop arm: GOP'; expect_log 'one from an earlier boot was never shown: dropped'
                        expect_log '^notice: Your Mac restarted because graphics acceleration failed to start.$'; expect_log 'notice: .* shown to mockuser'
                        expect_cmd "[ ! -e $NNEXT ]"; expect_no_reboot; go notice_carry_wd; }
# after that restart the GPU is warm from the failed boot's own bring-up: the refusal's notice says so
sc_notice_carry_warm(){ world; DESK=0; SIM_SQUAT=1; AUTOF=1; upfail_stub "bring-up failed" "$WDARM"; boot1; keep1 1
                        rm -f "$FR/gpu/phxctl/navi31_up.sh"; warm_stub; SIM_SQUAT=0
                        expect_log "notice: Your Mac restarted because graphics acceleration failed to start. Shut down \(don.t restart\)"
                        expect_nolog 'another operating system'; expect_cmd "[ ! -e $NNEXT ]"; expect_no_reboot; go notice_carry_warm; }
# m2_fail's restart (a non-squat desktop boot): the GOP boot after it shows the notice
sc_notice_carry_m2() {  world; SIM_METAL=0; boot1; keep1 1; SIM_METAL=1; DESK=0; SIM_USERS="mockuser console"
                        expect_cmd 'grep -q "FAIL (Metal device never came up)" "$W/boot1.1.log"'; expect_cmd 'grep -q "notice for the next boot: Your Mac restarted" "$W/boot1.1.log"'
                        expect_log '^notice: Your Mac restarted because graphics acceleration failed to start.$'; expect_log 'notice: .* shown to mockuser'; go notice_carry_m2; }
# a boot with a notice of its own (the safe desktop) shows only that one
sc_notice_carry_own() { world; DESK=0; SIM_SQUAT=1; echo stuck >"$FR/gpu/phxboot-nvstuck"; touch "$FR/var/db/phxboot.pending"; echo "carried" >"$FR/var/db/phxboot.notice-next"
                        expect_log 'notice: the last boot left one for this boot'; expect_log "notice: The display is in basic mode because the last startup didn't finish"
                        expect_nolog '^notice: carried$'; expect_cmd "[ ! -e $NNEXT ]"; go notice_carry_own; }
# Safe Mode leaves it for the next normal boot
sc_notice_carry_safeboot(){ world; SIM_SAFEBOOT=1; echo "carried" >"$FR/var/db/phxboot.notice-next"; expect_nolog 'notice:'; expect_cmd "[ -e $NNEXT ]"; go notice_carry_safeboot; }
sc_notice_stale() {     world; echo "old" >"$FR/var/db/phxboot.notice"; expect_log 'notice: one from an earlier boot was never shown: dropped'; expect_nofile "$FR/var/db/phxboot.notice"; go notice_stale; }
# 11-23 thread 01: the display check. A latched engine after the WindowServer restart = dark: an engine capture, one clean
# restart (no SUCCESS); a second dark boot in a row stays up; a fall-back to 144 is reported, still SUCCESS; a clean boot
# removes the dark-restart record.
sc_disp_ok() {          world; expect_nolog 'DARK|display: '; expect_log 'SUCCESS'; expect_no_reboot; X_NOFILE="$FR/var/db/phxboot.darkrestart"; go disp_ok; }
sc_disp_dark() {        world; SIM_P0ODM=dark; expect_log 'DARK at .*: dark: the replay engine latched \(result=FAILED'; expect_log 'engine state saved to .*/hang/phxdark-'
                        expect_log 'recovery: one clean restart now'; expect_log 'DARK at .*the display engine did not'; expect_nolog 'SUCCESS'; expect_killall; expect_reboot
                        X_FILE="$FR/var/db/phxboot.darkrestart"; go disp_dark; }
sc_disp_dark_again() {  world; SIM_P0ODM=dark; echo "dark at earlier" >"$FR/var/db/phxboot.darkrestart"; expect_log 'dark again on the boot after a dark restart'
                        expect_nolog 'recovery: one clean restart'; expect_nolog 'SUCCESS'; expect_no_reboot; X_FILE="$FR/var/db/phxboot.darkrestart"; go disp_dark_again; }
sc_disp_pipe0_dark() {  world; SIM_P0_DARK=1; expect_log 'DARK at .*the pipe-0 engine latched dark \(last=dark why=the revert went dark\)'; expect_reboot; expect_nolog 'SUCCESS'; go disp_pipe0_dark; }
sc_disp_fellback() {    world; SIM_P0ODM=fb; expect_log 'display: fell back: result=FELL-BACK-TO-144'; expect_log 'SUCCESS'; expect_no_reboot
                        expect_log '^engine run 2 at '; expect_log '^  result=FELL-BACK-TO-144 '; expect_log '^  train_w1: plan=1440p60hdr-to .*tries=4'; go disp_fellback; }
sc_disp_log_once() {    world; SIM_P0ODM=fb; expect_cmd '[ "$(grep -c "^engine run " "$LOGF")" = 1 ]'; expect_log 'SUCCESS'; go disp_log_once; }
sc_disp_clears() {      world; echo "dark at earlier" >"$FR/var/db/phxboot.darkrestart"; expect_log 'SUCCESS'; expect_no_reboot; X_NOFILE="$FR/var/db/phxboot.darkrestart"; go disp_clears; }
sc_disp_dark_auto() {   world; SIM_P0ODM=dark; DESK=0; SIM_SQUAT=1; AUTOF=1; expect_log 'recovery: one clean restart now'; expect_reboot; expect_nolog 'SUCCESS'
                        expect_nvram 'set phxfb-squat=1'; X_NOMARK=1; go disp_dark_auto; }
ALL="term_claim_desk safeboot_squat notice_carry_wd notice_carry_warm notice_carry_m2 notice_carry_own notice_carry_safeboot term_upwait term_upwait_done term_uphang upfail_desk_oneshot warm_desk_keeps rec_gop_nmx rec_gop_nobringup rec_safe_fails upfail_squat_armed upfail_unreadable rec_no_killswitch rec_return rec_backoff rec_retry_fails rec_oldfailf upfail_desk upfail_nodesk upfail_stuck upfail_squat upfail_loop upfail_retry bringup_hang mark_early term_bringup safeboot m2fail_noclaim m2fail_claimed notice_safe notice_nologin notice_none notice_stale nodesk_failed_rearm disp_ok disp_dark disp_dark_again disp_pipe0_dark disp_fellback disp_log_once disp_clears disp_dark_auto squat_late fb_first squat_neither nodesk_rearm nodesk_failed nodesk_noauto fail_marks success_clears squat_happy squat_noauto squat_killswitch squat_mark squat_metal_fail squat_user squat_crash nodesk_no_boot_arm happy metal_stderr_guard metal_fail phxfb_fail nmxaccel_fail user_logged killswitch mark_recovery not_desktop crash_loop ws_norestart agdc_fail agdc_never agdc_late vcn_off vcn_up vcn_fail b15_off b15_on b15_missing b15_nodesk idledpm_off idledpm_on idledpm_missing idledpm_b15 idledpm_nodesk bovram_off bovram_on bovram_stfail bovram_ws bovram_bad bovram_empty bovram_oldkext bovram_nodesk gl_off gl_on gl_oldkext gl_fail gl_nodesk audio_off audio_on audio_dcfail audio_noplugin audio_missing audio_nodesk m7_off m7_on m7_light_fail m7_bind_fail m7_missing m7_no_late_smu m7_phase_ok_smu m7_light_fail_vcn aoc_off aoc_modes aoc_144flag term_in_watch squat_term_in_watch hotplug_off hotplug_on hotplug_bootarg hotplug_bootarg_like hotplug_fail hotplug_nohead1 hotplug_nom7 hotplug_nodesk gamma_off gamma_on gamma_pref_true gamma_pref_absent gamma_nocdpref gamma_busy gamma_busy_stuck gamma_fail gamma_nohead1 gamma_nodesk flags_both flags_term aocrate_off aocrate_144 aocrate_144_space aocrate_60 aocrate_last_60 aocrate_last_144 aocrate_last_none aocrate_last_bad aocrate_nolist aocrate_aoc144flag aocrate_nob15flags aocrate_nohead1 aocrate_unaligned aocrate_nom7 aocrate_old_accel aocrate_nmodes aocrate_b15_gone aocrate_set_fail aocrate_resync_bad aocrate_nodesk aocrate_user term_late_watch squat_term_late_watch term_late_restart term_late_arm squat_crash_shutdown_term ws_crash_oldkext gate_fix gate_session_race gate_cold_twice gate_bootarg gate_no_list gate_open_fails gate_resync_opens gate_late_oid gate_noresync_rate v4_race_repro v4_leftover v4_leftover_import_fail v4_leftover_moved dispovr_off dispovr_on dispovr_missing dispovr_fail dispovr_hang dispovr_real dispovr_real_twice one_aoc one_aoc_m7off one_aoc_no_solo one_aoc_refused one_aoc_noflag one_aoc_resync_bad two_unaligned_no_solo one_acer silent_crash_loop silent_crash_once late_silent late_logout dpwatch_off dpwatch_on dpwatch_empty dpwatch_l2 dpwatch_l2_old dpwatch_nooid dpwatch_badflag dpwatch_bootarg dpwatch_nodesk dpwatch_events dpwatch_fail_ev dpwatch_quiet dpwatch_unarmed_ev hp0_off hp0_on hp0_l2 hp0_badflag hp0_nooid hp0_bootarg hp0_nodesk hp0_fail b21_start b21_happy b21_user_true b21_user_false b21_gop b21_metal_fail b21_crash_loop b21_late_revert b21_shutdown b21_term_nocfp_false b21_term_nocfp_true b21_attempt_term b21_flag_off b21_flag_off_left b21_two_boots b21_off_fails prehook_desktop prehook_fail prehook_hang cdcopy_off cdcopy_on cdcopy_noasync cdcopy_nogp cdcopy_lcfail cdcopy_nodesk wstiled_off wstiled_on wstiled_lcfail wstiled_nodesk waitstep_off waitstep_on waitstep_empty waitstep_space waitstep_edges waitstep_low waitstep_high waitstep_bad waitstep_octal waitstep_huge waitstep_nooid waitstep_fail waitstep_nodesk waitstep_gp irqwait_off irqwait_on irqwait_fail irqwait_nooid irqwait_nodesk p0modes_off p0modes_on p0modes_oldkext p0modes_fail al_off al_on al_marker_stuck al_user_marker al_user_in al_nokc al_metal_fail al_shutdown al_b21off squat_kill_pending stuck_loop stuck_safe_hung stuck_after_headless stuck_cleared stuck_metal_fail stuck_crash stuck_failf stuck_full vrr_default vrr_off vrr_safe vrrmin_default vrrmin_on vrrmin_space vrrmin_edid vrrmin_bad vrrmin_low vrrmin_high vrrmin_octal vrrmin_empty vrrmin_nooid vrrmin_safe hdr_default hdr_off hdr_safe warm_desk warm_nodesk warm_squat warm_stuck sos_logged"
make_fakes; make_world_tpl
TORUN="${*:-$ALL}"
echo "== phxboot mock harness :: daemon=$DAEMON"
echo "== scratch=$SCR"
# PAR=<n> (default 2): the scenarios split round-robin over n background shards (each scenario a fresh world, as serial);
# each scenario's lines go to its own file, printed in scenario order once all are done. PAR=1 = the plain serial loop.
PAR=${PAR:-2}
if [ "$PAR" -gt 1 ]; then
  k=0; while [ $k -lt "$PAR" ]; do
    ( i=0; for s in $TORUN; do i=$((i+1)); [ $(( (i-1) % PAR )) = $k ] && sc_"$s" >"$SCR/par.$i" 2>&1; done; echo "$KEEP" >"$SCR/par.keep.$k" ) &
    k=$((k+1)); done; wait
  i=0; for s in $TORUN; do i=$((i+1)); cat "$SCR/par.$i"
    case "$(grep -E '^(PASS|FAIL)  ' "$SCR/par.$i" | head -1)" in PASS*) PASSN=$((PASSN+1));; FAIL*) FAILN=$((FAILN+1)); FAILED="$FAILED $s";;
      *) FAILN=$((FAILN+1)); FAILED="$FAILED $s"; echo "FAIL  $s (no result line)"; KEEP=1;; esac; done
  grep -qx 1 "$SCR"/par.keep.* 2>/dev/null && KEEP=1; rm -f "$SCR"/par.*
else
  for s in $TORUN; do sc_"$s"; done
fi
echo "-----------------------------------------------------------"
echo "RESULT: $PASSN passed, $FAILN failed${FAILED:+ (failed:$FAILED)}"
[ $FAILN = 0 ] && echo "ALL GREEN — daemon logic verified without a single reboot." || true
[ $KEEP = 1 ] && echo "(work dirs kept under $SCR)" || rm -rf "$SCR"
exit $([ $FAILN = 0 ] && echo 0 || echo 1)
