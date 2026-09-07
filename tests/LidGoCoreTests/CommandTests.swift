import Foundation
import LidGoCore

@MainActor
final class CommandTests {
    func testParsesEveryPublicCommandAndAlias() throws {
        try XCTAssertEqual(try LidGoCommand.parse([]), .activate)
        try XCTAssertEqual(try LidGoCommand.parse(["--hold"]), .hold)
        try XCTAssertEqual(try LidGoCommand.parse(["-r"]), .refresh)
        try XCTAssertEqual(try LidGoCommand.parse(["--refresh"]), .refresh)
        try XCTAssertEqual(try LidGoCommand.parse(["switch"]), .switchNeedsForce)
        try XCTAssertEqual(try LidGoCommand.parse(["switch", "-f"]), .switchForce)
        try XCTAssertEqual(try LidGoCommand.parse(["switch", "--force"]), .switchForce)
        try XCTAssertEqual(try LidGoCommand.parse(["config"]), .config(ConfigUpdate()))
        try XCTAssertEqual(
            try LidGoCommand.parse(["config", "--duration", "1h30m", "--battery", "20"]),
            .config(ConfigUpdate(defaultDurationSeconds: 5_400, batteryCutoffPercent: 20))
        )
        try XCTAssertEqual(
            try LidGoCommand.parse(["config", "--duration", "45"]),
            .config(ConfigUpdate(defaultDurationSeconds: 2_700))
        )
        try XCTAssertEqual(
            try LidGoCommand.parse(["config", "-d", "45", "-b", "20"]),
            .config(ConfigUpdate(defaultDurationSeconds: 2_700, batteryCutoffPercent: 20))
        )
        try XCTAssertEqual(try LidGoCommand.parse(["setup"]), .setup)
        try XCTAssertEqual(try LidGoCommand.parse(["help"]), .help)
        try XCTAssertEqual(try LidGoCommand.parse(["-h"]), .help)
        try XCTAssertEqual(try LidGoCommand.parse(["--help"]), .help)
    }

    func testRejectsOldOrExpandedInterfaces() {
        let invalidArguments = [
            ["status"], ["on"], ["off"], ["start"], ["stop"], ["security"],
            ["install"], ["uninstall"], ["--release"], ["-t", "60"], ["-w", "1"],
            ["-disu"], ["switch", "-x"], ["config", "--battery", "0"],
            ["config", "--battery", "100"], ["config", "--duration", "0m"],
            ["config", "--duration", "1h", "--duration", "2h"],
            ["config", "-d", "1h", "--duration", "2h"],
            ["config", "--duration", "1h", "-d", "2h"],
            ["config", "-b", "10", "--battery", "20"],
            ["config", "--battery", "10", "-b", "20"],
        ]
        for arguments in invalidArguments {
            XCTAssertThrowsError(try LidGoCommand.parse(arguments), "Should reject \(arguments)")
        }
    }

    func testStatusFormattingShowsTimerAndHoldTogether() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let timer = TimerLease(now: now, duration: 3_600, generation: 0)
        let output = StatusFormatter.active(
            LeaseSummary(timer: timer, holdCount: 2),
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertTrue(output.contains("LidGo on"))
        XCTAssertTrue(output.contains("Timer: 60 min remaining"))
        XCTAssertTrue(output.contains("Hold: 2 terminal session(s) holding"))
    }

    func testHelpContainsOnlyPublicSurface() {
        let help = StatusFormatter.help
        for expected in [
            "lidgo --hold", "lidgo -r, --refresh", "lidgo switch -f",
            "lidgo config -d 45", "lidgo config -b 10", "lidgo setup",
        ] {
            XCTAssertTrue(help.contains(expected), "Help is missing \(expected)")
        }
        for forbidden in [" status", " on", " off", " security", " install", " uninstall", "--release", "-t ", "-w ", "caffeinate"] {
            XCTAssertFalse(help.contains(forbidden), "Help must not contain \(forbidden)")
        }
    }
}
