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

for VFLAG in --version -v; do
  "$KEEPAWAKE" "$VFLAG" >/tmp/kw_version.log 2>&1
  V_EXIT=$?
  # Must exit 0 and print "keepawake <semver>" -- nothing else, no side effects.
  if [ "$V_EXIT" -eq 0 ] && grep -qE '^keepawake [0-9]+\.[0-9]+\.[0-9]+$' /tmp/kw_version.log; then
    pass "$VFLAG prints the version and exits 0 ($(cat /tmp/kw_version.log))"
  else
    fail "$VFLAG (exit=$V_EXIT, output: $(cat /tmp/kw_version.log))"
  fi
done

# The version the binary reports must match the newest git tag, or a release
# will ship a binary that misreports itself.
BIN_VERSION=$("$KEEPAWAKE" --version 2>/dev/null | awk '{print $2}')
TAG_VERSION=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
NEWER=$(printf '%s\n%s\n' "$BIN_VERSION" "$TAG_VERSION" | sort -V | tail -1)
if [ -z "$TAG_VERSION" ]; then
  skip "version-matches-tag check (no git tags found)"
elif [ "$BIN_VERSION" == "$TAG_VERSION" ]; then
  pass "reported version matches the latest git tag ($BIN_VERSION)"
elif [ "$NEWER" == "$BIN_VERSION" ]; then
  # Normal between bumping toolVersion and cutting the tag. Only the reverse
  # is a real problem: a binary that under-reports what it actually is.
  pass "version $BIN_VERSION is ahead of latest tag v$TAG_VERSION (unreleased)"
else
  fail "binary reports $BIN_VERSION but tag v$TAG_VERSION is newer; toolVersion is stale"
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
    pass "refuses to run on Intel"
  else
    fail "expected a refusal message on Intel hardware"
  fi
else
  skip "Intel-refusal check (running on $ARCH, not Intel)"
fi

section "Startup output is quiet"

# A clean run should print exactly one line: the status line. The battery and
# cursor-drift warnings were deliberately removed (a permanent property of the
# mechanism belongs in the README, not on every launch), so assert their
# absence rather than their presence -- otherwise they could creep back in.
if [ "$ARCH" == "x86_64" ]; then
  skip "quiet-startup check (Intel dies at the arch guard before reaching this)"
else
  "$KEEPAWAKE" >/tmp/kw_quiet.log 2>&1 &
  KWQ=$!
  disown
  sleep 2
  QUIET_LINES=$(grep -c . /tmp/kw_quiet.log)
  if [ "$QUIET_LINES" -eq 1 ]; then
    pass "clean run prints exactly one line of output"
  else
    fail "expected 1 line of startup output, got $QUIET_LINES:"
    sed 's/^/      /' /tmp/kw_quiet.log
  fi
  if grep -qi "warning:" /tmp/kw_quiet.log; then
    fail "clean run emitted a warning; startup is supposed to be silent"
    grep -i "warning:" /tmp/kw_quiet.log | sed 's/^/      /'
  else
    pass "clean run emits no warnings"
  fi
  kill -INT "$KWQ" 2>/dev/null
  wait_for_exit "$KWQ"
fi

# The sections below (caffeinate integration, command wrapping, -w) don't
# depend on a single-display baseline or on the phantom display actually
# registering with WindowServer; on Intel, apply() reports success even
# though nothing really registers (see RESEARCH.md), so these still exercise
# real code paths there. Only the "Virtual display creation" and
# clamshell-property assertions further down are genuinely
# Apple-Silicon/clean-baseline-dependent.
section "caffeinate integration"

"$KEEPAWAKE" >/tmp/kw_caffeinate_default.log 2>&1 &
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

"$KEEPAWAKE" --thermal serious -t 1 >/tmp/kw_thermal_serious.log 2>&1
if grep -q "thermal-cutoff serious" /tmp/kw_thermal_serious.log; then
  pass "--thermal serious is reflected in the status line"
else
  fail "expected 'thermal-cutoff serious' in the status line with --thermal serious"
fi

section "Battery cutoff"

if grep -q "battery-cutoff 5%" /tmp/kw_caffeinate_default.log; then
  pass "default run reports battery-cutoff 5% in its status line"
else
  fail "expected 'battery-cutoff 5%' in the default status line"
fi

"$KEEPAWAKE" --battery none -t 1 >/tmp/kw_batt_none.log 2>&1
if grep -q "battery-cutoff none" /tmp/kw_batt_none.log; then
  pass "--battery none is reflected in the status line"
else
  fail "expected 'battery-cutoff none' in the status line"
fi

"$KEEPAWAKE" --battery 20 -t 1 >/tmp/kw_batt_20.log 2>&1
if grep -q "battery-cutoff 20%" /tmp/kw_batt_20.log; then
  pass "--battery 20 is reflected in the status line"
else
  fail "expected 'battery-cutoff 20%' in the status line"
fi

for BAD in 0 100 -5 abc; do
  "$KEEPAWAKE" --battery "$BAD" >/tmp/kw_batt_bad.log 2>&1
  if [ $? -ne 0 ] && grep -q "between 1 and 99" /tmp/kw_batt_bad.log; then
    pass "--battery rejects '$BAD'"
  else
    fail "--battery '$BAD' should have been rejected"
  fi
done

"$KEEPAWAKE" --battery >/tmp/kw_batt_missing.log 2>&1
if [ $? -ne 0 ]; then
  pass "--battery rejects a missing value"
else
  fail "--battery with no value should fail"
fi

# Behavioral, not just cosmetic: the cutoff is gated on BOTH being on battery
# power AND the lid being closed. The suite always runs with the lid open, so
# even an absurd 99% threshold must not fire. This catches an inverted or
# missing gate, which would otherwise only show up as keepawake mysteriously
# quitting on a real closed-lid run.
"$KEEPAWAKE" --battery 99 >/tmp/kw_batt_gate.log 2>&1 &
KWBG=$!
disown
sleep 3
if kill -0 "$KWBG" 2>/dev/null; then
  pass "--battery 99 does not fire with the lid open (cutoff is correctly lid-gated)"
else
  fail "keepawake exited with --battery 99 and the lid open; the cutoff is not lid-gated"
  cat /tmp/kw_batt_gate.log | sed 's/^/      /'
fi
kill -INT "$KWBG" 2>/dev/null
wait_for_exit "$KWBG"

"$KEEPAWAKE" -d -s >/tmp/kw_caffeinate_flags.log 2>&1 &
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

"$KEEPAWAKE" -d -i -m -s -u >/tmp/kw_caffeinate_allflags.log 2>&1 &
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

"$KEEPAWAKE" -- sh -c "exit 7" >/tmp/kw_wrap_exit.log 2>&1 &
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

"$KEEPAWAKE" -- sleep 30 >/tmp/kw_wrap_signal.log 2>&1 &
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

"$KEEPAWAKE" -w 1 -- echo hi >/tmp/kw_mutex_w.log 2>&1
if [ $? -ne 0 ] && grep -q "can't be combined with a wrapped command" /tmp/kw_mutex_w.log; then
  pass "-w and a wrapped command are rejected together (deliberately not matching caffeinate's silent-ignore here; see RESEARCH.md)"
else
  fail "expected a mutual-exclusivity error for -w + wrapped command"
fi

"$KEEPAWAKE" -t 100 -- echo hi >/tmp/kw_mutex_t.log 2>&1
if [ $? -ne 0 ] && grep -q "can't be combined with a wrapped command" /tmp/kw_mutex_t.log; then
  pass "--duration and a wrapped command are rejected together"
else
  fail "expected a mutual-exclusivity error for -t + wrapped command"
fi

section "-w (wait on external pid)"

sleep 30 &
TARGET_PID=$!
disown
"$KEEPAWAKE" -w "$TARGET_PID" >/tmp/kw_waitpid.log 2>&1 &
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

"$KEEPAWAKE" -w 999999 >/tmp/kw_waitpid_bad.log 2>&1
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

  "$KEEPAWAKE" >/tmp/kw_run.log 2>&1 &
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
    # keepawake no longer computes a target size: it requests the main
    # display's full native pixel size and lets macOS downsize to whatever the
    # (version-dependent) CGVirtualDisplay pixel cap allows. So don't assert an
    # exact resolution -- assert the two properties that actually matter.
    #
    # 1. Aspect ratio is preserved, so windows moved to the phantom aren't
    #    reshaped more than necessary.
    # 2. The phantom didn't collapse to a degenerate fallback. Requesting the
    #    point size instead of the pixel size is the known way to trip this: on
    #    a 16" MBP it yields 1024x662 (0.68M) instead of 1600x1034 (1.65M).
    #    Anything at or above 1.4M means we landed near the cap as intended.
    ASPECT_OK=$(python3 -c "
main = $MAIN_W / $MAIN_H
phantom = $PHANTOM_W / $PHANTOM_H
print('yes' if abs(main - phantom) / main <= 0.02 else 'no')
")
    if [ "$ASPECT_OK" == "yes" ]; then
      pass "virtual display preserves the main display's aspect ratio (${PHANTOM_W}x${PHANTOM_H} vs ${MAIN_W}x${MAIN_H})"
    else
      fail "virtual display aspect ratio does not match main (${PHANTOM_W}x${PHANTOM_H} vs ${MAIN_W}x${MAIN_H})"
    fi

    # The phantom must never be LARGER than the real display in points. It
    # becomes the main display when the lid closes, and overshooting is far more
    # disruptive than falling slightly short -- a 2x phantom would reflow every
    # window into a space four times the area. Guards against the pixel cap
    # rising in a future release and letting an oversized request through.
    CEILING_OK=$(python3 -c "
print('yes' if $PHANTOM_W <= $MAIN_W and $PHANTOM_H <= $MAIN_H else 'no')
")
    if [ "$CEILING_OK" == "yes" ]; then
      pass "virtual display never exceeds the real display's point size (${PHANTOM_W}x${PHANTOM_H} <= ${MAIN_W}x${MAIN_H})"
    else
      fail "virtual display is LARGER than the real display (${PHANTOM_W}x${PHANTOM_H} vs ${MAIN_W}x${MAIN_H}); this would reflow every window on lid close"
    fi

    SIZE_OK=$(python3 -c "
phantom_px = $PHANTOM_W * $PHANTOM_H
main_px = $MAIN_W * $MAIN_H
# If the main display is itself small enough to fit under the cap, the phantom
# should simply match it; otherwise expect a near-cap result.
print('yes' if phantom_px >= min(main_px, 1_400_000) else 'no')
")
    if [ "$SIZE_OK" == "yes" ]; then
      PX=$(python3 -c "print(f'{$PHANTOM_W * $PHANTOM_H / 1e6:.2f}M')")
      pass "virtual display landed near the pixel cap, not a degenerate fallback ($PX px)"
    else
      PX=$(python3 -c "print(f'{$PHANTOM_W * $PHANTOM_H / 1e6:.2f}M')")
      fail "virtual display collapsed to a small fallback size (${PHANTOM_W}x${PHANTOM_H}, $PX px)"
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

  "$KEEPAWAKE" >/tmp/kw_second_instance.log 2>&1
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

  "$KEEPAWAKE" -t 2 >/tmp/kw_relock.log 2>&1
  if grep -q "running (virtual display" /tmp/kw_relock.log; then
    pass "lock released after SIGINT teardown (new instance started fine)"
  else
    fail "lock not released after SIGINT teardown; new instance could not start"
  fi

  "$KEEPAWAKE" >/tmp/kw_run2.log 2>&1 &
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

  "$KEEPAWAKE" -t 3 >/tmp/kw_duration.log 2>&1 &
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
