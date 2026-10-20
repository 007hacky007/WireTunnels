import Darwin
import Foundation

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw InventoryError.operation("FAILED: \(message)") }
}

private func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw InventoryError.operation("FAILED: expected rejection")
}

private final class NetworkFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var events: [String] = []
    var rules = ""
    var peerPrefixes: [String] = []
    var failRoute = false
    var reachable = true
    var supportsAnchor = true
    var states = ""
    lazy var service = InventoryRoutingService(file: directory.appendingPathComponent("policies.json"), expectedUID: getuid(),
        run: { [unowned self] _, arguments, input in
            if arguments == ["-sr"] { return self.supportsAnchor ? "anchor \"com.apple/*\" all" : "" }
            if arguments.contains("-f") { self.rules = input ?? ""; self.events.append("guard") }
            if arguments.contains("-k") { self.events.append("kill " + arguments.joined(separator: " ")) }
            return arguments == ["-ss"] ? self.states : ""
        }, resolve: { [unowned self] _ in
            guard self.reachable else { throw InventoryError.staleOperation }
            return InventoryLiveInterface(name: "utun123", endpointHost: "198.51.100.1", endpointPort: 51820)
        }, updatePeer: { [unowned self] _, _, prefixes in
            self.events.append("peer"); self.peerPrefixes = prefixes
        }, route: { [unowned self] add, prefix, _ in
            self.events.append("\(add ? "add" : "remove") \(prefix.string)")
            if add && self.failRoute { throw InventoryError.operation("Injected route failure") }
        })

    deinit { try? FileManager.default.removeItem(at: directory) }
    func request() -> InventoryRoutingRequest {
        InventoryRoutingRequest(action: .protect, ownerID: UUID(), generation: UUID(), configName: "test.conf",
            localPublicKey: Data(repeating: 1, count: 32).base64EncodedString(),
            peerPublicKey: Data(repeating: 2, count: 32).base64EncodedString(),
            staticPrefixes: ["192.0.2.0/24"], discoveredPrefixes: [])
    }
    func records() throws -> [InventoryRoutingService.Record] {
        try JSONDecoder().decode([InventoryRoutingService.Record].self,
            from: Data(contentsOf: directory.appendingPathComponent("policies.json")))
    }
}

@main
struct InventoryRoutingTests {
    static func main() async throws {
        try prefixes()
        try policies()
        try failures()
        try ownershipAndRestoration()
        try persistence()
        try routeMessages()
        try await commands()
        try await appIntegration()
        print("PASS: prefixes, policy lifecycle, rollback, ownership, restoration, persistence, route encoding, command execution, app integration")
    }

    static func prefixes() throws {
        try check(IPPrefix.normalized(["192.0.2.17/24", "192.0.2.0/24", "2001:0DB8::1", "192.0.2.4"]) ==
            ["192.0.2.0/24", "192.0.2.4/32", "2001:db8::1/128"], "canonical IPv4/IPv6 and deduplication")
        try check(IPPrefix("::/0").contains(IPPrefix("2001:db8::1")), "IPv6 default contains IPv6 host")
        try check(!IPPrefix("::/0").contains(IPPrefix("192.0.2.1")), "families remain separate")
        try check(IPPrefix.parseOutput(Data("192.0.2.1,\n2001:db8::2\t192.0.2.1".utf8)).count == 2, "stdout separators")
        for invalid in ["", "hostname", "192.0.2.256", "192.0.2.1/33", "::/129", "fe80::1%en0", "::/", "::/1/2"] {
            try rejects { _ = try IPPrefix(invalid) }
        }
        try rejects { _ = try IPPrefix.parseOutput(Data("192.0.2.1\ninvalid".utf8)) }
        try rejects { _ = try IPPrefix.parseOutput(Data()) }
        try rejects { _ = try IPPrefix.normalized(Array(repeating: "192.0.2.1", count: 100_001)) }
    }

    static func policies() throws {
        let f = NetworkFixture()
        var request = f.request()
        try f.service.perform(request, uid: getuid())
        try check(f.rules.contains("block return out quick"), "static prefixes blocked before connection")
        try check(!f.rules.contains("on utun"), "disconnected policy permits no tunnel interface")
        request.action = .apply
        request.discoveredPrefixes = ["192.0.2.7", "203.0.113.7", "2001:db8::1"]
        f.events = []
        try f.service.perform(request, uid: getuid())
        try check(f.events.first == "guard", "protection precedes peer and route changes")
        try check(f.peerPrefixes == ["192.0.2.0/24", "192.0.2.7/32", "203.0.113.7/32", "2001:db8::1/128"], "append static and discovered AllowedIPs")
        try check(!f.events.contains("add 192.0.2.7/32"), "static routes remain managed by wg-quick")
        try check(f.rules.contains("pass out quick on utun123"), "open tunnel path after successful route update")
        try check(f.events.last == "guard", "open tunnel only after installing routes")
        request.discoveredPrefixes = ["203.0.113.8"]
        f.events = []
        try f.service.perform(request, uid: getuid())
        try check(f.events.contains("remove 203.0.113.7/32") && f.events.contains("add 203.0.113.8/32"), "refresh replaces owned dynamic routes")
        request.action = .protect; request.generation = UUID(); request.discoveredPrefixes = []
        try f.service.perform(request, uid: getuid())
        try check(!f.rules.contains("on utun"), "disconnect closes tunnel exception")
        try check(f.rules.contains("203.0.113.8/32"), "helper retains cached protection even with empty app cache")
        try check(try f.records()[0].ownedRoutes.isEmpty, "disconnect removes owned dynamic routes")
        request.action = .remove
        try f.service.perform(request, uid: getuid())
        try check(try f.records().isEmpty, "explicit disable removes persistent policy")
    }

    static func failures() throws {
        let f = NetworkFixture(); var request = f.request()
        f.supportsAnchor = false
        try rejects { try f.service.perform(request, uid: getuid()) }
        try check(!f.events.contains("peer"), "unsupported PF layout cannot apply routes")
        f.supportsAnchor = true
        try f.service.perform(request, uid: getuid())
        request.action = .apply; request.discoveredPrefixes = ["203.0.113.1"]
        f.failRoute = true
        try rejects { try f.service.perform(request, uid: getuid()) }
        try check(!f.rules.contains("on utun"), "route failure retains destination block")
        try check(try f.records()[0].interface == nil, "failed update cannot persist an allowed interface")
        request.generation = UUID()
        try rejects { try f.service.perform(request, uid: getuid()) }
        request.action = .protect; request.peerPublicKey = "invalid"
        try rejects { try f.service.perform(request, uid: getuid()) }
    }

    static func ownershipAndRestoration() throws {
        let f = NetworkFixture(); var request = f.request()
        f.states = "all tcp 192.0.2.3:443 <- 198.51.100.2:52000 ESTABLISHED:ESTABLISHED\nall udp [2001:db8::2]:53 <- [2001:db8:1::2]:55000"
        request.staticPrefixes.append("2001:db8::/64")
        try f.service.perform(request, uid: getuid())
        try check(f.events.contains("kill -k 0.0.0.0/0 -k 192.0.2.3"), "existing IPv4 destination state is killed")
        try check(f.events.contains("kill -k ::/0 -k 2001:db8::2"), "existing IPv6 destination state is killed")
        try rejects { try f.service.perform(request, uid: getuid() + 1) }
        var overlapping = f.request(); overlapping.staticPrefixes = ["192.0.2.5"]
        try rejects { try f.service.perform(overlapping, uid: getuid()) }
        request.action = .apply; request.discoveredPrefixes = ["203.0.113.1"]
        try f.service.perform(request, uid: getuid())
        f.reachable = false
        try f.service.restoreProtection()
        try check(!f.rules.contains("on utun"), "helper restart restores blocks without trusting stored interface names")
        try check(try f.records()[0].request.action == .protect, "restart persists blocked state")
    }

    static func persistence() throws {
        var tunnel = Tunnel(name: "Example", configPath: "/tmp/example.conf")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let legacy = try decoder.decode(Tunnel.self, from: encoder.encode(tunnel))
        try check(legacy.inventoryCommand == nil && legacy.inventoryAllowedIPs.isEmpty, "existing metadata loads with no inventory")
        tunnel.inventoryCommand = InventoryCommand(executable: "/usr/bin/python3", arguments: ["/example.py", "https://inventory.example.com/"])
        tunnel.inventoryAllowedIPs = ["192.0.2.4/30"]; tunnel.inventoryUpdatedAt = Date()
        try check(decoder.decode(Tunnel.self, from: encoder.encode(tunnel)) == tunnel, "command and successful cache round trip")
    }

    static func routeMessages() throws {
        for value in ["203.0.113.1/32", "203.0.113.0/24", "2001:db8::/64", "2001:db8::1/128"] {
            let prefix = try IPPrefix(value)
            let data = InventoryRouteSocket.message(type: RTM_ADD, prefix: prefix, interfaceIndex: 42, sequence: 7)
            let header = data.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
            try check(header.rtm_msglen == data.count && header.rtm_index == 42 && header.rtm_seq == 7, "routing message size and identity")
            try check(header.rtm_addrs == RTA_DST | RTA_GATEWAY | RTA_NETMASK, "routing message includes destination, interface gateway, and mask")
            try check((header.rtm_flags & RTF_HOST != 0) == (prefix.length == prefix.bytes.count * 8), "host flag follows mask length")
        }
    }

    static func commands() async throws {
        let result = try await InventoryCommandService.run(InventoryCommand(executable: "/usr/bin/printf", arguments: ["%s\\n", "192.0.2.1", "2001:db8::1"]))
        try check(result == ["192.0.2.1/32", "2001:db8::1/128"], "direct unprivileged command captures final output")
        do {
            _ = try await InventoryCommandService.run(InventoryCommand(executable: "/usr/bin/false", arguments: []))
            throw InventoryError.operation("FAILED: nonzero command accepted")
        } catch InventoryError.commandFailed { }
        do {
            _ = try await InventoryCommandService.run(InventoryCommand(executable: "/bin/sleep", arguments: ["10"]), timeout: 0.05)
            throw InventoryError.operation("FAILED: command timeout ignored")
        } catch InventoryError.timedOut { }
        let task = Task { try await InventoryCommandService.run(InventoryCommand(executable: "/bin/sleep", arguments: ["10"])) }
        try await Task.sleep(nanoseconds: 30_000_000); task.cancel()
        do { _ = try await task.value; throw InventoryError.operation("FAILED: cancellation ignored") }
        catch is CancellationError { }
        let many = (0..<10_000).map { "10.\($0 / 256).\($0 % 256).1" }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try many.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let bulk = try await InventoryCommandService.run(InventoryCommand(executable: "/bin/cat", arguments: [file.path]))
        try check(bulk.count == many.count, "bulk inventory drains pipe without truncation")
    }
}
