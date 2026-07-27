import AppIntents

struct DisconnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect Tunnel"
    static var description = IntentDescription("Disconnects the specified WireTunnels tunnel.")

    @Parameter(title: "Tunnel")
    var tunnel: TunnelEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let tunnelManager = AppIntentBridge.tunnelManager else {
            throw AppIntentError.appNotReady
        }
        guard let live = tunnelManager.tunnels.first(where: { $0.id == tunnel.id }) else {
            return .result()
        }
        await tunnelManager.disconnectTunnel(live)
        return .result()
    }
}
