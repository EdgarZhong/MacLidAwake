// keepawake — prevent clamshell sleep with no external hardware.
//
// Holds open a tiny software-only virtual display via the private
// CGVirtualDisplay API (see experiments/phantom-display and RESEARCH.md for
// how this was discovered/validated). No kext, no dummy HDMI plug. Run it
// before closing the lid; Ctrl-C (or --duration elapsing) releases the hold
// and lets normal clamshell sleep resume.

import Cocoa
import CoreGraphics
import IOKit.ps

let toolName = "keepawake"

func printUsage() {
    print("""
    Usage: \(toolName) [-disu] [-t seconds] [-w pid] [-f] [command [arg ...]]

    Prevents this Mac from sleeping — lid closed or open — without any
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

    Session bounds:
      -t, --duration <seconds>   Automatically stop after this many seconds.
      -w <pid>                   Wait for an existing process to exit, then
                                  stop. Mutually exclusive with a wrapped
                                  command below.
      command [arg ...]          Run this command, hold the sleep-prevention
                                  for its duration, then stop and exit with
                                  its exit status (like `caffeinate cmd`).
                                  Use `--` before it if it starts with `-`.

    Other:
      -f, --force                Skip safety warnings (battery power, Sidecar
                                  connected, non-Apple-Silicon Mac, etc.) and
                                  run anyway.
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
    case "-d":
        assertDisplay = true
    case "-i":
        assertIdle = true
    case "-m":
        assertDisk = true
    case "-s":
        assertSystem = true
    case "-u":
        assertUser = true
    case "-w":
        i += 1
        guard i < args.count, let pid = Int32(args[i]), pid > 0 else {
            die("-w requires a positive process ID")
        }
        waitPid = pid
    case "--":
        // Everything after `--` is the wrapped command, verbatim — including
        // tokens that look like our own flags.
        commandArgs = Array(args[(i + 1)...])
    default:
        if arg.hasPrefix("-") {
            die("unknown argument '\(arg)' (see --help)")
        }
        // First non-flag token starts the wrapped command, like caffeinate:
        // everything from here on (including further `-`-prefixed tokens)
        // belongs to the command, not to us.
        commandArgs = Array(args[i...])
    }
    if !commandArgs.isEmpty {
        break
    }
    i += 1
}

if waitPid != nil && !commandArgs.isEmpty {
    die("-w and a wrapped command are mutually exclusive — use one or the other")
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
// Nothing else stops two `keepawake` processes running at once, which would
// create two identically-identified virtual displays. Use flock(2) on an
// open file descriptor held for the life of the process rather than a
// check-then-write PID file: the check-and-create was two separate
// operations with a race between them (two simultaneous launches could both
// pass the check), and a PID file also needs manual staleness detection for
// crashed holders. flock is atomic and the kernel releases it automatically
// on any exit path — signal, --duration, thermal-critical, early die(), or
// a crash — so there's nothing to clean up and nothing that can go stale.

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
// We hold the lock; record our PID purely so a future contender can report
// it in the message above. Not load-bearing for correctness.
ftruncate(lockFD, 0)
let pidString = "\(ProcessInfo.processInfo.processIdentifier)\n"
_ = pidString.withCString { write(lockFD, $0, strlen($0)) }

// ---- Private API availability check ----
//
// CGVirtualDisplay is undocumented and unsupported — Apple can rename or
// remove it in any macOS release with no notice. This can't catch every
// possible failure mode (a fully-removed class could fail at the dynamic
// linker level before any of our code runs at all), but it catches the
// more likely case of the class still loading while behaving differently,
// with a clear message instead of a confusing crash.
guard NSClassFromString("CGVirtualDisplay") != nil,
    NSClassFromString("CGVirtualDisplayDescriptor") != nil,
    NSClassFromString("CGVirtualDisplaySettings") != nil
else {
    die("""
    the private CGVirtualDisplay API this tool depends on doesn't appear \
    to be available on this macOS version. This is undocumented, \
    unsupported API — Apple can change or remove it at any time, and \
    there is no fallback if it's gone.
    """)
}

// ---- Pre-flight checks ----

// A compile-time `#if arch(x86_64)` check here would test the architecture
// this binary was built for, not the actual host CPU — an x86_64 slice
// running under Rosetta on real Apple Silicon would wrongly hit this guard
// (telling a machine that genuinely needs keepawake to go use `pmset`
// instead, which wouldn't work there). Check the real hardware at runtime:
// a native arm64 build is always Apple Silicon, and for an x86_64 build,
// `sysctl.proc_translated` distinguishes "running under Rosetta on Apple
// Silicon" (exists, reads 1) from "genuinely running on Intel" (the sysctl
// doesn't exist at all pre-Apple-Silicon).
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
    (macOS Ventura+) — on Intel, `sudo pmset -a disablesleep 1` already \
    prevents clamshell sleep without any of this (confirmed by testing). \
    Note that plain `caffeinate` does NOT: it only blocks idle/display \
    sleep, never lid-closed sleep, on any Mac. --force will let you run \
    this anyway, but on the one Intel Mac this has actually been tested on, \
    the virtual display never registered at any size — `pmset` is very \
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
    warn("""
    running on battery power. Closing the lid for extended periods on \
    battery bypasses the thermal/battery protections clamshell sleep \
    normally provides (e.g. in an enclosed bag). Re-run with --force to \
    suppress this warning, or plug in first.
    """)
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
    // Always shown, not just when Sidecar is connected right now: the
    // virtual display always sits adjacent to the real one (attempts to
    // park it elsewhere via CGConfigureDisplayOrigin were confirmed not to
    // work — see RESEARCH.md), so the cursor can always reach its corner.
    // Whether that then routes onto a nearby Mac depends on Universal
    // Control being enabled, which isn't reliably detectable from here —
    // so this warns unconditionally rather than under-warning.
    warn("""
    your cursor can reach this tool's virtual display by crossing the \
    bottom-right corner of your screen (no working way to prevent this \
    has been found). If Universal Control is enabled, this has been \
    observed to route the cursor onward onto a nearby Mac/iPad — disable \
    Universal Control if you want to rule that out. Re-run with --force \
    to suppress this warning.
    """)
    let displayTypes = connectedDisplayTypeLines()
    if displayTypes.contains(where: { $0.contains("Sidecar") }) {
        warn("a Sidecar display is currently connected, which increases the chance of the above actually happening.")
    }
}

// ---- Determine sizing and create the virtual display ----
//
// CGVirtualDisplay appears to enforce a hard cap on total pixels (an
// unaccelerated software framebuffer limit, not a real GPU output) — found
// empirically at ~1,654,400 pixels, but only tested on one machine (see the
// "Device support" note in RESEARCH.md). Rather than trust that number
// blindly on hardware/macOS versions it's never been checked against, start
// there and halve down if `apply()` actually rejects it.
//
// NOTE: an `NSScreen.screens.count` check was tried here as an extra
// verification (RESEARCH.md documents `apply()` once reporting success
// without the display actually registering), but proved unreliable: checked
// from within the same process that calls `apply()`, `NSScreen.screens`
// never updated even after a multi-second wait, in this bare-script
// (non-`NSApplication`) execution context — even though the display had, in
// fact, registered at the OS level the whole time (confirmed externally via
// `system_profiler` from a separate process). `apply()`'s own return value
// is the only in-process signal that's actually reliable here.

guard let mainScreen = NSScreen.main else {
    die("couldn't read the main display's resolution")
}
let pointSize = mainScreen.frame.size
let requestedPixels = Double(pointSize.width) * Double(pointSize.height)
let startingPixelCap = 1_654_400.0
let minPixels = 4.0 // 2x2 — the smallest size confirmed to register as a real screen.

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
    behave differently, on this macOS version or device — this is \
    undocumented, unsupported API with no further fallback. If you can, \
    please report this (device model + macOS version) so RESEARCH.md's \
    device-support notes can be updated.
    """)
}

// No attempt is made to reposition the display: CGConfigureDisplayOrigin is
// confirmed non-functional for a CGVirtualDisplay-backed display (WindowServer
// silently discards the requested origin — see RESEARCH.md), so that code was
// removed rather than kept as a no-op that looked like a working mitigation.
// In practice WindowServer's default placement already tucks it into a
// screen corner adjacent to the real display, which is an acceptable resting
// spot on its own — see the cursor-drift warning below for the residual risk.

// ---- Internal caffeinate: hold the same sleep assertions caffeinate would ----
//
// The virtual display above only defeats the hardware-enforced clamshell
// check — it does nothing about ordinary idle/display/disk sleep, which is
// governed separately via IOPMAssertion. Rather than reimplement that in
// Swift, shell out to the system's own `caffeinate` and tie its lifetime to
// ours via `-w <our pid>`: however we exit — clean signal, --duration,
// thermal bailout, or even a `kill -9` that bypasses every handler below —
// caffeinate notices we're gone and releases its assertions on its own, with
// no explicit cleanup required on our end for that path. The explicit
// `teardown()` below (called on every normal exit path) is just to make
// cleanup prompt rather than waiting on caffeinate's own polling interval.

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
        print("\(toolName): wrapped command exited (status \(finished.terminationStatus)), stopping")
        teardown()
        exit(finished.terminationStatus)
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
print("\(toolName): running (virtual display \(Int(targetWidth))x\(Int(targetHeight)), caffeinate -\(caffeinateFlags), \(statusSuffix))")
fflush(stdout)

// ---- Thermal safety net ----
// Release the hold voluntarily under sustained critical thermal pressure,
// rather than relying solely on the hardware/firmware emergency path.
NotificationCenter.default.addObserver(
    forName: ProcessInfo.thermalStateDidChangeNotification,
    object: nil, queue: .main
) { _ in
    if ProcessInfo.processInfo.thermalState == .critical {
        FileHandle.standardError.write(
            "\(toolName): thermal state critical — releasing the sleep hold\n".data(using: .utf8)!)
        teardown()
        exit(0)
    }
}

// ---- Clean shutdown on Ctrl-C / termination ----
//
// A DispatchSource-based handler was tried first but never fired here —
// this script drives its run loop with bare CFRunLoopRun(), which doesn't
// reliably pump the main GCD queue the way an app-framework run loop does.
// A plain C signal handler doesn't depend on that integration.

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

// -w waits on a process we didn't spawn (no terminationHandler available for
// a non-child pid) — poll for it instead.
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
