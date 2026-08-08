# keepawake

Keep an Apple Silicon Mac awake with the lid closed: no external display, no
dummy HDMI plug, no kext. See `../../RESEARCH.md` for the technical findings and
known limitations.

## Install

```
brew tap ecc521/keepawake
brew install ecc521/keepawake/keepawake
```

Or `./build.sh` to build from source.

## Use

```
keepawake                    # run until Ctrl-C
keepawake -t 3600            # run for 1 hour, then stop automatically
keepawake -disu              # hold every caffeinate assertion too
keepawake -- ./backup.sh     # run a command, stop when it exits
keepawake -w 1234            # stop when pid 1234 exits
keepawake --thermal serious  # release earlier under thermal pressure
keepawake --battery 20       # release at 20% battery; default 5
```

Run it before closing the lid. Ctrl-C, the `-t` timer, or a wrapped command /
`-w` pid exiting all release the hold and let normal sleep resume.

keepawake is a drop-in `caffeinate` replacement, not just a clamshell patch: the
phantom display defeats hardware-enforced clamshell sleep, and an internal
`/usr/bin/caffeinate` (tied to keepawake's PID via `-w`) holds the same `-disu`
assertions, covering ordinary idle/display/disk sleep. The assertion flags, `-t`,
`-w`, and trailing-command wrapping all match `caffeinate`'s semantics. See
`--help` for the full flag reference.

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

## Notes

A normal run prints one status line and nothing else.

**keepawake does not work on Intel Macs and refuses to run there.** Use
`sudo pmset -a disablesleep 1` instead, which already prevents clamshell sleep
on Intel.

The phantom is capped in total pixels by `CGVirtualDisplay`. The limit is
undocumented and moves between releases (~1.66M on macOS 26, ~1.76M on macOS
27), so keepawake scales down from your display's point size against a fixed
1,654,400 and never requests more than that point size. On larger displays the
phantom is therefore slightly smaller than the real screen; the status line
reports the size that actually registered.
