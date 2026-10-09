import Foundation

/// Tracks terminal modes by scanning the output stream.
///
/// SwiftTerm keeps several of these modes internal (cursor visibility, origin mode,
/// application keypad, focus reporting...), so the daemon needs its own record to
/// rebuild them on reattach.
public struct ModeTracker: Equatable {
    public static let defaultPrivateModes: Set<Int> = [7, 25]

    public private(set) var privateModes: Set<Int> = ModeTracker.defaultPrivateModes
    public private(set) var ansiModes: Set<Int> = []
    public private(set) var applicationKeypad = false
    public private(set) var cursorStyle: Int?

    private enum State: Equatable { case ground, escape, csi, string, stringEscape }
    private var state: State = .ground
    private var parameters: [UInt8] = []

    public init() {}

    public static let alternateScreenModes: Set<Int> = [47, 1047, 1049]

    /// Scans the bytes and returns the index of each byte that completes a sequence
    /// entering the alternate screen. Feeding the emulator up to (not including) that
    /// index leaves it on the normal screen, which is the last chance to read that
    /// buffer with colors.
    @discardableResult
    public mutating func consume(_ bytes: ArraySlice<UInt8>) -> [Int] {
        var alternateScreenEntries: [Int] = []
        for index in bytes.indices {
            let wasAlternate = isAlternateScreen
            step(bytes[index])
            if !wasAlternate && isAlternateScreen { alternateScreenEntries.append(index) }
        }
        return alternateScreenEntries
    }

    public var isAlternateScreen: Bool {
        !privateModes.isDisjoint(with: ModeTracker.alternateScreenModes)
    }

    private mutating func step(_ byte: UInt8) {
        switch state {
        case .ground:
            if byte == 0x1b { state = .escape }
        case .escape:
            stepEscape(byte)
        case .csi:
            stepControlSequence(byte)
        case .string:
            if byte == 0x07 { state = .ground } else if byte == 0x1b { state = .stringEscape }
        case .stringEscape:
            state = byte == 0x5c ? .ground : .string
        }
    }

    private mutating func stepEscape(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "["):
            parameters = []
            state = .csi
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"):
            state = .string
        case UInt8(ascii: "="):
            applicationKeypad = true
            state = .ground
        case UInt8(ascii: ">"):
            applicationKeypad = false
            state = .ground
        case UInt8(ascii: "c"):
            reset()
        case 0x1b:
            state = .escape
        default:
            state = .ground
        }
    }

    private mutating func stepControlSequence(_ byte: UInt8) {
        if byte >= 0x40 && byte <= 0x7e {
            finishControlSequence(final: byte)
            state = .ground
        } else if byte == 0x1b {
            state = .escape
        } else {
            parameters.append(byte)
        }
    }

    private mutating func finishControlSequence(final: UInt8) {
        let text = String(decoding: parameters, as: UTF8.self)
        if final == UInt8(ascii: "h") || final == UInt8(ascii: "l") {
            applyModes(text, enabled: final == UInt8(ascii: "h"))
        } else if final == UInt8(ascii: "q"), text.hasSuffix(" ") {
            cursorStyle = Int(text.dropLast()) ?? 0
        } else if final == UInt8(ascii: "p"), text == "!" {
            reset()
        }
    }

    private mutating func applyModes(_ text: String, enabled: Bool) {
        let isPrivate = text.hasPrefix("?")
        let numbers = text.drop(while: { $0 == "?" }).split(separator: ";").compactMap { Int($0) }
        for number in numbers {
            if isPrivate {
                if enabled { privateModes.insert(number) } else { privateModes.remove(number) }
            } else {
                if enabled { ansiModes.insert(number) } else { ansiModes.remove(number) }
            }
        }
    }

    private mutating func reset() {
        privateModes = ModeTracker.defaultPrivateModes
        ansiModes = []
        applicationKeypad = false
        cursorStyle = nil
        state = .ground
    }

    /// Modes that the screen serializer restores through other means or must not replay.
    public static let modesHandledElsewhere: Set<Int> = [47, 1047, 1048, 1049, 2026]

    public var summary: String {
        let modes = privateModes.sorted().map(String.init).joined(separator: ",")
        let ansi = ansiModes.sorted().map(String.init).joined(separator: ",")
        return "private=[\(modes)] ansi=[\(ansi)] keypad=\(applicationKeypad) cursorStyle=\(cursorStyle ?? -1)"
    }
}
