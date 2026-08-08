# keepawake

Keep an Apple Silicon Mac awake with the lid closed: no external display, no
dummy HDMI plug, no kernel extension.

## Install

```
brew tap ecc521/keepawake
brew install ecc521/keepawake/keepawake
```

Or build from source with `cd cli/keepawake && ./build.sh`. Requires Apple
Silicon (M1 or later) and macOS Ventura or later.

## Use

```
keepawake                    # run until Ctrl-C
keepawake -t 3600            # run for 1 hour, then stop automatically
keepawake -- ./backup.sh     # run a command, stop when it exits
```

Run it before closing the lid. Whenever keepawake stops, the hold is released
and normal sleep resumes. keepawake is a drop-in `caffeinate` replacement — the
`-d -i -m -s -u -w` flags match — so ordinary idle, display, and disk sleep are
covered too. Full CLI reference:
[cli/keepawake/README.md](cli/keepawake/README.md).

## The problem

Since Ventura, Apple Silicon Macs enforce clamshell sleep in hardware: closing
the lid sleeps the machine unless a real external display is attached.
`caffeinate` and the public `IOPMAssertion` APIs don't touch this. The only
supported workaround is a real monitor or a dummy HDMI/DisplayPort plug —
exactly the hardware dependency this project exists to avoid.

## How it works

keepawake creates a tiny software-only virtual display via the private
`CGVirtualDisplay` CoreGraphics API. It registers as an external display, which
satisfies the clamshell check even with nothing plugged in. That covers
lid-closed sleep only, so keepawake also runs `/usr/bin/caffeinate` internally
(tied to its own lifetime via `-w`) to hold the ordinary sleep assertions.

## Known limitations

- **Cursor drift.** The phantom is parked at the far-right edge of your
  arrangement so it doesn't displace real displays, but your cursor can still
  reach it. With Universal Control enabled it has been seen to travel onward
  onto a nearby Mac or iPad, taking input focus off this machine.
- **App resizing on 16" MacBooks.** Their native resolution exceeds the
  `CGVirtualDisplay` pixel cap, so the phantom registers slightly smaller than
  the real screen and windows may reflow on lid close.
- **Ongoing CPU cost.** Holding the display open adds a small amount of
  WindowServer CPU usage.

[RESEARCH.md](RESEARCH.md) covers the mechanism, the Intel vs. Apple Silicon
findings, and every known limitation in full.

## Testing

```
./tests/run_tests.sh
```

Covers everything up to the one thing it can't: a real physical lid close, which
remains a manual test.

## License

MIT. See [LICENSE](LICENSE).
