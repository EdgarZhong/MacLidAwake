import Darwin
import Foundation

@MainActor
final class TestRecorder {
    static let shared = TestRecorder()
    private(set) var assertionFailures: [String] = []

    func record(_ message: String, file: StaticString, line: UInt) {
        assertionFailures.append("\(file):\(line): \(message)")
    }
}

@MainActor
func XCTAssertTrue(
    _ expression: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard expression() else {
        TestRecorder.shared.record(message.isEmpty ? "Expected true" : message, file: file, line: line)
        return
    }
}

@MainActor
func XCTAssertFalse(
    _ expression: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(!expression(), message.isEmpty ? "Expected false" : message, file: file, line: line)
}

@MainActor
func XCTAssertEqual<T: Equatable>(
    _ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    let actualValue = try actual()
    let expectedValue = try expected()
    guard actualValue == expectedValue else {
        let detail = message.isEmpty ? "Expected \(expectedValue), got \(actualValue)" : message
        TestRecorder.shared.record(detail, file: file, line: line)
        return
    }
}

@MainActor
func XCTAssertNil<T>(
    _ value: @autoclosure () -> T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard value() == nil else {
        TestRecorder.shared.record(message.isEmpty ? "Expected nil" : message, file: file, line: line)
        return
    }
}

@MainActor
func XCTAssertNotNil<T>(
    _ value: @autoclosure () -> T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard value() != nil else {
        TestRecorder.shared.record(message.isEmpty ? "Expected non-nil" : message, file: file, line: line)
        return
    }
}

@MainActor
func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        _ = try expression()
        TestRecorder.shared.record(message.isEmpty ? "Expected an error to be thrown" : message, file: file, line: line)
    } catch {
        return
    }
}

@MainActor
func XCTFail(
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Void {
    TestRecorder.shared.record(message, file: file, line: line)
}

@MainActor
func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    } while Date() < deadline
    return condition()
}

@MainActor
final class TestRunner {
    private var testFailures = 0
    private var testPasses = 0

    func run(_ name: String, _ body: () throws -> Void) {
        let before = TestRecorder.shared.assertionFailures.count
        do {
            try body()
        } catch {
            TestRecorder.shared.record("Uncaught error: \(error)", file: #filePath, line: #line)
        }
        let failures = Array(TestRecorder.shared.assertionFailures.dropFirst(before))
        if failures.isEmpty {
            testPasses += 1
            print("PASS \(name)")
        } else {
            testFailures += 1
            print("FAIL \(name)")
            failures.forEach { print("  \($0)") }
        }
    }

    func finish() -> Never {
        print("SUMMARY \(testPasses) passed, \(testFailures) failed")
        exit(testFailures == 0 ? 0 : 1)
    }
}
