import Foundation
import HubAgentShared
import HubAgentTransport

/// What the app found when it reached for its daemon.
enum DaemonAvailability {
    /// Connected to a daemon of this same build.
    case ready(DaemonClient, WelcomeReply)
    /// Connected and usable, but the daemon is from another build. Replacing it ends
    /// every terminal, so it only happens after the user confirms.
    case outdated(DaemonClient, WelcomeReply)
    /// The running daemon shares no protocol version with this app. Nothing works
    /// until it is replaced, which also needs the user's confirmation.
    case incompatible(RejectedReply)
}

enum DaemonSupervisorError: Error, Equatable {
    /// The daemon on this socket serves the other copy of hub-agent.
    case wrongInstallation(InstallationKind)
    case daemonDidNotStart
    case daemonDidNotStop
}

/// Starts, finds, replaces and stops the daemon on the app's behalf.
///
/// It never replaces or stops a daemon on its own: both end the user's terminals.
final class DaemonSupervisor: Sendable {
    let endpoint: DaemonEndpoint
    private let launcher: DaemonLauncher
    private let expectedVersion: String
    private let startTimeout: TimeInterval
    private let stopTimeout: TimeInterval

    init(
        endpoint: DaemonEndpoint, launcher: DaemonLauncher, expectedVersion: String = HubAgentVersion.current,
        startTimeout: TimeInterval = 10, stopTimeout: TimeInterval = 10
    ) {
        self.endpoint = endpoint
        self.launcher = launcher
        self.expectedVersion = expectedVersion
        self.startTimeout = startTimeout
        self.stopTimeout = stopTimeout
    }

    /// Connects to the daemon, starting it when nothing is listening.
    func connect() throws -> DaemonAvailability {
        if let availability = try connectToRunningDaemon() { return availability }
        try launcher.launch(endpoint)
        let deadline = Date().addingTimeInterval(startTimeout)
        while Date() < deadline {
            if let availability = try connectToRunningDaemon() { return availability }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw DaemonSupervisorError.daemonDidNotStart
    }

    /// Stops the running daemon, ending its terminals, and starts this build's.
    /// Call only after the user confirmed.
    func replaceDaemon() throws -> DaemonAvailability {
        try stopDaemon()
        return try connect()
    }

    /// Asks the daemon to stop and waits until its process is gone. Does nothing when
    /// no daemon is running. Call only after the user confirmed.
    func stopDaemon() throws {
        guard let connection = try? BlockingConnection(path: endpoint.socketPath) else { return }
        try connection.send(ClientMessage.shutdown.encodedFrame())
        let deadline = Date().addingTimeInterval(stopTimeout)
        // The daemon keeps its clients until it exits: the end of this connection is
        // the moment a replacement can take the installation's lock.
        while Date() < deadline {
            do {
                _ = try connection.receive(timeout: max(0.01, deadline.timeIntervalSinceNow))
            } catch SocketError.timedOut {
                break
            } catch {
                return
            }
        }
        throw DaemonSupervisorError.daemonDidNotStop
    }

    /// Nil when no daemon is listening on the socket.
    private func connectToRunningDaemon() throws -> DaemonAvailability? {
        let client = DaemonClient(socketPath: endpoint.socketPath)
        do {
            let welcome = try client.connect()
            if let kind = welcome.installation, kind != endpoint.installation.kind {
                client.disconnect()
                throw DaemonSupervisorError.wrongInstallation(kind)
            }
            return welcome.daemonVersion == expectedVersion ? .ready(client, welcome) : .outdated(client, welcome)
        } catch DaemonClient.ClientError.incompatibleDaemon(let rejection) {
            return .incompatible(rejection)
        } catch SocketError.system {
            return nil
        }
    }
}
