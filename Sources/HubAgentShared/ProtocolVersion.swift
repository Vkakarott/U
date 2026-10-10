/// Version of the app–daemon protocol.
///
/// The daemon outlives the app, so a newer app routinely talks to an older daemon
/// (and the other way around). Both sides announce the range they understand in the
/// first message and agree on the highest version in common.
public struct ProtocolVersion: Sendable, Equatable {
    public static let current: UInt16 = 1
    public static let minimumSupported: UInt16 = 1

    /// The version both sides can speak, or nil when the ranges do not overlap.
    public static func negotiate(
        peerCurrent: UInt16,
        peerMinimum: UInt16,
        localCurrent: UInt16 = current,
        localMinimum: UInt16 = minimumSupported
    ) -> UInt16? {
        let agreed = min(peerCurrent, localCurrent)
        return agreed >= max(peerMinimum, localMinimum) ? agreed : nil
    }
}
