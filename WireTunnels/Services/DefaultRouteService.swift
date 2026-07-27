import Foundation

/// Reads the current default route — unprivileged, direct-shellout-from-the-app
/// pattern like `PingService`/`NetworkMonitorService.knownWiFiNetworkNames()`.
/// Never cached: Wi-Fi/Ethernet switches change the default gateway, and a stale
/// value here would silently break split-tunnel exclusions.
enum DefaultRouteService {
    struct DefaultRoute {
        let gateway: String?
        let interfaceName: String
    }

    /// Blocking — call from a background task, not the main actor.
    nonisolated static func currentDefaultRoute() -> DefaultRoute? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var gateway: String?
        var interfaceName: String?
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gateway = trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("interface:") {
                interfaceName = trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }

        guard let interfaceName, !interfaceName.isEmpty else { return nil }
        return DefaultRoute(gateway: gateway, interfaceName: interfaceName)
    }
}
