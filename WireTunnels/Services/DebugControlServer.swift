#if DEBUG
import Darwin
import Foundation

/// Debug-only control channel: one JSON line per connection over a Unix socket
/// that only the current user can open, answered by `handler`. The whole file is
/// compiled out of Release builds, so shipped apps expose no such channel.
nonisolated final class DebugControlServer: @unchecked Sendable {
    enum ServerError: Error { case pathTooLong, socket(Int32) }

    static let defaultPath = AppPaths.userRoot.appendingPathComponent("debug-control.sock").path
    private static let maxRequestBytes = 1 << 20

    private let path: String
    private let handler: @Sendable (Data) async -> Data
    private var listener: Int32 = -1

    init(path: String = DebugControlServer.defaultPath, handler: @escaping @Sendable (Data) async -> Data) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        // sun_path is 104 bytes on macOS.
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ServerError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerError.socket(errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // Another user lacks write permission on the socket even before this chmod.
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 4) == 0 else {
            let failure = errno
            close(descriptor)
            throw ServerError.socket(failure)
        }
        listener = descriptor
        Thread.detachNewThread { [self] in acceptLoop(descriptor) }
    }

    func stop() {
        if listener >= 0 { close(listener) }
        listener = -1
        unlink(path)
    }

    private func acceptLoop(_ descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            Task.detached { [self] in await serve(client) }
        }
    }

    private func serve(_ client: Int32) async {
        defer { close(client) }
        // A silent peer must not pin a worker thread.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(client, F_SETNOSIGPIPE, 1)
        guard let request = readLine(from: client) else { return }
        var reply = await handler(request)
        reply.append(0x0A)
        reply.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(client, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private func readLine(from client: Int32) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < Self.maxRequestBytes {
            let count = read(client, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return nil }
            if let newline = chunk[..<count].firstIndex(of: 0x0A) {
                data.append(chunk, count: newline)
                return data
            }
            data.append(chunk, count: count)
        }
        return nil
    }
}
#endif
