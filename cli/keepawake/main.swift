// keepawake: prevent this Mac from sleeping, lid open or closed, on battery or
// AC, by holding the system-wide `SleepDisabled` power-management setting via
// `pmset`, gated by a narrow sudoers rule installed once with
// `sudo keepawake install`.
//
// See the project README for why this beats an IOPMAssertion, and for the
// history of the CGVirtualDisplay approach this replaced.

import Cocoa
import IOKit
import IOKit.ps

let toolName = "keepawake"
// Keep in sync with the git tag and the Homebrew formula's url/sha256.
let toolVersion = "0.3.0"

let sudoPath = "/usr/bin/sudo"
let pmsetPath = "/usr/bin/pmset"
let visudoPath = "/usr/sbin/visudo"
let installPath = "/usr/bin/install"
let sudoersRulePath = "/etc/sudoers.d/keepawake"
// System-wide on purpose. NSTemporaryDirectory() is per-uid on macOS, so a lock
// living there would only serialize one user's sessions while the thing it
// guards, `SleepDisabled`, is a single global setting. Two logged-in users, or
// `sudo keepawake` alongside an ordinary one, would each take "the" lock and
// then fight over one hold.
//
// NOT in /tmp, though it is the obvious world-writable choice. /tmp's sticky bit
// stops one user unlinking another's file; it does not stop anyone creating a
// name that doesn't exist yet. An attacker who wins that race with a symlink
// turns a session's open(O_CREAT)/fchmod into arbitrary file creation, and a
// chmod to 0666, as whoever runs keepawake next. /var/db is root-owned 0755, so
// only root can place this path, which is why `install` creates the file and
// sessions merely open it.
let lockFilePath = "/var/db/keepawake.lock"

// How aggressively to release the sleep hold under thermal pressure. `.serious`
// fires eagerly (ordinary heavy CPU/GPU work reaches it) and is opt-in via
// --thermal; `.critical` is the default backstop; `.none` disables it.
enum ThermalCutoff: String { case none, serious, critical }

// Deadbands. A cutoff no longer ends the session, it only suspends the hold, so
// both directions need a margin or the hold would chatter around the threshold.
let batteryResumeMargin = 5      // percentage points above the cutoff to resume at
let thermalResumeDwell = 60.0    // seconds to stay released before re-taking

func printUsage() {
    print("""
    Usage: \(toolName) [-disu] [-t seconds] [-w pid] [command [arg ...]]
           \(toolName) install | uninstall | --release

    Prevents this Mac from sleeping, with the lid open or closed and on
    battery or AC power, by holding the system-wide `SleepDisabled` setting
    through `pmset`. No external display, dummy HDMI plug, or kext required.
    Also runs `caffeinate` internally to hold the display/disk assertions
    `SleepDisabled` doesn't cover, so this is a drop-in replacement rather
    than a system-sleep-only patch.

    Requires a one-time `sudo \(toolName) install`, which adds a sudoers rule
    permitting exactly two commands: taking and releasing the hold.

    Assertion flags (same meaning as caffeinate; passed straight through):
      -d                          Prevent display sleep.
      -i                          Prevent idle system sleep.
      -m                          Prevent disk idle sleep.
      -s                          Prevent system sleep.
      -u                          Declare the user is active.
                                  Default if none of -disu given: -i.
                                  The hold already covers -i and -s; they stay
                                  accepted for caffeinate compatibility.

    Session bounds (pick exactly one, mutually exclusive):
      -t, --duration <seconds>   Automatically stop after this many seconds.
      -w <pid>                   Wait for an existing process to exit, then
                                  stop.
      command [arg ...]          Run this command, hold sleep-prevention for
                                  its duration, then stop and exit with its
                                  exit status (like `caffeinate cmd`). Use
                                  `--` before it if it starts with `-`.

    Safety cutoffs (these release the hold; they do not stop the session):
      --battery <pct>            Release the hold once the battery falls to
                                  this percentage (1-99), or `none` to
                                  disable. Default: 10. Never fires on AC.
                                  Re-taken on AC, or at \(batteryResumeMargin) points above
                                  the cutoff.
      --thermal <level>          Release the hold under thermal pressure, one
                                  of: none, serious, critical. Default:
                                  critical. `serious` only acts with the lid
                                  closed and is opt-in. Re-taken once thermal
                                  state returns to nominal.

    Subcommands:
      install                    (as root) Install the sudoers rule.
      uninstall                  (as root) Remove it and clear any hold.
      --release                  Clear a hold left behind by a killed run.

    Other:
      -v, --version              Show the version and exit.
      -h, --help                 Show this help and exit.

    With no -t/-w/command given, runs until Ctrl-C, which stops it and lets
    normal sleep resume immediately.
    """)
}

func warn(_ message: String) {
    FileHandle.standardError.write("\(toolName): warning: \(message)\n".data(using: .utf8)!)
}

func note(_ message: String) {
    FileHandle.standardError.write("\(toolName): \(message)\n".data(using: .utf8)!)
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write("\(toolName): error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// Run a command to completion, capturing its output. Used for every privileged
// operation, so failures are reported rather than silently ignored.
@discardableResult
@Sendable
func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = arguments
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
    } catch {
        return (-1, "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// Is any session currently participating, i.e. does anyone want the machine
// awake right now? Answered by trying to take the lock exclusively on a fresh
// descriptor: shared and exclusive conflict, so success means no shares exist.
// flock is dropped by the kernel on every exit path, `kill -9` included, so
// there is no stale-lock case to reason about here.
func anySessionActive() -> Bool {
    // O_NOFOLLOW as belt-and-braces: only root can write /var/db, but a lock file
    // that turned into a symlink is never something to follow. No O_CREAT: the
    // file is install's to create, and a missing one means no session can exist.
    let fd = open(lockFilePath, O_RDWR | O_NOFOLLOW)
    guard fd != -1 else { return false }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
    flock(fd, LOCK_UN)
    return false
}

// ---- The sudoers rule ----
//
// sudoers matches the FULL argument vector literally when arguments are given,
// so this grants exactly two commands and no other `pmset` invocation. The match
// is byte-exact: the argv built in setHold() below must stay token-for-token
// identical to what's written here, and any change to one is a change to both.
// The version comment lets a stale rule be spotted after an upgrade.
func sudoersRuleText() -> String {
    """
    # keepawake \(toolVersion), installed by `sudo keepawake install`
    # Grants exactly two commands: taking and releasing the system sleep hold.
    # Remove with `sudo keepawake uninstall`.
    %admin ALL=(root) NOPASSWD: \(pmsetPath) -a disablesleep 1, \(pmsetPath) -a disablesleep 0

    """
}

// Whether our specific NOPASSWD grant is in place.
//
// `sudo -l <cmd>` cannot answer this. It reports whether the user may *ever*
// run the command, and macOS grants admins a blanket `%admin ALL=(ALL) ALL`, so
// it succeeds for every command: it returns 0 for `/bin/rm -rf /` just as
// readily as for ours. Worse, once any NOPASSWD rule exists the listing itself
// stops requiring a password, so `-n` doesn't discriminate either. A machine
// carrying some unrelated NOPASSWD rule would pass the check and then fail at
// the first real `pmset` call.
//
// So parse the listing and look for our own grant: a single entry that is both
// NOPASSWD and names the hold command.
func hasSudoersRule() -> Bool {
    let listing = run(sudoPath, ["-n", "-l"])
    guard listing.status == 0 else { return false }
    return listing.output.split(separator: "\n").contains { line in
        line.contains("NOPASSWD:") && line.contains("\(pmsetPath) -a disablesleep 1")
    }
}

func installSudoersRule() -> Never {
    guard geteuid() == 0 else {
        die("`\(toolName) install` must run as root:\n\n    sudo \(toolName) install\n")
    }

    let tempPath = NSTemporaryDirectory() + "keepawake.sudoers.\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: tempPath) }
    do {
        try sudoersRuleText().write(toFile: tempPath, atomically: true, encoding: .utf8)
    } catch {
        die("couldn't write the temporary rule file: \(error)")
    }
    chmod(tempPath, 0o440)

    // Non-negotiable: a malformed file in sudoers.d breaks `sudo` system-wide,
    // so the rule is validated before it is ever placed where sudo will read it.
    let check = run(visudoPath, ["-cf", tempPath])
    guard check.status == 0 else {
        die("""
        the generated sudoers rule failed validation and was NOT installed. \
        Nothing has been changed. visudo said:
        \(check.output.trimmingCharacters(in: .whitespacesAndNewlines))
        """)
    }

    let placed = run(installPath, ["-m", "0440", "-o", "root", "-g", "wheel", tempPath, sudoersRulePath])
    guard placed.status == 0 else {
        die("couldn't install the rule to \(sudoersRulePath): \(placed.output)")
    }

    // The participation lock lives in root-owned /var/db so that no unprivileged
    // user can pre-place it (see lockFilePath). That means root has to create it
    // here: sessions open it 0666 but never create it. Empty file, contents
    // irrelevant; only flock(2) state on it matters.
    let emptyPath = tempPath + ".lock"
    defer { try? FileManager.default.removeItem(atPath: emptyPath) }
    FileManager.default.createFile(atPath: emptyPath, contents: Data())
    let lockPlaced = run(installPath, ["-m", "0666", "-o", "root", "-g", "wheel", emptyPath, lockFilePath])
    guard lockPlaced.status == 0 else {
        die("couldn't create the lock file at \(lockFilePath): \(lockPlaced.output)")
    }

    print("""
    \(toolName): installed \(sudoersRulePath)

    Members of the `admin` group can now run exactly these two commands
    without a password, and nothing else:

        \(pmsetPath) -a disablesleep 1
        \(pmsetPath) -a disablesleep 0

    Remove with `sudo \(toolName) uninstall`.
    """)
    exit(0)
}

func uninstallSudoersRule() -> Never {
    guard geteuid() == 0 else {
        die("`\(toolName) uninstall` must run as root:\n\n    sudo \(toolName) uninstall\n")
    }
    // Refuse while a session is running. Pulling the rule out from under it
    // strands its hold for good: its teardown `pmset ... 0` would be denied, and
    // so would `--release`, leaving `sudo pmset -a disablesleep 0` by hand as
    // the only way back.
    if anySessionActive() {
        die("""
        keepawake is currently running. Removing the rule now would strand the \
        sleep hold: no running session could release it without a password. Stop \
        every keepawake session first, then uninstall.
        """)
    }

    // Clear any live hold first. Removing the rule while the hold is set would
    // strand it: nothing left could release it without a password prompt.
    run(pmsetPath, ["-a", "disablesleep", "0"])

    if FileManager.default.fileExists(atPath: sudoersRulePath) {
        do {
            try FileManager.default.removeItem(atPath: sudoersRulePath)
            try? FileManager.default.removeItem(atPath: lockFilePath)
            print("\(toolName): removed \(sudoersRulePath), and cleared any sleep hold.")
        } catch {
            die("couldn't remove \(sudoersRulePath): \(error)")
        }
    } else {
        print("\(toolName): no rule at \(sudoersRulePath); cleared any sleep hold anyway.")
    }
    exit(0)
}

// Escape hatch for a hold left behind by a run that died without releasing
// (`kill -9`, a panic). Normal startup reconciles this on its own, so this
// exists for the case where you don't want to start a session just to clear one.
func releaseStaleHold() -> Never {
    // If any session is participating the hold isn't stale, it's in use.
    // Clearing it anyway would desync those sessions: each still believes it is
    // participating, so setHold() short-circuits every future re-take and the
    // machine is free to sleep while keepawake reports that it is holding.
    if anySessionActive() {
        die("""
        keepawake is currently running, so the hold isn't stale. Stop the running \
        session (or sessions); the last one out releases the hold on exit.
        """)
    }

    let viaSudo = geteuid() != 0
    let result = viaSudo
        ? run(sudoPath, ["-n", pmsetPath, "-a", "disablesleep", "0"])
        : run(pmsetPath, ["-a", "disablesleep", "0"])
    guard result.status == 0 else {
        die("""
        couldn't clear the hold. If the sudoers rule isn't installed, run \
        `sudo \(toolName) install` first, or clear it directly with \
        `sudo pmset -a disablesleep 0`.
        """)
    }
    print("\(toolName): sleep hold cleared; normal sleep resumes.")
    exit(0)
}

// ---- Argument parsing ----

var duration: Double?
var assertDisplay = false
var assertIdle = false
var assertDisk = false
var assertSystem = false
var assertUser = false
var waitPid: pid_t?
var thermalCutoff: ThermalCutoff = .critical
// Percentage at or below which the hold is released. Raised from 5% for 0.3.0:
// the hold is now unbreakable where the old one wasn't, so this is the only
// thing between an unattended machine and a flat battery, and since a cutoff
// now only suspends the hold rather than ending the session, firing early is
// cheap.
var batteryCutoff: Int? = 10
var commandArgs: [String] = []

let args = Array(CommandLine.arguments.dropFirst())

// Subcommands are checked before anything else: they're the setup and recovery
// paths, and must work when a normal session couldn't start.
if let first = args.first {
    switch first {
    case "install": installSudoersRule()
    case "uninstall": uninstallSudoersRule()
    case "--release": releaseStaleHold()
    default: break
    }
}

var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
    case "-h", "--help":
        printUsage()
        exit(0)
    case "-v", "--version":
        print("\(toolName) \(toolVersion)")
        exit(0)
    case "-t", "--duration":
        i += 1
        guard i < args.count, let secs = Double(args[i]), secs > 0 else {
            die("--duration requires a positive number of seconds")
        }
        duration = secs
    case "-w":
        i += 1
        guard i < args.count, let pid = Int32(args[i]), pid > 0 else {
            die("-w requires a positive process ID")
        }
        waitPid = pid
    case "--thermal":
        i += 1
        guard i < args.count, let level = ThermalCutoff(rawValue: args[i]) else {
            die("--thermal requires a level: none, serious, or critical")
        }
        thermalCutoff = level
    case "--battery":
        i += 1
        guard i < args.count else {
            die("--battery requires a percentage between 1 and 99, or 'none'")
        }
        if args[i] == "none" {
            batteryCutoff = nil
        } else if let pct = Int(args[i]), pct >= 1, pct <= 99 {
            batteryCutoff = pct
        } else {
            die("--battery requires a percentage between 1 and 99, or 'none'")
        }
    case "--":
        // Everything after `--` is the wrapped command, verbatim, including
        // tokens that look like our own flags.
        commandArgs = Array(args[(i + 1)...])
    default:
        // Matches caffeinate's combined short-flag syntax: `-dis` means
        // `-d -i -s`. Validated all-or-nothing so a typo like `-dx` doesn't
        // apply `-d` before rejecting `x`.
        let flagChars = arg.hasPrefix("-") ? arg.dropFirst() : ""
        let validFlags = Set("dimsu")
        if arg.hasPrefix("-"), !flagChars.isEmpty, flagChars.allSatisfy({ validFlags.contains($0) }) {
            for ch in flagChars {
                switch ch {
                case "d": assertDisplay = true
                case "i": assertIdle = true
                case "m": assertDisk = true
                case "s": assertSystem = true
                case "u": assertUser = true
                default: break
                }
            }
        } else if arg.hasPrefix("-") {
            die("unknown argument '\(arg)' (see --help)")
        } else {
            // First non-flag token starts the wrapped command, like
            // caffeinate: everything from here on (including further
            // `-`-prefixed tokens) belongs to the command, not to us.
            commandArgs = Array(args[i...])
        }
    }
    if !commandArgs.isEmpty {
        break
    }
    i += 1
}

// caffeinate silently ignores -t/-w when a command is given (the command's
// lifetime is the natural bound). We error instead: silently dropping a flag the
// user typed is the worse failure, since it could let a session run far longer
// than intended.
if !commandArgs.isEmpty, waitPid != nil || duration != nil {
    die("-t/--duration and -w can't be combined with a wrapped command; the command's own lifetime already bounds the session.")
}

// kill(pid, 0) also fails with EPERM for a live process owned by someone else,
// which is a different problem than a pid that doesn't exist. Only ESRCH means
// "gone"; anything else we accept and let the poll loop below handle.
if let targetPid = waitPid, kill(targetPid, 0) != 0, errno == ESRCH {
    die("-w \(targetPid): no such process")
}

// Match caffeinate's own default: if no assertion flag was given, hold just
// the idle-sleep assertion.
if !assertDisplay && !assertIdle && !assertDisk && !assertSystem && !assertUser {
    assertIdle = true
}

// ---- Pre-flight: the sudoers rule ----

guard hasSudoersRule() else {
    die("""
    the sudoers rule isn't installed, so the sleep hold can't be taken \
    without a password. Install it once with:

        sudo \(toolName) install

    It permits exactly two commands (`pmset -a disablesleep 1` and `... 0`) \
    and nothing else. Remove it any time with `sudo \(toolName) uninstall`.
    """)
}

// ---- Participation lock ----
//
// `SleepDisabled` is one global setting with no owner, so the hard part is not
// taking it (that is idempotent, every session can simply set it) but knowing
// when it is safe to CLEAR it. A written reference count would answer that and
// reintroduce exactly the failure this design exists to avoid: a `kill -9` leaks
// a decrement, and unlike a stranded hold a leaked count is unrecoverable,
// because "the next run re-takes it and later clears it" no longer applies.
//
// So let the kernel count. Every session that currently wants the machine awake
// holds a SHARED flock, and "am I the last one out?" is answered by dropping to
// unlocked and trying to retake the lock EXCLUSIVELY. Shared and exclusive
// conflict, so mutating the hold while holding either one serializes every take
// against every release. The kernel drops a dead process's share, so `kill -9`
// needs no cleanup: the next session to leave finds the share gone and clears
// the hold.
//
// The share means "this session wants the hold right now", not merely "this
// session exists": a safety cutoff drops it and re-takes it through the same
// path as startup and teardown. Sessions therefore OR together the way
// caffeinate's assertions do: the machine stays awake while anyone still wants
// it, and one session's cutoff cannot force another's hold off.

// Opened, never created: the file belongs to root in root-owned /var/db, placed
// there by `install`, which is what keeps an unprivileged user from pre-placing
// a symlink at this path. O_NOFOLLOW as belt-and-braces.
let lockFD = open(lockFilePath, O_RDWR | O_NOFOLLOW)
guard lockFD != -1 else {
    die("""
    couldn't open the lock file at \(lockFilePath) (\(String(cString: strerror(errno)))). \
    Re-run `sudo \(toolName) install` to recreate it.
    """)
}

// ---- The sleep hold ----
//
// Taking is unconditional at startup and the last session out clears it, which
// doubles as the reconcile for a hold stranded by a previous run that died
// without releasing: the next run re-takes it and later clears it. No marker
// file and no state to keep in sync. The one cost is that a hold set by hand
// outside keepawake is cleared when the last session ends.

// Whether THIS session currently holds a share, that is, whether it currently
// wants the machine awake. Distinct from whether `SleepDisabled` is set, which
// is global and may be being held on our behalf by another session.
var participating = false

@Sendable
func holdFailure(_ verb: String, _ output: String) {
    warn("""
    couldn't \(verb) the sleep hold \
    (\(output.trimmingCharacters(in: .whitespacesAndNewlines))). \
    Check that the sudoers rule is current: `sudo \(toolName) install`.
    """)
}

@discardableResult
@Sendable
func setHold(_ wanted: Bool) -> Bool {
    guard wanted != participating else { return true }

    if wanted {
        // Join, then set. Blocking rather than LOCK_NB: the only thing that ever
        // holds this exclusively is another session inside its own brief
        // last-one-out check, so the wait is bounded by one subprocess spawn.
        // Setting the hold is idempotent, so there is no need to work out
        // whether we are the first session in: every session just sets it.
        flock(lockFD, LOCK_SH)
        participating = true
        // Argv must match the sudoers rule token-for-token; see sudoersRuleText().
        let result = run(sudoPath, ["-n", pmsetPath, "-a", "disablesleep", "1"])
        guard result.status == 0 else {
            flock(lockFD, LOCK_UN)
            participating = false
            holdFailure("take", result.output)
            return false
        }
        return true
    }

    // Leave, then find out whether anyone else still wants the hold. Dropping to
    // unlocked first is what makes the exclusive retake meaningful: if it
    // succeeds, no other session holds a share, so we are the last one out and
    // the hold is ours to clear. If it fails, someone else still wants the
    // machine awake; leave the hold alone.
    flock(lockFD, LOCK_UN)
    participating = false
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return true }
    defer { flock(lockFD, LOCK_UN) }
    let result = run(sudoPath, ["-n", pmsetPath, "-a", "disablesleep", "0"])
    guard result.status == 0 else {
        holdFailure("release", result.output)
        return false
    }
    return true
}

// ---- Lid state ----
//
// True only when we can confirm the lid is open. AppleClamshellState on
// IOPMrootDomain is the physical lid sensor (true = closed), and more stable
// than AppleClamshellCausesSleep, which has been seen to report `No` on a
// machine that in fact sleeps on every real lid close. If we can't read it,
// return false so the caller errs toward acting.
@Sendable
func isLidConfirmedOpen() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    guard let closed = IORegistryEntryCreateCFProperty(
        service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue() as? Bool else {
        return false
    }
    return !closed
}

// ---- Power source ----

@Sendable
func isOnACPower() -> Bool {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
    else { return true }  // unreadable -> assume AC, i.e. don't fire
    return type == (kIOPMACPowerKey as String)
}

// Whole-number battery percentage, or nil when there's no battery to read (a
// desktop Mac, or an unreadable power source).
@Sendable
func batteryPercent() -> Int? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
            .takeUnretainedValue() as? [String: Any] else { continue }
        if let current = description[kIOPSCurrentCapacityKey as String] as? Int,
           let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
           maximum > 0 {
            return Int((Double(current) / Double(maximum) * 100).rounded())
        }
    }
    return nil
}

// ---- Safety cutoffs ----
//
// A cutoff releases the hold and keeps running; it does not end the session.
// Session lifetime belongs to -t/-w/command/signal ("the reason to be awake is
// over"); a cutoff answers a different question ("it is unsafe to be awake right
// now"). Conflating the two used to mean a transient thermal spike killed the
// session outright, and that a low-battery release stayed in effect even after
// plugging back in.
//
// Each cutoff latches its own reason, so recovery on one doesn't depend on the
// other, and each has a deadband so the hold can't chatter at the threshold.

var thermalHeldOff = false
var batteryHeldOff = false
// When thermal state was last observed non-nominal. The dwell runs from here
// rather than from the moment of release, so thermalResumeDwell means "this long
// continuously nominal". Anchoring it to the release instead would let a long
// hot spell satisfy the dwell retroactively and resume the instant things cool,
// which is exactly the chatter the dwell exists to prevent.
var lastNonNominalThermal: Date?
// True while a dwell re-check is already scheduled, so repeated reconciles
// during the dwell don't stack up redundant timers.
var thermalRecheckPending = false

// Does the current thermal state meet the configured cutoff? `serious` is
// reached by ordinary heavy CPU/GPU work, so it only acts with the lid closed
// (the in-a-bag case) and is opt-in. `critical` acts regardless of lid state.
// Suppress only when the lid is *confirmed* open, so an unreadable lid state
// still errs toward releasing.
@Sendable
func thermalTriggered() -> Bool {
    let state = ProcessInfo.processInfo.thermalState
    switch thermalCutoff {
    case .none:
        return false
    case .serious:
        guard !isLidConfirmedOpen() else { return false }
        return state == .serious || state == .critical
    case .critical:
        return state == .critical
    }
}

// Level-triggered: re-decides both latches from current state on every call
// rather than tracking edges, then applies the result. Driven from the thermal
// notification, the battery notification, display reconfiguration (a lid close
// shows up there as the built-in deactivating, which neither notification would
// catch on its own), wake, and once at startup.
@Sendable
func reconcileHold() {
    // Thermal: release on trigger, resume only once fully nominal and after a
    // dwell, since thermal state oscillates on its way back down.
    if thermalHeldOff {
        if ProcessInfo.processInfo.thermalState != .nominal {
            lastNonNominalThermal = Date()
        }
        let dwellRemaining = lastNonNominalThermal
            .map { thermalResumeDwell - Date().timeIntervalSince($0) } ?? 0
        if dwellRemaining <= 0 {
            thermalHeldOff = false
            note("thermal state back to nominal, re-taking the sleep hold")
        } else if ProcessInfo.processInfo.thermalState == .nominal, !thermalRecheckPending {
            // The dwell needs its own timer. Once thermal state reaches nominal
            // it stops changing, so no further thermalStateDidChangeNotification
            // is coming and nothing else would re-drive this. Without the timer
            // the hold stays released until some unrelated event (a battery or
            // display change) happens to reconcile; on a desktop Mac, possibly
            // never.
            thermalRecheckPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + dwellRemaining) {
                thermalRecheckPending = false
                reconcileHold()
            }
        }
    } else if thermalTriggered() {
        thermalHeldOff = true
        lastNonNominalThermal = Date()
        note("thermal state \(ProcessInfo.processInfo.thermalState == .critical ? "critical" : "serious"), releasing the sleep hold")
    }

    // Battery: on battery the level only falls, so the realistic resume trigger
    // is AC being connected: a discrete event that can't flap. The percentage
    // margin covers a charge that climbs back without a power-source change.
    if let cutoff = batteryCutoff {
        if batteryHeldOff {
            if isOnACPower() {
                batteryHeldOff = false
                note("back on AC power, re-taking the sleep hold")
            } else if let percent = batteryPercent(), percent >= cutoff + batteryResumeMargin {
                batteryHeldOff = false
                note("battery back to \(percent)%, re-taking the sleep hold")
            }
        } else if !isOnACPower(), let percent = batteryPercent(), percent <= cutoff {
            batteryHeldOff = true
            note("battery at \(percent)%, releasing the sleep hold (it will be re-taken on AC)")
        }
    }

    setHold(!thermalHeldOff && !batteryHeldOff)
}

// A lid close can satisfy a gating condition without the thermal state or
// battery level itself changing, so display reconfiguration re-drives the
// reconcile. Must be a non-capturing function to serve as a C callback.
func displayReconfigured(_ display: CGDirectDisplayID,
                         _ flags: CGDisplayChangeSummaryFlags,
                         _ userInfo: UnsafeMutableRawPointer?) {
    if flags.contains(.beginConfigurationFlag) { return }
    reconcileHold()
}

// ---- Internal caffeinate ----
//
// `SleepDisabled` governs system sleep only; display sleep and disk sleep are
// independent pmset timers it doesn't touch, so -d/-m/-u still need real
// assertions. -i and -s are redundant under the hold but stay accepted and
// passed through for caffeinate compatibility: harmless and additive. Shell out
// to the system `caffeinate` rather than reimplement it, tied to our PID via
// `-w` so it self-releases however we exit, including a `kill -9`.

var caffeinateFlags = ""
if assertDisplay { caffeinateFlags += "d" }
if assertIdle { caffeinateFlags += "i" }
if assertDisk { caffeinateFlags += "m" }
if assertSystem { caffeinateFlags += "s" }
if assertUser { caffeinateFlags += "u" }

var caffeinateProcess: Process?
do {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    proc.arguments = ["-\(caffeinateFlags)", "-w", String(ProcessInfo.processInfo.processIdentifier)]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try proc.run()
    caffeinateProcess = proc
} catch {
    warn("""
    couldn't start the internal `caffeinate -\(caffeinateFlags)` assertion \
    holder (\(error)). The sleep hold still prevents system sleep, but \
    display and disk sleep will not be held off.
    """)
}

var wrappedProcess: Process?

@Sendable
func teardown() {
    setHold(false)
    if let caff = caffeinateProcess, caff.isRunning {
        caff.terminate()
    }
    if let wrapped = wrappedProcess, wrapped.isRunning {
        wrapped.terminate()
    }
}

// Every way a session ends funnels through here. The callers genuinely race: a
// wrapped command's terminationHandler runs on an arbitrary background queue and
// the -w poll runs on DispatchQueue.global(), while signals, the duration timer
// and the cutoffs all arrive on main. Two of those reaching teardown() at once
// would mutate `participating` and the lock fd unsynchronized and then call
// exit() concurrently, which is undefined.
//
// So: hop to main if we aren't there, and run once. The main queue is serial, so
// checking the flag on it is enough; no lock required.
var isShuttingDown = false

@Sendable
func finish(_ message: String, status: Int32) {
    guard Thread.isMainThread else {
        DispatchQueue.main.async { finish(message, status: status) }
        return
    }
    guard !isShuttingDown else { return }
    isShuttingDown = true
    print(message)
    teardown()
    exit(status)
}

// ---- Clean shutdown on Ctrl-C / termination ----
//
// Installed BEFORE the hold is taken, deliberately. Everything between taking
// the hold and reaching the run loop (spawning the wrapped command, printing
// the status line, registering the cutoff observers) is a window in which a
// Ctrl-C would otherwise hit SIGINT's default disposition and kill the process
// with `SleepDisabled` already set, stranding it with no session running. The
// handler only writes to a pipe, so it is safe to have live this early: a signal
// arriving before the run loop starts waits in the pipe and is serviced the
// moment CFRunLoopRun() begins.
//
// The handler does the only async-signal-safe thing it can: one write() to a
// pipe. Everything real (printing, clearing the hold through `sudo pmset`,
// terminating children) happens back on the run loop, where it is ordinary
// code again. Doing that work in signal context meant calling print(), fork and
// exec, and exit() from a handler that may have interrupted an in-flight
// Process, which can deadlock on the allocator locks that fork inherits. Coming
// back through the main queue also removes the re-entrancy: a shutdown can no
// longer land in the middle of reconcileHold()'s own pmset call.
//
// A DispatchSourceSignal would escape signal context too, but isn't used here.
// An earlier attempt at one never fired; the bare CFRunLoopRun() isn't the
// culprit (it does pump the main GCD queue, which the --duration timer below
// and the thermal dwell re-check both rely on). The real issue: a dispatch
// signal source observes a signal *in addition to* its default disposition,
// so each signal still needs SIG_IGN'd alongside it. But SIG_IGN survives
// exec, so a wrapped command would silently inherit it and ignore Ctrl-C. An
// installed handler is reset to SIG_DFL in the child instead.

var shutdownPipe: [Int32] = [-1, -1]
guard pipe(&shutdownPipe) == 0 else {
    die("couldn't create the shutdown pipe")
}
// Plain Int32 globals, not an array element: the handler below reads these
// directly, and a Swift array subscript is not something to run in signal
// context. In main.swift top-level code these are initialized in order, before
// any handler can fire.
let shutdownReadFD = shutdownPipe[0]
let shutdownWriteFD = shutdownPipe[1]
_ = fcntl(shutdownReadFD, F_SETFD, FD_CLOEXEC)
_ = fcntl(shutdownWriteFD, F_SETFD, FD_CLOEXEC)

func handleShutdownSignal(_ sig: Int32) {
    // Async-signal-safe: no allocation, no locks, no Swift runtime. errno is
    // preserved so a failed write can't perturb the code this interrupted.
    let savedErrno = errno
    var byte = UInt8(truncatingIfNeeded: sig)
    _ = write(shutdownWriteFD, &byte, 1)
    errno = savedErrno
}
signal(SIGINT, handleShutdownSignal)
signal(SIGTERM, handleShutdownSignal)
signal(SIGHUP, handleShutdownSignal)

let shutdownSource = DispatchSource.makeReadSource(fileDescriptor: shutdownReadFD, queue: .main)
shutdownSource.setEventHandler {
    finish("\n\(toolName): stopping", status: 0)
}
shutdownSource.resume()

// ---- Take the hold ----

guard setHold(true) else {
    die("couldn't take the sleep hold; not starting.")
}

// ---- Optional: wrap a command ----
//
// Mirrors `caffeinate command [args...]`: run it as a child, hold the sleep
// prevention for as long as it's alive, then stop and exit with its status.
if !commandArgs.isEmpty {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = commandArgs
    proc.standardInput = FileHandle.standardInput
    proc.standardOutput = FileHandle.standardOutput
    proc.standardError = FileHandle.standardError
    proc.terminationHandler = { finished in
        // Real caffeinate execs into the command, so a signal shows up as
        // 128+signal. We spawn it as a child instead, so terminationStatus is a
        // raw signal number when terminationReason == .uncaughtSignal. Translate
        // it to match what the shell shows for a directly-run process (confirmed
        // against real caffeinate).
        let exitCode = finished.terminationReason == .uncaughtSignal
            ? 128 + finished.terminationStatus
            : finished.terminationStatus
        finish("\(toolName): wrapped command exited (status \(exitCode)), stopping", status: exitCode)
    }
    do {
        try proc.run()
    } catch {
        teardown()
        die("couldn't run '\(commandArgs[0])': \(error)")
    }
    wrappedProcess = proc
}

let statusSuffix: String
if !commandArgs.isEmpty {
    statusSuffix = "wrapping '\(commandArgs.joined(separator: " "))'"
} else if let targetPid = waitPid {
    statusSuffix = "waiting on pid \(targetPid)"
} else if let duration = duration {
    statusSuffix = "auto-stopping in \(Int(duration))s"
} else {
    statusSuffix = "Ctrl-C to stop"
}
let batteryLabel = batteryCutoff.map { "\($0)%" } ?? "none"
print("\(toolName): running (sleep hold active, caffeinate -\(caffeinateFlags), thermal-cutoff \(thermalCutoff.rawValue), battery-cutoff \(batteryLabel), \(statusSuffix))")
fflush(stdout)

// ---- Cutoff triggers ----

NotificationCenter.default.addObserver(
    forName: ProcessInfo.thermalStateDidChangeNotification,
    object: nil, queue: .main
) { _ in reconcileHold() }

// Event-driven, not polled. IOPSNotificationCreateRunLoopSource delivers a
// callback whenever a power source changes.
func batteryCallback(_ context: UnsafeMutableRawPointer?) {
    reconcileHold()
}
if let source = IOPSNotificationCreateRunLoopSource(batteryCallback, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
} else {
    warn("couldn't register for battery-level notifications; the --battery cutoff may respond late.")
}

// A lid close re-drives the cutoffs even when neither notification fires.
CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)

// If the hold was released and the machine then slept, neither the thermal nor
// the power-source notification is guaranteed to fire on the other side, so
// re-decide explicitly on wake.
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: nil, queue: .main
) { _ in reconcileHold() }

// Once at startup, in case we launched already low or already hot.
reconcileHold()


if let duration = duration {
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        finish("\(toolName): duration elapsed, stopping", status: 0)
    }
}

// -w waits on a process we didn't spawn (no terminationHandler for a non-child
// pid), so poll it. Never coexists with a wrapped command; enforced by the
// mutual-exclusivity check above.
if let targetPid = waitPid {
    DispatchQueue.global().async {
        while kill(targetPid, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.5)
        }
        finish("\(toolName): pid \(targetPid) exited, stopping", status: 0)
    }
}

CFRunLoopRun()
