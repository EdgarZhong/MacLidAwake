#!/bin/bash
# Automated test suite for keepawake. macOS-only, by necessity (everything
# here pokes real OS-level display/power state).
#
# What this DOES verify empirically: the virtual display gets created with
# the right name/size, AppleClamshellCausesSleep flips to No while it's
# running, teardown happens correctly on SIGINT/SIGTERM/--duration, and
# basic CLI argument handling.
#
# What this CANNOT verify: whether the machine actually stays awake through
# a real physical lid close. There is no software path to simulate
# AppleClamshellState; that remains a manual test (see RESEARCH.md).
#
# Tests that assume a clean single-display baseline are skipped if a real
# external display is already attached.

set -uo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd .. && pwd)"
CLI_DIR="$REPO_ROOT/cli/keepawake"
KEEPAWAKE="$CLI_DIR/keepawake"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }
section() { echo ""; echo "== $1 =="; }

display_type_count() {
  # NOTE: "Display Type:" is only present for real/built-in displays,
  # CGVirtualDisplay-backed entries omit that key entirely. "Resolution:"
  # is present on every display entry we've observed, real or virtual.
  system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution:"
}

clamshell_prop() {
  ioreg -r -k AppleClamshellCausesSleep 2>/dev/null \
    | awk -F'= ' '/AppleClamshellCausesSleep/{gsub(/[^A-Za-z]/,"",$2); print $2}'
}

screen_info() {
  swift "$REPO_ROOT/tests/screen_info.swift" 2>/dev/null
}

# Poll until a PID actually exits (and its lock/display are gone) instead of
# guessing a fixed sleep duration; avoids flaky races between test sections.
wait_for_exit() {
  local pid="$1"
  local timeout="${2:-5}"
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    waited=$(echo "$waited + 0.2" | bc)
    if (($(echo "$waited >= $timeout" | bc))); then
      return 1
    fi
  done
  return 0
}

cleanup_stray_processes() {
  pkill -f "$KEEPAWAKE" 2>/dev/null
  sleep 1
}
trap cleanup_stray_processes EXIT

cleanup_stray_processes

section "Preconditions"
INITIAL_DISPLAY_COUNT=$(display_type_count)
if [ "$INITIAL_DISPLAY_COUNT" -gt 1 ]; then
  echo "  external display(s) already attached ($INITIAL_DISPLAY_COUNT total)"
  SKIP_HARDWARE_TESTS=1
else
  pass "no external display attached (clean single-display baseline)"
  SKIP_HARDWARE_TESTS=0
fi

section "Build"
if (cd "$CLI_DIR" && ./build.sh >/tmp/keepawake_build.log 2>&1); then
  pass "keepawake builds successfully"
else
  fail "keepawake failed to build (see /tmp/keepawake_build.log)"
  echo ""
  echo "Cannot continue without a working binary."
  exit 1
fi

section "Argument parsing"

"$KEEPAWAKE" --help >/tmp/kw_help.log 2>&1
HELP_EXIT=$?
if [ "$HELP_EXIT" -eq 0 ] && grep -q "Usage:" /tmp/kw_help.log; then
  pass "--help exits 0 and prints usage"
else
  fail "--help (exit=$HELP_EXIT)"
fi

"$KEEPAWAKE" --duration abc >/tmp/kw_bad.log 2>&1
if [ $? -ne 0 ] && grep -q "positive number" /tmp/kw_bad.log; then
  pass "--duration rejects non-numeric input"
else
  fail "--duration abc should fail with a clear message"
fi

"$KEEPAWAKE" -t -5 >/tmp/kw_neg.log 2>&1
if [ $? -ne 0 ]; then
  pass "--duration rejects negative input"
else
  fail "--duration -5 should fail"
fi

"$KEEPAWAKE" --bogus >/tmp/kw_bogus.log 2>&1
if [ $? -ne 0 ]; then
  pass "unknown argument rejected"
else
  fail "--bogus should fail"
fi

"$KEEPAWAKE" --thermal bogus >/tmp/kw_thermal_bad.log 2>&1
if [ $? -ne 0 ] && grep -qi "none, serious, or critical" /tmp/kw_thermal_bad.log; then
  pass "--thermal rejects an invalid level"
else
  fail "--thermal bogus should fail with a level error"
fi

"$KEEPAWAKE" --thermal >/tmp/kw_thermal_missing.log 2>&1
if [ $? -ne 0 ]; then
  pass "--thermal rejects a missing level"
else
  fail "--thermal with no value should fail"
fi

ARCH=$(uname -m)
if [ "$ARCH" == "x86_64" ]; then
  "$KEEPAWAKE" >/tmp/kw_intel.log 2>&1
  if [ $? -ne 0 ] && grep -qi "intel" /tmp/kw_intel.log; then
    pass "refuses to run on Intel without --force"
  else
    fail "expected a refusal message on Intel hardware"
  fi
else
  skip "Intel-refusal check (running on $ARCH, not Intel)"
fi

section "Pre-flight warnings"

# These warnings only fire without --force, and only after the Intel-arch
# guard, which itself requires --force to get past on Intel (see the
# "refuses to run on Intel without --force" check above). So on Intel,
# without --force, the process dies at the arch guard before ever reaching
# this code; there's no way to observe these warnings there without also
# suppressing them via --force, which would defeat the point. Skip on Intel
# rather than failing on an unreachable code path.
if [ "$ARCH" == "x86_64" ]; then
  skip "battery-power warning check (unreachable on Intel without --force, which also suppresses it)"
  skip "cursor-drift warning check (unreachable on Intel without --force, which also suppresses it)"
  skip "Sidecar-specific addendum check (unreachable on Intel without --force, which also suppresses it)"
else
  if pmset -g batt 2>/dev/null | head -1 | grep -q "Battery Power"; then
    "$KEEPAWAKE" >/tmp/kw_battery_warn.log 2>&1 &
    KWB=$!
    disown
    sleep 1
    if grep -q "battery power" /tmp/kw_battery_warn.log; then
      pass "battery-power warning shown when running on battery"
    else
      fail "expected battery-power warning not found"
    fi
    kill -INT "$KWB" 2>/dev/null
    wait_for_exit "$KWB"
  else
    skip "battery-power warning check (currently on AC power)"
  fi

  "$KEEPAWAKE" >/tmp/kw_cursor_warn.log 2>&1 &
  KWC=$!
  disown
  sleep 1
  if grep -qi "cursor can still reach" /tmp/kw_cursor_warn.log; then
    pass "cursor-drift warning shown unconditionally (phantom is parked at the edge but still reachable)"
  else
    fail "expected cursor-drift warning not found"
  fi

  if system_profiler SPDisplaysDataType 2>/dev/null | grep -qi "Sidecar"; then
    if grep -qi "sidecar display is currently connected" /tmp/kw_cursor_warn.log; then
      pass "additional Sidecar-specific warning shown when Sidecar is connected"
    else
      fail "expected Sidecar-specific addendum not found"
    fi
  else
    skip "Sidecar-specific addendum check (no Sidecar currently connected)"
  fi
  kill -INT "$KWC" 2>/dev/null
  wait_for_exit "$KWC"
fi

# The sections below (caffeinate integration, command wrapping, -w) don't
# depend on a single-display baseline or on the phantom display actually
# registering with WindowServer; on Intel, apply() reports success even
# though nothing really registers (see RESEARCH.md), so these still exercise
# real code paths there. Only the "Virtual display creation" and
# clamshell-property assertions further down are genuinely
# Apple-Silicon/clean-baseline-dependent.
section "caffeinate integration"

"$KEEPAWAKE" --force >/tmp/kw_caffeinate_default.log 2>&1 &
KWCA=$!
disown
sleep 1
if pgrep -f "caffeinate -i -w $KWCA" >/dev/null; then
  pass "default run spawns internal caffeinate with -i (matches caffeinate's own default)"
else
  fail "expected an internal 'caffeinate -i -w $KWCA' process, none found"
fi
kill -INT "$KWCA" 2>/dev/null
wait_for_exit "$KWCA"
sleep 1
if pgrep -f "caffeinate .* -w $KWCA" >/dev/null; then
  fail "internal caffeinate still running after keepawake stopped (SIGINT)"
else
  pass "internal caffeinate exits when keepawake is stopped (SIGINT)"
fi

# The running status line advertises the thermal-cutoff level (default critical).
if grep -q "thermal-cutoff critical" /tmp/kw_caffeinate_default.log; then
  pass "default run reports thermal-cutoff critical in its status line"
else
  fail "expected 'thermal-cutoff critical' in the default status line"
fi

"$KEEPAWAKE" --force --thermal serious -t 1 >/tmp/kw_thermal_serious.log 2>&1
if grep -q "thermal-cutoff serious" /tmp/kw_thermal_serious.log; then
  pass "--thermal serious is reflected in the status line"
else
  fail "expected 'thermal-cutoff serious' in the status line with --thermal serious"
fi

"$KEEPAWAKE" --force -d -s >/tmp/kw_caffeinate_flags.log 2>&1 &
KWCB=$!
disown
sleep 1
if pgrep -f "caffeinate -ds -w $KWCB" >/dev/null; then
  pass "-d -s flags passed through to internal caffeinate"
else
  fail "expected 'caffeinate -ds -w $KWCB', not found"
fi
kill -INT "$KWCB" 2>/dev/null
wait_for_exit "$KWCB"

"$KEEPAWAKE" --force -d -i -m -s -u >/tmp/kw_caffeinate_allflags.log 2>&1 &
KWCC=$!
disown
sleep 1
if pgrep -f "caffeinate -dimsu -w $KWCC" >/dev/null; then
  pass "all five assertion flags (-d -i -m -s -u) passed through together"
else
  fail "expected 'caffeinate -dimsu -w $KWCC', not found"
fi
kill -INT "$KWCC" 2>/dev/null
wait_for_exit "$KWCC"

section "Command wrapping"

"$KEEPAWAKE" --force -- sh -c "exit 7" >/tmp/kw_wrap_exit.log 2>&1 &
KWE=$!
wait "$KWE" 2>/dev/null
WRAP_EXIT=$?
if [ "$WRAP_EXIT" -eq 7 ]; then
  pass "wrapped command's exit code is propagated"
else
  fail "expected exit 7 from wrapped command, got $WRAP_EXIT"
fi
if grep -q "wrapped command exited (status 7)" /tmp/kw_wrap_exit.log; then
  pass "wrapped-command-exit message printed"
else
  fail "expected wrapped-command-exit message not found"
fi
if pgrep -f "caffeinate .* -w $KWE" >/dev/null; then
  fail "internal caffeinate leaked after wrapped command exited on its own"
else
  pass "internal caffeinate cleaned up after wrapped command exited on its own"
fi

"$KEEPAWAKE" --force -- sleep 30 >/tmp/kw_wrap_signal.log 2>&1 &
KWW=$!
disown
sleep 1
WRAPPED_PID=$(pgrep -P "$KWW" -f sleep)
if [ -n "$WRAPPED_PID" ]; then
  pass "wrapped command started as a child of keepawake"
else
  fail "could not find wrapped 'sleep' child process"
fi
kill -INT "$KWW" 2>/dev/null
wait_for_exit "$KWW"
sleep 1
if [ -n "$WRAPPED_PID" ] && kill -0 "$WRAPPED_PID" 2>/dev/null; then
  fail "wrapped command still running after keepawake was interrupted"
else
  pass "wrapped command is terminated when keepawake receives SIGINT"
fi

"$KEEPAWAKE" --force -w 1 -- echo hi >/tmp/kw_mutex_w.log 2>&1
if [ $? -ne 0 ] && grep -q "can't be combined with a wrapped command" /tmp/kw_mutex_w.log; then
  pass "-w and a wrapped command are rejected together (deliberately not matching caffeinate's silent-ignore here; see RESEARCH.md)"
else
  fail "expected a mutual-exclusivity error for -w + wrapped command"
fi

"$KEEPAWAKE" --force -t 100 -- echo hi >/tmp/kw_mutex_t.log 2>&1
if [ $? -ne 0 ] && grep -q "can't be combined with a wrapped command" /tmp/kw_mutex_t.log; then
  pass "--duration and a wrapped command are rejected together"
else
  fail "expected a mutual-exclusivity error for -t + wrapped command"
fi

section "-w (wait on external pid)"

sleep 30 &
TARGET_PID=$!
disown
"$KEEPAWAKE" --force -w "$TARGET_PID" >/tmp/kw_waitpid.log 2>&1 &
KWWP=$!
disown
sleep 1
if kill -0 "$KWWP" 2>/dev/null; then
  pass "keepawake stays running while the -w target pid is alive"
else
  fail "keepawake exited early while target pid was still alive"
fi
kill "$TARGET_PID" 2>/dev/null
if wait_for_exit "$KWWP" 5; then
  pass "keepawake stops once the -w target pid exits"
else
  fail "keepawake did not stop after target pid exited"
  kill -9 "$KWWP" 2>/dev/null
fi

"$KEEPAWAKE" --force -w 999999 >/tmp/kw_waitpid_bad.log 2>&1
if [ $? -ne 0 ] && grep -q "no such process" /tmp/kw_waitpid_bad.log; then
  pass "-w rejects a nonexistent pid"
else
  fail "expected '-w 999999' to fail with 'no such process'"
fi

cleanup_stray_processes

if [ "$SKIP_HARDWARE_TESTS" -eq 1 ]; then
  skip "virtual display creation/sizing/clamshell tests (external display already attached)"
  skip "shutdown-behavior tests (external display already attached)"
  skip "duration auto-stop tests (external display already attached)"
else
  section "Virtual display creation"

  BASELINE_CLAMSHELL=$(clamshell_prop)
  echo "  baseline AppleClamshellCausesSleep = $BASELINE_CLAMSHELL"

  "$KEEPAWAKE" --force >/tmp/kw_run.log 2>&1 &
  KW_PID=$!
  disown
  sleep 2

  if grep -q "running (virtual display" /tmp/kw_run.log; then
    pass "keepawake reports running"
  else
    fail "keepawake did not print running status"
  fi

  DISPLAY_COUNT_NOW=$(display_type_count)
  if [ "$DISPLAY_COUNT_NOW" -eq 2 ]; then
    pass "virtual display appears in system_profiler"
  else
    fail "expected 2 displays, got $DISPLAY_COUNT_NOW"
  fi

  if system_profiler SPDisplaysDataType 2>/dev/null | grep -q "Keepawake Phantom Display"; then
    pass "virtual display has expected name"
  else
    fail "virtual display name not found"
  fi

  SCREENS_JSON=$(screen_info)
  SCREEN_COUNT=$(echo "$SCREENS_JSON" | jq 'length' 2>/dev/null)
  if [ "$SCREEN_COUNT" == "2" ]; then
    pass "NSScreen.screens count is 2"
  else
    fail "expected NSScreen count 2, got $SCREEN_COUNT"
  fi

  MAIN_JSON=$(echo "$SCREENS_JSON" | jq '.[] | select(.isMain==true)' 2>/dev/null)
  PHANTOM_JSON=$(echo "$SCREENS_JSON" | jq '.[] | select(.isMain==false)' 2>/dev/null)
  MAIN_W=$(echo "$MAIN_JSON" | jq '.frameW' 2>/dev/null)
  MAIN_H=$(echo "$MAIN_JSON" | jq '.frameH' 2>/dev/null)
  PHANTOM_W=$(echo "$PHANTOM_JSON" | jq '.frameW' 2>/dev/null)
  PHANTOM_H=$(echo "$PHANTOM_JSON" | jq '.frameH' 2>/dev/null)
  PHANTOM_X=$(echo "$PHANTOM_JSON" | jq '.frameX' 2>/dev/null)
  MAIN_X=$(echo "$MAIN_JSON" | jq '.frameX' 2>/dev/null)

  if [ -n "$MAIN_W" ] && [ -n "$PHANTOM_W" ]; then
    read -r EXP_W EXP_H <<EOF
$(python3 -c "
import math
w, h = $MAIN_W, $MAIN_H
cap = 1654400.0
pixels = w * h
if pixels > cap:
    scale = math.sqrt(cap / pixels)
    print(int(w * scale), int(h * scale))
else:
    print(int(w), int(h))
")
EOF
    DIFF_W=$(python3 -c "print(abs($PHANTOM_W - $EXP_W))")
    DIFF_H=$(python3 -c "print(abs($PHANTOM_H - $EXP_H))")
    if [ "$DIFF_W" -le 2 ] && [ "$DIFF_H" -le 2 ]; then
      pass "virtual display sized correctly (got ${PHANTOM_W}x${PHANTOM_H}, expected ~${EXP_W}x${EXP_H})"
    else
      fail "virtual display size mismatch (got ${PHANTOM_W}x${PHANTOM_H}, expected ~${EXP_W}x${EXP_H})"
    fi

    # keepawake parks the phantom at the far-right outer edge, bottom-aligned to
    # its neighbor (see RESEARCH.md; positioning works, it just clamps to a
    # contiguous edge). On a single-display machine the neighbor is the main
    # display, so the phantom's left edge should sit exactly at the main
    # display's right edge. Assert that.
    ADJACENT=$(python3 -c "
main_x1 = $MAIN_X + $MAIN_W
print('yes' if abs($PHANTOM_X - main_x1) <= 2 else 'no')
")
    if [ "$ADJACENT" == "yes" ]; then
      pass "virtual display parked at the main display's right edge (far-right, as intended)"
    else
      fail "virtual display not parked at the expected far-right edge (got phantom x=$PHANTOM_X, main right edge=$((MAIN_X + MAIN_W)))"
    fi
  else
    fail "could not read screen geometry to check sizing/placement"
  fi

  RUNNING_CLAMSHELL=$(clamshell_prop)
  echo "  with virtual display running, AppleClamshellCausesSleep = $RUNNING_CLAMSHELL"
  if [ "$RUNNING_CLAMSHELL" == "No" ]; then
    pass "AppleClamshellCausesSleep reads No with virtual display active"
  else
    fail "AppleClamshellCausesSleep reads $RUNNING_CLAMSHELL (note: this property has been observed to be an unreliable instantaneous read in manual testing; a failure here is worth rechecking by hand, not necessarily proof the mechanism is broken)"
  fi

  section "Instance locking"

  "$KEEPAWAKE" --force >/tmp/kw_second_instance.log 2>&1
  SECOND_EXIT=$?
  if [ "$SECOND_EXIT" -ne 0 ] && grep -q "already running" /tmp/kw_second_instance.log; then
    pass "second instance refuses to start while one is already running"
  else
    fail "second instance should have refused to start (exit=$SECOND_EXIT)"
  fi

  section "Shutdown behavior"

  kill -INT "$KW_PID"
  if wait_for_exit "$KW_PID"; then
    pass "process exits after SIGINT"
  else
    fail "process still alive after SIGINT"
    kill -9 "$KW_PID" 2>/dev/null
    sleep 1
  fi
  DISPLAY_COUNT_AFTER=$(display_type_count)
  if [ "$DISPLAY_COUNT_AFTER" -eq 1 ]; then
    pass "virtual display torn down after SIGINT"
  else
    fail "virtual display still present after SIGINT (count=$DISPLAY_COUNT_AFTER)"
  fi

  "$KEEPAWAKE" --force -t 2 >/tmp/kw_relock.log 2>&1
  if grep -q "running (virtual display" /tmp/kw_relock.log; then
    pass "lock released after SIGINT teardown (new instance started fine)"
  else
    fail "lock not released after SIGINT teardown; new instance could not start"
  fi

  "$KEEPAWAKE" --force >/tmp/kw_run2.log 2>&1 &
  KW_PID2=$!
  disown
  sleep 2
  kill -TERM "$KW_PID2"
  if wait_for_exit "$KW_PID2"; then
    pass "process exits after SIGTERM"
  else
    fail "process still alive after SIGTERM"
    kill -9 "$KW_PID2" 2>/dev/null
    sleep 1
  fi
  DISPLAY_COUNT_AFTER2=$(display_type_count)
  if [ "$DISPLAY_COUNT_AFTER2" -eq 1 ]; then
    pass "virtual display torn down after SIGTERM"
  else
    fail "virtual display still present after SIGTERM (count=$DISPLAY_COUNT_AFTER2)"
  fi

  section "Duration auto-stop"

  "$KEEPAWAKE" --force -t 3 >/tmp/kw_duration.log 2>&1 &
  KW_PID3=$!
  disown
  sleep 2
  D1=$(display_type_count)
  if [ "$D1" -eq 2 ]; then
    pass "display present shortly after start (duration test)"
  else
    fail "display not created for duration test"
  fi
  sleep 4
  if ! kill -0 "$KW_PID3" 2>/dev/null; then
    pass "process auto-exits after --duration elapses"
  else
    fail "process still alive after duration elapsed"
    kill -9 "$KW_PID3" 2>/dev/null
  fi
  D2=$(display_type_count)
  if [ "$D2" -eq 1 ]; then
    pass "display torn down after duration auto-stop"
  else
    fail "display still present after duration auto-stop"
  fi
fi

section "Known not automatable"
echo "  Confirming the machine actually stays awake through a REAL physical"
echo "  lid close is not covered here; there is no software path to"
echo "  simulate AppleClamshellState. This suite validates every mechanism"
echo "  up to that point. See RESEARCH.md's \"Verifying it yourself\" section."

section "Summary"
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  exit 0
fi
