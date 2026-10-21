#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/WireTunnelsFunctionalSettings.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/main.swift" <<'SWIFT'
import Foundation
import UserNotifications

@MainActor
private final class NotificationDeliverySpy: NotificationDelivering {
    var authorizationRequests = 0
    var authorizationGranted = true
    var delivered: [UNMutableNotificationContent] = []

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        return authorizationGranted
    }

    func add(_ request: UNNotificationRequest) async throws {
        delivered.append(request.content.mutableCopy() as! UNMutableNotificationContent)
    }
}

@main
@MainActor
struct FunctionalSettingsTest {
    static func main() async throws {
        try await testNotifications()
        try testLogPreferencesAndClear()
        try testResetBoundariesAndIntegrationSignal()
        print("Functional settings behavior passed")
    }

    private static func testNotifications() async throws {
        let suiteName = "WireTunnelsNotificationTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let delivery = NotificationDeliverySpy()
        let service = NotificationService(defaults: defaults, delivery: delivery)

        guard await service.setNotificationsEnabled(true) else {
            fatalError("enabling notifications should reflect granted authorization")
        }
        guard delivery.authorizationRequests == 1 else {
            fatalError("enabling notifications did not request authorization")
        }

        try await service.postConnected(tunnelName: "Office")
        try await service.postDisconnected(tunnelName: "Office")
        try await service.postError(tunnelName: "Office", message: "Handshake failed")
        guard delivery.delivered.count == 3 else {
            fatalError("connect, disconnect, and error notifications were not delivered")
        }
        guard delivery.delivered.map(\.title) == [
            "Tunnel Connected",
            "Tunnel Disconnected",
            "Tunnel Error"
        ] else {
            fatalError("notification event titles are incorrect")
        }

        _ = await service.setNotificationsEnabled(false)
        try await service.postConnected(tunnelName: "Ignored")
        guard delivery.delivered.count == 3 else {
            fatalError("disabled notifications should not be delivered")
        }
    }

    private static func testLogPreferencesAndClear() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WireTunnelsLogTest-\(UUID().uuidString)", isDirectory: true)
        let logFile = root.appendingPathComponent("logs/test.log")
        let suiteName = "WireTunnelsLogTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let log = LogService(logFile: logFile, defaults: defaults)

        defaults.set(false, forKey: LogService.showRawOutputPreferenceKey)
        log.rawOutput("secret wg output")
        guard log.logLines.isEmpty else {
            fatalError("raw output was logged while the preference was disabled")
        }

        defaults.set(true, forKey: LogService.showRawOutputPreferenceKey)
        log.rawOutput("visible wg output")
        guard log.logLines.count == 1,
              log.logLines[0].contains("visible wg output"),
              FileManager.default.fileExists(atPath: logFile.path) else {
            fatalError("enabled raw output was not written to memory and disk")
        }

        log.clearLog()
        guard log.logLines.isEmpty else {
            fatalError("clear did not remove in-memory log entries")
        }
        guard !FileManager.default.fileExists(atPath: logFile.path) else {
            fatalError("clear did not remove the disk log")
        }
    }

    private static func testResetBoundariesAndIntegrationSignal() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WireTunnelsResetTest-\(UUID().uuidString)", isDirectory: true)
        let configs = root.appendingPathComponent("user/configs", isDirectory: true)
        let metadata = root.appendingPathComponent("user/metadata", isDirectory: true)
        let logs = root.appendingPathComponent("user/logs", isDirectory: true)
        let systemRuntime = root.appendingPathComponent("system/runtime", isDirectory: true)
        let helper = root.appendingPathComponent("system/helper", isDirectory: false)
        let suiteName = "WireTunnelsResetTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        for directory in [configs, metadata, logs, systemRuntime] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("data".utf8).write(to: directory.appendingPathComponent("test"))
        }
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: helper)
        defaults.set(true, forKey: "showNotifications")
        defaults.set(true, forKey: "showRawOutput")

        let service = AppDataResetService(
            userDataDirectories: [configs, metadata, logs],
            defaults: defaults,
            defaultsDomain: suiteName
        )
        var completionCalled = false
        var notificationReceived = false
        let observer = NotificationCenter.default.addObserver(
            forName: .appDataDidReset,
            object: nil,
            queue: nil
        ) { _ in
            notificationReceived = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try service.reset {
            completionCalled = true
        }

        guard [configs, metadata, logs].allSatisfy({
            !FileManager.default.fileExists(atPath: $0.path)
        }) else {
            fatalError("reset did not remove all user data")
        }
        guard FileManager.default.fileExists(atPath: systemRuntime.path),
              FileManager.default.fileExists(atPath: helper.path) else {
            fatalError("reset removed system runtime or helper data")
        }
        guard defaults.persistentDomain(forName: suiteName)?.isEmpty != false else {
            fatalError("reset did not remove preferences")
        }
        guard completionCalled, notificationReceived else {
            fatalError("reset did not expose manager integration signals")
        }
    }
}
SWIFT

xcrun swiftc \
    -parse-as-library \
    "$ROOT_DIR/WireTunnels/Services/AppPaths.swift" \
    "$ROOT_DIR/WireTunnels/Services/LogService.swift" \
    "$ROOT_DIR/WireTunnels/Services/NotificationService.swift" \
    "$ROOT_DIR/WireTunnels/Services/AppDataResetService.swift" \
    "$TEST_DIR/main.swift" \
    -o "$TEST_DIR/functional-settings-test"

"$TEST_DIR/functional-settings-test"

SETTINGS="$ROOT_DIR/WireTunnels/Views/Settings/SettingsView.swift"
MANAGER="$ROOT_DIR/WireTunnels/Services/TunnelManager.swift"
grep -q 'setNotificationsEnabled' "$SETTINGS" ||
    { echo "Settings must request authorization when notifications are enabled" >&2; exit 1; }
grep -q 'await tunnelManager.resetUserData()' "$SETTINGS" ||
    { echo "Settings reset must synchronize through TunnelManager" >&2; exit 1; }
grep -q 'AppDataResetService.shared' "$MANAGER" ||
    { echo "TunnelManager reset must use AppDataResetService" >&2; exit 1; }
grep -q 'log.clearLog()' "$MANAGER" ||
    { echo "TunnelManager reset must clear the in-memory log" >&2; exit 1; }
