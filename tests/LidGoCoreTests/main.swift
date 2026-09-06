import Foundation

@MainActor
func runStateStoreTest(
    _ runner: TestRunner,
    _ name: String,
    _ body: @escaping (StateStoreTests) throws -> Void
) {
    runner.run(name) {
        let tests = StateStoreTests()
        try tests.setUpWithError()
        defer { try? tests.tearDownWithError() }
        try body(tests)
    }
}

let runner = TestRunner()
let duration = DurationParserTests()
runner.run("duration parses supported forms", duration.testParsesSupportedDurationForms)
runner.run("duration rejects invalid forms", duration.testRejectsMalformedOrNonPositiveDurations)
runner.run("config validates safety bounds", duration.testConfigValidationAcceptsDefaultsAndRejectsUnsafeValues)

let lease = LeaseCoordinatorTests()
runner.run("default timer is idempotent", lease.testDefaultCreatesTimerThenRemainsIdempotent)
runner.run("refresh only changes pure timer", lease.testRefreshCreatesOrRefreshesOnlyPureTimerState)
runner.run("timer and multiple holds compose", lease.testTimerAndMultipleHoldsComposeAndReleaseIndependently)
runner.run("expired timer preserves live hold", lease.testExpiredTimerDoesNotRemoveLiveHold)
runner.run("invalid processes lose holds", lease.testStoppedZombieDeadAndReusedPIDsAreRemoved)
runner.run("force and safety revoke generations", lease.testForceClearAndSafetyTripRevokeOldHolds)
runner.run("suspended hold resumes conditionally", lease.testSuspendedHoldCanResumeOnlyWithinSameGeneration)

runStateStoreTest(runner, "state persists privately") { try $0.testPersistsConfigAndRuntimeWithPrivatePermissions() }
runStateStoreTest(runner, "state transactions serialize") { try $0.testSerializesConcurrentTransactions() }
runStateStoreTest(runner, "corrupt state recovers fail-safe") { try $0.testCorruptRuntimeIsQuarantinedAndRecoveredAsEmpty() }
runStateStoreTest(runner, "symlinked state directory is rejected") { try $0.testRejectsSymlinkedStateDirectory() }
runner.finish()
