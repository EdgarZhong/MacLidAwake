# keepawake

Keep an Apple Silicon Mac awake with the lid closed: no external display, no
dummy HDMI plug, no kext. See `../../RESEARCH.md` for the technical findings and
known limitations.

## Install

Via Homebrew:

```
brew tap ecc521/keepawake
brew install ecc521/keepawake/keepawake
```

Or build from source (drop the leading `./` below if you installed via Homebrew):

```
./build.sh
```

## Use

```
./keepawake                    # run until Ctrl-C
./keepawake -t 3600            # run for 1 hour, then stop automatically
./keepawake -disu              # hold every caffeinate assertion too
./keepawake -- ./backup.sh     # run a command, stop when it exits
./keepawake -w 1234            # stop when pid 1234 exits
./keepawake --thermal serious  # release earlier under thermal pressure (lid closed)
./keepawake --battery 20       # release at 20% battery (lid closed); default 5
```

Run it before closing the lid. Ctrl-C, the `--duration` timer, or a wrapped
command / `-w` pid exiting all release the hold and let normal sleep resume.

keepawake is a drop-in `caffeinate` replacement, not just a clamshell patch: the
phantom display defeats hardware-enforced clamshell sleep, and it also spawns
`/usr/bin/caffeinate` internally (tied to its own PID via `-w`) to hold the same
`-disu` assertions, so ordinary idle/display/disk sleep is covered too. The
assertion flags (`-d -i -m -s -u`), `-t` duration, `-w pid`, and trailing-command
wrapping all match `caffeinate`'s semantics. See `-h`/`--help` for the full flag
reference.

## Cutoffs

Two cutoffs stop keepawake and let normal sleep resume. Both only act with the
lid closed — with it open, you're at the machine and don't need it deciding for
you — and both are silent unless they fire.

- `--battery <pct>|none` (default `5`) — stop at that battery percentage, so an
  unattended machine doesn't run itself flat. Ignored on AC power. Event-driven
  via `IOPSNotificationCreateRunLoopSource`, not polled.
- `--thermal none|serious|critical` (default `critical`) — stop under thermal
  pressure, for when keepawake gets left running and the machine ends up
  somewhere it can't shed heat. `serious` is reached by ordinary heavy CPU/GPU
  work, so it's opt-in.

macOS handles both of these on its own; these cutoffs exist because keepawake is
the reason the machine is awake in the first place.

## Pre-flight check

A normal run prints one status line and nothing else. There is one pre-flight
check, and it's fatal: **keepawake does not work on Intel Macs and refuses to
run there.** Use `sudo pmset -a disablesleep 1` instead, which already prevents
clamshell sleep on Intel. See RESEARCH.md for the details.

## Known limitations

See RESEARCH.md for full detail. Summary:

- The virtual display is capped in total pixels by `CGVirtualDisplay` itself.
  The limit is undocumented and varies by release (~1.66M on macOS 26, ~1.76M on
  macOS 27), so keepawake scales down against a conservative fixed 1.6M and
  never requests more than your display's point size. On larger displays the
  phantom is therefore slightly smaller than the real screen and won't be
  pixel-for-pixel identical. The status line reports the size that registered.
- When the lid closes, the built-in panel deactivates and the virtual display
  briefly becomes the system's Main display (standard clamshell behavior). Apps
  may reflow or resize during this transition. Sizing the virtual display close
  to the real one minimizes this but doesn't guarantee zero disruption, and
  native-fullscreen apps haven't been exhaustively tested across it.
- **Universal Control is a known, unresolved hazard.** The phantom is parked at
  the far-right outer edge, but the cursor can still reach it, and with
  Universal Control enabled it has been observed travelling onward onto a nearby
  Mac or iPad, taking input focus off this machine. Disable Universal Control to
  rule that out. (Not warned about at runtime: it's a permanent property of the
  mechanism, not something detectable per-run — Universal Control's state is
  stored as an opaque hashed device graph with no readable on/off flag.)
- Adds some ongoing WindowServer CPU overhead while running.
