#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsMigrationTest.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/main.swift" <<'SWIFT'
import Foundation

@main
struct MigrationTest {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WireTunnelsMigration-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let current = root.appendingPathComponent("current", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data("legacy-a".utf8).write(to: legacy.appendingPathComponent("a.conf"))
        try Data("legacy-b".utf8).write(to: legacy.appendingPathComponent("b.conf"))
        try Data("current-a".utf8).write(to: current.appendingPathComponent("a.conf"))

        AppMigration.copyMissingContents(from: legacy, to: current, fileManager: fm)

        let preserved = try String(contentsOf: current.appendingPathComponent("a.conf"), encoding: .utf8)
        let copied = try String(contentsOf: current.appendingPathComponent("b.conf"), encoding: .utf8)
        guard preserved == "current-a" else {
            fatalError("existing WireTunnels file was overwritten")
        }
        guard copied == "legacy-b" else {
            fatalError("missing legacy file was not copied")
        }
        guard fm.fileExists(atPath: legacy.appendingPathComponent("b.conf").path) else {
            fatalError("legacy source was removed")
        }

        let suiteName = "WireTunnelsMigrationTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("could not create test defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "showNotifications")
        AppMigration.migratePreferencesIfNeeded(
            defaults: defaults,
            legacyDomain: [
                "launchAtLogin": true,
                "showNotifications": true,
                "showRawOutput": true
            ]
        )

        guard defaults.bool(forKey: "launchAtLogin") else {
            fatalError("legacy preference was not copied")
        }
        guard defaults.object(forKey: "showNotifications") as? Bool == false else {
            fatalError("existing WireTunnels preference was overwritten")
        }
        guard defaults.bool(forKey: "showRawOutput") else {
            fatalError("legacy raw-output preference was not copied")
        }

        print("WireTunnels migration behavior passed")
    }
}
SWIFT

xcrun swiftc \
    -parse-as-library \
    "$ROOT_DIR/WireTunnels/Services/AppPaths.swift" \
    "$ROOT_DIR/WireTunnels/Services/AppMigration.swift" \
    "$TEST_DIR/main.swift" \
    -o "$TEST_DIR/migration-test"

"$TEST_DIR/migration-test"
