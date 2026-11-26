#!/bin/bash
# SPDX-License-Identifier: MIT
# Navi31 phxboot (LaunchDaemon local.phxboot): boot-time GPU bring-up + Metal claim, then (on a desktop-arm boot) it
# confirms PhxAMDFB took the panel and a LIVE Metal device exists, arms the display, and does ONE clean WindowServer
# restart so WindowServer enumerates Metal fresh (Cobalt64's proven ordering), 2026-10-24.
#
# TESTABLE BUILD: every path + HOME is env-overridable (PHXBOOT_*) with the production value as the default, so running
# it unchanged on the box behaves exactly as before, while the mock harness (tests/mock/run.sh) can redirect every
# path into a fake root and shim every external command via PATH. This file is meant to REPLACE the deployed
# ~/gpu/phxboot-navi31.sh after review (defaults == current production, so no behaviour change on the box).
#
# SQUAT MODE (2026-10-24): a boot where PhxBringup's PhxFBSquatter holds the IOFramebuffer category (armed by the
# one-shot NVRAM var phxfb-squat, which the kext clears at probe) has NO IONDRV console: PhxAMDFB is the only display,
# so that boot is the desktop-arm boot. SUCCESS re-arms phxfb-squat for the next boot unless $G/phxboot-auto-off exists;
# any failure (or kill switch / unfinished previous attempt) on a squat boot reboots, and the next boot comes up on
# IONDRV.
#
# Fail-safes: kill switch $OFF (the owner's); unfinished boot (MARK, from the bring-up on) -> GOP; any failure -> m2_fail
# reverts to GOP; the record $FAILS brings the full desktop back by itself after clean fallback boots. NO forced
# WindowServer kickstart (that wedged the GPU). Exactly ONE killall -9 WindowServer, only at 0 users, only at the end.
# Install layout (docs/INSTALL.md): the box tools live in ~/gpu of the desktop user, PHX_USER. The LaunchDaemon plist
# (local.phxboot.plist.in) sets PHX_USER; without it the owner of this script is taken (the install copies it as that user).
PHX_USER=${PHX_USER:-$(/usr/bin/stat -f %Su "$0" 2>/dev/null)}
if [ -z "${PHXBOOT_G:-}" ] || [ -z "${PHXBOOT_HOME:-}" ]; then
  PHX_UHOME=${PHX_UHOME:-$(/usr/bin/dscl . -read "/Users/$PHX_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')}
fi
G=${PHXBOOT_G:-${PHX_UHOME:-}/gpu}; export HOME=${PHXBOOT_HOME:-${PHX_UHOME:-}}
LOG=${PHXBOOT_LOG:-/var/log/phxboot.log}; MARK=${PHXBOOT_MARK:-/var/db/phxboot.pending}
OFF=${PHXBOOT_OFF:-$G/phxboot-off}; DESKTOP=${PHXBOOT_DESKTOP:-$G/phxboot-desktop}
# Failure marker of the daemons before 2026-11-25 (11-02: every revert to GOP left it, removed only by hand or a SUCCESS).
# The record $FAILS replaces it; one left by an earlier daemon is taken over at the start and removed.
FAILF=${PHXBOOT_FAILF:-$G/phxboot-failed}
ALLOW=${PHXBOOT_ALLOW:-/Library/GPUBundles/nvmtl-allow.txt}; DR=${PHXBOOT_DR:-/Library/Logs/DiagnosticReports}
MB=${PHXBOOT_MB:-/usr/local/sbin/mesboot}
PHXCTL=${PHXBOOT_PHXCTL:-/usr/local/sbin/phxctl}
ACCEL=${PHXBOOT_ACCEL:-/Library/Extensions/VermilionAccel.kext}; RUNAS=${PHXBOOT_RUNAS-sudo -u $PHX_USER}
LOGCMD=${PHXBOOT_LOGCMD:-/usr/bin/log}
exec >>"$LOG" 2>&1
echo "== $(date '+%F %T') phxboot(navi31, Option 1b)"
# Pre-start hook (2026-11-19): $G/phxboot-pre.sh, when present, runs first, as root, with $G as its argument and its
# output in this log, before any flag is read. The XTX machine uses it to take flag files staged on the EFI partition
# from Linux (tools/phxctl/esp_flags.sh), because Linux cannot write APFS. It gets PHXBOOT_PRE_WAIT seconds (default
# 30); a hook still running then is killed and the boot goes on. A failing hook is logged and changes nothing else.
PRE=${PHXBOOT_PRE:-$G/phxboot-pre.sh}
if [ -f "$PRE" ]; then
  bash "$PRE" "$G" & prep=$!; prend=$(( $(date +%s) + ${PHXBOOT_PRE_WAIT:-30} ))
  while kill -0 $prep 2>/dev/null && [ "$(date +%s)" -lt $prend ]; do sleep 1; done
  if kill -0 $prep 2>/dev/null; then kill -9 $prep 2>/dev/null; wait $prep 2>/dev/null; echo "pre-hook: $PRE still running after ${PHXBOOT_PRE_WAIT:-30}s: killed"
  else wait $prep; prerc=$?; [ $prerc = 0 ] || echo "pre-hook: $PRE exit $prerc"; fi
fi
# Feature switches (2026-11-26, docs/INSTALL.md 7.3): every proven feature is ON by default, as on the XTX machine; the
# file ~/gpu/phxboot-<name>-off turns one off (the scheme of ws-gpu-present-off). The old opt-in file ~/gpu/phxboot-<name>
# is redundant now and never an opt-out: at most one "note:" line per file per boot says so ($OLD_OPT_INS; nohdr is in
# the list because HDR is off without it too). Value files keep their meaning: phxboot-waitstep, phxboot-bovram and
# phxboot-vrrmin hold a value that replaces the built-in one, so they get no note.
# Not switches (unchanged): state files (phxboot-nvstuck, phxboot-safe, the pending mark, the fails record, rate-last),
# the kill switch phxboot-off, and the flags that stay opt-in by design: phxboot-autologin (never an automatic login by
# default), phxboot-m7* (the second monitor), phxboot-b15*, phxboot-hdr (HDR is broken in this preview), diagnostics,
# and everything the XTX machine does not run.
feat_on(){ [ ! -e "$G/phxboot-$1-off" ]; }
OLD_OPT_INS="auto sdma cg uclk vcn idledpm idledpm-dcf irqwait p0modes gl audio wscdcopy nohdr"
old_notes(){ local n
  for n in $OLD_OPT_INS; do
    [ -e "$G/phxboot-$n" ] && [ ! -e "$G/phxboot-$n-off" ] && echo "note: ~/gpu/phxboot-$n is no longer needed (on by default)"
  done; return 0; }
old_notes
# First-WindowServer crash fix (11-03).
# The first WindowServer (up since boot, started before any display pipe existed) restores the stored one-display set as
# soon as the arm below publishes the display pipe (debug.nvaccel_iop/nvaccelfb=1). Since 11-01 that set is "AOC alone"
# at IODisplayModeID 2 (144 Hz); PhxAMDFB refuses id 2 while the pipe-0 kill switch is on, the refused switch still runs
# WillChange/DidChange, the pipe's framebuffer resource is rebuilt and that WindowServer's software blit writes through a
# failed CPU lock (NULL): SIGSEGV on almost every boot, mostly with no .ips.
# The stored sets cannot be kept away from that WindowServer: it reads com.apple.windowserver once, before this daemon runs,
# and every display change of a logged-in session copies the user's own DisplaySets (with "AOC
# alone" at 144) into DisplayAnyUserSets at once (SkyLight WSSaveServerWidePreferences). So the
# fix is PhxAccel's head-0 offer gate (src/vermilion-accel/accel/phxoffer.h): with a head-0 mode list, head 0 offers only the
# lit mode from its start, the stored 144 set matches nothing and the first WindowServer keeps the current mode; this daemon
# opens the gate (debug.phxfb0_offer=1, which also drops CoreDisplay's IOFBConfig cache) just before its ONE restart, so the
# restarted WindowServer lists every mode. The v4 prefs edits are gone; a v4 stash left on disk is put back once.
WSPFLAG=${PHXBOOT_WSPFLAG:-$G/phxboot-wsprefs}; WSPDOM=${PHXBOOT_WSPDOM:-/Library/Preferences/com.apple.windowserver}
WSPSTASH=${PHXBOOT_WSPSTASH:-$G/phxboot-wsprefs.stash.d}; WSPTMP=${PHXBOOT_WSPTMP:-/tmp}; PB=${PHXBOOT_PLISTBUDDY:-/usr/libexec/PlistBuddy}
wsp_val(){ "$PB" -c "Print :DisplayAnyUserSets:$2:0:$3" "$1" 2>/dev/null; }      # <plist> <set index> <entry key>
wsp_has(){ "$PB" -c "Print :DisplayAnyUserSets:$2" "$1" >/dev/null 2>&1; }
wsp_one(){ wsp_has "$1" "$2:0" && ! wsp_has "$1" "$2:1"; }                          # a one-display set
wsp_export(){ rm -f "$1"; defaults export "$WSPDOM" "$1" >/dev/null 2>&1 && [ -s "$1" ]; }
# v4 leftover (daemon 04c751b1 kept the user's one-display values in $WSPSTASH/<DisplayID>): put them back into the live
# one-display set of that display still at the neutral id 1, once; a stash file whose set is not found stays
wsp_restore(){ ls "$WSPSTASH"/* >/dev/null 2>&1 || return 0
  local cur="$WSPTMP/phxboot-wsprefs-r.$$.plist" j sf d f n=0 k v
  wsp_export "$cur" || { echo "wsprefs: restore ($1): cannot export $WSPDOM: values kept"; rm -f "$cur"; return 1; }
  for sf in "$WSPSTASH"/*; do d=${sf##*/}; case "$d" in *.new) continue;; esac; f=""; j=0
    while wsp_has "$cur" $j; do
      wsp_one "$cur" $j && [ "$(wsp_val "$cur" $j DisplayID)" = "$d" ] && [ "$(wsp_val "$cur" $j Mode:IODisplayModeID)" = 1 ] && { f=$j; break; }
      j=$((j+1)); done
    if [ -z "$f" ]; then echo "wsprefs: restore ($1): no live one-display set of display $d at id 1: left as is, values kept"; continue; fi
    while IFS=$'\t' read -r k v; do [ -n "$k" ] && "$PB" -c "Set :DisplayAnyUserSets:$f:0:$k $v" "$cur"; done <"$sf"
    n=$((n+1)); echo "$sf" >>"$cur.done"; done
  if [ $n -gt 0 ] && ! defaults import "$WSPDOM" "$cur"; then echo "wsprefs: restore ($1): import failed: values kept"; rm -f "$cur" "$cur.done"; return 1; fi
  [ -e "$cur.done" ] && while read -r sf; do rm -f "$sf"; done <"$cur.done"
  rmdir "$WSPSTASH" 2>/dev/null
  echo "wsprefs: $(date '+%T') restored $n set(s) ($1)"
  rm -f "$cur" "$cur.done"; sync; }
# the WindowServer pid (the first one is up since boot; a change before the restart = it died, usually with no .ips)
wspid(){ pgrep -x WindowServer 2>/dev/null | head -1; }
# head 0's offer gate (PhxAccel phxoffer.h): 0 = only the lit mode offered, 1 = every mode, "" = no such oid.
# PhxAMDFB registers debug.phxfb0_offer at the END of its start (the gate itself is decided before IOFramebuffer::start),
# seconds after `ioreg` already shows PhxAMDFB (an early probe read "absent"), so the gate is read and opened
# only right before the restart, after a wait for the oid; the write runs whatever a resync did (the kernel ignores a second
# opening) and must read back 1.
offer_state(){ sysctl -n debug.phxfb0_offer 2>/dev/null; }
offer_open(){ local st out i opens0
  for ((i=0; i<${PHXBOOT_OFFER_WAIT:-10}; i++)); do st=$(offer_state); [ -n "$st" ] && break; nap 1; done
  case "$st" in
    0|1) ;;
    *) echo "head-0 offer gate: absent after ${PHXBOOT_OFFER_WAIT:-10}s (PhxAccel without debug.phxfb0_offer: the first WindowServer may have restored a stored 144 set)"; return 0;; esac
  opens0=$(sysctl -n debug.phxfb0_offer_opens 2>/dev/null)
  out=$(sysctl -w debug.phxfb0_offer=1 2>&1)
  if [ "$(offer_state)" = 1 ]; then
    if [ "$st" = 0 ]; then echo "head-0 offer gate open (was closed; debug.phxfb0_offer=1, IOFBConfig dropped): the restarted WindowServer lists every head-0 mode"
    else echo "head-0 offer gate open (verified; already opened before the restart: ${opens0:-?} opening(s) by a resync, or -phxfb0open / no head-0 list)"; fi
  else echo "head-0 offer gate: debug.phxfb0_offer=1 FAILED (state ${st}, now $(offer_state); $(echo "$out" | tail -1 | cut -c1-100)): the restarted WindowServer lists only the lit mode"; fi; }
# rotation rot15 (11-03): a display override per connected display with
# default-resolution 0x0 @255 Hz, so CoreDisplay's default at a display set it never saw (a first rotation, a new cable
# layout) is the highest rate instead of the mode under 86 Hz; with it PhxAccel needs no verticalBlankingExtension rate
# marks (they made System Settings show "Variable (0-N Hertz)"). Flag ~/gpu/phxboot-dispovr; the tool only writes or
# refreshes files it wrote itself (key phx-override) and never touches another override.
# Never blocks the restart: a missing tool or a failed write is logged, and a tool still running
# after PHXBOOT_DISPOVR_WAIT s (10; it only reads ioreg and writes a few small files) is killed and the boot goes on.
DISPOVR=${PHXBOOT_DISPOVR:-$G/dispovr.sh}
disp_ovr(){ [ -e "$G/phxboot-dispovr" ] || return 0
  [ -x "$DISPOVR" ] || [ -r "$DISPOVR" ] || { echo "dispovr: $DISPOVR missing (flag set): no display overrides"; return 0; }
  local out="$WSPTMP/phxboot-dispovr.$$.log" p end rc
  rm -f "$out"; sh "$DISPOVR" >"$out" 2>&1 & p=$!
  end=$(( $(date +%s) + ${PHXBOOT_DISPOVR_WAIT:-10} ))   # wall clock (not a count of naps)
  while kill -0 $p 2>/dev/null && [ "$(date +%s)" -lt $end ]; do nap 1; done
  if kill -0 $p 2>/dev/null; then kill -9 $p 2>/dev/null; wait $p 2>/dev/null; sed 's/^/  /' "$out" 2>/dev/null
    echo "dispovr: $DISPOVR still running after ${PHXBOOT_DISPOVR_WAIT:-10}s: killed, the restart goes on"; rm -f "$out"; return 0; fi
  wait $p; rc=$?; sed 's/^/  /' "$out" 2>/dev/null; rm -f "$out"
  [ $rc = 0 ] || echo "dispovr: $DISPOVR exit $rc: some overrides not written, the restart goes on"; return 0; }
release(){ sysctl -w debug.phxfb_hold=0 >/dev/null 2>&1; }
apps_only(){ printf '# phxboot: Metal for test tools only\n' > "$ALLOW"; }
DENY="mediaanalysisd photoanalysisd Spotlight Dock"   # NotificationCenter allowed again 2026-10-26 (BIG_PAGE fix); iconservicesagent allowed 2026-10-26: its "?" icons were cold shader compiles, not broken rendering
all_apps(){ { printf '# phxboot: Metal for every app%s\n' "$1"; for d in $DENY; do printf -- '-%s\n' "$d"; done; printf '*\n'; [ -z "$2" ] || printf '%s\n' "$2"; } > "$ALLOW"; }
# the one-shots of a desktop attempt off: PhxAMDFB's panel take-over, the squat for the next boot, the in-progress mark,
# the desktop arm file
oneshots_off(){ nvram -d phxfb-boot; nvram -d phxfb-squat; rm -f "$MARK" "$DESKTOP"; sync; }
# Failure record (2026-11-25, phase 2 item 3 step 1; .agents/findings/2026-11-25-recovery-trap-design.md). Root-owned,
# next to the in-progress mark, written only by this daemon. It replaces the daemon's own latches: the kill switch $OFF
# it used to create after an unfinished attempt (now the owner's switch alone) and $FAILF (taken over once, below).
#   fails=  failed or unfinished attempts in a row (a full SUCCESS sets 0)
#   clean=  fallback boots (safe desktop, GOP) that finished since the last failure; counted at the next boot's start,
#           when no in-progress mark is left, so a fallback that froze does not count
#   bfail=  bring-up failures in a row (navi31_up.sh without "navi31 up:"; a hang in the bring-up counts too)
#   skipped=1 the last boot skipped the bring-up (bfail >= 2): this boot tries again
#   last=   what the last boot ran: full, safe, gop or skip (no bring-up, one that failed, or a fallback that failed:
#           only a safe or gop boot that ended without a failure counts as a clean fallback boot)
# The return: with fails > 0 the next boot after REC_NEED clean fallback boots tries the full desktop again. REC_NEED is
# 1, and 3 once 3 attempts in a row failed. One clean boot shows that the machine and the plain path work; the failures
# seen so far on the XTX machine (the 2026-11-24 freeze, the HDR freeze) did not repeat on the next attempt. A failure
# that does repeat then costs every second boot, and after 3 in a row every fourth, never every boot and never a manual
# rm. No path here adds a reboot: a failed retry falls back the same way as the first failure.
FAILS=${PHXBOOT_FAILS:-/var/db/phxboot.fails}
REC_F=0; REC_C=0; REC_B=0; REC_S=0; REC_L=none; REC_SAVED=""
rec_num(){ case "$1" in [0-9]|[0-9][0-9]) echo "$1";; *) echo 0;; esac; }
rec_load(){ local k v
  [ -r "$FAILS" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in fails) REC_F=$(rec_num "$v");; clean) REC_C=$(rec_num "$v");; bfail) REC_B=$(rec_num "$v");;
      skipped) REC_S=$(rec_num "$v");; last) case "$v" in full|safe|gop|skip) REC_L=$v;; esac;; esac
  done <"$FAILS"
  REC_SAVED=$(rec_text); }
rec_text(){ printf 'fails=%s clean=%s bfail=%s skipped=%s last=%s' "$REC_F" "$REC_C" "$REC_B" "$REC_S" "$REC_L"; }
rec_save(){ local t; t=$(rec_text); [ "$t" = "$REC_SAVED" ] && return 0
  printf '%s\n' $t >"$FAILS.new" && mv -f "$FAILS.new" "$FAILS"; sync; REC_SAVED=$t; echo "record: $t ($1)"; }
rec_need(){ if [ "$REC_F" -ge 3 ]; then echo 3; else echo 1; fi; }
inc(){ local v=$(( $1 + 1 )); [ $v -gt 99 ] && v=99; echo $v; }
# a failed attempt. A fallback boot (safe desktop, GOP) that fails is no clean fallback boot: last=skip, so the next
# boot does not count it as one (it would try the full desktop at once)
rec_fail(){ REC_F=$(inc "$REC_F"); REC_C=0; case "$REC_L" in safe|gop) REC_L=skip;; esac; rec_save "$1"; }
# when the full desktop comes back, said from this boot's point of view (this boot, once it finishes, is one more clean one)
rec_when(){ local left=$(( $(rec_need) - REC_C - 1 ))
  if [ $left -le 0 ]; then echo "at the next startup"; elif [ $left = 1 ]; then echo "after 1 more startup"; else echo "after $left more startups"; fi; }
# Notice (2026-11-25): one plain sentence to the user after login, as a notification of the logged-in user (no dialog,
# nothing waits for it), and its "notice:" line here. $NOTICE holds it until it was shown; one left from an earlier boot
# is dropped at the start (it was about that boot). Waits up to PHXBOOT_NOTICE_WAIT s (900) for a console user, in the
# background (PHXBOOT_NOTICE_FG=1, the mocks: in the foreground), so a daemon that keeps running (the safe desktop)
# goes on; notice_join waits for it before an exit, since launchd ends the job's other processes when the daemon exits.
# Shown through launchctl asuser + sudo -u, so it runs in the user's session as the user (unverified on hardware).
NOTICE=${PHXBOOT_NOTICE:-/var/db/phxboot.notice}; NOTICEPID=""; NOTICED=0
# A restart after a failure (the bring-up watchdog's, m2_fail's, the hang watch's) comes before most logins, and the next
# boot drops this boot's notice. So such a boot also leaves one sentence for the next boot in $NOTICE_NEXT. The next boot
# takes it at its start (after the Safe Mode exit: Safe Mode leaves it) and shows it after login unless it has a notice
# of its own (which then says more); a warm refusal words its own with it. One boot only: not shown, it is dropped then.
NOTICE_NEXT=${PHXBOOT_NOTICE_NEXT:-/var/db/phxboot.notice-next}; CARRY=""
RESTARTED="Your Mac restarted because graphics acceleration failed to start."
notice_show(){ local u="" uid t=0 w=${PHXBOOT_NOTICE_WAIT:-900}
  while [ $t -lt $w ]; do u=$(who 2>/dev/null | awk '$2=="console"{print $1; exit}'); [ -n "$u" ] && break; sleep 3; t=$((t+3)); done
  [ -n "$u" ] || { echo "notice: nobody logged in within ${w}s: not shown (kept in $NOTICE)"; return 0; }
  uid=$(id -u "$u" 2>/dev/null) || { echo "notice: no uid for '$u': not shown (kept in $NOTICE)"; return 0; }
  sleep 3   # the desktop of the login first
  if launchctl asuser "$uid" sudo -u "$u" /usr/bin/osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Graphics"' -e 'end run' "$(cat "$NOTICE" 2>/dev/null)" >/dev/null 2>&1
  then rm -f "$NOTICE"; echo "notice: $(date '+%T') shown to $u"
  else echo "notice: $(date '+%T') could not be shown to $u (osascript failed): kept in $NOTICE"; fi; }
notice(){ NOTICED=1; printf '%s\n' "$1" >"$NOTICE"; sync; echo "notice: $1"
  if [ "${PHXBOOT_NOTICE_FG:-0}" = 1 ]; then notice_show; else notice_show & NOTICEPID=$!; fi; }
notice_join(){ [ -n "$NOTICEPID" ] && wait "$NOTICEPID" 2>/dev/null; NOTICEPID=""; return 0; }
notice_next(){ printf '%s\n' "$1" >"$NOTICE_NEXT"; sync; echo "notice for the next boot: $1"; }   # right before a restart
notice_carry(){ [ -n "$CARRY" ] && [ "$NOTICED" = 0 ] && notice "$CARRY"; CARRY=""; return 0; }   # the last boot's notice, if this boot has none
bye(){ notice_carry; notice_join; exit 0; }   # an exit before or instead of the desktop: the notice shown
leave(){ release; bye; }                      # the same, with the hold off
CLAIMED=0   # 1 once mesboot claim ran: PhxAMDFB and NMXAccel may be up, Metal may be on the GPU
# revert to a safe GOP boot: drop the panel/arm, consume the one-shots, reboot.
# The clean-shutdown TERM trap is dropped first: the TERM of the reboot below must not run it (it would log a clean
# shutdown and re-arm phxfb-squat after a failure). The Metal allow list and debug.phxagdc=0 only after the claim: before
# it nothing runs on the GPU and the oid does not exist (PhxAMDFB registers it at the end of its start).
m2_fail(){ trap - TERM; echo "FAIL ($1): reverting to GOP"; b21_on "FAIL: the next boot is GOP"; rec_fail "FAIL: $1"
           if [ "$CLAIMED" = 1 ]; then apps_only; sysctl -w debug.phxagdc=0 >/dev/null 2>&1; fi
           oneshots_off
           # a stuck squat (below) would come straight back here: stay up instead; the next boot runs the safe desktop
           [ "${SQUAT:-0}" = 1 ] && { squat_reboot "squat boot: rebooting onto IONDRV" "$RESTARTED" || { echo "stuck squat: no reboot after the failure (it would come back to the squat)"
             notice "Graphics acceleration failed to start this time. Your Mac will try again when it restarts."; leave; }; }
           notice_next "$RESTARTED"; shutdown -r now; exit 0; }
# Login-window guard (11-04): a WindowServer without Metal (the first
# one of every boot until the restart below, or the only one of a GOP boot) aborts in QuartzCore CA::OGL push_surface when
# loginwindow draws the Memoji lock-screen avatar. SHOWFULLNAME true (name + password fields) avoids the avatar. loginwindow
# starts ~1 s before this daemon, so the key must already be true when the box goes down: ON at a shutdown TERM, at every
# revert to GOP and at the daemon's start (that covers a loginwindow restarted after a crash this boot; after an unclean
# shutdown the first loginwindow still reads the session value). OFF only right before the Metal WindowServer restart, back
# to the value the user had (absent = delete, the user's own true stays true), kept in $B21ORIG between ON and OFF.
# ~/gpu/phxboot-b21guard holding 0 = the key is never touched. At a shutdown TERM `defaults` may not reach cfprefsd (the v4
# `defaults export` at TERM returned no sets 3/3), so the plist file is the fallback for both
# the read of the user's value and the write.
LWDOM=${PHXBOOT_LWDOM:-/Library/Preferences/com.apple.loginwindow}; B21ORIG=${PHXBOOT_B21ORIG:-$G/phxboot-b21guard.orig}
b21_ok(){ [ "$(tr -d ' \t\r\n' 2>/dev/null <"$G/phxboot-b21guard")" != 0 ]; }   # 2> first: a missing flag file prints nothing
b21_cfp(){ defaults read "$LWDOM" SHOWFULLNAME 2>/dev/null || echo absent; }               # what loginwindow reads
b21_file(){ "$PB" -c "Print :SHOWFULLNAME" "$LWDOM.plist" 2>/dev/null || echo absent; }    # the plist on disk
# Automatic login (2026-11-20, owner): macOS's autologin would log the user in before this daemon's arm, and the arm
# refuses with a user logged in (no accelerated desktop). So the daemon owns loginwindow's autoLoginUser: deleted wherever the
# login-window guard goes ON (daemon start, shutdown TERM, every revert to GOP), written right before the Metal WindowServer
# restart, so the accelerated loginwindow logs the user in. ~/gpu/phxboot-autologin holds the user name; /etc/kcpassword (made
# once by `sysadminctl -autologin set`) holds the password. Either missing = the key is only ever deleted (password login).
KCPW=${PHXBOOT_KCPASSWORD:-/etc/kcpassword}; LWRAN=${PHXBOOT_LWRAN:-/private/var/run/com.apple.loginwindow.didRunThisBoot}
al_user(){ tr -d ' \t\r\n' 2>/dev/null <"$G/phxboot-autologin"; }
al_off(){ [ -e "$G/phxboot-autologin" ] || return 0
  defaults delete "$LWDOM" autoLoginUser >/dev/null 2>&1
  "$PB" -c "Delete :autoLoginUser" "$LWDOM.plist" >/dev/null 2>&1   # the plist too (cfprefsd may be gone at a TERM)
  sync; echo "autologin: $(date '+%T') off ($1): autoLoginUser removed, a password login unless the daemon turns it on"; }
al_on(){ [ -e "$G/phxboot-autologin" ] || return 0
  local u; u=$(al_user)
  [ -n "$u" ] || { echo "autologin: ~/gpu/phxboot-autologin is empty: no automatic login"; return 0; }
  [ -s "$KCPW" ] || { echo "autologin: $KCPW missing (run sysadminctl -autologin set once): no automatic login"; return 0; }
  defaults write "$LWDOM" autoLoginUser "$u" >/dev/null 2>&1
  # 2026-11-24: loginwindow autologins only on its first run of the boot (FirstRunKey in the authref), and it decides that
  # from $LWRAN, which the boot's first loginwindow creates. The loginwindow relaunched by the restart below found it and
  # showed the password prompt. Removing it makes that relaunched loginwindow the "first run"; it re-creates the file at
  # once, so any later loginwindow this boot (a crash of the Metal WindowServer) still asks for the password: no loop.
  rm -f "$LWRAN" 2>/dev/null
  echo "autologin: $(date '+%T') on for '$u' before the Metal WindowServer restart (reads '$(defaults read "$LWDOM" autoLoginUser 2>/dev/null)'; first-run marker $([ -e "$LWRAN" ] && echo "STILL PRESENT: password prompt likely" || echo removed))"; }
b21_on(){ al_off "$1"
  b21_ok || return 0
  local was o rec=earlier rc f how=""
  was=$(b21_cfp)
  if [ -e "$B21ORIG" ]; then o=$(cat "$B21ORIG")
  else o=$was; [ "$o" = absent ] && { o=$(b21_file); case "$o" in true) o=1;; false) o=0;; esac; }
    echo "$o" >"$B21ORIG"; rec=now; fi
  defaults write "$LWDOM" SHOWFULLNAME -bool true >/dev/null 2>&1; rc=$?
  f=$(b21_file); [ "$f" = true ] || { "$PB" -c "Set :SHOWFULLNAME true" "$LWDOM.plist" >/dev/null 2>&1 || "$PB" -c "Add :SHOWFULLNAME bool true" "$LWDOM.plist" >/dev/null 2>&1
    how=", file was $f: written directly, now $(b21_file)"; }
  sync; echo "b21guard: $(date '+%T') ON ($1): SHOWFULLNAME was '$was', set true (defaults rc $rc$how); the user's value '$o' recorded $rec"; }
b21_off(){ b21_ok || return 0
  [ -e "$B21ORIG" ] || { echo "b21guard: $(date '+%T') OFF skipped: no recorded user value ($B21ORIG): SHOWFULLNAME stays '$(b21_cfp)'"; return 0; }
  local o rc=0 want now
  o=$(cat "$B21ORIG")
  case "$o" in
    absent) defaults delete "$LWDOM" SHOWFULLNAME >/dev/null 2>&1; rc=$?; want=absent;;
    1|true|YES|yes) want=1;;    # the user's own true: never removed
    *) defaults write "$LWDOM" SHOWFULLNAME -bool false >/dev/null 2>&1; rc=$?; want=0;;
  esac
  now=$(b21_cfp)
  if [ "$now" = "$want" ]; then rm -f "$B21ORIG"; sync
    echo "b21guard: $(date '+%T') OFF before the Metal WindowServer restart: SHOWFULLNAME back to the user's '$o' (rc $rc, reads '$now'): avatar on the accelerated login"
  else echo "b21guard: $(date '+%T') OFF FAILED: SHOWFULLNAME reads '$now', not the user's '$o' (rc $rc): name + password this login, the user's value kept in $B21ORIG"; fi; }
if b21_ok; then b21_on "daemon start"
else al_off "daemon start";  echo "b21guard: off (~/gpu/phxboot-b21guard = 0): SHOWFULLNAME not managed$([ -e "$B21ORIG" ] && echo " (a guard ON left by an earlier boot stays: the user's value '$(cat "$B21ORIG")' is in $B21ORIG)")"; fi
[ -e "$NOTICE" ] && { rm -f "$NOTICE"; echo "notice: one from an earlier boot was never shown: dropped"; }
# Squat detection (11-02): poll until PhxFBSquatter (squat boot) or an
# IOFramebuffer (IONDRV/GOP boot) appears, up to 60 s. The old one-shot check ran before the squatter attached on fast
# boots (no -v: the daemon starts ~4 s after the kernel), read 0, and wait_fb then waited 90 s for a framebuffer the
# squatter blocks: the Apple logo stayed (22:46 / 22:58 11-02, misread as a lost NVRAM write).
SQUAT=0; SQWHY="neither in ${PHXBOOT_SQUAT_WAIT:-60}s"
for ((sq=0; sq<${PHXBOOT_SQUAT_WAIT:-60}; sq++)); do
  ioreg -rc PhxFBSquatter -d0 | grep -q PhxFBSquatter && { SQUAT=1; SQWHY="PhxFBSquatter after ${sq}s"; break; }
  ioreg -rc IOFramebuffer -d0 | grep -q 'class ' && { SQWHY="IOFramebuffer after ${sq}s"; break; }
  sleep 1
done
# Safe Mode (Shift at startup; XNU's -x, kern.safeboot 1): no bring-up, no kmutil load, nothing armed, the record and the
# in-progress mark left for the next normal boot. A Mac in Safe Mode runs without its third-party drivers too. The
# squat detection above (ioreg reads only) runs first, for this: a squat boot in Safe Mode has no picture. VermilionBoot
# (OSBundleRequired Root) loads in Safe Mode and PhxFBSquatter squats whenever phxfb-squat is set (it has no -x check),
# so IONDRV never starts, and PhxAMDFB, in VermilionAccel in the AuxKC, which Safe Mode doesn't load (unverified), never
# takes the screen. Nothing in the running boot can give it back: `release` is PhxAMDFB's own hold (debug.phxfb_hold),
# not the squat, and terminating the squatter hot-resets the GPU (hard rule 1). The fix is VermilionBoot not squatting
# with -x (.agents/findings/2026-11-25-recovery-trap-design.md, plan step 2). Until then the log says so, and the next
# normal boot tells the user why the screen stayed dark.
if [ "$(sysctl -n kern.safeboot 2>/dev/null)" = 1 ]; then
  if [ $SQUAT = 1 ]; then
    echo "safe mode (kern.safeboot 1): no bring-up, nothing armed this boot; PhxFBSquatter holds the framebuffer and Safe Mode starts no PhxAMDFB: no picture this boot (until VermilionBoot doesn't squat in Safe Mode, plan step 2); ssh and T3 reach the machine"
    notice_next "Safe Mode can't show a picture on this Mac yet, so the screen stayed dark. Start up normally instead."
  else echo "safe mode (kern.safeboot 1): no bring-up, nothing armed this boot"; fi
  exit 0
fi
if [ -e "$NOTICE_NEXT" ]; then CARRY=$(head -1 "$NOTICE_NEXT" 2>/dev/null); rm -f "$NOTICE_NEXT"; sync
  echo "notice: the last boot left one for this boot (shown after login unless this boot has its own): $CARRY"; fi
# GPU state at a hang, logged before any revert so the next boot can tell a GPU hang from a WindowServer-side stall
HANGDIR=${PHXBOOT_HANGDIR:-/var/log}; PTWALK=${PHXBOOT_PTWALK:-$G/ptwalk.sh}
# GPU state at a hang, kept in $HANGDIR/phxhang-<time>/ (survives the revert reboot; /tmp does not): GC status, the VM
# telemetry, a walk of the faulting VMID's page table to the faulting VA, and every process's plugin log
gpu_dump(){ local d="$HANGDIR/phxhang-$(date '+%Y%m%d-%H%M%S')"; mkdir -p "$d"
            echo "--- GPU state ($1) at $(date '+%T'): frames=$(sysctl -n debug.nvaccel_iop_ok 2>/dev/null) -> $d"
            "$PHXCTL" gc 2>&1 | head -20; sleep 1; echo "--- 1s later"; "$PHXCTL" gc 2>&1 | head -4
            { echo "$1"; date; sysctl -n debug.phxvm 2>&1; "$PHXCTL" regs 0x2004 0x2828 0x2829 0x282a 2>&1; } > "$d/state.txt"
            [ -f "$PTWALK" ] && bash "$PTWALK" > "$d/ptwalk.txt" 2>&1
            ps -axo pid,stat,comm > "$d/ps.txt" 2>&1
            find /tmp /private/var/folders -name 'nvmtl*.log' 2>/dev/null | while read -r f; do cp "$f" "$d/$(echo "$f" | tr '/' '_')" 2>/dev/null; done
            grep -E 'fault|VMID' "$d/state.txt" | head -12; }
# Display check (thread 01, 2026-11-23): the display engines' own state, read during the crash watch and before SUCCESS.
# A latched engine means a mode switch left pipe 0 where no plan knows it, the screen most likely dark (2026-11-22 20:19:
# a login switch to 1440p60 HDR failed link training, black screen, every later switch refused, and the daemon said
# SUCCESS). debug.phxp0odm_stat line 2 "failed=1" (the replay engine; b151 latches only after a from plan failed twice,
# a halt or a DMUB timeout), debug.phxpipe0_stat "dark=1" (the pipe-0 engine's revert failed). Reads only.
# Recovery: one clean restart (the TERM trap below clears the in-progress mark and re-arms as a clean shutdown does).
# $DARKF records it; a second dark boot in a row stays up and reports (no restart loop); a boot that ends clean removes it.
DARKF=${PHXBOOT_DARKF:-/var/db/phxboot.darkrestart}
disp_state(){ local st p0
  st=$(sysctl -n debug.phxp0odm_stat 2>/dev/null); p0=$(sysctl -n debug.phxpipe0_stat 2>/dev/null)
  if printf '%s\n' "$st" | grep -q '^state: .* failed=1 '; then echo "dark: the replay engine latched ($(printf '%s\n' "$st" | head -1))"; return 0; fi
  if printf '%s\n' "$p0" | grep -q ' dark=1 '; then echo "dark: the pipe-0 engine latched dark ($(printf '%s\n' "$p0" | sed -n 's/.*\(last=[^ ]*\).*\( why=.*\)/\1\2/p' | head -1))"; return 0; fi
  if printf '%s\n' "$st" | grep -q '^result=FELL-BACK-TO-144 '; then echo "fell back: $(printf '%s\n' "$st" | head -1)"; return 0; fi
  return 1; }
DISPNOTE=""
# The replay engine's last run into this log, once per new run (the run counter in line 2): its result, the recoveries,
# each link window's training and timing (b152). The kernel's own lines don't reach the unified log, and the sysctl
# keeps only the last run of the current boot. Reads only.
DISPRUNS=""
disp_log(){ local st a
  st=$(sysctl -n debug.phxp0odm_stat 2>/dev/null) || return 0
  a=$(printf '%s\n' "$st" | sed -n 's/^state: .* attempts=\([0-9]*\) .*/\1/p')
  [ -n "$a" ] && [ "$a" != "$DISPRUNS" ] || return 0
  DISPRUNS=$a; echo "engine run $a at $(date '+%T'):"
  printf '%s\n' "$st" | grep -E '^(result=|recovery:|train_w[0-9]+:|last_fail:|last_fail_train:)' | grep -v '^last_fail: target=0 ' | sed 's/^/  /'; }
disp_check(){ local d
  d=$(disp_state) || return 0
  case "$d" in
    fell*) [ "$DISPNOTE" = "$d" ] || { DISPNOTE=$d; echo "display: $d (a visible picture at 144 Hz; the saved mode was not reached)"; }; return 0;;
  esac
  echo "DARK at $(date '+%T'): $d"
  local f="$HANGDIR/phxdark-$(date '+%Y%m%d-%H%M%S').txt"; mkdir -p "$HANGDIR"
  { echo "$d"; date; sysctl debug.phxp0odm_stat debug.phxpipe0_stat debug.phxvrr_stat debug.phxfb0_vrr debug.phxfb0_hdr debug.phxscan 2>&1; } > "$f" 2>&1
  echo "  engine state saved to $f"
  if [ -e "$DARKF" ]; then
    echo "  dark again on the boot after a dark restart ($DARKF): no restart, staying up (ssh / T3 reach the machine; Apple menu > Restart, or pick another mode in System Settings once the engine allows it)"
    DARK=1; return 0
  fi
  echo "dark at $(date '+%F %T'): $d" > "$DARKF"; sync
  echo "  recovery: one clean restart now ($DARKF set: a second dark boot in a row will not restart)"
  shutdown -r now; DARK=1; return 0; }
DARK=0
# A sleep that a TERM ends at once. Bash runs a trap only after the foreground child exits, so a plain `sleep 5` held
# the TERM trap below for up to 5 s, the time launchd gives the job before SIGKILL at shutdown (its default ExitTimeOut);
# `wait` returns as soon as the trapped signal arrives.
nap(){ sleep "$1" & wait $!; }
# phxfb-squat for the next boot, logged with an NVRAM read-back (a lost write turned every later boot GOP on 11-02)
rearm(){ nvram phxfb-squat=1 || return 1; sync; if nvram phxfb-squat >/dev/null 2>&1; then echo "phxfb-squat re-armed for the next boot ($1; read-back ok)"; else echo "phxfb-squat re-armed for the next boot ($1; read-back FAILED)"; fi; }
wait_fb(){ for i in $(seq 1 90); do ioreg -rc IOFramebuffer -d0 | grep -q 'class ' && break; sleep 1; done; }

echo "squat boot (PhxFBSquatter holds IOFramebuffer, no IONDRV console): $SQUAT (decided by $SQWHY)"
# A squat boot that cannot leave the squat (seen on the XTX machine). PhxFBSquatter squats while phxfb-squat is in the
# firmware's NVRAM. With OpenCore's DisableVariableWrite, macOS's `nvram -d` (and the squatter's own removal) never
# reach the firmware, so every "reboot onto IONDRV" comes back squatting: a reboot loop until something else deletes the
# variable (.agents/findings/2026-11-20-b138-freeze-and-squat-loop.md).
# $NVSTUCK holds "pending" when a boot rebooted to clear phxfb-squat. A squat boot that finds it knows the clear did not
# stick (STUCK=1): no reboot can help, so the recovery runs a SAFE desktop on the squat instead, the plain path (CPU copy
# at the boot mode: no pipe-0 mode list, GPU present, flip, M7, b15, VCN). A safe attempt that does not finish leaves
# the next boot headless (dark, reachable over the network), never a loop; the boot after that tries the safe desktop
# again. The full desktop comes back by itself after the clean fallback boots the record asks for ($FAILS, above). The
# squat itself is the intended state (phxfb-squat is set from Linux): never Reset NVRAM, which deletes it (CLAUDE.md,
# hard rule 1). The first boot without a squat removes $NVSTUCK and $SAFEF.
NVSTUCK=${PHXBOOT_NVSTUCK:-$G/phxboot-nvstuck}; SAFEF=${PHXBOOT_SAFEF:-$G/phxboot-safe}
# the in-progress mark holds the stage the unfinished attempt was in: bringup, claim or desktop (empty: a daemon before
# 2026-11-25, which set it only for the desktop attempt)
STUCK=0; SAFE=0; HUNG=0; HUNGAT=""; WHY=""
[ -e "$MARK" ] && { HUNG=1; HUNGAT=$(tr -dc 'a-z' <"$MARK" 2>/dev/null | head -c 12); }
if [ -e "$NVSTUCK" ]; then
  if [ $SQUAT = 1 ]; then STUCK=1; echo stuck > "$NVSTUCK"; sync
    echo "nvstuck: still a squat boot after a reboot meant to clear phxfb-squat: macOS cannot clear it (OpenCore DisableVariableWrite); no reboot this boot; the desktop runs on the squat (after a failure a fallback boot first, then the full desktop again by itself: $FAILS); do not Reset NVRAM, it deletes phxfb-squat"
  else rm -f "$NVSTUCK" "$SAFEF"; sync; echo "nvstuck: not a squat boot: phxfb-squat is clear"; fi
fi
# a squat boot's way back to IONDRV. On a stuck squat it returns 1 instead, and the caller goes on without a reboot.
# $2: the notice for the boot after the reboot (after a failure)
squat_reboot(){ [ $STUCK = 1 ] && return 1; echo pending > "$NVSTUCK"; nvram -d phxfb-squat; sync; echo "$1"
  [ -z "${2:-}" ] || notice_next "$2"; shutdown -r now; exit 0; }
headless(){ REC_L=skip; rec_save "headless"
  echo "stuck squat: $1: no desktop attempt and no reboot this boot (the screen stays dark; ssh and T3 still reach the machine). The next boot tries the safe desktop again: restart once. Do not Reset NVRAM, it deletes phxfb-squat"; release; exit 0; }
# the record: the last boot's outcome first (an unfinished attempt, or one more clean fallback boot)
rec_load
if [ -e "$FAILF" ]; then [ "$REC_F" -ge 1 ] || REC_F=1; REC_C=0; rm -f "$FAILF"; sync; rec_save "$FAILF of an earlier daemon taken over"; fi
if [ $HUNG = 1 ]; then
  REC_F=$(inc "$REC_F"); REC_C=0; [ "$HUNGAT" = bringup ] && REC_B=$(inc "$REC_B")
  rec_save "the last boot's attempt did not finish (stage ${HUNGAT:-desktop})"
elif [ "$REC_F" -gt 0 ] && { [ "$REC_L" = safe ] || [ "$REC_L" = gop ]; }; then
  REC_C=$(inc "$REC_C"); rec_save "the last boot's $REC_L fallback finished"
fi
# a squat boot has no display until we arm, so every early exit on one must reboot (back to IONDRV) instead
if [ -e "$OFF" ]; then
  echo "kill switch present (~/gpu/phxboot-off, the owner's switch: this daemon never sets it)"; release
  rm -f "$MARK"; sync   # an unfinished attempt is counted above, once
  REC_L=skip; [ $SQUAT = 1 ] || { rec_save "kill switch"; bye; }
  rec_save "kill switch"; squat_reboot "squat boot with the kill switch on: rebooting onto IONDRV"
  SAFE=1; WHY="the kill switch is on"
elif [ $HUNG = 1 ]; then
  echo "previous attempt did not finish -> GOP (one-shots cleared; counted in $FAILS, fails=$REC_F)"
  oneshots_off
  REC_L=skip; rec_save "no attempt this boot"
  [ $SQUAT = 1 ] || bye
  squat_reboot "squat boot: rebooting onto IONDRV"
  SAFE=1; WHY="the last startup did not finish"
elif [ $STUCK = 1 ] && [ "$REC_F" -gt 0 ] && [ "$REC_C" -lt "$(rec_need)" ]; then
  echo "stuck squat after a failed attempt (fails=$REC_F, clean fallback boots $REC_C of $(rec_need))"; SAFE=1; WHY="an attempt failed"
elif [ "$REC_F" -gt 0 ] && [ $SQUAT = 1 ]; then
  echo "record: $REC_C clean fallback boot(s) after $REC_F failed attempt(s): the full desktop again"
fi
if [ $SAFE = 1 ]; then
  rm -f "$MARK"
  [ $HUNG = 1 ] && [ -e "$SAFEF" ] && headless "the safe desktop did not finish last boot"
fi
# Loop guard: a bring-up that fails inside bringup_navi31.sh leaves its 3-minute watchdog armed (kept: rule 1), which
# restarts the machine, and the next boot would run the same bring-up again. After 2 failed bring-ups in a row one boot
# skips it (nothing touches the GPU, so no watchdog and no restart) and the boot after that tries again: never more than
# 2 restarts in a row by themselves.
if [ "$REC_B" -ge 2 ] && [ "$REC_S" = 0 ]; then
  REC_S=1; REC_L=skip; rec_save "bring-up skipped"; rm -f "$MARK" "$DESKTOP"; sync
  echo "bring-up skipped: it failed on the last $REC_B startups ($FAILS): nothing touches the GPU this boot (no bring-up watchdog, no restart); the next startup tries again$([ $SQUAT = 1 ] && echo '; a squat boot: the screen stays dark (ssh and T3 reach the machine)')"
  notice "Graphics acceleration is off for this startup because it failed to start the last $REC_B times. Your Mac will try again at the next startup."
  leave
fi
REC_S=0
# when the safe desktop gives way to the full one (a function: bash 3.2 misreads a case pattern's ")" inside "$(...)")
full_when(){ case "$WHY" in *kill*) echo "once ~/gpu/phxboot-off is removed";; *) rec_when;; esac; }
# the safe desktop's notice after login (after "safe desktop up")
safe_notice(){ case "$WHY" in
  *kill*) notice "The display is in basic mode because graphics acceleration is turned off (the file phxboot-off in the gpu folder).";;
  *finish*) notice "The display is in basic mode because the last startup didn't finish. Your Mac will try the full mode again $(rec_when).";;
  *) if [ "$REC_F" -ge 3 ]; then notice "The display is in basic mode because graphics failed to start fully $REC_F times in a row. Your Mac will try the full mode again $(rec_when)."
     else notice "The display is in basic mode because graphics failed to start fully last time. Your Mac will try the full mode again $(rec_when)."; fi;; esac; }
if [ $SAFE = 1 ]; then
  touch "$SAFEF"; sync
  echo "safe desktop on the stuck squat: CPU copy at the boot mode (no pipe-0 modes, GPU present, flip, M7, b15, VCN); why: $WHY; the full desktop again $(full_when)"
fi

DESK=0; { [ -e "$DESKTOP" ] || [ $SQUAT = 1 ]; } && DESK=1
echo "desktop-arm: $DESK (phxboot-desktop file or squat boot)"
if [ $SAFE = 1 ]; then REC_L=safe; elif [ $DESK = 1 ]; then REC_L=full; else REC_L=gop; fi; rec_save "this boot: $REC_L"
[ $REC_L = full ] && rm -f "$SAFEF"   # a full attempt: a hang of this one (from its bring-up on) is not the safe desktop's
for i in $(seq 1 60); do ioreg -l | grep -q '"phx-build"' && break; sleep 1; done
[ $SQUAT = 1 ] || wait_fb    # a squat boot has no framebuffer until PhxAMDFB starts at claim
# A GOP boot without PhxBringup, or (below) whose NMXAccel did not start, is no clean fallback boot: its plain path
# failed, and the full desktop would fail the same way. It is no failed desktop attempt either (fails stays).
ioreg -l | grep -q '"phx-build"' || { [ $DESK = 1 ] && m2_fail "PhxBringup not loaded"; REC_L=skip; rec_save "PhxBringup not loaded: no clean fallback boot"; echo "PhxBringup not loaded"; bye; }

# bring-up + claim (needed for Metal either way)
# PhxAMDFB takes the panel at start only with phxfb-boot set (it clears it at once)
[ $DESK = 1 ] && nvram phxfb-boot=1
# PhxAccel lives in the AuxKC, which does not always load it at boot
kmutil showloaded 2>/dev/null | grep -q org.vermilion.accel || kmutil load -p "$ACCEL" 2>&1 | tail -2
# A GOP boot without VermilionAccel (the Allow click is still missing: the AuxKC loads the kext only after it) has no
# NMXAccel and no PhxAMDFB, and a bring-up here would fail: so nothing touches the GPU, nothing counts as a failed
# attempt, and the user is told what to click (the daemon never arms a squat boot until this passes: the re-arm below
# needs a finished GOP bring-up and claim, which needs the kext and the firmware).
if [ $SQUAT = 0 ] && ! kmutil showloaded 2>/dev/null | grep -q org.vermilion.accel; then
  REC_L=skip; rec_save "VermilionAccel not loaded: no clean fallback boot"
  echo "VermilionAccel not loaded (the Allow click is missing?): no bring-up this boot, the GPU is not touched"
  notice "Graphics acceleration needs your approval: open System Settings > Privacy & Security, click Allow next to the Vermilion system software, then restart."
  bye
fi
echo "== bring-up + claim =="
# The in-progress mark from here on (before 2026-11-25 it was set only after the claim): a hang in the bring-up, the
# claim or the desktop attempt leaves it, and the next boot counts it as an unfinished attempt. A clean shutdown or
# restart meanwhile (launchd's TERM) is not one: the trap clears the mark.
echo bringup >"$MARK"; sync
# launchd's TERM during navi31_up.sh: bash runs a trap only after a foreground command returns, so with UPOUT=$(...) a
# shutdown during the bring-up (about 10 s on the XTX machine) waited for its end, launchd SIGKILLed the daemon after
# its exit timeout first, and the mark stayed: the next boot counted a failed bring-up. navi31_up.sh runs in the
# background and the daemon waits for it with `wait`, which a trapped TERM ends at once (nap() does the same).
# A TERM in the first PHXBOOT_UP_HANG s (60) of the bring-up is a clean shutdown or restart: the mark is cleared. A
# later one is the bring-up watchdog's restart (3 min) of a hung bring-up, or a shutdown during one: the mark stays and
# the next boot counts it, as before. Either way the daemon then waits for the bring-up to end, so nothing in it stops
# sooner than before, and exits without a claim.
# A clean shutdown before the claim also takes phxfb-boot back (set above for PhxAMDFB's start at the claim; no
# PhxAMDFB consumed it): with the mark cleared, the next boot's oneshots_off doesn't run (hw-safety review 2026-11-25).
# The output file comes from mktemp: root writes it in /tmp, where a fixed name could be a planted link. If mktemp
# fails, the file has a fixed name in /var/db, which only root writes.
UPF=$(mktemp "$WSPTMP/phxboot-up.XXXXXX" 2>/dev/null) || UPF=/var/db/phxboot-up.log; UPT0=$(date +%s); UPTERM=0
up_term(){ local s; [ $UPTERM = 1 ] && return 0; UPTERM=1; s=$(( $(date +%s) - UPT0 ))
  if [ $s -lt "${PHXBOOT_UP_HANG:-60}" ]; then rm -f "$MARK"; [ $DESK = 1 ] && nvram -d phxfb-boot; sync
    echo "clean shutdown (TERM) at $(date '+%T') during the bring-up (${s}s in): in-progress mark cleared, not counted; no claim"
  else echo "TERM at $(date '+%T') after ${s}s of the bring-up (it takes about 10 s): a hung bring-up (the bring-up watchdog restarts after 3 min): the in-progress mark stays, the next boot counts it"; fi
  b21_on "shutdown (TERM) during the bring-up"; }
trap up_term TERM
bash "$G/phxctl/navi31_up.sh" >"$UPF" 2>&1 & UPPID=$!
wait $UPPID; UPRC=$?
while [ $UPTERM = 1 ] && kill -0 $UPPID 2>/dev/null; do wait $UPPID; UPRC=$?; done   # after a TERM: until it ends
UPOUT=$(cat "$UPF" 2>/dev/null); rm -f "$UPF"
trap 'echo "clean shutdown (TERM) at $(date "+%T") before the desktop attempt: in-progress mark cleared"; rm -f "$MARK"
      [ $DESK = 1 ] && nvram -d phxfb-boot; sync; b21_on "shutdown (TERM) before the desktop attempt"; exit 0' TERM
echo "$UPOUT" | tail -4
[ $UPTERM = 1 ] && { echo "the bring-up ended after the shutdown's TERM: no claim"; exit 0; }
UPOK=0; [ $UPRC = 0 ] && echo "$UPOUT" | grep -q "navi31 up:" && UPOK=1   # the GPU came up: navi31_up.sh's last line
echo "$UPOUT" | grep -m1 '^sOS check:'   # C2PMSG_81 before the power-up, at every boot (is a warm restart cold?)
# A bring-up that did not end with "navi31 up:" claims nothing: no Metal on a GPU without working queues, no PhxAMDFB.
# The one-shots set for this boot are taken back (phxfb-boot), no Metal allow list or debug.phxagdc write (nothing runs
# on the GPU, the oid does not exist), and no reboot by the daemon except a non-stuck squat boot's way back to IONDRV.
upfail_end(){ trap - TERM; rm -f "$MARK"; [ $DESK = 1 ] && nvram -d phxfb-boot; sync; }
# ~/gpu/phxboot-desktop (one desktop attempt on a non-squat boot) after a bring-up that did not come up: a failure uses
# it up, as m2_fail does, so the next boot doesn't run the same attempt again (it is a GOP boot until the owner arms
# again). The warm refusal keeps it: nothing was attempted, and the cold boot after the power-off should get the desktop
# that was asked for. A refusal repeats only on another warm boot, and the daemon never restarts after one.
desk_used(){ [ -e "$DESKTOP" ] || return 0
  if [ "$1" = keep ]; then echo "phxboot-desktop kept for the next boot (the refusal was no desktop attempt)"
  else rm -f "$DESKTOP"; sync; echo "phxboot-desktop used up by the failed bring-up: the next boot is a GOP boot"; fi; }
# A warm GPU (PSP sOS already running): bringup_navi31.sh wrote nothing and refused. That is not a driver failure: the
# record stays as it was and nothing reboots (a restart keeps the GPU warm). Only a full power-off makes it cold again.
# On a squat boot the screen stays dark until the kext can hand the display back in the same boot (plan step 3).
# The other refusal, "warm GPU check failed: C2PMSG_81 unreadable", wrote nothing either, but it means phxctl or
# PhxBringup doesn't answer: a failure that repeats, so it takes the failure path below (counted, the loop guard),
# where "shut down fully" would be the wrong advice.
case "$UPOUT" in *"refused: warm GPU ("*)
  upfail_end; desk_used keep; REC_L=skip; rec_save "warm GPU refused"
  echo "warm GPU: bring-up refused, no Metal this boot ($([ $SQUAT = 1 ] && echo 'a squat boot: no display without the claim, the screen stays dark; ssh and T3 reach the machine' || echo 'firmware display')); power the machine off fully, then boot macOS. Nothing was written to the GPU: not counted as a failed attempt, no reboot"
  # after a restart that followed a failure, the GPU is warm from that boot's own bring-up, not from another system
  if [ "$CARRY" = "$RESTARTED" ]; then notice "$RESTARTED Shut down (don't restart), then turn the computer on again to get graphics acceleration back."
  else notice "The graphics card was still running from another operating system. Shut down (don't restart), then turn the computer on again to get graphics acceleration back."; fi
  leave;; esac
if [ $UPOK = 0 ]; then
  upfail_end; desk_used; REC_B=$(inc "$REC_B"); REC_L=skip; rec_fail "bring-up failed"
  echo "bring-up failed: no claim, no Metal this boot ($(echo "$UPOUT" | grep -m1 '^navi31 not up:' || echo "navi31_up.sh rc $UPRC without 'navi31 up:'"))"
  # A failure inside bringup_navi31.sh leaves its watchdog armed: it gives the PSP, SMU and RLC their 3 minutes, so the
  # daemon doesn't restart sooner (hw-safety review 2026-11-25); a non-stuck squat boot only clears the squat, so that
  # restart lands on IONDRV. After it (watchdog cancelled) the squat boot's way back to IONDRV is the restart at once.
  if [ $SQUAT = 1 ] && [ $STUCK = 1 ]; then
    echo "stuck squat: no display this boot (no claim) and no reboot by the daemon; a bring-up watchdog that is still armed restarts the machine"
  elif [ $SQUAT = 1 ] && echo "$UPOUT" | grep -q 'watchdog is still armed'; then
    echo pending > "$NVSTUCK"; nvram -d phxfb-squat; sync
    echo "squat boot: phxfb-squat cleared, no reboot by the daemon: the bring-up watchdog restarts the machine onto IONDRV within 3 min"
  elif [ $SQUAT = 1 ]; then
    squat_reboot "squat boot: rebooting onto IONDRV after the failed bring-up" "$RESTARTED"
  fi
  # the watchdog's restart comes before most logins: the next boot gets the notice too
  if echo "$UPOUT" | grep -q 'watchdog is still armed'; then notice_next "$RESTARTED"
    if [ "$REC_B" -ge 2 ]; then notice "Graphics acceleration failed to start again. Your Mac will restart by itself within 3 minutes."
    else notice "Graphics acceleration failed to start. Your Mac will restart by itself within 3 minutes."; fi
  elif [ "$REC_B" -ge 2 ]; then notice "Graphics acceleration failed to start again. Your Mac will start without it next time, then try again."
  else notice "Graphics acceleration failed to start. Your Mac will try again at the next startup."; fi
  leave
fi
[ "$REC_B" = 0 ] || { REC_B=0; rec_save "bring-up up"; }
echo claim >"$MARK"; sync
# Idle power: clock gating and the UCLK pin right after the GPU is up, not only after `done`: without them the card sat at
# ~110 C hotspot / 260 W for the ~2 min of the boot; the late calls below re-apply them after
# vcn_boot.
# M7 (10-29): the second monitor at boot when $G/phxboot-m7 exists (m7_boot.sh = tools/phxctl/m7_boot.sh):
# light (pipe 1 stream) before the AGDC arm, bind (head 1 + plane + flip) after it, so the ONE WindowServer restart
# below already sees both displays. Any M7 failure is logged and undone; the boot goes on with one monitor.
M7LIT=0; M7PHASE=0; M7BOUND=0
# GPU present E3 (2026-11-19, the XTX machine): on by default (off: $G/phxboot-wscdcopy-off), the restarted WindowServer
# gets NVMTL_WS_PRESENT_CDCOPY=1 from launchd (as CI_USE_MTL_DAG_FOR_CIKL_SRC), so the plugin presents CoreDisplay's display
# surfaces (every region current) instead of SkyLight's composite targets, which only have the changed regions redrawn:
# those regions flickered between new and old (findings 2026-11-19-gpu-present-flicker-heat.md; verified on the XTX
# machine at 1440p60). E3 presents at GPU completion, so it needs GPU present and async GPU present on; without them
# nothing is set. launchctl setenv lasts until the next reboot.
# GPU present, async GPU present and direct scan-out are ON by default (2026-11-26); the opt-out files in
# /Library/GPUBundles/nvmtl are ws-gpu-present-off, ws-gpu-present-async-off and ws-direct-off (the Metal plugin reads
# them; the daemon reads the first two). The old opt-in files (ws-gpu-present, ws-gpu-present-async, ws-direct) are
# ignored. The safe desktop (SAFE=1) never has GPU present: the daemon does not allow the scanout (debug.phxscan).
GPUPRESENT_OFF=${PHXBOOT_GPUPRESENT_OFF:-/Library/GPUBundles/nvmtl/ws-gpu-present-off}
WSASYNC_OFF=${PHXBOOT_WSASYNC_OFF:-/Library/GPUBundles/nvmtl/ws-gpu-present-async-off}
GPUPRESENT=0   # 1 from step 5a when GPU present is on this boot
ws_cdcopy(){ feat_on wscdcopy || return 0
  if [ "$GPUPRESENT" != 1 ] || [ -e "$WSASYNC_OFF" ]; then
    echo "wscdcopy: needs GPU present and async GPU present on (not the safe desktop, no $GPUPRESENT_OFF, no $WSASYNC_OFF): NVMTL_WS_PRESENT_CDCOPY not set"; return 0; fi
  if launchctl setenv NVMTL_WS_PRESENT_CDCOPY 1 2>/dev/null; then
    echo "wscdcopy: NVMTL_WS_PRESENT_CDCOPY=1 for the restarted WindowServer (CoreDisplay's display surfaces are presented)"
  else echo "wscdcopy: launchctl setenv failed: SkyLight's targets are presented"; fi; }
# WindowServer's display surface drawn tiled (thread 02 part C3, 2026-11-23): with $G/phxboot-wstiled, the restarted
# WindowServer gets NVMTL_WS_SCANOUT_TILED=1 from launchd, so the plugin composes into a TILED image and copies it to the
# display surface's pages at the end of every command buffer that drew it (upstream's probe: 1.77 ms linear, 88 us
# tiled, 491 us with the copy). The pages stay what GPU present (and every other reader) reads. Not on the safe desktop.
# Measured on the XTX machine (2026-11-23 17:11): the desktop draws right, but Horizon runs at 230 fps against 292
# without the flag (about 3 copies per frame), so the flag is not set there (findings 2026-11-23-horizon-present-cost.md).
ws_tiled(){ [ -e "$G/phxboot-wstiled" ] || return 0
  if [ $SAFE = 1 ]; then echo "wstiled: not on the safe desktop: NVMTL_WS_SCANOUT_TILED not set"; return 0; fi
  if launchctl setenv NVMTL_WS_SCANOUT_TILED 1 2>/dev/null; then
    echo "wstiled: NVMTL_WS_SCANOUT_TILED=1 for the restarted WindowServer (its display surface drawn tiled)"
  else echo "wstiled: launchctl setenv failed: the display surface stays linear"; fi; }
# Fence wait step (2026-11-19, the XTX machine): debug.phxwait_step_us gets 200 before the WindowServer restart; a file
# $G/phxboot-waitstep holds another value (empty = 200; 20-1000 accepted); with $G/phxboot-waitstep-off nothing is
# written. A WAITSEQ that outlasts its 20 us spin sleeps in timed steps of this length while IRQ waits are off; the
# kext's default is 50. 200 cut WindowServer's wakeups 5-15x and was not worse than 50 in a blind A/B (findings
# 2026-11-19-gpu-present-flicker-heat.md, live test 4). Only 50 and 200 were tried on hardware. The sysctl resets to 50
# at every boot; with the -off file nothing is written.
waitstep_boot(){ feat_on waitstep || return 0
  local v out rc
  if [ -e "$G/phxboot-waitstep" ]; then v=$(tr -d ' \t\r\n' <"$G/phxboot-waitstep" 2>/dev/null); else v=200; fi; [ -n "$v" ] || v=200
  case "$v" in [1-9][0-9]|[1-9][0-9][0-9]|1000) ;; *) v=0;; esac
  if [ "$v" -lt 20 ]; then
    echo "waitstep: ~/gpu/phxboot-waitstep holds '$(head -c 20 "$G/phxboot-waitstep" | tr -d '\r\n')', not 20-1000: debug.phxwait_step_us stays at the kext's default"; return 0; fi
  sysctl -n debug.phxwait_step_us >/dev/null 2>&1 || { echo "waitstep: PhxBringup without debug.phxwait_step_us: nothing set"; return 0; }
  out=$(sysctl -w debug.phxwait_step_us=$v 2>&1); rc=$?
  echo "waitstep: debug.phxwait_step_us=$v rc $rc, reads $(sysctl -n debug.phxwait_step_us 2>/dev/null) ($(echo "$out" | tail -1 | cut -c1-80))"; }
# Fence waits by interrupt (2026-11-23, thread 02, the XTX machine): on by default (off: $G/phxboot-irqwait-off). Before
# the WindowServer restart, the IH ring in VRAM (debug.phxih_vram, debug.phxih), the EOP interrupt (debug.phxeopirq),
# the MSI (debug.phxirq), then WAITSEQ sleeping on it (debug.phxwait_irq), in that order, each read back. Measured live:
# a short waited job 265 -> 114 us median (Linux 114), p99 lower too, 1.1 M MSIs without a storm (findings
# 2026-11-23-perf-power.md, section 4). The kext keeps the timed steps when it sees a storm. Any step that doesn't read
# back 1 turns all five off again (reverse order). The sysctls reset at every boot; with the -off file nothing is
# written.
irqwait_boot(){ feat_on irqwait || return 0
  local o out rc on=""
  sysctl -n debug.phxwait_irq >/dev/null 2>&1 || { echo "irqwait: PhxBringup without debug.phxwait_irq: polled waits stay"; return 0; }
  for o in phxih_vram phxih phxeopirq phxirq phxwait_irq; do
    out=$(sysctl -w debug.$o=1 2>&1); rc=$?
    if [ $rc != 0 ] || [ "$(sysctl -n debug.$o 2>/dev/null)" != 1 ]; then
      echo "irqwait: debug.$o=1 rc $rc, reads $(sysctl -n debug.$o 2>/dev/null) ($(echo "$out" | tail -1 | cut -c1-80)): all back to 0, polled waits stay"
      for o in phxwait_irq phxirq phxeopirq phxih phxih_vram; do sysctl -w debug.$o=0 >/dev/null 2>&1; done; return 0; fi
    on="$on $o"; done
  echo "irqwait: on (debug.$(echo $on | sed 's/ /=1 debug./g')=1)"; }
m7_light(){ [ -e "$G/phxboot-m7" ] || return 0
  [ -e "$G/m7_boot.sh" ] || { echo "m7: $G/m7_boot.sh missing"; return 0; }
  sh "$G/m7_boot.sh" light; r=$?
  [ $r = 0 ] && { M7LIT=1; M7PHASE=1; }; [ $r = 3 ] && M7LIT=1; return 0; }
m7_bind(){ [ "$M7LIT" = 1 ] || return 0
  if sh "$G/m7_boot.sh" bind; then M7BOUND=1; else echo "m7: bind failed: one monitor this boot"; fi; return 0; }
# 11-01: two head-1 features validated live on 10-31/11-01, each
# behind its own flag, both called after `done` and the late SMU calls, before b15_boot starts. Only on a desktop boot
# whose head 1 came up (m7_bind exit 0): that is the state both live passes ran in. A refused write is logged, never fatal.
# Hot-plug: ~/gpu/phxboot-hotplug
# = debug.phxhotplug=2 (kext b102+ with PhxAccel hpd1+: the Acer's unplug/plug takes head 1 offline / online). The
# boot-arg -phxhotplugoff keeps it at 0 (the kext refuses the write too, EPERM).
hotplug_boot(){ [ -e "$G/phxboot-hotplug" ] || return 0
  [ $DESK = 1 ] || { echo "hotplug: not a desktop boot: debug.phxhotplug stays 0"; return 0; }
  case " $(sysctl -n kern.bootargs 2>/dev/null) " in
    *" -phxhotplugoff "*) echo "hotplug: boot-arg -phxhotplugoff: debug.phxhotplug stays 0"; return 0 ;; esac
  [ "$M7BOUND" = 1 ] || { echo "hotplug: head 1 not up this boot: debug.phxhotplug stays 0"; return 0; }
  out=$(sysctl -w debug.phxhotplug=2 2>&1); rc=$?
  echo "hotplug: $(date '+%T') debug.phxhotplug=2 rc $rc, reads $(sysctl -n debug.phxhotplug 2>/dev/null) ($(echo "$out" | tail -1 | cut -c1-100))"; }
# 11-04 head-0 hot-plug: ~/gpu/phxboot-hotplug0 =
# debug.phxhotplug0 after `done` (PhxAccel hp1+: the AOC's DP unplug / plug takes head 0 offline / online, the Acer is the
# main display meanwhile). The flag holds the level, 1 (observe) or 2 (act); empty = 1. Not on a GOP boot; boot-arg
# -phxhotplugoff keeps it at 0 (the kext refuses the write too). A PhxAccel without the oid is logged and nothing is armed.
hotplug0_boot(){ [ -e "$G/phxboot-hotplug0" ] || return 0
  [ $DESK = 1 ] || { echo "hotplug0: not a desktop boot: debug.phxhotplug0 stays 0"; return 0; }
  case " $(sysctl -n kern.bootargs 2>/dev/null) " in
    *" -phxhotplugoff "*) echo "hotplug0: boot-arg -phxhotplugoff: debug.phxhotplug0 stays 0"; return 0 ;; esac
  local lvl out rc
  lvl=$(tr -d ' \t\r\n' <"$G/phxboot-hotplug0" 2>/dev/null); [ -n "$lvl" ] || lvl=1
  case "$lvl" in 1|2) ;; *) echo "hotplug0: ~/gpu/phxboot-hotplug0 holds '$lvl', not 1 or 2: debug.phxhotplug0 stays 0"; return 0 ;; esac
  sysctl -n debug.phxhotplug0 >/dev/null 2>&1 || { echo "hotplug0: PhxAccel without debug.phxhotplug0 (hp1+): nothing armed"; return 0; }
  out=$(sysctl -w debug.phxhotplug0=$lvl 2>&1); rc=$?
  echo "hotplug0: $(date '+%T') debug.phxhotplug0=$lvl rc $rc, reads $(sysctl -n debug.phxhotplug0 2>/dev/null) ($(echo "$out" | tail -1 | cut -c1-100))"; }
# 11-03 multiport S3: ~/gpu/phxboot-dpwatch = debug.phxdpwatch after `done`
# (kext b120+: the read-only DP stream watcher of DP B / DP A / DP E; b121+: level 2 = also the DP B dark-AOC fix, Linux's
# DIG FIFO reset + stream re-enable on a STUCK, once per plug). The flag holds the level, 1 or 2 (empty = 1). Not on a GOP
# boot; boot-arg -phxdpwatchoff keeps it off (the kext refuses the write too). A kext without the oid is logged and nothing
# is armed; one that refuses level 2 (before b121) gets level 1. watch_hangs then logs every new STUCK / recovery / fix.
DPWATCH=0; DPWPREV=""
dpwatch_boot(){ [ -e "$G/phxboot-dpwatch" ] || return 0
  [ $DESK = 1 ] || { echo "dpwatch: not a desktop boot: debug.phxdpwatch stays 0"; return 0; }
  case " $(sysctl -n kern.bootargs 2>/dev/null) " in
    *" -phxdpwatchoff "*) echo "dpwatch: boot-arg -phxdpwatchoff: debug.phxdpwatch stays 0"; return 0 ;; esac
  local lvl out rc
  lvl=$(tr -d ' \t\r\n' <"$G/phxboot-dpwatch" 2>/dev/null); [ -n "$lvl" ] || lvl=1
  case "$lvl" in 1|2) ;; *) echo "dpwatch: ~/gpu/phxboot-dpwatch holds '$lvl', not 1 or 2: debug.phxdpwatch stays 0"; return 0 ;; esac
  sysctl -n debug.phxdpwatch >/dev/null 2>&1 || { echo "dpwatch: PhxBringup without debug.phxdpwatch (kext b120+): nothing armed"; return 0; }
  out=$(sysctl -w debug.phxdpwatch=$lvl 2>&1); rc=$?
  if [ $rc != 0 ] && [ "$lvl" = 2 ]; then
    echo "dpwatch: level 2 refused ($(echo "$out" | tail -1 | cut -c1-80)): a kext before b121? level 1"
    lvl=1; out=$(sysctl -w debug.phxdpwatch=1 2>&1); rc=$?
  fi
  [ $rc = 0 ] && DPWATCH=1
  echo "dpwatch: $(date '+%T') debug.phxdpwatch=$lvl rc $rc, reads $(sysctl -n debug.phxdpwatch 2>/dev/null) ($(echo "$out" | tail -1 | cut -c1-100))"; }
# One look at the watcher (called by watch_hangs every 15 s): a line for each counter that went up since the last look
# (per connector STUCK / recovered / ended by an unplug; DP B's fix ok / fail / refused), with the newest matching event.
dpwatch_check(){ [ "$DPWATCH" = 1 ] || return 0
  local s cur k c n p ev
  s=$(sysctl -n debug.phxdpwatch_stat 2>/dev/null) || return 0
  cur=$(printf '%s\n' "$s" | sed -n -e 's/^\(DP-[ABE]\): .* STUCK=\([0-9]*\) recovered=\([0-9]*\) stuck_ended_off=\([0-9]*\) .*/\1:STUCK=\2 \1:recovered=\3 \1:stream-off=\4/p' \
        -e 's/^DP-B fix (level 2): .* ok=\([0-9]*\) fail=\([0-9]*\) refused=\([0-9]*\) .*/DP-B:FIX-OK=\1 DP-B:FIX-FAIL=\2 DP-B:fix-refused=\3/p' | tr '\n' ' ')
  for k in $cur; do c=${k%%=*}; n=${k#*=}
    p=$(printf '%s\n' $DPWPREV | sed -n "s/^$c=//p"); [ -n "$p" ] || p=0
    [ "$n" -gt "$p" ] 2>/dev/null || continue
    ev=$(printf '%s\n' "$s" | grep -E "^ev .* ${c%%:*} ${c#*:} " | tail -1 | cut -c1-220)
    echo "dpwatch: $(date '+%F %T') ${c%%:*} ${c#*:} $p -> $n${ev:+ | $ev}"
  done
  DPWPREV=$cur; }
# Gamma: ~/gpu/phxboot-gamma = debug.phxgamma=1 (kext b98+: head-1 tables
# written to MPCC_OGAM1; the 0 -> 1 write applies the last table CoreDisplay sent). Head 1 gets tables only when CoreDisplay
# reads useIOP_gamma_onAMD = false: logged from ~/gpu/cdpref, never set here (a user/system setting).
# The kext answers EBUSY while the pipe-1 engine is held (a mode switch, a hot-plug action): up to 3 writes, 1 s apart.
CDPREF=${PHXBOOT_CDPREF:-$G/cdpref}
gamma_boot(){ [ -e "$G/phxboot-gamma" ] || return 0
  [ $DESK = 1 ] || { echo "gamma: not a desktop boot: debug.phxgamma stays 0"; return 0; }
  [ "$M7BOUND" = 1 ] || { echo "gamma: head 1 not up this boot: debug.phxgamma stays 0"; return 0; }
  if [ -x "$CDPREF" ]; then p=$("$CDPREF" get useIOP_gamma_onAMD 2>&1 | tail -1)
    case "$p" in *"useIOP_gamma_onAMD = false") echo "gamma: CoreDisplay useIOP_gamma_onAMD = false: head-1 tables reach the kext" ;;
      *) echo "gamma: CoreDisplay useIOP_gamma_onAMD is not false ($p): head 1 gets no tables (sudo ~/gpu/cdpref set useIOP_gamma_onAMD 0 + a WindowServer restart)" ;; esac
  else echo "gamma: $CDPREF missing: CoreDisplay useIOP_gamma_onAMD not checked"; fi
  t=0; while :; do t=$((t + 1)); out=$(sysctl -w debug.phxgamma=1 2>&1); rc=$?
    [ $rc != 0 ] && [ $t -lt 3 ] && echo "$out" | grep -qi busy || break; sleep 1; done
  echo "gamma: $(date '+%T') debug.phxgamma=1 rc $rc after $t write(s), reads $(sysctl -n debug.phxgamma 2>/dev/null) ($(echo "$out" | tail -1 | cut -c1-100))"; }
# Boot rate (11-02): ~/gpu/phxboot-aoc-rate = 144 (or "last" = the aoc= rate b15_boot.sh
# remembered in ~/gpu/phxboot-rate-last, 144 when none) puts the AOC at 144 BEFORE the one WindowServer restart, so the
# restarted WindowServer starts with the AOC at 144 and nothing switches after the login: b15_boot.sh aocboot (the 60
# recipe's pipe-0 part + the kext's macOS sequence to 144 + aoc144), then PhxAccel head 0 takes OTG0's new totals as its
# current mode (debug.phxfb_resync=1; PhxAccel boot-rate build). Only when head 1 came up phase-aligned (pipe 1 at 144 or 165
# with DET 9/9 is aocboot's own check), the head-0 mode list is armed and b15 will follow (phxboot-b15 + -b15-2pipe). Any
# refusal = the AOC stays at 60 as today (b15 then asks 144 after the login as before); a resync that does not report id 2
# = the engine back to 60 (b15_boot.sh aocback). Never fatal for the boot.
AOCRATE=${PHXBOOT_AOCRATE:-$G/phxboot-aoc-rate}; RATELAST=${PHXBOOT_RATELAST:-$G/phxboot-rate-last}
aoc_boot(){ [ -e "$AOCRATE" ] || return 0
  local want src out rc id
  want=$(tr -d ' \t\r\n' < "$AOCRATE"); src="$AOCRATE"
  if [ "$want" = last ]; then want=$(sed -n 's/.*aoc=\([0-9][0-9]*\).*/\1/p' "$RATELAST" 2>/dev/null | head -1); src="remembered in $RATELAST"
    case "$want" in 60|144) ;; *) want=144; src="no remembered rate in $RATELAST" ;; esac; fi
  [ "$want" = 144 ] || { echo "aocboot: boot rate '$want' ($src): the AOC stays at 60"; return 0; }
  { [ -e "$G/phxboot-m7-aocmodes" ] || [ -e "$G/phxboot-m7-aoc144" ]; } || { echo "aocboot: no head-0 mode list flag (phxboot-m7-aocmodes): the AOC stays at 60"; return 0; }
  # two displays (head 1 up and phase-aligned) = aocboot next to the Acer; the AOC alone (pipe 1 never lit this boot: no
  # Acer) = aocboot1 (11-03 p0solo: needs ~/gpu/phxboot-m7 for
  # the DAL hard mins and PhxBringup's debug.phxpipe0_solo); pipe 1 lit but not bound / not aligned = no 144 (as before)
  local cmd alone=""
  if [ "$M7BOUND" = 1 ] && [ "$M7PHASE" = 1 ]; then cmd=aocboot
    { [ -e "$G/phxboot-b15" ] && [ -e "$G/phxboot-b15-2pipe" ]; } || { echo "aocboot: b15 two-display flags missing (phxboot-b15, -b15-2pipe): the AOC stays at 60"; return 0; }
  elif [ "$M7LIT" = 0 ]; then cmd=aocboot1; alone=" (alone)"
    [ -e "$G/phxboot-b15" ] || { echo "aocboot: one display: no ~/gpu/phxboot-b15: the AOC stays at 60"; return 0; }
    [ -e "$G/phxboot-m7" ] || { echo "aocboot: one display: no ~/gpu/phxboot-m7 (its rate setup sends the DAL hard mins the 144 set needs): the AOC stays at 60"; return 0; }
    sysctl -n debug.phxpipe0_solo >/dev/null 2>&1 || { echo "aocboot: one display: PhxBringup without debug.phxpipe0_solo (kernel-p0solo.patch): the AOC stays at 60"; return 0; }
  else echo "aocboot: head 1 not up and phase-aligned this boot: the AOC stays at 60"; return 0; fi
  [ -e "$G/b15_boot.sh" ] || { echo "aocboot: $G/b15_boot.sh missing: the AOC stays at 60"; return 0; }
  sysctl -n debug.phxfb_resync >/dev/null 2>&1 || { echo "aocboot: PhxAccel without debug.phxfb_resync: the AOC stays at 60"; return 0; }
  [ "$(sysctl -n debug.phxfb_nmodes 2>/dev/null)" = 2 ] || { echo "aocboot: head 0 has no 60/144 mode list (debug.phxfb_nmodes $(sysctl -n debug.phxfb_nmodes 2>/dev/null)): the AOC stays at 60"; return 0; }
  echo "aocboot: $(date '+%T') boot rate 144 ($src): the AOC$alone to 144 before the WindowServer restart"
  out=$(sh "$G/b15_boot.sh" $cmd 2>&1); rc=$?; printf '%s\n' "$out"
  [ $rc = 0 ] || { echo "aocboot: b15_boot.sh $cmd rc $rc: the AOC stays at 60"; return 0; }
  sysctl -w debug.phxfb_resync=1 >/dev/null 2>&1; id=$(sysctl -n debug.phxfb_resync 2>/dev/null)
  if [ "$id" = 2 ]; then echo "aocboot: $(date '+%T') head 0 resynced: id 2, VBL $(sysctl -n debug.phxfb_refresh 2>/dev/null) mHz"; return 0; fi
  echo "aocboot: head 0 resync answered '$id', not id 2: the AOC back to 60"
  sh "$G/b15_boot.sh" aocback 2>&1; return 0; }
cg_boot(){
  feat_on cg || return 0
  [ -e "$G/gfx_cg.sh" ] || { echo "cg: $G/gfx_cg.sh missing"; return 0; }
  echo "cg: $(PHXCTL=$G/phxctl.bin sh "$G/gfx_cg.sh" on 2>&1 | tail -1 | cut -c1-120)"; }
# Memory clock hard minimum, on by default (off: $G/phxboot-uclk-off): without the DAL hand-off a UCLK switch under GPU
# load underflows the display (glitches under video decode). U1 (finding 2026-11-26-u1-uclk-dal.md): `uclk.sh pin` = the
# DAL hard minimum at the top UCLK level, what Linux's DC holds while the mode can't take a UCLK switch. The content of
# an old phxboot-uclk (456) is not read. Needs kext >= b75 (the DAL selector); idle_dpm.sh lets it go at the settled
# desktop.
uclk_boot(){
  feat_on uclk || return 0
  [ -e "$G/uclk.sh" ] || { echo "uclk: $G/uclk.sh missing"; return 0; }
  echo "uclk: $(PHXCTL=$G/phxctl.bin sh "$G/uclk.sh" pin 2>&1 | tail -1 | cut -c1-120)"; }
# Idle power root cause: the RLC grants CGCG only once both SDMA engines report idle; never-started engines stay "busy" and
# the card idles at ~150 W with PMFW activity 100 %. Start their queue 0 idle, before cg_boot.
sdma_boot(){
  feat_on sdma || return 0
  [ -e "$G/sdma_idle.sh" ] || { echo "sdma: $G/sdma_idle.sh missing"; return 0; }
  echo "sdma: $(PHXCTL=$G/phxctl.bin sh "$G/sdma_idle.sh" 2>&1 | tail -1 | cut -c1-100)"; }
if [ $UPOK = 1 ]; then   # only on a GPU that came up (gfx_cg.sh polls the RLC)
  [ "${PHXBOOT_NO_SDMA:-0}" = 1 ] || sdma_boot
  [ "${PHXBOOT_NO_CG:-0}" = 1 ] || cg_boot
  [ "${PHXBOOT_NO_UCLK:-0}" = 1 ] || uclk_boot
fi
# AOC at 144 (10-31): with $G/phxboot-m7-aocmodes or -aoc144, PhxAMDFB head 0
# lists the AOC's 60 and 144 Hz modes. It reads the kext's phx-pipe0-modes once, when it starts at the claim below, so the
# kext flag goes up first (kext b101+; an older kext has no such sysctl: one mode as before). The switch itself stays
# refused until b15_boot.sh arms the pipe-0 engine after `done`.
aoc_modes(){ { [ -e "$G/phxboot-m7-aocmodes" ] || [ -e "$G/phxboot-m7-aoc144" ]; } || return 0
  if sysctl -w debug.phxpipe0_modes=1 >/dev/null 2>&1; then echo "aoc: head-0 mode list armed (debug.phxpipe0_modes=1)"
  else echo "aoc: no debug.phxpipe0_modes (kext < b101): head 0 keeps one mode"; fi; }
[ "${PHXBOOT_NO_AOC:-0}" = 1 ] || [ $SAFE = 1 ] || aoc_modes
# 1440p high refresh (2026-11-20, the XTX machine): unless $G/phxboot-p0modes-off the pipe-0 engine is switched on and
# PhxAMDFB head 0 lists the modes of the plan family OTG0 runs (the LG's 2560x1440 at 60/120/144 Hz), so System Settings
# can pick one; it reads phx-pipe0-modes once, at the claim below. Needs VermilionBoot b128 (the 1440p plans: its pipe-0
# stat has dal_sent=) and a PhxAccel with the 1440p mode rows; with older ones nothing is armed (one mode, as before).
# Nothing switches here: a mode change runs only when macOS asks for one. On by default; off: ~/gpu/phxboot-p0modes-off.
p0modes_boot(){ feat_on p0modes || return 0
  sysctl -n debug.phxpipe0_stat 2>/dev/null | grep -q "dal_sent=" || { echo "p0modes: VermilionBoot before b128 (no 1440p plans): nothing armed"; return 0; }
  local o1 o2 r1 r2; o1=$(sysctl -w debug.phxpipe0_enable=1 2>&1); r1=$?; o2=$(sysctl -w debug.phxpipe0_modes=1 2>&1); r2=$?
  if [ $r1 = 0 ] && [ $r2 = 0 ]; then echo "p0modes: pipe-0 engine on, head-0 mode list armed (debug.phxpipe0_enable=1, debug.phxpipe0_modes=1)"
  else echo "p0modes: enable rc $r1, modes rc $r2 ($(echo "$o1 $o2" | tr '\n' ' ' | cut -c1-100)): head 0 may keep one mode"; fi; }
[ "${PHXBOOT_NO_AOC:-0}" = 1 ] || [ $SAFE = 1 ] || p0modes_boot
# Display features of head 0 (docs/XTX.md, "Display settings"). PhxAMDFB reads three sysctls once, when head 0 starts at
# the claim below, so they are written here, before it:
#   debug.phxfb0_vrr     Adaptive Sync, System Settings' "Variable"; on by default    off: $G/phxboot-novrr
#   debug.phxfb0_vrrmin  Variable's lowest rate in Hz; default 60                     set: $G/phxboot-vrrmin
#   debug.phxfb0_hdr     System Settings' "High Dynamic Range"; OFF by default        on:  $G/phxboot-hdr
# Each needs the monitor and a PhxBringup that supports it (b144 / b146 / b145); with an older PhxAccel the sysctl is
# missing and nothing is written.
#
# Adaptive Sync (.agents/findings/2026-11-20-adaptive-sync-research.md): $G/phxboot-novrr turns it off; the safe desktop
# always does (VRR needs GPU present, which it has not).
novrr_boot(){ { [ -e "$G/phxboot-novrr" ] || [ $SAFE = 1 ]; } || return 0
  if sysctl -w debug.phxfb0_vrr=0 >/dev/null 2>&1; then echo "vrr: off (debug.phxfb0_vrr=0: $([ $SAFE = 1 ] && echo 'the safe desktop' || echo "$G/phxboot-novrr"))"
  else echo "vrr: no debug.phxfb0_vrr (PhxAccel before Adaptive Sync): nothing to turn off"; fi; }
novrr_boot
# Adaptive Sync's floor: the XTX machine's LG flickers in Variable near its EDID minimum of 48 Hz (the monitor's own VRR
# behaviour), so PhxAccel's default floor is 60 Hz (the XTX machine's value: no write needed). $G/phxboot-vrrmin holds
# another floor in Hz (24-240; 0 = the EDID's minimum). Not on the safe desktop (no VRR there). macOS sees the floor in
# the EDID PhxAccel serves, so a new value makes it a new display to macOS: its colour profile and per-display settings
# start over.
vrrmin_boot(){ [ -e "$G/phxboot-vrrmin" ] && [ $SAFE = 0 ] || return 0
  local v
  v=$(tr -d ' \t\r\n' <"$G/phxboot-vrrmin" 2>/dev/null)
  case "$v" in 0|2[4-9]|[3-9][0-9]|1[0-9][0-9]|2[0-3][0-9]|240) ;; *)
    echo "vrr: ~/gpu/phxboot-vrrmin holds '$(head -c 20 "$G/phxboot-vrrmin" | tr -d '\r\n')', not 0 or 24-240: PhxAccel's default floor"; return 0;; esac
  if sysctl -w debug.phxfb0_vrrmin=$v >/dev/null 2>&1; then echo "vrr: floor $v Hz (debug.phxfb0_vrrmin=$v: $G/phxboot-vrrmin)"
  else echo "vrr: no debug.phxfb0_vrrmin (PhxAccel before the floor): the EDID's minimum"; fi; }
vrrmin_boot
# HDR (.agents/findings/2026-11-21-hdr.md): OFF by default (2026-11-26: it is broken in this preview); $G/phxboot-hdr
# turns it on to try it; the safe desktop never has it. HDR is offered only together with Adaptive Sync's timing range, so
# $G/phxboot-novrr turns HDR off too. The old $G/phxboot-nohdr is redundant (a note at the start).
nohdr_boot(){ { [ ! -e "$G/phxboot-hdr" ] || [ $SAFE = 1 ]; } || return 0
  if sysctl -w debug.phxfb0_hdr=0 >/dev/null 2>&1; then echo "hdr: off (debug.phxfb0_hdr=0: $([ $SAFE = 1 ] && echo 'the safe desktop' || echo "the default; $G/phxboot-hdr turns it on"))"
  else echo "hdr: no debug.phxfb0_hdr (PhxAccel before HDR): nothing to turn off"; fi; }
nohdr_boot
WS0=$(wspid)                 # the first WindowServer (up since boot; it read com.apple.windowserver before this daemon ran)
"$MB" claim 2>&1; CLAIMED=1
sysctl -w debug.phxbos_flush=0 >/dev/null 2>&1
for i in $(seq 1 20); do ioreg -rc NMXAccel -d0 | grep -q NMXAccel && break; sleep 1; done
if ! ioreg -rc NMXAccel -d0 | grep -q NMXAccel; then
  [ $DESK = 1 ] && m2_fail "NMXAccel did not start"
  trap - TERM; rm -f "$MARK"; sync
  REC_L=skip; rec_save "NMXAccel did not start: no clean fallback boot"
  echo "NMXAccel did not start (apps-only this boot)"; leave
fi
echo "NMXAccel up"

if [ $DESK = 1 ]; then
  rm -f "$DESKTOP"            # one-shot: exactly one desktop attempt per arm
  echo desktop >"$MARK"; sync   # in-progress (since the bring-up): a hang before we finish -> next boot reverts
  # a clean restart or shutdown (launchd sends TERM; a hang never does) is not a failed attempt: clear the mark and
  # re-arm the next boot as SUCCESS would, so a restart from the login window during the watch keeps acceleration
  trap 'echo "clean shutdown (TERM) at $(date "+%T") during the desktop attempt: in-progress mark cleared"; rm -f "$MARK"; disp_log
        feat_on auto && nvram phxfb-squat=1 && echo "phxfb-squat re-armed for the next boot (automatic desktop on)"; sync
        b21_on "shutdown (TERM) during the desktop attempt"; exit 0' TERM
  # 1) PhxAMDFB should already be on the panel (took it at claim via nmxgpu-claimed match).
  pub=0
  for i in $(seq 1 30); do ioreg -rc PhxAMDFB -d0 | grep -q PhxAMDFB && { pub=1; echo "PhxAMDFB on panel after ${i}s"; break; }; nap 1; done
  [ $pub = 1 ] || m2_fail "PhxAMDFB never took the panel (nmxgpu-claimed match)"
  # 2) confirm a LIVE Metal device (clean probe; metaltest logs via NSLog=stderr so merge 2>&1).
  echo "waiting for a live Metal device (clean probe)..."
  mtlok=0
  for i in $(seq 1 40); do
    $RUNAS "$G/metaltest" 2>&1 | grep -q 'Metal devices: 1' && { mtlok=1; echo "Metal device ready after ${i}s"; break; }
    nap 1
  done
  [ $mtlok = 1 ] || m2_fail "Metal device never came up"
  # 3) WindowServer may use Metal + set the Core Image backstop NOW (the restarted WindowServer inherits it).
  all_apps "; WindowServer composites on the GPU (Metal allowed)" ''
  release   # harmless no-op unless -phxfbhold put the hold back
  launchctl setenv CI_USE_MTL_DAG_FOR_CIKL_SRC 0 2>/dev/null   # Core Image backstop (Cobalt64 app-crash-study)
  # 3b) a user must NOT be logged in -- check BEFORE arming, so if someone is in
  #     we touch nothing (no arm, no pipe) and revert clean.
  if who 2>/dev/null | grep -q . ; then m2_fail "a user is logged in before arming -- refusing (log out / stay on the login screen)"; fi
  # (the 11-02 scdclog boot hook was removed 11-03: its data is in)
  [ $SAFE = 1 ] || m7_light
  # 4) arm the display pipe now that the panel is ours and Metal is ready.
  #    same order as the hand-run test that reached the desktop (2026-10-24 17:55)
  # 10-29: debug.phxagdc exists only once PhxAMDFB::start has finished
  # (phxAgdcInstall), and "on panel" above matches while start() still runs: a write before that is lost. Wait for the
  # oid; the poll below writes 1 again while it reads 0.
  for i in $(seq 1 15); do sysctl -n debug.phxagdc >/dev/null 2>&1 && break; nap 1; done
  sysctl -w debug.phxagdc=1 >/dev/null; nap 1
  sysctl -w debug.nvaccel_iop=1 >/dev/null
  sysctl -w debug.nvaccelfb=1 >/dev/null; nap 1
  sysctl -w debug.nvaccelfb=3 >/dev/null; nap 2
  # 4b) AGDC arms ASYNC (thread_call sets gState: 1 ok, <0 fail e.g. -6). Blindly
  #     sleeping then restarting could killall before AGDC is up, or after it silently failed -> WindowServer
  #     comes back in SOFTWARE compositing and we'd falsely print SUCCESS. Poll the readback instead.
  agdc=""
  for i in $(seq 1 15); do
    agdc=$(sysctl -n debug.phxagdc 2>/dev/null || echo "")
    [ "$agdc" = 1 ] && { echo "AGDC up after ${i}s"; break; }
    [ "$agdc" = 0 ] && sysctl -w debug.phxagdc=1 >/dev/null 2>&1
    case "$agdc" in -[0-9]*) m2_fail "AGDC failed to arm (debug.phxagdc=$agdc)";; esac
    nap 1
  done
  [ "$agdc" = 1 ] || m2_fail "AGDC never armed (debug.phxagdc='$agdc' after 15s)"
  echo "armed at $(date '+%T'); agdc=$agdc"
  [ $SAFE = 1 ] || m7_bind
  [ $SAFE = 1 ] || aoc_boot   # boot rate: the AOC at 144 before the restart (flag ~/gpu/phxboot-aoc-rate)
  # 5) ONE clean WindowServer restart. Metal caches an empty device list per process if asked too early, so
  #    WindowServer -- up since boot -- never sees our device until it restarts fresh. Only at 0 interactive users.
  #    final 0-users guard IMMEDIATELY before the killall, nothing slow between arm-confirm and kill, so the
  #    window where the stale-cache boot WindowServer could hit the assert on its own is as small as possible.
  if who 2>/dev/null | grep -q . ; then m2_fail "a user logged in during arm -- refusing the WindowServer restart"; fi
  # 5a) GPU present (2026-10-25): with GPUPRESENT=1 the plugin copies WindowServer's frames into VRAM slots on the GPU
  #     and flips HUBP0 itself (PhxBringup scanout, debug.phxscan); it needs the scanout allowed before WindowServer
  #     comes back, and phxfb's own flip left off (both would program HUBP0)
  #     On by default; off on the safe desktop and with $GPUPRESENT_OFF.
  GPUPRESENT=1; { [ $SAFE = 1 ] || [ -e "$GPUPRESENT_OFF" ]; } && GPUPRESENT=0
  GPUDIR=$(dirname "$GPUPRESENT_OFF")
  for f in ws-gpu-present ws-gpu-present-async ws-direct; do
    [ -e "$GPUDIR/$f" ] && echo "note: $GPUDIR/$f is no longer used (GPU present, async and direct scan-out are on by default; ws-gpu-present-off, ws-gpu-present-async-off and ws-direct-off turn them off)"
  done
  [ $GPUPRESENT = 0 ] && [ $SAFE != 1 ] && echo "gpu present off ($GPUPRESENT_OFF)"
  [ $GPUPRESENT = 1 ] && { sysctl -w debug.phxscan=1 >/dev/null 2>&1 && echo "gpu present allowed (debug.phxscan=1)"; }
  ws_cdcopy    # E3: the restarted WindowServer presents CoreDisplay's display surfaces (off: ~/gpu/phxboot-wscdcopy-off)
  ws_tiled     # C3: the restarted WindowServer composes into a tiled image (flag ~/gpu/phxboot-wstiled)
  waitstep_boot   # the fence wait's timed step for the restarted WindowServer (value file ~/gpu/phxboot-waitstep, off: -waitstep-off)
  irqwait_boot    # fence waits by interrupt for the restarted WindowServer (off: ~/gpu/phxboot-irqwait-off)
  WS1=$(wspid)
  if [ -n "$WS0" ] && [ "$WS1" != "$WS0" ]; then echo "first WindowServer died before the restart (pid $WS0 -> ${WS1:-none}; usually no .ips)"
  else echo "first WindowServer survived to the restart (pid ${WS0:-none})"; fi
  wsp_restore "v4 leftover, before the WindowServer restart"   # once: a v4 (04c751b1) stash goes back to the user's values
  [ -e "$WSPFLAG" ] && echo "wsprefs: $WSPFLAG is no longer used (the kernel offer gate replaced it; rm it)"
  offer_open   # every head-0 mode for the restarted WindowServer
  disp_ovr     # rotation rot15: the highest rate is the default at a new display set (read by the restarted WindowServer)
  b21_off      # login-window guard: the user's SHOWFULLNAME for the accelerated loginwindow the restart brings up
  al_on        # automatic login by the accelerated loginwindow (flag ~/gpu/phxboot-autologin)
  echo "restarting WindowServer once (Metal ready, AGDC up) at $(date '+%T')"
  killall -9 WindowServer 2>/dev/null
  nap 6
  # 5b) the DCN A/B flip (validated 2026-10-24: 0 timeouts in >20k flips) inside the crash watch below;
  #     $G/phxboot-noflip keeps the copy into the scanned surface; GPU present replaces it
  #     with GPU present the display pipe's copy into A is skipped while HUBP0 scans a slot (PhxAccel with
  #     debug.nvaccel_iop_skipforeign; an older PhxAccel has no such sysctl and keeps copying)
  if [ $GPUPRESENT = 1 ]; then echo "phxfb flip left off (GPU present owns HUBP0)"
    sysctl -w debug.nvaccel_iop_skipforeign=1 >/dev/null 2>&1 && echo "display pipe copy skipped while GPU present scans (debug.nvaccel_iop_skipforeign=1)"
  elif [ $SAFE = 0 ] && [ ! -e "$G/phxboot-noflip" ]; then sysctl -w debug.phxfb_flip=1 >/dev/null 2>&1 && echo "flip on (debug.phxfb_flip=1)"; fi
  before=$(ls "$DR" 2>/dev/null | grep -c '^WindowServer[-_]')   # baseline AFTER the clean restart: earlier crashes don't count
  # 11-03: a WindowServer crash often writes NO .ips (12 corpses, 0 files), so a WindowServer
  # pid change also counts (0 users here: no logout restarts it); the verdict uses the larger of the two counts
  wsr=$(wspid); died=0
  echo "watching 120s for crashes with Metal ready (baseline $before .ips, WindowServer pid ${wsr:-none})..."
  for ((t=0;t<120;t+=5)); do nap 5; n=$(( $(ls "$DR" 2>/dev/null | grep -c '^WindowServer[-_]') - before ))
    p=$(wspid); if [ -n "$p" ] && [ "$p" != "$wsr" ]; then died=$((died+1)); echo "watch: WindowServer pid ${wsr:-none} -> $p at $(date '+%T') (a silent crash counts too)"; wsr=$p; fi
    [ $died -gt $n ] && n=$died
    [ $n -ge 3 ] && { gpu_dump "WindowServer crashed/hung $n times"; m2_fail "WindowServer crashed/hung $n times after the clean restart"; }
    disp_log; [ $DARK = 1 ] || disp_check; done
  pgrep -qx WindowServer || m2_fail "no WindowServer after the restart"
  disp_log; [ $DARK = 1 ] || disp_check
  if [ $DARK = 1 ]; then echo "DARK at $(date '+%T'): the accelerated desktop survived, the display engine did not (above)"
  else rm -f "$DARKF"; fi
  [ $DARK = 1 ] || echo "SUCCESS at $(date '+%T'): WindowServer pid $(pgrep -x WindowServer), frames=$(sysctl -n debug.nvaccel_iop_ok 2>/dev/null) -- accelerated desktop survived"
  # the session's shutdown TERM: login-window guard ON for the next boot's first loginwindow, then die of the TERM as before
  trap 'b21_on "shutdown (TERM)"; trap - TERM; kill -TERM $$' TERM; rm -f "$MARK"
  if [ $SAFE = 1 ]; then echo "safe desktop up (the stuck squat stays, nothing re-armed; why: $WHY; the full desktop again $(full_when))"
    safe_notice   # in the background: the daemon keeps running (watch_hangs)
  else
    [ $DARK = 1 ] || { REC_F=0; REC_C=0; REC_B=0; rec_save "SUCCESS"; }
    if feat_on auto; then rearm "automatic desktop on"; fi; fi
  sync
else
  trap - TERM; rm -f "$MARK"; sync   # the GOP boot's bring-up and claim finished
  release; all_apps " (WindowServer stays on firmware framebuffer)" ""
  echo "no desktop arm: GOP + Metal for apps"
  # a GOP boot with the automatic desktop on (no $G/phxboot-auto-off; no kill switch, no unfinished MARK: both exit
  # earlier) re-arms the next boot unless the record says the last accelerated attempt failed and this GOP boot is not
  # yet the last clean fallback boot it asks for (11-02: one lost NVRAM write kept every boot GOP; 2026-11-25: no manual
  # rm, it re-arms by itself)
  if feat_on auto; then
    if [ "$REC_F" -gt 0 ] && [ $((REC_C + 1)) -lt "$(rec_need)" ]; then echo "phxfb-squat NOT re-armed: the last accelerated attempt failed ($FAILS: fails=$REC_F, this is clean fallback boot $((REC_C + 1)) of $(rec_need); it re-arms by itself $(rec_when))"
    else gopnote=""; [ "$REC_F" -gt 0 ] && gopnote=", clean fallback boot $((REC_C + 1)) of $(rec_need) after $REC_F failed attempt(s)"
      if rearm "GOP boot, automatic desktop on$gopnote" && nvram phxfb-squat >/dev/null 2>&1; then
        # (the last boot's own notice, a failure it explains, is shown instead: notice_carry)
        [ -n "$CARRY" ] || notice "Graphics acceleration is ready. Restart to turn on the accelerated desktop."; fi; fi
  fi
fi
echo "done $(date '+%T')"
notice_carry   # the last boot's notice when this one has none (in the background: watch_hangs below never returns)

# WP6 (10-27): unless $G/phxboot-vcn-off, after "done": bring VCN0 up (vcn_up.sh, its own log in $G/vcnup/boot.log),
# let the kext adopt its ring (debug.phxvcn=1) and turn MMHUB VM on (debug.phxmmvm=1) so VCN can decode for apps.
# On by default (off: $G/phxboot-vcn-off); a failure only leaves VCN off (the desktop does not depend on it).
vcn_boot(){
  feat_on vcn || return 0
  [ -x "$G/vcnup/vcn_up.sh" ] || { echo "vcn: $G/vcnup/vcn_up.sh missing"; return 0; }
  if bash "$G/vcnup/vcn_up.sh" --run > "$G/vcnup/boot.log" 2>&1; then
    sysctl -w debug.phxvcn=1 >/dev/null 2>&1 && sysctl -w debug.phxmmvm=1 >/dev/null 2>&1 \
      && echo "vcn: up, ring adopted, MMHUB VM on ($(sysctl -n debug.phxmmvm_stat 2>/dev/null | cut -c1-40))" \
      || echo "vcn: up, but adopt / MMHUB VM failed"
  else
    echo "vcn: bring-up failed ($(tail -1 "$G/vcnup/boot.log")): VCN stays off"
  fi; }
# 10-30: with pipe 1 lit at boot, the first SMU message after it
# (PowerUpVcn, or the late UCLK pin) stalls the PMFW message handler for the rest of the boot. Until that is understood,
# a boot that lit pipe 1 sends no SMU message after `done`: no VCN bring-up, no late UCLK pin (the early pin stays).
# Since then m7_boot.sh aligns OTG1's vblank on OTG0's (exit 0); only an unaligned pipe 1 skips.
if [ "$M7LIT" = 1 ] && [ "$M7PHASE" != 1 ]; then
  feat_on vcn && echo "vcn: skipped: pipe 1 lit at boot (an SMU message then stalls the PMFW)"
else
  [ "${PHXBOOT_NO_VCN:-0}" = 1 ] || [ $SAFE = 1 ] || vcn_boot
fi

# 10-28: unless $G/phxboot-cg-off, after "done": GFX clock gating as Linux enables it (gfx_cg.sh on). Without it the
# idle card runs ~250 W at a 110 C hotspot with the fans at full.
[ "${PHXBOOT_NO_CG:-0}" = 1 ] || cg_boot
if [ "$M7LIT" = 1 ] && [ "$M7PHASE" != 1 ]; then
  feat_on uclk && echo "uclk: late pin skipped: pipe 1 lit at boot (an SMU message then stalls the PMFW)"
else
  [ "${PHXBOOT_NO_UCLK:-0}" = 1 ] || uclk_boot
fi
# 11-01: hot-plug and gamma (defined next to m7_bind): after the one WindowServer restart and its crash watch, so neither
# can blur that verdict; before b15_boot starts, so these one-time writes never overlap its recipe.
hotplug_boot
hotplug0_boot   # 11-04: the AOC's hot-plug level (flag ~/gpu/phxboot-hotplug0), after the Acer's
gamma_boot
dpwatch_boot   # 11-03 S3: after hotplug / gamma, before b15 (flag ~/gpu/phxboot-dpwatch)

# 10-29: with $G/phxboot-b15 present, on a desktop boot after the late cg/uclk calls: the display power recipe
# (watermarks, DET, DAL WM table, HUBP0 DLG) then stutter allowed, with an underflow watchdog that stays in the background
# for the whole boot (b15_boot.sh). Its output goes to this log.
b15_boot(){
  [ -e "$G/phxboot-b15" ] || return 0
  [ $DESK = 1 ] || { echo "b15: not a desktop boot: skip"; return 0; }
  [ -e "$G/b15_boot.sh" ] || { echo "b15: $G/b15_boot.sh missing"; return 0; }
  sh "$G/b15_boot.sh" & echo "b15: started (pid $!)"; }
[ "${PHXBOOT_NO_B15:-0}" = 1 ] || [ $SAFE = 1 ] || b15_boot
# 2026-11-23 (thread 02, the XTX machine): unless $G/phxboot-idledpm-off, on a one-display desktop boot: memory and
# fabric clocks free to drop at idle under an underflow watchdog for the whole boot (idle_dpm.sh; b15's step 6 for one
# display). Not with b15 (its own recipe) and not after a pipe-1 boot (an SMU message then stalls the PMFW, above).
idledpm_boot(){
  feat_on idledpm || return 0
  [ $DESK = 1 ] || { echo "idledpm: not a desktop boot: skip"; return 0; }
  [ -e "$G/phxboot-b15" ] && { echo "idledpm: phxboot-b15 present (its own recipe): skip"; return 0; }
  [ "$M7LIT" = 1 ] && [ "$M7PHASE" != 1 ] && { echo "idledpm: pipe 1 lit at boot: skip (UCLK stays pinned)"; return 0; }
  [ -e "$G/idle_dpm.sh" ] || { echo "idledpm: $G/idle_dpm.sh missing"; return 0; }
  PHXBOOT_G=$G sh "$G/idle_dpm.sh" & echo "idledpm: started (pid $!)"; }
[ "${PHXBOOT_NO_IDLEDPM:-0}" = 1 ] || [ $SAFE = 1 ] || idledpm_boot
# 2026-11-23 (thread 02 part B): on a desktop boot, VermilionBoot b156's VRAM-backed BOs for the processes named in
# $G/phxboot-bovram (comma-separated, e.g. "vkbench,metalbench"). The feature is on by default (off:
# $G/phxboot-bovram-off), but without the file the list is $BOVRAM_DEFAULT, which names no process: one log line, no
# sysctl write. The kext's self-test first
# (debug.phxbo_vram_selftest=1 must read 1), then debug.phxbo_vram_proc and debug.phxbo_vram=1, each read back. Names:
# letters, digits, . _ - and space, at most 127 characters; WindowServer is refused (it stays on the proven path until
# M3). Measured on the XTX machine: 42.9 -> 840.9 GB/s buffer bandwidth, new buffers zero (VRAM BO design note).
BOVRAM_DEFAULT=""   # no process by default (a general rule needs a measurement); ~/gpu/phxboot-bovram names them
bovram_boot(){
  feat_on bovram || return 0
  [ $DESK = 1 ] || { echo "bovram: not a desktop boot: skip"; return 0; }
  local v st
  if [ -e "$G/phxboot-bovram" ]; then v=$(head -c 200 "$G/phxboot-bovram" 2>/dev/null | tr -d '\r\n' | sed 's/^ *//; s/ *$//'); else v=$BOVRAM_DEFAULT; fi
  [ -e "$G/phxboot-bovram" ] || [ -n "$v" ] || { echo "bovram: no process list (~/gpu/phxboot-bovram): off"; return 0; }
  case "$v" in ''|*[!A-Za-z0-9._,\ -]*) echo "bovram: ~/gpu/phxboot-bovram holds '$(echo "$v" | cut -c1-40)': not a list of process names: off"; return 0;; esac
  [ ${#v} -le 127 ] || { echo "bovram: the name list is over 127 characters: off"; return 0; }
  case ",$v," in *,WindowServer,*) echo "bovram: WindowServer stays on system memory (M3): off"; return 0;; esac
  sysctl -n debug.phxbo_vram_selftest >/dev/null 2>&1 || { echo "bovram: VermilionBoot before b156: off"; return 0; }
  sysctl -w debug.phxbo_vram_selftest=1 >/dev/null 2>&1; st=$(sysctl -n debug.phxbo_vram_selftest 2>/dev/null)
  [ "$st" = 1 ] || { echo "bovram: self-test reads '$st', not 1: VRAM BOs stay off"; return 0; }
  sysctl -w debug.phxbo_vram_proc="$v" >/dev/null 2>&1 && [ "$(sysctl -n debug.phxbo_vram_proc 2>/dev/null)" = "$v" ] \
    || { echo "bovram: debug.phxbo_vram_proc not set: off"; return 0; }
  if sysctl -w debug.phxbo_vram=1 >/dev/null 2>&1 && [ "$(sysctl -n debug.phxbo_vram 2>/dev/null)" = 1 ]; then
    echo "bovram: on for $v (self-test 1)"
  else echo "bovram: debug.phxbo_vram=1 refused: off"; fi; }
[ "${PHXBOOT_NO_BOVRAM:-0}" = 1 ] || [ $SAFE = 1 ] || bovram_boot
# 2026-11-23 (thread 03): unless $G/phxboot-gl-off, on a desktop boot: OpenGL over Metal (VermilionAccel's
# debug.phxgl=1, which publishes IOGLBundleName=AppleMetalOpenGLRenderer on NMXAccel), read back. Only OpenGL processes
# started afterwards use it; `sysctl -w debug.phxgl=0` turns it off for new processes without a restart. Seen on the XTX
# machine: the renderer "AMD Radeon RX 7900 XTX (RADV NAVI31) ... 4.1 Metal" instead of the Apple Software Renderer,
# Minecraft 26.3 on it.
gl_boot(){
  feat_on gl || return 0
  [ $DESK = 1 ] || { echo "gl: not a desktop boot: skip"; return 0; }
  sysctl -n debug.phxgl >/dev/null 2>&1 || { echo "gl: VermilionAccel without debug.phxgl: off"; return 0; }
  if sysctl -w debug.phxgl=1 >/dev/null 2>&1 && [ "$(sysctl -n debug.phxgl 2>/dev/null)" = 1 ]; then
    echo "gl: OpenGL over Metal on"
  else echo "gl: debug.phxgl=1 refused: off"; fi; }
[ "${PHXBOOT_NO_GL:-0}" = 1 ] || [ $SAFE = 1 ] || gl_boot
# 2026-11-24 (thread 04): unless $G/phxboot-audio-off, on a desktop boot: DP audio on head 0, as a real Mac with an AMD
# GPU has it. First the display engine's audio blocks from the monitor's EDID ($G/phxaudio apply: Linux DC's sequence
# for DIG1; its full output in $G/phxaudio.log), then Apple's AppleGFXHDA on the GPU's audio function ($G/audio_match.sh
# on, which needs VermilionAudio 1.6.0 in the EFI and waits for the audio engine). Once per boot, never undone: a detach
# makes the next attach hot-reset the whole GPU (findings/2026-11-24-gfxhda-detach-gpu-hot-reset.md).
audio_boot(){
  feat_on audio || return 0
  [ $DESK = 1 ] || { echo "audio: not a desktop boot: skip"; return 0; }
  sysctl -n debug.phxaudio_match >/dev/null 2>&1 || { echo "audio: VermilionAudio not loaded (not in the EFI, or -phxaudiooff): off"; return 0; }
  { [ -x "$G/phxaudio" ] && [ -e "$G/audio_match.sh" ]; } || { echo "audio: $G/phxaudio or $G/audio_match.sh missing: off"; return 0; }
  if ! "$G/phxaudio" apply >"$G/phxaudio.log" 2>&1; then
    echo "audio: display engine not programmed ($(tail -1 "$G/phxaudio.log")): AppleGFXHDA not attached"; return 0
  fi
  echo "audio: display engine programmed ($(tail -1 "$G/phxaudio.log" | sed 's/^phxaudio: //'))"
  sh "$G/audio_match.sh" on 2>&1; }
[ "${PHXBOOT_NO_AUDIO:-0}" = 1 ] || [ $SAFE = 1 ] || audio_boot

# 11-03: a WindowServer pid change counts as a crash only with the kernel's "WindowServer[pid] Corpse allowed" line for the
# old pid (a logout also restarts WindowServer, cleanly); .ips files alone missed silent crashes
watch_hangs(){ local base n now first=0 wsp p c silent=0 it=0
  base=$(ls "$DR" 2>/dev/null | grep -c '^WindowServer-.*\.ips$'); wsp=$(wspid)
  while nap 15; do
    it=$((it+1)); [ -n "${PHXBOOT_WATCH_MAX:-}" ] && [ $it -gt "$PHXBOOT_WATCH_MAX" ] && return 0
    dpwatch_check   # 11-03 S3: the DP stream watcher's new STUCK / recovery / fix events into this log
    p=$(wspid)
    if [ -n "$p" ] && [ -n "$wsp" ] && [ "$p" != "$wsp" ]; then
      c=$("$LOGCMD" show --last 60s --style compact --predicate 'eventMessage CONTAINS "Corpse"' 2>/dev/null | grep -c "WindowServer\[$wsp\] Corpse")
      if [ "${c:-0}" -gt 0 ]; then silent=$((silent+1)); echo "$(date '+%F %T') WindowServer pid $wsp crashed (kernel corpse; now pid $p)"
      else echo "$(date '+%F %T') WindowServer pid $wsp -> $p with no kernel corpse (a logout or a clean restart): not counted"; fi
    fi; [ -n "$p" ] && wsp=$p
    n=$(( $(ls "$DR" 2>/dev/null | grep -c '^WindowServer-.*\.ips$') - base )); [ $silent -gt $n ] && n=$silent
    n=$((n+base)); [ $n -gt $base ] || continue
    now=$(date +%s); [ $first = 0 ] && first=$now
    if [ $((n-base)) -ge 2 ]; then
      echo "$(date '+%F %T') WindowServer hung $((n-base))x on GPU: reverting to GOP"; b21_on "revert to GOP after the hangs"; gpu_dump "WindowServer hung $((n-base))x"; rec_fail "WindowServer hung $((n-base))x"; oneshots_off   # the mark is already gone (SUCCESS)
      [ $SQUAT = 1 ] && { squat_reboot "squat boot: rebooting onto IONDRV" "$RESTARTED" || { echo "stuck squat: staying up after the hangs (no reboot can leave the squat)"; return; }; }
      notice_next "$RESTARTED"; shutdown -r now; return
    fi
    [ $((now-first)) -gt 300 ] && { base=$(ls "$DR" 2>/dev/null | grep -c '^WindowServer-.*\.ips$'); silent=0; first=0; }
  done; }
[ "${PHXBOOT_NO_WATCH:-0}" = 1 ] || { [ $DESK = 1 ] && watch_hangs; }
notice_join   # a notice still waiting for a login (the daemon has nothing else to do)
