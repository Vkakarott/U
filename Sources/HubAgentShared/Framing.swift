/// Errors raised while decoding protocol data. Any of them means the peer is not
/// speaking the protocol correctly and the connection should be closed.
public enum ProtocolError: Error, Equatable {
    case frameTooLarge(Int)
    case emptyFrame
    case unknownMessageKind(UInt8)
    case truncatedMessage
    case malformedPayload
}

/// Wire framing: a 4-byte big-endian length followed by that many body bytes.
///
/// The format is binary because terminal output is binary and high-volume; the same
/// frames can travel inside WebSocket messages when the mobile client arrives.
public enum Frame {
    public static let headerLength = 4
    /// Larger frames are treated as a protocol violation, not buffered.
    public static let defaultMaximumBodyLength = 32 * 1024 * 1024

    public static func encode(body: [UInt8]) -> [UInt8] {
        let length = UInt32(body.count)
        var frame: [UInt8] = []
        frame.reserveCapacity(headerLength + body.count)
        frame.append(UInt8(truncatingIfNeeded: length >> 24))
        frame.append(UInt8(truncatingIfNeeded: length >> 16))
        frame.append(UInt8(truncatingIfNeeded: length >> 8))
        frame.append(UInt8(truncatingIfNeeded: length))
        frame.append(contentsOf: body)
        return frame
    }
}

/// Reassembles frame bodies from a byte stream that arrives in arbitrary chunks.
public struct FrameDecoder: Sendable {
    private var pending: [UInt8] = []
    private let maximumBodyLength: Int

    public init(maximumBodyLength: Int = Frame.defaultMaximumBodyLength) {
        self.maximumBodyLength = maximumBodyLength
    }

    /// Appends received bytes and returns every body completed by them.
    public mutating func append(_ bytes: some Sequence<UInt8>) throws -> [[UInt8]] {
        pending.append(contentsOf: bytes)
        var bodies: [[UInt8]] = []
        var offset = 0
        while let length = try bodyLength(at: offset), pending.count - offset >= Frame.headerLength + length {
            let start = offset + Frame.headerLength
            bodies.append(Array(pending[start..<(start + length)]))
            offset = start + length
        }
        pending.removeFirst(offset)
        return bodies
    }

    private func bodyLength(at offset: Int) throws -> Int? {
        guard pending.count - offset >= Frame.headerLength else { return nil }
        let length = pending[offset..<(offset + Frame.headerLength)].reduce(0) { $0 << 8 | Int($1) }
        guard length > 0 else { throw ProtocolError.emptyFrame }
        guard length <= maximumBodyLength else { throw ProtocolError.frameTooLarge(length) }
        return length
    }
}
