import Foundation
import Testing

@testable import HubAgentTransport

private func temporarySocketPath() -> String {
    NSTemporaryDirectory() + "hubagent-test-\(UUID().uuidString.prefix(8)).sock"
}

@Suite struct UnixSocketTests {
    @Test func listeningSocketIsOwnerOnly() throws {
        let path = temporarySocketPath()
        let listener = try UnixSocket.listen(path: path)
        defer {
            close(listener)
            unlink(path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func listeningLeavesTheProcessUmaskAlone() throws {
        let before = umask(0o022)
        defer { umask(before) }
        let path = temporarySocketPath()
        let listener = try UnixSocket.listen(path: path)
        close(listener)
        unlink(path)
        let after = umask(0o022)
        #expect(after == 0o022)
    }

    @Test func carriesBytesBothWays() throws {
        let path = temporarySocketPath()
        let listener = try UnixSocket.listen(path: path)
        defer {
            close(listener)
            unlink(path)
        }
        let client = try BlockingConnection(path: path)
        let server = BlockingConnection(descriptor: try #require(UnixSocket.accept(listener: listener)))
        try client.send([1, 2, 3])
        #expect(try server.receive(timeout: 2) == [1, 2, 3])
        try server.send([9, 8])
        #expect(try client.receive(timeout: 2) == [9, 8])
    }

    @Test func reportsTimeoutAndClosedPeer() throws {
        let path = temporarySocketPath()
        let listener = try UnixSocket.listen(path: path)
        defer {
            close(listener)
            unlink(path)
        }
        let client = try BlockingConnection(path: path)
        let server = BlockingConnection(descriptor: try #require(UnixSocket.accept(listener: listener)))
        #expect(throws: SocketError.timedOut) { try client.receive(timeout: 0.05) }
        server.close()
        #expect(throws: SocketError.closed) { try client.receive(timeout: 2) }
    }

    @Test func socketsAreNotInheritedByStartedPrograms() throws {
        let path = temporarySocketPath()
        let listener = try UnixSocket.listen(path: path)
        defer {
            close(listener)
            unlink(path)
        }
        let client = try UnixSocket.connect(path: path)
        defer { close(client) }
        let accepted = try #require(UnixSocket.accept(listener: listener))
        defer { close(accepted) }
        for descriptor in [listener, client, accepted] {
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        }
    }

    @Test func refusesPathsThatDoNotFit() {
        let path = "/tmp/" + String(repeating: "x", count: 200)
        #expect(throws: SocketError.pathTooLong(path)) { try UnixSocket.listen(path: path) }
    }

    @Test func connectingWithoutListenerFails() {
        #expect(throws: SocketError.self) { try UnixSocket.connect(path: temporarySocketPath()) }
    }

    @Test func nonBlockingReadReportsWouldBlock() throws {
        let path = temporarySocketPath()
        let listener = try UnixSocket.listen(path: path)
        defer {
            close(listener)
            unlink(path)
        }
        let client = try UnixSocket.connect(path: path)
        defer { close(client) }
        UnixSocket.setNonBlocking(client)
        #expect(UnixSocket.read(client) == .wouldBlock)
    }
}
