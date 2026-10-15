import AppKit
import Foundation
import Network
import CoreWLAN
import CoreLocation
import Combine
import OSLog
#if canImport(Darwin)
import Darwin
#endif

/// Monitors active network interfaces and drives auto-connect/disconnect logic.
@MainActor
final class NetworkMonitorService: NSObject, ObservableObject {
    @Published private(set) var isOnEthernet: Bool   = false
    @Published private(set) var isOnWiFi: Bool       = false
    @Published private(set) var currentSSID: String? = nil
    // macOS only returns a real SSID from CoreWLAN once Location Services access
    // is granted (privacy restriction since 10.15) — without it, SSID-scoped
    // On-Demand rules can never match even though "Any Wi-Fi" rules work fine.
    @Published private(set) var hasWiFiNamePermission: Bool = false

    // On-Demand rules describe the physical network. A userspace VPN can
    // replace the default path with an "other" (utun) interface, which would
    // otherwise make its own connect rule stop matching and tear it down.
    private let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
    private let queue   = DispatchQueue(label: "com.fmdigitech.WireTunnels.netmon", qos: .utility)
    private let log     = Logger(subsystem: "com.fmdigitech.WireTunnels", category: "NetworkMonitor")
    private let locationManager = CLLocationManager()

    /// Called on every network path change (already dispatched to MainActor).
    var onNetworkChange: (() async -> Void)?
    /// Called when the system wakes from sleep (already dispatched to MainActor).
    var onSystemWake: (() async -> Void)?
    /// Called when the primary physical interface keeps its name (no Wi-Fi/Ethernet
    /// switch) but its own IPv4 address changes — e.g. a DHCP lease renewal. Distinct
    /// from `onNetworkChange`, which only drives On-Demand rule evaluation and does
    /// nothing for an already-active tunnel that isn't governed by a rule.
    var onLocalAddressChange: (() async -> Void)?

    // Last-seen (interface name, IPv4 address) of the primary physical interface,
    // used to tell a DHCP renewal (same interface, new address) apart from a real
    // interface switch (handled separately via onNetworkChange/On-Demand rules).
    private var lastPrimaryInterfaceFingerprint: (name: String, address: String)?

    // Tunnels connected by the auto-connect rule (not by the user)
    private var autoConnectedIDs: Set<UUID>  = []
    // Tunnels the user manually disconnected while the rule was matching —
    // prevents immediate reconnect until the matching network is lost and rejoined.
    private var suppressedIDs: Set<UUID>     = []

    override init() {
        super.init()
        locationManager.delegate = self
        updateWiFiNamePermission()

        monitor.pathUpdateHandler = { [weak self] path in
            let onWifi     = path.usesInterfaceType(.wifi)
            let onEthernet = path.usesInterfaceType(.wiredEthernet)
            let primaryInterfaceName = path.availableInterfaces.first {
                (onWifi && $0.type == .wifi) || (onEthernet && $0.type == .wiredEthernet)
            }?.name
            let primaryAddress = primaryInterfaceName.flatMap { Self.ipv4Address(forInterface: $0) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ssid: String? = onWifi ? Self.fetchCurrentSSID() : nil
                self.isOnWiFi     = onWifi
                self.isOnEthernet = onEthernet
                self.currentSSID  = ssid
                self.log.info("Network change — wifi=\(onWifi) ethernet=\(onEthernet) ssid=\(ssid ?? "nil")")

                let previous = self.lastPrimaryInterfaceFingerprint
                if let name = primaryInterfaceName, let address = primaryAddress {
                    self.lastPrimaryInterfaceFingerprint = (name, address)
                    if let previous, previous.name == name, previous.address != address {
                        self.log.info("Local IP changed on \(name): \(previous.address) -> \(address)")
                        await self.onLocalAddressChange?()
                    }
                } else {
                    self.lastPrimaryInterfaceFingerprint = nil
                }

                await self.onNetworkChange?()
            }
        }
        monitor.start(queue: queue)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    deinit {
        monitor.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleSystemWake() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log.info("System woke from sleep")
            await self.onSystemWake?()
        }
    }

    // MARK: - Wi-Fi name permission (Location Services)

    /// Prompts for Location access if not yet decided. Safe to call repeatedly —
    /// macOS only shows the system dialog once per app.
    func requestWiFiNamePermissionIfNeeded() {
        guard locationManager.authorizationStatus == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
    }

    func openLocationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    private func updateWiFiNamePermission() {
        switch locationManager.authorizationStatus {
        case .authorized, .authorizedAlways:
            hasWiFiNamePermission = true
        default:
            hasWiFiNamePermission = false
        }
    }

    // MARK: - Rule matching

    /// True if either the connect or the disconnect half of the rule matches the current network.
    func matchesTunnel(_ tunnel: Tunnel) -> Bool {
        matchesConnect(tunnel) || matchesDisconnect(tunnel)
    }

    func matchesConnect(_ tunnel: Tunnel) -> Bool {
        matches(tunnel.autoConnectRule.connect)
    }

    func matchesDisconnect(_ tunnel: Tunnel) -> Bool {
        matches(tunnel.autoConnectRule.disconnect)
    }

    private func matches(_ rule: AutoConnectNetworkMatch) -> Bool {
        guard rule.enabled else { return false }
        switch rule.interface {
        case .ethernet: return isOnEthernet
        case .wifi:     return matchesWiFi(rule: rule)
        case .both:     return isOnEthernet || matchesWiFi(rule: rule)
        }
    }

    private func matchesWiFi(rule: AutoConnectNetworkMatch) -> Bool {
        guard isOnWiFi else { return false }
        if rule.matchesAnyWiFi { return true }
        guard let ssid = currentSSID else { return false }
        return rule.wifiSSIDs.contains(ssid)
    }

    // MARK: - Auto-connect state tracking

    func markAutoConnected(_ id: UUID)        { autoConnectedIDs.insert(id) }
    func markAutoDisconnected(_ id: UUID)     { autoConnectedIDs.remove(id) }
    func wasAutoConnected(_ id: UUID) -> Bool { autoConnectedIDs.contains(id) }

    /// Call when the user manually disconnects — suppresses reconnect while network still matches.
    func userDidDisconnect(_ id: UUID) {
        autoConnectedIDs.remove(id)
        suppressedIDs.insert(id)
    }

    /// Call when the user manually connects — lifts suppression.
    func userDidConnect(_ id: UUID) {
        suppressedIDs.remove(id)
        autoConnectedIDs.remove(id)
    }

    /// Clear suppression for a tunnel whose network condition stopped matching.
    /// Next time the matching network appears it will auto-connect again.
    func clearSuppression(_ id: UUID) {
        suppressedIDs.remove(id)
    }

    func isSuppressed(_ id: UUID) -> Bool { suppressedIDs.contains(id) }

    // MARK: - SSID helpers

    static func fetchCurrentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    /// Networks macOS already remembers (System Settings > Wi-Fi > preferred networks),
    /// so the user can pick one instead of typing an SSID by hand. Shells out to
    /// networksetup(8), which (unlike CoreWLAN scanning) needs no location permission.
    nonisolated static func knownWiFiNetworkNames() -> [String] {
        guard let device = wifiDeviceName() else { return [] }
        guard let output = runNetworksetup(["-listpreferredwirelessnetworks", device]) else { return [] }
        return output
            .split(separator: "\n")
            .dropFirst() // "Preferred networks on enX:"
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private nonisolated static func wifiDeviceName() -> String? {
        guard let output = runNetworksetup(["-listallhardwareports"]) else { return nil }
        let lines = output.components(separatedBy: "\n")
        guard let portIndex = lines.firstIndex(where: { $0.contains("Hardware Port: Wi-Fi") }),
              portIndex + 1 < lines.count,
              let range = lines[portIndex + 1].range(of: "Device: ")
        else { return nil }
        return String(lines[portIndex + 1][range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// The IPv4 address currently bound to a named interface (e.g. "en0"), or nil
    /// if the interface has none. Used to notice DHCP lease renewals, which change
    /// the interface's own address without triggering an interface/SSID switch.
    private nonisolated static func ipv4Address(forInterface interfaceName: String) -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let ifa = pointer {
            defer { pointer = ifa.pointee.ifa_next }
            guard let sockaddr = ifa.pointee.ifa_addr, sockaddr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard String(cString: ifa.pointee.ifa_name) == interfaceName else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                sockaddr, socklen_t(sockaddr.pointee.sa_len),
                &hostBuffer, socklen_t(hostBuffer.count),
                nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            return String(cString: hostBuffer)
        }
        return nil
    }

    private nonisolated static func runNetworksetup(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

extension NetworkMonitorService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateWiFiNamePermission()
            // Permission just changed — re-read the SSID immediately instead of
            // waiting for the next network path event.
            if self.isOnWiFi {
                self.currentSSID = Self.fetchCurrentSSID()
            }
        }
    }
}
