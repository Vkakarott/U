import Foundation
import SwiftTerm

/// Canonical, comparable description of an emulator's state.
///
/// Two emulators that produce equal dumps hold the same visible screen, history,
/// colors, attributes and cursor. Callers must hold the terminal lock.
struct EmulatorStateDump: Codable, Equatable {
    var columns: Int
    var rows: Int
    var alternateScreen: Bool
    var cursorX: Int
    var cursorY: Int
    var historyLines: Int
    var lines: [String]
    var applicationCursor: Bool
    var bracketedPaste: Bool
    var mouseMode: String
    var trackedModes: String

    init(terminal: Terminal, modes: ModeTracker) {
        let buffer = terminal.buffer
        columns = terminal.cols
        rows = terminal.rows
        alternateScreen = terminal.isCurrentBufferAlternate
        cursorX = min(buffer.x, terminal.cols - 1)
        cursorY = buffer.y
        historyLines = buffer.yDisp
        applicationCursor = terminal.applicationCursor
        bracketedPaste = terminal.bracketedPasteMode
        mouseMode = "\(terminal.mouseMode)"
        trackedModes = modes.summary
        lines = EmulatorStateDump.activeLines(of: terminal).map(EmulatorStateDump.describe)
        // The oldest history line can be the tail of a line whose start was already
        // trimmed; its wrap flag has no predecessor and cannot be rebuilt, so it is ignored.
        if let first = lines.first, first.hasPrefix("W") { lines[0] = "-" + first.dropFirst() }
    }

    /// Every line of the active buffer, history first.
    static func activeLines(of terminal: Terminal) -> [BufferLine] {
        let first = terminal.buffer.totalLinesTrimmed
        let count = terminal.buffer.yDisp + terminal.rows
        return (first..<(first + count)).compactMap { terminal.getScrollInvariantLine(row: $0) }
    }

    static func isBlank(_ cell: CharData) -> Bool {
        let character = cell.getCharacter()
        return (character == "\0" || character == " ") && cell.attribute == CharData.Null.attribute
    }

    static func lastUsedColumn(_ line: BufferLine) -> Int {
        var index = line.count - 1
        while index >= 0 && isBlank(line[index]) { index -= 1 }
        return index
    }

    static func describe(_ line: BufferLine) -> String {
        var result = line.isWrapped ? "W" : "-"
        var currentKey = ""
        let last = lastUsedColumn(line)
        guard last >= 0 else { return result }
        for index in 0...last {
            let cell = line[index]
            let key = describe(cell.attribute)
            if key != currentKey {
                result += "{\(key)}"
                currentKey = key
            }
            let character = cell.getCharacter()
            result.append(character == "\0" ? " " : character)
        }
        return result
    }

    static func describe(_ attribute: Attribute) -> String {
        var key = "\(describe(attribute.fg))/\(describe(attribute.bg))/\(attribute.style.rawValue)"
        if let underline = attribute.underlineColor { key += "/u\(describe(underline))" }
        return key
    }

    static func describe(_ color: Attribute.Color) -> String {
        switch color {
        case .ansi256(let code): return "a\(code)"
        case .trueColor(let red, let green, let blue): return "t\(red).\(green).\(blue)"
        case .defaultColor: return "d"
        case .defaultInvertedColor: return "i"
        }
    }

    /// Human-readable differences, empty when both dumps match.
    func differences(from other: EmulatorStateDump, limit: Int = 6) -> [String] {
        var found: [String] = []
        func check<T: Equatable>(_ name: String, _ mine: T, _ theirs: T) {
            if mine != theirs { found.append("\(name): daemon=\(theirs) client=\(mine)") }
        }
        check("columns", columns, other.columns)
        check("rows", rows, other.rows)
        check("alternateScreen", alternateScreen, other.alternateScreen)
        check("cursorX", cursorX, other.cursorX)
        check("cursorY", cursorY, other.cursorY)
        check("historyLines", historyLines, other.historyLines)
        check("applicationCursor", applicationCursor, other.applicationCursor)
        check("bracketedPaste", bracketedPaste, other.bracketedPaste)
        check("mouseMode", mouseMode, other.mouseMode)
        check("trackedModes", trackedModes, other.trackedModes)
        check("lineCount", lines.count, other.lines.count)
        var differingLines = 0
        for index in 0..<min(lines.count, other.lines.count) where lines[index] != other.lines[index] {
            differingLines += 1
            if differingLines <= limit {
                found.append("line \(index):\n    daemon=\(other.lines[index])\n    client=\(lines[index])")
            }
        }
        if differingLines > limit { found.append("... \(differingLines) differing lines in total") }
        return found
    }

    var visibleText: String {
        lines.suffix(rows).map { line in
            var text = ""
            var insideKey = false
            for character in line.dropFirst() {
                if character == "{" {
                    insideKey = true
                } else if character == "}" {
                    insideKey = false
                } else if !insideKey {
                    text.append(character)
                }
            }
            return text
        }.joined(separator: "\n")
    }
}
