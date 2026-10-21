#if DEBUG
import Foundation

/// Starts the debug control socket for the running app. Debug builds only.
@MainActor
enum DebugControl {
    private static var server: DebugControlServer?

    static func start(_ manager: TunnelManager) {
        let server = DebugControlServer { request in
            await DebugControlTools.handle(request, manager: manager)
        }
        do {
            try server.start()
            self.server = server
            LogService.shared.info("Debug control socket: \(DebugControlServer.defaultPath)")
        } catch {
            LogService.shared.warning("Debug control socket unavailable: \(error)")
        }
    }
}

/// Maps `{"tool": ..., "args": {...}}` requests onto the app's `TunnelManager`.
/// Private keys never leave the app: config reads hide PrivateKey/PresharedKey.
@MainActor
enum DebugControlTools {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func handle(_ request: Data, manager: TunnelManager) async -> Data {
        do {
            guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
                  let tool = object["tool"] as? String else {
                throw Failure("Expected {\"tool\": ..., \"args\": {...}}")
            }
            return encode(["ok": true, "result": try await run(tool, object["args"] as? [String: Any] ?? [:], manager)])
        } catch {
            return encode(["ok": false, "error": error.localizedDescription])
        }
    }

    private static func run(_ tool: String, _ args: [String: Any], _ manager: TunnelManager) async throws -> Any {
        switch tool {
        case "list_tunnels":
            return manager.tunnels.map(summary)
        case "app_status":
            return [
                "initialized": manager.isInitialized, "loading": manager.isLoading,
                "needsSetup": manager.needsSetup, "setupStatus": orNull(manager.setupStatus),
                "helperRequiresApproval": manager.helperRequiresApproval,
                "toolInstallRequired": manager.toolInstallRequired,
                "error": orNull(manager.errorMessage),
                "warnings": manager.activeWarnings.map { String(describing: $0) },
                "menuBar": manager.menuBarConnectionStatus.description,
                "tunnelStatus": Dictionary(uniqueKeysWithValues: manager.tunnels.compactMap { tunnel in
                    manager.connectionStatus(for: tunnel).map { (tunnel.name, $0.description) }
                }),
            ] as [String: Any]
        case "clear_error":
            manager.errorMessage = nil
            return ["error": NSNull()]
        case "get_log":
            let count = max(1, min(args["lines"] as? Int ?? 100, 1000))
            return Array(LogService.shared.logLines.suffix(count))
        case "refresh_status":
            await manager.refreshStatus()
            return manager.tunnels.map(summary)
        case "read_config":
            let text = try String(contentsOfFile: try find(args, manager).configPath, encoding: .utf8)
            return text.replacingOccurrences(
                of: "(?im)^([ \\t]*(?:PrivateKey|PresharedKey)[ \\t]*=[ \\t]*).*$",
                with: "$1(hidden)", options: .regularExpression)
        case "connect":
            let tunnel = try find(args, manager)
            manager.errorMessage = nil
            // "auto": true exercises the On-Demand path, whose failures must stay passive.
            await manager.connectTunnel(tunnel, isAutoConnect: args["auto"] as? Bool ?? false)
            return outcome(tunnel.id, manager)
        case "disconnect":
            let tunnel = try find(args, manager)
            manager.errorMessage = nil
            await manager.disconnectTunnel(tunnel)
            return outcome(tunnel.id, manager)
        case "stop_all":
            manager.errorMessage = nil
            await manager.stopAllActive()
            return outcome(nil, manager)
        case "duplicate_tunnel":
            return summary(try manager.duplicateTunnel(try find(args, manager)))
        case "create_tunnel":
            guard let name = args["name"] as? String, let config = args["config"] as? String else {
                throw Failure("create_tunnel needs name and config")
            }
            try await manager.createTunnel(name: name, configContent: config)
            return manager.tunnels.map(summary)
        case "update_tunnel":
            // Without "config" the current file is reused, so renames never expose keys.
            let tunnel = try find(args, manager)
            let config = try args["config"] as? String ?? String(contentsOfFile: tunnel.configPath, encoding: .utf8)
            try await manager.updateTunnel(tunnel, name: args["name"] as? String ?? tunnel.name, configContent: config)
            return manager.tunnels.map(summary)
        case "delete_tunnel":
            let tunnel = try find(args, manager)
            manager.errorMessage = nil
            manager.deleteTunnel(tunnel)
            return ["deleted": !manager.tunnels.contains { $0.id == tunnel.id }, "error": orNull(manager.errorMessage)]
        case "set_kill_switch":
            guard let enabled = args["enabled"] as? Bool else { throw Failure("set_kill_switch needs enabled") }
            let tunnel = try find(args, manager)
            manager.updateKillSwitch(for: tunnel, enabled: enabled)
            return outcome(tunnel.id, manager)
        case "set_split_dns":
            guard let domains = args["domains"] as? [String] else { throw Failure("set_split_dns needs domains") }
            let tunnel = try find(args, manager)
            manager.updateSplitDNSDomains(for: tunnel, domains: domains, reconnect: args["reconnect"] as? Bool ?? false)
            return outcome(tunnel.id, manager)
        case "set_excluded_routes":
            guard let routes = args["routes"] as? [String] else { throw Failure("set_excluded_routes needs routes") }
            let tunnel = try find(args, manager)
            manager.updateExcludedRoutes(for: tunnel, routes: routes)
            return outcome(tunnel.id, manager)
        default:
            throw Failure("Unknown tool: \(tool)")
        }
    }

    private static func find(_ args: [String: Any], _ manager: TunnelManager) throws -> Tunnel {
        guard let key = args["tunnel"] as? String else { throw Failure("Missing \"tunnel\" (id or name)") }
        let matches = manager.tunnels.filter { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame
            || $0.name.caseInsensitiveCompare(key) == .orderedSame }
        guard matches.count == 1, let tunnel = matches.first else {
            let names = manager.tunnels.map(\.name).joined(separator: ", ")
            throw Failure(matches.isEmpty ? "No tunnel \"\(key)\". Available: \(names)" : "\"\(key)\" is ambiguous; use the id")
        }
        return tunnel
    }

    private static func outcome(_ id: UUID?, _ manager: TunnelManager) -> [String: Any] {
        let tunnels = manager.tunnels.filter { id == nil || $0.id == id }
        return ["tunnels": tunnels.map(summary), "error": orNull(manager.errorMessage)]
    }

    private static func summary(_ t: Tunnel) -> [String: Any] {
        [
            "id": t.id.uuidString, "name": t.name, "scope": t.scope.rawValue,
            "active": t.isActive, "interface": orNull(t.interfaceName), "endpoint": orNull(t.endpoint),
            "address": t.address ?? [], "allowedIPs": t.allowedIPs, "dns": t.dns,
            "splitDNSDomains": t.splitDNSDomains, "excludedRoutes": t.excludedRoutes,
            "killSwitch": t.killSwitchEnabled, "favorite": t.isFavorite,
            "autoConnect": ["connect": t.autoConnectRule.connect.enabled,
                            "disconnect": t.autoConnectRule.disconnect.enabled],
            "lastHandshake": orNull(t.lastHandshake.map { ISO8601DateFormatter().string(from: $0) }),
            "connectedAt": orNull(t.connectedAt.map { ISO8601DateFormatter().string(from: $0) }),
            "rxBytes": t.rxBytes, "txBytes": t.txBytes,
            "runtimeConfig": orNull(t.runtimeConfigPath.map { URL(fileURLWithPath: $0).lastPathComponent }),
        ]
    }

    private static func orNull(_ value: Any?) -> Any { value ?? NSNull() }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"Result was not encodable"}"#.utf8)
    }
}
#endif
