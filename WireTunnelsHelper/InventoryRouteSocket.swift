import Darwin
import Foundation

final class InventoryRouteSocket {
    private let descriptor: Int32
    private var sequence: Int32 = 0

    init() throws {
        descriptor = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    deinit { close(descriptor) }

    static func message(type: Int32, prefix: IPPrefix, interfaceIndex: UInt16, sequence: Int32) -> Data {
        var header = rt_msghdr()
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_type = UInt8(type)
        header.rtm_index = interfaceIndex
        header.rtm_pid = getpid()
        header.rtm_seq = sequence
        header.rtm_flags = RTF_UP | RTF_STATIC
        if prefix.length == prefix.bytes.count * 8 { header.rtm_flags |= RTF_HOST }
        header.rtm_addrs = RTA_DST | RTA_NETMASK
        if type != RTM_GET { header.rtm_addrs |= RTA_GATEWAY }
        var addresses = Data()
        func append<T>(_ value: inout T) {
            withUnsafeBytes(of: &value) { addresses.append(contentsOf: $0) }
            // Darwin routing sockaddrs use 32-bit alignment, including on arm64.
            while addresses.count % 4 != 0 { addresses.append(0) }
        }
        func appendIP(_ bytes: [UInt8]) {
            if prefix.family == AF_INET {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: bytes) }
                append(&address)
            } else {
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: bytes) }
                append(&address)
            }
        }
        appendIP(prefix.bytes)
        if type != RTM_GET {
            var gateway = sockaddr_dl()
            gateway.sdl_len = UInt8(MemoryLayout<sockaddr_dl>.size)
            gateway.sdl_family = sa_family_t(AF_LINK)
            gateway.sdl_index = interfaceIndex
            append(&gateway)
        }
        let mask = prefix.bytes.indices.map { i -> UInt8 in
            let kept = max(0, min(8, prefix.length - i * 8))
            return kept == 0 ? 0 : UInt8(0xff << (8 - kept) & 0xff)
        }
        appendIP(mask)
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + addresses.count)
        var data = withUnsafeBytes(of: &header) { Data($0) }
        data.append(addresses)
        return data
    }

    struct Reply {
        var header: rt_msghdr
        var prefix: IPPrefix?
    }

    static func decodeReply(_ data: Data) throws -> Reply {
        guard data.count >= MemoryLayout<rt_msghdr>.size else { throw POSIXError(.EIO) }
        let header = data.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
        guard header.rtm_errno == 0 else { return Reply(header: header) }
        guard header.rtm_msglen <= data.count else { throw POSIXError(.EIO) }
        var offset = MemoryLayout<rt_msghdr>.size
        var addresses: [Int: Data] = [:]
        for i in 0..<RTAX_MAX where header.rtm_addrs & (1 << i) != 0 {
            guard offset < header.rtm_msglen else { throw POSIXError(.EIO) }
            let length = Int(data[offset])
            guard offset + length <= header.rtm_msglen else { throw POSIXError(.EIO) }
            addresses[Int(i)] = data.subdata(in: offset..<(offset + length))
            offset += length == 0 ? 4 : ((length + 3) & ~3)
        }
        guard let destination = addresses[Int(RTAX_DST)], destination.count >= 2 else { throw POSIXError(.EIO) }
        let family = Int32(destination[1])
        guard family == AF_INET || family == AF_INET6 else { throw POSIXError(.EIO) }
        let start = family == AF_INET ? 4 : 8, width = family == AF_INET ? 4 : 16
        guard destination.count >= start + width else { throw POSIXError(.EIO) }
        var bits = width * 8
        if header.rtm_flags & RTF_HOST == 0 {
            let mask = addresses[Int(RTAX_NETMASK)] ?? Data()
            bits = 0
            var ended = false
            for i in 0..<width {
                let byte = start + i < mask.count ? mask[start + i] : 0
                for bit in (0..<8).reversed() {
                    let set = byte & (1 << bit) != 0
                    guard !set || !ended else { throw POSIXError(.EIO) }
                    if set { bits += 1 } else { ended = true }
                }
            }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = destination.subdata(in: start..<(start + width)).withUnsafeBytes {
            inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count))
        }
        return Reply(header: header, prefix: try IPPrefix("\(String(cString: buffer))/\(bits)"))
    }

    static func removalNeeded(_ reply: Reply, prefix: IPPrefix, index: UInt16) throws -> Bool {
        if [ESRCH, ENOENT].contains(reply.header.rtm_errno) { return false }
        guard reply.header.rtm_errno == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: reply.header.rtm_errno) ?? .EIO)
        }
        // RTM_GET can return a covering route when the exact route is already gone.
        guard reply.prefix == prefix else { return false }
        guard reply.header.rtm_index == index else {
            throw InventoryError.operation("An inventory route changed ownership; it was left untouched")
        }
        return true
    }

    private func exchange(type: Int32, prefix: IPPrefix, index: UInt16) throws -> Reply {
        sequence &+= 1
        let data = Self.message(type: type, prefix: prefix, interfaceIndex: index, sequence: sequence)
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if written < 0 {
            var header = rt_msghdr()
            header.rtm_errno = errno
            return Reply(header: header)
        }
        guard written == data.count else { throw POSIXError(.EIO) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var buffer = [UInt8](repeating: 0, count: 65536)
        while ProcessInfo.processInfo.systemUptime < deadline {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw POSIXError(.EIO) }
            if ready == 0 { continue }
            let count = read(descriptor, &buffer, buffer.count)
            guard count >= MemoryLayout<rt_msghdr>.size else { continue }
            let reply = buffer.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
            if reply.rtm_pid == getpid(), reply.rtm_seq == sequence {
                return try Self.decodeReply(Data(buffer.prefix(count)))
            }
        }
        throw InventoryError.operation("Timed out waiting for a route acknowledgement")
    }

    func add(_ prefix: IPPrefix, interface: String, expectedIndex: UInt32) throws {
        let index = if_nametoindex(interface)
        guard index > 0, index == expectedIndex, index <= UInt16.max else { throw InventoryError.staleOperation }
        let reply = try exchange(type: RTM_ADD, prefix: prefix, index: UInt16(index))
        if reply.header.rtm_errno == EEXIST {
            // Existing routes belong to somebody else; never replace or claim them.
            throw InventoryError.operation("A route for \(prefix.string) already exists")
        }
        guard reply.header.rtm_errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: reply.header.rtm_errno) ?? .EIO) }
    }

    func remove(_ prefix: IPPrefix, interface: String, expectedIndex: UInt32) throws {
        let index = if_nametoindex(interface)
        if index == 0 { return }
        guard index == expectedIndex, index <= UInt16.max else { throw InventoryError.staleOperation }
        let current = try exchange(type: RTM_GET, prefix: prefix, index: 0)
        guard try Self.removalNeeded(current, prefix: prefix, index: UInt16(index)) else { return }
        guard if_nametoindex(interface) == expectedIndex else { throw InventoryError.staleOperation }
        let reply = try exchange(type: RTM_DELETE, prefix: prefix, index: UInt16(index))
        guard [0, ESRCH, ENOENT].contains(reply.header.rtm_errno) else {
            throw POSIXError(POSIXErrorCode(rawValue: reply.header.rtm_errno) ?? .EIO)
        }
    }
}
