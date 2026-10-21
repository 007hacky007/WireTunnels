#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT_DIR/WireTunnelsHelper/HelperTool.swift"
ENGINE="$ROOT_DIR/WireTunnelsHelper/AppRoutingEngine.swift"
STORE="$ROOT_DIR/WireTunnelsHelper/AppRoutingStore.swift"
LAUNCHER="$ROOT_DIR/WireTunnelsHelper/RoutedLauncher.swift"
PROTO_APP="$ROOT_DIR/WireTunnels/Helpers/XPC/WireguardHelperProtocol.swift"
PROTO_HELPER="$ROOT_DIR/WireTunnelsHelper/WireguardHelperProtocol.swift"
COMMAND_SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"
TUNNEL="$ROOT_DIR/WireTunnels/Models/Tunnel.swift"

fail() { echo "$1" >&2; exit 1; }

# Protocol copies.
diff "$PROTO_APP" "$PROTO_HELPER" >/dev/null ||
    fail "Both WireguardHelperProtocol.swift copies must stay byte-identical"

# The four XPC methods: protocol, helper, client.
for method in \
    'func syncAppRouting(entries: Data, reply: @escaping (Bool, String?) -> Void)' \
    'func appRoutingStatus(reply: @escaping (Data?, String?) -> Void)' \
    'func ensureAppRoutingGroup(ruleId: String, reply: @escaping (Int, String?) -> Void)' \
    'func removeAppRoutingGroup(ruleId: String, reply: @escaping (Bool, String?) -> Void)' \
    'func launchRoutedApp(bundlePath: String, ruleId: String, reply: @escaping (Bool, String?) -> Void)'; do
    grep -qF "$method" "$PROTO_APP" || fail "XPC protocol is missing: $method"
    grep -qF "$method" "$HELPER" || fail "HelperTool must implement: $method"
done
for client in \
    'func syncAppRouting(entries: [AppRoutingEntry]) async throws' \
    'func appRoutingStatus() async throws -> AppRoutingStatusReport' \
    'func ensureAppRoutingGroup(ruleId: UUID) async throws -> Int' \
    'func removeAppRoutingGroup(ruleId: UUID) async throws' \
    'func launchRoutedApp(bundlePath: String, ruleId: UUID) async throws'; do
    grep -qF "$client" "$COMMAND_SERVICE" || fail "WireGuardCommandService is missing: $client"
done

# Revision: equal on both sides, and not the pre-app-routing one (so older helpers are replaced).
expected=$(sed -n 's/.*expectedHelperProtocolRevision = "\([^"]*\)".*/\1/p' "$COMMAND_SERVICE")
reported=$(sed -n 's/.*helperProtocolRevisionValue = "\([^"]*\)".*/\1/p' "$HELPER")
[ -n "$expected" ] && [ "$expected" = "$reported" ] ||
    fail "Helper protocol revision mismatch: app='$expected' helper='$reported'"
[ "$expected" != "route-sync-v1" ] || fail "Protocol revision must be bumped from route-sync-v1"

# PF safety: never disable PF globally; "-F all/states/Tables" would wipe state shared with other
# software (the state table is global even with -a), so app routing may only flush our own
# anchor's rules and nat. The pre-existing kill switch flush is the one allowed "-F all".
if grep -nE '"-d"|"-F",[[:space:]]*"(all|states|Tables|queue)"' "$HELPER" "$ENGINE" "$STORE" "$LAUNCHER" |
    grep -vE '"-a",[[:space:]]*Self\.killSwitchAnchor,[[:space:]]*"-F",[[:space:]]*"all"' | grep .; then
    fail "pfctl must never be called with -d or a flush that wipes the state table"
fi
if grep -nE '"-F"' "$HELPER" | grep -vE '"-a"' | grep .; then
    fail "pfctl -F must always be scoped with -a <anchor>"
fi
grep -q 'static let anchor = "com.apple/250.WireTunnels.AppRouting"' "$ENGINE" ||
    fail "App routing anchor constant changed"
# -X releases only a token we hold; -E must be the ref-counted enable, never a bare -e in app routing.
app_routing_section=$(awk '/^private let appRoutingLock/{found=1} found' "$HELPER")
if grep -qE '"-e"|"-d"' <<<"$app_routing_section"; then
    fail "App routing must use pfctl -E/-X tokens, never -e/-d"
fi

# App routing never touches the kill switch anchor (only the lines from appRoutingLock onward
# and the dedicated files are app routing).
if grep -qiE 'killswitch' <<<"$app_routing_section"; then
    fail "App routing code must not reference the kill switch"
fi
for file in "$ENGINE" "$STORE" "$LAUNCHER"; do
    if grep -qiE 'killswitch' "$file"; then fail "$(basename "$file") must not reference the kill switch"; fi
done

# Launcher must be root-only, fixed-argument, drop privileges.
grep -q 'guard geteuid() == 0' "$LAUNCHER" || fail "Routed launcher must require euid 0"
grep -q 'setuid(uid_t(uid)) == 0' "$LAUNCHER" || fail "Routed launcher must drop to the user"
grep -q 'setuid(0) != 0' "$LAUNCHER" || fail "Routed launcher must verify root cannot be regained"
grep -q 'AppRoutingEngine.gidRange.contains(gid)' "$LAUNCHER" || fail "Routed launcher must validate the gid range"

# Imported config is never modified: the runtime copy is written only to a temp URL.
fn_body=$(awk '/private static func writeConfigWithoutDNS/{f=1} f{print} f&&/^    }$/{exit}' "$MANAGER")
[ -n "$fn_body" ] || fail "writeConfigWithoutDNS not found"
write_count=$(grep -c '\.write(' <<<"$fn_body")
[ "$write_count" = "1" ] || fail "writeConfigWithoutDNS must have exactly one write"
grep -q 'try filteredLines.joined(separator: "\\n").write(to: tempURL' <<<"$fn_body" ||
    fail "writeConfigWithoutDNS must write only to its temp copy"
grep -q 'temporaryDirectory' <<<"$fn_body" || fail "Runtime copy must live in the temporary directory"
grep -q 'runtimeConfigRemovingSystemRoutes' "$MANAGER" || fail "runtimeConfigRemovingSystemRoutes missing"
runtime_body=$(awk '/private static func runtimeConfigRemovingSystemRoutes/{f=1} f{print} f&&/^    }$/{exit}' "$MANAGER")
grep -q 'writeConfigWithoutDNS(from: configPath, tableOff: true)' <<<"$runtime_body" ||
    fail "runtimeConfigRemovingSystemRoutes must derive a Table = off copy"
if grep -q 'write(' <<<"$runtime_body"; then fail "runtimeConfigRemovingSystemRoutes must not write files itself"; fi

# Tunnel model.
grep -q 'decodeIfPresent(Bool.self, forKey: .appRoutingOnly) ?? false' "$TUNNEL" ||
    fail "appRoutingOnly must decode with a false fallback for old saved tunnels"

echo "OK"
