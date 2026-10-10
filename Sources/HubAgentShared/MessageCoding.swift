import Foundation

/// Body layout: one kind byte, then the payload. Session-scoped messages start the
/// payload with the 16 raw bytes of the session id. Terminal data travels as raw
/// bytes; everything else is JSON.
struct BodyWriter {
    private(set) var bytes: [UInt8]

    init(kind: UInt8) {
        bytes = [kind]
    }

    mutating func append(_ sessionId: UUID) {
        withUnsafeBytes(of: sessionId.uuid) { bytes.append(contentsOf: $0) }
    }

    mutating func append(raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    mutating func append(json value: some Encodable) {
        // Encoding the protocol's own plain value types cannot fail.
        if let data = try? JSONEncoder().encode(value) { bytes.append(contentsOf: data) }
    }
}

struct BodyReader {
    private var remaining: ArraySlice<UInt8>

    init(payload: ArraySlice<UInt8>) {
        remaining = payload
    }

    mutating func sessionId() throws -> UUID {
        guard remaining.count >= 16 else { throw ProtocolError.truncatedMessage }
        var raw = UUID().uuid
        withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: remaining.prefix(16)) }
        remaining = remaining.dropFirst(16)
        return UUID(uuid: raw)
    }

    mutating func rest() -> [UInt8] {
        defer { remaining = [] }
        return Array(remaining)
    }

    mutating func json<Value: Decodable>(_ type: Value.Type) throws -> Value {
        guard let value = try? JSONDecoder().decode(type, from: Data(rest())) else {
            throw ProtocolError.malformedPayload
        }
        return value
    }
}

private struct ExitPayload: Codable {
    var exitCode: Int32?
}

extension ClientMessage {
    private enum Kind: UInt8 {
        case hello = 1
        case createSession = 2
        case listSessions = 3
        case attach = 4
        case detach = 5
        case input = 6
        case resize = 7
        case terminate = 8
        case acknowledgeExit = 9
        case setTheme = 10
        case shutdown = 11
    }

    public func encodedBody() -> [UInt8] {
        switch self {
        case .hello(let request): return Self.body(.hello, json: request)
        case .createSession(let request): return Self.body(.createSession, json: request)
        case .listSessions: return BodyWriter(kind: Kind.listSessions.rawValue).bytes
        case .attach(let sessionId, let size): return Self.body(.attach, sessionId, json: size)
        case .detach(let sessionId): return Self.body(.detach, sessionId)
        case .input(let sessionId, let bytes): return Self.body(.input, sessionId, raw: bytes)
        case .resize(let sessionId, let size): return Self.body(.resize, sessionId, json: size)
        case .terminate(let sessionId): return Self.body(.terminate, sessionId)
        case .acknowledgeExit(let sessionId): return Self.body(.acknowledgeExit, sessionId)
        case .setTheme(let colors): return Self.body(.setTheme, json: colors)
        case .shutdown: return BodyWriter(kind: Kind.shutdown.rawValue).bytes
        }
    }

    public init(body: [UInt8]) throws {
        guard let first = body.first else { throw ProtocolError.emptyFrame }
        guard let kind = Kind(rawValue: first) else { throw ProtocolError.unknownMessageKind(first) }
        var reader = BodyReader(payload: body.dropFirst())
        switch kind {
        case .hello: self = .hello(try reader.json(HelloRequest.self))
        case .createSession: self = .createSession(try reader.json(CreateSessionRequest.self))
        case .listSessions: self = .listSessions
        case .attach: self = .attach(sessionId: try reader.sessionId(), size: try reader.json(TerminalSize.self))
        case .detach: self = .detach(sessionId: try reader.sessionId())
        case .input: self = .input(sessionId: try reader.sessionId(), bytes: reader.rest())
        case .resize: self = .resize(sessionId: try reader.sessionId(), size: try reader.json(TerminalSize.self))
        case .terminate: self = .terminate(sessionId: try reader.sessionId())
        case .acknowledgeExit: self = .acknowledgeExit(sessionId: try reader.sessionId())
        case .setTheme: self = .setTheme(try reader.json(ThemeColors.self))
        case .shutdown: self = .shutdown
        }
    }

    private static func body(
        _ kind: Kind, _ sessionId: UUID? = nil, raw: [UInt8]? = nil, json: (any Encodable)? = nil
    ) -> [UInt8] {
        var writer = BodyWriter(kind: kind.rawValue)
        if let sessionId { writer.append(sessionId) }
        if let raw { writer.append(raw: raw) }
        if let json { writer.append(json: json) }
        return writer.bytes
    }
}

extension DaemonMessage {
    private enum Kind: UInt8 {
        case welcome = 101
        case rejected = 102
        case sessionCreated = 103
        case sessions = 104
        case screen = 105
        case output = 106
        case sessionExited = 107
        case detached = 108
        case failure = 109
    }

    public func encodedBody() -> [UInt8] {
        switch self {
        case .welcome(let reply): return Self.body(.welcome, json: reply)
        case .rejected(let reply): return Self.body(.rejected, json: reply)
        case .sessionCreated(let reply): return Self.body(.sessionCreated, json: reply)
        case .sessions(let list): return Self.body(.sessions, json: list)
        case .screen(let sessionId, let bytes): return Self.body(.screen, sessionId, raw: bytes)
        case .output(let sessionId, let bytes): return Self.body(.output, sessionId, raw: bytes)
        case .sessionExited(let sessionId, let exitCode):
            return Self.body(.sessionExited, sessionId, json: ExitPayload(exitCode: exitCode))
        case .detached(let sessionId, let reason): return Self.body(.detached, sessionId, json: reason)
        case .failure(let reply): return Self.body(.failure, json: reply)
        }
    }

    public init(body: [UInt8]) throws {
        guard let first = body.first else { throw ProtocolError.emptyFrame }
        guard let kind = Kind(rawValue: first) else { throw ProtocolError.unknownMessageKind(first) }
        var reader = BodyReader(payload: body.dropFirst())
        switch kind {
        case .welcome: self = .welcome(try reader.json(WelcomeReply.self))
        case .rejected: self = .rejected(try reader.json(RejectedReply.self))
        case .sessionCreated: self = .sessionCreated(try reader.json(SessionCreatedReply.self))
        case .sessions: self = .sessions(try reader.json([SessionDescriptor].self))
        case .screen: self = .screen(sessionId: try reader.sessionId(), bytes: reader.rest())
        case .output: self = .output(sessionId: try reader.sessionId(), bytes: reader.rest())
        case .sessionExited:
            let sessionId = try reader.sessionId()
            self = .sessionExited(sessionId: sessionId, exitCode: try reader.json(ExitPayload.self).exitCode)
        case .detached: self = .detached(sessionId: try reader.sessionId(), reason: try reader.json(DetachReason.self))
        case .failure: self = .failure(try reader.json(FailureReply.self))
        }
    }

    private static func body(
        _ kind: Kind, _ sessionId: UUID? = nil, raw: [UInt8]? = nil, json: (any Encodable)? = nil
    ) -> [UInt8] {
        var writer = BodyWriter(kind: kind.rawValue)
        if let sessionId { writer.append(sessionId) }
        if let raw { writer.append(raw: raw) }
        if let json { writer.append(json: json) }
        return writer.bytes
    }
}

extension ClientMessage {
    /// The complete frame, ready to be written to the transport.
    public func encodedFrame() -> [UInt8] { Frame.encode(body: encodedBody()) }
}

extension DaemonMessage {
    /// The complete frame, ready to be written to the transport.
    public func encodedFrame() -> [UInt8] { Frame.encode(body: encodedBody()) }
}
