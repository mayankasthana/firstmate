#!/usr/bin/env bash
set -u
. tests/wake-helpers.sh
LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-concurrency)

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  echo "winners=$wins"
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}
test_lock_single_winner_under_concurrency
