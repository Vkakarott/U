import Foundation
import HubAgentShared

/// Where a daemon process listens and which copy of hub-agent it serves.
struct DaemonOptions: Equatable {
    enum OptionError: Error, Equatable {
        case unknownEnvironment(String)
        case missingValue(String)
    }

    /// Nil when the daemon was started on an explicit socket, outside any installation.
    var installation: Installation?
    var socketPath: String
    var lockPath: String

    /// `--environment production|development` selects a copy; `--home` moves its
    /// folders under another root; `--socket` listens somewhere else altogether.
    /// With no arguments the daemon serves the development copy.
    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let home = try Self.value(of: "--home", in: arguments) ?? NSHomeDirectory()
        if let socket = try Self.value(of: "--socket", in: arguments), !arguments.contains("--environment") {
            installation = nil
            socketPath = socket
            lockPath = socket + ".lock"
            return
        }
        let kind = try Self.kind(arguments: arguments, environment: environment)
        let installation = Installation(kind: kind, homeDirectory: home)
        self.installation = installation
        socketPath = try Self.value(of: "--socket", in: arguments) ?? installation.socketPath
        lockPath = installation.lockPath
    }

    private static func kind(arguments: [String], environment: [String: String]) throws -> InstallationKind {
        guard let name = try value(of: "--environment", in: arguments) else {
            return Installation.kind(environment: environment, bundleIdentifier: nil)
        }
        guard let kind = InstallationKind(rawValue: name) else { throw OptionError.unknownEnvironment(name) }
        return kind
    }

    private static func value(of option: String, in arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: option) else { return nil }
        guard index + 1 < arguments.count else { throw OptionError.missingValue(option) }
        return arguments[index + 1]
    }
}
