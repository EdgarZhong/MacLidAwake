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
./keepawake --force            # skip the pre-flight warnings below
./keepawake -disu              # hold every caffeinate assertion too
./keepawake -- ./backup.sh     # run a command, stop when it exits
./keepawake -w 1234            # stop when pid 1234 exits
./keepawake --thermal serious  # release earlier under thermal pressure (lid closed)
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

Under thermal pressure keepawake releases the hold and exits, but only while the
lid is closed (with the lid open, thermal management is left to the OS). Choose
the threshold with `--thermal none|serious|critical` (default `critical`).
`serious` fires eagerly, since normal heavy CPU/GPU work reaches it, so it's
opt-in rather than the default.

## Pre-flight warnings

- **Battery power.** Closing the lid for extended periods on battery bypasses the
  thermal and battery protections clamshell sleep normally provides (e.g. in an
  enclosed bag). When Low Power Mode is off, the warning also suggests enabling
  it (System Settings > Battery) to cut heat and drain during a closed-lid run.
- **Sidecar connected.** Universal Control has been observed routing the cursor
  onto a nearby Mac through the virtual display. Disconnect Sidecar / disable
  Universal Control first, or expect this.
- **Intel Macs.** The hardware clamshell enforcement this tool works around
  doesn't exist pre-Apple-Silicon; `sudo pmset -a disablesleep 1` already
  prevents clamshell sleep there. `--force` runs the tool on Intel anyway, but on
  the one Intel Mac tested the virtual display never registered at any size (see
  RESEARCH.md), so `pmset` may be the only option that works.

All three can be skipped with `--force`.

## Known limitations

See RESEARCH.md for full detail. Summary:

- The virtual display is capped at ~1.65 million total pixels by
  `CGVirtualDisplay` itself, so it's scaled down proportionally from your real
  resolution and won't be pixel-for-pixel identical.
- When the lid closes, the built-in panel deactivates and the virtual display
  briefly becomes the system's Main display (standard clamshell behavior). Apps
  may reflow or resize during this transition. Sizing the virtual display close
  to the real one minimizes this but doesn't guarantee zero disruption, and
  native-fullscreen apps haven't been exhaustively tested across it.
- Universal Control is a known, unresolved hazard (see above).
- Adds some ongoing WindowServer CPU overhead while running.
