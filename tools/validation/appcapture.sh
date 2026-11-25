#!/bin/bash
# SPDX-License-Identifier: MIT
# appcapture.sh <process> <label> [seconds]: one read-only capture of where a running app's frames go, while the owner
# uses the app (finding 2026-11-25-maps-fullscreen-perf.md). Changes nothing on the GPU, the display or the app.
#
#   sudo bash tools/validation/appcapture.sh Maps window 20
#   sudo bash tools/validation/appcapture.sh Maps fullscreen 20
#
# For [seconds] (default 20) it records:
#   - per second: frames WindowServer showed (debug.nvaccel_iop_ok), CPU % of the app and of WindowServer;
#   - a CPU sample (`sample`, 1 ms) of the app and of WindowServer over the middle of the window;
#   - the plugin's log lines (subsystem org.vermilion.nvmtl) of the app and WindowServer;
#   - named read-only kext counters before and after (never a whole sysctl tree: debug.phxedid and debug.phxshot act
#     on the hardware when read);
#   - SMU=1 (default): GPU activity, clocks and power once a second (~/gpu/smumetrics.py: the SMU's metrics-table
#     transfer that Linux amdgpu also sends, a read; the owner allowed SMU-metric reads);
#   - GPUTIME=1 (off by default, the megamind's call): GPU time per process (debug.phxgpu_time_on=1 for the window,
#     then back to 0). It adds two timestamp packets to every submission while on (b157), so it is not a pure read.
# Output: $APPCAP_OUT (default ~/vermilion-captures/<date>-appcap)/<label>-<time>/, owned by the calling user. It may
# hold the app's log lines (Maps: places): keep it out of git.
# Bash 3.2 (macOS /bin/bash). Needs root (sample of WindowServer, smumetrics, the GPUTIME switch).
set -u
APP=${1:?usage: appcapture.sh <process> <label> [seconds]}
LABEL=${2:?usage: appcapture.sh <process> <label> [seconds]}
DUR=${3:-20}
SMU=${SMU:-1}; GPUTIME=${GPUTIME:-0}
LOG=/usr/bin/log            # zsh has a `log` builtin; always call the binary
SYSCTL=/usr/sbin/sysctl
OWNER=${SUDO_USER:-$(id -un)}
HOMEDIR=$(eval echo "~$OWNER")
OUT=${APPCAP_OUT:-$HOMEDIR/vermilion-captures/$(date +%F)-appcap}/$LABEL-$(date +%H%M%S)

[ "$(id -u)" = 0 ] || { echo "appcapture: run it with sudo (WindowServer's sample and the SMU metrics need root)"; exit 1; }
case "$DUR" in ''|*[!0-9]*) echo "appcapture: seconds must be a number"; exit 1;; esac
[ "$DUR" -ge 6 ] || DUR=6
pid=$(pgrep -x "$APP" | head -1)
[ -n "$pid" ] || { echo "appcapture: no process named $APP is running"; exit 1; }
ws=$(pgrep -x WindowServer | head -1)
mkdir -p "$OUT" || exit 1

# Read-only OIDs only, by name.
STATE="debug.phxtrust_files debug.phxbo_vram debug.phxbo_vram_proc debug.phxwait_irq debug.phxfb0_vrr debug.phxfb0_hdr"
COUNTERS="debug.phxvm debug.phxbo_stats debug.phxbo_vram_stat debug.phxwait_stat debug.phxwait_lat debug.phxirq_stat
debug.phxscan_race_stat debug.phxcalls debug.phxpt_stat debug.nvaccel_iop_ok debug.nvaccel_iop_fail debug.nvaccel_iop_empty
debug.nvaccel_iop_src_surf debug.nvaccel_iop_copy_us_sum debug.nvaccel_iop_gap1 debug.nvaccel_iop_gap2
debug.nvaccel_iop_gap3 debug.nvaccel_iop_gap4 debug.phxgpu_time"
get() { $SYSCTL -n "$1" 2>/dev/null || echo "-"; }
snap() { local o; for o in $COUNTERS; do printf '%s: %s\n' "$o" "$(get "$o")"; done > "$OUT/counters-$1.txt"; }
# CPU time used so far by a process, in ms (ps prints [[d-]h:]m:ss.ss; the % column is a decaying average)
cpums() { ps -o time= -p "$1" 2>/dev/null | awk -F'[-:]' '{ t = 0; for (i = 1; i <= NF; i++) t = t * 60 + $i; printf "%d", t * 1000 }'; }

{
  echo "appcapture $APP ($pid) label $LABEL, ${DUR}s, $(date '+%F %T'); WindowServer $ws"
  echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)); up $(( ($(date +%s) - $($SYSCTL -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')) / 60 )) min"
  for o in $STATE; do printf '%s: %s\n' "$o" "$(get "$o")"; done
  echo "SMU=$SMU GPUTIME=$GPUTIME"
} > "$OUT/info.txt"

start=$(date '+%F %T')
snap before
gt=0
if [ "$GPUTIME" = 1 ] && [ "$(get debug.phxgpu_time_on)" = 0 ]; then
  $SYSCTL -w debug.phxgpu_time_on=1 >/dev/null && $SYSCTL -w debug.phxgpu_time_reset=1 >/dev/null && gt=1
fi

# the samples cover the middle of the window: start 2 s in, end 2 s before the end
sdur=$((DUR - 4))
( sleep 2; sample "$pid" "$sdur" 1 -mayDie -file "$OUT/sample-$APP.txt" >/dev/null 2>&1 ) &
s1=$!
( sleep 2; [ -n "$ws" ] && sample "$ws" "$sdur" 1 -mayDie -file "$OUT/sample-WindowServer.txt" >/dev/null 2>&1 ) &
s2=$!
smu=""
if [ "$SMU" = 1 ] && [ -x "$HOMEDIR/gpu/phxctl.bin" ] && [ -f "$HOMEDIR/gpu/smumetrics.py" ]; then
  SMU_CLOCKS= python3 "$HOMEDIR/gpu/smumetrics.py" "$DUR" 1 > "$OUT/smu.txt" 2>&1 &
  smu=$!
fi

echo "t_s frames_shown app_cpu_% ws_cpu_% (CPU % = ms of CPU time in that second / 10)" > "$OUT/per-second.txt"
prev=$(get debug.nvaccel_iop_ok); pa=$(cpums "$pid"); pw=$(cpums "$ws")
i=0
while [ $i -lt "$DUR" ]; do
  sleep 1; i=$((i + 1))
  cur=$(get debug.nvaccel_iop_ok)
  f="-"; case "$prev$cur" in *[!0-9]*) ;; *) f=$((cur - prev));; esac
  prev=$cur
  ca=$(cpums "$pid"); cw=$(cpums "$ws")
  echo "$i $f $(( (${ca:-0} - ${pa:-0}) / 10 )) $(( (${cw:-0} - ${pw:-0}) / 10 ))" >> "$OUT/per-second.txt"
  pa=$ca; pw=$cw
done
ps -M -p "$pid" > "$OUT/threads-$APP.txt" 2>&1
wait $s1 $s2 2>/dev/null
[ -n "$smu" ] && wait $smu 2>/dev/null

snap after
if [ $gt = 1 ]; then
  get debug.phxgpu_time > "$OUT/gputime.txt"
  $SYSCTL -w debug.phxgpu_time_on=0 >/dev/null
fi
end=$(date '+%F %T')
$LOG show --style compact --start "$start" --end "$end" \
  --predicate "subsystem == \"org.vermilion.nvmtl\" AND (process == \"$APP\" OR process == \"WindowServer\")" \
  > "$OUT/nvmtl-log.txt" 2>&1

# one-screen summary
{
  cat "$OUT/info.txt"
  echo "-- per second (frames WindowServer showed, CPU %)"
  cat "$OUT/per-second.txt"
  awk 'NR > 1 && $2 ~ /^[0-9]+$/ { n++; s += $2; a += $3; w += $4 }
       END { if (n) printf "mean: %.0f frames/s shown, %s %.0f %% CPU, WindowServer %.0f %% CPU\n", s / n, "'"$APP"'", a / n, w / n }' "$OUT/per-second.txt"
  [ -s "$OUT/smu.txt" ] && { echo "-- SMU"; cat "$OUT/smu.txt"; }
  [ -s "$OUT/gputime.txt" ] && { echo "-- GPU time per process"; cat "$OUT/gputime.txt"; }
  echo "-- plugin census lines in the window"
  grep -E 'census|high-water|slowest|REFUSED|FAILED|nil' "$OUT/nvmtl-log.txt" | sed -E 's/^([0-9-]+ [0-9:.]+) [^ ]+ ([^[]+)\[[^]]*\] \[[^]]*\] NVMTL: /\1 \2 /' | cut -c1-260 | tail -40
  for s in "$OUT"/sample-*.txt; do
    [ -f "$s" ] || continue
    echo "-- $(basename "$s"): heaviest stack frames"
    sed -n '/^Sort by top of stack/,/^$/p' "$s" | head -30
  done
} > "$OUT/summary.txt"
chown -R "$OWNER" "$(dirname "$OUT")" 2>/dev/null
echo "appcapture: $OUT/summary.txt"
