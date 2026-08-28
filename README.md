## Apparently pmset \*does\* work on Apple Silicon (whoops!), and while keepawake suppresses sleep when closed and plugged in, it cannot suppress sleep on battery when plugged in. I'll be updating keepawake shortly in v 0.3 to use pmset instead, which will require a one-time `sudo` call. Until then, keepawake cannot fully guarantee your device will not sleep. 

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

Whenever keepawake stops, the hold is released and normal sleep resumes.
The `-d -i -m -s -u -w` flags match `caffeinate`, so you can use keepawake in
its place and still cover ordinary idle, display, and disk sleep. Full CLI
reference:
[cli/keepawake/README.md](cli/keepawake/README.md).

## The problem

Since Ventura, Apple Silicon Macs enforce clamshell sleep in hardware: closing
the lid sleeps the machine unless a real external display is attached.
`caffeinate` and the public `IOPMAssertion` APIs don't touch this. The only
supported workaround is a real monitor or a dummy HDMI/DisplayPort plug, which
is the hardware dependency this project exists to avoid.

## How it works

keepawake creates a small software-only virtual display via the private
`CGVirtualDisplay` CoreGraphics API. It registers as an external display, which
satisfies the clamshell check even with nothing plugged in. That covers
lid-closed sleep only, so keepawake also runs `/usr/bin/caffeinate` internally
(tied to its own lifetime via `-w`) to hold the ordinary sleep assertions.

The clamshell decision is understood to route through
`AppleGraphicsControl`/AGDC, which normally reasons about hotplug and EDID data
from a real DisplayPort, HDMI, or eDP connector. `CGVirtualDisplay` has no
connector at all, and empirically none is required: a software framebuffer is
enough to satisfy the check. Kernel extensions are the obvious alternative and
are ruled out, since they need Reduced Security plus manual approval on Apple
Silicon.

The first time keepawake runs, WindowServer asks "What do you want to show on
'Keepawake Phantom Display'?". Answer it however you like. The prompt can't be
suppressed from the command line, and its "Set as Default" checkbox applies
system-wide rather than to this display alone.

## Known limitations

- **Cursor drift.** macOS treats the phantom as a real display, so your cursor
  can move onto it.
- **App resizing on 16" MacBooks.** `CGVirtualDisplay` limits the phantom to
  just under the resolution of a 16" MacBook Pro, which can cause slight
  resizing.

## Testing

```
./tests/run_tests.sh
```

Covers everything except a real physical lid close, which still has to be
tested by hand.

## License

MIT. See [LICENSE](LICENSE).
