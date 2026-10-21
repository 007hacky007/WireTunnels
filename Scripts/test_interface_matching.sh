#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsMatching.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

cat > "${TEST_DIR}/main.swift" <<'SWIFT'
import Foundation

func peer(_ key: String, _ endpoint: String) -> PeerStatus {
    PeerStatus(publicKey: key, endpoint: endpoint, allowedIPs: [], lastHandshake: nil, rxBytes: 0, txBytes: 0, persistentKeepalive: nil)
}
func status(_ iface: String, local: String, server: String, endpoint: String) -> TunnelStatus {
    TunnelStatus(interfaceName: iface, publicKey: local, listenPort: 0, peers: [peer(server, endpoint)])
}
func expect(_ cond: Bool, _ msg: String) { if !cond { fatalError(msg) } }

// GitHub #4: two clients, same server key + endpoint + port, only client A is up.
let a = InterfaceMatcher.Candidate(peerPublicKey: "SRV", localPublicKey: "A", endpoint: "1.2.3.4:51820", interfaceHint: "client_a")
let b = InterfaceMatcher.Candidate(peerPublicKey: "SRV", localPublicKey: "B", endpoint: "1.2.3.4:51820", interfaceHint: "client_b")
let live = ["utun4": status("utun4", local: "A", server: "SRV", endpoint: "1.2.3.4:51820")]
var m = InterfaceMatcher.assign([a, b], statuses: live)
expect(m[0]?.interfaceName == "utun4", "client A must own its interface")
expect(m[1] == nil, "client B must stay inactive when only A is up")

// Both up: each gets its own interface regardless of order or stale name hints.
let both = [
    "utun4": status("utun4", local: "A", server: "SRV", endpoint: "1.2.3.4:51820"),
    "utun5": status("utun5", local: "B", server: "SRV", endpoint: "1.2.3.4:51820"),
]
var staleB = b; staleB.interfaceHint = "utun4"   // utun numbers get recycled
m = InterfaceMatcher.assign([staleB, a], statuses: both)
expect(m[0]?.interfaceName == "utun5" && m[1]?.interfaceName == "utun4", "stale hints must not steal another client's interface")

// A key-less (e.g. old record) tunnel never takes an interface already owned by a keyed one.
let keyless = InterfaceMatcher.Candidate(peerPublicKey: "SRV", localPublicKey: nil, endpoint: "1.2.3.4:51820", interfaceHint: "old")
m = InterfaceMatcher.assign([keyless, a], statuses: live)
expect(m[1]?.interfaceName == "utun4" && m[0] == nil, "keyed tunnel wins over key-less one")

// v1.0.5 behaviour kept: same server key, different ports -> different tunnels.
let p443 = InterfaceMatcher.Candidate(peerPublicKey: "SRV", localPublicKey: nil, endpoint: "1.2.3.4:443", interfaceHint: "t443")
let p4443 = InterfaceMatcher.Candidate(peerPublicKey: "SRV", localPublicKey: nil, endpoint: "1.2.3.4:4443", interfaceHint: "t4443")
m = InterfaceMatcher.assign([p443, p4443], statuses: ["utun7": status("utun7", local: "X", server: "SRV", endpoint: "1.2.3.4:4443")])
expect(m[0] == nil && m[1]?.interfaceName == "utun7", "ports must still disambiguate")

// IPv6 endpoint parsing
expect(InterfaceMatcher.parseEndpoint("[2001:db8::1]:51820")?.port == 51820, "ipv6 endpoint")
print("Interface matching checks passed")
SWIFT

xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/WireTunnelsModuleCache" \
    "${ROOT_DIR}/WireTunnels/Models/TunnelStatus.swift" "${TEST_DIR}/main.swift" -o "${TEST_DIR}/t"
"${TEST_DIR}/t"
