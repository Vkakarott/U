import Foundation

/// Makes sure a single daemon serves an installation.
///
/// Two daemons on one socket path would each own terminals while only the last one
/// to start could be reached. The lock belongs to the process and is released by the
/// system when it dies, so a crash never leaves a stale lock behind.
final class InstanceLock {
    private let descriptor: Int32

    /// Returns nil when another process holds the lock or the file cannot be created.
    init?(path: String) {
        // Close-on-exec: a program started in a terminal must not keep the daemon's
        // lock alive after the daemon is gone.
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }
}
