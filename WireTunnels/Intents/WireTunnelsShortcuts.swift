import AppIntents

struct WireTunnelsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectTunnelIntent(),
            phrases: [
                "Connect \(\.$tunnel) in \(.applicationName)",
                "Connect to \(\.$tunnel) with \(.applicationName)"
            ],
            shortTitle: "Connect Tunnel",
            systemImageName: "network"
        )
        AppShortcut(
            intent: DisconnectTunnelIntent(),
            phrases: [
                "Disconnect \(\.$tunnel) in \(.applicationName)"
            ],
            shortTitle: "Disconnect Tunnel",
            systemImageName: "network.slash"
        )
        AppShortcut(
            intent: DisconnectAllTunnelsIntent(),
            phrases: [
                "Disconnect all tunnels in \(.applicationName)",
                "Stop all tunnels in \(.applicationName)"
            ],
            shortTitle: "Disconnect All Tunnels",
            systemImageName: "network.slash"
        )
        AppShortcut(
            intent: ConnectedTunnelsStatusIntent(),
            phrases: [
                "Which tunnels are connected in \(.applicationName)",
                "Show tunnel status in \(.applicationName)"
            ],
            shortTitle: "Tunnel Status",
            systemImageName: "list.bullet"
        )
    }
}
