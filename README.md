# keepawake

Keep an Apple Silicon Mac awake with the lid closed: no external display, no
dummy HDMI plug, no kernel extension.

## Requirements

- Apple Silicon Mac (M1 or later), macOS Ventura or later.

## Installation

Via Homebrew:

```
brew tap ecc521/keepawake
brew install ecc521/keepawake/keepawake
```

Or build from source:

```
cd cli/keepawake
./build.sh
```

Then (drop the leading `./` if you installed via Homebrew):

```
./keepawake                    # run until Ctrl-C
./keepawake -t 3600            # run for 1 hour, then stop automatically
./keepawake -- ./backup.sh     # run a command, stop when it exits
```

Run it before closing the lid. Ctrl-C, the `--duration` timer elapsing, or a
wrapped command exiting all release the hold and let normal sleep resume. Full
CLI usage, including the `caffeinate`-compatible `-d -i -m -s -u -w` flags:
[cli/keepawake/README.md](cli/keepawake/README.md).


## The problem

Starting with macOS Ventura, Apple Silicon Macs enforce clamshell sleep in
hardware: closing the lid sleeps the machine unless a real external display is
attached. `caffeinate` and the public `IOPMAssertion` APIs don't touch this. The
only officially supported workaround is a real external monitor or a physical
dummy HDMI/DisplayPort plug, which is exactly the hardware dependency this
project exists to avoid.

## How it works

keepawake creates a tiny software-only virtual display via the private
`CGVirtualDisplay` CoreGraphics API. This registers as an external display, preventing automatic sleep in clamshell even when no display is connected. 

The virtual display only handles the clamshell check. For ordinary idle,
display, and disk sleep, keepawake also runs `/usr/bin/caffeinate` internally
(tied to its own lifetime via `-w`), holding the same assertions plain
`caffeinate` would. That makes it a drop-in `caffeinate` replacement, not just a
clamshell patch.

See [RESEARCH.md](RESEARCH.md) for the mechanism, the Intel vs. Apple Silicon
findings, and every known limitation. It's more thorough than this README.

## Known limitations

- **Cursor and window drift:** The virtual display is parked at the far right
  edge of your arrangement so it doesn't displace your real displays, but
  your cursor can still reach it. 
- **Application Resizing on large MacBooks:** 16-inch MacBooks have physical displays that exceed the `CGVirtualDisplay`
  pixel cap (~1.65 million). This can cause minor resizing on those devices. 
- **Ongoing CPU cost.** Holding the display open adds a small, ongoing amount of
  WindowServer CPU usage.

## Testing

```
./tests/run_tests.sh
```

Covers build, argument parsing, pre-flight warnings, virtual-display
creation/sizing/naming, the clamshell-sleep property flip, clean shutdown, the
`--duration` auto-stop, single-instance locking, the internal `caffeinate`
holder, `-w pid` waiting, and command wrapping. The one thing it can't cover is a
real physical lid close, which remains a manual test. 

## License

MIT. See [LICENSE](LICENSE).
