# keepawake

Prevents an Apple Silicon Mac from sleeping when the lid is closed — no
external display, no dummy HDMI plug, no kext. See `../../RESEARCH.md` for
the technical findings behind this, including known limitations.

## Install

Via Homebrew:

```
brew tap ecc521/keepawake
brew install ecc521/keepawake/keepawake
```

Or build from source directly (drop the leading `./` below if installed via
Homebrew):

```
./build.sh
```

## Use

```
./keepawake                    # run until Ctrl-C
./keepawake -t 3600            # run for 1 hour, then stop automatically
./keepawake --force            # skip the pre-flight warnings below
./keepawake -disu               # hold every caffeinate assertion too
./keepawake -- ./backup.sh     # run a command, stop when it exits
./keepawake -w 1234            # stop when pid 1234 exits
```

Run it before closing the lid; Ctrl-C (or the `--duration` timer elapsing,
or a wrapped command/`-w` pid exiting) releases the hold and lets normal
sleep resume immediately.

`keepawake` is meant as a drop-in replacement for `caffeinate`, not just a
clamshell patch: the phantom display defeats hardware-enforced clamshell
sleep, and it also spawns `/usr/bin/caffeinate` internally (tied to its own
PID via `-w`) to hold the same `-disu` assertions `caffeinate` would, so
ordinary idle/display/disk sleep is covered too. See `-h`/`--help` for the
full flag reference — the assertion flags (`-d -i -m -s -u`), `-t`
duration, `-w pid`, and trailing-command wrapping all match `caffeinate`'s
own semantics.

## Pre-flight warnings

- **Battery power**: closing the lid for extended periods on battery
  bypasses the thermal/battery protections clamshell sleep normally
  provides (e.g. in an enclosed bag).
- **Sidecar connected**: Universal Control has been observed routing the
  cursor onto a nearby Mac through the virtual display during development
  testing. Disconnect Sidecar / disable Universal Control first, or expect
  this.
- **Intel Macs**: the hardware-level clamshell enforcement this tool works
  around doesn't exist pre-Apple-Silicon; `sudo pmset -a disablesleep 1`
  already prevents clamshell sleep there (confirmed by testing) — plain
  `caffeinate` does not, it only blocks idle/display sleep, never
  lid-closed sleep. `--force` will run this tool on Intel anyway, but on
  the one Intel Mac it's actually been tested on, the virtual display
  never registered at any size (see RESEARCH.md) — `pmset` isn't just the
  easier option there, it may be the only one that works.

All three can be skipped with `--force`.

## Known limitations

See RESEARCH.md for full detail. Summary:

- The virtual display is capped at ~1.65 million total pixels by
  `CGVirtualDisplay` itself (unaccelerated software framebuffer) — sized
  down proportionally from your real display's resolution if it exceeds
  that, so it won't be pixel-for-pixel identical.
- When the lid closes, the built-in panel deactivates and the virtual
  display briefly becomes the system's Main display (standard clamshell
  behavior) — apps may reflow/resize during this transition. Sizing the
  virtual display close to the real one minimizes this but doesn't
  guarantee zero visual disruption, and native-fullscreen apps have not
  been exhaustively tested across this transition.
- Universal Control is a known, unresolved hazard — see above.
- Adds some ongoing WindowServer CPU overhead while running.
