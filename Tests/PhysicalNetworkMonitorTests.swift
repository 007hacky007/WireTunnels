import Foundation

// Controlled Network.framework boundary. These fixtures are the two different
// route views supplied by macOS while a userspace VPN owns the default route.
// No host interfaces, routes, DNS settings or tunnels are changed by this test.
private struct NWInterface {
    enum InterfaceType: Hashable { case wifi, wiredEthernet, other, loopback }
    let name: String
    let type: InterfaceType
}

private struct NWPath {
    var availableInterfaces: [NWInterface] = []
    func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool {
        availableInterfaces.contains { $0.type == type }
    }
}

private final class NWPathMonitor {
    static var created: NWPathMonitor?
    var currentPath = NWPath()
    var pathUpdateHandler: ((NWPath) -> Void)?
    private let prohibited: [NWInterface.InterfaceType]

    init() { prohibited = []; Self.created = self }
    init(prohibitedInterfaceTypes: [NWInterface.InterfaceType]) {
        prohibited = prohibitedInterfaceTypes
        Self.created = self
    }
    func start(queue: DispatchQueue) {}
    func cancel() {}
    func deliver(defaultPath: NWPath, physicalPath: NWPath) {
        // A monitor that allows VPN interfaces receives the VPN default path.
        currentPath = prohibited.contains(.other) ? physicalPath : defaultPath
        pathUpdateHandler?(currentPath)
    }
}

// PRODUCTION_NETWORK_MONITOR

@main
private struct PhysicalNetworkMonitorTests {
    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
    }

    @MainActor
    static func main() async throws {
        let service = NetworkMonitorService()
        let monitor = NWPathMonitor.created!
        let wifi = NWPath(availableInterfaces: [.init(name: "test-wifi", type: .wifi)])
        let ethernet = NWPath(availableInterfaces: [.init(name: "test-wired", type: .wiredEthernet)])
        let vpn = NWPath(availableInterfaces: [.init(name: "utun42", type: .other)])
        let offline = NWPath()
        var changes = 0
        service.onNetworkChange = { changes += 1 }

        func deliver(_ defaultPath: NWPath, _ physicalPath: NWPath) async throws {
            let before = changes
            monitor.deliver(defaultPath: defaultPath, physicalPath: physicalPath)
            for _ in 0..<1_000 {
                if changes > before { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            expect(false, "network observation was not delivered")
        }
        let wifiRule = AutoConnectNetworkMatch(enabled: true, interface: .wifi)
        let ethernetRule = AutoConnectNetworkMatch(enabled: true, interface: .ethernet)
        func matches(_ rule: AutoConnectNetworkMatch) -> Bool {
            var tunnel = Tunnel(name: "Synthetic tunnel", configPath: "/private/tmp/synthetic.conf")
            tunnel.autoConnectRule.connect = rule
            return service.matchesConnect(tunnel)
        }

        try await deliver(wifi, wifi)
        expect(matches(wifiRule), "Wi-Fi must match before a tunnel starts")
        for _ in 0..<3 {
            try await deliver(vpn, wifi)
            expect(matches(wifiRule), "a VPN default route must not make the Wi-Fi connect rule stop matching")
            try await deliver(wifi, wifi)
            expect(matches(wifiRule), "Wi-Fi must remain matched when the VPN route is removed")
        }
        try await deliver(vpn, ethernet)
        expect(matches(ethernetRule) && !matches(wifiRule),
            "a real switch to Ethernet must be observed even while the VPN owns the default route")
        try await deliver(vpn, offline)
        expect(!matches(ethernetRule) && !matches(wifiRule),
            "physical link loss must stop matching even if a VPN interface still exists")
        try await deliver(vpn, wifi)
        expect(matches(wifiRule), "physical Wi-Fi reconnection must restore matching")
        print("PASS: production network monitoring preserves physical rules across VPN routes and observes real switches and link loss")
    }
}
