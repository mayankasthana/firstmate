#!/usr/bin/env bash
# Adversarial live drive of the successor-lock race the arm's stale-lock release
# closes (bin/fm-watch-arm.sh clear_stale_recorded_watcher_lock): the arm holds
# the watcher lock's steal mutex across a final ownership recheck and the
# removal, so its removal lands on the verified stale owner or not at all.
#
# Two live variants, each driving the real arm against a really-wedged owned
# watcher:
#   A. a concurrent successor steals the lock while the arm is retiring its
#      stalled child -> the arm must NOT remove the successor's live lock.
#   B. a live foreign holder of the steal mutex -> the arm must refuse the
#      removal and report its typed release failure instead of deleting a lock
#      it could not verify.
set -u

WT=${WT:?set WT to the worktree root}
EV=${EV:?set EV to the evidence dir}
# shellcheck source=tests/wake-helpers.sh
. "$WT/tests/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot live-race-drive) || { echo "FAIL: could not make a temp root"; exit 1; }

WATCH_ARM="$WT/bin/fm-watch-arm.sh"
LIB="$WT/bin/fm-wake-lib.sh"

section() { printf '\n===== %s =====\n' "$1"; }

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

wait_for_file() {  # <file> <max-tenths>
  local f=$1 max=$2 i=0
  while [ "$i" -lt "$max" ]; do
    [ -e "$f" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# arm_and_wedge <outfile> <errfile>: start the real arm, confirm it owns a
# started watcher, then wedge that watcher (SIGSTOP + backdated beacon). Sets
# AW_ARM and AW_WATCHER.
AW_ARM=
AW_WATCHER=
arm_and_wedge() {
  local out=$1 age
  start_arm "$out" "$2"
  AW_ARM=$ARM_PID
  wait_for_line "$out" 'watcher: started pid=' 650 || {
    echo "FAIL: arm never confirmed a started watcher"
    return 1
  }
  AW_WATCHER=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -STOP "$AW_WATCHER" 2>/dev/null || { echo "FAIL: could not SIGSTOP watcher"; return 1; }
  touch -t 200001010000 "$state/.last-watcher-beat"
  age=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_path_age "$2"' _ "$LIB" "$state/.last-watcher-beat")
  echo "arm pid=$AW_ARM -> $(grep -F 'watcher: started pid=' "$out")"
  echo "wedge: SIGSTOP owned watcher pid=$AW_WATCHER, beacon age ${age}s vs grace 5s"
}

########################################################################
section "A: a concurrent successor's live lock survives the arm's stale-lock release"
dir=$(make_case live-successor-race); state="$dir/state"; fakebin="$dir/fakebin"
A_OUT="$dir/armA.out"; A_ERR="$dir/armA.err"

arm_and_wedge "$A_OUT" "$A_ERR" || { echo "RESULT: FAIL - setup"; exit 1; }
arm_a=$AW_ARM; watcher_a=$AW_WATCHER

# The concurrent successor: a real steal of the now-stale lock by a live peer,
# interposed inside the arm's multi-second retirement window (the TERM bound and
# the KILL sweep). It takes the same steal mutex, removes the stale lock,
# publishes its own live lock, and stays alive as the new holder.
(
  sleep 0.4
  bash -c '
    . "$1"
    steal="$2/.watch.lock.steal"
    fm_lock_try_acquire_steal_mutex "$steal" || exit 3
    rm -rf "$2/.watch.lock"
    mkdir -p "$2/.watch.lock"
    printf "%s\n" "$$" > "$2/.watch.lock/pid"
    fm_pid_identity "$$" > "$2/.watch.lock/pid-identity"
    printf "%s\n" "$3" > "$2/.watch.lock/fm-home"
    printf "%s\n" "$4" > "$2/.watch.lock/watcher-path"
    fm_lock_release "$steal"
    printf "%s" "$$" > "$5"
    sleep 120
  ' _ "$LIB" "$state" "$dir" "$WT/bin/fm-watch.sh" "$dir/successor-pid"
) &
successor_shell=$!
if ! wait_for_file "$dir/successor-pid" 150; then
  echo "RESULT: FAIL - the concurrent successor never took the lock"
  kill "$successor_shell" 2>/dev/null
  exit 1
fi
successor_pid=$(cat "$dir/successor-pid")
echo "concurrent successor pid=$successor_pid stole the stale lock while the arm was retiring its child"
echo "state/.watch.lock/pid is now $(cat "$state/.watch.lock/pid" 2>/dev/null || true)"

wait_for_exit "$arm_a" 400; rc_a=$?
echo "--- arm stdout (exit status $rc_a) ---"
cat "$A_OUT"
echo "--- end arm stdout ---"

lock_pid_after=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
echo "after the arm closed: state/.watch.lock/pid=$lock_pid_after (successor pid=$successor_pid)"
kill "$successor_pid" "$successor_shell" 2>/dev/null || true
wait "$successor_shell" 2>/dev/null || true

[ "$rc_a" != 0 ] || { echo "RESULT: FAIL - the retirement did not fail the arm loudly"; exit 1; }
[ "$rc_a" != 124 ] || { echo "RESULT: FAIL - the arm blocked"; exit 1; }
if [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ]; then
  echo "RESULT: FAIL - the arm removed a lock a live concurrent successor owned (the Greptile race)"
  exit 1
fi
[ "$lock_pid_after" = "$successor_pid" ] || { echo "RESULT: FAIL - the successor's lock was replaced (pid=$lock_pid_after)"; exit 1; }
grep -q 'reason=stale-beacon-retired' "$state/.watch-cycle-exits.log" || { echo "RESULT: FAIL - ledger not classified"; exit 1; }
echo "RESULT: PASS - the arm retired its own stalled child without touching the successor's lock"

########################################################################
section "B: a live steal-mutex holder makes the arm refuse the removal by name"
dir=$(make_case live-steal-mutex-held); state="$dir/state"; fakebin="$dir/fakebin"
B_OUT="$dir/armB.out"; B_ERR="$dir/armB.err"

arm_and_wedge "$B_OUT" "$B_ERR" || { echo "RESULT: FAIL - setup"; exit 1; }
arm_b=$AW_ARM; watcher_b=$AW_WATCHER

# A live foreign holder of the watcher lock's steal mutex: the state a concurrent
# stealer is in for the few microseconds it owns it.
(
  sleep 0.4
  bash -c '
    . "$1"
    fm_lock_try_acquire_steal_mutex "$2/.watch.lock.steal" || exit 3
    printf "%s" "$$" > "$3"
    sleep 120
  ' _ "$LIB" "$state" "$dir/mutex-pid"
) &
mutex_shell=$!
if ! wait_for_file "$dir/mutex-pid" 150; then
  echo "RESULT: FAIL - could not hold the steal mutex"
  kill "$mutex_shell" 2>/dev/null
  exit 1
fi
mutex_pid=$(cat "$dir/mutex-pid")
echo "foreign steal-mutex holder pid=$mutex_pid is live for the whole retirement window"

wait_for_exit "$arm_b" 400; rc_b=$?
echo "--- arm stdout (exit status $rc_b) ---"
cat "$B_OUT"
echo "--- end arm stdout ---"
kill "$mutex_pid" "$mutex_shell" 2>/dev/null || true
wait "$mutex_shell" 2>/dev/null || true

[ "$rc_b" != 0 ] || { echo "RESULT: FAIL - the arm did not fail loudly"; exit 1; }
[ "$rc_b" != 124 ] || { echo "RESULT: FAIL - the arm blocked"; exit 1; }
grep -qF 'recovery state could not release stale ownership' "$B_OUT" \
  || { echo "RESULT: FAIL - the arm did not report its typed release failure"; exit 1; }
grep -q 'reason=stale-beacon-release-failed' "$state/.watch-cycle-exits.log" \
  || { echo "RESULT: FAIL - the refused release was not classified in the ledger"; exit 1; }
[ -e "$state/.watch.lock" ] || [ -L "$state/.watch.lock" ] \
  || { echo "RESULT: FAIL - the arm removed a lock it could not verify under the mutex"; exit 1; }
[ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher_b" ] \
  || { echo "RESULT: FAIL - the refused release changed the recorded owner"; exit 1; }
echo "RESULT: PASS - with the steal mutex held the arm refused the removal by name and left the lock intact"
