import Foundation
import HubAgentShared
import HubAgentTransport
import os

struct ServerConfiguration: Sendable {
    /// Bytes waiting to be written to one client before terminal output starts being
    /// dropped for it. A dropped client is caught up later with a fresh screen, so a
    /// slow or stuck client costs bounded memory and never holds a terminal back.
    var outboundHighWaterMark = 4 * 1024 * 1024
    var daemonVersion = HubAgentVersion.current
    /// Reported to clients so that an app never drives the other copy's daemon.
    var installation: InstallationKind?
}

/// One connected client: decodes its messages, hands them to the session manager and
/// queues what must be sent back. Lives on the daemon's queue.
final class ClientConnection: SessionClient, @unchecked Sendable {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let manager: SessionManager
    private let configuration: ServerConfiguration
    private let onClose: (ClientConnection) -> Void
    private let onShutdownRequest: () -> Void
    private let logger = Logger(subsystem: "com.hubagent.daemon", category: "connection")

    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var isWriteSourceActive = false
    private var decoder = FrameDecoder()
    private var hasCompletedHandshake = false
    private var isClosed = false
    private var closesWhenDrained = false

    private var pending: [UInt8] = []
    private var pendingOffset = 0
    /// Sessions whose output was dropped for this client and that need a fresh screen.
    private var staleSessions: Set<UUID> = []

    init(
        descriptor: Int32, queue: DispatchQueue, manager: SessionManager, configuration: ServerConfiguration,
        onClose: @escaping (ClientConnection) -> Void, onShutdownRequest: @escaping () -> Void
    ) {
        self.descriptor = descriptor
        self.queue = queue
        self.manager = manager
        self.configuration = configuration
        self.onClose = onClose
        self.onShutdownRequest = onShutdownRequest
    }

    func start() {
        UnixSocket.setNonBlocking(descriptor)
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        readSource.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        writeSource.setEventHandler { [weak self] in self?.flush() }
        self.readSource = readSource
        self.writeSource = writeSource
        readSource.resume()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        manager.disconnect(self)
        if !isWriteSourceActive { writeSource?.resume() }
        writeSource?.cancel()
        readSource?.cancel()
        onClose(self)
    }

    // MARK: Outbound

    /// Called by the session manager. Terminal output is dropped while the client is
    /// behind; everything else is always queued.
    func receive(_ message: DaemonMessage) {
        guard !isClosed else { return }
        switch message {
        case .output(let sessionId, _), .screen(let sessionId, _):
            if staleSessions.contains(sessionId) || pendingCount > configuration.outboundHighWaterMark {
                staleSessions.insert(sessionId)
                return
            }
        default:
            break
        }
        enqueue(message)
    }

    private var pendingCount: Int { pending.count - pendingOffset }

    private func enqueue(_ message: DaemonMessage) {
        pending.append(contentsOf: message.encodedFrame())
        flush()
    }

    private func flush() {
        while pendingCount > 0 {
            switch UnixSocket.write(descriptor, pending[pendingOffset...]) {
            case .wrote(let count): pendingOffset += count
            case .wouldBlock: return setWriteSource(active: true)
            case .failed: return close()
            }
        }
        pending.removeAll(keepingCapacity: pending.capacity <= 1024 * 1024)
        pendingOffset = 0
        setWriteSource(active: false)
        if closesWhenDrained { return close() }
        refreshStaleSessions()
    }

    /// The backlog is gone: replace what was dropped with the current screen.
    private func refreshStaleSessions() {
        guard !staleSessions.isEmpty else { return }
        let sessions = staleSessions
        staleSessions = []
        for sessionId in sessions {
            guard let screen = manager.screen(sessionId: sessionId) else { continue }
            enqueue(.screen(sessionId: sessionId, bytes: screen))
        }
    }

    private func setWriteSource(active: Bool) {
        guard active != isWriteSourceActive, !isClosed else { return }
        isWriteSourceActive = active
        if active { writeSource?.resume() } else { writeSource?.suspend() }
    }

    // MARK: Inbound

    private func readAvailable() {
        while !isClosed {
            switch UnixSocket.read(descriptor) {
            case .bytes(let bytes): decode(bytes)
            case .wouldBlock: return
            case .closed: return close()
            }
        }
    }

    private func decode(_ bytes: [UInt8]) {
        do {
            for body in try decoder.append(bytes) where !isClosed && !closesWhenDrained {
                handle(try ClientMessage(body: body))
            }
        } catch {
            logger.error("closing client after protocol error: \(String(describing: error), privacy: .public)")
            refuse(FailureReply(code: .malformedMessage, message: "\(error)"))
        }
    }

    private func refuse(_ failure: FailureReply) {
        closesWhenDrained = true
        enqueue(.failure(failure))
    }

    private func handle(_ message: ClientMessage) {
        if case .hello(let request) = message { return greet(request) }
        // Allowed without a handshake: an app that shares no protocol version with
        // this daemon must still be able to replace it.
        if case .shutdown = message { return onShutdownRequest() }
        guard hasCompletedHandshake else {
            return refuse(FailureReply(code: .handshakeRequired, message: "hello must be the first message"))
        }
        switch message {
        case .hello, .shutdown: break
        case .createSession(let request): create(request)
        case .listSessions: enqueue(.sessions(manager.listSessions()))
        case .attach(let sessionId, let size): report(manager.attach(sessionId: sessionId, size: size, client: self))
        case .detach(let sessionId): manager.detach(sessionId: sessionId, client: self)
        case .input(let sessionId, let bytes): manager.write(sessionId: sessionId, bytes: bytes, client: self)
        case .resize(let sessionId, let size): report(manager.resize(sessionId: sessionId, size: size, client: self))
        case .terminate(let sessionId): report(manager.terminate(sessionId: sessionId))
        case .acknowledgeExit(let sessionId): manager.acknowledgeExit(sessionId: sessionId)
        case .setTheme(let colors): manager.setTheme(colors)
        }
    }

    private func greet(_ request: HelloRequest) {
        let agreed = ProtocolVersion.negotiate(
            peerCurrent: request.protocolVersion, peerMinimum: request.minimumProtocolVersion)
        guard let agreed else {
            closesWhenDrained = true
            return enqueue(
                .rejected(
                    RejectedReply(
                        reason: "no protocol version in common",
                        daemonProtocolVersion: ProtocolVersion.current,
                        daemonMinimumProtocolVersion: ProtocolVersion.minimumSupported)))
        }
        hasCompletedHandshake = true
        enqueue(
            .welcome(
                WelcomeReply(
                    protocolVersion: agreed, daemonVersion: configuration.daemonVersion,
                    installation: configuration.installation, processId: getpid())))
    }

    private func create(_ request: CreateSessionRequest) {
        switch manager.createSession(request) {
        case .success(let session):
            enqueue(.sessionCreated(SessionCreatedReply(requestId: request.requestId, session: session)))
        case .failure(let failure):
            enqueue(.failure(failure))
        }
    }

    private func report(_ failure: FailureReply?) {
        if let failure { enqueue(.failure(failure)) }
    }
}
