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
desc.name = "Keepawake Phantom Display"
desc.maxPixelsWide = 1920
desc.maxPixelsHigh = 1080
desc.sizeInMillimeters = CGSize(width: 1800, height: 1012.5)
desc.productID = 0x1234
desc.vendorID = 0x3456
desc.serialNum = 0x0001

let display = CGVirtualDisplay(descriptor: desc)

let settings = CGVirtualDisplaySettings()
settings.hiDPI = 0
settings.modes = [
    CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60),
]

let applied = display.applySettings(settings)
print("applySettings succeeded: \(applied)")
print("Virtual display created. CGDirectDisplayID = \(display.displayID)")
print("Active display count now: \(NSScreen.screens.count)")
print("Holding display open — Ctrl-C to release it.")

// Keep the process (and the dispatch queue backing the display) alive.
CFRunLoopRun()
