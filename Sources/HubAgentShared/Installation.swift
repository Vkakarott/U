import Foundation

/// Which copy of hub-agent a process belongs to.
///
/// The copy in daily use and the one being developed never share anything: each has
/// its own daemon, socket, data folder and launchd name, so testing hub-agent cannot
/// reach the terminals someone is working in.
public enum InstallationKind: String, Codable, Sendable, CaseIterable {
    case production
    case development
}

/// Every name and location that differs between the two copies.
public struct Installation: Sendable, Equatable {
    /// Selects the copy explicitly, overriding what the process would infer.
    public static let environmentVariable = "HUBAGENT_ENVIRONMENT"
    public static let productionBundleIdentifier = "com.hubagent.app"

    public var kind: InstallationKind
    public var homeDirectory: String

    public init(kind: InstallationKind, homeDirectory: String = NSHomeDirectory()) {
        self.kind = kind
        self.homeDirectory = homeDirectory
    }

    /// The name the daemon is registered under in launchd.
    public var launchdLabel: String {
        kind == .production ? "com.hubagent.daemon" : "com.hubagent.daemon.dev"
    }

    public var supportDirectory: String {
        let name = kind == .production ? "HubAgent" : "HubAgent-Dev"
        return homeDirectory + "/Library/Application Support/" + name
    }

    public var socketPath: String { supportDirectory + "/daemon.sock" }
    /// Held by the running daemon so that a second one refuses to start.
    public var lockPath: String { supportDirectory + "/daemon.lock" }
    public var daemonLogPath: String { supportDirectory + "/daemon.log" }
    public var projectsFilePath: String { supportDirectory + "/projects.json" }
    public var launchAgentPath: String { homeDirectory + "/Library/LaunchAgents/" + launchdLabel + ".plist" }

    /// The copy a process belongs to: an explicit choice wins, then the packaged app's
    /// identity. Anything else (running from the source tree) is development, so a
    /// stray process can never reach the daily-use daemon by accident.
    public static func kind(environment: [String: String], bundleIdentifier: String?) -> InstallationKind {
        if let chosen = environment[environmentVariable].flatMap(InstallationKind.init(rawValue:)) { return chosen }
        return bundleIdentifier == productionBundleIdentifier ? .production : .development
    }
}

/// Version of the hub-agent build. The daemon reports it when a client connects, and
/// the app compares it with its own to notice a daemon left over from an older build.
public enum HubAgentVersion {
    public static let current = "0.3.0"
}
