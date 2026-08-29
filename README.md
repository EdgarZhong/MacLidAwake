# keepawake

Keep a Mac awake - even on battery with the lid closed. 

## Install

```
brew tap ecc521/keepawake
brew install ecc521/keepawake/keepawake
sudo keepawake install
```

Or build from source with `cd cli/keepawake && ./build.sh`, then run
`sudo ./keepawake install`.

The one-time `install` step adds a sudoers rule permitting exactly two
commands (taking and releasing the sleep hold) and nothing else, plus the
lock file sessions use to coordinate. Remove both at any time with
`sudo keepawake uninstall`. See [How it works](#how-it-works) for what the rule
contains and why it's needed. Works on Apple Silicon and Intel.

(macOS leaves `sudo` inheriting your `PATH`, so `sudo keepawake install` finds
the Homebrew binary. If you've set `secure_path` in your sudoers, use
`sudo "$(which keepawake)" install` instead.)

## Use

```
keepawake                    # run until Ctrl-C
keepawake -t 3600            # run for 1 hour, then stop automatically
keepawake -- ./backup.sh     # run a command, stop when it exits
keepawake --battery 20       # release the hold at 20% battery; default 10
```

Whenever keepawake stops, the hold is released and normal sleep resumes.
The `-d -i -m -s -u` flags match `caffeinate`, so you can use keepawake in its
place and still cover ordinary display and disk sleep. Full CLI reference:
[cli/keepawake/README.md](cli/keepawake/README.md).

## The problem

Clamshell mode has always had two gates: an external display **and** AC power.
`caffeinate` and the public `IOPMAssertion` APIs can't clear either one. The
AC-power gate is stated outright in `caffeinate`'s own man page, for `-s`:

> This assertion is valid only when system is running on AC power.

So an unplugged Mac with the lid closed sleeps when idle no matter how many
assertions are held. Attaching a real monitor or a dummy HDMI plug satisfies the
display gate, but that's the hardware dependency this project exists to avoid,
and on battery it doesn't help anyway.

## How it works

keepawake holds the system-wide `SleepDisabled` power-management setting, via
`pmset -a disablesleep 1`, for as long as the session lasts.

That setting is why this works where assertions don't. Run `pmset -g` and it is
reported in its own **System-wide power settings** block, outside the AC/Battery
split that every other setting lives in. It isn't an assertion competing with
power-source policy: `powerd` consults it directly, and it is power-source
independent.

Setting it requires root, which is what the one-time `sudo keepawake install`
is for. It writes `/etc/sudoers.d/keepawake`:

```
%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

When arguments are specified, sudoers matches the **full argument vector
literally**, so this grants those two exact commands and no other `pmset`
invocation. The file is installed `0440 root:wheel` and validated with
`visudo -cf` before being placed, since a malformed file in `sudoers.d` would
break `sudo` system-wide.

`SleepDisabled` governs system sleep only. Display and disk sleep are
independent timers it doesn't touch, so keepawake also runs `/usr/bin/caffeinate`
internally (tied to its own lifetime via `-w`) to hold those assertions. That
makes it a drop-in `caffeinate` replacement rather than a system-sleep-only
patch.

## Safety cutoffs

The hold is unbreakable in a way an assertion isn't, which makes the cutoffs the
most important part of the tool. Both **release the hold without ending the
session**, and re-take it when conditions recover:

- `--battery <pct>|none` (default `10`): releases on battery at that
  percentage, so an unattended machine doesn't run itself flat. Never fires on
  AC. Re-taken when you plug in.
- `--thermal none|serious|critical` (default `critical`): releases under
  thermal pressure, for when keepawake is left running somewhere the machine
  can't shed heat. Re-taken once thermal state returns to nominal. `serious` is
  reached by ordinary heavy CPU/GPU work, so it's opt-in and only acts with the
  lid closed.

Releasing rather than exiting matters: thermal pressure is transient, and
plugging back in after a low-battery release should restore protection rather
than leave the rest of your work unguarded.

## Recovering a stuck hold

`SleepDisabled` is persisted to disk, so a run killed with `kill -9` or lost to
a panic can leave it set. Any of these clears it:

```
keepawake --release          # explicit
keepawake ...                # any later run takes the hold, then clears it on exit
sudo pmset -a disablesleep 0 # directly, no keepawake involved
```

`pmset -g` reports `SleepDisabled` on its first line, which is also the answer
to "why won't this Mac sleep?".

## Known limitations

- **The hold is system-wide.** It is one global setting, not a per-process
  assertion. Concurrent sessions are fine: they share a `flock(2)`, and the last
  one out releases the hold, but that also means the last session ending clears
  a hold you set by hand outside keepawake.
- **Requires an admin user.** The sudoers rule is granted to the `admin` group.

## Testing

```
./tests/run_tests.sh
```

Tests that take a real hold need the sudoers rule installed and skip cleanly
without it. A physical lid close still has to be tested by hand.

## History

Before 0.3.0, keepawake defeated clamshell sleep by registering a software-only
virtual display through the private `CGVirtualDisplay` API, no hardware, but it
only ever satisfied the *display* gate. The AC-power gate remained, so an
unplugged machine still slept with the lid closed. `SleepDisabled` clears both,
which retired the private API along with its cursor drift, its WindowServer
prompt, and an undocumented pixel cap that moved between macOS releases. The
proof of concept is preserved in [experiments/](experiments/).

## License

MIT. See [LICENSE](LICENSE).
