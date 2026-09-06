import Darwin
import Foundation
import LidGoCore

struct RecordedCommand: Equatable {
    let executable: String
    let arguments: [String]
}

final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedCommand] = []
    var result = CommandResult(status: 0, output: "")

    var commands: [RecordedCommand] {
        lock.withLock { storage }
    }

    func run(executable: String, arguments: [String]) -> CommandResult {
        lock.withLock {
            storage.append(RecordedCommand(executable: executable, arguments: arguments))
            return result
        }
    }

    func setResult(_ result: CommandResult) {
        lock.withLock { self.result = result }
    }
}

@MainActor
final class PowerControllerTests {
    private var root: URL!

    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidgo-power-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testUsesOnlyExactWhitelistedCommandsAndDeduplicatesTargets() throws {
        let lockPath = makeLockFile()
        let runner = RecordingCommandRunner()
        let controller = try GlobalPowerController(lockPath: lockPath, runner: runner)

        try controller.setAwake(true)
        try controller.setAwake(true)
        try controller.setAwake(false)
        try controller.setAwake(false)

        XCTAssertEqual(runner.commands, [
            RecordedCommand(
                executable: "/usr/bin/sudo",
                arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]
            ),
            RecordedCommand(
                executable: "/usr/bin/sudo",
                arguments: ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]
            ),
        ])
    }

    func testOnlyLastParticipantClearsGlobalHold() throws {
        let lockPath = makeLockFile()
        let runnerA = RecordingCommandRunner()
        let runnerB = RecordingCommandRunner()
        let controllerA = try GlobalPowerController(lockPath: lockPath, runner: runnerA)
        let controllerB = try GlobalPowerController(lockPath: lockPath, runner: runnerB)

        try controllerA.setAwake(true)
        try controllerB.setAwake(true)
        try controllerA.setAwake(false)
        XCTAssertFalse(runnerA.commands.contains { $0.arguments.last == "0" })
        try controllerB.setAwake(false)
        XCTAssertTrue(runnerB.commands.contains { $0.arguments.last == "0" })
    }

    func testMissingOrSymlinkedGlobalLockIsRejected() throws {
        let missing = root.appendingPathComponent("missing.lock")
        XCTAssertThrowsError(try GlobalPowerController(lockPath: missing, runner: RecordingCommandRunner()))

        let real = makeLockFile(name: "real.lock")
        let linked = root.appendingPathComponent("linked.lock")
        XCTAssertEqual(symlink(real.path, linked.path), 0)
        XCTAssertThrowsError(try GlobalPowerController(lockPath: linked, runner: RecordingCommandRunner()))
    }

    func testFailedCommandDoesNotPoisonRetryState() throws {
        let runner = RecordingCommandRunner()
        runner.setResult(CommandResult(status: 1, output: "denied"))
        let controller = try GlobalPowerController(lockPath: makeLockFile(), runner: runner)
        XCTAssertThrowsError(try controller.setAwake(true))

        runner.setResult(CommandResult(status: 0, output: ""))
        try controller.setAwake(true)
        XCTAssertEqual(runner.commands.count, 2)
        XCTAssertEqual(runner.commands.last?.arguments.last, "1")
    }

    private func makeLockFile(name: String = "global.lock") -> URL {
        let url = root.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        return url
    }
}
