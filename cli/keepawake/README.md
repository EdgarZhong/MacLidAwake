# keepawake

Keep a Mac awake — lid closed or open, on battery or AC — with no external
display, no dummy HDMI plug, and no kext. See
[the project README](../../README.md) for how it works and the known
limitations.

## Install

```
brew tap ecc521/keepawake
brew install ecc521/keepawake/keepawake
sudo keepawake install
```

Or `./build.sh` to build from source, then `sudo ./keepawake install`.

`install` is a one-time step that writes `/etc/sudoers.d/keepawake`, permitting
exactly two commands without a password:

```
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

sudoers matches the full argument vector literally when arguments are given, so
no other `pmset` invocation is granted. The rule is validated with `visudo -cf`
before installation and placed `0440 root:wheel`.

`install` also creates the participation lock file, `/var/db/keepawake.lock`
(`0666 root:wheel`). Sessions open it but never create it, deliberately: it has
to live somewhere every user shares, and any directory an unprivileged user can
write to is one where an attacker can pre-place a symlink at that name and
redirect the first session's `open()`. `/var/db` is root-owned, so only root can
put the file there. Undo both with `sudo keepawake uninstall`, which also clears
any live hold.

Works on Apple Silicon and Intel.

## Use

```
keepawake                    # run until Ctrl-C
keepawake -t 3600            # run for 1 hour, then stop automatically
keepawake -disu              # hold every caffeinate assertion too
keepawake -- ./backup.sh     # run a command, stop when it exits
keepawake -w 1234            # stop when pid 1234 exits
keepawake --thermal serious  # release the hold earlier under thermal pressure
keepawake --battery 20       # release at 20% battery; default 10
keepawake --release          # clear a hold left behind by a killed run
```

Whenever keepawake stops, the hold is released and normal sleep resumes.

keepawake is a drop-in `caffeinate` replacement, not just a clamshell patch. The
`SleepDisabled` hold covers system sleep on any power source with the lid in any
position; an internal `/usr/bin/caffeinate` (tied to keepawake's PID via `-w`)
holds the display and disk assertions `SleepDisabled` doesn't reach. The
assertion flags, `-t`, `-w`, and trailing-command wrapping all match
`caffeinate`'s semantics. `-i` and `-s` are already covered by the hold, but stay
accepted and passed through for compatibility. See `--help` for the full flag
reference.

## Cutoffs

Two cutoffs guard against keepawake being the reason a machine comes to harm.
Both **release the hold without stopping the session**, and re-take it when
conditions recover — so a transient thermal spike doesn't kill a long job, and
plugging in after a low-battery release restores protection.

- `--battery <pct>|none` (default `10`) — release at that battery percentage, so
  an unattended machine doesn't run itself flat. Never fires on AC power.
  Event-driven via `IOPSNotificationCreateRunLoopSource`, not polled. Re-taken
  on AC, or once charge climbs 5 points above the cutoff.
- `--thermal none|serious|critical` (default `critical`) — release under thermal
  pressure, for when keepawake gets left running somewhere the machine can't
  shed heat. Re-taken once thermal state returns to nominal, after a 60s dwell so
  it can't chatter. `serious` is reached by ordinary heavy CPU/GPU work, so it's
  opt-in and only acts with the lid closed.

macOS handles both of these on its own under normal circumstances; these cutoffs
exist because keepawake is the reason the machine is awake in the first place,
and because `SleepDisabled` is not an assertion the OS can simply override.

## Notes

A normal run prints one status line and nothing else. Cutoff activity goes to
stderr, so it's visible without polluting a wrapped command's output.

Sessions compose, so keepawake stays a drop-in `caffeinate` replacement in
scripts: a run started while another is active joins it rather than failing. The
hold is one global setting rather than a per-process assertion, so participation
is tracked with a shared `flock(2)` on `/var/db/keepawake.lock` — every session
that currently wants the machine awake holds a share, and the last one to leave
clears the hold. The
kernel drops a dead process's share, so a `kill -9`ed session strands nothing as
long as another is still running.

Sessions OR together the way caffeinate's assertions do: the machine stays awake
while anyone still wants it, and a `--battery` or `--thermal` cutoff firing in
one session won't force the hold off for another that set different thresholds.

`pmset -g` reports `SleepDisabled` on its first line — the quickest way to check
whether a hold is currently active.
