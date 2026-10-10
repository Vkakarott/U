import Foundation
import HubAgentShared

/// Runs a system command and reports how it ended.
protocol CommandRunner: Sendable {
    func run(_ command: [String]) throws -> (status: Int32, output: String)
}

struct ProcessCommandRunner: CommandRunner {
    func run(_ command: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// The launchd description of an installation's daemon.
enum LaunchAgent {
    /// No start at login and no automatic restart: the daemon starts when the app
    /// asks, and a daemon that died took its terminals with it, so restarting it
    /// behind the user's back would only hide that.
    static func propertyList(for endpoint: DaemonEndpoint) -> [String: Any] {
        [
            "Label": endpoint.installation.launchdLabel,
            "ProgramArguments": [endpoint.executablePath] + endpoint.daemonArguments,
            "RunAtLoad": false,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "WorkingDirectory": "/",
            "StandardOutPath": endpoint.installation.daemonLogPath,
            "StandardErrorPath": endpoint.installation.daemonLogPath,
        ]
    }

    static func data(for endpoint: DaemonEndpoint) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: propertyList(for: endpoint), format: .xml, options: 0)
    }
}

/// Registers the daemon as a launchd user agent and asks launchd to start it.
///
/// Not verified against a real launchd: registering a service was not allowed while
/// this was written. The tests cover the file it writes and the commands it issues.
struct LaunchdDaemonLauncher: DaemonLauncher {
    var runner: CommandRunner = ProcessCommandRunner()
    var userId: uid_t = getuid()

    private static let launchctl = "/bin/launchctl"

    func launch(_ endpoint: DaemonEndpoint) throws {
        guard FileManager.default.isExecutableFile(atPath: endpoint.executablePath) else {
            throw DaemonLaunchError.executableNotFound(endpoint.executablePath)
        }
        let label = endpoint.installation.launchdLabel
        if try install(endpoint) {
            // A changed description only takes effect once the old one is unloaded.
            _ = try runner.run([Self.launchctl, "bootout", "gui/\(userId)/\(label)"])
        }
        // Fails when the service is already loaded, which is fine.
        _ = try runner.run([Self.launchctl, "bootstrap", "gui/\(userId)", endpoint.installation.launchAgentPath])
        try runChecked([Self.launchctl, "kickstart", "gui/\(userId)/\(label)"])
    }

    /// Writes the description when it is missing or out of date. Returns whether it changed.
    private func install(_ endpoint: DaemonEndpoint) throws -> Bool {
        let path = endpoint.installation.launchAgentPath
        let data = try LaunchAgent.data(for: endpoint)
        guard FileManager.default.contents(atPath: path) != data else { return false }
        for directory in [(path as NSString).deletingLastPathComponent, endpoint.installation.supportDirectory] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return true
    }

    private func runChecked(_ command: [String]) throws {
        let result = try runner.run(command)
        guard result.status == 0 else {
            throw DaemonLaunchError.commandFailed(command: command, status: result.status, output: result.output)
        }
    }
}
