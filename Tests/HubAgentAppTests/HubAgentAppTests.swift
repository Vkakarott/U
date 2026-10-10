import Foundation
import HubAgentShared
import HubAgentTransport
import Testing

@testable import HubAgentApp

/// Collects what a `DaemonClient` delivers, for a test thread to wait on.
private final class Inbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var messages: [DaemonMessage] = []
    private var disconnects: [Error?] = []

    func add(_ message: DaemonMessage) {
        condition.withLock {
            messages.append(message)
            condition.broadcast()
        }
    }

    func addDisconnect(_ error: Error?) {
        condition.withLock {
            disconnects.append(error)
            condition.broadcast()
        }
    }

    /// Waits until a message matches and returns everything received so far.
    func wait(timeout: TimeInterval = 20, until matches: (DaemonMessage) -> Bool) -> [DaemonMessage]? {
        let deadline = Date().addingTimeInterval(timeout)
        return condition.withLock {
            while !messages.contains(where: matches) {
                if !condition.wait(until: deadline) { return nil }
            }
            return messages
        }
    }

    func waitForDisconnect(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        return condition.withLock {
            while disconnects.isEmpty {
                if !condition.wait(until: deadline) { return false }
            }
            return true
        }
    }
}

/// A scripted daemon: accepts one client, reads its hello and answers with `reply`.
private final class ScriptedDaemon: @unchecked Sendable {
    let path = NSTemporaryDirectory() + "hubagent-app-test-\(UUID().uuidString.prefix(8)).sock"
    private let listener: Int32
    private(set) var hello: ClientMessage?
    private var connection: BlockingConnection?
    private let ready = DispatchSemaphore(value: 0)

    init(reply: DaemonMessage, thenSend extra: [DaemonMessage] = [], thenClose: Bool = false) throws {
        listener = try UnixSocket.listen(path: path)
        Thread.detachNewThread { [self] in
            guard let descriptor = UnixSocket.accept(listener: listener) else { return }
            let connection = BlockingConnection(descriptor: descriptor)
            var decoder = FrameDecoder()
            if let bytes = try? connection.receive(timeout: 5), let body = try? decoder.append(bytes).first {
                hello = try? ClientMessage(body: body)
            }
            for message in [reply] + extra { try? connection.send(message.encodedFrame()) }
            if thenClose { connection.close() } else { self.connection = connection }
            ready.signal()
        }
    }

    func waitUntilAnswered() {
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit {
        connection?.close()
        close(listener)
        unlink(path)
    }
}

@Suite struct DaemonClientHandshake {
    @Test func connectsAndAnnouncesItsVersions() throws {
        let welcome = WelcomeReply(protocolVersion: ProtocolVersion.current, daemonVersion: "9.9.9")
        let daemon = try ScriptedDaemon(reply: .welcome(welcome))
        let client = DaemonClient(socketPath: daemon.path, clientName: "tests")
        #expect(try client.connect() == welcome)
        daemon.waitUntilAnswered()
        #expect(daemon.hello == .hello(HelloRequest(clientName: "tests")))
    }

    @Test func reportsAnIncompatibleDaemon() throws {
        let rejection = RejectedReply(reason: "too old", daemonProtocolVersion: 9, daemonMinimumProtocolVersion: 8)
        let daemon = try ScriptedDaemon(reply: .rejected(rejection), thenClose: true)
        let client = DaemonClient(socketPath: daemon.path)
        #expect(throws: DaemonClient.ClientError.incompatibleDaemon(rejection)) { try client.connect() }
        #expect(throws: DaemonClient.ClientError.notConnected) { try client.send(.listSessions) }
    }

    @Test func failsWhenNoDaemonIsListening() {
        let client = DaemonClient(socketPath: NSTemporaryDirectory() + "hubagent-nobody-\(UUID().uuidString.prefix(8))")
        #expect(throws: SocketError.self) { try client.connect() }
    }

    @Test func deliversMessagesInOrderAndReportsTheDisconnect() throws {
        let sessionId = UUID()
        let stream: [DaemonMessage] = [
            .output(sessionId: sessionId, bytes: [1]), .output(sessionId: sessionId, bytes: [2]),
            .sessionExited(sessionId: sessionId, exitCode: 0),
        ]
        let welcome = WelcomeReply(protocolVersion: 1, daemonVersion: "x")
        let daemon = try ScriptedDaemon(reply: .welcome(welcome), thenSend: stream, thenClose: true)
        let client = DaemonClient(socketPath: daemon.path)
        try client.connect()
        let inbox = Inbox()
        client.startReceiving(
            on: DispatchQueue(label: "tests.delivery"), onMessage: { inbox.add($0) },
            onDisconnect: { inbox.addDisconnect($0) })
        let received = inbox.wait { if case .sessionExited = $0 { true } else { false } }
        #expect(received == stream)
        #expect(inbox.waitForDisconnect())
        #expect(throws: DaemonClient.ClientError.notConnected) { try client.send(.listSessions) }
    }
}

/// The real daemon executable, started as a separate process on a private socket.
private final class DaemonProcess {
    let socketPath = NSTemporaryDirectory() + "hubagent-app-test-\(UUID().uuidString.prefix(8)).sock"
    private let process = Process()

    init() throws {
        process.executableURL = try #require(Self.productsDirectory()).appendingPathComponent("HubAgentDaemon")
        process.arguments = ["--socket", socketPath]
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socketPath), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// The directory holding the built products, found from the test bundle's path.
    private static func productsDirectory() -> URL? {
        let candidates = Bundle.allBundles.map(\.bundlePath) + CommandLine.arguments
        guard let bundle = candidates.first(where: { $0.contains(".xctest") }),
            let range = bundle.range(of: ".xctest")
        else { return nil }
        return URL(fileURLWithPath: String(bundle[..<range.upperBound])).deletingLastPathComponent()
    }

    /// Asks the daemon to stop and reports whether it exited and removed its socket.
    func stop() -> Bool {
        process.terminate()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        return !process.isRunning && !FileManager.default.fileExists(atPath: socketPath)
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        unlink(socketPath)
        unlink(socketPath + ".lock")
    }
}

@Suite struct AppAndDaemonTogether {
    @Test func theAppClientDrivesATerminalInTheRealDaemon() throws {
        let daemon = try DaemonProcess()
        let client = DaemonClient(socketPath: daemon.socketPath)
        let welcome = try client.connect()
        #expect(welcome.protocolVersion == ProtocolVersion.current)

        let inbox = Inbox()
        client.startReceiving(
            on: DispatchQueue(label: "tests.delivery"), onMessage: { inbox.add($0) },
            onDisconnect: { inbox.addDisconnect($0) })

        let size = TerminalSize(columns: 100, rows: 30)
        let directory = FileManager.default.temporaryDirectory.path
        try client.send(.createSession(CreateSessionRequest(requestId: 1, workingDirectory: directory, size: size)))
        let created = try #require(inbox.wait { if case .sessionCreated = $0 { true } else { false } })
        guard case .sessionCreated(let reply) = try #require(created.last) else { return }
        let sessionId = reply.session.id

        // The user's own login shell runs here; the marker is computed so that the
        // echoed command line cannot be mistaken for its output.
        try client.send(.attach(sessionId: sessionId, size: size))
        try client.send(.input(sessionId: sessionId, bytes: Array("echo marker-$((6 * 7))\n".utf8)))
        let seen = inbox.wait { message in
            guard case .output(_, let bytes) = message else { return false }
            return String(decoding: bytes, as: UTF8.self).contains("marker-42")
        }
        #expect(seen != nil, "the terminal's output never arrived")
        #expect(seen?.contains { if case .screen = $0 { true } else { false } } == true)

        try client.send(.terminate(sessionId: sessionId))
        #expect(inbox.wait { if case .sessionExited = $0 { true } else { false } } != nil)

        #expect(daemon.stop(), "the daemon did not stop cleanly")
        #expect(inbox.waitForDisconnect())
    }
}
