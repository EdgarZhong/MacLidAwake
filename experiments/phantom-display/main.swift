// Phantom-display experiment.
//
// Creates a software-only virtual display via the private CGVirtualDisplay API
// (the same mechanism BetterDisplay/FreeDisplay use) and holds it open until
// killed. No physical hardware, no kext, no root needed to create the display
// itself.
//
// Purpose: test whether macOS's clamshell-sleep decision (which is made by
// IOPMrootDomain/AppleGraphicsControl at the IOKit/kernel-driver level, based
// on real GPU output/EDID detection) can be satisfied by a display that only
// exists at the CoreGraphics/WindowServer layer, with no corresponding
// IOFramebuffer-backed physical connection.
//
// Usage: run this, confirm the virtual display shows up in System Settings >
// Displays / system_profiler SPDisplaysDataType, then close the lid and check
// `pmset -g log | grep -i clamshell` afterward on wake.

import Cocoa
import CoreGraphics

let desc = CGVirtualDisplayDescriptor()
desc.setDispatchQueue(DispatchQueue.main)
desc.terminationHandler = { a, b in
    NSLog("Virtual display terminated: \(String(describing: a)), \(String(describing: b))")
}
// Sized to match this Mac's real built-in display's logical POINT resolution
// (1728x1117 — what window geometry is actually computed against) so that if
// the built-in deactivates on lid-close and this display briefly becomes
// Main, window frames map 1:1 instead of squeezing into a tiny canvas and
// back. Requesting this directly as a 1x mode (skipping hiDPI, which got
// silently overridden down to a smaller capped mode when tried at 2x/3456px
// — CGVirtualDisplay appears to enforce a max total-pixel-count limit) lands
// safely under that cap while still matching points exactly.
desc.name = "Keepawake Phantom Display"
desc.maxPixelsWide = 1728
desc.maxPixelsHigh = 1117
desc.sizeInMillimeters = CGSize(width: 344, height: 222)
desc.productID = 0x1234
desc.vendorID = 0x3456
desc.serialNum = 0x0001

let display = CGVirtualDisplay(descriptor: desc)

let settings = CGVirtualDisplaySettings()
settings.hiDPI = 0
settings.modes = [
    CGVirtualDisplayMode(width: 1728, height: 1117, refreshRate: 60),
]

let applied = display.apply(settings)
print("applySettings succeeded: \(applied)")
print("Virtual display created. CGDirectDisplayID = \(display.displayID)")
print("Active display count now: \(NSScreen.screens.count)")
fflush(stdout)

// Park the display far outside the main display's bounds so its arrangement
// rectangle never touches the main display's — this prevents the cursor
// (and accidental window drags) from ever crossing onto it, without relying
// on any global system preference.
let mainBounds = CGDisplayBounds(CGMainDisplayID())
let parkOrigin = CGPoint(x: mainBounds.maxX + 5000, y: mainBounds.origin.y + 5000)
var config: CGDisplayConfigRef?
if CGBeginDisplayConfiguration(&config) == .success, let config = config {
    CGConfigureDisplayOrigin(config, display.displayID, Int32(parkOrigin.x), Int32(parkOrigin.y))
    let result = CGCompleteDisplayConfiguration(config, .permanently)
    print("Repositioned display to \(parkOrigin): \(result == .success ? "ok" : "failed (\(result))")")
} else {
    print("Failed to begin display configuration")
}
print("Holding display open — Ctrl-C to release it.")
fflush(stdout)

// Keep the process (and the dispatch queue backing the display) alive.
CFRunLoopRun()
