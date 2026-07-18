# keepawake technical findings

A reference for what's actually true about this mechanism. Where something is
counterintuitive, a short "why" is included.

## Device support

**Works: Apple Silicon (M1 or later), macOS Ventura or later.** A software-only
virtual display, created via the private `CGVirtualDisplay` CoreGraphics API,
prevents clamshell sleep. Confirmed on one machine: MacBook Pro 16", Apple M5
Max, macOS 26.5.2. Other Apple Silicon chips are assumed to behave the same but
haven't been independently tested.

**Doesn't work: Intel.** The virtual display never registers, at any size
(tested on a MacBookPro15,3, macOS 15.7.7). It isn't needed there anyway:
`sudo pmset -a disablesleep 1` already prevents clamshell sleep on Intel, which
is what keepawake's Intel guard points to. Plain `caffeinate` prevents lid-closed
sleep on no Mac, Intel or otherwise; it only blocks idle and display sleep.

## Why it works on Apple Silicon

Starting with Ventura, Apple Silicon Macs enforce clamshell sleep in hardware
via `IOPMrootDomain`: closing the lid sleeps the machine unless a real external
display is attached. `caffeinate`, `IOPMAssertion`, and `pmset -a disablesleep 1`
do not override this. (On Intel, the last one does.)

The surprising part: the clamshell decision is understood to route through
`AppleGraphicsControl`/AGDC, which normally reasons about real DisplayPort, HDMI,
or eDP hotplug (EDID) data, and `CGVirtualDisplay` has no physical connector.
Empirically, no real `IOFramebuffer`/EDID detection turns out to be required.
That is the mechanism keepawake relies on.

Kernel extensions are the obvious alternative, and are ruled out: they require
Reduced Security plus manual approval on Apple Silicon, and the existing
kext-based tools (InsomniaX, Frizlab's Insomnia) haven't been updated for the
newer hardware enforcement anyway.

## The virtual display

- **Resolution cap.** `CGVirtualDisplay` caps total pixels at roughly 1.65M (an
  unaccelerated software framebuffer, not a real GPU output). Among current
  M-series laptops only the 16" MacBook Pro's native resolution
  (1728x1117 = 1.93M) exceeds it; the Air and 14" Pro already fit. A request over
  the cap doesn't fail. It silently registers a smaller, aspect-preserved
  resolution instead, so keepawake computes a size under the cap rather than
  relying on that fallback.
- **One-time consent dialog.** The first time a given virtual-display identity
  appears, WindowServer shows "What do you want to show on '[name]'?". This isn't
  scriptable even as root; it's gated by code-signing and entitlements, not Unix
  privilege. Its "Set as Default" checkbox is system-wide, not per-display, and
  there's no known way to reset it short of System Settings' privacy reset.
- **Positioning works, within limits.** macOS keeps arrangements gap-free, so
  `CGConfigureDisplayOrigin` can't float the phantom off in empty space; it
  clamps the requested origin to a contiguous position. But it does honor which
  outer edge the phantom attaches to: request a far-off origin and it parks at
  the far right/left/bottom, past the real displays, which keep their positions
  (verified on a 3-display setup, the requested edge origin is applied exactly).
  keepawake uses this to park the phantom at the far-right edge, bottom-aligned
  to its neighbor, and re-parks on every display reconfiguration.
- **Cursor and window drift.** Even parked at the outer edge, the cursor can
  cross onto the virtual display where it meets its neighbor. Windows or the Dock
  dragged onto it become invisible until the process is killed, which migrates
  them back to the real display. Parking keeps it out of the main working area
  but doesn't eliminate this.
- **Universal Control hazard.** If enabled, the cursor can travel through the
  virtual display onto a nearby Mac signed into the same iCloud account, taking
  input focus off the machine entirely. Disable Universal Control when using
  keepawake.

## Idle sleep is separate from clamshell sleep

The virtual display only defeats the hardware clamshell check. It does nothing
for ordinary idle, display, or disk sleep, which are governed by `IOPMAssertion`.
keepawake closes that gap by spawning `/usr/bin/caffeinate` as a child rather
than reimplementing the assertion bindings: same semantics, already maintained by
Apple. Its lifetime is tied to keepawake's PID via `-w`, so it self-releases on
any exit path, including a `kill -9` that bypasses every signal handler. (The few
places keepawake deliberately doesn't mirror real `caffeinate` are documented as
code comments in `main.swift`, next to the logic they justify.)

## Known gaps

- Not tested over a multi-hour closed duration; only about 30 seconds is
  confirmed.
- Power draw with the lid closed and no real display is unmeasured. Clamshell
  sleep exists partly for thermal and battery protection, so this is worth ruling
  out as a bag-overheating risk. The CLI's battery pre-flight warning covers it
  in the meantime.
- Initial parking is verified live (parked exactly, no real display displaced),
  but re-parking triggered by a physical monitor hotplug uses the same path via
  a reconfiguration callback and hasn't been confirmed on real hardware. Worst
  case if the callback misbehaves is cosmetic: the phantom stays wedged where a
  newly-connected display pushed it until the next layout change.

## Verifying it yourself

`pmset -g log | grep -i clamshell | tail -5`, before and after a deliberate lid
close and reopen, is the ground truth. Don't trust an instantaneous
`ioreg -r -k AppleClamshellCausesSleep` read instead: it's been seen to report
`No` on a machine that in fact sleeps on every real lid close.
`experiments/clamshell-watch.sh` polls the same properties live if you want to
watch rather than check the log afterward.
