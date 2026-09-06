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

let processInspector = ProcessInspectorTests()
runner.run("process inspector reads identity", processInspector.testReadsCurrentProcessIdentity)
runner.run("process inspector detects stopped and dead", processInspector.testDetectsStoppedAndDeadChild)

@MainActor
func runPowerTest(_ name: String, _ body: @escaping (PowerControllerTests) throws -> Void) {
    runner.run(name) {
        let tests = PowerControllerTests()
        try tests.setUpWithError()
        defer { try? tests.tearDownWithError() }
        try body(tests)
    }
}
runPowerTest("power uses exact commands", { try $0.testUsesOnlyExactWhitelistedCommandsAndDeduplicatesTargets() })
runPowerTest("power clears only for last participant", { try $0.testOnlyLastParticipantClearsGlobalHold() })
runPowerTest("power rejects unsafe locks", { try $0.testMissingOrSymlinkedGlobalLockIsRejected() })
runPowerTest("power retries failed commands", { try $0.testFailedCommandDoesNotPoisonRetryState() })

let agent = AgentRuntimeTests()
runner.run("agent expires timer but preserves hold", agent.testTimerExpiresWhileLiveHoldRemainsActive)
runner.run("agent rejects stopped and reused owners", agent.testStoppedOrReusedProcessCannotKeepAwake)
runner.run("battery trip latches off", agent.testBatteryTripClearsAllLeasesAndDoesNotAutoResume)
runner.run("thermal trip latches off", agent.testCriticalThermalTripClearsLeasesPermanently)
runner.run("unreadable battery fails safe", agent.testUnreadableBatteryFailsSafeAndLatchesOff)
runner.run("agent fail-safes empty and corrupt state", agent.testEmptyAndCorruptStateFailSafeToSleep)

let command = CommandTests()
runner.run("command parser accepts public contract", command.testParsesEveryPublicCommandAndAlias)
runner.run("command parser rejects expanded surface", command.testRejectsOldOrExpandedInterfaces)
runner.run("status formats timer and hold", command.testStatusFormattingShowsTimerAndHoldTogether)
runner.run("help exposes only public surface", command.testHelpContainsOnlyPublicSurface)

@MainActor
func runSetupTest(_ name: String, _ body: @escaping (SetupManagerTests) throws -> Void) {
    runner.run(name) {
        let tests = SetupManagerTests()
        try tests.setUpWithError()
        defer { try? tests.tearDownWithError() }
        try body(tests)
    }
}
runSetupTest("sudoers scope is exact", { $0.testSudoersRuleHasExactlyTwoLiteralPmsetCommands() })
runSetupTest("root setup validates before install", { $0.testRootSetupPlanValidatesBeforeInstalling() })
runSetupTest("generated sudoers passes real visudo", { try $0.testGeneratedRulePassesRealVisudoAndGarbageFails() })
runSetupTest("launch agent plist is exact", { try $0.testLaunchAgentPlistUsesExpectedLabelAndInternalAgent() })
runSetupTest("testing setup is idempotent", { try $0.testTestingSetupIsIdempotentAndNonRootHelperRefuses() })
runSetupTest("testing setup rejects symlinked lock", { try $0.testTestingSetupRejectsSymlinkedGlobalLockWithoutChangingTarget() })

let hold = HoldSessionTests()
runner.run("hold begins and releases own lease", hold.testBeginAndReleaseOwnLease)
runner.run("hold resumes only when safe and current", hold.testResumeRequiresSameGenerationAndSafeConditions)
runner.finish()
