import Foundation

/// What the daemon tells clients about a terminal session.
public struct SessionDescriptor: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case running
        case exited
    }

    public var id: UUID
    public var workingDirectory: String
    public var columns: Int
    public var rows: Int
    public var processId: Int32
    /// Opaque to the daemon. The app stores which project and tab own the session.
    public var label: [String: String]
    public var createdAt: Date
    public var state: State
    public var exitCode: Int32?

    public init(
        id: UUID,
        workingDirectory: String,
        columns: Int,
        rows: Int,
        processId: Int32,
        label: [String: String],
        createdAt: Date,
        state: State,
        exitCode: Int32?
    ) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
        self.processId = processId
        self.label = label
        self.createdAt = createdAt
        self.state = state
        self.exitCode = exitCode
    }
}

/// Terminal size in character cells.
public struct TerminalSize: Codable, Sendable, Equatable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    /// Sizes outside this range are refused instead of passed to the terminal.
    public var isValid: Bool {
        (2...1000).contains(columns) && (1...1000).contains(rows)
    }
}

/// Colors the daemon reports to programs that ask the terminal for them.
public struct ThemeColors: Codable, Sendable, Equatable {
    public struct Color: Codable, Sendable, Equatable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public var foreground: Color
    public var background: Color

    public init(foreground: Color, background: Color) {
        self.foreground = foreground
        self.background = background
    }
}
