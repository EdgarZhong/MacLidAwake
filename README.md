# MacLidAwake

**Temporarily keep a MacBook running with the lid closed — then automatically restore normal sleep.**

[中文文档](README.zh-Hans.md)

MacLidAwake is built for one job: you need to close the lid and carry your MacBook for a while, but a local task — an AI agent like Claude Code or Codex, a build, a download — should keep running. When the timer ends, you stop the hold, or a safety condition trips, your Mac goes back to its normal sleep behavior.

It is not a general power manager, not a `caffeinate` clone, and not a command wrapper.

## Requirements

- macOS 13 (Ventura) or later, Apple Silicon or Intel.
- An administrator account. `lidgo setup` asks for your password once, through the system `sudo` prompt — MacLidAwake never sees, stores, or types your password.

## Install

**Homebrew** (installs the prebuilt universal binary and zsh completion):

```bash
git clone https://github.com/EdgarZhong/MacLidAwake.git
cd MacLidAwake
brew install --formula Formula/maclidawake.rb
```

**Prebuilt binary** from [GitHub Releases](https://github.com/EdgarZhong/MacLidAwake/releases):

```bash
tar -xzf maclidawake-*-macos.tar.gz
cd maclidawake-*-macos
xattr -d com.apple.quarantine lidgo   # only needed for browser downloads
install -m 0755 lidgo "${HOME}/.local/bin/lidgo"
```

**Build from source** (requires a Swift 6 toolchain):

```bash
git clone https://github.com/EdgarZhong/MacLidAwake.git
cd MacLidAwake
./scripts/build.sh
install -m 0755 .build/release/lidgo "${HOME}/.local/bin/lidgo"
```

Make sure `~/.local/bin` (or your chosen install directory) is on your `PATH`.

## Setup (once)

```bash
lidgo setup
```

This idempotently installs three things, and can repair them if they break:

- a **sudoers rule** allowing exactly two commands without a password: `pmset -a disablesleep 1` and `pmset -a disablesleep 0` (validated with `visudo` before install),
- a root-owned **participation lock** at `/var/db/maclidawake.lock`,
- a per-user **LaunchAgent** that supervises timers and safety cutoffs in the background.

## Usage

```text
lidgo                        Start the default 60-minute timer (or show status if already on)
lidgo --hold                 Keep awake until you press Ctrl-C in this terminal
lidgo -r | --refresh         Restart the timer (refused while a Hold is active)
lidgo switch -f | --force    Force-toggle the global state
lidgo config                 Show configuration
lidgo config -d 45           Set future timers to 45 minutes (also: 90m, 2h, 1h30m)
lidgo config -b 10           Set the battery safety cutoff (percent)
lidgo setup                  Install or repair permissions and the LaunchAgent
lidgo help                   Show help
```

- Defaults: **60-minute timer**, **10% battery cutoff**.
- Running `lidgo` while a timer is active just shows the deadline — it never silently refreshes.
- A Timer and any number of Holds can coexist. Normal sleep resumes only when the *last* valid lease disappears.
- A Hold verifies the holding process by PID, start-time identity, and run state — a stopped (Ctrl-Z) or dead process cannot pin your Mac awake forever.

## Safety model

- No passwords stored, no Keychain, no auto-typing. Day-to-day runs use `sudo -n` only.
- All leases are cleared and stay off when the battery reaches the cutoff, the battery state can't be read, or thermal pressure is critical. They never turn back on by themselves.
- `lidgo switch -f` and safety trips bump a generation counter, so stale holds can't reclaim the awake state.
- Full details: [docs/architecture-and-security.md](docs/architecture-and-security.md).

## Uninstall

```bash
launchctl bootout "gui/$(id -u)" com.maclidawake.lidgo.agent 2>/dev/null
rm -f "${HOME}/Library/LaunchAgents/com.maclidawake.lidgo.agent.plist"
sudo rm -f /etc/sudoers.d/maclidawake
sudo rm -f /var/db/maclidawake.lock
rm -rf "${HOME}/Library/Application Support/MacLidAwake"
rm -f "${HOME}/.local/bin/lidgo"   # or: brew uninstall maclidawake
```

## Known limitations

- `SleepDisabled` is a system-wide boolean with no owner. MacLidAwake's fail-safe cleanup may reset a value set by hand or by another tool.
- The supervisor runs inside your login session; between boot and login it does not repair state.
- Actual lid-closed behavior depends on the specific MacBook, macOS version, and hardware state.

## For developers

Testing, CI, and release automation live in `tests/`, `scripts/`, and `.github/workflows/`. See [docs/testing.md](docs/testing.md) and [docs/product-spec.md](docs/product-spec.md) for the full specification.

## License & attribution

MacLidAwake is derived from [ecc521/keepawake](https://github.com/ecc521/keepawake) and reuses its least-privilege design: exact sudoers grants, `pmset`, and a kernel participation lock. It remains under the MIT License with Tucker Willenborg's copyright notice preserved. See [LICENSE](LICENSE).
