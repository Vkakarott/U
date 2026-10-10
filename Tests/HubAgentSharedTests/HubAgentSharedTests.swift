import Foundation
import Testing

@testable import HubAgentShared

private let sessionId = UUID(uuidString: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")!
private let size = TerminalSize(columns: 120, rows: 40)
private let descriptor = SessionDescriptor(
    id: sessionId, workingDirectory: "/tmp/project", columns: 120, rows: 40, processId: 4242,
    label: ["projectId": "p1", "tabId": "t1", "title": "Terminal 1"],
    createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000), state: .exited, exitCode: 3)

@Suite struct ClientMessageCoding {
    static let samples: [ClientMessage] = [
        .hello(HelloRequest(clientName: "tests")),
        .createSession(
            CreateSessionRequest(requestId: 7, workingDirectory: "/tmp/project", size: size, label: ["tabId": "t1"])),
        .listSessions,
        .attach(sessionId: sessionId, size: size),
        .detach(sessionId: sessionId),
        .input(sessionId: sessionId, bytes: [0x1b, 0x5b, 0x41, 0x00, 0xff]),
        .input(sessionId: sessionId, bytes: []),
        .resize(sessionId: sessionId, size: size),
        .terminate(sessionId: sessionId),
        .acknowledgeExit(sessionId: sessionId),
        .setTheme(
            ThemeColors(
                foreground: .init(red: 230, green: 230, blue: 230), background: .init(red: 10, green: 20, blue: 30))),
        .shutdown,
    ]

    @Test(arguments: samples)
    func roundTrips(message: ClientMessage) throws {
        #expect(try ClientMessage(body: message.encodedBody()) == message)
    }

    @Test func rejectsUnknownKind() {
        #expect(throws: ProtocolError.unknownMessageKind(200)) { try ClientMessage(body: [200]) }
    }

    @Test func rejectsTruncatedSessionId() {
        let truncated = Array(ClientMessage.detach(sessionId: sessionId).encodedBody().prefix(10))
        #expect(throws: ProtocolError.truncatedMessage) { try ClientMessage(body: truncated) }
    }

    @Test func rejectsMalformedJSON() {
        let body = ClientMessage.hello(HelloRequest(clientName: "x")).encodedBody().prefix(1) + Array("{oops".utf8)
        #expect(throws: ProtocolError.malformedPayload) { try ClientMessage(body: Array(body)) }
    }
}

@Suite struct DaemonMessageCoding {
    static let samples: [DaemonMessage] = [
        .welcome(WelcomeReply(protocolVersion: 1, daemonVersion: "0.1.0")),
        .welcome(WelcomeReply(protocolVersion: 1, daemonVersion: "0.3.0", installation: .development, processId: 77)),
        .rejected(RejectedReply(reason: "too old", daemonProtocolVersion: 4, daemonMinimumProtocolVersion: 3)),
        .sessionCreated(SessionCreatedReply(requestId: 7, session: descriptor)),
        .sessions([descriptor, descriptor]),
        .sessions([]),
        .screen(sessionId: sessionId, bytes: Array("\u{1b}cprompt % ".utf8)),
        .output(sessionId: sessionId, bytes: [0x00, 0x0a, 0xe2, 0x9c, 0x93]),
        .sessionExited(sessionId: sessionId, exitCode: 0),
        .sessionExited(sessionId: sessionId, exitCode: nil),
        .detached(sessionId: sessionId, reason: .takenOver),
        .failure(FailureReply(code: .sessionNotFound, message: "gone", requestId: nil, sessionId: sessionId)),
    ]

    @Test(arguments: samples)
    func roundTrips(message: DaemonMessage) throws {
        #expect(try DaemonMessage(body: message.encodedBody()) == message)
    }

    @Test func clientAndDaemonKindsDoNotOverlap() {
        let clientBody = ClientMessage.listSessions.encodedBody()
        #expect(throws: ProtocolError.self) { try DaemonMessage(body: clientBody) }
    }
}

@Suite struct Framing {
    @Test func reassemblesFramesSplitAtEveryPosition() throws {
        let first = DaemonMessage.output(sessionId: sessionId, bytes: Array("hello".utf8))
        let second = DaemonMessage.sessionExited(sessionId: sessionId, exitCode: 1)
        let stream = first.encodedFrame() + second.encodedFrame()
        for split in 0...stream.count {
            var decoder = FrameDecoder()
            var bodies = try decoder.append(stream[..<split])
            bodies += try decoder.append(stream[split...])
            #expect(try bodies.map { try DaemonMessage(body: $0) } == [first, second])
        }
    }

    @Test func deliversByteByByte() throws {
        let message = ClientMessage.input(sessionId: sessionId, bytes: Array(0...255))
        var decoder = FrameDecoder()
        var bodies: [[UInt8]] = []
        for byte in message.encodedFrame() { bodies += try decoder.append([byte]) }
        #expect(try bodies.map { try ClientMessage(body: $0) } == [message])
    }

    @Test func rejectsOversizedFrame() {
        var decoder = FrameDecoder(maximumBodyLength: 16)
        #expect(throws: ProtocolError.frameTooLarge(17)) { try decoder.append([0, 0, 0, 17]) }
    }

    @Test func rejectsEmptyFrame() {
        var decoder = FrameDecoder()
        #expect(throws: ProtocolError.emptyFrame) { try decoder.append([0, 0, 0, 0]) }
    }
}

@Suite struct VersionNegotiation {
    @Test func agreesOnHighestCommonVersion() {
        #expect(ProtocolVersion.negotiate(peerCurrent: 5, peerMinimum: 2, localCurrent: 3, localMinimum: 1) == 3)
        #expect(ProtocolVersion.negotiate(peerCurrent: 2, peerMinimum: 1, localCurrent: 6, localMinimum: 2) == 2)
    }

    @Test func refusesWhenRangesDoNotOverlap() {
        #expect(ProtocolVersion.negotiate(peerCurrent: 2, peerMinimum: 1, localCurrent: 6, localMinimum: 3) == nil)
        #expect(ProtocolVersion.negotiate(peerCurrent: 9, peerMinimum: 7, localCurrent: 6, localMinimum: 3) == nil)
    }

    @Test func currentBuildTalksToItself() {
        let agreed = ProtocolVersion.negotiate(
            peerCurrent: ProtocolVersion.current, peerMinimum: ProtocolVersion.minimumSupported)
        #expect(agreed == ProtocolVersion.current)
    }
}

@Suite struct InstallationIdentity {
    @Test func theTwoCopiesShareNothing() {
        let production = Installation(kind: .production, homeDirectory: "/Users/someone")
        let development = Installation(kind: .development, homeDirectory: "/Users/someone")
        let paths: [KeyPath<Installation, String>] = [
            \.launchdLabel, \.supportDirectory, \.socketPath, \.lockPath, \.daemonLogPath, \.projectsFilePath,
            \.launchAgentPath,
        ]
        for path in paths { #expect(production[keyPath: path] != development[keyPath: path]) }
    }

    @Test func socketPathsFitTheSystemLimit() {
        for kind in InstallationKind.allCases {
            let installation = Installation(kind: kind, homeDirectory: "/Users/a-rather-long-account-name")
            #expect(installation.socketPath.utf8.count < 104)
        }
    }

    @Test func runningFromSourceIsDevelopment() {
        #expect(Installation.kind(environment: [:], bundleIdentifier: nil) == .development)
        #expect(Installation.kind(environment: [:], bundleIdentifier: "com.apple.dt.Xcode") == .development)
    }

    @Test func thePackagedAppIsProduction() {
        let identifier = Installation.productionBundleIdentifier
        #expect(Installation.kind(environment: [:], bundleIdentifier: identifier) == .production)
    }

    @Test func anExplicitChoiceWins() {
        let identifier = Installation.productionBundleIdentifier
        let variable = Installation.environmentVariable
        #expect(Installation.kind(environment: [variable: "development"], bundleIdentifier: identifier) == .development)
        #expect(Installation.kind(environment: [variable: "production"], bundleIdentifier: nil) == .production)
        #expect(Installation.kind(environment: [variable: "nonsense"], bundleIdentifier: nil) == .development)
    }

    @Test func aWelcomeFromAnOlderDaemonStillDecodes() throws {
        let old = Array(#"{"protocolVersion":1,"daemonVersion":"0.2.0"}"#.utf8)
        let message = try DaemonMessage(body: [101] + old)
        #expect(message == .welcome(WelcomeReply(protocolVersion: 1, daemonVersion: "0.2.0")))
    }

    @Test func shutdownKeepsItsEncoding() {
        #expect(ClientMessage.shutdown.encodedBody() == [11])
    }
}
