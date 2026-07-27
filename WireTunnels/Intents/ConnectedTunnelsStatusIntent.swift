import AppIntents

struct ConnectedTunnelsStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "List Connected Tunnels"
    static var description = IntentDescription("Reports which WireTunnels tunnels are currently connected.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TunnelEntity]> & ProvidesDialog {
        guard let tunnelManager = AppIntentBridge.tunnelManager else {
            throw AppIntentError.appNotReady
        }
        let active = tunnelManager.tunnels.filter(\.isActive)
        let entities = active.map { TunnelEntity(id: $0.id, name: $0.name) }
        let dialog: String
        if active.isEmpty {
            dialog = "No tunnels are connected."
        } else {
            dialog = "\(active.count) tunnel\(active.count == 1 ? "" : "s") connected: \(active.map(\.name).joined(separator: ", "))."
        }
        return .result(value: entities, dialog: IntentDialog(stringLiteral: dialog))
    }
}
