# keepawake

Keep an Apple Silicon Mac awake with the lid closed: no external display, no
dummy HDMI plug, no kernel extension.

## The problem

Starting with macOS Ventura, Apple Silicon Macs enforce clamshell sleep in
hardware: closing the lid sleeps the machine unless a real external display is
attached. `caffeinate` and the public `IOPMAssertion` APIs don't touch this. The
only officially supported workaround is a real external monitor or a physical
dummy HDMI/DisplayPort plug, which is exactly the hardware dependency this
project exists to avoid.

## Requirements

- Apple Silicon Mac (M1 or later), macOS Ventura or later
- No external display

Tested on one machine so far (MacBook Pro 16", M5 Max, macOS 26.5.2). See
[RESEARCH.md](RESEARCH.md)'s device-support note before assuming broad M-series
coverage.

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

## How it works

keepawake creates a tiny software-only virtual display via the private
`CGVirtualDisplay` CoreGraphics API, the same mechanism apps like BetterDisplay
use. That alone satisfies the check gating clamshell sleep, so the lid can stay
closed indefinitely while the Mac keeps working.

The virtual display only handles the hardware clamshell check. For ordinary idle,
display, and disk sleep, keepawake also runs `/usr/bin/caffeinate` internally
(tied to its own lifetime via `-w`), holding the same assertions plain
`caffeinate` would. That makes it a drop-in `caffeinate` replacement, not just a
clamshell patch.

See [RESEARCH.md](RESEARCH.md) for the mechanism, the Intel vs. Apple Silicon
findings, and every known limitation. It's more thorough than this README.

## Known limitations

- **Cursor and window drift.** The virtual display always sits adjacent to your
  real one; parking it elsewhere doesn't work, because WindowServer silently
  discards the request. Your cursor can reach it by crossing the bottom-right
  corner of your screen, and with Universal Control enabled it can continue onto
  a nearby Mac/iPad. Disable Universal Control to rule that out. The CLI warns
  about this every time it starts.
- **Reduced resolution.** `CGVirtualDisplay` caps out around 1.65 million total
  pixels (an unaccelerated software framebuffer, not a real GPU output), so the
  phantom display is scaled down from your real resolution rather than matched
  pixel-for-pixel. This also rules out screen mirroring, since a Mac's native
  resolution sits well above the cap.
- **Not App Store distributable.** It uses private, undocumented API. Fine for
  direct distribution; the Mac App Store would reject it.
- **No fallback if Apple changes the API.** `CGVirtualDisplay` is unsupported and
  can change or vanish in any release. keepawake checks for it at startup and
  exits with a clear message rather than crashing, but there's no other recourse.
- **Some CPU cost.** Holding the display open adds a small, ongoing amount of
  WindowServer CPU usage.

## Testing

```
./tests/run_tests.sh
```

Covers build, argument parsing, pre-flight warnings, virtual-display
creation/sizing/naming, the clamshell-sleep property flip, clean shutdown, the
`--duration` auto-stop, single-instance locking, the internal `caffeinate`
holder, `-w pid` waiting, and command wrapping. The one thing it can't cover is a
real physical lid close; there's no software way to simulate that, so it stays a
manual test (protocol in RESEARCH.md).

## License

MIT. See [LICENSE](LICENSE).
