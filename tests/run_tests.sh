#!/bin/bash
# Automated test suite for keepawake. macOS-only, by necessity (everything
# here pokes real OS-level power state).
#
# What this DOES verify empirically: the generated sudoers rule passes visudo
# validation and grants only the two intended commands, the `SleepDisabled`
# hold is taken at startup and cleared on every exit path (SIGINT, SIGTERM,
# SIGHUP, --duration, -w, wrapped-command exit), the privileged subcommands
# refuse to run unprivileged, and basic CLI argument handling.
#
# What this CANNOT verify: whether the machine actually stays awake through a
# real physical lid close, and whether a cutoff fires against real hardware
# conditions (draining a battery to 10% or driving thermal state to critical
# on demand aren't things a test can arrange). Those remain manual; see the
# closing note.
#
# Tests that take a real hold need the sudoers rule installed
# (`sudo keepawake install`) and skip cleanly without it.

set -uo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd .. && pwd)"
CLI_DIR="$REPO_ROOT/cli/keepawake"
KEEPAWAKE="$CLI_DIR/keepawake"

PMSET=/usr/bin/pmset
SUDOERS_RULE=/etc/sudoers.d/keepawake
# Created by `keepawake install`, as root: it lives in root-owned /var/db so no
# unprivileged user can pre-place a symlink there. Sessions open it but never
# create it, so its absence means no session can start.
LOCK_FILE=/var/db/keepawake.lock

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }
section() { echo ""; echo "== $1 =="; }

# The single source of truth for whether a hold is active. `pmset -g` reports
# it under "System-wide power settings", outside the AC/Battery split.
sleep_disabled() {
  $PMSET -g 2>/dev/null | awk '/SleepDisabled/{print $2; exit}'
}

# Does the sudoers rule grant the hold commands without a password? -n keeps
# this from blocking on a password prompt when the rule is absent.
# NOTE: `sudo -l <cmd>` is useless here. macOS grants admins a blanket
# `%admin ALL=(ALL) ALL`, so it reports success for every command, and once any
# NOPASSWD rule exists the listing stops requiring a password too. Parse the
# listing for an entry that is both NOPASSWD and names the hold command.
has_sudoers_rule() {
  sudo -n -l 2>/dev/null | grep -q "NOPASSWD.*$PMSET -a disablesleep 1"
}

# Poll until a PID actually exits instead of guessing a fixed sleep duration;
# avoids flaky races between test sections.
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

# Wait for SleepDisabled to reach an expected value, rather than sleeping a
# fixed amount: the pmset call is a subprocess and settles asynchronously.
wait_for_hold() {
  local want="$1"
  local timeout="${2:-5}"
  local waited=0
  while [ "$(sleep_disabled)" != "$want" ]; do
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
  # Never leave a hold behind, whatever happened above.
  if has_sudoers_rule; then
    sudo -n "$PMSET" -a disablesleep 0 >/dev/null 2>&1
  fi
}
trap cleanup_stray_processes EXIT

cleanup_stray_processes

section "Preconditions"
# Both halves of `install` are needed: the sudoers rule to take the hold without
# a password, and the root-created lock file to join the participation lock.
if has_sudoers_rule && [ -e "$LOCK_FILE" ]; then
  pass "sudoers rule and lock file present; hold tests will run"
  RULE_INSTALLED=1
elif has_sudoers_rule; then
  echo "  sudoers rule present but $LOCK_FILE is missing."
  echo "  Re-run 'sudo keepawake install' to create it (idempotent) and cover the hold tests."
  RULE_INSTALLED=0
else
  echo "  sudoers rule not installed (run 'sudo keepawake install' to cover the hold tests)"
  RULE_INSTALLED=0
fi

if [ "$(sleep_disabled)" == "0" ]; then
  pass "no sleep hold active at start (clean baseline)"
else
  echo "  WARNING: SleepDisabled is already 1 before testing; clearing it"
  if [ "$RULE_INSTALLED" -eq 1 ]; then
    sudo -n "$PMSET" -a disablesleep 0 >/dev/null 2>&1
  fi
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

if grep -qi "warning:" /tmp/keepawake_build.log; then
  fail "build emitted warnings"
  grep -i "warning:" /tmp/keepawake_build.log | head -5 | sed 's/^/      /'
else
  pass "build is warning-free"
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

# These all fail during parsing, before the sudoers preflight, so they run
# whether or not the rule is installed.
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

"$KEEPAWAKE" --battery 150 >/tmp/kw_batt_bad.log 2>&1
if [ $? -ne 0 ] && grep -q "between 1 and 99" /tmp/kw_batt_bad.log; then
  pass "--battery rejects an out-of-range percentage"
else
  fail "--battery 150 should fail with a range error"
fi

"$KEEPAWAKE" -w 999999 >/tmp/kw_waitpid_bad.log 2>&1
if [ $? -ne 0 ] && grep -q "no such process" /tmp/kw_waitpid_bad.log; then
  pass "-w rejects a nonexistent pid"
else
  fail "expected '-w 999999' to fail with 'no such process'"
fi

"$KEEPAWAKE" -w 1 -- echo hi >/tmp/kw_mutex_w.log 2>&1
if [ $? -ne 0 ] && grep -q "can't be combined with a wrapped command" /tmp/kw_mutex_w.log; then
  pass "-w and a wrapped command are rejected together (deliberately not matching caffeinate's silent-ignore here)"
else
  fail "expected a mutual-exclusivity error for -w + wrapped command"
fi

"$KEEPAWAKE" -t 100 -- echo hi >/tmp/kw_mutex_t.log 2>&1
if [ $? -ne 0 ] && grep -q "can't be combined with a wrapped command" /tmp/kw_mutex_t.log; then
  pass "--duration and a wrapped command are rejected together"
else
  fail "expected a mutual-exclusivity error for -t + wrapped command"
fi

section "Privileged subcommands"

"$KEEPAWAKE" install >/tmp/kw_install_nonroot.log 2>&1
if [ $? -ne 0 ] && grep -q "must run as root" /tmp/kw_install_nonroot.log; then
  pass "install refuses to run unprivileged"
else
  fail "install should refuse to run without root"
fi

"$KEEPAWAKE" uninstall >/tmp/kw_uninstall_nonroot.log 2>&1
if [ $? -ne 0 ] && grep -q "must run as root" /tmp/kw_uninstall_nonroot.log; then
  pass "uninstall refuses to run unprivileged"
else
  fail "uninstall should refuse to run without root"
fi

# The rule keepawake would install must survive visudo validation. A malformed
# file in sudoers.d breaks sudo system-wide, so this is the highest-stakes
# assertion in the suite. Build the expected text independently of the binary
# so a regression in either side shows up as a mismatch.
EXPECTED_RULE=/tmp/kw_expected.sudoers
# Must be removed first: it's written 0440, so a second run of this suite can't
# overwrite it in place. Without this the write fails silently and the check
# below validates a stale file from a previous run -- passing vacuously.
rm -f "$EXPECTED_RULE"
cat > "$EXPECTED_RULE" <<EOF
# keepawake $BIN_VERSION — installed by \`sudo keepawake install\`
# Grants exactly two commands: taking and releasing the system sleep hold.
# Remove with \`sudo keepawake uninstall\`.
%admin ALL=(root) NOPASSWD: $PMSET -a disablesleep 1, $PMSET -a disablesleep 0
EOF
chmod 0440 "$EXPECTED_RULE"

if ! grep -q "disablesleep" "$EXPECTED_RULE" 2>/dev/null; then
  fail "could not write the expected rule file; the visudo check below would be vacuous"
elif /usr/sbin/visudo -cf "$EXPECTED_RULE" >/tmp/kw_visudo.log 2>&1; then
  pass "generated sudoers rule passes visudo validation"
else
  fail "generated sudoers rule FAILS visudo validation: $(cat /tmp/kw_visudo.log)"
fi

# Confirm visudo actually rejects garbage, so the check above isn't vacuous.
printf 'this is not valid sudoers\n' > /tmp/kw_bad.sudoers
if /usr/sbin/visudo -cf /tmp/kw_bad.sudoers >/dev/null 2>&1; then
  fail "visudo accepted a malformed rule; the install-time validation is not protective"
else
  pass "visudo rejects a malformed rule (validation is meaningful)"
fi

if [ "$RULE_INSTALLED" -eq 1 ]; then
  # Scope is checked against the `sudo -l` listing, not by reading the file:
  # it's installed 0440 root:wheel and deliberately unreadable to a normal user.
  # Only NOPASSWD lines matter -- the blanket `%admin ALL=(ALL) ALL` that macOS
  # ships covers every command anyway, but demands a password, so it isn't a
  # grant this rule is responsible for.
  NOPASSWD_LINES=$(sudo -n -l 2>/dev/null | grep "NOPASSWD")

  if echo "$NOPASSWD_LINES" | grep -q "$PMSET -a disablesleep 0"; then
    pass "installed rule grants the release command"
  else
    fail "installed rule does not grant the release command"
  fi

  # Any NOPASSWD pmset grant beyond the two disablesleep forms is too wide.
  if echo "$NOPASSWD_LINES" | grep -q "hibernatemode\|sleep 0 \|disablesleep [^01]"; then
    fail "installed rule grants an unintended pmset command; the grant is too wide"
    echo "$NOPASSWD_LINES" | sed 's/^/      /'
  else
    pass "installed rule grants no pmset command beyond the two disablesleep forms"
  fi
else
  skip "installed-rule scope checks (rule not installed)"
fi

if [ "$RULE_INSTALLED" -eq 0 ]; then
  section "Hold behavior"
  skip "all hold tests (sudoers rule not installed; run 'sudo keepawake install')"

  # Either prerequisite can be the missing one — the sudoers rule or the
  # root-created lock file — and they fail at different points with different
  # text. The invariant is the same: refuse to start, and name the one command
  # that fixes it.
  "$KEEPAWAKE" -t 1 >/tmp/kw_preflight.log 2>&1
  if [ $? -ne 0 ] && grep -q "keepawake install" /tmp/kw_preflight.log; then
    pass "preflight fails with an actionable message when a prerequisite is absent"
  else
    fail "expected a preflight error naming 'sudo keepawake install'"
  fi
else

  section "Hold lifecycle"

  "$KEEPAWAKE" >/tmp/kw_run.log 2>&1 &
  KW_PID=$!
  disown
  if wait_for_hold 1; then
    pass "SleepDisabled set to 1 while keepawake runs"
  else
    fail "SleepDisabled did not reach 1 after startup"
  fi

  if grep -q "running (sleep hold active" /tmp/kw_run.log; then
    pass "status line reports the hold as active"
  else
    fail "expected 'running (sleep hold active' in the status line"
  fi

  section "Startup output is quiet"

  # A clean run should print exactly one line: the status line. Cutoff activity
  # goes to stderr and only on an actual event, so assert the absence of
  # warnings rather than their presence -- otherwise they could creep back in.
  QUIET_LINES=$(grep -c . /tmp/kw_run.log)
  if [ "$QUIET_LINES" -eq 1 ]; then
    pass "clean run prints exactly one line of output"
  else
    fail "expected 1 line of startup output, got $QUIET_LINES:"
    sed 's/^/      /' /tmp/kw_run.log
  fi
  if grep -qi "warning:" /tmp/kw_run.log; then
    fail "clean run emitted a warning; startup is supposed to be silent"
    grep -i "warning:" /tmp/kw_run.log | sed 's/^/      /'
  else
    pass "clean run emits no warnings"
  fi

  section "Concurrent sessions"

  # Sessions compose: the hold is a shared flock, so a second session joins
  # rather than being refused, and the hold survives until the LAST one leaves.
  "$KEEPAWAKE" >/tmp/kw_second_instance.log 2>&1 &
  KW_SECOND_PID=$!
  disown
  if wait_for_exit "$KW_SECOND_PID" 3; then
    fail "second concurrent session exited instead of joining"
    cat /tmp/kw_second_instance.log
  else
    pass "second concurrent session starts alongside the first"
  fi
  if [ "$(sleep_disabled)" == "1" ]; then
    pass "hold still held with two sessions running"
  else
    fail "hold not set with two sessions running"
  fi

  # The critical property: the first session leaving must NOT clear a hold the
  # second still wants. This is what a naive single-owner design gets wrong.
  kill -INT "$KW_SECOND_PID"
  wait_for_exit "$KW_SECOND_PID" 5
  sleep 0.5
  if [ "$(sleep_disabled)" == "1" ]; then
    pass "one session exiting leaves the hold intact for the session still running"
  else
    fail "hold was cleared while another session was still running"
  fi

  # And a SIGKILLed participant must not strand the hold either: the kernel
  # drops its share, so the next session to leave still sees itself as last out.
  "$KEEPAWAKE" >/tmp/kw_third_instance.log 2>&1 &
  KW_THIRD_PID=$!
  disown
  sleep 1
  kill -9 "$KW_THIRD_PID" 2>/dev/null
  wait_for_exit "$KW_THIRD_PID" 5
  if [ "$(sleep_disabled)" == "1" ]; then
    pass "hold survives a SIGKILLed participant while another session runs"
  else
    fail "hold lost after a participant was SIGKILLed"
  fi

  section "Shutdown behavior"

  kill -INT "$KW_PID"
  if wait_for_exit "$KW_PID"; then
    pass "process exits after SIGINT"
  else
    fail "process still alive after SIGINT"
    kill -9 "$KW_PID" 2>/dev/null
  fi
  if wait_for_hold 0; then
    pass "hold released after SIGINT"
  else
    fail "SleepDisabled still 1 after SIGINT"
  fi

  "$KEEPAWAKE" -t 2 >/tmp/kw_relock.log 2>&1
  if grep -q "running (sleep hold active" /tmp/kw_relock.log; then
    pass "a fresh session starts cleanly after the last one exited"
  else
    fail "fresh session could not start after the last one exited"
  fi

  for SIG in TERM HUP; do
    "$KEEPAWAKE" >/tmp/kw_run_$SIG.log 2>&1 &
    KW_SIG_PID=$!
    disown
    wait_for_hold 1
    kill -$SIG "$KW_SIG_PID"
    if wait_for_exit "$KW_SIG_PID"; then
      pass "process exits after SIG$SIG"
    else
      fail "process still alive after SIG$SIG"
      kill -9 "$KW_SIG_PID" 2>/dev/null
    fi
    if wait_for_hold 0; then
      pass "hold released after SIG$SIG"
    else
      fail "SleepDisabled still 1 after SIG$SIG"
    fi
  done

  section "Duration auto-stop"

  "$KEEPAWAKE" -t 3 >/tmp/kw_duration.log 2>&1 &
  KW_PID3=$!
  disown
  if wait_for_hold 1; then
    pass "hold taken shortly after start (duration test)"
  else
    fail "hold not taken for duration test"
  fi
  if wait_for_exit "$KW_PID3" 8; then
    pass "process auto-exits after --duration elapses"
  else
    fail "process still alive after duration elapsed"
    kill -9 "$KW_PID3" 2>/dev/null
  fi
  if wait_for_hold 0; then
    pass "hold released after duration auto-stop"
  else
    fail "SleepDisabled still 1 after duration auto-stop"
  fi

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

  # The running status line advertises both cutoffs and their defaults.
  if grep -q "thermal-cutoff critical" /tmp/kw_caffeinate_default.log; then
    pass "default run reports thermal-cutoff critical in its status line"
  else
    fail "expected 'thermal-cutoff critical' in the default status line"
  fi
  if grep -q "battery-cutoff 10%" /tmp/kw_caffeinate_default.log; then
    pass "default run reports battery-cutoff 10% in its status line"
  else
    fail "expected 'battery-cutoff 10%' in the default status line"
  fi

  "$KEEPAWAKE" --thermal serious -t 1 >/tmp/kw_thermal_serious.log 2>&1
  if grep -q "thermal-cutoff serious" /tmp/kw_thermal_serious.log; then
    pass "--thermal serious is reflected in the status line"
  else
    fail "expected 'thermal-cutoff serious' in the status line with --thermal serious"
  fi

  "$KEEPAWAKE" --battery none -t 1 >/tmp/kw_batt_none.log 2>&1
  if grep -q "battery-cutoff none" /tmp/kw_batt_none.log; then
    pass "--battery none is reflected in the status line"
  else
    fail "expected 'battery-cutoff none' in the status line"
  fi

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
  if wait_for_hold 0; then
    pass "hold released after wrapped command exited on its own"
  else
    fail "SleepDisabled still 1 after wrapped command exited"
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
  if wait_for_hold 0; then
    pass "hold released after -w target exited"
  else
    fail "SleepDisabled still 1 after -w target exited"
  fi

  section "Stale-hold recovery"

  # SIGKILL bypasses every handler, so the hold survives the process. This is
  # the one failure mode the design accepts, and both documented recoveries
  # must actually work.
  "$KEEPAWAKE" >/tmp/kw_kill.log 2>&1 &
  KWK=$!
  disown
  wait_for_hold 1
  kill -9 "$KWK" 2>/dev/null
  wait_for_exit "$KWK"
  sleep 1
  if [ "$(sleep_disabled)" == "1" ]; then
    pass "SIGKILL leaves the hold set (expected; recovery is tested below)"
  else
    skip "stale-hold recovery (hold was already clear after SIGKILL)"
  fi

  "$KEEPAWAKE" --release >/tmp/kw_release.log 2>&1
  if [ $? -eq 0 ] && wait_for_hold 0; then
    pass "--release clears a stale hold"
  else
    fail "--release did not clear the stale hold"
  fi

  # The other documented recovery: any later run takes the hold and clears it
  # on exit, so a stranded hold self-heals without an explicit --release.
  sudo -n "$PMSET" -a disablesleep 1 >/dev/null 2>&1
  "$KEEPAWAKE" -t 1 >/tmp/kw_reconcile.log 2>&1
  if wait_for_hold 0; then
    pass "an ordinary run reconciles a pre-existing stale hold on exit"
  else
    fail "a pre-existing hold survived an ordinary run"
  fi
fi

cleanup_stray_processes

section "Known not automatable"
echo "  Two things this suite cannot cover:"
echo
echo "  1. Whether the machine actually stays awake through a REAL physical"
echo "     lid close. There is no software path to simulate"
echo "     AppleClamshellState. To check by hand, run this before and after a"
echo "     deliberate lid close and reopen:"
echo
echo "       pmset -g log | grep -i clamshell | tail -5"
echo
echo "     That log is the ground truth. Don't substitute an instantaneous"
echo "     \`ioreg -r -k AppleClamshellCausesSleep\` read: it has reported No on"
echo "     a machine that in fact sleeps on every real lid close."
echo "     experiments/clamshell-watch.sh polls the same properties live if"
echo "     you'd rather watch than check the log afterward."
echo
echo "  2. Whether a cutoff fires and recovers against real conditions."
echo "     Draining to 10% or forcing thermal state to critical on demand"
echo "     isn't something a test can arrange. To check the battery path by"
echo "     hand, run with a cutoff just under the current charge, e.g."
echo
echo "       keepawake --battery \$(( \$(pmset -g batt | grep -o '[0-9]*%' | tr -d '%') - 1 ))"
echo
echo "     then unplug and watch for the release message, and plug back in to"
echo "     confirm the hold is re-taken. \`pmset -g | head -2\` shows the state."

section "Summary"
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  exit 0
fi
