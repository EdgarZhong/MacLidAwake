# keepawake technical findings

A reference for what's actually true about this mechanism, with a short "why"
wherever something is counterintuitive.

## Device support

**Works: Apple Silicon (M1 or later), macOS Ventura or later.** A software-only
virtual display, created via the private `CGVirtualDisplay` CoreGraphics API,
prevents clamshell sleep. Confirmed on one machine: MacBook Pro 16", Apple M5
Max, on macOS 26.5.2 and again on 27.0. Other Apple Silicon chips are assumed to
behave the same but haven't been tested.

**Doesn't work: Intel.** The virtual display never registers, at any size
(tested on a MacBookPro15,3, macOS 15.7.7). It isn't needed there: `sudo pmset -a
disablesleep 1` already prevents clamshell sleep on Intel, which is what
keepawake's Intel guard points to. Plain `caffeinate` prevents lid-closed sleep
on no Mac, Intel or otherwise; it only blocks idle and display sleep.

## Why it works on Apple Silicon

Since Ventura, Apple Silicon Macs enforce clamshell sleep in hardware via
`IOPMrootDomain`: closing the lid sleeps the machine unless a real external
display is attached. `caffeinate`, `IOPMAssertion`, and `pmset -a disablesleep 1`
do not override this. (On Intel, the last one does.)

The surprising part: the clamshell decision is understood to route through
`AppleGraphicsControl`/AGDC, which normally reasons about real DisplayPort, HDMI,
or eDP hotplug (EDID) data, and `CGVirtualDisplay` has no physical connector.
Empirically, no real `IOFramebuffer`/EDID detection is required. That is the
mechanism keepawake relies on.

Kernel extensions are the obvious alternative and are ruled out: they need
Reduced Security plus manual approval on Apple Silicon, and the existing
kext-based tools (InsomniaX, Frizlab's Insomnia) haven't been updated for the
newer hardware enforcement anyway.

## The virtual display

- **Resolution cap.** `CGVirtualDisplay` caps total pixels — an unaccelerated
  software framebuffer, not a real GPU output. **The ceiling moves between macOS
  releases:** 1,662,600–1,684,900 on macOS 26.5.2, and **1,761,617–1,764,336 on
  macOS 27.0** (same machine, bisected). Don't hardcode it tightly. Among current
  M-series laptops only the 16" MacBook Pro's native resolution (1728x1117 =
  1.93M) exceeds it; the Air and 14" Pro already fit.
- **The cap is per-display, not a shared budget.** Measured with keepawake's own
  1.65M phantom already active: a second virtual display still registered at
  1.76M alongside it.
- **It's a pixel budget, not an aspect limit — but there is a separate width
  limit.** `1312x1312` and `2600x660` both register exactly. Width fails between
  **2600 and 2605 px** regardless of total pixels, while height goes past 8160.
  Doesn't affect keepawake, which is aspect-matched to the built-in display.
- **An over-cap request does not fail, and `apply()` still returns `true`.** A
  smaller, aspect-preserved resolution silently registers instead, so `apply()`
  cannot be used to detect the cap and a request-and-halve-down loop never
  iterates. The only way to know what you got is to read back
  `CGDisplayPixelsWide`/`High` afterward.
- **How far macOS downsizes is non-obvious, and "let macOS decide" is a trap.**
  On a 16" MBP, requesting 1728x1117 (native points, 1.93M) yields 1024x662,
  while requesting 3456x2234 (native pixels, 7.72M) yields 1600x1034 — right
  against the cap. Below the cap, a pixel request lands exactly on the point size
  (3024x1964 → 1512x982 on a 14"). Tempting, but the phantom is
  `backingScaleFactor: 1`, so its point size equals its pixel size: if the cap
  ever rose past 7.72M the full request would be honored and the phantom would
  become 3456x2234 *points*, 2x the built-in per dimension and 4x the area,
  reflowing every window into a far larger space. Overshooting is much worse than
  falling short.
- **keepawake therefore scales down from the point size against a fixed
  1,654,400**, treating the real display's point size as a hard ceiling. That's
  below every measured limit; being conservative costs a few percent of phantom
  size and makes an oversized phantom structurally impossible.
- **One-time consent dialog.** The first time a given virtual-display identity
  appears, WindowServer shows "What do you want to show on '[name]'?". This isn't
  scriptable even as root — it's gated by code-signing and entitlements, not Unix
  privilege. Its "Set as Default" checkbox is system-wide, not per-display, and
  there's no known way to reset it short of System Settings' privacy reset.
- **Positioning works, within limits.** macOS keeps arrangements gap-free, so
  `CGConfigureDisplayOrigin` can't float the phantom off in empty space; it
  clamps to a contiguous position. But it does honor which outer edge the phantom
  attaches to: request a far-off origin and it parks at the far right/left/bottom
  past the real displays, which keep their positions (verified on a 3-display
  setup — the requested edge origin is applied exactly). keepawake parks it at
  the far-right edge, bottom-aligned to its neighbor, and re-parks on every
  display reconfiguration.
- **Cursor and window drift.** Even parked at the outer edge, the cursor can
  cross onto the phantom where it meets its neighbor. Windows or the Dock dragged
  onto it become invisible until the process is killed, which migrates them back.
  Parking keeps it out of the main working area but doesn't eliminate this.
- **Universal Control hazard.** If enabled, the cursor can travel through the
  phantom onto a nearby Mac signed into the same iCloud account, taking input
  focus off the machine entirely. Disable Universal Control when using keepawake.
  Not warned about at runtime: its state is an opaque hashed device graph with no
  readable on/off flag, so it isn't detectable per-run.

## Idle sleep is separate from clamshell sleep

The virtual display only defeats the hardware clamshell check. Ordinary idle,
display, and disk sleep are governed by `IOPMAssertion`. keepawake closes that
gap by spawning `/usr/bin/caffeinate` as a child rather than reimplementing the
assertion bindings: same semantics, already maintained by Apple. Its lifetime is
tied to keepawake's PID via `-w`, so it self-releases on any exit path, including
a `kill -9` that bypasses every signal handler. (The few places keepawake
deliberately doesn't mirror real `caffeinate` are documented as code comments in
`main.swift`, next to the logic they justify.)

## Known gaps

- Not tested over a multi-hour closed duration; only about 30 seconds is
  confirmed.
- Power draw with the lid closed and no real display is unmeasured. Clamshell
  sleep exists partly for thermal protection, so this is worth ruling out as a
  bag-overheating risk. Mitigated by `--thermal none|serious|critical` (default
  `critical`, lid-gated). `serious` is reached by ordinary heavy CPU/GPU work,
  which is why it's opt-in.
- Whether the phantom affects **low-battery emergency sleep** is untested. macOS
  force-sleeps at critical battery and `IOPMAssertion` doesn't override that, so
  it most likely still works — but keepawake already defeats one class of
  hardware-enforced sleep, so that expectation isn't free. `--battery <pct>`
  (default 5, lid-gated, ignored on AC) covers it. It's event-driven via
  `IOPSNotificationCreateRunLoopSource`, which fires on percent/time-remaining
  change and is a `CFRunLoopSource`, so it schedules directly onto keepawake's
  bare `CFRunLoopRun()` with no polling and no dependency on the main GCD queue
  being pumped. `IOPSCreateLimitedPowerNotification` is the cheaper sibling but
  only fires on AC-vs-battery transitions, so it can't drive a threshold.
- **Whether phantom size actually matters is unverified.** Sizing the phantom
  close to the real display is assumed to reduce window reflow on lid close, but
  that has never been measured — it needs a physical lid close with window frames
  recorded before and after. If it turns out not to matter, the sizing logic can
  be dropped for whatever is simplest.
- Initial parking is verified live (parked exactly, no real display displaced),
  but re-parking on a physical monitor hotplug uses the same path via a
  reconfiguration callback and hasn't been confirmed on hardware. Worst case is
  cosmetic: the phantom stays wedged where a new display pushed it until the next
  layout change.

## Verifying it yourself

`pmset -g log | grep -i clamshell | tail -5`, before and after a deliberate lid
close and reopen, is the ground truth. Don't trust an instantaneous
`ioreg -r -k AppleClamshellCausesSleep` read instead: it's been seen to report
`No` on a machine that in fact sleeps on every real lid close.
`experiments/clamshell-watch.sh` polls the same properties live if you'd rather
watch than check the log afterward.
