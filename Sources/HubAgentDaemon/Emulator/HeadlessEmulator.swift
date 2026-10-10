import HubAgentShared
import SwiftTerm

/// The daemon's view of a terminal emulator without a window.
///
/// The rest of the daemon only sees this protocol, so the emulator can be replaced
/// without touching session management. Implementations are confined to the
/// daemon's queue.
protocol HeadlessEmulator: AnyObject {
    /// Bytes the emulator produces in answer to program queries (cursor position,
    /// device attributes, colors). They must be written back to the terminal.
    var onReply: (([UInt8]) -> Void)? { get set }
    var title: String? { get }

    func feed(_ bytes: ArraySlice<UInt8>)
    func resize(_ size: TerminalSize)
    func setTheme(_ colors: ThemeColors)
    /// Terminal bytes that rebuild the current screen, history and modes in a client's emulator.
    func screen() -> [UInt8]
}

/// `HeadlessEmulator` backed by SwiftTerm's engine.
final class SwiftTermHeadlessEmulator: HeadlessEmulator, TerminalDelegate {
    var onReply: (([UInt8]) -> Void)?
    private(set) var title: String?

    private var terminal: Terminal!
    private var modes = ModeTracker()
    /// The shell screen captured right before a full-screen program hid it.
    private var hiddenNormalScreen: String?

    init(size: TerminalSize, historyLines: Int) {
        let options = TerminalOptions(cols: size.columns, rows: size.rows, scrollback: historyLines)
        terminal = Terminal(delegate: self, options: options)
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        var start = bytes.startIndex
        for boundary in modes.consume(bytes) {
            terminal.terminalLock.withLock {
                terminal.feed(buffer: bytes[start..<boundary.index])
                if boundary.entersAlternateScreen && !terminal.isCurrentBufferAlternate {
                    hiddenNormalScreen = ScreenSerializer.normalScreen(of: terminal)
                }
            }
            start = boundary.index
        }
        terminal.terminalLock.withLock { terminal.feed(buffer: bytes[start...]) }
        if !modes.isAlternateScreen { hiddenNormalScreen = nil }
    }

    func resize(_ size: TerminalSize) {
        terminal.terminalLock.withLock { terminal.resize(cols: size.columns, rows: size.rows) }
    }

    func setTheme(_ colors: ThemeColors) {
        terminal.terminalLock.withLock {
            terminal.foregroundColor = Self.color(colors.foreground)
            terminal.backgroundColor = Self.color(colors.background)
        }
    }

    func screen() -> [UInt8] {
        terminal.terminalLock.withLock {
            ScreenSerializer.serialize(
                terminal: terminal, modes: modes, title: title, hiddenNormalScreen: hiddenNormalScreen)
        }
    }

    /// Comparable description of the emulator's state, for tests and diagnostics.
    func stateDump() -> EmulatorStateDump {
        terminal.terminalLock.withLock { EmulatorStateDump(terminal: terminal, modes: modes) }
    }

    private static func color(_ color: ThemeColors.Color) -> Color {
        Color(red: UInt16(color.red) * 257, green: UInt16(color.green) * 257, blue: UInt16(color.blue) * 257)
    }

    // MARK: TerminalDelegate

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        onReply?(Array(data))
    }

    func setTerminalTitle(source: Terminal, title: String) {
        self.title = title
    }
}
