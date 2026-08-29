// Test helper: dumps structured JSON info about every currently active
// NSScreen, for use by run_tests.sh. Not part of the shipped tool.
import Cocoa

var entries: [[String: Any]] = []
for screen in NSScreen.screens {
    var entry: [String: Any] = [
        "name": screen.localizedName,
        "frameX": screen.frame.origin.x,
        "frameY": screen.frame.origin.y,
        "frameW": screen.frame.size.width,
        "frameH": screen.frame.size.height,
        "backingScaleFactor": screen.backingScaleFactor,
        "isMain": screen == NSScreen.main,
    ]
    if let desc = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
        entry["displayID"] = desc.uint32Value
    }
    entries.append(entry)
}

let data = try! JSONSerialization.data(withJSONObject: entries, options: [])
print(String(data: data, encoding: .utf8)!)
