import AppIntents

struct ConnectTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect Tunnel"
    static var description = IntentDescription("Connects the specified WireTunnels tunnel.")

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
        await tunnelManager.connectTunnel(live)
        return .result()
    }
}
