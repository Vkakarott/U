import Foundation
import HubAgentTransport
import os

/// Accepts clients on a Unix socket and gives each one a `ClientConnection`.
///
/// This is the only place that knows the transport. Adding another one later (a
/// WebSocket for the mobile client) means another server feeding the same manager.
final class ProtocolServer: @unchecked Sendable {
    let socketPath: String
    private let queue: DispatchQueue
    private let manager: SessionManager
    private let configuration: ServerConfiguration
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: ClientConnection] = [:]
    private let logger = Logger(subsystem: "com.hubagent.daemon", category: "server")

    init(
        socketPath: String, queue: DispatchQueue, manager: SessionManager,
        configuration: ServerConfiguration = ServerConfiguration()
    ) {
        self.socketPath = socketPath
        self.queue = queue
        self.manager = manager
        self.configuration = configuration
    }

    /// Starts listening. Call on the daemon's queue or before it is in use.
    func start() throws {
        let listener = try UnixSocket.listen(path: socketPath)
        UnixSocket.setNonBlocking(listener)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(listener: listener) }
        source.setCancelHandler { Darwin.close(listener) }
        acceptSource = source
        source.resume()
        logger.notice("listening on \(self.socketPath, privacy: .public)")
    }

    /// Stops listening and drops every client. Sessions are not touched.
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for connection in Array(connections.values) { connection.close() }
        unlink(socketPath)
    }

    var connectionCount: Int { connections.count }

    private func acceptPending(listener: Int32) {
        while let descriptor = UnixSocket.accept(listener: listener) {
            let connection = ClientConnection(
                descriptor: descriptor, queue: queue, manager: manager, configuration: configuration,
                onClose: { [weak self] in self?.connections[ObjectIdentifier($0)] = nil })
            connections[ObjectIdentifier(connection)] = connection
            connection.start()
        }
    }
}
