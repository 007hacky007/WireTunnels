#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/WireTunnelsModuleCache"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsAppRoutingEngine.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

cat > "${TEST_DIR}/main.swift" <<'SWIFT'
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

func lines(_ text: String) -> [String] {
    text.split(separator: "\n").map(String.init)
}

func rejects(_ entry: AppRoutingEntry) -> Bool {
    (try? AppRoutingEngine.ruleset(for: [entry])) == nil
}

let ruleA = "11111111-2222-3333-4444-555555555555"
let ruleB = "AAAAAAAA-2222-3333-4444-555555555555"

// Empty set => empty ruleset (nothing, not even a newline-only anchor body of rules).
let empty = try AppRoutingEngine.ruleset(for: [])
check(lines(empty).isEmpty, "empty entry set must produce an empty ruleset, got: \(empty)")

// Single entry with a live tunnel: order is pass-utun, route-to, block (last).
let single = lines(try AppRoutingEngine.ruleset(for: [
    AppRoutingEntry(ruleId: ruleA, groupId: 7300, interfaceName: "utun4", allowIPv6: false)
]))
let group = single.filter { $0.contains("group 7300") }
check(group.count == 3, "expected pass utun + route-to + block for gid 7300, got \(group)")
check(group[0].hasPrefix("pass out quick on utun4 ") && group[0].contains("group 7300"), "pass on utun must come first: \(group[0])")
check(group[1].contains("route-to utun4") && group[1].contains("inet proto"), "route-to must come second: \(group[1])")
check(group[2].hasPrefix("block drop out quick"), "fail-closed block must come last: \(group[2])")
check(single.last == group[2], "block must be the last line of the single-entry ruleset")
check(group.allSatisfy { $0.contains("on ! lo0") || $0.contains("on utun4") }, "group rules must never apply to loopback")
check(!single.contains { $0.contains("inet6") && $0.contains("group 7300") }, "no IPv6 rule unless allowIPv6")

// nil interface => block only.
let blocked = lines(try AppRoutingEngine.ruleset(for: [
    AppRoutingEntry(ruleId: ruleA, groupId: 7301, interfaceName: nil, allowIPv6: true)
]))
check(blocked.count == 1 && blocked[0].hasPrefix("block drop out quick") && blocked[0].contains("group 7301"),
      "nil interface must yield exactly one block rule, got \(blocked)")
check(!blocked.contains { $0.contains("route-to") || $0.contains("nat ") }, "nil interface must not route or NAT")

// IPv6 only when allowIPv6.
let v6 = lines(try AppRoutingEngine.ruleset(for: [
    AppRoutingEntry(ruleId: ruleA, groupId: 7302, interfaceName: "utun5", allowIPv6: true)
]))
check(v6.contains { $0.contains("route-to utun5 inet6") && $0.contains("group 7302") }, "allowIPv6 must add an inet6 route-to rule")

// Two entries must not interleave: all rules of the lower gid precede the higher gid.
let two = lines(try AppRoutingEngine.ruleset(for: [
    AppRoutingEntry(ruleId: ruleB, groupId: 7401, interfaceName: "utun7", allowIPv6: false),
    AppRoutingEntry(ruleId: ruleA, groupId: 7400, interfaceName: nil, allowIPv6: false)
]))
let g0 = two.indices.filter { two[$0].contains("group 7400") }
let g1 = two.indices.filter { two[$0].contains("group 7401") }
check(!g0.isEmpty && !g1.isEmpty, "both groups must appear")
check(g0.max()! < g1.min()!, "entries must not interleave (sorted by gid, each contiguous)")
check(g1.last == two.count - 1 || two[g1.last!].hasPrefix("block"), "block is the last rule of its entry")

// Validation: gid range, utun names, rule ids.
for gid in [0, 1, 7299, 8000, 65534, -1] {
    check(rejects(AppRoutingEntry(ruleId: ruleA, groupId: gid, interfaceName: nil, allowIPv6: false)), "gid \(gid) must be rejected")
}
for name in ["en0", "lo0", "utun", "utun1234", "utun1;", "utun 1", "utun1 \nblock", "UTUN1", "utunx", "utun-1", "bridge0", "utun1\n"] {
    check(rejects(AppRoutingEntry(ruleId: ruleA, groupId: 7300, interfaceName: name, allowIPv6: false)), "interface \(name.debugDescription) must be rejected")
}
for id in ["", "not-a-uuid", ruleA + "x", "\(ruleA)\nblock all", " " + ruleA] {
    check(rejects(AppRoutingEntry(ruleId: id, groupId: 7300, interfaceName: nil, allowIPv6: false)), "rule id \(id.debugDescription) must be rejected")
}
// Duplicate rule or group.
check((try? AppRoutingEngine.ruleset(for: [
    AppRoutingEntry(ruleId: ruleA, groupId: 7300, interfaceName: nil, allowIPv6: false),
    AppRoutingEntry(ruleId: ruleB, groupId: 7300, interfaceName: nil, allowIPv6: false)
])) == nil, "duplicate gid must be rejected")
check((try? AppRoutingEngine.ruleset(for: [
    AppRoutingEntry(ruleId: ruleA, groupId: 7300, interfaceName: nil, allowIPv6: false),
    AppRoutingEntry(ruleId: ruleA.lowercased(), groupId: 7301, interfaceName: nil, allowIPv6: false)
])) == nil, "duplicate rule id (case-insensitive) must be rejected")

// Token whitelist: every line is built only from known keywords, integers and a validated utun.
let big = try AppRoutingEngine.ruleset(for: [
    AppRoutingEntry(ruleId: ruleA, groupId: 7300, interfaceName: "utun4", allowIPv6: true),
    AppRoutingEntry(ruleId: ruleB, groupId: 7301, interfaceName: nil, allowIPv6: true)
])
let allowedWords: Set<String> = [
    "pass", "block", "drop", "out", "quick", "on", "!", "lo0", "all", "group", "no", "state", "keep",
    "route-to", "inet", "inet6", "proto", "{", "}", "tcp", "udp", "from", "any", "to", "nat", "->",
    "flags", "(if-bound)"
]
for line in lines(big) {
    for token in line.split(separator: " ").map(String.init) {
        if allowedWords.contains(token) { continue }
        if Int(token) != nil { continue }
        if AppRoutingEngine.isValidInterfaceName(token) { continue }
        // (utunN) in the nat/second-pass rules
        if token.hasPrefix("(") && token.hasSuffix(")") && AppRoutingEngine.isValidInterfaceName(String(token.dropFirst().dropLast())) { continue }
        check(false, "unexpected token \(token.debugDescription) in rule: \(line)")
    }
}

check(AppRoutingEngine.anchor == "com.apple/250.WireTunnels.AppRouting", "anchor constant changed")
print("OK")
SWIFT

xcrun swiftc -module-cache-path "${MODULE_CACHE_DIR}" \
    "${ROOT_DIR}/WireTunnelsHelper/AppRoutingEngine.swift" \
    "${TEST_DIR}/main.swift" \
    -o "${TEST_DIR}/test_app_routing_engine"

"${TEST_DIR}/test_app_routing_engine"
