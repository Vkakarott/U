import Foundation
import os

@main
enum HubAgentDaemon {
    /// Exit status when another daemon already serves the installation (`EX_TEMPFAIL`).
    static let alreadyRunningStatus: Int32 = 75

    static func main() {
        let logger = Logger(subsystem: "com.hubagent.daemon", category: "main")
        // A client that goes away must not kill the daemon and every terminal with it.
        signal(SIGPIPE, SIG_IGN)
        do {
            let runtime = DaemonRuntime(options: try DaemonOptions(arguments: CommandLine.arguments))
            try runtime.start(onStopped: { exit(EXIT_SUCCESS) })
            stopSources = [SIGTERM, SIGINT].map { stopSource(for: $0, runtime: runtime) }
        } catch DaemonStartError.alreadyRunning {
            logger.notice("another daemon already serves this installation; leaving")
            exit(alreadyRunningStatus)
        } catch {
            logger.fault("cannot start: \(String(describing: error), privacy: .public)")
            exit(EXIT_FAILURE)
        }
        dispatchMain()
    }

    /// Kept for the life of the process: a released signal source stops delivering.
    private nonisolated(unsafe) static var stopSources: [DispatchSourceSignal] = []

    /// Stopping the daemon ends every terminal, so it only happens on an explicit
    /// signal or on a client's request.
    private static func stopSource(for signalNumber: Int32, runtime: DaemonRuntime) -> DispatchSourceSignal {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: runtime.queue)
        source.setEventHandler { runtime.stop(then: { exit(EXIT_SUCCESS) }) }
        source.resume()
        return source
    }
}
