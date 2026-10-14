import Foundation
import Observation
import HubAgentShared

@MainActor
@Observable
final class DaemonStatusModel {
    var status = "Desconectado"
    var isConnected = false

    @ObservationIgnored
    private var client: DaemonClient?

    func connect() async {
        status = "Conectando..."
        isConnected = false

        let kind = Installation.kind(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )

        let installation = Installation(kind: kind)

        guard let executablePath = DaemonEndpoint.bundledExecutablePath() else {
            status = "Executável do daemon não encontrado"
            return
        }

        let endpoint = DaemonEndpoint(
            installation: installation,
            executablePath: executablePath
        )

        let supervisor = DaemonSupervisor(
            endpoint: endpoint,
            launcher: ProcessDaemonLauncher()
        )

        do {
            let result = try await Task.detached {
                try supervisor.connect()
            }.value

            switch result {
            case .ready(let client, let welcome):
                self.client = client
                self.isConnected = true
                self.status = "Conectado ao daemon (PID: \(welcome.processId.map(String.init) ?? "?"))"

            case .outdated(let client, _):
                self.client = client
                self.status = "Daemon de outra versão"

            case .incompatible:
                self.status = "Daemon incompatível"
            }

        } catch {
            status = "Erro: \(error.localizedDescription)"
        }
    }
}