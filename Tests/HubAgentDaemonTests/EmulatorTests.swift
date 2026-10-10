import HubAgentShared
import Testing

@testable import HubAgentDaemon

private let escape = "\u{1b}"

/// Feeds `chunks` to a "daemon" emulator, rebuilds a "client" emulator from the
/// daemon's screen bytes and returns the differences between the two (none expected).
private func restoreDifferences(
    _ chunks: [String], size: TerminalSize = .init(columns: 40, rows: 10), historyLines: Int = 200,
    clientPrelude: String = "", afterRestore: String = ""
) -> [String] {
    let daemon = SwiftTermHeadlessEmulator(size: size, historyLines: historyLines)
    let client = SwiftTermHeadlessEmulator(size: size, historyLines: historyLines)
    for chunk in chunks { daemon.feed(Array(chunk.utf8)[...]) }
    client.feed(Array(clientPrelude.utf8)[...])
    client.feed(daemon.screen()[...])
    for emulator in [daemon, client] { emulator.feed(Array(afterRestore.utf8)[...]) }
    return client.stateDump().differences(from: daemon.stateDump())
}

@Suite struct ScreenRestoration {
    @Test func plainTextAndCursor() {
        #expect(restoreDifferences(["hello\r\nworld\r\n$ "]) == [])
    }

    @Test func colorsAndStyles() {
        let text =
            "\(escape)[31mred \(escape)[1;32mbold green \(escape)[38;5;208morange \(escape)[38;2;10;200;250mtrue"
            + "\(escape)[0;4;7m under inverse \(escape)[0;2;3;9mdim italic struck"
            + "\(escape)[0m\(escape)[44m bg \(escape)[0m"
        #expect(restoreDifferences([text]) == [])
    }

    @Test func wideCharactersAndAccents() {
        #expect(restoreDifferences(["wide: 日本語 emoji: 😀🎉 accents: ação é ü\r\nnext"]) == [])
    }

    @Test func wrappedLines() {
        let exactlyOneRow = String(repeating: "a", count: 40)
        let threeRows = String(repeating: "b", count: 100)
        #expect(restoreDifferences([exactlyOneRow + "\r\n" + threeRows + "\r\nend"]) == [])
    }

    @Test func emptyContinuationLine() {
        // A full row followed by a wrap that carries no characters (zsh does this at the prompt).
        let text = String(repeating: "x", count: 40) + " \u{08}\r\nafter"
        #expect(restoreDifferences([text]) == [])
    }

    @Test func historyBeyondTheLimit() {
        let lines = (1...300).map { "line \($0) " + String(repeating: "z", count: $0 % 50) }
        #expect(restoreDifferences([lines.joined(separator: "\r\n")], historyLines: 50) == [])
    }

    @Test func scrollRegionAndCursorPosition() {
        #expect(restoreDifferences(["one\r\ntwo\r\nthree\(escape)[2;6r\(escape)[4;7Hhere"]) == [])
    }

    @Test func terminalModes() {
        let modes = "\(escape)[?1h\(escape)[?25l\(escape)[?1000h\(escape)[?1006h\(escape)[?2004h\(escape)=\(escape)[5 q"
        #expect(restoreDifferences(["prompt " + modes]) == [])
    }

    @Test func fullScreenProgram() {
        let shell = "\(escape)[33m$ vim\(escape)[0m\r\n"
        let program = "\(escape)[?1049h\(escape)[H\(escape)[7m status bar \(escape)[0m\r\n~\r\n~\(escape)[3;5H"
        #expect(restoreDifferences([shell, program]) == [])
    }

    @Test func shellHiddenBehindFullScreenProgramKeepsItsColors() {
        let shell = "\(escape)[36mcolored history\(escape)[0m\r\n$ top\r\n"
        let program = "\(escape)[?1049h\(escape)[Hfull screen"
        #expect(restoreDifferences([shell, program], afterRestore: "\(escape)[?1049l") == [])
    }

    @Test func alternateScreenSequenceSplitAcrossChunks() {
        let shell = "\(escape)[35mbefore\(escape)[0m\r\n"
        let chunks = [shell + "\(escape)[?10", "49h\(escape)[Hinside"]
        #expect(restoreDifferences(chunks, afterRestore: "\(escape)[?1049l") == [])
    }

    @Test func screenReplacesWhateverTheClientHad() {
        let stale = (1...80).map { "stale \($0)" }.joined(separator: "\r\n") + "\(escape)[?1049hstale program"
        #expect(restoreDifferences(["fresh\r\n$ "], clientPrelude: stale) == [])
    }

    @Test func outputAfterRestoreStaysInSync() {
        let before = (1...30).map { "before \($0)" }.joined(separator: "\r\n")
        let after = "\r\n\(escape)[32mafter\(escape)[0m\r\n" + String(repeating: "w", count: 90)
        #expect(restoreDifferences([before], afterRestore: after) == [])
    }
}

@Suite struct EmulatorReplies {
    @Test func answersCursorPositionQuery() {
        let emulator = SwiftTermHeadlessEmulator(size: .init(columns: 40, rows: 10), historyLines: 10)
        var replies: [[UInt8]] = []
        emulator.onReply = { replies.append($0) }
        emulator.feed(Array("ab\r\ncd\(escape)[6n".utf8)[...])
        #expect(replies.map { String(decoding: $0, as: UTF8.self) } == ["\(escape)[2;3R"])
    }

    @Test func reportsThemeBackgroundColor() {
        let emulator = SwiftTermHeadlessEmulator(size: .init(columns: 40, rows: 10), historyLines: 10)
        var reply = ""
        emulator.onReply = { reply += String(decoding: $0, as: UTF8.self) }
        emulator.setTheme(
            ThemeColors(
                foreground: .init(red: 255, green: 255, blue: 255), background: .init(red: 18, green: 52, blue: 86)))
        emulator.feed(Array("\(escape)]11;?\u{07}".utf8)[...])
        #expect(reply.contains("rgb:1212/3434/5656"))
    }

    @Test func keepsTheTitle() {
        let emulator = SwiftTermHeadlessEmulator(size: .init(columns: 40, rows: 10), historyLines: 10)
        emulator.feed(Array("\(escape)]0;my title\u{07}".utf8)[...])
        #expect(emulator.title == "my title")
    }
}

@Suite struct ModeTracking {
    private func tracker(_ text: String) -> ModeTracker {
        var tracker = ModeTracker()
        tracker.consume(Array(text.utf8)[...])
        return tracker
    }

    @Test func startsWithDefaults() {
        #expect(ModeTracker().privateModes == [7, 25])
    }

    @Test func setsAndResetsPrivateModes() {
        let modes = tracker("\(escape)[?1000;1006h\(escape)[?25l\(escape)[?1000l").privateModes
        #expect(modes == [7, 1006])
    }

    @Test func tracksKeypadCursorStyleAndAnsiModes() {
        let tracked = tracker("\(escape)=\(escape)[4h\(escape)[6 q")
        #expect(tracked.applicationKeypad)
        #expect(tracked.ansiModes == [4])
        #expect(tracked.cursorStyle == 6)
    }

    @Test func ignoresSequencesInsideStrings() {
        let tracked = tracker("\(escape)]0;title \(escape)[?1000h still title\u{07}")
        #expect(tracked.privateModes == [7, 25])
    }

    @Test func fullResetRestoresDefaults() {
        #expect(tracker("\(escape)[?1049h\(escape)[?2004h\(escape)c") == ModeTracker())
    }

    @Test func reportsWhereTheAlternateScreenStarts() {
        var tracker = ModeTracker()
        let bytes = Array("ab\(escape)[?1049hcd".utf8)
        #expect(tracker.consume(bytes[...]) == [.init(index: 2, entersAlternateScreen: true)])
        #expect(tracker.isAlternateScreen)
    }

    @Test func cutsAtTheFinalByteWhenTheSequenceStartedInAnEarlierChunk() {
        var tracker = ModeTracker()
        tracker.consume(Array("ab\(escape)[?10".utf8)[...])
        let rest = Array("49hcd".utf8)
        #expect(tracker.consume(rest[...]) == [.init(index: 2, entersAlternateScreen: true)])
    }

    @Test func cutsRightAfterAFullReset() {
        var tracker = ModeTracker()
        let bytes = Array("ab\(escape)ccd".utf8)
        #expect(tracker.consume(bytes[...]) == [.init(index: 4, entersAlternateScreen: false)])
    }
}
