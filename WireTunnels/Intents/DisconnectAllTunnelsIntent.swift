import AppIntents

struct DisconnectAllTunnelsIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect All Tunnels"
    static var description = IntentDescription("Disconnects every active WireTunnels tunnel.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let tunnelManager = AppIntentBridge.tunnelManager else {
            throw AppIntentError.appNotReady
        }
        await tunnelManager.stopAllActive()
        return .result()
    }
}
