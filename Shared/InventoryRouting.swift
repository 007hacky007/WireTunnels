import Darwin
import Foundation

nonisolated struct InventoryCommand: Codable, Hashable {
    var executable: String
    var arguments: [String]
}

nonisolated struct InventoryRoutingRequest: Codable {
    enum Action: String, Codable { case protect, apply, remove }
    var action: Action
    var ownerID: UUID
    var generation: UUID
    var configName: String
    var localPublicKey: String
    var peerPublicKey: String
    var staticPrefixes: [String]
    var discoveredPrefixes: [String]
}

nonisolated struct IPPrefix: Hashable, Comparable {
    let bytes: [UInt8]
    let length: Int
    var family: Int32 { bytes.count == 4 ? AF_INET : AF_INET6 }

    init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !value.contains("%") else { throw InventoryError.invalidOutput }
        var address4 = in_addr(), address6 = in6_addr()
        var raw: [UInt8]
        if inet_pton(AF_INET, String(parts[0]), &address4) == 1 {
            raw = withUnsafeBytes(of: &address4) { Array($0) }
        } else if inet_pton(AF_INET6, String(parts[0]), &address6) == 1 {
            raw = withUnsafeBytes(of: &address6) { Array($0) }
        } else { throw InventoryError.invalidOutput }
        let bits = parts.count == 1 ? raw.count * 8 : (Int(parts[1]) ?? -1)
        guard (0...(raw.count * 8)).contains(bits) else { throw InventoryError.invalidOutput }
        for i in raw.indices {
            let kept = max(0, min(8, bits - i * 8))
            raw[i] &= kept == 0 ? 0 : UInt8(0xff << (8 - kept) & 0xff)
        }
        bytes = raw
        length = bits
    }

    var string: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        return "\(String(cString: buffer))/\(length)"
    }

    func contains(_ other: IPPrefix) -> Bool {
        guard family == other.family, length <= other.length else { return false }
        for bit in 0..<length {
            let mask = UInt8(1 << (7 - bit % 8))
            if bytes[bit / 8] & mask != other.bytes[bit / 8] & mask { return false }
        }
        return true
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.bytes.count != rhs.bytes.count { return lhs.bytes.count < rhs.bytes.count }
        if lhs.bytes != rhs.bytes { return lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
        return lhs.length < rhs.length
    }

    static func normalized(_ values: [String]) throws -> [String] {
        guard values.count <= 100_000 else { throw InventoryError.invalidOutput }
        return try Set(values.map(Self.init)).sorted().map(\.string)
    }

    static func parseOutput(_ data: Data) throws -> [String] {
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw InventoryError.invalidOutput
        }
        let values = text.split { $0.isWhitespace || $0 == "," }.map(String.init)
        guard !values.isEmpty else { throw InventoryError.invalidOutput }
        return try normalized(values)
    }
}

nonisolated enum InventoryError: LocalizedError {
    case invalidOutput, invalidCommand, commandFailed, timedOut, staleOperation
    case operation(String)
    var errorDescription: String? {
        switch self {
        case .invalidOutput: return "Inventory must contain IP addresses or CIDRs, with no scopes, and at most 100,000 entries (8 MiB)."
        case .invalidCommand: return "Choose an executable using an absolute path. Arguments are passed individually, without a shell."
        case .commandFailed: return "The inventory command failed. The last successful inventory was kept."
        case .timedOut: return "The inventory command exceeded its 60-second deadline."
        case .staleOperation: return "The tunnel changed while its inventory was being refreshed."
        case .operation(let message): return message
        }
    }
}
