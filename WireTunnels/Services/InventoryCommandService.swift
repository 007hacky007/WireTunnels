import Darwin
import Foundation

nonisolated enum InventoryCommandService {
    static func run(_ command: InventoryCommand, timeout: TimeInterval = 60) async throws -> [String] {
        guard command.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command.executable),
              !command.executable.contains("\0"), command.arguments.count <= 1024,
              command.arguments.reduce(0, { $0 + $1.utf8.count + 1 }) <= 128 * 1024,
              command.arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw InventoryError.invalidCommand
        }
        let worker = Task.detached(priority: .utility) { try capture(command, timeout: timeout) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private static func capture(_ command: InventoryCommand, timeout: TimeInterval) throws -> [String] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer { try? output.fileHandleForReading.close() }
        try process.run()
        let group = getpgid(process.processIdentifier)
        let isolated = group == process.processIdentifier && group != getpgrp()
        func stop() {
            if isolated { _ = kill(-group, SIGTERM) } else { process.terminate() }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
            if isolated { _ = kill(-group, SIGKILL) }
            else if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        func drain() throws {
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return }
                data.append(buffer, count: count)
                guard data.count <= 8 * 1024 * 1024 else { throw InventoryError.invalidOutput }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            repeat {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw InventoryError.timedOut }
                try drain()
                if !process.isRunning { break }
                usleep(10_000)
            } while true
            process.waitUntilExit()
            try drain()
            guard process.terminationStatus == 0 else { throw InventoryError.commandFailed }
            return try IPPrefix.parseOutput(data)
        } catch {
            stop()
            throw error
        }
    }
}
