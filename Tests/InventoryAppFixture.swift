import Foundation

// Compile the real app integration against a small helper boundary, without
// registering a daemon or touching the host network.
@MainActor
final class TunnelManager {
    struct Chain { var hopTunnelID: UUID; var exitTunnelID: UUID }
    final class Commands {
        var requests: [InventoryRoutingRequest] = []
        func updateInventoryRouting(_ request: InventoryRoutingRequest) async throws {
            requests.append(request)
        }
    }
    var tunnels: [Tunnel] = []
    var refreshingInventories: Set<UUID> = []
    var inventoryErrors: [UUID: String] = [:]
    var inventoryGenerations: [UUID: UUID] = [:]
    var inventoryTasks: [UUID: Task<[String], Error>] = [:]
    var connectingTunnels: Set<UUID> = []
    var hopChains: [Chain] = []
    let commandService = Commands()
    var saved: [Tunnel] = []
    func saveInventoryTunnels() throws { saved = tunnels }
}

extension InventoryRoutingTests {
    @MainActor
    static func appIntegration() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".conf")
        defer { try? FileManager.default.removeItem(at: file) }
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        try """
        [Interface]
        PrivateKey = \(key)
        Address = 192.0.2.1/32
        [Peer]
        PublicKey = \(key)
        Endpoint = 198.51.100.1:51820
        AllowedIPs = 192.0.2.0/24
        """.write(to: file, atomically: true, encoding: .utf8)
        var tunnel = Tunnel(name: "Inventory", configPath: file.path)
        // Live AllowedIPs must never become the source of the static base.
        tunnel.allowedIPs = ["203.0.113.99/32"]
        tunnel.inventoryCommand = InventoryCommand(executable: "/usr/bin/printf", arguments: ["203.0.113.1\\n2001:db8::1\\n"])
        tunnel.isActive = true
        let manager = TunnelManager(); manager.tunnels = [tunnel]
        try await manager.protectInventory(tunnel)
        try await manager.applyCachedInventory(tunnel)
        await manager.refreshInventory(for: tunnel)
        try check(manager.commandService.requests.last?.staticPrefixes == ["192.0.2.0/24"], "static base is read from saved config")
        try check(manager.tunnels[0].allowedIPs == ["192.0.2.0/24", "203.0.113.1/32", "2001:db8::1/128"], "script output reaches live AllowedIPs")
        try check(manager.saved[0].inventoryAllowedIPs == ["203.0.113.1/32", "2001:db8::1/128"], "successful inventory persists")
        let count = manager.commandService.requests.count
        manager.tunnels[0].inventoryCommand = InventoryCommand(executable: "/usr/bin/false", arguments: [])
        await manager.refreshInventory(for: tunnel)
        try check(manager.commandService.requests.count == count, "failed command never changes helper policy")
        try check(manager.tunnels[0].inventoryAllowedIPs.count == 2 && manager.inventoryErrors[tunnel.id] != nil, "failed fetch keeps cache and displays error")
        manager.tunnels[0].inventoryCommand = InventoryCommand(executable: "/bin/sleep", arguments: ["10"])
        let refresh = Task { await manager.refreshInventory(for: tunnel) }
        try await Task.sleep(nanoseconds: 30_000_000)
        try await manager.protectInventory(tunnel)
        manager.tunnels[0].isActive = false
        await refresh.value
        try check(manager.commandService.requests.last?.action == .protect, "disconnect cancels refresh without reopening policy")
        try await manager.updateInventoryCommand(for: tunnel, command: nil)
        try check(manager.commandService.requests.last?.action == .remove && manager.saved[0].inventoryCommand == nil, "disable removes helper policy and metadata")
    }
}
