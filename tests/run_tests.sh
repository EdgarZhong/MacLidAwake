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
printf 'broken plist\n' >"$LIDGO_HOME/com.maclidawake.lidgo.agent.plist"
if "$LIDGO_BIN" setup >/dev/null \
  && /usr/bin/plutil -extract Label raw "$LIDGO_HOME/com.maclidawake.lidgo.agent.plist" 2>/dev/null \
    | grep -q '^com.maclidawake.lidgo.agent$'; then
  pass "setup repairs a corrupt LaunchAgent plist"
else
  fail "setup repairs a corrupt LaunchAgent plist"
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
"$LIDGO_BIN" config --duration 2h >/dev/null
configured_deadline="$(grep '"deadline"' "$LIDGO_HOME/state.json")"
if [ "$configured_deadline" = "$second_deadline" ]; then
  pass "config does not change an existing timer"
else
  fail "config does not change an existing timer"
fi
state_before_switch="$(cksum "$LIDGO_HOME/state.json")"
switch_output="$("$LIDGO_BIN" switch 2>&1)"
switch_status=$?
state_after_switch="$(cksum "$LIDGO_HOME/state.json")"
if [ "$switch_status" -eq 1 ] \
  && echo "$switch_output" | grep -q 'lidgo switch -f' \
  && [ "$state_before_switch" = "$state_after_switch" ]; then
  pass "switch without force has no side effect"
else
  fail "switch without force has no side effect"
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

use_home refresh-off
"$LIDGO_BIN" setup >/dev/null || true
if "$LIDGO_BIN" -r >/dev/null && grep -q '"timer" : {' "$LIDGO_HOME/state.json"; then
  pass "refresh creates a timer while OFF"
else
  fail "refresh creates a timer while OFF"
fi

use_home invalid-config
"$LIDGO_BIN" setup >/dev/null || true
config_before="$(cksum "$LIDGO_HOME/config.json")"
state_before="$(cksum "$LIDGO_HOME/state.json")"
if ! "$LIDGO_BIN" config --battery 0 >/dev/null 2>&1 \
  && [ "$config_before" = "$(cksum "$LIDGO_HOME/config.json")" ] \
  && [ "$state_before" = "$(cksum "$LIDGO_HOME/state.json")" ]; then
  pass "invalid config is rejected without side effects"
else
  fail "invalid config is rejected without side effects"
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

use_home refresh-with-hold
"$LIDGO_BIN" setup >/dev/null || true
if start_hold; then
  state_before="$(cksum "$LIDGO_HOME/state.json")"
  refresh_output="$("$LIDGO_BIN" -r)"
  state_after="$(cksum "$LIDGO_HOME/state.json")"
  if echo "$refresh_output" | grep -q '无法刷新' \
    && [ "$state_before" = "$state_after" ] \
    && finish_hold INT; then
    pass "refresh rejects Hold without changing leases"
  else
    fail "refresh rejects Hold without changing leases"
  fi
else
  fail "refresh rejects Hold without changing leases"
fi

use_home multiple-holds
"$LIDGO_BIN" setup >/dev/null || true
"$LIDGO_BIN" --hold >"$LIDGO_HOME/hold-a.out" 2>&1 &
HOLD_A=$!
"$LIDGO_BIN" --hold >"$LIDGO_HOME/hold-b.out" 2>&1 &
HOLD_B=$!
if wait_until '[ "$(hold_count)" -eq 2 ]' \
  && "$LIDGO_BIN" | grep -q 'Hold：2 个终端会话正在维持' \
  && kill -INT "$HOLD_A" \
  && wait_until '! kill -0 "$HOLD_A" 2>/dev/null' \
  && wait_until '[ "$(hold_count)" -eq 1 ]' \
  && kill -0 "$HOLD_B" \
  && kill -TERM "$HOLD_B" \
  && wait_until '! kill -0 "$HOLD_B" 2>/dev/null' \
  && wait_until '[ "$(hold_count)" -eq 0 ]'; then
  wait "$HOLD_A" >/dev/null 2>&1 || true
  wait "$HOLD_B" >/dev/null 2>&1 || true
  pass "multiple Holds display and release independently"
else
  fail "multiple Holds display and release independently"
fi

use_home timer-plus-hold
"$LIDGO_BIN" setup >/dev/null || true
"$LIDGO_BIN" >/dev/null || true
if start_hold \
  && "$LIDGO_BIN" | grep -q 'Timer：' \
  && "$LIDGO_BIN" | grep -q 'Hold：1 个终端会话正在维持' \
  && kill -STOP "$HOLD_PID" \
  && wait_until 'ps -o stat= -p "$HOLD_PID" | grep -q T' \
  && /usr/bin/plutil -replace timer.deadline -string '2000-01-01T00:00:00Z' "$LIDGO_HOME/state.json" \
  && kill -CONT "$HOLD_PID"; then
  "$LIDGO_BIN" __agent >"$LIDGO_HOME/agent.out" 2>&1 &
  AGENT_PID=$!
  if wait_until 'timer_is_null && [ "$(hold_count)" -eq 1 ]' \
    && finish_hold INT; then
    pass "expired Timer is removed while live Hold remains"
  else
    fail "expired Timer is removed while live Hold remains"
  fi
  kill -TERM "$AGENT_PID" >/dev/null 2>&1 || true
  wait "$AGENT_PID" >/dev/null 2>&1 || true
else
  fail "expired Timer is removed while live Hold remains"
fi

use_home force-live-holds
"$LIDGO_BIN" setup >/dev/null || true
"$LIDGO_BIN" --hold >"$LIDGO_HOME/hold-a.out" 2>&1 &
HOLD_A=$!
"$LIDGO_BIN" --hold >"$LIDGO_HOME/hold-b.out" 2>&1 &
HOLD_B=$!
if wait_until '[ "$(hold_count)" -eq 2 ]' \
  && "$LIDGO_BIN" switch -f >/dev/null \
  && wait_until '! kill -0 "$HOLD_A" 2>/dev/null' \
  && wait_until '! kill -0 "$HOLD_B" 2>/dev/null' \
  && [ "$(hold_count)" -eq 0 ] \
  && timer_is_null; then
  wait "$HOLD_A" >/dev/null 2>&1 || true
  wait "$HOLD_B" >/dev/null 2>&1 || true
  pass "force revokes all live Holds"
else
  fail "force revokes all live Holds"
fi

use_home stale-crash
"$LIDGO_BIN" setup >/dev/null || true
"$LIDGO_BIN" __agent >"$LIDGO_HOME/agent.out" 2>&1 &
AGENT_PID=$!
if start_hold && kill -KILL "$HOLD_PID"; then
  wait "$HOLD_PID" >/dev/null 2>&1 || true
  if wait_until '[ "$(hold_count)" -eq 0 ]'; then
    pass "agent removes a crashed stale Hold"
  else
    fail "agent removes a crashed stale Hold"
  fi
else
  fail "agent removes a crashed stale Hold"
fi
kill -TERM "$AGENT_PID" >/dev/null 2>&1 || true
wait "$AGENT_PID" >/dev/null 2>&1 || true

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

run_safety_case() {
  local name="$1"
  local battery="$2"
  local thermal="$3"
  local reason="$4"
  use_home "safety-$name"
  "$LIDGO_BIN" setup >/dev/null || true
  "$LIDGO_BIN" >/dev/null || true
  LIDGO_TEST_BATTERY="$battery" LIDGO_TEST_THERMAL="$thermal" \
    "$LIDGO_BIN" __agent >"$LIDGO_HOME/unsafe-agent.out" 2>&1 &
  AGENT_PID=$!
  if wait_until 'timer_is_null' \
    && grep -q "\"reason\" : \"$reason\"" "$LIDGO_HOME/state.json"; then
    generation_before="$(grep '"generation"' "$LIDGO_HOME/state.json")"
    kill -TERM "$AGENT_PID" >/dev/null 2>&1 || true
    wait "$AGENT_PID" >/dev/null 2>&1 || true
    LIDGO_TEST_BATTERY=80 LIDGO_TEST_THERMAL=nominal \
      "$LIDGO_BIN" __agent >"$LIDGO_HOME/safe-agent.out" 2>&1 &
    AGENT_PID=$!
    sleep 1.2
    if timer_is_null \
      && [ "$generation_before" = "$(grep '"generation"' "$LIDGO_HOME/state.json")" ] \
      && grep -q "\"reason\" : \"$reason\"" "$LIDGO_HOME/state.json"; then
      pass "$name safety trip latches OFF across recovery"
    else
      fail "$name safety trip latches OFF across recovery"
    fi
  else
    fail "$name safety trip latches OFF across recovery"
  fi
  kill -TERM "$AGENT_PID" >/dev/null 2>&1 || true
  wait "$AGENT_PID" >/dev/null 2>&1 || true
}

run_safety_case battery 15 nominal battery
run_safety_case battery-unavailable unavailable nominal batteryUnavailable
run_safety_case thermal 80 critical thermal

echo "SUMMARY $PASS_COUNT passed, $FAIL_COUNT failed"
exit "$FAIL_COUNT"
