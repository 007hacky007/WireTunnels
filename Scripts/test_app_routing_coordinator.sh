#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/WireTunnelsModuleCache"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsAppRoutingCoordinator.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

# The coordinator's pure static functions (desiredEntries / deriveStates / assignmentProblem)
# are compiled from the real source; only the collaborators that need the helper, the logger
# and the filesystem layout are stubbed.
cat > "${TEST_DIR}/Stubs.swift" <<'SWIFT'
import Foundation

struct AppRoutingEntry: Codable, Equatable {
    let ruleId: String
    let groupId: Int
    let interfaceName: String?
    let allowIPv6: Bool
}

struct AppRoutingRuleStatus: Codable, Equatable {
    let ruleId: String
    let armed: Bool
    let routed: Bool
    let interfaceName: String?
    let reason: String?
}

struct AppRoutingStatusReport: Codable, Equatable {
    let helperInstanceId: String
    let pfEnabled: Bool
    let rules: [AppRoutingRuleStatus]
}

@MainActor
final class WireGuardCommandService {
    func appRoutingStatus() async throws -> AppRoutingStatusReport {
        AppRoutingStatusReport(helperInstanceId: "x", pfEnabled: true, rules: [])
    }
    func syncAppRouting(entries: [AppRoutingEntry]) async throws {}
    func ensureAppRoutingGroup(ruleId: UUID) async throws -> Int { 0 }
    func removeAppRoutingGroup(ruleId: UUID) async throws {}
    func launchRoutedApp(bundlePath: String, ruleId: UUID) async throws {}
}

final class LogService {
    static let shared = LogService()
    func info(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {}
}

enum AppPaths {
    static var userMetadataDir: URL { URL(fileURLWithPath: NSTemporaryDirectory()) }
}
SWIFT

cat > "${TEST_DIR}/main.swift" <<'SWIFT'
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

typealias C = AppRoutingCoordinator

func tunnel(_ name: String, appOnly: Bool = true, address: [String]? = ["10.0.0.2/32"], scope: TunnelScope = .personal) -> Tunnel {
    var t = Tunnel(name: name, configPath: "/tmp/\(name).conf")
    t.appRoutingOnly = appOnly
    t.address = address
    t.scope = scope
    return t
}

let tunnelA = tunnel("A")
let tunnelB = tunnel("B", address: ["10.0.0.3/32", "fd00::3/128"])
let ruleA = AppRoutingRule(bundleIdentifier: "com.example.a", appName: "A", appPath: "/Applications/A.app", tunnelID: tunnelA.id)
let ruleB = AppRoutingRule(bundleIdentifier: "com.example.b", appName: "B", appPath: "/Applications/B.app", tunnelID: tunnelB.id)
let groups = [ruleA.id: 7300, ruleB.id: 7301]

// Both live: each rule gets its own entry with the live interface; IPv6 follows the tunnel address.
var entries = C.desiredEntries(rules: [ruleA, ruleB], tunnels: [tunnelA, tunnelB],
                               liveInterfaces: [tunnelA.id: "utun4", tunnelB.id: "utun5"], groupIDs: groups)
check(entries.count == 2, "one entry per rule")
check(entries.first { $0.groupId == 7300 }?.interfaceName == "utun4", "rule A uses its live utun")
check(entries.first { $0.groupId == 7300 }?.allowIPv6 == false, "IPv4-only tunnel must not allow IPv6")
check(entries.first { $0.groupId == 7301 }?.allowIPv6 == true, "tunnel with an IPv6 address allows IPv6")

// Tunnel down: entry kept with nil interface (fail closed), never dropped, never stale.
entries = C.desiredEntries(rules: [ruleA, ruleB], tunnels: [tunnelA, tunnelB],
                           liveInterfaces: [tunnelB.id: "utun5"], groupIDs: groups)
check(entries.count == 2, "a down tunnel must keep its entry")
let down = entries.first { $0.groupId == 7300 }!
check(down.interfaceName == nil && down.allowIPv6 == false, "down tunnel => nil interface, no IPv6")

// Deleted tunnel: entry kept, blocked; even a stale live map entry for the id must not be used.
entries = C.desiredEntries(rules: [ruleA], tunnels: [], liveInterfaces: [tunnelA.id: "utun9"], groupIDs: groups)
check(entries.count == 1 && entries[0].interfaceName == nil, "deleted tunnel => blocked entry, no stale utun reuse")

// Tunnel no longer app-routing-only or shared: blocked, not routed system-wide.
var notOnly = tunnelA
notOnly.appRoutingOnly = false
entries = C.desiredEntries(rules: [ruleA], tunnels: [notOnly], liveInterfaces: [tunnelA.id: "utun4"], groupIDs: groups)
check(entries.count == 1 && entries[0].interfaceName == nil, "unusable tunnel must be blocked even if live")

// Disabled rules produce no entry; rules without a group are skipped (nothing to match on).
var disabled = ruleA
disabled.isEnabled = false
check(C.desiredEntries(rules: [disabled], tunnels: [tunnelA], liveInterfaces: [tunnelA.id: "utun4"], groupIDs: groups).isEmpty,
      "disabled rule must produce no entry")
check(C.desiredEntries(rules: [ruleA], tunnels: [tunnelA], liveInterfaces: [tunnelA.id: "utun4"], groupIDs: [:]).isEmpty,
      "rule without a group must produce no entry")

// Distinct gids and rule ids across entries.
entries = C.desiredEntries(rules: [ruleA, ruleB], tunnels: [tunnelA, tunnelB], liveInterfaces: [:], groupIDs: groups)
check(Set(entries.map(\.groupId)).count == entries.count && Set(entries.map(\.ruleId)).count == entries.count,
      "entries must have unique group and rule ids")

// States are derived from the helper's reported status only.
func st(_ rule: AppRoutingRule, armed: Bool = true, routed: Bool = false, iface: String? = nil,
        reason: String? = nil) -> AppRoutingRuleStatus {
    AppRoutingRuleStatus(ruleId: rule.id.uuidString, armed: armed, routed: routed, interfaceName: iface, reason: reason)
}
func report(_ rules: [AppRoutingRuleStatus], instance: String = "h1", pf: Bool = true) -> AppRoutingStatusReport {
    AppRoutingStatusReport(helperInstanceId: instance, pfEnabled: pf, rules: rules)
}
func state(_ rule: AppRoutingRule, tunnels: [Tunnel], live: [UUID: String], groups: [UUID: Int] = groups,
           groupErrors: [UUID: String] = [:], syncError: String? = nil, outside: Set<UUID> = [],
           status: AppRoutingStatusReport?) -> AppRoutingState {
    C.deriveStates(rules: [rule], tunnels: tunnels, liveInterfaces: live, groupIDs: groups,
                   groupErrors: groupErrors, syncError: syncError, runningOutside: outside,
                   status: status)[rule.id]!
}
let liveA = [tunnelA.id: "utun4"]
check(state(ruleA, tunnels: [tunnelA], live: liveA, status: report([st(ruleA, routed: true, iface: "utun4")])) == .routed,
      "armed + routed on the live utun => routed")
check(state(ruleA, tunnels: [tunnelA], live: [:], status: report([st(ruleA)])) == .blocked, "down + armed => blocked")
check(state(ruleA, tunnels: [tunnelA], live: [:], status: report([st(ruleA, routed: true, iface: "utun4")])) != .blocked,
      "helper still routing while tunnel down must not be reported blocked")
check(state(ruleA, tunnels: [tunnelA], live: liveA, status: report([st(ruleA, armed: false, reason: "pf load failed")]))
      == .failed("pf load failed"), "sync ok but armed=false => failed with the helper's reason")
check(state(ruleA, tunnels: [tunnelA], live: [:], status: report([st(ruleA, armed: false)])) != .blocked,
      "armed=false must never be blocked")
check(state(ruleA, tunnels: [tunnelA], live: liveA, status: report([st(ruleA, routed: true, iface: "utun9")])) != .routed,
      "routed on a different interface is not routed")
check(state(ruleA, tunnels: [tunnelA], live: liveA, status: report([st(ruleA)])) != .routed, "armed but not routed is not routed")
check(state(ruleA, tunnels: [tunnelA], live: liveA, status: report([])) != .routed, "missing helper entry is not routed")
check(state(ruleA, tunnels: [tunnelA], live: liveA, status: nil) != .routed, "no status => never routed")
check(state(ruleA, tunnels: [tunnelA], live: liveA, status: report([st(ruleA, routed: true, iface: "utun4")], pf: false)) != .routed,
      "PF disabled => not routed")
check(state(ruleA, tunnels: [], live: [:], status: report([st(ruleA)])) == .failed("Its tunnel was deleted. Assign another tunnel."), "deleted => failed")
check(state(ruleA, tunnels: [tunnelA], live: liveA, outside: [ruleA.id],
            status: report([st(ruleA, routed: true, iface: "utun4")])) == .needsRelaunch, "outside launcher => needsRelaunch")
check(state(ruleA, tunnels: [tunnelA], live: liveA, syncError: "boom",
            status: report([st(ruleA, routed: true, iface: "utun4")])) == .failed("boom"), "sync error => failed, never routed")
check(state(ruleA, tunnels: [tunnelA], live: liveA, groups: [:], groupErrors: [ruleA.id: "nope"],
            status: report([])) == .failed("nope"), "no group => failed")
check(state(disabled, tunnels: [tunnelA], live: liveA, status: report([])) == .configured, "disabled => configured")
check(state(ruleA, tunnels: [notOnly], live: liveA, status: report([st(ruleA, routed: true, iface: "utun4")])) != .routed,
      "unusable tunnel must never be reported routed")

// Resync decisions (pure).
let wantRouted = AppRoutingEntry(ruleId: ruleA.id.uuidString, groupId: 7300, interfaceName: "utun4", allowIPv6: false)
let wantBlocked = AppRoutingEntry(ruleId: ruleA.id.uuidString, groupId: 7300, interfaceName: nil, allowIPv6: false)
let okRouted = report([st(ruleA, routed: true, iface: "utun4")])
check(!C.needsResync(report: okRouted, lastInstanceId: "h1", desired: [wantRouted]), "in agreement => no resync")
check(C.needsResync(report: report([st(ruleA, routed: true, iface: "utun4")], instance: "h2"), lastInstanceId: "h1",
                    desired: [wantRouted]), "helperInstanceId change => resync")
check(C.needsResync(report: report([st(ruleA)]), lastInstanceId: "h1", desired: [wantRouted]), "armed but not routed => resync")
check(C.needsResync(report: report([st(ruleA, routed: true, iface: "utun9")]), lastInstanceId: "h1", desired: [wantRouted]),
      "wrong interface => resync")
check(C.needsResync(report: report([st(ruleA, armed: false)]), lastInstanceId: "h1", desired: [wantBlocked]), "armed=false => resync")
check(C.needsResync(report: report([]), lastInstanceId: "h1", desired: [wantBlocked]), "missing entry => resync")
check(C.needsResync(report: okRouted, lastInstanceId: "h1", desired: [wantBlocked]), "helper routes while desired blocked => resync")
check(!C.needsResync(report: report([st(ruleA)]), lastInstanceId: "h1", desired: [wantBlocked]), "blocked in agreement => no resync")
check(!C.needsResync(report: report([], instance: "h2"), lastInstanceId: nil, desired: []), "first sight, nothing wanted => no resync")

// Assignment rules.
check(C.assignmentProblem(for: tunnelA) == nil, "app-routing-only personal tunnel is assignable")
check(C.assignmentProblem(for: notOnly) != nil, "full-tunnel is not assignable")
check(C.assignmentProblem(for: tunnel("S", scope: .managed)) != nil, "shared tunnel is not assignable")
print("OK")
SWIFT

xcrun swiftc -module-cache-path "${MODULE_CACHE_DIR}" \
    "${ROOT_DIR}/WireTunnels/Services/AppRoutingCoordinator.swift" \
    "${ROOT_DIR}/WireTunnels/Services/AppRoutingRepository.swift" \
    "${ROOT_DIR}/WireTunnels/Models/AppRoutingRule.swift" \
    "${ROOT_DIR}/WireTunnels/Models/AutoConnectRule.swift" \
    "${ROOT_DIR}/WireTunnels/Models/Tunnel.swift" \
    "${TEST_DIR}/Stubs.swift" \
    "${TEST_DIR}/main.swift" \
    -o "${TEST_DIR}/test_app_routing_coordinator"

"${TEST_DIR}/test_app_routing_coordinator"
