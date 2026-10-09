import Foundation

/// Wire format: 4-byte big-endian length (type + payload), 1-byte type, payload.
public enum MessageType: UInt8 {
    case create = 1
    case attach = 2
    case input = 3
    case resize = 4
    case list = 5
    case kill = 6
    case dump = 7
    case detach = 8
    case setAnswering = 9

    case created = 101
    case snapshot = 102
    case output = 103
    case sessions = 104
    case exited = 105
    case dumped = 106
    case failure = 107
}

public struct Frame {
    public let type: MessageType
    public let payload: [UInt8]

    public init(type: MessageType, payload: [UInt8] = []) {
        self.type = type
        self.payload = payload
    }

    public func encoded() -> [UInt8] {
        let length = UInt32(payload.count + 1)
        var bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
            type.rawValue,
        ]
        bytes.append(contentsOf: payload)
        return bytes
    }

    public static func json<T: Encodable>(_ type: MessageType, _ value: T) -> Frame {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return Frame(type: type, payload: [UInt8](data))
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(payload))
    }
}

public struct FrameParser {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: ArraySlice<UInt8>) -> [Frame] {
        pending.append(contentsOf: bytes)
        var frames: [Frame] = []
        var offset = 0
        while pending.count - offset >= 5 {
            let length =
                Int(pending[offset]) << 24 | Int(pending[offset + 1]) << 16
                | Int(pending[offset + 2]) << 8 | Int(pending[offset + 3])
            guard pending.count - offset >= 4 + length else { break }
            let body = pending[(offset + 5)..<(offset + 4 + length)]
            if let type = MessageType(rawValue: pending[offset + 4]) {
                frames.append(Frame(type: type, payload: Array(body)))
            }
            offset += 4 + length
        }
        pending.removeFirst(offset)
        return frames
    }
}

public struct CreateRequest: Codable {
    public var workingDirectory: String
    public var columns: Int
    public var rows: Int
    public var label: [String: String]

    public init(workingDirectory: String, columns: Int, rows: Int, label: [String: String] = [:]) {
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
        self.label = label
    }
}

public struct AttachRequest: Codable {
    public var sessionId: String
    public var columns: Int
    public var rows: Int

    public init(sessionId: String, columns: Int, rows: Int) {
        self.sessionId = sessionId
        self.columns = columns
        self.rows = rows
    }
}

public struct ResizeRequest: Codable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public struct AnsweringRequest: Codable {
    public var daemonAnswers: Bool

    public init(daemonAnswers: Bool) {
        self.daemonAnswers = daemonAnswers
    }
}

public struct SessionInfo: Codable {
    public var sessionId: String
    public var columns: Int
    public var rows: Int
    public var exitCode: Int32?
    public var exited: Bool
    public var label: [String: String]
    public var title: String?

    public init(
        sessionId: String, columns: Int, rows: Int, exitCode: Int32?, exited: Bool, label: [String: String],
        title: String?
    ) {
        self.sessionId = sessionId
        self.columns = columns
        self.rows = rows
        self.exitCode = exitCode
        self.exited = exited
        self.label = label
        self.title = title
    }
}

public struct DumpReply: Codable {
    public var grid: GridDump
    public var answeredQueries: Int
    public var residentBytes: UInt64
    public var totalOutputBytes: UInt64

    public init(grid: GridDump, answeredQueries: Int, residentBytes: UInt64, totalOutputBytes: UInt64) {
        self.grid = grid
        self.answeredQueries = answeredQueries
        self.residentBytes = residentBytes
        self.totalOutputBytes = totalOutputBytes
    }
}
