import Foundation
import HubAgentShared
import os

/// A connected client, as the session manager sees it.
protocol SessionClient: AnyObject {
    func receive(_ message: DaemonMessage)
}

/// Owns every terminal session. It knows nothing about projects, tabs or how clients
/// connect, and it lives entirely on the daemon's queue.
final class SessionManager: @unchecked Sendable {
    typealias TerminalFactory = () -> PseudoTerminal
    typealias EmulatorFactory = (TerminalSize, Int) -> HeadlessEmulator

    private let queue: DispatchQueue
    private let configuration: SessionConfiguration
    private let launcher: ShellLauncher
    private let makeTerminal: TerminalFactory
    private let makeEmulator: EmulatorFactory
    private var sessions: [UUID: Session] = [:]
    /// Each session has at most one client in v1.
    private var clients: [UUID: SessionClient] = [:]
    private var theme: ThemeColors?
    private let logger = Logger(subsystem: "com.hubagent.daemon", category: "sessions")

    init(
        queue: DispatchQueue, configuration: SessionConfiguration = SessionConfiguration(),
        launcher: ShellLauncher = LoginShellLauncher(), makeTerminal: TerminalFactory? = nil,
        makeEmulator: EmulatorFactory? = nil
    ) {
        self.queue = queue
        self.configuration = configuration
        self.launcher = launcher
        self.makeTerminal = makeTerminal ?? { LocalPseudoTerminal(queue: queue) }
        self.makeEmulator = makeEmulator ?? { SwiftTermHeadlessEmulator(size: $0, historyLines: $1) }
    }

    func createSession(_ request: CreateSessionRequest) -> Result<SessionDescriptor, FailureReply> {
        if let failure = validate(request) { return .failure(failure) }
        let session = Session(
            request: request, terminal: makeTerminal(),
            emulator: makeEmulator(request.size, configuration.historyLines), queue: queue,
            configuration: configuration)
        if let theme { session.setTheme(theme) }
        observe(session)
        do {
            try session.start(launcher.launch(workingDirectory: request.workingDirectory))
        } catch {
            return .failure(FailureReply(code: .launchFailed, message: "\(error)", requestId: request.requestId))
        }
        sessions[session.id] = session
        logger.info("created session \(session.id, privacy: .public)")
        return .success(session.descriptor)
    }

    func listSessions() -> [SessionDescriptor] {
        sessions.values.map(\.descriptor).sorted { $0.createdAt < $1.createdAt }
    }

    /// Attaches the client, replacing whoever was attached, and sends it the screen.
    func attach(sessionId: UUID, size: TerminalSize, client: SessionClient) -> FailureReply? {
        guard let session = sessions[sessionId] else { return notFound(sessionId) }
        guard size.isValid else { return invalidSize(sessionId: sessionId) }
        if let previous = clients[sessionId], previous !== client {
            previous.receive(.detached(sessionId: sessionId, reason: .takenOver))
        }
        clients[sessionId] = client
        session.resize(size)
        client.receive(.screen(sessionId: sessionId, bytes: session.screen()))
        if session.state == .exited {
            client.receive(.sessionExited(sessionId: sessionId, exitCode: session.exitCode))
        }
        return nil
    }

    func detach(sessionId: UUID, client: SessionClient) {
        guard clients[sessionId] === client else { return }
        clients[sessionId] = nil
        client.receive(.detached(sessionId: sessionId, reason: .requested))
    }

    /// Forgets a client that went away. Its sessions keep running.
    func disconnect(_ client: SessionClient) {
        clients = clients.filter { $0.value !== client }
    }

    func write(sessionId: UUID, bytes: [UInt8], client: SessionClient) {
        guard clients[sessionId] === client else { return }
        sessions[sessionId]?.write(bytes)
    }

    func resize(sessionId: UUID, size: TerminalSize, client: SessionClient) -> FailureReply? {
        guard let session = sessions[sessionId] else { return notFound(sessionId) }
        guard size.isValid else { return invalidSize(sessionId: sessionId) }
        guard clients[sessionId] === client else { return nil }
        session.resize(size)
        return nil
    }

    func terminate(sessionId: UUID) -> FailureReply? {
        guard let session = sessions[sessionId] else { return notFound(sessionId) }
        session.terminate()
        return nil
    }

    /// Drops a finished session once its client has seen that it ended.
    func acknowledgeExit(sessionId: UUID) {
        guard let session = sessions[sessionId], session.state == .exited else { return }
        sessions[sessionId] = nil
        clients[sessionId] = nil
    }

    func setTheme(_ colors: ThemeColors) {
        theme = colors
        for session in sessions.values { session.setTheme(colors) }
    }

    /// A fresh screen for a client that fell behind and had output dropped.
    func screen(sessionId: UUID) -> [UInt8]? {
        sessions[sessionId]?.screen()
    }

    func terminateAll() {
        for session in sessions.values { session.terminate() }
    }

    var runningSessionCount: Int { sessions.values.filter { $0.state == .running }.count }

    private func observe(_ session: Session) {
        let sessionId = session.id
        session.onOutput = { [weak self] bytes in
            self?.clients[sessionId]?.receive(.output(sessionId: sessionId, bytes: bytes))
        }
        session.onScreenRefresh = { [weak self] bytes in
            self?.clients[sessionId]?.receive(.screen(sessionId: sessionId, bytes: bytes))
        }
        session.onExit = { [weak self, weak session] in
            self?.logger.info("session \(sessionId, privacy: .public) exited")
            self?.clients[sessionId]?.receive(.sessionExited(sessionId: sessionId, exitCode: session?.exitCode))
        }
    }

    private func validate(_ request: CreateSessionRequest) -> FailureReply? {
        guard request.size.isValid else { return invalidSize(requestId: request.requestId) }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: request.workingDirectory, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            return FailureReply(
                code: .workingDirectoryNotFound, message: request.workingDirectory, requestId: request.requestId)
        }
        return Self.canEnter(request.workingDirectory)
            ? nil
            : FailureReply(
                code: .workingDirectoryNotAccessible, message: request.workingDirectory, requestId: request.requestId)
    }

    /// Opens the folder the way the new shell will have to. A folder that exists but
    /// cannot be entered would otherwise leave the shell, silently, wherever the
    /// daemon itself happens to be.
    private static func canEnter(_ directory: String) -> Bool {
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return access(directory, X_OK) == 0
    }

    private func notFound(_ sessionId: UUID) -> FailureReply {
        FailureReply(code: .sessionNotFound, message: sessionId.uuidString, sessionId: sessionId)
    }

    private func invalidSize(requestId: UInt32? = nil, sessionId: UUID? = nil) -> FailureReply {
        FailureReply(code: .invalidSize, message: "size out of range", requestId: requestId, sessionId: sessionId)
    }
}
