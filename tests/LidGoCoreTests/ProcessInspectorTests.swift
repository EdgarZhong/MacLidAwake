import Darwin
import Foundation
import LidGoCore

@MainActor
final class ProcessInspectorTests {
    func testReadsCurrentProcessIdentity() {
        let inspector = DarwinProcessInspector()
        let snapshot = inspector.snapshot(pid: getpid())
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.pid, getpid())
        XCTAssertTrue((snapshot?.startTime ?? 0) > 0)
        XCTAssertTrue(snapshot?.status.canOwnHold == true)
    }

    func testDetectsStoppedAndDeadChild() throws {
        let inspector = DarwinProcessInspector()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        defer {
            _ = kill(pid, SIGCONT)
            _ = kill(pid, SIGTERM)
            child.waitUntilExit()
        }

        XCTAssertTrue(inspector.snapshot(pid: pid)?.status.canOwnHold == true)
        XCTAssertEqual(kill(pid, SIGSTOP), 0)
        XCTAssertTrue(waitUntil(timeout: 2) { inspector.snapshot(pid: pid)?.status == .stopped })
        XCTAssertEqual(kill(pid, SIGCONT), 0)
        XCTAssertEqual(kill(pid, SIGTERM), 0)
        child.waitUntilExit()
        XCTAssertNil(inspector.snapshot(pid: pid))
    }
}
