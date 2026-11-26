#!/bin/bash
# SPDX-License-Identifier: MIT
# uclk_test.sh: tools/phxctl/uclk.sh (U1, finding 2026-11-26-u1-uclk-dal.md) against a fake phxctl.bin and a fake sudo.
# No hardware. The fake answers `smu <msg> <arg>` in phxctl's own line format, models the PMFW's DAL answers (the version,
# the UCLK DPM table 96 / 456 / 772 / 1249, the hard min, the hard-min status bits, a busy mailbox) and logs every message;
# a driver-mailbox message (msg below 0x10000) is logged as DRIVER and refused, as kext b167 refuses 0x1B. Each scenario:
# which messages went out, in which order, the printed line and the exit code. Run with bash or sh; exit 0 iff all pass.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); SRC=${UCLK_SRC:-$HERE/../../tools/phxctl/uclk.sh}
. "$HERE/lib/portable.sh"
SCR=$(mktemp -d "$MOCKTMP/uclk.XXXXXX"); PASSN=0; FAILN=0
setup() {   # setup <name>: a fresh world in $W; the knobs below are files the fake reads
  W=$SCR/$1; mkdir -p "$W/bin" "$W/k"; : >"$W/sent.log"; : >"$W/sleep.log"; echo 0 >"$W/n"
  cat >"$W/bin/phxctl.bin" <<'EOF'
#!/bin/bash
W=$(dirname "$0")/..; K=$W/k
kv() { cat "$K/$1" 2>/dev/null || echo "$2"; }
[ "$1" = smu ] || { echo "phxctl: $1 not modelled"; exit 1; }
msg=$(($2)); arg=$(($3)); n=$(($(cat "$W/n") + 1)); echo $n >"$W/n"
line() { printf 'smu %-22s msg 0x%02x arg 0x%08x -> kr 0x%08x resp 0x%02x (%s) out 0x%08x\n' "" $msg $arg $(($1)) $(($2)) "$3" $(($4)); }
if [ $msg -lt $((0x10000)) ]; then echo "DRIVER $(printf 0x%x $msg) $(printf 0x%x $arg)" >>"$W/sent.log"; line 0xe00002e2 0 "no response" 0; exit 0; fi
if [ $n -le "$(kv busy 0)" ]; then echo "BUSY $(printf 0x%x $msg)" >>"$W/sent.log"; line 0xe00002d5 0 "no response" 0; exit 0; fi
id=$((msg & 0xFFFF)); echo "DAL $(printf 0x%x $id) $(printf 0x%x $arg)" >>"$W/sent.log"
[ "$(kv fail_id -)" = "$(printf 0x%x $id)" ] && { line 0 0xff Failed 0; exit 0; }
case $id in
  2) line 0 1 OK "$(kv ver 0x004E8700)" ;;
  11) [ $((arg >> 16)) = 2 ] || { line 0 0xff Failed 0; exit 0; }
      i=$((arg & 0xFF))
      if [ $i = 255 ]; then line 0 1 OK "$(kv count 4)"
      else set -- $(kv levels "96 456 772 1249"); shift $i; line 0 1 OK "${1:-0}"; fi ;;
  9) line 0 "$(kv hm_resp 1)" "$( [ "$(kv hm_resp 1)" = 1 ] && echo OK || echo Failed)" $((arg & 0xFFFF)) ;;
  21) s=$(($(cat "$K/polls" 2>/dev/null || echo 0) + 1)); echo $s >"$K/polls"
      if [ $s -gt "$(kv status_after 0)" ] && [ ! -e "$K/status_never" ]; then line 0 1 OK 0x24; else line 0 1 OK "$(kv status_pending 0x04)"; fi ;;
  *) line 0 0xfe UnknownCmd 0 ;;
esac
EOF
  cat >"$W/bin/sudo" <<EOF
#!/bin/bash
while [ "\${1:-}" = -n ] || [ "\${1:-}" = -E ]; do shift; done
[ "\${1:-}" = "$W/bin/phxctl.bin" ] && exec "\$@"
echo "sudo \$*" >>"$W/sent.log"
EOF
  printf '#!/bin/sh\necho "sleep $*" >>"%s/sleep.log"\n' "$W" >"$W/bin/sleep"
  chmod +x "$W/bin/"*
}
knob() { echo "$2" >"$W/k/$1"; }
run() {   # run <args...>: uclk.sh in $W; stdout+stderr in $W/out, exit code in RC
  PATH="$W/bin:$PATH" HOME=$W PHXCTL=$W/bin/phxctl.bin sh "$SRC" "$@" >"$W/out" 2>&1; RC=$?; }
check() {   # check <name> <condition>
  local name=$1; shift
  if eval "$@"; then PASSN=$((PASSN + 1)); echo "PASS  $name"; else FAILN=$((FAILN + 1)); echo "FAIL  $name (rc $RC)"; sed 's/^/        /' "$W/out" "$W/sent.log"; fi; }
has() { grep -q -- "$1" "$W/$2"; }
sent() { grep -v '^BUSY' "$W/sent.log" | tr '\n' ,; }
nodriver() { ! grep -q '^DRIVER' "$W/sent.log"; }
TABLE="DAL 0x2 0x0,DAL 0xb 0x200ff,DAL 0xb 0x20000,DAL 0xb 0x20001,DAL 0xb 0x20002,DAL 0xb 0x20003,"

# pin: the version, the table, the hard min at the top level (1249 = 0x4e1), one status read with UCLK + DPREFCLK done
setup pin; run pin
check pin_top '[ $RC = 0 ] && [ "$(sent)" = "${TABLE}DAL 0x9 0x204e1,DAL 0x15 0x0," ] && nodriver && [ "$(wc -l <"$W/out")" -eq 1 ] && has "UCLK 1249 MHz (top; levels 96 456 772 1249): (OK), status 0x24 done" out'
# unpin: level 0 (96 = 0x60), what Linux sends after every mode set on this card
setup unpin; run unpin
check unpin_level0 '[ $RC = 0 ] && [ "$(sent)" = "${TABLE}DAL 0x9 0x20060,DAL 0x15 0x0," ] && nodriver && has "UCLK 96 MHz (level 0" out && has "(OK)" out'
# pin 456 (older callers: idle_dpm.sh before U1, b15_boot.sh): the MHz is not used, the top level still goes out
setup pin456; run pin 456
check pin_mhz_ignored '[ $RC = 0 ] && has "DAL 0x9 0x204e1" sent.log && ! has "0x201c8" sent.log && has "not used" out && nodriver'
# the PMFW reports the hard minimum done on the fourth status read: four reads, 10 ms apart
setup slow; knob status_after 3; run pin
check status_polled '[ $RC = 0 ] && [ "$(grep -c "DAL 0x15" "$W/sent.log")" = 4 ] && [ "$(grep -c "sleep 0.01" "$W/sleep.log")" = 3 ] && has "status 0x24 done" out'
# never done: bounded (UCLK_STATUS_TRIES), reported, the hard minimum itself still acknowledged
setup never; : >"$W/k/status_never"; UCLK_STATUS_TRIES=5 run pin
check status_bounded '[ $RC = 0 ] && [ "$(grep -c "DAL 0x15" "$W/sent.log")" = 5 ] && has "not confirmed" out && has "(OK)" out'
# a status read not answered OK: Linux stops there (the read counts as the whole 2 s); the hard minimum stays acknowledged
setup statusfail; knob fail_id 0x15; run pin
check status_read_fails '[ $RC = 0 ] && [ "$(grep -c "DAL 0x15" "$W/sent.log")" = 1 ] && [ ! -s "$W/sleep.log" ] && has "read not answered" out && has "(OK)" out'
# the UCLK bit without DPREFCLK's is not done yet: Linux waits for both (CHECK_HARD_MIN_CLK_DPREFCLK | _UCLK)
setup uclkbit; knob status_after 2; knob status_pending 0x20; run pin
check status_both_bits '[ $RC = 0 ] && [ "$(grep -c "DAL 0x15" "$W/sent.log")" = 3 ] && has "status 0x24 done" out'
# a PMFW before 0x4E6A00: Linux asks no status (dcn32_get_hard_min_status_supported)
setup oldfw; knob ver 0x004E6900; run pin
check old_pmfw_no_status '[ $RC = 0 ] && ! has "DAL 0x15" sent.log && has "not asked (PMFW 0x4E6900" out && has "DAL 0x9 0x204e1" sent.log'
# the kext answers busy three times (a DAL message in flight): tried again every 10 ms, then the same messages
setup busy; knob busy 3; run pin
check busy_retried '[ $RC = 0 ] && [ "$(grep -c "^BUSY" "$W/sent.log")" = 3 ] && [ "$(sent)" = "${TABLE}DAL 0x9 0x204e1,DAL 0x15 0x0," ]'
# busy for longer than the bound: nothing answered, no hard minimum, no "(OK)", exit 1
setup busylong; knob busy 99; UCLK_BUSY_TRIES=4 run pin
check busy_bounded '[ $RC = 1 ] && ! has "DAL 0x9" sent.log && ! has "(OK)" out && [ "$(grep -c "^BUSY" "$W/sent.log")" = 5 ]'
# the PMFW refuses the hard minimum: exit 1, no "(OK)" (idle_dpm.sh pins again on that), no status read
setup refused; knob hm_resp 0xff; run unpin
check hardmin_refused '[ $RC = 1 ] && has "DAL 0x9 0x20060" sent.log && ! has "DAL 0x15" sent.log && ! has "(OK)" out && has "not acknowledged" out'
# GetSmuVersion unanswered: Linux then sends the PMFW nothing (smu_present false): nothing more goes out
setup nover; knob fail_id 0x2; run pin
check no_version_nothing_sent '[ $RC = 1 ] && [ "$(sent)" = "DAL 0x2 0x0," ] && ! has "(OK)" out'
# no UCLK level reported: no table, no hard minimum
setup nolevels; knob count 0; run pin
check no_table '[ $RC = 1 ] && ! has "DAL 0x9" sent.log && has "no table" out'
# more levels than Linux's table holds (MAX_NUM_DPM_LVL 16): a garbage count, no table
setup manylevels; knob count 17; run pin
check too_many_levels '[ $RC = 1 ] && ! has "DAL 0x9" sent.log && [ "$(grep -c "DAL 0xb" "$W/sent.log")" = 1 ] && has "17 UCLK levels" out'
# a level that reads 0 MHz: no table, no hard minimum
setup zerolevel; knob levels "96 0 772 1249"; run pin
check zero_level '[ $RC = 1 ] && ! has "DAL 0x9" sent.log && has "level 1 reads 0 MHz" out'
# fine-grained DPM (bit 31): two levels, index 0 and 1, the top = index 1
setup fine; knob count 0x80000004; knob levels "96 1249"; run pin
check fine_grained '[ $RC = 0 ] && [ "$(grep -c "DAL 0xb 0x2000" "$W/sent.log")" = 2 ] && has "DAL 0x9 0x204e1" sent.log && has "levels 96 1249)" out'
# levels: the table only, no hard minimum
setup levels; run levels
check levels_read_only '[ $RC = 0 ] && [ "$(sent)" = "$TABLE" ] && has "96 456 772 1249; PMFW 0x4E8700" out'
# anything else: usage, nothing sent
setup usage; run 456
check usage '[ $RC = 2 ] && [ ! -s "$W/sent.log" ] && has usage out'

echo "RESULT: $PASSN passed, $FAILN failed"; [ $FAILN = 0 ] && rm -rf "$SCR"; [ $FAILN = 0 ]
