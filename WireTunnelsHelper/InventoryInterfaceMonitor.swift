import Darwin
import Foundation

/// Drain route notifications on a separate queue so bulk route updates cannot
/// hide an interface teardown while the inventory operation queue is busy.
final class InventoryInterfaceMonitor {
    private let source: DispatchSourceRead

    init(changed: @escaping () -> Void) throws {
        let fd = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd,
            queue: DispatchQueue(label: "com.fmdigitech.wiretunnels.interface-events"))
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            var changedInterface = false
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                if Self.containsInterfaceChange(Data(buffer.prefix(count))) { changedInterface = true }
            }
            if changedInterface { changed() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }

    static func containsInterfaceChange(_ data: Data) -> Bool {
        var offset = 0
        while offset + 4 <= data.count {
            let length = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) })
            guard length >= 4, offset + length <= data.count else { return false }
            let type = Int32(data[offset + 3])
            if [RTM_IFINFO, RTM_NEWADDR, RTM_DELADDR].contains(type) { return true }
            offset += length
        }
        return false
    }
}
