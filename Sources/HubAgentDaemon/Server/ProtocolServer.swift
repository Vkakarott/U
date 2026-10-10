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
    /// Called when a client asks the daemon to stop.
    var onShutdownRequest: (() -> Void)?
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
        stopListening()
        for connection in Array(connections.values) { connection.close() }
    }

    /// Refuses new clients but keeps the connected ones. Used while the daemon winds
    /// down: a client sees its connection end only when the process is really gone,
    /// which is when a replacement daemon can start.
    func stopListening() {
        guard let source = acceptSource else { return }
        source.cancel()
        acceptSource = nil
        unlink(socketPath)
    }

    var connectionCount: Int { connections.count }

    private func acceptPending(listener: Int32) {
        while let descriptor = UnixSocket.accept(listener: listener) {
            let connection = ClientConnection(
                descriptor: descriptor, queue: queue, manager: manager, configuration: configuration,
                onClose: { [weak self] in self?.connections[ObjectIdentifier($0)] = nil },
                onShutdownRequest: { [weak self] in self?.onShutdownRequest?() })
            connections[ObjectIdentifier(connection)] = connection
            connection.start()
        }
    }
}
