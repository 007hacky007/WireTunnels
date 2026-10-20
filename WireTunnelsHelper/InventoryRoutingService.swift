import Darwin
import Foundation

struct InventoryLiveInterface {
    var name: String
    var endpointHost: String
    var endpointPort: Int
    var index: UInt32 = 0
}

final class InventoryRoutingService {
    struct Record: Codable {
        var request: InventoryRoutingRequest
        var uid: uid_t
        var interface: String?
        var ownedRoutes: [String] = []
        var interfaceIndex: UInt32?
        var pendingPrefixes: [String]?
    }
    typealias Run = (URL, [String], String?) throws -> String
    private let file: URL
    private let run: Run
    private let resolve: (InventoryRoutingRequest) throws -> InventoryLiveInterface
    private let updatePeer: (InventoryLiveInterface, String, [String]) throws -> Void
    private let route: (Bool, IPPrefix, InventoryLiveInterface) throws -> Void
    private let expectedUID: uid_t
    private let localAddresses: () -> Set<String>
    private static let lock = NSRecursiveLock()
    static let anchor = "com.apple/wiretunnels.inventory"
    static let killSwitchAnchor = "com.apple/wiretunnels.killswitch"

    init(file: URL, expectedUID: uid_t = 0, localAddresses: @escaping () -> Set<String> = InventoryRoutingService.interfaceAddresses, run: @escaping Run,
         resolve: @escaping (InventoryRoutingRequest) throws -> InventoryLiveInterface,
         updatePeer: @escaping (InventoryLiveInterface, String, [String]) throws -> Void,
         route: @escaping (Bool, IPPrefix, InventoryLiveInterface) throws -> Void) {
        self.file = file; self.expectedUID = expectedUID; self.localAddresses = localAddresses; self.run = run
        self.resolve = resolve; self.updatePeer = updatePeer; self.route = route
    }

    func perform(_ input: InventoryRoutingRequest, uid: uid_t) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var records = try load()
        let old = records.first { $0.request.ownerID == input.ownerID }
        guard old == nil || old?.uid == uid else { throw InventoryError.operation("Inventory policy belongs to another user") }
        let others = records.filter { $0.request.ownerID != input.ownerID }
        if input.action == .remove {
            do {
                if let old, let live = matchingInterface(old) {
                    for value in old.ownedRoutes { try route(false, IPPrefix(value), live) }
                }
                try installGuard(others)
                try save(others)
            } catch {
                try? save(records)
                try? installGuard(records)
                throw error
            }
            return
        }
        var request = input
        guard request.configName.range(of: "^[A-Za-z0-9_=+.-]{1,15}\\.conf$", options: .regularExpression) != nil,
              !request.configName.contains(".."),
              Data(base64Encoded: request.peerPublicKey)?.count == 32,
              Data(base64Encoded: request.localPublicKey)?.count == 32 else { throw InventoryError.invalidOutput }
        request.staticPrefixes = try IPPrefix.normalized(request.staticPrefixes)
        request.discoveredPrefixes = try IPPrefix.inventoryPrefixes(request.discoveredPrefixes)
        guard !request.staticPrefixes.isEmpty else { throw InventoryError.invalidOutput }
        if request.action == .apply {
            guard old?.request.generation == request.generation else { throw InventoryError.staleOperation }
        }
        if request.action == .protect || request.useCachedInventory == true, let old {
            request.discoveredPrefixes = old.request.discoveredPrefixes
        }
        let effective = try IPPrefix.normalized(request.staticPrefixes + request.discoveredPrefixes)
        let protected = try effective.map(IPPrefix.init)
        for other in others {
            let prefixes = IPPrefixIndex(try guardedPrefixes(other).map(IPPrefix.init))
            guard !protected.contains(where: prefixes.overlaps) else {
                throw InventoryError.operation("Inventory-protected destinations cannot overlap another inventory tunnel")
            }
        }
        var record = Record(request: request, uid: uid)
        if let old {
            record.interface = old.interface; record.interfaceIndex = old.interfaceIndex
            record.ownedRoutes = old.ownedRoutes; record.pendingPrefixes = old.pendingPrefixes
        }
        if request.action == .protect {
            record.request.action = .protect
            do {
                try installGuard(others + [record], purge: effective)
                try save(others + [record])
            } catch {
                // A failed first enable must not leave an orphan policy behind.
                try? save(records)
                try? installGuard(records)
                throw error
            }
            if let old, let live = matchingInterface(old) {
                for value in old.ownedRoutes { try route(false, IPPrefix(value), live) }
            }
            record.interface = nil; record.interfaceIndex = nil; record.ownedRoutes = []
            try save(others + [record])
            return
        }
        let live = try resolve(request)
        guard live.name.range(of: "^utun[0-9]+$", options: .regularExpression) != nil, live.index > 0 else {
            throw InventoryError.staleOperation
        }
        let previousLive = old.flatMap(matchingInterface)
        let owned = previousLive?.name == live.name && previousLive?.index == live.index ? Set(old?.ownedRoutes ?? []) : []
        let staticPrefixes = IPPrefixIndex(try request.staticPrefixes.map(IPPrefix.init))
        let wanted = Set(try request.discoveredPrefixes.map(IPPrefix.init).filter { prefix in
            !staticPrefixes.contains(prefix)
        }.map(\.string))
        if let old, old.request.action == .apply, previousLive?.index == live.index,
           old.request.staticPrefixes == request.staticPrefixes, old.request.discoveredPrefixes == request.discoveredPrefixes,
           old.pendingPrefixes?.isEmpty != false, wanted == owned { return }

        var transition = old ?? record
        transition.pendingPrefixes = effective
        if previousLive == nil { transition.request.action = .protect }
        // Keep the verified VPN path open and block every physical fallback.
        let oldPrefixes = IPPrefixIndex(try (old.map(guardedPrefixes) ?? []).map(IPPrefix.init))
        let newlyProtected = protected.filter { !oldPrefixes.contains($0) }.map(\.string)
        var added: [String] = [], removed: [String] = []
        var peerChanged = false
        do {
            try installGuard(others + [transition], purge: newlyProtected)
            for value in wanted.subtracting(owned).sorted() {
                try route(true, IPPrefix(value), live)
                added.append(value)
            }
            // An error can occur after WireGuard accepted part of the update.
            peerChanged = true
            try updatePeer(live, request.peerPublicKey, effective)
            for value in owned.subtracting(wanted).sorted() {
                try route(false, IPPrefix(value), live)
                removed.append(value)
            }
            record.interface = live.name; record.interfaceIndex = live.index
            record.ownedRoutes = wanted.sorted(); record.pendingPrefixes = nil
            record.request.action = .apply
            try save(others + [record])
            try installGuard(others + [record])
        } catch {
            let originalError = error
            var rollbackFailed = false
            for value in removed {
                do { try route(true, IPPrefix(value), live) } catch { rollbackFailed = true }
            }
            if peerChanged, let old {
                do { try updatePeer(live, old.request.peerPublicKey,
                                   IPPrefix.normalized(old.request.staticPrefixes + old.request.discoveredPrefixes)) }
                catch { rollbackFailed = true }
            }
            var retained = owned
            for value in added {
                do { try route(false, IPPrefix(value), live) }
                catch { rollbackFailed = true; retained.insert(value) }
            }
            if rollbackFailed {
                // Keep the last good cache, the pending block set, and ownership for cleanup.
                transition.request.action = .protect
                transition.interface = live.name; transition.interfaceIndex = live.index
                transition.ownedRoutes = retained.union(removed).sorted()
                records = others + [transition]
            }
            do { try save(records); try installGuard(records) }
            catch {
                transition.request.action = .protect
                try? installGuard(others + [transition])
                throw InventoryError.operation("Inventory update failed and recovery is incomplete; reconnect the tunnel before retrying")
            }
            if rollbackFailed { throw InventoryError.operation("Inventory update failed; destinations remain blocked until the tunnel reconnects") }
            throw originalError
        }
    }

    func restoreProtection() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var records = try load()
        guard !records.isEmpty else { return }
        for i in records.indices { records[i].request.action = .protect }
        try installGuard(records, purge: try records.flatMap(guardedPrefixes))
        try save(records)
    }

    func reconcileInterfaces() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var records = try load()
        var changed = false
        for i in records.indices where records[i].request.action == .apply {
            if matchingInterface(records[i]) == nil {
                records[i].request.action = .protect
                changed = true
            }
        }
        if changed {
            try installGuard(records)
            try save(records)
        }
    }

    private func matchingInterface(_ record: Record) -> InventoryLiveInterface? {
        guard let name = record.interface, let live = try? resolve(record.request), live.name == name,
              record.interfaceIndex == nil || record.interfaceIndex == live.index else { return nil }
        return live
    }

    private func guardedPrefixes(_ record: Record) throws -> [String] {
        try IPPrefix.normalized(record.request.staticPrefixes + record.request.discoveredPrefixes + (record.pendingPrefixes ?? []), maximum: 200_000)
    }

    private func load() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == expectedUID,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
            throw InventoryError.operation("Unsafe inventory policy file")
        }
        return try JSONDecoder().decode([Record].self, from: Data(contentsOf: file))
    }

    private func save(_ records: [Record]) throws {
        let fm = FileManager.default, directory = file.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == expectedUID,
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
            throw InventoryError.operation("Unsafe inventory policy directory")
        }
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func installGuard(_ records: [Record], purge: [String] = []) throws {
        let pf = URL(fileURLWithPath: "/sbin/pfctl")
        if records.isEmpty { _ = try run(pf, ["-a", Self.anchor, "-F", "all"], nil); return }
        let main = try run(pf, ["-sr"], nil)
        guard main.contains("anchor \"com.apple/*\"") else {
            throw InventoryError.operation("The active PF rules must include the standard com.apple/* anchor before inventory protection can be enabled")
        }
        var lines = ["pass quick on lo0 all"]
        for (index, record) in records.enumerated() {
            let values = try guardedPrefixes(record)
            lines.append("table <inventory_\(index)> { \(values.joined(separator: ", ")) }")
        }
        let liveInterfaces = records.map { try? resolve($0.request) }
        for live in liveInterfaces.compactMap({ $0 }) {
            // Only the helper's root-owned WireGuard transport may use this exception.
            lines.append("pass out quick proto udp to \(live.endpointHost) port \(live.endpointPort) user root no state")
        }
        for (index, record) in records.enumerated() {
            let live = liveInterfaces[index]
            let allowed = record.request.action == .apply && record.interface == live?.name && record.interfaceIndex == live?.index
            let interface = allowed ? " on ! \(live!.name)" : ""
            // No quick VPN pass: the later kill-switch anchor must still be evaluated.
            lines.append("block drop out quick\(interface) to <inventory_\(index)>")
        }
        _ = try run(pf, ["-a", Self.anchor, "-f", "-"], lines.joined(separator: "\n") + "\n")
        _ = try run(pf, ["-e"], nil)
        if !purge.isEmpty { try purgeStates(prefixes: purge) }
    }

    private func purgeStates(prefixes: [String]) throws {
        let pf = URL(fileURLWithPath: "/sbin/pfctl")
        let ranges = IPPrefixIndex(try prefixes.map(IPPrefix.init))
        let local = localAddresses()
        let states = try run(pf, ["-ss"], nil)
        var pairs = Set<[String]>()
        for line in states.split(separator: "\n") {
            let addresses = Set(line.split(whereSeparator: \.isWhitespace).compactMap(Self.stateAddress))
            for host in addresses where !local.contains(host) {
                guard let address = try? IPPrefix(host), ranges.contains(address) else { continue }
                for other in addresses where other != host && other.contains(":") == host.contains(":") {
                    pairs.insert([host, other]); pairs.insert([other, host])
                }
            }
        }
        for pair in pairs.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            _ = try run(pf, ["-k", pair[0], "-k", pair[1]], nil)
        }
    }

    static func stateAddress(_ token: Substring) -> String? {
        var value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        if value.hasPrefix("["), let end = value.firstIndex(of: "]") {
            value = String(value[value.index(after: value.startIndex)..<end])
        } else if let bracket = value.firstIndex(of: "[") { value = String(value[..<bracket]) }
        if (try? IPPrefix(value)) == nil, value.contains("."), let colon = value.lastIndex(of: ":") {
            value = String(value[..<colon])
        }
        guard let address = try? IPPrefix(value) else { return nil }
        return address.string.components(separatedBy: "/")[0]
    }

    static func interfaceAddresses() -> Set<String> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result = Set<String>(), current = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let host = String(cString: buffer).components(separatedBy: "%")[0]
                result.insert(host)
            }
        }
        return result
    }
}
