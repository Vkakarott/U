import Foundation

/// A connected socket used with blocking calls: one thread reads, any thread may send.
public final class BlockingConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let sendLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false

    public init(descriptor: Int32) {
        self.descriptor = descriptor
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
        var remaining = bytes[...]
        while !remaining.isEmpty {
            guard case .wrote(let count) = UnixSocket.write(descriptor, remaining) else { throw SocketError.closed }
            remaining = remaining.dropFirst(count)
        }
    }

    /// Returns the next bytes, or throws `timedOut` when nothing arrives in time and
    /// `closed` when the peer is gone.
    public func receive(timeout: TimeInterval) throws -> [UInt8] {
        guard UnixSocket.waitReadable(descriptor, timeout: timeout) else { throw SocketError.timedOut }
        guard case .bytes(let bytes) = UnixSocket.read(descriptor) else { throw SocketError.closed }
        return bytes
    }

    public func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        // Wakes a thread blocked in `receive` before the descriptor goes away.
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }
}
