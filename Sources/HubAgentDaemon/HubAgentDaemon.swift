import Foundation
import os

@main
enum HubAgentDaemon {
    /// Where the daemon listens when no `--socket` is given. Provisional: the
    /// permanent locations for the daily-use and development daemons are defined in
    /// phase 3, together with launchd.
    static var defaultSocketPath: String { NSTemporaryDirectory() + "hub-agent-dev-daemon.sock" }

    static func socketPath(arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count else {
            return defaultSocketPath
        }
        return arguments[index + 1]
    }

    static func main() {
        let logger = Logger(subsystem: "com.hubagent.daemon", category: "main")
        // A client that goes away must not kill the daemon and every terminal with it.
        signal(SIGPIPE, SIG_IGN)
        let queue = DispatchQueue(label: "com.hubagent.daemon")
        let manager = SessionManager(queue: queue)
        let server = ProtocolServer(
            socketPath: socketPath(arguments: CommandLine.arguments), queue: queue, manager: manager)
        do {
            try queue.sync { try server.start() }
        } catch {
            logger.fault("cannot start: \(String(describing: error), privacy: .public)")
            exit(EXIT_FAILURE)
        }
        stopSources = [SIGTERM, SIGINT].map { stopSource(for: $0, queue: queue, server: server) }
        dispatchMain()
    }

    /// Kept for the life of the process: a released signal source stops delivering.
    private nonisolated(unsafe) static var stopSources: [DispatchSourceSignal] = []

    /// Stopping the daemon ends every terminal, so it only happens on an explicit signal.
    private static func stopSource(
        for signalNumber: Int32, queue: DispatchQueue, server: ProtocolServer
    ) -> DispatchSourceSignal {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
        source.setEventHandler {
            server.stop()
            exit(EXIT_SUCCESS)
        }
        source.resume()
        return source
    }
}
