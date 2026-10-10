import Foundation
import HubAgentShared
import HubAgentTransport
import Testing

@testable import HubAgentDaemon

/// A real client on the socket, with its own emulator per attached session.
private final class SocketClient {
    private let connection: BlockingConnection
    private var decoder = FrameDecoder()
    private var queued: [DaemonMessage] = []
    private(set) var received: [DaemonMessage] = []
    private(set) var emulator: SwiftTermHeadlessEmulator?

    init(path: String, hello: HelloRequest? = HelloRequest(clientName: "tests")) throws {
        connection = try BlockingConnection(path: path)
        if let hello {
            try send(.hello(hello))
            _ = try next()
        }
    }

    func send(_ message: ClientMessage) throws {
        try connection.send(message.encodedFrame())
    }

    func sendRaw(_ bytes: [UInt8]) throws {
        try connection.send(bytes)
    }

    func prepareEmulator(size: TerminalSize) {
        emulator = SwiftTermHeadlessEmulator(size: size, historyLines: 10_000)
    }

    /// The next message, feeding terminal data to the emulator on the way.
    func next(timeout: TimeInterval = 5) throws -> DaemonMessage {
        let deadline = Date().addingTimeInterval(timeout)
        while queued.isEmpty {
            let bytes = try connection.receive(timeout: max(0.01, deadline.timeIntervalSinceNow))
            queued += try decoder.append(bytes).map { try DaemonMessage(body: $0) }
        }
        let message = queued.removeFirst()
        received.append(message)
        switch message {
        case .screen(_, let bytes), .output(_, let bytes): emulator?.feed(bytes[...])
        default: break
        }
        return message
    }

    /// Reads until a message satisfies the predicate.
    @discardableResult
    func waitFor(timeout: TimeInterval = 10, _ predicate: (DaemonMessage) -> Bool) throws -> DaemonMessage {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let message = try next(timeout: max(0.01, deadline.timeIntervalSinceNow))
            if predicate(message) { return message }
        }
    }

    /// Reads whatever arrives until the emulator shows the text.
    func waitForText(_ text: String, timeout: TimeInterval = 10) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while emulator?.stateDump().visibleText.contains(text) != true {
            _ = try next(timeout: max(0.01, deadline.timeIntervalSinceNow))
        }
    }

    /// Keeps reading until this client's emulator matches the daemon's.
    func isInSync(with daemon: DaemonHarness, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if emulator?.stateDump().differences(from: daemon.daemonDump()) == [] { return true }
            _ = try? next(timeout: 0.1)
        }
        return false
    }

    func createSession(directory: String, size: TerminalSize = DaemonHarness.size) throws -> SessionDescriptor {
        try send(.createSession(CreateSessionRequest(requestId: 42, workingDirectory: directory, size: size)))
        guard case .sessionCreated(let reply) = try next() else { throw SocketError.closed }
        #expect(reply.requestId == 42)
        return reply.session
    }

    func attach(_ sessionId: UUID, size: TerminalSize = DaemonHarness.size) throws {
        prepareEmulator(size: size)
        try send(.attach(sessionId: sessionId, size: size))
        try waitFor { if case .screen = $0 { true } else { false } }
    }

    func close() {
        connection.close()
    }
}

/// A server over a harness, on a private socket.
private final class ServerHarness {
    let daemon: DaemonHarness
    let server: ProtocolServer
    let path = NSTemporaryDirectory() + "hubagent-test-\(UUID().uuidString.prefix(8)).sock"

    init(configuration: ServerConfiguration = ServerConfiguration()) throws {
        daemon = DaemonHarness()
        server = ProtocolServer(
            socketPath: path, queue: daemon.queue, manager: daemon.manager, configuration: configuration)
        try daemon.sync { try server.start() }
    }

    deinit {
        daemon.sync { server.stop() }
    }
}

extension TerminalTests {
    @Suite struct Handshake {
        @Test func welcomesACompatibleClient() throws {
            let harness = try ServerHarness()
            let client = try SocketClient(path: harness.path, hello: nil)
            try client.send(.hello(HelloRequest(clientName: "tests")))
            let reply = try client.next()
            #expect(
                reply
                    == .welcome(
                        WelcomeReply(
                            protocolVersion: ProtocolVersion.current, daemonVersion: HubAgentVersion.current,
                            processId: getpid())))
        }

        @Test func rejectsAnIncompatibleClientAndClosesTheConnection() throws {
            let harness = try ServerHarness()
            let client = try SocketClient(path: harness.path, hello: nil)
            let tooNew = ProtocolVersion.current + 5
            try client.send(
                .hello(HelloRequest(protocolVersion: tooNew, minimumProtocolVersion: tooNew, clientName: "x")))
            guard case .rejected(let reply) = try client.next() else {
                Issue.record("expected a rejection")
                return
            }
            #expect(reply.daemonProtocolVersion == ProtocolVersion.current)
            #expect(throws: SocketError.closed) { try client.next(timeout: 3) }
        }

        @Test func refusesMessagesBeforeTheHandshake() throws {
            let harness = try ServerHarness()
            let client = try SocketClient(path: harness.path, hello: nil)
            try client.send(.listSessions)
            guard case .failure(let failure) = try client.next() else {
                Issue.record("expected a failure")
                return
            }
            #expect(failure.code == .handshakeRequired)
            #expect(throws: SocketError.closed) { try client.next(timeout: 3) }
        }

        @Test func closesTheConnectionOnGarbage() throws {
            let harness = try ServerHarness()
            let client = try SocketClient(path: harness.path)
            try client.sendRaw([0, 0, 0, 2, 250, 1])
            guard case .failure(let failure) = try client.next() else {
                Issue.record("expected a failure")
                return
            }
            #expect(failure.code == .malformedMessage)
            #expect(throws: SocketError.closed) { try client.next(timeout: 3) }
        }
    }
}

extension TerminalTests {
    @Suite struct SessionsOverTheSocket {
        @Test func createsAttachesTypesAndReadsOutput() throws {
            let harness = try ServerHarness()
            let client = try SocketClient(path: harness.path)
            let session = try client.createSession(directory: harness.daemon.directory)
            try client.attach(session.id)
            try client.waitForText("$")
            try client.send(.input(sessionId: session.id, bytes: Array("echo over-the-socket\n".utf8)))
            try client.waitForText("\nover-the-socket")

            try client.send(.listSessions)
            guard case .sessions(let list) = try client.waitFor({ if case .sessions = $0 { true } else { false } })
            else {
                return
            }
            #expect(list.map(\.id) == [session.id])
        }

        @Test func reportsFailuresWithTheRequestTheyBelongTo() throws {
            let harness = try ServerHarness()
            let client = try SocketClient(path: harness.path)
            let request = CreateSessionRequest(
                requestId: 77, workingDirectory: harness.daemon.directory + "/missing", size: DaemonHarness.size)
            try client.send(.createSession(request))
            guard case .failure(let failure) = try client.next() else {
                Issue.record("expected a failure")
                return
            }
            #expect(failure.code == .workingDirectoryNotFound)
            #expect(failure.requestId == 77)
        }

        @Test func aSessionSurvivesItsClientAndRestoresTheScreenForTheNextOne() throws {
            let harness = try ServerHarness()
            let first = try SocketClient(path: harness.path)
            let session = try first.createSession(directory: harness.daemon.directory)
            try first.attach(session.id)
            try first.waitForText("$")
            let command = "printf '\\033[35mkept\\033[0m\\n'; seq 1 40; (sleep 0.5; echo left-$((40 + 2))) &\n"
            try first.send(.input(sessionId: session.id, bytes: Array(command.utf8)))
            try first.waitForText("\n40")
            first.close()

            #expect(harness.daemon.eventually { harness.server.connectionCount == 0 })
            #expect(harness.daemon.eventually { harness.daemon.daemonDump().visibleText.contains("left-42") })

            let second = try SocketClient(path: harness.path)
            try second.attach(session.id)
            #expect(second.isInSync(with: harness.daemon))
            #expect(second.emulator?.stateDump().visibleText.contains("left-42") == true)
            try second.send(.input(sessionId: session.id, bytes: Array("echo still-usable\n".utf8)))
            try second.waitForText("\nstill-usable")
        }

        @Test func tellsTheClientWhenTheShellExits() throws {
            let harness = try ServerHarness()
            let client = try SocketClient(path: harness.path)
            let session = try client.createSession(directory: harness.daemon.directory)
            try client.attach(session.id)
            try client.waitForText("$")
            try client.send(.input(sessionId: session.id, bytes: Array("exit 7\n".utf8)))
            let exited = try client.waitFor { if case .sessionExited = $0 { true } else { false } }
            #expect(exited == .sessionExited(sessionId: session.id, exitCode: 7))

            try client.send(.acknowledgeExit(sessionId: session.id))
            try client.send(.listSessions)
            let list = try client.waitFor { if case .sessions = $0 { true } else { false } }
            #expect(list == .sessions([]))
        }

        @Test func resizingSendsAFreshScreen() throws {
            let harness = try ServerHarness()
            let client = try SocketClient(path: harness.path)
            let session = try client.createSession(directory: harness.daemon.directory)
            try client.attach(session.id)
            try client.waitForText("$")
            let wide = TerminalSize(columns: 120, rows: 30)
            client.emulator?.resize(wide)
            try client.send(.resize(sessionId: session.id, size: wide))
            try client.waitFor { if case .screen = $0 { true } else { false } }
            try client.send(.input(sessionId: session.id, bytes: Array("stty size\n".utf8)))
            try client.waitForText("\n30 120")
            #expect(client.isInSync(with: harness.daemon))
        }
    }
}

extension TerminalTests {
    @Suite struct SlowClients {
        @Test func aClientThatStopsReadingDoesNotHoldTheTerminalBack() throws {
            var configuration = ServerConfiguration()
            configuration.outboundHighWaterMark = 64 * 1024
            let harness = try ServerHarness(configuration: configuration)
            let client = try SocketClient(path: harness.path)
            let session = try client.createSession(directory: harness.daemon.directory)
            try client.attach(session.id)
            try client.waitForText("$")

            // About 2 MB of output while the client reads nothing at all.
            let flood =
                "yes 'filling the pipe with plenty of text to overflow every buffer' | head -n 30000; echo flood-done\n"
            try client.send(.input(sessionId: session.id, bytes: Array(flood.utf8)))
            #expect(
                harness.daemon.eventually(timeout: 60, interval: 0.5) {
                    harness.daemon.daemonDump().visibleText.contains("\nflood-done")
                },
                "the terminal was held back by the client")

            // The client wakes up: after the backlog it must receive a screen that catches it up.
            try client.waitForText("\nflood-done", timeout: 60)
            #expect(client.isInSync(with: harness.daemon, timeout: 30))
            let screens = client.received.filter { if case .screen = $0 { true } else { false } }.count
            #expect(screens >= 2, "no catch-up screen was sent")
        }
    }
}
