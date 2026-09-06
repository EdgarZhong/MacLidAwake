import Darwin
import Foundation
import LidGoCore

@MainActor
final class StateStoreTests {
    private var root: URL!
    private var paths: LidGoPaths!

    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidgo-state-tests-\(UUID().uuidString)", isDirectory: true)
        paths = LidGoPaths.testing(root: root)
    }

    func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testPersistsConfigAndRuntimeWithPrivatePermissions() throws {
        let store = StateStore(paths: paths)
        try store.withLock { state, config in
            state.generation = 9
            config.defaultDurationSeconds = 7_200
        }

        let snapshot = try store.withLock { state, config in (state, config) }
        XCTAssertEqual(snapshot.0.generation, 9)
        XCTAssertEqual(snapshot.1.defaultDurationSeconds, 7_200)
        XCTAssertEqual(fileMode(paths.stateFile), 0o600)
        XCTAssertEqual(fileMode(paths.configFile), 0o600)
        XCTAssertEqual(fileMode(paths.stateLock), 0o600)
        XCTAssertEqual(fileMode(root), 0o700)
    }

    func testSerializesConcurrentTransactions() throws {
        let store = StateStore(paths: paths)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            try! store.withLock { state, _ in
                state.generation += 1
            }
        }

        let generation = try store.withLock { state, _ in state.generation }
        XCTAssertEqual(generation, 50)
    }

    func testCorruptRuntimeIsQuarantinedAndRecoveredAsEmpty() throws {
        let store = StateStore(paths: paths)
        try store.withLock { _, _ in }
        try Data("not-json".utf8).write(to: paths.stateFile)

        let recovered = try store.withLock { state, _ in state }

        XCTAssertEqual(recovered, RuntimeState())
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("state.corrupt-") && $0.hasSuffix(".json") })
    }

    func testRejectsSymlinkedStateDirectory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidgo-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        let realDirectory = parent.appendingPathComponent("real", isDirectory: true)
        let linkedDirectory = parent.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(symlink(realDirectory.path, linkedDirectory.path), 0)
        defer { try? FileManager.default.removeItem(at: parent) }

        let store = StateStore(paths: .testing(root: linkedDirectory))
        XCTAssertThrowsError(try store.withLock { _, _ in })
    }

    private func fileMode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(stat(url.path, &info), 0)
        return info.st_mode & 0o777
    }
}
