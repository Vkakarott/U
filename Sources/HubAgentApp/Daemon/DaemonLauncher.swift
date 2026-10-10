import Foundation
import HubAgentShared

/// Where an installation's daemon is reached and which program it is.
struct DaemonEndpoint: Equatable, Sendable {
    var installation: Installation
    var socketPath: String
    var executablePath: String

    init(installation: Installation, executablePath: String, socketPath: String? = nil) {
        self.installation = installation
        self.executablePath = executablePath
        self.socketPath = socketPath ?? installation.socketPath
    }

    /// The daemon ships next to the app's own executable, in the source tree's build
    /// folder and inside the packaged app alike.
    static func bundledExecutablePath(appExecutable: URL? = Bundle.main.executableURL) -> String? {
        appExecutable?.deletingLastPathComponent().appendingPathComponent("HubAgentDaemon").path
    }

    /// Arguments that make the daemon serve exactly this endpoint.
    var daemonArguments: [String] {
        var arguments = ["--environment", installation.kind.rawValue]
        if installation.homeDirectory != NSHomeDirectory() { arguments += ["--home", installation.homeDirectory] }
        if socketPath != installation.socketPath { arguments += ["--socket", socketPath] }
        return arguments
    }
}

enum DaemonLaunchError: Error, Equatable {
    case executableNotFound(String)
    case spawnFailed(code: Int32)
    case commandFailed(command: [String], status: Int32, output: String)
}

/// Starts a daemon that outlives the app.
protocol DaemonLauncher: Sendable {
    func launch(_ endpoint: DaemonEndpoint) throws
}

/// Starts the daemon as an ordinary process in a session of its own.
///
/// It is not registered anywhere: nothing guarantees a single instance except the
/// daemon's own lock, and nothing restarts it. launchd (`LaunchdDaemonLauncher`) is
/// the intended mechanism; this one needs no system registration.
struct ProcessDaemonLauncher: DaemonLauncher {
    func launch(_ endpoint: DaemonEndpoint) throws {
        guard FileManager.default.isExecutableFile(atPath: endpoint.executablePath) else {
            throw DaemonLaunchError.executableNotFound(endpoint.executablePath)
        }
        let processId = try Self.spawnDetached(
            executable: endpoint.executablePath, arguments: endpoint.daemonArguments)
        // The daemon is our child until we exit; collect it if it ends first.
        Thread.detachNewThread {
            var status: Int32 = 0
            waitpid(processId, &status, 0)
        }
    }

    /// Spawns with a new session, no inherited descriptors and `/` as its folder, so
    /// nothing ties the daemon to the app: not its terminal, files or current folder.
    private static func spawnDetached(executable: String, arguments: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        posix_spawn_file_actions_addchdir(&actions, "/")

        var processId: pid_t = 0
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = daemonEnvironment().map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + environment { free(pointer) } }
        let code = posix_spawn(&processId, executable, &actions, &attributes, argv, environment)
        guard code == 0 else { throw DaemonLaunchError.spawnFailed(code: code) }
        return processId
    }

    /// The copy is chosen by argument; the variable would only contradict it.
    private static func daemonEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { $0.key != Installation.environmentVariable }
    }
}
