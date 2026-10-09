import Foundation
import SwiftTerm

/// Turns the state of a headless emulator into terminal bytes that rebuild the same
/// screen in a fresh emulator (decision P3 of the spec). Callers must hold the terminal lock.
public enum ScreenSerializer {
    private static let escape = "\u{1b}"

    /// `hiddenNormalScreen` is the result of `normalScreen(of:)` captured just before the
    /// program entered the alternate screen; without it the hidden shell history is
    /// restored as plain text.
    public static func serialize(
        terminal: Terminal, modes: ModeTracker, title: String?, hiddenNormalScreen: String? = nil
    ) -> [UInt8] {
        var output = "\(escape)c"
        if terminal.isCurrentBufferAlternate {
            output += hiddenNormalScreen ?? plainNormalBuffer(of: terminal)
            output += "\(escape)[?1049h\(escape)[H"
            output += flowingLines(GridDump.activeLines(of: terminal))
        } else {
            output += flowingLines(GridDump.activeLines(of: terminal))
        }
        output += epilogue(terminal: terminal, modes: modes, title: title)
        return Array(output.utf8)
    }

    /// History, screen and cursor position of the normal screen. Only valid while the
    /// normal screen is the active one.
    public static func normalScreen(of terminal: Terminal) -> String {
        let buffer = terminal.buffer
        return flowingLines(GridDump.activeLines(of: terminal))
            + "\(escape)[\(buffer.y + 1);\(min(buffer.x, terminal.cols - 1) + 1)H"
    }

    /// Lines written top to bottom, so the receiving emulator scrolls exactly as the
    /// original did and keeps the wrapped-line flags. Used for history plus screen, and
    /// for the alternate screen (which has exactly one screen of lines, so nothing scrolls).
    private static func flowingLines(_ lines: [BufferLine]) -> String {
        var output = ""
        for (index, line) in lines.enumerated() {
            let nextIsWrapped = index + 1 < lines.count && lines[index + 1].isWrapped
            let content = cells(of: line, fullWidth: nextIsWrapped)
            // An empty continuation line still has to trigger the pending wrap of the line above.
            output += content.isEmpty && line.isWrapped ? " " : content
            if index + 1 < lines.count && !nextIsWrapped { output += "\r\n" }
        }
        return output
    }

    /// Fallback: SwiftTerm exposes the inactive buffer only as plain text, so without a
    /// capture the shell history hidden behind a full-screen program loses its colors.
    private static func plainNormalBuffer(of terminal: Terminal) -> String {
        let data = terminal.getBufferAsData(kind: .normal)
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func cells(of line: BufferLine, fullWidth: Bool) -> String {
        let last = fullWidth ? line.count - 1 : GridDump.lastUsedColumn(line)
        guard last >= 0 else { return "" }
        var output = ""
        var current = CharData.Null.attribute
        var skipNext = false
        for index in 0...last {
            if skipNext {
                skipNext = false
                continue
            }
            let cell = line[index]
            if cell.attribute != current {
                output += selectGraphicRendition(cell.attribute)
                current = cell.attribute
            }
            let character = cell.getCharacter()
            output.append(character == "\0" ? " " : character)
            skipNext = cell.width == 2
        }
        if current != CharData.Null.attribute { output += "\(escape)[0m" }
        return output
    }

    static func selectGraphicRendition(_ attribute: Attribute) -> String {
        var codes = ["0"]
        let styles: [(CharacterStyle, String)] = [
            (.bold, "1"), (.dim, "2"), (.italic, "3"), (.underline, "4"), (.blink, "5"),
            (.inverse, "7"), (.invisible, "8"), (.crossedOut, "9"),
        ]
        for (style, code) in styles where attribute.style.contains(style) { codes.append(code) }
        codes += colorCodes(attribute.fg, base: 30, brightBase: 90, extended: 38)
        codes += colorCodes(attribute.bg, base: 40, brightBase: 100, extended: 48)
        if let underline = attribute.underlineColor {
            codes += colorCodes(underline, base: nil, brightBase: nil, extended: 58)
        }
        return "\(escape)[\(codes.joined(separator: ";"))m"
    }

    private static func colorCodes(_ color: Attribute.Color, base: Int?, brightBase: Int?, extended: Int) -> [String] {
        switch color {
        case .ansi256(let code):
            if let base, code < 8 { return ["\(base + Int(code))"] }
            if let brightBase, code < 16 { return ["\(brightBase + Int(code) - 8)"] }
            return ["\(extended)", "5", "\(code)"]
        case .trueColor(let red, let green, let blue):
            return ["\(extended)", "2", "\(red)", "\(green)", "\(blue)"]
        case .defaultColor, .defaultInvertedColor:
            return []
        }
    }

    private static func epilogue(terminal: Terminal, modes: ModeTracker, title: String?) -> String {
        let buffer = terminal.buffer
        var output = "\(escape)[0m"
        if buffer.scrollTop != 0 || buffer.scrollBottom != terminal.rows - 1 {
            output += "\(escape)[\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r"
        }
        output += "\(escape)[\(buffer.y + 1);\(min(buffer.x, terminal.cols - 1) + 1)H"
        output += selectGraphicRendition(terminal.currentAttribute)
        output += modeSequences(modes)
        let keyboardFlags = terminal.keyboardEnhancementFlags.rawValue
        if keyboardFlags != 0 { output += "\(escape)[=\(keyboardFlags);1u" }
        if let title { output += "\(escape)]0;\(title)\u{07}" }
        return output
    }

    private static func modeSequences(_ modes: ModeTracker) -> String {
        var output = ""
        let replayable = modes.privateModes.subtracting(ModeTracker.modesHandledElsewhere)
        for mode in replayable.subtracting(ModeTracker.defaultPrivateModes).sorted() {
            output += "\(escape)[?\(mode)h"
        }
        for mode in ModeTracker.defaultPrivateModes.subtracting(modes.privateModes).sorted() {
            output += "\(escape)[?\(mode)l"
        }
        for mode in modes.ansiModes.sorted() { output += "\(escape)[\(mode)h" }
        if modes.applicationKeypad { output += "\(escape)=" }
        if let style = modes.cursorStyle { output += "\(escape)[\(style) q" }
        return output
    }
}
