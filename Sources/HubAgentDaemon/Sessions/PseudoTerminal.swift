import Foundation
import HubAgentShared
import SwiftTerm

/// What to run inside a terminal.
struct ProcessLaunch: Equatable {
    var executable: String
    var arguments: [String] = []
    /// `KEY=value` entries. Nothing is inherited from the daemon.
    var environment: [String]
    /// Value of `argv[0]`; a leading dash makes a shell behave as a login shell.
    var processName: String?
    var workingDirectory: String
}

enum PseudoTerminalError: Error, Equatable {
    case launchFailed(String)
}

/// A pseudo-terminal with one process attached. Callbacks arrive on the daemon's queue.
protocol PseudoTerminal: AnyObject {
    var processId: Int32 { get }
    var onOutput: ((ArraySlice<UInt8>) -> Void)? { get set }
    /// Receives the exit status, or nil when the process was killed by a signal.
    var onExit: ((Int32?) -> Void)? { get set }

    func start(_ launch: ProcessLaunch, size: TerminalSize) throws
    func write(_ bytes: [UInt8])
    func resize(_ size: TerminalSize)
    func send(signal: Int32)
}

/// `PseudoTerminal` backed by SwiftTerm's `LocalProcess`. Confined to the daemon's queue.
final class LocalPseudoTerminal: PseudoTerminal, LocalProcessDelegate, @unchecked Sendable {
    var onOutput: ((ArraySlice<UInt8>) -> Void)?
    var onExit: ((Int32?) -> Void)?

    private var process: LocalProcess!
    private var size = TerminalSize(columns: 80, rows: 24)

    init(queue: DispatchQueue) {
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }

    var processId: Int32 { process.shellPid }

    func start(_ launch: ProcessLaunch, size: TerminalSize) throws {
        self.size = size
        let result = process.startProcessChecked(
            executable: launch.executable, args: launch.arguments, environment: launch.environment,
            execName: launch.processName, currentDirectory: launch.workingDirectory)
        if case .failure(let error) = result { throw PseudoTerminalError.launchFailed("\(error)") }
    }

    func write(_ bytes: [UInt8]) {
        process.send(data: bytes[...])
    }

    func resize(_ size: TerminalSize) {
        self.size = size
        var window = getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &window)
    }

    func send(signal: Int32) {
        guard process.running, processId > 0 else { return }
        kill(processId, signal)
    }

    // MARK: LocalProcessDelegate

    func dataReceived(slice: ArraySlice<UInt8>) {
        onOutput?(slice)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        // SwiftTerm already reports the exit status, or nil for death by signal.
        onExit?(exitCode)
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.columns), ws_xpixel: 0, ws_ypixel: 0)
    }
}
