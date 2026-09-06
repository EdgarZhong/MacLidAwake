#!/bin/bash

set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIDGO_BIN="${LIDGO_BIN:-$ROOT_DIR/.build/debug/lidgo}"
TEST_ROOT="$(mktemp -d -t lidgo-cli-tests.XXXXXX)"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  set +u
  for pid in $(jobs -p); do
    kill -TERM "$pid" >/dev/null 2>&1 || true
    kill -CONT "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
  /usr/bin/trash "$TEST_ROOT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL $1"
}

wait_until() {
  local attempts=100
  while [ "$attempts" -gt 0 ]; do
    if eval "$1"; then return 0; fi
    sleep 0.05
    attempts=$((attempts - 1))
  done
  return 1
}

use_home() {
  export LIDGO_TESTING=1
  export LIDGO_HOME="$TEST_ROOT/$1"
  export LIDGO_TEST_BATTERY=80
  export LIDGO_TEST_THERMAL=nominal
}

hold_count() {
  grep -c '"pid"' "$LIDGO_HOME/state.json" 2>/dev/null || true
}

timer_is_null() {
  ! grep -q '"timer"' "$LIDGO_HOME/state.json" 2>/dev/null
}

start_hold() {
  "$LIDGO_BIN" --hold >"$LIDGO_HOME/hold.out" 2>&1 &
  HOLD_PID=$!
  wait_until '[ "$(hold_count)" -eq 1 ]'
}

finish_hold() {
  local signal_name="$1"
  kill -"$signal_name" "$HOLD_PID" || return 1
  wait_until '! kill -0 "$HOLD_PID" 2>/dev/null' || return 1
  wait "$HOLD_PID" >/dev/null 2>&1 || true
  [ "$(hold_count)" -eq 0 ]
}

if [ ! -x "$LIDGO_BIN" ]; then
  echo "FAIL lidgo executable is missing: $LIDGO_BIN"
  exit 1
fi

use_home public-surface
if "$LIDGO_BIN" help | grep -q 'lidgo --hold' && [ ! -e "$LIDGO_HOME/state.json" ]; then
  pass "help has no state side effect"
else
  fail "help has no state side effect"
fi
if ! "$LIDGO_BIN" status >/dev/null 2>&1 && [ ! -e "$LIDGO_HOME/state.json" ]; then
  pass "legacy command is rejected without side effects"
else
  fail "legacy command is rejected without side effects"
fi

use_home setup
if "$LIDGO_BIN" setup >/dev/null && "$LIDGO_BIN" setup >/dev/null \
  && [ -f "$LIDGO_HOME/com.maclidawake.lidgo.agent.plist" ] \
  && [ -f "$LIDGO_HOME/maclidawake.global.lock" ]; then
  pass "testing setup is idempotent"
else
  fail "testing setup is idempotent"
fi

use_home timer
"$LIDGO_BIN" setup >/dev/null || true
if "$LIDGO_BIN" config --duration 90m --battery 20 | grep -q 'Battery cutoff   : 20%'; then
  pass "config updates both supported values"
else
  fail "config updates both supported values"
fi
if "$LIDGO_BIN" >/dev/null && grep -q '"timer" : {' "$LIDGO_HOME/state.json"; then
  first_deadline="$(grep '"deadline"' "$LIDGO_HOME/state.json")"
  "$LIDGO_BIN" >/dev/null
  second_deadline="$(grep '"deadline"' "$LIDGO_HOME/state.json")"
  if [ "$first_deadline" = "$second_deadline" ]; then
    pass "default timer is idempotent"
  else
    fail "default timer is idempotent"
  fi
else
  fail "default creates timer"
fi
sleep 1
"$LIDGO_BIN" -r >/dev/null
refreshed_deadline="$(grep '"deadline"' "$LIDGO_HOME/state.json")"
if [ "$refreshed_deadline" != "$second_deadline" ]; then
  pass "refresh advances timer deadline"
else
  fail "refresh advances timer deadline"
fi
if "$LIDGO_BIN" switch -f | grep -q '已强制关闭' && timer_is_null; then
  pass "force clears active timer"
else
  fail "force clears active timer"
fi

for signal_name in INT TERM HUP QUIT; do
  use_home "signal-$signal_name"
  "$LIDGO_BIN" setup >/dev/null || true
  if start_hold && finish_hold "$signal_name"; then
    pass "$signal_name releases its Hold lease"
  else
    fail "$signal_name releases its Hold lease"
  fi
done

use_home tstp-cont
"$LIDGO_BIN" setup >/dev/null || true
if start_hold \
  && kill -TSTP "$HOLD_PID" \
  && wait_until '[ "$(hold_count)" -eq 0 ]' \
  && wait_until 'ps -o stat= -p "$HOLD_PID" | grep -q T' \
  && kill -CONT "$HOLD_PID" \
  && wait_until '[ "$(hold_count)" -eq 1 ]' \
  && finish_hold INT; then
  pass "TSTP releases and CONT restores Hold"
else
  fail "TSTP releases and CONT restores Hold"
fi

use_home force-during-suspend
"$LIDGO_BIN" setup >/dev/null || true
if start_hold \
  && kill -TSTP "$HOLD_PID" \
  && wait_until '[ "$(hold_count)" -eq 0 ]' \
  && "$LIDGO_BIN" switch -f >/dev/null \
  && kill -CONT "$HOLD_PID" \
  && wait_until '! kill -0 "$HOLD_PID" 2>/dev/null' \
  && [ "$(hold_count)" -eq 0 ]; then
  wait "$HOLD_PID" >/dev/null 2>&1 || true
  pass "force generation prevents suspended Hold recovery"
else
  fail "force generation prevents suspended Hold recovery"
fi

use_home sigstop
"$LIDGO_BIN" setup >/dev/null || true
"$LIDGO_BIN" __agent >"$LIDGO_HOME/agent.out" 2>&1 &
AGENT_PID=$!
if start_hold \
  && kill -STOP "$HOLD_PID" \
  && wait_until '[ "$(hold_count)" -eq 0 ]' \
  && kill -CONT "$HOLD_PID" \
  && wait_until '[ "$(hold_count)" -eq 1 ]' \
  && finish_hold INT; then
  pass "agent removes SIGSTOP Hold and CONT restores it"
else
  fail "agent removes SIGSTOP Hold and CONT restores it"
fi
kill -TERM "$AGENT_PID" >/dev/null 2>&1 || true
wait "$AGENT_PID" >/dev/null 2>&1 || true

use_home agent-shutdown
"$LIDGO_BIN" setup >/dev/null || true
"$LIDGO_BIN" >/dev/null || true
"$LIDGO_BIN" __agent >"$LIDGO_HOME/agent.out" 2>&1 &
AGENT_PID=$!
if wait_until '[ "$(tail -n 1 "$LIDGO_HOME/power.log" 2>/dev/null)" = 1 ]'; then
  kill -TERM "$AGENT_PID" >/dev/null 2>&1 || true
  wait "$AGENT_PID" >/dev/null 2>&1 || true
  if [ "$(tail -n 1 "$LIDGO_HOME/power.log" 2>/dev/null)" = 0 ]; then
    pass "agent termination restores normal sleep target"
  else
    fail "agent termination restores normal sleep target"
  fi
else
  fail "agent termination restores normal sleep target"
fi

use_home safety
"$LIDGO_BIN" setup >/dev/null || true
"$LIDGO_BIN" >/dev/null || true
LIDGO_TEST_BATTERY=15 "$LIDGO_BIN" __agent >"$LIDGO_HOME/unsafe-agent.out" 2>&1 &
AGENT_PID=$!
if wait_until 'timer_is_null' && grep -q '"reason" : "battery"' "$LIDGO_HOME/state.json"; then
  pass "unsafe agent clears all leases and latches reason"
else
  fail "unsafe agent clears all leases and latches reason"
fi
kill -TERM "$AGENT_PID" >/dev/null 2>&1 || true
wait "$AGENT_PID" >/dev/null 2>&1 || true

echo "SUMMARY $PASS_COUNT passed, $FAIL_COUNT failed"
exit "$FAIL_COUNT"
