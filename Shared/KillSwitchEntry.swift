import Foundation

nonisolated struct KillSwitchEntry: Codable {
    let interfaceName: String
    let endpointHost: String
    let endpointPort: Int

    static func rules(for entries: [Self]) -> String {
        var lines = ["block drop all", "pass quick on lo0 all"]
        for entry in entries {
            lines.append("pass quick on \(entry.interfaceName) all")
            lines.append("pass out quick proto udp to \(entry.endpointHost) port \(entry.endpointPort) user root")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
