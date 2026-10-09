import Foundation
import ProtoCore
import SwiftTerm

let scrollbackLines = 5000
let queue = DispatchQueue(label: "proto.daemon")
var sessions: [String: Session] = [:]
var clients: [Int32: ClientConnection] = [:]
var daemonAnswersQueries = true

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

/// Environment built from the account record, never inherited, to mimic launchd.
func loginEnvironment() -> (shell: String, variables: [String]) {
    let record = getpwuid(getuid())
    let home = record.flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    let user = record.flatMap { String(validatingCString: $0.pointee.pw_name) } ?? NSUserName()
    let shell = record.flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
    var variables = [
        "HOME=\(home)", "USER=\(user)", "LOGNAME=\(user)", "SHELL=\(shell)",
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TERM=xterm-256color", "COLORTERM=truecolor",
        "LANG=en_US.UTF-8", "TERM_PROGRAM=HubAgentProto",
    ]
    if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] { variables.append("TMPDIR=\(temporary)") }
    return (shell, variables)
}

final class Session: TerminalDelegate, LocalProcessDelegate {
    let sessionId = UUID().uuidString
    let label: [String: String]
    var terminal: Terminal!
    var process: LocalProcess!
    var modes = ModeTracker()
    var hiddenNormalScreen: String?
    var title: String?
    var columns: Int
    var rows: Int
    var exited = false
    var exitCode: Int32?
    var answeredQueries = 0
    var totalOutputBytes: UInt64 = 0
    weak var attached: ClientConnection?

    init(request: CreateRequest) {
        label = request.label
        columns = request.columns
        rows = request.rows
        let options = TerminalOptions(cols: columns, rows: rows, scrollback: scrollbackLines)
        terminal = Terminal(delegate: self, options: options)
        process = LocalProcess(delegate: self, dispatchQueue: queue)
        let login = loginEnvironment()
        let shellName = "-" + (login.shell as NSString).lastPathComponent
        process.startProcess(
            executable: login.shell, args: [], environment: login.variables, execName: shellName,
            currentDirectory: request.workingDirectory)
    }

    func resize(columns: Int, rows: Int) {
        guard columns != self.columns || rows != self.rows else { return }
        self.columns = columns
        self.rows = rows
        var size = getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
        terminal.terminalLock.withLock { terminal.resize(cols: columns, rows: rows) }
    }

    /// An interactive shell ignores SIGTERM, so hang up first (the shell forwards it to
    /// its jobs) and force-kill whatever is left.
    func terminate() {
        let shell = process.shellPid
        guard !exited, shell > 0 else { return }
        kill(shell, SIGHUP)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.exited else { return }
            kill(shell, SIGKILL)
        }
    }

    func snapshot() -> [UInt8] {
        terminal.terminalLock.withLock {
            ScreenSerializer.serialize(
                terminal: terminal, modes: modes, title: title, hiddenNormalScreen: hiddenNormalScreen)
        }
    }

    func dump() -> DumpReply {
        let grid = terminal.terminalLock.withLock { GridDump(terminal: terminal, modes: modes) }
        return DumpReply(
            grid: grid, answeredQueries: answeredQueries, residentBytes: residentBytes(),
            totalOutputBytes: totalOutputBytes)
    }

    var info: SessionInfo {
        SessionInfo(
            sessionId: sessionId, columns: columns, rows: rows, exitCode: exitCode, exited: exited, label: label,
            title: title)
    }

    // MARK: LocalProcessDelegate

    func dataReceived(slice: ArraySlice<UInt8>) {
        totalOutputBytes += UInt64(slice.count)
        var start = slice.startIndex
        for entry in modes.consume(slice) {
            terminal.terminalLock.withLock {
                terminal.feed(buffer: slice[start..<entry])
                if !terminal.isCurrentBufferAlternate {
                    hiddenNormalScreen = ScreenSerializer.normalScreen(of: terminal)
                }
            }
            start = entry
        }
        terminal.terminalLock.withLock { terminal.feed(buffer: slice[start...]) }
        if !modes.isAlternateScreen { hiddenNormalScreen = nil }
        attached?.send(Frame(type: .output, payload: Array(slice)))
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        exited = true
        self.exitCode = exitCode
        logLine("session \(sessionId) exited code=\(exitCode.map(String.init) ?? "nil")")
        attached?.send(Frame.json(.exited, info))
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
    }

    // MARK: TerminalDelegate

    /// Replies the emulator generates for program queries (cursor position, device attributes...).
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard daemonAnswersQueries else { return }
        answeredQueries += 1
        process.send(data: data)
    }

    func setTerminalTitle(source: Terminal, title: String) {
        self.title = title
    }
}

final class ClientConnection {
    let fd: Int32
    var parser = FrameParser()
    var source: DispatchSourceRead?
    var session: Session?

    init(fd: Int32) {
        self.fd = fd
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in close(fd) }
        self.source = source
        source.resume()
    }

    func send(_ frame: Frame) {
        if !SocketIO.writeAll(fd, frame.encoded()) { disconnect() }
    }

    private func readAvailable() {
        guard let bytes = SocketIO.read(fd, timeoutMilliseconds: 0), !bytes.isEmpty else {
            disconnect()
            return
        }
        for frame in parser.append(bytes[...]) { handle(frame) }
    }

    func disconnect() {
        guard clients[fd] != nil else { return }
        clients[fd] = nil
        if session?.attached === self { session?.attached = nil }
        session = nil
        source?.cancel()
        logLine("client \(fd) disconnected; sessions alive: \(sessions.values.filter { !$0.exited }.count)")
    }

    private func handle(_ frame: Frame) {
        switch frame.type {
        case .create:
            guard let request = frame.decode(CreateRequest.self) else { return fail("bad create") }
            guard FileManager.default.fileExists(atPath: request.workingDirectory) else {
                return fail("working directory not found: \(request.workingDirectory)")
            }
            let created = Session(request: request)
            sessions[created.sessionId] = created
            send(Frame.json(.created, created.info))
        case .attach:
            guard let request = frame.decode(AttachRequest.self), let target = sessions[request.sessionId] else {
                return fail("unknown session")
            }
            attach(to: target, columns: request.columns, rows: request.rows)
        case .detach:
            if session?.attached === self { session?.attached = nil }
            session = nil
        case .input:
            session?.process.send(data: frame.payload[...])
        case .resize:
            guard let request = frame.decode(ResizeRequest.self) else { return }
            session?.resize(columns: request.columns, rows: request.rows)
        case .list:
            send(Frame.json(.sessions, sessions.values.map(\.info)))
        case .kill:
            session?.terminate()
        case .dump:
            guard let session else { return fail("not attached") }
            send(Frame.json(.dumped, session.dump()))
        case .setAnswering:
            guard let request = frame.decode(AnsweringRequest.self) else { return }
            daemonAnswersQueries = request.daemonAnswers
        default:
            fail("unexpected message \(frame.type)")
        }
    }

    /// One client per session: a new attach takes the session over.
    private func attach(to target: Session, columns: Int, rows: Int) {
        if let previous = target.attached, previous !== self { previous.session = nil }
        target.resize(columns: columns, rows: rows)
        let started = Date()
        let snapshot = target.snapshot()
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        logLine("snapshot session=\(target.sessionId.prefix(8)) bytes=\(snapshot.count) builtInMs=\(milliseconds)")
        send(Frame(type: .snapshot, payload: snapshot))
        target.attached = self
        session = target
        if target.exited { send(Frame.json(.exited, target.info)) }
    }

    private func fail(_ message: String) {
        send(Frame(type: .failure, payload: Array(message.utf8)))
    }
}

func socketPath() -> String {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count { return arguments[index + 1] }
    return NSTemporaryDirectory() + "hubagent-proto.sock"
}

signal(SIGPIPE, SIG_IGN)
let path = socketPath()
guard let listener = SocketIO.listen(path: path) else {
    logLine("cannot listen on \(path): \(String(cString: strerror(errno)))")
    exit(1)
}
let acceptSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
acceptSource.setEventHandler {
    let fd = accept(listener, nil, nil)
    guard fd >= 0 else { return }
    SocketIO.disableSigpipe(fd)
    let client = ClientConnection(fd: fd)
    clients[fd] = client
    client.start()
    logLine("client \(fd) connected")
}
acceptSource.resume()
logLine("proto-daemon pid=\(getpid()) parent=\(getppid()) listening on \(path)")
dispatchMain()
