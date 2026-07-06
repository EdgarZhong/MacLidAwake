# Keepawake — research log

Goal: keep a Mac from sleeping when the lid is closed, with **no external
hardware**, root acceptable, kext unacceptable. Target machine: MacBook Pro
with M5 (Apple Silicon).

## Constraints established

1. Do not sleep, even with lid closed.
2. No external hardware (no dummy HDMI/DP plug, no real monitor).
3. Root-level software is fine. Kernel extensions are not (deprecated,
   effectively unloadable on Apple Silicon under normal Secure Boot, and
   InsomniaX/Frizlab's kext-based approach is dead for this reason).

## What's confirmed so far

- `caffeinate` / public `IOPMAssertion` types never touch lid-closed sleep at
  all — they only block idle/display sleep while the lid is open.
- Apple added **hardware-level lid enforcement** on Apple Silicon starting
  macOS Ventura: the lid sensor can force a sleep at a level `pmset -a
  disablesleep 1` does not override, when no display is attached. This is the
  central obstacle for the M5.
- The officially supported bypass is clamshell mode: external display
  (real or a physical dummy plug) + power. That's exactly the hardware
  dependency we're trying to avoid.
- Kext-based historical workarounds (InsomniaX / Frizlab's `Insomnia` kext)
  patched this at the kernel level, but are not viable now: kexts require
  Reduced Security + manual approval on Apple Silicon and haven't been
  updated to fight the newer hardware enforcement anyway. Ruled out per
  constraint #3 regardless.
- `AppleClamshellCausesSleep` / `AppleClamshellState` are the relevant
  `IOPMrootDomain` properties (`ioreg -r -k AppleClamshellCausesSleep`).
  `AppleClamshellCausesSleep=No` is supposed to mean "external display mode,
  won't sleep on lid close."

### Live baseline data point (Intel MacBookPro15,3, T2, macOS 15.7.7)

This is **not** the target hardware (Intel, not Apple Silicon — predates the
Ventura hardware lid-enforcement change), but it's what was on hand to poke
at first:

- Instantaneous `ioreg` read of `AppleClamshellCausesSleep` showed `No` even
  with no external display and no overrides set — this reading turned out to
  be **not predictive**. `pmset -g log` shows this exact machine has actually
  entered `Sleep state due to 'Clamshell Sleep'` repeatedly and consistently
  on ordinary lid-close, with no external display attached, across the last
  several days of real usage. Lesson: don't trust an instantaneous
  `AppleClamshellCausesSleep` read as ground truth — use `pmset -g log`
  historical entries (`grep -i clamshell`) as the real signal, or an actual
  lid-close test.
- Conclusion: the Intel run doesn't tell us much about the M5's behavior.
  The real test has to happen on Apple Silicon.

## The open question: phantom/virtual display

BetterDisplay (and FreeDisplay, SimpleDisplay, etc.) create displays purely in
software via the **private `CGVirtualDisplay` API** in CoreGraphics — no
hardware, no kext. A minimal reference implementation is in
`experiments/phantom-display/` (adapted from
https://github.com/KhaosT/CGVirtualDisplay).

The question: does a `CGVirtualDisplay`-created display satisfy whatever
check sets `AppleClamshellCausesSleep = No` / lets clamshell mode engage
without a real display?

**Working theory (unconfirmed):** probably not, because of a layering
mismatch:

- `CGVirtualDisplay` lives at the CoreGraphics/SkyLight/WindowServer layer —
  entirely userspace, no corresponding `IOFramebuffer` tied to a real GPU
  output connector.
- The clamshell-causes-sleep decision is made by `IOPMrootDomain` in
  coordination with `AppleGraphicsControl`/AGDC, which reasons about real
  `IOFramebuffer` instances backed by actual DisplayPort/HDMI/eDP hotplug
  detection (EDID over an electrical connection) — this is why a passive
  $9 dummy HDMI plug works (it presents a real EDID over a real physical
  connector) while a software-only display might not register at that layer
  at all.
- No community report was found of "pure virtual display, zero physical
  dummy plug, lid closed, no sleep" working — despite this being an
  extremely desirable and heavily searched-for combination. Its absence
  despite years of BetterDisplay/Amphetamine/KeepingYouAwake community
  activity is circumstantial evidence against it working, on top of the
  architectural argument above.

This is a theory, not a confirmed result — it needs an actual test on the M5.

## Test protocol (run on the M5)

1. `cd experiments && ./clamshell-watch.sh &` in one terminal (or just run
   `pmset -g log | tail -5` before/after, simpler and equally valid — the
   watch script is for real-time visibility during the close/open, the log
   is the ground truth after the fact).
2. Baseline: with lid open, no external display, confirm via
   `system_profiler SPDisplaysDataType` that only the built-in display is
   listed. Close the lid, wait ~15s, reopen. Check `pmset -g log | grep -i
   clamshell | tail -5` — expect to see `Entering Sleep state due to
   'Clamshell Sleep'` (i.e., confirm the machine sleeps normally with no
   virtual display, establishing the control case).
3. Build and run the phantom display: `cd experiments/phantom-display &&
   ./build.sh && ./phantom-display`. Confirm a second display now appears in
   `system_profiler SPDisplaysDataType` / System Settings > Displays.
4. With the phantom display still running, close the lid, wait ~15s, reopen.
5. Check `pmset -g log | grep -i clamshell | tail -5` again:
   - If a new `'Clamshell Sleep'` entry appears → phantom display did NOT
     prevent sleep. Approach disproven.
   - If no new sleep entry, and the log instead shows normal continued
     operation (or an `'External Display Mode'`-style entry) → phantom
     display DID prevent sleep. Approach proven viable, worth building out.
6. Also worth checking `ioreg -r -k AppleClamshellCausesSleep` immediately
   before step 4, to see if it flips to `No` once the phantom display is
   attached (informative, but per the Intel finding above, treat this as a
   secondary signal — the `pmset -g log` sleep/no-sleep result after an
   actual lid-close is the real answer).

## If the phantom display doesn't work

Fallback theories worth investigating next, roughly in order of promise:
- Whether there's a private/root-accessible IOKit user-client call that lets
  something set `AppleClamshellCausesSleep` or otherwise override the
  root-domain decision directly (bypassing the display-detection question
  entirely) — unconfirmed, would need kernel symbol / entitlement digging.
  This is the only path that stays software-only if the phantom display
  fails, and it may not exist in a form reachable without a kext.
- Accept the external-display-hardware requirement, but explore whether a
  *virtual* display is at least a necessary complement to some other trick —
  e.g., some evidence suggests display detection at the AGDC layer might
  behave differently across chip generations; worth double checking on the
  M5 specifically before concluding it's a dead end everywhere.
