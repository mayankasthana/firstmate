#!/usr/bin/env bash
set -u
. tests/wake-helpers.sh
WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-retire-e2e-demo)

mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

dir=$(make_case retire-e2e)
state="$dir/state"
fakebin="$dir/fakebin"
armout="$dir/arm.out"
mark_pr_check_migration_complete "$state"

echo "=== 1) launch a real fm-watch-arm.sh; it forks an owned watcher child ==="
PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
  FM_GUARD_GRACE=1 FM_ARM_CONFIRM_TIMEOUT=60 FM_ARM_ATTACH_POLL=0.05 FM_POLL=0.1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" 2>&1 &
ARMPID=$!

i=0
child=
while [ "$i" -lt 650 ]; do
  child=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && [ -n "$child" ] && break
  grep -qF 'watcher: FAILED' "$armout" 2>/dev/null && break
  sleep 0.1; i=$((i+1))
done
echo "arm status: $(grep -o 'watcher: started pid=.*' "$armout" | head -1)"
[ -n "$child" ] || { echo "NO CHILD STARTED; output:"; cat "$armout"; exit 1; }
echo "owned watcher pid=$child, beacon: $(ls -la "$state/.last-watcher-beat" 2>/dev/null | awk '{print $6,$7,$8}')"

echo "=== 2) SIGSTOP the owned watcher: it goes live-but-stalled (stops advancing its beacon) ==="
kill -STOP "$child"
sleep 2   # let the beacon age past the 1s grace

echo "=== 3) the arm's watchdog notices the stale beacon and retires the group (TERM then KILL) ==="
i=0
while [ "$i" -lt 300 ]; do
  grep -qF 'watcher: FAILED' "$armout" 2>/dev/null && break
  sleep 0.1; i=$((i+1))
done
wait "$ARMPID" 2>/dev/null; armrc=$?

echo
echo "=== arm exit code: $armrc ==="
echo "=== arm stdout/stderr (user-visible line): ==="
cat "$armout"
echo
echo "=== recovery state published: state/.watcher-down ==="
cat "$state/.watcher-down" 2>/dev/null || echo "(none)"
echo
echo "=== lifecycle ledger classification: ==="
grep -E 'stale-beacon|stand-down' "$state/.watch-cycle-exits.log" 2>/dev/null | tail -3 || echo "(none)"
echo
echo "=== own watcher alive after retirement? ==="
if kill -0 "$child" 2>/dev/null; then echo "STILL ALIVE (release-failed shape)"; kill -CONT "$child" 2>/dev/null; else echo "dead (retired)"; fi
