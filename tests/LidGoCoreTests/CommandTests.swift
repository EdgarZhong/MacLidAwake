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
        ]
        for arguments in invalidArguments {
            XCTAssertThrowsError(try LidGoCommand.parse(arguments), "应拒绝 \(arguments)")
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
        XCTAssertTrue(output.contains("LidGo 已开启"))
        XCTAssertTrue(output.contains("Timer：剩余 60 分钟"))
        XCTAssertTrue(output.contains("Hold：2 个终端会话正在维持"))
    }

    func testHelpContainsOnlyPublicSurface() {
        let help = StatusFormatter.help
        for expected in ["lidgo --hold", "lidgo -r, --refresh", "lidgo switch -f", "lidgo config", "lidgo setup"] {
            XCTAssertTrue(help.contains(expected), "帮助缺少 \(expected)")
        }
        for forbidden in [" status", " on", " off", " security", " install", " uninstall", "--release", "-t ", "-w ", "caffeinate"] {
            XCTAssertFalse(help.contains(forbidden), "帮助不应包含 \(forbidden)")
        }
    }
}
