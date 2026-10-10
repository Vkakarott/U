import Foundation

public struct HelloRequest: Codable, Sendable, Equatable {
    public var protocolVersion: UInt16
    public var minimumProtocolVersion: UInt16
    public var clientName: String

    public init(
        protocolVersion: UInt16 = ProtocolVersion.current,
        minimumProtocolVersion: UInt16 = ProtocolVersion.minimumSupported,
        clientName: String
    ) {
        self.protocolVersion = protocolVersion
        self.minimumProtocolVersion = minimumProtocolVersion
        self.clientName = clientName
    }
}

public struct WelcomeReply: Codable, Sendable, Equatable {
    /// The version both sides agreed on.
    public var protocolVersion: UInt16
    public var daemonVersion: String

    public init(protocolVersion: UInt16, daemonVersion: String) {
        self.protocolVersion = protocolVersion
        self.daemonVersion = daemonVersion
    }
}

public struct RejectedReply: Codable, Sendable, Equatable {
    public var reason: String
    public var daemonProtocolVersion: UInt16
    public var daemonMinimumProtocolVersion: UInt16

    public init(reason: String, daemonProtocolVersion: UInt16, daemonMinimumProtocolVersion: UInt16) {
        self.reason = reason
        self.daemonProtocolVersion = daemonProtocolVersion
        self.daemonMinimumProtocolVersion = daemonMinimumProtocolVersion
    }
}

public struct CreateSessionRequest: Codable, Sendable, Equatable {
    /// Echoed in the reply so the client can match it to the request.
    public var requestId: UInt32
    public var workingDirectory: String
    public var size: TerminalSize
    public var label: [String: String]

    public init(requestId: UInt32, workingDirectory: String, size: TerminalSize, label: [String: String] = [:]) {
        self.requestId = requestId
        self.workingDirectory = workingDirectory
        self.size = size
        self.label = label
    }
}

public struct SessionCreatedReply: Codable, Sendable, Equatable {
    public var requestId: UInt32
    public var session: SessionDescriptor

    public init(requestId: UInt32, session: SessionDescriptor) {
        self.requestId = requestId
        self.session = session
    }
}

public struct FailureReply: Codable, Sendable, Equatable, Error {
    public enum Code: String, Codable, Sendable {
        case workingDirectoryNotFound
        case sessionNotFound
        case invalidSize
        case launchFailed
        case malformedMessage
        case handshakeRequired
    }

    public var code: Code
    public var message: String
    public var requestId: UInt32?
    public var sessionId: UUID?

    public init(code: Code, message: String, requestId: UInt32? = nil, sessionId: UUID? = nil) {
        self.code = code
        self.message = message
        self.requestId = requestId
        self.sessionId = sessionId
    }
}

/// Why the daemon stopped sending a session's output to a client.
public enum DetachReason: String, Codable, Sendable {
    case requested
    /// Another client attached. Each session has a single client in v1.
    case takenOver
}

/// Messages the app sends to the daemon.
public enum ClientMessage: Sendable, Equatable {
    case hello(HelloRequest)
    case createSession(CreateSessionRequest)
    case listSessions
    case attach(sessionId: UUID, size: TerminalSize)
    case detach(sessionId: UUID)
    case input(sessionId: UUID, bytes: [UInt8])
    case resize(sessionId: UUID, size: TerminalSize)
    case terminate(sessionId: UUID)
    /// The client has seen that the session ended; the daemon may forget it.
    case acknowledgeExit(sessionId: UUID)
    case setTheme(ThemeColors)
}

/// Messages the daemon sends to the app.
public enum DaemonMessage: Sendable, Equatable {
    case welcome(WelcomeReply)
    case rejected(RejectedReply)
    case sessionCreated(SessionCreatedReply)
    case sessions([SessionDescriptor])
    /// A complete screen. The client resets its emulator and feeds these bytes.
    case screen(sessionId: UUID, bytes: [UInt8])
    case output(sessionId: UUID, bytes: [UInt8])
    case sessionExited(sessionId: UUID, exitCode: Int32?)
    case detached(sessionId: UUID, reason: DetachReason)
    case failure(FailureReply)
}
