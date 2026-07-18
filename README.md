# keepawake

Prevents an Apple Silicon Mac from sleeping when the lid is closed — no
external display, no dummy HDMI plug, no kernel extension required.

## The problem

Starting with macOS Ventura, Apple Silicon Macs enforce clamshell sleep at
the hardware level: closing the lid puts the machine to sleep unless a real
external display is attached, full stop. `caffeinate` and the public
`IOPMAssertion` APIs don't touch this. The only officially supported way
around it is a real external monitor (or a physical dummy HDMI/DisplayPort
plug) — exactly the hardware dependency this project exists to avoid.

## Requirements

- Apple Silicon Mac (M1 or later), macOS Ventura or later
- No external display required (the whole point)

Only actually tested on one machine so far (MacBook Pro 16", M5 Max, macOS
26.5.2) — see RESEARCH.md's "Device support" note before assuming this is
broadly confirmed across the M-series lineup.

## Installation

Via Homebrew:

```
brew tap ecc521/keepawake
brew install ecc521/keepawake/keepawake
```

Or build from source directly:

```
cd cli/keepawake
./build.sh
```

Either way (drop the leading `./` if you installed via Homebrew):

```
./keepawake                    # run until Ctrl-C
./keepawake -t 3600            # run for 1 hour, then stop automatically
./keepawake -- ./backup.sh     # run a command, stop when it exits
```

Run it before closing the lid. Ctrl-C (or the `--duration` timer elapsing,
or a wrapped command exiting) releases the hold and lets normal sleep
resume immediately. Full CLI usage, including the `caffeinate`-compatible
`-d -i -m -s -u -w` flags: [cli/keepawake/README.md](cli/keepawake/README.md).

## How it works

`keepawake` creates a tiny, software-only virtual display via the private
`CGVirtualDisplay` CoreGraphics API — the same mechanism apps like
BetterDisplay use, no kext, no physical hardware. That's enough to satisfy
whatever check gates clamshell sleep: with it running, the lid can be
closed indefinitely and the Mac stays fully awake and working.

The phantom display only defeats that hardware-enforced clamshell check —
it does nothing about ordinary idle/display/disk sleep, which is a separate
mechanism. So `keepawake` also runs `/usr/bin/caffeinate` internally
(tied to its own lifetime via `-w`) to hold the same assertions plain
`caffeinate` would. That makes it a full drop-in replacement for
`caffeinate`, not just a clamshell-only patch — including `-w pid` and
wrapping a command, the same way `caffeinate` does.

See [RESEARCH.md](RESEARCH.md) for the technical findings behind this —
what's confirmed on Intel vs. Apple Silicon, how the virtual display
mechanism behaves, and every current limitation. Read it before trusting
this for anything important; it's more thorough than this README.

## Known limitations

- **Cursor/window drift**: the virtual display always sits directly
  adjacent to your real display — an attempt to park it far away
  programmatically was confirmed *not* to work (WindowServer silently
  discards the request). Your cursor can reach it by crossing the
  bottom-right corner of your screen, and if Universal Control is enabled,
  from there it can continue onto a nearby Mac/iPad. Disable Universal
  Control if you want to rule that out; the CLI warns about this every
  time it starts.
- **Resolution cap**: `CGVirtualDisplay` enforces a hard limit around 1.65
  million total pixels (it's an unaccelerated software framebuffer, not a
  real GPU output) — the virtual display is sized down proportionally from
  your real display's resolution to fit under that, so it won't be
  pixel-for-pixel identical. This also rules out screen-mirroring as an
  alternative approach, since a real Mac's native resolution is well above
  that cap.
- **Not notarizable for the App Store**: this uses undocumented, private
  API. Fine for direct distribution; would be rejected from the Mac App
  Store.
- **No fallback if Apple changes the API**: `CGVirtualDisplay` is
  unsupported and can be altered or removed at any time. `keepawake` checks
  for its availability at startup and fails with a clear message rather
  than crashing, but there's no other recourse if it's gone.
- **Some CPU cost**: holding the virtual display open adds a small,
  ongoing amount of WindowServer CPU usage for as long as it runs.

## Testing

```
./tests/run_tests.sh
```

Automated coverage: build, argument parsing, pre-flight warnings, virtual
display creation/sizing/naming, the clamshell-sleep property flip, clean
shutdown (SIGINT/SIGTERM), `--duration` auto-stop, single-instance locking,
the internal `caffeinate` assertion holder (flags, cleanup, orphan
prevention), `-w pid` waiting, and command-wrapping (exit-code propagation,
signal forwarding). What it can't cover: whether the machine actually stays
awake through a *real* physical lid close — there's no software way to
simulate that, so it remains a manual test (protocol in RESEARCH.md).

## License

MIT — see [LICENSE](LICENSE).
