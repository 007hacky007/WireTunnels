import Foundation

@main
struct KillSwitchRulesTests {
    static func main() {
        let rules = KillSwitchEntry.rules(for: [
            KillSwitchEntry(interfaceName: "utun4", endpointHost: "198.51.100.7", endpointPort: 51820),
            KillSwitchEntry(interfaceName: "utun5", endpointHost: "2001:db8::7", endpointPort: 443)
        ]).split(separator: "\n").map(String.init)
        guard rules.prefix(2) == ["block drop all", "pass quick on lo0 all"] else {
            print("FAIL: the kill switch must start by blocking everything except loopback"); exit(1)
        }
        guard rules.contains("pass quick on utun4 all"), rules.contains("pass quick on utun5 all") else {
            print("FAIL: every armed tunnel interface must pass"); exit(1)
        }
        let endpoints = rules.filter { $0.hasPrefix("pass out quick proto udp") }
        guard endpoints.count == 2, endpoints.allSatisfy({ $0.hasSuffix("user root") }) else {
            print("FAIL: the endpoint exception must be limited to root-owned WireGuard transport"); exit(1)
        }
        // After "block drop all" a stateless exception would drop the server's replies.
        guard !rules.contains(where: { $0.contains("no state") }) else {
            print("FAIL: kill switch rules must keep state so the server's replies are accepted"); exit(1)
        }
        guard KillSwitchEntry.rules(for: []) == "block drop all\npass quick on lo0 all\n" else {
            print("FAIL: an empty entry list must still block"); exit(1)
        }
        print("PASS: kill switch rules block by default, pass the tunnel and keep state for the endpoint")
    }
}
