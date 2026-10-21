import Foundation

@main
struct WireGuardDNSTests {
    static func main() {
        // wg-quick: anything that is not an IPv4/IPv6 address in `DNS =` is a search domain.
        let entries = ["192.168.10.112", "office.lan", "2001:db8::1", "fe80::1", "corp.example"]
        guard WireGuardDNS.servers(entries) == ["192.168.10.112", "2001:db8::1", "fe80::1"],
              WireGuardDNS.searchDomains(entries) == ["office.lan", "corp.example"] else {
            print("FAIL: DNS entries must split into servers and search domains like wg-quick does"); exit(1)
        }

        let parsed = WireGuardConfigParser().parse(string: """
        [Interface]
        PrivateKey = \(Data(repeating: 1, count: 32).base64EncodedString())
        Address = 10.0.0.2/32
        DNS = 192.168.10.112, office.lan
        [Peer]
        PublicKey = \(Data(repeating: 2, count: 32).base64EncodedString())
        AllowedIPs = 10.0.0.0/24
        Endpoint = 192.0.2.1:51820
        """)
        guard parsed.isValid, WireGuardDNS.servers(parsed.dns) == ["192.168.10.112"],
              WireGuardDNS.searchDomains(parsed.dns) == ["office.lan"] else {
            print("FAIL: a config with a search domain must parse and split"); exit(1)
        }

        let ok = WireGuardDNS.compose(servers: "192.168.10.112", searchDomains: "Office.LAN, corp.lan  office.lan")
        guard ok.line == "192.168.10.112, office.lan, corp.lan", ok.invalidDomains.isEmpty else {
            print("FAIL: domains must be normalized, de-duplicated and appended to the servers: \(ok)"); exit(1)
        }
        let onlyDomains = WireGuardDNS.compose(servers: "", searchDomains: "office.lan")
        guard onlyDomains.line == "office.lan" else { print("FAIL: domains without servers"); exit(1) }

        // Anything that could reach wg-quick unquoted must be rejected, not passed through.
        let bad = WireGuardDNS.compose(servers: "1.1.1.1", searchDomains: "good.lan, bad domain!, $(touch x), *, -x.lan, a..b")
        guard bad.line == "1.1.1.1, good.lan, bad",
              bad.invalidDomains == ["domain!", "$(touch", "x)", "*", "-x.lan", "a..b"] else {
            print("FAIL: invalid search domains must be dropped and reported: \(bad)"); exit(1)
        }
        guard WireGuardDNS.compose(servers: "", searchDomains: "").line.isEmpty else {
            print("FAIL: empty input must give an empty DNS line"); exit(1)
        }
        guard WireGuardDNS.normalizedDomain("*.Corp.Example.") == "corp.example",
              WireGuardDNS.normalizedDomain(String(repeating: "a", count: 64) + ".lan") == nil else {
            print("FAIL: domain normalization"); exit(1)
        }
        print("PASS: DNS entries split like wg-quick, search domains are validated and composed back into the DNS line")
    }
}
