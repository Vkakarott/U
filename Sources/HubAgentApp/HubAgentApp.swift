import SwiftUI

@main
struct HubAgentApp: App {
    @State private var daemon = DaemonStatusModel()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("Hub Agent")
                    .font(.title)

                Text(daemon.status)

                Circle()
                    .fill(daemon.isConnected ? .green : .red)
                    .frame(width: 12, height: 12)
            }
            .padding(32)
            .task {
                await daemon.connect()
            }
        }
    }
}