import Foundation
import HubAgentShared
import HubAgentTransport
import Testing

@testable import HubAgentDaemon

@Suite struct DaemonOptionParsing {
    @Test func servesTheDevelopmentCopyByDefault() throws {
        let options = try DaemonOptions(arguments: ["daemon"], environment: [:])
        #expect(options.installation?.kind == .development)
        #expect(options.socketPath == Installation(kind: .development).socketPath)
    }

    @Test func selectsACopyAndItsRoot() throws {
        let options = try DaemonOptions(
            arguments: ["daemon", "--environment", "production", "--home", "/tmp/elsewhere"], environment: [:])
        let expected = Installation(kind: .production, homeDirectory: "/tmp/elsewhere")
        #expect(options.installation == expected)
        #expect(options.socketPath == expected.socketPath)
        #expect(options.lockPath == expected.lockPath)
    }

    @Test func anExplicitSocketAloneBelongsToNoCopy() throws {
        let options = try DaemonOptions(arguments: ["daemon", "--socket", "/tmp/x.sock"], environment: [:])
        #expect(options.installation == nil)
        #expect(options.socketPath == "/tmp/x.sock")
        #expect(options.lockPath == "/tmp/x.sock.lock")
    }

    @Test func aCopyMayListenOnAnotherSocket() throws {
        let options = try DaemonOptions(
            arguments: ["daemon", "--environment", "development", "--socket", "/tmp/x.sock"], environment: [:])
        #expect(options.installation?.kind == .development)
        #expect(options.socketPath == "/tmp/x.sock")
    }

    @Test func refusesBadArguments() {
        #expect(throws: DaemonOptions.OptionError.unknownEnvironment("staging")) {
            try DaemonOptions(arguments: ["daemon", "--environment", "staging"], environment: [:])
        }
        #expect(throws: DaemonOptions.OptionError.missingValue("--socket")) {
            try DaemonOptions(arguments: ["daemon", "--socket"], environment: [:])
        }
    }
}

/// A scratch folder standing in for the user's home.
final class ScratchHome {
    let path: String

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ha-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.resolvingSymlinksInPath().path
    }

    /// Options for a daemon of this home. The socket gets a short path of its own:
    /// the scratch folder is too deep for the system's limit on socket paths.
    func options(_ kind: InstallationKind) throws -> DaemonOptions {
        try DaemonOptions(
            arguments: ["daemon", "--environment", kind.rawValue, "--home", path, "--socket", socketPath(kind)],
            environment: [:])
    }

    func socketPath(_ kind: InstallationKind) -> String { path + "/\(kind.rawValue.prefix(4)).sock" }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

@Suite struct SingleInstance {
    @Test func aSecondLockOnTheSamePathIsRefused() throws {
        let home = ScratchHome()
        let path = home.path + "/daemon.lock"
        let first = InstanceLock(path: path)
        #expect(first != nil)
        #expect(InstanceLock(path: path) == nil)
    }

    @Test func theLockIsFreeAgainOnceItsOwnerIsGone() {
        let home = ScratchHome()
        let path = home.path + "/daemon.lock"
        var first = InstanceLock(path: path)
        #expect(first != nil)
        first = nil
        #expect(InstanceLock(path: path) != nil)
    }
}

extension TerminalTests {
    @Suite struct DaemonLifecycle {
        private func runtime(_ home: ScratchHome, _ kind: InstallationKind) throws -> DaemonRuntime {
            DaemonRuntime(options: try home.options(kind), launcher: PlainShellLauncher())
        }

        private func connect(_ path: String) throws -> (BlockingConnection, WelcomeReply) {
            let connection = try BlockingConnection(path: path)
            try connection.send(ClientMessage.hello(HelloRequest(clientName: "tests")).encodedFrame())
            var decoder = FrameDecoder()
            let bodies = try decoder.append(try connection.receive(timeout: 5))
            guard case .welcome(let welcome) = try DaemonMessage(body: try #require(bodies.first)) else {
                throw SocketError.closed
            }
            return (connection, welcome)
        }

        @Test func createsItsFolderForTheOwnerOnly() throws {
            let home = ScratchHome()
            let runtime = try runtime(home, .development)
            try runtime.start(onStopped: {})
            defer { runtime.queue.sync { runtime.server.stop() } }
            let directory = Installation(kind: .development, homeDirectory: home.path).supportDirectory
            let attributes = try FileManager.default.attributesOfItem(atPath: directory)
            #expect(attributes[.posixPermissions] as? Int == 0o700)
        }

        @Test func aSecondDaemonForTheSameCopyRefusesToStart() throws {
            let home = ScratchHome()
            let first = try runtime(home, .development)
            try first.start(onStopped: {})
            defer { first.queue.sync { first.server.stop() } }
            let second = try runtime(home, .development)
            #expect(throws: DaemonStartError.alreadyRunning) { try second.start(onStopped: {}) }
            // The refused daemon must not have taken the first one's socket away.
            #expect(try connect(home.socketPath(.development)).1.installation == .development)
        }

        @Test func theTwoCopiesRunSideBySideAndSeeOnlyTheirOwnSessions() throws {
            let home = ScratchHome()
            let production = try runtime(home, .production)
            let development = try runtime(home, .development)
            try production.start(onStopped: {})
            try development.start(onStopped: {})
            defer {
                for runtime in [production, development] {
                    runtime.queue.sync {
                        runtime.manager.terminateAll()
                        runtime.server.stop()
                    }
                }
            }
            #expect(try connect(home.socketPath(.production)).1.installation == .production)
            #expect(try connect(home.socketPath(.development)).1.installation == .development)

            let request = CreateSessionRequest(
                requestId: 1, workingDirectory: home.path, size: TerminalSize(columns: 80, rows: 24))
            _ = try production.queue.sync { try production.manager.createSession(request).get() }
            #expect(production.queue.sync { production.manager.listSessions().count } == 1)
            #expect(development.queue.sync { development.manager.listSessions() }.isEmpty)
        }

        @Test func aShutdownRequestEndsTheTerminalsAndThenTheDaemon() throws {
            let home = ScratchHome()
            let runtime = try runtime(home, .development)
            let stopped = DispatchSemaphore(value: 0)
            try runtime.start(onStopped: { stopped.signal() })
            let request = CreateSessionRequest(
                requestId: 1, workingDirectory: home.path, size: TerminalSize(columns: 80, rows: 24))
            let session = try runtime.queue.sync { try runtime.manager.createSession(request).get() }

            let (connection, _) = try connect(home.socketPath(.development))
            try connection.send(ClientMessage.shutdown.encodedFrame())
            #expect(stopped.wait(timeout: .now() + 10) == .success)
            #expect(runtime.queue.sync { runtime.manager.runningSessionCount } == 0)
            #expect(kill(session.processId, 0) != 0, "the shell outlived the daemon's shutdown")
            #expect(!FileManager.default.fileExists(atPath: home.socketPath(.development)))
            runtime.queue.sync { runtime.server.stop() }
        }

        @Test func shutdownIsAcceptedBeforeTheHandshake() throws {
            let home = ScratchHome()
            let runtime = try runtime(home, .development)
            let stopped = DispatchSemaphore(value: 0)
            try runtime.start(onStopped: { stopped.signal() })
            let connection = try BlockingConnection(path: home.socketPath(.development))
            try connection.send(ClientMessage.shutdown.encodedFrame())
            #expect(stopped.wait(timeout: .now() + 10) == .success)
            runtime.queue.sync { runtime.server.stop() }
        }

        @Test func refusesAFolderThatCannotBeEntered() throws {
            let harness = DaemonHarness()
            let locked = harness.directory + "/locked"
            try FileManager.default.createDirectory(
                atPath: locked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o000])
            defer { chmod(locked, 0o700) }
            let request = CreateSessionRequest(requestId: 9, workingDirectory: locked, size: DaemonHarness.size)
            let result = harness.sync { harness.manager.createSession(request) }
            guard case .failure(let failure) = result else {
                Issue.record("a terminal was opened for a folder nobody can enter")
                return
            }
            #expect(failure.code == .workingDirectoryNotAccessible)
            #expect(failure.requestId == 9)
            #expect(harness.sync { harness.manager.listSessions() }.isEmpty)
        }
    }
}
