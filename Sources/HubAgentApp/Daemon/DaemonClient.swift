import Foundation
import HubAgentShared
import HubAgentTransport

/// The app's connection to the daemon.
///
/// It only speaks the protocol: it knows nothing about how the daemon runs terminals,
/// and nothing here touches the interface.
final class DaemonClient: @unchecked Sendable {
    enum ClientError: Error, Equatable {
        /// The daemon and this app share no protocol version. The daemon outlives the
        /// app, so this is expected after an update and must be shown to the user.
        case incompatibleDaemon(RejectedReply)
        case unexpectedReply
        case notConnected
    }

    private let socketPath: String
    private let clientName: String
    private let lock = NSLock()
    private var connection: BlockingConnection?
    private var decoder = FrameDecoder()
    /// Messages that arrived in the same read as the handshake reply.
    private var backlog: [DaemonMessage] = []

    init(socketPath: String, clientName: String = "HubAgentApp") {
        self.socketPath = socketPath
        self.clientName = clientName
    }

    /// Connects and agrees on a protocol version. Blocks for at most `timeout`.
    @discardableResult
    func connect(timeout: TimeInterval = 5) throws -> WelcomeReply {
        let connection = try BlockingConnection(path: socketPath)
        try connection.send(ClientMessage.hello(HelloRequest(clientName: clientName)).encodedFrame())
        var pending: [DaemonMessage] = []
        while pending.isEmpty {
            pending = try decoder.append(try connection.receive(timeout: timeout)).map { try DaemonMessage(body: $0) }
        }
        switch pending[0] {
        case .welcome(let welcome):
            lock.withLock {
                self.connection = connection
                backlog = Array(pending.dropFirst())
            }
            return welcome
        case .rejected(let rejection):
            connection.close()
            throw ClientError.incompatibleDaemon(rejection)
        default:
            connection.close()
            throw ClientError.unexpectedReply
        }
    }

    /// Starts delivering the daemon's messages, in order, on `queue`. `onDisconnect`
    /// is called once when the connection ends, with the error that ended it, if any.
    func startReceiving(
        on queue: DispatchQueue, onMessage: @escaping @Sendable (DaemonMessage) -> Void,
        onDisconnect: @escaping @Sendable (Error?) -> Void
    ) {
        guard let connection = lock.withLock({ self.connection }) else {
            return queue.async { onDisconnect(ClientError.notConnected) }
        }
        Thread.detachNewThread { [self] in
            let failure = receiveLoop(connection: connection) { message in queue.async { onMessage(message) } }
            disconnect()
            queue.async { onDisconnect(failure) }
        }
    }

    func send(_ message: ClientMessage) throws {
        guard let connection = lock.withLock({ self.connection }) else { throw ClientError.notConnected }
        try connection.send(message.encodedFrame())
    }

    func disconnect() {
        let connection = lock.withLock {
            defer { self.connection = nil }
            return self.connection
        }
        connection?.close()
    }

    /// Reads until the connection ends. Returns nil for an orderly close.
    private func receiveLoop(connection: BlockingConnection, deliver: (DaemonMessage) -> Void) -> Error? {
        let early = lock.withLock {
            defer { backlog = [] }
            return backlog
        }
        early.forEach(deliver)
        while true {
            do {
                let bytes = try connection.receive(timeout: 3600)
                for body in try decoder.append(bytes) { deliver(try DaemonMessage(body: body)) }
            } catch SocketError.timedOut {
                continue
            } catch SocketError.closed {
                return nil
            } catch {
                return error
            }
        }
    }
}
