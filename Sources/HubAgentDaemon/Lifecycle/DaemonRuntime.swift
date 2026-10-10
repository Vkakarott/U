import Foundation
import HubAgentShared
import os

enum DaemonStartError: Error, Equatable {
    /// Another daemon already serves this installation.
    case alreadyRunning
    case cannotCreateDirectory(String)
}

/// A running daemon: its sessions, its server and the way it stops.
final class DaemonRuntime: @unchecked Sendable {
    let options: DaemonOptions
    let queue: DispatchQueue
    let manager: SessionManager
    let server: ProtocolServer
    private let sessionConfiguration: SessionConfiguration
    private var instanceLock: InstanceLock?
    private var isStopping = false
    private let logger = Logger(subsystem: "com.hubagent.daemon", category: "lifecycle")

    init(
        options: DaemonOptions, queue: DispatchQueue = DispatchQueue(label: "com.hubagent.daemon"),
        sessionConfiguration: SessionConfiguration = SessionConfiguration(),
        launcher: ShellLauncher = LoginShellLauncher()
    ) {
        self.options = options
        self.queue = queue
        self.sessionConfiguration = sessionConfiguration
        manager = SessionManager(queue: queue, configuration: sessionConfiguration, launcher: launcher)
        var configuration = ServerConfiguration()
        configuration.installation = options.installation?.kind
        server = ProtocolServer(
            socketPath: options.socketPath, queue: queue, manager: manager, configuration: configuration)
    }

    /// Takes the installation's lock and starts listening. Call before the queue is in use.
    func start(onStopped: @escaping @Sendable () -> Void) throws {
        try prepareDirectory()
        guard let lock = InstanceLock(path: options.lockPath) else { throw DaemonStartError.alreadyRunning }
        instanceLock = lock
        server.onShutdownRequest = { [weak self] in self?.stop(then: onStopped) }
        try queue.sync { try server.start() }
    }

    /// Ends every terminal and calls `completion` once they are gone, or once the time
    /// a terminal gets before being killed has passed. Runs on the daemon's queue.
    ///
    /// Clients stay connected until the process exits, so the end of the connection
    /// tells them the daemon is really gone.
    func stop(then completion: @escaping @Sendable () -> Void) {
        guard !isStopping else { return }
        isStopping = true
        logger.notice("stopping; ending \(self.manager.runningSessionCount) terminals")
        server.stopListening()
        manager.terminateAll()
        waitForSessions(until: Date().addingTimeInterval(sessionConfiguration.forceKillDelay + 1), then: completion)
    }

    private func waitForSessions(until deadline: Date, then completion: @escaping @Sendable () -> Void) {
        guard manager.runningSessionCount > 0, Date() < deadline else { return completion() }
        queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.waitForSessions(until: deadline, then: completion)
        }
    }

    /// The installation's folder holds the socket and the user's data: owner only.
    private func prepareDirectory() throws {
        guard let directory = options.installation?.supportDirectory else { return }
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw DaemonStartError.cannotCreateDirectory(directory)
        }
    }
}
