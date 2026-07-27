import AppIntents

struct TunnelEntity: AppEntity {
    let id: UUID
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tunnel"
    static var defaultQuery = TunnelEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct TunnelEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [TunnelEntity.ID]) async throws -> [TunnelEntity] {
        let tunnels = AppIntentBridge.tunnelManager?.tunnels ?? []
        return tunnels
            .filter { identifiers.contains($0.id) }
            .map { TunnelEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TunnelEntity] {
        let tunnels = AppIntentBridge.tunnelManager?.tunnels ?? []
        return tunnels.map { TunnelEntity(id: $0.id, name: $0.name) }
    }
}
