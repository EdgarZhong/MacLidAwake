// keepawake: prevent clamshell sleep with no external hardware, by holding open
// a software-only virtual display via the private CGVirtualDisplay API.
// See the project README for why this works, and experiments/phantom-display
// for the original proof of concept.

import Cocoa
import CoreGraphics
import IOKit
import IOKit.ps

let toolName = "keepawake"
// Keep in sync with the git tag and the Homebrew formula's url/sha256.
let toolVersion = "0.2.1"

// How aggressively to release the sleep hold under thermal pressure. Only ever
// acts while the lid is closed (see the thermal safety net below); with the lid
// open, thermal management is the OS's job. `.serious` fires eagerly and is
// opt-in via --thermal; `.critical` is the default backstop; `.none` disables it.
enum ThermalCutoff: String { case none, serious, critical }

func printUsage() {
    print("""
    Usage: \(toolName) [-disu] [-t seconds] [-w pid] [command [arg ...]]

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
      --thermal <level>          When to release the hold under thermal
                                  pressure, one of: none, serious, critical.
                                  Default: critical. Only acts while the lid is
                                  closed; with the lid open, thermal management
                                  is left to the OS. `serious` fires eagerly
                                  (normal heavy CPU/GPU work reaches it), so
                                  it's opt-in.
      --battery <pct>            Release the hold and stop once the battery
                                  falls to this percentage (1-99), or `none`
                                  to disable. Default: 5. Like --thermal, only
                                  acts on battery power with the lid closed;
                                  plugged in, or lid open, it never fires.
      -v, --version              Show the version and exit.
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
var assertDisplay = false
var assertIdle = false
var assertDisk = false
var assertSystem = false
var assertUser = false
var waitPid: pid_t?
var thermalCutoff: ThermalCutoff = .critical
// Percentage at or below which we release the hold, or nil to disable. Low by
// default so it's a backstop against a machine running itself flat in a bag,
// not a nag about being unplugged.
var batteryCutoff: Int? = 5
var commandArgs: [String] = []

let args = Array(CommandLine.arguments.dropFirst())
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

if !isRunningOnAppleSilicon() {
    die("this tool does not work on Intel Macs. Use `sudo pmset -a disablesleep 1` instead.")
}

// Cursor drift onto the phantom (and onward to another Mac, if Universal
// Control is on) is a permanent property of the mechanism rather than anything
// detectable about a given run, so it lives in the README's known-limitations
// section instead of being reprinted on every launch.

// ---- Determine sizing and create the virtual display ----
//
// CGVirtualDisplay silently caps total pixels: an over-cap request doesn't
// fail, `apply()` still returns true and a smaller mode registers instead.
// The limit is undocumented and varies by release (measured ~1.66M on macOS 26,
// ~1.76M on macOS 27), so this sits just under the lowest observed value and
// may become unnecessary in a future release. To re-measure it on a new
// release, bisect the requested size and read back CGDisplayPixelsWide/High;
// the request itself never reports the cap.
//
// Scale down from the main display's *point* size, never up. Matching the real
// display as closely as possible minimizes window reflow when the lid closes
// and the phantom becomes the main display; exceeding it would be far more
// disruptive than falling slightly short, so the point size is a hard ceiling.
// Whether the matching actually reduces reflow is unverified (it needs a
// physical lid close with window frames recorded either side), so if it turns
// out not to matter, this sizing logic can be dropped for a fixed size.
//
// An `NSScreen.screens.count` sanity check was tried and dropped: in this bare
// CFRunLoop (non-NSApplication) context it never updated even when the display
// had registered (confirmed externally via `system_profiler`). `apply()`'s
// return value is the only reliable in-process signal.

// Probably reachable on headless devices, not tested. Fallback should be safe
// either way: the phantom is likely unneeded there, but it's harmless.
let fallbackPointSize = CGSize(width: 1440, height: 900)
let pointSize: CGSize
if let mainScreen = NSScreen.main {
    pointSize = mainScreen.frame.size
} else {
    warn("couldn't read the main display's resolution; using \(Int(fallbackPointSize.width))x\(Int(fallbackPointSize.height)) for the virtual display")
    pointSize = fallbackPointSize
}
let pixelCap = 1_654_400.0
let requestedPixels = Double(pointSize.width) * Double(pointSize.height)
let sizeScale = requestedPixels > pixelCap ? (pixelCap / requestedPixels).squareRoot() : 1.0
let requestedWidth = (Double(pointSize.width) * sizeScale).rounded(.down)
let requestedHeight = (Double(pointSize.height) * sizeScale).rounded(.down)

let desc = CGVirtualDisplayDescriptor()
desc.setDispatchQueue(DispatchQueue.main)
desc.name = "Keepawake Phantom Display"
desc.maxPixelsWide = UInt32(requestedWidth)
desc.maxPixelsHigh = UInt32(requestedHeight)
desc.sizeInMillimeters = CGSize(width: requestedWidth / 10, height: requestedHeight / 10)
// Distinctive identity above 0xFFFF (bytes spell keep/awak/e).
desc.productID = 0x6177616B  // "awak"
desc.vendorID = 0x6B656570   // "keep"
desc.serialNum = 0x00000065  // "e"
desc.terminationHandler = { _, _ in }

let display = CGVirtualDisplay(descriptor: desc)
let settings = CGVirtualDisplaySettings()
settings.hiDPI = 0
settings.modes = [CGVirtualDisplayMode(width: UInt(requestedWidth),
                                       height: UInt(requestedHeight),
                                       refreshRate: 60)]

guard display.apply(settings) else {
    die("""
    failed to create the virtual display. CGVirtualDisplay may be \
    unavailable, or may behave differently, on this macOS version or device. \
    This is undocumented, unsupported API with no further fallback. If you \
    can, please open an issue with your device model and macOS version.
    """)
}

// ---- Park the virtual display out of the way ----
//
// Left alone, WindowServer inserts the phantom mid-arrangement and displaces
// real displays (with two externals attached, it lands between them). Shove it
// to the far-right outer edge instead, bottom-aligned to its neighbor, so the
// real displays keep their positions. macOS keeps arrangements gap-free, so
// CGConfigureDisplayOrigin can't float the phantom off in empty space; it clamps
// the request to a contiguous spot. It does generally honor which outer edge
// the phantom attaches to, which is all we need, but the placement doesn't
// always hold.

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
    // the case both cutoff notifications miss (neither the thermal state nor the
    // battery level changes, only the lid does), so re-check them here too.
    evaluateSafetyCutoffs()
    if display == phantomDisplayID { return }
    DispatchQueue.main.async { parkPhantom() }
}

phantomDisplayID = display.displayID

// Wait for WindowServer to finish settling the phantom's insertion before the
// first park. apply() returns before the arrangement stabilizes, and parking
// mid-insertion computes the neighbor against a transient layout, which
// mis-aligns the result. (The re-park path always runs post-settle, which is
// why a later display change looks correct but the initial placement doesn't.)
// Poll until the layout is stable across two reads, or a short timeout, then
// park against the settled arrangement.
func layoutSignature() -> String {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return "" }
    return ids.map { id -> String in
        let b = CGDisplayBounds(id)
        return "\(id):\(Int(b.origin.x)),\(Int(b.origin.y)),\(Int(b.width)),\(Int(b.height))"
    }.sorted().joined(separator: "|")
}
var previousLayout = ""
for _ in 0..<50 {  // up to ~1s; breaks as soon as the layout stops changing
    let current = layoutSignature()
    if !current.isEmpty, current == previousLayout { break }
    previousLayout = current
    Thread.sleep(forTimeInterval: 0.02)
}

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

// Report what actually registered rather than what was asked for: macOS
// silently downsizes an over-cap request, so the requested size would be a lie
// on any display bigger than the cap. Reads 0 if nothing registered at all
// (observed on Intel, where `apply()` reports success regardless).
let registeredWidth = CGDisplayPixelsWide(display.displayID)
let registeredHeight = CGDisplayPixelsHigh(display.displayID)
let sizeLabel = registeredWidth > 0 && registeredHeight > 0
    ? "virtual display \(registeredWidth)x\(registeredHeight)"
    : "virtual display NOT registered (requested \(Int(requestedWidth))x\(Int(requestedHeight)))"

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
print("\(toolName): running (\(sizeLabel), caffeinate -\(caffeinateFlags), thermal-cutoff \(thermalCutoff.rawValue), battery-cutoff \(batteryLabel), \(statusSuffix))")
fflush(stdout)

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

// ---- Low-battery cutoff (lid-gated, same shape as the thermal one) ----
//
// Keeps an unattended closed machine from running itself flat. macOS force-
// sleeps at critical battery on its own and IOPMAssertion doesn't override
// that, so this is usually redundant. It's here because keepawake already
// defeats one class of hardware-enforced sleep, and whether the phantom display
// also affects low-battery sleep is untested.

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

// Level-triggered like the thermal check: re-decides from current state on
// every call rather than tracking a previous reading.
func evaluateBatteryCutoff() {
    guard let cutoff = batteryCutoff else { return }
    // On AC the charge isn't a countdown, so a low reading means "charging",
    // not "about to die". Nothing to protect against.
    guard !isOnACPower(), let percent = batteryPercent(), percent <= cutoff else { return }
    guard !isLidConfirmedOpen() else { return }
    FileHandle.standardError.write(
        "\(toolName): battery at \(percent)% with lid closed, releasing the sleep hold and exiting\n".data(using: .utf8)!)
    teardown()
    exit(0)
}

// Both nets share the lid-close trigger: closing the lid can satisfy the
// gating condition without the thermal state or battery level itself changing,
// so neither notification alone would catch that ordering.
func evaluateSafetyCutoffs() {
    evaluateThermalCutoff()
    evaluateBatteryCutoff()
}

if thermalCutoff != .none {
    NotificationCenter.default.addObserver(
        forName: ProcessInfo.thermalStateDidChangeNotification,
        object: nil, queue: .main
    ) { _ in evaluateThermalCutoff() }
    evaluateThermalCutoff()  // in case we launched already hot with the lid shut
}

if batteryCutoff != nil {
    // Event-driven, not polled. IOPSNotificationCreateRunLoopSource delivers a
    // callback whenever percent-or-time remaining changes, and it's a
    // CFRunLoopSource, which suits this process exactly: it drives a bare
    // CFRunLoopRun() and so can schedule the source directly, with no
    // dependency on the main GCD queue being pumped.
    let batteryCallback: IOPowerSourceCallbackType = { _ in evaluateBatteryCutoff() }
    if let source = IOPSNotificationCreateRunLoopSource(batteryCallback, nil)?.takeRetainedValue() {
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    } else {
        warn("couldn't register for battery-level notifications; the --battery cutoff is inactive for this run.")
        batteryCutoff = nil
    }
    evaluateBatteryCutoff()  // in case we launched already low with the lid shut
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
