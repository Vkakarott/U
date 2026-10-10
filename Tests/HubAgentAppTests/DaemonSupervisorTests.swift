import Foundation
import HubAgentShared
import HubAgentTransport
import Testing

@testable import HubAgentApp

/// A scratch folder standing in for the user's home, with the endpoint of a real
/// daemon inside it. Whatever daemon is left running there is stopped at the end.
final class ScratchInstallation {
    let home: String
    let endpoint: DaemonEndpoint

    init(kind: InstallationKind = .development) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ha-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        home = url.resolvingSymlinksInPath().path
        // The scratch folder is too deep for the system's limit on socket paths.
        endpoint = DaemonEndpoint(
            installation: Installation(kind: kind, homeDirectory: home), executablePath: BuiltProducts.daemonPath,
            socketPath: home + "/d.sock")
    }

    func supervisor(expecting version: String = HubAgentVersion.current, launcher: DaemonLauncher? = nil)
        -> DaemonSupervisor
    {
        DaemonSupervisor(
            endpoint: endpoint, launcher: launcher ?? ProcessDaemonLauncher(), expectedVersion: version)
    }

    deinit {
        try? supervisor().stopDaemon()
        try? FileManager.default.removeItem(atPath: home)
    }
}

final class RecordingLauncher: DaemonLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var launchCount: Int { lock.withLock { count } }

    func launch(_ endpoint: DaemonEndpoint) throws {
        lock.withLock { count += 1 }
    }
}

final class RecordingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var commands: [[String]] { lock.withLock { recorded } }
    var failing: String?

    func run(_ command: [String]) throws -> (status: Int32, output: String) {
        lock.withLock { recorded.append(command) }
        return command.contains(where: { $0 == failing }) ? (5, "refused") : (0, "")
    }
}

/// Drives a connected client the way the app will.
struct DaemonSession {
    let client: DaemonClient
    let inbox = Inbox()

    init(_ client: DaemonClient) {
        self.client = client
        let inbox = inbox
        client.startReceiving(
            on: DispatchQueue(label: "tests.delivery"), onMessage: { inbox.add($0) },
            onDisconnect: { inbox.addDisconnect($0) })
    }

    func createSession(in directory: String) throws -> SessionDescriptor {
        let size = TerminalSize(columns: 80, rows: 24)
        try client.send(.createSession(CreateSessionRequest(requestId: 1, workingDirectory: directory, size: size)))
        let messages = try #require(inbox.wait { if case .sessionCreated = $0 { true } else { false } })
        guard case .sessionCreated(let reply) = try #require(messages.last) else { throw SocketError.closed }
        return reply.session
    }

    func listSessions() throws -> [SessionDescriptor] {
        try client.send(.listSessions)
        let messages = try #require(inbox.wait { if case .sessions = $0 { true } else { false } })
        guard case .sessions(let list) = try #require(messages.last) else { throw SocketError.closed }
        return list
    }
}

private func client(_ availability: DaemonAvailability) throws -> (DaemonClient, WelcomeReply) {
    switch availability {
    case .ready(let client, let welcome), .outdated(let client, let welcome): return (client, welcome)
    case .incompatible: throw DaemonSupervisorError.daemonDidNotStart
    }
}

@Suite(.serialized) struct DaemonSupervision {
    @Test func startsTheDaemonWhenNothingIsListening() throws {
        let scratch = ScratchInstallation()
        guard case .ready(_, let welcome) = try scratch.supervisor().connect() else {
            Issue.record("expected a daemon of this build")
            return
        }
        #expect(welcome.installation == .development)
        #expect(welcome.daemonVersion == HubAgentVersion.current)
    }

    @Test func theDaemonRunsInASessionOfItsOwn() throws {
        let scratch = ScratchInstallation()
        let (_, welcome) = try client(try scratch.supervisor().connect())
        let daemonProcess = try #require(welcome.processId)
        #expect(daemonProcess != getpid())
        #expect(getsid(daemonProcess) == daemonProcess, "the daemon shares the session of whoever started it")
        #expect(getsid(daemonProcess) != getsid(0))
    }

    @Test func reusesTheRunningDaemonInsteadOfStartingAnother() throws {
        let scratch = ScratchInstallation()
        let (_, first) = try client(try scratch.supervisor().connect())
        let launcher = RecordingLauncher()
        let (_, second) = try client(try scratch.supervisor(launcher: launcher).connect())
        #expect(launcher.launchCount == 0)
        #expect(second.processId == first.processId)
    }

    @Test func terminalsSurviveTheAppGoingAway() throws {
        let scratch = ScratchInstallation()
        let (firstClient, _) = try client(try scratch.supervisor().connect())
        let first = DaemonSession(firstClient)
        let session = try first.createSession(in: scratch.home)
        firstClient.disconnect()
        #expect(first.inbox.waitForDisconnect())

        let (secondClient, _) = try client(try scratch.supervisor().connect())
        let sessions = try DaemonSession(secondClient).listSessions()
        #expect(sessions.map(\.id) == [session.id])
        #expect(sessions.first?.state == .running)
        #expect(kill(session.processId, 0) == 0)
    }

    @Test func aDaemonFromAnotherBuildKeepsWorkingUntilReplacementIsConfirmed() throws {
        let scratch = ScratchInstallation()
        let (oldClient, old) = try client(try scratch.supervisor().connect())
        let session = try DaemonSession(oldClient).createSession(in: scratch.home)
        oldClient.disconnect()

        // The same daemon, seen by an app that expects another version.
        let newer = scratch.supervisor(expecting: "9.9.9")
        guard case .outdated(let client, let welcome) = try newer.connect() else {
            Issue.record("expected the daemon to be reported as outdated")
            return
        }
        #expect(welcome.processId == old.processId)
        #expect(try DaemonSession(client).listSessions().map(\.id) == [session.id])
        #expect(kill(session.processId, 0) == 0, "the terminal was lost before any confirmation")
        client.disconnect()

        let (replacementClient, replacement) = try HubAgentAppTests.client(try newer.replaceDaemon())
        #expect(replacement.processId != old.processId)
        #expect(try DaemonSession(replacementClient).listSessions().isEmpty)
        #expect(kill(try #require(old.processId), 0) != 0, "the old daemon is still running")
    }

    @Test func anIncompatibleDaemonIsReportedAndLeftAlone() throws {
        let rejection = RejectedReply(reason: "too old", daemonProtocolVersion: 9, daemonMinimumProtocolVersion: 8)
        let daemon = try ScriptedDaemon(reply: .rejected(rejection), thenClose: true)
        let launcher = RecordingLauncher()
        let endpoint = DaemonEndpoint(
            installation: Installation(kind: .development), executablePath: "/nonexistent", socketPath: daemon.path)
        let supervisor = DaemonSupervisor(endpoint: endpoint, launcher: launcher)
        guard case .incompatible(let reported) = try supervisor.connect() else {
            Issue.record("expected an incompatible daemon")
            return
        }
        #expect(reported == rejection)
        #expect(launcher.launchCount == 0)
    }

    @Test func refusesADaemonOfTheOtherCopy() throws {
        let welcome = WelcomeReply(
            protocolVersion: 1, daemonVersion: HubAgentVersion.current, installation: .production)
        let daemon = try ScriptedDaemon(reply: .welcome(welcome))
        let endpoint = DaemonEndpoint(
            installation: Installation(kind: .development), executablePath: "/nonexistent", socketPath: daemon.path)
        let supervisor = DaemonSupervisor(endpoint: endpoint, launcher: RecordingLauncher())
        #expect(throws: DaemonSupervisorError.wrongInstallation(.production)) { _ = try supervisor.connect() }
    }

    @Test func stoppingTheDaemonEndsItsTerminals() throws {
        let scratch = ScratchInstallation()
        let supervisor = scratch.supervisor()
        let (daemonClient, welcome) = try client(try supervisor.connect())
        let session = try DaemonSession(daemonClient).createSession(in: scratch.home)
        try supervisor.stopDaemon()
        #expect(kill(try #require(welcome.processId), 0) != 0)
        #expect(kill(session.processId, 0) != 0)
        #expect(!FileManager.default.fileExists(atPath: scratch.endpoint.socketPath))
    }

    @Test func stoppingWhenNothingRunsDoesNothing() throws {
        let scratch = ScratchInstallation()
        try scratch.supervisor().stopDaemon()
    }

    @Test func reportsADaemonThatNeverComesUp() {
        let scratch = ScratchInstallation()
        let supervisor = DaemonSupervisor(endpoint: scratch.endpoint, launcher: RecordingLauncher(), startTimeout: 0.3)
        #expect(throws: DaemonSupervisorError.daemonDidNotStart) { _ = try supervisor.connect() }
    }

    @Test func reportsAMissingDaemonProgram() {
        var endpoint = ScratchInstallation().endpoint
        endpoint.executablePath = "/nonexistent/HubAgentDaemon"
        let supervisor = DaemonSupervisor(endpoint: endpoint, launcher: ProcessDaemonLauncher())
        #expect(throws: DaemonLaunchError.executableNotFound(endpoint.executablePath)) { _ = try supervisor.connect() }
    }
}

@Suite struct LaunchdRegistration {
    private func endpoint(_ scratch: ScratchInstallation) -> DaemonEndpoint {
        DaemonEndpoint(installation: scratch.endpoint.installation, executablePath: BuiltProducts.daemonPath)
    }

    @Test func describesADaemonThatNeitherStartsAtLoginNorRestarts() throws {
        let scratch = ScratchInstallation(kind: .production)
        let endpoint = endpoint(scratch)
        let data = try LaunchAgent.data(for: endpoint)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "com.hubagent.daemon")
        #expect(plist["RunAtLoad"] as? Bool == false)
        #expect(plist["KeepAlive"] as? Bool == false)
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments.first == BuiltProducts.daemonPath)
        #expect(arguments.contains("production"))
        #expect(plist["StandardErrorPath"] as? String == endpoint.installation.daemonLogPath)
    }

    @Test func writesTheDescriptionAndAsksLaunchdToStartTheDaemon() throws {
        let scratch = ScratchInstallation()
        let endpoint = endpoint(scratch)
        let runner = RecordingRunner()
        let launcher = LaunchdDaemonLauncher(runner: runner, userId: 501)
        try launcher.launch(endpoint)

        let path = endpoint.installation.launchAgentPath
        #expect(path.hasPrefix(scratch.home))
        #expect(FileManager.default.contents(atPath: path) == (try LaunchAgent.data(for: endpoint)))
        let label = "com.hubagent.daemon.dev"
        #expect(
            runner.commands == [
                ["/bin/launchctl", "bootout", "gui/501/\(label)"],
                ["/bin/launchctl", "bootstrap", "gui/501", path],
                ["/bin/launchctl", "kickstart", "gui/501/\(label)"],
            ])
    }

    @Test func anUnchangedDescriptionIsNotReloaded() throws {
        let scratch = ScratchInstallation()
        let runner = RecordingRunner()
        let launcher = LaunchdDaemonLauncher(runner: runner, userId: 501)
        try launcher.launch(endpoint(scratch))
        try launcher.launch(endpoint(scratch))
        #expect(runner.commands.filter { $0.contains("bootout") }.count == 1)
        #expect(runner.commands.filter { $0.contains("kickstart") }.count == 2)
    }

    @Test func reportsWhenLaunchdRefusesToStartTheDaemon() throws {
        let scratch = ScratchInstallation()
        let runner = RecordingRunner()
        runner.failing = "kickstart"
        let launcher = LaunchdDaemonLauncher(runner: runner, userId: 501)
        #expect(throws: DaemonLaunchError.self) { try launcher.launch(endpoint(scratch)) }
    }
}
