import Foundation

public struct LidGoPaths: Sendable {
    public let applicationSupport: URL
    public let configFile: URL
    public let stateFile: URL
    public let stateLock: URL
    public let agentLog: URL
    public let launchAgentPlist: URL
    public let globalParticipationLock: URL

    public init(
        applicationSupport: URL,
        launchAgentPlist: URL,
        globalParticipationLock: URL
    ) {
        self.applicationSupport = applicationSupport
        configFile = applicationSupport.appendingPathComponent("config.json")
        stateFile = applicationSupport.appendingPathComponent("state.json")
        stateLock = applicationSupport.appendingPathComponent("state.lock")
        agentLog = applicationSupport.appendingPathComponent("agent.log")
        self.launchAgentPlist = launchAgentPlist
        self.globalParticipationLock = globalParticipationLock
    }

    public static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LidGoPaths {
        if environment["LIDGO_TESTING"] == "1", let override = environment["LIDGO_HOME"] {
            return testing(root: URL(fileURLWithPath: override, isDirectory: true))
        }

        let support = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("MacLidAwake", isDirectory: true)
        let plist = home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.maclidawake.lidgo.agent.plist")
        return LidGoPaths(
            applicationSupport: support,
            launchAgentPlist: plist,
            globalParticipationLock: URL(fileURLWithPath: "/var/db/maclidawake.lock")
        )
    }

    public static func testing(root: URL) -> LidGoPaths {
        LidGoPaths(
            applicationSupport: root,
            launchAgentPlist: root.appendingPathComponent("com.maclidawake.lidgo.agent.plist"),
            globalParticipationLock: root.appendingPathComponent("maclidawake.global.lock")
        )
    }
}
