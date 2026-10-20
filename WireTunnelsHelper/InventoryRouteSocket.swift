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

    private func exchange(type: Int32, prefix: IPPrefix, index: UInt16) throws -> rt_msghdr {
        sequence &+= 1
        let data = Self.message(type: type, prefix: prefix, interfaceIndex: index, sequence: sequence)
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
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
            if reply.rtm_pid == getpid(), reply.rtm_seq == sequence { return reply }
        }
        throw InventoryError.operation("Timed out waiting for a route acknowledgement")
    }

    @discardableResult
    func add(_ prefix: IPPrefix, interface: String) throws -> Bool {
        let index = if_nametoindex(interface)
        guard index > 0, index <= UInt16.max else { throw InventoryError.staleOperation }
        let reply = try exchange(type: RTM_ADD, prefix: prefix, index: UInt16(index))
        if reply.rtm_errno == EEXIST {
            // Existing routes belong to somebody else; never replace or claim them.
            throw InventoryError.operation("A route for \(prefix.string) already exists")
        }
        guard reply.rtm_errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: reply.rtm_errno) ?? .EIO) }
        return true
    }

    func remove(_ prefix: IPPrefix, interface: String) throws {
        let index = if_nametoindex(interface)
        if index == 0 { return }
        guard index <= UInt16.max else { throw InventoryError.staleOperation }
        let current = try exchange(type: RTM_GET, prefix: prefix, index: 0)
        if current.rtm_errno == ESRCH || current.rtm_errno == ENOENT { return }
        guard current.rtm_errno == 0, current.rtm_index == UInt16(index) else {
            throw InventoryError.operation("An inventory route changed ownership; it was left untouched")
        }
        let reply = try exchange(type: RTM_DELETE, prefix: prefix, index: UInt16(index))
        guard [0, ESRCH, ENOENT].contains(reply.rtm_errno) else {
            throw POSIXError(POSIXErrorCode(rawValue: reply.rtm_errno) ?? .EIO)
        }
    }
}
