import Foundation

/// A connected socket used with blocking calls: one thread reads, any thread may send
/// and any thread may close.
public final class BlockingConnection: @unchecked Sendable {
    private let descriptor: Int32
    /// Written to by `close` to interrupt a thread waiting in `receive`.
    private var wakePipe: [Int32] = [-1, -1]
    private let sendLock = NSLock()
    private let receiveLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false

    public init(descriptor: Int32) {
        self.descriptor = descriptor
        if pipe(&wakePipe) == 0 {
            for end in wakePipe { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        }
    }

    public convenience init(path: String) throws {
        self.init(descriptor: try UnixSocket.connect(path: path))
    }

    deinit {
        close()
    }

    /// Writes all the bytes, keeping concurrent senders from interleaving their frames.
    public func send(_ bytes: [UInt8]) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard !closed else { throw SocketError.closed }
        var remaining = bytes[...]
        while !remaining.isEmpty {
            guard case .wrote(let count) = UnixSocket.write(descriptor, remaining) else { throw SocketError.closed }
            remaining = remaining.dropFirst(count)
        }
    }

    /// Returns the next bytes, or throws `timedOut` when nothing arrives in time and
    /// `closed` when the peer is gone or the connection was closed from this side.
    public func receive(timeout: TimeInterval) throws -> [UInt8] {
        receiveLock.lock()
        defer { receiveLock.unlock() }
        guard !closed else { throw SocketError.closed }
        guard UnixSocket.waitReadable(descriptor, orWoken: wakePipe[0], timeout: timeout) else {
            throw closed ? SocketError.closed : SocketError.timedOut
        }
        guard !closed, case .bytes(let bytes) = UnixSocket.read(descriptor) else { throw SocketError.closed }
        return bytes
    }

    /// Closes the connection. A thread waiting in `receive` is woken first and the
    /// descriptor is only released once nobody is using it: its number can be handed
    /// to the next socket opened, and a late reader would then steal that socket's data.
    public func close() {
        let wasClosed = stateLock.withLock {
            defer { isClosed = true }
            return isClosed
        }
        guard !wasClosed else { return }
        shutdown(descriptor, SHUT_RDWR)
        var wake: UInt8 = 1
        _ = write(wakePipe[1], &wake, 1)
        receiveLock.lock()
        sendLock.lock()
        Darwin.close(descriptor)
        for end in wakePipe where end >= 0 { Darwin.close(end) }
        sendLock.unlock()
        receiveLock.unlock()
    }

    private var closed: Bool { stateLock.withLock { isClosed } }
}
