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
    var ruleHistory: [String] = []
    var rules = ""
    var peerPrefixes: [String] = []
    var failRoute = false
    var failNextPeer = false
    var failRemoval: String?
    var reachable = true
    var supportsAnchor = true
    var states = ""
    var interfaceIndex: UInt32 = 123
    lazy var service = InventoryRoutingService(file: directory.appendingPathComponent("policies.json"), expectedUID: getuid(), localAddresses: { ["10.1.2.3"] },
        run: { [unowned self] _, arguments, input in
            if arguments == ["-sr"] { return self.supportsAnchor ? "anchor \"com.apple/*\" all" : "" }
            if arguments.contains("-f") { self.rules = input ?? ""; self.ruleHistory.append(self.rules); self.events.append("guard") }
            if arguments.contains("-k") { self.events.append("kill " + arguments.joined(separator: " ")) }
            return arguments == ["-ss"] ? self.states : ""
        }, resolve: { [unowned self] _ in
            guard self.reachable else { throw InventoryError.staleOperation }
            return InventoryLiveInterface(name: "utun123", endpointHost: "198.51.100.1", endpointPort: 51820, index: self.interfaceIndex)
        }, updatePeer: { [unowned self] _, _, prefixes in
            self.events.append("peer"); self.peerPrefixes = prefixes
            if self.failNextPeer { self.failNextPeer = false; throw InventoryError.operation("Partial peer update") }
        }, route: { [unowned self] add, prefix, _ in
            self.events.append("\(add ? "add" : "remove") \(prefix.string)")
            if add && self.failRoute { throw InventoryError.operation("Injected route failure") }
            if !add && self.failRemoval == prefix.string { throw InventoryError.operation("Injected removal failure") }
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
        try refreshRollback()
        try firewallInteraction()
        try interfaceReuse()
        try bulkPolicies()
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
        for invalid in ["0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "::/0", "::/1", "8000::/1",
                        "127.0.0.1", "169.254.1.1", "::1", "fe80::1", "ff02::1", "::ffff:192.0.2.1"] {
            try rejects { _ = try IPPrefix.parseOutput(Data(invalid.utf8)) }
        }
        try check(IPPrefix.inventoryPrefixes(["10.0.0.0/8", "2001:db8::/32"]).count == 2, "minimum inventory prefix lengths accepted")
        let index = IPPrefixIndex(try ["10.0.0.0/8", "10.1.0.0/16", "192.0.2.1", "2001:db8::/32"].map(IPPrefix.init))
        try check(index.contains(IPPrefix("10.1.2.3")) && index.overlaps(IPPrefix("192.0.2.0/24")) && !index.overlaps(IPPrefix("198.51.100.1")), "range index handles nested, covering and disjoint ranges")
    }

    static func policies() throws {
        let f = NetworkFixture()
        var request = f.request()
        try f.service.perform(request, uid: getuid())
        try check(f.rules.contains("block drop out quick"), "static prefixes blocked before connection")
        try check(!f.rules.contains("on utun"), "disconnected policy permits no tunnel interface")
        request.action = .apply
        request.discoveredPrefixes = ["192.0.2.7", "203.0.113.7", "2001:db8::1"]
        f.events = []
        try f.service.perform(request, uid: getuid())
        try check(f.events.first == "guard", "protection precedes peer and route changes")
        try check(f.peerPrefixes == ["192.0.2.0/24", "192.0.2.7/32", "203.0.113.7/32", "2001:db8::1/128"], "append static and discovered AllowedIPs")
        try check(!f.events.contains("add 192.0.2.7/32"), "static routes remain managed by wg-quick")
        try check(f.rules.contains("block drop out quick on ! utun123"), "open tunnel path after successful route update")
        try check(f.events.last == "guard", "open tunnel only after installing routes")
        f.events = []
        try f.service.perform(request, uid: getuid())
        try check(f.events.isEmpty, "unchanged inventory does not reload PF, purge states or rewrite routes")
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

    static func refreshRollback() throws {
        for failure in 0..<3 {
            let f = NetworkFixture(); var request = f.request()
            try f.service.perform(request, uid: getuid())
            request.action = .apply; request.discoveredPrefixes = ["203.0.113.1"]
            try f.service.perform(request, uid: getuid())
            let old = try f.records()[0]
            f.events = []; f.ruleHistory = []
            request.discoveredPrefixes = ["203.0.113.2"]
            if failure == 0 { f.failRoute = true }
            if failure == 1 { f.failNextPeer = true }
            if failure == 2 { f.failRemoval = "203.0.113.1/32" }
            try rejects { try f.service.perform(request, uid: getuid()) }
            let restored = try f.records()[0]
            try check(restored.request.discoveredPrefixes == old.request.discoveredPrefixes && restored.ownedRoutes == old.ownedRoutes, "failed refresh preserves root cache and route ownership")
            try check(f.rules.contains("203.0.113.1/32") && !f.rules.contains("203.0.113.2/32"), "failed refresh restores old physical-interface blocks")
            try check(f.ruleHistory.allSatisfy { $0.contains("block drop out quick on ! utun123") && !$0.contains("block return") }, "refresh leaves the verified VPN path open without resetting TCP")
            if failure > 0 { try check(f.peerPrefixes.contains("203.0.113.1/32") && !f.peerPrefixes.contains("203.0.113.2/32"), "partial peer update is rolled back") }
        }
        let f = NetworkFixture(); var request = f.request()
        try f.service.perform(request, uid: getuid())
        request.action = .apply; request.discoveredPrefixes = ["203.0.113.1"]
        try f.service.perform(request, uid: getuid())
        request.discoveredPrefixes = []; request.useCachedInventory = true
        try f.service.perform(request, uid: getuid())
        try check(f.records()[0].request.discoveredPrefixes == ["203.0.113.1/32"], "root cache wins over stale app metadata on reconnect")
        try rejects { try f.service.perform(.removal(ownerID: request.ownerID), uid: getuid() + 1) }
        try f.service.perform(.removal(ownerID: request.ownerID), uid: getuid())
        try check(f.records().isEmpty, "owner can remove policy without keys or a config file")
    }

    static func firewallInteraction() throws {
        let f = NetworkFixture(); var request = f.request()
        request.staticPrefixes = ["10.0.0.0/8"]
        f.states = "all tcp 10.1.2.3:52000 -> 198.51.100.2:443 ESTABLISHED:ESTABLISHED\nall tcp 10.1.2.3:52001 -> 10.8.0.1:443 ESTABLISHED:ESTABLISHED"
        try f.service.perform(request, uid: getuid())
        try check(!f.events.contains(where: { $0.contains("-k 198.51.100.2") }), "local protected source cannot kill unrelated Internet connections")
        try check(f.events.contains("kill -k 10.1.2.3 -k 10.8.0.1"), "remote protected destination is killed as an exact pair")
        try check(f.rules.contains("user root no state"), "unprivileged UDP cannot use endpoint exception")
        request.action = .apply
        try f.service.perform(request, uid: getuid())
        let inventory = f.rules
        let killSwitch = KillSwitchEntry.rules(for: [.init(interfaceName: "utun124", endpointHost: "198.51.100.2", endpointPort: 51820)])
        try check(InventoryRoutingService.anchor < InventoryRoutingService.killSwitchAnchor && InventoryRoutingService.anchor.hasPrefix("com.apple/") && InventoryRoutingService.killSwitchAnchor.hasPrefix("com.apple/"), "standard wildcard evaluates inventory before the kill switch")
        try check(inventory.contains("block drop out quick on ! utun123") && !inventory.contains("pass quick on utun"), "inventory blocks wrong interfaces before another VPN's quick pass")
        try check(killSwitch.hasPrefix("block drop all\n") && killSwitch.contains("pass quick on utun124 all"), "inventory's VPN exception falls through to the kill switch's own interface policy")
    }

    static func interfaceReuse() throws {
        let f = NetworkFixture(); var request = f.request()
        try f.service.perform(request, uid: getuid())
        request.action = .apply; request.discoveredPrefixes = ["203.0.113.1"]
        try f.service.perform(request, uid: getuid())
        f.interfaceIndex = 456 // Same utun name, newly created device.
        try f.service.reconcileInterfaces()
        try check(!f.rules.contains("on ! utun123") && f.records()[0].request.action == .protect, "reused interface name closes persisted VPN exception")
        f.events = []
        try f.service.perform(.removal(ownerID: request.ownerID), uid: getuid())
        try check(!f.events.contains(where: { $0.hasPrefix("remove ") }), "cleanup cannot delete routes from a replacement interface")
        for type in [RTM_IFINFO, RTM_NEWADDR, RTM_DELADDR, RTM_ADD] {
            let data = InventoryRouteSocket.message(type: type, prefix: try IPPrefix("192.0.2.1"), interfaceIndex: 123, sequence: 1)
            try check(InventoryInterfaceMonitor.containsInterfaceChange(data) == (type != RTM_ADD), "route watcher distinguishes interface changes from bulk route updates")
            try check(!InventoryInterfaceMonitor.containsInterfaceChange(Data(data.prefix(3))), "truncated notifications rejected")
        }
    }

    static func bulkPolicies() throws {
        let f = NetworkFixture(); var request = f.request()
        try f.service.perform(request, uid: getuid())
        request.action = .apply
        request.discoveredPrefixes = (0..<10_000).map { "10.\($0 / 256).\($0 % 256).1" }
        try f.service.perform(request, uid: getuid())
        try check(f.records()[0].ownedRoutes.count == 10_000, "ten thousand addresses install without truncation")
        f.events = []
        try f.service.perform(request, uid: getuid())
        try check(f.events.isEmpty, "ten thousand unchanged routes are a no-op")
    }

    static func ownershipAndRestoration() throws {
        let f = NetworkFixture(); var request = f.request()
        f.states = "all tcp 192.0.2.3:443 <- 198.51.100.2:52000 ESTABLISHED:ESTABLISHED\nall udp [2001:db8::2]:53 <- [2001:db8:1::2]:55000"
        request.staticPrefixes.append("2001:db8::/64")
        try f.service.perform(request, uid: getuid())
        try check(f.events.contains("kill -k 198.51.100.2 -k 192.0.2.3"), "existing IPv4 destination state is killed")
        try check(f.events.contains("kill -k 2001:db8:1::2 -k 2001:db8::2"), "existing IPv6 destination state is killed")
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
            let reply = try InventoryRouteSocket.decodeReply(data)
            try check(reply.prefix == prefix && InventoryRouteSocket.removalNeeded(reply, prefix: prefix, index: 42), "decode IPv4/IPv6 exact route and permit owned removal")
            try rejects { _ = try InventoryRouteSocket.removalNeeded(reply, prefix: prefix, index: 43) }
            try rejects { _ = try InventoryRouteSocket.decodeReply(Data(data.dropLast())) }
        }
        let host = try IPPrefix("203.0.113.1")
        let covering = try InventoryRouteSocket.decodeReply(InventoryRouteSocket.message(type: RTM_GET, prefix: try IPPrefix("0.0.0.0/0"), interfaceIndex: 9, sequence: 1))
        try check(!InventoryRouteSocket.removalNeeded(covering, prefix: host, index: 42), "covering physical default route is absence, not an ownership error")
        var missing = rt_msghdr(); missing.rtm_errno = ESRCH
        try check(!InventoryRouteSocket.removalNeeded(.init(header: missing), prefix: host, index: 42), "missing route removal is idempotent")
        missing.rtm_errno = EACCES
        try rejects { _ = try InventoryRouteSocket.removalNeeded(.init(header: missing), prefix: host, index: 42) }
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
