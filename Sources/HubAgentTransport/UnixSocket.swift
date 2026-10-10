import Foundation

public enum SocketError: Error, Equatable {
    /// Unix socket paths are limited to about 100 bytes.
    case pathTooLong(String)
    case system(operation: String, code: Int32)
    case closed
    case timedOut
}

public enum ReadResult: Equatable, Sendable {
    case bytes([UInt8])
    case wouldBlock
    case closed
}

public enum WriteResult: Equatable, Sendable {
    case wrote(Int)
    case wouldBlock
    case failed
}

/// Thin wrappers over the POSIX calls for local stream sockets.
public enum UnixSocket {
    /// Creates a listening socket readable and writable only by its owner. Whoever can
    /// connect can run commands as the user, so the mode is part of the contract.
    ///
    /// The mode is set between `bind` and `listen`: nobody can connect before `listen`,
    /// so there is no window with looser permissions. The process umask is deliberately
    /// left alone, because it is process-wide and every terminal started meanwhile
    /// would inherit the temporary value.
    public static func listen(path: String, backlog: Int32 = 16) throws -> Int32 {
        var address = try makeAddress(path: path)
        unlink(path)
        let descriptor = try makeSocket()
        let bound = withSocketAddress(&address) { Darwin.bind(descriptor, $0, $1) }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, backlog) == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system(operation: "listen", code: code)
        }
        return descriptor
    }

    public static func connect(path: String) throws -> Int32 {
        var address = try makeAddress(path: path)
        let descriptor = try makeSocket()
        guard withSocketAddress(&address, { Darwin.connect(descriptor, $0, $1) }) == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system(operation: "connect", code: code)
        }
        return descriptor
    }

    public static func accept(listener: Int32) -> Int32? {
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else { return nil }
        configure(descriptor)
        return descriptor
    }

    public static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    public static func read(_ descriptor: Int32, maximumLength: Int = 65536) -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: maximumLength)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { return .bytes(Array(buffer[..<count])) }
            if count == 0 { return .closed }
            if errno == EINTR { continue }
            return errno == EAGAIN || errno == EWOULDBLOCK ? .wouldBlock : .closed
        }
    }

    public static func write(_ descriptor: Int32, _ bytes: ArraySlice<UInt8>) -> WriteResult {
        while true {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count >= 0 { return .wrote(count) }
            if errno == EINTR { continue }
            return errno == EAGAIN || errno == EWOULDBLOCK ? .wouldBlock : .failed
        }
    }

    /// Waits until the descriptor is readable. Returns false on timeout.
    public static func waitReadable(_ descriptor: Int32, timeout: TimeInterval) -> Bool {
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(0, min(timeout, 86_400)) * 1000)
        return poll(&entry, 1, milliseconds) > 0
    }

    /// Waits until the descriptor is readable or `wake` becomes readable. Returns true
    /// only when the descriptor itself has something to read.
    public static func waitReadable(_ descriptor: Int32, orWoken wake: Int32, timeout: TimeInterval) -> Bool {
        var entries = [
            pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
        ]
        let milliseconds = Int32(max(0, min(timeout, 86_400)) * 1000)
        guard poll(&entries, 2, milliseconds) > 0 else { return false }
        return entries[1].revents == 0 && entries[0].revents != 0
    }

    private static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.system(operation: "socket", code: errno) }
        configure(descriptor)
        return descriptor
    }

    /// Writing to a closed peer must fail instead of killing the process, and the
    /// socket must not leak into the programs started inside terminals.
    private static func configure(_ descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    private static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        return address
    }

    private static func withSocketAddress(
        _ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32
    ) -> Int32 {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
