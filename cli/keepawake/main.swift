// keepawake: prevent clamshell sleep with no external hardware, by holding open
// a software-only virtual display via the private CGVirtualDisplay API.
// See RESEARCH.md for why this works, and experiments/phantom-display for the
// original proof of concept.

import Cocoa
import CoreGraphics
import IOKit
import IOKit.ps

let toolName = "keepawake"

// How aggressively to release the sleep hold under thermal pressure. Only ever
// acts while the lid is closed (see the thermal safety net below); with the lid
// open, thermal management is the OS's job. `.serious` fires eagerly and is
// opt-in via --thermal; `.critical` is the default backstop; `.none` disables it.
enum ThermalCutoff: String { case none, serious, critical }

func printUsage() {
    print("""
    Usage: \(toolName) [-disu] [-t seconds] [-w pid] [-f] [command [arg ...]]

    Prevents this Mac from sleeping (lid closed or open) without any
    external display or hardware. Holds open a tiny software-only virtual
    display to defeat hardware-enforced clamshell sleep (no kext, no dummy
    HDMI plug required), and internally runs `caffeinate` to hold the same
    sleep assertions it would, so this is a drop-in replacement rather than
    just a clamshell-only patch.

    Assertion flags (same meaning as caffeinate; passed straight through):
      -d                          Prevent display sleep.
      -i                          Prevent idle system sleep.
      -m                          Prevent disk idle sleep.
      -s                          Prevent system sleep (AC power only).
      -u                          Declare the user is active.
                                  Default if none of -disu given: -i.

    Session bounds (pick exactly one, mutually exclusive):
      -t, --duration <seconds>   Automatically stop after this many seconds.
      -w <pid>                   Wait for an existing process to exit, then
                                  stop.
      command [arg ...]          Run this command, hold the sleep-prevention
                                  for its duration, then stop and exit with
                                  its exit status (like `caffeinate cmd`).
                                  Use `--` before it if it starts with `-`.

    Other:
      -f, --force                Skip safety warnings (battery power, Sidecar
                                  connected, non-Apple-Silicon Mac, etc.) and
                                  run anyway.
      --thermal <level>          When to release the hold under thermal
                                  pressure, one of: none, serious, critical.
                                  Default: critical. Only acts while the lid is
                                  closed; with the lid open, thermal management
                                  is left to the OS. `serious` fires eagerly
                                  (normal heavy CPU/GPU work reaches it), so
                                  it's opt-in.
      -h, --help                 Show this help and exit.

    With no -t/-w/command given, runs until Ctrl-C, which stops it and lets
    normal sleep resume immediately.
    """)
}

func warn(_ message: String) {
    FileHandle.standardError.write("\(toolName): warning: \(message)\n".data(using: .utf8)!)
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write("\(toolName): error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// ---- Argument parsing ----

var duration: Double?
var force = false
var assertDisplay = false
var assertIdle = false
var assertDisk = false
var assertSystem = false
var assertUser = false
var waitPid: pid_t?
var thermalCutoff: ThermalCutoff = .critical
var commandArgs: [String] = []

let args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
    case "-h", "--help":
        printUsage()
        exit(0)
    case "-f", "--force":
        force = true
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

if let targetPid = waitPid, kill(targetPid, 0) != 0 {
    die("-w \(targetPid): no such process")
}

// Match caffeinate's own default: if no assertion flag was given, hold just
// the idle-sleep assertion.
if !assertDisplay && !assertIdle && !assertDisk && !assertSystem && !assertUser {
    assertIdle = true
}

// ---- Single-instance lock ----
//
// Two keepawake processes would create two identically-identified virtual
// displays. flock(2) on a held file descriptor is atomic (unlike a
// check-then-write PID file, where two launches could both pass the check), and
// the kernel releases it on any exit path, so there's nothing to clean up or go
// stale.

let lockFilePath = NSTemporaryDirectory() + "keepawake.lock"
let lockFD = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
guard lockFD != -1 else {
    die("couldn't open lock file at \(lockFilePath)")
}
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    let existingPID = (try? String(contentsOfFile: lockFilePath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let pid = existingPID, !pid.isEmpty {
        die("keepawake is already running (pid \(pid)). Stop it first with `kill \(pid)`.")
    }
    die("keepawake is already running. Stop it first.")
}
// Record our PID so a future contender can name it in its error. Not
// load-bearing for correctness.
ftruncate(lockFD, 0)
let pidString = "\(ProcessInfo.processInfo.processIdentifier)\n"
_ = pidString.withCString { write(lockFD, $0, strlen($0)) }

// ---- Private API availability check ----
//
// CGVirtualDisplay is undocumented; Apple can rename or remove it in any macOS
// release. This won't catch a fully-removed class (that fails at the dynamic
// linker before our code runs), but it catches the class still loading while
// behaving differently, with a clear message instead of a crash.
guard NSClassFromString("CGVirtualDisplay") != nil,
    NSClassFromString("CGVirtualDisplayDescriptor") != nil,
    NSClassFromString("CGVirtualDisplaySettings") != nil
else {
    die("""
    the private CGVirtualDisplay API this tool depends on doesn't appear \
    to be available on this macOS version. This is undocumented, \
    unsupported API. Apple can change or remove it at any time, and \
    there is no fallback if it's gone.
    """)
}

// ---- Pre-flight checks ----

// Check the real hardware at runtime, not the build arch: a compile-time
// `#if arch(x86_64)` would test what the binary was built for, so an x86_64
// slice under Rosetta on Apple Silicon would wrongly hit the Intel guard. A
// native arm64 build is always Apple Silicon; for an x86_64 build,
// `sysctl.proc_translated` reads 1 under Rosetta and doesn't exist at all on
// genuine Intel.
func isRunningOnAppleSilicon() -> Bool {
    #if arch(arm64)
    return true
    #else
    var translated: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 else {
        return false
    }
    return translated == 1
    #endif
}

if !isRunningOnAppleSilicon() && !force {
    die("""
    this Mac appears to be Intel-based. The hardware-level clamshell-sleep \
    enforcement this tool works around was introduced with Apple Silicon \
    (macOS Ventura+). On Intel, `sudo pmset -a disablesleep 1` already \
    prevents clamshell sleep without any of this (confirmed by testing). \
    Note that plain `caffeinate` does NOT: it only blocks idle/display \
    sleep, never lid-closed sleep, on any Mac. --force will let you run \
    this anyway, but on the one Intel Mac this has actually been tested on, \
    the virtual display never registered at any size, so `pmset` is very \
    likely your only real option here, not just the easier one.
    """)
}

func isOnACPower() -> Bool {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
    else { return true }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
            .takeUnretainedValue() as? [String: Any]
        else { continue }
        if let state = description[kIOPSPowerSourceStateKey as String] as? String {
            return state == kIOPSACPowerValue as String
        }
    }
    return true
}

if !isOnACPower() && !force {
    var batteryWarning = """
    running on battery power. Closing the lid for extended periods on \
    battery bypasses the thermal/battery protections clamshell sleep \
    normally provides (e.g. in an enclosed bag).
    """
    // Only nag about Low Power Mode when it's actually off (public API, no sudo
    // to read; enabling it does need sudo or the Settings toggle, so we suggest
    // rather than set it).
    if !ProcessInfo.processInfo.isLowPowerModeEnabled {
        batteryWarning += " Enabling Low Power Mode (System Settings > Battery)"
            + " cuts heat and drain and is worth doing before a closed-lid run."
    }
    batteryWarning += " Re-run with --force to suppress this warning, or plug in first."
    warn(batteryWarning)
}

func connectedDisplayTypeLines() -> [String] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    task.arguments = ["SPDisplaysDataType"]
    let pipe = Pipe()
    task.standardOutput = pipe
    do {
        try task.run()
    } catch {
        return []
    }
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    return text.components(separatedBy: "\n").filter { $0.contains("Display Type:") }
}

if !force {
    // Always shown, not just when Sidecar is connected right now: the phantom
    // is parked at the bottom-right outer edge (see the parking logic below),
    // but the cursor can still reach it there. Whether that then routes onto a
    // nearby Mac depends on Universal Control being enabled, which isn't
    // reliably detectable from here, so this warns unconditionally.
    warn("""
    this tool's virtual display is parked at the bottom-right outer edge of \
    your screen arrangement, but your cursor can still reach it there. If \
    Universal Control is enabled, this has been observed to route the cursor \
    onward onto a nearby Mac/iPad. Disable Universal Control if you want to \
    rule that out. Re-run with --force to suppress this warning.
    """)
    let displayTypes = connectedDisplayTypeLines()
    if displayTypes.contains(where: { $0.contains("Sidecar") }) {
        warn("a Sidecar display is currently connected, which increases the chance of the above actually happening.")
    }
}

// ---- Determine sizing and create the virtual display ----
//
// CGVirtualDisplay caps total pixels (a software-framebuffer limit) somewhere
// between 1,662,600 and 1,684,900 on the one machine tested (see RESEARCH.md).
// Start under it and halve down if `apply()` rejects a size, rather than
// trusting that number on untested hardware. A request above the cap silently
// registers a smaller resolution instead of failing, which is fine: any
// registered display satisfies the clamshell check, right-sized or not.
//
// An `NSScreen.screens.count` sanity check was tried and dropped: in this bare
// CFRunLoop (non-NSApplication) context it never updated even when the display
// had registered (confirmed externally via `system_profiler`). `apply()`'s
// return value is the only reliable in-process signal.

guard let mainScreen = NSScreen.main else {
    die("couldn't read the main display's resolution")
}
let pointSize = mainScreen.frame.size
let requestedPixels = Double(pointSize.width) * Double(pointSize.height)
let startingPixelCap = 1_654_400.0
let minPixels = 4.0 // 2x2, the smallest size confirmed to register as a real screen.

var candidatePixels = min(requestedPixels, startingPixelCap)
var display: CGVirtualDisplay?
var targetWidth = 0.0
var targetHeight = 0.0

while candidatePixels >= minPixels {
    let scale = (candidatePixels / requestedPixels).squareRoot()
    let w = (Double(pointSize.width) * scale).rounded(.down)
    let h = (Double(pointSize.height) * scale).rounded(.down)

    let desc = CGVirtualDisplayDescriptor()
    desc.setDispatchQueue(DispatchQueue.main)
    desc.name = "Keepawake Phantom Display"
    desc.maxPixelsWide = UInt32(w)
    desc.maxPixelsHigh = UInt32(h)
    desc.sizeInMillimeters = CGSize(width: w / 10, height: h / 10)
    desc.productID = 0x1234
    desc.vendorID = 0x3456
    desc.serialNum = 0x0001
    desc.terminationHandler = { _, _ in }

    let candidate = CGVirtualDisplay(descriptor: desc)
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: 60)]

    if candidate.apply(settings) {
        display = candidate
        targetWidth = w
        targetHeight = h
        break
    }

    candidatePixels /= 2
}

guard let display = display else {
    die("""
    failed to create the virtual display at any size down to \
    \(Int(minPixels)) pixels. CGVirtualDisplay may be unavailable, or may \
    behave differently, on this macOS version or device. This is \
    undocumented, unsupported API with no further fallback. If you can, \
    please report this (device model + macOS version) so RESEARCH.md's \
    device-support notes can be updated.
    """)
}

// ---- Park the virtual display out of the way ----
//
// Left alone, WindowServer inserts the phantom mid-arrangement and displaces
// real displays (with two externals attached, it lands between them). Shove it
// to the far-right outer edge instead, bottom-aligned to its neighbor, so the
// real displays keep their positions. macOS keeps arrangements gap-free, so
// CGConfigureDisplayOrigin can't float the phantom off in empty space; it clamps
// the request to a contiguous spot. But it does honor which outer edge the
// phantom attaches to, which is all we need. Verified on a 3-display setup: the
// requested edge origin is applied exactly and no real display moves.

var phantomDisplayID: CGDirectDisplayID?

func parkPhantom() {
    guard let vid = phantomDisplayID else { return }
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }

    // Rightmost real display (exclude the phantom itself) is the neighbor we
    // attach past and bottom-align to.
    guard let neighbor = ids.filter({ $0 != vid })
        .map({ CGDisplayBounds($0) })
        .max(by: { $0.maxX < $1.maxX })
    else { return }

    let targetX = Int32(neighbor.maxX)
    let targetY = Int32(neighbor.maxY - CGDisplayBounds(vid).height)

    // Already parked? Do nothing, so our own move can't retrigger the reconfig
    // callback into an endless re-park loop.
    let cur = CGDisplayBounds(vid)
    if Int32(cur.origin.x) == targetX, Int32(cur.origin.y) == targetY { return }

    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg = cfg else { return }
    CGConfigureDisplayOrigin(cfg, vid, targetX, targetY)
    CGCompleteDisplayConfiguration(cfg, .forSession)
}

// Re-park whenever the display layout changes (a monitor connects, the
// arrangement is edited), since that can wedge the phantom back into the middle.
// Must be a non-capturing function to serve as a C callback. Ignore changes to
// the phantom itself so our own re-park move doesn't loop, and defer the re-park
// off the callback (starting a new configuration from inside it is unsafe).
func displayReconfigured(_ display: CGDirectDisplayID,
                         _ flags: CGDisplayChangeSummaryFlags,
                         _ userInfo: UnsafeMutableRawPointer?) {
    if flags.contains(.beginConfigurationFlag) { return }
    // The lid closing surfaces here as the built-in display deactivating. That's
    // the one thermal case the thermal-change notification misses (the thermal
    // state doesn't change, only the lid does), so re-check the cutoff here too.
    evaluateThermalCutoff()
    if display == phantomDisplayID { return }
    DispatchQueue.main.async { parkPhantom() }
}

phantomDisplayID = display.displayID
parkPhantom()
CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)

// ---- Internal caffeinate: hold the assertions the virtual display doesn't ----
//
// The virtual display only defeats the hardware clamshell check; idle, display,
// and disk sleep go through IOPMAssertion separately. Shell out to the system
// `caffeinate` rather than reimplement it, tied to our PID via `-w` so it
// self-releases however we exit, including a `kill -9` that bypasses every
// handler below. The explicit `teardown()` on normal exit paths just makes
// release prompt rather than waiting on caffeinate's own poll interval.

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
    holder (\(error)). The virtual display still prevents clamshell sleep, \
    but ordinary idle/display/disk sleep will not be held off.
    """)
}

var wrappedProcess: Process?

func teardown() {
    if let caff = caffeinateProcess, caff.isRunning {
        caff.terminate()
    }
    if let wrapped = wrappedProcess, wrapped.isRunning {
        wrapped.terminate()
    }
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
        print("\(toolName): wrapped command exited (status \(exitCode)), stopping")
        teardown()
        exit(exitCode)
    }
    do {
        try proc.run()
    } catch {
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
print("\(toolName): running (virtual display \(Int(targetWidth))x\(Int(targetHeight)), caffeinate -\(caffeinateFlags), thermal-cutoff \(thermalCutoff.rawValue), \(statusSuffix))")
fflush(stdout)

// True only when we can confirm the lid is open. AppleClamshellState on
// IOPMrootDomain is the physical lid sensor (true = closed), and more stable
// than the AppleClamshellCausesSleep property RESEARCH.md warns about. If we
// can't read it, return false so the caller errs toward acting.
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

// ---- Thermal safety net (lid-gated) ----
// Release the hold under thermal pressure, but only while the lid is closed:
// with the lid open, thermal management is the OS's job and it will emergency-
// sleep itself if it must, so exiting there would just kill the session for no
// benefit. Suppress only when the lid is *confirmed* open, so an unreadable lid
// state still errs toward releasing. The threshold comes from --thermal.
//
// Level-triggered, not edge-triggered: this re-decides from the current thermal
// + lid state on every call, and is driven from three places — the thermal-state
// notification, the display-reconfiguration callback (the lid closing shows up
// there as the built-in deactivating), and once at startup. That covers the
// go-critical-then-close-the-lid ordering, where the thermal state itself never
// changes, so the notification alone would miss it.
func evaluateThermalCutoff() {
    let state = ProcessInfo.processInfo.thermalState
    let hit: Bool
    switch thermalCutoff {
    case .none: hit = false
    case .serious: hit = (state == .serious || state == .critical)
    case .critical: hit = (state == .critical)
    }
    guard hit, !isLidConfirmedOpen() else { return }
    let label = state == .critical ? "critical" : "serious"
    FileHandle.standardError.write(
        "\(toolName): thermal state \(label) with lid closed, releasing the sleep hold and exiting\n".data(using: .utf8)!)
    teardown()
    exit(0)
}

if thermalCutoff != .none {
    NotificationCenter.default.addObserver(
        forName: ProcessInfo.thermalStateDidChangeNotification,
        object: nil, queue: .main
    ) { _ in evaluateThermalCutoff() }
    evaluateThermalCutoff()  // in case we launched already hot with the lid shut
}

// ---- Clean shutdown on Ctrl-C / termination ----
//
// A DispatchSource handler was tried first but never fired: this script drives
// its run loop with bare CFRunLoopRun(), which doesn't reliably pump the main
// GCD queue the way an app-framework run loop does. A plain C signal handler
// doesn't depend on that.

func handleShutdownSignal(_ sig: Int32) {
    print("\n\(toolName): stopping")
    teardown()
    exit(0)
}
signal(SIGINT, handleShutdownSignal)
signal(SIGTERM, handleShutdownSignal)

if let duration = duration {
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        print("\(toolName): duration elapsed, stopping")
        teardown()
        exit(0)
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
        print("\(toolName): pid \(targetPid) exited, stopping")
        teardown()
        exit(0)
    }
}

CFRunLoopRun()
