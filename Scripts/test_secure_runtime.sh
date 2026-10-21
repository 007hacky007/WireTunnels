#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS="$ROOT_DIR/Scripts/wireguard-versions.env"
BUILD_SCRIPT="$ROOT_DIR/Scripts/build_wireguard_binaries.sh"
APP_PROTOCOL="$ROOT_DIR/WireTunnels/Helpers/XPC/WireguardHelperProtocol.swift"
HELPER_PROTOCOL="$ROOT_DIR/WireTunnelsHelper/WireguardHelperProtocol.swift"
HELPER="$ROOT_DIR/WireTunnelsHelper/HelperTool.swift"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"
SETTINGS="$ROOT_DIR/WireTunnels/Views/Settings/SettingsView.swift"
COMMAND_SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"
PATHS="$ROOT_DIR/WireTunnels/Services/AppPaths.swift"
MANIFEST_SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardManifest.swift"
RUNTIME_STATUS="$ROOT_DIR/WireTunnels/Models/WireGuardRuntimeStatus.swift"

fail() {
    echo "secure runtime test failed: $*" >&2
    exit 1
}

[ -f "$VERSIONS" ] || fail "missing pinned WireGuard revisions"

grep -Eq '^WIREGUARD_GO_REVISION=[0-9a-f]{40}$' "$VERSIONS" ||
    fail "wireguard-go revision must be a full commit hash"
grep -Eq '^WIREGUARD_TOOLS_REVISION=[0-9a-f]{40}$' "$VERSIONS" ||
    fail "wireguard-tools revision must be a full commit hash"
grep -q 'https://git.zx2c4.com/wireguard-go' "$VERSIONS" ||
    fail "wireguard-go source must be official"
grep -q 'https://git.zx2c4.com/wireguard-tools' "$VERSIONS" ||
    fail "wireguard-tools source must be official"

! grep -Eq 'git .* pull' "$BUILD_SCRIPT" ||
    fail "build must not update from a moving branch"
grep -q 'manifest.json' "$BUILD_SCRIPT" ||
    fail "build must generate a runtime manifest"
grep -q 'shasum -a 256' "$BUILD_SCRIPT" ||
    fail "build must hash bundled artifacts"

[ -f "$MANIFEST_SERVICE" ] || fail "missing app-side manifest verifier"
[ -f "$RUNTIME_STATUS" ] || fail "missing runtime status model"
grep -q 'import CryptoKit' "$MANIFEST_SERVICE" ||
    fail "manifest verifier must use CryptoKit"
grep -q 'schemaVersion == 1' "$MANIFEST_SERVICE" ||
    fail "manifest verifier must reject unsupported schemas"
grep -q 'expectedArtifactNames' "$MANIFEST_SERVICE" ||
    fail "manifest verifier must enforce the exact artifact set"
grep -q 'runtimeConfigDir' "$PATHS" ||
    fail "paths must define the privileged runtime directory"
grep -q 'legacyRuntimeConfigDir' "$PATHS" ||
    fail "paths must preserve legacy runtime directories"
grep -q 'userMetadataDir' "$PATHS" ||
    fail "paths must define user metadata storage"
grep -q 'userLogsDir' "$PATHS" ||
    fail "paths must define user log storage"

for protocol in "$APP_PROTOCOL" "$HELPER_PROTOCOL"; do
    grep -q 'installBundledTools' "$protocol" ||
        fail "protocol must expose installBundledTools"
    grep -q 'stageConfig(named' "$protocol" ||
        fail "protocol must stage configs by name"
    grep -q 'startTunnel(named' "$protocol" ||
        fail "protocol must start tunnels by name"
    grep -q 'stopTunnel(named' "$protocol" ||
        fail "protocol must stop tunnels by name"
    ! grep -Eq 'appBundlePath|sourcePath|destPath' "$protocol" ||
        fail "protocol must not accept arbitrary paths"
done

grep -q 'SecCodeCheckValidity' "$HELPER" ||
    fail "helper must validate the XPC client signature"
grep -q 'SecStaticCodeCheckValidity' "$HELPER" ||
    fail "helper must validate the complete signed app bundle"
grep -q 'createDirectory(stagedBin, permissions: 0o755)' "$HELPER" ||
    fail "installed binary directory must be root-owned and executable"
grep -q 'createDirectory(metadataDir, permissions: 0o755)' "$HELPER" ||
    fail "installed public manifest must remain readable to the app"
grep -q 'runtimeConfigDir' "$HELPER" ||
    fail "helper must use the new runtime directory"
grep -q 'legacyRuntimeConfigDirs' "$HELPER" ||
    fail "helper must preserve legacy stop compatibility"
grep -q 'manifest.json' "$HELPER" ||
    fail "helper must independently verify the manifest"

initialize_body="$(
    awk '
        /func initialize\(\) async/ { in_initialize = 1 }
        in_initialize { print }
        in_initialize && /^    }$/ { exit }
    ' "$MANAGER"
)"
! grep -q 'installBundledTools' <<<"$initialize_body" ||
    fail "initialization must not silently install tools"
grep -q 'func installBundledTools() async' "$MANAGER" ||
    fail "manager must expose an explicit installation action"
grep -q 'expectedHelperVersion' "$COMMAND_SERVICE" ||
    fail "command service must publish the bundled helper version"
grep -q 'version != WireGuardCommandService.expectedHelperVersion' "$MANAGER" ||
    fail "initialization must replace a reachable but stale helper"
grep -Eq 'Install Tools|Reinstall Tools' "$SETTINGS" ||
    fail "settings must expose explicit install or reinstall consent"
grep -qi 'no download' "$SETTINGS" ||
    fail "settings must explain that installation performs no download"

echo "Secure runtime requirements are implemented"
