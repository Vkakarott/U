import Foundation
import HubAgentShared
import Testing

@testable import HubAgentDaemon

/// A bare `/bin/sh` with a fixed prompt, so tests do not depend on the user's shell setup.
struct PlainShellLauncher: ShellLauncher {
    func launch(workingDirectory: String) -> ProcessLaunch {
        ProcessLaunch(
            executable: "/bin/sh",
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color", "PS1=$ ", "HOME=\(workingDirectory)"],
            workingDirectory: workingDirectory)
    }
}

/// Plays the app's role: keeps its own emulator, fed only by what the daemon sends.
final class RecordingClient: SessionClient {
    private(set) var messages: [DaemonMessage] = []
    private var emulator: SwiftTermHeadlessEmulator?
    private let historyLines: Int

    init(historyLines: Int = 10_000) {
        self.historyLines = historyLines
    }

    func receive(_ message: DaemonMessage) {
        messages.append(message)
        switch message {
        case .screen(_, let bytes), .output(_, let bytes): emulator?.feed(bytes[...])
        default: break
        }
    }

    /// Must be called before attaching, with the size used to attach.
    func prepare(size: TerminalSize) {
        emulator = SwiftTermHeadlessEmulator(size: size, historyLines: historyLines)
    }

    func resizeEmulator(_ size: TerminalSize) {
        emulator?.resize(size)
    }

    var dump: EmulatorStateDump? { emulator?.stateDump() }
    var text: String { dump?.visibleText ?? "" }
    var screenCount: Int { messages.filter { if case .screen = $0 { true } else { false } }.count }

    var exitCodes: [Int32?] {
        messages.compactMap { if case .sessionExited(_, let code) = $0 { .some(code) } else { nil } }
    }

    var detachReasons: [DetachReason] {
        messages.compactMap { if case .detached(_, let reason) = $0 { reason } else { nil } }
    }
}

/// A session manager on its own queue, with helpers to observe it from a test.
final class DaemonHarness {
    static let size = TerminalSize(columns: 80, rows: 24)

    let queue = DispatchQueue(label: "hubagent.tests.daemon")
    let directory: String
    let manager: SessionManager
    init(configuration: SessionConfiguration = SessionConfiguration(), launcher: ShellLauncher = PlainShellLauncher()) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hubagent-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url.resolvingSymlinksInPath().path
        let box = EmulatorBox()
        manager = SessionManager(
            queue: queue, configuration: configuration, launcher: launcher,
            makeEmulator: { size, lines in
                let emulator = SwiftTermHeadlessEmulator(size: size, historyLines: lines)
                box.emulators.append(emulator)
                return emulator
            })
        self.box = box
        queue.setSpecific(key: Self.queueKey, value: queueIdentity)
    }

    private let box: EmulatorBox
    private static let queueKey = DispatchSpecificKey<UUID>()
    private let queueIdentity = UUID()

    deinit {
        queue.sync { manager.terminateAll() }
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// Runs the body on the daemon's queue; safe to nest.
    func sync<Value>(_ body: () throws -> Value) rethrows -> Value {
        try DispatchQueue.getSpecific(key: Self.queueKey) == queueIdentity ? body() : queue.sync(execute: body)
    }

    /// The daemon-side emulator of the n-th session created.
    func daemonDump(_ index: Int = 0) -> EmulatorStateDump {
        sync { box.emulators[index].stateDump() }
    }

    /// Polls a condition on the daemon's queue until it holds or the time runs out.
    ///
    /// The condition runs on the queue that also reads the terminals, so a costly
    /// condition polled often starves them; raise `interval` for those.
    func eventually(timeout: TimeInterval = 10, interval: TimeInterval = 0.02, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sync(condition) { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        return sync(condition)
    }

    func createSession(size: TerminalSize = DaemonHarness.size, label: [String: String] = [:]) -> SessionDescriptor? {
        let request = CreateSessionRequest(requestId: 1, workingDirectory: directory, size: size, label: label)
        return sync { try? manager.createSession(request).get() }
    }

    /// Creates a session and attaches a fresh client, waiting for the first prompt.
    func createAttachedSession(
        size: TerminalSize = DaemonHarness.size, historyLines: Int = 10_000
    ) -> (id: UUID, client: RecordingClient)? {
        guard let session = createSession(size: size) else { return nil }
        let client = attach(session.id, size: size, historyLines: historyLines)
        return eventually { client.text.contains("$") } ? (session.id, client) : nil
    }

    func attach(_ sessionId: UUID, size: TerminalSize = DaemonHarness.size, historyLines: Int = 10_000)
        -> RecordingClient
    {
        let client = RecordingClient(historyLines: historyLines)
        client.prepare(size: size)
        sync { _ = manager.attach(sessionId: sessionId, size: size, client: client) }
        return client
    }

    func type(_ text: String, into sessionId: UUID, as client: RecordingClient) {
        sync { manager.write(sessionId: sessionId, bytes: Array(text.utf8), client: client) }
    }
}

private final class EmulatorBox {
    var emulators: [SwiftTermHeadlessEmulator] = []
}

/// Parent of every suite that starts real terminals.
///
/// These tests block their thread while they wait for a terminal. Run all at once,
/// they occupy the whole thread pool that the terminals' own I/O also needs and time
/// out waiting for output that cannot be delivered. The daemon never blocks that
/// pool, so this is a constraint of the tests, not of the product.
@Suite(.serialized) struct TerminalTests {}
