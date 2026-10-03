#!/usr/bin/env bash
# Live drive of bin/fm-watch-arm.sh's stalled-owned-child retirement contract.
#
# Drives the real product component (the arm script plus the real watcher it
# forks) in a disposable home, exactly as a persistent adapter (Pi / OpenCode /
# Claude stop-autoarm) runs it - as a tracked child of its own process - and
# prints an explicit transcript of the observable behavior:
#   1. a wedged (SIGSTOPped, stale-beacon) owned watcher is retired within a
#      bound and the arm fails loudly with its typed line,
#   2. the SAME session's next arm surfaces the accepted downtime - no session
#      restart,
#   3. adversarial over-retirement check: a healthy owned watcher is NOT retired
#      and keeps advancing its beacon across the arm's grace.
set -u

WT=${WT:?set WT to the worktree root}
EV=${EV:?set EV to the evidence dir}
# shellcheck source=tests/wake-helpers.sh
. "$WT/tests/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot live-drive) || { echo "FAIL: could not make a temp root"; exit 1; }

WATCH_ARM="$WT/bin/fm-watch-arm.sh"
LIB="$WT/bin/fm-wake-lib.sh"
DRAIN="$WT/bin/fm-wake-drain.sh"

section() { printf '\n===== %s =====\n' "$1"; }

# The same acknowledgement handshake tests/fm-watcher-lock.test.sh uses.
drain_and_ack() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

dir=$(make_case live-wedge)
state="$dir/state"
fakebin="$dir/fakebin"

# The arm is a direct child of this shell, so this driver can wait on it the way
# an adapter does. The env is the suite's fast cadence so a wedge is observable
# in seconds rather than the production 300s grace.
ARM_PID=
start_arm() {  # <outfile> <errfile>
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_GUARD_GRACE=5 FM_ARM_CONFIRM_TIMEOUT=30 FM_ARM_ATTACH_POLL=0.05 \
    FM_POLL=0.1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH_ARM" > "$1" 2> "$2" &
  ARM_PID=$!
}

wait_for_line() {  # <file> <pattern> <max-tenths>
  local f=$1 pat=$2 max=$3 i=0
  while [ "$i" -lt "$max" ]; do
    grep -qF "$pat" "$f" 2>/dev/null && return 0
    grep -qF 'watcher: FAILED' "$f" 2>/dev/null && return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

dump_arm() {  # <stdout-file> <stderr-file>
  echo "--- arm stdout ---"; cat "$1" 2>/dev/null || true
  echo "--- arm stderr ---"; cat "$2" 2>/dev/null || true
}

########################################################################
section "S1: retire a wedged owned watcher within a bound (no session restart)"
arm1out="$dir/arm1.out"; arm1err="$dir/arm1.err"
start_arm "$arm1out" "$arm1err"; arm1=$ARM_PID
if ! wait_for_line "$arm1out" 'watcher: started pid=' 650; then
  echo "RESULT: FAIL - arm never confirmed a started watcher"
  dump_arm "$arm1out" "$arm1err"
  exit 1
fi
watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
echo "arm confirmed:   $(grep -F 'watcher: started pid=' "$arm1out")"
echo "owned watcher:   pid=$watcher_pid pgid=$(ps -o pgid= -p "$watcher_pid" 2>/dev/null | tr -d ' ') (arm pid=$arm1)"

kill -STOP "$watcher_pid" 2>/dev/null || { echo "RESULT: FAIL - could not SIGSTOP the watcher"; exit 1; }
touch -t 200001010000 "$state/.last-watcher-beat"
beat_age=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_path_age "$2"' _ "$LIB" "$state/.last-watcher-beat")
echo "wedge:           SIGSTOP + beacon backdated; beacon age ${beat_age}s vs grace 5s"

t0=$(date +%s)
wait_for_exit "$arm1" 400; rc1=$?
t1=$(date +%s)
echo "--- arm stdout ---"
cat "$arm1out"
echo "--- end arm stdout; exit status $rc1 after $((t1 - t0))s ---"

[ "$rc1" != 0 ] || { echo "RESULT: FAIL - retirement did not fail the arm loudly"; exit 1; }
[ "$rc1" != 124 ] || { echo "RESULT: FAIL - arm never exited (unbounded wait)"; exit 1; }
grep -qF 'watcher: FAILED - watcher pid=' "$arm1out" || { echo "RESULT: FAIL - no typed failure line"; exit 1; }
grep -qF 'stopped advancing its beacon' "$arm1out" || { echo "RESULT: FAIL - failure did not name liveness"; exit 1; }
grep -q 'reason=stale-beacon-retired' "$state/.watch-cycle-exits.log" || { echo "RESULT: FAIL - ledger not classified"; exit 1; }
{ [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ]; } || { echo "RESULT: FAIL - stale singleton ownership survived"; exit 1; }
if is_live_non_zombie "$watcher_pid"; then echo "RESULT: FAIL - wedged watcher survived the bounded retirement"; exit 1; fi
token=$(cat "$state/.watcher-down" 2>/dev/null || true)
case "$token" in
  pending:downtime:*) ;;
  *) echo "RESULT: FAIL - no downtime episode published ('$token')"; exit 1 ;;
esac
echo "observed state:  watcher $watcher_pid gone; state/.watch.lock absent; state/.watcher-down=$token"
echo "ledger row:      $(grep 'stale-beacon-retired' "$state/.watch-cycle-exits.log")"
echo "RESULT: PASS - wedged owned watcher retired in $((t1 - t0))s, ownership released, arm failed loudly"

########################################################################
section "S2: the SAME session re-arms and surfaces the accepted downtime"
arm2out="$dir/arm2.out"; arm2err="$dir/arm2.err"
start_arm "$arm2out" "$arm2err"; arm2=$ARM_PID
wait_for_exit "$arm2" 300; rc2=$?
echo "--- arm stdout (exit status $rc2) ---"
cat "$arm2out"
echo "--- end arm stdout ---"
[ "$rc2" = 0 ] || { echo "RESULT: FAIL - same-session recovery arm did not close cleanly"; exit 1; }
grep -qF 'check: rearm-resurface' "$arm2out" || { echo "RESULT: FAIL - recovery episode was not surfaced"; exit 1; }
drain_and_ack "$state" || { echo "RESULT: FAIL - could not acknowledge the recovery wake"; exit 1; }
echo "RESULT: PASS - same home/session, no restart: the next arm surfaced the downtime and exited 0"

########################################################################
section "S3 (adversarial): a healthy owned watcher is NOT retired"
arm3out="$dir/arm3.out"; arm3err="$dir/arm3.err"
start_arm "$arm3out" "$arm3err"; arm3=$ARM_PID
if ! wait_for_line "$arm3out" 'watcher: started pid=' 650; then
  echo "RESULT: FAIL - healthy recovery cycle did not establish"
  dump_arm "$arm3out" "$arm3err"
  exit 1
fi
healthy_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
echo "arm confirmed:   $(grep -F 'watcher: started pid=' "$arm3out")"
beat_before=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_path_mtime "$2"' _ "$LIB" "$state/.last-watcher-beat")
i=0
while [ "$i" -lt 140 ]; do
  sleep 0.1
  if ! is_live_non_zombie "$arm3"; then
    echo "RESULT: FAIL - arm exited while its owned watcher was healthy"
    echo "--- arm stdout ---"; cat "$arm3out"
    exit 1
  fi
  i=$((i + 1))
done
beat_after=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_path_mtime "$2"' _ "$LIB" "$state/.last-watcher-beat")
echo "held 14s (grace 5s, retirement bound 3s) with the arm alive; beacon mtime $beat_before -> $beat_after"
if grep -qF 'watcher: FAILED' "$arm3out"; then echo "RESULT: FAIL - healthy child was failed: $(cat "$arm3out")"; exit 1; fi
if ! is_live_non_zombie "$healthy_pid"; then echo "RESULT: FAIL - healthy watcher was retired"; exit 1; fi
[ "$beat_after" -gt "$beat_before" ] || { echo "RESULT: FAIL - healthy watcher stopped advancing its beacon"; exit 1; }
echo "before cleanup:  arm alive=$(is_live_non_zombie "$arm3" && echo yes || echo no), watcher $healthy_pid alive=$(is_live_non_zombie "$healthy_pid" && echo yes || echo no)"
kill -HUP "$arm3" 2>/dev/null || true
wait_for_exit "$arm3" 100 >/dev/null 2>&1 || true
echo "RESULT: PASS - healthy owned watcher survived the grace window and kept beating"
