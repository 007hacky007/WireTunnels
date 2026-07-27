import Foundation

/// Pairs two personal tunnels into a client-side multi-hop chain: `hopTunnelID`
/// connects normally, then `exitTunnelID`'s WireGuard handshake/data packets are
/// routed through the hop's interface via a host route (see
/// `TunnelManager.connectHopChain`), so the exit server sees traffic arriving from
/// the hop's exit IP rather than the real one.
struct HopChain: Identifiable, Codable, Equatable {
    let id: UUID
    var hopTunnelID: UUID
    var exitTunnelID: UUID
    var isEnabled: Bool
    var createdAt: Date

    init(hopTunnelID: UUID, exitTunnelID: UUID, isEnabled: Bool = true) {
        self.id = UUID()
        self.hopTunnelID = hopTunnelID
        self.exitTunnelID = exitTunnelID
        self.isEnabled = isEnabled
        self.createdAt = Date()
    }
}
