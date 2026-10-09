import Foundation
import ProtoCore
import SwiftTerm

/// Headless client that plays the app's role: it keeps its own emulator, fed only by
/// what the daemon sends, and compares its state with the daemon's.
///
/// Script commands (one per line, read from standard input):
///   create DIR COLS ROWS | attach COLS ROWS | detach | reconnect
///   type TEXT (escapes: \r \n \e \t \xHH \\) | wait SECONDS | waitfor SECONDS TEXT
///   compare NAME | screen | resize COLS ROWS | answering daemon|app|both|none
///   stats | list | adopt [ID-PREFIX] (use a live session) | kill | expect TEXT | reject TEXT | throughput SECONDS
final class Probe: TerminalDelegate {
    let socketPath: String
    var fd: Int32 = -1
    var parser = FrameParser()
    var terminal: Terminal!
    var modes = ModeTracker()
    var sessionId: String?
    var appAnswers = false
    var appReplies = 0
    var failures = 0
    var outputBytes = 0
    var lastDump: DumpReply?
    var sessionExited = false
    var knownSessions: [SessionInfo] = []

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func connect() {
        guard let connected = SocketIO.connect(path: socketPath) else {
            report("FAIL cannot connect to \(socketPath)")
            exit(2)
        }
        fd = connected
        parser = FrameParser()
    }

    func report(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    func fail(_ message: String) {
        failures += 1
        report("FAIL \(message)")
    }

    func send(_ frame: Frame) {
        SocketIO.writeAll(fd, frame.encoded())
    }

    /// Emulator replies to program queries; forwarded only in the "app answers" experiments.
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        appReplies += 1
        if appAnswers { send(Frame(type: .input, payload: Array(data))) }
    }

    func handle(_ frame: Frame) {
        switch frame.type {
        case .snapshot, .output:
            if frame.type == .output { outputBytes += frame.payload.count }
            terminal.feed(byteArray: frame.payload)
            modes.consume(frame.payload[...])
        case .created:
            sessionId = frame.decode(SessionInfo.self)?.sessionId
        case .dumped:
            lastDump = frame.decode(DumpReply.self)
        case .exited:
            sessionExited = true
            report("EVENT session exited code=\(frame.decode(SessionInfo.self)?.exitCode.map(String.init) ?? "nil")")
        case .sessions:
            let list = frame.decode([SessionInfo].self) ?? []
            knownSessions = list
            report("SESSIONS \(list.map { "\($0.sessionId.prefix(8)) \($0.columns)x\($0.rows) exited=\($0.exited)" })")
        case .failure:
            fail("daemon: \(String(decoding: frame.payload, as: UTF8.self))")
        default:
            break
        }
    }

    /// Reads frames until `done` returns true or the time runs out.
    @discardableResult
    func pump(seconds: Double, until done: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            guard let bytes = SocketIO.read(fd, timeoutMilliseconds: Int32(min(remaining, 0.05) * 1000) + 1) else {
                fail("connection closed by daemon")
                return false
            }
            for frame in parser.append(bytes[...]) { handle(frame) }
        }
        return true
    }

    func localDump() -> GridDump {
        GridDump(terminal: terminal, modes: modes)
    }

    func resetLocalEmulator(columns: Int, rows: Int) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: columns, rows: rows, scrollback: 5000))
        modes = ModeTracker()
    }

    func unescape(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\"), let next = iterator.next() else {
                bytes.append(byte)
                continue
            }
            switch next {
            case UInt8(ascii: "r"): bytes.append(0x0d)
            case UInt8(ascii: "n"): bytes.append(0x0a)
            case UInt8(ascii: "e"): bytes.append(0x1b)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "x"):
                let digits = [iterator.next(), iterator.next()].compactMap { $0 }
                bytes.append(UInt8(String(decoding: digits, as: UTF8.self), radix: 16) ?? 0)
            default: bytes.append(next)
            }
        }
        return bytes
    }

    func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let command = parts.first, !command.hasPrefix("#") else { return }
        let argument = parts.count > 1 ? parts[1] : ""
        let words = argument.split(separator: " ").map(String.init)
        switch command {
        case "create":
            guard words.count == 3, let columns = Int(words[1]), let rows = Int(words[2]) else { return fail("usage") }
            sessionId = nil
            send(Frame.json(.create, CreateRequest(workingDirectory: words[0], columns: columns, rows: rows)))
            if !pump(seconds: 5, until: { self.sessionId != nil || self.failures > 0 }) { fail("create timed out") }
            attach(columns: columns, rows: rows)
        case "attach":
            guard words.count == 2, let columns = Int(words[0]), let rows = Int(words[1]) else { return fail("usage") }
            attach(columns: columns, rows: rows)
        case "detach":
            send(Frame(type: .detach))
        case "reconnect":
            close(fd)
            connect()
        case "type":
            send(Frame(type: .input, payload: unescape(argument)))
        case "wait":
            pump(seconds: Double(argument) ?? 1)
        case "waitfor":
            let pieces = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let seconds = Double(pieces[0]) else { return fail("usage") }
            if !pump(seconds: seconds, until: { self.localDump().visibleText.contains(pieces[1]) }) {
                fail("waitfor timed out: \(pieces[1])")
            }
        case "expect":
            if !localDump().visibleText.contains(argument) {
                fail("expected on screen: \(argument)")
            } else {
                report("OK   screen shows: \(argument)")
            }
        case "reject":
            if localDump().visibleText.contains(argument) {
                fail("unexpected on screen: \(argument)")
            } else {
                report("OK   screen does not show: \(argument)")
            }
        case "compare":
            compare(name: argument)
        case "screen":
            report("----- screen -----\n\(localDump().visibleText)\n------------------")
        case "resize":
            guard words.count == 2, let columns = Int(words[0]), let rows = Int(words[1]) else { return fail("usage") }
            terminal.resize(cols: columns, rows: rows)
            send(Frame.json(.resize, ResizeRequest(columns: columns, rows: rows)))
        case "answering":
            appAnswers = argument == "app" || argument == "both"
            send(Frame.json(.setAnswering, AnsweringRequest(daemonAnswers: argument == "daemon" || argument == "both")))
        case "stats":
            requestDump()
            if let dump = lastDump {
                report(
                    "STATS daemonAnswered=\(dump.answeredQueries) appEmulatorReplies=\(appReplies) "
                        + "daemonResidentMB=\(dump.residentBytes / 1_048_576) daemonOutputBytes=\(dump.totalOutputBytes) "
                        + "history=\(dump.grid.historyLines)")
            }
        case "throughput":
            measureThroughput(seconds: Double(argument) ?? 5)
        case "list":
            send(Frame(type: .list))
            pump(seconds: 0.5)
        case "adopt":
            send(Frame(type: .list))
            pump(seconds: 0.5)
            sessionId = knownSessions.first { !$0.exited && $0.sessionId.hasPrefix(argument) }?.sessionId
        case "kill":
            send(Frame(type: .kill))
            pump(seconds: 3, until: { self.sessionExited })
        default:
            fail("unknown command \(command)")
        }
    }

    func attach(columns: Int, rows: Int) {
        guard let sessionId else { return fail("no session") }
        resetLocalEmulator(columns: columns, rows: rows)
        send(Frame.json(.attach, AttachRequest(sessionId: sessionId, columns: columns, rows: rows)))
    }

    func requestDump() {
        lastDump = nil
        send(Frame(type: .dump))
        if !pump(seconds: 20, until: { self.lastDump != nil }) { fail("dump timed out") }
    }

    /// The daemon answers the dump request in stream order, so every byte it produced
    /// before the dump has already been fed to the local emulator when the reply arrives.
    func compare(name: String) {
        requestDump()
        guard let daemon = lastDump?.grid else { return }
        let local = localDump()
        let differences = local.differences(from: daemon)
        let summary =
            "\(daemon.columns)x\(daemon.rows) history=\(daemon.historyLines) alt=\(daemon.alternateScreen) "
            + "cursor=\(daemon.cursorX),\(daemon.cursorY) modes{\(daemon.trackedModes)}"
        if differences.isEmpty {
            report("SAME \(name): \(summary)")
        } else {
            failures += 1
            report("DIFF \(name): \(summary)\n  " + differences.joined(separator: "\n  "))
        }
    }

    func measureThroughput(seconds: Double) {
        let startBytes = outputBytes
        let start = Date()
        pump(seconds: seconds)
        let elapsed = Date().timeIntervalSince(start)
        let megabytes = Double(outputBytes - startBytes) / 1_048_576
        report(String(format: "THROUGHPUT %.1f MB in %.1fs = %.1f MB/s", megabytes, elapsed, megabytes / elapsed))
    }
}

let arguments = CommandLine.arguments
guard let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count else {
    logLine("usage: proto-probe --socket PATH < script")
    exit(2)
}
signal(SIGPIPE, SIG_IGN)
let probe = Probe(socketPath: arguments[index + 1])
probe.connect()
while let line = readLine() {
    probe.run(line.trimmingCharacters(in: .whitespaces))
}
probe.report(probe.failures == 0 ? "RESULT all checks passed" : "RESULT \(probe.failures) failure(s)")
exit(probe.failures == 0 ? 0 : 1)
