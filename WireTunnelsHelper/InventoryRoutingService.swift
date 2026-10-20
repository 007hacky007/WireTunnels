import Darwin
import Foundation

struct InventoryLiveInterface {
    var name: String
    var endpointHost: String
    var endpointPort: Int
}

final class InventoryRoutingService {
    struct Record: Codable {
        var request: InventoryRoutingRequest
        var uid: uid_t
        var interface: String?
        var ownedRoutes: [String] = []
    }
    typealias Run = (URL, [String], String?) throws -> String
    private let file: URL
    private let run: Run
    private let resolve: (InventoryRoutingRequest) throws -> InventoryLiveInterface
    private let updatePeer: (String, String, [String]) throws -> Void
    private let route: (Bool, IPPrefix, String) throws -> Void
    private let expectedUID: uid_t
    private static let lock = NSRecursiveLock()
    static let anchor = "com.apple/wiretunnels.inventory"

    init(file: URL, expectedUID: uid_t = 0, run: @escaping Run,
         resolve: @escaping (InventoryRoutingRequest) throws -> InventoryLiveInterface,
         updatePeer: @escaping (String, String, [String]) throws -> Void,
         route: @escaping (Bool, IPPrefix, String) throws -> Void) {
        self.file = file; self.expectedUID = expectedUID; self.run = run
        self.resolve = resolve; self.updatePeer = updatePeer; self.route = route
    }

    func perform(_ input: InventoryRoutingRequest, uid: uid_t) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var request = input
        guard request.configName.range(of: "^[A-Za-z0-9_=+.-]{1,15}\\.conf$", options: .regularExpression) != nil,
              !request.configName.contains(".."),
              Data(base64Encoded: request.peerPublicKey)?.count == 32,
              Data(base64Encoded: request.localPublicKey)?.count == 32 else { throw InventoryError.invalidOutput }
        request.staticPrefixes = try IPPrefix.normalized(request.staticPrefixes)
        request.discoveredPrefixes = try IPPrefix.normalized(request.discoveredPrefixes)
        guard !request.staticPrefixes.isEmpty else { throw InventoryError.invalidOutput }
        var records = try load()
        let old = records.first { $0.request.ownerID == request.ownerID }
        guard old == nil || old?.uid == uid else { throw InventoryError.operation("Inventory policy belongs to another user") }
        if request.action == .apply {
            guard old?.request.generation == request.generation else { throw InventoryError.staleOperation }
        }
        if request.action == .protect, request.discoveredPrefixes.isEmpty, let old {
            request.discoveredPrefixes = old.request.discoveredPrefixes
        }
        if request.action != .remove {
            let protected = try (request.staticPrefixes + request.discoveredPrefixes).map(IPPrefix.init)
            for other in records where other.request.ownerID != request.ownerID {
                let otherPrefixes = try (other.request.staticPrefixes + other.request.discoveredPrefixes).map(IPPrefix.init)
                guard !protected.contains(where: { prefix in otherPrefixes.contains { prefix.contains($0) || $0.contains(prefix) } }) else {
                    throw InventoryError.operation("Inventory-protected destinations cannot overlap another inventory tunnel")
                }
            }
        }
        var record = Record(request: request, uid: uid)
        if let old { record.ownedRoutes = old.ownedRoutes; record.interface = old.interface }
        records.removeAll { $0.request.ownerID == request.ownerID }
        if request.action == .remove {
            if let old, let interface = old.interface, (try? resolve(old.request))?.name == interface {
                for value in old.ownedRoutes { try route(false, IPPrefix(value), interface) }
            }
            try installGuard(records)
            try save(records)
            return
        }
        // First close the physical path. An apply failure leaves these rules in place.
        record.request.action = .protect
        let blocked = records + [record]
        try save(blocked)
        try installGuard(blocked)
        if let old, let interface = old.interface, (try? resolve(old.request))?.name == interface {
            for value in old.ownedRoutes { try route(false, IPPrefix(value), interface) }
        }
        record.ownedRoutes = []
        record.interface = nil
        if request.action == .protect {
            try save(records + [record])
            return
        }
        let live = try resolve(request)
        guard live.name.range(of: "^utun[0-9]+$", options: .regularExpression) != nil else {
            throw InventoryError.staleOperation
        }
        let effective = try IPPrefix.normalized(request.staticPrefixes + request.discoveredPrefixes)
        try updatePeer(live.name, request.peerPublicKey, effective)
        let staticPrefixes = try request.staticPrefixes.map(IPPrefix.init)
        let additions = try request.discoveredPrefixes.map(IPPrefix.init).filter { prefix in
            !staticPrefixes.contains { $0.contains(prefix) }
        }
        do {
            for prefix in additions {
                try route(true, prefix, live.name)
                record.ownedRoutes.append(prefix.string)
            }
            record.interface = live.name
            record.request.action = .apply
            try save(records + [record])
            try installGuard(records + [record], endpoints: [request.ownerID: live])
        } catch {
            for value in record.ownedRoutes { try? route(false, IPPrefix(value), live.name) }
            record.interface = nil; record.ownedRoutes = []
            try? save(records + [record])
            try? installGuard(records + [record])
            throw error
        }
    }

    func restoreProtection() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var records = try load()
        guard !records.isEmpty else { return }
        for i in records.indices { records[i].request.action = .protect }
        try save(records)
        try installGuard(records)
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

    private func installGuard(_ records: [Record], endpoints: [UUID: InventoryLiveInterface] = [:]) throws {
        let pf = URL(fileURLWithPath: "/sbin/pfctl")
        if records.isEmpty { _ = try run(pf, ["-a", Self.anchor, "-F", "all"], nil); return }
        let main = try run(pf, ["-sr"], nil)
        guard main.contains("anchor \"com.apple/*\"") else {
            throw InventoryError.operation("The active PF rules must include the standard com.apple/* anchor before inventory protection can be enabled")
        }
        var lines: [String] = []
        var allPrefixes: [IPPrefix] = []
        for (index, record) in records.enumerated() {
            let values = try IPPrefix.normalized(record.request.staticPrefixes + record.request.discoveredPrefixes)
            allPrefixes += try values.map(IPPrefix.init)
            lines.append("table <inventory_\(index)> { \(values.joined(separator: ", ")) }")
        }
        let liveInterfaces = records.map { endpoints[$0.request.ownerID] ?? (try? resolve($0.request)) }
        for live in liveInterfaces.compactMap({ $0 }) {
            // Permit the encrypted transport even if its endpoint is in a protected range.
            lines.append("pass out quick proto udp to \(live.endpointHost) port \(live.endpointPort) no state")
        }
        for (index, record) in records.enumerated() {
            if let live = liveInterfaces[index], record.request.action == .apply, record.interface == live.name {
                lines.append("pass out quick on \(live.name) to <inventory_\(index)> no state")
            }
            lines.append("block return out quick to <inventory_\(index)>")
        }
        _ = try run(pf, ["-a", Self.anchor, "-f", "-"], lines.joined(separator: "\n") + "\n")
        _ = try run(pf, ["-e"], nil)
        // Existing physical connections must not bypass a newly installed policy via PF state.
        let states = try run(pf, ["-ss"], nil)
        var hosts = Set<String>()
        for token in states.split(whereSeparator: \.isWhitespace) {
            var value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            if value.hasPrefix("["), let end = value.firstIndex(of: "]") { value = String(value[value.index(after: value.startIndex)..<end]) }
            else if let bracket = value.firstIndex(of: "[") { value = String(value[..<bracket]) }
            if value.contains("."), let colon = value.lastIndex(of: ":") { value = String(value[..<colon]) }
            if let address = try? IPPrefix(value), allPrefixes.contains(where: { $0.contains(address) }) {
                hosts.insert(address.string.components(separatedBy: "/")[0])
            }
        }
        for host in hosts {
            _ = try run(pf, ["-k", host], nil)
            _ = try run(pf, ["-k", host.contains(":") ? "::/0" : "0.0.0.0/0", "-k", host], nil)
        }
    }
}
