#!/usr/bin/env bash
set -u
. tests/wake-helpers.sh
WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-stopped)

mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

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
test_stopped_watcher_is_retired_and_rearms_without_session_restart() {
  local dir state fakebin armout recovery_out healthy_out armpid watcher_pid i status
  local recovery_arm healthy_arm healthy_pid beat_before beat_after token wedge_limit
  dir=$(make_case stopped-watcher)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  recovery_out="$dir/recovery.out"
  healthy_out="$dir/healthy.out"
  mark_pr_check_migration_complete "$state"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_GUARD_GRACE=30 FM_ARM_CONFIRM_TIMEOUT=60 FM_ARM_ATTACH_POLL=0.05 FM_POLL=0.1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  # Under host contention the owned child's first fresh beacon can land after
  # the arm's default 11s confirmation deadline, so poll through the widened
  # confirm budget and fail fast on a loud typed failure instead.
  while [ "$i" -lt 650 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    grep -qF 'watcher: FAILED' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "load counterfactual watcher did not start"

  kill -STOP "$watcher_pid" 2>/dev/null || fail "could not SIGSTOP watcher"
  touch -t 200001010000 "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$watcher_pid" \
    || fail "SIGSTOP watcher was not classified as a live pid"
  if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ "$LIB" "$state" "$WATCH" "$dir"; then
    fail "SIGSTOP watcher with a stale beacon was classified healthy"
  fi

  i=0
  wedge_limit=80
  [ "$(uname)" != Linux ] || wedge_limit=160
  while [ "$i" -lt "$wedge_limit" ] && is_live_non_zombie "$armpid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if is_live_non_zombie "$armpid"; then
    # Pre-fix cleanup: a raw wait on the stopped child held this arm forever.
    # Continue the watcher before terminating it so this failing regression
    # never strands a stopped process in the test host.
    kill -CONT "$watcher_pid" 2>/dev/null || true
    kill -TERM "$watcher_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
    fail "arm stayed wedged behind a live watcher whose beacon was stale"
  fi
  wait "$armpid"
  status=$?
  [ "$status" -ne 0 ] || fail "stale-beacon retirement did not fail the owned arm loudly"
  grep -F 'watcher: FAILED - watcher pid=' "$armout" >/dev/null \
    || fail "stale-beacon retirement omitted its typed watcher failure: $(cat "$armout")"
  grep -F 'stopped advancing its beacon' "$armout" >/dev/null \
    || fail "stale-beacon retirement did not name the liveness failure: $(cat "$armout")"
  token=$(cat "$state/.watcher-down" 2>/dev/null || true)
  case "$token" in
    pending:downtime:*) ;;
    *) fail "stale-beacon retirement did not publish watcher-down recovery state: '$token'" ;;
  esac
  case "$(uname)" in
    Linux)
      # SIGKILL is never held pending for a stopped process on Linux: the
      # retirement's KILL kills the stopped watcher immediately, the arm's
      # wait reaps it before the expected-pid hardening runs, and the
      # retirement takes the released-lock shape (stale-beacon-retired), not
      # the release-failed shape.
      ! is_live_non_zombie "$watcher_pid" \
        || fail "bounded retirement did not kill the stopped watcher on Linux"
      [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ] \
        || fail "stalled watcher retained singleton ownership after retirement on Linux"
      grep -q 'reason=stale-beacon-retired' "$state/.watch-cycle-exits.log" \
        || fail "stale-beacon retirement was not classified in the lifecycle ledger on Linux"
      kill -CONT "$watcher_pid" 2>/dev/null || true
      wait_for_exit "$watcher_pid" 40 2>/dev/null || true
      pass "owned arm bounds its retirement of a stopped watcher and fails loudly on Linux"
      return 0
      ;;
  esac
  ! is_live_non_zombie "$watcher_pid" \
    || fail "stalled watcher remained alive after bounded retirement"
  [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ] \
    || fail "stalled watcher retained singleton ownership after retirement"
  grep -q 'reason=stale-beacon-retired' "$state/.watch-cycle-exits.log" \
    || fail "stale-beacon retirement was not classified in the lifecycle ledger"

  # A fresh arm in the same primary session must take ownership and surface the
  # accepted downtime episode. No Pi/Herdr process is involved in this fixture.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_GUARD_GRACE=30 FM_ARM_CONFIRM_TIMEOUT=60 FM_ARM_ATTACH_POLL=0.05 FM_POLL=0.1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$recovery_out" &
  recovery_arm=$!
  wait_for_exit "$recovery_arm" 140
  status=$?
  expect_code 0 "$status" "same-session recovery arm must surface accepted watcher downtime"
  grep -F 'check: rearm-resurface' "$recovery_out" >/dev/null \
    || fail "same-session recovery arm did not surface the watcher-down episode: $(cat "$recovery_out")"
  drain_and_ack "$state" || fail "same-session watcher recovery acknowledgement failed"

  # Once the recovery episode is acknowledged, the next healthy cycle stays
  # live and keeps advancing its real watcher-owned beacon. The real watcher
  # advances the beacon once per main-loop iteration, which takes ~2-3.5s on a
  # loaded host, so this arm's grace must outrun that cadence: a grace tighter
  # than the cadence makes the arm's own stale-beacon watchdog retire a
  # healthy child. Poll through the grace with a liveness check per tick, then
  # require the beacon to have advanced.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_GUARD_GRACE=30 FM_ARM_CONFIRM_TIMEOUT=60 FM_ARM_ATTACH_POLL=0.05 FM_POLL=0.1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$healthy_out" &
  healthy_arm=$!
  i=0
  while [ "$i" -lt 650 ]; do
    grep -qF 'watcher: started pid=' "$healthy_out" 2>/dev/null && break
    grep -qF 'watcher: FAILED' "$healthy_out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  healthy_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$healthy_pid" "$healthy_out" \
    || fail "healthy recovery cycle did not establish: $(cat "$healthy_out")"
  beat_before=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_path_mtime "$2"' _ "$LIB" "$state/.last-watcher-beat")
  i=0
  while [ "$i" -lt 140 ]; do
    sleep 0.1
    is_live_non_zombie "$healthy_arm" \
      || fail "healthy arm was retired by the stale-beacon watchdog"
    i=$((i + 1))
  done
  beat_after=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_path_mtime "$2"' _ "$LIB" "$state/.last-watcher-beat")
  [ "$beat_after" -gt "$beat_before" ] \
    || fail "healthy watcher did not advance its beacon ($beat_before -> $beat_after)"
  kill -HUP "$healthy_arm" 2>/dev/null || true
  wait "$healthy_arm" 2>/dev/null || true
  pass "owned arm retires a live stale watcher, releases recovery state, and preserves a healthy successor"
}

test_stopped_watcher_is_retired_and_rearms_without_session_restart
