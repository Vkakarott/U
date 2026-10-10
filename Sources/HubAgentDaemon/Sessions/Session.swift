import Foundation
import HubAgentShared
import os

struct SessionConfiguration: Sendable {
    /// Lines of history each terminal keeps. Bounds the daemon's memory per session.
    var historyLines = 10_000
    /// Wait after the last resize before sending the client a fresh screen, so a
    /// window being dragged does not trigger one screen per step.
    var resizeRefreshDelay: TimeInterval = 0.15
    /// Time given to a hung-up shell before it is killed.
    var forceKillDelay: TimeInterval = 1
}

/// One terminal: a pseudo-terminal, its process and the emulator that tracks its
/// screen. Lives entirely on the daemon's queue.
final class Session: @unchecked Sendable {
    let id: UUID
    let label: [String: String]
    let workingDirectory: String
    let createdAt = Date()
    private(set) var size: TerminalSize
    private(set) var state = SessionDescriptor.State.running
    private(set) var exitCode: Int32?

    var onOutput: (([UInt8]) -> Void)?
    /// A complete screen the attached client must take in place of what it has.
    var onScreenRefresh: (([UInt8]) -> Void)?
    var onExit: (() -> Void)?

    private let terminal: PseudoTerminal
    private let emulator: HeadlessEmulator
    private let queue: DispatchQueue
    private let configuration: SessionConfiguration
    private var pendingRefresh: DispatchWorkItem?
    private let logger = Logger(subsystem: "com.hubagent.daemon", category: "session")

    init(
        request: CreateSessionRequest, terminal: PseudoTerminal, emulator: HeadlessEmulator, queue: DispatchQueue,
        configuration: SessionConfiguration
    ) {
        id = UUID()
        label = request.label
        workingDirectory = request.workingDirectory
        size = request.size
        self.terminal = terminal
        self.emulator = emulator
        self.queue = queue
        self.configuration = configuration
        connect()
    }

    private func connect() {
        terminal.onOutput = { [weak self] in self?.receive($0) }
        terminal.onExit = { [weak self] in self?.finish(exitCode: $0) }
        // Only the daemon answers program queries: it is the one emulator that is
        // always running, and a second answer would reach the program as typed text.
        emulator.onReply = { [weak self] in self?.terminal.write($0) }
    }

    func start(_ launch: ProcessLaunch) throws {
        try terminal.start(launch, size: size)
    }

    var descriptor: SessionDescriptor {
        SessionDescriptor(
            id: id, workingDirectory: workingDirectory, columns: size.columns, rows: size.rows,
            processId: terminal.processId, label: label, createdAt: createdAt, state: state, exitCode: exitCode)
    }

    func write(_ bytes: [UInt8]) {
        guard state == .running else { return }
        terminal.write(bytes)
    }

    func resize(_ newSize: TerminalSize) {
        guard newSize != size else { return }
        size = newSize
        if state == .running { terminal.resize(newSize) }
        emulator.resize(newSize)
        scheduleScreenRefresh()
    }

    func setTheme(_ colors: ThemeColors) {
        emulator.setTheme(colors)
    }

    func screen() -> [UInt8] {
        emulator.screen()
    }

    /// Hangs the shell up (it forwards the signal to its jobs) and kills it if it is
    /// still there after a grace period. An interactive shell ignores SIGTERM.
    func terminate() {
        guard state == .running else { return }
        terminal.send(signal: SIGHUP)
        queue.asyncAfter(deadline: .now() + configuration.forceKillDelay) { [weak self] in
            guard let self, self.state == .running else { return }
            self.logger.notice("session \(self.id, privacy: .public) ignored hangup; killing")
            self.terminal.send(signal: SIGKILL)
        }
    }

    private func receive(_ bytes: ArraySlice<UInt8>) {
        emulator.feed(bytes)
        onOutput?(Array(bytes))
    }

    private func finish(exitCode: Int32?) {
        state = .exited
        self.exitCode = exitCode
        pendingRefresh?.cancel()
        onExit?()
    }

    /// After a resize the client's emulator and this one have laid out in-flight
    /// output at different widths; a fresh screen puts them back in agreement.
    private func scheduleScreenRefresh() {
        pendingRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onScreenRefresh?(self.screen())
        }
        pendingRefresh = refresh
        queue.asyncAfter(deadline: .now() + configuration.resizeRefreshDelay, execute: refresh)
    }
}
