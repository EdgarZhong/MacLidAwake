import Darwin
import Foundation
import LidGoCore

@MainActor
final class SetupManagerTests {
    private var root: URL!
    private var paths: LidGoPaths!

    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidgo-setup-tests-\(UUID().uuidString)", isDirectory: true)
        paths = .testing(root: root)
    }

    func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testSudoersRuleHasExactlyTwoLiteralPmsetCommands() {
        let rule = SetupManager.sudoersRuleText
        XCTAssertTrue(rule.contains("/usr/bin/pmset -a disablesleep 1"))
        XCTAssertTrue(rule.contains("/usr/bin/pmset -a disablesleep 0"))
        XCTAssertEqual(rule.components(separatedBy: "/usr/bin/pmset").count - 1, 2)
        XCTAssertFalse(rule.contains("*"))
        XCTAssertFalse(rule.contains("ALL, ALL"))
    }

    func testRootSetupPlanValidatesBeforeInstalling() {
        let commands = SetupManager.rootSetupCommands(
            temporaryRule: URL(fileURLWithPath: "/tmp/lidgo.rule"),
            temporaryLock: URL(fileURLWithPath: "/tmp/lidgo.lock"),
            sudoersRule: URL(fileURLWithPath: "/etc/sudoers.d/maclidawake"),
            globalLock: URL(fileURLWithPath: "/var/db/maclidawake.lock")
        )
        XCTAssertEqual(commands.map(\.executable), [
            "/usr/sbin/visudo", "/usr/bin/install", "/usr/bin/install",
        ])
        XCTAssertEqual(commands[0].arguments, ["-cf", "/tmp/lidgo.rule"])
        XCTAssertEqual(commands[1].arguments, [
            "-m", "0660", "-o", "root", "-g", "admin",
            "/tmp/lidgo.lock", "/var/db/maclidawake.lock",
        ])
        XCTAssertEqual(commands[2].arguments, [
            "-m", "0440", "-o", "root", "-g", "wheel",
            "/tmp/lidgo.rule", "/etc/sudoers.d/maclidawake",
        ])
    }

    func testGeneratedRulePassesRealVisudoAndGarbageFails() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = root.appendingPathComponent("valid.sudoers")
        let invalid = root.appendingPathComponent("invalid.sudoers")
        try SetupManager.sudoersRuleText.write(to: valid, atomically: true, encoding: .utf8)
        try "this is not valid sudoers\n".write(to: invalid, atomically: true, encoding: .utf8)

        let runner = ProcessCommandRunner()
        let validResult = runner.run(executable: "/usr/sbin/visudo", arguments: ["-cf", valid.path])
        let invalidResult = runner.run(executable: "/usr/sbin/visudo", arguments: ["-cf", invalid.path])
        XCTAssertEqual(validResult.status, 0, validResult.output)
        XCTAssertFalse(invalidResult.status == 0, "visudo 不应接受损坏规则")
    }

    func testLaunchAgentPlistUsesExpectedLabelAndInternalAgent() throws {
        let manager = SetupManager(
            paths: paths,
            executablePath: "/opt/homebrew/bin/lidgo",
            isTesting: true
        )
        let data = try manager.launchAgentPlistData()
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = object as! [String: Any]
        XCTAssertEqual(plist["Label"] as? String, "com.maclidawake.lidgo.agent")
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/opt/homebrew/bin/lidgo", "__agent"]
        )
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
    }

    func testTestingSetupIsIdempotentAndNonRootHelperRefuses() throws {
        let manager = SetupManager(paths: paths, executablePath: "/tmp/lidgo", isTesting: true)
        try manager.setup()
        let firstPlist = try Data(contentsOf: paths.launchAgentPlist)
        try manager.setup()
        let secondPlist = try Data(contentsOf: paths.launchAgentPlist)
        XCTAssertEqual(secondPlist, firstPlist)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.globalParticipationLock.path))
        XCTAssertEqual(fileMode(paths.applicationSupport), 0o700)

        let productionSemantics = SetupManager(
            paths: paths,
            executablePath: "/tmp/lidgo",
            isTesting: false
        )
        if geteuid() != 0 {
            XCTAssertThrowsError(try productionSemantics.rootSetup())
        }
    }

    func testTestingSetupRejectsSymlinkedGlobalLockWithoutChangingTarget() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("lock-target")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        XCTAssertEqual(symlink(target.path, paths.globalParticipationLock.path), 0)

        let manager = SetupManager(paths: paths, executablePath: "/tmp/lidgo", isTesting: true)
        XCTAssertThrowsError(try manager.setup())
        XCTAssertEqual(fileMode(target), 0o600)
    }

    private func fileMode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(stat(url.path, &info), 0)
        return info.st_mode & 0o777
    }
}
