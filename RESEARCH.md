# Keepawake — technical findings

What's actually true about this mechanism, by topic — a reference, not a lab
notebook. Where something is counterintuitive, a short "why" is included;
disproven theories and discovery play-by-play are not.

## Device support

Everything in this document confirmed by actual testing on Apple Silicon was
tested on exactly one machine: **MacBook Pro (16"), Apple M5 Max, macOS
26.5.2.** That includes the pixel cap (somewhere between 1,662,600 and
1,684,900 total pixels — see "Operational facts" below) and the
phantom-display-prevents-sleep result itself. Neither has been checked on
any other Apple Silicon chip (M1/M2/M3/M4, or other M5 variants) or macOS
version — treat both as "true on this one machine, unconfirmed elsewhere"
rather than a universal fact.

The CLI degrades safely if the pixel cap turns out to be lower elsewhere: it
retries at progressively smaller sizes rather than assuming the number
above, and only fails outright if no size down to 2x2 works. If you hit that
failure (or anything else that contradicts this document) on different
hardware, that's worth reporting — this note should get more data points
over time, not stay a single anecdote.

**Intel: confirmed not to work, on one machine.** Tested on a MacBook Pro15,3
(Intel UHD Graphics 630 + Radeon Pro Vega 20, only the built-in display
active), macOS 15.7.7, from a local Terminal session (ruling out an earlier
false lead — see below). `CGVirtualDisplay.apply()` returned `true` at every
size tried — native resolution, the M5's cap-fitted size, 800x600, and 2x2 —
but the display never registered with WindowServer at any of them (checked
via `system_profiler`, which correctly listed the real built-in display each
time, ruling out a tooling/grep mistake). This isn't the same failure mode
as the Apple Silicon pixel cap: there, sizes under the cap register
reliably and only oversized requests silently fail; here, *nothing*
registers, at any size, including ones well within the Apple Silicon cap.
Whether this is specific to this dual-GPU Intel configuration, Intel Macs
generally, or this macOS version isn't known — one data point, not tested
elsewhere. Moot for `keepawake`'s actual purpose either way, since
`pmset -a disablesleep 1` already solves Intel without any of this — but it
does mean `--force` on Intel is very unlikely to actually work if anyone
tries it, beyond just being unnecessary.

An earlier attempt to test this same question over SSH gave an identical
"apply() true, never registers" result at every size, which looked like the
same finding — but that test turned out to be confounded (visibly, by a
black-screen flash reported live during testing) and was re-run properly
from a local session before being trusted. The SSH context lacked any TCC
permission grants for the ad-hoc-signed test binary, which is a plausible
explanation for a silent non-registration on its own, independent of
architecture. The result above is the clean re-test; the SSH run is not
being relied on for this conclusion, just noted so the same detour isn't
repeated.

## Constraints

1. Must not sleep, even with the lid closed.
2. No external hardware (no dummy HDMI/DP plug, no real monitor).
3. Root-level software is fine. Kernel extensions are not — they require
   Reduced Security + manual approval on Apple Silicon, and existing
   kext-based tools (InsomniaX / Frizlab's `Insomnia`) haven't been updated
   to fight the newer hardware enforcement anyway.

## Intel Macs: this tool isn't needed

`sudo pmset -a disablesleep 1` prevents clamshell sleep on Intel — confirmed
by direct testing (lid closed 3+ minutes; no new `Clamshell Sleep` entry in
`pmset -g log`; `SleepDisabled` stayed `1`). No virtual display, no private
API required.

Plain `caffeinate` does **not** do this — it only blocks idle/display sleep
via `IOPMAssertion`, and never touches lid-closed sleep at all, on any Mac.
`keepawake`'s Intel guard points at `pmset -a disablesleep 1` specifically,
not `caffeinate`, for that reason.

## Apple Silicon (Ventura+): hardware-enforced, needs a workaround

Starting with Ventura, Apple Silicon Macs enforce clamshell sleep at the
hardware level via `IOPMrootDomain` — closing the lid sleeps the machine
unless a real external display is attached, full stop. `caffeinate`,
`IOPMAssertion`, and `pmset -a disablesleep 1` do **not** override this when
no display is attached (unlike on Intel, where the last one does).

**A software-only virtual display, created via the private `CGVirtualDisplay`
CoreGraphics API, is sufficient to prevent clamshell sleep** — confirmed by
direct lid-close testing (MacBook Pro, M5 Max, macOS 26.5.2):
- Control (no virtual display): lid closed 5s → clean sleep cycle appears in
  `pmset -g log` within seconds.
- Test (virtual display running): lid closed 30s → zero sleep-related log
  entries; the machine stayed fully awake throughout.

This is architecturally a bit surprising — the clamshell decision is
understood to route through `AppleGraphicsControl`/AGDC, which normally
reasons about real DisplayPort/HDMI/eDP hotplug (EDID) data, and
`CGVirtualDisplay` has no corresponding physical connector — but empirically,
no real `IOFramebuffer`/EDID detection turns out to be required. This is the
mechanism `keepawake` uses.

`AppleClamshellCausesSleep` (`ioreg -r -k AppleClamshellCausesSleep`) flips
`Yes` → `No` while the virtual display is running, but treat that as a
secondary signal only — an instantaneous read of it has been observed to be
unreliable (reading `No` on a machine that in fact sleeps on every real lid
close). `pmset -g log` history after an actual lid-close test is the real
signal; see "Verifying it yourself" below.

## Operational facts about the virtual display

- **Sizing and the pixel cap, in Extend mode.** Reliable down to 2x2
  pixels; 128x128 failed once (`apply()` succeeded but never registered —
  stick to sizes at or above what's confirmed working). On the high end,
  the boundary is roughly 1,662,600–1,684,900 total pixels, not a clean
  number; `keepawake` targets ~1,652,000, comfortably under it. This only
  matters for the 16" MacBook Pro in practice: every other current
  M-series MacBook's default point resolution (13"/13.6" Air, 14" Pro —
  1.3–1.5M pixels) already fits under the cap with no scaling needed. Only
  the 16" Pro's own default (1728x1117 = 1.93M, the machine everything
  here was tested on) exceeds it, and only by a modest ~1.16x.
- **Exceeding the cap doesn't fail — it silently substitutes a different,
  unpredictable resolution, and `apply()` still returns `true`.** E.g.
  1920x1080 → 960x540, 1660x1015 → 1024x626 — aspect-preserving but
  otherwise not a documented or derivable formula. How much of the budget
  gets used scales with how far over you ask (~30% at 1.0–1.4x overage, up
  to 100% by ~4.7x) — real screens sit in the worst-utilization range, so
  "just request native and trust the fallback" isn't a substitute for
  computing a size that deliberately fits under the cap, which is what
  `keepawake` already does. Severity-tested up to 4.6x over (the 16"
  Pro's actual native pixel count, the realistic worst case if scaling
  logic were ever bypassed): the smallest substitution seen was still
  ~26x larger than the known small-size failure zone (128x128), so going
  over looks safe in practice, just wasteful if relied on carelessly.
- **Extend vs Mirror is about direction, not a blanket rule.** Mirroring
  the virtual display via macOS's normal automatic setup drags the real
  Retina panel down to the virtual's lower resolution — visibly blurry,
  why `keepawake` uses Extend. But explicitly setting the *virtual*
  display as mirror slave to the real one
  (`CGConfigureDisplayMirrorOfDisplay`) leaves the real display untouched
  at full native resolution with no pixel-cap concern at all — a
  confirmed, safe alternative sizing strategy, not implemented or decided
  on.
- **One-time consent dialog.** The first time a given virtual display
  identity is seen, WindowServer shows "What do you want to show on
  '[name]'?" (Entire Screen / Window or App / Extended Display), with a
  "Set as Default" checkbox. Not scriptable, even as root — gated by
  code-signing/entitlements, not Unix privilege level.
  - "Set as Default" is broadly scoped, not per-display: it silently
    applies to other virtual-display-identity prompts too (confirmed via a
    live Sidecar connection skipping its own picker afterward). No known
    way to reset it short of System Settings' broader privacy/location
    reset options.
- **No way to reposition it.** `CGConfigureDisplayOrigin` reports success,
  but the display's actual bounds always snap adjacent to the main
  display regardless of the requested origin — confirmed, not fixable.
  `keepawake` doesn't attempt this. WindowServer's default placement
  already puts it in a screen corner, which is an acceptable resting spot
  on its own. No manual workaround exists either (System Settings →
  Displays doesn't list it as an arrangeable tile — no real
  `IOFramebuffer`).
- **Cursor/window drift, no mitigation.** The cursor can cross onto the
  virtual display via its screen corner; windows or the Dock dragged onto
  it become invisible until the process is killed (which forces macOS to
  migrate them back to the real display). No known fix.
- **Universal Control hazard.** If enabled, the cursor can travel from the
  real display, through the virtual display, onto a *nearby Mac* signed
  into the same iCloud account — worse than losing a window, since input
  focus leaves the machine entirely. No known mitigation; disable
  Universal Control when using `keepawake`.

## Idle/display/disk sleep is a separate mechanism from clamshell sleep

The virtual display only defeats the hardware-enforced *clamshell* check —
it has no effect on ordinary idle-sleep, display-sleep, or disk-sleep
timers, which are gated by `IOPMAssertion`, not by anything display-related.
A `keepawake` session with the lid closed (or open) could still idle-sleep
on its own timer if nothing were holding those assertions.

`keepawake` closes that gap by spawning `/usr/bin/caffeinate` as an internal
child rather than reimplementing `IOPMAssertionCreateWithName` bindings —
same assertion semantics, already correct, already maintained by Apple.
Its lifetime is tied to `keepawake`'s own PID via `-w`, so it self-releases
on any exit path, including a `kill -9` that bypasses every signal handler.

Two places where `keepawake` deliberately diverges from real `caffeinate`,
confirmed by testing the real thing rather than assuming:
- **Signal-killed wrapped commands**: real `caffeinate` execs directly into
  the wrapped command, so the shell reports a killed child the normal way
  (128+signal). `keepawake` has to stay alive itself, so it spawns the
  command as a genuine child instead — `Process.terminationStatus` is a raw
  signal number in that case, not an exit code, so `keepawake` translates it
  to 128+signal itself to match what a directly-run `caffeinate` would show.
- **`-t`/`-w` combined with a wrapped command**: real `caffeinate` silently
  ignores both the moment a command is given (confirmed: a watched `-w` pid
  and a `-t` timeout are both completely unused, not composed). `keepawake`
  rejects the combination instead — silently ignoring a flag someone typed
  is worse than an upfront error, since if it would do nothing, it almost
  certainly wasn't meant to be there.

## Known gaps — not yet tested

- Whether this holds over a multi-hour closed duration (only 30 seconds is
  confirmed).
- Power draw with the lid closed and no real display — clamshell sleep
  exists partly for thermal/battery protection, worth ruling out as a
  bag-thermal-event risk. (The CLI's battery-power pre-flight warning
  covers this in the meantime.)

## Verifying it yourself

`pmset -g log | grep -i clamshell | tail -5` before and after a deliberate
lid close/reopen is the ground truth — not an instantaneous
`AppleClamshellCausesSleep` read (see above for why). `experiments/clamshell-watch.sh`
polls the same properties in real time if you want to watch it live instead
of checking the log after the fact.
