#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/WireTunnels.xcodeproj/project.pbxproj"
APP="$ROOT_DIR/WireTunnels/WireTunnelsApp.swift"
PATHS="$ROOT_DIR/WireTunnels/Services/AppPaths.swift"
MIGRATION="$ROOT_DIR/WireTunnels/Services/AppMigration.swift"
HELPER="$ROOT_DIR/WireTunnelsHelper/HelperTool.swift"
COMMAND_SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"
ACCENT="$ROOT_DIR/WireTunnels/Assets.xcassets/AccentColor.colorset/Contents.json"

fail() {
    echo "WireTunnels identity test failed: $*" >&2
    exit 1
}

[ -f "$PROJECT" ] || fail "renamed Xcode project is missing"
[ -f "$APP" ] || fail "renamed app entry point is missing"
[ -f "$PATHS" ] || fail "renamed AppPaths source is missing"
[ -f "$MIGRATION" ] || fail "AppMigration source is missing"
[ -f "$HELPER" ] || fail "renamed helper source is missing"

grep -q 'com.fmdigitech.WireTunnels' "$PROJECT" ||
    fail "project must use the WireTunnels bundle identifier"
grep -q 'WireTunnels.app' "$PROJECT" ||
    fail "project must produce WireTunnels.app"
grep -q 'Window("WireTunnels", id: "dashboard")' "$APP" ||
    fail "main window must use the WireTunnels product name"
grep -q 'Application Support/WireTunnels' "$PATHS" ||
    fail "current application support path must use WireTunnels"
grep -q 'legacyUserRoot' "$PATHS" ||
    fail "legacy user data path must remain available for migration"
grep -q 'legacySystemRoot' "$PATHS" ||
    fail "legacy privileged path must remain available for compatibility"
grep -q 'migrateUserDataIfNeeded' "$MIGRATION" ||
    fail "user data migration must be implemented"
grep -q 'migratePreferencesIfNeeded' "$MIGRATION" ||
    fail "preference migration must be implemented"
grep -q 'copyItem' "$MIGRATION" ||
    fail "migration must copy rather than delete legacy data"
! grep -q 'moveItem' "$MIGRATION" ||
    fail "migration must not move or delete legacy data"
grep -q 'com.fmdigitech.WireTunnels' "$HELPER" ||
    fail "helper must validate the WireTunnels app identifier"
grep -q 'com.fmdigitech.WireTunnels.helper' "$COMMAND_SERVICE" ||
    fail "app must connect to the WireTunnels helper"
grep -q '"red" : "0.4862745098"' "$ACCENT" ||
    fail "accent red component must match #7C4DFF"
grep -q '"green" : "0.3019607843"' "$ACCENT" ||
    fail "accent green component must match #7C4DFF"
grep -q '"blue" : "1.0000000000"' "$ACCENT" ||
    fail "accent blue component must match #7C4DFF"

echo "WireTunnels identity and migration checks passed"
