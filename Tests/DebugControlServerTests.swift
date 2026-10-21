import Darwin
import Foundation

/// Opens `path`, optionally sends `payload`, and returns everything the server answers.
func exchange(_ path: String, _ payload: Data?) -> String {
    let client = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(client) }
    _ = fcntl(client, F_SETNOSIGPIPE, 1)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in path.utf8CString.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return "CONNECT-FAILED" }
    if let payload {
        payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(client, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }
    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(client, &chunk, chunk.count)
        if count <= 0 { break }
        reply.append(chunk, count: count)
    }
    return String(decoding: reply, as: UTF8.self)
}

@main
struct DebugControlServerTests {
    static func main() throws {
        let path = NSTemporaryDirectory() + "dc-\(getpid()).sock"
        let server = DebugControlServer(path: path) { request in
            Data(("echo:" + String(decoding: request, as: UTF8.self)).utf8)
        }
        try server.start()
        defer { server.stop() }

        var attributes = stat()
        guard stat(path, &attributes) == 0, attributes.st_mode & 0o777 == 0o600 else {
            print("FAIL: the control socket must be readable and writable by its owner only")
            exit(1)
        }
        guard exchange(path, Data("hello\n".utf8)) == "echo:hello\n" else {
            print("FAIL: one request line must return one reply line")
            exit(1)
        }
        // A client that never sends anything must not block the next one.
        let silent = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(silent) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8CString.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(silent, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard exchange(path, Data("second\n".utf8)) == "echo:second\n" else {
            print("FAIL: an idle connection blocked another client")
            exit(1)
        }
        guard exchange(path, Data(repeating: 0x41, count: 2 << 20)).isEmpty else {
            print("FAIL: an oversized request must be dropped without a reply")
            exit(1)
        }
        guard exchange(path, Data("still-alive\n".utf8)) == "echo:still-alive\n" else {
            print("FAIL: the server stopped answering after an oversized request")
            exit(1)
        }
        server.stop()
        guard exchange(path, Data("x\n".utf8)) == "CONNECT-FAILED" else {
            print("FAIL: a stopped server must not accept connections")
            exit(1)
        }
        do {
            try DebugControlServer(path: "/tmp/" + String(repeating: "a", count: 120)) { $0 }.start()
            print("FAIL: a path longer than sun_path must be rejected")
            exit(1)
        } catch {}
        print("PASS: debug control socket is owner-only, line-based, isolated per connection and size-bounded")
    }
}
